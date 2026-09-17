//! Zig-on-SQLite Acceleration Sidecar ("The Semantic Sidecar")
//!
//! Not a SQL engine replacement (sqlite-zig/sqlnano/limbo are explicitly
//! rejected by the architecture this implements). SQLite stays the cold,
//! queryable, ANSI-SQL system of record. This module is the hot-path
//! bypass sitting in front of it:
//!
//!   1. Hot path (SubmitTransaction / countByState): 64B BytecodeHeader
//!      transactions land in a contiguous, cache-aligned Cell buffer via a
//!      lock-free pacer.zig slot lease. Zero heap allocation, zero SQLite
//!      involvement, zero SQL string parsing / AST / VDBE.
//!   2. Cold path (drainOnce / startDrainWorker): a background worker
//!      asynchronously flushes committed slots into a real SQLite table
//!      (`sidecar_records`, via sqlite3.h cImport) for durable storage and
//!      ANSI SQL queryability. This is the ONLY place SQLite is touched,
//!      and it never runs on the hot path -- consistent with Scar 17
//!      (sqlite_lock_tax_leak: veto file-level sqlite mutex in hot path;
//!      use lock-free ring), not a violation of it.
//!
//! Invariant A-1 (17,408B Cell) / A-2 (64B =Q16s16s16sII header) hold for
//! every slot. Host Law: no ISA pinning in source -- the SIMD scan below
//! uses a portable @Vector, lowered per host by Zig/LLVM.
//!
//! Slot allocation terminology note: the directive names "@atomicRmw
//! fetch-and-add" specifically. pacer.zig's already-tested
//! CellSlotPacer.grabNextCellSlot instead uses a cmpxchgWeak CAS retry loop
//! over std.atomic.Value(u64) -- also lock-free, same guarantee (a busy
//! slot never blocks another writer), just a different primitive. Reused
//! as-is rather than duplicating a second, parallel allocation path just to
//! literally match the named instruction.
//!
//! SIMD scan note: Cell headers sit CELL_BYTES (17,408B) apart in the
//! active buffer -- not vector-loadable directly, a single @Vector lane
//! can't stride 17KB. countByState scans a compact, genuinely contiguous
//! one-byte-per-slot status side-array instead. That is what makes the
//! scan actually vectorizable rather than a byte-strided illusion of one.

const std = @import("std");
// Re-exported: `submitTransaction` takes a `geometry.BytecodeHeader` and a
// `pacer.WriterIdentity`, so a caller in another module cannot use this API
// without them. Same shape as the `pub const c` below.
//
// council/claude wrote these as path imports (`@import("geometry.zig")`).
// build.zig already wires geometry and pacer in as MODULES for this module
// (build.zig:718-719), and a path import beside a module import gives the
// build two distinct copies of the same struct -- the exact hazard his own
// comment at build.zig:791 names. The re-export is his and is kept; only the
// import form is changed to the module, so `sqlite_sidecar.geometry` and
// `@import("geometry")` are the same type in every caller.
pub const geometry = @import("geometry");
pub const pacer = @import("pacer");

// @cImport was removed from this Zig toolchain (0.17-dev); build.zig
// generates this module via std.Build.addTranslateC(src/sqlite3_shim.h)
// instead and wires it in under the name "sqlite3_c".
pub const c = @import("sqlite3_c");

/// -Dtarget-host tuning constants (build.zig). Host name / L3 size only --
/// never a dispatch switch on instruction set. The hot-path code below stays
/// one portable @Vector implementation lowered per host by Zig/LLVM (Host
/// Law); this is used only to size the suggested cell-bank capacity.
const build_config = @import("build_config");

/// SIMD scan lane width. 32 x u8 = one AVX2 YMM register's worth on either
/// host; Zig/LLVM lowers it to whatever the actual target supports.
const SCAN_LANES = 32;

/// Cell-bank slot count that keeps the active buffer within this host's L3
/// (build_config.l3_bytes, from -Dtarget-host): 8MiB / 17,408B =~ 481 cells
/// on pop, 16MiB / 17,408B =~ 963 cells on Brandys. A caller isn't required
/// to use this -- SidecarEngine.init takes max_slots directly -- but it's
/// the honest default for "stay resident in this host's L3."
pub const SUGGESTED_MAX_SLOTS_FOR_L3: u64 = build_config.l3_bytes / geometry.CELL_BYTES;

