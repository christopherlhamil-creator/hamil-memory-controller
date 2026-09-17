# 7. Related Work

**Lead author of the architecture under review**: Christopher Hamil  
**This section (literature survey and adversarial review)**: Council Seat 1 (`council-grok`)  
**Grounding files (disk-first)**: `research/RFC-0001-HAMIL-CELLULAR-MEMORY-SUBSTRATE.md`, `src/ipc_ring.zig`, `src/sqlite_sidecar.zig`, `src/ebm_governor.zig`, `inventory/EVAL-SQLITE-SIDECAR-BENCH-20260908.md`, `inventory/EVAL-1M-QUERY-BENCH-20260908.md`, `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md`, `inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md`, `inventory/EVAL-GRAND-FUSION-BENCH-20260908.md`  
**Citation index**: `research/references.bib`

Christopher Hamil’s Hamil Memory Controller is not a new SQL engine. It is a **hardware-symbiotic hot tier** whose atomic unit is the 17,408-byte cell (Invariant A-1: \(272 \times 64\,\mathrm{B}\) cache lines) with a 64-byte `=Q16s16s16sII` instruction header (Invariant A-2), a lock-free seqlock ring (`src/ipc_ring.zig`), domain **spoke manifolds**, and an asynchronous **Semantic Sidecar** that drains committed cells into ordinary SQLite (`src/sqlite_sidecar.zig`). This section places that design against forty years of database systems and states the Gegenrede a relational architect will raise.

Numbers below are taken from on-disk evaluation reports, not from the RFC summary table when the two disagree.

---

## 7.1 The relational tax, named

Codd’s relational model [codd1970relational] separated logical structure from physical access. System R [astrahan1976systemr, chamberlin1974systemr] then bound that model to a *compiled* path: SQL text → parse tree → cost-based access path [selinger1979access] → iterator plan. Gray’s transaction concept [gray1981transaction, gray1993transaction] made durability and isolation first-class, and with them **locks, logs, and a single writer in the common embedded case**.

Hipp’s SQLite [hipp2000sqlite, hipp2018vdbe, hipp2010wal] is the purest living form of that stack in a library: Lemon parser, VDBE bytecode, pager, and WAL with **one writer**. `inventory/EVAL-SQLITE-SIDECAR-BENCH-20260908.md` measures the tax on pop-os (AVX2, Linux 6.9): formatted `INSERT` SQL under 8 threads falls to **276.9 tx/s** at **15,651.7 µs (15.65 ms)** mean latency as `SQLITE_BUSY` serializes commits. That is Defect Class 20 in this repository: file-level SQLite mutex on the hot path.

Hamil’s claim, implemented in `src/sqlite_sidecar.zig`, is that this tax is **optional for ingest**. The hot path packs Invariant A-2 headers and leases 17,408 B slots through `pacer.zig`; SQLite is touched only in `drainOnce` / `startDrainWorker` against table `sidecar_records`. The module comment states the rejected alternative explicitly: *“Not a SQL engine replacement (sqlite-zig/sqlnano/limbo are explicitly rejected).”*

---

## 7.2 “Rewrite the engine” (the monolith fallacy)

Stonebraker’s “one size fits all” critique [stonebraker2007onelinesize] and the H-Store rewrite thesis [stonebraker2007hstore, kallman2008hstore] argued that a disk-era System R descendant cannot be the OLTP engine of a DRAM machine. C-Store [stonebraker2005cstore], VoltDB [stonebraker2010voltdb], Hekaton [diaconu2013hekaton], Silo [tu2013silo], HyPer [neumann2011hyper], DuckDB [raasveldt2019duckdb], ClickHouse [clickhouse2016], and compiled/vectorized execution surveys [kersten2018everything] each specialize storage and execution (columns, compilation, vectorization, partitioning).

They remain **general-purpose query processors**. They still own:

- a SQL or SQL-like surface (or a record API that reconstructs one);
- a page or vector *buffer* whose width is not 272 cache lines;
- a catalog, optimizer, and concurrency protocol for *ad-hoc* access.

Limbo [limbo2024], sqlnano [sqlnano], and sqlite-zig [sqlitezig] tighten that fallacy: they reimplement SQLite’s *role* (in-process SQL VM) in a new language. Hamil’s Semantic Sidecar does the opposite. SQLite stays the cold ANSI-SQL system of record; the Zig controller is an **acceleration layer in front of it**, not a fork of VDBE.

OLTP-through-the-looking-glass [harizopoulos2008oltp] already showed that buffer-pool, latching, and WAL dominate CPU in classical engines. Ailamaki et al. [ailamaki1999dbmstalling] showed the stall is often **cache**. Hamil’s Spoke Manifold Principle is a geometry answer to that stall: keep an operational domain in a 640 KB header spoke (10,000 × 64 B) so the working set is L2/L3-resident, rather than hoping a rewritten VM will chase fewer pointers.

---

## 7.3 Access methods that are still not A-2

