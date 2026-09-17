//! Portable 64-byte SIMD/SWAR chunk lexer (Tier 0).
//!
//! Extracted carry protocol from Accelerated-Zig-Parser (Validark) + simdjson
//! escaped-position algorithm (John Keiser, Apache-2.0). Zig 0.17, no ISA pin:
//! `@Vector(64, u8)` is lowered by LLVM (AVX2 on Pop, AVX-512 on Brandys).
//!
//! Invariants: A-1 17408, A-2 64, A-11 hop<=4. Zero heap in scanChunk64.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");

pub const CHUNK_BYTES: usize = 64;
pub const CELL_BYTES: usize = geometry.CELL_BYTES;
pub const BYTECODE_HEADER_BYTES: usize = geometry.BYTECODE_HEADER_BYTES;
pub const MAX_HOP_DEPTH: usize = geometry.MAX_HOP_DEPTH;

comptime {
    std.debug.assert(CHUNK_BYTES == 64);
    std.debug.assert(CELL_BYTES == 17408);
    std.debug.assert(BYTECODE_HEADER_BYTES == 64);
    std.debug.assert(MAX_HOP_DEPTH == 4);
    std.debug.assert(@sizeOf(geometry.BytecodeHeader) == 64);
    std.debug.assert(@sizeOf(geometry.Cell) == 17408);
}

pub const Carry = packed struct(u8) {
    next_is_escaped: u1 = 0,
    inside_quotes: u1 = 0,
    inside_comments: u1 = 0,
    inside_line_strings: u1 = 0,
    prev_slash: u1 = 0,
    prev_backslash: u1 = 0,
    prev_cr: u1 = 0,
    _reserved: u1 = 0,

    pub fn toU8(self: Carry) u8 {
        return @bitCast(self);
    }

    pub fn fromU8(bits: u8) Carry {
        return @bitCast(bits);
    }
};

pub const ScanResult = struct {
    quotes: u64,
    backslashes: u64,
    slashes: u64,
    newlines: u64,
    carriages: u64,
    escaped: u64,
    unescaped_quotes: u64,
    double_slash_starts: u64,
    double_backslash_starts: u64,
    inside_quotes: u64,
    inside_comments: u64,
    inside_line_strings: u64,
    bad_carriage_returns: u64,
    carry: Carry,
};

inline fn eqMask(chunk: @Vector(64, u8), needle: u8) u64 {
    const eq = chunk == @as(@Vector(64, u8), @splat(needle));
    return @as(u64, @bitCast(@as(@Vector(64, u1), @intFromBool(eq))));
}

/// Prefix-XOR: bit i is the parity of bits 0..=i. Used as quote-toggle fill.
fn prefixXor(x: u64) u64 {
    var y = x;
    y ^= y << 1;
    y ^= y << 2;
    y ^= y << 4;
    y ^= y << 8;
    y ^= y << 16;
    y ^= y << 32;
    return y;
}

/// simdjson escaped-byte mask. `carry.next_is_escaped` is the previous chunk's
/// trailing-backslash oddness (LSB 0/1). Bit 0 = first byte of this chunk.
fn escapedPositions(backslashes: u64, carry: *Carry) u64 {
    const odd: u64 = 0xAAAAAAAAAAAAAAAA;
    const next_is_escaped: u64 = carry.next_is_escaped;
    const potential_escape = backslashes & ~next_is_escaped;
    const maybe_escaped = potential_escape << 1;
    const even_series_codes_and_odd = (maybe_escaped | odd) -% potential_escape;
    const escape_and_terminal = even_series_codes_and_odd ^ odd;
    const escaped = escape_and_terminal ^ (backslashes | next_is_escaped);
    carry.next_is_escaped = @truncate((escape_and_terminal & backslashes) >> 63);
    return escaped;
}

