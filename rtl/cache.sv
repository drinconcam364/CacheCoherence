// cache.sv  (owner: Person A)
// One private L1 cache: arrays, hit path, cache controller (Sorin Table 7.11),
// snoop logic and the pending-transaction register.
// Person A may split the controller into cache_ctrl.sv later; these ports stay the same.
// SHELL: ports are final, logic still to be written.

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

  // TODO (Phase 1): arrays, hit path, miss handling, PutM eviction
  assign req_ready      = 1'b0;
  assign resp_valid     = 1'b0;
  assign resp_rdata     = '0;
  assign bus_req        = 1'b0;
  assign cache_cmd      = CMD_NONE;
  assign cache_addr     = '0;
  assign cache_put_kind = PUT_DATA;
  assign cache_dval     = 1'b0;
  assign cache_data     = '0;

endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
