//! Cell Mitosis & Fractal Chaining (Clean-Room Implementation)
//!
//! Subsystem: tot_hybrid/src/mitosis.zig
//!
//! What a write does when its logical payload does not fit in one cell's
//! 960-byte semantic_payload region: splits (mitosis) into a chain of linked cells,
//! never silently truncating or dropping bytes.
//!
//! Specifications & Invariants:
//!   - Invariant A-1: Strict 17,408B cell size (272 x 64B cache lines).
//!   - Invariant A-2: Strict 64B bytecode header (1 cache line).
//!   - Invariant A-11: 4-hop kill trigger (branch depth > 4 throws immediate refusal).
//!   - Invariant A-8: Intent overrules semantics.
//!   - Link Footer: Trailing 24 bytes of semantic_payload (LINK_FOOTER_BYTES).
//!   - Linked Data Bytes: 960 - 24 = 936 bytes per linked cell.
//!   - Zero Allocation: Operates over caller-provided buffers and pre-allocated cell pools.
//!
//! Toolchain: Zig 0.17 / Zig 0.16 compatible.

const std = @import("std");
const geometry = @import("geometry");

// ── Invariant Constants ───────────────────────────────────────────────────────

pub const CELL_BYTES: usize = geometry.CELL_BYTES; // 17,408
pub const BYTECODE_HEADER_BYTES: usize = geometry.BYTECODE_HEADER_BYTES; // 64
pub const SEMANTIC_PAYLOAD_BYTES: usize = geometry.SEMANTIC_PAYLOAD_BYTES; // 960
pub const LINK_BYTES: usize = geometry.LINK_FOOTER_BYTES; // 24
pub const MAX_HOP_DEPTH: usize = geometry.MAX_HOP_DEPTH; // 4

/// Usable payload data bytes in a linked cell.
pub const LINKED_DATA_BYTES: usize = SEMANTIC_PAYLOAD_BYTES - LINK_BYTES; // 936

/// Maximum payload bytes deliverable within the 4-hop limit (1 root + 4 hops = 5 cells).
/// 5 cells * 936 bytes = 4,680 bytes. Anything larger requires recursive mitosis beyond 4 hops
/// and triggers immediate hard refusal (Invariant A-11).
pub const MAX_PAYLOAD_WITHIN_HOP_LIMIT: usize = (MAX_HOP_DEPTH + 1) * LINKED_DATA_BYTES;

/// Flag bits stored in BytecodeHeader.provenance_flags, bits 4..7 (the
/// Mitosis chain flags nibble reserved in geometry.zig — bits 0..3 belong to
/// provenance.zig's ProvenanceSource and must never be touched here).
pub const FLAG_MITOSIS_MEMBER: u64 = geometry.FLAG_MITOSIS_MEMBER;
pub const FLAG_MITOSIS_HAS_NEXT: u64 = geometry.FLAG_MITOSIS_HAS_NEXT;

comptime {
    std.debug.assert(LINK_BYTES == 24);
    std.debug.assert(LINKED_DATA_BYTES == 936);
    std.debug.assert(SEMANTIC_PAYLOAD_BYTES == 960);
    std.debug.assert(MAX_HOP_DEPTH == 4);
    std.debug.assert(MAX_PAYLOAD_WITHIN_HOP_LIMIT == 4680);
    // Mitosis flags must stay within their reserved nibble (bits 4..7) and
    // never overlap ProvenanceSource (bits 0..3).
    std.debug.assert(FLAG_MITOSIS_MEMBER == 0x10);
    std.debug.assert(FLAG_MITOSIS_HAS_NEXT == 0x20);
    std.debug.assert((FLAG_MITOSIS_MEMBER | FLAG_MITOSIS_HAS_NEXT) & 0x0F == 0);
}

// ── Errors ───────────────────────────────────────────────────────────────────

pub const MitosisError = error{
    /// Key slice length does not match required cell count.
    KeyCountMismatch,
    /// Output buffer does not have enough cells.
    OutCountMismatch,
    /// Destination buffer too small for reassembly.
    DestinationTooSmall,
    /// Cell is not a member of a mitosis chain.
    NotAMitosisChain,
    /// Broken chain pointer or corrupted sequence index.
    BrokenLink,
    /// Provenance fields mismatch across chain members.
    ProvenanceMismatch,
    /// Reassembled length does not match header declaration.
    LengthMismatch,
    /// Empty chain input.
    EmptyChain,
    /// Invariant A-11: 4-hop kill trigger fired. Branch depths > 4 are prohibited.
    RefusalMaxHopExceeded,
};

// ── Wire Layout ──────────────────────────────────────────────────────────────

/// On-wire 24-byte layout in the trailing semantic_payload region.
/// Layout: next_key (8B) + chain_seq (4B) + chain_len (4B) + total_payload_len (8B) = 24B.
pub const MitosisLink = struct {
    next_key: u64,
    chain_seq: u32,
    chain_len: u32,
    total_payload_len: u64,
};

