# 2. Mathematical Geometry

**Section of**: *The Hamil Memory Controller: Abolishing the Relational Tax via
Hardware-Symbiotic Cellular Memory and the Semantic Sidecar*
**Author**: Christopher Hamil, Tree of Thoughts Hybrid Systems Laboratory
**Section Author (drafting)**: Seat 0 (`council-claude`), Chief Systems Theorist & Mathematical Foundations
**Core Reference Specification**: [`research/RFC-0001-HAMIL-CELLULAR-MEMORY-SUBSTRATE.md`](../RFC-0001-HAMIL-CELLULAR-MEMORY-SUBSTRATE.md)
**Grounding Source Files**: [`src/geometry.zig`](../../src/geometry.zig), [`src/ipc_ring.zig`](../../src/ipc_ring.zig), [`src/gate_lattice_laws.zig`](../../src/gate_lattice_laws.zig), [`src/sqlite_sidecar.zig`](../../src/sqlite_sidecar.zig), [`src/intake_gate.zig`](../../src/intake_gate.zig), [`src/lsp_indexer.zig`](../../src/lsp_indexer.zig)
**Directive**: `DIRECTIVE-COUNCIL-20260908-HAMIL-WHITEPAPER-RD-LANE`, finalized under `DIRECTIVE-COUNCIL-20260908-BRANDYS-RESEARCH-PAPERS-EXECUTION`
**Revision 2 (2026-09-08)**: §2.4 (Invariant A-2 as a grammar terminal — Theorems 2.9–2.10, first-byte refusal and injective identifier construction) and §2.5 (Invariant A-1 as a transport-invariant DMA wire format — Theorems 2.11–2.12) added, following the Frontier 1 and Frontier 3 hardware verifications on `main` @ `2368a5b`. §2.1–§2.3 are unchanged; the prior §2.4 Summary is renumbered §2.6.

---

This section formalizes the two physical geometry invariants introduced in
[RFC-0001 §1](../RFC-0001-HAMIL-CELLULAR-MEMORY-SUBSTRATE.md#1-physical-geometry-invariants)
— **Invariant A-1** (the 17,408-byte Cell) and **Invariant A-2** (the 64-byte
instruction header) — as mathematical claims with proofs, then formalizes
the **Seqlock Memory Barrier Protocol** that governs every concurrent read
against the substrate, single-process and multi-process. Every structural
constant cited below is enforced not only by this proof but by a
`comptime` assertion in the implementation itself — the Zig compiler
refuses to build the substrate if any of these relationships do not hold,
so drift between this section and the running system is a compile error,
not a documentation-maintenance burden.

---

## 2.1 Invariant A-1: The 17,408-Byte Cell

### 2.1.1 Definition

**Definition 2.1 (Cache Line).** A cache line is the minimum unit of memory
a CPU's coherency protocol (MESI, MOESI, and their variants on all modern
x86_64 and AArch64 implementations) tracks, transfers between cache levels,
and invalidates atomically with respect to other cores. On every
microarchitecture this substrate targets — Intel Coffee Lake and AMD Zen 4
alike — this unit is:
$$L = 64 \text{ bytes.}$$

**Definition 2.2 (Cell).** The Cell (`geometry.Cell`, [`src/geometry.zig:178`](../../src/geometry.zig))
is the atomic unit of storage and transmission in the Hamil substrate,
composed of three disjoint, contiguous sub-regions:

$$
\text{Cell} = \underbrace{\text{Header}}_{H} \;\|\; \underbrace{\text{Fingerprints}}_{F} \;\|\; \underbrace{\text{SemanticPayload}}_{S}
$$

where, per the implementation:

$$
|H| = 64\text{ B}, \qquad
|F| = 32 \times 512\text{ B} = 16{,}384\text{ B}, \qquad
|S| = 960\text{ B}.
$$

**Theorem 2.1 (Invariant A-1).**
$$
|\text{Cell}| = |H| + |F| + |S| = 64 + 16{,}384 + 960 = 17{,}408 \text{ bytes} = 272 \times 64 \text{ bytes} = 272L.
$$

*Proof.* By direct arithmetic on the definitions above:
$64 + 16{,}384 + 960 = 17{,}408$, and $17{,}408 / 64 = 272$ exactly (no
remainder), so the Cell occupies precisely 272 whole cache lines with zero
partial-line remainder. $\blacksquare$

This is not merely asserted in prose: [`src/geometry.zig`](../../src/geometry.zig)
enforces it at compile time —
`std.debug.assert(@sizeOf(Cell) == 17408)`,
`std.debug.assert(@sizeOf(Cell) == CELL_BYTES)` where
`CELL_BYTES = CELL_CACHE_LINES * CACHE_LINE_BYTES = 272 * 64` — making
Theorem 2.1 a build-time invariant rather than a documentation claim that
could silently drift from the running code.

### 2.1.2 Theorem: Zero-Remainder Sub-Structure Alignment

The stronger and more architecturally consequential claim is not merely
that the *whole* Cell is a multiple of the cache line width, but that
*every independently-addressed sub-region within it* begins on a cache-line
boundary — which is the precondition for the false-sharing and
memory-tearing elimination proved in §2.1.3.

**Theorem 2.2 (Sub-Structure Line Alignment).** Let $\text{off}(X)$ denote
the byte offset of sub-region $X$ from the start of a Cell. Then for the
header, every one of the 32 fingerprint vector slots $F_0, \dots, F_{31}$,
and the semantic payload:
$$
\text{off}(H) \equiv 0, \quad \text{off}(F_i) \equiv 0 \;\; \forall i \in [0,32), \quad \text{off}(S) \equiv 0 \pmod{64}.
$$

