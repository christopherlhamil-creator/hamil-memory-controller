# PACKET — Phase 1B: prior art for signal independence (Viking/Cactus hybrid)

**READ THIS FIRST — DIRECTIVE**

Your Phase 1 answer is corrected below. Read the corrections, then answer **PHASE 1B ONLY**.
Stop at the end and write `END PHASE 1B`.

**Your role has changed.** In Phase 1 you were asked to *design* mechanisms, and three of five
answers failed for the same reason: you invented a mechanism instead of retrieving one that
already exists. That is the wrong use of you.

**You are now a research synthesist.** Your value here is not invention — it is that you can
reach the published literature across retrieval, information theory, energy-based models, and
neuroscience, and tell us **what is already known and who established it**. The operating
assumption of this system is: *nothing here is a new idea; the version already in the
literature is usually better than the one we would improvise.*

So: **do not propose. Retrieve, attribute, and synthesise.** Where the literature disagrees
with itself, say so and keep both sides — a contested finding is data, not a problem to
resolve by picking a winner.

---

## OUTPUT FORMAT — atomic cards, one claim each

Every answer is a set of **atomic cards**. One card = one claim. No prose essays.

```
### CARD <n> — <one-line claim, stated as a proposition>
**Domain:** retrieval | information-theory | EBM | neuroscience | systems
**Source:** <author, year, venue, title>  — or  UNSOURCED
**Confidence:** ESTABLISHED (replicated, textbook) | REPORTED (single paper) | FOLKLORE (widely practised, no citation) | MY INFERENCE
**Claim:** <2–4 sentences>
**Applies to our case because:** <1–2 sentences tying it to the measured facts below>
**Would be wrong if:** <the observation that would falsify it here>
**Links to:** CARD <n>, CARD <m>
```

**Citation rules — enforced:**
1. A source must be **real and checkable**: author, year, venue, title. If you cannot name
   one, write `UNSOURCED` and mark confidence `FOLKLORE` or `MY INFERENCE`. An UNSOURCED
   card is still welcome — a fabricated citation is not.
2. Do not invent numbers. Every measured value you need is in MEASURED FACTS. Anything else:
   `UNKNOWN — needs measurement: <what, how>`.
3. If two sources disagree, write **both cards** and add
   `**Contested with:** CARD <n>`. Do not adjudicate.

---

## PHASE 1 CORRECTIONS — read before answering

You did one thing right: you wrote `UNKNOWN — needs measurement:` twice with concrete
instructions rather than inventing latency. Keep doing that.

But you also wrote *"Negligible. Approximately 2 to 3 microseconds per candidate"* for
Proposal B. That number was not supplied and not measured. It is the same failure as the
0.46 edit-distance ratio you invented in an earlier round — small, confident, unsourced.

**Four substantive defects:**

**C1 — Proposal B is fatally broken and the reasoning error matters more than the bug.**
You proposed dot-producting `fingerprints[1..31]`. The packet stated those are **unused**.
Unused means zero-filled: `dotProduct48(query, zeros) = 0` for *every* candidate — a
constant, with zero discriminative power. You never said what would *write* them.

The deeper error: you called them *"auxiliary orthogonal projections"* and treated
orthogonality as sufficient for independence. **It is not.** A second projection of the same
source embedding is a rotation of the same information. Product-of-Experts requires experts
that see **different evidence**, not different axes on the same evidence. This is precisely
the defect the current stub already has, restated.

**C2 — Proposals A and C rest on an unstated assumption.** Both route `semantic_payload`
through token-based paths (`cactus_score_window`, gemma prefill). The packet states the
payload is *"PROVISIONAL / opaque, NOT on the retrieval path"*, schema out of scope. **You
assumed it contains text tokens.** Nothing said that. Two of your three proposals depend on it.

**C3 — On Q3 you defended the defect you were asked to fix.** You committed to "no veto, soft
scalar multiplier." Signal 2 is *already* a soft scalar multiplier — and its output is
**clamped to a maximum of 0.02** of joint energy by construction. You never mentioned the
clamp. A 0.02 ceiling is the mechanism that makes signal 2 unable to affect any outcome.
Answering "leave it soft" is answering "leave it as it is."

**C4 — Your null hypothesis is inverted.** You wrote `H₀: ρ ≥ 0.15`, reject if `ρ < 0.15`.
A null is the default-true claim you attempt to *disprove*. Yours makes *dependence* the
default and *independence* the finding — so failing to gather evidence would "prove"
independence. Standard form is `H₀: ρ = 0`. Separately, 0.15 is asserted, not derived.

**C5 — On Q5 you dissolved the constraint instead of solving it.** You claimed a
`R^1024 → R^1` energy head can be *"extracted directly from the internal weights"* of the
frozen bundle and is therefore a pretrained artifact with no version-control conflict.
A causal LM's `lm_head` maps hidden state to **vocabulary logits** (~256k dimensions), not to
a scalar energy. **No pretrained scalar energy head exists in these models.** Collapsing
vocabulary logits to one number requires a *chosen* reduction — and any learned mapping is a
fitted artifact. Calling it pretrained does not make the conflict go away.

