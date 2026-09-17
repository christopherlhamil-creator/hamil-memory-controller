//! Memory Controller Dispatcher & 4-Signal Candidate Ranking
//!
//! Combines four independent scoring signals over stored cells and candidate records:
//!   1. Recency Signal: Temporal decay based on nanosecond timestamp deltas.
//!   2. Frequency Signal: Access and touch intensity using non-linear saturation.
//!   3. Semantic Cosine Similarity Signal: AVX2 SIMD zero-allocation cosine matching.
//!   4. Structural Graph Distance Signal: Topological hop distance from query anchor.
//!
//! Specifications & Architectural Invariants:
//!   - Invariant A-1: Strict 17,408B cell size (272 x 64B cache lines).
//!   - Invariant A-2: Strict 64B bytecode header (1 cache line).
//!   - Invariant A-11: 4-hop kill trigger (branch depth > 4 throws immediate refusal).
//!   - Invariant A-8: Intent overrules semantics.
//!   - Invariant A-31: ~1.3GB capacity planning observation (not a 1GB hard constraint).
//!   - Routing Signature Width: 48 bytes (ROUTING_FP_BYTES), frozen into fingerprints[0].
//!   - Zero Allocation: No dynamic heap allocation in any ranking or dispatch path.
//!   - Zero Shared ISA Pinning: Uses portable @Vector lowered per host.
//!
//! Toolchain: Zig 0.17 / Zig 0.16 compatible.

const std = @import("std");
const geometry = @import("geometry");
const simd = @import("simd.zig");
pub const gates = @import("gate_lattice_laws");

// ── Invariant Constants & Law ─────────────────────────────────────────────────

/// One 64-byte CPU cache line.
pub const CACHE_LINE_BYTES: usize = geometry.CACHE_LINE_BYTES;

/// Cache lines per cell (Invariant A-1).
pub const CELL_CACHE_LINES: usize = geometry.CELL_CACHE_LINES;

/// A cell is L1-resident and cache-line aligned: 272 x 64 = 17,408 bytes (Invariant A-1).
pub const CELL_BYTES: usize = geometry.CELL_BYTES; // 17,408

/// Uniform bytecode instruction header width (Invariant A-2).
pub const BYTECODE_HEADER_BYTES: usize = geometry.BYTECODE_HEADER_BYTES; // 64

/// Maximum recursive mitosis hop count before hard refusal (Invariant A-11).
pub const MAX_HOP_DEPTH: usize = geometry.MAX_HOP_DEPTH; // 4

/// Invariant A-31: ~1.3GB measured observation for capacity planning, not a 1GB hard constraint.
pub const MODEL_CAPACITY_OBSERVATION_BYTES: usize = geometry.MODEL_CAPACITY_OBSERVATION_BYTES;

/// Routing signature width frozen into fingerprints[0] on write/touch path.
pub const ROUTING_FP_BYTES: usize = geometry.ROUTING_FP_BYTES; // 48

/// Maximum top-k candidates for bounded dispatcher queries.
pub const MAX_TOP_K: usize = 64;

comptime {
    std.debug.assert(CELL_BYTES == 17408);
    std.debug.assert(BYTECODE_HEADER_BYTES == 64);
    std.debug.assert(MAX_HOP_DEPTH == 4);
    std.debug.assert(ROUTING_FP_BYTES == 48);
}

// ── Errors ───────────────────────────────────────────────────────────────────

pub const ControllerError = error{
    /// Invariant A-11: 4-hop kill trigger fired. Branch depths > 4 are strictly prohibited.
    RefusalMaxHopExceeded,
    /// Invariant A-8: Intent overrules semantics. Candidate violates explicit intent constraint.
    IntentConstraintViolation,
    /// Candidate pool capacity exceeded.
    PoolExhausted,
    /// Query provided empty candidate set.
    EmptyCandidateSet,
    /// Invalid configuration or parameters.
    InvalidParameter,
};

