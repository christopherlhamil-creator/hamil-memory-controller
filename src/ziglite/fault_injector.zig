//! In-Flight Storage Fault Injector & Syscall Interception Layer for ZIGlite
//!
//! Subsystem: tot_hybrid/src/ziglite/fault_injector.zig
//! Toolchain: Zig 0.17
//!
//! Intercepts raw POSIX storage calls (pwrite64, pread64, fdatasync) to simulate
//! realistic NVMe/SSD hardware failure modes: torn writes, bit-flips, latent sector EIO,
//! lost writes, and misdirected block writes under concurrent multi-threaded stress.

const std = @import("std");
const posix = std.posix;

pub const RECORD_BYTES: usize = 20480;
pub const SECTOR_BYTES: usize = 4096;
pub const ZECKENDORF_SEAL_BYTES: usize = 16;
pub const PREFETCH_LABEL_BYTES: usize = 3072;
pub const BYTECODE_HEADER_BYTES: usize = 64;

pub const FaultType = enum(u8) {
    none = 0,
    torn_write = 1,
    bitflip_payload = 2,
    bitflip_seal = 3,
    bitflip_header = 4,
    latent_sector_eio = 5,
    lost_write = 6,
    misdirected_write = 7,
    fdatasync_failure = 8,
};

pub const FaultConfig = struct {
    seed: u64 = 0,
    probability: f32 = 0.0,
    fault_type: FaultType = .none,
    torn_write_bytes: usize = 4096,
    target_slot_min: u32 = 0,
    target_slot_max: u32 = std.math.maxInt(u32),
};

