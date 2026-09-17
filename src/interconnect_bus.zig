//! Interconnection Progress Bus — fleet.interconnect.progress.v1
//!
//! Portable (no AVX-512). Coffee Lake and Zen 4 share this source.
//! Hot path is O_APPEND of one JSONL line (< PIPE_BUF) plus SHA-256 of
//! 64B BytecodeHeader / 17,408B Cell. SQLite is not on this path.

const std = @import("std");
const geometry = @import("geometry.zig");

pub const SCHEMA = "fleet.interconnect.progress.v1";
pub const CELL_BYTES = geometry.CELL_BYTES;
pub const HEADER_BYTES = geometry.BYTECODE_HEADER_BYTES;

comptime {
    std.debug.assert(CELL_BYTES == 17408);
    std.debug.assert(HEADER_BYTES == 64);
}

pub const HEADER_SHA256_HEX = "4c227c463cbed282ef8c6569d0136874a40b59c6661aadccb80a9c6444493c04";
pub const CELL_SHA256_HEX = "063198bac77798c6b1c79020e3946c2088e8c6354d575aed10c422eeb5d745f8";

pub const ProgressEvent = struct {
    timestamp: i64,
    seat: []const u8,
    host: []const u8,
    pid: u32,
    model: []const u8,
    phase: []const u8,
    task: []const u8,
    status: []const u8,
    commit: []const u8,
    metrics: []const u8,
};

fn pad16(src: []const u8) [16]u8 {
    var out: [16]u8 = @splat(0);
    const n = @min(src.len, 16);
    @memcpy(out[0..n], src[0..n]);
    return out;
}

/// Canonical A-2 header: little-endian u64 opcode + 16+16+16 ids + u64 provenance.
pub fn packFixtureHeader() [HEADER_BYTES]u8 {
    var out: [HEADER_BYTES]u8 = @splat(0);
    std.mem.writeInt(u64, out[0..8], 1001, .little);
    const subj = pad16("aherron");
    const pred = pad16("assert_relation");
    const tgt = pad16("oysterman");
    @memcpy(out[8..24], &subj);
    @memcpy(out[24..40], &pred);
    @memcpy(out[40..56], &tgt);
    std.mem.writeInt(u64, out[56..64], 1, .little);
    return out;
}

pub fn packFixtureCell() [CELL_BYTES]u8 {
    var cell: [CELL_BYTES]u8 = @splat(0);
    const hdr = packFixtureHeader();
    @memcpy(cell[0..HEADER_BYTES], &hdr);
    return cell;
}

pub fn sha256Hex(bytes: []const u8, out: *[64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

pub fn headerSha256Hex(out: *[64]u8) void {
    const hdr = packFixtureHeader();
    sha256Hex(&hdr, out);
}

pub fn cellSha256Hex(out: *[64]u8) void {
    const cell = packFixtureCell();
    sha256Hex(&cell, out);
}

/// One atomic O_APPEND of a JSONL line. Line must be < 4096 B (PIPE_BUF).
pub fn appendProgress(path: []const u8, event: ProgressEvent) !void {
    var buf: [2048]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{{\"schema\":\"{s}\",\"timestamp\":{d},\"seat\":\"{s}\",\"host\":\"{s}\",\"pid\":{d},\"model\":\"{s}\",\"phase\":\"{s}\",\"task\":\"{s}\",\"status\":\"{s}\",\"commit\":\"{s}\",\"metrics\":{s}}}\n", .{
        SCHEMA,
        event.timestamp,
        event.seat,
        event.host,
        event.pid,
        event.model,
        event.phase,
        event.task,
        event.status,
        event.commit,
        event.metrics,
    });
    if (line.len >= 4096) return error.LineExceedsPipeBuf;

    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
        0o644,
    );
    defer _ = std.os.linux.close(fd);
    const n = std.os.linux.write(fd, line.ptr, line.len);
    if (n != line.len) return error.ShortWrite;
}

test "A-2 fixture header is 64B and SHA-256 is host-independent" {
    const hdr = packFixtureHeader();
    try std.testing.expectEqual(@as(usize, 64), hdr.len);
    var hex: [64]u8 = undefined;
    headerSha256Hex(&hex);
    try std.testing.expectEqualStrings(HEADER_SHA256_HEX, &hex);
}

test "A-1 fixture cell is 17408B and SHA-256 is host-independent" {
    const cell = packFixtureCell();
    try std.testing.expectEqual(@as(usize, 17408), cell.len);
    try std.testing.expectEqual(@as(u8, 0), cell[64]);
    var hex: [64]u8 = undefined;
    cellSha256Hex(&hex);
    try std.testing.expectEqualStrings(CELL_SHA256_HEX, &hex);
}

test "appendProgress is O_APPEND JSONL with schema v1" {
    const path = "/tmp/tot_hybrid_interconnect_progress_test.jsonl";
    const zpath = try std.posix.toPosixPath(path);
    _ = std.os.linux.unlinkat(std.posix.AT.FDCWD, &zpath, 0);
    defer _ = std.os.linux.unlinkat(std.posix.AT.FDCWD, &zpath, 0);

    try appendProgress(path, .{
        .timestamp = 1,
        .seat = "council-grok",
        .host = "pop-os",
        .pid = 1,
        .model = "grok",
        .phase = "test",
        .task = "append",
        .status = "ok",
        .commit = "deadbeef",
        .metrics = "{\"ns\":1}",
    });

    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.os.linux.close(fd);
    var tmp_buf: [4096]u8 = undefined;
    const n = try std.posix.read(fd, &tmp_buf);
    const body = tmp_buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, body, SCHEMA) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "council-grok") != null);
    try std.testing.expect(std.mem.endsWith(u8, body, "\n"));
}
