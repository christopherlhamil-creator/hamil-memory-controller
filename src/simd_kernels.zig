//! Re-export of SIMD kernels for tot_hybrid/src/simd_kernels.zig.
//!
//! The C ABI below is deliberately small: callers provide one input chunk,
//! one caller-owned token buffer, and an explicit continuation state. No
//! allocator, global state, or host-specific ISA is part of the contract.

const std = @import("std");
const geometry = @import("geometry");
pub const simd = @import("simd.zig");

pub const CACHE_LINE_BYTES = simd.CACHE_LINE_BYTES;
pub const CELL_CACHE_LINES = simd.CELL_CACHE_LINES;
pub const CELL_BYTES = simd.CELL_BYTES;
pub const BYTECODE_HEADER_BYTES = simd.BYTECODE_HEADER_BYTES;
pub const MAX_HOP_DEPTH = simd.MAX_HOP_DEPTH;
pub const MODEL_CAPACITY_OBSERVATION_BYTES = simd.MODEL_CAPACITY_OBSERVATION_BYTES;
pub const ROUTING_FP_BYTES = simd.ROUTING_FP_BYTES;
pub const ROUTING_VECTOR_BYTES = simd.ROUTING_VECTOR_BYTES;
pub const SIMD_SCAN_BUDGET_MS = simd.SIMD_SCAN_BUDGET_MS;
pub const SIMD_SCAN_BUDGET_NS = simd.SIMD_SCAN_BUDGET_NS;
pub const SIMD_BATCH_SIZE = simd.SIMD_BATCH_SIZE;
pub const MRL_DIM_256 = simd.MRL_DIM_256;
pub const MRL_DIM_1024 = simd.MRL_DIM_1024;
pub const R1_EMBED_DIM = simd.R1_EMBED_DIM;

pub const SimdError = simd.SimdError;
pub const checkHopLimit = simd.checkHopLimit;
pub const RoutingVector = simd.RoutingVector;
pub const RouterMap = simd.RouterMap;

pub const dotProductI8_48 = simd.dotProductI8_48;
pub const cosineSimilarityI8_48 = simd.cosineSimilarityI8_48;
pub const cosineDistanceI8_48 = simd.cosineDistanceI8_48;
pub const dotProductI8 = simd.dotProductI8;
pub const cosineDistanceI8 = simd.cosineDistanceI8;
pub const fingerprintCell = simd.fingerprintCell;

pub const dotProductF32 = simd.dotProductF32;
pub const cosineDistanceF32 = simd.cosineDistanceF32;
pub const cosineSimilarityF32 = simd.cosineSimilarityF32;
pub const euclideanDistanceF32 = simd.euclideanDistanceF32;

pub const dotProductF32_256 = simd.dotProductF32_256;
pub const cosineDistanceF32_256 = simd.cosineDistanceF32_256;
pub const dotProductF32_1024 = simd.dotProductF32_1024;
pub const cosineDistanceF32_1024 = simd.cosineDistanceF32_1024;
pub const dotProductF32_4096 = simd.dotProductF32_4096;
pub const cosineDistanceF32_4096 = simd.cosineDistanceF32_4096;

pub const MatchResult = simd.MatchResult;
pub const scanBestMatchF32 = simd.scanBestMatchF32;
pub const nowNs = simd.nowNs;

// ── Stable chunk lexer ABI ──────────────────────────────────────────────────

pub const SIMD_LEXER_CHUNK_BYTES: usize = 64;

pub const LexerMode = enum(u8) {
    normal = 0,
    string = 1,
    line_comment = 2,
};

/// Continuation state owned by the caller. This is intentionally POD so it is
/// directly representable from C and C# without a Zig allocator or slice.
pub const SimdLexerState = extern struct {
    mode: u8 = @intFromEnum(LexerMode.normal),
    escaped: u8 = 0,
    reserved: [6]u8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(SimdLexerState) == 8);
    }
};

pub const SimdTokenKind = enum(u8) {
    identifier = 1,
    number = 2,
    string = 3,
    line_comment = 4,
    whitespace = 5,
    punctuation = 6,
};

pub const TOKEN_FLAG_CONTINUED: u8 = 1 << 0;
pub const TOKEN_FLAG_CONTINUES: u8 = 1 << 1;

/// A token span relative to the current 64-byte input chunk.
pub const SimdToken = extern struct {
    offset: u32,
    length: u32,
    kind: u8,
    flags: u8,
    reserved: u16 = 0,

    comptime {
        std.debug.assert(@sizeOf(SimdToken) == 12);
    }
};

