const std = @import("std");

pub const CELL_BYTES: usize = 17408;
pub const BYTECODE_HEADER_BYTES: usize = 64;
pub const RECORD_BYTES: usize = 20480;
pub const PREFETCH_LABEL_BYTES: usize = 3072;

comptime {
    std.debug.assert(CELL_BYTES == 272 * 64);
    std.debug.assert(BYTECODE_HEADER_BYTES == 64);
    std.debug.assert(RECORD_BYTES == 5 * 4096);
    std.debug.assert(PREFETCH_LABEL_BYTES == RECORD_BYTES - CELL_BYTES);
}

pub const SlotState = enum(u8) {
    free = 0,
    leased = 1,
    committed = 2,
    tombstone = 3,
};

pub const ZigliteTuple = extern struct {
    opcode: u64 align(64),
    subject_id: [16]u8,
    predicate_id: [16]u8,
    target_id: [16]u8,
    flags: u32,
    epoch: u32,

    comptime {
        std.debug.assert(@sizeOf(ZigliteTuple) == 64);
        std.debug.assert(@alignOf(ZigliteTuple) == 64);
    }
};

pub const RawCell = extern struct {
    header: ZigliteTuple,
    payload: [CELL_BYTES - BYTECODE_HEADER_BYTES]u8,

    comptime {
        std.debug.assert(@sizeOf(RawCell) == CELL_BYTES);
    }
};

pub const ZigliteEngine = struct {
    allocator: std.mem.Allocator,
    cells: []align(64) RawCell,
    status: []u8,
    max_slots: usize,
    next_slot: std.atomic.Value(usize),
    committed_watermark: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, max_slots: usize) !ZigliteEngine {
        const cells = try allocator.alignedAlloc(RawCell, std.mem.Alignment.@"64", max_slots);
        errdefer allocator.free(cells);
        // Note: Full slab memset omitted for instant startup; slot validity is strictly governed by status array

        const status = try allocator.alloc(u8, max_slots);
        errdefer allocator.free(status);
        @memset(status, @intFromEnum(SlotState.free));

        return ZigliteEngine{
            .allocator = allocator,
            .cells = cells,
            .status = status,
            .max_slots = max_slots,
            .next_slot = std.atomic.Value(usize).init(0),
            .committed_watermark = std.atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *ZigliteEngine) void {
        self.allocator.free(self.status);
        self.allocator.free(self.cells);
    }

    pub fn advanceWatermark(self: *ZigliteEngine) void {
        while (true) {
            const wm = self.committed_watermark.load(.monotonic);
            if (wm >= self.max_slots) break;
            if (self.status[wm] == @intFromEnum(SlotState.committed)) {
                _ = self.committed_watermark.cmpxchgWeak(wm, wm + 1, .seq_cst, .monotonic);
            } else {
                break;
            }
        }
    }

    pub fn insertTuple(self: *ZigliteEngine, tuple: ZigliteTuple) !usize {
        while (true) {
            const current = self.next_slot.load(.monotonic);
            if (current >= self.max_slots) return error.TableFull;
            if (self.next_slot.cmpxchgWeak(current, current + 1, .seq_cst, .monotonic) == null) {
                self.status[current] = @intFromEnum(SlotState.leased);
                self.cells[current].header = tuple;
                self.status[current] = @intFromEnum(SlotState.committed);
                self.advanceWatermark();
                return current;
            }
        }
    }

    pub fn getStatus(self: *const ZigliteEngine, slot: usize) SlotState {
        if (slot >= self.max_slots) return .free;
        return @enumFromInt(self.status[slot]);
    }

    pub fn getTuple(self: *const ZigliteEngine, slot: usize) ?ZigliteTuple {
        if (slot >= self.max_slots) return null;
        if (self.status[slot] != @intFromEnum(SlotState.committed)) return null;
        return self.cells[slot].header;
    }

    pub fn countCommitted(self: *const ZigliteEngine) usize {
        var count: usize = 0;
        const current = self.next_slot.load(.monotonic);
        const limit = @min(current, self.max_slots);
        for (0..limit) |i| {
            if (self.status[i] == @intFromEnum(SlotState.committed)) {
                count += 1;
            }
        }
        return count;
    }

    pub fn deleteTuple(self: *ZigliteEngine, slot: usize) bool {
        if (slot >= self.max_slots) return false;
        if (self.status[slot] == @intFromEnum(SlotState.committed)) {
            self.status[slot] = @intFromEnum(SlotState.tombstone);
            return true;
        }
        return false;
    }

    pub fn markSlotCorrupt(self: *ZigliteEngine, slot: usize) void {
        if (slot < self.max_slots) {
            self.status[slot] = @intFromEnum(SlotState.tombstone);
        }
    }

    pub fn isSlotCorrupt(self: *const ZigliteEngine, slot: usize) bool {
        if (slot >= self.max_slots) return false;
        return self.status[slot] == @intFromEnum(SlotState.tombstone);
    }
};

test "ZigliteTuple enforces Invariant A-1 (17,408B) and A-2 (64B Header)" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(ZigliteTuple));
    try std.testing.expectEqual(@as(usize, 64), @alignOf(ZigliteTuple));
    try std.testing.expectEqual(@as(usize, 17408), CELL_BYTES);
    try std.testing.expectEqual(@as(usize, 20480), RECORD_BYTES);
}

test "ZigliteEngine initializes and commits tuples lock-free" {
    var engine = try ZigliteEngine.init(std.testing.allocator, 128);
    defer engine.deinit();

    const tuple = ZigliteTuple{
        .opcode = 0x01,
        .subject_id = @splat(1),
        .predicate_id = @splat(2),
        .target_id = @splat(3),
        .flags = 0,
        .epoch = 1,
    };

    const slot = try engine.insertTuple(tuple);
    try std.testing.expect(slot < 128);
    try std.testing.expectEqual(SlotState.committed, engine.getStatus(slot));
    const retrieved = engine.getTuple(slot);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u64, 0x01), retrieved.?.opcode);
}
