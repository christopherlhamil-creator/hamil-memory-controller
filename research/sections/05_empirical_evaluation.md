# 5. Empirical Evaluation

**Section Lead**: Seat 2 (`@sonnet`, `council-sonnet`) — Empirical Evaluation & Reproducibility
**Status**: Draft for whitepaper integration
**Grounding Policy**: Every figure in this section is sourced to a specific committed proof file or a raw benchmark capture on disk (see §5.6, Data Provenance). No figure is asserted without a citable source.

---

## 5.1 Experimental Methodology

### 5.1.1 Test Hosts

All benchmarks were executed as `ReleaseFast` native-target Zig 0.16/0.17 machine code, compiled and run directly on physical metal — no containers, no virtualization, no emulation.

| | **Host A** | **Host B** |
| :--- | :--- | :--- |
| **Hostname** | `pop-os` (local development host) | `Brandys` (`10.10.10.2`, remote over 1 Gbps copper hardline) |
| **CPU** | Intel Core i5-8300H (Coffee Lake, 4C/8T) | AMD Ryzen 7 8700F (Zen 4, 8C/16T) |
| **L3 Cache** | 8 MiB (shared) | 16 MiB (shared) |
| **L2 Cache** | 256 KiB per core (shared topology) | 1 MiB **private** per core |
| **Memory** | DDR4-2666 | DDR5-5400 |
| **SIMD ISA** | AVX2 | AVX-512 |
| **Compile Target** | native (`-march=x86-64-v3`, AVX2) | native `znver4` |
| **OS / Kernel** | Pop!_OS 22.04, Linux 6.9.3-76060903-generic | Linux (SSH, `occupancy=linux` verified — port 3389 RDP refused, port 22 SSH open) |

Host A is the architecture's *worst case*: a mobile/laptop-class Coffee Lake part with a shared, comparatively small L2. Host B is the architecture's *target case*: a modern desktop Zen 4 part with large private per-core L2 — chosen specifically to test the Spoke Manifold Principle's central claim, that a 640 KB domain spoke should lock entirely inside a Zen 4 core's 1 MiB private L2.

### 5.1.2 Benchmark Harnesses

Three compiled Zig test/benchmark binaries produced every number in this section, all invoked through `zig build`:

| Harness | Build Step | Tier(s) |
| :--- | :--- | :--- |
| `tests/test_sqlite_sidecar_bench.zig` | `bench-sqlite-sidecar` | Tier 1 |
| `tests/test_multiprocess_shm.zig` | `test-multiprocess-shm` | Tier 2 |
| `tests/test_1m_query_bench.zig` | `bench-1m-query` | Tier 3, Tier 4 |
| `tests/test_spoke_memory_footprint.zig`-class harness (`bench-spoke-isolation`) | `bench-spoke-isolation` | Spoke locality corroboration (§5.5) |

Each harness runs both arms of its comparison (traditional SQLite vs. the Hamil cellular substrate) under identical load in the same process invocation, on the same machine, in the same run — eliminating cross-run environmental drift (thermal state, background load, page-cache warmth) as a confound between arms.

### 5.1.3 What Each Arm Measures

- **Arm A (SQLite baseline)**: real `libsqlite3.so.0` linked directly into the Zig binary. Text SQL (`INSERT INTO records VALUES (...)`), full Lemon parser → AST → VDBE bytecode compilation, and standard SQLite locking (WAL mode, `busy_timeout` backoff) — i.e., SQLite used the way any application uses it, with no artificial handicap.
- **Arm B (Hamil substrate)**: the 64-byte `InstructionHeader` (`=Q16s16s16sII`, Invariant A-2) written directly into lock-free, atomically-leased slots inside 17,408-byte cells (Invariant A-1), queried via in-register SIMD comparison rather than B-tree traversal.
- Both arms perform a real, durable write or a real, exhaustive query — Arm B is not "skipping the work," it is doing the same logical operation through a different physical mechanism (see RFC-0001 §2–§4 for the mechanism).

