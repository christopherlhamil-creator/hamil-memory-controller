# CITATION-CHECK — P1B answer cards (2026-09-10)

**Routed:** `python3 scripts/doc_route.py "CITATION-CHECK-P1B-ANSWER-20260910.md"` → `research/`
**SoT:** `docs/BLUEPRINT-20260910-INDEPENDENCE-INSTRUMENT-CORRECTED.md` §0.7 (queries recorded 2026-09-10)
**Packet copy (the question, not the answer):** `research/PACKET-P1B-prior-art-signal-independence-20260902.md`
**Original stays:** `~/Documents/PACKET-P1B-prior-art-signal-independence-20260902.md` (read-only; not moved, not edited)
**PHASE 1B answer was not copied.** A card is not a build spec until it has a real title and a DOI or an ACL/arXiv id.

This file copies successor §0.7 rows. It does not implement ColBERT, ME-BERT, PQ, PCA, or any write into `fingerprints[1..31]`.

---

## Named layers (Track 0 done-condition)

A third party can name these without opening `src/lexicon.zig` and calling it the catalog:

| reserved name | what the bytes are | production role this checkout |
| :--- | :--- | :--- |
| **Rel slot** | `LogicOp` enum(u64) 1001–1008 | header.opcode; `intake_gate` / `lexicon_intake.py`. How rows link. |
| **Closed lexicon** | INVARIANT-02 Sentence→Row / F11 TERM | unbuilt as a store of terms. Not the eight RELs. Not tokenizer tables. |
| **`simd_kernels.zig`** | C-ABI 64 B carry scanner `simd_tokenize_chunk` | First Zig **non-test** caller: `tokenizeSourceChunk` (`src/lsp_indexer.zig:493`, call site `:501`), reached only from `indexScannedIdentifiers` (`:843`), which currently has **no caller and no test**. Not the catalog. A green `zig build test` is not evidence the scanner works. |
| **`simd_lexer.zig`** | bench-side scan→phonetic-map module | a **different file** from `simd_kernels.zig`. Collapse benches. |
| **Fingerprint WRITER** | `cactus_embed_pack.packEmbed` slots `[0..6)` | the one writer. Declarations (BioCLIP / DINOv3 / EBM / `fingerprintCell`) are not writers. |

`controller.zig` Signal 1..4 (Recency / Frequency / Cosine / Structural) are shipped identifiers. They are not Rel slots, not the closed lexicon, and not PoE-Expert-2.

### Reachability (post-close, C2)

`tokenizeSourceChunk` is Zig, non-test, and calls `simd_kernels.simd_tokenize_chunk`. `rg indexScannedIdentifiers src/ tools/ bindings/ build.zig` returns one hit: the definition at `src/lsp_indexer.zig:843`. The chain dead-ends. The test at `src/lsp_indexer.zig:1543` passes the string `"simd_tokenize_chunk"` to `encodeHeaderWithLanguage`; it does not call the scanner.

---

## SKIPPED-STAGED: ARCHITECTURE-ESTABLISHED

`docs/ARCHITECTURE-ESTABLISHED-20260909.md` is in `git diff --cached --name-only` (the 305-file migration). Track 0 does **not** modify it (successor F-C). The fourth-impostor paragraph that would have been a merge-aware append to "The three impostors" is recorded here instead. The first three rows on that file stay intact; nothing is deleted.

### Fourth impostor (not appended to the staged file)

| what was called "lexicon" | what it actually is | where |
| :--- | :--- | :--- |
| SIMD scanner, or `lexicon.zig` tokenizer tables (`WORDS`, `LogicOp`) | **not the closed lexicon** | `src/simd_kernels.zig` (`simd_tokenize_chunk`, C-ABI 64 B carry scanner) is one file. `src/simd_lexer.zig` (bench-side scan→phonetic-map module) is a **second file**. They are not interchangeable. Neither is INVARIANT-02 / F11 TERM. |

`src/simd_kernels.zig` ≠ `src/simd_lexer.zig`. Calling either the closed lexicon, or calling `lexicon.zig` the catalog because it holds Rel-slot names, is the fourth impostor.