*Proof.* By construction of the layout:
- $\text{off}(H) = 0 \equiv 0 \pmod{64}$ trivially.
- Each $F_i$ is a `FingerprintVector` of exactly $64 \times 8\text{ B} = 512\text{ B}$
  ([`src/geometry.zig:163`](../../src/geometry.zig), `FINGERPRINT_VECTOR_WORDS = 64`
  words of `u64`), so $\text{off}(F_i) = |H| + 512i = 64 + 512i$. Since
  $64 \equiv 0$ and $512i = 8 \cdot 64 \cdot i \equiv 0 \pmod{64}$ for every
  integer $i$, the sum is $\equiv 0 \pmod{64}$ for all $i \in [0, 32)$.
- $\text{off}(S) = |H| + |F| = 64 + 16{,}384 = 16{,}448$, and
  $16{,}448 / 64 = 257$ exactly, so $\text{off}(S) \equiv 0 \pmod{64}$.

Each case holds, so the theorem holds for every named sub-region.
$\blacksquare$

These offsets — $0$, $64$, $16{,}448$ — are, again, not merely proved here
but asserted at compile time in [`src/geometry.zig`](../../src/geometry.zig):
`@offsetOf(Cell, "header") == 0`, `@offsetOf(Cell, "fingerprints") == 64`,
`@offsetOf(Cell, "semantic_payload") == 16448`.

**Corollary 2.2.1 (Array Alignment Propagates).** For an array of Cells
indexed $0, 1, 2, \dots$, the $k$-th Cell begins at byte offset
$k \cdot 17{,}408$. Since $17{,}408 = 272 \times 64 \equiv 0 \pmod{64}$
(Theorem 2.1), every Cell in the array is itself cache-line-aligned
whenever the array's base address is, by induction on $k$: the base case
$k=0$ holds by hypothesis, and the inductive step
$k\cdot 17{,}408 \equiv 0 \implies (k+1)\cdot 17{,}408 = k\cdot17{,}408 + 17{,}408 \equiv 0 + 0 = 0 \pmod {64}$
holds because $17{,}408 \equiv 0 \pmod{64}$. This is why a contiguous
buffer of $N$ Cells (as used by [`src/ipc_ring.zig`](../../src/ipc_ring.zig)'s
`LockFreeRingBuffer(geometry.Cell, N)` and `SharedCellRing(N)`) never
requires per-element padding to preserve alignment — the geometry is
self-similar under array indexing.

### 2.1.3 Theorem: Elimination of False Sharing and Memory Tearing

**Definition 2.3 (False Sharing).** Two logically independent values $a, b$
suffer false sharing if they reside within the same cache line $L_i$ such
that a write to $a$ by core $c_1$ forces cache-coherency invalidation of
$L_i$ on core $c_2$, which holds $b$ live in its own cache and was not
itself modified — i.e., coherency traffic is generated by *proximity*, not
by a genuine data dependency.

**Definition 2.4 (Memory Tearing).** A reader observes memory tearing if it
reads a value $v$ spanning byte range $[o, o+n)$ while a concurrent writer
is mid-store to that same range, such that the reader's observed bytes are
a mixture of the pre-write and post-write states — neither fully old nor
fully new.

**Theorem 2.3.** Under the Hamil substrate's write discipline — where
distinct logical sub-fields of a Cell are written by at most one writer at
a time per field, and every sub-field boundary satisfies Theorem 2.2 — no
two independently-mutated sub-fields of a Cell (nor of two adjacent Cells
in an array, by Corollary 2.2.1) can produce false sharing between each
other, and no cache-coherency-atomic write (≤ 64 B, naturally aligned) can
be observed torn.

*Proof.* Modern cache coherency protocols transfer and invalidate cache
lines as indivisible 64-byte units; two byte ranges that do not share any
64-byte-aligned line cannot generate coherency traffic against each other,
by the definition of the protocol's own granularity. By Theorem 2.2, every
named sub-region of a Cell — the header, each of the 32 independent
fingerprint slots, and the semantic payload — begins on a 64-byte boundary
and (by its own declared size, itself a multiple of 64 B for $H$ and every
$F_i$) ends on one too. Therefore no two *distinct* named sub-regions can
share a physical cache line, which by Definition 2.3 rules out false
sharing between them categorically, not merely statistically.

For memory tearing: any store of $\leq 64$ bytes to a naturally 64-byte-
aligned address is guaranteed atomic with respect to the cache-coherency
protocol on x86_64 and AArch64 — the CPU cannot observe or transfer a
partial cache line. Since the substrate's individually-addressed fields
(the 8-byte `opcode`, the 16-byte `subject_id`, etc. within the 64-byte
header; each 512-byte-but-64-byte-line-aligned `FingerprintVector`) never
straddle a line boundary, by Theorem 2.2, every atomic store the substrate
issues to one of these fields is a store the coherency protocol itself
treats as indivisible. Where a write is *larger* than one line (e.g. the
full 17,408-byte Cell, or writing an entire `FingerprintVector`), atomicity
of the *whole* write is not claimed from alignment alone — that guarantee
is provided separately, by the seqlock protocol of §2.3, which is exactly
why the substrate layers a seqlock over the geometry rather than relying on
geometry alone for whole-record consistency. $\blacksquare$

**Corollary 2.3.1 (SIMD Load Legality).** Because every field boundary is
64-byte aligned (Theorem 2.2) and 64 bytes is an integer multiple of every
SIMD register width the substrate targets (16 B for `@Vector(16, u8)` on
the `subject_id`/`predicate_op`/`target_val` fields, 32 B for AVX2 `ymm`,
64 B for AVX-512 `zmm`), every SIMD load the query path issues against a
Cell's header is guaranteed to complete within a single cache line — never
split across two lines, which on real microarchitectures costs a
measurable, and on some generations a severe, additional-µop penalty. This
is the geometric precondition for the in-register evaluation proved in
§2.2.2, and its effect is directly visible in measurement: cold,
cross-spoke-hopping SIMD scans (Arm B1/B2, where alignment holds but
locality does not) sustain IPC 0.30 (point) / 0.41 (multi-constraint),
while warm, line-resident scans against the identical geometry (Arm B3/B4)
sustain IPC 1.32 / 1.43 respectively — a 4.4x (point) and 3.5x
(multi-constraint) efficiency gain, attributable to cache residency
compounding on top of, not substituting for, the alignment guarantee
proved here
([`inventory/EVAL-1M-QUERY-BENCH-20260908.md`](../../inventory/EVAL-1M-QUERY-BENCH-20260908.md), Table, §2.2).