/// Enforces Invariant A-11: 4-hop kill trigger refusal.
/// Any branching or graph traversal exceeding depth 4 is immediately aborted.
pub inline fn checkHopLimit(hop: usize) ControllerError!void {
    if (hop > MAX_HOP_DEPTH) {
        return ControllerError.RefusalMaxHopExceeded;
    }
}

// ── Storage Tier Taxonomy ───────────────────────────────────────────────────

pub const CandidateTier = enum(u8) {
    hot = 0,
    cold = 1,
    disk = 2,
};

// ── 4-Signal Configuration & Weights ────────────────────────────────────────

pub const SignalWeights = struct {
    /// Weight for temporal recency decay signal (default: 0.20).
    recency: f32 = 0.20,
    /// Weight for usage/access frequency signal (default: 0.20).
    frequency: f32 = 0.20,
    /// Weight for SIMD semantic cosine similarity signal (default: 0.40).
    semantic: f32 = 0.40,
    /// Weight for structural graph topological distance signal (default: 0.20).
    structural: f32 = 0.20,

    /// Half-life in nanoseconds for recency exponential/harmonic decay (default: 60s).
    recency_half_life_ns: u64 = 60 * std.time.ns_per_s,
    /// Half-saturation access count for frequency signal (default: 10 touches).
    frequency_half_saturation: u32 = 10,

    pub fn validate(self: *const SignalWeights) bool {
        const sum = self.recency + self.frequency + self.semantic + self.structural;
        return @abs(sum - 1.0) <= 0.001 and self.recency >= 0.0 and self.frequency >= 0.0 and self.semantic >= 0.0 and self.structural >= 0.0;
    }
};

// ── Individual Signal Calculators ───────────────────────────────────────────

/// SIGNAL 1: Recency Signal (Temporal Proximity).
/// Bounded strictly to [0.0, 1.0].
/// If candidate is at or newer than query timestamp, score is 1.0.
/// Decays monotonically with time elapsed: S = 1.0 / (1.0 + delta_ns / half_life_ns).
pub fn computeRecencyScore(query_timestamp_ns: u64, cand_timestamp_ns: u64, half_life_ns: u64) f32 {
    if (cand_timestamp_ns >= query_timestamp_ns) return 1.0;
    if (half_life_ns == 0) return 0.0;

    const delta_ns = query_timestamp_ns - cand_timestamp_ns;
    const ratio = @as(f32, @floatFromInt(delta_ns)) / @as(f32, @floatFromInt(half_life_ns));
    const score = 1.0 / (1.0 + ratio);
    return std.math.clamp(score, 0.0, 1.0);
}

/// SIGNAL 2: Frequency Signal (Access Intensity).
/// Bounded strictly to [0.0, 1.0).
/// Uses Hill/saturation equation: S = access_count / (access_count + half_saturation).
/// S(0) = 0.0, S(half_saturation) = 0.5, S(inf) -> 1.0.
pub fn computeFrequencyScore(access_count: u32, half_saturation: u32) f32 {
    if (access_count == 0) return 0.0;
    if (half_saturation == 0) return 1.0;

    const count_f = @as(f32, @floatFromInt(access_count));
    const half_f = @as(f32, @floatFromInt(half_saturation));
    const score = count_f / (count_f + half_f);
    return std.math.clamp(score, 0.0, 1.0);
}

/// SIGNAL 3: Semantic Cosine Similarity Signal (SIMD Vector Matching).
/// Bounded strictly to [0.0, 1.0].
/// Uses AVX2 SIMD dot product kernel to evaluate cosine similarity between 48-byte
/// routing vectors, normalizing raw cosine similarity [-1.0, 1.0] to [0.0, 1.0].
pub fn computeSemanticScoreI8(query_fp: *const [ROUTING_FP_BYTES]i8, cand_fp: *const [ROUTING_FP_BYTES]i8) f32 {
    const raw_sim = simd.cosineSimilarityI8_48(query_fp, cand_fp);
    // Map [-1.0, 1.0] -> [0.0, 1.0]
    const normalized = (raw_sim + 1.0) * 0.5;
    return std.math.clamp(normalized, 0.0, 1.0);
}