pub const SimdLexerStatus = enum(i32) {
    ok = 0,
    null_pointer = -1,
    chunk_too_large = -2,
    output_count_pointer_missing = -3,
    output_too_small = -4,
    invalid_state = -5,
};

fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentifierContinue(c: u8) bool {
    return isAlpha(c) or isDigit(c) or c == '_';
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

const ScanError = error{OutputTooSmall};

fn emitToken(
    out: ?[*]SimdToken,
    out_cap: usize,
    count: *usize,
    offset: usize,
    length: usize,
    kind: SimdTokenKind,
    flags: u8,
) ScanError!void {
    if (out != null and count.* >= out_cap) return ScanError.OutputTooSmall;
    if (out) |ptr| {
        ptr[count.*] = .{
            .offset = @intCast(offset),
            .length = @intCast(length),
            .kind = @intFromEnum(kind),
            .flags = flags,
        };
    }
    count.* += 1;
}

fn scanChunk(
    input: []const u8,
    initial: SimdLexerState,
    out: ?[*]SimdToken,
    out_cap: usize,
) ScanError!struct { state: SimdLexerState, count: usize } {
    var state = initial;
    var count: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        const mode: LexerMode = @enumFromInt(state.mode);
        switch (mode) {
            .string => {
                const start = i;
                while (i < input.len) : (i += 1) {
                    const c = input[i];
                    if (state.escaped != 0) {
                        state.escaped = 0;
                    } else if (c == '\\') {
                        state.escaped = 1;
                    } else if (c == '"') {
                        i += 1;
                        state.mode = @intFromEnum(LexerMode.normal);
                        break;
                    }
                }
                var flags: u8 = TOKEN_FLAG_CONTINUED;
                if (state.mode == @intFromEnum(LexerMode.string)) flags |= TOKEN_FLAG_CONTINUES;
                try emitToken(out, out_cap, &count, start, i - start, .string, flags);
            },
            .line_comment => {
                const start = i;
                while (i < input.len) : (i += 1) {
                    if (input[i] == '\n') {
                        i += 1;
                        state.mode = @intFromEnum(LexerMode.normal);
                        break;
                    }
                }
                var flags: u8 = TOKEN_FLAG_CONTINUED;
                if (state.mode == @intFromEnum(LexerMode.line_comment)) flags |= TOKEN_FLAG_CONTINUES;
                try emitToken(out, out_cap, &count, start, i - start, .line_comment, flags);
            },
            .normal => {
                const start = i;
                const c = input[i];
                if (state.reserved[0] == 1 and c != '/') state.reserved[0] = 0;

                if (isWhitespace(c)) {
                    i += 1;
                    while (i < input.len and isWhitespace(input[i])) : (i += 1) {}
                    try emitToken(out, out_cap, &count, start, i - start, .whitespace, 0);
                } else if (isAlpha(c) or c == '_') {
                    i += 1;
                    while (i < input.len and isIdentifierContinue(input[i])) : (i += 1) {}
                    try emitToken(out, out_cap, &count, start, i - start, .identifier, 0);
                } else if (isDigit(c)) {
                    i += 1;
                    while (i < input.len and isDigit(input[i])) : (i += 1) {}
                    try emitToken(out, out_cap, &count, start, i - start, .number, 0);
                } else if (c == '"') {
                    i += 1;
                    state.mode = @intFromEnum(LexerMode.string);
                    state.escaped = 0;
                    while (i < input.len) : (i += 1) {
                        const next = input[i];
                        if (state.escaped != 0) {
                            state.escaped = 0;
                        } else if (next == '\\') {
                            state.escaped = 1;
                        } else if (next == '"') {
                            i += 1;
                            state.mode = @intFromEnum(LexerMode.normal);
                            break;
                        }
                    }
                    var flags: u8 = 0;
                    if (state.mode == @intFromEnum(LexerMode.string)) flags |= TOKEN_FLAG_CONTINUES;
                    try emitToken(out, out_cap, &count, start, i - start, .string, flags);
                } else if (c == '/' and ((i + 1 < input.len and input[i + 1] == '/') or state.reserved[0] == 1)) {
                    if (state.reserved[0] == 1) {
                        i += 1;
                    } else {
                        i += 2;
                    }
                    state.reserved[0] = 0;
                    state.mode = @intFromEnum(LexerMode.line_comment);
                    while (i < input.len) : (i += 1) {
                        if (input[i] == '\n') {
                            i += 1;
                            state.mode = @intFromEnum(LexerMode.normal);
                            break;
                        }
                    }
                    var flags: u8 = 0;
                    if (state.mode == @intFromEnum(LexerMode.line_comment)) flags |= TOKEN_FLAG_CONTINUES;
                    try emitToken(out, out_cap, &count, start, i - start, .line_comment, flags);
                } else {
                    if (c == '/' and i + 1 == input.len) {
                        state.reserved[0] = 1;
                    } else {
                        state.reserved[0] = 0;
                    }
                    i += 1;
                    try emitToken(out, out_cap, &count, start, 1, .punctuation, 0);
                }
            },
        }
    }

    return .{ .state = state, .count = count };
}