---

## 2.2 Invariant A-2: The 64-Byte `=Q16s16s16sII` Header

### 2.2.1 Definition and Size Proof

**Definition 2.5 (Canonical Instruction Header).** The physical,
on-the-wire instruction header format is the Python `struct`-notation
layout `=Q16s16s16sII`, implemented byte-for-byte as
`gate_lattice_laws.InstructionHeader` ([`src/gate_lattice_laws.zig:31`](../../src/gate_lattice_laws.zig)):

| Format Code | Field | Width | Offset |
| :---: | :--- | :---: | :---: |
| `Q` | `opcode` (`u64`) | 8 B | `0x00` |
| `16s` | `subject_id` (`[16]u8`) | 16 B | `0x08` |
| `16s` | `predicate_id` (`[16]u8`) | 16 B | `0x18` |
| `16s` | `target_id` (`[16]u8`) | 16 B | `0x28` |
| `I` | `flags` (`u32`) | 4 B | `0x38` |
| `I` | `epoch` (`u32`) | 4 B | `0x3C` |

**Theorem 2.4 (Invariant A-2).**
$$
8 + 16 + 16 + 16 + 4 + 4 = 64 \text{ bytes} = 1L.
$$

*Proof.* Direct summation of Definition 2.5's field widths. $\blacksquare$
Enforced at compile time: `std.debug.assert(@sizeOf(InstructionHeader) == 64)`,
`std.debug.assert(@alignOf(InstructionHeader) == 64)`
([`src/gate_lattice_laws.zig:39-42`](../../src/gate_lattice_laws.zig)).

**Remark 2.4.1 (The In-Memory Isomorphism).** The substrate's live,
in-memory ring buffer path uses a second, bit-packed representation,
`geometry.BytecodeHeader`, which folds `flags` and `epoch` into a single
64-bit `provenance_flags` word ($ \text{prov} = \text{flags} \mid
(\text{epoch} \ll 32)$) to carry additional routing metadata (provenance
source, mitosis chain flags, outcome kind, hop count, embedder/session/
ticket hash tokens — [`src/geometry.zig:96-127`](../../src/geometry.zig)) within
the same 64 bytes. This is not an inconsistency between two formats but a
proven bijection: [`src/gate_lattice_laws.zig:44-64`](../../src/gate_lattice_laws.zig)
implements `InstructionHeader.toBytecodeHeader` and its inverse
`fromBytecodeHeader` as total, lossless conversions between the two
64-byte layouts. Both representations independently satisfy Theorem 2.4;
the substrate is free to choose whichever representation a given subsystem
needs (the canonical on-disk/spoke format for the 1M-record and sidecar
benchmarks; the packed in-memory format for live ring-buffer routing)
without ever leaving the single-cache-line invariant.

### 2.2.2 Theorem: Elimination of AST Allocation and In-Register Evaluation

**Definition 2.6 (Query Predicate Cost Model).** For a predicate over $N$
boolean terms against fields of a candidate record, define the evaluation
cost as the pair $(\mu, \iota)$ where $\mu$ is the number of *memory
operations* (distinct cache-line fetches from a cold cache) required and
$\iota$ is the number of *instructions* required, exclusive of the
predicate's own unavoidable comparison logic.

**Theorem 2.5 (Constant-Memory, Allocation-Free Predicate Evaluation).**
For any predicate over terms drawn from `opcode`, `subject_id`,
`predicate_op`/`predicate_id`, `target_val`/`target_id`, `flags`, and
`epoch`/`provenance_flags` — i.e. any term the canonical header (Definition
2.5) or its in-memory isomorph (Remark 2.4.1) carries — evaluation against
the Hamil substrate costs $\mu = 1$ (one 64-byte cache line fetch, by
Theorem 2.4) and requires zero heap allocations, independent of $N$.

*Proof.* By Definition 2.5/Theorem 2.4, every term the predicate can
range over is a field of the same 64-byte, single-cache-line header; a
single aligned load of that line (legal by Theorem 2.2/Corollary 2.3.1)
brings every term into registers simultaneously. Because every field's
byte offset is a compile-time constant (enforced by the `@offsetOf`
assertions cited in Definition 2.5's source and in
[`src/ipc_ring.zig`](../../src/ipc_ring.zig)'s own `IpcQuery`/`IpcResponse`
structs), no term requires a pointer dereference, a hash lookup, or a
heap-allocated intermediate node to locate — each is a fixed-offset
register load from the one cache line already fetched. No step in this
process allocates: there is no abstract syntax tree to allocate nodes for,
because there is no text to parse into one; the "instruction" *is* the
memory layout, not a token stream requiring a separate parse phase.
Therefore $\mu = 1$ regardless of $N$, and heap allocation count is $0$.
$\blacksquare$

**Corollary 2.5.1 (Empirical Confirmation).** This is not a purely
asymptotic claim; it is directly measured. Arm A2 of the 1M-record
benchmark (SQLite composite B-tree, multi-constraint) requires SQLite's
full parse–plan–VDBE–B-tree pipeline and sustains **IPC 0.83** with
**197,958 LLC misses across 5,000 multi-constraint queries**. Arm B4 (Zig
Domain Spoke, identical multi-constraint predicate, in-register evaluation
per Theorem 2.5) sustains **IPC 1.43** with **3,656 LLC misses across the
same 5,000-query load** — a **54× reduction in cache misses**
([`inventory/EVAL-1M-QUERY-BENCH-20260908.md`](../../inventory/EVAL-1M-QUERY-BENCH-20260908.md), Table §1,
§2.2 item 3). The $\mu = 1$ claim of Theorem 2.5 predicts exactly this
shape of result: cache-miss count bounded by a small constant per query
(one line for the header, plus whatever the routing/spoke-selection step
itself touches) rather than scaling with B-tree depth or index traversal
width.

