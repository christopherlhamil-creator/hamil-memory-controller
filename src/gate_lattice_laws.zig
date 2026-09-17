//! Gate Lattice Laws: Compile-Time and Fast Native C-ABI Invariant Enforcement
//!
//! Subsystem: tot_hybrid/src/gate_lattice_laws.zig
//!
//! Replaces legacy SQLite database triggers (17 triggers from genealogy-2026-08-23.sqlite)
//! with machine-speed gate validation at the memory controller ABI boundary:
//!   - Gate 1: Replaces `trg_conclusions_no_machine_author` -> Rejects machine authorship.
//!   - Gate 2: Replaces `trg_conclusions_require_gate` -> Enforces HUB_WRITE capability bitmask.
//!   - Gate 3: Replaces `trg_protect_human_review` -> Enforces append-only human reviewed invariant.
//!   - Gate 4: Kleppmann monotonic fencing -> Drops stale / out-of-order epoch packets at the wire.
//!   - Gate 5: Defect Class 20 (`sqlite_lock_tax_leak`) -> Permanent veto against file-level DB mutexes in hot path.
//!   - Bare-Metal Kanban Kernel Integration: Every candidate cell pushed to `kanban_kernel`
//!     is verified through `evaluate_gate_lattice_laws` BEFORE lease grant. Zero silent drops.

const std = @import("std");
pub const geometry = @import("geometry");

pub const MAX_CELL_BYTES: usize = 17408;

pub const GateError = error{
    MachineAuthorRefused,
    CapabilityBitmaskMissing,
    HumanReviewViolation,
    SqliteLockTaxLeak, // Defect Class 20: file-level database mutex / lock tax leak
    CellInvalidGeometry,
    SilentErrorDropped,
    LeaseDenied,
    SlotExhausted,
};

pub const InstructionHeader = extern struct {
    opcode: u64 align(64),
    subject_id: [16]u8,
    predicate_id: [16]u8,
    target_id: [16]u8,
    flags: u32,
    epoch: u32,

    comptime {
        std.debug.assert(@sizeOf(InstructionHeader) == 64);
        std.debug.assert(@alignOf(InstructionHeader) == 64);
    }

    pub fn toBytecodeHeader(self: *const InstructionHeader) geometry.BytecodeHeader {
        const prov: u64 = @as(u64, self.flags) | (@as(u64, self.epoch) << 32);
        return .{
            .opcode = self.opcode,
            .subject_id = self.subject_id,
            .predicate_op = self.predicate_id,
            .target_val = self.target_id,
            .provenance_flags = prov,
        };
    }

    pub fn fromBytecodeHeader(bh: *const geometry.BytecodeHeader) InstructionHeader {
        return .{
            .opcode = bh.opcode,
            .subject_id = bh.subject_id,
            .predicate_id = bh.predicate_op,
            .target_id = bh.target_val,
            .flags = @truncate(bh.provenance_flags),
            .epoch = @truncate(bh.provenance_flags >> 32),
        };
    }
};

/// Bitmask checks mapped directly out of old admin_flags trigger requirements
pub const CapabilityFlags = enum(u32) {
    HUB_WRITE = 0x0001,           // Old hub_write flag gate
    HUMAN_REVIEWED = 0x0002,      // Protections for immutable lines
    SYSTEM_ADMIN = 0x0004,        // Root infrastructure execution
    SQLITE_LOCK_ATTEMPT = 0x0008, // Defect Class 20: file-level database lock attempt (permanent veto)
};

/// Identity denylist mapping to machine signatures to replicate trg_conclusions_no_machine_author
pub const machine_identities = [_][16]u8{
    [_]u8{ 'c', 'l', 'a', 'u', 'd', 'e', '-', 'c', 'o', 'd', 'e', 0, 0, 0, 0, 0 },
    [_]u8{ 'o', 'l', 'l', 'a', 'm', 'a', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 'g', 'e', 'm', 'i', 'n', 'i', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 'p', 'i', 'p', 'e', 'l', 'i', 'n', 'e', 0, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 'w', 'a', 't', 'c', 'h', 'e', 'r', 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 'l', 'o', 'c', 'a', 'l', '_', 'l', 'l', 'm', 0, 0, 0, 0, 0, 0, 0 },
};

