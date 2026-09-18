//! Fast-Bypass SQL Query Router & Zero-Copy Tokenizer
//!
//! Subsystem: tot_hybrid/src/ziglite/sql_router.zig
//! Toolchain: Zig 0.17
//!
//! Hot-path zero-copy classification of SQL queries into native ZIGlite
//! cell operations vs embedded SQLite cold-path fallback.

const std = @import("std");

pub const QueryKind = enum {
    insert_tuple,
    select_by_id,
    select_all,
    update_by_id,
    delete_by_id,
    table_control,
    harpy_semantic_query,
    harpy_graph_query,
    unsupported_fallback,
};

pub const InsertTupleData = struct {
    opcode: u64 = 0,
    subject_id: u64 = 0,
    predicate_id: u64 = 0,
    target_id: u64 = 0,
    flags: u32 = 0,
    epoch: u32 = 1,
};

pub const HarpyQueryData = struct {
    prompt: []const u8 = "",
    limit_k: usize = 10,
};

pub const HarpyGraphData = struct {
    root_note: []const u8 = "",
    max_depth: u32 = 4,
};

pub const TableControlData = struct {
    is_pragma_sync: bool = false,
    sync_mode: u8 = 2, // 0: off, 1: normal, 2: full/extra
};

pub const ParsedQuery = struct {
    kind: QueryKind,
    insert_data: InsertTupleData = .{},
    select_id: u64 = 0,
    update_id: u64 = 0,
    delete_id: u64 = 0,
    is_parameterized: bool = false,
    harpy_query: HarpyQueryData = .{},
    harpy_graph: HarpyGraphData = .{},
    table_control: TableControlData = .{},
};

fn startsWithIgnoreCase(str: []const u8, prefix: []const u8) bool {
    if (str.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(str[0..prefix.len], prefix);
}

fn skipWhitespace(str: []const u8, pos: usize) usize {
    var i = pos;
    while (i < str.len and std.ascii.isWhitespace(str[i])) : (i += 1) {}
    return i;
}

fn parseU64(str: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u64, trimmed, 0) catch null;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    if (needle.len == 0) return 0;
    var i: usize = 0;
    const max = haystack.len - needle.len;
    while (i <= max) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return i;
        }
    }
    return null;
}

