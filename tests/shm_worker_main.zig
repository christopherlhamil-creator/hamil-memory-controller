//! Multi-Process Benchmark Worker: one real OS process, spawned by
//! `tests/test_multiprocess_shm.zig` via `std.process.Child`, simulating one
//! concurrent council agent.
//!
//! Subsystem: tot_hybrid/tests/shm_worker_main.zig
//! Directive: Seat 0 -- Multi-Process Shared Memory Engine & IPC Benchmark
//!
//! Two arms, selected by argv[1]:
//!   - "shm":    attaches an already-created `ipc_ring.SharedCellRing` over
//!               a POSIX MAP.SHARED /dev/shm segment and performs `num_ops`
//!               lease-and-write calls (atomic CAS lease + seqlock commit).
//!   - "sqlite": opens an already-schema'd shared SQLite database file and
//!               performs `num_ops` autocommit INSERTs, relying on
//!               `sqlite3_busy_timeout` to serialize against the other
//!               worker processes' write locks on the same file.
//!
//! Every worker writes its own `<ops> <elapsed_ns>` result line to a private
//! result file (argv[5]) rather than through a pipe, so the parent test
//! process can `wait()` all four children first and read results after --
//! no pipe-buffer deadlock risk.
//!
//! argv: [mode] [target_path] [agent_id] [num_ops] [result_path]
//!
//! Toolchain: Zig 0.17.

const std = @import("std");
const ipc_ring = @import("ipc_ring");

const SHM_RING_CAPACITY = ipc_ring.DEFAULT_SHM_RING_CAPACITY;
const ShmRing = ipc_ring.SharedCellRing(SHM_RING_CAPACITY);

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// ── Minimal SQLite3 C ABI bindings (mirrors tests/test_sqlite_sidecar_bench.zig) ──

const sqlite3 = anyopaque;
const SQLITE_OK: c_int = 0;
const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
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
extern "c" fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) c_int;

fn writeResult(io: std.Io, path: []const u8, ops: u64, elapsed_ns: u64) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = false, .truncate = true });
    defer file.close(io);

    var line_buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "{d} {d}\n", .{ ops, elapsed_ns });

    var writer = file.writer(io, &.{});
    try writer.interface.writeAll(line);
    try writer.interface.flush();
}

fn runShmArm(io: std.Io, shm_path: []const u8, agent_id: u32, num_ops: u64, result_path: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, shm_path, .{ .mode = .read_write });
    defer file.close(io);

    const mapped = try std.posix.mmap(
        null,
        ShmRing.TOTAL_BYTES,
        std.posix.PROT{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );
    defer std.posix.munmap(mapped);

    const ring = ShmRing.attach(mapped, false);
    const pid: u64 = @intCast(std.os.linux.getpid());

    const t_start = nowNs();
    var i: u64 = 0;
    while (i < num_ops) : (i += 1) {
        _ = ring.leaseAndWrite(agent_id, pid);
    }
    const t_end = nowNs();

    try writeResult(io, result_path, num_ops, t_end - t_start);
}

fn runSqliteArm(io: std.Io, db_path: []const u8, agent_id: u32, num_ops: u64, result_path: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const db_path_z = try std.fmt.bufPrintSentinel(&path_buf, "{s}", .{db_path}, 0);

    var db: ?*sqlite3 = null;
    const rc = sqlite3_open_v2(db_path_z, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, null);
    if (rc != SQLITE_OK) return error.SqliteOpenFailed;
    defer _ = sqlite3_close(db);

    _ = sqlite3_busy_timeout(db, 30_000);

    const pid: u64 = @intCast(std.os.linux.getpid());

    const t_start = nowNs();
    var i: u64 = 0;
    while (i < num_ops) : (i += 1) {
        var sql_buf: [256]u8 = undefined;
        const sql_z = try std.fmt.bufPrintSentinel(
            &sql_buf,
            "INSERT INTO records (agent_id, seq, writer_pid) VALUES ({d}, {d}, {d});",
            .{ agent_id, i, pid },
            0,
        );
        var errmsg: ?[*:0]u8 = null;
        const insert_rc = sqlite3_exec(db, sql_z, null, null, &errmsg);
        if (insert_rc != SQLITE_OK) {
            return error.SqliteInsertFailed;
        }
    }
    const t_end = nowNs();

    try writeResult(io, result_path, num_ops, t_end - t_start);
}

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);

    _ = args_iter.next() orelse return error.MissingArgv0;
    const mode = args_iter.next() orelse return error.MissingMode;
    const target_path = args_iter.next() orelse return error.MissingTargetPath;
    const agent_id_str = args_iter.next() orelse return error.MissingAgentId;
    const num_ops_str = args_iter.next() orelse return error.MissingNumOps;
    const result_path = args_iter.next() orelse return error.MissingResultPath;

    const agent_id = try std.fmt.parseInt(u32, agent_id_str, 10);
    const num_ops = try std.fmt.parseInt(u64, num_ops_str, 10);

    if (std.mem.eql(u8, mode, "shm")) {
        try runShmArm(init.io, target_path, agent_id, num_ops, result_path);
    } else if (std.mem.eql(u8, mode, "sqlite")) {
        try runSqliteArm(init.io, target_path, agent_id, num_ops, result_path);
    } else {
        return error.UnknownMode;
    }
}