/// Forbidden lock tokens mapping to Defect Class 20 (sqlite_lock_tax_leak)
pub const sqlite_lock_tokens = [_][]const u8{
    "sqlite_mutex",
    "file_lock",
    "wal_checkpoint",
    "sqlite_lock",
    "db_mutex",
    "busy_handler",
};

/// Forbidden lock opcodes mapping to Defect Class 20
pub const FORBIDDEN_SQLITE_MUTEX_OPCODE: u64 = 0x0020_0000;

/// Compile-time and fast native runtime gate lattice validator
pub fn evaluate_gate_lattice_laws(header: *const InstructionHeader, current_system_epoch: u32) GateError!void {
    // 1. Replicate trg_conclusions_no_machine_author logic via header identity loops
    inline for (machine_identities) |blocked_identity| {
        if (std.mem.eql(u8, &header.subject_id, &blocked_identity)) {
            // Reject write operations originating from an automated system instantly at ABI limit
            return GateError.MachineAuthorRefused;
        }
    }

    // 2. Defect Class 20: Permanent veto against any component introducing file-level database mutexes into hot path
    const sqlite_lock_mask = @intFromEnum(CapabilityFlags.SQLITE_LOCK_ATTEMPT);
    if ((header.flags & sqlite_lock_mask) != 0 or header.opcode == FORBIDDEN_SQLITE_MUTEX_OPCODE) {
        return GateError.SqliteLockTaxLeak;
    }
    inline for (sqlite_lock_tokens) |lock_tok| {
        if (std.mem.indexOf(u8, &header.predicate_id, lock_tok) != null or
            std.mem.indexOf(u8, &header.target_id, lock_tok) != null)
        {
            return GateError.SqliteLockTaxLeak;
        }
    }

    // 3. Replicate trg_conclusions_require_gate: Check capabilities via explicit bitmask flags
    const hub_write_mask = @intFromEnum(CapabilityFlags.HUB_WRITE);
    if ((header.flags & hub_write_mask) == 0) {
        return GateError.CapabilityBitmaskMissing;
    }

    // 4. Replicate trg_protect_human_review: Deny alterations to locked records
    const human_lock_mask = @intFromEnum(CapabilityFlags.HUMAN_REVIEWED);
    if ((header.flags & human_lock_mask) != 0) {
        // Enforce append-only history invariant; changes must be appended alongside via mitosis instead
        return GateError.HumanReviewViolation;
    }

    // 5. Enforce monotonic Kleppmann fencing epoch tokens to ignore out-of-order packets
    if (header.epoch < current_system_epoch) {
        // Packet dropped at the wire; old network state can never alter newer converged realities
        return GateError.CapabilityBitmaskMissing;
    }
}

// ── Bare-Metal Kanban Kernel (Write-Gate & Lease Grant Integration) ──────────

pub const KanbanLane = enum(u8) {
    inbox_unread = 0,
    active_pending = 1,
    blocked_preflight = 2,
    complete_grounded = 3,
};

pub const KanbanCellLease = struct {
    slot_id: u64,
    byte_offset: u64,
    author: [16]u8,
    lane: KanbanLane,
    epoch: u32,
    granted_timestamp_ns: i64,
    committed: bool,
};

pub const MAX_KANBAN_CELLS: usize = 128;

