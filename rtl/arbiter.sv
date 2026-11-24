// arbiter.sv  (owner: Person B)
// Round-robin bus arbiter. One-hot grant, registered, held until bus_done.
//
// Behaviour (spec 6.1 and 7):
//   - Idle (no grant): if any bus_req is high, grant one requester next cycle.
//   - Busy: hold bus_gnt unchanged until bus_done.
//   - bus_done cycle: pick the next requester so the new grant appears in
//     done+1 (the earliest next grant). The cache that just finished is masked
//     out, because its bus_req may still be high in the done cycle. If nobody
//     else is waiting, the bus goes idle for a cycle.
//   - Priority starts at the core after the last one granted, so every waiting
//     requester is served within N_CORES transactions. The pointer only moves
//     when a grant is actually given.

module arbiter
  import mesi_pkg::*;
(
  input  logic               clk,
  input  logic               rst_n,
  input  logic [N_CORES-1:0] bus_req,   // cache i wants the bus
  input  logic               bus_done,  // current transaction finished
  output logic [N_CORES-1:0] bus_gnt    // one-hot grant
);

  logic [N_CORES-1:0]   gnt_q;      // registered grant (drives bus_gnt)
  logic [CORE_ID_W-1:0] last_q;     // index of the last core granted
  logic [N_CORES-1:0]   cand;       // requesters eligible this cycle
  logic [N_CORES-1:0]   pick;       // one-hot winner among cand
  logic [CORE_ID_W-1:0] pick_idx;   // index of the winner
  logic                 busy;

  assign busy = |gnt_q;

  // Who may be granted this cycle
  always_comb begin
    if (!busy)         cand = bus_req;            // idle: anyone
    else if (bus_done) cand = bus_req & ~gnt_q;   // finishing: anyone but the current owner
    else               cand = '0;                 // mid-transaction: hold
  end

  // Round-robin search: start at last_q + 1 and wrap around
  always_comb begin
    logic [CORE_ID_W-1:0] idx;
    pick     = '0;
    pick_idx = last_q;
    for (int off = 1; off <= N_CORES; off++) begin
      idx = CORE_ID_W'((int'(last_q) + off) % N_CORES);  // % keeps it correct for non-power-of-2 N_CORES
      if (pick == '0 && cand[idx]) begin
        pick[idx] = 1'b1;
        pick_idx  = idx;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      gnt_q  <= '0;
      last_q <= CORE_ID_W'(N_CORES - 1);   // core 0 has priority after reset
    end else if (!busy || bus_done) begin
      gnt_q <= pick;                       // new grant, or '0 to go idle
      if (pick != '0) last_q <= pick_idx;  // advance only on a grant
    end
  end

  assign bus_gnt = gnt_q;

endmodule