/// SIGNAL 3 (F32 Alternative): Semantic Cosine Similarity for high-dimensional chunk embeddings.
pub fn computeSemanticScoreF32(query_vec: []const f32, cand_vec: []const f32) f32 {
    const raw_sim = simd.cosineSimilarityF32(query_vec, cand_vec);
    const normalized = (raw_sim + 1.0) * 0.5;
    return std.math.clamp(normalized, 0.0, 1.0);
}

/// SIGNAL 4: Structural Graph Distance Signal & 4-Hop Kill Trigger.
/// Bounded strictly to [0.0, 1.0].
/// ENFORCES INVARIANT A-11:
/// If hop_distance > MAX_HOP_DEPTH (4 hops), immediately returns RefusalMaxHopExceeded.
/// Valid hop distances [0, 4] produce linearly decreasing structural scores:
///   hop 0 -> 1.0 (self / exact anchor)
///   hop 1 -> 0.8 (direct neighbor)
///   hop 2 -> 0.6
///   hop 3 -> 0.4
///   hop 4 -> 0.2 (boundary limit)
///   hop >= 5 -> REFUSAL (Invariant A-11)
pub fn computeStructuralScore(hop_distance: usize) ControllerError!f32 {
    try checkHopLimit(hop_distance);

    const max_hop_f: f32 = @floatFromInt(MAX_HOP_DEPTH + 1); // 5.0
    const hop_f: f32 = @floatFromInt(hop_distance);
    const score = (max_hop_f - hop_f) / max_hop_f;
    return std.math.clamp(score, 0.0, 1.0);
}

// ── Candidate & Query Types ─────────────────────────────────────────────────

/// Candidate entry submitted for 4-signal ranking and dispatch.
pub const Candidate = struct {
    key: u64,
    class_key: u64 = 0,
    timestamp_ns: u64 = 0,
    access_count: u32 = 0,
    hop_distance: usize = 0,
    fingerprint: [ROUTING_FP_BYTES]i8 = std.mem.zeroes([ROUTING_FP_BYTES]i8),
    tier: CandidateTier = .hot,

    // Signal scoring outputs
    recency_score: f32 = 0.0,
    frequency_score: f32 = 0.0,
    semantic_score: f32 = 0.0,
    structural_score: f32 = 0.0,
    composite_score: f32 = 0.0,

    /// Intent verification flag (Invariant A-8: Intent overrules semantics)
    intent_matched: bool = true,
};

/// Query context containing target parameters for recall and dispatch.
pub const QueryContext = struct {
    timestamp_ns: u64,
    fingerprint: [ROUTING_FP_BYTES]i8,
    required_class_key: ?u64 = null,
    weights: SignalWeights = .{},
    max_hops: usize = MAX_HOP_DEPTH,
};

// ── Ranked Candidate Pool (Zero Allocation) ─────────────────────────────────

pub fn RankedPool(comptime capacity: usize) type {
    comptime std.debug.assert(capacity > 0);
    return struct {
        const Self = @This();

        items: [capacity]Candidate = undefined,
        count: usize = 0,

        pub fn init() Self {
            return .{ .count = 0 };
        }

        pub fn clear(self: *Self) void {
            self.count = 0;
        }

        /// Inserts candidate maintaining descending order of composite_score.
        pub fn insert(self: *Self, item: Candidate) void {
            if (self.count < capacity) {
                var pos: usize = 0;
                while (pos < self.count and self.items[pos].composite_score >= item.composite_score) : (pos += 1) {}
                var j: usize = self.count;
                while (j > pos) : (j -= 1) {
                    self.items[j] = self.items[j - 1];
                }
                self.items[pos] = item;
                self.count += 1;
            } else {
                if (item.composite_score <= self.items[capacity - 1].composite_score) return;
                var pos: usize = 0;
                while (pos < capacity and self.items[pos].composite_score >= item.composite_score) : (pos += 1) {}
                if (pos >= capacity) return;
                var j: usize = capacity - 1;
                while (j > pos) : (j -= 1) {
                    self.items[j] = self.items[j - 1];
                }
                self.items[pos] = item;
            }
        }

        pub fn slice(self: *const Self) []const Candidate {
            return self.items[0..self.count];
        }
    };
}

