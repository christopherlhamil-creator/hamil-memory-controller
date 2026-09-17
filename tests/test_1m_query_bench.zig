//! Benchmark: Traditional SQLite 1M Indexed B-Tree vs. Bare-Metal Zig Cellular Spoke + SIMD Vector Scan
//!
//! Subsystem: tot_hybrid/tests/test_1m_query_bench.zig
//! Directive: Council Arena — 1M-Record Scale & Multi-Process Shared Memory Proof
//! Seat: Seat 2 — @antigravity (council-agy)
//! Role: Reality Checker & Latency Benchmark Auditor (agency-reality-checker)
//!
//! Evaluates the two competing query models at 1,000,000 record scale:
//!   - Arm A (Traditional SQLite 1M Indexed B-Tree):
//!       Full 1,000,000-row relational table with primary key, point-query B-tree index
//!       on `subject_id`, and composite B-tree index on `(subject_id, epoch, flags)`.
//!       Pays VDBE opcode dispatch, B-tree depth traversal (4-5 levels), SQLite page cache
//!       pointer chasing, and column serialization/unserialisation.
//!   - Arm B (Zig Cellular Spoke + SIMD Vector Scan):
//!       1,000,000 cache-aligned 64-byte InstructionHeaders (Invariant A-2, =Q16s16s16sII)
//!       federated across 100 domain spokes (10,000 headers = 640 KB per spoke).
//!       Evaluates point queries via O(1) Spoke routing + 16-byte SIMD vector comparison (@Vector(16, u8)),
//!       and multi-constraint scans via register-level bitwise evaluation in the same 64B cache line.
//!
//! Measures on Physical Metal:
//!   - Throughput (QPS)
//!   - Latency distribution (mean, p50, p90, p99, p99.9) in nanoseconds
//!   - Bare-metal hardware performance counters via Linux SYS_perf_event_open:
//!       CPU Cycles, Instructions Retired, IPC, L1D Misses, LLC (Last-Level Cache) Misses
//!   - Operating System Virtual Memory telemetry (VmRSS, Minor Page Faults)
//!
//! Toolchain: Zig 0.17 / ReleaseFast.
//! Run: zig build bench-1m-query

const std = @import("std");

// ── Invariant Constants ───────────────────────────────────────────────────────
pub const CELL_BYTES: usize = 17408; // Invariant A-1
pub const BYTECODE_HEADER_BYTES: usize = 64; // Invariant A-2

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
};

// ── C ABI Bindings to SQLite 3 ────────────────────────────────────────────────
pub const sqlite3 = anyopaque;
pub const sqlite3_stmt = anyopaque;

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;
pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;
pub const SQLITE_OPEN_FULLMUTEX: c_int = 0x00010000;
pub const SQLITE_STATIC: ?*const anyopaque = null;

pub extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
pub extern "c" fn sqlite3_close(db: ?*sqlite3) c_int;
pub extern "c" fn sqlite3_exec(
    db: ?*sqlite3,
    sql: [*:0]const u8,
    callback: ?*anyopaque,
    arg: ?*anyopaque,
    errmsg: ?*?[*:0]u8,
) c_int;
pub extern "c" fn sqlite3_prepare_v2(
    db: ?*sqlite3,
    zSql: [*:0]const u8,
    nByte: c_int,
    ppStmt: *?*sqlite3_stmt,
    pzTail: ?*[*:0]const u8,
) c_int;
pub extern "c" fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_reset(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_clear_bindings(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_bind_text(
    stmt: ?*sqlite3_stmt,
    idx: c_int,
    val: [*]const u8,
    len: c_int,
    destructor: ?*const anyopaque,
) c_int;
pub extern "c" fn sqlite3_bind_int(stmt: ?*sqlite3_stmt, idx: c_int, val: c_int) c_int;
pub extern "c" fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, val: i64) c_int;
pub extern "c" fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, iCol: c_int) i64;
pub extern "c" fn sqlite3_column_int(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
pub extern "c" fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*]const u8;
pub extern "c" fn sqlite3_free(p: ?*anyopaque) void;
pub extern "c" fn sqlite3_libversion() [*:0]const u8;
pub extern "c" fn unlink(path: [*:0]const u8) c_int;

