// top.sv  (owners: both)
// Wires N_CORES caches, the arbiter, the bus and the memory controller together.
// The traffic generators live in tb/ and connect to the core-side ports below.

module top
  import mesi_pkg::*;
(
  input  logic  clk,
  input  logic  rst_n,

  // One core-side interface per cache
  input  logic  req_valid  [N_CORES],
  output logic  req_ready  [N_CORES],
  input  op_t   req_op     [N_CORES],
  input  addr_t req_addr   [N_CORES],
  input  word_t req_wdata  [N_CORES],
  output logic  resp_valid [N_CORES],
  output word_t resp_rdata [N_CORES]
);

  // Arbitration
  logic [N_CORES-1:0] bus_req;
  logic [N_CORES-1:0] bus_gnt;

  // Per-cache outputs to the bus
  bus_cmd_t           cache_cmd      [N_CORES];
  addr_t              cache_addr     [N_CORES];
  put_t               cache_put_kind [N_CORES];
  logic [N_CORES-1:0] cache_dval;
  line_t              cache_data     [N_CORES];

  // Memory controller outputs
  logic  mem_dval, mem_excl, mem_owned;
  line_t mem_data;

  // Bus broadcast
  bus_cmd_t bus_cmd;
  addr_t    bus_addr;
  put_t     bus_put_kind;
  logic     bus_addr_valid, bus_snoop_end;
  line_t    bus_data;
  logic     bus_data_valid, bus_data_excl, bus_done;

  // ---------------------------------------------------------------
  // Caches
  // ---------------------------------------------------------------
  for (genvar i = 0; i < N_CORES; i++) begin : g_cache
    cache #(.CORE_ID(i)) u_cache (
      .clk, .rst_n,
      .req_valid      (req_valid[i]),
      .req_ready      (req_ready[i]),
      .req_op         (req_op[i]),
      .req_addr       (req_addr[i]),
      .req_wdata      (req_wdata[i]),
      .resp_valid     (resp_valid[i]),
      .resp_rdata     (resp_rdata[i]),
      .bus_req        (bus_req[i]),
      .bus_gnt        (bus_gnt[i]),
      .cache_cmd      (cache_cmd[i]),
      .cache_addr     (cache_addr[i]),
      .cache_put_kind (cache_put_kind[i]),
      .cache_dval     (cache_dval[i]),
      .cache_data     (cache_data[i]),
      .bus_cmd, .bus_addr, .bus_put_kind, .bus_addr_valid, .bus_snoop_end,
      .bus_data, .bus_data_valid, .bus_data_excl, .bus_done
    );
  end

  // ---------------------------------------------------------------
  // Arbiter, bus, memory
  // ---------------------------------------------------------------
  arbiter u_arbiter (
    .clk, .rst_n, .bus_req, .bus_done, .bus_gnt
  );

  bus u_bus (
    .clk, .rst_n, .bus_gnt,
    .cache_cmd, .cache_addr, .cache_put_kind, .cache_dval, .cache_data,
    .mem_dval, .mem_data, .mem_excl, .mem_owned,
    .bus_cmd, .bus_addr, .bus_put_kind, .bus_addr_valid, .bus_snoop_end,
    .bus_data, .bus_data_valid, .bus_data_excl, .bus_done
  );

  mem_ctrl u_mem (
    .clk, .rst_n,
    .bus_cmd, .bus_addr, .bus_put_kind, .bus_addr_valid,
    .bus_data, .bus_data_valid, .bus_done,
    .mem_dval, .mem_data, .mem_excl, .mem_owned
  );

endmodule
