// mesi_pkg.sv
// Shared parameters, types and helper functions for the 4-core MESI system.
// Every RTL and testbench file imports this:   import mesi_pkg::*;
// Changing anything here changes the contract between Person A and Person B,
// so agree on it together and update docs/spec.md.

// A package declares things other files may or may not use yet, and the helper
// functions deliberately look at only part of the address. Silence those two
// lint warnings here only; they stay on for every other file.
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */

package mesi_pkg;

  // ------------------------------------------------------------------
  // 1. Parameters (spec Section 2)
  // ------------------------------------------------------------------
  localparam int N_CORES     = 4;      // debug with 2
  localparam int ADDR_W      = 32;     // byte address
  localparam int WORD_W      = 32;     // load/store width
  localparam int LINE_BYTES  = 32;     // 8 words per line
  localparam int CACHE_BYTES = 2048;   // per core
  localparam int WAYS        = 1;      // 1 now, 2 in Phase 4
  localparam int MEM_LAT     = 20;     // memory response latency (cycles), must be >= 3
  localparam int SNOOP_LAT   = 2;      // snoop window length (cycles)
  localparam int MEM_BYTES   = 65536;  // size of the memory model

  // ------------------------------------------------------------------
  // 2. Derived widths (computed, never hard-coded)
  // ------------------------------------------------------------------
  localparam int WORD_BYTES     = WORD_W / 8;                       // 4
  localparam int WORDS_PER_LINE = LINE_BYTES / WORD_BYTES;          // 8
  localparam int BYTE_OFF_W     = $clog2(WORD_BYTES);               // 2
  localparam int WORD_OFF_W     = $clog2(WORDS_PER_LINE);           // 3
  localparam int OFFSET_W       = $clog2(LINE_BYTES);               // 5
  localparam int LINE_W         = LINE_BYTES * 8;                   // 256
  localparam int N_SETS         = CACHE_BYTES / (LINE_BYTES * WAYS); // 64 (1-way), 32 (2-way)
  localparam int INDEX_W        = $clog2(N_SETS);                   // 6 (1-way), 5 (2-way)
  localparam int TAG_W          = ADDR_W - INDEX_W - OFFSET_W;      // 21 (1-way), 22 (2-way)
  localparam int MEM_LINES      = MEM_BYTES / LINE_BYTES;           // 2048
  localparam int MEM_IDX_W      = $clog2(MEM_LINES);                // 11
  localparam int CORE_ID_W      = (N_CORES > 1) ? $clog2(N_CORES) : 1;

  // ------------------------------------------------------------------
  // 3. Basic data types
  // ------------------------------------------------------------------
  typedef logic [ADDR_W-1:0]  addr_t;
  typedef logic [WORD_W-1:0]  word_t;
  typedef logic [LINE_W-1:0]  line_t;
  typedef logic [TAG_W-1:0]   tag_t;
  typedef logic [INDEX_W-1:0] index_t;
  typedef logic [WORD_OFF_W-1:0] word_off_t;

  // ------------------------------------------------------------------
  // 4. Cache stable states (stored per line in the array)
  //    ST_I must be 0 so that clearing the array at reset = all invalid.
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    ST_I = 2'b00,
    ST_S = 2'b01,
    ST_E = 2'b10,
    ST_M = 2'b11
  } mesi_t;

  // ------------------------------------------------------------------
  // 5. Cache transient states (held in the pending-transaction register)
  //    Names follow Sorin Table 7.11. TR_NONE = no transaction in flight.
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    TR_NONE = 4'd0,
    TR_IS_AD,   // I -> S/E, waiting for own GetS on bus, then data
    TR_IS_D,    // own GetS ordered, waiting for data
    TR_IM_AD,   // I -> M, waiting for own GetM on bus, then data
    TR_IM_D,    // own GetM ordered, waiting for data
    TR_SM_AD,   // S -> M, waiting for own GetM on bus, then data
    TR_SM_D,    // own GetM ordered, waiting for data
    TR_MI_A,    // M -> I, waiting for own PutM on bus
    TR_EI_A,    // E -> I, waiting for own PutM on bus
    TR_II_A     // lost the line to another core, still owes a PutM (NoData)
  } trans_t;

  // ------------------------------------------------------------------
  // 6. Memory per-block states (Sorin Table 7.12)
  //    The D-suffixed transients (I^D, S^D, EorM^D) live in bus.sv's FSM.
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    MEM_I    = 2'b00,
    MEM_S    = 2'b01,
    MEM_EORM = 2'b10
  } mem_state_t;

  // ------------------------------------------------------------------
  // 7. Bus request and PutM data kind
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    CMD_NONE = 2'b00,
    CMD_GETS = 2'b01,
    CMD_GETM = 2'b10,
    CMD_PUTM = 2'b11
  } bus_cmd_t;

  typedef enum logic [1:0] {
    PUT_DATA     = 2'b00,  // M eviction: line goes to memory
    PUT_NODATA   = 2'b01,  // II^A: lost ownership, nothing to write
    PUT_NODATA_E = 2'b10   // E eviction: clean, memory just goes to I
  } put_t;

  // ------------------------------------------------------------------
  // 8. Core request op (traffic generator -> cache)
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    OP_LD  = 2'b00,
    OP_ST  = 2'b01,
    OP_TAS = 2'b10   // reserved for stretch goal S2
  } op_t;

  // ------------------------------------------------------------------
  // 9. Address helper functions
  //    Use these everywhere so the bit slicing lives in one place.
  // ------------------------------------------------------------------
  function automatic tag_t get_tag(addr_t a);
    return a[ADDR_W-1 -: TAG_W];
  endfunction

  function automatic index_t get_index(addr_t a);
    return a[OFFSET_W +: INDEX_W];
  endfunction

  function automatic word_off_t get_word(addr_t a);
    return a[BYTE_OFF_W +: WORD_OFF_W];
  endfunction

  // Clear the offset bits: the address the bus carries
  function automatic addr_t line_addr(addr_t a);
    return {a[ADDR_W-1:OFFSET_W], {OFFSET_W{1'b0}}};
  endfunction

  // Rebuild a line address from a stored tag and its set index (for evictions)
  function automatic addr_t make_line_addr(tag_t t, index_t i);
    return {t, i, {OFFSET_W{1'b0}}};
  endfunction

endpackage

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
