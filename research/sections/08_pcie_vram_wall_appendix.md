# 8. Appendix — Overcoming the PCIe & VRAM Wall: Pre-Interpreted Cellular Memory vs. Tensor KV-Cache in Hybrid Consumer-Grade Architectures

**Lead author of the architecture under review**: Christopher Hamil  
**This section (systems theory and cross-domain grounding)**: Council Seat 0 (`council-claude`)  
**Grounding files (disk-first)**: `src/geometry.zig`, `src/ipc_ring.zig`, `src/mcp_bridge.zig`, `src/lexicon.zig`, `inventory/EVAL-LEXICON-COLLAPSE-BENCH-20260908.md`  
**Cross-seat inputs (not re-run on this branch; cited by their own proof artifacts)**: `inventory/EVAL-TOKENIZER-CORPUS-BPE-20260908.md` (Council Seat 1, `council-grok`), `inventory/EVAL-LLAMACPP-TOKENIZER-BENCH-20260908.md` (Council Seat 2, `council-sonnet`)  
**Citation index**: `research/references.bib`

Section 7 places the Hamil Memory Controller against forty years of *database* systems. This appendix places it against a narrower, more recent target: the memory-bandwidth ceiling that a consumer-grade host hits when it tries to run large-language-model inference with any layers offloaded off the accelerator (`llama.cpp`'s `-ngl`), and the specific hazards a 2022 database-systems paper raised against using `mmap` as a storage engine's primary access path. The claim under test is narrow and falsifiable: **does A-1/A-2 cellular geometry avoid the hazards `mmap`-as-buffer-manager was criticized for, and does collapsing a proposition to a 64-byte header actually reduce the memory traffic a transformer's KV cache would otherwise need — measured, not assumed?**

---

## 8.1 The hybrid latency bubble

A datacenter accelerator (e.g. an H100 at roughly 3.35 TB/s HBM3 bandwidth) can stream a transformer's per-token KV-cache growth — commonly on the order of 100+ KB/token for a 7–8B-class dense/GQA model at F16 (§8.4 derives this exactly) — without the memory system becoming the bottleneck. Consumer hardware does not have that headroom: JEDEC-rated dual-channel DDR4 tops out at roughly 17–25 GB/s of realized bandwidth, and PCIe Gen3/Gen4 x16 links run at roughly 8–16 GB/s of achievable host-to-device throughput. Neither figure is measured on this host in `proof/` — they are cited as published platform specifications, not benchmark results, and are flagged as such deliberately, per the "Disk-First Evidence" invariant. When `llama.cpp`'s `-ngl` splits a model's layers between a small consumer GPU and host RAM, every KV-cache byte that belongs to an off-GPU layer has to cross that DDR4/PCIe path once per token generated. This is the "hybrid latency bubble": the datacenter memory-bandwidth budget the model's KV-cache growth rate assumes does not exist on the hardware actually running it.

Two independent, real measurements in this repository speak to the two halves of that bubble without needing to reproduce it directly:

1. `inventory/EVAL-LLAMACPP-TOKENIZER-BENCH-20260908.md` (Seat 2) measures, on a physical GTX 1060 Max-Q host across the canonical N=100 corpus, that compact A-2 prompt tuples reduce `llama-cli`'s own prefill latency by **1.90×** (141.10 ms $\to$ 74.12 ms) and its token count / KV-cache growth by **2.99×** (69.87 $\to$ 23.38 tokens) (§8.4) — real, on-metal effects of feeding the same unmodified engine less to stream, with no Hamil-substrate code involved at all.
2. `inventory/EVAL-LEXICON-COLLAPSE-BENCH-20260908.md` (Seat 0) measures that the Hamil substrate's own collapse pipeline needs none of that per-token streaming in the first place: a proposition becomes a fixed 64 bytes once, regardless of length (§8.4).

Neither report claims to have measured the DDR4/PCIe ceiling directly; both are consistent with it being real, and §8.4 makes the chain from "shorter input" to "smaller KV cache" to "the substrate's own fixed-64-byte alternative" explicit and separately sourced at each link.

---

## 8.2 The CIDR 2022 critique, named

Crotty, Leis, and Pavlo's "Are You Sure You Want to Use MMAP in Your Database Management System?" [crotty2022mmap] argues that `mmap`-as-storage-engine — letting the kernel's page cache stand in for a database's buffer manager — is a persistent-enough anti-pattern to warrant naming, because it reintroduces four hazards a hand-rolled buffer manager exists specifically to avoid:

1. **Uncontrolled kernel page eviction.** The kernel, not the database, decides which dirty or clean pages get reclaimed under memory pressure, with no knowledge of the database's own access patterns or transaction boundaries.
2. **Synchronous page-fault stalls.** A page fault on a `mmap`'d region blocks the faulting thread inside the kernel; there is no way to issue an async prefetch and continue other work the way an explicit buffer-pool `read()` can be overlapped.
3. **TLB shootdowns.** Concurrent writers that cause the kernel to remap or invalidate pages (copy-on-write, `munmap`, page reclaim) force a TLB invalidation IPI to every core that mapped the region — a scalability cost that grows with core count, not something a well-designed buffer pool pays.
4. **No transactional safety.** `mmap` gives no control over *when* a dirty page reaches disk; a naive `mmap`-as-storage engine cannot implement WAL-ordered durability without additional machinery layered back on top, at which point most of `mmap`'s simplicity advantage is gone.

The paper's target is a specific pattern — a multi-gigabyte, larger-than-RAM database file `mmap`'d directly as the engine's working set — not `mmap` as a system call in general. That distinction matters for §8.3.

---

## 8.3 What the substrate answers, hazard by hazard — and what it does not yet

`src/ipc_ring.zig`'s `SharedMemoryRegion.open` does call `std.posix.mmap(..., .{ .TYPE = .SHARED }, ...)` against a `/dev/shm`-backed file (`DEFAULT_SHM_PATH`), and `src/mcp_bridge.zig` separately `mmap`s the persisted cell bank at `db/zk_cells.bin` for sweep queries. Both are real, on-disk-verifiable uses of `mmap` in this codebase — but they are not the same case, and conflating them would overstate the claim:

### Table 8.3 — CIDR 2022 hazard mapping

| CIDR 2022 hazard | `SharedMemoryRegion` (`src/ipc_ring.zig`, `/dev/shm`) | `mcp_bridge.zig` sweep of `db/zk_cells.bin` |
| :--- | :--- | :--- |
| Uncontrolled kernel eviction | Backed by `tmpfs`, sized once at creation (`DEFAULT_SHM_RING_CAPACITY = 128` slots, ~2.1 MB) and never larger than physical RAM by construction — there is no "larger than RAM, kernel picks what to evict" scenario for this file. | An ordinary regular-file `mmap`. Nothing in `src/*.zig` calls `madvise` to pin, hint, or otherwise influence eviction for this mapping — the directive's claim of `MADV_WILLNEED`/`MADV_HUGEPAGE` use is **not present in source** as of this commit. This hazard is open, not closed, for the on-disk cell bank. |
| Synchronous page-fault stalls | Same reasoning: a `tmpfs` page that has never been swapped is already resident: a fault here is a first-touch mapping-table fault, not an I/O-bound one. | Not mitigated. A cold page fault against `db/zk_cells.bin` on a real block device still blocks the faulting thread exactly as [crotty2022mmap] describes; no async prefetch path exists in this codebase today. |
| TLB shootdowns | The region is `MAP.SHARED`, fixed-size, and mutated via in-place seqlock/CAS writes to already-mapped pages (`alloc_cursor` `cmpxchgWeak`, per §2.3 of this whitepaper) — not COW, not `mprotect`, not remapping. There is no repeated remap/unmap traffic on the hot path to trigger shootdowns. This is a structural argument from the code's mutation pattern, **not an independently measured IPI count** — no `proof/` artifact instruments TLB shootdown counters in this repository. | Same structural argument applies (sweep is read-only against an already-mapped region), with the same caveat: unmeasured. |
| No transactional safety | Correct as stated, and not disputed: nothing in `src/ipc_ring.zig` or `src/geometry.zig` provides ACID durability on its own. Section 7.1/7.5 already give the actual answer — durability and transactional semantics are the **Semantic Sidecar**'s job (`src/sqlite_sidecar.zig`, `BEGIN IMMEDIATE … COMMIT` against `sidecar_records`), deliberately kept off the cellular hot path rather than bolted onto the `mmap` region itself. | Same answer applies: the sidecar, not the mapped cell bank, is where transactional guarantees live. |

The honest summary: the `/dev/shm` IPC ring sidesteps hazards 1–2 by being small, `tmpfs`-backed, and pre-sized rather than by any explicit kernel hinting — and the operational directive's specific claim of `madvise(MADV_HUGEPAGE)` / `MADV_WILLNEED` pinning does not currently exist in `src/*.zig`. That is a real gap between the council directive's framing and the repository's actual state, flagged here in the same spirit Section 7.4 flags RFC-0001 figures absent from `proof/`: **numbers and mechanisms not on disk are not claimed as verified.** Adding `madvise` hints to `SharedMemoryRegion.open` and to the `db/zk_cells.bin` sweep path is the concrete, scoped follow-up this appendix recommends — not a re-statement of a mitigation that does not yet exist in code.

---

## 8.4 The KV-cache-vs-cell comparison chain, sourced link by link

Three separate, independently measured claims chain together into the directive's headline ratio. Each is sourced to the branch and file that actually produced it — merged into `council/agy` and cross-verified per `proof/`:

**Link 1 — real corpus, real tokenizers (Seat 1, `inventory/EVAL-TOKENIZER-CORPUS-BPE-20260908.md`, on `council/grok`).** A 100-proposition, 4,766-English-word evaluation corpus, tokenized by the real on-disk GGUF vocabularies (`vocab_only=True`, no Ollama, Invariant 12) for `gemma-4-E2B_q4_0-it.gguf` and `Qwen2.5-Coder-7B-Instruct-Q6_K.gguf`, BPE-fragments into 6,887 and 6,805 tokens respectively — a **68.87×** (Gemma) / **68.05×** (Qwen) expansion in token count versus one 64-byte A-2 header per proposition (100 × 64 B = 6,400 B).

**Link 2 — real hardware, real `llama-cli` (Seat 2, `inventory/EVAL-LLAMACPP-TOKENIZER-BENCH-20260908.md`, on `council/sonnet`).** Running actual `llama-cli` inference on the canonical N=100 proposition corpus (200 invocations, uncontended re-runs on metal) against `gemma-4-E2B_q4_0-it.gguf` on a physical GTX 1060 Max-Q, compact-tuple prompts measure **2.99× fewer prompt tokens** (69.87 $\to$ 23.38) and **1.90× faster prefill latency** (141.10 ms $\to$ 74.12 ms) than verbose-prose prompts — engine-reported, not derived. The report explicitly flags two honest null results (raw t/s is *lower*, not higher, for short prompts at this size; host RSS/VRAM show no measurable delta at `-n 4`) rather than omitting the parts of the data that complicate the headline number.

**Link 3 — real Zig pipeline vs. theoretical KV-cache footprint (Seat 0, `inventory/EVAL-LEXICON-COLLAPSE-BENCH-20260908.md`, this branch).** `zig build bench-lexicon-collapse` (ReleaseFast) measures the substrate's own scan → phonetic-map → collapse pipeline (`src/simd_lexer.zig`, `src/b2b_pack.zig`, `src/lexicon.zig`) at **3,903.6 ns/proposition** (256,174 propositions/sec) for N=1,000, producing exactly **64,000 bytes** of resident output. Against the KV-cache footprint those same 1,000 propositions would occupy in an unmodified transformer — using GGUF-metadata-extracted architecture constants, not assumed ones — the reduction is **62,720×** (Qwen2.5-Coder-7B, real config) to **143,360×** (the directive's own 128 KiB/token reference baseline), with the mid-range figure at $T{=}70$ tokens/proposition given as the headline.