// ── Memory Controller Dispatcher ────────────────────────────────────────────

pub const DispatchStats = struct {
    scanned_count: usize = 0,
    ranked_count: usize = 0,
    vetoed_hop_count: usize = 0,
    vetoed_intent_count: usize = 0,
};

pub const MemoryController = struct {
    weights: SignalWeights,

    pub fn init(weights: SignalWeights) MemoryController {
        return .{
            .weights = weights,
        };
    }

    pub fn default() MemoryController {
        return .{
            .weights = .{},
        };
    }

    /// Evaluates all 4 signals for a single candidate.
    /// Strictly enforces Invariant A-11: throws RefusalMaxHopExceeded if hop_distance > 4.
    /// Strictly enforces Invariant A-8: marks intent_matched false or returns error on mismatch.
    pub fn scoreCandidate(
        self: *const MemoryController,
        query: *const QueryContext,
        cand: *Candidate,
    ) ControllerError!f32 {
        // Enforce Invariant A-11: 4-hop kill trigger refusal
        try checkHopLimit(cand.hop_distance);

        // Check query-specific max hop restriction
        if (cand.hop_distance > query.max_hops) {
            return ControllerError.RefusalMaxHopExceeded;
        }

        const weights = if (query.weights.validate()) query.weights else self.weights;

        // Signal 1: Recency
        cand.recency_score = computeRecencyScore(
            query.timestamp_ns,
            cand.timestamp_ns,
            weights.recency_half_life_ns,
        );

        // Signal 2: Frequency
        cand.frequency_score = computeFrequencyScore(
            cand.access_count,
            weights.frequency_half_saturation,
        );

        // Signal 3: Semantic Cosine Similarity
        cand.semantic_score = computeSemanticScoreI8(
            &query.fingerprint,
            &cand.fingerprint,
        );

        // Signal 4: Structural Graph Distance
        cand.structural_score = try computeStructuralScore(cand.hop_distance);

        // Invariant A-8: Intent overrules semantics
        if (query.required_class_key) |req_key| {
            if (cand.class_key != req_key) {
                cand.intent_matched = false;
                cand.composite_score = 0.0;
                return 0.0;
            }
        }
        cand.intent_matched = true;

        // Fused Composite Score
        const composite = (weights.recency * cand.recency_score) +
            (weights.frequency * cand.frequency_score) +
            (weights.semantic * cand.semantic_score) +
            (weights.structural * cand.structural_score);

        cand.composite_score = std.math.clamp(composite, 0.0, 1.0);
        return cand.composite_score;
    }

    /// Ranks candidates in-place or into `out_ranked`, sorted by composite_score descending.
    /// Drops candidates that fail intent constraints or trigger the 4-hop refusal.
    pub fn rankCandidates(
        self: *const MemoryController,
        query: *const QueryContext,
        candidates: []Candidate,
        out_ranked: []Candidate,
        stats: ?*DispatchStats,
    ) ControllerError!usize {
        if (candidates.len == 0) return ControllerError.EmptyCandidateSet;

        var valid_count: usize = 0;

        for (candidates) |*cand| {
            if (stats) |s| s.scanned_count += 1;

            // Enforce 4-hop kill trigger: skip or flag refusal
            if (cand.hop_distance > MAX_HOP_DEPTH or cand.hop_distance > query.max_hops) {
                if (stats) |s| s.vetoed_hop_count += 1;
                continue;
            }

            const score = self.scoreCandidate(query, cand) catch |err| switch (err) {
                ControllerError.RefusalMaxHopExceeded => {
                    if (stats) |s| s.vetoed_hop_count += 1;
                    continue;
                },
                else => return err,
            };

            // Invariant A-8: intent filter
            if (!cand.intent_matched) {
                if (stats) |s| s.vetoed_intent_count += 1;
                continue;
            }

            if (valid_count < out_ranked.len) {
                out_ranked[valid_count] = cand.*;
                out_ranked[valid_count].composite_score = score;
                valid_count += 1;
            }
        }

        // Sort descending by composite_score
        if (valid_count > 1) {
            std.mem.sort(Candidate, out_ranked[0..valid_count], {}, struct {
                fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                    return a.composite_score > b.composite_score;
                }
            }.lessThan);
        }

        if (stats) |s| s.ranked_count = valid_count;
        return valid_count;
    }

    /// Dispatches query and collects the top-K verified candidates into a RankedPool.
    /// Zero dynamic heap allocation.
    pub fn dispatchTopK(
        self: *const MemoryController,
        comptime K: usize,
        query: *const QueryContext,
        candidates: []const Candidate,
        stats: ?*DispatchStats,
    ) ControllerError!RankedPool(K) {
        var pool = RankedPool(K).init();

        for (candidates) |cand_in| {
            var cand = cand_in;
            if (stats) |s| s.scanned_count += 1;

            if (cand.hop_distance > MAX_HOP_DEPTH) {
                if (stats) |s| s.vetoed_hop_count += 1;
                continue;
            }

            const score = self.scoreCandidate(query, &cand) catch |err| switch (err) {
                ControllerError.RefusalMaxHopExceeded => {
                    if (stats) |s| s.vetoed_hop_count += 1;
                    continue;
                },
                else => return err,
            };

            if (!cand.intent_matched) {
                if (stats) |s| s.vetoed_intent_count += 1;
                continue;
            }

            cand.composite_score = score;
            pool.insert(cand);
        }

        if (stats) |s| s.ranked_count = pool.count;
        return pool;
    }
};

