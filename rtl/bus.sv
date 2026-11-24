// bus.sv  (owner: Person B)
// Bus sequencer and muxes. Follows the spec Section 7 timeline:
//   G grant -> G+1 address (bus_addr_valid) -> snoop window (bus_snoop_end on its
//   last cycle) -> data -> bus_done.
// No tri-states: the granted cache's request and the data source are muxed here.
//
// How it works:
//   - Sequencer FSM: IDLE -> ADDR -> SNOOP (SNOOP_LAT cycles) -> DATA -> IDLE.
//     IDLE sees the arbiter's registered grant in cycle G and moves to ADDR for G+1.
//   - Request: the granted cache's cache_cmd / cache_addr / cache_put_kind are latched at the
//     end of G and held on bus_cmd / bus_addr / bus_put_kind until bus_done, so the cache is free
//     to change its own outputs once its request is ordered. bus_cmd is CMD_NONE when idle.
//   - Data source, chosen in DATA (spec 6.4):
//       PutM + DATA          -> the requester's line, when it raises cache_dval
//       PutM + NoData(-E)    -> no data; done in the first DATA cycle (G+4)
//       GetS/GetM, mem_owned -> the owner cache's line (whichever cache_dval is high)
//       GetS/GetM, otherwise -> memory's line when mem_dval; bus_data_excl = mem_excl
//     bus_done is raised in the same cycle the data (or the NoData PutM) completes.
//   - Memory's transient states (I^D / S^D / EorM^D) are held in mem_ctrl.sv, not here.

module bus
  import mesi_pkg::*;