/// Tokenizes one chunk of at most 64 bytes. The caller owns all buffers.
/// Return codes are SimdLexerStatus values; on output_too_small, out_count
/// reports the required token capacity and the continuation state is unchanged.
pub export fn simd_tokenize_chunk(
    input_ptr: ?[*]const u8,
    input_len: usize,
    state_ptr: ?*SimdLexerState,
    out_ptr: ?[*]SimdToken,
    out_cap: usize,
    out_count: ?*usize,
) callconv(.c) i32 {
    if (out_count == null) return @intFromEnum(SimdLexerStatus.output_count_pointer_missing);
    out_count.?.* = 0;
    if (input_len > SIMD_LEXER_CHUNK_BYTES) return @intFromEnum(SimdLexerStatus.chunk_too_large);
    if (input_len != 0 and input_ptr == null) return @intFromEnum(SimdLexerStatus.null_pointer);
    if (state_ptr == null) return @intFromEnum(SimdLexerStatus.null_pointer);
    if (out_cap != 0 and out_ptr == null) return @intFromEnum(SimdLexerStatus.null_pointer);
    if (state_ptr.?.mode > @intFromEnum(LexerMode.line_comment) or state_ptr.?.escaped > 1) {
        return @intFromEnum(SimdLexerStatus.invalid_state);
    }

    const input = if (input_len == 0) &[_]u8{} else input_ptr.?[0..input_len];
    const initial = state_ptr.?.*;
    const sizing = scanChunk(input, initial, null, 0) catch unreachable;
    out_count.?.* = sizing.count;
    if (sizing.count > out_cap) return @intFromEnum(SimdLexerStatus.output_too_small);

    const written = scanChunk(input, initial, out_ptr, out_cap) catch unreachable;
    state_ptr.?.* = written.state;
    return @intFromEnum(SimdLexerStatus.ok);
}

// ── C ABI Kanban ring ──────────────────────────────────────────────────────
//
// The mapped region is owned by the caller. `KanbanRing` contains process-local
// pointers only; it must not be persisted in the file backing the mapping.
// Claims return a pointer into the caller-owned slot array, so consumers can
// inspect a cell without copying it across the native boundary.

pub const KANBAN_RING_MAX_CAPACITY: usize = 1024;

pub const KanbanRing = extern struct {
    write_seq: u64 align(64) = 0,
    capacity: u32 = 0,
    initialized: u32 = 0,
    slots: ?[*]KanbanSlot = null,
    reserved: [32]u8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(KanbanRing) == 64);
        std.debug.assert(@alignOf(KanbanRing) == 64);
    }
};

pub const KanbanSlot = extern struct {
    sequence: u64 align(64) = 0,
    cell: geometry.Cell align(64) = undefined,

    comptime {
        std.debug.assert(@sizeOf(KanbanSlot) == 17472);
        std.debug.assert(@alignOf(KanbanSlot) == 64);
        std.debug.assert(@offsetOf(KanbanSlot, "cell") == 64);
    }
};

pub const KanbanStatus = enum(i32) {
    ok = 0,
    null_pointer = -1,
    invalid_capacity = -2,
    not_initialized = -3,
    buffer_full = -4,
    buffer_empty = -5,
    lagging_reader = -6,
    invalid_cursor = -7,
};

fn isPowerOfTwo(value: usize) bool {
    return value != 0 and (value & (value - 1)) == 0;
}

/// Initializes metadata and the caller-owned slot array. The slot array must
/// contain at least `capacity` KanbanSlot values and remain mapped for the
/// lifetime of the ring. No pointer in KanbanRing is suitable for persistence.
pub export fn kanban_ring_init(
    ring: ?*KanbanRing,
    slots: ?[*]KanbanSlot,
    capacity: usize,
) callconv(.c) i32 {
    if (ring == null or slots == null) return @intFromEnum(KanbanStatus.null_pointer);
    if (!isPowerOfTwo(capacity) or capacity > KANBAN_RING_MAX_CAPACITY) {
        return @intFromEnum(KanbanStatus.invalid_capacity);
    }

    ring.?.* = .{
        .write_seq = 0,
        .capacity = @intCast(capacity),
        .initialized = 1,
        .slots = slots,
    };
    for (slots.?[0..capacity]) |*slot| {
        slot.sequence = 0;
        slot.cell = std.mem.zeroes(geometry.Cell);
    }
    return @intFromEnum(KanbanStatus.ok);
}