**Keep:** the elbow-detection cascade (rank by Pass 1, cut at the largest score drop within
the top 8–16, fall back to a hard 8) is a good idea and survives. It is the one part of
Phase 1 carried forward unchanged.

---

## MEASURED FACTS — verified on disk, use these, invent nothing

**Store.** `Cell` = 17,408 B, 272 cache lines, 64-byte aligned. Layout: `header` 64 B at
offset 0 (`content_hash` 32 B Blake3-256, `source_id` u64, `timestamp_ns` u64, `class_key`
u64 — only bits 8–9 used, `flags` u64 unused); `fingerprints` 16,384 B at offset 64 = 32
vectors × 512 B, each `[64]u64 align(64)`; `semantic_payload` 960 B at offset 16,448,
PROVISIONAL/opaque.

**Retrieval.** `fingerprints[0]` reinterpreted as **`[48]i8`** is the routing vector — 48
bytes, one cache line. `fingerprints[1..31]` = 15.8 KB allocated, **unused**.
`MAX_K = 64`, `DEFAULT_CANDIDATE_POOL = 128`. Fibonacci hashing, `PHI64 =
11400714819323198485`, `bucket_bits: u6` (0 = scan all, 1..16 = partition prune).

PASS 1: SIMD dot over the frozen fingerprint table, 4 KB O_DIRECT sector-0 prefetch (header +
fingerprints only), no Blake3, no byte folding. PASS 2: fetch full cell, evaluate signals,
fuse `E_joint = Σ Eᵢ`, then `fused_score = s1_score × (1 − min(0.99, E_joint))`.

**Signals.** 1 = `dotProduct48` over `[48]i8`. 2 = **stub**: discards `cand_cell`, recomputes
signal 1's dot product, clamps to `norm × 0.02`. 3 = Needle class routing (blocked / review /
goal / other), **can veto**. 4 = EBM Product-of-Experts energy gate, **can veto**.

**Measured retrieval quality**, 72 chunks / 24–26 paraphrase queries, 2026-09-02:

| what fills the 48 bytes | MRR | R@1 |
|---|---|---|
| byte-fold checksum (ships today) | 0.064 | 0.00 |
| random ranking (arithmetic floor) | 0.068 | 0.01 |
| MRL truncate-48 int8 | 0.211 | 0.08 |
| random projection-48 int8 | 0.426 | 0.33 |
| fitted PCA-48 int8 | **0.618** | **0.54** |
| full 768-d fp32 ceiling | 0.636 | 0.50 |

Chance floor = `sum(1/r for r in 1..n)/n`; n=72 → 0.0675.

**Timing.** get(hot) ~312 µs, get(disk) ~437 µs; 3-lane cascade hot 12.8% / cold 51.2% /
disk 36.0%. Embedding on this CPU: nomic ~13 s/item, Qwen ~7 s/item, serial.

**Hardware.** pop: Intel i5-8300H, 4c/8t, **AVX2 + F16C, no AVX-512**, 31 GB RAM. Brandys:
Zen4, 16 threads, AVX-512, **usually powered off**. Engine is CPU-only; the GTX 1060 is
irrelevant.

**Engine.** cactus, `libcactus_engine.so` 5,401,640 B. Build-once DAG serialized to
`.cactus`, one dispatch table over CPU/NPU, `mmap_weights` reads in place, per-tensor
precision incl. CQ1–CQ4. FFI exposes `cactus_embed`, `cactus_score_window` (returns
`{success, logprob, tokens}`), `cactus_rag_query`, `cactus_index_t`, `cactus_tokenize`.
Kernels: `attention.cpp`, `attention_hybrid.cpp`, `blas.cpp`, `fused.cpp`, plus
`cactus_neon_shim.h` / `cactus_fp16_x86.h` — the NEON→x86 port boundary. Zig 0.16.0.

**Bundles.** `gemma-4-e2b-it-cq4` 3.8 GB, 10 components incl. `decoder_prefill_chunk`→
`logits`, `decoder_step`→`logits`+`probe_hidden`, `decoder_embed_chunk`→`last_hidden_state`.
`probe_hidden` is a deliberate layer-28 mid-network tap (`capture_layer_index=28`), returned
at the last position. `nomic-embed-text-v2-moe-cq4` 265 MB, 1 component, 768-d, max **512
tokens**. `qwen3-embedding-0.6b-cq4` 4.6 GB.

**Constraints.** No new daemons. No cloud/paid API in steady state. Never overwrite a finding
— disagreement is a new row (Autopsy blackboard: Content identified by hash / Artifact = a
typed finding about a Content / Attribute = typed name-value pair). Retain everything; a
zero-result exact-match search is not evidence of absence. Human **over** the loop. `.sqlite`
is generated output, source-only in version control.

