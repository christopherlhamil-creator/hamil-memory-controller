# Tables and Data — Empirical Evaluation (Section 5) Companion

**Author**: Seat 2 (`@sonnet`, `council-sonnet`)
**Scope**: Every table cited in `research/sections/05_empirical_evaluation.md`, collected into one publication-ready file — Markdown for direct repo/HTML rendering, `booktabs`-style LaTeX for `research/latex/`. Tiers 1–4 and the tokenizer-boundary tables here restate (do not re-derive) the figures already detailed in `research/sections/06_empirical_data_appendix.md`; this file adds the Frontier 3 (physical NPU streaming) and Frontier 4 (Grand Fusion) tables that appendix did not yet cover, plus a master cross-Rectangle summary. Every number traces to a file under `proof/` — none is asserted from memory or generated synthetically (Disk-First Grounded Evidence, per `05_empirical_evaluation.md` §5.6).

This file is intentionally **not** numeric-prefixed (`build_whitepaper.py`'s `SECTION_NAME` pattern only concatenates `\d+_*.md` files into the manuscript body): it is a standalone data/reference companion, not a numbered section of the whitepaper itself.

---

## Table A — Tier 1: Multi-Threaded Ingestion (Host A, Intel Coffee Lake)

**Source**: `inventory/EVAL-SQLITE-SIDECAR-BENCH-20260908.md`

| Threads | SQLite (tx/s) | SQLite Mean Latency | Hamil Substrate (tx/s) | Substrate Mean Latency | Speedup |
| :---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 317.9 | 3,136.9 µs | 311,519.2 | 2.54 µs | 979x |
| 4 | 285.6 | 8,705.2 µs | 697,120.5 | 3.45 µs | 2,440x |
| 8 | 276.9 | 15,651.7 µs | 986,382.9 | 4.60 µs | 3,562x |

Corroborating independent run (not the primary committed figure; see `05_empirical_evaluation.md` §5.2): 1,000,659.8 tx/s vs. SQLite 257.5 tx/s at 8 threads (3,886x).

```latex
\begin{table}[htbp]
  \centering
  \caption{Tier 1 --- Multi-threaded ingestion, SQLite vs.\ the Hamil cellular substrate (Host A: Intel Coffee Lake).}
  \label{tab:tables-data-tier1}
  \begin{tabular}{@{}rrrrrr@{}}
    \toprule
    Threads & SQLite (tx/s) & SQLite latency & Substrate (tx/s) & Substrate latency & Speedup \\
    \midrule
    1 & 317.9   & 3{,}136.9\,\textmu s  & 311{,}519.2 & 2.54\,\textmu s & 979$\times$ \\
    4 & 285.6   & 8{,}705.2\,\textmu s  & 697{,}120.5 & 3.45\,\textmu s & 2{,}440$\times$ \\
    8 & 276.9   & 15{,}651.7\,\textmu s & 986{,}382.9 & 4.60\,\textmu s & 3{,}562$\times$ \\
    \bottomrule
  \end{tabular}
\end{table}
```

## Table B — Tier 2: Multi-Process Shared-Memory Concurrency

**Source**: Host A raw capture; Host B `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md` §2.

| Host | SQLite (4 processes, WAL) | Hamil Substrate (`/dev/shm` ring) | Speedup |
| :--- | ---: | ---: | ---: |
| Host A — Intel Coffee Lake | 225 ops/s (9,425.9 µs) | 4,880 ops/s (12.19 µs) | 21.7x |
| Host B — AMD Zen 4 (Brandys) | 144 ops/s (15,343.8 µs) | 11,459 ops/s (7.02 µs) | 79.7x |

```latex
\begin{table}[htbp]
  \centering
  \caption{Tier 2 --- Multi-process shared-memory concurrency, 4 OS child processes.}
  \label{tab:tables-data-tier2}
  \begin{tabular}{@{}lrrr@{}}
    \toprule
    Host & SQLite (ops/s) & Substrate (ops/s) & Speedup \\
    \midrule
    A --- Intel Coffee Lake & 225 (9{,}425.9\,\textmu s)  & 4{,}880 (12.19\,\textmu s) & 21.7$\times$ \\
    B --- AMD Zen 4 (Brandys) & 144 (15{,}343.8\,\textmu s) & 11{,}459 (7.02\,\textmu s) & 79.7$\times$ \\
    \bottomrule
  \end{tabular}
\end{table}
```

## Table C — Tier 3: 1,000,000-Record Query Traversal

**Source**: Host A `inventory/EVAL-1M-QUERY-BENCH-20260908.md`; Host B `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md` §3.

| Arm | Host | Query Type | QPS | p50 | LLC Misses (5k q) | IPC |
| :--- | :--- | :--- | ---: | ---: | ---: | ---: |
| SQLite B-Tree | A | Point | 70,145.1 | 12,310 ns | 246,845 | 0.87 |
| SQLite Composite B-Tree | A | Multi-constraint | 49,429.3 | 9,729 ns | 197,958 | 0.83 |
| SQLite B-Tree | B (Zen 4) | Point | 200,615.6 | — | — | ~2.1 |
| Hamil Domain Spoke (warm L2) | A | Point | 135,175.4 | 5,956 ns | 46,396 | 1.32 |
| Hamil Domain Spoke (warm L2) | A | Multi-constraint | 80,796.7 | 11,101 ns | 3,656 | 1.43 |
| **Hamil Domain Spoke (warm L2)** | **B (Zen 4)** | **Point** | **381,119.3** | **2,290 ns** | **0** | **2.90** |

```latex
\begin{table}[htbp]
  \centering
  \caption{Tier 3 --- 1,000,000-record query traversal, SQLite B-tree vs.\ Hamil domain spoke.}
  \label{tab:tables-data-tier3}
  \begin{tabular}{@{}llrrrr@{}}
    \toprule
    Arm & Host & Query & QPS & p50 & IPC \\
    \midrule
    SQLite B-Tree & A & Point & 70{,}145.1 & 12{,}310\,ns & 0.87 \\
    SQLite Composite B-Tree & A & Multi & 49{,}429.3 & 9{,}729\,ns & 0.83 \\
    SQLite B-Tree & B (Zen 4) & Point & 200{,}615.6 & --- & $\sim$2.1 \\
    Hamil Domain Spoke & A & Point & 135{,}175.4 & 5{,}956\,ns & 1.32 \\
    Hamil Domain Spoke & A & Multi & 80{,}796.7 & 11{,}101\,ns & 1.43 \\
    \textbf{Hamil Domain Spoke} & \textbf{B (Zen 4)} & \textbf{Point} & \textbf{381{,}119.3} & \textbf{2{,}290\,ns} & \textbf{2.90} \\
    \bottomrule
  \end{tabular}
\end{table}
```

## Table D — Tier 4: Tail Latency & Spoke-Locality Jitter (Host A)

**Source**: `inventory/EVAL-1M-QUERY-BENCH-20260908.md` §2.1–§2.2.

| Arm | p90 | p99 | p99.9 (tail) |
| :--- | ---: | ---: | ---: |
| SQLite Composite B-Tree | 11,008 ns | 31,958 ns | 3,112,396 ns |
| Hamil Domain Spoke (SIMD) | 11,688 ns | 16,935 ns | 42,913 ns |

```latex
\begin{table}[htbp]
  \centering
  \caption{Tier 4 --- Tail latency (multi-constraint query), Host A.}
  \label{tab:tables-data-tier4}
  \begin{tabular}{@{}lrrr@{}}
    \toprule
    Arm & p90 & p99 & p99.9 \\
    \midrule
    SQLite Composite B-Tree & 11{,}008\,ns & 31{,}958\,ns & 3{,}112{,}396\,ns \\
    Hamil Domain Spoke (SIMD) & 11{,}688\,ns & 16{,}935\,ns & 42{,}913\,ns \\
    \bottomrule
  \end{tabular}
\end{table}
```

## Table E — Frontier 3: Physical AMD XDNA NPU Silicon Streaming (Host B)

**Source**: `inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md`, N = 100,000 cells.

| Metric | Value |
| :--- | ---: |
| Total transferred data | 3.48 GB |
| Total stream duration | 27.44 ms |
| Throughput | 3,644,530 cells/sec |
| Bidirectional bandwidth | **118.174 GiB/s** |
| Mean DMA latency | 252.686 ns |
| p50 / p95 / p99 / max latency | 250 / 270 / 320 / 13,531 ns |
| Thermal delta (CPU) | 0.0°C |
| GPU wakes | 0 / 100,000 |

```latex
\begin{table}[htbp]
  \centering
  \caption{Frontier 3 --- Physical AMD XDNA NPU bidirectional DMA streaming (Host B, N=100{,}000 cells).}
  \label{tab:tables-data-frontier3}
  \begin{tabular}{@{}lr@{}}
    \toprule
    Metric & Value \\
    \midrule
    Throughput            & 3{,}644{,}530 cells/s \\
    Bidirectional bandwidth & \textbf{118.174 GiB/s} \\
    Mean DMA latency       & 252.686\,ns \\
    p99 latency            & 320\,ns \\
    Thermal delta (CPU)    & 0.0\textdegree C \\
    GPU wakes              & 0 / 100{,}000 \\
    \bottomrule
  \end{tabular}
\end{table}
```

## Table F — Frontier 4: Grand Fusion Composed Intent Loop

**Source**: `inventory/EVAL-GRAND-FUSION-BENCH-20260908.md`, N = 100,000 full cycles, `ReleaseFast`.

| Metric | Value |
| :--- | ---: |
| End-to-end latency | **894.35 ns/cycle** |
| Throughput | **1,118,133 cycles/sec** (1.12 Mops/s) |
| GPU happy-path skips | 100,000 / 100,000 (100.00%) |
| Dynamic heap allocation | 0 bytes |
| Cell / header geometry | 17,408 B / 64 B |
| Hop-limit circuit breaker | Hop 5 refused (Invariant A-11) |

```latex
\begin{table}[htbp]
  \centering
  \caption{Frontier 4 --- Grand Fusion end-to-end composed intent loop (N=100{,}000 cycles).}
  \label{tab:tables-data-frontier4}
  \begin{tabular}{@{}lr@{}}
    \toprule
    Metric & Value \\
    \midrule
    End-to-end latency        & \textbf{894.35\,ns/cycle} \\
    Throughput                & \textbf{1{,}118{,}133 cycles/s} \\
    GPU happy-path skips      & 100{,}000 / 100{,}000 (100.00\%) \\
    Dynamic heap allocation   & 0 bytes \\
    Hop-limit circuit breaker & Hop 5 refused (Invariant A-11) \\
    \bottomrule
  \end{tabular}
\end{table}
```

## Table G — Master Summary Across All Four Open Rectangles

**Sources**: as listed in the rightmost column. Rectangle 1/2 figures restated from their own proof files (Seat 0/Seat 3 authorship territory) for cross-comparison only; full methodology is documented in `research/sections/01_introduction.md` and `research/sections/03_spoke_manifold_and_sidecar.md`.

| Rectangle | Mechanism | Headline Throughput | Headline Latency | Source |
| :--- | :--- | ---: | ---: | :--- |
| 1 — GBNF Intake Token Masking | Compile-time grammar mask stamps the 64B header at intake | 2,071,574 triples/sec | 482.72 ns/triple | `inventory/EVAL-GBNF-INTAKE-BENCH-20260908.md` |
| 2 — Deterministic Context Assembly | Content-addressed, byte-stable JSON boot packs | 5,408 packs/sec | 184.91 µs/pack | `inventory/EVAL-DETERMINISTIC-CONTEXT-ASSEMBLY-20260908.md` |
| 3 — Physical XDNA NPU Streaming | Bidirectional DMA of 17,408B cells | 3,644,530 cells/sec | 252.69 ns/cell (118.17 GiB/s) | `inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md` |
| 4 — Grand Fusion Composed Loop | Stages 1–5 fused into one intent cycle | 1,118,133 cycles/sec | 894.35 ns/cycle | `inventory/EVAL-GRAND-FUSION-BENCH-20260908.md` |

```latex
\begin{table}[htbp]
  \centering
  \caption{Master summary across all four Open Rectangles.}
  \label{tab:tables-data-master-summary}
  \begin{tabular}{@{}p{0.30\linewidth}p{0.34\linewidth}rr@{}}
    \toprule
    Rectangle & Mechanism & Throughput & Latency \\
    \midrule
    1 --- GBNF Intake        & Grammar mask stamps 64B header       & 2{,}071{,}574 triples/s & 482.72\,ns \\
    2 --- Context Assembly   & Content-addressed JSON boot packs    & 5{,}408 packs/s         & 184.91\,\textmu s \\
    3 --- XDNA NPU Streaming & Bidirectional DMA of 17{,}408B cells & 3{,}644{,}530 cells/s   & 252.69\,ns \\
    4 --- Grand Fusion       & Stages 1--5 fused into one cycle     & 1{,}118{,}133 cycles/s  & 894.35\,ns \\
    \bottomrule
  \end{tabular}
\end{table}
```

**Disk-first note on Rectangle 1**: an earlier council directive's summary prose cited Rectangle 1 at "1.57 Mcells/sec, 634.76 ns stamping." The committed proof file (`inventory/EVAL-GBNF-INTAKE-BENCH-20260908.md` §3) instead measures relation GBNF evaluation (381.53 ns/token, 2,621,025 tokens/s), identifier validation (10.29 ns/id), and end-to-end triple stamping (482.72 ns/triple, 2,071,574 triples/s) — none of which is "1.57 Mcells/sec / 634.76 ns." Table G reports the proof file's own numbers, not the directive summary's, per the Disk-First Grounded Evidence invariant: the source on disk governs when the two disagree.

## Table H — Tokenizer / Inference Boundary Summary

**Sources**: `inventory/EVAL-TOKENIZER-CORPUS-BPE-20260908.md`, `inventory/EVAL-LEXICON-COLLAPSE-BENCH-20260908.md`, `inventory/EVAL-LLAMACPP-TOKENIZER-BENCH-20260908.md`. Restated from `06_empirical_data_appendix.md` §6.1 for a single self-contained tables file.

| Measurement | Verbose / baseline | Pre-interpreted / substrate | Interpretation |
| :--- | ---: | ---: | :--- |
| llama.cpp prompt tokens (mean, N=100) | 69.87 | 23.38 | 2.99× measured reduction |
| llama.cpp prefill latency (mean, N=100) | 141.10 ms | 74.12 ms | 1.90× measured improvement |
| Native Zig collapse (N=1,000) | — | 3,903.6 ns/proposition | 256,174.4 propositions/s |
| Gemma / Qwen BPE tokens (N=100 corpus) | 6,887 / 6,805 | 100 × 64B headers | 68.87× / 68.05× expansion |

```latex
\begin{table}[htbp]
  \centering
  \caption{Tokenizer / inference boundary summary.}
  \label{tab:tables-data-tokenizer}
  \begin{tabular}{@{}lrrl@{}}
    \toprule
    Measurement & Baseline & Substrate & Interpretation \\
    \midrule
    Prompt tokens (mean, N=100)   & 69.87    & 23.38  & 2.99$\times$ reduction \\
    Prefill latency (mean, N=100) & 141.10\,ms & 74.12\,ms & 1.90$\times$ improvement \\
    \bottomrule
  \end{tabular}
\end{table}
```

---

## Provenance Index

| Table | Proof File(s) |
| :--- | :--- |
| A (Tier 1) | `inventory/EVAL-SQLITE-SIDECAR-BENCH-20260908.md` |
| B (Tier 2) | `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md` |
| C (Tier 3) | `inventory/EVAL-1M-QUERY-BENCH-20260908.md`, `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md` |
| D (Tier 4) | `inventory/EVAL-1M-QUERY-BENCH-20260908.md` |
| E (Frontier 3) | `inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md` |
| F (Frontier 4) | `inventory/EVAL-GRAND-FUSION-BENCH-20260908.md` |
| G (Master Summary) | All four proof files above the fold in this index |
| H (Tokenizer) | `inventory/EVAL-TOKENIZER-CORPUS-BPE-20260908.md`, `inventory/EVAL-LEXICON-COLLAPSE-BENCH-20260908.md`, `inventory/EVAL-LLAMACPP-TOKENIZER-BENCH-20260908.md` |

No table in this file was generated from a directive summary or from memory; every cell traces to a specific committed `proof/EVAL-*.md` file, consistent with `05_empirical_evaluation.md` §5.6's Data Provenance policy.