**Corollary 2.5.2 (B-Tree Comparison Bound).** A B-tree of branching
factor $B$ over $R$ rows requires $\Theta(\log_B R)$ *data-dependent* page
fetches per lookup (§1.1.3), each a candidate cache/DRAM round trip because
the address of fetch $k+1$ is not known until fetch $k$ completes. Theorem
2.5's $\mu = 1$ is therefore not merely a constant-factor improvement over
$\Theta(\log_B R)$ — it is an asymptotic class change from
data-dependent-page-chain lookup to single-fetch, non-data-dependent
lookup, which is precisely why the advantage widens rather than narrows as
$R$ grows: at $R = 1{,}000{,}000$ this manifests as the measured
**33,420 instructions per SQLite point query** (§1.1.2) against a Hamil
substrate query whose instruction count is bounded by the fixed evaluation
chain of Theorem 2.5 independent of $R$.

---

## 2.3 The Seqlock Memory Barrier: Correctness Proof

Sections 2.1–2.2 establish *what* is safe to load in one shot and evaluate
without allocation. This section proves that concurrent *access* to that
geometry — a writer committing a new Cell while readers observe the slot,
across threads and, via [`src/ipc_ring.zig`](../../src/ipc_ring.zig)'s POSIX
shared-memory extension, across independent OS processes — is correct: no
reader ever observes a torn or partially-written Cell, and the sequence
readers observe never regresses.

### 2.3.1 The Protocol

**Definition 2.7 (Seqlock Slot).** A slot pairs a monotonic sequence counter
$\text{seq}$ (an atomic 64-bit word) with a data region $\text{data}$ (a
Cell, satisfying §2.1). The invariant maintained at all times is:
$$
\text{seq} \bmod 2 = 0 \iff \text{data is fully committed and safe to read.}
$$
An odd $\text{seq}$ signals a writer is *mid-write*.

**Writer protocol** (`LockFreeRingBuffer.pushUnchecked`,
[`src/ipc_ring.zig:196-215`](../../src/ipc_ring.zig); the cross-process
generalization `SharedCellRing.leaseAndWrite`,
[`src/ipc_ring.zig`](../../src/ipc_ring.zig), differs only in how the ticket
$S$ is obtained — see §2.3.4). For ticket (absolute sequence number) $S$:

1. `slot.seq.store(2S + 1, .release)` — announce write-in-progress.
2. `slot.data = item` — plain (non-atomic) store of the full Cell.
3. `slot.seq.store(2S + 2, .release)` — announce commit; $2S+2 = 2(S+1)$ is
   even by construction, satisfying Definition 2.7.

**Reader protocol** (`readAt`, [`src/ipc_ring.zig:232-279`](../../src/ipc_ring.zig)
for the single-writer ring; structurally identical in `SharedCellRing.readAt`
for the multi-process ring). For a target ticket $S$:

1. $s_0 \leftarrow \text{slot.seq.load(.acquire)}$.
2. If $s_0$ is odd, or $s_0 \ne 2(S+1)$ (wrong/not-yet-arrived generation),
   spin-retry step 1 (bounded — see Theorem 2.7).
3. Copy `val ← slot.data` (the candidate read).
4. $s_1 \leftarrow \text{slot.seq.load(.acquire)}$.
5. If $s_1 = s_0$, return `val` as the verified result; otherwise retry
   from step 1.

### 2.3.2 Theorem: No Torn Reads

**Theorem 2.6 (Read Consistency).** If the reader protocol returns `val`
for ticket $S$, then `val` is byte-for-byte identical to the Cell the
writer stored for ticket $S$ in step 2 of the writer protocol — never a
mixture of two writes, and never a partial write.

