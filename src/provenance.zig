//! Provenance — Origin Tracing and Tagging for tot_hybrid Memory Cells
//!
//! Every cell in the memory controller inherits and carries traceable provenance
//! from the historical source that created it:
//!   1. Embedder: Which model wrote the vector (the closed singleton below)
//!   2. Session: Active session epoch / ID (e.g. default/20260907_125913_f36ccf)
//!   3. Ticket: Originating prompt / task / class_key (from work_pool or antfarm strips)
//!   4. Outcome: Historical outcome / verification (STOP, reconciled, scar_failure, done)
//!
//! Provenance is encoded in two synchronized tiers:
//!   - Tier A: Compact 64-bit bitmask in BytecodeHeader.provenance_flags
//!   - Tier B: Structured CellProvenance descriptor in semantic_payload[0..476]
//!
//! Toolchain: Zig 0.17 compatible. Zero-allocation, clean-room authored.

const std = @import("std");
const geometry = @import("geometry");

/// Model identity is intentionally a closed singleton at the substrate boundary.
pub const EMBEDDER_ID = "embeddinggemma-300m";

// ── Invariants ───────────────────────────────────────────────────────────────

pub const PROVENANCE_MAGIC: u32 = 0x50524F56; // 'PROV' in ASCII
pub const PROVENANCE_VERSION: u16 = 1;

/// String slot widths. These are PERSISTED: `CellProvenance`'s comptime block
/// asserts the byte offset of every field, so changing one re-interprets every
/// cell already on disk. They are named here so the refusals in `init` and the
/// array declarations can never disagree about what the limit is.
pub const EMBEDDER_BYTES: usize = 64;
pub const SESSION_BYTES: usize = 64;
pub const TICKET_BYTES: usize = 128;
pub const OUTCOME_BYTES: usize = 64;
pub const SOURCE_PATH_BYTES: usize = 128;



pub const MAX_PAYLOAD_AVAILABLE: usize = geometry.SEMANTIC_PAYLOAD_BYTES - geometry.LINK_FOOTER_BYTES; // 936 bytes

// ── Enums ───────────────────────────────────────────────────────────────────

pub const ProvenanceSource = enum(u8) {
    unknown = 0,
    embedder_log = 1,      // factory_resident_embed.log
    qdrant_vector = 2,     // fleet_memory (768-d cosine)
    genealogy_sot = 3,     // genealogy.sqlite (transcriptions / extractions)
    antfarm_strip = 4,     // antfarm/strips (1,472 prompt -> action examples)
    scar_failure = 5,      // scars.jsonl (recorded failures)
    fleet_pool_ticket = 6, // fleet_pool.sqlite (work_pool / archive)
    lst_symbol = 7,        // LST pack tracked symbol (file + line, no vector)
};

/// Highest currently-defined tag for each 4-bit enum field. Values above these
/// are foreign or corrupted tags and decode to `.unknown` rather than an
/// illegal enum. Kept next to the enums so adding a variant updates the bound.
pub const MAX_SOURCE_TAG: u8 = @intFromEnum(ProvenanceSource.lst_symbol);
pub const MAX_OUTCOME_TAG: u8 = @intFromEnum(OutcomeKind.refused);

pub const OutcomeKind = enum(u8) {
    unknown = 0,
    verified_pass = 1,
    done = 2,
    reconciled = 3,
    gemini_stop = 4,
    scar_failure = 5,
    refused = 6,
};

// ── Tier A: 64-bit Bitmask Flag Layout ───────────────────────────────────────