pub const SidecarEngine = struct {
    allocator: std.mem.Allocator,
    /// Contiguous, cache-aligned hot L1/L2 active cell buffer.
    cells: []align(64) geometry.Cell,
    /// One byte per slot, mirroring pacer.SlotState -- contiguous by
    /// construction so countByState can actually vectorize over it.
    ///
    /// Plain u8, not std.atomic.Value(u8): provably no same-byte
    /// write/write race under the state machine this module actually
    /// drives -- the drain worker only ever transitions a byte
    /// committed -> released, and only after the hot-path writer that owns
    /// that slot has already moved on (a slot's status is only ever
    /// written by one side at a time across its lifecycle: submit/close on
    /// the hot path, then drain). countByState() reading concurrently with
    /// a worker write is a read/write race in the strict memory-model
    /// sense (no compiler barrier), though byte-sized loads/stores are
    /// atomic at the ISA level on both target hosts. This is a testbed
    /// prototype scoped to that reasoning -- promote to
    /// std.atomic.Value(u8) before this backs anything production-critical.
    status: []u8,
    cell_pacer: pacer.CellSlotPacer,

    pub fn init(allocator: std.mem.Allocator, max_slots: u64) !SidecarEngine {
        const cells = try allocator.alignedAlloc(geometry.Cell, std.mem.Alignment.@"64", @intCast(max_slots));
        errdefer allocator.free(cells);
        @memset(std.mem.sliceAsBytes(cells), 0);

        const status = try allocator.alloc(u8, @intCast(max_slots));
        errdefer allocator.free(status);
        @memset(status, @intFromEnum(pacer.SlotState.unreserved));

        const cell_pacer = try pacer.CellSlotPacer.init(allocator, max_slots);

        return .{
            .allocator = allocator,
            .cells = cells,
            .status = status,
            .cell_pacer = cell_pacer,
        };
    }

    pub fn deinit(self: *SidecarEngine) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.status);
        self.cell_pacer.deinit();
    }

    /// Hot path. Grabs a lock-free slot lease, writes the header + payload
    /// directly into the pre-allocated contiguous cell buffer, and marks
    /// the slot's status byte `.claimed`. No allocation, no SQLite.
    pub fn submitTransaction(
        self: *SidecarEngine,
        identity: pacer.WriterIdentity,
        header: geometry.BytecodeHeader,
        payload: []const u8,
        now_ms: i64,
    ) !u64 {
        const lease = try self.cell_pacer.grabNextCellSlot(identity, now_ms);
        const idx: usize = @intCast(lease.slot_id - self.cell_pacer.base_slot);

        self.cells[idx].header = header;
        @memset(&self.cells[idx].semantic_payload, 0);
        const n = @min(payload.len, geometry.SEMANTIC_PAYLOAD_BYTES);
        @memcpy(self.cells[idx].semantic_payload[0..n], payload[0..n]);

        self.status[idx] = @intFromEnum(pacer.SlotState.claimed);
        return lease.slot_id;
    }

    /// Closes a transaction: commits the pacer lease and flips the slot's
    /// status byte to `.committed`, making it eligible for the next drain.
    pub fn closeTransaction(self: *SidecarEngine, slot_id: u64, identity: pacer.WriterIdentity) !void {
        try self.cell_pacer.commitCellSlot(slot_id, identity);
        const idx: usize = @intCast(slot_id - self.cell_pacer.base_slot);
        self.status[idx] = @intFromEnum(pacer.SlotState.committed);
    }

    /// Portable-@Vector scan over the contiguous status side-array. Counts
    /// how many in-flight slots are in `state` without touching the
    /// 17,408B-strided cell headers at all.
    pub fn countByState(self: *const SidecarEngine, state: pacer.SlotState) usize {
        const V = @Vector(SCAN_LANES, u8);
        const target: V = @splat(@intFromEnum(state));

        var total: usize = 0;
        var i: usize = 0;
        const len = self.status.len;
        while (i + SCAN_LANES <= len) : (i += SCAN_LANES) {
            const chunk: V = self.status[i..][0..SCAN_LANES].*;
            const eq = chunk == target;
            total += std.simd.countTrues(eq);
        }
        while (i < len) : (i += 1) {
            if (self.status[i] == @intFromEnum(state)) total += 1;
        }
        return total;
    }

    /// One synchronous drain pass: flushes every `.committed` slot into
    /// SQLite's `sidecar_records` table, then marks it `.released`. Kept
    /// separate from the worker loop so callers (and tests) can drive it
    /// deterministically instead of racing a live thread.
    pub fn drainOnce(self: *SidecarEngine, db: *c.sqlite3) !usize {
        var drained: usize = 0;
        for (self.status, 0..) |*st, idx| {
            if (st.* != @intFromEnum(pacer.SlotState.committed)) continue;
            const slot_id = self.cell_pacer.base_slot + idx;
            try insertRecord(db, slot_id, &self.cells[idx]);
            st.* = @intFromEnum(pacer.SlotState.released);
            drained += 1;
        }
        return drained;
    }

    /// Background worker: the real production entry point. Polls
    /// drainOnce off the hot path until `stop` is set. Runtime callers use
    /// this; tests call drainOnce directly for determinism. `io` is passed
    /// through explicitly (std.Thread.sleep no longer exists in this Zig
    /// toolchain -- sleeping now goes through std.Io, which requires an Io
    /// instance; callers pass std.testing.io in tests or init.io from
    /// std.process.Init in real entry points).
    pub fn startDrainWorker(
        self: *SidecarEngine,
        db: *c.sqlite3,
        io: std.Io,
        poll_interval_ms: u64,
        stop: *std.atomic.Value(bool),
    ) !std.Thread {
        return std.Thread.spawn(.{}, drainWorkerLoop, .{ self, db, io, poll_interval_ms, stop });
    }

    fn drainWorkerLoop(self: *SidecarEngine, db: *c.sqlite3, io: std.Io, poll_interval_ms: u64, stop: *std.atomic.Value(bool)) void {
        while (!stop.load(.acquire)) {
            _ = self.drainOnce(db) catch {};
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(poll_interval_ms)), .awake) catch return;
        }
    }
};

