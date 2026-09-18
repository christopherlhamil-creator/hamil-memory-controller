const std = @import("std");
const durability = @import("ziglite_durability");

test "durability: mid-file corruption marks tombstone without truncating subsequent valid slots" {
    var buffer: [durability.RECORD_BYTES * 4]u8 = @splat(0);

    // Slot 0: Superblock / Metapage
    std.mem.writeInt(u64, buffer[durability.PREFETCH_LABEL_BYTES..][0..8], 0x1001, .little);
    durability.sealRecord(buffer[0..durability.RECORD_BYTES]);

    // Slot 1: Valid Record
    std.mem.writeInt(u64, buffer[durability.RECORD_BYTES + durability.PREFETCH_LABEL_BYTES..][0..8], 0x1001, .little);
    durability.sealRecord(buffer[durability.RECORD_BYTES .. durability.RECORD_BYTES * 2]);

    // Slot 2: Corrupted record (bitflip in payload)
    std.mem.writeInt(u64, buffer[durability.RECORD_BYTES * 2 + durability.PREFETCH_LABEL_BYTES..][0..8], 0x1001, .little);
    durability.sealRecord(buffer[durability.RECORD_BYTES * 2 .. durability.RECORD_BYTES * 3]);
    buffer[durability.RECORD_BYTES * 2 + 5000] ^= 0xFF; // Mutate payload

    // Slot 3: Valid Record
    std.mem.writeInt(u64, buffer[durability.RECORD_BYTES * 3 + durability.PREFETCH_LABEL_BYTES..][0..8], 0x1001, .little);
    durability.sealRecord(buffer[durability.RECORD_BYTES * 3 .. durability.RECORD_BYTES * 4]);

    var bitmap: [1024]bool = @splat(false);
    const res = durability.scanBufferProtocolAware(&buffer, 4, &bitmap);

    try std.testing.expectEqual(@as(usize, 3), res.valid_records);
    try std.testing.expectEqual(@as(usize, 1), res.corrupt_records);
    try std.testing.expectEqual(false, bitmap[1]);
    try std.testing.expectEqual(true, bitmap[2]); // Slot 2 tombstoned
    try std.testing.expectEqual(false, bitmap[3]); // Slot 3 healthy and retained!
}

test "durability: tail torn write truncates cleanly to last valid sector boundary" {
    var buffer: [durability.RECORD_BYTES * 2 + 8192]u8 = @splat(0);

    // Slot 0: Valid
    std.mem.writeInt(u64, buffer[durability.PREFETCH_LABEL_BYTES..][0..8], 0x1001, .little);
    durability.sealRecord(buffer[0..durability.RECORD_BYTES]);

    // Slot 1: Valid
    std.mem.writeInt(u64, buffer[durability.RECORD_BYTES + durability.PREFETCH_LABEL_BYTES..][0..8], 0x1001, .little);
    durability.sealRecord(buffer[durability.RECORD_BYTES .. durability.RECORD_BYTES * 2]);

    // Trailing 8192 bytes (incomplete slot 2)
    @memset(buffer[durability.RECORD_BYTES * 2 ..], 0xEE);

    var bitmap: [1024]bool = @splat(false);
    const res = durability.scanBufferProtocolAware(&buffer, 2, &bitmap);

    try std.testing.expectEqual(@as(usize, 2), res.valid_records);
    try std.testing.expect(res.tail_torn_detected);
    try std.testing.expectEqual(@as(usize, durability.RECORD_BYTES * 2), res.clean_byte_boundary);
}
