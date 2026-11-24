// mem_ctrl.sv  (owner: Person B)
// Memory controller: data array + per-block state (I / S / EorM), Sorin Table 7.12.
// Responds to GetS/GetM MEM_LAT cycles after the address phase unless the block is EorM.
// Writes data on PutM+DATA and on an owner's response to a GetS.
//
// How it works:
//   - Address phase (bus_addr_valid, G+1): latch the command, block index, put kind and the
//     block's current state into a transaction register. That register is held until bus_done.
//     Because the bus is atomic, there is only ever one transaction, so this one register also
//     plays the role of Sorin's transient states (I^D / S^D / EorM^D = "PutM or owner GetS,
//     waiting for data").
//   - Memory responds (GetS/GetM to a block in I or S): count MEM_LAT cycles from the address
//     phase, then pulse mem_dval with the line at G+1+MEM_LAT. mem_excl = GetS to a block in I.
//   - Block is EorM on GetS/GetM: stay silent, assert mem_owned so bus.sv takes the owner's data.
//   - Data writes: PutM + DATA, and the owner's data on a GetS (not on a GetM: memory stays stale).
//   - Block state update: applied once, at bus_done, from Table 7.12 (see next_state below).
//     Memory and the caches change state on the same edge, so the checkers never see a mismatch.

module mem_ctrl
  import mesi_pkg::*;
