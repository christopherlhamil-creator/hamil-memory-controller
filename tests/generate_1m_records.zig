//! 1,000,000-record A-2 header synthesizer (Seat 1).
//!
//! Writes three header rings (64 B × N, Invariant A-2 packets) for the
//! 1M SIMD scan bench. This is NOT a 17,408 B cell bank: the query
//! frontier is contiguous BytecodeHeader packets, not full cells.
//!
//!   zig run tests/generate_1m_records.zig
//!
//! Portable: no AVX-512 pin. SQLite load is scripts/generate_1m_spokes.py.

const std = @import("std");

const HEADER_BYTES: usize = 64;
const OCR_COUNT: usize = 400_000;
const QMS_COUNT: usize = 300_000;
const RESEARCH_COUNT: usize = 300_000;

fn pad16(src: []const u8) [16]u8 {
    var out: [16]u8 = @splat(0);
    const n = @min(src.len, 16);
    @memcpy(out[0..n], src[0..n]);
    return out;
}

fn packHeader(out: *[HEADER_BYTES]u8, opcode: u64, subject: []const u8, pred: []const u8, target: []const u8, provenance: u64) void {
    std.mem.writeInt(u64, out[0..8], opcode, .little);
    const s = pad16(subject);
    const p = pad16(pred);
    const t = pad16(target);
    @memcpy(out[8..24], &s);
    @memcpy(out[24..40], &p);
    @memcpy(out[40..56], &t);
    std.mem.writeInt(u64, out[56..64], provenance, .little);
}

fn writeSpoke(path: []const u8, spoke: []const u8, count: usize, spoke_tag: u64) !void {
    const buf = try std.heap.page_allocator.alloc(u8, count * HEADER_BYTES);
    defer std.heap.page_allocator.free(buf);

    var subj_buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const n = std.fmt.bufPrint(&subj_buf, "{s}_{d:0>12}", .{ spoke, i }) catch unreachable;
        const provenance: u64 = (spoke_tag << 32) | i;
        packHeader(
            buf[i * HEADER_BYTES ..][0..HEADER_BYTES],
            1001,
            n,
            "spoke_route",
            "ring_queue",
            provenance,
        );
    }

    const zpath = try std.posix.toPosixPath(path);
    _ = std.os.linux.unlinkat(std.posix.AT.FDCWD, &zpath, 0);
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true },
        0o644,
    );
    defer _ = std.os.linux.close(fd);
    const wrote = std.os.linux.write(fd, buf.ptr, buf.len);
    if (wrote != buf.len) return error.ShortWrite;
}

pub fn main() !void {
    try writeSpoke("run/spoke_queues/1m_ocr.cells", "ocr", OCR_COUNT, 1);
    try writeSpoke("run/spoke_queues/1m_qms.cells", "qms", QMS_COUNT, 2);
    try writeSpoke("run/spoke_queues/1m_research.cells", "res", RESEARCH_COUNT, 3);
    const msg = "wrote 1000000 A-2 headers (ocr 400000 qms 300000 research 300000)\n";
    _ = std.os.linux.write(1, msg.ptr, msg.len);
}