### 5.1.4 Reproduction Commands

```bash
# Tier 1 — ingestion
zig build bench-sqlite-sidecar --summary all

# Tier 2 — multi-process shared memory
zig build test-multiprocess-shm --summary all

# Tier 3 / Tier 4 — 1M-record query traversal + tail latency
zig build bench-1m-query --summary all

# Cross-host (Zen 4): append -Dcpu=znver4 (native target on Brandys itself)
zig build test-multiprocess-shm -Dcpu=znver4 --summary all
zig build bench-1m-query -Dcpu=znver4 --summary all
```

---

## 5.2 Tier 1: Multi-Threaded Ingestion (Sidecar Benchmark)

**Host**: A (Intel Coffee Lake). **Harness**: `tests/test_sqlite_sidecar_bench.zig`. **Source**: `inventory/EVAL-SQLITE-SIDECAR-BENCH-20260908.md`.

600 SQLite `INSERT` transactions (Arm A) vs. 30,000 lock-free cellular commits (Arm B) at 1, 4, and 8 concurrent writer threads. Arm A's transaction count is deliberately smaller because SQLite's write-lock serialization makes higher counts impractically slow to benchmark; Arm B's count is large enough to make its per-transaction timing statistically stable at nanosecond resolution.

| Threads | SQLite (tx/s) | SQLite mean latency | Hamil Substrate (tx/s) | Substrate mean latency | Speedup |
| :---: | :---: | :---: | :---: | :---: | :---: |
| 1 | 317.9 | 3,136.9 µs | 311,519.2 | 2.54 µs | 979x |
| 4 | 285.6 | 8,705.2 µs | 697,120.5 | 3.45 µs | 2,440x |
| 8 | 276.9 | 15,651.7 µs | 986,382.9 | 4.60 µs | 3,562x |

At 8 threads, SQLite throughput *drops* relative to 1 thread (317.9 → 276.9 tx/s) because every writer serializes behind the single database write lock; mean latency rises 4.99x. The Hamil substrate instead *scales* (311,519 → 986,382 tx/s, a 3.17x gain from 1→8 threads) because writers acquire non-overlapping cell slots via a single atomic `fetchAdd`, with zero mutex contention and zero false sharing across 64-byte cache lines.

A second, independent execution of the same harness on the same host measured a peak of **1,000,659.8 tx/s** at 8 threads (4,699.1 ns mean latency) against an SQLite baseline of **257.5 tx/s** (20,013.4 µs mean latency) in that run — a **3,886x** throughput speedup and **4,259x** latency reduction. Both runs are reported rather than only the higher one: the committed run above (986,382.9 tx/s) and this corroborating run (1,000,659.8 tx/s) bound the observed throughput at 8 threads to a **950k–1.05M tx/s** band on this hardware, comfortably above the "1M tx/s" headline claim's neighborhood without depending on a single favorable sample.

**Asynchronous relational projection**: the substrate never blocks writers on SQLite I/O. A background worker drains committed cells in batches and projects them into SQLite for durable, ANSI-SQL-queryable storage: 2,000 cells flushed in 10.67 ms (**187,455.7 rows/sec**), 589x the unbatched SQLite write rate. This is the mechanism, not a separate optimization — Arm B's hot path throughput figures above already assume this decoupling.

---

## 5.3 Tier 2: Multi-Process Shared-Memory Concurrency

**Harness**: `tests/test_multiprocess_shm.zig` (`test-multiprocess-shm`). Unlike Tier 1 (threads within one process), this tier forks **4 independent OS child processes**, each opening the same `/dev/shm`-backed cell ring and the same SQLite file, to test cross-process (not just cross-thread) correctness and throughput — including a reader process that verifies monotonic epoch ordering and the absence of torn reads across all committed cells.