pub const KanbanKernel = struct {
    cell_slots: [MAX_KANBAN_CELLS]geometry.Cell = undefined,
    leases: [MAX_KANBAN_CELLS]KanbanCellLease = undefined,
    slot_allocated: [MAX_KANBAN_CELLS]bool = @splat(false),
    slot_count: usize = 0,
    current_system_epoch: u32,

    pub fn init(initial_epoch: u32) KanbanKernel {
        return .{
            .current_system_epoch = initial_epoch,
            .slot_count = 0,
        };
    }

    /// Push candidate cell to Kanban Kernel.
    /// Invariant: Every candidate cell pushed to kanban_kernel is verified
    /// through evaluate_gate_lattice_laws BEFORE lease grant.
    /// If verification fails, no lease is granted and the exact GateError is returned.
    /// Rejects any write path that silently drops errors.
    pub fn pushCandidateCell(
        self: *KanbanKernel,
        candidate_cell: *const geometry.Cell,
        lane: KanbanLane,
        timestamp_ns: i64,
    ) GateError!KanbanCellLease {
        // 1. Extract instruction header from candidate cell
        const inst_hdr = InstructionHeader.fromBytecodeHeader(&candidate_cell.header);

        // 2. Machine-speed gate verification BEFORE lease grant
        // Propagate error directly; NEVER silently drop.
        try evaluate_gate_lattice_laws(&inst_hdr, self.current_system_epoch);

        // 3. Verify cell geometry
        if (@sizeOf(geometry.Cell) != MAX_CELL_BYTES) {
            return GateError.CellInvalidGeometry;
        }

        // 4. Grant atomic lease only after passing gate verification
        if (self.slot_count >= MAX_KANBAN_CELLS) {
            return GateError.SlotExhausted;
        }

        const slot_idx = self.slot_count;
        self.slot_count += 1;

        // Copy candidate cell into kernel cell slot
        self.cell_slots[slot_idx] = candidate_cell.*;
        self.slot_allocated[slot_idx] = true;

        const lease = KanbanCellLease{
            .slot_id = slot_idx,
            .byte_offset = slot_idx * MAX_CELL_BYTES,
            .author = candidate_cell.header.subject_id,
            .lane = lane,
            .epoch = inst_hdr.epoch,
            .granted_timestamp_ns = timestamp_ns,
            .committed = true,
        };
        self.leases[slot_idx] = lease;

        return lease;
    }

    /// Request a mutable lease for a new Kanban work item cell.
    /// Verifies the planned instruction header through evaluate_gate_lattice_laws
    /// BEFORE granting the lease and slot pointer.
    pub fn requestCellLease(
        self: *KanbanKernel,
        header: *const InstructionHeader,
        lane: KanbanLane,
        timestamp_ns: i64,
    ) GateError!*geometry.Cell {
        try evaluate_gate_lattice_laws(header, self.current_system_epoch);

        if (self.slot_count >= MAX_KANBAN_CELLS) {
            return GateError.SlotExhausted;
        }

        const slot_idx = self.slot_count;
        self.slot_count += 1;

        const cell_ptr = &self.cell_slots[slot_idx];
        cell_ptr.header = header.toBytecodeHeader();
        @memset(std.mem.asBytes(&cell_ptr.fingerprints), 0);
        @memset(&cell_ptr.semantic_payload, 0);

        self.slot_allocated[slot_idx] = true;
        self.leases[slot_idx] = .{
            .slot_id = slot_idx,
            .byte_offset = slot_idx * MAX_CELL_BYTES,
            .author = header.subject_id,
            .lane = lane,
            .epoch = header.epoch,
            .granted_timestamp_ns = timestamp_ns,
            .committed = false,
        };

        return cell_ptr;
    }

    pub fn commitLease(self: *KanbanKernel, slot_id: u64) GateError!void {
        if (slot_id >= self.slot_count or !self.slot_allocated[slot_id]) {
            return GateError.LeaseDenied;
        }
        self.leases[slot_id].committed = true;
    }

    pub fn getCell(self: *const KanbanKernel, slot_id: u64) ?*const geometry.Cell {
        if (slot_id >= self.slot_count or !self.slot_allocated[slot_id]) {
            return null;
        }
        return &self.cell_slots[slot_id];
    }
};

pub export fn kanban_kernel_validate_and_grant(
    opcode: u64,
    sub_ptr: [*]const u8,
    pred_ptr: [*]const u8,
    targ_ptr: [*]const u8,
    flags: u32,
    epoch: u32,
    current_system_epoch: u32,
) callconv(.c) i32 {
    var header: InstructionHeader = undefined;
    header.opcode = opcode;
    @memcpy(&header.subject_id, sub_ptr[0..16]);
    @memcpy(&header.predicate_id, pred_ptr[0..16]);
    @memcpy(&header.target_id, targ_ptr[0..16]);
    header.flags = flags;
    header.epoch = epoch;

    evaluate_gate_lattice_laws(&header, current_system_epoch) catch |err| switch (err) {
        error.MachineAuthorRefused => return 1,
        error.CapabilityBitmaskMissing => return 2,
        error.HumanReviewViolation => return 3,
        error.SqliteLockTaxLeak => return 4,
        error.CellInvalidGeometry => return 5,
        error.SilentErrorDropped => return 6,
        error.LeaseDenied => return 7,
        error.SlotExhausted => return 8,
    };
    return 0; // Success: Gate law verified cleanly
}

