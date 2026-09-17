//! Baremetal Markdown Vault & Wikilink Graph Ingestion Engine
//!
//! Subsystem: tot_hybrid/src/vault_graph.zig
//!
//! Council directive 2026-09-08 -- Seat 1 (council-sonnet), "Brain 2" of the
//! two-brain baremetal architecture: Christopher's mandate is to leave
//! Obsidian's Electron/JS-GC vault behind and keep only its graph function,
//! re-implemented in pure Zig with no allocation on the hot parsing path.
//! This module reads the same on-disk vault format Obsidian uses --
//! Markdown notes with `---`-delimited YAML frontmatter and `[[wikilinks]]`
//! -- and turns it into an in-memory graph plus, per node, an exact
//! Invariant A-1/A-2 cell.
//!
//! Scope of THIS file: frontmatter + wikilink parsing, the in-memory
//! VaultGraph (adjacency + lookup), and the node -> cell converter. It does
//! NOT implement graph_layout.zig's SIMD force-directed layout or the
//! cockpit's Braille canvas render -- those are separate deliverables this
//! module exists to feed with a VaultNode/VaultGraph it can query.
//!
//! Architectural Invariants enforced:
//!   - Invariant A-1: Strict 17,408B cell size (272 x 64B cache lines).
//!   - Invariant A-2: Strict 64B bytecode header (1 cache line).
//!   - Invariant A-11: 4-hop traversal ceiling. This doubles as the
//!     circular-wikilink safety net: `navigateGraph` cannot loop forever on
//!     a cycle (A -> B -> A) because BFS depth is monotonically
//!     non-decreasing and hard-capped at MAX_HOP_DEPTH -- the exact
//!     mechanism src/lsp_indexer.zig already uses for call-graph traversal.
//!     There is no separate "visited node" bookkeeping because the hop
//!     ceiling already makes one unnecessary; this is intentional, not an
//!     oversight (see the circular-link test below).
//!
//! Parsing is zero-copy: `VaultNode.id`, `.title`, `.status`, `.body`, and
//! wikilink target/alias text are all slices into the caller-owned source
//! buffer, never copied. The one place bytes are actually copied is the
//! explicit node -> Cell converter (`packNodeToCell`), because a Cell is a
//! fixed-layout owned buffer by definition (Invariant A-1) -- the same
//! "collapse to compact form" boundary every other subsystem in this
//! repo (`lexicon.zig`, `b2b_pack.zig`, `lsp_indexer.zig`) draws.
//!
//! Toolchain: Zig 0.17.

const std = @import("std");
const geometry = @import("geometry");

// ── Compile-time invariant re-exports & assertions ──────────────────────────

pub const CELL_BYTES: usize = geometry.CELL_BYTES;
pub const BYTECODE_HEADER_BYTES: usize = geometry.BYTECODE_HEADER_BYTES;
pub const MAX_HOP_DEPTH: usize = geometry.MAX_HOP_DEPTH;
pub const SEMANTIC_PAYLOAD_BYTES: usize = geometry.SEMANTIC_PAYLOAD_BYTES;

comptime {
    std.debug.assert(CELL_BYTES == 17408);
    std.debug.assert(BYTECODE_HEADER_BYTES == 64);
    std.debug.assert(MAX_HOP_DEPTH == 4);
    std.debug.assert(SEMANTIC_PAYLOAD_BYTES == 960);
}

// ── Errors ───────────────────────────────────────────────────────────────────

pub const VaultError = error{
    /// Invariant A-11: traversal depth would exceed 4 hops.
    RefusalMaxHopExceeded,
    /// `VaultGraph`'s fixed node table is full.
    TooManyNodes,
    /// `VaultGraph`'s fixed edge table is full.
    TooManyEdges,
    /// A note declared more tags than `MAX_TAGS_PER_NODE`.
    TooManyTags,
    /// `findNode`/`navigateGraph` could not resolve an id.
    NodeNotFound,
    /// A node's packed cell content would not fit in the fixed layout.
    BufferTooSmall,
};

// ── Tunables ─────────────────────────────────────────────────────────────────

pub const MAX_TAGS_PER_NODE: usize = 8;

// ── Frontmatter + wikilink data model (zero-copy) ───────────────────────────

/// A parsed vault note. Every `[]const u8` field is a slice into the source
/// buffer `addNote` was called with (or, for `id`, possibly the caller's
/// `fallback_id` when the note has no explicit frontmatter `id:`) -- no
/// bytes are copied during parsing.
pub const VaultNode = struct {
    id: []const u8,
    title: []const u8,
    tags: [MAX_TAGS_PER_NODE][]const u8 = undefined,
    tag_count: usize = 0,
    status: []const u8,
    score: f64,
    body: []const u8,
    /// FNV-1a split hash of `id`, used for fast table lookups and as the
    /// packed cell's `subject_id`.
    subject_id: [16]u8,
};