| Lineage | Representative work | What it shares with Hamil | What it does not |
| :--- | :--- | :--- | :--- |
| B-tree / System R | [selinger1979access], SQLite [hipp2000sqlite] | Durable keyed lookup | 4–5 level pointer chase on 4 KiB pages at 1M rows (`inventory/EVAL-1M-QUERY-BENCH-20260908.md`) |
| LSM | [oneil1996lsm], LevelDB [ghemawat2011leveldb], RocksDB [dong2021rocksdb], Cassandra [lakshman2010cassandra] | Append-friendly ingest | Compaction storms; no 64 B instruction header |
| Column / vector | C-Store [stonebraker2005cstore], MonetDB/X100 [boncz2005monetdb], DuckDB [raasveldt2019duckdb], ClickHouse [clickhouse2016] | Scan bandwidth, SIMD | Column vectors, not co-located opcode+ids+flags+epoch in one line |
| MM-OLTP | H-Store [kallman2008hstore], Hekaton [diaconu2013hekaton], Silo [tu2013silo] | Latch-free or partition-serial | Tuple/record layouts; still a database kernel |
| mmap K/V | LMDB [chu2011lmdb] | Zero-copy pages | COW B+ tree, not seqlock cells |
| Structure store | Redis [sanfilippo2009redis], RAMCloud [ousterhout2011ramcloud], Memcached [fitzpatrick2004memcached] | DRAM-first | No A-1 cell, no sidecar drain to SQL |
| Geo-distributed SQL | Spanner [corbett2013spanner], Calvin [thomson2012calvin] | Epochs / TrueTime / sequencing | WAN consensus, not L1 ingest |

Lock-free rings and seqlocks [lamport1977concurrent, herlihy1991waitfree, michael1996queue, linuxseqlock, boehm2012seqlock] are the *concurrency* ancestors of `src/ipc_ring.zig` (`cmpxchgWeak` on `alloc_cursor`, odd/even `seq`). Hamil’s contribution is binding that protocol to **Invariant A-1 cells** and an A-2 header that is also the query predicate, not inventing CAS.

Lamport clocks [lamport1978time] and Kleppmann’s fencing discussion [kleppmann2017designing] are the conceptual neighbors of the A-2 `epoch` field. They are not a 17,408 B geometry.

---

## 7.4 Measurements that exist on this disk

**Ingest (sidecar vs SQLite INSERT), pop-os, `inventory/EVAL-SQLITE-SIDECAR-BENCH-20260908.md`:**

| Arm | 8 writers | Throughput | Mean latency |
| :--- | ---: | ---: | ---: |
| SQLite formatted INSERT | 600 tx | 276.9 tx/s | 15.65 ms |
| Hamil cellular sidecar (`pacer` + A-1 cells) | 30,000 tx | **986,382.9 tx/s** | **4.60 µs** |

Speedup on that file: **3,562×** throughput, **3,402×** lower mean latency. Asynchronous drain: 2,000 cells → SQLite in 10.67 ms (**187,455.7 rows/s**). SIMD status scan: 9.20–13.22 ns/cell over 30,000 cells.

RFC-0001 §5 quotes 1,000,659.8 tx/s and 3,886×. Those figures are **not** in `EVAL-SQLITE-SIDECAR-BENCH-20260908.md`. This section uses the evaluation file.

**1M-record query, pop-os, `inventory/EVAL-1M-QUERY-BENCH-20260908.md`:**

| Arm | Mode | QPS | LLC misses / 5k |
| :--- | :--- | ---: | ---: |
| SQLite 1M B-tree | point | 70,145.1 | 246,845 |
| SQLite composite | multi-constraint | 49,429.3 | 197,958 |
| Zig **cross-spoke hopping** (61 MB monolith analogue) | multi-constraint | 24,703.4 | 22,682,034 |
| Zig **domain spoke** (640 KB, warm) | point | **135,175.4** | 46,396 |
| Zig **domain spoke** (warm) | multi-constraint | **80,796.7** | **3,656** |

Spoke vs hopping: **3.27×** QPS and **3,395×** fewer LLC misses (22,682,034 / 3,656), matching the locality claim in RFC-0001. Tail: SQLite multi-constraint p99.9 = 3,112.4 µs vs spoke 42.9 µs (**72.5×**).

**Zen 4 (Brandys), `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md`:** 4 OS processes on `/dev/shm` SharedCellRing **11,459 ops/s** (7.02 µs) vs SQLite **144 ops/s** (15,343.8 µs) — **79.7×**. Warm domain spoke point query **381,119.3 QPS**, p50 **2,290 ns**, **LLC misses = 0**. Those RFC-0001 §5 rows are now grounded in that proof file.

---

## 7.5 Gegenrede (relational architect)

> *If the hot store is a bag of 64-byte headers and 17,408-byte cells, how do you express an ad-hoc JOIN, a `GROUP BY`, or a report that was not anticipated when the spoke was laid out? You have abolished the optimizer. You will reinvent SQL badly.*

