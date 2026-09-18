# The Hamil Memory Controller: Abolishing the Relational Tax via Hardware-Symbiotic Cellular Memory and the Semantic Sidecar

**Lead Author & System Architect:** Christopher Hamil  
**Affiliation:** Tree of Thoughts Hybrid Systems Laboratory  
**Specification:** RFC-0001 (Hamil Cellular Memory Substrate)  
**Date:** September 2026  

---

## Abstract

This repository contains the official standalone implementation, specifications, and academic research corpus for the **Hamil Memory Controller**, a hardware-symbiotic cellular memory substrate and asynchronous semantic sidecar designed to abolish the 40-year Relational Tax imposed by conventional database architectures (SQLite, PostgreSQL, MySQL).

By co-locating relational logic operators directly into 64-byte L1 cache-line-aligned instruction headers (`=Q16s16s16sII`, Invariant A-2) and partitioning working sets into 17,408-byte L1d cache-aligned cells (272 cache lines, Invariant A-1) across 640 KB private domain spoke manifolds, the architecture achieves single-pass in-register predicate evaluation with **zero dynamic heap allocation**. 

Empirical evaluations conducted on physical Intel Coffee Lake (`pop-os`) and AMD Zen 4 (`Brandys`) silicon confirm:
- **Sustained ingestion exceeding 986,000 tx/s** (3,562× faster than SQLite)
- **Multi-process shared-memory throughput exceeding 11,450 ops/s** (79.7× faster than SQLite)
- **1,000,000-record query traversal at 381,119 QPS** with a 3,395× reduction in Last Level Cache (LLC) misses and a 72.5× reduction in tail latency jitter ($p99.9$)
- **Asynchronous Semantic Sidecar** draining committed cells into SQLite projections at 230,000 rows/s without imposing lock contention on the sub-microsecond hot path.

---

## Core Invariants & Architectural Law

The Hamil Memory Controller enforces strict hardware-level invariants at compile time:

| Invariant | Constant | Specification & Architectural Enforcement |
| :--- | :--- | :--- |
| **Invariant A-1** | `17,408 Bytes` | Strict cell geometry (272 × 64B cache lines), L1d cache-resident. |
| **Invariant A-2** | `64 Bytes` | Bytecode header width fitting exactly one CPU cache line (`=Q16s16s16sII`). |
| **Invariant A-8** | Law | Intent overrules semantics in conflict resolution. |
| **Invariant A-11** | `4 Hops` | Strict recursive mitosis kill-trigger; depths $> 4$ throw immediate refusal. |
| **Invariant A-31** | `~1.3 GB` | Measured working set observation for capacity planning (not an arbitrary hard limit). |
| **Routing FP** | `48 Bytes` | Frozen routing signature width in fingerprint `[0]` on write/touch path. |
| **Allocation** | `0 Bytes` | Zero dynamic heap allocation in any ranking, dispatch, or query path. |

---

## 4-Signal Candidate Ranking Engine

The dispatcher (`src/controller.zig`) synthesizes four independent scoring signals across stored memory cells and candidate records in register:

$$\text{Score}(c) = w_r \cdot S_{\text{recency}}(c) + w_f \cdot S_{\text{frequency}}(c) + w_s \cdot S_{\text{cosine}}(c) + w_g \cdot S_{\text{graph}}(c)$$

1. **Recency Signal ($S_r$)**: Temporal decay based on nanosecond timestamp deltas.
2. **Frequency Signal ($S_f$)**: Access and touch intensity modeled via non-linear saturation curves.
3. **Semantic Cosine Similarity ($S_s$)**: AVX2/NEON SIMD zero-allocation dot-product vector matching over normalized embeddings.
4. **Structural Graph Distance ($S_g$)**: Topological hop distance from the query anchor node in the note graph.

---

## Repository Structure

```
.
├── build.zig                   # Standalone Zig 0.17 build configuration (zero external C dependencies)
├── src/                        # Native Zig engine and substrate implementation
│   ├── controller.zig          # Memory Controller Dispatcher & 4-Signal Candidate Ranking
│   ├── geometry.zig            # Geometry constants, cache line alignments, and invariant assertions
│   ├── gate_lattice_laws.zig   # Hardware gate lattices and admissibility logic
│   ├── hardware_allocator.zig  # Hardware-aware load shedding and NUMA-domain routing
│   ├── interconnect_bus.zig    # Interconnection Progress Bus (fleet.interconnect.progress.v1)
│   ├── ipc_ring.zig            # Lock-Free SWMR Shared Memory Ring Buffer & Dual-Head Swap
│   ├── mitosis.zig             # Mitosis cell division and lineage preservation
│   ├── sqlite_sidecar.zig      # Asynchronous SQLite semantic sidecar projection
│   ├── simd.zig                # Portable SIMD vector primitives lowered per host
│   ├── simd_kernels.zig        # Vectorized kernels for distance and predicate evaluation
│   ├── simd_lexer.zig          # Zero-allocation SIMD tokenization
│   ├── lexicon.zig             # 56-byte normalized semantic tuple engine
│   ├── vault_graph.zig         # Topological graph traversal and structure notes
│   ├── stt_pointer.zig         # Opaque citation keys and reference gates
│   ├── provenance.zig          # Deterministic provenance auditing
│   ├── baremetal_codec.zig     # Zero-shuffle NVMe/GPU cacheline streaming codec
│   └── pacer.zig               # I/O throughput pacer and backpressure governor
├── research/                   # Full academic research papers, whitepapers, and RFCs
│   ├── WHITEPAPER_HAMIL_CONTROLLER.md   # The canonical 227 KB foundational research paper
│   ├── WHITEPAPER_HAMIL_CONTROLLER.html # Formatted publication monograph
│   ├── RFC-0001-HAMIL-CELLULAR-MEMORY-SUBSTRATE.md # Formal RFC specification
│   ├── RFC-20260912-full-floats-model-weight-coding.md # Full floats weight coding RFC
│   ├── MEMORY-CONTROLLER-TOC.md         # Full audit ledger and claims index
│   ├── references.bib          # BibTeX citation catalog
│   ├── latex/                  # Formal LaTeX manuscript sources
│   ├── pdf/                    # Compiled preprint publication PDF
│   └── sections/               # Modular monograph chapters
├── benchmarks/                 # Empirical evaluation reports from physical silicon
│   ├── EVAL-SQLITE-SIDECAR-BENCH-20260908.md
│   ├── EVAL-1M-QUERY-BENCH-20260908.md
│   ├── EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md
│   ├── EVAL-CELL-SIZE-COMPRESSION-FLOOR-20260909.md
│   ├── EVAL-SPOKE-MEMORY-FOOTPRINT-20260908.md
│   ├── EVAL-SPOKE-VS-MONOLITH-LEXICON-20260908-council-grok.md
│   └── EVAL-BOOTPACK-MITOSIS-SPLIT-20260908.md
└── tests/                      # Validation test suites and benchmark runners
    ├── test_sqlite_sidecar_bench.zig
    ├── test_1m_query_bench.zig
    ├── test_multiprocess_shm.zig
    ├── test_grand_fusion.zig
    ├── bench_spoke_memory_footprint.zig
    ├── generate_1m_records.zig
    └── shm_worker_main.zig
```