/// A directed edge extracted from a `[[wikilink]]` (or `[[Target|Alias]]`)
/// found in a note's body. `target_id` is the raw link text as written --
/// resolution against an actual node (or discovering it is a dangling
/// link) is `findNode`'s job, not the scanner's.
pub const VaultEdge = struct {
    source_id: []const u8,
    target_id: []const u8,
    alias: ?[]const u8,
    source_subject_id: [16]u8,
    target_subject_id: [16]u8,
};

// ── FNV-1a split hash (subject id) ──────────────────────────────────────────
//
// Same construction as lsp_indexer.zig's HeaderEncoder.makeSubjectId (two
// independent 64-bit FNV-1a lanes concatenated into 128 bits) -- duplicated
// locally rather than imported so this module's only dependency stays
// `geometry`, matching the task's stated file scope.

pub fn makeSubjectId(name: []const u8) [16]u8 {
    var id: [16]u8 = @splat(0);
    var h1: u64 = 0xcbf29ce484222325;
    var h2: u64 = 0x100000001b3;
    for (name) |b| {
        h1 = (h1 ^ b) *% 0x100000001b3;
        h2 = (h2 ^ (b +% 0x55)) *% 0xcbf29ce484222325;
    }
    std.mem.writeInt(u64, id[0..8], h1, .little);
    std.mem.writeInt(u64, id[8..16], h2, .little);
    return id;
}

// ── Frontmatter parsing ──────────────────────────────────────────────────────

const ParsedFrontmatter = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    tags: [MAX_TAGS_PER_NODE][]const u8 = undefined,
    tag_count: usize = 0,
    status: []const u8 = "",
    score: f64 = 0.0,
    /// Everything after the closing `---` delimiter (or the whole source,
    /// if there was no frontmatter block at all).
    body: []const u8 = "",
};

fn isDelimiterLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return std.mem.eql(u8, trimmed, "---");
}

/// Parses `[a, b, c]` or `a, b, c` into up to `MAX_TAGS_PER_NODE` slices
/// (zero-copy, sliced from `value`). Returns the number of tags parsed;
/// extras beyond capacity are dropped (not silently -- callers of
/// `parseFrontmatter` can compare against a re-count if they need to know).
fn parseInlineTags(value: []const u8, out: *[MAX_TAGS_PER_NODE][]const u8) usize {
    var v = std.mem.trim(u8, value, " \t\r");
    if (v.len >= 2 and v[0] == '[' and v[v.len - 1] == ']') {
        v = std.mem.trim(u8, v[1 .. v.len - 1], " \t\r");
    }
    if (v.len == 0) return 0;

    var count: usize = 0;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |raw| {
        if (count >= out.len) break;
        var tag = std.mem.trim(u8, raw, " \t\r");
        if (tag.len >= 2 and ((tag[0] == '"' and tag[tag.len - 1] == '"') or
            (tag[0] == '\'' and tag[tag.len - 1] == '\'')))
        {
            tag = tag[1 .. tag.len - 1];
        }
        if (tag.len == 0) continue;
        out[count] = tag;
        count += 1;
    }
    return count;
}

/// Parses the `---`-delimited YAML-ish frontmatter block at the start of a
/// note plus the body that follows. Recognizes `id`, `title`, `tags`
/// (inline `[a, b]`/`a, b` or a block list of `- tag` lines), `status`, and
/// `score`. Unrecognized keys are ignored (not an error -- this is a
/// deliberately small subset of YAML, not a general parser). If the source
/// does not open with a `---` delimiter line, there is no frontmatter and
/// the entire source is the body.
pub fn parseFrontmatter(source: []const u8) ParsedFrontmatter {
    var result = ParsedFrontmatter{ .body = source };

    var lines = std.mem.splitScalar(u8, source, '\n');
    const first = lines.next() orelse return result;
    if (!isDelimiterLine(first)) return result;

    var body_start: usize = first.len + 1; // account for the consumed '\n'
    var closed = false;

    while (lines.next()) |line| {
        const consumed = line.len + 1; // this line + its '\n'
        if (isDelimiterLine(line)) {
            body_start += consumed;
            closed = true;
            break;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            body_start += consumed;
            continue;
        };
        const key = std.mem.trim(u8, line[0..colon], " \t\r");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");

        if (std.mem.eql(u8, key, "id")) {
            result.id = value;
        } else if (std.mem.eql(u8, key, "title")) {
            result.title = value;
        } else if (std.mem.eql(u8, key, "status")) {
            result.status = value;
        } else if (std.mem.eql(u8, key, "score")) {
            result.score = std.fmt.parseFloat(f64, value) catch 0.0;
        } else if (std.mem.eql(u8, key, "tags")) {
            if (value.len > 0) {
                result.tag_count = parseInlineTags(value, &result.tags);
            } else {
                // Block-list style:
                //   tags:
                //     - alpha
                //     - beta
                var block_count: usize = 0;
                var lookahead = lines;
                var lookahead_advance: usize = 0;
                while (lookahead.next()) |maybe_item| {
                    const item_trimmed = std.mem.trim(u8, maybe_item, " \t\r");
                    if (item_trimmed.len == 0 or item_trimmed[0] != '-') break;
                    if (isDelimiterLine(maybe_item)) break;
                    var item = std.mem.trim(u8, item_trimmed[1..], " \t\r");
                    if (item.len >= 2 and ((item[0] == '"' and item[item.len - 1] == '"') or
                        (item[0] == '\'' and item[item.len - 1] == '\'')))
                    {
                        item = item[1 .. item.len - 1];
                    }
                    if (block_count < result.tags.len and item.len > 0) {
                        result.tags[block_count] = item;
                        block_count += 1;
                    }
                    lookahead_advance += maybe_item.len + 1;
                }
                if (block_count > 0) {
                    result.tag_count = block_count;
                    // Actually advance the real iterator past the consumed
                    // block-list lines (the lookahead above only measured).
                    var skip: usize = 0;
                    while (skip < block_count) : (skip += 1) {
                        _ = lines.next();
                    }
                    body_start += lookahead_advance;
                }
            }
        }

        body_start += consumed;
    }

    if (!closed) {
        // Unterminated frontmatter block: treat the whole source as body
        // rather than guessing -- an honest degrade, not a silent one.
        return ParsedFrontmatter{ .body = source };
    }

    result.body = if (body_start <= source.len) source[body_start..] else "";
    return result;
}

