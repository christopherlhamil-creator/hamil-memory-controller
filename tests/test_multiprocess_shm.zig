//! Multi-Process Shared Memory Engine & IPC Benchmark
//!
//! Subsystem: tot_hybrid/tests/test_multiprocess_shm.zig
//! Directive: Council Arena -- Seat 0 (council/claude) Multi-Process Shared
//! Memory Engine & IPC Benchmark
//!
//! Spawns 4 real, distinct OS child processes (via `std.process.Child`,
//! never threads) that concurrently lease and write 17,408-byte `Cell` slots
//! into a POSIX `/dev/shm` `MAP.SHARED` `ipc_ring.SharedCellRing`, arbitrated
//! by an explicit atomic compare-and-swap lease (Arm A). While they write, a
//! reader thread in THIS process continuously drains the ring and verifies
//! seqlock sequence monotonicity: every ticket it observes must be strictly
//! greater than the last, must recover the exact ticket that was assigned to
//! it (not a torn or stale read), and must come from more than one distinct
//! OS pid (proof this is genuinely multi-process, not one process wearing 4
//! hats).
//!
//! Arm B repeats the same 4-process, N-op workload against a single shared
//! SQLite database file (WAL journal mode + `sqlite3_busy_timeout`, the
//! idiomatic way to let independent OS processes serialize writes to one
//! SQLite file), so the two arms' throughput and latency are directly
//! comparable end-to-end proof, not a synthetic microbenchmark.
//!
//! Run: zig build test-multiprocess-shm
//!
//! Toolchain: Zig 0.17.

const std = @import("std");
const ipc_ring = @import("ipc_ring");
const worker_path_mod = @import("shm_worker_path");

// `ipc_ring.zig` resolves its own `geometry` dependency via a file-relative
// `@import("geometry.zig")`, which subsumes src/geometry.zig into the
// `ipc_ring` module itself; a sibling `addImport("geometry", geometry)` on
// this module would collide with that (see the identical, previously-hit
// issue documented in tests/test_spoke_vs_monolith_bench.zig). Cell is used
// via `ipc_ring`'s own re-export instead of a second geometry import.
const Cell = ipc_ring.IpcCellMessage;

const WORKER_PATH: []const u8 = worker_path_mod.path;

const ShmRing = ipc_ring.SharedCellRing(ipc_ring.DEFAULT_SHM_RING_CAPACITY);

const NUM_AGENTS: usize = 4;
// Kept comfortably below `ipc_ring.DEFAULT_SHM_RING_CAPACITY` (128) so the
// single verifying reader below can NEVER have an entry evicted out from
// under it by wraparound before it gets to read it -- this test's job is to
// prove multi-process CAS-lease correctness and benchmark throughput, not
// re-exercise bounded-ring eviction semantics (that's already covered
// in-process by `SharedCellRing concurrent CAS lease arbitration` and
// `LockFreeRingBuffer wraparound and lagging reader detection` in
// src/ipc_ring.zig). Total = 96 writes, 25% headroom under capacity.
const NUM_OPS_PER_AGENT: u64 = 24;

// ── Minimal SQLite3 C ABI bindings (parent side: schema + final row-count
// verification -- mirrors tests/test_sqlite_sidecar_bench.zig) ─────────────

const sqlite3 = anyopaque;
const sqlite3_stmt = anyopaque;
const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
const SQLITE_OPEN_CREATE: c_int = 0x00000004;
const SQLITE_OPEN_FULLMUTEX: c_int = 0x00010000;

extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close(db: ?*sqlite3) c_int;
extern "c" fn sqlite3_exec(
    db: ?*sqlite3,
    sql: [*:0]const u8,
    callback: ?*anyopaque,
    arg: ?*anyopaque,
    errmsg: ?*?[*:0]u8,
) c_int;
extern "c" fn sqlite3_prepare_v2(
    db: ?*sqlite3,
    zSql: [*:0]const u8,
    nByte: c_int,
    ppStmt: *?*sqlite3_stmt,
    pzTail: ?*[*:0]const u8,
) c_int;
extern "c" fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
extern "c" fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
extern "c" fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, col: c_int) i64;
extern "c" fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) c_int;