/// Compact bitfield layout for BytecodeHeader.provenance_flags (64 bits).
/// Canonical layout lives in geometry.zig (shared with mitosis.zig's chain
/// flags at bits 4..7) so the two modules cannot silently collide again:
///   - Bits 0..3   (4 bits):  ProvenanceSource (0..15)
///   - Bits 4..7   (4 bits):  Mitosis chain flags (mitosis.zig, NOT provenance)
///   - Bits 8..11  (4 bits):  OutcomeKind (0..15)
///   - Bits 12..15 (4 bits):  Hop count (0..4, Invariant A-11)
///   - Bits 16..31 (16 bits): Embedder ID hash token
///   - Bits 32..47 (16 bits): Session ID hash token
///   - Bits 48..63 (16 bits): Ticket / Work order ID hash token
pub const ProvenanceTag = struct {
    source: ProvenanceSource = .unknown,
    outcome: OutcomeKind = .unknown,
    hop_count: u8 = 0,
    embedder_id: u16 = 0,
    session_id: u16 = 0,
    ticket_id: u16 = 0,

    pub fn pack(self: ProvenanceTag) u64 {
        const src_val = (@as(u64, @intFromEnum(self.source)) & geometry.PROV_SOURCE_MASK) << geometry.PROV_SOURCE_SHIFT;
        const out_val = (@as(u64, @intFromEnum(self.outcome)) & 0x0F) << geometry.PROV_OUTCOME_SHIFT;
        const hop_val = (@as(u64, self.hop_count) & 0x0F) << geometry.PROV_HOP_SHIFT;
        const emb_val = (@as(u64, self.embedder_id) & 0xFFFF) << geometry.PROV_EMBEDDER_SHIFT;
        const ses_val = (@as(u64, self.session_id) & 0xFFFF) << geometry.PROV_SESSION_SHIFT;
        const tkt_val = (@as(u64, self.ticket_id) & 0xFFFF) << geometry.PROV_TICKET_SHIFT;

        // Bits 4..7 (mitosis chain flags) are deliberately excluded: pack()
        // only ever sets provenance bits, so callers that OR this into an
        // existing provenance_flags value never clobber mitosis state.
        return src_val | out_val | hop_val | emb_val | ses_val | tkt_val;
    }

    pub fn unpack(flags: u64) ProvenanceTag {
        const src_int = @as(u8, @truncate((flags >> geometry.PROV_SOURCE_SHIFT) & 0x0F));
        const out_int = @as(u8, @truncate((flags >> geometry.PROV_OUTCOME_SHIFT) & 0x0F));
        const hop_int = @as(u8, @truncate((flags >> geometry.PROV_HOP_SHIFT) & 0x0F));
        const emb_int = @as(u16, @truncate((flags >> geometry.PROV_EMBEDDER_SHIFT) & 0xFFFF));
        const ses_int = @as(u16, @truncate((flags >> geometry.PROV_SESSION_SHIFT) & 0xFFFF));
        const tkt_int = @as(u16, @truncate((flags >> geometry.PROV_TICKET_SHIFT) & 0xFFFF));

        return .{
            .source = if (src_int <= MAX_SOURCE_TAG) @enumFromInt(src_int) else .unknown,
            .outcome = if (out_int <= MAX_OUTCOME_TAG) @enumFromInt(out_int) else .unknown,
            .hop_count = hop_int,
            .embedder_id = emb_int,
            .session_id = ses_int,
            .ticket_id = tkt_int,
        };
    }

    pub fn hashToken(str: []const u8) u16 {
        var h: u32 = 2166136261;
        for (str) |b| {
            h ^= b;
            h *%= 16777619;
        }
        return @as(u16, @truncate(h ^ (h >> 16)));
    }
};

// ── Tier B: Structured Cell Provenance Descriptor ───────────────────────────