/// Opens (creating if needed) the sidecar SQLite database and its cold
/// storage table. The only place a raw SQL string appears in this module.
pub fn openSidecarDb(path: [:0]const u8) !*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path.ptr, &db) != c.SQLITE_OK or db == null) {
        return error.SqliteOpenFailed;
    }
    errdefer _ = c.sqlite3_close(db);

    const create_sql =
        \\CREATE TABLE IF NOT EXISTS sidecar_records (
        \\  slot_id INTEGER PRIMARY KEY,
        \\  opcode INTEGER NOT NULL,
        \\  subject_id BLOB NOT NULL,
        \\  predicate_op BLOB NOT NULL,
        \\  target_val BLOB NOT NULL,
        \\  provenance_flags INTEGER NOT NULL,
        \\  payload BLOB NOT NULL
        \\);
    ;
    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, create_sql, null, null, &errmsg) != c.SQLITE_OK) {
        if (errmsg != null) c.sqlite3_free(errmsg);
        return error.SqliteExecFailed;
    }
    return db.?;
}

pub fn closeSidecarDb(db: *c.sqlite3) void {
    _ = c.sqlite3_close(db);
}

const SQLITE_TRANSIENT: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));

fn insertRecord(db: *c.sqlite3, slot_id: u64, cell: *const geometry.Cell) !void {
    const sql = "INSERT OR REPLACE INTO sidecar_records " ++
        "(slot_id, opcode, subject_id, predicate_op, target_val, provenance_flags, payload) " ++
        "VALUES (?, ?, ?, ?, ?, ?, ?)";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(slot_id));
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(cell.header.opcode));
    _ = c.sqlite3_bind_blob(stmt, 3, &cell.header.subject_id, 16, SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_blob(stmt, 4, &cell.header.predicate_op, 16, SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_blob(stmt, 5, &cell.header.target_val, 16, SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_int64(stmt, 6, @intCast(cell.header.provenance_flags));
    _ = c.sqlite3_bind_blob(stmt, 7, &cell.semantic_payload, geometry.SEMANTIC_PAYLOAD_BYTES, SQLITE_TRANSIENT);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.SqliteStepFailed;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

test "Invariant A-1/A-2 hold for the sidecar's active cell buffer" {
    try std.testing.expectEqual(@as(usize, 17408), @sizeOf(geometry.Cell));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(geometry.BytecodeHeader));
}

test "-Dtarget-host build_config feeds a real, checkable L3-sizing constant" {
    try std.testing.expect(build_config.l3_bytes > 0);
    try std.testing.expectEqual(
        build_config.l3_bytes / geometry.CELL_BYTES,
        SUGGESTED_MAX_SLOTS_FOR_L3,
    );
    // Default is "pop" (8MiB L3) unless -Dtarget-host=brandys was passed.
    try std.testing.expect(std.mem.eql(u8, build_config.host_name, "pop") or
        std.mem.eql(u8, build_config.host_name, "brandys"));
}

test "submitTransaction: hot path writes header+payload without touching SQLite" {
    var engine = try SidecarEngine.init(std.testing.allocator, 8);
    defer engine.deinit();

    const identity = pacer.WriterIdentity.init("human_researcher", "sidecar_test", 1, 1);
    const header = geometry.BytecodeHeader{
        .opcode = 1001,
        .subject_id = @splat(0),
        .predicate_op = @splat(0),
        .target_val = @splat(0),
        .provenance_flags = 0,
    };

    const slot0 = try engine.submitTransaction(identity, header, "hot path payload", 1000);
    const slot1 = try engine.submitTransaction(identity, header, "second payload", 1001);

    try std.testing.expectEqual(@as(u64, 0), slot0);
    try std.testing.expectEqual(@as(u64, 1), slot1);
    try std.testing.expectEqual(@as(usize, 2), engine.countByState(.claimed));
    try std.testing.expectEqual(@as(usize, 0), engine.countByState(.committed));

    try std.testing.expectEqualStrings(
        "hot path payload",
        engine.cells[0].semantic_payload[0.."hot path payload".len],
    );
}

test "closeTransaction: commit flips pacer lease and status byte together" {
    var engine = try SidecarEngine.init(std.testing.allocator, 4);
    defer engine.deinit();

    const identity = pacer.WriterIdentity.init("human_researcher", "sidecar_test", 2, 1);
    const header = geometry.BytecodeHeader{
        .opcode = 1001,
        .subject_id = @splat(0),
        .predicate_op = @splat(0),
        .target_val = @splat(0),
        .provenance_flags = 0,
    };

    const slot = try engine.submitTransaction(identity, header, "close me", 2000);
    try std.testing.expectEqual(@as(usize, 1), engine.countByState(.claimed));

    try engine.closeTransaction(slot, identity);
    try std.testing.expectEqual(@as(usize, 0), engine.countByState(.claimed));
    try std.testing.expectEqual(@as(usize, 1), engine.countByState(.committed));

    // Wrong owner must be refused (pacer.zig's own contract, exercised
    // end-to-end through the sidecar).
    const other = pacer.WriterIdentity.init("human_researcher", "sidecar_test", 99, 1);
    const slot2 = try engine.submitTransaction(identity, header, "second", 2001);
    try std.testing.expectError(error.OwnerMismatch, engine.closeTransaction(slot2, other));
}

test "countByState: SIMD scan is correct across a lane boundary (33 slots, 32-lane width)" {
    var engine = try SidecarEngine.init(std.testing.allocator, 33);
    defer engine.deinit();

    const identity = pacer.WriterIdentity.init("human_researcher", "sidecar_test", 3, 1);
    const header = geometry.BytecodeHeader{
        .opcode = 1001,
        .subject_id = @splat(0),
        .predicate_op = @splat(0),
        .target_val = @splat(0),
        .provenance_flags = 0,
    };

    var i: usize = 0;
    while (i < 33) : (i += 1) {
        _ = try engine.submitTransaction(identity, header, "x", 3000);
    }
    try std.testing.expectEqual(@as(usize, 33), engine.countByState(.claimed));
    try std.testing.expectEqual(@as(usize, 0), engine.countByState(.unreserved));
}

test "drainOnce: cold path flushes committed slots to a real SQLite table and releases them" {
    var engine = try SidecarEngine.init(std.testing.allocator, 4);
    defer engine.deinit();

    const identity = pacer.WriterIdentity.init("human_researcher", "sidecar_test", 4, 1);
    const header = geometry.BytecodeHeader{
        .opcode = 1001,
        .subject_id = @splat('A'),
        .predicate_op = @splat('B'),
        .target_val = @splat('C'),
        .provenance_flags = 0xABCD,
    };

    const slot = try engine.submitTransaction(identity, header, "drain payload", 4000);
    try engine.closeTransaction(slot, identity);

    const tmp_path = "/tmp/tot_hybrid_sidecar_test.sqlite3";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_path) catch {};

    const db = try openSidecarDb(tmp_path);
    defer closeSidecarDb(db);

    const drained = try engine.drainOnce(db);
    try std.testing.expectEqual(@as(usize, 1), drained);
    try std.testing.expectEqual(@as(usize, 0), engine.countByState(.committed));
    try std.testing.expectEqual(@as(usize, 1), engine.countByState(.released));

    // Prove it actually landed in SQLite, independent of the sidecar's own
    // in-memory state -- a fresh query against the real database file.
    const select_sql = "SELECT opcode, provenance_flags FROM sidecar_records WHERE slot_id = ?";
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, select_sql, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(slot));
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 1001), c.sqlite3_column_int64(stmt, 0));
    try std.testing.expectEqual(@as(i64, 0xABCD), c.sqlite3_column_int64(stmt, 1));
}