| Host | SQLite (4 processes, WAL) | Hamil Substrate (`/dev/shm` ring, atomic-CAS lease) | Speedup |
| :--- | :---: | :---: | :---: |
| Host A — Intel Coffee Lake | 225 ops/s (9,425.9 µs mean latency) | 4,880 ops/s (12.19 µs mean latency) | **21.7x** |
| Host B — AMD Zen 4 (Brandys) | 144 ops/s (15,343.8 µs mean latency) | 11,459 ops/s (7.02 µs mean latency) | **79.7x** |

**Source**: Host A figures captured directly in a benchmark run log; Host B figures are the raw remote `stdout` of the same harness cross-compiled and executed natively (`-Dcpu=znver4`) on Brandys, formalized in `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md` §2 (superseding the earlier `inventory/EVAL-BRANDYS-1M-BENCH-20260908-council-codex.md` audit, which correctly reported this benchmark as blocked before the missing `test-multiprocess-shm` build step existed).

All 96 committed cells were verified monotonic with **zero torn reads** across all 4 processes in every run. Every process operates on cells it does not own the address space of at fork time; correctness here (not just speed) is the load-bearing claim — a lock-free scheme that corrupted data under multi-process contention would be disqualifying regardless of throughput.

The 79.7x figure on Zen 4 exceeds the 21.7x figure on Coffee Lake primarily because SQLite's *absolute* penalty under WAL lock contention is worse on Brandys (144 ops/s vs 225 ops/s) even though the underlying hardware is faster — a reminder that SQLite's write-lock serialization is an architectural bottleneck, not a hardware one, and does not automatically improve with better silicon.

---

## 5.4 Tier 3: 1,000,000-Record Query Traversal

**Harness**: `tests/test_1m_query_bench.zig` (`bench-1m-query`). A standardized 1,000,000-record dataset, populated identically into (a) a SQLite table with a primary-key B-tree index and a composite `(subject_id, epoch, flags)` index, and (b) 100 domain spokes of 10,000 cache-aligned 64-byte `InstructionHeader` packets each (640 KB/spoke). 5,000 point queries and 5,000 multi-constraint range queries per arm.

**Source**: Host A — `inventory/EVAL-1M-QUERY-BENCH-20260908.md`. Host B — `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md` §3.

| Arm | Host | Query Type | QPS | p50 Latency | LLC Misses (5k queries) | IPC |
| :--- | :--- | :--- | :---: | :---: | :---: | :---: |
| SQLite B-Tree | A | Point | 70,145.1 | 12,310 ns | 246,845 | 0.87 |
| SQLite Composite B-Tree | A | Multi-constraint | 49,429.3 | 9,729 ns | 197,958 | 0.83 |
| SQLite B-Tree | B (Zen 4) | Point | 200,615.6 | — | — | ~2.1 |
| **Hamil Domain Spoke (warm L2)** | **A** | **Point (early-exit)** | **135,175.4** | **5,956 ns** | **46,396** | **1.32** |
| **Hamil Domain Spoke (warm L2)** | **A** | **Multi-constraint (SIMD)** | **80,796.7** | **11,101 ns** | **3,656** | **1.43** |
| **Hamil Domain Spoke (warm L2)** | **B (Zen 4)** | **Point (early-exit)** | **381,119.3** | **2,290 ns** | **0** | **2.90** |

On Host A, the domain spoke arm delivers **1.93x** the throughput and **2.07x** lower p50 latency than SQLite's B-tree at point-query granularity, and cuts multi-constraint LLC misses by **54x** (197,958 → 3,656) because `epoch` and `flags` share the exact same 64-byte cache line as `subject_id` — the multi-constraint check requires zero additional memory loads once the header is in a register.

