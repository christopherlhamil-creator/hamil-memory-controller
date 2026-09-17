//! Cell Slot Pacer & Council Coordination Engine
//!
//! Subsystem: tot_hybrid/src/pacer.zig
//!
//! Architecture:
//!   1. Cell Slot Pacing (Timing the Grab):
//!      Lock-free atomic slot reservation for 17,408-byte cell buffers.
//!      Rather than serializing writers with a global mutex, the pacer times
//!      and dispenses the cell grab: Writer A takes cell N, Writer B immediately
//!      advances to cell N+1. Writes occur concurrently across non-overlapping
//!      17,408B cache-line aligned slots with zero false sharing.
//!
//!   2. Writer Identity Stamping (Seat + Model + PID):
//!      Each cell grab stamps the exact author identity:
//!      - Seat identifier (16B): e.g. "council-claude", "council-codex"
//!      - Model identifier (16B): e.g. "claude-3-7-son", "gpt-5.6-luna"
//!      - OS Process ID (u32 PID)
//!      - Monotonic epoch fencing token
//!
//!   3. Council Workspace Lease Pacer:
//!      Prevents concurrent multi-agent write collisions on shared source files
//!      (such as the Seat 0 vs Seat 3 collision on src/intake_gate.zig).
//!      Leases are non-blocking: if a file is leased by peer (Seat X, PID Y),
//!      the second writer is redirected to its secondary task.
//!
//!   4. 3-Way Liveness Verification:
//!      Unifies OS PID state, PTY prompt state, and ring sequence monotonicity
//!      to eliminate false positives in agent idle/active detection.
//!
//! Toolchain: Zig 0.17 / Zig 0.16 compatible.

const std = @import("std");
const geometry = @import("geometry");

// ── Compile-time Invariants ──────────────────────────────────────────────────

pub const CELL_BYTES: usize = geometry.CELL_BYTES; // 17,408
pub const BYTECODE_HEADER_BYTES: usize = geometry.BYTECODE_HEADER_BYTES; // 64
pub const MAX_HOP_DEPTH: usize = geometry.MAX_HOP_DEPTH; // 4

comptime {
    std.debug.assert(CELL_BYTES == 17408);
    std.debug.assert(BYTECODE_HEADER_BYTES == 64);
    std.debug.assert(MAX_HOP_DEPTH == 4);
}

// ── Identity Stamping ────────────────────────────────────────────────────────

pub const WriterIdentity = struct {
    seat: [16]u8,
    model: [16]u8,
    pid: u32,
    epoch: u32,

    pub fn init(seat_str: []const u8, model_str: []const u8, pid: u32, epoch: u32) WriterIdentity {
        var id = WriterIdentity{
            .seat = @splat(0),
            .model = @splat(0),
            .pid = pid,
            .epoch = epoch,
        };
        const s_len = @min(seat_str.len, 16);
        @memcpy(id.seat[0..s_len], seat_str[0..s_len]);

        const m_len = @min(model_str.len, 16);
        @memcpy(id.model[0..m_len], model_str[0..m_len]);

        return id;
    }

    pub fn matchesSeat(self: *const WriterIdentity, seat_str: []const u8) bool {
        const s_len = @min(seat_str.len, 16);
        return std.mem.eql(u8, self.seat[0..s_len], seat_str[0..s_len]);
    }
};

// ── Cell Slot Pacer (Timing the Grab) ─────────────────────────────────────────

pub const SlotState = enum(u8) {
    unreserved = 0,
    claimed = 1,
    committed = 2,
    released = 3,
};

pub const CellSlotLease = struct {
    slot_id: u64,
    byte_offset: u64,
    identity: WriterIdentity,
    state: SlotState,
    claim_timestamp_ms: i64,
};