pub const CellProvenance = extern struct {
    magic: u32 align(8) = PROVENANCE_MAGIC,
    version: u16 = PROVENANCE_VERSION,
    source_type: u8,
    outcome_kind: u8,
    timestamp_ns: u64,
    embedder_len: u16,
    session_len: u16,
    ticket_len: u16,
    outcome_len: u16,
    path_len: u16,
    reserved: [2]u8 = @splat(0),
    /// 1-based line within `source_path` that this cell was tracked from.
    /// 0 means "no line" — the descriptor names a file but not a location.
    /// Carved out of the former `reserved: [6]u8` at a 4-byte-aligned offset,
    /// so every other field offset and the 480-byte size are unchanged and
    /// pre-existing descriptors decode as `source_line == 0`.
    source_line: u32 = 0,
    embedder: [EMBEDDER_BYTES]u8,
    session: [SESSION_BYTES]u8,
    ticket: [TICKET_BYTES]u8,
    outcome: [OUTCOME_BYTES]u8,
    source_path: [SOURCE_PATH_BYTES]u8,

    comptime {
        std.debug.assert(@sizeOf(CellProvenance) == 480);
        std.debug.assert(@sizeOf(CellProvenance) <= MAX_PAYLOAD_AVAILABLE);
        // Layout is on-disk format. These offsets are law, not preference:
        // widening `source_line` or shrinking `reserved` must not shift the
        // string fields, or every persisted cell decodes to garbage.
        std.debug.assert(@offsetOf(CellProvenance, "path_len") == 24);
        std.debug.assert(@offsetOf(CellProvenance, "reserved") == 26);
        std.debug.assert(@offsetOf(CellProvenance, "source_line") == 28);
        std.debug.assert(@offsetOf(CellProvenance, "embedder") == 32);
        std.debug.assert(@offsetOf(CellProvenance, "source_path") == 352);
    }

    /// Stamps a provenance record. Every string field is REFUSED if it will
    /// not fit its slot; none is trimmed.
    ///
    /// This record is persisted and its byte offsets are asserted above, so
    /// widening a slot is not available -- it would re-interpret every cell
    /// already on disk. Refusal is the only honest answer left, and it is the
    /// right one: `source_path` is 128 bytes and **11 of this repo's 2,663
    /// tracked files have an absolute path longer than that** (longest 155,
    /// measured 2026-09-12). A trimmed `source_path` is not a shorter path, it
    /// is a path that does not exist, returned by `getSourcePath()` to a caller
    /// trying to resolve a cite key. Provenance that cannot be resolved is
    /// worse than absent provenance, because it looks resolvable.
    pub fn init(
        source: ProvenanceSource,
        outcome: OutcomeKind,
        embedder_str: []const u8,
        session_str: []const u8,
        ticket_str: []const u8,
        outcome_str: []const u8,
        path_str: []const u8,
        line: u32,
        ts_ns: u64,
    ) ProvenanceError!CellProvenance {
        if (embedder_str.len > EMBEDDER_BYTES) return ProvenanceError.EmbedderTooLong;
        if (session_str.len > SESSION_BYTES) return ProvenanceError.SessionTooLong;
        if (ticket_str.len > TICKET_BYTES) return ProvenanceError.TicketTooLong;
        if (outcome_str.len > OUTCOME_BYTES) return ProvenanceError.OutcomeTooLong;
        if (path_str.len > SOURCE_PATH_BYTES) return ProvenanceError.SourcePathTooLong;

        var res = CellProvenance{
            .magic = PROVENANCE_MAGIC,
            .version = PROVENANCE_VERSION,
            .source_type = @intFromEnum(source),
            .outcome_kind = @intFromEnum(outcome),
            .timestamp_ns = ts_ns,
            .embedder_len = @intCast(embedder_str.len),
            .session_len = @intCast(session_str.len),
            .ticket_len = @intCast(ticket_str.len),
            .outcome_len = @intCast(outcome_str.len),
            .path_len = @intCast(path_str.len),
            .reserved = @splat(0),
            .source_line = line,
            .embedder = @splat(0),
            .session = @splat(0),
            .ticket = @splat(0),
            .outcome = @splat(0),
            .source_path = @splat(0),
        };

        @memcpy(res.embedder[0..embedder_str.len], embedder_str);
        @memcpy(res.session[0..session_str.len], session_str);
        @memcpy(res.ticket[0..ticket_str.len], ticket_str);
        @memcpy(res.outcome[0..outcome_str.len], outcome_str);
        @memcpy(res.source_path[0..path_str.len], path_str);

        return res;
    }

    pub fn getEmbedder(self: *const CellProvenance) []const u8 {
        return self.embedder[0..self.embedder_len];
    }

    pub fn getSession(self: *const CellProvenance) []const u8 {
        return self.session[0..self.session_len];
    }

    pub fn getTicket(self: *const CellProvenance) []const u8 {
        return self.ticket[0..self.ticket_len];
    }

    pub fn getOutcome(self: *const CellProvenance) []const u8 {
        return self.outcome[0..self.outcome_len];
    }

    pub fn getSourcePath(self: *const CellProvenance) []const u8 {
        return self.source_path[0..self.path_len];
    }

    pub fn getSourceLine(self: *const CellProvenance) u32 {
        return self.source_line;
    }

    /// True when the descriptor names a concrete `file:line` location rather
    /// than a bare file or nothing at all.
    pub fn hasSourceLocation(self: *const CellProvenance) bool {
        return self.path_len > 0 and self.source_line > 0;
    }
};

// ── Cell Tagging & Verification API ─────────────────────────────────────────

pub const ProvenanceError = error{
    MissingProvenance,
    InvalidMagic,
    VersionMismatch,
    HopDepthExceeded,
    InvalidEmbedder,
    CorruptedProvenance,
    // ── Stamp-time refusals. Persisted slots cannot widen, so they refuse. ──
    EmbedderTooLong,
    SessionTooLong,
    TicketTooLong,
    OutcomeTooLong,
    /// A source path wider than `SOURCE_PATH_BYTES`. Measured 2026-09-12: 11 of
    /// this repo's 2,663 tracked files exceed it, longest 155 bytes. A trimmed
    /// path is not a shorter path, it is one that does not exist.
    SourcePathTooLong,
};