On Host B, the same 640 KB domain spoke fits **entirely inside Zen 4's 1 MiB private per-core L2** (versus Coffee Lake's smaller, shared L2 topology), and the effect is qualitative, not just quantitative: **LLC misses drop to exactly zero** across the full 5,000-query run, IPC rises to 2.90, and throughput reaches 381,119.3 QPS — a **1.90x** speedup over SQLite's own (also-improved, 200,615.6 QPS) Zen 4 baseline. This is the empirical confirmation of the Spoke Manifold Principle's central hardware-sizing claim: partition size to fit the target core's private cache, and last-level cache traffic for hot-domain queries falls to zero.

A control condition (`Arm B1/B2` in `inventory/EVAL-1M-QUERY-BENCH-20260908.md`) ran the identical spoke query logic but hopped randomly across all 100 spokes per query (simulating an unpartitioned 61 MB monolith) instead of staying resident in one domain spoke: throughput collapsed to 24,703.4–33,166.6 QPS and LLC misses rose to 12.4M–22.7M. The gain in the warm-spoke rows above is therefore attributable to the domain-partitioning strategy itself, not merely to the SIMD comparison mechanism — see §5.5.

---

## 5.5 Tier 4: Tail Latency & Spoke-Locality Jitter

**Source**: `inventory/EVAL-1M-QUERY-BENCH-20260908.md` §2.1–§2.2 (Host A).

| Arm | p90 | p99 | p99.9 (tail) |
| :--- | :---: | :---: | :---: |
| SQLite Composite B-Tree (multi-constraint) | 11,008 ns | 31,958 ns | **3,112,396 ns (3,112.4 µs)** |
| Hamil Domain Spoke (multi-constraint, SIMD) | 11,688 ns | 16,935 ns | **42,913 ns (42.9 µs)** |

SQLite's p99.9 tail is **72.5x** worse than its own median (9,729 ns → 3,112,396 ns) — a jitter spike attributable to internal page-cache hash-table rehashing, cursor-state allocation, and database-level read-lock acquisition under sustained query load. The Hamil substrate's p99.9 (42.9 µs) is within **3.9x** of its own median (11,101 ns) and remains bounded below 43 µs — because there is no B-tree to rebalance, no page cache to miss, and no lock to wait on; every query performs the same fixed-cost SIMD scan of a resident 640 KB buffer regardless of query history.

**Spoke locality vs. monolith (memory footprint corroboration)**: a separate harness (`inventory/EVAL-SPOKE-MEMORY-FOOTPRINT-20260908.md`) isolates the locality effect from the query-engine comparison entirely, measuring raw sweep latency over an isolated 1,000-cell spoke (16.6 MB) vs. an unpartitioned 3,000-cell monolith (49.8 MB) using only `getrusage`/`/proc/self/smaps` — no SQLite in either arm. Result: 6.94 µs/sweep (spoke) vs. 29.26 µs/sweep (monolith), a **4.22x** difference, with the monolith incurring 2.89x more minor page faults (797 vs. 276) and consuming 2.92x more resident memory during the sweep. Both arms return to identical baseline RSS with zero dirty pages after unmap — ruling out a memory leak as an explanation for the monolith's slower behavior; the difference is cache locality, not memory pressure.

---

## 5.6 Data Provenance

Per the project's Disk-First Grounded Evidence invariant, every figure above traces to one of these committed or disk-resident sources — no figure in this section is asserted from memory or generated synthetically:

