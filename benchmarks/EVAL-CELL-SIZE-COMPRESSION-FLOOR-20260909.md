# EVAL — the compression floor, and where 17,408 B sits on it

**Date**: 2026-09-09 · **Host**: pop (lab tier — Intel i5-8300H, 8 MiB L3, AVX2, DDR4)
**Harness**: `scratchpad/quant_floor.py` (zlib-9 / lzma-6 / bz2-9, stdlib)
**Corpus**: **8,965,135 B from 1,437 real notes** under `/home/christopherhamil/tot_hybrid/zk/notes` —
his own data, not synthetic.
**Method**: for each candidate cell size, the corpus is cut into chunks of `size − 64 B` and **each
chunk is compressed independently**. A cell cannot borrow context from the cell before it, so
compressing the corpus as one stream would not measure what a cell does. Ragged tails dropped;
220 chunks sampled per size.

## Why this was run

F21 asked whether 17,408 B is the right number. The returned answer recommended **16,384 B**
(§E.9) on page-alignment grounds. Christopher's counter, 2026-09-09:

> *"my main argument to the orginal 17kb was it was the smallest that could be then compressed,
> like quantization"*

and then the derivation itself:

> *"4kb is your normal file, 4x4 16kb i leave extra for crypto"*

**Neither side had measured it.** This is that measurement.

## The derivation, checked

```
page / normal file     4,096 B
4 KiB x 4             16,384 B  = exactly 4 pages
+ crypto headroom      1,024 B  = 16 cache lines
= the cell            17,408 B  = 272 lines            (Invariant A-1)
```

**17,408 is derived, not found.** The headroom is 5.88% of the cell. `zeckendorf_seal: u128`
occupies 16 B of it — 1.6% — leaving 1,008 B (15 lines) for the rest of the crypto material.

## RESULT — compression ratio against cell size

| cell B | payload | zlib-9 | lzma-6 | bz2-9 | vs 17,408 (zlib) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1,024 | 960 | 1.760 | 1.517 | 1.544 | **−55.9%** |
| 2,048 | 1,984 | 1.961 | 1.799 | 1.783 | −50.9% |
| **4,096** | 4,032 | 2.617 | 2.502 | 2.385 | **−34.5%** |
| 8,192 | 8,128 | 3.287 | 3.246 | 3.052 | −17.7% |
| 12,288 | 12,224 | 3.697 | 3.710 | 3.498 | −7.4% |
| **16,384** | 16,320 | 3.904 | 3.963 | 3.753 | **−2.2%** |
| **17,408** | 17,344 | **3.993** | **4.062** | **3.848** | — |
| 20,480 | 20,416 | 4.147 | 4.242 | 4.030 | +3.9% |
| 24,576 | 24,512 | 4.347 | 4.470 | 4.266 | +8.9% |
| 32,768 | 32,704 | 4.676 | 4.847 | 4.656 | +17.1% |
| 65,536 | 65,472 | 4.948 | 5.273 | 5.202 | +23.9% |

### Marginal return, normalised — % ratio gained per % of size added

| step | size +% | ratio +% | **return** |
| :--- | ---: | ---: | ---: |
| 1,024 → 2,048 | 100.0 | 11.42 | 0.114 |
| 2,048 → 4,096 | 100.0 | 33.45 | 0.335 |
| 4,096 → 8,192 | 100.0 | 25.60 | 0.256 |
| 8,192 → 12,288 | 50.0 | 12.47 | 0.249 |
| 12,288 → 16,384 | 33.3 | 5.60 | 0.168 |
| **16,384 → 17,408** | **6.2** | **2.28** | **0.365 ← highest in the table** |
| 17,408 → 20,480 | 17.6 | 3.86 | 0.219 |
| 20,480 → 24,576 | 20.0 | 4.82 | 0.241 |
| 24,576 → 32,768 | 33.3 | 7.57 | 0.227 |
| 32,768 → 65,536 | 100.0 | 5.82 | 0.058 |

## What this settles, and what it does not

**HIS FLOOR CLAIM IS SUPPORTED.** There is a real collapse below the cell. A 4 KiB page-sized cell
— the obvious "clean" choice — loses **34.5%** of the achievable compression on his own notes.
At 1 KiB it loses 55.9%. The floor is not rhetoric; it is a measured cliff.

**THE 16,384 RECOMMENDATION IS MEASURABLY WORSE ON THIS AXIS.** 17,408 beats it by **+2.28%
(zlib), +2.48% (lzma), +2.54% (bz2)** — three independent compressors agreeing. And 16,384 is
exactly his base *before* the crypto headroom, so the recommendation was to delete the 1 KiB he
added deliberately. It optimised page alignment and did not weigh what the cell exists to do.

**THE 16,384 → 17,408 STEP HAS THE HIGHEST NORMALISED RETURN IN THE TABLE** — 0.365% of ratio per
1% of size, against 0.168 for the step before it and 0.219 for the step after. That last KiB is
the best-paying kilobyte in the whole range.

**BUT THE ANSWER IS ALSO PARTLY RIGHT, AND THIS IS THE HONEST HALF.** 17,408 is **not** a maximum.
The curve is still climbing: +3.9% at 20,480, +8.9% at 24,576, **+17.1% at 32,768**. If compression
ratio were the only criterion, a bigger cell wins. 17,408 is defensible as *a floor with crypto
headroom*, **not** as the optimum of this curve. What stops the curve is L1d: at 32,768 B a cell
consumes an entire 32 KiB L1d with zero lines spare, and at 65,536 none fits at all.

**CONTESTED, BOTH CARDS STAND** (rule 3): the answer's page-straddling argument (§E.2) and TLB
claims are **not** tested here and are not refuted by this artifact. This measures one axis —
compression — and on that axis the invariant holds and the recommendation loses.

## Limits of this measurement — stated, not buried

- **zlib/lzma/bz2 are stand-ins.** They are not `immune_compressor.zig`. What the real compressor
  does at each size is `UNKNOWN — needs measurement: run the same sweep through the native
  compressor with sealing on.`
- **Lab tier.** Ratios are data-dependent, not host-dependent, so the numbers should carry across
  the hard barrier — but the *timing* of compression was not measured at all, and that is
  host-dependent and belongs on Brandys.
- **One corpus.** Markdown notes. A different payload kind (embeddings, transaction rows) would
  have a different floor, which is exactly the answer's §E.3 counter-case and remains untested.
- 220 chunks per size; no variance reported. `UNKNOWN — needs measurement: per-chunk distribution
  and whether the 2.3% gap survives a confidence interval.`