(
  input  logic     clk,
  input  logic     rst_n,

  // Bus (broadcast from bus.sv)
  input  bus_cmd_t bus_cmd,
  input  addr_t    bus_addr,
  input  put_t     bus_put_kind,
  input  logic     bus_addr_valid,
  input  line_t    bus_data,
  input  logic     bus_data_valid,
  input  logic     bus_done,

  // Response to bus.sv
  output logic     mem_dval,
  output line_t    mem_data,
  output logic     mem_excl,
  output logic     mem_owned
);

  localparam int CNT_W = $clog2(MEM_LAT + 1);
  typedef logic [MEM_IDX_W-1:0] midx_t;

  // ------------------------------------------------------------------
  // Storage
  // ------------------------------------------------------------------
  line_t      mem_arr [MEM_LINES];   // data, no reset (initialized below)
  mem_state_t st_arr  [MEM_LINES];   // per-block state, reset to MEM_I

  // Initial contents (spec 8): every word holds its own byte address.
  // Word w of a line lives in bits [w*WORD_W +: WORD_W].
  initial begin
    for (int l = 0; l < MEM_LINES; l++)
      for (int w = 0; w < WORDS_PER_LINE; w++)
        mem_arr[l][w*WORD_W +: WORD_W] = word_t'(l*LINE_BYTES + w*WORD_BYTES);
  end

  // ------------------------------------------------------------------
  // Address-phase lookup (combinational, from the live bus)
  // ------------------------------------------------------------------
  midx_t      a_idx;   // block index of the address on the bus
  mem_state_t a_st;    // that block's current state
  logic       a_get;   // command is GetS or GetM

  assign a_idx = bus_addr[OFFSET_W +: MEM_IDX_W];
  assign a_st  = st_arr[a_idx];
  assign a_get = (bus_cmd == CMD_GETS) || (bus_cmd == CMD_GETM);

  // ------------------------------------------------------------------
  // Transaction register: latched at the address phase, held until bus_done
  // ------------------------------------------------------------------
  logic             act_q;    // a transaction is in progress
  bus_cmd_t         cmd_q;
  put_t             kind_q;
  midx_t            idx_q;
  mem_state_t       st_q;     // block state seen at the address phase
  logic             resp_q;   // memory still owes a data response
  logic [CNT_W-1:0] cnt_q;    // cycles left until the response

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      act_q  <= 1'b0;
      cmd_q  <= CMD_NONE;
      kind_q <= PUT_DATA;
      idx_q  <= '0;
      st_q   <= MEM_I;
      resp_q <= 1'b0;
      cnt_q  <= '0;
    end else if (bus_addr_valid) begin
      act_q  <= 1'b1;
      cmd_q  <= bus_cmd;
      kind_q <= bus_put_kind;
      idx_q  <= a_idx;
      st_q   <= a_st;
      resp_q <= a_get && (a_st != MEM_EORM);
      cnt_q  <= CNT_W'(MEM_LAT - 1);       // reaches 0 in cycle G+1+MEM_LAT
    end else begin
      if (mem_dval)    resp_q <= 1'b0;     // one-cycle pulse
      else if (resp_q) cnt_q  <= cnt_q - 1'b1;
      if (bus_done)    act_q  <= 1'b0;
    end
  end

  // ------------------------------------------------------------------
  // Table 7.12: block state after the transaction
  // ------------------------------------------------------------------
  function automatic mem_state_t next_state(bus_cmd_t c, put_t k, mem_state_t s);
    case (c)
      CMD_GETS: begin                                     // I -> EorM, S -> S, EorM -> S^D -> S
        if (s == MEM_I) return MEM_EORM;
        return MEM_S;
      end
      CMD_GETM: return MEM_EORM;                          // I/S -> EorM, EorM stays
      CMD_PUTM: begin
        if (s == MEM_S)                        return MEM_S;     // S^D: any message -> S
        if (s == MEM_EORM && k == PUT_NODATA)  return MEM_EORM;  // EorM^D + NoData (from II^A)
        return MEM_I;                          // EorM^D + Data / NoData-E, or I^D (impossible)
      end
      default:  return s;
    endcase
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < MEM_LINES; i++) st_arr[i] <= MEM_I;
    end else if (act_q && bus_done) begin
      st_arr[idx_q] <= next_state(cmd_q, kind_q, st_q);
    end
  end

  // ------------------------------------------------------------------
  // Data writes: PutM + Data, or the owner's data on a GetS
  // ------------------------------------------------------------------
  logic wr_en;
  assign wr_en = act_q && bus_data_valid &&
                 (((cmd_q == CMD_PUTM) && (kind_q == PUT_DATA)) ||
                  ((cmd_q == CMD_GETS) && (st_q == MEM_EORM)));

  always_ff @(posedge clk) begin
    if (wr_en) mem_arr[idx_q] <= bus_data;
  end

  // ------------------------------------------------------------------
  // Outputs
  // ------------------------------------------------------------------
  assign mem_dval = resp_q && (cnt_q == '0);
  assign mem_data = mem_arr[idx_q];
  assign mem_excl = mem_dval && (cmd_q == CMD_GETS) && (st_q == MEM_I);

  // Valid from the address phase (combinational in G+1) until bus_done
  assign mem_owned = bus_addr_valid ? (a_get && (a_st == MEM_EORM))
                                    : (act_q && (cmd_q != CMD_PUTM) && (st_q == MEM_EORM));

  // ------------------------------------------------------------------
  // Sanity checks (protocol.md 3.1, spec 8)
  // ------------------------------------------------------------------
`ifndef SYNTHESIS
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // no checks in reset
    end else begin
      if (bus_data_valid) begin
        assert (act_q) else $error("mem_ctrl: bus_data_valid with no transaction");
      end
      if (bus_addr_valid) begin
        assert (!act_q)
          else $error("mem_ctrl: address phase while a transaction is still active");
        assert (bus_cmd != CMD_NONE)
          else $error("mem_ctrl: address phase with CMD_NONE");
        assert (bus_addr[OFFSET_W-1:0] == '0)
          else $error("mem_ctrl: bus_addr %h is not line-aligned", bus_addr);
        assert (bus_addr[ADDR_W-1:OFFSET_W+MEM_IDX_W] == '0)
          else $error("mem_ctrl: bus_addr %h is beyond MEM_BYTES", bus_addr);
        assert (!(bus_cmd == CMD_PUTM && a_st == MEM_I))
          else $error("mem_ctrl: PutM to block %0d in MEM_I", a_idx);
      end
    end
  end
`endif

endmodule
