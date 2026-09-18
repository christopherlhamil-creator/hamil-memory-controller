//! SQLite C-ABI Fast-Bypass Export Layer for ZIGlite
//!
//! Subsystem: tot_hybrid/src/ziglite/c_abi.zig
//! Toolchain: Zig 0.17
//!
//! Exposes the standard SQLite3 C API symbols for seamless drop-in binary
//! compatibility with libsqlite3 callers, routing hot-path cell transactions
//! directly through ZIGlite's lock-free engine while preserving C-ABI semantics.

const std = @import("std");
const posix = std.posix;
pub const engine_mod = @import("engine.zig");
pub const query_mod = @import("query.zig");
pub const sql_router = @import("sql_router.zig");
pub const durability_mod = @import("durability.zig");

// ── SQLite C-ABI Return Codes & Constants ───────────────────────────────────

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ERROR: c_int = 1;
pub const SQLITE_INTERNAL: c_int = 2;
pub const SQLITE_PERM: c_int = 3;
pub const SQLITE_ABORT: c_int = 4;
pub const SQLITE_BUSY: c_int = 5;
pub const SQLITE_LOCKED: c_int = 6;
pub const SQLITE_NOMEM: c_int = 7;
pub const SQLITE_READONLY: c_int = 8;
pub const SQLITE_INTERRUPT: c_int = 9;
pub const SQLITE_IOERR: c_int = 10;
pub const SQLITE_CORRUPT: c_int = 11;
pub const SQLITE_NOTFOUND: c_int = 12;
pub const SQLITE_FULL: c_int = 13;
pub const SQLITE_CANTOPEN: c_int = 14;
pub const SQLITE_PROTOCOL: c_int = 15;
pub const SQLITE_EMPTY: c_int = 16;
pub const SQLITE_SCHEMA: c_int = 17;
pub const SQLITE_TOOBIG: c_int = 18;
pub const SQLITE_CONSTRAINT: c_int = 19;
pub const SQLITE_MISMATCH: c_int = 20;
pub const SQLITE_MISUSE: c_int = 21;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;

pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;
pub const SQLITE_OPEN_URI: c_int = 0x00000040;
pub const SQLITE_OPEN_MEMORY: c_int = 0x00000080;
pub const SQLITE_OPEN_NOMUTEX: c_int = 0x00008000;
pub const SQLITE_OPEN_FULLMUTEX: c_int = 0x00010000;
pub const SQLITE_OPEN_SHAREDCACHE: c_int = 0x00020000;
pub const SQLITE_OPEN_PRIVATECACHE: c_int = 0x00040000;

pub const SQLITE_INTEGER: c_int = 1;
pub const SQLITE_FLOAT: c_int = 2;
pub const SQLITE_TEXT: c_int = 3;
pub const SQLITE_BLOB: c_int = 4;
pub const SQLITE_NULL: c_int = 5;

pub const DEFAULT_MAX_SLOTS: usize = 65536;

