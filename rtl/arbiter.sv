// arbiter.sv  (owner: Person B)
// Round-robin bus arbiter. One-hot grant, registered, held until bus_done.
// SHELL: ports are final, logic still to be written.

/* verilator lint_off UNUSEDSIGNAL */  // remove once implemented
module arbiter
  import mesi_pkg::*;
(
  input  logic               clk,
  input  logic               rst_n,
  input  logic [N_CORES-1:0] bus_req,   // cache i wants the bus
  input  logic               bus_done,  // current transaction finished
  output logic [N_CORES-1:0] bus_gnt    // one-hot grant
);

  // TODO (Phase 1): round-robin pointer, advance only on a grant
  assign bus_gnt = '0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
