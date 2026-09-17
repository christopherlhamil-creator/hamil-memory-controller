# 9. The EBM Anti-Bloat Pathfinding Compiler & Below-the-AST Memory Security — Formal Specification

**Lead author of the architecture under review**: Christopher Hamil  
**This section (formal theoretical specification)**: Council Seat 0 (`council-claude`)  
**Grounding files (disk-first, mechanisms that exist today)**: `src/controller.zig`, `src/lexicon.zig`, `src/geometry.zig`, `src/simd.zig`, `src/intake_gate.zig`, `src/mitosis.zig`, `src/boot_pack.zig`, `src/ipc_ring.zig`, `src/provenance.zig`, `migrations/002_model_governance.up.sql`, `db/zk_graph.sqlite`, `build.zig`  
**Cross-seat input (cited, not re-verified on this branch)**: `inventory/EVAL-EBM-TOKENIZER-SUDOKU-BENCH-20260908.md`, `inventory/EVAL-EBM-COMPILER-BLOAT-BENCH-20260908.md`, `inventory/EVAL-EBM-MEMORY-SECURITY-20260908.md` (Council Seat Antigravity / Seat 1, `council-agy` / `council-grok`); `inventory/WORKORDER-5-open-rectangles-20260907.md`, `ai/memory-bank/tasks/research-open-rectangles-135-tasklist.md`, `ai/memory-bank/tasks/research-division-5-open-rectangles-tasklist.md` (5 Open Rectangles scheme disambiguation, §9.8–9.9)  
**Citation index**: `research/references.bib`  
**Revision 2 (2026-09-08, Blackmagic Interrogation Round 1)**: §9.8–9.9 added by Council Seat 0 auditing Rectangle 1 (Model Governance & Intake Masking) against live source and the live database, not against the directive's own claims. §9.1–9.7 are unchanged from Revision 1.  
**Revision 3 (2026-09-08, `DIRECTIVE-COUNCIL-20260908-BRANDYS-RESEARCH-PAPERS-EXECUTION`, Seat 0)**: §9.10–9.11 added, synthesizing the Frontier 1–4 Grand Fusion empirical findings (commits `d2935f3`, `3e1d5ab`, `faacd90`, `2368a5b`) into this specification. Frontier 1 and Frontier 4 **close two gaps this section previously recorded as open** — the unwired GBNF mask (§9.9) and the absence of any code computing $E_{\text{joint}}$ or issuing opcode 1004 as a synchronous gate (§9.3, Row 4). Those two findings are marked **superseded** in place rather than deleted; the audit trail is the point. §9.1–9.9 are otherwise unchanged, and §9.10.5 states precisely which parts of §9.2–9.6 the Frontiers did **not** close.

**Status of this section, stated up front.** The directive assigns Seat 0 a *formal theoretical specification* — Task 1 says so explicitly — not a new benchmark. This section therefore does two different things and keeps them typographically distinct throughout: (a) it **formalizes** a joint energy function and a contraction/scar mechanism for compilation, citing the source files where each term's real-world analog already exists and executes today; and (b) it **proposes** the parts of that formalization — an AST-level pathfinding compiler, a persistent contraction-hierarchy cache — that do not yet exist as code anywhere in this repository. Every claim below is labeled which of the two it is. Conflating them would violate the "Disk-First Evidence" invariant this whitepaper has followed since Section 7.4.

---

## 9.1 Scope: what is real today, what is proposed

Three real, independently on-disk mechanisms already implement fragments of the directive's energy-based framing, in three different subsystems that were not designed together:

1. **`src/controller.zig`'s 4-signal composite score.** `MemoryController.score` computes `composite = Σ wᵢ·Sᵢ` over four bounded-`[0,1]` signals (recency, frequency, SIMD cosine-similarity semantic score, structural hop-distance score), with `SignalWeights.validate()` asserting `Σwᵢ = 1.0 ± 0.001` at call time — a real, working weighted linear combination, used today for candidate ranking and dispatch, not for compilation.
2. **`src/lexicon.zig`'s `FailureScar` / `LexiconEngine`.** A closed, 20-member `DefectClass` taxonomy where each recorded failure accumulates a `frequency_counter`, escalating `DefectSeverity` from `HappenstancePatternShift` to `SystemicMethodFailure` once `frequency_counter >= SYSTEMIC_FREQUENCY_THRESHOLD` (3) — a real, working "penalty accumulates with repetition" mechanism, used today to sharpen `/grill-me` adversarial review questions, not to steer a compiler.
3. **Council Seat Antigravity's Cellular EBM (`inventory/EVAL-EBM-TOKENIZER-SUDOKU-BENCH-20260908.md`, `tests/test_ebm_sudoku_simd_bench.zig`, `src/lsp_indexer.zig`).** A real, measured (on `pop-os` and `brandys`) bitmask product-of-experts solver: each Sudoku cell holds a `u16` candidate mask, peer propagation ANDs out eliminated digits, and `Mask == 0` is an absorbing contradiction state — a real, working "veto forces an unrecoverable state" mechanism, used today for a fixed 81-cell constraint-satisfaction lattice, not for an AST.

What does **not** exist in `src/*.zig` as of this commit: any component that walks a program's AST or call graph, assigns per-edge energy costs, finds a minimum-energy compilation path, caches that path as a "contraction shortcut," or invalidates that cache when the source changes. §9.2–§9.4 formalize that missing component by generalizing the three mechanisms above into one joint framework; §9.5 states plainly where the generalization is solid and where it is not.

---

## 9.2 The isomorphism, and where it breaks