/// Classify one aligned 64-byte chunk. No allocation.
pub fn scanChunk64(bytes: *const [CHUNK_BYTES]u8, carry_in: Carry) ScanResult {
    const chunk: @Vector(64, u8) = bytes.*;
    const quotes = eqMask(chunk, '"');
    const backslashes = eqMask(chunk, '\\');
    const slashes = eqMask(chunk, '/');
    const newlines = eqMask(chunk, '\n');
    const carriages = eqMask(chunk, '\r');

    var carry = carry_in;
    const escaped = escapedPositions(backslashes, &carry);
    const unescaped_quotes = quotes & ~escaped;

    const bad_carriage_returns = ~newlines & ((carriages << 1) | @as(u64, carry_in.prev_cr));
    const double_slash_starts = slashes & ((slashes >> 1) | @as(u64, carry_in.prev_slash));
    const double_backslash_starts = backslashes & ((backslashes >> 1) | @as(u64, carry_in.prev_backslash));

    var inside_quotes = prefixXor(unescaped_quotes);
    if (carry_in.inside_quotes == 1) inside_quotes = ~inside_quotes;

    var inside_comments: u64 = 0;
    var inside_line_strings: u64 = 0;
    var in_comment = carry_in.inside_comments == 1;
    var in_ls = carry_in.inside_line_strings == 1;

    // Fast interval scanning using hardware @ctz (tzcnt)
    if (in_comment) {
        if (newlines != 0) {
            const nl_pos = @ctz(newlines);
            const mask = (@as(u64, 1) << @truncate(nl_pos)) -% 1;
            inside_comments |= mask;
            in_comment = false;
        } else {
            inside_comments = ~@as(u64, 0);
        }
    } else if (in_ls) {
        if (newlines != 0) {
            const nl_pos = @ctz(newlines);
            const mask = (@as(u64, 1) << @truncate(nl_pos)) -% 1;
            inside_line_strings |= mask;
            in_ls = false;
        } else {
            inside_line_strings = ~@as(u64, 0);
        }
    }

    var rem_starts = (double_slash_starts | double_backslash_starts) & ~inside_quotes;
    while (rem_starts != 0) {
        const start_pos: u6 = @truncate(@ctz(rem_starts));
        const start_bit = @as(u64, 1) << start_pos;
        const start_mask = ~((start_bit << 1) -% 1);

        if ((double_slash_starts & start_bit) != 0) {
            const rem_nl = newlines & start_mask;
            if (rem_nl != 0) {
                const nl_pos: u6 = @truncate(@ctz(rem_nl));
                const mask = ((@as(u64, 1) << nl_pos) -% 1) & ~(start_bit -% 1);
                inside_comments |= mask;
                rem_starts &= ~((@as(u64, 1) << nl_pos) -% 1);
            } else {
                inside_comments |= ~(start_bit -% 1);
                in_comment = true;
                break;
            }
        } else {
            const rem_nl = newlines & start_mask;
            if (rem_nl != 0) {
                const nl_pos: u6 = @truncate(@ctz(rem_nl));
                const mask = ((@as(u64, 1) << nl_pos) -% 1) & ~(start_bit -% 1);
                inside_line_strings |= mask;
                rem_starts &= ~((@as(u64, 1) << nl_pos) -% 1);
            } else {
                inside_line_strings |= ~(start_bit -% 1);
                in_ls = true;
                break;
            }
        }
    }

    carry.inside_quotes = @truncate(inside_quotes >> 63);
    carry.inside_comments = if (in_comment) 1 else 0;
    carry.inside_line_strings = if (in_ls) 1 else 0;
    carry.prev_slash = @truncate(slashes >> 63);
    carry.prev_backslash = @truncate(backslashes >> 63);
    carry.prev_cr = @truncate(carriages >> 63);

    return .{
        .quotes = quotes,
        .backslashes = backslashes,
        .slashes = slashes,
        .newlines = newlines,
        .carriages = carriages,
        .escaped = escaped,
        .unescaped_quotes = unescaped_quotes,
        .double_slash_starts = double_slash_starts,
        .double_backslash_starts = double_backslash_starts,
        .inside_quotes = inside_quotes,
        .inside_comments = inside_comments,
        .inside_line_strings = inside_line_strings,
        .bad_carriage_returns = bad_carriage_returns,
        .carry = carry,
    };
}

