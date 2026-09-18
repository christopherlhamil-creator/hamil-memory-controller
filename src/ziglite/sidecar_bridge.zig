const std = @import("std");
const engine_mod = @import("engine.zig");
const query_mod = @import("query.zig");

pub const ZigliteHandle = *engine_mod.ZigliteEngine;

pub fn ziglite_open(max_slots: usize) !ZigliteHandle {
    const allocator = std.heap.page_allocator;
    const engine = try allocator.create(engine_mod.ZigliteEngine);
    engine.* = try engine_mod.ZigliteEngine.init(allocator, max_slots);
    return engine;
}

pub fn ziglite_close(handle: ZigliteHandle) void {
    const allocator = std.heap.page_allocator;
    handle.deinit();
    allocator.destroy(handle);
}

pub fn ziglite_insert(
    handle: ZigliteHandle,
    opcode: u64,
    subject: []const u8,
    predicate: []const u8,
    target: []const u8,
) i32 {
    var tuple = engine_mod.ZigliteTuple{
        .opcode = opcode,
        .subject_id = @splat(0),
        .predicate_id = @splat(0),
        .target_id = @splat(0),
        .flags = 0,
        .epoch = 1,
    };
    @memcpy(tuple.subject_id[0..@min(subject.len, 16)], subject[0..@min(subject.len, 16)]);
    @memcpy(tuple.predicate_id[0..@min(predicate.len, 16)], predicate[0..@min(predicate.len, 16)]);
    @memcpy(tuple.target_id[0..@min(target.len, 16)], target[0..@min(target.len, 16)]);

    _ = handle.insertTuple(tuple) catch return -1;
    return 0; // SQLITE_OK
}

pub fn ziglite_query_opcode(
    handle: ZigliteHandle,
    opcode: u64,
    out_slots: []usize,
) usize {
    return query_mod.scanTuplesByOpcode(handle, opcode, out_slots);
}

test "SidecarBridge handles open, insert, and query seamlessly" {
    const handle = try ziglite_open(64);
    defer ziglite_close(handle);

    const rc = ziglite_insert(handle, 0x42, "subj_1", "pred_1", "targ_1");
    try std.testing.expectEqual(@as(i32, 0), rc);

    var out_buf: [16]usize = undefined;
    const found = ziglite_query_opcode(handle, 0x42, &out_buf);
    try std.testing.expectEqual(@as(usize, 1), found);
}
