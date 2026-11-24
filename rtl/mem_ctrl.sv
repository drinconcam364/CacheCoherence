// mem_ctrl.sv  (owner: Person B)
// Memory controller: data array + per-block state (I / S / EorM), Sorin Table 7.12.
// Responds to GetS/GetM MEM_LAT cycles after the address phase unless the block is EorM.
// Writes data on PutM+DATA and on an owner's response to a GetS.
// SHELL: ports are final, logic still to be written.

/* verilator lint_off UNUSEDSIGNAL */  // remove once implemented
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

  // TODO (Phase 1): data array, latency counter, PutM write
  // TODO (Phase 2/3): per-block mem_state_t array
  assign mem_dval  = 1'b0;
  assign mem_data  = '0;
  assign mem_excl  = 1'b0;
  assign mem_owned = 1'b0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