pub const CellSlotPacer = struct {
    base_slot: u64 = 0,
    max_slots: u64,
    next_slot: std.atomic.Value(u64),
    committed_count: std.atomic.Value(u64),
    leases: []CellSlotLease,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_slots: u64) !CellSlotPacer {
        return initStartingAt(allocator, 0, max_slots);
    }

    pub fn initStartingAt(allocator: std.mem.Allocator, base_slot: u64, max_slots: u64) !CellSlotPacer {
        const leases = try allocator.alloc(CellSlotLease, @intCast(max_slots));
        for (leases, 0..) |*lease, i| {
            const slot = base_slot + i;
            lease.* = .{
                .slot_id = slot,
                .byte_offset = slot * CELL_BYTES,
                .identity = WriterIdentity.init("unassigned", "none", 0, 0),
                .state = .unreserved,
                .claim_timestamp_ms = 0,
            };
        }
        return CellSlotPacer{
            .base_slot = base_slot,
            .max_slots = max_slots,
            .next_slot = std.atomic.Value(u64).init(base_slot),
            .committed_count = std.atomic.Value(u64).init(0),
            .leases = leases,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CellSlotPacer) void {
        self.allocator.free(self.leases);
    }

    /// Atomically grabs the next available cell slot for a writer.
    /// Never serializes or blocks on a busy slot: if another writer is claiming slot N,
    /// this writer atomically receives slot N+1 immediately.
    pub fn grabNextCellSlot(self: *CellSlotPacer, identity: WriterIdentity, now_ms: i64) !CellSlotLease {
        while (true) {
            const current = self.next_slot.load(.acquire);
            if (current >= self.base_slot + self.max_slots) {
                return error.CellBankExhausted;
            }
            if (self.next_slot.cmpxchgWeak(current, current + 1, .seq_cst, .acquire) == null) {
                const idx: usize = @intCast(current - self.base_slot);
                self.leases[idx] = .{
                    .slot_id = current,
                    .byte_offset = current * CELL_BYTES,
                    .identity = identity,
                    .state = .claimed,
                    .claim_timestamp_ms = now_ms,
                };
                return self.leases[idx];
            }
        }
    }

    /// Marks a claimed slot as committed to disk/ring.
    pub fn commitCellSlot(self: *CellSlotPacer, slot_id: u64, identity: WriterIdentity) !void {
        if (slot_id < self.base_slot or slot_id >= self.base_slot + self.max_slots) return error.InvalidSlotId;
        const idx: usize = @intCast(slot_id - self.base_slot);
        const lease = &self.leases[idx];

        if (lease.state != .claimed) return error.SlotNotClaimed;
        if (lease.identity.pid != identity.pid and identity.pid != 0) {
            return error.OwnerMismatch;
        }

        lease.state = .committed;
        _ = self.committed_count.fetchAdd(1, .release);
    }
};

// ── Council File Lease Pacer ──────────────────────────────────────────────────

pub const MAX_LEASED_FILES: usize = 32;

pub const FileLease = struct {
    path: [64]u8,
    path_len: u8,
    holder: WriterIdentity,
    expires_at_ms: i64,
    active: bool,
};