// ── Wikilink scanning ────────────────────────────────────────────────────────

pub const WikilinkMatch = struct {
    target: []const u8,
    alias: ?[]const u8,
};

/// Iterator over `[[Target]]` / `[[Target|Alias]]` occurrences in a note
/// body. Flat scan -- does not support nested `[[...[[...]]...]]` brackets,
/// which is not a real Markdown/Obsidian construct anyway.
pub const WikilinkIterator = struct {
    body: []const u8,
    pos: usize = 0,

    pub fn next(self: *WikilinkIterator) ?WikilinkMatch {
        while (self.pos < self.body.len) {
            const open = std.mem.indexOfPos(u8, self.body, self.pos, "[[") orelse return null;
            const close = std.mem.indexOfPos(u8, self.body, open + 2, "]]") orelse {
                self.pos = self.body.len;
                return null;
            };
            const inner = self.body[open + 2 .. close];
            self.pos = close + 2;

            if (inner.len == 0) continue;
            if (std.mem.indexOfScalar(u8, inner, '|')) |pipe| {
                const target = std.mem.trim(u8, inner[0..pipe], " \t\r");
                const alias = std.mem.trim(u8, inner[pipe + 1 ..], " \t\r");
                if (target.len == 0) continue;
                return WikilinkMatch{ .target = target, .alias = alias };
            }
            const target = std.mem.trim(u8, inner, " \t\r");
            if (target.len == 0) continue;
            return WikilinkMatch{ .target = target, .alias = null };
        }
        return null;
    }
};

pub fn wikilinks(body: []const u8) WikilinkIterator {
    return .{ .body = body };
}

// ── In-memory graph ──────────────────────────────────────────────────────────