/// Scan an entire buffer as successive 64-byte chunks. `src.len` must be a
/// multiple of 64 (caller pads). Returns final carry. No heap.
pub fn scanBuffer(src: []align(64) const u8, carry_in: Carry) Carry {
    std.debug.assert(src.len % CHUNK_BYTES == 0);
    var carry = carry_in;
    var off: usize = 0;
    while (off < src.len) : (off += CHUNK_BYTES) {
        const chunk: *const [CHUNK_BYTES]u8 = @ptrCast(src.ptr + off);
        carry = scanChunk64(chunk, carry).carry;
    }
    return carry;
}

pub const TokenKind = enum(u8) {
    identifier = 1,
    string = 2,
    comment = 3,
    line_string = 4,
    newline = 5,
    other = 6,
};

/// Map a lexer kind + lexeme into a 64B BytecodeHeader (A-2). Seat 2 wires GBNF.
pub fn tokenToHeader(kind: TokenKind, lexeme: []const u8) geometry.BytecodeHeader {
    var hdr = std.mem.zeroes(geometry.BytecodeHeader);
    hdr.opcode = @intFromEnum(kind);
    const n = @min(lexeme.len, 16);
    @memcpy(hdr.subject_id[0..n], lexeme[0..n]);
    const pred = "lex_token";
    @memcpy(hdr.predicate_op[0..pred.len], pred);
    return hdr;
}

/// Scalar byte-by-byte classifier used as the legacy throughput baseline.
/// Same carry fields, no vectors. Heap-free.
pub fn scanChunk64Scalar(bytes: *const [CHUNK_BYTES]u8, carry_in: Carry) ScanResult {
    var quotes: u64 = 0;
    var backslashes: u64 = 0;
    var slashes: u64 = 0;
    var newlines: u64 = 0;
    var carriages: u64 = 0;
    var i: u6 = 0;
    while (true) {
        const bit = @as(u64, 1) << i;
        switch (bytes[i]) {
            '"' => quotes |= bit,
            '\\' => backslashes |= bit,
            '/' => slashes |= bit,
            '\n' => newlines |= bit,
            '\r' => carriages |= bit,
            else => {},
        }
        if (i == 63) break;
        i += 1;
    }
    var carry = carry_in;
    const escaped = escapedPositions(backslashes, &carry);
    const unescaped_quotes = quotes & ~escaped;
    const bad_carriage_returns = ~newlines & ((carriages << 1) | @as(u64, carry_in.prev_cr));
    const double_slash_starts = slashes & ((slashes >> 1) | @as(u64, carry_in.prev_slash));
    const double_backslash_starts = backslashes & ((backslashes >> 1) | @as(u64, carry_in.prev_backslash));
    var inside_quotes = prefixXor(unescaped_quotes);
    if (carry_in.inside_quotes == 1) inside_quotes = ~inside_quotes;

    var inside_comments: u64 = 0;
    var inside_line_strings: u64 = 0;
    var in_comment = carry_in.inside_comments == 1;
    var in_ls = carry_in.inside_line_strings == 1;
    i = 0;
    while (true) {
        const bit = @as(u64, 1) << i;
        if ((inside_quotes & bit) != 0) {
            in_comment = false;
            in_ls = false;
        } else {
            if (!in_comment and !in_ls) {
                if ((double_slash_starts & bit) != 0) in_comment = true;
                if ((double_backslash_starts & bit) != 0) in_ls = true;
            }
            if ((newlines & bit) != 0) {
                in_comment = false;
                in_ls = false;
            }
        }
        if (in_comment) inside_comments |= bit;
        if (in_ls) inside_line_strings |= bit;
        if (i == 63) break;
        i += 1;
    }
    carry.inside_quotes = @truncate(inside_quotes >> 63);
    carry.inside_comments = if (in_comment) 1 else 0;
    carry.inside_line_strings = if (in_ls) 1 else 0;
    carry.prev_slash = @truncate(slashes >> 63);
    carry.prev_backslash = @truncate(backslashes >> 63);
    carry.prev_cr = @truncate(carriages >> 63);
    return .{
        .quotes = quotes,
        .backslashes = backslashes,
        .slashes = slashes,
        .newlines = newlines,
        .carriages = carriages,
        .escaped = escaped,
        .unescaped_quotes = unescaped_quotes,
        .double_slash_starts = double_slash_starts,
        .double_backslash_starts = double_backslash_starts,
        .inside_quotes = inside_quotes,
        .inside_comments = inside_comments,
        .inside_line_strings = inside_line_strings,
        .bad_carriage_returns = bad_carriage_returns,
        .carry = carry,
    };
}