// ── Unit Tests & Comptime Assertions ─────────────────────────────────────────

test "comptime constants and invariants" {
    // Invariant A-1: 17,408B cell size
    try std.testing.expectEqual(@as(usize, 17408), CELL_BYTES);
    try std.testing.expectEqual(@as(usize, 272), CELL_CACHE_LINES);

    // Invariant A-2: 64B bytecode header
    try std.testing.expectEqual(@as(usize, 64), BYTECODE_HEADER_BYTES);

    // Invariant A-11: 4-hop kill trigger
    try std.testing.expectEqual(@as(usize, 4), MAX_HOP_DEPTH);

    // Invariant A-31: ~1.3GB capacity planning observation
    try std.testing.expectEqual(@as(usize, 1395864371), MODEL_CAPACITY_OBSERVATION_BYTES);

    // Routing vector dimension
    try std.testing.expectEqual(@as(usize, 48), ROUTING_FP_BYTES);
}

test "Signal 1: Recency scoring decay" {
    const t_now: u64 = 1_000_000_000_000;
    const half_life: u64 = 60 * std.time.ns_per_s;

    // Identical or future timestamp -> 1.0
    const s_curr = computeRecencyScore(t_now, t_now, half_life);
    try std.testing.expectEqual(@as(f32, 1.0), s_curr);

    const s_future = computeRecencyScore(t_now, t_now + 5000, half_life);
    try std.testing.expectEqual(@as(f32, 1.0), s_future);

    // Exactly 1 half-life in the past -> 0.5
    const s_half = computeRecencyScore(t_now, t_now - half_life, half_life);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s_half, 0.001);

    // 2 half-lives in the past -> 1/3 ~ 0.333
    const s_two_half = computeRecencyScore(t_now, t_now - (2 * half_life), half_life);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3333), s_two_half, 0.001);

    // Strict monotonic decrease with age
    try std.testing.expect(s_curr > s_half);
    try std.testing.expect(s_half > s_two_half);
}

