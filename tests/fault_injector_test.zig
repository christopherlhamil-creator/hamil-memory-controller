const std = @import("std");
const fault_injector = @import("ziglite_fault_injector");

test "fault_injector: passthrough writes full buffer when disabled" {
    var dev = fault_injector.StorageDevice.initMemory(std.testing.allocator);
    defer dev.deinit();

    var buf: [20480]u8 = @splat(0xAA);
    const written = try dev.pwrite(&buf, 0);
    try std.testing.expectEqual(@as(usize, 20480), written);

    var read_buf: [20480]u8 = @splat(0);
    const read_bytes = try dev.pread(&read_buf, 0);
    try std.testing.expectEqual(@as(usize, 20480), read_bytes);
    try std.testing.expectEqualSlices(u8, &buf, &read_buf);
}

test "fault_injector: injects torn write on configured slot" {
    var dev = fault_injector.StorageDevice.initMemory(std.testing.allocator);
    defer dev.deinit();

    dev.config = .{
        .seed = 42,
        .probability = 1.0,
        .fault_type = .torn_write,
        .torn_write_bytes = 4096,
        .target_slot_min = 0,
        .target_slot_max = 10,
    };

    var buf: [20480]u8 = @splat(0xBB);
    const written = try dev.pwrite(&buf, 0);
    try std.testing.expectEqual(@as(usize, 4096), written);
}

test "fault_injector: injects bitflip into payload" {
    var dev = fault_injector.StorageDevice.initMemory(std.testing.allocator);
    defer dev.deinit();

    dev.config = .{
        .seed = 12345,
        .probability = 1.0,
        .fault_type = .bitflip_payload,
        .target_slot_min = 0,
        .target_slot_max = 10,
    };

    var buf: [20480]u8 = @splat(0xCC);
    _ = try dev.pwrite(&buf, 0);

    var read_buf: [20480]u8 = @splat(0);
    _ = try dev.pread(&read_buf, 0);
    // At least one bit must differ
    try std.testing.expect(!std.mem.eql(u8, &buf, &read_buf));
}

test "fault_injector: injects latent sector EIO" {
    var dev = fault_injector.StorageDevice.initMemory(std.testing.allocator);
    defer dev.deinit();

    dev.config = .{
        .seed = 999,
        .probability = 1.0,
        .fault_type = .latent_sector_eio,
        .target_slot_min = 0,
        .target_slot_max = 10,
    };

    var buf: [20480]u8 = @splat(0xDD);
    try std.testing.expectError(error.InputOutput, dev.pwrite(&buf, 0));
}
