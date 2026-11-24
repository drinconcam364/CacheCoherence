# MESI Protocol Reference

The protocol this design implements, transcribed from Sorin, Hill & Wood, *A Primer on Memory
Consistency and Cache Coherence*, Section 7.3: Table 7.11 (cache controller), Table 7.12
(memory controller), Figures 7.4 / 7.5 (stable-state FSMs) and Table 7.13 (example execution).

Every directed test, assertion and coverage point traces back to a cell in these tables.
If this file disagrees with Sorin's tables, Sorin wins. Fix this file.

---

## 1. How to read the tables

| Notation | Meaning |
|---|---|
| `X / Y` | Do X, then go to state Y |
| `— / Y` | No action, go to state Y |
| `—` | No action, no state change |
| `Stall` | Don't process the core request yet: `req_ready` stays low |
| `Hit` | Serve the request from the cache, no bus traffic |
| `(A)` | Impossible because the bus is atomic. **Write an assertion that it never happens** |
| `n/a` | Impossible for another reason (shaded blank in Sorin). Also assert it never happens |

### 1.1 Events, mapped to RTL signals

| Sorin event | When it happens in this RTL |
|---|---|
| Load / Store | Core request accepted (`req_valid && req_ready`, `req_op` = OP_LD / OP_ST) |
| Replacement | A miss needs a way that holds a valid line |
| Own-GetS / Own-GetM / Own-PutM | `bus_addr_valid` = 1 and `bus_gnt[i]` = 1 (this cache's request is now ordered) |
| Other-GetS / Other-GetM / Other-PutM | `bus_addr_valid` = 1 and `bus_gnt[i]` = 0. The state change is applied at the end of the `bus_snoop_end` cycle |
| Own Data Response | `bus_data_valid` = 1 while this cache is granted, `bus_data_excl` = 0 |
| Own Data Response (exclusive) | Same, with `bus_data_excl` = 1 |

### 1.2 Names: Sorin ↔ RTL (`mesi_pkg.sv`)

| Sorin | RTL |
|---|---|
| I, S, E, M | ST_I, ST_S, ST_E, ST_M (`mesi_t`) |
| IS^AD, IS^D, IM^AD, IM^D, SM^AD, SM^D, MI^A, EI^A, II^A | TR_IS_AD, TR_IS_D, TR_IM_AD, TR_IM_D, TR_SM_AD, TR_SM_D, TR_MI_A, TR_EI_A, TR_II_A (`trans_t`) |
| Memory I, S, EorM | MEM_I, MEM_S, MEM_EORM (`mem_state_t`) |
| Memory I^D, S^D, EorM^D | Held in `mem_ctrl.sv`'s transaction register (not stored per block) |
| GetS, GetM, PutM | CMD_GETS, CMD_GETM, CMD_PUTM (`bus_cmd_t`) |
| Data, NoData, NoData-E | PUT_DATA, PUT_NODATA, PUT_NODATA_E (`put_t`) |

---

## 2. Cache controller (Sorin Table 7.11)

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

### 2.1 Notes for this design

- **Blocking cores:** the Load/Store "Hit" entries in SM^AD, SM^D, MI^A and EI^A never happen,
  because the core that started the transaction is waiting for it. Treat them as Stall.
- **"Send data"** = drive `cache_dval` / `cache_data` in the owner data cycle (G+4).
  "To requester and memory" vs. "to requester" is the same signal; memory decides whether to
  capture it based on the command (it captures on GetS, not on GetM).
- **Own-PutM data** = drive `cache_put_kind` (PUT_DATA / PUT_NODATA_E / PUT_NODATA), plus
  `cache_dval` / `cache_data` for PUT_DATA.
- **Other-PutM is always `—`.** A snooper never reacts to another cache's eviction.
- **SM^AD → SM^D → M:** memory is in S, so it sends a full data response. The cache may overwrite
  its line with it; the data is identical.
- **Snoops on a transient state** match on the pending register's `pend_addr`, not the tag array.
- **Store after a miss completes:** in IM^D → M (and SM^D → M), the store that caused the miss is
  applied to the line when it's installed.

---

## 3. Memory controller (Sorin Table 7.12)

| State | GetS | GetM | PutM | Data | NoData | NoData-E |
|---|---|---|---|---|---|---|
| **I** | Send data to requester (exclusive) / EorM | Send data to requester / EorM | — / I^D | n/a | n/a | n/a |
| **S** | Send data to requester | Send data to requester / EorM | — / S^D | n/a | n/a | n/a |
| **EorM** | — / S^D | — | — / EorM^D | n/a | n/a | n/a |
| **I^D** | (A) | (A) | (A) | Write data to memory / I | — / I | — / I |
| **S^D** | (A) | (A) | (A) | Write data to memory / S | — / S | — / S |
| **EorM^D** | (A) | (A) | (A) | Write data to memory / I | — / EorM | — / I |

### 3.1 Notes for this design

- **"Send data to requester"** = drive `mem_dval` / `mem_data` at G+1+MEM_LAT. "(exclusive)" = also `mem_excl` = 1.
- **EorM on GetS / GetM:** memory sends nothing; it sets `mem_owned` = 1 so `bus.sv` takes the
  owner cache's data. On GetS, memory goes to S^D and the owner's data counts as the "Data"
  message: memory writes it and goes to S.
- **EorM^D + NoData → EorM:** the evicting cache lost ownership (II^A) to another cache's GetM
  before its PutM was ordered. The new owner still holds the block.
- **S + PutM** only happens from a cache in II^A after another cache's GetS (memory went to S).
- **I + PutM** can't happen in this protocol (a PutM comes from E, M or II^A, and memory is EorM
  or S in all those cases). Add an assertion; it's a good sanity check.