pub const StorageDevice = struct {
    fd: ?posix.fd_t = null,
    allocator: ?std.mem.Allocator = null,
    mem_backing: ?std.ArrayListUnmanaged(u8) = null,
    config: ?FaultConfig = null,
    prng: std.Random.DefaultPrng,
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn acquireLock(self: *StorageDevice) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn releaseLock(self: *StorageDevice) void {
        self.lock.store(false, .release);
    }

    pub fn initFd(fd: posix.fd_t, config: ?FaultConfig) StorageDevice {
        const seed = if (config) |c| c.seed else 0;
        return .{
            .fd = fd,
            .allocator = null,
            .mem_backing = null,
            .config = config,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn initMemory(allocator: std.mem.Allocator) StorageDevice {
        return .{
            .fd = null,
            .allocator = allocator,
            .mem_backing = .empty,
            .config = null,
            .prng = std.Random.DefaultPrng.init(0),
        };
    }

    pub fn deinit(self: *StorageDevice) void {
        if (self.mem_backing) |*mem| {
            if (self.allocator) |alloc| {
                mem.deinit(alloc);
            }
        }
    }

    fn shouldInject(self: *StorageDevice, slot_idx: u32) bool {
        if (self.config) |cfg| {
            if (cfg.fault_type == .none) return false;
            if (slot_idx < cfg.target_slot_min or slot_idx > cfg.target_slot_max) return false;
            if (cfg.probability >= 1.0) return true;
            if (cfg.probability <= 0.0) return false;
            return self.prng.random().float(f32) < cfg.probability;
        }
        return false;
    }

    pub fn pwrite(self: *StorageDevice, buf: []const u8, offset: u64) !usize {
        self.acquireLock();
        defer self.releaseLock();

        const slot_idx: u32 = @intCast(offset / RECORD_BYTES);
        var write_slice = buf;
        var mutated_buf: [RECORD_BYTES]u8 = undefined;

        if (self.shouldInject(slot_idx)) {
            const cfg = self.config.?;
            switch (cfg.fault_type) {
                .torn_write => {
                    const cut = @min(cfg.torn_write_bytes, buf.len);
                    write_slice = buf[0..cut];
                },
                .latent_sector_eio => return error.InputOutput,
                .lost_write => return buf.len, // Silently drop write
                .fdatasync_failure => {},
                .bitflip_payload, .bitflip_seal, .bitflip_header => {
                    const len = @min(buf.len, RECORD_BYTES);
                    @memcpy(mutated_buf[0..len], buf[0..len]);
                    const offset_range: struct { min: usize, max: usize } = switch (cfg.fault_type) {
                        .bitflip_seal => .{ .min = 0, .max = ZECKENDORF_SEAL_BYTES },
                        .bitflip_header => .{ .min = PREFETCH_LABEL_BYTES, .max = PREFETCH_LABEL_BYTES + BYTECODE_HEADER_BYTES },
                        .bitflip_payload => .{ .min = PREFETCH_LABEL_BYTES + BYTECODE_HEADER_BYTES, .max = len },
                        else => .{ .min = 0, .max = len },
                    };
                    const max_bound = @min(offset_range.max - 1, len - 1);
                    if (max_bound >= offset_range.min) {
                        const target_byte = self.prng.random().intRangeAtMost(usize, offset_range.min, max_bound);
                        const bit_mask = @as(u8, 1) << @intCast(self.prng.random().intRangeAtMost(u3, 0, 7));
                        mutated_buf[target_byte] ^= bit_mask;
                        write_slice = mutated_buf[0..len];
                    }
                },
                .misdirected_write => {
                    return self.rawWrite(write_slice, offset + RECORD_BYTES);
                },
                .none => {},
            }
        }

        return self.rawWrite(write_slice, offset);
    }

    fn rawWrite(self: *StorageDevice, slice: []const u8, offset: u64) !usize {
        if (self.fd) |fd| {
            var total: usize = 0;
            while (total < slice.len) {
                const rc = std.os.linux.pwrite(fd, slice.ptr + total, slice.len - total, @intCast(offset + total));
                const s_rc: isize = @bitCast(rc);
                if (s_rc < 0) return error.InputOutput;
                if (s_rc == 0) return error.DiskFull;
                total += @intCast(s_rc);
            }
            return total;
        } else if (self.mem_backing) |*mem| {
            const end_pos = offset + slice.len;
            if (end_pos > mem.items.len) {
                try mem.resize(self.allocator.?, @intCast(end_pos));
            }
            @memcpy(mem.items[@intCast(offset)..@intCast(end_pos)], slice);
            return slice.len;
        }
        return error.BadFileDescriptor;
    }

    pub fn pread(self: *StorageDevice, buf: []u8, offset: u64) !usize {
        self.acquireLock();
        defer self.releaseLock();

        const slot_idx: u32 = @intCast(offset / RECORD_BYTES);
        if (self.shouldInject(slot_idx) and self.config.?.fault_type == .latent_sector_eio) {
            return error.InputOutput;
        }

        if (self.fd) |fd| {
            var total: usize = 0;
            while (total < buf.len) {
                const rc = std.os.linux.pread(fd, buf.ptr + total, buf.len - total, @intCast(offset + total));
                const s_rc: isize = @bitCast(rc);
                if (s_rc < 0) return error.InputOutput;
                if (s_rc == 0) break;
                total += @intCast(s_rc);
            }
            return total;
        } else if (self.mem_backing) |*mem| {
            if (offset >= mem.items.len) return 0;
            const available = mem.items.len - offset;
            const to_read = @min(buf.len, available);
            @memcpy(buf[0..to_read], mem.items[@intCast(offset)..@intCast(offset + to_read)]);
            return to_read;
        }
        return error.BadFileDescriptor;
    }

    pub fn sync(self: *StorageDevice) !void {
        if (self.config) |cfg| {
            if (cfg.fault_type == .fdatasync_failure) return error.InputOutput;
        }
        if (self.fd) |fd| {
            _ = std.os.linux.fdatasync(fd);
        }
    }
};

// ── Unit Tests ──────────────────────────────────────────────────────────────

test "fault_injector: passthrough writes full buffer when disabled" {
    var dev = StorageDevice.initMemory(std.testing.allocator);
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
    var dev = StorageDevice.initMemory(std.testing.allocator);
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
    var dev = StorageDevice.initMemory(std.testing.allocator);
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
    try std.testing.expect(!std.mem.eql(u8, &buf, &read_buf));
}

test "fault_injector: injects latent sector EIO" {
    var dev = StorageDevice.initMemory(std.testing.allocator);
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

test "fault_injector: injects fdatasync failure" {
    var dev = StorageDevice.initMemory(std.testing.allocator);
    defer dev.deinit();

    dev.config = .{
        .fault_type = .fdatasync_failure,
    };
    try std.testing.expectError(error.InputOutput, dev.sync());
}
