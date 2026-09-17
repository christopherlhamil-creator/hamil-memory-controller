# Verification Report: `boot_pack.zig` — Fractal Mitosis Wiring Audit & Fix

**Document ID**: `EVAL-BOOTPACK-MITOSIS-SPLIT-20260908`
**Directive**: Council Arena — The Blackmagic Interrogation: Auditing & Closing the 5 Open Rectangles
**Seat Context**: Seat 2 — `@sonnet` (`worktrees/council-sonnet`)
**Role**: Native Memory & Cellular Substrate Engineer — Rectangle 3: Fractal Mitosis
**Host Tested**: Local Development Host (`pop-os`, Linux `7.0.11-76070011-generic` x86_64)
**Toolchain**: Zig `0.17.0-dev.1970+67f39b551`
**Date**: 2026-09-08
**Certification Verdict**: **FOUND AND FIXED — `boot_pack.zig` was already calling `mitosis.splitWrite` (not returning a bare `error.SplitRequired`), but a threshold bug made that call's *success* branch mathematically unreachable: every payload that could ever trigger it was guaranteed to exceed mitosis's own 4-hop capacity and be refused. The threshold is now fixed, and a real fission-and-reassemble round trip is proven on metal.**

---

## 1. The Blackmagic Question, Answered Precisely

> *When working memory exceeds 17,408 bytes, does `boot_pack.zig` actually execute a
> non-truncating `mitosis.splitWrite` across cache-line boundaries (halting strictly at hop
> depth 4), or is it still returning `error.SplitRequired` and refusing the payload?*

**Neither answer offered in the question was quite right.** Before this fix, `boot_pack.zig`
did call `mitosis.splitWrite` for any payload over `MAX_CELL_BYTES` (17,408B, the full raw
cell size) — it was not merely returning a hardcoded `error.SplitRequired`. But it was also
not "actually executing a non-truncating split" in any way that could ever succeed:

```
MAX_CELL_BYTES (boot_pack's trigger threshold)        = 17,408 bytes
mitosis.MAX_PAYLOAD_WITHIN_HOP_LIMIT (mitosis's own
  ceiling for a chain that fits in <= 4 hops)          =  4,680 bytes  (5 cells x 936B)
```

Since `17,408 > 4,680`, **every payload large enough to reach `boot_pack`'s call to
`mitosis.splitWrite` was already, unconditionally, larger than the largest payload mitosis
can ever successfully chain within Invariant A-11's 4-hop limit.** The one pre-existing test
covering this path (`"boot pack overflow is wired to mitosis.splitWrite, never trimmed"`)
only ever exercised — and could only ever exercise — the refusal branch
(`RefusalMaxHopExceeded`). It read as proof that mitosis wiring worked, while actually being
proof that the success branch was dead code no input could reach. This is exactly the gap
the Blackmagic Interrogation is designed to surface: code that *looks* wired (real function
call, real error propagation, a passing test) but is structurally unreachable in the case
that matters.

**Root cause**: `boot_pack.zig` gated on `geometry.CELL_BYTES` (17,408B — a cell's *entire*
raw size, including its 64B bytecode header and reserved cache lines) instead of
`geometry.SEMANTIC_PAYLOAD_BYTES` (960B — the actual usable payload capacity of *one* cell,
which is also exactly what `mitosis.chainLen` itself uses to decide whether a payload needs
splitting at all: `if (payload_len <= SEMANTIC_PAYLOAD_BYTES) return 1;`). Fixing the
gate to match mitosis's own model of "does this fit in one cell" makes the 961B–4,680B range
— previously unreachable — a real, exercised, byte-identical split-and-reassemble path.

## 2. The Fix

`src/boot_pack.zig`:

1. Added `pub const FLAT_BLOB_MAX_BYTES: usize = geometry.SEMANTIC_PAYLOAD_BYTES;` (960),
   documented against `MAX_CELL_BYTES` (17,408, kept — it still names the cell's full raw
   size and remains meaningful elsewhere) so the distinction is load-bearing and explicit,
   not implicit.
2. Changed `register()`'s gate from `if (payload.len > MAX_CELL_BYTES)` to
   `if (payload.len > FLAT_BLOB_MAX_BYTES)` — the only line-level change needed to make the
   success path reachable. `mitosis.splitWrite` itself was untouched: it already correctly
   enforces Invariant A-11 (`if (n > MAX_HOP_DEPTH + 1) return RefusalMaxHopExceeded`) and
   never truncates.
3. Added `BootPackRegistry.reassemblePayload()` — a real production round-trip counterpart
   to `register()`'s split, not a test-only helper. It regenerates the same deterministic
   `0..n-1` chain keys `register()` assigned internally and calls `mitosis.reassemble`
   against the stored cell chain.

No change was made to `src/mitosis.zig` — its own `splitWrite`/`reassemble`/`chainLen`/hop
gate were already correct and already had their own passing unit tests (`"splitWrite and
reassemble multi-cell round trip"`, `"Invariant A-11: 4-hop kill trigger hard refusal"`).
The bug was entirely in how `boot_pack.zig` decided *whether* to call mitosis, not in
mitosis's own logic.

## 3. Tests Added / Updated in `src/boot_pack.zig`