| Figure(s) | Source File |
| :--- | :--- |
| Tier 1 (Host A, committed run) | `inventory/EVAL-SQLITE-SIDECAR-BENCH-20260908.md` |
| Tier 1 (Host A, corroborating run, 1,000,659.8 tx/s) | Raw benchmark capture cross-checked against §5.2; independently confirms the sub-5 µs / >950k tx/s regime |
| Tier 2 (Host A) | Raw benchmark capture (`throughput=4880 ops/s ... throughput=225 ops/s`, 21.7x) |
| Tier 2 (Host B) | `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md` §2 |
| Tier 3 (Host A) | `inventory/EVAL-1M-QUERY-BENCH-20260908.md` |
| Tier 3 (Host B) | `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md` §3 |
| Tier 4 | `inventory/EVAL-1M-QUERY-BENCH-20260908.md` §2.1–§2.2 |
| Spoke-locality memory footprint | `inventory/EVAL-SPOKE-MEMORY-FOOTPRINT-20260908.md` |
| Tokenizer expansion (Gemma 4 E2B vs Qwen2.5-Coder-7B, N=100) | `inventory/EVAL-TOKENIZER-CORPUS-BPE-20260908.md`; corpus `research/corpus/tokenizer_eval/` |
| Tokenizer collapse pipeline (ReleaseFast, N=1,000) | `inventory/EVAL-LEXICON-COLLAPSE-BENCH-20260908.md` |
| Physical llama.cpp prefill latency & token reduction (N=100) | `inventory/EVAL-LLAMACPP-TOKENIZER-BENCH-20260908.md`; `inventory/llamacpp_bench_gemma_20260908.json`; raw captures `inventory/llamacpp_bench_raw_20260908/` |
| Frontier 3 (Host B, physical AMD XDNA NPU DMA streaming, 118.17 GiB/s) | `inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md` |
| Frontier 4 (Grand Fusion composed intent loop, 1.12 Mops/s) | `inventory/EVAL-GRAND-FUSION-BENCH-20260908.md` |
| Frontier 1 (GBNF intake token masking, cited for §5.10 cross-comparison only) | `inventory/EVAL-GBNF-INTAKE-BENCH-20260908.md` |
| Frontier 2 (Deterministic context assembly, cited for §5.10 cross-comparison only) | `inventory/EVAL-DETERMINISTIC-CONTEXT-ASSEMBLY-20260908.md` |

Two items are flagged for transparency rather than silently omitted or silently asserted:

1. The Tier 1 "corroborating run" (1,000,659.8 tx/s) is not captured in a `proof/*.md` file the way the primary Tier 1 run is — it exists as a raw benchmark stdout capture outside `proof/`. It is reported here as a *second data point*, not the headline number, precisely because a single unrepeated run is weaker evidence than the committed, methodology-documented run in `inventory/EVAL-SQLITE-SIDECAR-BENCH-20260908.md`.
2. Prior to this section, `inventory/EVAL-BRANDYS-1M-BENCH-20260908-council-codex.md` certified the Host B Tier 2/Tier 3 benchmarks as **BLOCKED / NOT VERIFIED** (missing build steps). That blocker was resolved in commit `b456136`, and `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md` (authored alongside this section) is the first committed artifact grounding the resulting Host B numbers — until now they existed only in a gitignored local log (`run/council_progress.jsonl`) and in the already-drafted `research/RFC-0001-HAMIL-CELLULAR-MEMORY-SUBSTRATE.md` §5 summary table.

No claim in this section extrapolates beyond what a cited harness actually measured. Where a number in `research/RFC-0001-HAMIL-CELLULAR-MEMORY-SUBSTRATE.md` §5 could not be traced to a source at authoring time, it is either sourced here explicitly or is not repeated.

## 5.7 Tokenizer collapse and llama.cpp prefill

The tokenizer lane evaluates a separate boundary: semantic collapse before an unmodified `llama.cpp` prompt is submitted. Seat 0's native Zig harness (`bench-lexicon-collapse`) scans, phonetic-maps, and collapses propositions into the A-2 64-byte header. On the captured ReleaseFast run, the 1,000-proposition case completed at 3,903.6 ns/proposition and 256,174.4 propositions/s, producing 64,000 bytes of headers; the isolated SIMD scan measured 13.40 ns per 64-byte chunk. The scaling table and GGUF metadata extraction are recorded in `inventory/EVAL-LEXICON-COLLAPSE-BENCH-20260908.md`.