/// Null baseline: force a read of every byte via vector XOR-reduce. Heap-free
/// in the loop (buffer is caller-owned).
pub fn nullReadXor(src: []align(64) const u8) u8 {
    var acc: @Vector(64, u8) = @splat(0);
    var off: usize = 0;
    while (off < src.len) : (off += CHUNK_BYTES) {
        const chunk: @Vector(64, u8) = @as(*const [CHUNK_BYTES]u8, @ptrCast(src.ptr + off)).*;
        acc ^= chunk;
    }
    return @reduce(.Xor, acc);
}

pub const Throughput = struct {
    null_gbps: f64,
    scalar_gbps: f64,
    vector_gbps: f64,
};

fn gbps(bytes: usize, ns: u64) f64 {
    if (ns == 0) return 0;
    return (@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(ns))) * 1.0e9 / (1024.0 * 1024.0 * 1024.0);
}

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn measureThroughput(src: []align(64) const u8, repeats: u32) !Throughput {
    var null_ns: u64 = std.math.maxInt(u64);
    var scalar_ns: u64 = std.math.maxInt(u64);
    var vector_ns: u64 = std.math.maxInt(u64);

    var r: u32 = 0;
    while (r < repeats) : (r += 1) {
        const t0 = nowNs();
        const sink = nullReadXor(src);
        const n0 = nowNs() - t0;
        std.mem.doNotOptimizeAway(sink);
        if (n0 < null_ns) null_ns = n0;

        const t1 = nowNs();
        var carry_s: Carry = .{};
        var off: usize = 0;
        while (off < src.len) : (off += CHUNK_BYTES) {
            const chunk: *const [CHUNK_BYTES]u8 = @ptrCast(src.ptr + off);
            carry_s = scanChunk64Scalar(chunk, carry_s).carry;
        }
        const n1 = nowNs() - t1;
        std.mem.doNotOptimizeAway(carry_s.toU8());
        if (n1 < scalar_ns) scalar_ns = n1;

        const t2 = nowNs();
        var carry_v: Carry = .{};
        off = 0;
        while (off < src.len) : (off += CHUNK_BYTES) {
            const chunk: *const [CHUNK_BYTES]u8 = @ptrCast(src.ptr + off);
            carry_v = scanChunk64(chunk, carry_v).carry;
        }
        const n2 = nowNs() - t2;
        std.mem.doNotOptimizeAway(carry_v.toU8());
        if (n2 < vector_ns) vector_ns = n2;
    }

    return .{
        .null_gbps = gbps(src.len, null_ns),
        .scalar_gbps = gbps(src.len, scalar_ns),
        .vector_gbps = gbps(src.len, vector_ns),
    };
}

fn fillPattern(buf: []u8) void {
    const pat = "const x = \"hello\"; // cmt\n\\\\ line\r\na = \"esc\\\"q\"; fn f() void {}\n";
    var i: usize = 0;
    while (i < buf.len) {
        const n = @min(pat.len, buf.len - i);
        @memcpy(buf[i..][0..n], pat[0..n]);
        i += n;
    }
}

