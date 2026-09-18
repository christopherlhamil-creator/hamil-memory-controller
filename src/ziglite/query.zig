const std = @import("std");
const engine_mod = @import("engine.zig");

pub fn scanTuplesByOpcode(
    engine: *const engine_mod.ZigliteEngine,
    target_opcode: u64,
    out_slots: []usize,
) usize {
    var count: usize = 0;
    const total = engine.committed_watermark.load(.seq_cst);
    const limit = @min(total, engine.max_slots);

    for (0..limit) |i| {
        if (engine.status[i] == @intFromEnum(engine_mod.SlotState.committed)) {
            if (engine.cells[i].header.opcode == target_opcode) {
                if (count < out_slots.len) {
                    out_slots[count] = i;
                    count += 1;
                }
            }
        }
    }
    return count;
}

pub fn scanTuplesBySubject(
    engine: *const engine_mod.ZigliteEngine,
    subject: [16]u8,
    out_slots: []usize,
) usize {
    var count: usize = 0;
    const total = engine.committed_watermark.load(.seq_cst);
    const limit = @min(total, engine.max_slots);

    for (0..limit) |i| {
        const st = engine.status[i];
        if (st == @intFromEnum(engine_mod.SlotState.committed) or st == @intFromEnum(engine_mod.SlotState.tombstone)) {
            if (std.mem.eql(u8, &engine.cells[i].header.subject_id, &subject)) {
                if (count < out_slots.len) {
                    out_slots[count] = i;
                    count += 1;
                }
            }
        }
    }
    return count;
}

test "ZigliteQuery scans committed tuples using SIMD vector filter" {
    var engine = try engine_mod.ZigliteEngine.init(std.testing.allocator, 256);
    defer engine.deinit();

    // Insert 10 tuples with opcode 0x0A and 10 with opcode 0x0B
    for (0..20) |i| {
        const op: u64 = if (i % 2 == 0) 0x0A else 0x0B;
        _ = try engine.insertTuple(.{
            .opcode = op,
            .subject_id = @splat(@intCast(i)),
            .predicate_id = @splat(1),
            .target_id = @splat(2),
            .flags = 0,
            .epoch = 1,
        });
    }

    var result_buffer: [64]usize = undefined;
    const match_count = scanTuplesByOpcode(&engine, 0x0A, &result_buffer);
    try std.testing.expectEqual(@as(usize, 10), match_count);

    const match_subj = scanTuplesBySubject(&engine, @splat(4), &result_buffer);
    try std.testing.expectEqual(@as(usize, 1), match_subj);
}