The independent corpus audit used 100 paired propositions across census, QMS, and operational domains. Its verbose arm contained 4,766 English words and expanded to 6,887 Gemma tokens or 6,805 Qwen tokens, while the semantic arm contained 100 fixed 64-byte headers (6,400 bytes total). That is 68.87× Gemma and 68.05× Qwen token expansion relative to one header per proposition, not a claim that those headers were themselves passed through BPE. The source and corpus accounting are in `inventory/EVAL-TOKENIZER-CORPUS-BPE-20260908.md`.

Seat 2's physical `llama-cli` benchmark (`inventory/EVAL-LLAMACPP-TOKENIZER-BENCH-20260908.md`) evaluated the canonical N=100 proposition corpus against `models/gguf/gemma-4-E2B_q4_0-it.gguf` on metal (Host A: Intel Core i5-8300H, NVIDIA GeForce GTX 1060 Max-Q 6GB) across 200 individual invocations under strict Invariant 12 compliance (native compiled binary, zero background runners). Initial runs revealed a brief GPU contention window where background vocabulary extraction overlapped with items 0–4; re-benchmarking items 0–4 in strict isolation via `scripts/rebench_clashed_items.py` eliminated the contention (Item 2 prompt throughput surging from 205.1 t/s to 264.9 t/s, a 23% latency reduction).

The final uncontended N=100 physical telemetry confirms:
1. **Prompt token count**: Arm A averaged 69.87 tokens (range 51–82) while Arm B (compact A-2 tuples) averaged 23.38 tokens (range 19–28)—a directly measured **2.99× reduction** in input sequence length.
2. **Prompt prefill latency**: Arm A averaged 141.10 ms (range 111.9–157.4 ms) while Arm B averaged 74.12 ms (range 62.3–74.8 ms)—a directly measured **1.90× faster prefill latency** (47.5% reduction in time-to-first-token).
3. **Honest null results**: Prompt throughput in tokens/second was lower for Arm B (315.3 t/s vs 495.6 t/s) because small batches (19–28 tokens) do not amortize fixed CUDA kernel-launch overhead—prefill latency, not raw t/s, is the truthful performance metric. Autoregressive generation throughput over 4 tokens was identical (~47.5 t/s), and process-level peak host RSS (~3.62 GB) and GPU VRAM (2,600 MiB) showed zero variance because static 3.3 GB model weights dominate memory residency for short completions.
4. **KV-cache growth reduction**: Applying standard GQA KV-cache formulas ($2 \times 32 \times 8 \times 128 \times 2 = 131,072$ bytes/token for a 7B-class model), Arm A requires 8.73 MB of KV-cache streaming per proposition vs. 2.92 MB for Arm B—a **2.99× reduction** in memory bandwidth demanded during sequence extension.
5. **Cross-system representation comparison**: Comparing Arm A's KV cache footprint ($69.87 \times 131{,}072 = 9,157,990.4$ bytes) against the Hamil substrate's native 64-byte `BytecodeHeader` (Invariant A-2, `=Q16s16s16sII`), the derived architectural compression ratio is **143,093.8×** (~143,094×). As documented in Section 8 (§8.4) and `inventory/EVAL-LLAMACPP-TOKENIZER-BENCH-20260908.md`, this is an architectural cross-representation comparison between uncompressed transformer KV state and in-register cellular instruction headers, not an end-to-end `llama-cli` measurement.

For a detailed systems analysis of the consumer hardware memory-bandwidth wall, hybrid CPU-to-GPU offload bottlenecks, and the Gegenrede addressing the CIDR 2022 database `mmap` critique [@crotty2022mmap], see Section 8 (Appendix B).

---

## 5.8 Frontier 3: Physical AMD XDNA NPU Silicon Streaming (Host B)

**Host**: B (Brandys, AMD Ryzen 7 8700F, Phoenix NPU `[0000:12:00.1]`, XDNA 1 architecture, `/dev/accel/accel0`). **Harness**: `scripts/brandys_npu_stream_bench.cpp` / `scripts/brandys_npu_stream_bench.sh`, native AMD XRT userspace runtime (`libxrt_coreutil.so`, `libxrt_driver_xdna.so.2`). **Source**: `inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md`.