**Where the ratios come from, and where they don't.** Link 1 and Link 3's headline multiples (68×, 62,720–143,360×) are both **derived from real, extracted GGUF metadata and a real measured pipeline** — but neither is a single end-to-end benchmark run; they are two halves of the same comparison (token-count expansion, then byte-footprint-per-token) computed separately and multiplied, exactly as Seat 2's §6.2 makes explicit for its own **143,094×** cross-system figure: $\frac{69.87 \text{ tok} \times 131{,}072\text{ B/tok}}{64\text{ B}} \approx 143{,}094\times$ compares llama.cpp's *own measured* Arm-A token count against the Hamil substrate's *own measured* header size — a legitimate architectural-constant comparison, and, as Seat 2's report states in its own words, "not a measurement this llama-cli harness performed." Link 2's 2.99×/1.90× are the only figures in this chain that are direct, single-run, on-metal measurements with no cross-system arithmetic involved.

---

## 8.5 Gegenrede (systems architect, both directions)

> *Two objections, not one. First: the CIDR 2022 paper is about multi-gigabyte database files larger than RAM under real memory pressure — your `/dev/shm` ring is a few megabytes and never leaves `tmpfs`. You have not answered the paper's hazards; you have picked a use case small enough that the hazards don't apply. Second: a KV cache stores an arbitrary continuation of natural language: it can represent anything the model has ever seen. Your 64-byte header can only represent what `src/lexicon.zig`'s closed vocabulary and `MinimalPerfectHash` already know how to name. The ratio is real, but it is a ratio between a general-purpose representation and a closed one — of course the closed one is smaller.*