pub fn VaultGraph(comptime max_nodes: usize, comptime max_edges: usize) type {
    comptime {
        std.debug.assert(max_nodes > 0);
        std.debug.assert(max_edges > 0);
    }

    return struct {
        const Self = @This();

        nodes: [max_nodes]VaultNode = undefined,
        node_count: usize = 0,
        edges: [max_edges]VaultEdge = undefined,
        edge_count: usize = 0,

        /// Buffers this graph took ownership of via `ingestDirectory`
        /// (whole-file reads), freed by `deinit`. Notes added directly via
        /// `addNote` are the caller's memory and are not tracked here.
        owned_buffers: [max_nodes][]u8 = undefined,
        owned_count: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.owned_buffers[0..self.owned_count]) |buf| {
                allocator.free(buf);
            }
            self.owned_count = 0;
        }

        /// Parses `source` (a whole note's bytes: frontmatter + body) and
        /// registers it as a node, plus one edge per `[[wikilink]]` found
        /// in its body. `fallback_id` is used verbatim when the note has
        /// no frontmatter `id:` (typically the file's stem, supplied by
        /// the caller/directory walker). Zero-copy: every slice stored on
        /// the returned node/edges points into `source` (or `fallback_id`),
        /// which must outlive the graph.
        pub fn addNote(self: *Self, source: []const u8, fallback_id: []const u8) VaultError!*const VaultNode {
            if (self.node_count >= max_nodes) return VaultError.TooManyNodes;

            const fm = parseFrontmatter(source);
            const id = if (fm.id.len > 0) fm.id else fallback_id;

            var node = VaultNode{
                .id = id,
                .title = fm.title,
                .tag_count = fm.tag_count,
                .status = fm.status,
                .score = fm.score,
                .body = fm.body,
                .subject_id = makeSubjectId(id),
            };
            var i: usize = 0;
            while (i < fm.tag_count) : (i += 1) node.tags[i] = fm.tags[i];

            self.nodes[self.node_count] = node;
            const stored: *const VaultNode = &self.nodes[self.node_count];
            self.node_count += 1;

            var it = wikilinks(fm.body);
            while (it.next()) |link| {
                try self.addEdge(id, link.target, link.alias);
            }

            return stored;
        }

        fn addEdge(self: *Self, source_id: []const u8, target_id: []const u8, alias: ?[]const u8) VaultError!void {
            if (self.edge_count >= max_edges) return VaultError.TooManyEdges;
            self.edges[self.edge_count] = VaultEdge{
                .source_id = source_id,
                .target_id = target_id,
                .alias = alias,
                .source_subject_id = makeSubjectId(source_id),
                .target_subject_id = makeSubjectId(target_id),
            };
            self.edge_count += 1;
        }

        /// Fast(-ish) id lookup: O(node_count) bounded table scan comparing
        /// the 16-byte FNV subject-id hash first, falling back to an exact
        /// string compare only on a hash hit (guards against hash
        /// collision rather than trusting the hash blindly).
        pub fn findNode(self: *const Self, id: []const u8) ?*const VaultNode {
            const sid = makeSubjectId(id);
            for (self.nodes[0..self.node_count]) |*n| {
                if (std.mem.eql(u8, &n.subject_id, &sid) and std.mem.eql(u8, n.id, id)) {
                    return n;
                }
            }
            return null;
        }

        /// Populates `out` with outgoing edges from `id`; returns how many.
        pub fn edgesFrom(self: *const Self, id: []const u8, out: []VaultEdge) usize {
            const sid = makeSubjectId(id);
            var found: usize = 0;
            for (self.edges[0..self.edge_count]) |e| {
                if (found >= out.len) break;
                if (std.mem.eql(u8, &e.source_subject_id, &sid)) {
                    out[found] = e;
                    found += 1;
                }
            }
            return found;
        }

        /// Populates `out` with incoming edges to `id`; returns how many.
        pub fn edgesTo(self: *const Self, id: []const u8, out: []VaultEdge) usize {
            const sid = makeSubjectId(id);
            var found: usize = 0;
            for (self.edges[0..self.edge_count]) |e| {
                if (found >= out.len) break;
                if (std.mem.eql(u8, &e.target_subject_id, &sid)) {
                    out[found] = e;
                    found += 1;
                }
            }
            return found;
        }

        /// BFS from `from_id` to `to_id`, hard-capped at Invariant A-11's
        /// `MAX_HOP_DEPTH`. This is also the circular-wikilink guard: a
        /// cycle can requeue an already-seen node, but depth is
        /// monotonically non-decreasing along any queued path and capped,
        /// so the loop always terminates -- see the module doc comment.
        pub fn navigateGraph(self: *const Self, from_id: []const u8, to_id: []const u8) VaultError!u32 {
            const from = self.findNode(from_id) orelse return VaultError.NodeNotFound;
            const to = self.findNode(to_id) orelse return VaultError.NodeNotFound;

            if (std.mem.eql(u8, &from.subject_id, &to.subject_id)) return 0;

            const queue_cap = @min(max_edges + 1, 4096);
            var queue: [queue_cap][16]u8 = undefined;
            var depths: [queue_cap]u32 = undefined;
            var head: usize = 0;
            var tail: usize = 0;

            queue[tail] = from.subject_id;
            depths[tail] = 0;
            tail += 1;

            while (head < tail) {
                const cur_id = queue[head];
                const cur_depth = depths[head];
                head += 1;

                if (cur_depth >= MAX_HOP_DEPTH) continue;

                for (self.edges[0..self.edge_count]) |e| {
                    if (!std.mem.eql(u8, &e.source_subject_id, &cur_id)) continue;
                    if (std.mem.eql(u8, &e.target_subject_id, &to.subject_id)) {
                        return cur_depth + 1;
                    }
                    if (tail < queue.len) {
                        queue[tail] = e.target_subject_id;
                        depths[tail] = cur_depth + 1;
                        tail += 1;
                    }
                }
            }

            return VaultError.RefusalMaxHopExceeded;
        }

        /// Walks `dir_path` (non-recursive) for `*.md` files, reads each
        /// fully (the one unavoidable disk -> memory copy), and calls
        /// `addNote` with the file stem as `fallback_id`. The graph takes
        /// ownership of each file's buffer and frees it in `deinit`.
        /// Returns the number of notes ingested.
        pub fn ingestDirectory(
            self: *Self,
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
        ) !usize {
            var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
            defer dir.close(io);

            var ingested: usize = 0;
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
                if (self.owned_count >= self.owned_buffers.len) return VaultError.TooManyNodes;

                const buf = try dir.readFileAlloc(io, entry.name, allocator, .limited(SEMANTIC_PAYLOAD_BYTES * 64));
                self.owned_buffers[self.owned_count] = buf;
                self.owned_count += 1;

                const stem = entry.name[0 .. entry.name.len - 3]; // strip ".md"
                _ = try self.addNote(buf, stem);
                ingested += 1;
            }
            return ingested;
        }
    };
}