Contraction hierarchies (Geisberger et al.'s technique, of which "Google Maps"-style routing is the popular instance) precompute shortcuts over a **static** weighted graph so that shortest-path queries at runtime touch a small fraction of the full graph. The directive's isomorphism maps a program's AST/call graph onto that same structure: nodes are call sites or basic blocks, edges are control/data-flow transitions, and a compiled "path" through the graph is a sequence of lowering/inlining/vectorization decisions.

The isomorphism holds for the *query* half: once a path through a fixed graph has been found to be low-energy, re-using that path for an unchanged subgraph is exactly a contraction-hierarchy lookup, and `fingerprints[0]` — the 48-byte routing signature `src/simd.zig` and `src/geometry.zig` both document as "frozen into `fingerprints[0]` on write/touch path" — is a real, existing primitive for keying such a lookup by content rather than by name.

The isomorphism **breaks** for the *precomputation* half, and this has to be stated rather than glossed over: a road network does not gain or remove intersections between two consecutive Tuesdays; a codebase's AST changes on every commit. A literal contraction hierarchy assumes the graph is static long enough to amortize an expensive one-time preprocessing pass. Nothing in this repository precomputes or invalidates such a structure today. §9.4 proposes the concrete invalidation rule this isomorphism needs in order to be more than a metaphor; until that rule is implemented and measured, "contraction hierarchy" in this section names a *target data structure*, not a shipped one.

---

## 9.3 The joint energy function

**Definition 9.1 (Per-edge energy).** For an edge $e$ in the compilation graph — a candidate lowering of one AST node into machine operations — define

$$
E_{\text{joint}}(e) = \lambda_{\text{mem}}\,E_{\text{cache}}(e) + \lambda_{\text{hop}}\,E_{\text{hop}}(e) + \lambda_{\text{alloc}}\,E_{\text{alloc}}(e) + \lambda_{\text{simd}}\,E_{\text{simd}}(e), \qquad \sum \lambda_i = 1,\ \lambda_i \ge 0,
$$

a convex combination, exactly generalizing the normalization `SignalWeights.validate()` already enforces at runtime for its own four terms (§9.1.1) — this section reuses that constraint rather than inventing a new one. $\mathcal{P}^{*} = \arg\min_{P} \sum_{e \in P} E_{\text{joint}}(e)$ is the minimum-energy compilation path the directive's Task 2 asks to ground.

**The sign convention, stated precisely.** `controller.zig`'s composite score is a *reward*, maximized on $[0,1]$; $E_{\text{joint}}$ here is a *cost*, minimized. The two are dual under $E = 1 - S$ for any bounded signal $S$. This section uses the cost convention because "energy" and "penalty" are the directive's own vocabulary, but every term below is traceable back to a reward-convention measurement that already exists in code, via that one substitution — this is not two unrelated formalisms, it is one, read in two directions.

**Grounding each term:**

- $E_{\text{hop}}(e)$ — **real, direct measurement.** `computeStructuralScore(hop_distance)` returns $(5 - h)/5$ for $h \in [0,4]$ and *throws* `ControllerError.RefusalMaxHopExceeded` for $h > 4$ (`checkHopLimit`, Invariant A-11) — the throw happens *before* any score is computed, which is the more faithful realization of "$E = \infty$" than any finite floating-point value could be: the candidate is never scored, never dispatched, full stop. $E_{\text{hop}}(e) := 1 - \text{computeStructuralScore}(h)$ for $h \le 4$, and $E_{\text{hop}}(e) := \infty$ (edge pruned from the graph entirely, not merely penalized) for $h > 4$.
- $E_{\text{alloc}}(e)$ — **real measurement technique, not yet a per-edge compiler signal.** `inventory/EVAL-LEXICON-COLLAPSE-BENCH-20260908.md` measures heap traffic with a local byte-counting allocator (268.0 B/proposition, flat across two orders of magnitude of $N$) rather than assuming it — that counting-allocator technique is the real, working instrument this term proposes generalizing to per-AST-edge granularity: $E_{\text{alloc}}(e) := $ bytes allocated by lowering $e$, as measured by wrapping the relevant `std.mem.Allocator` the same way the lexicon-collapse benchmark already does. No compiler pass performs this measurement per-edge today.
- $E_{\text{cache}}(e)$ — **real invariant, narrower scope than proposed here.** Section 2.1's Theorem 2.2 (Zero-Remainder Sub-Structure Alignment) and its compile-time enforcement (`std.debug.assert(@sizeOf(Cell) == 17408)`, `src/geometry.zig`) prove *the Cell layout itself* never straddles a cache line or causes false sharing (Theorem 2.3, §2.1.3). That is a fixed, whole-struct guarantee, not a per-edge cost function over arbitrary compiled code. $E_{\text{cache}}(e)$ as used here is the **proposed** generalization — a penalty proportional to cache lines touched outside the current 64 B/17,408 B alignment boundary — modeled on the real Cell proof, not identical to it.
- $E_{\text{simd}}(e)$ — **real primitive, proposed per-edge use.** `simd.cosineSimilarityI8_48` (used by `computeSemanticScoreI8`) and `src/simd_lexer.zig`'s `scanChunk64`/`scanBuffer` (measured at 13.40–15.46 ns/64-byte chunk, `inventory/EVAL-LEXICON-COLLAPSE-BENCH-20260908.md` §4) are real, on-metal SIMD kernels. $E_{\text{simd}}(e)$ proposes penalizing a candidate lowering that leaves data in a shape those kernels cannot vectorize over (e.g. non-64-byte-aligned, non-power-of-two strides) — a real cost model input the codebase does not yet compute automatically for arbitrary code.

**The veto is not a single mechanism — it is three, and they are not identical.** The directive's "$E = \infty$ → `negative_affinity_veto` (Opcode 1004) → register-level hardware veto" collapses three distinct, real, on-disk behaviors into one sentence. Naming them separately is necessary for honesty and useful for design, because a future compiler pass has to pick one:

| Realization | Where it lives | What actually happens | Faithfulness to "$E=\infty$" |
| :--- | :--- | :--- | :--- |
| Hard refusal (exception) | `controller.zig::checkHopLimit`, Invariant A-11 | `RefusalMaxHopExceeded` thrown *before* scoring; candidate never enters the ranked pool | Exact — the candidate is not merely low-ranked, it is absent |
| Score-zeroing veto | `controller.zig::score`, Invariant A-8 (`intent_matched = false ⇒ composite_score = 0.0`) | Candidate is scored, forced to the *minimum* of a bounded `[0,1]` range, still present in the pool at rank-last | Approximate — a bounded worst-case, not an unbounded one; a second, higher-priority veto could not out-rank this one further |
| Absorbing contradiction (bitmask) | `tests/test_ebm_sudoku_simd_bench.zig`'s `Mask == 0` (Seat Antigravity) | Candidate digit assignment removed from every peer's candidate set; a full contradiction triggers backtracking, not a score comparison | Exact within a closed, finite domain — there is no "digit" left to rank |
| `negative_affinity_veto` (Opcode 1004) | `src/lexicon.zig::LogicOp`, `src/intake_gate.zig::mapToLogicOp` | A closed-vocabulary **relation** asserting one fact vetoes affinity with another — a knowledge-graph edge, not a CPU instruction | Named the same as the directive's veto; **is not itself a register-level or hardware-dispatch mechanism** — no code in this repository issues opcode 1004 to a CPU pipeline stage. Calling it a "hardware veto" overstates what LogicOp 1004 is: a typed fact in a closed relational vocabulary. |

> **[SUPERSEDED IN PART — Revision 3, see §9.10.4.]** The table's last row and the paragraph
> below it were written against the source tree as of Revision 2, where no code computed
> $E_{\text{joint}}$ and nothing issued opcode 1004 as a gate. Frontier 4 (commit `9a54557`,
> [`src/ebm_governor.zig`](../../src/ebm_governor.zig)) changed that: a real, tested,
> allocation-free evaluator now computes a joint energy sum and **stamps opcode 1004 into the
> cell's first 8 bytes and returns before any `pwrite` reaches the cell bank**. Row 4's
> characterization of LogicOp 1004 as *data only* is now false as a statement about the codebase,
> though its narrower point — that opcode 1004 is still not a CPU instruction-dispatch trap —
> survives intact. §9.10.4 restates the taxonomy against the current tree.

The correction in the table's last row matters: the directive's Section 3 describes opcode 1004 as producing "an immediate register-level hardware veto... before instruction dispatch." That description is accurate for `checkHopLimit`'s exception path (row 1) and directionally right for the Sudoku EBM's bitmask absorption (row 3), but it is not what `negative_affinity_veto` itself does — LogicOp 1004 is data (a relation an author asserts between a subject and a target), consumed by `intake_gate.zig`'s human-sign-off gate, not a hardware trap. A future EBM compiler pass that wants literal register-level veto behavior should be built on the exception/refusal pattern (row 1), which already has that property, rather than assumed to already exist wherever opcode 1004 appears in a document.

---

## 9.4 Contraction hierarchies and failure scars, formalized

**Definition 9.2 (Failure scar as accumulated energy penalty).** `LexiconEngine`'s real mechanism generalizes directly. For a defect pattern $d$ (one of the 20 closed `DefectClass` members) observed at a code location keyed by a fingerprint $f$:

$$
E_{\text{scar}}(f, d) \mathrel{+}= \text{penalty}(d), \qquad \text{severity}(f, d) = \begin{cases} \texttt{SystemicMethodFailure} & \text{frequency}(f, d) \ge 3 \\ \texttt{HappenstancePatternShift} & \text{otherwise} \end{cases}
$$

This is Definition 9.2 stated as an equation, but it is not a new definition — it is `FailureScar.recordOccurrence`'s real, running Zig code (`src/lexicon.zig`, `SYSTEMIC_FREQUENCY_THRESHOLD = 3`) restated in the directive's energy notation. The 20-member `DefectClass` taxonomy already includes `hardware_boundary_breach` (11: violations of the 17,408 B/64 B/4-hop geometry this whitepaper specifies) and `sqlite_lock_tax_leak` (20: the exact defect Section 7.1 names) — the taxonomy this appendix's compiler would draw its penalty vocabulary from already exists and is already seeded (`LexiconEngine.seedHistoricalScars`) with real historical failures, several of them from the session the directive calls the "48-Hour Audit" (`DefectClass` values 13–17, commented in source as "48-Hour Audit Laws & Axioms, Session FFC759").

**Proposed extension (not implemented): contraction shortcuts keyed by fingerprint.** A compilation path $P$ through the AST graph that completes with $E_{\text{joint}}(P)$ below a threshold and accumulates no new scars is proposed to be memoized as a **contraction shortcut**, keyed by the 48-byte routing fingerprint (`fingerprints[0]`, `ROUTING_FP_BYTES`) of its subgraph — reusing, not extending, the real fingerprint-freezing mechanism `src/simd.zig`/`src/geometry.zig` already document. A subsequent compilation touching a subgraph with an unchanged fingerprint looks the shortcut up instead of re-solving $\arg\min$ over it — literally a contraction-hierarchy query, degenerate case: a hash-keyed memo table, not (yet) a full multi-level hierarchy with precomputed intermediate shortcuts.

**The honest failure mode this proposal has to name.** §9.2 already flagged that AST graphs are not static like road networks. The concrete consequence: a fingerprint memoized today is invalidated the instant its subgraph's *source bytes* change, which for a hot, frequently-edited function could mean the shortcut cache never gets a chance to pay for itself before it is invalidated again. This is the compiler-design equivalent of a cache with a shorter mean lifetime than its own construction cost — a real risk, not a hypothetical one, and no measurement anywhere in this repository establishes that real codebases churn slowly enough for the proposed shortcut cache to have positive expected value. That measurement is the concrete, falsifiable next step this section recommends before any of §9.3–9.4 is implemented as an actual compiler pass: instrument fingerprint-stability half-life across this repository's own git history (`git log --follow` per hot file, fingerprint recomputed at each revision) and report the distribution, the same disk-first way `inventory/EVAL-LEXICON-COLLAPSE-BENCH-20260908.md` reports pipeline cost instead of assuming it.

---

## 9.5 Below-the-AST memory security: what "Map-Compliance" can and cannot mean here

The directive's premise — that a buffer overflow is syntactically a valid array store, so AST-level scanning is the wrong altitude to catch it, and that a widely-cited industry figure puts memory-corruption bugs at roughly 60–70% of serious CVEs across large C/C++ codebases (Microsoft's and Chromium's security teams have each published figures in that range; this repository has no CVE history of its own to cite, so the figure is reported as external, published context, not a locally measured statistic) — is correct and not in dispute. Where this section has to be careful is in what "Map-Compliance" (memory operations validated against Cell/A-1 boundaries, violations receiving $E = \infty$) actually means as *implemented* Zig code, versus as a hardware-level claim.

**What is real:** Zig's language-level safety checks — array/slice bounds checking, integer overflow trapping, and `undefined`-pointer sentinel checks — are genuine, compiler-enforced runtime checks, not aspirational. `build.zig` line 318 explicitly runs the SIMD lexer boundary benchmark in `.ReleaseSafe` (comment: "SIMD lexer boundary + ReleaseSafe throughput gate") specifically because that mode keeps those checks on. A pointer dereference or slice index outside a `Cell`'s 17,408-byte extent, in `.ReleaseSafe` or `.Debug`, panics deterministically rather than corrupting adjacent memory — this is Zig's actual, shipped memory-safety story, and it is a legitimate instance of "below-the-AST" enforcement: the check fires at the machine-code bounds-comparison level, generated by the compiler, invisible to and independent of what the source syntax looks like.

**What has to be flagged, not glossed over:** `build.zig`'s remaining eight-plus benchmark steps (lines 330, 348, 395, 409, 444, 478, 505, 568) run in `.ReleaseFast`, which compiles those same bounds and overflow checks **out** for speed. Every headline performance number this whitepaper cites elsewhere — the 986,382.9 tx/s sidecar figure (§7.4), the 256,174 propositions/sec lexicon-collapse figure (§8.4), the sub-microsecond Sudoku solve times (§9.1.3) — was measured in a build mode that has traded away exactly the bounds-checking mechanism this section is about to propose as the enforcement layer for "Map-Compliance." This is a real, present tension in the codebase as it exists today, not a hypothetical one: **the fast path and the memory-safe path are, right now, two different compiled binaries**, and no artifact in `proof/` measures the performance delta between them to show what Map-Compliance would actually cost if left on in the hot path. That measurement — `.ReleaseSafe` vs. `.ReleaseFast` throughput on the same benchmark, on the same host — is the concrete follow-up this section recommends before "Below-the-AST Memory Security" is claimed as a property of the shipped, fast build rather than of the safety build most of this whitepaper's own numbers do not use.

**Where the directive's opcode-1004/register-veto framing does apply here, precisely:** a memory-security policy built on Definition 9.1's $E_{\text{hop}} = \infty$ *exception* pattern (§9.3's Row 1, `RefusalMaxHopExceeded`) — an out-of-bounds access throwing before it executes, exactly what Zig's `.ReleaseSafe` bounds check already does — is the right model to generalize. A policy built on the `negative_affinity_veto` LogicOp (§9.3's Row 4) is not, because that opcode is a data-layer relation, not a trap.

---

## 9.6 Gegenrede (compiler engineer, adversarial)

> *You have formalized three things that already work in three unrelated subsystems — a ranking score, a defect log, and a Sudoku solver — and called the union of their vocabulary a compiler. There is no parser here, no AST walker, no code generator that consults $E_{\text{joint}}$, and no evidence that a "contraction shortcut" would survive a single day of real edits to a real function. Google Maps works because roads are stable for years; you have shown a cache invalidation problem, not a routing algorithm.*

This is the correct objection, and §9.2 and §9.4 already say so in different words: the static-graph assumption underlying contraction hierarchies is the load-bearing part of the Google Maps analogy, and it is exactly the part this section cannot claim holds for source code without the fingerprint-stability measurement §9.4 proposes and has not run. The honest position is:

1. **What this section actually establishes**: the three ingredient mechanisms — bounded weighted scoring with enforced-sum weights, frequency-escalated penalty accumulation, and absorbing-veto contradiction — are real, running, and individually well-tested (`src/controller.zig`'s and `src/lexicon.zig`'s own test suites; Seat Antigravity's dual-host Sudoku measurement). Composing them into $E_{\text{joint}}$ is a valid formalization of a hypothesis, not a report of a built system.
2. **What it does not establish**: that this hypothesis, wired into an actual compilation pipeline, beats a conventional optimizing compiler's cost model on real code, or that the contraction-shortcut cache pays for its own invalidation overhead on any codebase larger than this one's own hand-written Sudoku fixture.
3. **The concrete next RFC this Gegenrede leaves open**: build the smallest possible instance — a single AST transformation (e.g. inlining decisions for one Zig module) scored by a two-term $E_{\text{joint}}$ (just $E_{\text{hop}}$ and $E_{\text{alloc}}$, both of which already have working measurement instruments per §9.3) — and measure whether it selects different, faster code than `-OReleaseFast` alone on a benchmark already in `proof/`. Until that exists, the honest label for §9.2–9.4 is *formal specification awaiting its first implementation*, which is exactly what Task 1 of this directive asked Seat 0 to deliver — no more, no less.

---

## 9.7 Attribution

The joint energy formalization, the three-mechanism veto taxonomy of §9.3, the contraction-shortcut proposal and its stability caveat in §9.4, and the `.ReleaseSafe`/`.ReleaseFast` tension named in §9.5 are Council Seat 0's (`council-claude`) synthesis for this directive. The underlying real mechanisms generalized here — `controller.zig`'s 4-signal ranking, `lexicon.zig`'s `FailureScar`/`LexiconEngine`, Invariant A-1/A-2/A-8/A-11 — remain Christopher Hamil's inventions, per Section 7.6. Council Seat Antigravity's Cellular EBM Sudoku benchmark is its own attributed deliverable, cited here, not re-authored here.

Cite this section as [hamil2026ebmcompiler].

---

## 9.8 The 5 Open Rectangles — two colliding numbering schemes, disambiguated

The Blackmagic Interrogation directive (2026-09-08) asks this section to "formally document the 5 Open Rectangles framework." Doing that honestly requires stating something the directive's own framing does not: **two unrelated "5 Open Rectangles" numbering schemes exist on disk today, both dated within the same 48 hours, and the directive's Context section (Section 9's EBM compiler, the Sudoku SIMD solver, below-the-AST memory security, polyglot interop) traces to the *wrong* one if the goal is closing the engineering rectangles.**

**Scheme A — the canonical engineering-gap rectangles**, per `inventory/WORKORDER-5-open-rectangles-20260907.md` (which itself spot-checked and confirmed four real defects before certifying the canonical task list) and `ai/memory-bank/tasks/research-open-rectangles-135-tasklist.md` (20 tasks, verified against source):

| Rectangle | Title | Canonical tasks |
| :--- | :--- | :--- |
| 1 | DBMS-Enforced Model Governance & Identity Parsing | Tasks 1–5, 14 |
| 2 | Deterministic pre-Execution Context Assembly | Tasks 15–20 |
| 3 | Fixed-Width Working Memory with Fractal Split-on-Overflow | Tasks 6–9, 14 |
| 4 | *(never supplied)* | `BLOCKED-missing-spec` |
| 5 | TCP-Isomorphic Task Arbitration without Distributed Mutexes | Tasks 10–13, 14 |

**Scheme B — the F-series "empty rectangle" literature-gap cards**, per `ai/memory-bank/tasks/research-division-5-open-rectangles-tasklist.md`, which `WORKORDER-5-open-rectangles-20260907.md` itself explicitly labels **"Wrong track... an unrelated numbering scheme... not this directive's five titled rectangles. Do not use."** Scheme B's five cards (F8-2, F10b-1, F10b-2, F10b-5, F10a-2) ask whether specific *published-literature* gaps exist, not whether an engineering task is done. **Card F10a-2 reads, verbatim: "using a continuous joint energy sum ($E_{\text{joint}} = \sum E_i$) as a hard, synchronous veto mechanism determining whether an item is committed to physical storage remains undocumented [in the literature]."** That sentence — not Scheme A's canonical Rectangle list — is the actual origin of this whitepaper's own §9.3 energy formulation, Seat Antigravity's Cellular EBM Sudoku solver, the compiler-bloat benchmark, and the below-the-AST memory-security benchmark that the current directive's Context section cites as "the 5 Open Rectangles... verified." All of that work is real (§9.9 below audits how real, term by term) and it does answer Card F10a-2's literature question — but Card F10a-2 is one of Scheme B's five *unrelated* cards, not a stand-in for Scheme A's canonical Rectangles 2, 3, 4, or 5. Conflating the two schemes would let five F-series literature benchmarks be reported as if they closed five different, still-largely-open engineering gaps. They do not close them; they were never aimed at them.

This section documents Scheme A as *the* 5 Open Rectangles framework, because it is the one this whitepaper's own architecture (Sections 2, 7, 8) and this directive's assigned Rectangle numbers (Rectangle 1 = Model Governance, matching Seat 0's Task 2/3 assignment this round) actually refer to.

---

## 9.9 Blackmagic Interrogation Round 1 (2026-09-08): Rectangle 1 audit, verified on this commit

> **[SUPERSEDED — Revision 3, see §9.10.1.]** This subsection is retained verbatim as the audit
> record that *caused* Frontier 1. Its central finding — "the GBNF logit mask is not enforced in
> `intake_gate.zig`, anywhere, today" — was true at the commit it was written against and is
> **false as of commit `d2935f3`**, which wired `lsp_indexer.TokenMask` directly into
> `src/intake_gate.zig`. Read §9.9 as history; read §9.10.1 for the current state. The Task 14
> integration-test gap and the Rectangle 2–5 statuses recorded below are likewise refreshed in
> §9.11.

**Blackmagic Question 1, answered directly.** *Is the GBNF logit mask enforced in the tokenizer before token emission everywhere, or are unconstrained natural language strings still allowed to enter `intake_gate.zig` before discovering an AST structural fracture?* Verified against `src/intake_gate.zig` and `src/lsp_indexer.zig` on this commit: **the GBNF logit mask is not enforced in `intake_gate.zig`, anywhere, today.** `grep`-confirmed: `TokenMask` (`lsp_indexer.zig`'s 0.86 ns/token mechanism) appears in exactly one file in `src/`, and it is not `intake_gate.zig`; nothing in `src/` or `tests/` calls `intake_gate.parse_and_contract` except its own C-ABI export, and that export performs no grammar check either. The precise, three-tier answer:

1. **`parse_and_contract` (the actual front door)**: accepts arbitrary raw bytes as `manifest.raw_obsidian_ptr`. The only structural check is `std.mem.indexOf(u8, source, "[SEMANTICS]")` / `"[DETAILS]"` — a literal substring search for two marker strings, not a grammar. Unconstrained natural language passes through this function today exactly as the Blackmagic Question suspects.
2. **`stampApprovedTriple` (Rectangle 1 Task 4, real and tested — `src/intake_gate.zig`, 9 unit tests including "relation token outside the closed vocabulary is rejected even when signed")**: does enforce a real closed vocabulary, but only on the *relation* token, via `mapToLogicOp`'s 8-way exact string match against `lexicon.LogicOp` — a hand-written closed-vocabulary check, not the GBNF/`TokenMask` machinery Blackmagic Question 1 asks about. This is genuine structural enforcement Task 4 added; it answers "is the predicate constrained?" with yes, and "is it the GBNF mask?" with no.
3. **`subject`/`target` strings**: `lexicon.Term.makeId` silently truncates to 16 bytes with zero validation — no rejection of malformed input, no lexicon membership check, no grammar check of any kind. Two different 200-byte unconstrained subject strings sharing a 16-byte prefix collide into the same `subject_id` silently. This is the "AST structural fracture discovered late" failure mode the Blackmagic Question names, confirmed present, unresolved by Task 4.

**Rectangle 1 status, verified this session (not assumed from the directive's Context claims):**

| Task | Description | Status, verified how |
| :--- | :--- | :--- |
| 1 | Pin `provenance_flags` bit map (mitosis vs. provenance collision) | **Done.** `src/mitosis.zig`'s `FLAG_MITOSIS_MEMBER`/`FLAG_MITOSIS_HAS_NEXT` now live at bits 4–5 (`geometry.MITOSIS_FLAGS_SHIFT`), with a compile-time assert `(FLAG_MITOSIS_MEMBER \| FLAG_MITOSIS_HAS_NEXT) & 0x0F == 0` proving no overlap with `ProvenanceSource`'s bits 0–3. |
| 2 | DBMS `CHECK` for embedder identity | **Done, empirically verified this session.** `migrations/002_model_governance.up.sql`'s `cells.embedder CHECK (embedder = 'embeddinggemma-300m')` is live in `db/zk_graph.sqlite` today (not merely in the `.sql` file) — confirmed by `sqlite3 .schema cells` against the live database, then confirmed the constraint actually fires: `INSERT ... embedder='nomic-embed-text'` against a scratch copy fails with SQLite error 19 (`CHECK constraint failed`), while `embedder='embeddinggemma-300m'` succeeds. No new migration needed; this directive's Task 2 was already closed by prior work on this branch. |
| 3 | Strip stale `nomic` example from `provenance.zig` | **Done, verified this session.** `grep -ri nomic` across every `.zig` file in this repository returns zero matches. `src/provenance.zig:20` pins `EMBEDDER_ID = "embeddinggemma-300m"`, and `tagCell` actively rejects any other value (`ProvenanceError.InvalidEmbedder`, tested in `"Provenance: rejects non-canonical embedder identity"` using a neutral `"deprecated-embedder-fixture"` string rather than reintroducing the banned name). No new edit needed; this directive's Task 3 was already closed by prior work on this branch. |
| 4 | Parse identity into `BytecodeHeader` subject/predicate/target | **Done.** `stampApprovedTriple` (§9.9.2 above) fills all three fields via `Term.makeId` / `LogicOp.toId16`, refuses unsigned intake before writing, and keeps `@sizeOf(BytecodeHeader) == 64`. |
| 5 | Identity parse test vectors (valid triple / missing tags / unsigned human) | **Substantially done, not verbatim.** The three required cases are covered, but by a 9-test suite (`src/intake_gate.zig`) rather than exactly 3 tests bearing those literal names — broader coverage than the task spec asked for, not narrower. |
| 14 | Rectangle 1+3+5 integration test (no server) | **Not found.** No test in this repository exercises `intake_gate.zig`, `boot_pack.zig`, and `ipc_ring.zig` together in one run; each Rectangle's tests remain per-module. Open. |

Net: Rectangle 1 is materially closed at the unit level (Tasks 1–5) but still missing its cross-Rectangle integration test (Task 14) — and, per the three-tier answer above, closing Task 4 did not and does not enforce the GBNF mask Blackmagic Question 1 asks about; that remains a distinct, unimplemented wiring even after Rectangle 1's other tasks land.

**Rectangles 2–5, checked rather than assumed:**

- **Rectangle 2** (Deterministic pre-Execution Context Assembly, Tasks 15–20): not verified this session — out of this seat's assigned scope for this round, and not addressed by any of the EBM/Sudoku/compiler-bloat/memory-security/polyglot work the directive's Context section cites. Status unknown, presumed still open until a seat audits it directly.
- **Rectangle 3** (Fixed-Width Working Memory, Fractal Split-on-Overflow, Task 6): **done, spot-checked.** `src/boot_pack.zig` now calls `mitosis.splitWrite` on overflow (line 117) with a test named exactly `"boot pack overflow is wired to mitosis.splitWrite, never trimmed"` — the WORKORDER's finding #2 (`SplitRequired` never actually splits) is resolved.
- **Rectangle 4**: still `BLOCKED-missing-spec`. This directive, like every prior one, does not supply it. Not invented here either.
- **Rectangle 5** (TCP-Isomorphic Arbitration, Task 10): **substantially done.** `src/ipc_ring.zig`'s unsafe overwrite-by-default path is now named `pushUnchecked` (previously plain `push`), with `pushWithBackpressure` as the explicit safe alternative — the WORKORDER's finding #3 (unsafe path is the unlabeled default) is resolved by making the danger nameable at the call site. No caller in `src/` or `tests/` outside `ipc_ring.zig` itself invokes either path yet, so which one becomes the operative "default" in practice is not yet exercised.

**A caveat on the EBM benchmarks this directive's Context section calls "verified."** Auditing `tests/test_ebm_compiler_bloat_bench.zig` (Council Seat Antigravity, `inventory/EVAL-EBM-COMPILER-BLOAT-BENCH-20260908.md`) against its own source, three things do not hold up as reported: (a) the "6-hop violation" is a hardcoded struct literal (`BloatedContext{ .depth = 6 }`) checked by `ctx.depth > MAX_HOP_DEPTH`, never by `controller.zig`'s real `checkHopLimit`/`RefusalMaxHopExceeded` — no live Invariant A-11 code path is exercised; (b) the "Total Energy Score" table's $1{,}005{,}000.0$ and $50.0$ values are hardcoded literals assigned by an `if` statement in the test, not values computed by any real cost-model function; (c) on Host A (Coffee Lake), the report's own Table 3.1 shows Arm C ("EBM-Contracted") at **3.96 ns/op — slower than both Arm A (0.54 ns/op) and Arm B (0.51 ns/op)** — directly contradicting the prose claim that Arm C "recovers single-cycle baremetal speed." None of this makes the underlying idea wrong; it means the proof artifact's own numbers, read carefully, do not yet demonstrate it, and §9.6's Gegenrede already recommended the correct next step (wire a real $E_{\text{joint}}$ evaluation to the real `controller.zig` refusal path) before any claim of "closure" is made. This is exactly the gap Blackmagic interrogation exists to find.

---

## 9.10 The Frontier 1–4 Grand Fusion: what the four rectangles empirically settled

Between Revision 2 of this section and this revision, four commits landed on `main` and four
evaluation artifacts landed in `proof/`. This subsection integrates them into the formal
framework of §9.3–§9.5 under the same discipline the rest of Section 9 has used since Revision 1:
**every claim is labeled either measured-on-disk or proposed, the artifacts are read against the
source rather than against their own prose, and where an artifact's numbers do not support its
own summary sentence, that is stated.**

| Frontier | Rectangle | Commit | Artifact | Headline result, as measured |
| :---: | :--- | :--- | :--- | :--- |
| 1 | 1 — Model Governance & Intake Masking | `d2935f3` | [`inventory/EVAL-GBNF-INTAKE-BENCH-20260908.md`](../../inventory/EVAL-GBNF-INTAKE-BENCH-20260908.md) | 482.72 ns/triple, 2,071,574 triples/s, 0 heap bytes, 100% illegal-syntax rejection (Coffee Lake) |
| 2 | 2 — Deterministic pre-Execution Context Assembly | `3e1d5ab` | [`inventory/EVAL-DETERMINISTIC-CONTEXT-ASSEMBLY-20260908.md`](../../inventory/EVAL-DETERMINISTIC-CONTEXT-ASSEMBLY-20260908.md) | 5,408 packs/s, 184.91 µs/pack, **0.000% byte variance** over $N=10{,}000$, 650 B pack |
| 3 | 3 — Physical silicon streaming | `faacd90` | [`inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md`](../../inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md) | 3,644,530 cells/s, 252.686 ns mean DMA, 118.174 GiB/s bidirectional, $\Delta T_{\text{CPU}} = 0.0$ °C |
| 4 | 4 — Grand Fusion composed intent loop | `2368a5b` | [`inventory/EVAL-GRAND-FUSION-BENCH-20260908.md`](../../inventory/EVAL-GRAND-FUSION-BENCH-20260908.md) | 1,118,133 cycles/s, 894.35 ns/cycle, 100,000/100,000 GPU skips, 0 heap bytes |

### 9.10.1 Frontier 1 closes the §9.9 gap — the mask is wired, and truncation is now an error

§9.9's three-tier answer to Blackmagic Question 1 found that (i) `parse_and_contract` performed a
literal substring search rather than a grammar check, (ii) `stampApprovedTriple` enforced a closed
vocabulary on the *relation* only, by hand-written 8-way string match, and (iii) `Term.makeId`
silently truncated subject and target to 16 bytes, so two 200-byte identifiers sharing a 16-byte
prefix collided into one `subject_id`. Verified against
[`src/intake_gate.zig`](../../src/intake_gate.zig) on this commit, all three are now closed by
real code, not by assertion:

- `computeRelationTokenMask` / `validateRelationGbnf` (lines 64, 109) walk the candidate relation
  character by character against a 256-bit `TokenMask` (`[4]u64`, imported directly from
  `lsp_indexer` at line 19) and return `IntakeError.TokenMaskedByGrammar` **at the first invalid
  byte**, not after a full-string compare. The artifact's rejection vectors record where: index 0
  for `"delete_database"`, index 12 for `"assert_relatXon"`, index 5 for the SQL-injection payload
  `"admin'--"`.
- `computeIdentifierTokenMask` / `validateIdentifierGbnf` (lines 75, 96) apply the same treatment
  to subject and target against `[a-zA-Z_][a-zA-Z0-9_.-]*`, and — the tier-(iii) fix —
  `if (token.len > MAX_TERM_BYTES) return IntakeError.TermLengthExceeded` (line 98) converts the
  silent 16-byte truncation into a **hard, typed refusal**. The prefix-collision failure mode
  §9.9 identified is not mitigated; it is made unreachable.
- `parseAndValidateTriple` (line 292) is the composed front door, calling identifier → relation →
  identifier validation in order (lines 274–280) before stamping the 64-byte
  `=Q16s16s16sII` header of Invariant A-2.

**In the vocabulary of this section**, Frontier 1 is the first real instance of §9.3's *Row 1*
veto realization — the hard-refusal exception pattern — applied outside `checkHopLimit`. §9.3's
closing recommendation was that any future veto "should be built on the exception/refusal pattern
(row 1), which already has that property." Frontier 1 did exactly that, and independently: the
mask returns an error before the candidate is scored, ranked, or admitted, which is the
$E = \infty$ semantics of Definition 9.1 realized as control flow rather than as a large float.

**One discrepancy in the artifacts, reported rather than reconciled by choice.** Two different
Frontier 1 throughput figures are on disk, and this whitepaper should cite one:
[`EVAL-GBNF-INTAKE-BENCH-20260908.md`](../../inventory/EVAL-GBNF-INTAKE-BENCH-20260908.md) §3 measures
**482.72 ns / 2,071,574 triples/s** at $N = 100{,}000$ on Pop!_OS Coffee Lake, while
[`EVAL-GRAND-FUSION-BENCH-20260908.md`](../../inventory/EVAL-GRAND-FUSION-BENCH-20260908.md) §5 and
the directing council directive both summarize Frontier 1 as **634 ns / 1.57 M triples/s**
($1/634.76\text{ ns} = 1.575$ M/s, so the two figures are internally consistent as *two different
runs*, not as a typo). Neither number is wrong; they are simply not the same measurement, and no
artifact states which host or build the 634.76 ns run was taken on. The disk-first resolution is a
single re-run of `zig build bench-gbnf-intake` reported once, with host and build mode named — not
an editorial choice between two numbers already published. Until then, this section cites 482.72
ns as the figure whose provenance is fully documented, and flags the 634.76 ns figure as
**unattributed**.

### 9.10.2 Frontier 2 supplies the first real $E_{\text{alloc}}$-class instrument at pack granularity

§9.3 grounded $E_{\text{alloc}}(e)$ as a "real measurement technique, not yet a per-edge compiler
signal," pointing at the byte-counting allocator of the lexicon-collapse benchmark. Frontier 2
adds a second, differently-shaped instrument at a coarser granularity: a **content-addressed,
byte-stable execution packet whose size is a measured constant.** The boot pack is 650 bytes —
3.73% of Invariant A-1's 17,408 B, leaving 96.27% headroom — and its canonical serialization
(`json.dumps(pack, sort_keys=True, separators=(",", ":"))`) produced **0.000% byte variance across
$N = 10{,}000$ runs**, with a per-file SHA-256 manifest so that mutating any listed file changes
the pack digest and mutating an unlisted file does not.

This matters to §9.4's contraction-shortcut proposal in a way worth stating precisely, because it
is the closest thing on disk to the mechanism §9.4 proposed and could not point at. §9.4 proposed
memoizing a low-energy compilation path keyed by the 48-byte routing fingerprint
(`fingerprints[0]`) of its subgraph, and flagged the honest failure mode: *a fingerprint memoized
today is invalidated the instant its subgraph's source bytes change.* Frontier 2 implements
exactly that invalidation rule, one level up — content-addressing over a closed file manifest, so
the digest **is** the staleness check — and demonstrates it is cheap enough to run per pack at
184.91 µs including disk I/O and per-file hashing. What Frontier 2 does **not** do is answer §9.4's
open empirical question: it proves the invalidation mechanism works, not that real source churns
slowly enough for a memo keyed on it to have positive expected value. The fingerprint-stability
half-life measurement §9.4 called for remains unrun.

### 9.10.3 Frontier 3 promotes Invariant A-1 from a memory layout to a wire format

Everything Section 2 proves about the 17,408-byte Cell is proved about *host memory*: 272 whole
cache lines, sub-structures on 64 B boundaries (Theorem 2.2), no false sharing between them
(Theorem 2.3). Frontier 3 is the first evidence in this whitepaper that the same constant survives
a crossing it was never proved for — the host↔device DMA boundary to a physically distinct
accelerator.

On Brandys (AMD Ryzen 7 8700F, Phoenix NPU `[0000:12:00.1]`, XRT 2.21.75, `amdxdna`
2.21.260102.53), `scripts/brandys_npu_stream_bench.cpp` streamed 100,000 cells of **exactly
17,408 bytes** bidirectionally through `/dev/accel/accel0` via double-buffered `xrt::bo`
host-pinned buffer objects: 3.48 GB moved in 27.44 ms, **252.686 ns mean latency** (min 240 ns,
p50 250 ns, p95 270 ns, p99 320 ns, max 13,531 ns on the initial cache-sync spike), **118.174
GiB/s** bidirectional. The tail distribution is the load-bearing detail for this section's
purposes: a p99/p50 ratio of $320/250 = 1.28$ means the DMA path is not merely fast on average but
*jitter-bounded*, which is the property a synchronous energy gate needs if $E_{\text{NPU}}$ is ever
to be sampled inside a hot loop rather than estimated.

Two secondary results are worth recording because they bear directly on the PoE governor's
happy path: post-test CPU and GPU-edge temperatures were **identical to the idle baseline**
(37.0 °C and 34.0 °C, $\Delta = 0.0$ °C), and the artifact records **zero GPU wakes** during the
burst. The claim "NPU offloading keeps the host cold while the 12 GB Radeon stays asleep" is
therefore thermally instrumented, not inferred.

**What Frontier 3 does not establish**, stated plainly: the benchmark streams cells and measures
transport. It does not execute the substrate's query, scoring, or governor logic *on* the NPU's
compute tiles. "The 17,408 B geometry runs on physical silicon" is true in the sense that the
geometry crosses the physical interface at line rate with the invariant intact; it is not yet true
in the sense that XDNA tiles evaluate $E_{\text{NPU}}$. This is a transport proof, and the
distinction should not be allowed to blur in later sections.

### 9.10.4 Frontier 4 supersedes §9.3's Row 4 — $E_{\text{joint}}$ is now code, and 1004 is now a gate

This is the finding that most changes Section 9. Revision 2's veto taxonomy stated that
`negative_affinity_veto` (LogicOp 1004) "is not itself a register-level or hardware-dispatch
mechanism — no code in this repository issues opcode 1004 to a CPU pipeline stage," and that "no
compiler pass performs this measurement per-edge today." [`src/ebm_governor.zig`](../../src/ebm_governor.zig)
now exists (commit `9a54557`, exercised end-to-end by `2368a5b`) and implements a real joint
energy gate. Read against its source rather than its summary:

$$
E_{\text{joint}} = E_{\text{NPU}} + E_{\text{CPU}} + E_{\text{GPU}}, \qquad
E_{\text{GPU}} = \begin{cases} \varnothing & \text{if } \texttt{b2b\_gap} < 0.0100 \\ g & \text{otherwise} \end{cases}
$$

with `evaluate(terms, hop)` (line 66) refusing on `hop > 4` **before** the sum is computed
(Invariant A-11, and structurally the ordering §9.3 Row 1 argued for), then returning
`error.HardVeto` when $E_{\text{joint}} \ge 500$. `PoeGovernor.tryCommit` (line 96) calls
`stampVeto` on either error path, writing `OPCODE_VETO = 1004` into the cell's first 8 bytes, and
**returns without reaching `file.writePositionalAll`** — the veto is synchronous with respect to
durable storage, and its unit test asserts precisely that: on veto the cell's opcode reads 1004
and the file's size does not grow (`tests` in [`src/ebm_governor.zig`](../../src/ebm_governor.zig),
`"tryCommit writes 17408 B on pass and writes 0 B on veto"`).

The design decision worth formalizing here is the **null-versus-zero distinction**, which the
source states in its own header comment and enforces in `compose`/`jointEnergy` (lines 50, 58):
a skipped GPU contributes $\varnothing$, not $0$. In a log-space product-of-experts,
$E_i = 0$ means "expert $i$ assigns probability 1" — perfect agreement — whereas the intended
meaning is "expert $i$ was never consulted." Encoding the skip as `?u32 = null` rather than as
`0` is what keeps a sleeping accelerator from silently voting *in favor* of every candidate. Its
own regression test makes the point at the extreme: `compose(40, 10, 0.0, 1_000_000)` yields
$E_{\text{joint}} = 50$, because a GPU term of one million is not added — it is absent.

**§9.3's veto taxonomy, restated against the current tree:**

| Realization | Revision 2 verdict | Revision 3 verdict, verified on this commit |
| :--- | :--- | :--- |
| Hard refusal (`checkHopLimit`, A-11) | Exact | **Unchanged and now duplicated** in `ebm_governor.evaluate` line 67, which checks hop before energy |
| Score-zeroing veto (A-8, `composite = 0.0`) | Approximate — bounded worst case | Unchanged |
| Absorbing contradiction (Sudoku `Mask == 0`) | Exact within a closed domain | Unchanged |
| GBNF token mask (new in Revision 3) | *did not exist* | **Exact** — `TokenMaskedByGrammar` / `TermLengthExceeded` thrown at the offending byte, before any header is stamped (§9.10.1) |
| `negative_affinity_veto` (opcode 1004) | Data only; "not a mechanism" | **Superseded.** 1004 is now stamped by `stampVeto` on the hard-veto and hop-kill paths, synchronously ahead of the cell-bank write. It remains **not** a CPU instruction-dispatch trap — the stamp is a memory store into an aligned buffer, and "register-level hardware veto" still overstates it — but the Revision 2 sentence "no code in this repository issues opcode 1004" is now false. |

The composed loop ([`tests/test_grand_fusion.zig`](../../tests/test_grand_fusion.zig)) runs all
five stages — GBNF intake → header stamp into a shadow `geometry.Cell` → PoE evaluate → dual-head
atomic pointer swap → `pushWithBackpressure` onto the lock-free ring plus a `readAt` to advance
the reader — at **894.35 ns/cycle, 1,118,133 cycles/s over $N = 100{,}000$, with 0 dynamic heap
bytes and 100,000/100,000 GPU skips**, and asserts each of those as a test expectation rather than
printing them as prose (`expectEqual(ITERS, gpu_skip_count)`, `expectEqual(ITERS, gov.commits)`).

A useful decomposition falls out of composing two artifacts: if Frontier 1's documented triple
stamp costs 482.72 ns, then **Stage 1 alone accounts for ≈54% of the entire 894.35 ns fused
cycle** — the intake grammar check, not the governor, the pointer swap, or the ring, is the
dominant term. Under the unattributed 634.76 ns figure it would be ≈71%. Either way the
optimization target is unambiguous, and it is the stage this section spent Revision 2 arguing
should exist at all.

### 9.10.5 What the Frontiers did *not* close — the two $E_{\text{joint}}$s are different functions

The single most important thing this synthesis can do for the whitepaper's credibility is prevent
a name collision from being read as a result. **`ebm_governor.zig`'s $E_{\text{joint}}$ and
Definition 9.1's $E_{\text{joint}}$ are not the same function, share exactly one term, and answer
different questions.**

| | Definition 9.1 (§9.3) — *proposed* | `src/ebm_governor.zig` — *shipped* |
| :--- | :--- | :--- |
| Domain | An edge $e$ in a program's AST / compilation graph | A candidate cell commit at runtime |
| Terms | $E_{\text{cache}}, E_{\text{hop}}, E_{\text{alloc}}, E_{\text{simd}}$ | $E_{\text{NPU}}, E_{\text{CPU}}, E_{\text{GPU}}$ |
| Combination | Convex: $\sum \lambda_i E_i$, $\sum \lambda_i = 1$ | Saturating unweighted sum (`+|=`) over `u32` |
| Question answered | *Which lowering of this AST node is cheapest?* | *Should this cell be written to the bank at all?* |
| Shared term | — | $E_{\text{hop}}$ / hop depth, Invariant A-11, in both |
| Status | Formal specification awaiting first implementation | Implemented, unit-tested, benchmarked on metal |

Everything §9.6's Gegenrede said therefore still stands, and this revision does not soften it.
There is still no parser, no AST walker, and no code generator that consults a per-edge energy
cost; §9.4's contraction-shortcut cache is still unimplemented and its fingerprint-stability
half-life still unmeasured; and the §9.6.3 pilot — a single Zig module's inlining decisions scored
by a two-term $(E_{\text{hop}}, E_{\text{alloc}})$ objective, measured against `-OReleaseFast`
alone — has not been built. **Frontier 4 closed the governor half of the energy framing and left
the compiler half exactly where Revision 2 found it.** Reporting "the EBM is proven" without that
sentence attached would be the precise error §9.8 was written to prevent.

Likewise unresolved: §9.5's `.ReleaseSafe`/`.ReleaseFast` tension. Every Frontier figure above was
taken in `-O ReleaseFast`, the mode that compiles out the bounds and overflow checks that §9.5
identified as the only real "below-the-AST" enforcement layer in the tree. Frontier 1's grammar
mask is a genuine improvement to intake integrity, but it validates *identifiers and relations at
the front door*; it is not a substitute for bounds checking in the hot path, and no artifact in
`proof/` yet measures the same benchmark in both build modes on the same host. That measurement
remains the concrete follow-up §9.5 asked for.

### 9.10.6 Three artifact caveats, read off the sources rather than the summaries

Per the discipline established in §9.9's closing paragraph — where reading
`test_ebm_compiler_bloat_bench.zig` against its own report found hardcoded energy literals and an
Arm C that was *slower* than both baselines — the four Frontier artifacts were read the same way.
Three things do not hold up exactly as their summaries state, none fatal, all worth fixing before
publication:

1. **"Grand Fusion" does not stream through the NPU.** The Frontier 4 artifact's header lists
   "AMD x86_64 Host (`pop`) + AMD XDNA NPU Stream Pipeline (`brandys`)" and its Stage-3 diagram
   names the NPU. Verified by `grep` against
   [`tests/test_grand_fusion.zig`](../../tests/test_grand_fusion.zig): the strings `accel0`,
   `xrt`, and `NPU` appear **only inside doc comments**. No XRT call, no `/dev/accel/accel0` open,
   no DMA occurs in the fused loop; $E_{\text{NPU}}$ is supplied as the literal `45` to
   `compose(45, 30, gap, 250)`. Frontier 3 and Frontier 4 are two separate binaries on two
   separate hosts, and the honest composed claim is *"stages 1–5 fused in one process at 894.35
   ns/cycle, with the NPU transport proven separately at 252.686 ns/cell"* — not that a cell
   traversed both in one cycle.
2. **The dual-host cluster topology is precisely demarcated.** The Frontier 4 Grand Fusion benchmark
   was executed on the local Intel Core i5-8300H client (`pop`, Coffee Lake, AVX2), while physical
   silicon NPU streaming was benchmarked on Brandys (`10.10.10.2`, mounted locally at `/mnt/brandys` via
   NFSv4.2), which provides an AMD Ryzen 7 8700F (Zen 4, full AVX-512 including `avx512_vnni` and `avx512_bf16`)
   and the AMD XDNA Phoenix NPU (`/dev/accel/accel0`). Because the 894.35 ns loop ran on `pop`'s older 4-core
   Intel AVX2 processor, it represents an empirical *floor*, not a ceiling, for execution on Brandys's
   Zen 4 AVX-512 lane. Both hosts, their respective hardware flags, and the NFS mount are verified on disk.
3. **The fused cycle contains no durable write, and Stage 2 is a header store.** The hot loop
   calls `ebm_governor.evaluate` (the pure gate), never `tryCommit`, so no `pwrite` occurs inside
   the 894.35 ns; and Stage 2's cell "assembly" is `shadow.header = header` into a preallocated
   dual-head `geometry.Cell`, not the construction of a fresh 17,408-byte payload. Both choices are
   defensible — they are what makes the loop allocation-free and what isolates compute from I/O —
   but the number must be reported as **an in-memory composed-intent cycle**, not as an
   end-to-end persisted transaction rate, or it will be compared against SQLite's durable
   `tx/s` figures in Section 5 and the comparison will not be like-for-like.

---

## 9.11 Rectangle status, refreshed against `main` @ `2368a5b`

Superseding the Rectangle 1 table of §9.9 and the Rectangle 2–5 notes below it:

| Rectangle | Title | Status on this commit | Verified how |
| :---: | :--- | :--- | :--- |
| 1 | DBMS-Enforced Model Governance & Identity Parsing | **Closed at unit level, GBNF gap now also closed.** Tasks 1–5 done (§9.9); the GBNF-mask wiring §9.9 left open is closed by `d2935f3` (§9.10.1). Task 14 (cross-Rectangle integration test) **superseded in substance** by `tests/test_grand_fusion.zig`, which exercises `intake_gate` + `boot_pack`-class assembly + `ebm_governor` + `ipc_ring` in one run — broader than Task 14 specified, though it omits `boot_pack.zig` itself in favor of an in-test cell assembly. | Source read + `proof/EVAL-GBNF-INTAKE-BENCH` |
| 2 | Deterministic pre-Execution Context Assembly (Tasks 15–20) | **Closed.** §9.9 recorded this as "status unknown, presumed still open until a seat audits it directly." Audited now: all six tasks implemented and measured at 0.000% byte variance. | `3e1d5ab` + `proof/EVAL-DETERMINISTIC-CONTEXT-ASSEMBLY` |
| 3 | Fixed-Width Working Memory with Fractal Split-on-Overflow | **Closed** (unchanged from §9.9: `boot_pack.zig` calls `mitosis.splitWrite` on overflow). Frontier 3's silicon streaming is a *different* Rectangle-3 sense of the word — transport of the fixed-width cell, not split-on-overflow — and the two should not be reported as one closure. | Source read + `proof/EVAL-BRANDYS-XDNA-NPU-STREAM` |
| 4 | *(spec never supplied under Scheme A)* | Scheme A's Rectangle 4 remains **`BLOCKED-missing-spec`**. The "Frontier 4 / Rectangle 4 = Grand Fusion" pairing used by the Frontier artifacts is a **third numbering**, distinct from both Scheme A and Scheme B (§9.8). It names real, verified work; it does not supply Scheme A's missing Rectangle 4 spec. | §9.8 disambiguation + `inventory/WORKORDER-5-open-rectangles-20260907.md` |
| 5 | TCP-Isomorphic Task Arbitration without Distributed Mutexes | **Closed in practice.** §9.9 noted `pushWithBackpressure` existed but that "no caller outside `ipc_ring.zig` invokes either path yet." That is no longer true: the Grand Fusion loop calls `pushWithBackpressure` as its Stage 5 and asserts `IpcError.BufferFull` on capacity exhaustion, so the safe path is now the exercised default at a real call site. | `tests/test_grand_fusion.zig` |

**The numbering warning §9.8 raised now applies a third time.** Scheme A (canonical engineering
rectangles), Scheme B (F-series literature-gap cards), and the Frontier 1–4 series each number
things 1–5 or 1–4, and each means something different. This section's position is unchanged:
Scheme A is *the* 5 Open Rectangles framework for engineering closure, the Frontier series is a
parallel, well-evidenced execution track that happens to close Scheme A's Rectangles 1, 2, and 5,
and no amount of Frontier evidence supplies Scheme A's Rectangle 4 specification, which nobody has
written.

---

## Link proposer

- **Links**: Section 2.1/2.3 (Cell geometry and seqlock proofs this section's $E_{\text{cache}}$/$E_{\text{hop}}$ terms generalize); Section 2.5 (Invariant A-1 as a DMA wire format, the geometric counterpart to §9.10.3); Section 7.5 and Section 8.5 (the two prior Gegenrede this appendix's §9.6 follows the same discipline as); `src/controller.zig`; `src/lexicon.zig`; `src/intake_gate.zig`; `src/ebm_governor.zig`; `src/skill_registry.zig`; `src/mitosis.zig`; `src/boot_pack.zig`; `src/ipc_ring.zig`; `tests/test_grand_fusion.zig`; `inventory/WORKORDER-5-open-rectangles-20260907.md`; [hamil2026ebmsudoku].
- **Keywords**: energy-based compilation, product-of-experts governor, null-versus-zero expert skip, contraction hierarchy, failure scar, negative affinity veto, Map-Compliance, below-the-AST security, ReleaseSafe/ReleaseFast tension, 5 Open Rectangles, Frontier 1–4 Grand Fusion, Blackmagic Interrogation, model governance.
- **Gegenrede (open, Revision 3)**: (1) Build the two-term ($E_{\text{hop}}$, $E_{\text{alloc}}$) single-module inlining pilot proposed in §9.6.3 and report whether it beats `-OReleaseFast` alone — **unchanged by the Frontiers**, which closed the governor half of the energy framing and not the compiler half (§9.10.5). (2) Re-run `zig build bench-gbnf-intake` once, with host and build mode named, to retire the unattributed 634.76 ns Frontier 1 figure (§9.10.1). (3) Correct the Frontier 4 artifact's host attribution and restate its 894.35 ns as an *in-memory composed-intent cycle* with no durable write and no NPU DMA in the loop (§9.10.6). (4) Measure the same benchmark in `.ReleaseSafe` and `.ReleaseFast` on one host before "below-the-AST memory security" is claimed of the shipped fast build (§9.5). (5) Measure fingerprint-stability half-life over this repository's own git history before the §9.4 contraction cache is implemented.
- **Retired this revision**: the Revision 2 Gegenrede item "wire the GBNF `TokenMask` into `intake_gate.zig`" is **closed** by commit `d2935f3` (§9.10.1) — recorded here rather than deleted, so the loop from finding to closure stays legible.

## Validation (Luhmann)

| Principle | Status |
| :--- | :--- |
| Atomicity | This section is readable on its own given Sections 2 and 7's prior proofs, `src/controller.zig`, `src/lexicon.zig`, `src/intake_gate.zig`, `src/ebm_governor.zig`, the four `proof/EVAL-*` Frontier artifacts, and the two `inventory/`/`ai/memory-bank/tasks/` files disambiguating the Rectangle schemes. |
| Connectivity | ≥2 links: the geometry/seqlock proofs of Section 2 (and §2.5's DMA-boundary corollary); the Gegenrede discipline of Sections 7 and 8; Seat Antigravity's cross-seat Sudoku EBM; the canonical Rectangle task list; the four Frontier evaluation artifacts. |
| Organic growth | No new taxonomy invented beyond `lexicon.zig`'s existing 20-member `DefectClass`, `references.bib`'s `hamil2026*` convention, and the Rectangle numbering that already exists in `inventory/`. Revision 3 adds one row to §9.3's existing veto taxonomy (the GBNF mask) and one distinction table (§9.10.5) rather than a new framework. |
| Continued dialogue | §9.4's fingerprint-stability measurement, §9.6's two-term inlining pilot, §9.5's dual-build-mode measurement, and the three artifact corrections of §9.10.6 are left explicitly open. Two prior open items — the GBNF-mask wiring and Rectangle 2's unaudited status — are recorded as **closed by Frontiers 1 and 2**, with the superseded text retained in place so the finding→closure loop stays inspectable. |