/// Writes ONLY the Tier B descriptor into `cell.semantic_payload[0..480]`,
/// leaving `cell.header` byte-for-byte untouched.
///
/// This is the path a `memctl_post` cell must take. Its 64-byte header is a
/// `gate_lattice_laws.InstructionHeader` (`=Q16s16s16sII` — Invariant A-2),
/// whose trailing 8 bytes are `flags:u32 | epoch:u32`, occupying exactly the
/// bits `ProvenanceTag` claims for the session (32..47) and ticket (48..63)
/// hash tokens. Packing Tier A over them would silently destroy the epoch
/// fencing token that `memctl_query` and the gate lattice both read, so a
/// posted cell records its origin in Tier B only.
///
/// Tier B is self-describing: `readCellProvenance` gates on
/// `PROVENANCE_MAGIC`, so a reader can tell a stamped cell from an unstamped
/// one without any header bit to flag it.
pub fn writeTierB(cell: *geometry.Cell, prov: CellProvenance) void {
    const prov_bytes = std.mem.asBytes(&prov);
    @memcpy(cell.semantic_payload[0..@sizeOf(CellProvenance)], prov_bytes);
}

/// Tags a Cell with both Tier A bitflags in header and Tier B descriptor in payload.
pub fn tagCell(cell: *geometry.Cell, prov: CellProvenance, hop_count: u8) ProvenanceError!void {
    if (hop_count > geometry.MAX_HOP_DEPTH) {
        return ProvenanceError.HopDepthExceeded;
    }
    if (!std.mem.eql(u8, prov.getEmbedder(), EMBEDDER_ID)) {
        return ProvenanceError.InvalidEmbedder;
    }

    const tag = ProvenanceTag{
        .source = if (prov.source_type <= MAX_SOURCE_TAG) @enumFromInt(prov.source_type) else .unknown,
        .outcome = if (prov.outcome_kind <= MAX_OUTCOME_TAG) @enumFromInt(prov.outcome_kind) else .unknown,
        .hop_count = hop_count,
        .embedder_id = ProvenanceTag.hashToken(prov.getEmbedder()),
        .session_id = ProvenanceTag.hashToken(prov.getSession()),
        .ticket_id = ProvenanceTag.hashToken(prov.getTicket()),
    };

    // Pack Tier A into header.provenance_flags, preserving bits 4..7 (mitosis
    // chain flags) — tag.pack() never sets them, but a naive assignment here
    // would still zero out whatever mitosis.zig had already written there.
    const mitosis_bits = cell.header.provenance_flags & geometry.MITOSIS_FLAGS_MASK;
    cell.header.provenance_flags = tag.pack() | mitosis_bits;

    // Pack Tier B into semantic_payload[0..480]
    writeTierB(cell, prov);
}

/// Reads and validates provenance descriptor directly from a Cell.
pub fn readCellProvenance(cell: *const geometry.Cell) ProvenanceError!CellProvenance {
    var prov: CellProvenance = undefined;
    const prov_bytes = std.mem.asBytes(&prov);
    @memcpy(prov_bytes, cell.semantic_payload[0..@sizeOf(CellProvenance)]);

    if (prov.magic != PROVENANCE_MAGIC) {
        return ProvenanceError.MissingProvenance;
    }
    if (prov.version != PROVENANCE_VERSION) {
        return ProvenanceError.VersionMismatch;
    }

    const tag = ProvenanceTag.unpack(cell.header.provenance_flags);
    if (tag.hop_count > geometry.MAX_HOP_DEPTH) {
        return ProvenanceError.HopDepthExceeded;
    }

    return prov;
}