(
  input  logic               clk,
  input  logic               rst_n,

  // From the arbiter
  input  logic [N_CORES-1:0] bus_gnt,

  // From each cache (only the granted cache's request is used)
  input  bus_cmd_t           cache_cmd      [N_CORES],
  input  addr_t              cache_addr     [N_CORES],
  input  put_t               cache_put_kind [N_CORES],
  input  logic [N_CORES-1:0] cache_dval,              // cache i is driving cache_data[i]
  input  line_t              cache_data     [N_CORES],

  // From the memory controller
  input  logic               mem_dval,                // memory is driving mem_data
  input  line_t              mem_data,
  input  logic               mem_excl,                // memory's response is exclusive
  input  logic               mem_owned,               // block is EorM: a cache will respond

  // Broadcast to every cache and to memory
  output bus_cmd_t           bus_cmd,
  output addr_t              bus_addr,
  output put_t               bus_put_kind,
  output logic               bus_addr_valid,          // 1-cycle pulse: address phase (the Own-/Other- event)
  output logic               bus_snoop_end,           // 1-cycle pulse: last cycle of the snoop window
  output line_t              bus_data,
  output logic               bus_data_valid,
  output logic               bus_data_excl,
  output logic               bus_done
);

  typedef enum logic [1:0] {
    B_IDLE,    // waiting for a grant
    B_ADDR,    // G+1: address phase
    B_SNOOP,   // snoop window, SNOOP_LAT cycles
    B_DATA     // waiting for the data source, then bus_done
  } bstate_t;

  localparam int SCNT_W = (SNOOP_LAT > 1) ? $clog2(SNOOP_LAT) : 1;

  bstate_t              state_q;
  logic [SCNT_W-1:0]    scnt_q;    // snoop cycles left (0 = last one)
  logic [CORE_ID_W-1:0] gidx;      // index of the granted cache (from the live grant)
  logic [CORE_ID_W-1:0] gidx_q;    // ... latched for this transaction
  bus_cmd_t             cmd_q;
  addr_t                addr_q;
  put_t                 kind_q;

  // One-hot grant -> index
  always_comb begin
    gidx = '0;
    for (int i = 0; i < N_CORES; i++)
      if (bus_gnt[i]) gidx = CORE_ID_W'(i);
  end

  // ------------------------------------------------------------------
  // Sequencer
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= B_IDLE;
      scnt_q  <= '0;
      gidx_q  <= '0;
      cmd_q   <= CMD_NONE;
      addr_q  <= '0;
      kind_q  <= PUT_DATA;
    end else begin
      case (state_q)
        B_IDLE: if (|bus_gnt) begin           // cycle G: latch the granted cache's request
          state_q <= B_ADDR;
          gidx_q  <= gidx;
          cmd_q   <= cache_cmd[gidx];
          addr_q  <= cache_addr[gidx];
          kind_q  <= cache_put_kind[gidx];
        end
        B_ADDR: begin
          state_q <= B_SNOOP;
          scnt_q  <= SCNT_W'(SNOOP_LAT - 1);
        end
        B_SNOOP: begin
          if (scnt_q == '0) state_q <= B_DATA;
          else              scnt_q  <= scnt_q - 1'b1;
        end
        B_DATA: if (bus_done) state_q <= B_IDLE;
        default: state_q <= B_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // Request broadcast
  // ------------------------------------------------------------------
  always_comb begin
    if (state_q == B_IDLE) bus_cmd = CMD_NONE;
    else                   bus_cmd = cmd_q;
  end
  assign bus_addr       = addr_q;
  assign bus_put_kind   = kind_q;
  assign bus_addr_valid = (state_q == B_ADDR);
  assign bus_snoop_end  = (state_q == B_SNOOP) && (scnt_q == '0);

  // ------------------------------------------------------------------
  // Data mux and completion
  // ------------------------------------------------------------------
  line_t owner_data;   // OR of every driving cache's line (cache_dval is one-hot)
  always_comb begin
    owner_data = '0;
    for (int i = 0; i < N_CORES; i++)
      if (cache_dval[i]) owner_data = owner_data | cache_data[i];
  end

  always_comb begin
    bus_data       = mem_data;
    bus_data_valid = 1'b0;
    bus_data_excl  = 1'b0;
    bus_done       = 1'b0;
    if (state_q == B_DATA) begin
      if (cmd_q == CMD_PUTM) begin
        bus_data = cache_data[gidx_q];
        if (kind_q == PUT_DATA) begin                // requester sends its dirty line
          bus_data_valid = cache_dval[gidx_q];
          bus_done       = cache_dval[gidx_q];
        end else begin                               // NoData / NoData-E: nothing to send
          bus_done       = 1'b1;
        end
      end else if (mem_owned) begin                  // owner cache supplies the line
        bus_data       = owner_data;
        bus_data_valid = |cache_dval;
        bus_done       = |cache_dval;
      end else begin                                 // memory supplies the line
        bus_data       = mem_data;
        bus_data_valid = mem_dval;
        bus_data_excl  = mem_excl;
        bus_done       = mem_dval;
      end
    end
  end

  // ------------------------------------------------------------------
  // Sanity checks (spec 6, protocol.md 7)
  // ------------------------------------------------------------------
`ifndef SYNTHESIS
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // no checks in reset
    end else begin
      assert ((bus_gnt & (bus_gnt - 1'b1)) == '0)
        else $error("bus: bus_gnt %b is not one-hot", bus_gnt);
      assert ((cache_dval & (cache_dval - 1'b1)) == '0)
        else $error("bus: more than one cache_dval high: %b", cache_dval);
      if (state_q == B_IDLE && |bus_gnt) begin
        assert (cache_cmd[gidx] != CMD_NONE)
          else $error("bus: cache %0d granted with CMD_NONE", gidx);
      end
      if (state_q != B_IDLE) begin
        assert (bus_gnt == (N_CORES'(1) << gidx_q))
          else $error("bus: grant changed mid-transaction (%b)", bus_gnt);
      end
      if (state_q != B_DATA) begin
        assert (cache_dval == '0) else $error("bus: cache_dval outside the data phase");
        assert (!mem_dval)        else $error("bus: mem_dval outside the data phase");
      end
      if (state_q == B_DATA && cmd_q != CMD_PUTM && mem_owned) begin
        assert (!mem_dval)
          else $error("bus: memory responded to a block a cache owns");
        assert (!cache_dval[gidx_q])
          else $error("bus: requester %0d drove data for its own GetS/GetM", gidx_q);
      end
    end
  end
`endif

endmodule