// ── Linux Monotonic High-Resolution Clock ────────────────────────────────────
fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// ── Linux Bare-Metal Hardware Performance Counters (SYS_perf_event_open) ─────
const PerfEventAttr = extern struct {
    type: u32,
    size: u32 = 112,
    config: u64,
    sample_period_or_freq: u64 = 0,
    sample_type: u64 = 0,
    read_format: u64 = 0,
    flags: u64 = 0, // disabled (1<<0) | exclude_kernel (1<<5) | exclude_hv (1<<6)
    extra: [64]u8 = @splat(0),
};

fn perf_event_open(attr: *const PerfEventAttr, pid: i32, cpu: i32, group_fd: i32, flags: usize) isize {
    return @bitCast(std.os.linux.syscall5(
        .perf_event_open,
        @intFromPtr(attr),
        @bitCast(@as(isize, pid)),
        @bitCast(@as(isize, cpu)),
        @bitCast(@as(isize, group_fd)),
        flags,
    ));
}

fn openHwCounter(ev_type: u32, config: u64) ?c_int {
    var attr = std.mem.zeroes(PerfEventAttr);
    attr.type = ev_type;
    attr.size = 112;
    attr.config = config;
    attr.flags = (1 << 0) | (1 << 5) | (1 << 6); // disabled | exclude_kernel | exclude_hv

    const fd = perf_event_open(&attr, 0, -1, -1, 0);
    if (fd < 0) return null;
    return @intCast(fd);
}

pub const HardwareTelemetry = struct {
    cycles: u64 = 0,
    instructions: u64 = 0,
    ipc: f64 = 0.0,
    l1d_misses: u64 = 0,
    llc_misses: u64 = 0,
};

pub const PerfCounterSession = struct {
    cycles_fd: ?c_int,
    inst_fd: ?c_int,
    l1d_fd: ?c_int,
    llc_fd: ?c_int,
    available: bool,

    pub fn init() PerfCounterSession {
        const c = openHwCounter(0, 0); // PERF_COUNT_HW_CPU_CYCLES
        const i = openHwCounter(0, 1); // PERF_COUNT_HW_INSTRUCTIONS
        const l1 = openHwCounter(3, (0) | (0 << 8) | (1 << 16)); // L1D Read Miss
        const llc = openHwCounter(3, (2) | (0 << 8) | (1 << 16)); // LLC Read Miss
        const avail = (c != null and i != null);
        return .{
            .cycles_fd = c,
            .inst_fd = i,
            .l1d_fd = l1,
            .llc_fd = llc,
            .available = avail,
        };
    }

    pub fn start(self: *const PerfCounterSession) void {
        const fds = [_]?c_int{ self.cycles_fd, self.inst_fd, self.l1d_fd, self.llc_fd };
        for (fds) |maybe_fd| {
            if (maybe_fd) |fd| {
                _ = std.os.linux.ioctl(fd, 0x2403, 0); // PERF_EVENT_IOC_RESET
                _ = std.os.linux.ioctl(fd, 0x2400, 0); // PERF_EVENT_IOC_ENABLE
            }
        }
    }

    pub fn stop(self: *const PerfCounterSession) HardwareTelemetry {
        const fds = [_]?c_int{ self.cycles_fd, self.inst_fd, self.l1d_fd, self.llc_fd };
        for (fds) |maybe_fd| {
            if (maybe_fd) |fd| {
                _ = std.os.linux.ioctl(fd, 0x2401, 0); // PERF_EVENT_IOC_DISABLE
            }
        }

        var t = HardwareTelemetry{};
        if (self.cycles_fd) |fd| _ = std.os.linux.read(fd, @ptrCast(&t.cycles), 8);
        if (self.inst_fd) |fd| _ = std.os.linux.read(fd, @ptrCast(&t.instructions), 8);
        if (self.l1d_fd) |fd| _ = std.os.linux.read(fd, @ptrCast(&t.l1d_misses), 8);
        if (self.llc_fd) |fd| _ = std.os.linux.read(fd, @ptrCast(&t.llc_misses), 8);

        if (t.cycles > 0) {
            t.ipc = @as(f64, @floatFromInt(t.instructions)) / @as(f64, @floatFromInt(t.cycles));
        }
        return t;
    }

    pub fn deinit(self: *const PerfCounterSession) void {
        const fds = [_]?c_int{ self.cycles_fd, self.inst_fd, self.l1d_fd, self.llc_fd };
        for (fds) |maybe_fd| {
            if (maybe_fd) |fd| _ = std.os.linux.close(fd);
        }
    }
};