test "background drain worker: real thread drains a committed slot off the hot path" {
    var engine = try SidecarEngine.init(std.testing.allocator, 4);
    defer engine.deinit();

    const identity = pacer.WriterIdentity.init("human_researcher", "sidecar_test", 5, 1);
    const header = geometry.BytecodeHeader{
        .opcode = 1001,
        .subject_id = @splat(0),
        .predicate_op = @splat(0),
        .target_val = @splat(0),
        .provenance_flags = 0,
    };
    const slot = try engine.submitTransaction(identity, header, "worker payload", 5000);
    try engine.closeTransaction(slot, identity);

    const tmp_path = "/tmp/tot_hybrid_sidecar_worker_test.sqlite3";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_path) catch {};

    const db = try openSidecarDb(tmp_path);
    defer closeSidecarDb(db);

    var stop = std.atomic.Value(bool).init(false);
    var worker = try engine.startDrainWorker(db, std.testing.io, 5, &stop);

    var attempts: usize = 0;
    while (engine.countByState(.released) == 0 and attempts < 200) : (attempts += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch break;
    }
    stop.store(true, .release);
    worker.join();

    try std.testing.expectEqual(@as(usize, 1), engine.countByState(.released));
}

// ── Gegenrede: is "sidecar AFTER commit" actually ordered? ────────────────────
//
// Every existing test in this module submits and closes its slot BEFORE
// spawning the drain worker, so none of them ever has a writer and the drain
// worker live at the same time -- the exact overlap production runs in. This
// one does.
//
// The claim under test is not the same-byte write/write race the `status`
// field comment already reasons about. It is cross-object ordering:
//
//   submitTransaction:  cells[idx].header = ...;  @memcpy(payload)   (object A)
//                       status[idx] = .claimed                       (object B)
//   closeTransaction:   status[idx] = .committed                     (object B)
//   drainOnce (thread): reads status[idx]                            (object B)
//                       reads cells[idx] and persists it             (object A)
//
// Nothing publishes A before B. The status stores are plain, non-atomic
// stores to a separate allocation from `cells`, and `drainOnce` performs a
// plain load with no acquire. `pacer.commitCellSlot` does carry a
// `.release`, but it is on `committed_count`, which `drainOnce` never reads,
// so it is paired with no acquire and establishes no happens-before edge to
// this thread. "byte-sized stores are atomic at the ISA level" is a statement
// about atomicity, not ordering, and x86-TSO constrains the hardware, not the
// compiler's freedom to sink a non-atomic store to `status` past a memcpy
// into `cells`.
//
// Run it instrumented:  zig build test-sqlite-sidecar-tsan
test "Gegenrede: writer and drain worker overlap (run under -fsanitize-thread)" {
    var engine = try SidecarEngine.init(std.testing.allocator, 256);
    defer engine.deinit();

    const tmp_path = "/tmp/tot_hybrid_sidecar_race_test.sqlite3";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_path) catch {};
    const db = try openSidecarDb(tmp_path);
    defer closeSidecarDb(db);

    var stop = std.atomic.Value(bool).init(false);
    var worker = try engine.startDrainWorker(db, std.testing.io, 1, &stop);

    // Writer runs concurrently with the drain worker, which is the overlap
    // production has and no other test in this file creates.
    const identity = pacer.WriterIdentity.init("human_researcher", "sidecar_race", 5, 1);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const header = geometry.BytecodeHeader{
            .opcode = 1001,
            .subject_id = @splat(0),
            .predicate_op = @splat(0),
            .target_val = @splat(0),
            .provenance_flags = @intCast(i),
        };
        const slot = engine.submitTransaction(identity, header, "race payload", 5000) catch break;
        try engine.closeTransaction(slot, identity);
        // Hot-path reader racing the worker's `status[idx] = .released`.
        _ = engine.countByState(.committed);
    }

    stop.store(true, .release);
    worker.join();
}

