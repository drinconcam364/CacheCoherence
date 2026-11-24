# MESI Coherence System: Specification

**Status:** DRAFT (change to FROZEN when both of you sign off)
**Signed off:** ☐ Person A (____, date ____)  ☐ Person B (____, date ____)

> Rule: any change to a port, the bus timing, or a parameter after the freeze needs both
> of you to agree, and an entry in the Change Log at the bottom.
>
> **Protocol source of truth:** Sorin, Hill & Wood, *A Primer on Memory Consistency and Cache
> Coherence*, Section 7.3 (MESI snooping): Figure 7.4, Figure 7.5, Table 7.11, Table 7.12.
> Section 4 below transcribes those tables. If anything here disagrees with them, the tables win.
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
- **Stable state encoding (proposed):** I = `2'b00`, S = `2'b01`, E = `2'b10`, M = `2'b11`.
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
| `pend_state` | The transient state (`trans_t` enum: IS_AD, IS_D, IM_AD, IM_D, SM_AD, SM_D, MI_A, EI_A, II_A) |

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

- **Encoding (proposed):** I = `2'b00`, S = `2'b01`, EorM = `2'b10`. **Reset:** every block I.
- Memory can't tell E from M. That's why E evictions send **NoData-E** (memory → I) and M
  evictions send **Data** (memory writes, → I).
- Silent S evictions mean memory may say S when no cache actually holds the block. That's safe:
  a later GetS just gets S instead of E.
- **Transient memory states** (I^D, S^D, EorM^D: "waiting for data after a PutM or owner GetS")
  are held in the bus sequencer, not per block, because the atomic bus allows only one at a time.

## 4. Protocol tables

Transcribed from Sorin Tables 7.11 and 7.12. `—` = no action, no state change.
`(A)` = impossible because the bus is atomic (assert it never happens).
`n/a` = impossible for other reasons (shaded blank in Sorin). `X/Y` = do X, go to state Y.

### 4.1 Event meanings in this design

| Sorin event | What it means in this RTL |
|---|---|
| Load / Store | Core request from the traffic generator |
| Replacement | The cache must evict a valid line to make room for a miss |
| Own-GetS / Own-GetM / Own-PutM | This cache's own request reaches the address phase on the bus (it's now ordered) |
| Other-GetS / Other-GetM / Other-PutM | Another cache's request is in the address phase. This cache snoops it |
| Own Data Response | Data for this cache's GetS/GetM appears on the bus (`bus_data_valid`, `bus_data_excl` = 0) |
| Own Data Response (exclusive) | Same, with `bus_data_excl` = 1 (memory responded to a GetS from state I) |
| Stall | Hold `req_ready` low. Don't process the core request yet |

### 4.2 Cache controller (Sorin Table 7.11)

| State | Load | Store | Replacement | Own-GetS | Own-GetM | Own-PutM | Other-GetS | Other-GetM | Other-PutM | Own Data Resp | Own Data Resp (excl) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **I** | Issue GetS / IS^AD | Issue GetM / IM^AD | n/a | n/a | n/a | n/a | — | — | — | n/a | n/a |
| **IS^AD** | Stall | Stall | Stall | — / IS^D | n/a | n/a | — | — | — | n/a | n/a |
| **IS^D** | Stall | Stall | Stall | n/a | n/a | n/a | (A) | (A) | (A) | — / S | — / E |
| **IM^AD** | Stall | Stall | Stall | n/a | — / IM^D | n/a | — | — | — | n/a | n/a |
| **IM^D** | Stall | Stall | Stall | n/a | n/a | n/a | (A) | (A) | (A) | — / M | n/a |
| **S** | Hit | Issue GetM / SM^AD | — / I (silent) | n/a | n/a | n/a | — | — / I | — | n/a | n/a |
| **SM^AD** | Hit | Stall | Stall | n/a | — / SM^D | n/a | — | — / IM^AD | — | n/a | n/a |
| **SM^D** | Hit | Stall | Stall | n/a | n/a | n/a | (A) | (A) | n/a | — / M | n/a |
| **E** | Hit | Hit / M (silent) | Issue PutM / EI^A | n/a | n/a | n/a | Send data to requester and memory / S | Send data to requester / I | — | n/a | n/a |
| **M** | Hit | Hit | Issue PutM / MI^A | n/a | n/a | n/a | Send data to requester and memory / S | Send data to requester / I | — | n/a | n/a |
| **MI^A** | Hit | Hit | Stall | n/a | n/a | Send Data to memory / I | Send data to requester and memory / II^A | Send data to requester / II^A | — | n/a | n/a |
| **EI^A** | Hit | Stall | Stall | n/a | n/a | Send NoData-E to memory / I | Send data to requester and memory / II^A | Send data to requester / II^A | — | n/a | n/a |
| **II^A** | Stall | Stall | Stall | n/a | n/a | Send NoData to memory / I | — | — | — | n/a | n/a |