fn twoChunks(c0: * [64]u8, c1: *[64]u8) void {
    @memset(c0, ' ');
    @memset(c1, ' ');
}

test "invariants A-1 A-2 A-11" {
    try std.testing.expectEqual(@as(usize, 17408), CELL_BYTES);
    try std.testing.expectEqual(@as(usize, 64), BYTECODE_HEADER_BYTES);
    try std.testing.expectEqual(@as(usize, 4), MAX_HOP_DEPTH);
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(geometry.BytecodeHeader));
    try std.testing.expectEqual(@as(usize, 17408), @sizeOf(geometry.Cell));
}

test "string literal crossing the 64-byte boundary" {
    var c0: [64]u8 = undefined;
    var c1: [64]u8 = undefined;
    twoChunks(&c0, &c1);
    c0[62] = '"';
    c0[63] = 'a';
    c1[0] = 'b';
    c1[1] = 'c';
    c1[2] = '"';

    const r0 = scanChunk64(&c0, .{});
    try std.testing.expectEqual(@as(u1, 1), r0.carry.inside_quotes);
    try std.testing.expect((r0.unescaped_quotes & (@as(u64, 1) << 62)) != 0);
    try std.testing.expect((r0.inside_quotes & (@as(u64, 1) << 63)) != 0);

    const r1 = scanChunk64(&c1, r0.carry);
    try std.testing.expectEqual(@as(u1, 0), r1.carry.inside_quotes);
    try std.testing.expect((r1.inside_quotes & 1) != 0);
    try std.testing.expect((r1.inside_quotes & (@as(u64, 1) << 1)) != 0);
    try std.testing.expect((r1.unescaped_quotes & (@as(u64, 1) << 2)) != 0);
}

test "backslash on byte 63, quote on byte 64 is escaped not a delimiter" {
    var c0: [64]u8 = undefined;
    var c1: [64]u8 = undefined;
    twoChunks(&c0, &c1);
    c0[60] = '"';
    c0[61] = 'x';
    c0[62] = 'y';
    c0[63] = '\\';
    c1[0] = '"';
    c1[1] = 'z';
    c1[2] = '"';

    const r0 = scanChunk64(&c0, .{});
    try std.testing.expectEqual(@as(u1, 1), r0.carry.next_is_escaped);
    try std.testing.expectEqual(@as(u1, 1), r0.carry.inside_quotes);

    const r1 = scanChunk64(&c1, r0.carry);
    try std.testing.expect((r1.escaped & 1) != 0);
    try std.testing.expect((r1.unescaped_quotes & 1) == 0);
    try std.testing.expect((r1.unescaped_quotes & (@as(u64, 1) << 2)) != 0);
    try std.testing.expectEqual(@as(u1, 0), r1.carry.inside_quotes);
}

test "double-slash comment spanning two chunks" {
    var c0: [64]u8 = undefined;
    var c1: [64]u8 = undefined;
    twoChunks(&c0, &c1);
    c0[63] = '/';
    c1[0] = '/';
    c1[1] = ' ';
    c1[2] = 'c';
    c1[10] = '\n';
    c1[11] = 'x';

    const r0 = scanChunk64(&c0, .{});
    try std.testing.expectEqual(@as(u1, 1), r0.carry.prev_slash);

    const r1 = scanChunk64(&c1, r0.carry);
    try std.testing.expect((r1.double_slash_starts & 1) != 0);
    try std.testing.expect((r1.inside_comments & 1) != 0);
    try std.testing.expect((r1.inside_comments & (@as(u64, 1) << 2)) != 0);
    try std.testing.expect((r1.inside_comments & (@as(u64, 1) << 11)) == 0);
    try std.testing.expectEqual(@as(u1, 0), r1.carry.inside_comments);
}