Both objections are correct, and Section 8.3/8.4 already contain the evidence for them rather than hiding it:

1. **The small-mapping objection stands for `/dev/shm`, and does not yet have an answer for `db/zk_cells.bin`.** The IPC ring's safety from eviction and fault stalls is a consequence of being small and `tmpfs`-backed, not of any kernel-hinting mechanism this codebase implements — Table 8.3 says so directly. The on-disk cell bank `mmap`'d in `src/mcp_bridge.zig` *is* the CIDR paper's actual target case (a regular file, potentially larger than a single working set), and it currently has **no** `madvise`-based mitigation. Claiming victory over [crotty2022mmap] on the strength of the `/dev/shm` ring alone would be answering the easy half of the objection and staying silent on the hard half; this appendix answers the easy half and marks the hard half open.
2. **The closed-vocabulary objection is not a flaw to argue away — it is the actual shape of the claim.** Nothing in `src/lexicon.zig`, `src/simd_lexer.zig`, or the A-2 header format lets the substrate collapse a proposition it cannot parse into `SentenceRow`'s `term_a | relation_op | target_val | provenance` shape. The 62,720–143,360× figure is a real reduction **for the class of proposition the closed grammar already covers**, exactly the same way a schema'd relational column beats a `TEXT` blob for a value the schema already typed. Section 7.5's Gegenrede makes the identical move for JOINs against the operational tier: the sidecar handles what the hot path structurally cannot, and the honest scope statement here is that the Hamil substrate is not proposed as a drop-in KV-cache replacement for arbitrary generative continuation — it is proposed as the representation for the subset of inference-adjacent state that is already closed-grammar structured data wearing natural-language clothing (the census/legal/operational domains Seat 1's corpus and Seat 2's bench both draw from).