pub const CouncilFilePacer = struct {
    leases: [MAX_LEASED_FILES]FileLease,
    lock: std.atomic.Value(bool),

    pub fn init() CouncilFilePacer {
        var pacer = CouncilFilePacer{
            .leases = undefined,
            .lock = std.atomic.Value(bool).init(false),
        };
        for (&pacer.leases) |*l| {
            l.path = @splat(0);
            l.path_len = 0;
            l.holder = WriterIdentity.init("none", "none", 0, 0);
            l.expires_at_ms = 0;
            l.active = false;
        }
        return pacer;
    }

    fn acquireSpinlock(self: *CouncilFilePacer) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn releaseSpinlock(self: *CouncilFilePacer) void {
        self.lock.store(false, .release);
    }

    /// Attempts to acquire an exclusive file mutation lease.
    /// If already leased by a different seat and not expired, returns error.ResourceLeasedByPeer.
    pub fn acquireLease(
        self: *CouncilFilePacer,
        path: []const u8,
        holder: WriterIdentity,
        ttl_ms: i64,
        now_ms: i64,
    ) !void {
        self.acquireSpinlock();
        defer self.releaseSpinlock();

        const copy_len = @min(path.len, 64);
        var free_slot: ?usize = null;

        for (&self.leases, 0..) |*l, i| {
            if (!l.active or l.expires_at_ms <= now_ms) {
                if (free_slot == null) free_slot = i;
                l.active = false;
                continue;
            }
            if (l.path_len == copy_len and std.mem.eql(u8, l.path[0..copy_len], path[0..copy_len])) {
                // Same seat refreshing its own lease is allowed
                if (l.holder.pid == holder.pid and std.mem.eql(u8, &l.holder.seat, &holder.seat)) {
                    l.expires_at_ms = now_ms + ttl_ms;
                    return;
                }
                return error.ResourceLeasedByPeer;
            }
        }

        const slot_idx = free_slot orelse return error.NoFreeLeaseSlots;
        var new_path: [64]u8 = @splat(0);
        @memcpy(new_path[0..copy_len], path[0..copy_len]);

        self.leases[slot_idx] = .{
            .path = new_path,
            .path_len = @intCast(copy_len),
            .holder = holder,
            .expires_at_ms = now_ms + ttl_ms,
            .active = true,
        };
    }

    /// Releases a file lease held by this seat.
    pub fn releaseLease(self: *CouncilFilePacer, path: []const u8, holder: WriterIdentity) !void {
        self.acquireSpinlock();
        defer self.releaseSpinlock();

        const copy_len = @min(path.len, 64);
        for (&self.leases) |*l| {
            if (l.active and l.path_len == copy_len and std.mem.eql(u8, l.path[0..copy_len], path[0..copy_len])) {
                if (l.holder.pid == holder.pid) {
                    l.active = false;
                    return;
                }
                return error.OwnerMismatch;
            }
        }
    }
};

// ── 3-Way Liveness Verification ──────────────────────────────────────────────

pub const AgentLivenessVerdict = enum {
    active_working,
    quiescent_idle,
    hung_or_desynced,
    dead_process,
};

pub const ThreeWayCheck = struct {
    pid_alive: bool,
    pty_idle_prompt: bool,
    sequence_head_advanced: bool,

    pub fn evaluate(self: ThreeWayCheck) AgentLivenessVerdict {
        if (!self.pid_alive) {
            return .dead_process;
        }
        if (!self.pty_idle_prompt) {
            // Actively computing or writing in PTY
            return .active_working;
        }
        if (self.pty_idle_prompt and !self.sequence_head_advanced) {
            // Sitting idle at prompt, no active uncommitted sequence
            return .quiescent_idle;
        }
        // Sitting at idle prompt but uncommitted sequence is hanging
        return .hung_or_desynced;
    }
};

// ── Unit Tests ───────────────────────────────────────────────────────────────

test "pacer: timing the grab avoids writer serialization" {
    const allocator = std.testing.allocator;
    var pacer = try CellSlotPacer.init(allocator, 16);
    defer pacer.deinit();

    const claude = WriterIdentity.init("council-claude", "sonnet-3-7", 1001, 1);
    const codex = WriterIdentity.init("council-codex", "gpt-5.6", 1002, 1);

    // Claude grabs slot 0
    const lease0 = try pacer.grabNextCellSlot(claude, 1000);
    try std.testing.expectEqual(@as(u64, 0), lease0.slot_id);
    try std.testing.expectEqual(@as(u64, 0), lease0.byte_offset);

    // Codex immediately grabs slot 1 without blocking or clobbering
    const lease1 = try pacer.grabNextCellSlot(codex, 1001);
    try std.testing.expectEqual(@as(u64, 1), lease1.slot_id);
    try std.testing.expectEqual(@as(u64, 17408), lease1.byte_offset);

    // Both commit their independent non-overlapping slots
    try pacer.commitCellSlot(lease0.slot_id, claude);
    try pacer.commitCellSlot(lease1.slot_id, codex);

    try std.testing.expectEqual(@as(u64, 2), pacer.committed_count.load(.acquire));
}