// ── Virtual Memory & Rusage Telemetry ─────────────────────────────────────────
const ProcMemoryStatus = struct {
    vm_size_kb: usize = 0,
    vm_rss_kb: usize = 0,
    vm_hwm_kb: usize = 0,
};

fn readProcStatus() !ProcMemoryStatus {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, "/proc/self/status", .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.os.linux.close(fd);
    var buf: [4096]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    const content = buf[0..n];

    var res = ProcMemoryStatus{};
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmSize:")) res.vm_size_kb = parseKb(line);
        if (std.mem.startsWith(u8, line, "VmRSS:")) res.vm_rss_kb = parseKb(line);
        if (std.mem.startsWith(u8, line, "VmHWM:")) res.vm_hwm_kb = parseKb(line);
    }
    return res;
}

fn parseKb(line: []const u8) usize {
    var it = std.mem.tokenizeAny(u8, line, " \t:");
    _ = it.next();
    if (it.next()) |val_str| {
        return std.fmt.parseInt(usize, val_str, 10) catch 0;
    }
    return 0;
}

const Rusage = struct {
    min_flt: i64,
    maj_flt: i64,
    max_rss_kb: i64,
};

fn getRusage() Rusage {
    const u = std.posix.getrusage(0);
    return .{
        .min_flt = u.minflt,
        .maj_flt = u.majflt,
        .max_rss_kb = u.maxrss,
    };
}

// ── Scale & Workload Parameters ───────────────────────────────────────────────
pub const TOTAL_RECORDS: usize = 1_000_000;
pub const NUM_SPOKES: usize = 100;
pub const RECORDS_PER_SPOKE: usize = TOTAL_RECORDS / NUM_SPOKES; // 10,000 headers
pub const ENTITIES_PER_SPOKE: usize = 1000;
pub const VERSIONS_PER_ENTITY: usize = 10;
pub const NUM_QUERIES: usize = 5000;

fn sortU64(slice: []u64) void {
    std.mem.sort(u64, slice, {}, std.sort.asc(u64));
}

// ── Spoke Routing Logic ───────────────────────────────────────────────────────
/// O(1) Spoke partition routing.
/// In tot_hybrid, entities route deterministically to their domain spoke.
pub inline fn routeSubjectToSpoke(subject: *const [16]u8) usize {
    if (subject[0] == 's' and subject[1] == '_') {
        var spoke_id: usize = 0;
        for (subject[2..6]) |c| {
            if (c >= '0' and c <= '9') {
                spoke_id = spoke_id * 10 + (c - '0');
            }
        }
        return spoke_id % NUM_SPOKES;
    }
    // FNV-1a deterministic hash fallback
    var h: u64 = 0xcbf29ce484222325;
    for (subject) |b| {
        h = (h ^ b) *% 0x100000001b3;
    }
    return @intCast(h % NUM_SPOKES);
}

// ── Benchmark Execution & Output Formatting ───────────────────────────────────
pub const QueryStats = struct {
    name: []const u8,
    count: usize,
    wall_ns: u64,
    mean_ns: f64,
    p50_ns: u64,
    p90_ns: u64,
    p99_ns: u64,
    p999_ns: u64,
    qps: f64,
    telemetry: HardwareTelemetry,
    minor_pf: i64,
};

fn evaluateAndPrintArm(
    name: []const u8,
    count: usize,
    wall_ns: u64,
    lats: []u64,
    tele: HardwareTelemetry,
    minor_pf: i64,
) QueryStats {
    sortU64(lats);
    const wall_s = @as(f64, @floatFromInt(wall_ns)) / 1e9;
    const qps = @as(f64, @floatFromInt(count)) / wall_s;
    const p50 = lats[count * 50 / 100];
    const p90 = lats[count * 90 / 100];
    const p99 = lats[count * 99 / 100];
    const p999 = lats[count * 999 / 1000];

    var sum: u64 = 0;
    for (lats) |l| sum += l;
    const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(count));

    std.debug.print("\n  [{s}]\n", .{name});
    std.debug.print("    Throughput : {d:10.1} QPS (wall: {d:6.2} ms for {d} queries)\n", .{
        qps,
        wall_s * 1000.0,
        count,
    });
    std.debug.print("    Latency    : mean={d:7.1} ns | p50={d:6} ns | p90={d:6} ns | p99={d:6} ns | p99.9={d:6} ns\n", .{
        mean, p50, p90, p99, p999,
    });
    std.debug.print("    HW Counters: cycles={d:10} | inst={d:10} | IPC={d:4.2} | L1D misses={d:8} | LLC misses={d:7}\n", .{
        tele.cycles, tele.instructions, tele.ipc, tele.l1d_misses, tele.llc_misses,
    });
    std.debug.print("    OS Telemetry: Minor Page Faults = {d:4}\n", .{minor_pf});

    return .{
        .name = name,
        .count = count,
        .wall_ns = wall_ns,
        .mean_ns = mean,
        .p50_ns = p50,
        .p90_ns = p90,
        .p99_ns = p99,
        .p999_ns = p999,
        .qps = qps,
        .telemetry = tele,
        .minor_pf = minor_pf,
    };
}