Notes for this design:
- Because cores are blocking, the Load/Store "Hit" entries in **SM^AD, SM^D, MI^A, EI^A** never
  actually happen: the core that started the transaction is waiting for it. Treat them as Stall.
  (They'd matter if you later add a non-blocking core.)
- **Other-PutM is always `—`.** A snooper never reacts to another cache's eviction.
- In SM^AD, the data response for the GetM comes from memory (memory is in S). The cache can
  overwrite its line with it; the data is identical.

### 4.3 Memory controller (Sorin Table 7.12)

| State | GetS | GetM | PutM | Data | NoData | NoData-E |
|---|---|---|---|---|---|---|
| **I** | Send data to requester (exclusive) / EorM | Send data to requester / EorM | — / I^D | n/a | n/a | n/a |
| **S** | Send data to requester | Send data to requester / EorM | — / S^D | n/a | n/a | n/a |
| **EorM** | — / S^D (owner sends data; memory captures it) | — (owner sends data) | — / EorM^D | n/a | n/a | n/a |
| **I^D** | (A) | (A) | (A) | Write data to memory / I | — / I | — / I |
| **S^D** | (A) | (A) | (A) | Write data to memory / S | — / S | — / S |
| **EorM^D** | (A) | (A) | (A) | Write data to memory / I | — / EorM | — / I |

- In EorM^D, **NoData** → EorM is the case where the evicting cache lost ownership (II^A)
  to another cache's GetM before its PutM was ordered. The new owner still holds the block.
- In EorM, a GetS moves memory to S^D. The data the owner sends counts as the "Data" message
  that completes it (memory writes it and → S).

### 4.4 Stable-state FSM diagrams

Draw these into `docs/fsm_cache.png` and `docs/fsm_memory.png`, matching Sorin Figures 7.4 and 7.5.
Cache stable-state transitions (Figure 7.4):

| From | Event | To |
|---|---|---|
| I | Own-GetS, memory in I (exclusive response) | E |
| I | Own-GetS, memory not in I | S |
| I | Own-GetM | M |
| S | Own-GetM | M |
| S | Other-GetM, or Replacement (silent) | I |
| E | Store (silent) | M |
| E | Other-GetS | S |
| E | Other-GetM, or Own-PutM | I |
| M | Other-GetS | S |
| M | Other-GetM, or Own-PutM | I |

Memory stable-state transitions (Figure 7.5): I → EorM on GetS or GetM; S → EorM on GetM;
EorM → S on GetS; EorM → I on PutM (with Data or NoData-E).

## 5. Core-side interface (traffic generator ↔ cache)

| Signal | Dir (from cache's view) | Width | Meaning |
|---|---|---|---|
| req_valid | in | 1 | Traffic generator has a request |
| req_ready | out | 1 | Cache can accept a request this cycle |
| req_op | in | 2 | **(proposed)** `op_t` enum: LD, ST (TAS added later; 2 bits leaves room) |
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

| Signal | Driver | Width | Meaning |
|---|---|---|---|
| bus_req[i] | cache i | N_CORES | Cache i wants the bus; held high until granted |
| bus_gnt[i] | arbiter | N_CORES | One-hot; at most one bit set. Held until bus_done |
| bus_cmd | granted cache | `bus_cmd_t` (2 bits) | NONE, GetS, GetM, PutM |
| bus_addr | granted cache | ADDR_W | Line-aligned (low OFFSET_W bits = 0) |
| put_kind | granted cache | `put_t` (2 bits) | For PutM only: DATA, NODATA, NODATA_E |
| cache_dval[i] | cache i | N_CORES | Cache i (the owner) is driving its line onto the bus this cycle |
| cache_data[i] | cache i | LINE_W each | Cache i's outgoing line (owner response, or PutM data) |
| bus_data | mux in bus.sv | LINE_W | The line on the bus |
| bus_data_valid | bus.sv | 1 | `bus_data` holds the data response this cycle |
| bus_data_excl | bus.sv | 1 | The data response is exclusive (memory answered a GetS from state I) → requester installs E |
| bus_done | bus.sv | 1 | Transaction complete; arbiter may grant next cycle |

**Removed from the guide's interface:** `bus_shared` and `bus_owner` (the wired-ORs).
Memory's per-block state replaces both: it decides E vs. S, and it knows whether a cache owner will respond.

- **Who drives `bus_data_valid`, `bus_data_excl`, `bus_done` (proposed):** the central sequencer in
  `bus.sv`, which also holds memory's transient state (I^D / S^D / EorM^D) during a PutM.
- **Data mux select (proposed):**
  1. `bus_cmd == PutM` with `put_kind == DATA`: the **requester's** line (selected by `bus_gnt`).
  2. GetS / GetM and memory's block state is **EorM**: the **owner cache's** line
     (selected by `cache_dval`, which is one-hot because only one cache can be E or M).
  3. GetS / GetM and memory's block state is **I or S**: **memory's** line.
- **Requester ignoring its own transaction:** cache i only snoops when `bus_cmd != NONE` and
  `bus_gnt[i] == 0`.

## 7. Transaction timeline

Diagram: `docs/bus_timing.png`. Draw one for each case: GetS from memory, GetS from an owner cache,
GetM from memory, GetM from an owner cache, PutM with Data / NoData-E / NoData.

**(Proposed)** cycle numbering, relative to the grant cycle G, with SNOOP_LAT = 2:

| Phase | Cycle(s) | What happens |
|---|---|---|
| Grant | G | Arbiter asserts `bus_gnt[i]` (registered output) |
| Address | G+1 | Requester drives `bus_cmd`, `bus_addr` (and `put_kind` for PutM), held until bus_done. **This is the Own-* event** for the requester (e.g. IS^AD → IS^D). Memory reads its block state for `bus_addr` |
| Snoop window | G+2, G+3 | Snoopers look up their tag array and `pend_addr`. At the end of G+3, they apply their Other-* transition from Table 7.11. An owner (E/M/MI^A/EI^A) copies its line into a flush register |
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