This is the correct objection. Codd’s independence of access paths [codd1970relational] and Selinger’s optimizer [selinger1979access] exist because **the query is not known at write time**. A 16-byte `subject_id` SIMD scan is an equality/range predicate on a cache line, not a join kernel. DuckDB and HyPer exist because analytics wants exactly the plans Hamil refuses to run at ingest.

**Dialectical resolution (Hamil’s Semantic Sidecar).** Split the timescales:

1. **Operational tier** (Hamil controller): known keys, known opcodes (1001–1008), known spokes. Writes never parse SQL. Visibility is seqlock / pacer CAS (`src/ipc_ring.zig`). This is the 986k tx/s path.
2. **Relational drain** (SQLite `sidecar_records`): a background worker projects *closed* batches with `BEGIN IMMEDIATE … COMMIT` (`src/sqlite_sidecar.zig`, measured 187k rows/s). Ad-hoc JOIN, window functions, and BI tools attach **here**, on a stock SQLite file, after the fact.

The optimizer is not deleted. It is **moved off the ingest critical path**. Dual-write CDC and “operational store + warehouse” are industrial cousins; Hamil’s distinction is that the operational store is a **specified cache-line geometry** (A-1/A-2) rather than another undocumented Redis or an LSM with a SQL façade.

A remaining open loop, which this Gegenrede still owns: if a query *must* join two hot spokes before drain, the controller does not yet offer a relational algebra. The honest answer is: route it to the sidecar, or add a typed join in a later RFC. Do not pretend `vpcmpeqb` on `subject_id` is System R.

---

## 7.6 Heterogeneous accelerators are still not a sidecar

AVX-512 [intel2013avx512], AMD XDNA / Ryzen AI [amd2023ryzenai], and TPU-class systolic arrays [jouppi2017tpu] are the industrial ancestors of “put the hot loop on a special ISA.” GPU-resident transformers (CUDA, ROCm, llama.cpp `-ngl`) are the ancestor of “wake the discrete GPU by default.”

Hamil’s **tripartite** assignment (`research/sections/04_tripartite_heterogeneous_architecture.md`) is the Gegenrede to both:

- The CPU is not rewritten into a SQL engine (Monolith Fallacy, §7.2). It evaluates A-2 headers in-register.
- The NPU streams **cells**, not KV tensors: **118.174 GiB/s**, **252.686 ns/cell**, **0 GPU wakes**, **0.0 °C** thermal delta (`inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md`).
- The GPU is \(\varnothing\) on the happy path (`b2b` gap \(< 0.0100\)). Grand Fusion: **1,118,133** cycles/s, **894.35 ns/cycle**, **100.00% GPU skips**, 0 heap (`inventory/EVAL-GRAND-FUSION-BENCH-20260908.md`).

A CUDA graph or an XRT operator that still materializes a transformer KV cache is a **monolith on a faster bus**. The Semantic Sidecar remains SQLite on the drain path; XDNA does not replace Hipp.

---

## 7.7 Attribution

Invariant A-1, Invariant A-2, the Semantic Sidecar, the Spoke Manifold Principle, the PoE Governor, and the tripartite \(E_{\mathrm{NPU}}+E_{\mathrm{CPU}}+E_{\mathrm{GPU}}\) skip rule are inventions of **Christopher Hamil**, specified in RFC-0001 and implemented in `src/geometry.zig`, `src/ipc_ring.zig`, `src/pacer.zig`, `src/sqlite_sidecar.zig`, and `src/ebm_governor.zig`. Prior art cited above is the *dialogue partner*, not a claim of joint authorship.

Cite as [hamil2026cellular].

---

## Link proposer

- **Links**: RFC-0001; `src/sqlite_sidecar.zig` (rewrite rejection); `src/ebm_governor.zig`; `research/sections/04_tripartite_heterogeneous_architecture.md`; `inventory/EVAL-SQLITE-SIDECAR-BENCH-20260908.md`; `inventory/EVAL-1M-QUERY-BENCH-20260908.md`; `inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md`; `inventory/EVAL-GRAND-FUSION-BENCH-20260908.md`; [stonebraker2007hstore]; [hipp2018vdbe].
- **Keywords**: relational tax, VDBE, Semantic Sidecar, spoke manifold, seqlock, Defect Class 20, XDNA, PoE GPU skip.
- **Gegenrede (open)**: Does a 640 KB spoke still hold when embeddings occupy 32 × 512 B slots inside a *full* 17,408 B cell rather than a 64 B header ring?

## Validation (Luhmann)

| Principle | Status |
| :--- | :--- |
| Atomicity | This section is readable without the rest of the whitepaper if RFC-0001 and the two `proof/` files are at hand. |
| Connectivity | ≥2 links: Codd/Gray/Hipp lineage; Hamil sidecar vs H-Store rewrite; EVAL numbers. |
| Organic growth | Heterogeneous §7.6 added only after Frontiers 3–4 proofs landed on disk. |
| Continued dialogue | JOIN Gegenrede left unresolved on hot-path algebra. |
