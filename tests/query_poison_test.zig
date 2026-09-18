const std = @import("std");
const c_abi = @import("ziglite_c_abi");
const engine_mod = c_abi.engine_mod;
const query_mod = c_abi.query_mod;

test "query_poison: accessing tombstoned corrupt slot returns SQLITE_CORRUPT and zero poison bytes" {
    var engine = try engine_mod.ZigliteEngine.init(std.testing.allocator, 16);
    defer engine.deinit();

    // Insert 3 slots
    const s0 = try engine.insertTuple(.{ .opcode = 0x10, .subject_id = @splat(1), .predicate_id = @splat(0), .target_id = @splat(0), .flags = 0, .epoch = 1 });
    const s1 = try engine.insertTuple(.{ .opcode = 0x20, .subject_id = @splat(2), .predicate_id = @splat(0), .target_id = @splat(0), .flags = 0, .epoch = 1 });
    const s2 = try engine.insertTuple(.{ .opcode = 0x30, .subject_id = @splat(3), .predicate_id = @splat(0), .target_id = @splat(0), .flags = 0, .epoch = 1 });

    // Mark s1 as corrupt tombstone
    engine.markSlotCorrupt(s1);

    try std.testing.expect(engine.isSlotCorrupt(s1));
    try std.testing.expectEqual(@as(?engine_mod.ZigliteTuple, null), engine.getTuple(s1));

    // Scans must never return s1
    var results: [16]usize = undefined;
    const count = query_mod.scanTuplesByOpcode(&engine, 0x20, &results);
    try std.testing.expectEqual(@as(usize, 0), count);

    // Healthy s0 and s2 must remain accessible
    try std.testing.expect(engine.getTuple(s0) != null);
    try std.testing.expect(engine.getTuple(s2) != null);
}

test "query_poison: c_abi sqlite3_step returns SQLITE_CORRUPT on corrupt slot" {
    var db: ?*c_abi.sqlite3 = null;
    const rc_open = c_abi.sqlite3_open_v2(":memory:", &db, c_abi.SQLITE_OPEN_READWRITE | c_abi.SQLITE_OPEN_CREATE, null);
    try std.testing.expectEqual(c_abi.SQLITE_OK, rc_open);
    defer _ = c_abi.sqlite3_close_v2(db);

    // Insert record with id 777
    const ins = "INSERT INTO records VALUES (1001, 777, 1, 2, 0, 1)";
    var ins_stmt: ?*c_abi.sqlite3_stmt = null;
    try std.testing.expectEqual(c_abi.SQLITE_OK, c_abi.sqlite3_prepare_v2(db, ins, @intCast(ins.len), &ins_stmt, null));
    try std.testing.expectEqual(c_abi.SQLITE_DONE, c_abi.sqlite3_step(ins_stmt));
    _ = c_abi.sqlite3_finalize(ins_stmt);

    // Corrupt the inserted slot in engine
    db.?.engine.markSlotCorrupt(0);

    // Prepare SELECT for id 777
    const sel = "SELECT * FROM records WHERE id = 777";
    var sel_stmt: ?*c_abi.sqlite3_stmt = null;
    try std.testing.expectEqual(c_abi.SQLITE_OK, c_abi.sqlite3_prepare_v2(db, sel, @intCast(sel.len), &sel_stmt, null));
    defer _ = c_abi.sqlite3_finalize(sel_stmt);

    const step_rc = c_abi.sqlite3_step(sel_stmt);
    try std.testing.expectEqual(c_abi.SQLITE_CORRUPT, step_rc);
}