After merge `55ea1fc`, this staged file is no longer a draft-vs-draft. The SoT is law on `main`. `ARCHITECTURE-ESTABLISHED-20260909.md` remaining in the 305 is a staged draft one commit from contradicting law. This card does not `git add` that path and does not `git commit` that index.

---

## §0.7 rows (engine: web search, 2026-09-10)

| card | query | hits | verdict |
| :--- | :--- | :--- | :--- |
| CARD 1 ColBERT | (original turn; confirmed literature) | Khattab & Zaharia, SIGIR 2020, *ColBERT: Efficient and Effective Passage Search via Contextualized Late Interaction over BERT*, arXiv:2004.12832 | **REAL.** Title is *Passage Search*, not *Neural Search*. |
| CARD 2 ME-BERT | `Luan Eisenstein Toutanova Collins Sparse Dense and Attentional Representations for Text Retrieval TACL 2021 ME-BERT` | ACL Anthology `2021.tacl-1.20`; DOI `10.1162/tacl_a_00369`; authors Yi Luan, Jacob Eisenstein, Kristina Toutanova, **Michael Collins**; venue **TACL 2021**, not NAACL; fourth author is **not** Chang | **REAL paper, mangled citation.** ME-BERT is a model *inside* that paper. |
| CARD 7 | `Geva Scholer Thomas "Safe Minimum for Retrieval Ensembles" SIGIR 2023` | SIGIR '23 proceedings exist (Taipei, 10.1145/3539618). **Zero hits on that title / that author triple as named.** | `UNVERIFIED` — searched web 2026-09-10, query as left, 0 matching papers. Not a DOI gate until a real paper is named. |
| CARD 18 | `Babenko Lempitsky "Inverted Residual Vectors" AMDL 2014` | **0 hits on that title.** Their CVPR 2014 paper is *Additive Quantization for Extreme Vector Compression*, DOI `10.1109/CVPR.2014.124`, pp. 931–938. Related real paper: *The inverted multi-index* (TPAMI). | `UNVERIFIED as cited.` The real 2014 CVPR paper may be used **under its real title**. AMDL is not a license to invent a routing scheme. |

CARD 1's *Applies to our case* still maps ColBERT onto unused slots of the **same** embedding (P1B defect C1). No seat implements from that mapping.

---

## Remaining cards — `NOT-YET-CHECKED`

Default: a card is not a build spec. These numbers exist in the PHASE 1B answer drop; they were not re-queried this turn.

| card | verdict |
| :--- | :--- |
| CARD 3 | `NOT-YET-CHECKED` |
| CARD 4 | `NOT-YET-CHECKED` |
| CARD 5 | `NOT-YET-CHECKED` |
| CARD 6 | `NOT-YET-CHECKED` |
| CARD 8 | `NOT-YET-CHECKED` |
| CARD 9 | `NOT-YET-CHECKED` |
| CARD 10 | `NOT-YET-CHECKED` |
| CARD 11 | `NOT-YET-CHECKED` |
| CARD 12 | `NOT-YET-CHECKED` |
| CARD 13 | `NOT-YET-CHECKED` |
| CARD 14 | `NOT-YET-CHECKED` |
| CARD 15 | `NOT-YET-CHECKED` |
| CARD 16 | `NOT-YET-CHECKED` |
| CARD 17 | `NOT-YET-CHECKED` |
| CARD 19 | `NOT-YET-CHECKED` |
| CARD 20 | `NOT-YET-CHECKED` |
| CARD 21 | `NOT-YET-CHECKED` |

---

## Anti-use

- Do not cite CARD 7 until a real paper (title + DOI/arXiv) is named.
- Do not cite CARD 18 as "Inverted Residual Vectors AMDL". *Additive Quantization for Extreme Vector Compression* (CVPR 2014, DOI `10.1109/CVPR.2014.124`) may be cited under that title only.
- Do not implement from `~/Documents/PHASE 1B — Prior Art for Signal Independence.txt`.
- Do not implement from `docs/BLUEPRINT-20260910-INDEPENDENCE-NOT-CONFLATION.md` §3.