/// Checks if a cell carries verified, untampered provenance.
pub fn hasValidProvenance(cell: *const geometry.Cell) bool {
    const prov = readCellProvenance(cell) catch return false;
    const tag = ProvenanceTag.unpack(cell.header.provenance_flags);

    if (tag.source == .unknown) return false;
    if (!std.mem.eql(u8, prov.getEmbedder(), EMBEDDER_ID)) return false;
    if (prov.session_len == 0) return false;

    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "ProvenanceTag: pack and unpack roundtrip" {
    const tag = ProvenanceTag{
        .source = .genealogy_sot,
        .outcome = .reconciled,
        .hop_count = 2,
        .embedder_id = 0xA1B2,
        .session_id = 0xC3D4,
        .ticket_id = 0xE5F6,
    };

    const packed_flags = tag.pack();
    const unpacked = ProvenanceTag.unpack(packed_flags);

    try std.testing.expectEqual(tag.source, unpacked.source);
    try std.testing.expectEqual(tag.outcome, unpacked.outcome);
    try std.testing.expectEqual(tag.hop_count, unpacked.hop_count);
    try std.testing.expectEqual(tag.embedder_id, unpacked.embedder_id);
    try std.testing.expectEqual(tag.session_id, unpacked.session_id);
    try std.testing.expectEqual(tag.ticket_id, unpacked.ticket_id);
}

test "Provenance and mitosis flag masks are disjoint" {
    try std.testing.expectEqual(@as(u64, 0), geometry.MITOSIS_FLAGS_MASK & geometry.PROV_SOURCE_MASK);
    try std.testing.expectEqual(@as(u64, 0x10), geometry.FLAG_MITOSIS_MEMBER);
    try std.testing.expectEqual(@as(u64, 0x20), geometry.FLAG_MITOSIS_HAS_NEXT);

    var cell: geometry.Cell = undefined;
    cell.header.provenance_flags = geometry.MITOSIS_FLAGS_MASK;
    @memset(&cell.semantic_payload, 0);
    const prov = try CellProvenance.init(
        .embedder_log,
        .verified_pass,
        EMBEDDER_ID,
        "default/session",
        "ticket_001",
        "done",
        "logs/embedder.log",
        0,
        1000,
    );
    try tagCell(&cell, prov, 1);
    try std.testing.expectEqual(geometry.MITOSIS_FLAGS_MASK, cell.header.provenance_flags & geometry.MITOSIS_FLAGS_MASK);
    try std.testing.expectEqual(@as(u64, @intFromEnum(ProvenanceSource.embedder_log)), cell.header.provenance_flags & geometry.PROV_SOURCE_MASK);
}

test "Provenance: Invariant A-11 hop depth limit check" {
    var cell: geometry.Cell = undefined;
    cell.header.provenance_flags = 0;
    @memset(&cell.semantic_payload, 0);

    const prov = try CellProvenance.init(
        .embedder_log,
        .verified_pass,
        EMBEDDER_ID,
        "default/20260907_125913_f36ccf",
        "ticket_001",
        "done",
        "tot_hybrid/logs/embedder.log",
        0,
        1000,
    );

    // Hop count 4 passes
    try tagCell(&cell, prov, 4);
    const read_back = try readCellProvenance(&cell);
    try std.testing.expectEqualStrings(EMBEDDER_ID, read_back.getEmbedder());

    // Hop count 5 triggers HopDepthExceeded (Invariant A-11)
    const err = tagCell(&cell, prov, 5);
    try std.testing.expectError(ProvenanceError.HopDepthExceeded, err);
}

test "Provenance: Cell tagging, extraction, and validation roundtrip" {
    var cell: geometry.Cell = undefined;
    cell.header.opcode = 2561; // ENTITY_ASSERTION
    cell.header.provenance_flags = 0;
    @memset(&cell.fingerprints, @as(geometry.FingerprintVector, .{ .words = @splat(0) }));
    @memset(&cell.semantic_payload, 0);

    // Initial state has no valid provenance
    try std.testing.expect(!hasValidProvenance(&cell));

    // Tag cell with genealogy SOT provenance. The embedder is a closed
    // singleton at the substrate boundary; cloud model names are not embedder
    // identities and must not enter a cell fixture.
    const prov = try CellProvenance.init(
        .genealogy_sot,
        .gemini_stop,
        EMBEDDER_ID,
        "default/20260907_125913_f36ccf",
        "doc_intake_188_guion_miller",
        "STOP",
        "tot_hybrid/db/corpus.sqlite",
        0,
        1724227696000000000,
    );

    try tagCell(&cell, prov, 1);

    // Now provenance is valid
    try std.testing.expect(hasValidProvenance(&cell));

    const read = try readCellProvenance(&cell);
    try std.testing.expectEqualStrings(EMBEDDER_ID, read.getEmbedder());
    try std.testing.expectEqualStrings("default/20260907_125913_f36ccf", read.getSession());
    try std.testing.expectEqualStrings("doc_intake_188_guion_miller", read.getTicket());
    try std.testing.expectEqualStrings("STOP", read.getOutcome());
    try std.testing.expectEqualStrings("tot_hybrid/db/corpus.sqlite", read.getSourcePath());
}

test "Provenance: rejects non-canonical embedder identity" {
    var cell: geometry.Cell = undefined;
    cell.header.provenance_flags = 0;
    @memset(&cell.semantic_payload, 0);

    const noncanonical = try CellProvenance.init(
        .embedder_log,
        .verified_pass,
        "deprecated-embedder-fixture",
        "default/session",
        "ticket_001",
        "done",
        "logs/embedder.log",
        0,
        1000,
    );

    try std.testing.expectError(ProvenanceError.InvalidEmbedder, tagCell(&cell, noncanonical, 0));
    try std.testing.expect(!hasValidProvenance(&cell));
}

test "every persisted provenance slot refuses rather than trims" {
    // Exactly at each limit: admitted, and read back whole.
    const embedder: [EMBEDDER_BYTES]u8 = @splat('e');
    const session: [SESSION_BYTES]u8 = @splat('s');
    const ticket: [TICKET_BYTES]u8 = @splat('t');
    const outcome: [OUTCOME_BYTES]u8 = @splat('o');
    const path: [SOURCE_PATH_BYTES]u8 = @splat('p');

    const exact = try CellProvenance.init(
        .embedder_log, .verified_pass,
        &embedder, &session, &ticket, &outcome, &path, 1, 1,
    );
    try std.testing.expectEqualSlices(u8, &embedder, exact.getEmbedder());
    try std.testing.expectEqual(@as(usize, SOURCE_PATH_BYTES), exact.path_len);

    // One byte over each: refused, each with its own name.
    const e1: [EMBEDDER_BYTES + 1]u8 = @splat('e');
    const s1: [SESSION_BYTES + 1]u8 = @splat('s');
    const t1: [TICKET_BYTES + 1]u8 = @splat('t');
    const o1: [OUTCOME_BYTES + 1]u8 = @splat('o');
    const p1: [SOURCE_PATH_BYTES + 1]u8 = @splat('p');

    try std.testing.expectError(ProvenanceError.EmbedderTooLong, CellProvenance.init(
        .embedder_log, .verified_pass, &e1, "s", "t", "o", "p", 1, 1));
    try std.testing.expectError(ProvenanceError.SessionTooLong, CellProvenance.init(
        .embedder_log, .verified_pass, "e", &s1, "t", "o", "p", 1, 1));
    try std.testing.expectError(ProvenanceError.TicketTooLong, CellProvenance.init(
        .embedder_log, .verified_pass, "e", "s", &t1, "o", "p", 1, 1));
    try std.testing.expectError(ProvenanceError.OutcomeTooLong, CellProvenance.init(
        .embedder_log, .verified_pass, "e", "s", "t", &o1, "p", 1, 1));
    try std.testing.expectError(ProvenanceError.SourcePathTooLong, CellProvenance.init(
        .embedder_log, .verified_pass, "e", "s", "t", "o", &p1, 1, 1));
}

test "a real repo path over the 128-byte slot is refused, not silently shortened" {
    // Measured 2026-09-12: 11 of 2,663 tracked files have an absolute path
    // longer than SOURCE_PATH_BYTES. This is one of them, verbatim (155 B).
    const real = "/home/christopherhamil/tot_hybrid/inventory/PRESERVE-20260911-ROOT-TREE-VARIANTS/worktree/docs/BLUEPRINT-20260911-COUNCIL-CHAIN-IGNITION-PROVENANCE-GATE.md";
    try std.testing.expect(real.len > SOURCE_PATH_BYTES);

    try std.testing.expectError(ProvenanceError.SourcePathTooLong, CellProvenance.init(
        .embedder_log, .verified_pass, "e", "s", "t", "o", real, 1, 1));

    // Trimmed, it would have been stamped as this -- a path that does not
    // exist, handed to whoever tries to resolve the cite key.
    const trimmed = real[0..SOURCE_PATH_BYTES];
    try std.testing.expect(!std.mem.eql(u8, trimmed, real));
}

test "the persisted layout did not move" {
    // The refusals exist BECAUSE these offsets cannot change. If this test ever
    // fails, every cell already on disk decodes to garbage.
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(CellProvenance, "path_len"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(CellProvenance, "embedder"));
    try std.testing.expectEqual(@as(usize, 352), @offsetOf(CellProvenance, "source_path"));
}