// ── Unit Tests ───────────────────────────────────────────────────────────────

test "gate: reject machine author signatures" {
    var hdr: InstructionHeader = .{
        .opcode = 0x0A01,
        .subject_id = machine_identities[0], // claude-code
        .predicate_id = @splat(0),
        .target_id = @splat(0),
        .flags = @intFromEnum(CapabilityFlags.HUB_WRITE),
        .epoch = 100,
    };

    try std.testing.expectError(GateError.MachineAuthorRefused, evaluate_gate_lattice_laws(&hdr, 100));
}

test "gate: require HUB_WRITE capability bitmask" {
    var human_sub: [16]u8 = @splat(0);
    @memcpy(human_sub[0..5], "human");

    var hdr: InstructionHeader = .{
        .opcode = 0x0A01,
        .subject_id = human_sub,
        .predicate_id = @splat(0),
        .target_id = @splat(0),
        .flags = 0, // Missing HUB_WRITE
        .epoch = 100,
    };

    try std.testing.expectError(GateError.CapabilityBitmaskMissing, evaluate_gate_lattice_laws(&hdr, 100));
}

test "gate: prevent overwriting human-reviewed lines (human review violation)" {
    var human_sub: [16]u8 = @splat(0);
    @memcpy(human_sub[0..5], "human");

    var hdr: InstructionHeader = .{
        .opcode = 0x0A01,
        .subject_id = human_sub,
        .predicate_id = @splat(0),
        .target_id = @splat(0),
        .flags = @intFromEnum(CapabilityFlags.HUB_WRITE) | @intFromEnum(CapabilityFlags.HUMAN_REVIEWED),
        .epoch = 100,
    };

    try std.testing.expectError(GateError.HumanReviewViolation, evaluate_gate_lattice_laws(&hdr, 100));
}

test "gate: reject stale Kleppmann epoch fencing tokens" {
    var human_sub: [16]u8 = @splat(0);
    @memcpy(human_sub[0..5], "human");

    var hdr: InstructionHeader = .{
        .opcode = 0x0A01,
        .subject_id = human_sub,
        .predicate_id = @splat(0),
        .target_id = @splat(0),
        .flags = @intFromEnum(CapabilityFlags.HUB_WRITE),
        .epoch = 50, // Less than current system epoch 100
    };

    try std.testing.expectError(GateError.CapabilityBitmaskMissing, evaluate_gate_lattice_laws(&hdr, 100));
}

test "gate: valid human sovereign header passes cleanly" {
    var human_sub: [16]u8 = @splat(0);
    @memcpy(human_sub[0..14], "human_obsidian");

    const hdr: InstructionHeader = .{
        .opcode = 0x0A01,
        .subject_id = human_sub,
        .predicate_id = @splat(0),
        .target_id = @splat(0),
        .flags = @intFromEnum(CapabilityFlags.HUB_WRITE),
        .epoch = 100,
    };

    try evaluate_gate_lattice_laws(&hdr, 100);
}