test "Signal 2: Frequency scoring saturation" {
    const half_sat: u32 = 10;

    // 0 touches -> 0.0
    try std.testing.expectEqual(@as(f32, 0.0), computeFrequencyScore(0, half_sat));

    // Exactly half_sat touches -> 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), computeFrequencyScore(10, half_sat), 0.001);

    // 90 touches -> 90 / 100 = 0.9
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), computeFrequencyScore(90, half_sat), 0.001);

    // Monotonic increase
    const f1 = computeFrequencyScore(5, half_sat);
    const f2 = computeFrequencyScore(15, half_sat);
    const f3 = computeFrequencyScore(50, half_sat);
    try std.testing.expect(f1 < f2);
    try std.testing.expect(f2 < f3);
}

test "Signal 3: Semantic Cosine Similarity scoring" {
    var query_fp = std.mem.zeroes([ROUTING_FP_BYTES]i8);
    var cand_same = std.mem.zeroes([ROUTING_FP_BYTES]i8);
    var cand_opp = std.mem.zeroes([ROUTING_FP_BYTES]i8);
    var cand_ortho = std.mem.zeroes([ROUTING_FP_BYTES]i8);

    @memset(&query_fp, 4);
    @memset(&cand_same, 4);
    @memset(&cand_opp, -4);

    // Identical -> cosine similarity 1.0 -> normalized score 1.0
    const s_same = computeSemanticScoreI8(&query_fp, &cand_same);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s_same, 0.001);

    // Opposite -> cosine similarity -1.0 -> normalized score 0.0
    const s_opp = computeSemanticScoreI8(&query_fp, &cand_opp);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s_opp, 0.001);

    // Orthogonal -> cosine similarity 0.0 -> normalized score 0.5
    @memset(&query_fp, 0);
    query_fp[0] = 10;
    cand_ortho[1] = 10;
    const s_ortho = computeSemanticScoreI8(&query_fp, &cand_ortho);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s_ortho, 0.001);
}

test "Signal 4 & Invariant A-11: Structural Graph Distance and 4-Hop Kill Trigger" {
    // Valid hops [0..4] must pass and yield valid scores
    const s0 = try computeStructuralScore(0);
    const s1 = try computeStructuralScore(1);
    const s2 = try computeStructuralScore(2);
    const s3 = try computeStructuralScore(3);
    const s4 = try computeStructuralScore(4);

    try std.testing.expectEqual(@as(f32, 1.0), s0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), s1, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), s2, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), s3, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), s4, 0.001);

    // Monotonically decreasing with hop distance
    try std.testing.expect(s0 > s1);
    try std.testing.expect(s1 > s2);
    try std.testing.expect(s2 > s3);
    try std.testing.expect(s3 > s4);

    // 4-HOP KILL TRIGGER: 5th hop and beyond MUST throw immediate refusal
    try std.testing.expectError(ControllerError.RefusalMaxHopExceeded, computeStructuralScore(5));
    try std.testing.expectError(ControllerError.RefusalMaxHopExceeded, computeStructuralScore(6));
    try std.testing.expectError(ControllerError.RefusalMaxHopExceeded, computeStructuralScore(100));
    try std.testing.expectError(ControllerError.RefusalMaxHopExceeded, checkHopLimit(5));
}