test "pacer: council file lease prevents concurrent edit collision" {
    var file_pacer = CouncilFilePacer.init();

    const claude = WriterIdentity.init("council-claude", "sonnet-3-7", 1001, 1);
    const codex = WriterIdentity.init("council-codex", "gpt-5.6", 1002, 1);

    // Claude acquires exclusive lease on intake_gate.zig
    try file_pacer.acquireLease("src/intake_gate.zig", claude, 10000, 100);

    // Codex attempting to grab the same file concurrently is rejected with ResourceLeasedByPeer
    const codex_res = file_pacer.acquireLease("src/intake_gate.zig", codex, 10000, 105);
    try std.testing.expectError(error.ResourceLeasedByPeer, codex_res);

    // Codex can successfully acquire a different file
    try file_pacer.acquireLease("migrations/002_model_governance.up.sql", codex, 10000, 110);

    // Once Claude releases, Codex or another agent can acquire it
    try file_pacer.releaseLease("src/intake_gate.zig", claude);
    try file_pacer.acquireLease("src/intake_gate.zig", codex, 10000, 120);
}

test "pacer: 3-way liveness evaluation logic" {
    const active = ThreeWayCheck{
        .pid_alive = true,
        .pty_idle_prompt = false,
        .sequence_head_advanced = false,
    };
    try std.testing.expectEqual(AgentLivenessVerdict.active_working, active.evaluate());

    const idle = ThreeWayCheck{
        .pid_alive = true,
        .pty_idle_prompt = true,
        .sequence_head_advanced = false,
    };
    try std.testing.expectEqual(AgentLivenessVerdict.quiescent_idle, idle.evaluate());

    const dead = ThreeWayCheck{
        .pid_alive = false,
        .pty_idle_prompt = true,
        .sequence_head_advanced = false,
    };
    try std.testing.expectEqual(AgentLivenessVerdict.dead_process, dead.evaluate());
}

test "pacer: cell bank exhaustion invariant" {
    const allocator = std.testing.allocator;
    var pacer = try CellSlotPacer.init(allocator, 3);
    defer pacer.deinit();

    const id = WriterIdentity.init("seat-grok", "gemini-flash", 999, 1);
    _ = try pacer.grabNextCellSlot(id, 10);
    _ = try pacer.grabNextCellSlot(id, 11);
    _ = try pacer.grabNextCellSlot(id, 12);

    try std.testing.expectError(error.CellBankExhausted, pacer.grabNextCellSlot(id, 13));
}

test "pacer: commit rejects unreserved or mismatched owner" {
    const allocator = std.testing.allocator;
    var pacer = try CellSlotPacer.init(allocator, 4);
    defer pacer.deinit();

    const claude = WriterIdentity.init("seat-claude", "claude-sonnet", 101, 1);
    const rogue = WriterIdentity.init("seat-rogue", "unknown", 666, 1);

    // Slot 0 is unreserved
    try std.testing.expectError(error.SlotNotClaimed, pacer.commitCellSlot(0, claude));

    // Claim slot 0 as claude
    const lease = try pacer.grabNextCellSlot(claude, 100);
    try std.testing.expectEqual(@as(u64, 0), lease.slot_id);

    // Rogue PID cannot commit claude's slot
    try std.testing.expectError(error.OwnerMismatch, pacer.commitCellSlot(0, rogue));

    // Valid owner commits successfully
    try pacer.commitCellSlot(0, claude);

    // Double commit fails (already committed, not claimed)
    try std.testing.expectError(error.SlotNotClaimed, pacer.commitCellSlot(0, claude));
}

test "pacer: exact byte offset alignment invariant" {
    const allocator = std.testing.allocator;
    const num_slots: u64 = 64;
    var pacer = try CellSlotPacer.init(allocator, num_slots);
    defer pacer.deinit();

    const id = WriterIdentity.init("auditor", "model", 42, 1);
    var slot_idx: u64 = 0;
    while (slot_idx < num_slots) : (slot_idx += 1) {
        const lease = try pacer.grabNextCellSlot(id, 100);
        try std.testing.expectEqual(slot_idx, lease.slot_id);
        try std.testing.expectEqual(slot_idx * CELL_BYTES, lease.byte_offset);
        // Verify 64-byte cache line alignment
        try std.testing.expectEqual(@as(u64, 0), lease.byte_offset % 64);
        // Verify 17,408-byte cell geometry alignment
        try std.testing.expectEqual(@as(u64, 0), lease.byte_offset % CELL_BYTES);
    }
}