/// Parses and routes incoming SQL statements zero-copy.
pub fn routeSql(sql: []const u8) ParsedQuery {
    const trimmed = std.mem.trim(u8, sql, " \t\r\n;");
    if (trimmed.len == 0) return .{ .kind = .unsupported_fallback };

    // 0. Check Table & Transaction Control
    if (startsWithIgnoreCase(trimmed, "PRAGMA")) {
        if (indexOfIgnoreCase(trimmed, "synchronous")) |_| {
            var mode: u8 = 2;
            if (indexOfIgnoreCase(trimmed, "off") != null or indexOfIgnoreCase(trimmed, "= 0") != null or indexOfIgnoreCase(trimmed, "=0") != null) {
                mode = 0;
            } else if (indexOfIgnoreCase(trimmed, "normal") != null or indexOfIgnoreCase(trimmed, "= 1") != null or indexOfIgnoreCase(trimmed, "=1") != null) {
                mode = 1;
            } else if (indexOfIgnoreCase(trimmed, "full") != null or indexOfIgnoreCase(trimmed, "extra") != null or indexOfIgnoreCase(trimmed, "= 2") != null or indexOfIgnoreCase(trimmed, "=2") != null) {
                mode = 2;
            }
            return .{
                .kind = .table_control,
                .table_control = .{ .is_pragma_sync = true, .sync_mode = mode },
            };
        }
        return .{ .kind = .table_control };
    }

    if (startsWithIgnoreCase(trimmed, "CREATE TABLE") or
        startsWithIgnoreCase(trimmed, "BEGIN") or
        startsWithIgnoreCase(trimmed, "COMMIT") or
        startsWithIgnoreCase(trimmed, "ROLLBACK"))
    {
        return .{ .kind = .table_control };
    }

    // 1. Check INSERT INTO records VALUES (...)
    if (startsWithIgnoreCase(trimmed, "INSERT")) {
        if (std.mem.indexOfScalar(u8, trimmed, '?') != null) {
            return .{
                .kind = .insert_tuple,
                .is_parameterized = true,
            };
        }
        const after_insert = skipWhitespace(trimmed, 6);
        if (startsWithIgnoreCase(trimmed[after_insert..], "INTO")) {
            const after_into = skipWhitespace(trimmed, after_insert + 4);
            // Look for VALUES (...)
            const values_idx_opt = indexOfIgnoreCase(trimmed[after_into..], "VALUES");
            if (values_idx_opt) |v_offset| {
                const values_pos = after_into + v_offset + 6;
                const open_paren = std.mem.indexOfScalarPos(u8, trimmed, values_pos, '(');
                const close_paren = std.mem.lastIndexOfScalar(u8, trimmed, ')');

                if (open_paren != null and close_paren != null and open_paren.? < close_paren.?) {
                    const inner = trimmed[open_paren.? + 1 .. close_paren.?];
                    var it = std.mem.splitScalar(u8, inner, ',');
                    var parsed_data = InsertTupleData{};
                    var field_idx: usize = 0;

                    while (it.next()) |field| {
                        const val = parseU64(field) orelse return .{ .kind = .unsupported_fallback };
                        switch (field_idx) {
                            0 => parsed_data.opcode = val,
                            1 => parsed_data.subject_id = val,
                            2 => parsed_data.predicate_id = val,
                            3 => parsed_data.target_id = val,
                            4 => parsed_data.flags = @truncate(val),
                            5 => parsed_data.epoch = @truncate(val),
                            else => {},
                        }
                        field_idx += 1;
                    }

                    if (field_idx >= 4) {
                        return .{
                            .kind = .insert_tuple,
                            .insert_data = parsed_data,
                            .is_parameterized = false,
                        };
                    }
                }
            }
        }
    }

    // 2. Check SELECT queries
    if (startsWithIgnoreCase(trimmed, "SELECT")) {
        // Check if targeting harpy_query virtual table
        if (indexOfIgnoreCase(trimmed, "harpy_query")) |_| {
            var hq = HarpyQueryData{};
            // Extract prompt = '...'
            if (indexOfIgnoreCase(trimmed, "prompt")) |p_idx| {
                const after_prompt = trimmed[p_idx + 6 ..];
                const q1 = std.mem.indexOfScalar(u8, after_prompt, '\'');
                if (q1) |q1_pos| {
                    const q2 = std.mem.indexOfScalarPos(u8, after_prompt, q1_pos + 1, '\'');
                    if (q2) |q2_pos| {
                        hq.prompt = after_prompt[q1_pos + 1 .. q2_pos];
                    }
                }
            }
            // Extract limit_k = <num> or LIMIT <num>
            if (indexOfIgnoreCase(trimmed, "limit")) |lim_idx| {
                const after_lim = skipWhitespace(trimmed, lim_idx + 5);
                var num_start = after_lim;
                if (after_lim < trimmed.len and trimmed[after_lim] == '=') {
                    num_start = skipWhitespace(trimmed, after_lim + 1);
                } else if (after_lim + 2 <= trimmed.len and std.ascii.eqlIgnoreCase(trimmed[after_lim .. after_lim + 2], "_k")) {
                    num_start = skipWhitespace(trimmed, after_lim + 2);
                    if (num_start < trimmed.len and trimmed[num_start] == '=') {
                        num_start = skipWhitespace(trimmed, num_start + 1);
                    }
                }
                var num_end = num_start;
                while (num_end < trimmed.len and std.ascii.isDigit(trimmed[num_end])) : (num_end += 1) {}
                if (num_end > num_start) {
                    if (std.fmt.parseInt(usize, trimmed[num_start..num_end], 10)) |val| {
                        hq.limit_k = val;
                    } else |_| {}
                }
            }
            return .{
                .kind = .harpy_semantic_query,
                .harpy_query = hq,
            };
        }

        // Check if targeting harpy_graph virtual table
        if (indexOfIgnoreCase(trimmed, "harpy_graph")) |_| {
            var hg = HarpyGraphData{};
            // Extract root_note = '...' or root = '...'
            if (indexOfIgnoreCase(trimmed, "root")) |r_idx| {
                const after_root = trimmed[r_idx + 4 ..];
                const q1 = std.mem.indexOfScalar(u8, after_root, '\'');
                if (q1) |q1_pos| {
                    const q2 = std.mem.indexOfScalarPos(u8, after_root, q1_pos + 1, '\'');
                    if (q2) |q2_pos| {
                        hg.root_note = after_root[q1_pos + 1 .. q2_pos];
                    }
                }
            }
            // Extract max_depth = <num> or depth = <num>
            if (indexOfIgnoreCase(trimmed, "depth")) |d_idx| {
                const after_depth = skipWhitespace(trimmed, d_idx + 5);
                var num_start = after_depth;
                if (after_depth < trimmed.len and trimmed[after_depth] == '=') {
                    num_start = skipWhitespace(trimmed, after_depth + 1);
                }
                var num_end = num_start;
                while (num_end < trimmed.len and std.ascii.isDigit(trimmed[num_end])) : (num_end += 1) {}
                if (num_end > num_start) {
                    if (std.fmt.parseInt(u32, trimmed[num_start..num_end], 10)) |val| {
                        // Enforce Invariant A-11 (max_depth <= 4)
                        hg.max_depth = @min(val, 4);
                    } else |_| {}
                }
            }
            return .{
                .kind = .harpy_graph_query,
                .harpy_graph = hg,
            };
        }

        const where_idx_opt = indexOfIgnoreCase(trimmed, "WHERE");
        if (where_idx_opt) |w_offset| {
            const after_where = skipWhitespace(trimmed, w_offset + 5);
            const where_clause = trimmed[after_where..];

            // Look for "id = <val>" or "subject_id = <val>"
            const eq_idx_opt = std.mem.indexOfScalar(u8, where_clause, '=');
            if (eq_idx_opt) |eq_pos| {
                const lhs = std.mem.trim(u8, where_clause[0..eq_pos], " \t\r\n");
                const rhs = std.mem.trim(u8, where_clause[eq_pos + 1 ..], " \t\r\n;");

                if (std.ascii.eqlIgnoreCase(lhs, "id") or std.ascii.eqlIgnoreCase(lhs, "subject_id")) {
                    if (std.mem.eql(u8, rhs, "?")) {
                        return .{
                            .kind = .select_by_id,
                            .is_parameterized = true,
                        };
                    }
                    if (parseU64(rhs)) |val| {
                        return .{
                            .kind = .select_by_id,
                            .select_id = val,
                            .is_parameterized = false,
                        };
                    }
                }
            }
        } else {
            // SELECT * FROM records without WHERE
            return .{ .kind = .select_all };
        }
    }

    // 3. Check UPDATE queries
    if (startsWithIgnoreCase(trimmed, "UPDATE")) {
        const where_idx_opt = indexOfIgnoreCase(trimmed, "WHERE");
        if (where_idx_opt) |w_offset| {
            const after_where = skipWhitespace(trimmed, w_offset + 5);
            const where_clause = trimmed[after_where..];

            const eq_idx_opt = std.mem.indexOfScalar(u8, where_clause, '=');
            if (eq_idx_opt) |eq_pos| {
                const lhs = std.mem.trim(u8, where_clause[0..eq_pos], " \t\r\n");
                const rhs = std.mem.trim(u8, where_clause[eq_pos + 1 ..], " \t\r\n;");

                if (std.ascii.eqlIgnoreCase(lhs, "id") or std.ascii.eqlIgnoreCase(lhs, "subject_id")) {
                    if (std.mem.eql(u8, rhs, "?")) {
                        return .{
                            .kind = .update_by_id,
                            .is_parameterized = true,
                        };
                    }
                    if (parseU64(rhs)) |val| {
                        return .{
                            .kind = .update_by_id,
                            .update_id = val,
                            .is_parameterized = false,
                        };
                    }
                }
            }
        }
        return .{
            .kind = .update_by_id,
            .is_parameterized = true,
        };
    }

    // 4. Check DELETE queries
    if (startsWithIgnoreCase(trimmed, "DELETE")) {
        const where_idx_opt = indexOfIgnoreCase(trimmed, "WHERE");
        if (where_idx_opt) |w_offset| {
            const after_where = skipWhitespace(trimmed, w_offset + 5);
            const where_clause = trimmed[after_where..];

            const eq_idx_opt = std.mem.indexOfScalar(u8, where_clause, '=');
            if (eq_idx_opt) |eq_pos| {
                const lhs = std.mem.trim(u8, where_clause[0..eq_pos], " \t\r\n");
                const rhs = std.mem.trim(u8, where_clause[eq_pos + 1 ..], " \t\r\n;");

                if (std.ascii.eqlIgnoreCase(lhs, "id") or std.ascii.eqlIgnoreCase(lhs, "subject_id")) {
                    if (std.mem.eql(u8, rhs, "?")) {
                        return .{
                            .kind = .delete_by_id,
                            .is_parameterized = true,
                        };
                    }
                    if (parseU64(rhs)) |val| {
                        return .{
                            .kind = .delete_by_id,
                            .delete_id = val,
                            .is_parameterized = false,
                        };
                    }
                }
            }
        }
        return .{
            .kind = .delete_by_id,
            .is_parameterized = true,
        };
    }

    // Default: Fallback to SQLite sidecar for complex SQL
    return .{ .kind = .unsupported_fallback };
}