// ── High-Resolution Linux Monotonic Clock ────────────────────────────────────

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn unlinkQuiet(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn isTermSuccess(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

// ── Reader: continuously drains the ring, verifies seqlock monotonicity ─────

const MAX_DISTINCT_PIDS: usize = NUM_AGENTS * 2;

const ReaderCtx = struct {
    ring: ShmRing,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    consumed: usize = 0,
    last_ticket: ?u64 = null,
    monotonic_violation: bool = false,
    torn_violation: bool = false,
    distinct_pids: [MAX_DISTINCT_PIDS]u64 = @splat(0),
    distinct_pid_count: usize = 0,
    distinct_agents_mask: u8 = 0,
};

fn verifyCell(ctx: *ReaderCtx, cell: Cell) void {
    const ticket = cell.header.opcode;

    if (ctx.last_ticket) |last| {
        if (ticket <= last) ctx.monotonic_violation = true;
    }
    ctx.last_ticket = ticket;

    const expected_byte: u8 = @truncate(ticket);
    if (cell.semantic_payload[0] != expected_byte or
        cell.semantic_payload[cell.semantic_payload.len - 1] != expected_byte)
    {
        ctx.torn_violation = true;
    }

    const agent_id: u32 = @truncate(std.mem.readInt(u64, cell.header.subject_id[0..8], .little));
    if (agent_id < 8) ctx.distinct_agents_mask |= (@as(u8, 1) << @intCast(agent_id));

    const pid = std.mem.readInt(u64, cell.header.target_val[0..8], .little);
    var found = false;
    for (ctx.distinct_pids[0..ctx.distinct_pid_count]) |p| {
        if (p == pid) {
            found = true;
            break;
        }
    }
    if (!found and ctx.distinct_pid_count < ctx.distinct_pids.len) {
        ctx.distinct_pids[ctx.distinct_pid_count] = pid;
        ctx.distinct_pid_count += 1;
    }

    ctx.consumed += 1;
}

fn readerLoop(ctx: *ReaderCtx) void {
    var cursor: u64 = 0;

    while (!ctx.stop.load(.acquire)) {
        const maybe_cell = ctx.ring.tryReadNext(&cursor) catch |err| blk: {
            switch (err) {
                ipc_ring.IpcError.LaggingReader => {
                    const cur = ctx.ring.getAllocCursor();
                    cursor = if (cur > ShmRing.Capacity) cur - ShmRing.Capacity / 2 else 0;
                },
                else => {},
            }
            break :blk null;
        };
        const cell = maybe_cell orelse {
            std.atomic.spinLoopHint();
            continue;
        };
        verifyCell(ctx, cell);
    }

    // Drain whatever's left after stop was requested -- writers finish
    // before `stop` is set, so this catches the tail of the ring.
    while (true) {
        const maybe_cell = ctx.ring.tryReadNext(&cursor) catch break;
        const cell = maybe_cell orelse break;
        verifyCell(ctx, cell);
    }
}

// ── Worker process spawning ──────────────────────────────────────────────────

fn spawnWorker(
    io: std.Io,
    mode: []const u8,
    target_path: []const u8,
    agent_id: usize,
    num_ops: u64,
    result_path: []const u8,
) !std.process.Child {
    var agent_buf: [8]u8 = undefined;
    const agent_str = try std.fmt.bufPrint(&agent_buf, "{d}", .{agent_id});
    var ops_buf: [24]u8 = undefined;
    const ops_str = try std.fmt.bufPrint(&ops_buf, "{d}", .{num_ops});

    return std.process.spawn(io, .{
        .argv = &[_][]const u8{ WORKER_PATH, mode, target_path, agent_str, ops_str, result_path },
    });
}

const WorkerResult = struct { ops: u64, elapsed_ns: u64 };

fn readResultFile(io: std.Io, path: []const u8) !WorkerResult {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [256]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    const line = (try file_reader.interface.takeDelimiter('\n')) orelse return error.EmptyResultFile;

    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const ops_str = it.next() orelse return error.MalformedResultFile;
    const elapsed_str = it.next() orelse return error.MalformedResultFile;

    return .{
        .ops = try std.fmt.parseInt(u64, ops_str, 10),
        .elapsed_ns = try std.fmt.parseInt(u64, elapsed_str, 10),
    };
}

// ── The Directive ─────────────────────────────────────────────────────────

test "Seat 0: 4 OS child processes CAS-lease a /dev/shm ring vs. 4 OS child processes writing a shared SQLite file" {
    const io = std.testing.io;
    const pid = std.os.linux.getpid();
    _ = std.c.mkdir("run", 0o755);

    var shm_path_buf: [64]u8 = undefined;
    const shm_path = try std.fmt.bufPrint(&shm_path_buf, "/dev/shm/tot_council_shm_{d}.bin", .{pid});
    defer ipc_ring.SharedMemoryRegion.unlinkPath(io, shm_path);

    var sqlite_path_buf: [64]u8 = undefined;
    const sqlite_path = try std.fmt.bufPrint(&sqlite_path_buf, "run/tot_council_shm_bench_{d}.db", .{pid});
    var sqlite_wal_buf: [72]u8 = undefined;
    const sqlite_wal_path = try std.fmt.bufPrint(&sqlite_wal_buf, "{s}-wal", .{sqlite_path});
    var sqlite_shm_buf: [72]u8 = undefined;
    const sqlite_shm_path = try std.fmt.bufPrint(&sqlite_shm_buf, "{s}-shm", .{sqlite_path});
    defer {
        unlinkQuiet(io, sqlite_path);
        unlinkQuiet(io, sqlite_wal_path);
        unlinkQuiet(io, sqlite_shm_path);
    }

    var shm_result_bufs: [NUM_AGENTS][96]u8 = undefined;
    var shm_result_paths: [NUM_AGENTS][]const u8 = undefined;
    var sqlite_result_bufs: [NUM_AGENTS][96]u8 = undefined;
    var sqlite_result_paths: [NUM_AGENTS][]const u8 = undefined;
    for (0..NUM_AGENTS) |i| {
        shm_result_paths[i] = try std.fmt.bufPrint(&shm_result_bufs[i], "run/tot_shm_result_{d}_{d}.txt", .{ pid, i });
        sqlite_result_paths[i] = try std.fmt.bufPrint(&sqlite_result_bufs[i], "run/tot_sqlite_result_{d}_{d}.txt", .{ pid, i });
    }
    defer for (0..NUM_AGENTS) |i| {
        unlinkQuiet(io, shm_result_paths[i]);
        unlinkQuiet(io, sqlite_result_paths[i]);
    };

    std.debug.print("\n{s}\n", .{"========================================================================================"});
    std.debug.print("  SEAT 0: MULTI-PROCESS SHARED MEMORY ENGINE vs. SHARED SQLITE -- {d} OS CHILD PROCESSES\n", .{NUM_AGENTS});
    std.debug.print("{s}\n\n", .{"========================================================================================"});

    // ══════════════════════════════════════════════════════════════════════
    // ARM A: POSIX /dev/shm MAP.SHARED ipc_ring.SharedCellRing (atomic CAS lease)
    // ══════════════════════════════════════════════════════════════════════

    var region = try ipc_ring.SharedMemoryRegion.open(io, shm_path, ShmRing.TOTAL_BYTES, true);
    defer region.close(io);
    const ring = ShmRing.attach(region.bytes, true);

    var reader_ctx = ReaderCtx{ .ring = ring };
    var reader_thread = try std.Thread.spawn(.{}, readerLoop, .{&reader_ctx});

    var shm_children: [NUM_AGENTS]std.process.Child = undefined;
    const t_shm_start = nowNs();
    for (0..NUM_AGENTS) |i| {
        shm_children[i] = try spawnWorker(io, "shm", shm_path, i, NUM_OPS_PER_AGENT, shm_result_paths[i]);
    }
    for (0..NUM_AGENTS) |i| {
        const term = try shm_children[i].wait(io);
        try std.testing.expect(isTermSuccess(term));
    }
    const t_shm_end = nowNs();

    const total_shm_ops: u64 = NUM_AGENTS * NUM_OPS_PER_AGENT;

    var drain_spins: usize = 0;
    while (reader_ctx.consumed < total_shm_ops and drain_spins < 5_000_000) : (drain_spins += 1) {
        std.Thread.yield() catch {};
    }
    reader_ctx.stop.store(true, .release);
    reader_thread.join();

    try std.testing.expectEqual(total_shm_ops, ring.getAllocCursor());
    try std.testing.expect(!reader_ctx.monotonic_violation);
    try std.testing.expect(!reader_ctx.torn_violation);
    // Proof this was genuinely multi-process, not one process wearing 4 hats.
    try std.testing.expect(reader_ctx.distinct_pid_count >= 2);
    try std.testing.expectEqual(@as(u8, 0b1111), reader_ctx.distinct_agents_mask);
    try std.testing.expectEqual(total_shm_ops, @as(u64, reader_ctx.consumed));

    var shm_total_ops: u64 = 0;
    var shm_total_elapsed_ns: u64 = 0;
    for (0..NUM_AGENTS) |i| {
        const r = try readResultFile(io, shm_result_paths[i]);
        shm_total_ops += r.ops;
        shm_total_elapsed_ns += r.elapsed_ns;
    }
    try std.testing.expectEqual(total_shm_ops, shm_total_ops);

    const shm_wall_ns = t_shm_end - t_shm_start;
    const shm_throughput = @as(f64, @floatFromInt(shm_total_ops)) / (@as(f64, @floatFromInt(shm_wall_ns)) / 1e9);
    const shm_mean_latency_ns = @as(f64, @floatFromInt(shm_total_elapsed_ns)) / @as(f64, @floatFromInt(shm_total_ops));

    std.debug.print(
        "  [ARM A: /dev/shm SharedCellRing, atomic-CAS lease]  ops={d}  wall={d:.2}ms  throughput={d:.0} ops/s  mean_latency={d:.2}us  distinct_pids={d}  reader_consumed={d}  monotonic=OK  torn_reads=NONE\n",
        .{
            shm_total_ops,
            @as(f64, @floatFromInt(shm_wall_ns)) / 1e6,
            shm_throughput,
            shm_mean_latency_ns / 1e3,
            reader_ctx.distinct_pid_count,
            reader_ctx.consumed,
        },
    );

    // ══════════════════════════════════════════════════════════════════════
    // ARM B: shared SQLite database file, 4 OS processes, autocommit INSERTs
    // ══════════════════════════════════════════════════════════════════════

    unlinkQuiet(io, sqlite_path);
    unlinkQuiet(io, sqlite_wal_path);
    unlinkQuiet(io, sqlite_shm_path);

    var sqlite_path_z_buf: [80]u8 = undefined;
    const sqlite_path_z = try std.fmt.bufPrintSentinel(&sqlite_path_z_buf, "{s}", .{sqlite_path}, 0);

    {
        var db: ?*sqlite3 = null;
        const rc = sqlite3_open_v2(sqlite_path_z, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, null);
        try std.testing.expectEqual(SQLITE_OK, rc);
        defer _ = sqlite3_close(db);
        _ = sqlite3_busy_timeout(db, 30_000);
        _ = sqlite3_exec(db, "PRAGMA journal_mode = WAL;", null, null, null);
        _ = sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", null, null, null);
        _ = sqlite3_exec(db, "CREATE TABLE records (id INTEGER PRIMARY KEY, agent_id INTEGER, seq INTEGER, writer_pid INTEGER);", null, null, null);
    }

    var sqlite_children: [NUM_AGENTS]std.process.Child = undefined;
    const t_sqlite_start = nowNs();
    for (0..NUM_AGENTS) |i| {
        sqlite_children[i] = try spawnWorker(io, "sqlite", sqlite_path, i, NUM_OPS_PER_AGENT, sqlite_result_paths[i]);
    }
    for (0..NUM_AGENTS) |i| {
        const term = try sqlite_children[i].wait(io);
        try std.testing.expect(isTermSuccess(term));
    }
    const t_sqlite_end = nowNs();

    // Independently verify every row actually landed via a direct query --
    // not merely by trusting the children's self-reported op counts.
    var total_rows: i64 = 0;
    {
        var db: ?*sqlite3 = null;
        const rc = sqlite3_open_v2(sqlite_path_z, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, null);
        try std.testing.expectEqual(SQLITE_OK, rc);
        defer _ = sqlite3_close(db);

        var stmt: ?*sqlite3_stmt = null;
        const prc = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM records;", -1, &stmt, null);
        try std.testing.expectEqual(SQLITE_OK, prc);
        defer _ = sqlite3_finalize(stmt);
        const src = sqlite3_step(stmt);
        try std.testing.expectEqual(SQLITE_ROW, src);
        total_rows = sqlite3_column_int64(stmt, 0);
    }

    const total_sqlite_ops: u64 = NUM_AGENTS * NUM_OPS_PER_AGENT;
    try std.testing.expectEqual(@as(i64, @intCast(total_sqlite_ops)), total_rows);

    var sqlite_total_ops: u64 = 0;
    var sqlite_total_elapsed_ns: u64 = 0;
    for (0..NUM_AGENTS) |i| {
        const r = try readResultFile(io, sqlite_result_paths[i]);
        sqlite_total_ops += r.ops;
        sqlite_total_elapsed_ns += r.elapsed_ns;
    }
    try std.testing.expectEqual(total_sqlite_ops, sqlite_total_ops);

    const sqlite_wall_ns = t_sqlite_end - t_sqlite_start;
    const sqlite_throughput = @as(f64, @floatFromInt(sqlite_total_ops)) / (@as(f64, @floatFromInt(sqlite_wall_ns)) / 1e9);
    const sqlite_mean_latency_ns = @as(f64, @floatFromInt(sqlite_total_elapsed_ns)) / @as(f64, @floatFromInt(sqlite_total_ops));

    std.debug.print(
        "  [ARM B: shared SQLite file, {d} OS processes, WAL+busy_timeout]  ops={d}  wall={d:.2}ms  throughput={d:.0} ops/s  mean_latency={d:.2}us  verified_rows={d}\n",
        .{
            NUM_AGENTS,
            sqlite_total_ops,
            @as(f64, @floatFromInt(sqlite_wall_ns)) / 1e6,
            sqlite_throughput,
            sqlite_mean_latency_ns / 1e3,
            total_rows,
        },
    );

    std.debug.print("\n  SUMMARY: SharedCellRing throughput is {d:.1}x shared-SQLite throughput ({d:.0} vs {d:.0} ops/s)\n", .{
        shm_throughput / sqlite_throughput,
        shm_throughput,
        sqlite_throughput,
    });
    std.debug.print("{s}\n\n", .{"========================================================================================"});
}