test "gate: Defect Class 20 permanent veto against sqlite lock tax leak" {
    var human_sub: [16]u8 = @splat(0);
    @memcpy(human_sub[0..14], "human_obsidian");

    // 1. Flag-based lock attempt
    var flag_hdr: InstructionHeader = .{
        .opcode = 0x0A01,
        .subject_id = human_sub,
        .predicate_id = @splat(0),
        .target_id = @splat(0),
        .flags = @intFromEnum(CapabilityFlags.HUB_WRITE) | @intFromEnum(CapabilityFlags.SQLITE_LOCK_ATTEMPT),
        .epoch = 100,
    };
    try std.testing.expectError(GateError.SqliteLockTaxLeak, evaluate_gate_lattice_laws(&flag_hdr, 100));

    // 2. Predicate-based lock attempt (sqlite_mutex)
    var pred_hdr = flag_hdr;
    pred_hdr.flags = @intFromEnum(CapabilityFlags.HUB_WRITE);
    @memcpy(pred_hdr.predicate_id[0..12], "sqlite_mutex");
    try std.testing.expectError(GateError.SqliteLockTaxLeak, evaluate_gate_lattice_laws(&pred_hdr, 100));

    // 3. Target-based lock attempt (file_lock)
    var targ_hdr = flag_hdr;
    targ_hdr.flags = @intFromEnum(CapabilityFlags.HUB_WRITE);
    @memcpy(targ_hdr.target_id[0..9], "file_lock");
    try std.testing.expectError(GateError.SqliteLockTaxLeak, evaluate_gate_lattice_laws(&targ_hdr, 100));

    // 4. Forbidden opcode lock attempt
    var op_hdr = flag_hdr;
    op_hdr.flags = @intFromEnum(CapabilityFlags.HUB_WRITE);
    op_hdr.opcode = FORBIDDEN_SQLITE_MUTEX_OPCODE;
    try std.testing.expectError(GateError.SqliteLockTaxLeak, evaluate_gate_lattice_laws(&op_hdr, 100));
}

test "kanban_kernel: write-gate verifies candidate cells before lease grant" {
    var kernel = KanbanKernel.init(100);
    try std.testing.expectEqual(@as(usize, 0), kernel.slot_count);

    var human_sub: [16]u8 = @splat(0);
    @memcpy(human_sub[0..14], "human_obsidian");

    // Construct valid candidate cell
    var valid_cell: geometry.Cell = undefined;
    const valid_prov: u64 = @as(u64, @intFromEnum(CapabilityFlags.HUB_WRITE)) | (@as(u64, 100) << 32);
    valid_cell.header = .{
        .opcode = 0x0A01,
        .subject_id = human_sub,
        .predicate_op = @splat(0),
        .target_val = @splat(0),
        .provenance_flags = valid_prov,
    };
    @memset(std.mem.asBytes(&valid_cell.fingerprints), 0);
    @memset(&valid_cell.semantic_payload, 0);
    @memcpy(valid_cell.semantic_payload[0..11], "kanban_task");

    // 1. Rejected write: Machine author candidate cell -> NO lease granted
    var machine_cell = valid_cell;
    machine_cell.header.subject_id = machine_identities[0]; // claude-code
    try std.testing.expectError(
        GateError.MachineAuthorRefused,
        kernel.pushCandidateCell(&machine_cell, .inbox_unread, 1000),
    );
    try std.testing.expectEqual(@as(usize, 0), kernel.slot_count); // Slot NOT granted

    // 2. Rejected write: Missing HUB_WRITE candidate cell -> NO lease granted
    var nocap_cell = valid_cell;
    nocap_cell.header.provenance_flags = @as(u64, 100) << 32; // flags = 0
    try std.testing.expectError(
        GateError.CapabilityBitmaskMissing,
        kernel.pushCandidateCell(&nocap_cell, .inbox_unread, 1001),
    );
    try std.testing.expectEqual(@as(usize, 0), kernel.slot_count);

    // 3. Rejected write: Defect Class 20 SQLite lock attempt candidate cell -> NO lease granted
    var lock_cell = valid_cell;
    @memcpy(lock_cell.header.predicate_op[0..12], "sqlite_mutex");
    try std.testing.expectError(
        GateError.SqliteLockTaxLeak,
        kernel.pushCandidateCell(&lock_cell, .inbox_unread, 1002),
    );
    try std.testing.expectEqual(@as(usize, 0), kernel.slot_count);

    // 4. Rejected write: Human review violation candidate cell -> NO lease granted
    var human_rev_cell = valid_cell;
    const human_rev_prov: u64 = @as(u64, @intFromEnum(CapabilityFlags.HUB_WRITE) | @intFromEnum(CapabilityFlags.HUMAN_REVIEWED)) | (@as(u64, 100) << 32);
    human_rev_cell.header.provenance_flags = human_rev_prov;
    try std.testing.expectError(
        GateError.HumanReviewViolation,
        kernel.pushCandidateCell(&human_rev_cell, .inbox_unread, 1003),
    );
    try std.testing.expectEqual(@as(usize, 0), kernel.slot_count);

    // 5. Rejected write: Stale epoch candidate cell -> NO lease granted
    var stale_cell = valid_cell;
    const stale_prov: u64 = @as(u64, @intFromEnum(CapabilityFlags.HUB_WRITE)) | (@as(u64, 50) << 32); // epoch 50 < 100
    stale_cell.header.provenance_flags = stale_prov;
    try std.testing.expectError(
        GateError.CapabilityBitmaskMissing,
        kernel.pushCandidateCell(&stale_cell, .inbox_unread, 1004),
    );
    try std.testing.expectEqual(@as(usize, 0), kernel.slot_count);

    // 6. Accepted write: Valid human candidate cell passes gate lattice laws -> Lease GRANTED!
    const lease = try kernel.pushCandidateCell(&valid_cell, .inbox_unread, 1005);
    try std.testing.expectEqual(@as(u64, 0), lease.slot_id);
    try std.testing.expectEqual(@as(u64, 0), lease.byte_offset);
    try std.testing.expectEqual(KanbanLane.inbox_unread, lease.lane);
    try std.testing.expectEqual(@as(u32, 100), lease.epoch);
    try std.testing.expect(lease.committed);
    try std.testing.expectEqual(@as(usize, 1), kernel.slot_count);

    // Verify cell content preserved exactly in bare-metal slot
    const stored = kernel.getCell(0);
    try std.testing.expect(stored != null);
    try std.testing.expectEqualStrings("kanban_task", stored.?.semantic_payload[0..11]);
    try std.testing.expectEqualStrings(&human_sub, &stored.?.header.subject_id);
}