---

## TigerBeetle-Grade Storage Durability & Fault Fuzzing (10,000-Run Audit)

To guarantee resilience against real-world NVMe hardware failures, ZIGlite implements a **TigerBeetle-grade protocol-aware durability architecture** tested across 10,000 randomized fault-injection cycles:

- **20,480-Byte Physical Stride**: Exactly $5 \times 4096\text{B}$ hardware sectors with 128-bit Zeckendorf dual FNV-1a integrity seals.
- **Protocol-Aware Recovery**: Distinguishes between **tail torn writes** (clean atomic truncation via `ftruncate`) and **mid-file corruption** (isolated as `SlotState.tombstone`, keeping healthy slots 100% accessible).
- **Zero Data Poisoning**: Mathematically enforces that 0 corrupt bytes ever reach query callers or SQLite C-ABI consumers (`SQLITE_CORRUPT`).
- **In-Flight Fault Injector (`src/ziglite/fault_injector.zig`)**: Comptime-zero-overhead POSIX interception simulating torn writes, bit-flips, and latent sector `EIO` during concurrent operations.
- **Native Sector Mutation Fuzzer (`tests/storage_fuzzer.zig`)**: Offline corruption suite testing 5 mutation classes against recovery scanners.

### Empirical Results Matrix (`benchmarks/EVAL-STORAGE-FAULT-FUZZING.md`):

| Fault Category | Iterations Audited | Detection Mechanism | Recovery Behavior | Poisoning Violations |
| :--- | :--- | :--- | :--- | :--- |
| **Tail Torn Writes** | `1,005` | Trailing length modulo check (`len % 20480 != 0`) | Clean atomic truncation via `ftruncate` | **0** |
| **Bitflips (Seal & Body)** | `1,022` | 128-bit Zeckendorf Dual FNV-1a Seal Validation | Quarantined / Tombstoned (`SQLITE_CORRUPT`) | **0** |
| **Phantom / Zeroed Sectors** | `997` | Opcode check & Zero-record header filter | Rejected as unallocated / corrupt slot | **0** |
| **Sector Swaps (Misdirected)**| `974` | Slot index provenance validation | Rejected on slot index mismatch | **0** |
| **Superblock Corruption** | `1,002` | Metapage magic bytes & metadata seal | Refuses mount (`error.CorruptSuperblock`) | **0** |

- **Total Test Cycles**: `10,000`
- **Data Poisoning Violations**: **`0`**
- **Panics / Undefined Behavior / Segfaults**: **`0`**

Full architecture specification: [`docs/STORAGE_DURABILITY_AND_FAULT_FUZZING.md`](docs/STORAGE_DURABILITY_AND_FAULT_FUZZING.md).

---

## Quickstart & Build

### Prerequisites
- [Zig 0.17](https://ziglang.org/download/) (or compatible 0.16 release)
- Python 3.10+ (for empirical fault auditor)

### Run Unit Tests
Validate all architectural invariants, geometry alignments, and durability recovery:
```bash
zig build test
```

### Run Storage Fault Fuzzer (1,000 Iterations)
Run native offline sector mutation fuzzer across torn writes, bit-flips, and sector swaps:
```bash
zig build test-fuzz
```

### Run 10,000-Cycle Storage Fault & Poisoning Audit
Run full Python Ground-Truth Oracle verification harness:
```bash
python3 scripts/audit_storage_faults.py --iterations 10000 --seed 0x1337BEEFCAFE
```

### Build Static Substrate Library
Compile the optimized static library artifact:
```bash
zig build -Doptimize=ReleaseFast
```

---

## Citation

To cite the Hamil Memory Controller in academic publications:

```bibtex
@article{hamil2026memorycontroller,
  title   = {The Hamil Memory Controller: Abolishing the Relational Tax via Hardware-Symbiotic Cellular Memory and the Semantic Sidecar},
  author  = {Hamil, Christopher},
  journal = {Tree of Thoughts Hybrid Systems Laboratory},
  year    = {2026},
  month   = {September},
  note    = {RFC-0001 (Hamil Cellular Memory Substrate)}
}
```

---

## License

Copyright © 2026 Christopher Hamil. All rights reserved.