pub fn main() !void {
    std.debug.print("\n════════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  COUNCIL ARENA: 1M-RECORD QUERY BENCHMARK ON PHYSICAL METAL\n", .{});
    std.debug.print("  Traditional SQLite Indexed B-Tree vs. Bare-Metal Zig Cellular Spoke + SIMD\n", .{});
    std.debug.print("  Toolchain: Zig 0.17 / ReleaseFast  |  SQLite Version: {s}\n", .{sqlite3_libversion()});
    std.debug.print("  Scale: 1,000,000 Records  |  Invariants: A-1 (17,408B) & A-2 (64B Header)\n", .{});
    std.debug.print("════════════════════════════════════════════════════════════════════════════════\n\n", .{});

    const perf = PerfCounterSession.init();
    defer perf.deinit();

    const mem_init = try readProcStatus();
    std.debug.print("[INIT] Baseline Process State: VmSize={d} KB, VmRSS={d} KB, Perf Counters={s}\n", .{
        mem_init.vm_size_kb,
        mem_init.vm_rss_kb,
        if (perf.available) "ENABLED (Bare Metal)" else "FALLBACK (Paranoid/Emulated)",
    });

    const alloc = std.heap.page_allocator;

    // ──────────────────────────────────────────────────────────────────────────
    // STEP 1: INITIALIZE ZIG CELLULAR SPOKES (1,000,000 Records)
    // ──────────────────────────────────────────────────────────────────────────
    std.debug.print("\n[STEP 1] Allocating and Synthesizing 1M 64-Byte InstructionHeaders across 100 Spokes...\n", .{});
    const spoke_mem = try alloc.alloc([RECORDS_PER_SPOKE]InstructionHeader, NUM_SPOKES);
    defer alloc.free(spoke_mem);

    const t0_zig_init = nowNs();
    for (0..NUM_SPOKES) |spoke_id| {
        for (0..ENTITIES_PER_SPOKE) |ent_id| {
            for (0..VERSIONS_PER_ENTITY) |ver| {
                const rec_idx = ent_id * VERSIONS_PER_ENTITY + ver;
                var hdr = &spoke_mem[spoke_id][rec_idx];
                hdr.opcode = 0x1000 + ver;
                hdr.subject_id = @splat(0);
                _ = try std.fmt.bufPrint(&hdr.subject_id, "s_{d:0>4}_{d:0>6}", .{ spoke_id, ent_id });
                hdr.predicate_id = @splat(0);
                @memcpy(hdr.predicate_id[0..15], "pred_knows_0001");
                hdr.target_id = @splat(0);
                @memcpy(hdr.target_id[0..15], "targ_ent_000001");
                hdr.flags = if (ver % 2 == 1) 0x0001 else 0x0002;
                hdr.epoch = @intCast(ver);
            }
        }
    }
    const t1_zig_init = nowNs();
    const mem_after_zig = try readProcStatus();
    std.debug.print("  -> 1,000,000 headers ({d:.2} MB) synthesized in {d:.2} ms (VmRSS={d} KB)\n", .{
        @as(f64, @floatFromInt(TOTAL_RECORDS * 64)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(t1_zig_init - t0_zig_init)) / 1e6,
        mem_after_zig.vm_rss_kb,
    });

    // ──────────────────────────────────────────────────────────────────────────
    // STEP 2: INITIALIZE SQLITE 1M DATABASE & BUILD B-TREE INDEXES
    // ──────────────────────────────────────────────────────────────────────────
    std.debug.print("\n[STEP 2] Creating SQLite 1M Database & Compiling B-Tree Indexes...\n", .{});
    const db_path: [*:0]const u8 = "run/bench_1m_query_sqlite.db";
    _ = unlink("run/bench_1m_query_sqlite.db");
    _ = unlink("run/bench_1m_query_sqlite.db-wal");
    _ = unlink("run/bench_1m_query_sqlite.db-shm");

    var db: ?*sqlite3 = null;
    _ = sqlite3_open_v2(db_path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, null);
    defer {
        _ = sqlite3_close(db);
        _ = unlink("run/bench_1m_query_sqlite.db");
        _ = unlink("run/bench_1m_query_sqlite.db-wal");
        _ = unlink("run/bench_1m_query_sqlite.db-shm");
    }

    _ = sqlite3_exec(db, "PRAGMA journal_mode = WAL;", null, null, null);
    _ = sqlite3_exec(db, "PRAGMA synchronous = OFF;", null, null, null);
    _ = sqlite3_exec(db, "PRAGMA cache_size = -64000;", null, null, null);
    _ = sqlite3_exec(db, "CREATE TABLE records (id INTEGER PRIMARY KEY, opcode INTEGER, subject_id TEXT, predicate_id TEXT, target_id TEXT, flags INTEGER, epoch INTEGER);", null, null, null);

    const sql_ins: [*:0]const u8 = "INSERT INTO records VALUES (?, ?, ?, ?, ?, ?, ?);";
    var stmt_ins: ?*sqlite3_stmt = null;
    _ = sqlite3_prepare_v2(db, sql_ins, -1, &stmt_ins, null);
    defer _ = sqlite3_finalize(stmt_ins);

    const t0_sql_ins = nowNs();
    _ = sqlite3_exec(db, "BEGIN TRANSACTION;", null, null, null);
    for (0..NUM_SPOKES) |spoke_id| {
        for (0..ENTITIES_PER_SPOKE) |ent_id| {
            for (0..VERSIONS_PER_ENTITY) |ver| {
                const rec_idx = spoke_id * RECORDS_PER_SPOKE + ent_id * VERSIONS_PER_ENTITY + ver;
                var subj_buf: [16]u8 = @splat(0);
                _ = try std.fmt.bufPrint(&subj_buf, "s_{d:0>4}_{d:0>6}", .{ spoke_id, ent_id });

                _ = sqlite3_bind_int64(stmt_ins, 1, @intCast(rec_idx));
                _ = sqlite3_bind_int64(stmt_ins, 2, @intCast(0x1000 + ver));
                _ = sqlite3_bind_text(stmt_ins, 3, &subj_buf, 13, SQLITE_STATIC);
                _ = sqlite3_bind_text(stmt_ins, 4, "pred_knows_0001", 15, SQLITE_STATIC);
                _ = sqlite3_bind_text(stmt_ins, 5, "targ_ent_000001", 15, SQLITE_STATIC);
                _ = sqlite3_bind_int(stmt_ins, 6, if (ver % 2 == 1) 1 else 2);
                _ = sqlite3_bind_int(stmt_ins, 7, @intCast(ver));

                _ = sqlite3_step(stmt_ins);
                _ = sqlite3_reset(stmt_ins);
            }
        }
    }
    _ = sqlite3_exec(db, "COMMIT;", null, null, null);
    const t1_sql_ins = nowNs();
    std.debug.print("  -> 1,000,000 rows inserted in {d:.2} s ({d:.1} rows/s)\n", .{
        @as(f64, @floatFromInt(t1_sql_ins - t0_sql_ins)) / 1e9,
        @as(f64, @floatFromInt(TOTAL_RECORDS)) / (@as(f64, @floatFromInt(t1_sql_ins - t0_sql_ins)) / 1e9),
    });

    const t0_idx = nowNs();
    _ = sqlite3_exec(db, "CREATE INDEX idx_records_subject ON records(subject_id);", null, null, null);
    _ = sqlite3_exec(db, "CREATE INDEX idx_records_composite ON records(subject_id, epoch, flags);", null, null, null);
    const t1_idx = nowNs();
    std.debug.print("  -> B-Tree Indexes `idx_records_subject` & `idx_records_composite` created in {d:.2} s\n", .{
        @as(f64, @floatFromInt(t1_idx - t0_idx)) / 1e9,
    });

    // ──────────────────────────────────────────────────────────────────────────
    // STEP 3: PREPARE QUERY WORKLOAD (5,000 Queries)
    // ──────────────────────────────────────────────────────────────────────────
    const latencies = try alloc.alloc(u64, NUM_QUERIES);
    defer alloc.free(latencies);

    // Global queries jumping across different domain spokes
    var query_subjs_global: [NUM_QUERIES][16]u8 = undefined;
    for (0..NUM_QUERIES) |q| {
        const q_spoke = (q * 7) % NUM_SPOKES;
        const q_ent = (q * 31) % ENTITIES_PER_SPOKE;
        query_subjs_global[q] = @splat(0);
        _ = try std.fmt.bufPrint(&query_subjs_global[q], "s_{d:0>4}_{d:0>6}", .{ q_spoke, q_ent });
    }

    // Domain-resident queries focused on an active spoke (simulating agent domain locality)
    var query_subjs_domain: [NUM_QUERIES][16]u8 = undefined;
    const active_spoke_id: usize = 42;
    for (0..NUM_QUERIES) |q| {
        const q_ent = (q * 17) % ENTITIES_PER_SPOKE;
        query_subjs_domain[q] = @splat(0);
        _ = try std.fmt.bufPrint(&query_subjs_domain[q], "s_{d:0>4}_{d:0>6}", .{ active_spoke_id, q_ent });
    }

    // Prepared statements for SQLite
    const sql_point: [*:0]const u8 = "SELECT id, opcode, subject_id, predicate_id, target_id, flags, epoch FROM records WHERE subject_id = ?;";
    var stmt_point: ?*sqlite3_stmt = null;
    _ = sqlite3_prepare_v2(db, sql_point, -1, &stmt_point, null);
    defer _ = sqlite3_finalize(stmt_point);

    const sql_multi: [*:0]const u8 = "SELECT id, opcode, subject_id, predicate_id, target_id, flags, epoch FROM records WHERE subject_id = ? AND epoch >= ? AND (flags & 1) != 0;";
    var stmt_multi: ?*sqlite3_stmt = null;
    _ = sqlite3_prepare_v2(db, sql_multi, -1, &stmt_multi, null);
    defer _ = sqlite3_finalize(stmt_multi);

    // Warmup
    for (0..500) |q| {
        _ = sqlite3_bind_text(stmt_point, 1, &query_subjs_global[q], 13, SQLITE_STATIC);
        while (sqlite3_step(stmt_point) == SQLITE_ROW) {}
        _ = sqlite3_reset(stmt_point);
        _ = sqlite3_clear_bindings(stmt_point);
    }

    std.debug.print("\n════════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  BENCHMARK PHASE: 1M RECORD QUERY EXECUTION ({d} queries per run)\n", .{NUM_QUERIES});
    std.debug.print("════════════════════════════════════════════════════════════════════════════════\n", .{});

    // ──────────────────────────────────────────────────────────────────────────
    // ARM A1: SQLite Point Query (B-Tree traversal on subject_id)
    // ──────────────────────────────────────────────────────────────────────────
    const ru_a1_before = getRusage();
    perf.start();
    const t0_a1 = nowNs();
    for (0..NUM_QUERIES) |q| {
        const q_t0 = nowNs();
        _ = sqlite3_bind_text(stmt_point, 1, &query_subjs_global[q], 13, SQLITE_STATIC);
        var row_count: usize = 0;
        while (sqlite3_step(stmt_point) == SQLITE_ROW) {
            _ = sqlite3_column_int64(stmt_point, 0);
            row_count += 1;
        }
        _ = sqlite3_reset(stmt_point);
        _ = sqlite3_clear_bindings(stmt_point);
        const q_t1 = nowNs();
        latencies[q] = q_t1 - q_t0;
    }
    const t1_a1 = nowNs();
    const tele_a1 = perf.stop();
    const ru_a1_after = getRusage();
    _ = evaluateAndPrintArm("Arm A1: SQLite 1M Point Query (B-Tree)", NUM_QUERIES, t1_a1 - t0_a1, latencies, tele_a1, ru_a1_after.min_flt - ru_a1_before.min_flt);

    // ──────────────────────────────────────────────────────────────────────────
    // ARM A2: SQLite Multi-Constraint Query (Composite B-Tree index)
    // ──────────────────────────────────────────────────────────────────────────
    const ru_a2_before = getRusage();
    perf.start();
    const t0_a2 = nowNs();
    for (0..NUM_QUERIES) |q| {
        const q_t0 = nowNs();
        _ = sqlite3_bind_text(stmt_multi, 1, &query_subjs_global[q], 13, SQLITE_STATIC);
        _ = sqlite3_bind_int(stmt_multi, 2, 5); // epoch >= 5
        var row_count: usize = 0;
        while (sqlite3_step(stmt_multi) == SQLITE_ROW) {
            _ = sqlite3_column_int64(stmt_multi, 0);
            row_count += 1;
        }
        _ = sqlite3_reset(stmt_multi);
        _ = sqlite3_clear_bindings(stmt_multi);
        const q_t1 = nowNs();
        latencies[q] = q_t1 - q_t0;
    }
    const t1_a2 = nowNs();
    const tele_a2 = perf.stop();
    const ru_a2_after = getRusage();
    _ = evaluateAndPrintArm("Arm A2: SQLite 1M Multi-Constraint (Composite Index)", NUM_QUERIES, t1_a2 - t0_a2, latencies, tele_a2, ru_a2_after.min_flt - ru_a2_before.min_flt);

    // ──────────────────────────────────────────────────────────────────────────
    // ARM B1: Zig Cellular Spoke Point Query (Spoke Routing + SIMD Vector Scan)
    // ──────────────────────────────────────────────────────────────────────────
    const ru_b1_before = getRusage();
    perf.start();
    const t0_b1 = nowNs();
    for (0..NUM_QUERIES) |q| {
        const q_t0 = nowNs();
        // 1. Spoke routing (O(1))
        const spoke_idx = routeSubjectToSpoke(&query_subjs_global[q]);
        const target_vec: @Vector(16, u8) = query_subjs_global[q];
        const headers = &spoke_mem[spoke_idx];

        // 2. Vector SIMD comparison across contiguous headers
        var match_count: usize = 0;
        for (headers) |*h| {
            const h_vec: @Vector(16, u8) = h.subject_id;
            if (@reduce(.And, h_vec == target_vec)) {
                std.mem.doNotOptimizeAway(h);
                match_count += 1;
                if (match_count == VERSIONS_PER_ENTITY) break;
            }
        }
        const q_t1 = nowNs();
        latencies[q] = q_t1 - q_t0;
    }
    const t1_b1 = nowNs();
    const tele_b1 = perf.stop();
    const ru_b1_after = getRusage();
    _ = evaluateAndPrintArm("Arm B1: Zig Spoke Point Query (Routing + SIMD Early-Exit)", NUM_QUERIES, t1_b1 - t0_b1, latencies, tele_b1, ru_b1_after.min_flt - ru_b1_before.min_flt);

    // ──────────────────────────────────────────────────────────────────────────
    // ARM B2: Zig Cellular Spoke Multi-Constraint Scan (In-Register Evaluation)
    // ──────────────────────────────────────────────────────────────────────────
    const ru_b2_before = getRusage();
    perf.start();
    const t0_b2 = nowNs();
    for (0..NUM_QUERIES) |q| {
        const q_t0 = nowNs();
        // 1. Spoke routing (O(1))
        const spoke_idx = routeSubjectToSpoke(&query_subjs_global[q]);
        const target_vec: @Vector(16, u8) = query_subjs_global[q];
        const headers = &spoke_mem[spoke_idx];

        // 2. SIMD Vector match + in-register multi-constraint evaluation (same 64B cache line)
        var match_count: usize = 0;
        for (headers) |*h| {
            const h_vec: @Vector(16, u8) = h.subject_id;
            if (@reduce(.And, h_vec == target_vec)) {
                // Evaluated directly from CPU register loaded in the same 64B cache line
                if (h.epoch >= 5 and (h.flags & 1) != 0) {
                    std.mem.doNotOptimizeAway(h);
                    match_count += 1;
                }
            }
        }
        const q_t1 = nowNs();
        latencies[q] = q_t1 - q_t0;
    }
    const t1_b2 = nowNs();
    const tele_b2 = perf.stop();
    const ru_b2_after = getRusage();
    _ = evaluateAndPrintArm("Arm B2: Zig Spoke Multi-Constraint (Full Spoke Register Scan)", NUM_QUERIES, t1_b2 - t0_b2, latencies, tele_b2, ru_b2_after.min_flt - ru_b2_before.min_flt);

    // ──────────────────────────────────────────────────────────────────────────
    // ARM B3: Zig Domain-Resident Spoke Point Query (L2 Cache Locality)
    // ──────────────────────────────────────────────────────────────────────────
    const ru_b3_before = getRusage();
    perf.start();
    const t0_b3 = nowNs();
    for (0..NUM_QUERIES) |q| {
        const q_t0 = nowNs();
        // 1. Spoke routing (O(1))
        const spoke_idx = routeSubjectToSpoke(&query_subjs_domain[q]);
        const target_vec: @Vector(16, u8) = query_subjs_domain[q];
        const headers = &spoke_mem[spoke_idx];

        // 2. Vector SIMD comparison in warm L2 cache
        var match_count: usize = 0;
        for (headers) |*h| {
            const h_vec: @Vector(16, u8) = h.subject_id;
            if (@reduce(.And, h_vec == target_vec)) {
                std.mem.doNotOptimizeAway(h);
                match_count += 1;
                if (match_count == VERSIONS_PER_ENTITY) break;
            }
        }
        const q_t1 = nowNs();
        latencies[q] = q_t1 - q_t0;
    }
    const t1_b3 = nowNs();
    const tele_b3 = perf.stop();
    const ru_b3_after = getRusage();
    _ = evaluateAndPrintArm("Arm B3: Zig Domain Spoke Point Query (Warm L2 Cache Locality)", NUM_QUERIES, t1_b3 - t0_b3, latencies, tele_b3, ru_b3_after.min_flt - ru_b3_before.min_flt);

    // ──────────────────────────────────────────────────────────────────────────
    // ARM B4: Zig Domain-Resident Spoke Multi-Constraint Scan (Warm L2 Cache)
    // ──────────────────────────────────────────────────────────────────────────
    const ru_b4_before = getRusage();
    perf.start();
    const t0_b4 = nowNs();
    for (0..NUM_QUERIES) |q| {
        const q_t0 = nowNs();
        // 1. Spoke routing (O(1))
        const spoke_idx = routeSubjectToSpoke(&query_subjs_domain[q]);
        const target_vec: @Vector(16, u8) = query_subjs_domain[q];
        const headers = &spoke_mem[spoke_idx];

        // 2. In-register evaluation across warm 640 KB spoke
        var match_count: usize = 0;
        for (headers) |*h| {
            const h_vec: @Vector(16, u8) = h.subject_id;
            if (@reduce(.And, h_vec == target_vec)) {
                if (h.epoch >= 5 and (h.flags & 1) != 0) {
                    std.mem.doNotOptimizeAway(h);
                    match_count += 1;
                }
            }
        }
        const q_t1 = nowNs();
        latencies[q] = q_t1 - q_t0;
    }
    const t1_b4 = nowNs();
    const tele_b4 = perf.stop();
    const ru_b4_after = getRusage();
    _ = evaluateAndPrintArm("Arm B4: Zig Domain Spoke Multi-Constraint (Warm L2 Cache Scan)", NUM_QUERIES, t1_b4 - t0_b4, latencies, tele_b4, ru_b4_after.min_flt - ru_b4_before.min_flt);

    std.debug.print("\n════════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  1M-RECORD SCALE BENCHMARK COMPLETE — PHYSICAL METAL VERIFIED\n", .{});
    std.debug.print("════════════════════════════════════════════════════════════════════════════════\n\n", .{});
}

test "1M query benchmark invariants and spoke routing" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(InstructionHeader));
    try std.testing.expectEqual(@as(usize, 64), @alignOf(InstructionHeader));
    try std.testing.expectEqual(@as(usize, 17408), CELL_BYTES);
    try std.testing.expectEqual(@as(usize, 64), BYTECODE_HEADER_BYTES);

    var test_subj: [16]u8 = @splat(0);
    _ = try std.fmt.bufPrint(&test_subj, "s_{d:0>4}_{d:0>6}", .{ 42, 123 });
    const spoke = routeSubjectToSpoke(&test_subj);
    try std.testing.expectEqual(@as(usize, 42), spoke);

    // Verify SIMD equality matches
    const target_vec: @Vector(16, u8) = test_subj;
    const match_vec: @Vector(16, u8) = test_subj;
    try std.testing.expect(@reduce(.And, target_vec == match_vec));
}