// ── Node -> Invariant A-1/A-2 cell converter ────────────────────────────────

pub const VaultOpcode = enum(u64) {
    /// This subsystem's own opcode space (4000s), deliberately far from
    /// lexicon.zig's LogicOp (1000s) and lsp_indexer.zig's LspOpcode
    /// (0x01..0x06) so a vault cell can never be mistaken for either.
    vault_node = 4001,
};

// provenance_flags layout for a vault_node cell (this module's own private
// scheme -- NOT the shared provenance.zig bit layout documented in
// geometry.zig; a vault cell is a self-contained representation and is
// never fed through provenance.zig's OutcomeKind/hop-count readers, so
// there is no bit collision. If that ever changes, this layout must be
// remapped onto geometry.PROV_* first, the same lesson mitosis.zig and
// provenance.zig already learned the hard way about bits 0..3.):
//   bits 0..15  (16): title_len
//   bits 16..31 (16): tags_blob_len
//   bits 32..47 (16): body_copied_len
//   bits 48..62 (15): reserved, always 0
//   bit  63     (1):  body_truncated flag
const TITLE_LEN_SHIFT: u6 = 0;
const TAGS_LEN_SHIFT: u6 = 16;
const BODY_LEN_SHIFT: u6 = 32;
const TRUNCATED_SHIFT: u6 = 63;

/// Bytes at the start of `semantic_payload` reserved for the note's true
/// (uncopied) body length, so a truncated cell never silently pretends
/// nothing was cut -- `unpackBodyTotalLen` always tells the truth even
/// when `unpackBody` had to stop early.
const PAYLOAD_META_BYTES: usize = 8;

/// Packs one `VaultNode` into an exact 17,408-byte cell (Invariant A-1)
/// with a 64-byte BytecodeHeader (Invariant A-2). Title and tags must fit
/// uncut; only the body is allowed to truncate (and the truncation is
/// always recorded, never silent -- see `unpackBodyTruncated`).
pub fn packNodeToCell(node: *const VaultNode, cell: *geometry.Cell) VaultError!void {
    cell.* = std.mem.zeroes(geometry.Cell);

    var tags_blob_buf: [MAX_TAGS_PER_NODE * 40]u8 = undefined;
    var tags_blob_len: usize = 0;
    {
        var i: usize = 0;
        while (i < node.tag_count) : (i += 1) {
            const tag = node.tags[i];
            if (i > 0) {
                if (tags_blob_len + 1 > tags_blob_buf.len) return VaultError.BufferTooSmall;
                tags_blob_buf[tags_blob_len] = ',';
                tags_blob_len += 1;
            }
            if (tags_blob_len + tag.len > tags_blob_buf.len) return VaultError.BufferTooSmall;
            @memcpy(tags_blob_buf[tags_blob_len .. tags_blob_len + tag.len], tag);
            tags_blob_len += tag.len;
        }
    }
    const tags_blob = tags_blob_buf[0..tags_blob_len];

    if (node.title.len > 0xFFFF or tags_blob.len > 0xFFFF) return VaultError.BufferTooSmall;
    const header_room = PAYLOAD_META_BYTES + node.title.len + tags_blob.len;
    if (header_room > SEMANTIC_PAYLOAD_BYTES) return VaultError.BufferTooSmall;

    const body_room = SEMANTIC_PAYLOAD_BYTES - header_room;
    const body_copied_len = @min(node.body.len, body_room);
    const truncated = body_copied_len < node.body.len;

    var predicate_op: [16]u8 = @splat(0);
    @memcpy(predicate_op[0..@min(node.status.len, 16)], node.status[0..@min(node.status.len, 16)]);

    var target_val: [16]u8 = @splat(0);
    target_val[0] = @intCast(node.tag_count);
    std.mem.writeInt(u64, target_val[4..12], @bitCast(node.score), .little);

    var flags: u64 = 0;
    flags |= (@as(u64, @intCast(node.title.len)) << TITLE_LEN_SHIFT);
    flags |= (@as(u64, @intCast(tags_blob.len)) << TAGS_LEN_SHIFT);
    flags |= (@as(u64, @intCast(body_copied_len)) << BODY_LEN_SHIFT);
    if (truncated) flags |= (@as(u64, 1) << TRUNCATED_SHIFT);

    cell.header = geometry.BytecodeHeader{
        .opcode = @intFromEnum(VaultOpcode.vault_node),
        .subject_id = geometry.LstSubjectId.fromHashBytes(node.subject_id).bytes,
        .predicate_op = predicate_op,
        .target_val = target_val,
        .provenance_flags = flags,
    };

    std.mem.writeInt(u64, cell.semantic_payload[0..8], @intCast(node.body.len), .little);
    var cursor: usize = PAYLOAD_META_BYTES;
    @memcpy(cell.semantic_payload[cursor .. cursor + node.title.len], node.title);
    cursor += node.title.len;
    @memcpy(cell.semantic_payload[cursor .. cursor + tags_blob.len], tags_blob);
    cursor += tags_blob.len;
    @memcpy(cell.semantic_payload[cursor .. cursor + body_copied_len], node.body[0..body_copied_len]);
}

