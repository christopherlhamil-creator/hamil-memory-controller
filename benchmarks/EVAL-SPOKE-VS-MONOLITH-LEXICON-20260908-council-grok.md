# EVAL — Spoke vs monolith lexicon isolation (`Aherron` / Soundex A650)

**Seat:** council-grok  
**Date:** 2026-09-08  
**Mode:** BENCHMARK & ROUTING  
**Harness:** `scripts/spoke_vs_monolith_lexicon_bench.py` (native cell sweep, no Ollama, no SQLite writes)  
**Verdict:** **NEEDS WORK** on the live rings (router already punched the air-gap). Fixture math **supports spoke isolation**.

---

## Method

- Cell law: 17,408 B, header `=Q16s16s16sII` (64 B). Remainder 0 on every bank touched.
- Query operators: exact substring + American Soundex from `src/b2b_pack.zig` (Seabolt → S143).
- No embeddings, no Ollama, no `BEGIN IMMEDIATE`.
- Structured records only (1860 Schedule 1 fields / ASME clause / citation). No 82-chunk prose.

Soundex this turn:

| Token | Code |
|---|---|
| Aherron | **A650** |
| Aaron | **A650** (collision) |
| ASME | A250 |
| Oysterman | O236 |

---

## 1. Precision: isolated spoke vs concatenated monolith

Four fixture cells (one file each), then the same four concatenated as a 69,632 B “monolith”:

| Record | File | Payload (structured) |
|---|---|---|
| TP | `genealogy.cells` / `ocr.cells` | `last=Aherron` … `occ=Oysterman` |
| FP plant | `qms.cells` | `clause=ASME_BPVC_Section_VIII inspector=Aaron` |
| FP plant | `research.cells` | `cite=Aaron_v_Gloucester inspector=Aaron` |

Query **`Aherron`**:

| Bank opened | Exact hits | Soundex FPs | Precision |
|---|---|---|---|
| genealogy spoke only | 1 (`Aherron`) | 0 | **1.00** |
| ocr spoke only | 1 (`Aherron`) | 0 | **1.00** |
| qms spoke only | 0 | 1 (`Aaron`) | n/a (query never issued if routed) |
| research spoke only | 0 | 1 (`Aaron`) | n/a |
| monolith (all four mmap’d) | 2 | 2 (`Aaron`×2) | **0.50** |

Needle-style routing that opens **only** `run/spoke_queues/genealogy.cells` never sees `Aaron` or `ASME`. Opening the concat file (or `zk_cells.bin`) does.

---

## 2. False positives on the live 1,995-cell bank

`db/zk_cells.bin` = 34,728,960 B, 1,995 cells, remainder 0. Sweep **6.84 µs/cell** this box (payload+Soundex, not SIMD).

| Query | Exact | Soundex FP | Notes |
|---|---|---|---|
| Aherron | **0** | 1 | slot 1368 token `aren` (`subject=20260902_00_aren`) — A650 drift, not the clan |
| Aaron | 0 | (same A650 class) | |
| ASME | **1** | — | QMS/legal token already lives in the **same** physical file as everything else |

Live spoke rings (4×4 cells, 69,632 B each) contain **zero** `Aherron` and **zero** `ASME`. They are ticket metadata, not census/QMS clauses — except genealogy **slot 2**.

---

## 3. The air-gap is a file descriptor, not a physics law

Physical separation (`ocr.cells` vs `qms.cells`) is an **mmap boundary**:

- A genealogy query that `open(2)`s only `genealogy.cells` cannot return QMS bytes. There is no cosine head mixing vocabularies across files you did not map.
- That is stronger than a “domain tag” column inside one 8.7 GB bank: L3 will still stream QMS cache lines if they sit on the same linear sweep.

It is **not** impenetrable:

1. **Router misroute (live, this worktree).** `genealogy.cells` slot 2 payload is `spoke_route qms enforce gate lattice scars 1-16; never open genealogy.sqlite`. A QMS ticket was appended to the genealogy file because `detect_spoke_name` used to match path substrings. File air-gap **failed the moment enqueue wrote the wrong fd**.
2. **Soundex is not a domain lock.** `Aherron` and `Aaron` are the same A650. Isolation works only if the Aaron cell is in a file you do not open. A monolith Soundex scan will always surface it.
3. **Monolith already holds ASME.** One exact `ASME` hit in `zk_cells.bin` means a global Aherron sweep pays to walk legal vocabulary even when the clan token is absent.

`needle_bridge_router.py` still keys `spoke_route <ocr|genealogy|qms|reptile>` to `run/spoke_queues/<spoke>.cells`. That routing is the air-gap. There is no `research.cells` in `SPOKES` yet.

Hygiene this turn: `unread=0`, fleet_pool WRITE locks none, inode 145746.

---

## 4. What this does *not* prove

- L3 blowout at 500k cells / 8.7 GB — not measured (fixture is 4 cells; live bank is 34 MB). Cache claims stay theoretical.
- Pacer spinlock contention across OCR vs legal workers — not instrumented.
- Embedding cosine contamination — banned Ollama; not run.

Those belong to other seats’ sweep benches. This seat only owns **vocabulary collision**.

---

## Production readiness

**NEEDS WORK** for live rings (genealogy already contains QMS text).  
**PASS as a fixture demonstration** that spoke-file query of `Aherron` is precision 1.00 vs monolith 0.50 once `Aaron` sits in QMS/research.

**Next metal step (not this commit):** refuse enqueue when folder-SoT spoke ≠ detected spoke; add `AHERRON` / `OYSTERMAN` to the closed genealogy lexicon so `Vlex` can fire; do not Soundex-scan `zk_cells.bin` for clan tokens.

**Not done:** Ollama, SQLite writes, appending to `zk_cells.bin`, inventing a 500k-cell L3 number.