// Header-equality was missing from the Gegenrede TSan test above: it only
// overlapped writer+drain. This test submits, closes, drains, then SELECTs
// opcode and provenance_flags and compares them to the header that was
// written. Fence A and atomic-status B are not applied here.
test "F12 gate: concurrent submit+drain must not observe a torn A-2 header" {
    const alloc = std.testing.allocator;
    const rounds: usize = 64;
    var engine = try SidecarEngine.init(alloc, rounds);
    defer engine.deinit();

    const Published = struct {
        slot_id: u64,
        opcode: u64,
        provenance_flags: u64,
    };
    const published = try alloc.alloc(Published, rounds);
    defer alloc.free(published);

    const tmp_path = "/tmp/tot_hybrid_sidecar_header_eq.sqlite3";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_path) catch {};
    const db = try openSidecarDb(tmp_path);
    defer closeSidecarDb(db);

    var stop = std.atomic.Value(bool).init(false);
    var worker = try engine.startDrainWorker(db, std.testing.io, 1, &stop);

    const identity = pacer.WriterIdentity.init("human_researcher", "header_eq", 5, 1);
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        const opcode: u64 = 1001 + i;
        const flags: u64 = 0xA2A2_0000 + i;
        const header = geometry.BytecodeHeader{
            .opcode = opcode,
            .subject_id = @splat(0),
            .predicate_op = @splat(0),
            .target_val = @splat(0),
            .provenance_flags = flags,
        };
        const slot = try engine.submitTransaction(identity, header, "header eq payload", 6000);
        try engine.closeTransaction(slot, identity);
        published[i] = .{ .slot_id = slot, .opcode = opcode, .provenance_flags = flags };
    }

    var settle: usize = 0;
    while (settle < 200 and engine.countByState(.committed) > 0) : (settle += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch break;
    }
    stop.store(true, .release);
    worker.join();

    const select_sql = "SELECT opcode, provenance_flags FROM sidecar_records WHERE slot_id = ?";
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, select_sql, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);

    var rows_found: usize = 0;
    var torn: usize = 0;
    i = 0;
    while (i < rounds) : (i += 1) {
        const p = published[i];
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(p.slot_id));
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) continue;
        rows_found += 1;
        const got_opcode: i64 = c.sqlite3_column_int64(stmt, 0);
        const got_flags: i64 = c.sqlite3_column_int64(stmt, 1);
        if (got_opcode != @as(i64, @intCast(p.opcode)) or got_flags != @as(i64, @intCast(p.provenance_flags))) {
            torn += 1;
        }
    }

    std.debug.print(
        "\n[HEADER_EQ] submitted={d} rows={d} torn={d}\n",
        .{ rounds, rows_found, torn },
    );
    try std.testing.expect(rows_found > 0);
    try std.testing.expectEqual(@as(usize, 0), torn);
}