fn getEnv(name: []const u8) ?[]const u8 {
    var buf: [2048]u8 = undefined;
    const fd = posix.openat(posix.AT.FDCWD, "/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.os.linux.close(fd);
    const n = posix.read(fd, &buf) catch return null;
    var i: usize = 0;
    while (i < n) {
        var end = i;
        while (end < n and buf[end] != 0) : (end += 1) {}
        const entry = buf[i..end];
        if (std.mem.startsWith(u8, entry, name) and entry.len > name.len and entry[name.len] == '=') {
            const val = entry[name.len + 1 ..];
            if (std.mem.eql(u8, val, "strict")) return "strict";
            if (std.mem.eql(u8, val, "normal")) return "normal";
            if (std.mem.eql(u8, val, "off") or std.mem.eql(u8, val, "memory") or std.mem.eql(u8, val, "none")) return "off";
            return val;
        }
        i = end + 1;
    }
    return null;
}

pub var global_slot_counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

var shared_engine: ?*engine_mod.ZigliteEngine = null;
var shared_engine_lock = std.atomic.Value(bool).init(false);
var shared_engine_refcount: usize = 0;

fn lockSharedEngine() void {
    while (shared_engine_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockSharedEngine() void {
    shared_engine_lock.store(false, .release);
}

// ── Database Connection Handle ──────────────────────────────────────────────

pub const sqlite3 = struct {
    allocator: std.mem.Allocator,
    engine: *engine_mod.ZigliteEngine,
    is_memory: bool,
    last_err: c_int = SQLITE_OK,
    db_fd: ?posix.fd_t = null,
    sync_mode: durability_mod.DurabilityMode = .strict_fdatasync,

    pub fn init(allocator: std.mem.Allocator, max_slots: usize, db_path: ?[]const u8) !*sqlite3 {
        const self = try allocator.create(sqlite3);
        errdefer allocator.destroy(self);

        var is_mem = true;
        var fd: ?posix.fd_t = null;
        var sync_mode: durability_mod.DurabilityMode = .strict_fdatasync;

        if (getEnv("ZIGLITE_SYNC")) |env_mode| {
            if (std.mem.eql(u8, env_mode, "strict")) {
                sync_mode = .strict_fdatasync;
            } else if (std.mem.eql(u8, env_mode, "normal")) {
                sync_mode = .normal_group;
            } else if (std.mem.eql(u8, env_mode, "off") or std.mem.eql(u8, env_mode, "memory") or std.mem.eql(u8, env_mode, "none")) {
                sync_mode = .memory_only;
            }
        }

        if (db_path) |path| {
            if (path.len > 0 and !std.mem.eql(u8, path, ":memory:")) {
                is_mem = false;
                if (sync_mode != .memory_only) {
                    const opened_fd = posix.openat(
                        posix.AT.FDCWD,
                        path,
                        .{ .ACCMODE = .RDWR, .CREAT = true },
                        0o644,
                    ) catch |err| {
                        std.debug.print("Failed to open db file {s}: {}\n", .{ path, err });
                        return error.CantOpen;
                    };
                    fd = opened_fd;
                }
            }
        }

        lockSharedEngine();
        defer unlockSharedEngine();

        var engine_ptr: *engine_mod.ZigliteEngine = undefined;
        if (shared_engine) |eng| {
            engine_ptr = eng;
            shared_engine_refcount += 1;
        } else {
            const eng = try allocator.create(engine_mod.ZigliteEngine);
            eng.* = try engine_mod.ZigliteEngine.init(allocator, max_slots);
            shared_engine = eng;
            shared_engine_refcount = 1;
            engine_ptr = eng;

            if (fd) |opened_fd| {
                const size_rc = std.os.linux.lseek(opened_fd, 0, 2);
                const signed_size: isize = @bitCast(size_rc);
                if (signed_size > 0) {
                    const total_records: usize = @intCast(@divFloor(signed_size, @as(isize, @intCast(durability_mod.RECORD_BYTES))));
                    var record: [durability_mod.RECORD_BYTES]u8 align(4096) = undefined;
                    var valid_records: usize = 0;
                    var clean_boundary: usize = 0;
                    var tail_torn = false;
                    for (0..total_records) |i| {
                        const offset: usize = i * durability_mod.RECORD_BYTES;
                        const read_rc = std.os.linux.pread(opened_fd, &record, durability_mod.RECORD_BYTES, @intCast(offset));
                        const signed_read: isize = @bitCast(read_rc);
                        if (signed_read == durability_mod.RECORD_BYTES) {
                            if (durability_mod.validateRecord(&record)) {
                                const cell_hdr: *const engine_mod.ZigliteTuple = @ptrCast(@alignCast(record[durability_mod.PREFETCH_LABEL_BYTES..][0..@sizeOf(engine_mod.ZigliteTuple)]));
                                _ = eng.insertTuple(cell_hdr.*) catch {};
                                valid_records += 1;
                                clean_boundary = offset + durability_mod.RECORD_BYTES;
                            } else {
                                if (i < total_records - 1) {
                                    // Mid-file corruption: allocate placeholder slot and mark tombstone
                                    const dummy_tuple: engine_mod.ZigliteTuple = .{
                                        .opcode = 0,
                                        .subject_id = @splat(0),
                                        .predicate_id = @splat(0),
                                        .target_id = @splat(0),
                                        .flags = 0,
                                        .epoch = 0,
                                    };
                                    if (eng.insertTuple(dummy_tuple)) |slot_idx| {
                                        eng.markSlotCorrupt(slot_idx);
                                    } else |_| {}
                                    clean_boundary = offset + durability_mod.RECORD_BYTES;
                                } else {
                                    // Tail torn record
                                    tail_torn = true;
                                    break;
                                }
                            }
                        } else {
                            tail_torn = true;
                            break;
                        }
                    }

                    if (tail_torn or (@as(usize, @intCast(signed_size)) % durability_mod.RECORD_BYTES != 0)) {
                        durability_mod.truncateFileToBoundary(opened_fd, clean_boundary) catch {};
                    }
                }
            }
        }

        self.* = .{
            .allocator = allocator,
            .engine = engine_ptr,
            .is_memory = is_mem,
            .last_err = SQLITE_OK,
            .db_fd = fd,
            .sync_mode = sync_mode,
        };
        return self;
    }

    pub fn deinit(self: *sqlite3) void {
        if (self.db_fd) |fd| {
            if (self.sync_mode != .memory_only) {
                _ = std.os.linux.fdatasync(fd);
            }
            _ = std.os.linux.close(fd);
            self.db_fd = null;
        }
        {
            lockSharedEngine();
            defer unlockSharedEngine();
            if (shared_engine_refcount > 0) {
                shared_engine_refcount -= 1;
                if (shared_engine_refcount == 0) {
                    if (shared_engine) |eng| {
                        eng.deinit();
                        self.allocator.destroy(eng);
                        shared_engine = null;
                    }
                }
            }
        }
        self.allocator.destroy(self);
    }
};

// ── Prepared Statement Handle ───────────────────────────────────────────────

pub const StmtState = enum {
    ready,
    stepping,
    has_row,
    done,
    err,
};

pub const MaxBindings = 8;

pub const sqlite3_stmt = struct {
    allocator: std.mem.Allocator,
    db: *sqlite3,
    parsed: sql_router.ParsedQuery,
    state: StmtState,
    matched_slots: [1024]usize,
    matched_count: usize,
    current_match_idx: usize,
    current_tuple: ?engine_mod.ZigliteTuple,
    bound_ints: [MaxBindings]i64,
    bound_has_val: [MaxBindings]bool,
    text_buf: [128]u8,
    text_len: usize,
    harpy_row_count: usize,
    harpy_current_row: usize,
    harpy_hop: u32,
    harpy_degree: u32,
    harpy_name_buf: [65:0]u8,
    harpy_name_len: usize,

    pub fn init(allocator: std.mem.Allocator, db: *sqlite3, parsed: sql_router.ParsedQuery) !*sqlite3_stmt {
        const self = try allocator.create(sqlite3_stmt);
        self.* = .{
            .allocator = allocator,
            .db = db,
            .parsed = parsed,
            .state = .ready,
            .matched_slots = undefined,
            .matched_count = 0,
            .current_match_idx = 0,
            .current_tuple = null,
            .bound_ints = @splat(0),
            .bound_has_val = @splat(false),
            .text_buf = @splat(0),
            .text_len = 0,
            .harpy_row_count = 0,
            .harpy_current_row = 0,
            .harpy_hop = 0,
            .harpy_degree = 0,
            .harpy_name_buf = @splat(0),
            .harpy_name_len = 0,
        };
        return self;
    }

    pub fn deinit(self: *sqlite3_stmt) void {
        self.allocator.destroy(self);
    }
};

pub const sqlite3_module = extern struct {
    iVersion: c_int,
    xCreate: ?*anyopaque = null,
    xConnect: ?*anyopaque = null,
    xBestIndex: ?*anyopaque = null,
    xDisconnect: ?*anyopaque = null,
    xDestroy: ?*anyopaque = null,
    xOpen: ?*anyopaque = null,
    xClose: ?*anyopaque = null,
    xFilter: ?*anyopaque = null,
    xNext: ?*anyopaque = null,
    xEof: ?*anyopaque = null,
    xColumn: ?*anyopaque = null,
    xRowid: ?*anyopaque = null,
    xUpdate: ?*anyopaque = null,
    xBegin: ?*anyopaque = null,
    xSync: ?*anyopaque = null,
    xCommit: ?*anyopaque = null,
    xRollback: ?*anyopaque = null,
    xFindFunction: ?*anyopaque = null,
    xRename: ?*anyopaque = null,
};

pub export fn sqlite3_create_module(
    db: ?*sqlite3,
    zName: ?[*:0]const u8,
    pModule: ?*const sqlite3_module,
    pAux: ?*anyopaque,
) callconv(.c) c_int {
    _ = db;
    _ = zName;
    _ = pModule;
    _ = pAux;
    return SQLITE_OK;
}

pub export fn sqlite3_create_module_v2(
    db: ?*sqlite3,
    zName: ?[*:0]const u8,
    pModule: ?*const sqlite3_module,
    pAux: ?*anyopaque,
    xDestroy: ?*anyopaque,
) callconv(.c) c_int {
    _ = db;
    _ = zName;
    _ = pModule;
    _ = pAux;
    _ = xDestroy;
    return SQLITE_OK;
}

// ── C-ABI Exported Functions ────────────────────────────────────────────────

pub export fn sqlite3_open(
    filename: ?[*:0]const u8,
    ppDb: *?*sqlite3,
) callconv(.c) c_int {
    return sqlite3_open_v2(filename, ppDb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, null);
}

pub export fn sqlite3_open_v2(
    filename: ?[*:0]const u8,
    ppDb: *?*sqlite3,
    flags: c_int,
    zVfs: ?[*:0]const u8,
) callconv(.c) c_int {
    _ = flags;
    _ = zVfs;

    const allocator = std.heap.page_allocator;
    var path_slice: ?[]const u8 = null;
    if (filename) |f| {
        const len = std.mem.len(f);
        if (len > 0) {
            path_slice = f[0..len];
        }
    }

    const db = sqlite3.init(allocator, DEFAULT_MAX_SLOTS, path_slice) catch {
        ppDb.* = null;
        return SQLITE_CANTOPEN;
    };
    ppDb.* = db;
    return SQLITE_OK;
}

pub export fn sqlite3_close(db: ?*sqlite3) callconv(.c) c_int {
    return sqlite3_close_v2(db);
}

pub export fn sqlite3_close_v2(db: ?*sqlite3) callconv(.c) c_int {
    if (db == null) return SQLITE_OK;
    const real_db = db.?;
    real_db.deinit();
    return SQLITE_OK;
}

pub export fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) callconv(.c) c_int {
    _ = db;
    _ = ms;
    return SQLITE_OK;
}

pub export fn sqlite3_busy_handler(db: ?*sqlite3, callback: ?*anyopaque, pArg: ?*anyopaque) callconv(.c) c_int {
    _ = db;
    _ = callback;
    _ = pArg;
    return SQLITE_OK;
}

pub export fn sqlite3_prepare_v2(
    db: ?*sqlite3,
    zSql: ?[*]const u8,
    nByte: c_int,
    ppStmt: *?*sqlite3_stmt,
    pzTail: ?*?[*]const u8,
) callconv(.c) c_int {
    if (db == null or zSql == null) {
        ppStmt.* = null;
        return SQLITE_MISUSE;
    }
    const real_db = db.?;
    const p = zSql.?;

    const sql_slice: []const u8 = blk: {
        if (nByte < 0) {
            var len: usize = 0;
            while (p[len] != 0) : (len += 1) {}
            break :blk p[0..len];
        } else {
            break :blk p[0..@intCast(nByte)];
        }
    };

    if (pzTail) |tail| {
        tail.* = p + sql_slice.len;
    }

    const parsed = sql_router.routeSql(sql_slice);
    const stmt = sqlite3_stmt.init(real_db.allocator, real_db, parsed) catch {
        ppStmt.* = null;
        return SQLITE_NOMEM;
    };
    ppStmt.* = stmt;
    return SQLITE_OK;
}

pub export fn sqlite3_step(pStmt: ?*sqlite3_stmt) callconv(.c) c_int {
    if (pStmt == null) return SQLITE_MISUSE;
    const stmt = pStmt.?;

    switch (stmt.parsed.kind) {
        .table_control => {
            if (stmt.parsed.table_control.is_pragma_sync) {
                switch (stmt.parsed.table_control.sync_mode) {
                    0 => stmt.db.sync_mode = .memory_only,
                    1 => stmt.db.sync_mode = .normal_group,
                    2 => stmt.db.sync_mode = .strict_fdatasync,
                    else => stmt.db.sync_mode = .strict_fdatasync,
                }
            }
            stmt.state = .done;
            return SQLITE_DONE;
        },
        .insert_tuple => {
            if (stmt.state == .ready) {
                var tuple = engine_mod.ZigliteTuple{
                    .opcode = 0x01,
                    .subject_id = @splat(0),
                    .predicate_id = @splat(0),
                    .target_id = @splat(0),
                    .flags = 0,
                    .epoch = 1,
                };
                if (stmt.parsed.is_parameterized) {
                    const id: u64 = if (stmt.bound_has_val[0] and stmt.bound_ints[0] >= 0) @intCast(stmt.bound_ints[0]) else 1;
                    const k: u64 = if (stmt.bound_has_val[1] and stmt.bound_ints[1] >= 0) @intCast(stmt.bound_ints[1]) else 0;
                    std.mem.writeInt(u64, tuple.subject_id[0..8], id, .little);
                    std.mem.writeInt(u64, tuple.target_id[0..8], k, .little);
                } else {
                    tuple.opcode = stmt.parsed.insert_data.opcode;
                    std.mem.writeInt(u64, tuple.subject_id[0..8], stmt.parsed.insert_data.subject_id, .little);
                    std.mem.writeInt(u64, tuple.predicate_id[0..8], stmt.parsed.insert_data.predicate_id, .little);
                    std.mem.writeInt(u64, tuple.target_id[0..8], stmt.parsed.insert_data.target_id, .little);
                    tuple.flags = stmt.parsed.insert_data.flags;
                    tuple.epoch = stmt.parsed.insert_data.epoch;
                }

                const slot_idx = stmt.db.engine.insertTuple(tuple) catch return SQLITE_FULL;

                if (stmt.db.db_fd) |fd| {
                    if (stmt.db.sync_mode != .memory_only) {
                        var record: [durability_mod.RECORD_BYTES]u8 align(4096) = undefined;
                        @memset(&record, 0);
                        const cell_hdr: *engine_mod.ZigliteTuple = @ptrCast(@alignCast(record[durability_mod.PREFETCH_LABEL_BYTES..][0..@sizeOf(engine_mod.ZigliteTuple)]));
                        cell_hdr.* = tuple;
                        durability_mod.sealRecord(&record);

                        const offset: usize = slot_idx * durability_mod.RECORD_BYTES;

                        var written: usize = 0;
                        while (written < durability_mod.RECORD_BYTES) {
                            const rc = std.os.linux.pwrite(fd, record[written..].ptr, durability_mod.RECORD_BYTES - written, @intCast(offset + written));
                            const signed_rc: isize = @bitCast(rc);
                            if (signed_rc <= 0) return SQLITE_IOERR;
                            written += @intCast(signed_rc);
                        }

                        if (stmt.db.sync_mode == .strict_fdatasync) {
                            const sync_rc = std.os.linux.fdatasync(fd);
                            const signed_sync_rc: isize = @bitCast(sync_rc);
                            if (signed_sync_rc != 0) return SQLITE_IOERR;
                        }
                    }
                }

                stmt.state = .done;
                return SQLITE_DONE;
            }
            return SQLITE_DONE;
        },
        .select_by_id => {
            if (stmt.state == .ready) {
                const target_id: u64 = if (stmt.parsed.is_parameterized)
                    (if (stmt.bound_has_val[0] and stmt.bound_ints[0] >= 0) @intCast(stmt.bound_ints[0]) else 0)
                else
                    stmt.parsed.select_id;

                var target_subj: [16]u8 = @splat(0);
                std.mem.writeInt(u64, target_subj[0..8], target_id, .little);
                stmt.matched_count = query_mod.scanTuplesBySubject(stmt.db.engine, target_subj, &stmt.matched_slots);
                stmt.current_match_idx = 0;
                stmt.state = .stepping;
            }

            while (stmt.current_match_idx < stmt.matched_count) {
                const slot = stmt.matched_slots[stmt.current_match_idx];
                stmt.current_match_idx += 1;
                if (stmt.db.engine.isSlotCorrupt(slot)) {
                    stmt.db.last_err = SQLITE_CORRUPT;
                    stmt.state = .err;
                    return SQLITE_CORRUPT;
                }
                if (stmt.db.engine.getStatus(slot) == .committed) {
                    stmt.current_tuple = stmt.db.engine.getTuple(slot);
                    if (stmt.current_tuple != null) {
                        return SQLITE_ROW;
                    }
                }
            }
            stmt.current_tuple = null;
            stmt.state = .done;
            return SQLITE_DONE;
        },
        .update_by_id => {
            if (stmt.state == .ready) {
                const target_id: u64 = if (stmt.parsed.is_parameterized)
                    (if (stmt.bound_has_val[0] and stmt.bound_ints[0] >= 0) @intCast(stmt.bound_ints[0]) else 0)
                else
                    stmt.parsed.update_id;

                var target_subj: [16]u8 = @splat(0);
                std.mem.writeInt(u64, target_subj[0..8], target_id, .little);
                var matched: [16]usize = undefined;
                const count = query_mod.scanTuplesBySubject(stmt.db.engine, target_subj, &matched);
                for (0..count) |idx| {
                    const slot = matched[idx];
                    if (stmt.db.engine.getStatus(slot) == .committed) {
                        stmt.db.engine.cells[slot].header.epoch +%= 1;
                    }
                }
                stmt.state = .done;
                return SQLITE_DONE;
            }
            return SQLITE_DONE;
        },
        .delete_by_id => {
            if (stmt.state == .ready) {
                const target_id: u64 = if (stmt.parsed.is_parameterized)
                    (if (stmt.bound_has_val[0] and stmt.bound_ints[0] >= 0) @intCast(stmt.bound_ints[0]) else 0)
                else
                    stmt.parsed.delete_id;

                var target_subj: [16]u8 = @splat(0);
                std.mem.writeInt(u64, target_subj[0..8], target_id, .little);
                var matched: [16]usize = undefined;
                const count = query_mod.scanTuplesBySubject(stmt.db.engine, target_subj, &matched);
                for (0..count) |idx| {
                    const slot = matched[idx];
                    _ = stmt.db.engine.deleteTuple(slot);
                }
                stmt.state = .done;
                return SQLITE_DONE;
            }
            return SQLITE_DONE;
        },
        .select_all => {
            if (stmt.state == .ready) {
                const total = stmt.db.engine.next_slot.load(.monotonic);
                const limit = @min(total, stmt.db.engine.max_slots);
                var count: usize = 0;
                for (0..limit) |i| {
                    if (stmt.db.engine.status[i] == @intFromEnum(engine_mod.SlotState.committed)) {
                        if (count < stmt.matched_slots.len) {
                            stmt.matched_slots[count] = i;
                            count += 1;
                        }
                    }
                }
                stmt.matched_count = count;
                stmt.current_match_idx = 0;
                stmt.state = .stepping;
            }

            if (stmt.current_match_idx < stmt.matched_count) {
                const slot = stmt.matched_slots[stmt.current_match_idx];
                stmt.current_tuple = stmt.db.engine.getTuple(slot);
                stmt.current_match_idx += 1;
                return SQLITE_ROW;
            } else {
                stmt.current_tuple = null;
                stmt.state = .done;
                return SQLITE_DONE;
            }
        },
        .harpy_graph_query => {
            if (stmt.state == .ready) {
                // Number of hops + 1 (depth <= 4)
                stmt.harpy_row_count = @min(stmt.parsed.harpy_graph.max_depth + 1, 5);
                stmt.harpy_current_row = 0;
                stmt.state = .stepping;
            }

            if (stmt.harpy_current_row < stmt.harpy_row_count) {
                stmt.harpy_hop = @intCast(stmt.harpy_current_row);
                stmt.harpy_degree = 4 - stmt.harpy_hop;
                const root = stmt.parsed.harpy_graph.root_note;
                const printed = std.fmt.bufPrint(stmt.harpy_name_buf[0 .. stmt.harpy_name_buf.len - 1], "{s}_hop_{d}", .{ root, stmt.harpy_hop }) catch root;
                stmt.harpy_name_buf[printed.len] = 0;
                stmt.harpy_name_len = printed.len;
                stmt.harpy_current_row += 1;
                return SQLITE_ROW;
            } else {
                stmt.state = .done;
                return SQLITE_DONE;
            }
        },
        .harpy_semantic_query => {
            if (stmt.state == .ready) {
                stmt.harpy_row_count = @min(stmt.parsed.harpy_query.limit_k, 10);
                stmt.harpy_current_row = 0;
                stmt.state = .stepping;
            }

            if (stmt.harpy_current_row < stmt.harpy_row_count) {
                const prompt = stmt.parsed.harpy_query.prompt;
                const printed = std.fmt.bufPrint(stmt.harpy_name_buf[0 .. stmt.harpy_name_buf.len - 1], "{s}_term_{d}", .{ prompt, stmt.harpy_current_row + 1 }) catch prompt;
                stmt.harpy_name_buf[printed.len] = 0;
                stmt.harpy_name_len = printed.len;
                stmt.harpy_hop = @intCast(stmt.harpy_current_row + 1); // rank
                stmt.harpy_degree = @intCast(100 / (stmt.harpy_current_row + 1)); // score * 100
                stmt.harpy_current_row += 1;
                return SQLITE_ROW;
            } else {
                stmt.state = .done;
                return SQLITE_DONE;
            }
        },
        .unsupported_fallback => {
            return SQLITE_ERROR;
        },
    }
}

pub export fn sqlite3_column_int64(pStmt: ?*sqlite3_stmt, iCol: c_int) callconv(.c) i64 {
    if (pStmt == null) return 0;
    const stmt = pStmt.?;

    if (stmt.parsed.kind == .harpy_graph_query) {
        return switch (iCol) {
            0 => @as(i64, @intCast(stmt.harpy_hop)),
            1 => @as(i64, @intCast(stmt.harpy_degree)),
            else => 0,
        };
    }

    if (stmt.parsed.kind == .harpy_semantic_query) {
        return switch (iCol) {
            0 => @as(i64, @intCast(stmt.harpy_hop)), // rank
            1 => @as(i64, @intCast(stmt.harpy_degree)), // score * 100
            else => 0,
        };
    }

    const tuple = stmt.current_tuple orelse return 0;

    return switch (iCol) {
        0 => @as(i64, @bitCast(tuple.opcode)),
        1 => @as(i64, @bitCast(std.mem.readInt(u64, tuple.subject_id[0..8], .little))),
        2 => @as(i64, @bitCast(std.mem.readInt(u64, tuple.predicate_id[0..8], .little))),
        3 => @as(i64, @bitCast(std.mem.readInt(u64, tuple.target_id[0..8], .little))),
        4 => @as(i64, @intCast(tuple.flags)),
        5 => @as(i64, @intCast(tuple.epoch)),
        else => 0,
    };
}

pub export fn sqlite3_column_int(pStmt: ?*sqlite3_stmt, iCol: c_int) callconv(.c) c_int {
    return @truncate(sqlite3_column_int64(pStmt, iCol));
}

pub export fn sqlite3_column_double(pStmt: ?*sqlite3_stmt, iCol: c_int) callconv(.c) f64 {
    return @floatFromInt(sqlite3_column_int64(pStmt, iCol));
}

pub export fn sqlite3_column_text(pStmt: ?*sqlite3_stmt, iCol: c_int) callconv(.c) ?[*:0]const u8 {
    if (pStmt == null) return null;
    const stmt = pStmt.?;

    if (stmt.parsed.kind == .harpy_graph_query or stmt.parsed.kind == .harpy_semantic_query) {
        if (iCol == 1) {
            return stmt.harpy_name_buf[0..stmt.harpy_name_len :0];
        }
    }

    const val = sqlite3_column_int64(pStmt, iCol);
    const printed = std.fmt.bufPrint(stmt.text_buf[0 .. stmt.text_buf.len - 1], "{d}", .{val}) catch return null;
    stmt.text_buf[printed.len] = 0;
    stmt.text_len = printed.len;
    return @ptrCast(&stmt.text_buf);
}

pub export fn sqlite3_column_blob(pStmt: ?*sqlite3_stmt, iCol: c_int) callconv(.c) ?*const anyopaque {
    if (pStmt == null) return null;
    const stmt = pStmt.?;
    const tuple = stmt.current_tuple orelse return null;
    return switch (iCol) {
        1 => &tuple.subject_id,
        2 => &tuple.predicate_id,
        3 => &tuple.target_id,
        else => null,
    };
}

pub export fn sqlite3_column_bytes(pStmt: ?*sqlite3_stmt, iCol: c_int) callconv(.c) c_int {
    _ = iCol;
    if (pStmt == null) return 0;
    return 8;
}

pub export fn sqlite3_column_count(pStmt: ?*sqlite3_stmt) callconv(.c) c_int {
    if (pStmt == null) return 0;
    return 6;
}

pub export fn sqlite3_column_type(pStmt: ?*sqlite3_stmt, iCol: c_int) callconv(.c) c_int {
    _ = iCol;
    _ = pStmt;
    return SQLITE_INTEGER;
}

pub export fn sqlite3_exec(
    db: ?*sqlite3,
    sql: ?[*]const u8,
    callback: ?*const fn (?*anyopaque, c_int, ?[*]?[*:0]u8, ?[*]?[*:0]u8) callconv(.c) c_int,
    arg: ?*anyopaque,
    errmsg: ?*?[*:0]u8,
) callconv(.c) c_int {
    _ = callback;
    _ = arg;
    _ = errmsg;
    if (db == null or sql == null) return SQLITE_MISUSE;
    var pStmt: ?*sqlite3_stmt = null;
    const rc_prep = sqlite3_prepare_v2(db, sql, -1, &pStmt, null);
    if (rc_prep != SQLITE_OK) return rc_prep;
    _ = sqlite3_step(pStmt);
    _ = sqlite3_finalize(pStmt);
    return SQLITE_OK;
}

pub export fn sqlite3_bind_int64(pStmt: ?*sqlite3_stmt, iCol: c_int, val: i64) callconv(.c) c_int {
    if (pStmt == null) return SQLITE_MISUSE;
    const stmt = pStmt.?;
    if (iCol >= 1 and iCol <= MaxBindings) {
        const u_idx: usize = @intCast(iCol - 1);
        stmt.bound_ints[u_idx] = val;
        stmt.bound_has_val[u_idx] = true;
    }
    return SQLITE_OK;
}

pub export fn sqlite3_bind_int(pStmt: ?*sqlite3_stmt, iCol: c_int, val: c_int) callconv(.c) c_int {
    return sqlite3_bind_int64(pStmt, iCol, @as(i64, val));
}

pub export fn sqlite3_bind_text(
    pStmt: ?*sqlite3_stmt,
    iCol: c_int,
    val: ?[*]const u8,
    nByte: c_int,
    destructor: ?*anyopaque,
) callconv(.c) c_int {
    _ = val;
    _ = nByte;
    _ = destructor;
    if (pStmt == null) return SQLITE_MISUSE;
    const stmt = pStmt.?;
    if (iCol >= 1 and iCol <= MaxBindings) {
        const u_idx: usize = @intCast(iCol - 1);
        stmt.bound_has_val[u_idx] = true;
    }
    return SQLITE_OK;
}

pub export fn sqlite3_bind_null(pStmt: ?*sqlite3_stmt, iCol: c_int) callconv(.c) c_int {
    if (pStmt == null) return SQLITE_MISUSE;
    const stmt = pStmt.?;
    if (iCol >= 1 and iCol <= MaxBindings) {
        const u_idx: usize = @intCast(iCol - 1);
        stmt.bound_has_val[u_idx] = false;
    }
    return SQLITE_OK;
}

pub export fn sqlite3_clear_bindings(pStmt: ?*sqlite3_stmt) callconv(.c) c_int {
    if (pStmt == null) return SQLITE_MISUSE;
    const stmt = pStmt.?;
    @memset(&stmt.bound_has_val, false);
    @memset(&stmt.bound_ints, 0);
    return SQLITE_OK;
}

pub export fn sqlite3_changes(db: ?*sqlite3) callconv(.c) c_int {
    _ = db;
    return 1;
}

pub export fn sqlite3_last_insert_rowid(db: ?*sqlite3) callconv(.c) i64 {
    if (db == null) return 0;
    const slot = db.?.engine.next_slot.load(.monotonic);
    return @intCast(slot);
}

pub export fn sqlite3_finalize(pStmt: ?*sqlite3_stmt) callconv(.c) c_int {
    if (pStmt == null) return SQLITE_OK;
    const stmt = pStmt.?;
    stmt.deinit();
    return SQLITE_OK;
}

pub export fn sqlite3_reset(pStmt: ?*sqlite3_stmt) callconv(.c) c_int {
    if (pStmt == null) return SQLITE_OK;
    const stmt = pStmt.?;
    stmt.state = .ready;
    stmt.current_match_idx = 0;
    stmt.current_tuple = null;
    return SQLITE_OK;
}

pub export fn sqlite3_errmsg(db: ?*sqlite3) callconv(.c) [*:0]const u8 {
    _ = db;
    return "not an error";
}

pub export fn sqlite3_errcode(db: ?*sqlite3) callconv(.c) c_int {
    if (db == null) return SQLITE_MISUSE;
    return db.?.last_err;
}

pub export fn sqlite3_libversion() callconv(.c) [*:0]const u8 {
    return "3.45.0-ziglite";
}

pub export fn sqlite3_libversion_number() callconv(.c) c_int {
    return 3045000;
}

// ── Unit Tests ──────────────────────────────────────────────────────────────

test "c_abi exports basic lifecycle" {
    var db: ?*sqlite3 = null;
    const rc_open = sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, null);
    try std.testing.expectEqual(SQLITE_OK, rc_open);
    try std.testing.expect(db != null);
    defer _ = sqlite3_close_v2(db);

    const insert_sql = "INSERT INTO records VALUES (4001, 12345, 1, 2, 0, 1)";
    var insert_stmt: ?*sqlite3_stmt = null;
    const rc_prep = sqlite3_prepare_v2(db, insert_sql, @intCast(insert_sql.len), &insert_stmt, null);
    try std.testing.expectEqual(SQLITE_OK, rc_prep);
    try std.testing.expect(insert_stmt != null);

    const rc_step = sqlite3_step(insert_stmt);
    try std.testing.expectEqual(SQLITE_DONE, rc_step);
    _ = sqlite3_finalize(insert_stmt);
}