test "kanban_kernel: requestCellLease and commitLease lifecycle" {
    var kernel = KanbanKernel.init(200);

    var human_sub: [16]u8 = @splat(0);
    @memcpy(human_sub[0..14], "human_obsidian");

    const valid_hdr = InstructionHeader{
        .opcode = 0x0A01,
        .subject_id = human_sub,
        .predicate_id = @splat(0),
        .target_id = @splat(0),
        .flags = @intFromEnum(CapabilityFlags.HUB_WRITE),
        .epoch = 200,
    };

    // Request lease: gate checked BEFORE returning cell pointer
    const cell_ptr = try kernel.requestCellLease(&valid_hdr, .active_pending, 2000);
    try std.testing.expectEqual(@as(usize, 1), kernel.slot_count);
    try std.testing.expectEqual(false, kernel.leases[0].committed);

    // Mutate cell payload under valid lease
    @memcpy(cell_ptr.semantic_payload[0..10], "lease_work");

    // Commit lease
    try kernel.commitLease(0);
    try std.testing.expectEqual(true, kernel.leases[0].committed);

    // Verify committing non-existent slot returns LeaseDenied (no silent drop)
    try std.testing.expectError(GateError.LeaseDenied, kernel.commitLease(99));
}

test "kanban_kernel: C-ABI export kanban_kernel_validate_and_grant" {
    var human_sub: [16]u8 = @splat(0);
    @memcpy(human_sub[0..14], "human_obsidian");
    const pred: [16]u8 = @splat(0);
    const targ: [16]u8 = @splat(0);

    // Valid human write -> returns 0
    const rc_ok = kanban_kernel_validate_and_grant(
        0x0A01,
        &human_sub,
        &pred,
        &targ,
        @intFromEnum(CapabilityFlags.HUB_WRITE),
        100,
        100,
    );
    try std.testing.expectEqual(@as(i32, 0), rc_ok);

    // Machine author -> returns 1
    const rc_machine = kanban_kernel_validate_and_grant(
        0x0A01,
        &machine_identities[0],
        &pred,
        &targ,
        @intFromEnum(CapabilityFlags.HUB_WRITE),
        100,
        100,
    );
    try std.testing.expectEqual(@as(i32, 1), rc_machine);

    // Defect Class 20 SQLite lock attempt -> returns 4
    const rc_lock = kanban_kernel_validate_and_grant(
        0x0A01,
        &human_sub,
        &pred,
        &targ,
        @intFromEnum(CapabilityFlags.HUB_WRITE) | @intFromEnum(CapabilityFlags.SQLITE_LOCK_ATTEMPT),
        100,
        100,
    );
    try std.testing.expectEqual(@as(i32, 4), rc_lock);
}