**Definitions — do not substitute your own.** *Low energy* = the solution was found **and is
producing the desired result**, externally verified; it does **not** mean the arms agreed.
*Similar information is the interconnection, not the competition* — two similar items link
rather than compete. *EBM specialists are pretrained GGUF files dropped in as truth-checkers*
— an input to the system, never something it trains.

---

# PHASE 1B — the questions

### Q1 — Multi-vector retrieval: who already stores many vectors per document?

`fingerprints[1..31]` is 15.8 KB of allocated, unused per-cell vector space. Systems that
keep **multiple vectors per document** and score by late interaction are an established
family.

- What are the named systems and their papers?
- What does each store in the extra vectors, and what **writes** them?
- What is the measured quality gain over single-vector retrieval, and the measured storage
  and latency cost?
- Which of them would fit a **fixed 512-byte-per-vector, 31-slot** budget, and which assume
  a variable number of vectors?

### Q2 — When are two retrieval signals actually independent?

This is the crux. Signal 2 must be independent of signal 1 or Product-of-Experts is
double-counting.

- What does the **ensemble diversity** literature establish about error correlation and why
  correlated members do not help? Name the decompositions (bias–variance–covariance, or
  ambiguity) and their authors.
- In **information-theoretic** terms, what is the right measure of "this signal adds
  evidence" — conditional mutual information, or something better suited to ranking?
- What is the standard published **test** for signal redundancy in retrieval fusion, and what
  is its null?
- Give the known failure case: two signals that *look* independent (different
  architecture/modality) but are empirically correlated because they share an upstream
  cause.

### Q3 — Biology: how do neural systems keep similar representations separate?

You are strongest here, and the mechanism is directly analogous. This system's stated rule is
*"similar information is the interconnection, not the competition"* — and it must keep
similar-but-distinct memories from collapsing into each other.

- **Pattern separation** in dentate gyrus: what is the actual mechanism, what are the key
  papers, and what is the measured expansion/sparsity ratio?
- **Sparse and decorrelated coding**: what does the literature establish about how the cortex
  reduces redundancy between neurons, and what are the named principles and authors?
- **Systems consolidation**: what is established about the hippocampal→neocortical transfer,
  what triggers it, and — critically — what is known about whether the original episodes are
  *retained* or *lost*?
- Is there evidence about what makes a consolidated memory **re-open** when the world
  changes? (This maps onto: a collapsed node whose solution stops working.)
- Where does the biological analogy **break down** for an engineered store? Name the
  disanalogies, not just the similarities.

### Q4 — Extracting a scalar from a frozen LM's internals

Correcting your Q5: there is no pretrained scalar energy head. But using a frozen LM's
internals as a *score* is a well-populated research area.

- What are the established methods for turning a frozen model's forward pass into a scalar
  quality/confidence/OOD score? Name them and their papers — including perplexity-based
  detection, logit-based confidence, and **probing classifiers on hidden states**.
- For each: is the required artifact **pretrained** (ships in the weights), **fitted** (must
  be trained on local data), or **derived** (a pure statistic of the forward pass, no
  parameters)? This distinction decides whether it can exist in a source-only repo.
- What is known about **which layer** to probe, and why a mid-network layer might be chosen
  over the final one? (Our tap is layer 28.)
- What does the literature say about the **failure mode** of likelihood-as-quality — where
  does low perplexity fail to mean correct?

### Q5 — 48 bytes: what does the compression literature say is achievable?

Our fitted PCA-48 int8 reaches 0.618 MRR against a 0.636 full-width ceiling on 72 chunks.

- What are the established families for compressing embeddings to a fixed tiny budget —
  product quantization, binary/Hamming codes, LSH, learned sketches? Name them and their
  papers.
- What recall retention do they **report** at roughly 48 bytes per vector, and on what corpus
  sizes? Our n=72 is tiny; what is known about how these methods degrade as n grows into the
  millions?
- Which of these produce a **fitted artifact** and which are **seeded/derivable**? Same
  version-control question as Q4.
- Is there published work on the specific observation we measured — that a compressed
  representation can score **higher R@1 than the uncompressed one** (0.54 vs 0.50)? Is that a
  known denoising effect, or is it more likely small-n noise?

### Q6 — What is NOT known

- Which of the above questions does the published literature **not** answer for our regime
  (single CPU host, ~10⁴–10⁶ cells, 48-byte routing vector, no GPU)?
- Where would we be **operating outside the evidence** and therefore need to measure locally?

Stop. Write `END PHASE 1B`.

---

## PHASES 2–6 — do not answer yet

2 — the fingerprint and the fitted-PCA-basis problem (refit cadence; what happens to stored
vectors on refit). 3 — branch topology in `class_key`'s 62 free bits given `fibHash` takes
high bits after PHI64 multiply. 4 — collapse/re-expansion and what posts the outcome
artifact; lazy vs eager re-check. 5 — the write-through projection from 17,408-byte binary
cells to a legible Obsidian graph without creating a second source of truth. 6 — AVX2 vs
AVX-512 split and the honest test that a kernel port is *correct*, not merely fast.