pub fn encodeLink(footer: *[LINK_BYTES]u8, l: MitosisLink) void {
    std.mem.writeInt(u64, footer[0..8], l.next_key, .little);
    std.mem.writeInt(u32, footer[8..12], l.chain_seq, .little);
    std.mem.writeInt(u32, footer[12..16], l.chain_len, .little);
    std.mem.writeInt(u64, footer[16..24], l.total_payload_len, .little);
}

pub fn decodeLink(footer: *const [LINK_BYTES]u8) MitosisLink {
    return .{
        .next_key = std.mem.readInt(u64, footer[0..8], .little),
        .chain_seq = std.mem.readInt(u32, footer[8..12], .little),
        .chain_len = std.mem.readInt(u32, footer[12..16], .little),
        .total_payload_len = std.mem.readInt(u64, footer[16..24], .little),
    };
}

/// Computes how many cells a payload of `payload_len` bytes requires.
/// Returns 1 if payload fits in single cell without split; otherwise calculates
/// ceil(payload_len / LINKED_DATA_BYTES).
pub fn chainLen(payload_len: usize) usize {
    if (payload_len <= SEMANTIC_PAYLOAD_BYTES) return 1;
    return (payload_len + LINKED_DATA_BYTES - 1) / LINKED_DATA_BYTES;
}

/// Returns the decoded MitosisLink if cell has the mitosis flag set.
pub fn linkOf(c: *const geometry.Cell) ?MitosisLink {
    if (c.header.provenance_flags & FLAG_MITOSIS_MEMBER == 0) return null;
    const footer: *const [LINK_BYTES]u8 = @ptrCast(c.semantic_payload[LINKED_DATA_BYTES..SEMANTIC_PAYLOAD_BYTES]);
    return decodeLink(footer);
}

/// Writes `payload` into `out` cells. If payload > 960 bytes, triggers mitosis.
/// Enforces Invariant A-11: if required chain exceeds MAX_HOP_DEPTH + 1 cells
/// (hop depth > 4), immediately throws RefusalMaxHopExceeded!
pub fn splitWrite(
    payload: []const u8,
    keys: []const u64,
    subject_id: [16]u8,
    predicate_op: [16]u8,
    provenance_flags: u64,
    out: []geometry.Cell,
) MitosisError!usize {
    const n = chainLen(payload.len);

    // Enforce Invariant A-11: 4-hop kill trigger refusal
    // Root cell is hop 0; each subsequent cell is hop 1, 2, 3, 4.
    // If n > 5 (i.e. hop_depth = n - 1 > 4), hard refusal!
    if (n > MAX_HOP_DEPTH + 1) {
        return MitosisError.RefusalMaxHopExceeded;
    }

    if (keys.len != n) return MitosisError.KeyCountMismatch;
    if (out.len < n) return MitosisError.OutCountMismatch;

    if (n == 1) {
        var c: geometry.Cell = std.mem.zeroes(geometry.Cell);
        c.header.opcode = 0x01; // Write opcode
        c.header.subject_id = subject_id;
        c.header.predicate_op = predicate_op;
        c.header.provenance_flags = provenance_flags;
        @memcpy(c.semantic_payload[0..payload.len], payload);
        out[0] = c;
        return 1;
    }

    var offset: usize = 0;
    var seq: u32 = 0;

    while (seq < n) : (seq += 1) {
        var c: geometry.Cell = std.mem.zeroes(geometry.Cell);
        c.header.opcode = 0x01;
        c.header.subject_id = subject_id;
        c.header.predicate_op = predicate_op;
        const base_flags = provenance_flags & ~(FLAG_MITOSIS_MEMBER | FLAG_MITOSIS_HAS_NEXT);
        c.header.provenance_flags = base_flags | FLAG_MITOSIS_MEMBER;

        const remaining = payload.len - offset;
        const take = @min(remaining, LINKED_DATA_BYTES);
        @memcpy(c.semantic_payload[0..take], payload[offset .. offset + take]);
        offset += take;

        const has_next = seq + 1 < n;
        if (has_next) c.header.provenance_flags |= FLAG_MITOSIS_HAS_NEXT;

        var footer: [LINK_BYTES]u8 = undefined;
        encodeLink(&footer, .{
            .next_key = if (has_next) keys[seq + 1] else 0,
            .chain_seq = seq,
            .chain_len = @intCast(n),
            .total_payload_len = @intCast(payload.len),
        });

        @memcpy(c.semantic_payload[LINKED_DATA_BYTES..SEMANTIC_PAYLOAD_BYTES], &footer);
        out[seq] = c;
    }

    return n;
}