/// Enqueues one complete fixed-size cell. This is the sole copy performed by
/// this ABI; reads use kanban_ring_claim and return a direct cell pointer.
pub export fn kanban_ring_push(
    ring: ?*KanbanRing,
    source_cell: ?[*]const u8,
    out_sequence: ?*u64,
) callconv(.c) i32 {
    if (ring == null or source_cell == null or out_sequence == null) return @intFromEnum(KanbanStatus.null_pointer);
    if (ring.?.initialized == 0 or ring.?.slots == null) return @intFromEnum(KanbanStatus.not_initialized);

    const seq = @atomicLoad(u64, &ring.?.write_seq, .acquire);
    const capacity: u64 = ring.?.capacity;
    const slot = &ring.?.slots.?[seq & (capacity - 1)];
    const previous = @atomicLoad(u64, &slot.sequence, .acquire);
    if (previous != 0 and seq >= capacity and previous != (seq - capacity + 1) * 2) {
        return @intFromEnum(KanbanStatus.buffer_full);
    }
    @atomicStore(u64, &slot.sequence, seq * 2 + 1, .release);
    @memcpy(std.mem.asBytes(&slot.cell), source_cell.?[0..geometry.CELL_BYTES]);
    @atomicStore(u64, &slot.sequence, (seq + 1) * 2, .release);
    @atomicStore(u64, &ring.?.write_seq, seq + 1, .release);
    out_sequence.?.* = seq;
    return @intFromEnum(KanbanStatus.ok);
}

/// Returns a direct pointer to the cell at `*cursor`. The pointer is valid
/// until that slot is reused; callers must call advance after consuming it.
pub export fn kanban_ring_claim(
    ring: ?*const KanbanRing,
    cursor: ?*u64,
    out_cell: ?*?[*]const u8,
) callconv(.c) i32 {
    if (ring == null or cursor == null or out_cell == null) return @intFromEnum(KanbanStatus.null_pointer);
    if (ring.?.initialized == 0 or ring.?.slots == null) return @intFromEnum(KanbanStatus.not_initialized);
    const write_seq = @atomicLoad(u64, &ring.?.write_seq, .acquire);
    if (cursor.?.* >= write_seq) return @intFromEnum(KanbanStatus.buffer_empty);
    if (write_seq > cursor.?.* + ring.?.capacity) return @intFromEnum(KanbanStatus.lagging_reader);
    const slot = &ring.?.slots.?[cursor.?.* & (ring.?.capacity - 1)];
    if (@atomicLoad(u64, &slot.sequence, .acquire) != (cursor.?.* + 1) * 2) {
        return @intFromEnum(KanbanStatus.buffer_empty);
    }
    out_cell.?.* = @ptrCast(&slot.cell);
    return @intFromEnum(KanbanStatus.ok);
}

/// Advances a reader cursor after its previously claimed cell has been used.
pub export fn kanban_ring_advance(
    ring: ?*const KanbanRing,
    cursor: ?*u64,
) callconv(.c) i32 {
    if (ring == null or cursor == null) return @intFromEnum(KanbanStatus.null_pointer);
    if (ring.?.initialized == 0) return @intFromEnum(KanbanStatus.not_initialized);
    const write_seq = @atomicLoad(u64, &ring.?.write_seq, .acquire);
    if (cursor.?.* >= write_seq) return @intFromEnum(KanbanStatus.invalid_cursor);
    if (write_seq > cursor.?.* + ring.?.capacity) return @intFromEnum(KanbanStatus.lagging_reader);
    cursor.?.* += 1;
    return @intFromEnum(KanbanStatus.ok);
}

test {
    _ = @import("simd.zig");
}