pub fn unpackTitleLen(cell: *const geometry.Cell) u16 {
    return @truncate(cell.header.provenance_flags >> TITLE_LEN_SHIFT);
}

pub fn unpackTagsBlobLen(cell: *const geometry.Cell) u16 {
    return @truncate(cell.header.provenance_flags >> TAGS_LEN_SHIFT);
}

pub fn unpackBodyCopiedLen(cell: *const geometry.Cell) u16 {
    return @truncate(cell.header.provenance_flags >> BODY_LEN_SHIFT);
}

pub fn unpackBodyTruncated(cell: *const geometry.Cell) bool {
    return (cell.header.provenance_flags >> TRUNCATED_SHIFT) & 1 != 0;
}

pub fn unpackBodyTotalLen(cell: *const geometry.Cell) u64 {
    return std.mem.readInt(u64, cell.semantic_payload[0..8], .little);
}

pub fn unpackTitle(cell: *const geometry.Cell) []const u8 {
    const len = unpackTitleLen(cell);
    return cell.semantic_payload[PAYLOAD_META_BYTES .. PAYLOAD_META_BYTES + len];
}

pub fn unpackTagsBlob(cell: *const geometry.Cell) []const u8 {
    const title_len = unpackTitleLen(cell);
    const tags_len = unpackTagsBlobLen(cell);
    const start = PAYLOAD_META_BYTES + title_len;
    return cell.semantic_payload[start .. start + tags_len];
}

pub fn unpackBody(cell: *const geometry.Cell) []const u8 {
    const title_len = unpackTitleLen(cell);
    const tags_len = unpackTagsBlobLen(cell);
    const body_len = unpackBodyCopiedLen(cell);
    const start = PAYLOAD_META_BYTES + title_len + tags_len;
    return cell.semantic_payload[start .. start + body_len];
}

pub fn unpackScore(cell: *const geometry.Cell) f64 {
    return @bitCast(std.mem.readInt(u64, cell.header.target_val[4..12], .little));
}