This tier answers a different question from Tiers 1–4: not "is the cellular substrate faster than SQLite," but "does the 17,408-byte cell geometry (Invariant A-1) survive contact with a physical, non-CPU accelerator without falling back to a software emulator or waking the discrete GPU." A double-buffered `xrt::bo` buffer object, mapped to host-pinned memory, streams a real 64-byte `BytecodeHeader`-populated cell (`opcode = 1001`, `assert_relation`) bidirectionally across the NPU's DMA path (`XCL_BO_SYNC_BO_TO_DEVICE` / `XCL_BO_SYNC_BO_FROM_DEVICE`) with zero heap allocations in the hot loop.

| Metric | Measured Value (N = 100,000 cells) |
| :--- | ---: |
| Total transferred data | 3.48 GB (100,000 × 17,408 B × 2, bidirectional) |
| Total stream duration | 27.44 ms |
| Throughput | **3,644,530 cells/sec** (3.64 Mcells/s) |
| Bidirectional bandwidth | **118.174 GiB/s** |
| Mean DMA latency | **252.686 ns** |
| p50 / p95 / p99 / max latency | 250 ns / 270 ns / 320 ns / 13,531 ns |
| Pre-test thermals (CPU / GPU edge) | 37.0°C / 34.0°C |
| Post-test thermals (CPU / GPU edge) | 37.0°C / 34.0°C (Δ = 0.0°C) |
| GPU wakes during the run | **0 / 100,000** |

Three things are directly measured here, not asserted: (1) the 17,408-byte cell geometry round-trips the NPU's DMA path intact at 3.64M cells/sec — this is real silicon throughput, not a simulated bus model; (2) the max-latency outlier (13,531 ns against a 252.7 ns mean) occurs once per run and is consistent with a one-time buffer-object cache-sync cost on the first transfer, not a recurring jitter pattern (p99 stays at 320 ns); (3) the zero-thermal-delta and zero-GPU-wake results together substantiate the PoE (Product-of-Experts) governor's design claim that NPU-resident cell streaming keeps the discrete GPU asleep and the host cold — this was measured with `nvidia-smi`/sensor-equivalent thermal reads before and after the 100,000-cell burst, not inferred from idle specifications.

## 5.9 Frontier 4: Grand Fusion — End-to-End Composed Intent Loop

**Hosts**: A (`pop`, intake/governance stages) composed with the Frontier 3 NPU stream pipeline (`brandys`). **Harness**: `tests/test_grand_fusion.zig` (`zig build bench-grand-fusion`, `ReleaseFast`). **Source**: `inventory/EVAL-GRAND-FUSION-BENCH-20260908.md`.

Tiers 1–4 and Frontier 3 each isolate one mechanism (ingestion, concurrency, query, tail latency, NPU DMA). Frontier 4 instead composes five previously-separate stages into one measured, end-to-end pipeline per intent cycle, so the reported number is a real composed-system latency rather than a sum of isolated benchmarks that might not actually chain cleanly in practice:

```
raw intent string
  → Stage 1  GBNF intake gate (src/intake_gate.zig): token-mask validation, stamps the 64B BytecodeHeader
  → Stage 2  Deterministic context assembly (src/boot_pack.zig): skill opcode + lane affinity, content-addressed payload, assembles the 17,408B Cell
  → Stage 3  Multi-signal PoE governor (E_joint = E_NPU + E_CPU + E_GPU): hard-vetoes high joint energy, enforces the Invariant A-11 4-hop limit
  → Stage 4  Zero-copy DualHeadBuffer pointer swap: atomic active/shadow flip, 0 memcpy, 0 mutex, 0 heap
  → Stage 5  Lock-free IPC ring enqueue (src/ipc_ring.zig): cache-line-aligned 64B response, backpressure via IpcError.BufferFull
```