---

## 4. MSI subset (build this first, Phase 2)

Drop E entirely: no ST_E, no EI^A, no exclusive responses, no NoData-E. Memory needs only two
stable states: memory owns the block (Sorin "IorS") or a cache does ("M").
These are derived from the MESI tables above; check them against Primer Section 7.2.

### 4.1 Cache controller, MSI

Same as Section 2 with these rows removed: **E**, **EI^A**, and the "Own Data Resp (excl)" column.
IS^D's data response always goes to **S**.

### 4.2 Memory controller, MSI

| State | GetS | GetM | PutM | Data | NoData |
|---|---|---|---|---|---|
| **IorS** | Send data to requester | Send data to requester / M | — / IorS^D | n/a | n/a |
| **M** | — / IorS^D | — | — / M^D | n/a | n/a |
| **IorS^D** | (A) | (A) | (A) | Write data to memory / IorS | — / IorS |
| **M^D** | (A) | (A) | (A) | Write data to memory / IorS | — / M |

In RTL, use MEM_S for IorS and MEM_EORM for M. `mem_excl` is always 0.

---

## 5. Stable-state FSMs (Sorin Figures 7.4 and 7.5)

Draw these as `docs/fsm_cache.png` and `docs/fsm_memory.png`.

### 5.1 Cache controller

| From | Event | To |
|---|---|---|
| I | Own-GetS, exclusive response (memory was in I) | E |
| I | Own-GetS, non-exclusive response | S |
| I | Own-GetM | M |
| S | Own-GetM | M |
| S | Other-GetM, or Replacement (silent) | I |
| E | Store (silent) | M |
| E | Other-GetS | S |
| E | Other-GetM, or Own-PutM | I |
| M | Other-GetS | S |
| M | Other-GetM, or Own-PutM | I |

### 5.2 Memory controller

| From | Event | To |
|---|---|---|
| I | GetS or GetM | EorM |
| S | GetM | EorM |
| EorM | GetS | S |
| EorM | PutM (with Data or NoData-E) | I |

---

## 6. Example execution (Sorin Table 7.13)

C1 loads block X while C2 stores to it. **Use this as your first two-core directed test** (Phase 3;
in Phase 2 with MSI, step 6 installs S instead of E). Sorin's steps are logical; in RTL each bus
transaction takes the full spec Section 7 timeline, but the order of states must match exactly.

| Step | C1 | C2 | Memory | Request on bus | Data on bus |
|---|---|---|---|---|---|
| 1 | Issue GetS / IS^AD | | | | |
| 2 | | Issue GetM / IM^AD | | | |
| 3 | | | | GetS (C1) | |
| 4 | — / IS^D | | Send exclusive data to C1 / EorM | | |
| 5 | | | | | Exclusive data from memory |
| 6 | Copy data from memory / E | | | GetM (C2) | |
| 7 | Send data to C2 / I | — / IM^D | — / EorM | | |
| 8 | | | | | Data from C1 |
| 9 | | Copy data from C1 / M | | | |
| 10 | Issue GetS / IS^AD | | | | |
| 11 | | | | GetS (C1) | |
| 12 | — / IS^D | Send data to C1 and memory / S | — / S^D | | |
| 13 | | | | | Data from C2 |
| 14 | Copy data from C2 / S | | Copy data from C2 / S | | |

---

## 7. Invariants (what the checkers enforce)

| Invariant | Checked by |
|---|---|
| SWMR: if any cache holds a block in E or M, no other cache holds it valid | `checkers.sv`, every cycle |
| Every S or E line matches memory | `checkers.sv`, every cycle |
| Memory MEM_I ⇒ no cache holds the block valid | `checkers.sv` |
| Memory MEM_S ⇒ no cache holds the block in E or M | `checkers.sv` |
| Memory MEM_EORM ⇒ exactly one cache holds it in E or M, and none in S (catches a silent E eviction) | `checkers.sv` (when the bus is idle) |
| Every (A) and n/a cell never happens | SVA |
| At most one `cache_dval` high at a time | SVA |
| `mem_excl` only on GetS with memory in MEM_I | SVA |
| E is installed only on `bus_data_excl` | SVA |