The open loop this Gegenrede leaves for a later RFC: instrument `madvise(MADV_WILLNEED)` / huge-page hints on the `db/zk_cells.bin` sweep path and re-run [crotty2022mmap]'s page-fault-stall scenario against it directly (a synthetic larger-than-RAM cell bank under memory pressure), so hazard 1–2 in Table 8.3's second column moves from "open" to a disk-first measured verdict.

---

## 8.6 Attribution

The hybrid-latency-bubble framing, the hazard-by-hazard mapping against [crotty2022mmap], and the cross-seat citation chain in §8.4 are Council Seat 0's (`council-claude`) synthesis for this directive. The underlying inventions being evaluated — Invariant A-1, Invariant A-2, the Semantic Sidecar, `src/lexicon.zig`'s closed-grammar collapse — remain Christopher Hamil's, per Section 7.6. Seat 1's evaluation corpus and Seat 2's `llama-cli` benchmark are their own attributed deliverables, cited here, not re-authored here.

Cite this appendix as [hamil2026pciewall].

---

## Link proposer

- **Links**: Section 7 (relational tax / Gegenrede structure this appendix mirrors); RFC-0001; `src/ipc_ring.zig`; `src/mcp_bridge.zig`; `src/lexicon.zig`; [crotty2022mmap]; [hamil2026lexiconcollapse]; [hamil2026tokenizercorpus]; [hamil2026llamacppbench].
- **Keywords**: hybrid latency bubble, `-ngl` layer offload, KV cache, `mmap` hazards, `madvise`, closed-grammar collapse, cross-seat provenance.
- **Gegenrede (open)**: Re-run [crotty2022mmap]'s eviction/page-fault scenario directly against a synthetic larger-than-RAM `db/zk_cells.bin`, with and without `madvise` hints, to close the hazard-1/2 gap this appendix leaves open in §8.3/§8.5.

## Validation (Luhmann)

| Principle | Status |
| :--- | :--- |
| Atomicity | This appendix is readable on its own given [crotty2022mmap], the three cited `proof/` files, and Section 7's Gegenrede pattern it reuses. |
| Connectivity | ≥2 links: Section 7's structure and attribution; the CIDR-2022-vs-`SharedMemoryRegion` hazard table; the three-link KV-cache citation chain. |
| Organic growth | No new taxonomy invented beyond `research/references.bib`'s existing `hamil2026*` proof-artifact convention. |
| Continued dialogue | `madvise`/huge-page gap on `db/zk_cells.bin` left explicitly open for a later RFC, not asserted as closed. |