test "pacer: concurrent multi-threaded cell slot grab" {
    const allocator = std.testing.allocator;
    const total_slots: u64 = 128;
    var pacer = try CellSlotPacer.init(allocator, total_slots);
    defer pacer.deinit();

    const Worker = struct {
        p: *CellSlotPacer,
        pid: u32,
        count: usize,
        grabbed: [32]u64,

        fn run(self: *@This()) void {
            const id = WriterIdentity.init("seat-worker", "test-model", self.pid, 1);
            for (0..self.count) |i| {
                const lease = self.p.grabNextCellSlot(id, 1000) catch return;
                self.grabbed[i] = lease.slot_id;
                self.p.commitCellSlot(lease.slot_id, id) catch {};
            }
        }
    };

    var w1 = Worker{ .p = &pacer, .pid = 1001, .count = 32, .grabbed = undefined };
    var w2 = Worker{ .p = &pacer, .pid = 1002, .count = 32, .grabbed = undefined };
    var w3 = Worker{ .p = &pacer, .pid = 1003, .count = 32, .grabbed = undefined };
    var w4 = Worker{ .p = &pacer, .pid = 1004, .count = 32, .grabbed = undefined };

    const t1 = try std.Thread.spawn(.{}, Worker.run, .{&w1});
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{&w2});
    const t3 = try std.Thread.spawn(.{}, Worker.run, .{&w3});
    const t4 = try std.Thread.spawn(.{}, Worker.run, .{&w4});

    t1.join();
    t2.join();
    t3.join();
    t4.join();

    // Verify exactly 128 slots committed
    try std.testing.expectEqual(@as(u64, 128), pacer.committed_count.load(.acquire));

    // Verify all grabbed slot IDs are unique in [0, 128)
    var seen: [128]bool = undefined;
    @memset(&seen, false);
    const all_workers = [_]*const Worker{ &w1, &w2, &w3, &w4 };
    for (all_workers) |w| {
        for (w.grabbed[0..w.count]) |slot_id| {
            try std.testing.expect(slot_id < 128);
            try std.testing.expect(!seen[slot_id]);
            seen[slot_id] = true;
        }
    }
}

test "pacer: file lease expiration allows acquisition after TTL" {
    var file_pacer = CouncilFilePacer.init();

    const claude = WriterIdentity.init("council-claude", "sonnet-3-7", 1001, 1);
    const codex = WriterIdentity.init("council-codex", "gpt-5.6", 1002, 1);

    // Claude acquires lease with TTL 50ms at now_ms = 100 (expires at 150)
    try file_pacer.acquireLease("src/remediation.zig", claude, 50, 100);

    // Codex rejected before expiration at now_ms = 120
    try std.testing.expectError(error.ResourceLeasedByPeer, file_pacer.acquireLease("src/remediation.zig", codex, 50, 120));

    // At now_ms = 160, Claude's lease has expired; Codex successfully acquires it
    try file_pacer.acquireLease("src/remediation.zig", codex, 50, 160);
}

test "pacer: initStartingAt non-zero base slot preserves existing bank" {
    const allocator = std.testing.allocator;
    var p = try CellSlotPacer.initStartingAt(allocator, 1994, 10);
    defer p.deinit();

    const id = WriterIdentity.init("seat-0", "model-x", 1234, 1);
    const lease1 = try p.grabNextCellSlot(id, 100);
    try std.testing.expectEqual(@as(u64, 1994), lease1.slot_id);
    try std.testing.expectEqual(@as(u64, 1994 * CELL_BYTES), lease1.byte_offset);

    const lease2 = try p.grabNextCellSlot(id, 101);
    try std.testing.expectEqual(@as(u64, 1995), lease2.slot_id);

    try p.commitCellSlot(1994, id);
    try std.testing.expectEqual(@as(u64, 1), p.committed_count.load(.acquire));
}