pub fn unpackTagCount(cell: *const geometry.Cell) u8 {
    return cell.header.target_val[0];
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "frontmatter: id/title/status/score/inline tags parse and body is exact" {
    const source =
        \\---
        \\id: council-f11
        \\title: F11 Synthesis
        \\tags: [legal, lexicon, council]
        \\status: active
        \\score: 0.875
        \\---
        \\Body line one.
        \\Body line two with [[Some Note]].
    ;
    const fm = parseFrontmatter(source);
    try std.testing.expectEqualStrings("council-f11", fm.id);
    try std.testing.expectEqualStrings("F11 Synthesis", fm.title);
    try std.testing.expectEqualStrings("active", fm.status);
    try std.testing.expectApproxEqAbs(@as(f64, 0.875), fm.score, 1e-12);
    try std.testing.expectEqual(@as(usize, 3), fm.tag_count);
    try std.testing.expectEqualStrings("legal", fm.tags[0]);
    try std.testing.expectEqualStrings("lexicon", fm.tags[1]);
    try std.testing.expectEqualStrings("council", fm.tags[2]);
    try std.testing.expectEqualStrings("Body line one.\nBody line two with [[Some Note]].", fm.body);
}

test "frontmatter: block-list tags parse and remaining lines are not swallowed" {
    const source =
        \\---
        \\id: n1
        \\tags:
        \\  - alpha
        \\  - beta
        \\  - gamma
        \\status: draft
        \\---
        \\Rest of the body.
    ;
    const fm = parseFrontmatter(source);
    try std.testing.expectEqualStrings("n1", fm.id);
    try std.testing.expectEqualStrings("draft", fm.status);
    try std.testing.expectEqual(@as(usize, 3), fm.tag_count);
    try std.testing.expectEqualStrings("alpha", fm.tags[0]);
    try std.testing.expectEqualStrings("beta", fm.tags[1]);
    try std.testing.expectEqualStrings("gamma", fm.tags[2]);
    try std.testing.expectEqualStrings("Rest of the body.", fm.body);
}

test "frontmatter: no frontmatter block means the whole source is body" {
    const source = "Just a plain note with [[A Link]] and no frontmatter.";
    const fm = parseFrontmatter(source);
    try std.testing.expectEqualStrings("", fm.id);
    try std.testing.expectEqualStrings(source, fm.body);
}

test "frontmatter: unterminated block degrades honestly to whole-source body" {
    const source =
        \\---
        \\id: broken
        \\title: never closed
    ;
    const fm = parseFrontmatter(source);
    try std.testing.expectEqualStrings("", fm.id);
    try std.testing.expectEqualStrings(source, fm.body);
}

test "wikilinks: plain target, aliased target, and malformed/empty are handled" {
    const body = "See [[Target One]] and [[Target Two|Display Alias]] then [[]] then [[Target Three]].";
    var it = wikilinks(body);

    const m1 = it.next().?;
    try std.testing.expectEqualStrings("Target One", m1.target);
    try std.testing.expect(m1.alias == null);

    const m2 = it.next().?;
    try std.testing.expectEqualStrings("Target Two", m2.target);
    try std.testing.expectEqualStrings("Display Alias", m2.alias.?);

    const m3 = it.next().?;
    try std.testing.expectEqualStrings("Target Three", m3.target);
    try std.testing.expect(m3.alias == null);

    try std.testing.expect(it.next() == null);
}

test "wikilinks: unterminated [[ does not infinite loop or crash" {
    const body = "Dangling [[Never Closed";
    var it = wikilinks(body);
    try std.testing.expect(it.next() == null);
}

test "VaultGraph: addNote builds nodes and directed wikilink edges" {
    const Graph = VaultGraph(8, 32);
    var g = Graph.init();

    _ = try g.addNote(
        \\---
        \\id: alpha
        \\title: Alpha
        \\---
        \\Links to [[beta]] and [[Gamma|The Third]].
    , "alpha-fallback");
    _ = try g.addNote(
        \\---
        \\id: beta
        \\title: Beta
        \\---
        \\No outgoing links here.
    , "beta-fallback");

    try std.testing.expectEqual(@as(usize, 2), g.node_count);
    try std.testing.expectEqual(@as(usize, 2), g.edge_count);

    const alpha = g.findNode("alpha").?;
    try std.testing.expectEqualStrings("Alpha", alpha.title);

    var out: [8]VaultEdge = undefined;
    const n = g.edgesFrom("alpha", &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("beta", out[0].target_id);
    try std.testing.expectEqualStrings("Gamma", out[1].target_id);
    try std.testing.expectEqualStrings("The Third", out[1].alias.?);

    var incoming: [8]VaultEdge = undefined;
    const inc = g.edgesTo("beta", &incoming);
    try std.testing.expectEqual(@as(usize, 1), inc);
    try std.testing.expectEqualStrings("alpha", incoming[0].source_id);
}

test "VaultGraph: fallback id is used when frontmatter has no id" {
    const Graph = VaultGraph(4, 8);
    var g = Graph.init();
    _ = try g.addNote("No frontmatter at all, just prose.", "filename-stem");
    try std.testing.expectEqual(@as(usize, 1), g.node_count);
    const node = g.findNode("filename-stem").?;
    try std.testing.expectEqualStrings("", node.title);
}

test "VaultGraph: circular wikilinks (A -> B -> A) do not infinite-loop and resolve in bounds" {
    const Graph = VaultGraph(4, 8);
    var g = Graph.init();

    _ = try g.addNote(
        \\---
        \\id: nodeA
        \\---
        \\Points at [[nodeB]].
    , "a");
    _ = try g.addNote(
        \\---
        \\id: nodeB
        \\---
        \\Points back at [[nodeA]].
    , "b");

    // Direct cycle: A -> B is 1 hop, and the traversal terminates instead
    // of looping forever on B -> A -> B -> A ...
    const hops_a_to_b = try g.navigateGraph("nodeA", "nodeB");
    try std.testing.expectEqual(@as(u32, 1), hops_a_to_b);

    const hops_b_to_a = try g.navigateGraph("nodeB", "nodeA");
    try std.testing.expectEqual(@as(u32, 1), hops_b_to_a);

    // Self-navigation short-circuits at 0 hops without touching the queue.
    const hops_a_to_a = try g.navigateGraph("nodeA", "nodeA");
    try std.testing.expectEqual(@as(u32, 0), hops_a_to_a);
}

test "VaultGraph: navigateGraph enforces Invariant A-11 (5-hop chain refuses)" {
    const Graph = VaultGraph(8, 16);
    var g = Graph.init();

    _ = try g.addNote("---\nid: n0\n---\nTo [[n1]].", "n0");
    _ = try g.addNote("---\nid: n1\n---\nTo [[n2]].", "n1");
    _ = try g.addNote("---\nid: n2\n---\nTo [[n3]].", "n2");
    _ = try g.addNote("---\nid: n3\n---\nTo [[n4]].", "n3");
    _ = try g.addNote("---\nid: n4\n---\nTo [[n5]].", "n4");
    _ = try g.addNote("---\nid: n5\n---\nEnd.", "n5");

    try std.testing.expectEqual(@as(u32, 4), try g.navigateGraph("n0", "n4"));
    try std.testing.expectError(VaultError.RefusalMaxHopExceeded, g.navigateGraph("n0", "n5"));
}

test "VaultGraph: node/edge table overflow refuses instead of corrupting" {
    const Graph = VaultGraph(1, 1);
    var g = Graph.init();
    _ = try g.addNote("---\nid: only\n---\nplain, no links.", "only");
    try std.testing.expectError(VaultError.TooManyNodes, g.addNote("---\nid: second\n---\nbody.", "second"));
}

test "makeSubjectId distinguishes handleAuthenticationRequest from handleAuthenticationResponse" {
    const req = makeSubjectId("handleAuthenticationRequest");
    const res = makeSubjectId("handleAuthenticationResponse");
    try std.testing.expect(!std.mem.eql(u8, &req, &res));
}

test "packNodeToCell: exact 17,408B / 64B geometry and round-trip fidelity" {
    try std.testing.expectEqual(@as(usize, 17408), @sizeOf(geometry.Cell));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(geometry.BytecodeHeader));

    var node = VaultNode{
        .id = "council-f11",
        .title = "F11 Synthesis",
        .status = "active",
        .score = 0.875,
        .body = "The legal and intent lexicon synthesis body text.",
        .subject_id = makeSubjectId("council-f11"),
    };
    node.tags[0] = "legal";
    node.tags[1] = "lexicon";
    node.tag_count = 2;

    var cell: geometry.Cell = undefined;
    try packNodeToCell(&node, &cell);

    try std.testing.expectEqual(@as(u64, @intFromEnum(VaultOpcode.vault_node)), cell.header.opcode);
    try std.testing.expectEqualSlices(u8, &node.subject_id, &cell.header.subject_id);
    try std.testing.expectEqualStrings("active", std.mem.sliceTo(&cell.header.predicate_op, 0));
    try std.testing.expectEqual(@as(u8, 2), unpackTagCount(&cell));
    try std.testing.expectApproxEqAbs(@as(f64, 0.875), unpackScore(&cell), 1e-12);

    try std.testing.expectEqualStrings(node.title, unpackTitle(&cell));
    try std.testing.expectEqualStrings("legal,lexicon", unpackTagsBlob(&cell));
    try std.testing.expectEqualStrings(node.body, unpackBody(&cell));
    try std.testing.expect(!unpackBodyTruncated(&cell));
    try std.testing.expectEqual(@as(u64, node.body.len), unpackBodyTotalLen(&cell));
}

test "packNodeToCell: oversized body truncates honestly, never silently" {
    var big_body: [SEMANTIC_PAYLOAD_BYTES * 2]u8 = undefined;
    @memset(&big_body, 'x');

    var node = VaultNode{
        .id = "huge",
        .title = "Huge Note",
        .status = "active",
        .score = 0.0,
        .body = &big_body,
        .subject_id = makeSubjectId("huge"),
    };

    var cell: geometry.Cell = undefined;
    try packNodeToCell(&node, &cell);

    try std.testing.expect(unpackBodyTruncated(&cell));
    try std.testing.expectEqual(@as(u64, big_body.len), unpackBodyTotalLen(&cell));
    try std.testing.expect(unpackBody(&cell).len < big_body.len);
    for (unpackBody(&cell)) |b| try std.testing.expectEqual(@as(u8, 'x'), b);
}

test "ingestDirectory: reads *.md files from a real directory, ignores non-md, frees on deinit" {
    const io = std.testing.io;
    const dir_path = "/tmp/tot_hybrid_vault_graph_test_vault";

    std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_path ++ "/one.md",
        .data =
        \\---
        \\id: one
        \\title: One
        \\---
        \\Links to [[two]].
        ,
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_path ++ "/two.md",
        .data =
        \\---
        \\id: two
        \\title: Two
        \\---
        \\No links.
        ,
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir_path ++ "/ignore.txt",
        .data = "not a vault note",
    });

    const Graph = VaultGraph(8, 16);
    var g = Graph.init();
    const allocator = std.testing.allocator;
    defer g.deinit(allocator);

    const count = try g.ingestDirectory(allocator, io, dir_path);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 2), g.node_count);
    try std.testing.expectEqual(@as(usize, 1), g.edge_count);

    const one = g.findNode("one").?;
    try std.testing.expectEqualStrings("One", one.title);
    const two = g.findNode("two").?;
    try std.testing.expectEqualStrings("Two", two.title);
}
