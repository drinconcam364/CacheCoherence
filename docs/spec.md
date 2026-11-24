# MESI Coherence System: Specification

**Status:** DRAFT (change to FROZEN when both of you sign off)
**Signed off:** ☐ Person A (____, date ____)  ☐ Person B (____, date ____)

> Rule: any change to a port, the bus timing, or a parameter after the freeze needs both
> of you to agree, and an entry in the Change Log at the bottom.
>
> **Protocol source of truth:** Sorin, Hill & Wood, *A Primer on Memory Consistency and Cache
> Coherence*, Section 7.3 (MESI snooping): Figure 7.4, Figure 7.5, Table 7.11, Table 7.12.
> `docs/protocol.md` transcribes those tables. If anything here disagrees with them, the tables win.
>
> Items marked **(proposed)** are implementation choices to discuss before signing off.

---

## 1. Design decisions

The project guide's Section 1 decisions, updated to follow Sorin's MESI protocol.
Rows marked **CHANGED** differ from the guide.

| Decision | Choice | Changed? Why |
|---|---|---|
| Protocol | MESI per Sorin Tables 7.11 / 7.12 (MSI first) | No |
| Mechanism | Snooping, atomic bus | No |
| Invalidate vs. update | Write-invalidate | No |
| Arbitration | Round-robin | No |
| Bus requests | **GetS, GetM, PutM** | **CHANGED.** Sorin's names. GetS = guide's BusRd, GetM = BusRdX, PutM = BusWB |
| S → M upgrade | **Issue GetM (S → SM^AD → SM^D → M)**, data response comes back | **CHANGED.** No BusUpgr. Costs one extra line transfer, but the upgrade race needs no command conversion: if the line is invalidated while waiting, the same GetM is still correct (SM^AD → IM^AD) |
| How a reader picks E or S | **Memory tracks a per-block state (I, S, EorM).** A GetS to a block memory has in I gets an **exclusive** data response → E. Otherwise → S | **CHANGED.** No wired-OR shared line. Memory already knows if anyone could hold the block |
| Who supplies data | **Owner = the cache in E or M.** If memory's state is EorM, the owner cache responds. If it's I or S, memory responds | **CHANGED.** E is an owner (guide had memory supply for E). No memory-inhibit (owner) wire needed, since memory knows from its own state whether to respond |
| Owner data on Other-GetS | Send to requester **and** memory; owner → S, memory → S | No (same as guide's Flush) |
| Owner data on Other-GetM | Send to requester **only**; owner → I, memory stays EorM | **CHANGED.** Memory isn't updated; ownership simply moves to the new M cache |
| Evictions | **M → PutM + Data. E → PutM + NoData-E. S → silent** | **CHANGED.** E can't drop silently: memory must hear about it to leave EorM |
| Write policy | Write-back, write-allocate | No |
| Snoop vs. core tag port | Single port, snoop wins, core stalls | No |

## 2. Parameters

| Parameter | Default | Notes |
|---|---|---|
| N_CORES | 4 | Debug with 2 |
| ADDR_W | 32 | Byte address |
| WORD_W | 32 | 4 bytes |
| LINE_BYTES | 32 | 8 words/line, 256 bits |
| CACHE_BYTES | 2048 | 64 lines |
| WAYS | 1, then 2 | |
| MEM_LAT | 20 | Configurable. Must be ≥ 3 (see Section 7) |
| SNOOP_LAT | 2 | |
| MEM_BYTES | 65536 | **(proposed)** Size of the memory model (see Section 8) |

### Derived address fields

Working:
- Bytes per word = 4, so byte-in-word = log2(4) = **2 bits**
- Words per line = 32 / 4 = 8, so word offset = log2(8) = **3 bits**
- Line offset total = log2(32) = **5 bits**
- 1-way: sets = 2048 / (32 × 1) = **64**, so index = **6 bits**
- 2-way: sets = 2048 / (32 × 2) = **32**, so index = **5 bits**
- Tag = 32 − index − 5

| Field | 1-way width | 1-way bits | 2-way width | 2-way bits |
|---|---|---|---|---|
| Byte-in-word | 2 | [1:0] | 2 | [1:0] |
| Word offset | 3 | [4:2] | 3 | [4:2] |
| Index (set) | 6 | [10:5] | 5 | [9:5] |
| Tag | 21 | [31:11] | 22 | [31:10] |
| Number of sets | 64 | — | 32 | — |

```systemverilog
localparam int BYTE_OFF_W = $clog2(WORD_W/8);                 // 2
localparam int WORD_OFF_W = $clog2(LINE_BYTES/(WORD_W/8));    // 3
localparam int OFFSET_W   = $clog2(LINE_BYTES);               // 5
localparam int N_SETS     = CACHE_BYTES / (LINE_BYTES*WAYS);  // 64 or 32
localparam int INDEX_W    = $clog2(N_SETS);                   // 6 or 5
localparam int TAG_W      = ADDR_W - INDEX_W - OFFSET_W;      // 21 or 22
localparam int LINE_W     = LINE_BYTES*8;                     // 256
```

## 3. State storage

### 3.1 Cache: stable states live in the array

- **Fields stored per line:** tag (TAG_W bits), stable MESI state (2 bits), data (256 bits).
  For 2-way, add 1 LRU bit per set.
- **Stable state encoding** (`mesi_t` in `mesi_pkg.sv`): ST_I = `2'b00`, ST_S = `2'b01`, ST_E = `2'b10`, ST_M = `2'b11`.
  I must be `00` so reset leaves every line invalid.
- **Why no separate valid/dirty bits:** valid ⇔ state ≠ I, and dirty ⇔ state = M.
- **Reset:** every line in every cache is I.

### 3.2 Cache: transient states live in the controller (proposed)

Sorin's table has 9 transient states: IS^AD, IS^D, IM^AD, IM^D, SM^AD, SM^D, MI^A, EI^A, II^A.
Because each core is blocking, a cache has **at most one transaction in flight at a time**.
So transient states are **not** stored per line. Instead, the controller keeps one
**pending-transaction register**:

| Field | Meaning |
|---|---|
| `pend_valid` | A transaction is in progress |
| `pend_addr` | Its line address |
| `pend_way` | Which way it will install into / evict from (2-way only) |
| `pend_state` | The transient state (`trans_t` in `mesi_pkg.sv`: TR_NONE, TR_IS_AD, TR_IS_D, TR_IM_AD, TR_IM_D, TR_SM_AD, TR_SM_D, TR_MI_A, TR_EI_A, TR_II_A) |

- While `pend_valid`, the array line can still hold its old stable state (S during SM^AD,
  M during MI^A, E during EI^A). It gets the new stable state when the transaction completes.
- **Snoop logic must check both** the tag array **and** `pend_addr`. A snoop that matches
  `pend_addr` uses the transient-state row of Table 7.11 (this is how the races in guide Phase 5 are handled).
- A dirty-line miss is two transactions back to back: first PutM (MI^A / EI^A → I), then the
  GetS or GetM for the new line.

### 3.3 Memory: per-block directory-like state

Memory keeps **2 bits per block** (Figure 7.5 / Table 7.12):

| State | Meaning |
|---|---|
| I | No cache holds the block. Memory is the owner |
| S | Zero or more caches may hold it in S. Memory is the owner and up to date |
| EorM | Exactly one cache holds it in E or M and is the owner. Memory may be stale |

- **Encoding** (`mem_state_t` in `mesi_pkg.sv`): MEM_I = `2'b00`, MEM_S = `2'b01`, MEM_EORM = `2'b10`. **Reset:** every block MEM_I.
- Memory can't tell E from M. That's why E evictions send **NoData-E** (memory → I) and M
  evictions send **Data** (memory writes, → I).
- Silent S evictions mean memory may say S when no cache actually holds the block. That's safe:
  a later GetS just gets S instead of E.
- **Transient memory states** (I^D, S^D, EorM^D: "waiting for data after a PutM or owner GetS")
  are held in `mem_ctrl.sv`'s transaction register, not per block, because the atomic bus allows
  only one at a time. The register latches the command, put kind, block index and the block's state
  at the address phase; e.g. `cmd_q` = PutM with `st_q` = EorM is EorM^D. The per-block state is
  updated once, at `bus_done`.

## 4. Protocol

The full protocol (Sorin Tables 7.11 / 7.12, the MSI subset for Phase 2, the stable-state FSMs,
the example execution and the invariants) lives in **`docs/protocol.md`**. It is part of this spec:
signing off this file signs off that one too.

## 5. Core-side interface (traffic generator ↔ cache)

| Signal | Dir (from cache's view) | Width | Meaning |
|---|---|---|---|
| req_valid | in | 1 | Traffic generator has a request |
| req_ready | out | 1 | Cache can accept a request this cycle |
| req_op | in | 2 | `op_t` in `mesi_pkg.sv`: OP_LD, OP_ST (OP_TAS reserved for stretch S2) |
| req_addr | in | ADDR_W | Byte address, word-aligned |
| req_wdata | in | WORD_W | Store data |
| resp_valid | out | 1 | One-cycle pulse: request finished |
| resp_rdata | out | WORD_W | Load data (valid when resp_valid and op was LD) |

- **Handshake (proposed):** a request is accepted on a clock edge where `req_valid && req_ready`.
  The cache latches it into its request register at that edge.
- **Blocking:** one outstanding request; `req_ready` stays low from acceptance until `resp_valid`.
  Stores also get a `resp_valid`. "Stall" in Table 7.11 means `req_ready` stays low.
- **Hit latency (proposed): 2 cycles from acceptance to `resp_valid`.**
  - Cycle T: request accepted, index sent to the tag/data arrays.
  - Cycle T+1: array outputs appear (synchronous read), tag compare, hit check, result registered.
  - Cycle T+2: `resp_valid`. A store writes the data array at the end of T+1.
  - (Alternative: 1 cycle, driving `resp_valid` straight from the compare in T+1.)
- **Misaligned or sub-word accesses:** not supported. `req_addr[1:0]` must be `00` (asserted).

## 6. Bus interface

Port names below match `rtl/top.sv`. No tri-states: every cache drives its own `cache_*`
outputs, and `bus.sv` muxes the granted cache's request onto the shared `bus_*` signals.

### 6.1 Arbitration

| Signal | Driver | Width | Meaning |
|---|---|---|---|
| bus_req[i] | cache i | N_CORES | Cache i wants the bus; held high until granted |
| bus_gnt[i] | arbiter | N_CORES | One-hot; at most one bit set. Registered, held until bus_done |

### 6.2 Cache → bus.sv (one set per cache)

| Signal | Width | Meaning |
|---|---|---|
| cache_cmd[i] | `bus_cmd_t` (2 bits) | CMD_NONE, CMD_GETS, CMD_GETM, CMD_PUTM. Only the granted cache's value is used |
| cache_addr[i] | ADDR_W | Line-aligned (low OFFSET_W bits = 0) |
| cache_put_kind[i] | `put_t` (2 bits) | For PutM only: PUT_DATA, PUT_NODATA, PUT_NODATA_E |
| cache_dval[i] | 1 | Cache i is driving `cache_data[i]` this cycle (owner response, or its own PutM data) |
| cache_data[i] | LINE_W | Cache i's outgoing line |

- **Request timing:** `bus.sv` latches the granted cache's `cache_cmd`, `cache_addr` and
  `cache_put_kind` at the end of the grant cycle G and holds them on `bus_cmd` / `bus_addr` /
  `bus_put_kind` until `bus_done`. So a cache must drive valid values on all three **for as long as
  its `bus_req` is high, including cycle G**, and `cache_cmd` must not be CMD_NONE then (asserted in
  `bus.sv`). From G+1 on, the cache may change them (e.g. when its pending state moves on at the
  Own-* event); the bus no longer looks at them. Before the grant they may change, e.g. a PutM's
  `cache_put_kind` goes PUT_DATA → PUT_NODATA when MI^A becomes II^A.

### 6.3 Memory controller → bus.sv

| Signal | Width | Meaning |
|---|---|---|
| mem_dval | 1 | Memory is driving `mem_data` this cycle |
| mem_data | LINE_W | Memory's line |
| mem_excl | 1 | Memory's response is exclusive (GetS to a block in I) |
| mem_owned | 1 | The block on the bus is in EorM: a cache owns it and will supply the data, so memory stays silent. Valid from the address phase until bus_done |

### 6.4 bus.sv → every cache and memory (broadcast)

| Signal | Width | Meaning |
|---|---|---|
| bus_cmd | `bus_cmd_t` | The granted cache's `cache_cmd` (CMD_NONE when idle) |
| bus_addr | ADDR_W | The granted cache's `cache_addr` |
| bus_put_kind | `put_t` | The granted cache's `cache_put_kind` |
| bus_addr_valid | 1 | **1-cycle pulse in the address phase (G+1).** This is the cycle of the Own-* event for the requester and the Other-* event for everyone else |
| bus_snoop_end | 1 | **1-cycle pulse on the last snoop-window cycle (G+1+SNOOP_LAT).** Snoopers apply their state change at the end of this cycle |
| bus_data | LINE_W | The line on the bus |
| bus_data_valid | 1 | `bus_data` holds valid data this cycle |
| bus_data_excl | 1 | The data response is exclusive → requester installs E |
| bus_done | 1 | Transaction complete; the arbiter may grant next cycle |

**Removed from the guide's interface:** `bus_shared` and `bus_owner` (the wired-ORs).
Memory's per-block state replaces both: it decides E vs. S (`mem_excl`), and it knows whether
a cache owner will respond (`mem_owned`).

**Why the phase strobes:** with `bus_addr_valid` and `bus_snoop_end` coming from one place
(`bus.sv`), caches and memory don't each have to count cycles from the grant. If the timeline
changes (e.g. SNOOP_LAT), only `bus.sv` changes.

- **Who drives `bus_addr_valid`, `bus_snoop_end`, `bus_data_valid`, `bus_data_excl`, `bus_done`:**
  the sequencer in `bus.sv`. Memory's transient state (I^D / S^D / EorM^D) is held in `mem_ctrl.sv`,
  not here (Section 3.3).
- **Data mux select:**
  1. `bus_cmd == CMD_PUTM` with `bus_put_kind == PUT_DATA`: the **requester's** line (`cache_data[i]` of the granted cache).
  2. GetS / GetM with `mem_owned == 1`: the **owner cache's** line (the cache whose `cache_dval` is high;
     one-hot because only one cache can be E or M).
  3. GetS / GetM with `mem_owned == 0`: **memory's** line (`mem_data` when `mem_dval`).
- **`bus_data_excl`** = `mem_excl` when memory is the data source, else 0.
- **Requester ignoring its own transaction:** cache i only snoops when `bus_addr_valid` is high and
  `bus_gnt[i] == 0`.

## 7. Transaction timeline

Diagram: `docs/bus_timing.png`. Draw one for each case: GetS from memory, GetS from an owner cache,
GetM from memory, GetM from an owner cache, PutM with Data / NoData-E / NoData.

**(Proposed)** cycle numbering, relative to the grant cycle G, with SNOOP_LAT = 2:

| Phase | Cycle(s) | What happens |
|---|---|---|
| Grant | G | Arbiter asserts `bus_gnt[i]` (registered output) |
| Address | G+1 | `bus_addr_valid` = 1. The granted cache's `cache_cmd` / `cache_addr` / `cache_put_kind` appear on `bus_cmd` / `bus_addr` / `bus_put_kind`, held until bus_done. **This is the Own-* event** for the requester (e.g. IS^AD → IS^D). Memory reads its block state and sets `mem_owned` |
| Snoop window | G+2, G+3 | Snoopers look up their tag array and `pend_addr`. `bus_snoop_end` = 1 in G+3; at the end of G+3 snoopers apply their Other-* transition from Table 7.11. An owner (E/M/MI^A/EI^A) copies its line into a flush register |
| Data, owner cache | G+4 | Owner drives `cache_dval` / `cache_data`. Memory captures it if the request was GetS |
| Data, memory | G+1+MEM_LAT | Memory knows from its own state that it should respond, so it starts counting at the address phase. MEM_LAT ≥ 3 keeps this after the snoop window |
| Data, PutM | G+4 | Requester sends Data, NoData-E or NoData. Memory updates per Table 7.12 |
| Completion | Same cycle as data | Requester installs the line and new stable state (E if `bus_data_excl`, else S, or M for GetM), clears `pend_valid`; `bus_done` = 1 |
| Earliest next grant | done cycle + 1 | |

### Decisions

1. **When do snoopers change state? (proposed): at the end of the snoop window (end of G+3).**
   Snoopers lose their copies before the requester installs at completion, so the SWMR checker never
   sees two valid copies at once. An owner keeps a flush register so it can still send data in G+4.
2. **Snoop arrives while the cache is serving its own core's hit: snoop wins, the core stalls.**
   The core request is already latched (Section 5) and `req_ready` is low. After the snoop, the cache
   **re-does the core lookup from the start**, since the snoop may have changed the line. A store
   only writes the array once its final lookup is a hit, so it's never half-applied.
3. **Transient states:** held in the pending-transaction register (Section 3.2). Snoops check it
   alongside the tag array.
4. **E vs. S:** decided by `bus_data_excl` at completion. No shared line.

## 8. Memory model

- **Size / address range (proposed):** MEM_BYTES = 64 KB, so 2048 lines. Indexes with `addr[15:5]`
  and ignores the upper bits. Traffic generators stay below 64 KB (asserted).
- **Per-block state:** 2 bits × 2048 blocks (Section 3.3). Reset to I.
- **Initial contents (proposed):** every word holds its own address (word at 0x40 holds 0x40).
  The golden model must initialize the same way.
- **Writes data on:** PutM + Data, and an owner's response to a GetS. **Not** on an owner's response
  to a GetM (memory stays EorM and stale).

## 9. Open questions

- [ ] 1-cycle or 2-cycle hit latency? (Section 5)
- [ ] Should memory's state S be allowed to fall back to I? (Sorin: no. Silent S evictions mean memory can't know.)
- [ ] Guide Phase 2 builds MSI first. Agree on the MSI subset of Tables 7.11 / 7.12 (drop E, EI^A, `bus_data_excl`, and NoData-E).

## Change log

| Date | Change | Agreed by |
|---|---|---|
| | Initial draft | |
| 2026-11-24 | Switched protocol to Sorin Tables 7.11 / 7.12: GetS/GetM/PutM, no BusUpgr, no shared/owner wires, per-block memory state, E is an owner and evicts with PutM, transient states listed | |
| 2026-11-24 | Bus interface matched to `rtl/top.sv`: per-cache `cache_cmd` / `cache_addr` / `cache_put_kind` muxed by bus.sv; added `bus_addr_valid`, `bus_snoop_end`, `bus_put_kind`, and memory outputs `mem_dval` / `mem_data` / `mem_excl` / `mem_owned`. Enum names now match `mesi_pkg.sv` (ST_, TR_, MEM_, CMD_, PUT_, OP_ prefixes) | |
| 2026-11-24 | Memory transient states (I^D / S^D / EorM^D) moved from `bus.sv` to `mem_ctrl.sv`'s transaction register; per-block state updates at `bus_done` | Person B |
| 2026-11-24 | Section 6.2: request timing rule. Cache's `cache_cmd` / `cache_addr` / `cache_put_kind` must be valid while `bus_req` is high, through grant cycle G; `bus.sv` latches them at the end of G | Person B |