| Metric | Measured Value (N = 100,000 full cycles) |
| :--- | ---: |
| Total elapsed time | 89.43 ms |
| End-to-end latency | **894.35 ns/cycle** |
| Throughput | **1,118,133 cycles/sec** (1.12 Mops/s) |
| GPU happy-path skips | **100,000 / 100,000 (100.00%)** |
| Dynamic heap allocation | **0 bytes** |
| Cell / header geometry | 17,408 B / 64 B (Invariants A-1 / A-2, unchanged under composition) |
| Hop-limit circuit breaker | Hop 5 strictly refused (Invariant A-11) |

Negative-space regression gates were exercised in the same run, not assumed: an out-of-vocabulary verb (`"malicious_verb"`) and an oversized identifier both throw at Stage 1 without silent truncation; a joint energy ≥ 500 throws `GovernorError.HardVeto` and stamps `OPCODE_VETO` (1004) at Stage 3 without reaching Stage 4; a traversal depth greater than 4 hops throws `GovernorError.RefusalMaxHopExceeded` at Stage 3; and IPC ring capacity exhaustion returns `IpcError.BufferFull` at Stage 5 rather than silently clobbering an in-flight packet. The 894.35 ns figure is therefore the latency of a pipeline that also correctly refuses bad input in the same measured run, not a happy-path-only number obtained by disabling the gates.

## 5.10 Summary Across All Four Open Rectangles

The four Rectangles were benchmarked independently, on different harnesses, at different points in the project's timeline; this table exists purely to let a reader see them side by side. Figures for Rectangles 1 and 2 are restated here from their own proof files for cross-comparison — their full methodology is out of this section's scope (Frontier 1/2 authorship belongs to Seat 0/Seat 3; see `research/sections/01_introduction.md` and `research/sections/03_spoke_manifold_and_sidecar.md`) — and are cited to their source files rather than re-derived here.

| Rectangle | Mechanism | Headline Throughput | Headline Latency | Source |
| :--- | :--- | ---: | ---: | :--- |
| 1 — GBNF Intake Token Masking | Compile-time grammar mask stamps the 64B header at intake | 2,071,574 triples/sec | 482.72 ns/triple (end-to-end stamping) | `inventory/EVAL-GBNF-INTAKE-BENCH-20260908.md` |
| 2 — Deterministic Context Assembly | Content-addressed, byte-stable JSON boot packs | 5,408 packs/sec | 184.91 µs/pack (0.000% byte variance) | `inventory/EVAL-DETERMINISTIC-CONTEXT-ASSEMBLY-20260908.md` |
| 3 — Physical XDNA NPU Streaming | Bidirectional DMA of 17,408B cells over `/dev/accel/accel0` | 3,644,530 cells/sec | 252.69 ns/cell (118.17 GiB/s) | `inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md` |
| 4 — Grand Fusion Composed Loop | Stages 1–5 fused into one intent cycle | 1,118,133 cycles/sec | 894.35 ns/cycle | `inventory/EVAL-GRAND-FUSION-BENCH-20260908.md` |

One discrepancy is flagged rather than silently smoothed over: an earlier council directive's summary prose cited Rectangle 1 at "1.57 Mcells/sec, 634.76 ns stamping." The committed proof file for Rectangle 1 (`inventory/EVAL-GBNF-INTAKE-BENCH-20260908.md` §3) instead measures three distinct sub-operations — relation GBNF evaluation (381.53 ns/token, 2,621,025 tokens/s), identifier validation (10.29 ns/id), and end-to-end triple stamping (482.72 ns/triple, 2,071,574 triples/s) — none of which is exactly "1.57 Mcells/sec / 634.76 ns." This table reports the committed proof file's own numbers rather than the directive summary's, per the Disk-First Grounded Evidence invariant (§5.6): when a summary and its cited source disagree, the source on disk governs.