test "4-Signal Candidate Ranking: multi-candidate fusion ordering" {
    const ctrl = MemoryController.default();
    const t_now: u64 = 1_000_000_000_000;

    var query = QueryContext{
        .timestamp_ns = t_now,
        .fingerprint = std.mem.zeroes([ROUTING_FP_BYTES]i8),
        .weights = .{
            .recency = 0.25,
            .frequency = 0.25,
            .semantic = 0.25,
            .structural = 0.25,
        },
    };
    @memset(&query.fingerprint, 10);

    // Candidate A: Perfect across all 4 signals
    const cand_a = Candidate{
        .key = 100,
        .timestamp_ns = t_now,
        .access_count = 100,
        .hop_distance = 0,
        .fingerprint = query.fingerprint,
    };

    // Candidate B: High semantic, low recency/frequency
    const cand_b = Candidate{
        .key = 200,
        .timestamp_ns = t_now - (300 * std.time.ns_per_s),
        .access_count = 1,
        .hop_distance = 2,
        .fingerprint = query.fingerprint,
    };

    // Candidate C: Zero semantic, moderate recency
    var cand_c = Candidate{
        .key = 300,
        .timestamp_ns = t_now - (10 * std.time.ns_per_s),
        .access_count = 5,
        .hop_distance = 1,
    };
    @memset(&cand_c.fingerprint, -10);

    // Candidate D: 4-hop kill trigger refusal candidate (hop = 5)
    const cand_d = Candidate{
        .key = 400,
        .timestamp_ns = t_now,
        .access_count = 50,
        .hop_distance = 5, // Triggers Invariant A-11 refusal
    };

    var input = [_]Candidate{ cand_c, cand_b, cand_a, cand_d };
    var ranked: [4]Candidate = undefined;
    var stats = DispatchStats{};

    const count = try ctrl.rankCandidates(&query, &input, &ranked, &stats);

    // Candidate D must be vetoed by 4-hop kill trigger refusal
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(usize, 1), stats.vetoed_hop_count);

    // Candidate A must rank #1 (highest composite score)
    try std.testing.expectEqual(@as(u64, 100), ranked[0].key);
    try std.testing.expect(ranked[0].composite_score > ranked[1].composite_score);
    try std.testing.expect(ranked[1].composite_score > ranked[2].composite_score);
}

test "Invariant A-8: Intent overrules semantics" {
    const ctrl = MemoryController.default();
    const t_now: u64 = 5_000_000_000;

    var query = QueryContext{
        .timestamp_ns = t_now,
        .fingerprint = std.mem.zeroes([ROUTING_FP_BYTES]i8),
        .required_class_key = 0xAAAA, // Intent law: only class 0xAAAA allowed
    };
    @memset(&query.fingerprint, 5);

    // Candidate 1: 100% semantic match, but mismatched class key
    const cand_mismatch = Candidate{
        .key = 1,
        .class_key = 0xBBBB, // Mismatch!
        .timestamp_ns = t_now,
        .access_count = 10,
        .hop_distance = 0,
        .fingerprint = query.fingerprint,
    };

    // Candidate 2: Moderate semantic match, but matching class key
    const cand_match = Candidate{
        .key = 2,
        .class_key = 0xAAAA, // Matching intent!
        .timestamp_ns = t_now,
        .access_count = 10,
        .hop_distance = 0,
        .fingerprint = std.mem.zeroes([ROUTING_FP_BYTES]i8),
    };

    var input = [_]Candidate{ cand_mismatch, cand_match };
    var ranked: [2]Candidate = undefined;
    var stats = DispatchStats{};

    const count = try ctrl.rankCandidates(&query, &input, &ranked, &stats);

    // Only cand_match survives; cand_mismatch is vetoed by intent
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u64, 2), ranked[0].key);
    try std.testing.expectEqual(@as(usize, 1), stats.vetoed_intent_count);
}

