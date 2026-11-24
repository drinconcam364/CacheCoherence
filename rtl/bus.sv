// bus.sv  (owner: Person B)
// Bus sequencer and muxes. Follows the spec Section 7 timeline:
//   G grant -> G+1 address (bus_addr_valid) -> snoop window (bus_snoop_end on its
//   last cycle) -> data -> bus_done.
// No tri-states: the granted cache's request and the data source are muxed here.
// SHELL: ports are final, logic still to be written.

/* verilator lint_off UNUSEDSIGNAL */  // remove once implemented
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

  // TODO (Phase 1): phase FSM, request mux, data mux
  assign bus_cmd        = CMD_NONE;
  assign bus_addr       = '0;
  assign bus_put_kind   = PUT_DATA;
  assign bus_addr_valid = 1'b0;
  assign bus_snoop_end  = 1'b0;
  assign bus_data       = '0;
  assign bus_data_valid = 1'b0;
  assign bus_data_excl  = 1'b0;
  assign bus_done       = 1'b0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
