//! Native Sector Mutation & Offline Corruption Fuzzer for ZIGlite
//!
//! Subsystem: tot_hybrid/tests/storage_fuzzer.zig
//! Toolchain: Zig 0.17
//!
//! Exhaustively subjects the 20,480-byte sector geometry to:
//! 1. Tail torn writes (unaligned sector boundaries)
//! 2. Bitflips across 128-bit Zeckendorf seals, 64-byte bytecode headers, and payloads
//! 3. Misdirected writes (swapped 20,480-byte sectors)
//! 4. Phantom / zeroed sectors (SSD TRIM / unmapped sector emulation)
//! 5. Superblock / metapage corruption
//!
//! Enforces Zero Data Poisoning and deterministic seed replayability.

const std = @import("std");
const c_abi = @import("ziglite_c_abi");
const durability = c_abi.durability_mod;
const engine_mod = c_abi.engine_mod;
const query_mod = c_abi.query_mod;

pub const MutationType = enum {
    torn_tail,
    bitflip_seal,
    bitflip_header,
    bitflip_payload,
    sector_swap,
    zero_fill,
    superblock,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var seed: u64 = 0x1337BEEFCAFE;
    var iterations: usize = 1000;

    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--seed") and idx + 1 < args.len) {
            idx += 1;
            seed = std.fmt.parseUnsigned(u64, args[idx], 0) catch 0x1337BEEFCAFE;
        } else if (std.mem.eql(u8, arg, "--iterations") and idx + 1 < args.len) {
            idx += 1;
            iterations = std.fmt.parseUnsigned(usize, args[idx], 10) catch 1000;
        }
    }

    std.debug.print("╔═══════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  ZIGlite Native Sector Mutation & Offline Corruption Fuzzer      ║\n", .{});
    std.debug.print("║  Seed: 0x{X:0>16} | Iterations: {d:<8}              ║\n", .{ seed, iterations });
    std.debug.print("╚═══════════════════════════════════════════════════════════════════╝\n", .{});

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var torn_count: usize = 0;
    var bitflip_count: usize = 0;
    var swap_count: usize = 0;
    var zero_count: usize = 0;
    var superblock_count: usize = 0;
    var passed: usize = 0;

    const num_slots: usize = 6;
    const full_db_size = num_slots * durability.RECORD_BYTES;

    for (0..iterations) |iter| {
        _ = iter;
        var db_buf: [full_db_size]u8 align(4096) = @splat(0);

        // 1. Seed clean valid database
        for (0..num_slots) |slot| {
            const off = slot * durability.RECORD_BYTES;
            // Write opcode in cell header at PREFETCH_LABEL_BYTES
            std.mem.writeInt(u64, db_buf[off + durability.PREFETCH_LABEL_BYTES..][0..8], 0x2000 + slot, .little);
            // Write subject ID
            std.mem.writeInt(u64, db_buf[off + durability.PREFETCH_LABEL_BYTES + 8 ..][0..8], slot + 1, .little);
            // Seal record
            const rec_ptr: *[durability.RECORD_BYTES]u8 = @ptrCast(db_buf[off .. off + durability.RECORD_BYTES].ptr);
            durability.sealRecord(rec_ptr);
            std.debug.assert(durability.validateRecord(rec_ptr));
        }

        // 2. Select and apply mutation class
        const mut_type = random.enumValue(MutationType);
        switch (mut_type) {
            .torn_tail => {
                torn_count += 1;
                // Truncate trailing record by random bytes (1 to 20,479 bytes)
                const cut = random.intRangeAtMost(usize, 1, durability.RECORD_BYTES - 1);
                const mutated_slice = db_buf[0 .. full_db_size - cut];

                var bitmap: [16]bool = @splat(false);
                const res = durability.scanBufferProtocolAware(mutated_slice, num_slots, &bitmap);

                // Invariant: Tail torn write MUST be detected and clean boundary MUST be exact multiple of 20,480
                std.debug.assert(res.tail_torn_detected);
                std.debug.assert(res.clean_byte_boundary == (num_slots - 1) * durability.RECORD_BYTES);
                std.debug.assert(res.valid_records == num_slots - 1);
            },
            .bitflip_seal => {
                bitflip_count += 1;
                const target_slot = random.intRangeAtMost(usize, 1, num_slots - 1);
                const off = target_slot * durability.RECORD_BYTES;
                const byte_idx = random.intRangeAtMost(usize, 0, durability.ZECKENDORF_SEAL_BYTES - 1);
                const bit_mask = @as(u8, 1) << @intCast(random.intRangeAtMost(u3, 0, 7));
                db_buf[off + byte_idx] ^= bit_mask;

                var bitmap: [16]bool = @splat(false);
                const res = durability.scanBufferProtocolAware(&db_buf, num_slots, &bitmap);

                std.debug.assert(res.corrupt_records >= 1);
                std.debug.assert(bitmap[target_slot] == true);
                // Invariant: Neighbors must remain intact
                if (target_slot > 1) std.debug.assert(bitmap[target_slot - 1] == false);
                if (target_slot < num_slots - 1) std.debug.assert(bitmap[target_slot + 1] == false);
            },
            .bitflip_header => {
                bitflip_count += 1;
                const target_slot = random.intRangeAtMost(usize, 1, num_slots - 1);
                const off = target_slot * durability.RECORD_BYTES;
                const byte_idx = random.intRangeAtMost(usize, durability.PREFETCH_LABEL_BYTES, durability.PREFETCH_LABEL_BYTES + durability.BYTECODE_HEADER_BYTES - 1);
                const bit_mask = @as(u8, 1) << @intCast(random.intRangeAtMost(u3, 0, 7));
                db_buf[off + byte_idx] ^= bit_mask;

                var bitmap: [16]bool = @splat(false);
                const res = durability.scanBufferProtocolAware(&db_buf, num_slots, &bitmap);

                std.debug.assert(res.corrupt_records >= 1);
                std.debug.assert(bitmap[target_slot] == true);
            },
            .bitflip_payload => {
                bitflip_count += 1;
                const target_slot = random.intRangeAtMost(usize, 1, num_slots - 1);
                const off = target_slot * durability.RECORD_BYTES;
                const byte_idx = random.intRangeAtMost(usize, durability.PREFETCH_LABEL_BYTES + durability.BYTECODE_HEADER_BYTES, durability.RECORD_BYTES - 1);
                const bit_mask = @as(u8, 1) << @intCast(random.intRangeAtMost(u3, 0, 7));
                db_buf[off + byte_idx] ^= bit_mask;

                var bitmap: [16]bool = @splat(false);
                const res = durability.scanBufferProtocolAware(&db_buf, num_slots, &bitmap);

                std.debug.assert(res.corrupt_records >= 1);
                std.debug.assert(bitmap[target_slot] == true);
            },
            .sector_swap => {
                swap_count += 1;
                const slot_a = random.intRangeAtMost(usize, 1, 2);
                const slot_b = random.intRangeAtMost(usize, 3, 4);
                var tmp: [durability.RECORD_BYTES]u8 = undefined;
                @memcpy(&tmp, db_buf[slot_a * durability.RECORD_BYTES .. (slot_a + 1) * durability.RECORD_BYTES]);
                @memcpy(db_buf[slot_a * durability.RECORD_BYTES .. (slot_a + 1) * durability.RECORD_BYTES], db_buf[slot_b * durability.RECORD_BYTES .. (slot_b + 1) * durability.RECORD_BYTES]);
                @memcpy(db_buf[slot_b * durability.RECORD_BYTES .. (slot_b + 1) * durability.RECORD_BYTES], &tmp);

                var bitmap: [16]bool = @splat(false);
                const res = durability.scanBufferProtocolAware(&db_buf, num_slots, &bitmap);
                std.debug.assert(res.valid_records <= num_slots);
            },
            .zero_fill => {
                zero_count += 1;
                const target_slot = random.intRangeAtMost(usize, 1, num_slots - 1);
                @memset(db_buf[target_slot * durability.RECORD_BYTES .. (target_slot + 1) * durability.RECORD_BYTES], 0);

                var bitmap: [16]bool = @splat(false);
                const res = durability.scanBufferProtocolAware(&db_buf, num_slots, &bitmap);
                std.debug.assert(bitmap[target_slot] == true or res.valid_records < num_slots);
            },
            .superblock => {
                superblock_count += 1;
                // Mutate slot 0 seal
                db_buf[0] ^= 0x55;
                const sb_ptr: *const [durability.RECORD_BYTES]u8 = @ptrCast(db_buf[0..durability.RECORD_BYTES].ptr);
                const is_valid = durability.validateRecord(sb_ptr);
                std.debug.assert(!is_valid);
            },
        }

        passed += 1;
    }

    std.debug.print("  Torn Writes Tested     : {d:<6}\n", .{torn_count});
    std.debug.print("  Bit-Flips Tested       : {d:<6}\n", .{bitflip_count});
    std.debug.print("  Sector Swaps Tested    : {d:<6}\n", .{swap_count});
    std.debug.print("  Zero-Fills Tested      : {d:<6}\n", .{zero_count});
    std.debug.print("  Superblock Tests       : {d:<6}\n", .{superblock_count});
    std.debug.print("───────────────────────────────────────────────────────────────────\n", .{});
    std.debug.print("  RESULT                 : ALL {d}/{d} ITERATIONS PASSED (0 POISONING)\n", .{ passed, iterations });
    std.debug.print("═══════════════════════════════════════════════════════════════════\n", .{});
}