| Test | Payload | Result |
| :--- | ---: | :--- |
| `"boot pack registry pointer hash and 17KB gate"` (pre-existing, unchanged) | 44 B | Flat blob, `chain_len == 0` |
| `"boot pack payload beyond mitosis's own hop limit is refused, never trimmed"` (renamed from the pre-existing overflow test; behavior unchanged and still passes under the new threshold) | 17,409 B | `RefusalMaxHopExceeded`, registry left empty |
| **`"boot pack payload beyond one cell actually fissions into linked cells and reassembles byte-identically"` (new)** | 3,000 B | **Splits into `mitosis.chainLen(3000) = 4` cells, `chain_len` set correctly, `reassemblePayload()` output is byte-identical (`expectEqualSlices`) to the original 3,000-byte input** |
| `"boot pack payload requiring more than 4 hops is still refused after the threshold fix"` (new) | 4,681 B (`MAX_PAYLOAD_WITHIN_HOP_LIMIT + 1`) | `RefusalMaxHopExceeded`, registry left empty — proves the fix did not soften Invariant A-11 |
| `"boot pointer path hashing deterministic"` (pre-existing, unchanged) | n/a | Passes |

### Directly observed test output (isolated `zig test` run of `boot_pack.zig` + its real imports, this host)

```
1/20 boot_pack.test.boot pack registry pointer hash and 17KB gate...OK
2/20 boot_pack.test.boot pack payload beyond mitosis's own hop limit is refused, never trimmed...OK
3/20 boot_pack.test.boot pack payload beyond one cell actually fissions into linked cells and reassembles byte-identically...OK
4/20 boot_pack.test.boot pack payload requiring more than 4 hops is still refused after the threshold fix...OK
5/20 boot_pack.test.boot pointer path hashing deterministic...OK
...
17/20 mitosis.test.chainLen capacity bounds...OK
18/20 mitosis.test.splitWrite single cell fits cleanly...OK
19/20 mitosis.test.splitWrite and reassemble multi-cell round trip...OK
20/20 mitosis.test.Invariant A-11: 4-hop kill trigger hard refusal...OK
All 20 tests passed.
```

### Whole-suite regression check (`zig build test`, cold cache, this host)

```
Build Summary: 61/61 steps succeeded; 474/475 tests passed (1 skipped)
```

The 1 skip is `src/simd_lexer.zig`'s pre-existing `error.SkipZigTest` debug-mode guard
(unrelated to this change, verified by `grep` — it is the only `SkipZigTest` in the
codebase). No test anywhere in the suite regressed from this fix.

## 4. Invariant Compliance

- **Invariant A-1** (17,408B cell): unchanged, still asserted at `comptime` in `geometry.zig`
  and exercised by every cell this path constructs.
- **Invariant A-2** (64B header): unchanged; `mitosis.splitWrite` still writes the standard
  header on every chain cell.
- **Invariant A-8** (intent overrules semantics): not directly exercised by this fix (that is
  Rectangle-4-adjacent territory), unaffected.
- **Invariant A-11** (4-hop kill trigger): **actively re-verified, not just left alone** — the
  new `"...requiring more than 4 hops is still refused after the threshold fix"` test exists
  specifically to prove the fix didn't accidentally widen the hop ceiling while widening the
  reachable success range. `mitosis.splitWrite`'s own gate (`n > MAX_HOP_DEPTH + 1 →
  RefusalMaxHopExceeded`) was never touched.
- **Git Hygiene**: no binaries touched or committed; only `src/boot_pack.zig`
  (source) and this proof doc.
- **Invariant 12**: no daemons, no network calls — a single native `zig build test` /
  `zig test` invocation.

## 5. Reproducibility Package

- Fixed source: [`src/boot_pack.zig`](file:///home/christopherhamil/tot_hybrid/worktrees/council-sonnet/src/boot_pack.zig)
- Unchanged (verified correct) source: [`src/mitosis.zig`](file:///home/christopherhamil/tot_hybrid/worktrees/council-sonnet/src/mitosis.zig)
- Reproduction:
  ```bash
  zig build test   # whole suite, includes boot_pack's 5 tests
  # or, isolated:
  zig test --dep geometry -Mroot=src/boot_pack.zig -Mgeometry=src/geometry.zig
  ```

## 6. Verdict & Recommendation to the Council

1. **Rectangle 3 is closed for the specific gap this directive named**: `boot_pack.zig` now
   has a real, tested, reachable path from an oversized payload through
   `mitosis.splitWrite` to linked cells and back through the new `reassemblePayload()` to
   byte-identical bytes — not just a call that exists in source but can never succeed.
2. **The general lesson generalizes beyond this one file**: "the function is called" and "the
   error type is a real invariant error, not a stub" are necessary but not sufficient
   evidence that a code path works — a threshold or capacity mismatch between two modules
   (here, `boot_pack`'s 17,408B gate vs. mitosis's real 960B/4,680B capacities) can make a
   correctly-implemented function's success branch permanently unreachable while every
   existing test still passes. Worth a pass over the other 4 Rectangles' seats for the same
   shape of bug (a real function call whose only reachable outcome is the failure path).
3. **No further action needed on `mitosis.zig` itself** — it was correct before this fix and
   remains correct; all changes were confined to how `boot_pack.zig` decides when to invoke
   it.

---
*Report Certified By*: **Seat 2 (`@sonnet`)**
*Verification Signature*: `SHA256-METAL-VERIFIED-BOOTPACK-MITOSIS-SPLIT-20260908`
