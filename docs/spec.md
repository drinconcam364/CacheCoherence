# MESI Coherence System: Specification

**Status:** DRAFT (change to FROZEN when both of you sign off)
**Signed off:** ☐ Person A (____, date ____)  ☐ Person B (____, date ____)

> Rule: any change to a port, the bus timing, or a parameter after the freeze needs both
> of you to agree, a PR that touches only this file (plus `mesi_pkg.sv` if needed), and
> an entry in the Change Log at the bottom.

---

## 1. Locked design decisions

See Section 1 of the project guide. Copy over any decision you change, with the reason.

| Decision | Choice | Changed? Why |
|---|---|---|
| Protocol | MESI (MSI first) | |
| Mechanism | Snooping, atomic bus | |
| Invalidate vs. update | Write-invalidate | |
| Arbitration | Round-robin | |
| Dirty data on remote read | Owner Flush, memory updated | |
| Evictions | M → BusWB; E/S silent | |
| Write policy | Write-back, write-allocate | |
| Snoop vs. core tag port | Single port, snoop wins | |

## 2. Parameters

| Parameter | Default | Notes |
|---|---|---|
| N_CORES | 4 | Debug with 2 |
| ADDR_W | 32 | Byte address |
| WORD_W | 32 | |
| LINE_BYTES | 32 | 8 words/line |
| CACHE_BYTES | 2048 | 64 lines |
| WAYS | 1, then 2 | |
| MEM_LAT | 20 | Configurable |
| SNOOP_LAT | 2 | |

### Derived address fields (work these out yourselves)

| Field | 1-way width | 1-way bit range | 2-way width | 2-way bit range |
|---|---|---|---|---|
| Byte-in-word | | | | |
| Word offset | | | | |
| Index (set) | | | | |
| Tag | | | | |
| Number of sets | | — | | — |

How the RTL computes these (localparam expressions in `mesi_pkg.sv`):

```
(fill in)
```

## 3. Per-line state

- Fields stored per line: ______
- State encoding (must match `mesi_pkg.sv`): I = ____, S = ____, E = ____, M = ____
- Why no separate valid/dirty bits: ______
- Reset value of every state: ______

## 4. Core-side interface (traffic generator ↔ cache)

| Signal | Dir (from cache's view) | Width | Meaning |
|---|---|---|---|
| req_valid | in | 1 | |
| req_ready | out | 1 | |
| req_op | in | | LD, ST (TAS later) |
| req_addr | in | ADDR_W | |
| req_wdata | in | WORD_W | |
| resp_valid | out | 1 | |
| resp_rdata | out | WORD_W | |

- Handshake rule (when does a request get accepted?): ______
- Blocking rule: one outstanding request; `req_ready` low until `resp_valid`.
- Hit latency (cycles from accept to `resp_valid`), given synchronous SRAM reads: ______
- Are misaligned or sub-word accesses supported? ______

## 5. Bus interface

| Signal | Driver | Width | Meaning |
|---|---|---|---|
| bus_req[i] | cache i | N_CORES | |
| bus_gnt[i] | arbiter | N_CORES | one-hot? ____ |
| bus_cmd | granted cache | | NONE, BusRd, BusRdX, BusUpgr, BusWB |
| bus_addr | granted cache | ADDR_W | line-aligned |
| bus_data | owner cache or memory or requester (WB) | LINE_BYTES*8 | |
| shared_out[i] / bus_shared | each cache / OR | 1 | |
| owner_out[i] / bus_owner | each cache / OR | 1 | memory-inhibit |
| bus_data_valid | | 1 | |
| bus_done | | 1 | |

- Who drives `bus_data_valid` and `bus_done`? ______
- Data mux select logic (owner vs. memory vs. requester for BusWB): ______
- How does a requester know to ignore its own transaction when snooping? ______

## 6. Transaction timeline

Diagram: `docs/bus_timing.png` (one per command: BusRd-from-memory, BusRd-with-Flush,
BusRdX, BusUpgr, BusWB).

| Phase | Cycle(s) | What happens |
|---|---|---|
| Grant | | |
| Address | | |
| Snoop window | | |
| Data | | |
| Completion / bus_done | | |
| Earliest next grant | | |

### Decisions

1. Do snoopers change state at the end of the snoop window, or at completion? **______**
   Why: ______
2. Snoop arrives while the cache is serving its own core's hit: **snoop wins; core stalls.**
   How the core request is held so it isn't lost: ______
3. When exactly is `shared_out` / `owner_out` valid, and when is it sampled? ______
4. Does the requester sample `bus_shared` at the end of the snoop window or at completion? ______

## 7. Memory model

- Size / address range: ______
- Initial contents (zero? pattern?): ______
- Captures data on: BusWB, Flush (when `bus_owner`=1). Stays silent when `bus_owner`=1.

## 8. Open questions

- [ ] ______

## Change log

| Date | Change | Agreed by |
|---|---|---|
| | Initial draft | |