test "double-backslash line string spanning two chunks" {
    var c0: [64]u8 = undefined;
    var c1: [64]u8 = undefined;
    twoChunks(&c0, &c1);
    c0[63] = '\\';
    c1[0] = '\\';
    c1[1] = 'L';
    c1[5] = '\n';

    const r0 = scanChunk64(&c0, .{});
    try std.testing.expectEqual(@as(u1, 1), r0.carry.prev_backslash);
    const r1 = scanChunk64(&c1, r0.carry);
    try std.testing.expect((r1.double_backslash_starts & 1) != 0);
    try std.testing.expect((r1.inside_line_strings & 1) != 0);
    try std.testing.expect((r1.inside_line_strings & (@as(u64, 1) << 1)) != 0);
    try std.testing.expectEqual(@as(u1, 0), r1.carry.inside_line_strings);
}

test "CRLF pair split across the chunk boundary is legal" {
    var c0: [64]u8 = undefined;
    var c1: [64]u8 = undefined;
    twoChunks(&c0, &c1);
    c0[63] = '\r';
    c1[0] = '\n';

    const r0 = scanChunk64(&c0, .{});
    try std.testing.expectEqual(@as(u1, 1), r0.carry.prev_cr);
    const r1 = scanChunk64(&c1, r0.carry);
    try std.testing.expectEqual(@as(u64, 0), r1.bad_carriage_returns);
}

test "CR without LF across the chunk boundary is a bad carriage return" {
    var c0: [64]u8 = undefined;
    var c1: [64]u8 = undefined;
    twoChunks(&c0, &c1);
    c0[63] = '\r';
    c1[0] = 'x';

    const r0 = scanChunk64(&c0, .{});
    const r1 = scanChunk64(&c1, r0.carry);
    try std.testing.expect((r1.bad_carriage_returns & 1) != 0);
}

test "vector and scalar classifiers agree on boundary fixtures" {
    var c0: [64]u8 = undefined;
    var c1: [64]u8 = undefined;
    twoChunks(&c0, &c1);
    c0[62] = '"';
    c0[63] = '\\';
    c1[0] = '"';
    c1[1] = '/';
    c1[2] = '/';
    c1[3] = '\r';
    c1[4] = '\n';

    const v0 = scanChunk64(&c0, .{});
    const s0 = scanChunk64Scalar(&c0, .{});
    try std.testing.expectEqual(s0.escaped, v0.escaped);
    try std.testing.expectEqual(s0.unescaped_quotes, v0.unescaped_quotes);
    try std.testing.expectEqual(s0.carry.toU8(), v0.carry.toU8());

    const v1 = scanChunk64(&c1, v0.carry);
    const s1 = scanChunk64Scalar(&c1, s0.carry);
    try std.testing.expectEqual(s1.escaped, v1.escaped);
    try std.testing.expectEqual(s1.inside_quotes, v1.inside_quotes);
    try std.testing.expectEqual(s1.carry.toU8(), v1.carry.toU8());
}

test "token maps into 64B BytecodeHeader" {
    const hdr = tokenToHeader(.string, "hello_world");
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(@TypeOf(hdr)));
    try std.testing.expectEqual(@as(u64, 2), hdr.opcode);
    try std.testing.expectEqualStrings("hello_world", std.mem.sliceTo(&hdr.subject_id, 0)[0..11]);
}

test "throughput: null vs scalar vs vector (ReleaseSafe/Fast gate)" {
    if (std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug")) return error.SkipZigTest;

    const n: usize = 16 * 1024 * 1024;
    const raw = try std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(64), n);
    defer std.testing.allocator.free(raw);
    fillPattern(raw);
    const src: []align(64) const u8 = @alignCast(raw);

    const t = try measureThroughput(src, 5);
    std.debug.print(
        "\nsimd_lexer throughput mode={s} null={d:.3} GB/s scalar={d:.3} GB/s vector={d:.3} GB/s\n",
        .{ @tagName(builtin.mode), t.null_gbps, t.scalar_gbps, t.vector_gbps },
    );
    try std.testing.expect(t.vector_gbps >= 1.0);
}