*Proof.* Suppose the reader returns `val` at step 5, having observed
$s_0 = s_1 = 2(S+1)$ (even, matching ticket $S$'s expected committed
value). Zig's `.release` store / `.acquire` load pair on the same atomic
object establishes a *synchronizes-with* edge (per the C11/Zig memory
model this substrate's atomics are defined against): the reader's
step-1 acquire-load of $\text{seq} = 2(S+1)$ synchronizes-with the
writer's step-3 release-store of that same value. By the transitivity of
*happens-before*, every action *program-order-before* the writer's step 3
— in particular, the writer's step 2 plain store of `slot.data` —
happens-before every action program-order-after the reader's
synchronizing load — in particular, the reader's step 3 copy of
`slot.data`. Therefore the reader's copy at step 3 is guaranteed to observe
the writer's complete step-2 store, not a state prior to it.

It remains to rule out the reader racing a *later* writer that started
concurrently with the reader's own step 3 copy. Suppose writer $S' > S$
begins its own step 1 between the reader's step 1 and step 4. Writer $S'$
necessarily targets the same physical slot only when $S' \equiv S
\pmod{\text{Capacity}}$ (ring wraparound) — the case where $S'$ instead
targets ticket $S$'s own *next* generation. If writer $S'$'s step 1 occurs
before the reader's step 4, the reader's step-4 load observes either an odd
value (writer $S'$ mid-write) or an even value $\ne 2(S+1)$ (writer $S'$
already committed a different generation) — in either case $s_1 \ne s_0$,
and by protocol step 5 the reader *discards* the candidate `val` and
retries rather than returning it. Hence the only path by which the reader
protocol *returns* a value is the path in which no intervening write to
that slot occurred between step 1 and step 4, which is exactly the
condition under which the happens-before argument above applies cleanly.
$\blacksquare$

This is precisely the reasoning [`src/ipc_ring.zig`](../../src/ipc_ring.zig)'s own
test suite verifies empirically rather than merely by inspection: `test
"Streaming 17,408-byte Cells across LockFreeRingBuffer"` and `test
"SharedCellRing single-threaded attach, leaseAndWrite, readAt round trip"`
assert byte-exact recovery of written Cells, and the four-real-OS-process
integration proof in [`tests/test_multiprocess_shm.zig`](../../tests/test_multiprocess_shm.zig)
fills every semantic-payload byte with a value derived from its own
ticket specifically as a torn-read tripwire, asserting
`reader_ctx.torn_violation == false` after every one of 96 concurrent
cross-process writes.

### 2.3.3 Theorem: Bounded (Wait-Free) Termination

**Theorem 2.7 (Bounded Retry / Wait-Freedom).** The reader protocol of
§2.3.1 terminates — returning either a verified value or a defined error —
within a fixed, finite number of steps, independent of the scheduling
behavior of any other thread or process.

*Proof.* [`src/ipc_ring.zig`](../../src/ipc_ring.zig)'s implementation bounds
the retry loop explicitly: `LockFreeRingBuffer.readAt` retries at most 128
times before returning `IpcError.TornRead`
([`src/ipc_ring.zig:245-278`](../../src/ipc_ring.zig)); the cross-process
`SharedCellRing.readAt` retries at most 100,000 times (a larger bound
chosen because cross-process scheduling jitter — a competing writer being
descheduled by the OS mid-critical-section — can exceed intra-thread
spin timescales) before returning the same error. In both cases the loop
count is a compile-time constant, not a function of any other thread's
progress. By the formal (Herlihy) definition of wait-freedom — every
operation completes in a bounded number of steps regardless of the
behavior of other threads — the reader protocol is wait-free: *completion*
is defined as returning a result, and a defined error return (signaling
"could not verify this read within the bound; the caller should retry the
whole operation or treat the slot as contended") is as much a completion as
a successful value return. This is a deliberately weaker and more precise
claim than "always succeeds" — the protocol never blocks, never
deadlocks, and never spins unboundedly, but it does not promise that every
individual attempt returns data; it promises every individual attempt
*terminates*. $\blacksquare$

**Remark 2.7.1.** The writer protocol is unconditionally wait-free by
inspection: it is three unconditional stores with no loop and no
condition on any other thread's state (single-writer case), or, in the
multi-process case, the atomic-CAS ticket-acquisition step of §2.3.4 — which
is itself bounded, per Theorem 2.8.

### 2.3.4 Theorem: Cross-Process Monotonic Epoch Progression

The single-writer protocol of §2.3.1 assumes a private, non-atomic ticket
counter (`local_head`) is safe because exactly one writer increments it.
[`src/ipc_ring.zig`](../../src/ipc_ring.zig)'s `SharedCellRing` generalizes
this to $N$ independent writers — including writers in *separate OS
processes*, coordinated only through a POSIX `MAP.SHARED` mapping of a
file conventionally under `/dev/shm` — which requires a new argument, since
$N$ processes each privately incrementing their own counter would
immediately violate ticket uniqueness.

**Definition 2.8 (Cross-Process Ticket Lease).**
`SharedCellRing.leaseAndWrite` acquires ticket $S$ via an explicit
compare-and-swap loop against a header field `alloc_cursor` mapped in the
shared segment: starting from an observed value $c$, the writer attempts
`alloc_cursor.cmpxchgWeak(c, c+1, .acq_rel, .acquire)`; on failure (another
writer's CAS won the race) it re-reads $c$ and retries; on success, it has
been granted $S = c$ and every other writer's next CAS attempt will observe
$c+1$.

**Theorem 2.8 (Global Ticket Uniqueness and Bounded Progress).** For any
number of writer processes concurrently calling `leaseAndWrite` against the
same mapped segment, (a) no two calls, in any process, ever receive the
same ticket $S$; (b) the set of tickets issued is exactly
$\{0, 1, \dots, K-1\}$ after $K$ total successful leases, with no gaps; and
(c) each individual CAS loop terminates in a number of iterations bounded
by the number of *other* writers that successfully CAS between this
writer's successive attempts.

*Proof.* (a) A `cmpxchgWeak(c, c+1, \dots)` succeeds if and only if
`alloc_cursor`'s current value is exactly the writer's last-observed $c$;
the underlying hardware CAS instruction (`LOCK CMPXCHG` on x86_64) is
atomic with respect to *every* observer of that physical memory location —
including other processes mapping the same page, since cache coherency and
atomic RMW instructions operate on physical memory, not on a
per-process abstraction. Therefore at most one concurrent CAS attempt
targeting a given $c$ can succeed; every other concurrent attempt observes
the post-increment value and must retry with a new $c' = c+1$. By
induction, each successful CAS consumes exactly one value from the
sequence $0, 1, 2, \dots$ and no two successful CASes consume the same
value, proving (a) and (b) together. (c) Since `cmpxchgWeak` is permitted
to fail spuriously but the loop retries on any failure by re-reading the
current value, and `alloc_cursor` only advances forward (each successful
CAS strictly increases it by exactly 1), a writer's $i$-th retry can only
be forced by a *distinct* successful CAS from another writer having
occurred since the writer's $(i-1)$-th attempt; the loop therefore
terminates after at most as many retries as there are other writers'
successful CASes interleaved with this writer's attempts — a quantity
bounded by the total number of concurrent writers, not unbounded.
$\blacksquare$

**Corollary 2.8.1 (Monotonic Epoch Progression, Multi-Process).** Because
every ticket in $\{0, \dots, K-1\}$ is issued exactly once (Theorem 2.8b),
and each writer commits its slot using the *same* odd→even seqlock
discipline as the single-writer case (§2.3.1) keyed off its own uniquely-
owned ticket, the seqlock generation value any reader observes at a given
slot is drawn from a strictly increasing sequence over the slot's history,
exactly as in the single-writer case — the cross-process extension changes
*how a ticket is obtained* (CAS lease vs. private counter) but not the
per-slot commit protocol Theorem 2.6 already covers. Read consistency
(Theorem 2.6) and bounded termination (Theorem 2.7) therefore both carry
over unchanged to the multi-process setting.

**Corollary 2.8.2 (Empirical Confirmation, Real OS Processes).** This is
verified, not merely proved, against real operating-system processes — not
threads simulating processes — in
[`tests/test_multiprocess_shm.zig`](../../tests/test_multiprocess_shm.zig):
four independent processes, spawned via `std.process.Child` (never
`std.Thread`), concurrently lease and commit into a `SharedCellRing` mapped
from `/dev/shm`, while a reader thread in the parent test process
continuously verifies (i) `reader_ctx.monotonic_violation == false` —
every observed ticket strictly exceeds the last, matching Corollary 2.8.1;
(ii) `reader_ctx.torn_violation == false` — matching Theorem 2.6; and (iii)
`reader_ctx.distinct_pid_count >= 2` — direct confirmation that ticket
uniqueness (Theorem 2.8a) held across genuinely distinct address spaces,
not merely distinct threads sharing one. The in-process CAS-arbitration
stress test `SharedCellRing concurrent CAS lease arbitration: no duplicate
or dropped tickets` ([`src/ipc_ring.zig`](../../src/ipc_ring.zig)) additionally
verifies Theorem 2.8(a)–(b) directly under 8-way concurrent contention:
every resident slot's ticket, recovered independently from the committed
Cell's own `header.opcode` field, matches the seqlock generation the ring's
own bookkeeping assigned it, with zero duplicates and zero gaps observed
across 800 leased writes into a 16-slot ring (50× wraparound).

---

## 2.4 Invariant A-2 as a Grammar Terminal: Refusal Before Stamping

Theorem 2.5 proved that predicate evaluation against the 64-byte header costs
one memory operation and zero allocations *because there is no text to parse*.
That proof characterizes the query side. It leaves open the symmetric question
on the ingestion side: if the substrate accepts an instruction from outside
itself — from a human, an agent, a network peer — something must convert
external bytes into a header, and if that conversion is a conventional parser
it reintroduces exactly the string-parsing tax of §1.1.1 at the front door,
one layer up from where §1.1.1 found it.

The resolution is to make the header not the *result of* a parse tree but the
**sole terminal of a regular grammar**, so that no tree is ever constructed.

**Definition 2.9 (Transition Mask).** For an alphabet $\Sigma$ of 256 byte
values, a transition mask is a bit vector $M \in \{0,1\}^{256}$, represented as
`[4]u64` (`lsp_indexer.TokenMask`, re-exported at
[`src/intake_gate.zig:19`](../../src/intake_gate.zig)), where $M[b] = 1$ iff
byte $b$ may legally follow the prefix consumed so far.

**Definition 2.10 (Prefix-Closed Vocabulary).** Let $V$ be the closed set of
eight canonical relation tokens (`assert_relation`, `contradicts`,
`requires_gate`, `negative_affinity_veto`, `supersedes`, `grounded_in`,
`mitosis_split`, `reconcile_match`, opcodes 1001–1008). For a prefix $p$,
define $\text{next}(p) = \{\, v_{|p|} : v \in V,\ v \text{ has prefix } p \,\}$
— the set of bytes that extend $p$ toward some member of $V$.
`computeRelationTokenMask(p)` ([`src/intake_gate.zig:64`](../../src/intake_gate.zig))
returns exactly the mask of $\text{next}(p)$.

**Theorem 2.9 (First-Byte Refusal).** For any candidate token $t \notin V$,
`validateRelationGbnf(t)` returns `IntakeError.TokenMaskedByGrammar` after
consuming exactly $k+1$ bytes, where $k$ is the length of the longest prefix of
$t$ that is also a prefix of some $v \in V$. In particular, the rejection cost
is bounded by $\min(|t|, \max_{v \in V} |v|)$ and is **independent of the
length of $t$** beyond that bound; no allocation occurs, and no header is
stamped.

*Proof.* The validator iterates $i = 0, 1, \dots$, computing
$M_i = \text{mask}(\text{next}(t[0..i]))$ and testing $M_i[t_i]$
([`src/intake_gate.zig:113–115`](../../src/intake_gate.zig)). By Definition
2.10, $M_i[t_i] = 1$ iff $t[0..i{+}1]$ remains a prefix of some $v \in V$.
Let $k$ be the largest index such that $t[0..k]$ is a prefix of some $v \in V$;
such a $k$ exists (possibly $k = 0$, the empty prefix, which every $v$ shares).
At iteration $i = k$ the test $M_k[t_k]$ fails, since by maximality of $k$ no
$v \in V$ has prefix $t[0..k{+}1]$, and the function returns the error
immediately. Iterations $0 \dots k-1$ each perform a constant-work mask
computation and bit test over a fixed 256-bit vector; no dynamic memory is
requested at any step. Termination at $i = k$ therefore bounds total work at
$k+1$ constant-cost steps. $\blacksquare$

**Corollary 2.9.1 (Adversarial Input Is Cheap to Refuse).** Theorem 2.9's
bound is what makes hostile input non-amplifying: a rejection costs strictly
less than an acceptance, so an adversary cannot make the gate expensive by
making the input long. The measured refusal points bear this out exactly —
`"delete_database"` fails at index 0 (no $v \in V$ begins with `d`),
`"admin'--"` at index 5, and the mid-word mutation `"assert_relatXon"` at index
12, the first byte at which it diverges from `assert_relation`
([`inventory/EVAL-GBNF-INTAKE-BENCH-20260908.md`](../../inventory/EVAL-GBNF-INTAKE-BENCH-20260908.md) §3).
A conventional parser must generally consume its entire input before it can
report that the input was invalid; a transition-mask gate reports at the byte
where validity was lost.

**Theorem 2.10 (No Silent Domain Collapse).** Let $\text{makeId}: \Sigma^* \to
\Sigma^{16}$ be the 16-byte identifier constructor of Invariant A-2's
`subject_id`/`predicate_id`/`target_id` fields. Unguarded truncation makes
$\text{makeId}$ non-injective: any two distinct inputs sharing a 16-byte prefix
map to the same field value, so two semantically distinct facts become
indistinguishable inside the header — a collision the substrate cannot detect
after the fact, because the evidence of divergence was discarded at
construction. The intake gate restores injectivity by *domain restriction*
rather than by widening the field: `validateIdentifierGbnf` rejects any token
with $|t| > 16$ via `IntakeError.TermLengthExceeded`
([`src/intake_gate.zig:98`](../../src/intake_gate.zig)), so $\text{makeId}$ is
only ever applied on the domain $\{t : 1 \le |t| \le 16\}$, on which it is
injective by construction.

*Proof.* On the restricted domain, $\text{makeId}$ pads rather than truncates,
and padding a string shorter than the field width to that width is injective
(the original is recoverable by stripping the pad). Inputs outside the domain
never reach $\text{makeId}$: the length test precedes it and returns an error.
Hence no two distinct accepted inputs share a field value. $\blacksquare$

**Remark 2.10.1 (Why this is a geometric result, not merely a validation
policy).** Invariant A-2 fixes the header at 64 bytes, which fixes each
identifier field at 16 — the widths are not free parameters, because widening
them would break Theorem 2.4 and with it the single-cache-line property every
result in §2.2 depends on. A fixed-width field admits exactly two disciplines:
truncate and lose injectivity, or refuse and keep it. The substrate refuses.
This is the general form of a principle worth stating once for the whole
design: **where a fixed geometry cannot represent an input, the correct
response is refusal, never silent approximation** — the same principle that
makes `RefusalMaxHopExceeded` (Invariant A-11) an exception rather than a
clamp, and that Section 9's energy framework generalizes as $E = \infty$.

**Corollary 2.10.2 (The Ingestion Path Is Allocation-Free End to End).**
Composing Theorem 2.9, Theorem 2.10, and Theorem 2.5: an external instruction
is validated by constant-space mask tests, its accepted terms are written into
fixed-offset fields of a 64-byte header (`parseAndValidateTriple`,
[`src/intake_gate.zig:292`](../../src/intake_gate.zig)), and that header is
subsequently queried by single-cache-line register evaluation. At no point in
this chain is an abstract syntax tree, a token vector, or an intermediate
representation allocated. The measurement confirms the structural claim:
**482.72 ns per end-to-end triple stamp at 2,071,574 triples/sec with 0 heap
bytes**, and 10.29 ns per identifier validation
([`inventory/EVAL-GBNF-INTAKE-BENCH-20260908.md`](../../inventory/EVAL-GBNF-INTAKE-BENCH-20260908.md) §3).
Tax Component I of §1.1 is therefore eliminated not only from the query path,
where Theorem 2.5 removed it, but from the ingestion path, where it would
otherwise have been quietly reintroduced.

---

## 2.5 Invariant A-1 Across the DMA Boundary: One Constant, Three Roles

Every result in §2.1 is stated about host memory and justified by the cache
coherency protocol. This section establishes a property the substrate relies on
but §2.1 does not prove: that the same 17,408-byte constant remains the correct
unit *outside* the coherency domain, when a Cell crosses into the physically
distinct address space of an accelerator over DMA.

**Definition 2.11 (Transport-Invariant Record).** A record format is
transport-invariant across an interface if a record can be transferred in both
directions with (i) no change in byte count, (ii) no insertion or removal of
padding, (iii) no field reordering or reserialization, and (iv) no negotiation
of layout between the endpoints — so that the sender's in-memory image and the
receiver's are byte-identical and directly addressable at both ends.

**Theorem 2.11 (Invariant A-1 Is Transport-Invariant Over Host-Pinned DMA).**
A `geometry.Cell` satisfies Definition 2.11 across a host↔accelerator DMA
interface whose transfer granularity $G$ divides the record size, provided the
buffer is mapped host-pinned at an address aligned to $\max(L, G)$.

*Proof.* Conditions (iii) and (iv) hold because there is no serialization step
to perform: the Cell is a flat, `extern`-layout byte image with compile-time
fixed offsets (Theorem 2.2), so the "wire format" and the "memory format" are
the same object, and the transfer is a copy rather than an encoding. Condition
(ii) holds because $|\text{Cell}| = 17{,}408 = 272L$ with zero remainder
(Theorem 2.1): a record that is already an exact multiple of the transfer
granularity requires no tail padding to fill a final partial unit, for any $G$
dividing $17{,}408$. Since $17{,}408 = 2^{10} \cdot 17$, every power of two up
to $1{,}024$ divides it — which covers the DMA burst granularities of practical
interest (64, 128, 256, 512, and 1,024 bytes). The 4,096-byte page size is
deliberately *not* among them ($17{,}408 / 4{,}096 = 4.25$), and it does not
need to be: page size is a property of how the pinned buffer is mapped, not a
divisor requirement of the transfer itself — a buffer of $N$ Cells is mapped
page-aligned at its base, after which Corollary 2.2.1 places every Cell within
it at a 64-byte-aligned offset regardless of page boundaries.
Condition (i) then follows: the byte count is the same at both ends because
neither padding nor encoding altered it. Finally, alignment to $\max(L, G)$ at
the buffer base propagates to every Cell in the buffer by Corollary 2.2.1, so
each record in a streamed batch is independently addressable at both endpoints
without a per-record offset table. $\blacksquare$

**Corollary 2.11.1 (Empirical Confirmation on Physical Silicon).** Theorem 2.11
is verified on hardware rather than assumed. On Brandys (AMD Ryzen 7 8700F,
Phoenix NPU `[0000:12:00.1]`, XDNA 1, NPU firmware `1.5.5.391`, `amdxdna`
`2.21.260102.53`, XRT `2.21.75`), `scripts/brandys_npu_stream_bench.cpp`
streamed $N = 100{,}000$ Cells of exactly 17,408 bytes bidirectionally through
`/dev/accel/accel0` using double-buffered `xrt::bo` host-pinned buffer objects
(`xrt::bo::flags::host_only`), moving 3.48 GB in 27.44 ms at **252.686 ns mean
latency and 118.174 GiB/s**, with **zero heap allocations** and the 64-byte
header of Invariant A-2 intact at offset 0 on arrival
([`inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md`](../../inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md)).
The latency distribution is tight — min 240 ns, p50 250 ns, p95 270 ns, p99
320 ns — giving $p_{99}/p_{50} = 1.28$; the single 13,531 ns maximum is the
initial cache-sync spike on the first transfer, not a recurring tail.

**Corollary 2.11.2 (Bandwidth Is Consistent With the Geometry, Not With a
Padded Format).** The reported figures are mutually consistent under Theorem
2.11 and would not be under a format requiring padding. Each iteration moves
$2 \times 17{,}408 = 34{,}816$ bytes (host→device and device→host); at
$N = 100{,}000$ that is $3.4816 \times 10^{9}$ bytes in $0.0274384$ s, i.e.
$1.2689 \times 10^{11}$ B/s $= 118.17$ GiB/s, matching the artifact's reported
bandwidth to the digit, and $0.0274384\,\text{s} / 100{,}000 = 274.4$ ns per
iteration against a reported 252.686 ns mean per-transfer latency (the
difference being loop and synchronization overhead outside the timed transfer).
Had the record required padding to a 512-byte or 4,096-byte boundary, the
delivered payload rate would have fallen below the wire rate by the padding
ratio; it does not.

**Theorem 2.12 (One Constant, Three Roles).** The single value 17,408
simultaneously satisfies three independent structural requirements, and this
coincidence is a design consequence rather than a numerical accident:

| Role | Requirement on the constant | Established by |
| :--- | :--- | :--- |
| **Cache residency unit** | Exact multiple of $L = 64$ B, with every sub-region line-aligned, so no false sharing and no split loads | Theorems 2.1, 2.2, 2.3 |
| **Concurrency unit** | A fixed-size slot a seqlock can guard as one generation, addressable by ticket arithmetic without an offset table | §2.3, Corollary 2.2.1 |
| **DMA transport unit** | Exact multiple of the transfer granularity, flat layout, no reserialization across an address-space boundary | Theorem 2.11, Corollary 2.11.1 |

*Proof.* Each row is established by the cited result; the theorem is their
conjunction on a single value. $\blacksquare$

**Remark 2.12.1 (What this does and does not claim).** Corollary 2.11.1
establishes *transport*: the geometry crosses the interface at line rate with
its invariants intact. It does not establish that the accelerator's compute
tiles evaluate substrate logic — no scoring, query, or governor kernel executes
on the NPU in that benchmark, and §9.10.3 states the same limitation from the
architectural side. The claim proved here is narrower and worth stating
precisely because the narrow claim is the load-bearing one: **a substrate whose
record format needs no marshalling to reach an accelerator can adopt one
without redesigning its record format.** The cost of heterogeneity, for this
geometry, is a `memcpy` at 118 GiB/s — not a schema.

---

## 2.6 Summary

Section 2.1 proved that Invariant A-1's 17,408-byte, 272-cache-line Cell
geometry places every independently-addressed sub-structure on a
64-byte-aligned boundary, which by construction rules out false sharing
between sub-structures and guarantees atomicity of any single-field store,
categorically rather than statistically (Theorem 2.3), and is the
precondition for legal, line-resident SIMD loads (Corollary 2.3.1). Section
2.2 proved that Invariant A-2's 64-byte `=Q16s16s16sII` header co-locates
every field a query predicate can range over within that one aligned line,
reducing predicate evaluation to a constant one-memory-operation,
zero-allocation cost independent of predicate arity (Theorem 2.5) — an
asymptotic class change from a B-tree's data-dependent
$\Theta(\log_B R)$ page-chase (Corollary 2.5.2), not merely a constant-factor
speedup. Section 2.3 proved that the seqlock protocol governing concurrent
access to this geometry guarantees torn-read-free consistency (Theorem 2.6)
with wait-free, bounded termination (Theorem 2.7), and that its
compare-and-swap-based generalization to independent OS processes over
POSIX shared memory preserves global ticket uniqueness and monotonic
sequence progression under concurrent multi-process write pressure (Theorem
2.8) — each claim grounded not only in proof but in passing, on-disk,
reproducible tests (`zig build test`, `zig build test-multiprocess-shm`)
against the exact source cited throughout this section.

Sections 2.4 and 2.5 then extend both invariants past the boundaries the first
three subsections assumed. Section 2.4 closed the ingestion side of the
string-parsing tax: by making the 64-byte header the sole terminal of a regular
grammar rather than the output of a parse tree, an illegal instruction is
refused at the exact byte where validity is lost (Theorem 2.9), an
over-long identifier is refused rather than silently truncated into a colliding
field value (Theorem 2.10), and the whole ingest-to-query chain therefore
allocates nothing at any step (Corollary 2.10.2) — so Tax Component I is
eliminated at the front door as well as in the query path. Section 2.5 proved
that Invariant A-1's 17,408-byte constant is transport-invariant across a
host↔accelerator DMA boundary (Theorem 2.11), verified at 118.174 GiB/s on a
physical AMD XDNA Phoenix NPU (Corollary 2.11.1), establishing that one
constant serves simultaneously as cache-residency unit, concurrency slot, and
DMA wire format (Theorem 2.12). The practical consequence is that adopting
heterogeneous silicon costs this substrate a copy, not a schema.

Together, these results are the mathematical justification for the
empirical advantage tabulated in Section 1: the Relational Tax's four
components (§1.1) are not merely *slower* than the Hamil substrate by
engineering effort — each is proved here to be structurally unnecessary
once the geometry guarantees single-cache-line, allocation-free,
wait-free-verified access to every field a transaction or query needs.