// ── Unit Tests ──────────────────────────────────────────────────────────────

test "sql_router: routes insert tuple zero-copy" {
    const sql = "INSERT INTO records VALUES (4001, 999, 1, 2, 0, 1);";
    const res = routeSql(sql);
    try std.testing.expectEqual(QueryKind.insert_tuple, res.kind);
    try std.testing.expectEqual(@as(u64, 4001), res.insert_data.opcode);
    try std.testing.expectEqual(@as(u64, 999), res.insert_data.subject_id);
    try std.testing.expectEqual(@as(u64, 1), res.insert_data.predicate_id);
    try std.testing.expectEqual(@as(u64, 2), res.insert_data.target_id);
}

test "sql_router: routes select by id zero-copy" {
    const sql = "SELECT * FROM records WHERE id = 12345";
    const res = routeSql(sql);
    try std.testing.expectEqual(QueryKind.select_by_id, res.kind);
    try std.testing.expectEqual(@as(u64, 12345), res.select_id);
}

test "sql_router: routes complex sql to unsupported fallback" {
    const sql = "WITH RECURSIVE cte AS (SELECT 1) SELECT * FROM cte;";
    const res = routeSql(sql);
    try std.testing.expectEqual(QueryKind.unsupported_fallback, res.kind);
}

test "sql_router: routes harpy_query semantic search" {
    const sql = "SELECT * FROM harpy_query WHERE prompt = 'active inference' AND limit_k = 25;";
    const res = routeSql(sql);
    try std.testing.expectEqual(QueryKind.harpy_semantic_query, res.kind);
    try std.testing.expectEqualStrings("active inference", res.harpy_query.prompt);
    try std.testing.expectEqual(@as(usize, 25), res.harpy_query.limit_k);
}

test "sql_router: routes harpy_graph topological traversal with A-11 clamp" {
    const sql = "SELECT * FROM harpy_graph WHERE root = 'Quantum Graph' AND depth = 8;";
    const res = routeSql(sql);
    try std.testing.expectEqual(QueryKind.harpy_graph_query, res.kind);
    try std.testing.expectEqualStrings("Quantum Graph", res.harpy_graph.root_note);
    // Depth clamped to Invariant A-11 ceiling (4)
    try std.testing.expectEqual(@as(u32, 4), res.harpy_graph.max_depth);
}