test "Kanban C ABI ring returns direct cell storage" {
    var ring: KanbanRing = .{};
    var slots: [2]KanbanSlot = undefined;
    try std.testing.expectEqual(@as(i32, 0), kanban_ring_init(&ring, &slots, slots.len));

    var cell: geometry.Cell = std.mem.zeroes(geometry.Cell);
    cell.header.opcode = 0xCAFE;
    var sequence: u64 = 99;
    try std.testing.expectEqual(@as(i32, 0), kanban_ring_push(&ring, @ptrCast(&cell), &sequence));
    try std.testing.expectEqual(@as(u64, 0), sequence);

    var cursor: u64 = 0;
    var direct: ?[*]const u8 = null;
    try std.testing.expectEqual(@as(i32, 0), kanban_ring_claim(&ring, &cursor, &direct));
    const claimed: *const geometry.Cell = @ptrCast(@alignCast(direct.?));
    try std.testing.expectEqual(@as(u64, 0xCAFE), claimed.header.opcode);
    try std.testing.expectEqual(@as(i32, 0), kanban_ring_advance(&ring, &cursor));
}

test "simd lexer carries a string across the 64-byte boundary" {
    var first: [64]u8 = @splat(' ');
    first[63] = '"';
    var second = [_]u8{ 'a', '\\', '"', 'b', '"' };
    var state = SimdLexerState{};
    var tokens: [4]SimdToken = undefined;
    var count: usize = 0;

    try std.testing.expectEqual(@as(i32, 0), simd_tokenize_chunk(&first, first.len, &state, &tokens, tokens.len, &count));
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u8, @intFromEnum(SimdTokenKind.string)), tokens[1].kind);
    try std.testing.expect((tokens[1].flags & TOKEN_FLAG_CONTINUES) != 0);

    try std.testing.expectEqual(@as(i32, 0), simd_tokenize_chunk(&second, second.len, &state, &tokens, tokens.len, &count));
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect((tokens[0].flags & TOKEN_FLAG_CONTINUED) != 0);
    try std.testing.expectEqual(@as(u8, @intFromEnum(LexerMode.normal)), state.mode);
}

test "simd lexer: backslash at byte 63 escapes quote at byte 64" {
    var first: [64]u8 = @splat(' ');
    first[60] = '"';
    first[61] = 'x';
    first[62] = 'y';
    first[63] = '\\';
    var second = [_]u8{ '"', 'z', '"' };
    var state = SimdLexerState{};
    var tokens: [8]SimdToken = undefined;
    var count: usize = 0;

    try std.testing.expectEqual(@as(i32, 0), simd_tokenize_chunk(&first, first.len, &state, &tokens, tokens.len, &count));
    try std.testing.expectEqual(@as(u8, @intFromEnum(LexerMode.string)), state.mode);
    try std.testing.expectEqual(@as(u8, 1), state.escaped);

    try std.testing.expectEqual(@as(i32, 0), simd_tokenize_chunk(&second, second.len, &state, &tokens, tokens.len, &count));
    try std.testing.expectEqual(@as(u8, @intFromEnum(LexerMode.normal)), state.mode);
    try std.testing.expectEqual(@as(u8, 0), state.escaped);
}

test "simd lexer: // comment spanning two 64-byte chunks" {
    var first: [64]u8 = @splat(' ');
    first[63] = '/';
    var second: [16]u8 = @splat('c');
    second[0] = '/';
    second[8] = '\n';
    second[9] = 'x';
    var state = SimdLexerState{};
    var tokens: [8]SimdToken = undefined;
    var count: usize = 0;

    try std.testing.expectEqual(@as(i32, 0), simd_tokenize_chunk(&first, first.len, &state, &tokens, tokens.len, &count));
    try std.testing.expectEqual(@as(i32, 0), simd_tokenize_chunk(&second, second.len, &state, &tokens, tokens.len, &count));
    try std.testing.expectEqual(@as(u8, @intFromEnum(LexerMode.normal)), state.mode);
    var saw_comment = false;
    for (tokens[0..count]) |tok| {
        if (tok.kind == @intFromEnum(SimdTokenKind.line_comment)) saw_comment = true;
    }
    try std.testing.expect(saw_comment);
}

test "simd lexer rejects oversized chunks and preserves state on short output" {
    var input: [65]u8 = @splat('x');
    var state = SimdLexerState{};
    var tokens: [1]SimdToken = undefined;
    var count: usize = 0;

    try std.testing.expectEqual(@as(i32, -2), simd_tokenize_chunk(&input, input.len, &state, &tokens, tokens.len, &count));
    try std.testing.expectEqual(@as(usize, 0), count);

    const short_input = "alpha beta";
    const before = state;
    try std.testing.expectEqual(@as(i32, -4), simd_tokenize_chunk(short_input.ptr, short_input.len, &state, &tokens, tokens.len, &count));
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(before, state);
}
