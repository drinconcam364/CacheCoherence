// cache.sv  (owner: Person A)
// One private L1 cache: arrays, hit path, cache controller (Sorin Table 7.11),
// snoop logic and the pending-transaction register.
// Person A may split the controller into cache_ctrl.sv later; these ports stay the same.
// IN PROGRESS: Phase 1 done (arrays, hit path, miss handling, dirty eviction).
//              Phase 2 (snooping, MSI between cores) still to come.

/* verilator lint_off UNUSEDSIGNAL */  // remove once implemented
/* verilator lint_off UNUSEDPARAM */
module cache
  import mesi_pkg::*;
#(
  parameter int CORE_ID = 0
)(
  input  logic     clk,
  input  logic     rst_n,

  // Core side (traffic generator)
  input  logic     req_valid,
  output logic     req_ready,
  input  op_t      req_op,
  input  addr_t    req_addr,
  input  word_t    req_wdata,
  output logic     resp_valid,
  output word_t    resp_rdata,

  // Arbitration
  output logic     bus_req,
  input  logic     bus_gnt,          // this cache's grant bit

  // This cache's request and data, to bus.sv
  output bus_cmd_t cache_cmd,
  output addr_t    cache_addr,
  output put_t     cache_put_kind,
  output logic     cache_dval,
  output line_t    cache_data,

  // Bus broadcast, from bus.sv
  input  bus_cmd_t bus_cmd,
  input  addr_t    bus_addr,
  input  put_t     bus_put_kind,
  input  logic     bus_addr_valid,
  input  logic     bus_snoop_end,
  input  line_t    bus_data,
  input  logic     bus_data_valid,
  input  logic     bus_data_excl,
  input  logic     bus_done
);

  // ==================================================================
  // 1. Address decode of the incoming core request (cycle T)
  //    req_addr = | tag [31:11] | index [10:5] | word [4:2] | byte [1:0] |
  //    Only the index is needed in cycle T (to start the array read).
  //    Tag and word offset come from the saved copy in cycle T+1 (section 3).
  // ==================================================================
  index_t incoming_index;                       // which set the new request maps to

  assign incoming_index = get_index(req_addr);

  // ==================================================================
  // 2. Storage arrays (spec 3.1): one entry per set, direct-mapped for now
  //    tag_array / data_array: no reset, so synthesis can map them to block RAM.
  //    state_array: plain flip-flops, because reset must clear every line to I
  //    in one cycle and block RAM can't do that.
  // ==================================================================
  tag_t  tag_array   [N_SETS];                  // which memory line each set holds
  mesi_t state_array [N_SETS];                  // I / S / E / M for each set
  line_t data_array  [N_SETS];                  // the 8 data words of each set

  // ------------------------------------------------------------------
  // Read port (synchronous): give an index in cycle T with array_read_enable=1,
  // the tag/state/data for that set appear on array_read_* in cycle T+1.
  // One port, shared later by core lookups and snoops (snoop wins).
  // ------------------------------------------------------------------
  logic   array_read_enable;                    // 1 = read a set this cycle
  index_t array_read_index;                     // which set to read
  tag_t   array_read_tag;                       // tag of that set   (valid next cycle)
  mesi_t  array_read_state;                     // state of that set (valid next cycle)
  line_t  array_read_data;                      // data of that set  (valid next cycle)

  always_ff @(posedge clk) begin
    if (array_read_enable) begin
      array_read_tag  <= tag_array[array_read_index];
      array_read_data <= data_array[array_read_index];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n)
      array_read_state <= ST_I;
    else if (array_read_enable)
      array_read_state <= state_array[array_read_index];
  end

  // ------------------------------------------------------------------
  // Write port: separate enables, because different events write different fields
  //   fill (miss data arrives) : tag + state + data
  //   store hit                : state (-> M) + data
  //   eviction / snoop         : state only
  // ------------------------------------------------------------------
  index_t array_write_index;                    // which set to write
  logic   tag_array_write_enable;               // 1 = write array_write_tag
  logic   state_array_write_enable;             // 1 = write array_write_state
  logic   data_array_write_enable;              // 1 = write array_write_data
  tag_t   array_write_tag;                      // new tag
  mesi_t  array_write_state;                    // new state
  line_t  array_write_data;                     // new 8-word line

  always_ff @(posedge clk) begin
    if (tag_array_write_enable)  tag_array[array_write_index]  <= array_write_tag;
    if (data_array_write_enable) data_array[array_write_index] <= array_write_data;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int set = 0; set < N_SETS; set++)
        state_array[set] <= ST_I;
    end else if (state_array_write_enable) begin
      state_array[array_write_index] <= array_write_state;
    end
  end

  // ==================================================================
  // 3. Saved request: a copy of the core's request, taken at acceptance
  //    and held until the response (the core may change req_* after that edge).
  // ==================================================================
  logic   request_accepted;                     // 1 = req_valid && req_ready this cycle
  op_t    saved_op;                             // OP_LD or OP_ST
  addr_t  saved_addr;                           // full byte address
  word_t  saved_store_data;                     // data to write (stores only)

  assign request_accepted = req_valid && req_ready;

  always_ff @(posedge clk) begin
    if (request_accepted) begin
      saved_op         <= req_op;
      saved_addr       <= req_addr;
      saved_store_data <= req_wdata;
    end
  end

  logic      saved_is_store;                    // 1 = saved request is a store
  tag_t      saved_tag;                         // tag bits of saved_addr
  index_t    saved_index;                       // set index of saved_addr
  word_off_t saved_word_offset;                 // which of the 8 words (0..7)

  assign saved_is_store    = (saved_op == OP_ST);
  assign saved_tag         = get_tag(saved_addr);
  assign saved_index       = get_index(saved_addr);
  assign saved_word_offset = get_word(saved_addr);

  // ==================================================================
  // 4. Controller state machine: what the cache is doing right now
  // ==================================================================
  typedef enum logic [1:0] {
    CTRL_IDLE,      // waiting for a core request; req_ready = 1
    CTRL_LOOKUP,    // cycle T+1: array outputs valid, check for a hit
    CTRL_WAIT_BUS   // miss: waiting for our bus transaction to bring the line
  } controller_state_t;

  controller_state_t controller_state;          // current state (flip-flops)
  controller_state_t controller_state_next;     // next state (combinational)

  always_ff @(posedge clk) begin
    if (!rst_n) controller_state <= CTRL_IDLE;
    else        controller_state <= controller_state_next;
  end

  // ==================================================================
  // 5. Hit check, load word select, store merge (combinational, cycle T+1)
  // ==================================================================
  logic  tags_match;                            // stored tag == saved request's tag
  logic  load_hit;                              // tags match and line is S, E or M
  logic  store_hit;                             // tags match and line is E or M
  logic  request_hit;                           // load_hit or store_hit, by op
  word_t load_word;                             // the word a load returns
  line_t line_after_store;                      // the line with the store's word written in

  always_comb begin
    tags_match  = (array_read_tag == saved_tag);
    load_hit    = tags_match && (array_read_state != ST_I);
    store_hit   = tags_match && (array_read_state == ST_M || array_read_state == ST_E);
    request_hit = saved_is_store ? store_hit : load_hit;

    load_word   = array_read_data[saved_word_offset*WORD_W +: WORD_W];

    line_after_store = array_read_data;
    line_after_store[saved_word_offset*WORD_W +: WORD_W] = saved_store_data;
  end

  // ==================================================================
  // 6. Miss: which kind, and which transient state it starts in (Table 7.11)
  //    load  to a line we don't have      -> GetS, I -> IS^AD
  //    store to a line we don't have      -> GetM, I -> IM^AD
  //    store to a line we have in S       -> GetM, S -> SM^AD  (upgrade)
  // ==================================================================
  logic   starting_miss;                        // LOOKUP found a miss this cycle
  trans_t miss_first_transient_state;           // IS^AD, IM^AD or SM^AD

  assign starting_miss = (controller_state == CTRL_LOOKUP) && !request_hit;

  always_comb begin
    if (!saved_is_store)
      miss_first_transient_state = TR_IS_AD;
    else if (tags_match && array_read_state == ST_S)
      miss_first_transient_state = TR_SM_AD;
    else
      miss_first_transient_state = TR_IM_AD;
  end

  // ------------------------------------------------------------------
  // Dirty victim: the set holds a DIFFERENT line, and that line is M.
  // Memory's copy is stale, so it must be written back (PutM with data)
  // before the set can be reused. That makes the miss two transactions:
  //   1. PutM for the victim   (M -> MI^A -> I)
  //   2. GetS / GetM for the line the core asked for
  // An S victim is dropped silently (memory already has the data).
  // TODO (Phase 3): an E victim needs PutM NoData-E (EI^A).
  // ------------------------------------------------------------------
  logic   victim_is_dirty;                      // must write back before the miss
  addr_t  victim_line_addr;                     // line address of the victim
  trans_t after_eviction_transient_state;       // the miss to start once PutM is done

  assign victim_is_dirty  = !tags_match && (array_read_state == ST_M);
  assign victim_line_addr = make_line_addr(array_read_tag, saved_index);

  // The victim had a different tag, so the wanted line is definitely not here:
  // the follow-up is always a full miss (never the S -> M upgrade).
  assign after_eviction_transient_state = saved_is_store ? TR_IM_AD : TR_IS_AD;

  // ==================================================================
  // 7. Pending-transaction register (spec 3.2)
  //    The core is blocking, so a cache has at most one bus transaction in
  //    flight. Its transient state lives here, not in the array.
  //      *_AD : waiting for our request to reach the bus (address phase)
  //      *_D  : our request has been ordered, waiting for the data
  // ==================================================================
  trans_t pending_transient_state;              // TR_NONE = no transaction in flight
  addr_t  pending_line_addr;                    // line address we asked the bus for
  logic   pending_valid;                        // a transaction is in flight

  assign pending_valid = (pending_transient_state != TR_NONE);

  // Events from the bus that belong to OUR transaction (bus_gnt = it's ours)
  logic pending_waiting_for_address;            // in IS^AD / IM^AD / SM^AD
  logic pending_waiting_for_data;               // in IS^D  / IM^D  / SM^D
  logic own_address_phase;                      // our request is on the bus this cycle
  logic own_data_arrived;                       // the data for our request is on the bus

  assign pending_waiting_for_address = (pending_transient_state == TR_IS_AD) ||
                                       (pending_transient_state == TR_IM_AD) ||
                                       (pending_transient_state == TR_SM_AD);
  assign pending_waiting_for_data    = (pending_transient_state == TR_IS_D)  ||
                                       (pending_transient_state == TR_IM_D)  ||
                                       (pending_transient_state == TR_SM_D);
  assign own_address_phase = bus_gnt && bus_addr_valid && pending_waiting_for_address;
  assign own_data_arrived  = bus_gnt && bus_data_valid && pending_waiting_for_data;

  // PutM (eviction) events
  logic pending_is_eviction;                    // in MI^A: our PutM is in flight
  logic own_eviction_done;                      // our PutM finished this cycle
  logic pending_needs_grant;                    // we have a request that hasn't been granted

  assign pending_is_eviction = (pending_transient_state == TR_MI_A);
  assign own_eviction_done   = bus_gnt && bus_done && pending_is_eviction;
  assign pending_needs_grant = pending_waiting_for_address || pending_is_eviction;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pending_transient_state <= TR_NONE;
    end else if (starting_miss) begin
      if (victim_is_dirty) begin                // transaction 1: PutM the victim
        pending_transient_state <= TR_MI_A;
        pending_line_addr       <= victim_line_addr;
      end else begin                            // straight to GetS / GetM
        pending_transient_state <= miss_first_transient_state;
        pending_line_addr       <= line_addr(saved_addr);
      end
    end else if (own_eviction_done) begin       // transaction 2: now fetch the wanted line
      pending_transient_state <= after_eviction_transient_state;
      pending_line_addr       <= line_addr(saved_addr);
    end else if (own_address_phase) begin
      case (pending_transient_state)           // Own-GetS / Own-GetM: AD -> D
        TR_IS_AD: pending_transient_state <= TR_IS_D;
        TR_IM_AD: pending_transient_state <= TR_IM_D;
        TR_SM_AD: pending_transient_state <= TR_SM_D;
        default:  ;
      endcase
    end else if (own_data_arrived) begin
      pending_transient_state <= TR_NONE;       // transaction complete
    end
  end

  // ------------------------------------------------------------------
  // Eviction buffer: a copy of the victim's data, taken when the eviction
  // starts, so the PutM data doesn't depend on the array read port
  // (which snoops will reuse in Phase 2).
  // ------------------------------------------------------------------
  line_t eviction_line;                         // the dirty line being written back

  always_ff @(posedge clk) begin
    if (starting_miss && victim_is_dirty)
      eviction_line <= array_read_data;
  end

  // ------------------------------------------------------------------
  // PutM data timing: spec section 7 puts PutM data at G+4, the cycle right
  // after the bus_snoop_end pulse (G+3). Remember last cycle's pulse.
  // ------------------------------------------------------------------
  logic snoop_end_was_last_cycle;               // bus_snoop_end was 1 one cycle ago
  logic eviction_data_cycle;                    // drive our PutM data this cycle

  always_ff @(posedge clk) begin
    if (!rst_n) snoop_end_was_last_cycle <= 1'b0;
    else        snoop_end_was_last_cycle <= bus_snoop_end;
  end

  assign eviction_data_cycle = bus_gnt && pending_is_eviction && snoop_end_was_last_cycle;

  // ==================================================================
  // 8. Fill: what to install when our data arrives
  //    load : install the line as S (or E if memory says exclusive), return the word
  //    store: merge the store's word into the line, install as M
  // ==================================================================
  line_t fill_line;                             // line to write into data_array
  word_t fill_load_word;                        // word to return for a load miss
  mesi_t fill_state;                            // state to write into state_array

  always_comb begin
    fill_line = bus_data;
    if (saved_is_store)
      fill_line[saved_word_offset*WORD_W +: WORD_W] = saved_store_data;

    fill_load_word = bus_data[saved_word_offset*WORD_W +: WORD_W];

    if (saved_is_store)     fill_state = ST_M;
    else if (bus_data_excl) fill_state = ST_E;   // never 1 in the MSI build
    else                    fill_state = ST_S;
  end

  // ==================================================================
  // 9. Next state + array control (combinational)
  // ==================================================================
  always_comb begin
    // Defaults: stay in the same state, both array ports idle
    controller_state_next    = controller_state;
    array_read_enable        = 1'b0;
    array_read_index         = incoming_index;
    array_write_index        = saved_index;
    tag_array_write_enable   = 1'b0;
    state_array_write_enable = 1'b0;
    data_array_write_enable  = 1'b0;
    array_write_tag          = saved_tag;
    array_write_state        = ST_M;
    array_write_data         = line_after_store;

    case (controller_state)
      CTRL_IDLE: begin
        if (request_accepted) begin
          array_read_enable     = 1'b1;          // cycle T: start the array read
          controller_state_next = CTRL_LOOKUP;
        end
      end

      CTRL_LOOKUP: begin
        if (request_hit) begin
          if (saved_is_store) begin              // store hit: write word, line -> M
            data_array_write_enable  = 1'b1;
            state_array_write_enable = 1'b1;
          end
          controller_state_next = CTRL_IDLE;
        end else begin
          controller_state_next = CTRL_WAIT_BUS; // pending register starts PutM or GetS/GetM
        end
      end

      CTRL_WAIT_BUS: begin
        if (own_eviction_done) begin             // victim written back: its set is now I
          state_array_write_enable = 1'b1;
          array_write_state        = ST_I;
        end else if (own_data_arrived) begin     // install the line, finish the op
          tag_array_write_enable   = 1'b1;
          state_array_write_enable = 1'b1;
          data_array_write_enable  = 1'b1;
          array_write_tag          = saved_tag;
          array_write_state        = fill_state;
          array_write_data         = fill_line;
          controller_state_next    = CTRL_IDLE;
        end
      end

      default: controller_state_next = CTRL_IDLE;
    endcase
  end

  assign req_ready = (controller_state == CTRL_IDLE);

  // ==================================================================
  // 10. Response registers: resp_valid comes from a flop
  //     hit : decided in T+1, core sees it in T+2
  //     miss: decided on the data cycle, core sees it one cycle later
  // ==================================================================
  logic  finishing_hit;                         // LOOKUP found a hit this cycle
  logic  finishing_miss;                        // our miss data arrived this cycle
  logic  resp_valid_reg;                        // drives resp_valid
  word_t resp_rdata_reg;                        // drives resp_rdata

  assign finishing_hit  = (controller_state == CTRL_LOOKUP) && request_hit;
  assign finishing_miss = (controller_state == CTRL_WAIT_BUS) && own_data_arrived;

  always_ff @(posedge clk) begin
    if (!rst_n) resp_valid_reg <= 1'b0;
    else        resp_valid_reg <= finishing_hit || finishing_miss;
  end

  always_ff @(posedge clk) begin
    if (!saved_is_store) begin
      if (finishing_hit)       resp_rdata_reg <= load_word;
      else if (finishing_miss) resp_rdata_reg <= fill_load_word;
    end
  end

  assign resp_valid = resp_valid_reg;
  assign resp_rdata = resp_rdata_reg;

  // ==================================================================
  // 11. Bus outputs
  //     bus_req  : high while we wait for a grant, drops the cycle the grant shows up
  //     cache_cmd: GetS / GetM for the whole transaction (bus.sv reads it once granted)
  // ==================================================================
  assign bus_req = pending_needs_grant && !bus_gnt;

  always_comb begin
    case (pending_transient_state)
      TR_IS_AD, TR_IS_D:                    cache_cmd = CMD_GETS;
      TR_IM_AD, TR_IM_D, TR_SM_AD, TR_SM_D: cache_cmd = CMD_GETM;
      TR_MI_A:                              cache_cmd = CMD_PUTM;
      default:                              cache_cmd = CMD_NONE;
    endcase
  end

  assign cache_addr = pending_valid ? pending_line_addr : '0;

  // PutM from MI^A always carries data (PUT_NODATA / PUT_NODATA_E come in Phase 2 / 3)
  assign cache_put_kind = PUT_DATA;
  assign cache_dval     = eviction_data_cycle;
  assign cache_data     = eviction_data_cycle ? eviction_line : '0;

endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
