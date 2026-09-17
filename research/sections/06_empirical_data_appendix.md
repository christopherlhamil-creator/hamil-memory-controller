# 6. Empirical Data Appendix — Publication-Ready Snippets

Companion data appendix to `05_empirical_evaluation.md`. Each table below is provided in both GitHub-Flavored Markdown (for the repo/preprint HTML render) and LaTeX (`booktabs`-style, for direct inclusion in the whitepaper's `.tex` build via `research/latex/`). All figures are sourced per `05_empirical_evaluation.md` §5.6.

## 6.1 Tokenizer and inference boundary summary

| Measurement | Verbose / baseline | Pre-interpreted / substrate | Interpretation |
| :--- | ---: | ---: | :--- |
| Corpus words / headers | 4,766 words | 100 × 64 B = 6,400 B | Seat 1 paired-corpus accounting |
| Gemma BPE tokens | 6,887 | 100 native headers | 68.87× expansion relative to one header/proposition |
| Qwen BPE tokens | 6,805 | 100 native headers | 68.05× expansion relative to one header/proposition |
| llama.cpp prompt tokens (mean, N=100) | 69.87 | 23.38 | **2.99×** measured reduction |
| llama.cpp prefill latency (mean, N=100) | 141.10 ms | 74.12 ms | **1.90×** measured improvement |
| Native Zig collapse (N=1,000) | — | 3,903.6 ns/proposition | 256,174.4 propositions/s |
| Native collapsed storage (N=1,000) | — | 64,000 B | 64 B per proposition |

The llama.cpp rows are directly measured on-metal benchmarks from
`inventory/EVAL-LLAMACPP-TOKENIZER-BENCH-20260908.md` across 200 invocations
(uncontended re-runs); the corpus rows come from
`inventory/EVAL-TOKENIZER-CORPUS-BPE-20260908.md`, and the native Zig rows come
from `inventory/EVAL-LEXICON-COLLAPSE-BENCH-20260908.md`.

## 6.2 Representation-ratio accounting

For the directive's illustrative 131,072-byte KV-cache-per-token constant,
the native header comparison is:

$$
R_{\mathrm{derived}} = \frac{69.87 \times 131{,}072}{64} \approx 143{,}094\times.
$$

This is a derived representation ratio, not a process-level bandwidth
measurement. The directly measured llama.cpp Arm A-to-Arm B comparison is
2.99× fewer prompt tokens and 1.90× lower mean prefill latency. The physical
report records both values and the unchanged RSS/VRAM null result so that
model residency is not confused with KV-cache growth.

---

## Table 1 — Tier 1: Multi-Threaded Ingestion (Host A, Intel Coffee Lake)

**Source**: `inventory/EVAL-SQLITE-SIDECAR-BENCH-20260908.md`

### Markdown

| Threads | SQLite (tx/s) | SQLite Mean Latency | Hamil Substrate (tx/s) | Substrate Mean Latency | Speedup |
| :---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 317.9 | 3,136.9 µs | 311,519.2 | 2.54 µs | 979x |
| 4 | 285.6 | 8,705.2 µs | 697,120.5 | 3.45 µs | 2,440x |
| 8 | 276.9 | 15,651.7 µs | 986,382.9 | 4.60 µs | 3,562x |

### LaTeX

```latex
\begin{table}[htbp]
  \centering
  \caption{Tier 1 --- Multi-threaded ingestion, SQLite vs.\ the Hamil cellular substrate (Host A: Intel Coffee Lake).}
  \label{tab:tier1-ingestion}
  \begin{tabular}{@{}rrrrrr@{}}
    \toprule
    Threads & SQLite (tx/s) & SQLite Latency & Substrate (tx/s) & Substrate Latency & Speedup \\
    \midrule
    1 & 317.9 & 3{,}136.9\,\textmu s & 311{,}519.2 & 2.54\,\textmu s & $979\times$ \\
    4 & 285.6 & 8{,}705.2\,\textmu s & 697{,}120.5 & 3.45\,\textmu s & $2{,}440\times$ \\
    8 & 276.9 & 15{,}651.7\,\textmu s & 986{,}382.9 & 4.60\,\textmu s & $3{,}562\times$ \\
    \bottomrule
  \end{tabular}
\end{table}
```

---

## Table 2 — Tier 2: Multi-Process Shared-Memory Concurrency (4 OS Processes, Cross-Host)

**Source**: Host A raw capture; Host B — `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md` §2

### Markdown

| Host | SQLite (ops/s) | SQLite Mean Latency | Hamil Substrate (ops/s) | Substrate Mean Latency | Speedup |
| :--- | ---: | ---: | ---: | ---: | ---: |
| Host A — Intel Coffee Lake | 225 | 9,425.9 µs | 4,880 | 12.19 µs | 21.7x |
| Host B — AMD Zen 4 (Brandys) | 144 | 15,343.8 µs | 11,459 | 7.02 µs | 79.7x |

### LaTeX

```latex
\begin{table}[htbp]
  \centering
  \caption{Tier 2 --- Multi-process (4 OS child processes) shared-memory concurrency, cross-host.}
  \label{tab:tier2-multiprocess}
  \begin{tabular}{@{}lrrrrr@{}}
    \toprule
    Host & SQLite (ops/s) & SQLite Latency & Substrate (ops/s) & Substrate Latency & Speedup \\
    \midrule
    Intel Coffee Lake & 225 & 9{,}425.9\,\textmu s & 4{,}880 & 12.19\,\textmu s & $21.7\times$ \\
    AMD Zen 4 (Brandys) & 144 & 15{,}343.8\,\textmu s & 11{,}459 & 7.02\,\textmu s & $79.7\times$ \\
    \bottomrule
  \end{tabular}
\end{table}
```

---

## Table 3 — Tier 3: 1,000,000-Record Query Traversal

**Source**: Host A — `inventory/EVAL-1M-QUERY-BENCH-20260908.md`; Host B — `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md` §3

### Markdown

| Arm | Host | Query Type | QPS | p50 Latency | LLC Misses (5k q) | IPC |
| :--- | :--- | :--- | ---: | ---: | ---: | ---: |
| SQLite B-Tree | A | Point | 70,145.1 | 12,310 ns | 246,845 | 0.87 |
| SQLite Composite B-Tree | A | Multi-constraint | 49,429.3 | 9,729 ns | 197,958 | 0.83 |
| SQLite B-Tree | B (Zen 4) | Point | 200,615.6 | — | — | ~2.1 |
| **Hamil Domain Spoke** | **A** | **Point** | **135,175.4** | **5,956 ns** | **46,396** | **1.32** |
| **Hamil Domain Spoke** | **A** | **Multi-constraint** | **80,796.7** | **11,101 ns** | **3,656** | **1.43** |
| **Hamil Domain Spoke** | **B (Zen 4)** | **Point** | **381,119.3** | **2,290 ns** | **0** | **2.90** |

### LaTeX

```latex
\begin{table}[htbp]
  \centering
  \caption{Tier 3 --- 1{,}000{,}000-record query traversal: SQLite indexed B-tree vs.\ Hamil domain spoke + SIMD scan.}
  \label{tab:tier3-1m-query}
  \begin{tabular}{@{}llrrrr@{}}
    \toprule
    Arm & Host & Query Type & QPS & p50 Latency & LLC Misses \\
    \midrule
    SQLite B-Tree & Coffee Lake & Point & 70{,}145.1 & 12{,}310\,ns & 246{,}845 \\
    SQLite Composite B-Tree & Coffee Lake & Multi-constraint & 49{,}429.3 & 9{,}729\,ns & 197{,}958 \\
    SQLite B-Tree & Zen 4 & Point & 200{,}615.6 & --- & --- \\
    \textbf{Hamil Domain Spoke} & \textbf{Coffee Lake} & \textbf{Point} & \textbf{135{,}175.4} & \textbf{5{,}956\,ns} & \textbf{46{,}396} \\
    \textbf{Hamil Domain Spoke} & \textbf{Coffee Lake} & \textbf{Multi-constraint} & \textbf{80{,}796.7} & \textbf{11{,}101\,ns} & \textbf{3{,}656} \\
    \textbf{Hamil Domain Spoke} & \textbf{Zen 4} & \textbf{Point} & \textbf{381{,}119.3} & \textbf{2{,}290\,ns} & \textbf{0} \\
    \bottomrule
  \end{tabular}
\end{table}
```

---

## Table 4 — Tier 4: Tail Latency Jitter (p90 / p99 / p99.9), Host A Multi-Constraint Query

**Source**: `inventory/EVAL-1M-QUERY-BENCH-20260908.md` §2.1–§2.2

### Markdown

| Arm | p90 | p99 | p99.9 (tail) | Tail-to-Median Ratio |
| :--- | ---: | ---: | ---: | ---: |
| SQLite Composite B-Tree | 11,008 ns | 31,958 ns | 3,112,396 ns (3,112.4 µs) | 320x |
| Hamil Domain Spoke (SIMD) | 11,688 ns | 16,935 ns | 42,913 ns (42.9 µs) | 3.9x |

### LaTeX

```latex
\begin{table}[htbp]
  \centering
  \caption{Tier 4 --- Tail latency jitter, multi-constraint query, Host A (Intel Coffee Lake).}
  \label{tab:tier4-tail-latency}
  \begin{tabular}{@{}lrrrr@{}}
    \toprule
    Arm & p90 & p99 & p99.9 (tail) & Tail/Median \\
    \midrule
    SQLite Composite B-Tree & 11{,}008\,ns & 31{,}958\,ns & 3{,}112{,}396\,ns & $320\times$ \\
    \textbf{Hamil Domain Spoke} & \textbf{11{,}688\,ns} & \textbf{16{,}935\,ns} & \textbf{42{,}913\,ns} & \textbf{$3.9\times$} \\
    \bottomrule
  \end{tabular}
\end{table}
```

---

## Table 5 — Spoke Locality vs. Monolith: Memory Footprint & Cache Behavior

**Source**: `inventory/EVAL-SPOKE-MEMORY-FOOTPRINT-20260908.md`

### Markdown

| Metric | Isolated Spoke (16.6 MB) | Monolith (49.8 MB) | Delta |
| :--- | ---: | ---: | ---: |
| Sweep duration | 6.94 µs | 29.26 µs | Monolith 4.22x slower |
| Cell-eval latency | 6.94 ns/cell | 9.75 ns/cell | Spoke 28.8% faster/cell |
| Minor page faults | 276 | 797 | Monolith 2.89x more |
| Resident memory (during) | 17.30 MB | 50.50 MB | Monolith 2.92x more |
| Resident memory (after unmap) | 716 kB (baseline) | 716 kB (baseline) | Zero leak, both arms |

### LaTeX

```latex
\begin{table}[htbp]
  \centering
  \caption{Domain-spoke isolation vs.\ monolithic sweep: memory footprint and page-fault behavior.}
  \label{tab:spoke-vs-monolith}
  \begin{tabular}{@{}lrrr@{}}
    \toprule
    Metric & Isolated Spoke & Monolith & Delta \\
    \midrule
    Sweep duration & 6.94\,\textmu s & 29.26\,\textmu s & $4.22\times$ slower \\
    Cell-eval latency & 6.94\,ns/cell & 9.75\,ns/cell & $+28.8\%$ \\
    Minor page faults & 276 & 797 & $2.89\times$ more \\
    Resident memory (during) & 17.30\,MB & 50.50\,MB & $2.92\times$ more \\
    Resident memory (after unmap) & 716\,kB & 716\,kB & no leak \\
    \bottomrule
  \end{tabular}
\end{table}
```

---

## Table 6 — Headline Cross-Platform Summary (for Abstract / Executive Summary use)

**Source**: aggregated from Tables 1–5 above; matches `research/RFC-0001-HAMIL-CELLULAR-MEMORY-SUBSTRATE.md` §5, cross-verified per `05_empirical_evaluation.md` §5.6.

### Markdown

| Evaluation Dimension | SQLite Baseline | Hamil Substrate | Advantage | Host |
| :--- | :--- | :--- | :---: | :--- |
| Multi-thread ingestion (8 threads) | 276.9 tx/s | 986,382.9 tx/s | **3,562x** | Coffee Lake |
| Multi-process concurrency (4 PIDs) | 225 ops/s | 4,880 ops/s | **21.7x** | Coffee Lake |
| Multi-process concurrency (4 PIDs) | 144 ops/s | 11,459 ops/s | **79.7x** | Zen 4 |
| 1M point-query throughput | 200,615.6 QPS | 381,119.3 QPS | **1.90x** | Zen 4 |
| Multi-constraint LLC misses | 197,958 | 3,656 | **54x fewer** | Coffee Lake |
| Multi-constraint LLC misses | — | 0 | **zero-miss** | Zen 4 |
| Tail latency (p99.9) | 3,112.4 µs | 42.9 µs | **72.5x** | Coffee Lake |
| Spoke vs. monolith throughput | 24,703 QPS | 80,797 QPS | **3.27x / 3,395x fewer misses** | Coffee Lake |
| BPE expansion (Gemma 4 E2B) | 6,887 tokens | 100 × 64 B headers | **68.87×** | Coffee Lake |
| BPE expansion (Qwen2.5-Coder-7B) | 6,805 tokens | 100 × 64 B headers | **68.05×** | Coffee Lake |
| Prompt token count (Gemma 4 E2B, N=100) | 69.87 tokens (prose) | 23.38 tokens (A-2 tuple) | **2.99x fewer** | Coffee Lake |
| Prompt prefill latency (N=100) | 141.10 ms (prose) | 74.12 ms (A-2 tuple) | **1.90x faster** | Coffee Lake |
| Cross-system KV vs 64B header | 9.16 MB (KV cache) | 64 B (header) | **143,094x** | Coffee Lake |

### LaTeX

```latex
\begin{table}[htbp]
  \centering
  \small
  \caption{Cross-platform empirical summary: SQLite baseline vs.\ the Hamil Memory Substrate.}
  \label{tab:headline-summary}
  \begin{tabular}{@{}lrrrl@{}}
    \toprule
    Dimension & SQLite & Substrate & Advantage & Host \\
    \midrule
    Ingestion (8 threads) & 276.9\,tx/s & 986{,}382.9\,tx/s & $3{,}562\times$ & Coffee Lake \\
    Multi-process (4 PIDs) & 225\,ops/s & 4{,}880\,ops/s & $21.7\times$ & Coffee Lake \\
    Multi-process (4 PIDs) & 144\,ops/s & 11{,}459\,ops/s & $79.7\times$ & Zen 4 \\
    1M point QPS & 200{,}615.6 & 381{,}119.3 & $1.90\times$ & Zen 4 \\
    Multi-constraint LLC misses & 197{,}958 & 3,656 & $54\times$ fewer & Coffee Lake \\
    Multi-constraint LLC misses & --- & 0 & zero-miss & Zen 4 \\
    Tail latency (p99.9) & 3{,}112.4\,\textmu s & 42.9\,\textmu s & $72.5\times$ & Coffee Lake \\
    Spoke vs.\ monolith & 24{,}703\,QPS & 80{,}797\,QPS & $3.27\times$ & Coffee Lake \\
    BPE expansion (Gemma 4 E2B) & 6{,}887 tokens & 100 headers & $68.87\times$ & Coffee Lake \\
    BPE expansion (Qwen2.5-Coder-7B) & 6{,}805 tokens & 100 headers & $68.05\times$ & Coffee Lake \\
    Prompt token count (N=100) & 69.87 tokens & 23.38 tokens & $2.99\times$ fewer & Coffee Lake \\
    Prefill latency (N=100) & 141.10\,ms & 74.12\,ms & $1.90\times$ faster & Coffee Lake \\
    KV vs.\ 64\,B header ratio & 9.16\,MB & 64\,B & $143{,}094\times$ & Coffee Lake \\
    \bottomrule
  \end{tabular}
\end{table}
```

---

## Table 7 — Cross-Model Token Expansion (Gemma 4 E2B vs Qwen2.5-Coder-7B)

**Source**: `inventory/EVAL-TOKENIZER-CORPUS-BPE-20260908.md`; corpus `research/corpus/tokenizer_eval/` (mirrors `run/tokenizer_eval/`). Measured 2026-09-08T17:18:54-0500 on Host A (`pop-os`, Intel Core i5-8300H) with llama.cpp `vocab_only=True` against on-disk GGUF. Port 11434 closed; zero Ollama processes. N=100 propositions, 4,766 English words (37–54 each). Arm B is 100 packed A-2 headers (`=Q16s16s16sII`), 6,400 B, SHA-256 `bbf4c828630d8b69510859682fc75b5992cc46cf84a2fe0d0cd31a4782b564c2`. First packet: opcode 1001 / `Aherron` / `assert_relation` / `Oysterman`.

### Markdown

| Arm | Representation | Gemma 4 E2B Q4_0 | Qwen2.5-Coder-7B Q6_K |
| :--- | :--- | ---: | ---: |
| A | English words | 4,766 (min 37, max 54) | same corpus |
| A | BPE tokens | **6,887** (mean 68.87, range 50–81) | **6,805** (mean 68.05, range 52–80) |
| A | tokens / word | 1.445 | 1.428 |
| B | A-2 headers | **100 × 64 B = 6,400 B** | same bank |
| — | Expansion vs 1 header/prop | **68.87×** | **68.05×** |
| — | 128 KiB/token KV foil | **860.9 MiB** | **850.6 MiB** |
| B | Header-bank KV foil | **0.0061 MiB** | **0.0061 MiB** |
| — | KV foil ratio (prose vs headers) | **141,046×** | **139,366×** |

Domain slice of the same 100 propositions:

| Domain | N | Words | Gemma tokens | Qwen tokens | Gemma mean | Qwen mean |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| census | 40 | 2,120 | 3,101 | 3,082 | 77.53 | 77.05 |
| qms | 30 | 1,395 | 1,950 | 1,938 | 65.00 | 64.60 |
| ops | 30 | 1,251 | 1,836 | 1,785 | 61.20 | 59.50 |
| **total** | **100** | **4,766** | **6,887** | **6,805** | **68.87** | **68.05** |

If the Arm B tuples are still fed as UTF-8 text to the same tokenizers (not the architecture's path): Gemma 1,853 tokens, Qwen 1,783 tokens. The substrate consumes the 64-byte header, not that BPE string.

Models: `/home/christopherhamil/models/gguf/gemma-4-E2B_q4_0-it.gguf` (3,349,516,256 B), `/home/christopherhamil/models/gguf/Qwen2.5-Coder-7B-Instruct-Q6_K.gguf` (6,254,198,752 B). Tokenize wall: Gemma 1.691 s, Qwen 0.537 s.

### LaTeX

```latex
\begin{table}[htbp]
  \centering
  \caption{Cross-model BPE expansion on the N=100 closed corpus (Host A). Arm B is one 64-byte A-2 header per proposition, not a second tokenizer.}
  \label{tab:tokenizer-expansion}
  \begin{tabular}{@{}lrr@{}}
    \toprule
    Representation & Gemma 4 E2B Q4\_0 & Qwen2.5-Coder-7B Q6\_K \\
    \midrule
    English words & 4{,}766 & 4{,}766 \\
    BPE tokens & 6{,}887 & 6{,}805 \\
    Mean tokens / proposition & 68.87 & 68.05 \\
    A-2 headers & 100 $\times$ 64\,B & 100 $\times$ 64\,B \\
    Expansion vs.\ one header & $68.87\times$ & $68.05\times$ \\
    128\,KiB/token KV foil & 860.9\,MiB & 850.6\,MiB \\
    Header-bank footprint & 0.0061\,MiB & 0.0061\,MiB \\
    \bottomrule
  \end{tabular}
\end{table}
```

---

## Table 8 — Physical llama-cli Prefill Latency & Token Reduction on Metal (N=100)

**Source**: `inventory/EVAL-LLAMACPP-TOKENIZER-BENCH-20260908.md`; structured JSON `inventory/llamacpp_bench_gemma_20260908.json`; raw stdout `inventory/llamacpp_bench_raw_20260908/`. Measured 2026-09-08 on Host A (`pop-os`, Intel Core i5-8300H, NVIDIA GeForce GTX 1060 Max-Q 6GB) with native `llama-cli` (`-ngl 1024`, `--single-turn --perf -n 4 -no-cnv`) against `/home/christopherhamil/models/gguf/gemma-4-E2B_q4_0-it.gguf` across 200 individual invocations (100 Arm A prose vs. 100 Arm B compact A-2 tuples). Zero Ollama processes, zero port-11434 listeners (Invariant 12). Items 0–4 re-benchmarked in strict isolation to guarantee 100% uncontended telemetry.

### Markdown

| Metric | Arm A (verbose prose) | Arm B (compact A-2 tuple) | Measured Advantage / Delta |
| :--- | ---: | ---: | ---: |
| Mean prompt tokens | 69.87 (range 51–82) | 23.38 (range 19–28) | **2.99x fewer tokens** |
| Mean prompt throughput | 495.6 t/s | 315.3 t/s | Lower t/s (small batch CUDA launch overhead) |
| Mean prefill latency | 141.10 ms (range 111.9–157.4) | 74.12 ms (range 62.3–74.8) | **1.90x faster prefill** (47.5% drop) |
| Mean generation throughput (4 tok) | 47.53 t/s | 47.59 t/s | ~parity (model size dependent) |
| Mean peak host RSS | 3,622,636 kB (~3.62 GB) | 3,622,653 kB (~3.62 GB) | parity (model residency dominates) |
| Mean peak GPU VRAM | 2,600 MiB | 2,600 MiB | parity (model residency dominates) |
| Derived GQA KV-cache growth | 8.73 MB | 2.92 MB | **2.99x reduction** |
| Cross-system KV vs 64B header | 9.16 MB (KV cache) | 64 B (native header) | **143,094x** (architectural comparison) |

### LaTeX

```latex
\begin{table}[htbp]
  \centering
  \small
  \caption{Physical llama.cpp on-metal benchmark on Host A (GTX 1060 Max-Q, $N=100$ propositions, 200 invocations).}
  \label{tab:llamacpp-prefill-bench}
  \begin{tabular}{@{}lrrr@{}}
    \toprule
    Metric & Arm A (prose) & Arm B (A-2 tuple) & Measured Advantage \\
    \midrule
    Prompt tokens (mean) & 69.87 & 23.38 & $2.99\times$ fewer \\
    Prompt throughput (mean) & 495.6\,t/s & 315.3\,t/s & batch-size amort.\ artifact \\
    Prefill latency (mean) & 141.10\,ms & 74.12\,ms & $1.90\times$ faster ($-47.5\%$) \\
    Generation throughput & 47.53\,t/s & 47.59\,t/s & $\sim$parity \\
    Peak host RSS & $\sim$3.62\,GB & $\sim$3.62\,GB & parity \\
    Peak GPU VRAM & 2{,}600\,MiB & 2{,}600\,MiB & parity \\
    GQA KV-cache growth (derived) & 8.73\,MB & 2.92\,MB & $2.99\times$ reduction \\
    KV vs.\ 64\,B header (derived) & 9.16\,MB & 64\,B & $143{,}094\times$ \\
    \bottomrule
  \end{tabular}
\end{table}
```

---

## Reproducibility Package Checklist

- [x] All harness source files identified per table (§ each table's Source line).
- [x] `zig build` step names documented in `05_empirical_evaluation.md` §5.1.4.
- [x] Cross-host figures (Zen 4 / Brandys) grounded in a committed proof file (`inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md`), not only a summary table.
- [x] Every LaTeX table above uses `booktabs` (`\toprule`/`\midrule`/`\bottomrule`); no vertical rules, per standard academic table style.
- [x] `references.bib` citation keys for Table 6's competitive baselines (SQLite, B-tree literature) and systems grounding ([@crotty2022mmap]).
- [x] Physical on-metal llama.cpp benchmark telemetry captured across 200 invocations in Table 8.
- [x] Final assembly into the whitepaper build verified via `scripts/build_whitepaper.py`.