/// Reassembles a chain of split cells back into contiguous bytes in `out`.
/// Verifies sequence order, link pointers, provenance flags, and length consistency.
pub fn reassemble(chain: []const geometry.Cell, keys: []const u64, out: []u8) MitosisError![]u8 {
    if (chain.len == 0) return MitosisError.EmptyChain;
    if (chain.len != keys.len) return MitosisError.BrokenLink;

    // Enforce Invariant A-11
    if (chain.len > MAX_HOP_DEPTH + 1) {
        return MitosisError.RefusalMaxHopExceeded;
    }

    const first_link = linkOf(&chain[0]) orelse return MitosisError.NotAMitosisChain;
    if (first_link.chain_len != chain.len) return MitosisError.BrokenLink;
    if (out.len < first_link.total_payload_len) return MitosisError.DestinationTooSmall;

    var offset: usize = 0;
    var seq: u32 = 0;

    while (seq < chain.len) : (seq += 1) {
        const c = &chain[seq];
        const l = linkOf(c) orelse return MitosisError.NotAMitosisChain;

        if (l.chain_seq != seq) return MitosisError.BrokenLink;
        if (l.chain_len != first_link.chain_len) return MitosisError.BrokenLink;
        if (l.total_payload_len != first_link.total_payload_len) return MitosisError.LengthMismatch;

        // Check provenance coherence across chain
        if (!std.mem.eql(u8, &c.header.subject_id, &chain[0].header.subject_id) or
            !std.mem.eql(u8, &c.header.predicate_op, &chain[0].header.predicate_op))
        {
            return MitosisError.ProvenanceMismatch;
        }

        const has_next = seq + 1 < chain.len;
        if (has_next) {
            if (c.header.provenance_flags & FLAG_MITOSIS_HAS_NEXT == 0) return MitosisError.BrokenLink;
            if (l.next_key != keys[seq + 1]) return MitosisError.BrokenLink;
        } else if (c.header.provenance_flags & FLAG_MITOSIS_HAS_NEXT != 0) {
            return MitosisError.BrokenLink;
        }

        const remaining_total = first_link.total_payload_len - offset;
        const take = @min(remaining_total, LINKED_DATA_BYTES);
        @memcpy(out[offset .. offset + take], c.semantic_payload[0..take]);
        offset += take;
    }

    if (offset != first_link.total_payload_len) return MitosisError.LengthMismatch;
    return out[0..offset];
}

// ── Unit Tests ───────────────────────────────────────────────────────────────

test "chainLen capacity bounds" {
    try std.testing.expectEqual(@as(usize, 1), chainLen(0));
    try std.testing.expectEqual(@as(usize, 1), chainLen(960));
    try std.testing.expectEqual(@as(usize, 2), chainLen(961));
    try std.testing.expectEqual(@as(usize, 2), chainLen(1872));
    try std.testing.expectEqual(@as(usize, 3), chainLen(1873));
    try std.testing.expectEqual(@as(usize, 5), chainLen(4680));
    try std.testing.expectEqual(@as(usize, 6), chainLen(4681));
}

test "splitWrite single cell fits cleanly" {
    var payload: [500]u8 = undefined;
    @memset(&payload, 0x42);
    const keys = [_]u64{100};
    var cells: [1]geometry.Cell = undefined;

    const n = try splitWrite(&payload, &keys, std.mem.zeroes([16]u8), std.mem.zeroes([16]u8), 0, &cells);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualSlices(u8, payload[0..500], cells[0].semantic_payload[0..500]);
    try std.testing.expectEqual(@as(?MitosisLink, null), linkOf(&cells[0]));
}

test "splitWrite and reassemble multi-cell round trip" {
    // 2500 bytes requires 3 cells (936 + 936 + 628)
    var payload: [2500]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @as(u8, @truncate(i));

    const keys = [_]u64{ 101, 102, 103 };
    var cells: [3]geometry.Cell = undefined;

    const n = try splitWrite(&payload, &keys, std.mem.zeroes([16]u8), std.mem.zeroes([16]u8), 0, &cells);
    try std.testing.expectEqual(@as(usize, 3), n);

    // Verify linkOf on each cell
    const l0 = linkOf(&cells[0]).?;
    try std.testing.expectEqual(@as(u32, 0), l0.chain_seq);
    try std.testing.expectEqual(@as(u32, 3), l0.chain_len);
    try std.testing.expectEqual(@as(u64, 102), l0.next_key);

    const l1 = linkOf(&cells[1]).?;
    try std.testing.expectEqual(@as(u32, 1), l1.chain_seq);
    try std.testing.expectEqual(@as(u64, 103), l1.next_key);

    const l2 = linkOf(&cells[2]).?;
    try std.testing.expectEqual(@as(u32, 2), l2.chain_seq);
    try std.testing.expectEqual(@as(u64, 0), l2.next_key);

    // Reassemble
    var reassembled_buf: [2500]u8 = undefined;
    const out = try reassemble(&cells, &keys, &reassembled_buf);
    try std.testing.expectEqualSlices(u8, &payload, out);
}

test "Invariant A-11: 4-hop kill trigger hard refusal" {
    // A payload requiring 6 cells (hop depth 5) must throw RefusalMaxHopExceeded
    // 5 * 936 = 4680 max payload for 5 cells (depth 4). 4681 bytes requires 6 cells (depth 5).
    var big_payload: [4681]u8 = undefined;
    @memset(&big_payload, 0xAA);

    const keys = [_]u64{ 1, 2, 3, 4, 5, 6 };
    var cells: [6]geometry.Cell = undefined;

    const err = splitWrite(&big_payload, &keys, std.mem.zeroes([16]u8), std.mem.zeroes([16]u8), 0, &cells);
    try std.testing.expectError(MitosisError.RefusalMaxHopExceeded, err);
}
