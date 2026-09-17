//! Bare-Metal Pre-Permuted Zero-Offset Weight Codec.
//!
//! Features:
//!   - Signed nibble lattice: [-8, +7]
//!   - Zero-offset: b = 0.0 (no runtime offset subtraction)
//!   - Linear scale factoring: sum(q * s * x) = s * sum(q * x)
//!   - Sector alignment: 16 KiB blocks (32,768 weights per tile)

const std = @import("std");
const geometry = @import("geometry.zig");
const weight_archive = @import("weight_archive.zig");

pub const TILE_CODE_BYTES: usize = 16384;
pub const WEIGHTS_PER_TILE: usize = 32768;
pub const COLS_PER_ROW: usize = 2048;
pub const ROWS_PER_TILE: usize = 16;

/// Computes GEMV for a zero-offset signed 4-bit tile (16 rows x 2048 cols = 32,768 weights).
/// Factors the scale out of the inner loop: dot = scale * sum(x * q).
pub fn gemvTileBareMetal(
    rec: *const geometry.Record,
    x: []const f32,
    y: []f32,
    row_base: usize,
) void {
    const payload = &rec.cell.semantic_payload;
    const scale: f32 = @bitCast(std.mem.readInt(u32, payload[32..36], .little));

    const coded: [*]const u8 = @ptrCast(&rec.cell.fingerprints);

    for (0..ROWS_PER_TILE) |r| {
        const row_bytes = coded[r * 1024 .. (r + 1) * 1024];
        var unscaled_dot: f32 = 0.0;

        for (0..1024) |j| {
            const b = row_bytes[j];
            // Sign extend 4-bit unsigned to signed i8
            const q0_u4: u8 = b & 0x0F;
            const q1_u4: u8 = (b >> 4) & 0x0F;

            const q0_i8: i8 = @as(i8, @bitCast(q0_u4 << 4)) >> 4;
            const q1_i8: i8 = @as(i8, @bitCast(q1_u4 << 4)) >> 4;

            const q0_f: f32 = @floatFromInt(q0_i8);
            const q1_f: f32 = @floatFromInt(q1_i8);

            unscaled_dot += x[2 * j] * q0_f + x[2 * j + 1] * q1_f;
        }

        // Multiply scale once per row
        y[row_base + r] += unscaled_dot * scale;
    }
}

test "baremetal codec zero-offset signed nibbles" {
    var mock_record: geometry.Record = undefined;
    @memset(std.mem.asBytes(&mock_record), 0);

    // Set scale = 0.5, bias = 0.0 in semantic payload
    const payload = &mock_record.cell.semantic_payload;
    const scale_bytes: [4]u8 = @bitCast(@as(f32, 0.5));
    @memcpy(payload[32..36], &scale_bytes);

    const coded: [*]u8 = @ptrCast(&mock_record.cell.fingerprints);
    // Byte with q0 = -8 (0x8), q1 = +7 (0x7) -> byte = 0x78
    // Row 0 filled with 0x78
    for (0..1024) |j| {
        coded[j] = 0x78;
    }

    var in_vec: [2048]f32 = @splat(1.0);
    var out_vec: [16]f32 = @splat(0.0);

    gemvTileBareMetal(&mock_record, &in_vec, &out_vec, 0);

    // Row 0 calculation:
    // 1024 pairs of (q0 = -8, q1 = +7)
    // sum(q * x) = 1024 * (-8 * 1.0 + 7 * 1.0) = 1024 * (-1.0) = -1024.0
    // dot = scale * sum = 0.5 * (-1024.0) = -512.0
    try std.testing.expectApproxEqAbs(@as(f32, -512.0), out_vec[0], 1e-4);
}