test "Dispatcher Top-K selection with zero allocation" {
    const ctrl = MemoryController.default();
    const t_now: u64 = 100_000 * std.time.ns_per_s;

    var query = QueryContext{
        .timestamp_ns = t_now,
        .fingerprint = std.mem.zeroes([ROUTING_FP_BYTES]i8),
    };
    @memset(&query.fingerprint, 2);

    var candidates: [20]Candidate = undefined;
    for (&candidates, 0..) |*c, i| {
        c.* = Candidate{
            .key = i + 1,
            .timestamp_ns = t_now - (i * 10 * std.time.ns_per_s),
            .access_count = @as(u32, @intCast(20 - i)),
            .hop_distance = i % 5, // 0..4 (all valid)
        };
        @memset(&c.fingerprint, @as(i8, @truncate(@as(isize, @bitCast(i)))));
    }

    // Add 2 invalid candidates with hop = 5 and hop = 7
    candidates[18].hop_distance = 5;
    candidates[19].hop_distance = 7;

    var stats = DispatchStats{};
    const top4 = try ctrl.dispatchTopK(4, &query, &candidates, &stats);

    // Out of 20, 2 vetoed by 4-hop trigger
    try std.testing.expectEqual(@as(usize, 4), top4.count);
    try std.testing.expectEqual(@as(usize, 2), stats.vetoed_hop_count);

    // Verify descending order
    const hits = top4.slice();
    try std.testing.expect(hits[0].composite_score >= hits[1].composite_score);
    try std.testing.expect(hits[1].composite_score >= hits[2].composite_score);
    try std.testing.expect(hits[2].composite_score >= hits[3].composite_score);
}

// ── Cactus MCP Router C-ABI Bindings ─────────────────────────────────────────

/// Binds directly into the Cactus MCP Tool router execution path via clean C-ABI link.
/// Validates compile-time and fast runtime gate lattice laws before memory operations.
pub export fn mcp_route_validate_header(
    opcode: u64,
    sub_ptr: [*]const u8,
    pred_ptr: [*]const u8,
    targ_ptr: [*]const u8,
    flags: u32,
    epoch: u32,
    current_system_epoch: u32,
) callconv(.c) i32 {
    var header: gates.InstructionHeader = undefined;
    header.opcode = opcode;
    @memcpy(&header.subject_id, sub_ptr[0..16]);
    @memcpy(&header.predicate_id, pred_ptr[0..16]);
    @memcpy(&header.target_id, targ_ptr[0..16]);
    header.flags = flags;
    header.epoch = epoch;

    gates.evaluate_gate_lattice_laws(&header, current_system_epoch) catch |err| switch (err) {
        error.MachineAuthorRefused => return 1,
        error.CapabilityBitmaskMissing => return 2,
        error.HumanReviewViolation => return 3,
        error.SqliteLockTaxLeak => return 4,
        else => return 5,
    };

    return 0; // Return zero code implies validation passed successfully
}

test "mcp_route_validate_header C-ABI exports" {
    var sub: [16]u8 = @splat(0);
    @memcpy(sub[0..5], "human");
    var pred: [16]u8 = @splat(0);
    var targ: [16]u8 = @splat(0);

    // 1. Valid human header
    const rc_ok = mcp_route_validate_header(
        0x0A01,
        &sub,
        &pred,
        &targ,
        @intFromEnum(gates.CapabilityFlags.HUB_WRITE),
        100,
        100,
    );
    try std.testing.expectEqual(@as(i32, 0), rc_ok);

    // 2. Machine author refused
    var machine_sub: [16]u8 = gates.machine_identities[0];
    const rc_machine = mcp_route_validate_header(
        0x0A01,
        &machine_sub,
        &pred,
        &targ,
        @intFromEnum(gates.CapabilityFlags.HUB_WRITE),
        100,
        100,
    );
    try std.testing.expectEqual(@as(i32, 1), rc_machine);

    // 3. Capability bitmask missing
    const rc_nocap = mcp_route_validate_header(
        0x0A01,
        &sub,
        &pred,
        &targ,
        0, // Missing HUB_WRITE
        100,
        100,
    );
    try std.testing.expectEqual(@as(i32, 2), rc_nocap);

    // 4. Human review violation
    const rc_rev = mcp_route_validate_header(
        0x0A01,
        &sub,
        &pred,
        &targ,
        @intFromEnum(gates.CapabilityFlags.HUB_WRITE) | @intFromEnum(gates.CapabilityFlags.HUMAN_REVIEWED),
        100,
        100,
    );
    try std.testing.expectEqual(@as(i32, 3), rc_rev);
}
