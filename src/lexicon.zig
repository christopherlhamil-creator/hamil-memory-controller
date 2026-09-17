//! Living Lexicon — Closed Vocabulary, Relational Logic Operators, and Compressed Failure Scars
//!
//! Subsystem: tot_hybrid/src/lexicon.zig
//! Toolchain: Zig 0.17 compatible.
//!
//! Architectural Principles (Blackmagic F7, F8, F9, F10b, F11):
//!   1. "The lexicon isn't a dictionary. It's the compressed failures that make the next contract easier to write."
//!   2. Sentence -> Row: Intent over a subject's lexicon normalizes into an atomic 64-byte instruction
//!      tuple (term_a, relation, term_b, provenance). Terms are foreign keys; prose is reconstructible.
//!   3. Closed Vocabulary: Closed defect taxonomy & domain categories (CaseMark 883-skill aligned).
//!   4. Scar Tissue (CEGAR / Negative Selection): Runtime failures and contract violations are compiled
//!      into permanent geometric vetoes (separating predicates) rather than evicted.
//!   5. Adversarial Grill Integration: Accumulated scars sharpen the pointed questions asked by /grill-me.
//!   6. Backward Compatibility: Preserves the 90-entry 19th-century ground truth fixture for benchmark harnesses.

const std = @import("std");
const geometry = @import("geometry");

// ── Invariants ───────────────────────────────────────────────────────────────

pub const MAX_SCARS: usize = 2048;
pub const MAX_TERMS_PER_CATEGORY: usize = 128;

// ── 1. The 19th-Century Ground Truth Fixture (Preserved for Benchmarks) ──────

pub const WORDS = [_][]const u8{
    // Given names (55)
    "ALEXANDER", "EBENEZER",   "CORNELIUS",  "BARTHOLOMEW", "THEODORE",
    "NATHANIEL", "JEDEDIAH",   "ZACHARIAH",  "MONTGOMERY",  "WASHINGTON",
    "JEFFERSON", "ABIGAIL",    "PRUDENCE",   "TEMPERANCE",  "CONSTANCE",
    "JOSEPHINE", "CAROLINE",   "ELIZABETH",  "MARGARET",    "DEBORAH",
    "LAVINIA",   "ORLANDO",    "HORATIO",    "AUGUSTUS",    "PERCIVAL",
    "REGINALD",  "HUMPHREY",   "GODFREY",    "LEOPOLD",     "FREDERICK",
    "SEBASTIAN", "VALENTINE",  "ROSALIND",   "GERTRUDE",    "WILHELMINA",
    "MATILDA",   "BEATRICE",   "FLORENCE",   "CLEMENTINE",  "SUSANNAH",
    "PATIENCE",  "OBADIAH",    "ISAIAH",     "EZEKIEL",     "JEREMIAH",
    "NEHEMIAH",  "THADDEUS",   "AMBROSE",    "SILAS",       "ELIJAH",
    "JOSIAH",    "CALEB",      "EPHRAIM",    "GIDEON",      "BENEDICT",
    // Occupations (35)
    "BLACKSMITH", "COOPER",       "CARPENTER", "WHEELWRIGHT", "MIDWIFE",
    "CORDWAINER", "TANNER",       "MILLER",    "SEAMSTRESS",  "CHANDLER",
    "COBBLER",    "WEAVER",       "MASON",     "TAILOR",      "BUTCHER",
    "DISTILLER",  "TEAMSTER",     "FERRYMAN",  "SURVEYOR",    "APOTHECARY",
    "PHYSICIAN",  "MERCHANT",     "PEDDLER",   "PRINTER",     "ENGRAVER",
    "GUNSMITH",   "LOCKSMITH",    "MILLWRIGHT", "SHIPWRIGHT", "LAUNDRESS",
    "CONSTABLE",  "ENUMERATOR",   "MARSHAL",   "SCHOOLMASTER", "INNKEEPER",
};

pub fn contains(token: []const u8) bool {
    for (WORDS) |w| {
        if (std.mem.eql(u8, w, token)) return true;
    }
    return false;
}

pub fn containsIgnoreCase(token: []const u8) bool {
    for (WORDS) |w| {
        if (std.ascii.eqlIgnoreCase(w, token)) return true;
    }
    return false;
}

// ── Minimal Perfect Hash Generator ──────────────────────────────────────────

/// Comptime minimal perfect hash generator with bitmask popcount index compression.
/// Discovers a collision-free seed at compile time and compresses hash table slots
/// into a dense [0, N) index using bitwise popcount.
pub fn MinimalPerfectHash(comptime keys: []const []const u8) type {
    @setEvalBranchQuota(100_000);
    comptime {
        for (keys, 0..) |k1, i| {
            for (keys[i + 1 ..]) |k2| {
                if (std.mem.eql(u8, k1, k2)) {
                    @compileError("Duplicate key in MinimalPerfectHash: " ++ k1);
                }
            }
        }
    }

    const N = keys.len;
    const M: usize = if (N <= 16)
        64
    else if (N <= 32)
        128
    else if (N <= 64)
        256
    else if (N <= 128)
        1024
    else
        2048;

    const NUM_WORDS = M / 64;

    const hashFn = struct {
        fn hashWithSeed(key: []const u8, seed_val: u32) usize {
            var h: u32 = seed_val;
            for (key) |b| {
                h = (h ^ b) *% 0x01000193;
            }
            const mixed = h ^ (h >> 16);
            return @as(usize, mixed) % M;
        }
    }.hashWithSeed;

    const discovery = blk: {
        var found_seed: u32 = 1;
        while (found_seed < 100000) : (found_seed += 1) {
            var candidate_mask: [NUM_WORDS]u64 = @splat(0);
            var collision = false;

            for (keys) |key| {
                const slot = hashFn(key, found_seed);
                const word_idx = slot / 64;
                const bit_idx: u6 = @truncate(slot % 64);
                const bit = @as(u64, 1) << bit_idx;

                if ((candidate_mask[word_idx] & bit) != 0) {
                    collision = true;
                    break;
                }
                candidate_mask[word_idx] |= bit;
            }

            if (!collision) {
                break :blk .{ .seed = found_seed, .masks = candidate_mask };
            }
        }
        @compileError("Failed to find collision-free seed for MinimalPerfectHash");
    };

    const SEED = discovery.seed;
    const MASKS = discovery.masks;

    const entries = blk: {
        var table: [N][]const u8 = undefined;
        for (keys) |key| {
            const slot = hashFn(key, SEED);
            const word_idx = slot / 64;
            const bit_idx: u6 = @truncate(slot % 64);
            var rank: usize = 0;
            for (0..word_idx) |w| {
                rank += @popCount(MASKS[w]);
            }
            const mask = (@as(u64, 1) << bit_idx) -% 1;
            rank += @popCount(MASKS[word_idx] & mask);
            table[rank] = key;
        }
        break :blk table;
    };

    return struct {
        const Self = @This();
        pub const key_count: usize = N;
        pub const table_size: usize = M;
        pub const seed: u32 = SEED;
        pub const masks: [NUM_WORDS]u64 = MASKS;
        pub const table: [N][]const u8 = entries;

        /// Raw hash of a slice with the comptime discovered seed.
        pub fn hash(key: []const u8) usize {
            return hashFn(key, SEED);
        }

        /// Map a hash slot to a compact index [0, N) using bitmask popcount.
        pub fn mapToIndex(slot: usize) usize {
            if (slot >= M) return N;
            const word_idx = slot / 64;
            const bit_idx: u6 = @truncate(slot % 64);
            var rank: usize = 0;
            inline for (0..NUM_WORDS) |w| {
                if (w < word_idx) {
                    rank += @popCount(MASKS[w]);
                }
            }
            const mask = (@as(u64, 1) << bit_idx) -% 1;
            rank += @popCount(MASKS[word_idx] & mask);
            return rank;
        }

        /// Looks up a token in O(1) time. Returns the compressed index [0, N) if found, or null.
        pub fn lookup(token: []const u8) ?usize {
            const slot = hash(token);
            const word_idx = slot / 64;
            const bit_idx: u6 = @truncate(slot % 64);
            const bit = @as(u64, 1) << bit_idx;

            // 1. Bitmask presence test
            if ((MASKS[word_idx] & bit) == 0) {
                return null;
            }

            // 2. Bitmask popcount index compression
            const idx = mapToIndex(slot);
            if (idx >= N) return null;

            // 3. Exact match verification (reject false positives from non-vocabulary strings)
            if (std.mem.eql(u8, table[idx], token)) {
                return idx;
            }

            return null;
        }

        /// Returns true if token is in the closed vocabulary.
        pub fn contains(token: []const u8) bool {
            return lookup(token) != null;
        }
    };
}

/// Compile-time perfect hash instance for 19th-century ground truth fixture (90 words).
pub const WordsPerfectHash = MinimalPerfectHash(&WORDS);

// ── 2. Subject Categories & Closed Term Registry ────────────────────────────

pub const Category = enum(u8) {
    intent = 0,
    contract = 1,
    legal_audit = 2,
    memory_ctrl = 3,
    verification = 4,
    phonetic = 5,
};

pub const Term = struct {
    category: Category,
    token_id: [16]u8,
    canonical_name: []const u8,
    trigger_words: []const []const u8,

    pub fn makeId(name: []const u8) [16]u8 {
        var id: [16]u8 = @splat(0);
        const copy_len = @min(name.len, 16);
        @memcpy(id[0..copy_len], name[0..copy_len]);
        return id;
    }
};

// ── 3. Relational Logic Operators ───────────────────────────────────────────

pub const LogicOp = enum(u64) {
    assert_relation = 1001,
    contradicts = 1002,
    requires_gate = 1003,
    negative_affinity_veto = 1004,
    supersedes = 1005,
    grounded_in = 1006,
    mitosis_split = 1007,
    reconcile_match = 1008,

    pub fn toId16(self: LogicOp) [16]u8 {
        var id: [16]u8 = @splat(0);
        const name = @tagName(self);
        const copy_len = @min(name.len, 16);
        @memcpy(id[0..copy_len], name[0..copy_len]);
        return id;
    }
};

// ── 4. Closed Defect Taxonomy & Failure Scars (Scar Tissue) ──────────────────

pub const DefectClass = enum(u8) {
    ambiguity_scope = 1,          // Unhandled conditional or attachment ambiguity
    polysemic_conflict = 2,       // Contronym or multiple conflicting definitions
    missing_bound = 3,            // Missing boundary check or hop limit exceeded (>4)
    ungrounded_claim = 4,         // Assertion lacking verified cite_key / grounding
    machine_author_violation = 5, // Forbidden automated entity authoring conclusion
    foreign_pool_leak = 6,        // Attempted write to external sqlite/pool instead of memory ring
    stale_epoch_overwrite = 7,    // Stale fencing token violation
    // 5-Family Taxonomy from Week 28–36 Audits
    substrate_search_bug = 8,     // A-SUBSTRATE: pickaxe misread, git log missing --all, single-host search
    procedural_preflight_gap = 9, // B-DENOMINATOR: missing preflight, empty loop variable, timeout vs empty output
    unenforced_policy_gap = 10,   // C-UNENFORCED: 3-host search skipped, unmeasured assertion, paper-only rule
    hardware_boundary_breach = 11,// D-ARCHITECTURE: 17,408B L1d cache, 64B headers, 4-hop limit, ISA pinning
    ledger_epistemic_drift = 12,  // E-LEDGER-EPISTEMICS: concurrent append drift misread as refutation, spent cite
    // 48-Hour Audit Laws & Axioms (Session FFC759)
    gold_ocr_invented_standard = 13, // F-INVENTED-STANDARD: Agent inventing rules or gold standards without ground truth
    bare_agent_no_role = 14,         // G-BARE-AGENT: Agent without persistent role asking "what's next?" in a memory-loss loop
    python_fallback_mask = 15,       // H-PYTHON-FALLBACK: Script used as permanent fallback masking compiled pipeline bug
    vram_oversubscription = 16,      // I-VRAM-OVERSUB: Hosting multiple base models simultaneously in 12GB VRAM
    prompt_as_prose = 17,            // J-UNENFORCED-CONTRACT: Loose prose prompt instead of typed contract with preconditions
    forensic_substrate_inversion = 18,// K-SUBSTRATE-INVERSION: Coupling substrate to single app rather than general forensic compute
    silent_in_place_overwrite = 19,   // L-SILENT-CLOBBER: In-place cell overwrite without slot reservation; count-only audit masking data loss
    sqlite_lock_tax_leak = 20,        // M-SQLITE-LOCK-TAX: Permanent veto against any new component introducing file-level database mutexes into the hot memory path
};

/// Quality Management / Root Cause Analysis (QM/RCA) Scar Classification
pub const DefectSeverity = enum(u8) {
    HappenstancePatternShift = 0x01, // Low frequency: Resolved via mild pattern adjustment
    SystemicMethodFailure = 0x02,    // High frequency: Triggers trial-and-error method exploration in research lab
};

pub const SYSTEMIC_FREQUENCY_THRESHOLD: u32 = 3;

/// 88-byte contiguous external struct matching C-ABI memory layout
pub const FailureScarRecord = extern struct {
    failed_component: [16]u8,
    defect_severity: DefectSeverity,
    padding: [3]u8 = @splat(0),
    frequency_counter: u32,
    lexicon_veto_payload: [64]u8, // Prepends directly into subsequent boot packet negative space

    pub fn vetoPayloadHex(self: *const FailureScarRecord) [128]u8 {
        return std.fmt.bytesToHex(self.lexicon_veto_payload, .lower);
    }
};

pub const FailureScar = struct {
    scar_id: u32,
    defect_class: DefectClass,
    subject_pattern: [16]u8,
    predicate_pattern: [16]u8,
    veto_mask: u64,
    separating_predicate: [64]u8,
    sharpened_grill_question: [128]u8,
    frequency_counter: u32 = 1,
    severity: DefectSeverity = .HappenstancePatternShift,

    pub fn init(
        scar_id: u32,
        defect: DefectClass,
        subject: []const u8,
        predicate: []const u8,
        veto_mask: u64,
        separator: []const u8,
        question: []const u8,
    ) FailureScar {
        var scar = FailureScar{
            .scar_id = scar_id,
            .defect_class = defect,
            .subject_pattern = @splat(0),
            .predicate_pattern = @splat(0),
            .veto_mask = veto_mask,
            .separating_predicate = @splat(0),
            .sharpened_grill_question = @splat(0),
            .frequency_counter = 1,
            .severity = .HappenstancePatternShift,
        };

        const sub_len = @min(subject.len, 16);
        @memcpy(scar.subject_pattern[0..sub_len], subject[0..sub_len]);

        const pred_len = @min(predicate.len, 16);
        @memcpy(scar.predicate_pattern[0..pred_len], predicate[0..pred_len]);

        const sep_len = @min(separator.len, 64);
        @memcpy(scar.separating_predicate[0..sep_len], separator[0..sep_len]);

        const q_len = @min(question.len, 128);
        @memcpy(scar.sharpened_grill_question[0..q_len], question[0..q_len]);

        return scar;
    }

    pub fn recordOccurrence(self: *FailureScar) DefectSeverity {
        self.frequency_counter += 1;
        if (self.frequency_counter >= SYSTEMIC_FREQUENCY_THRESHOLD) {
            self.severity = .SystemicMethodFailure;
        }
        return self.severity;
    }

    pub fn toRecord(self: *const FailureScar) FailureScarRecord {
        return FailureScarRecord{
            .failed_component = self.subject_pattern,
            .defect_severity = self.severity,
            .padding = @splat(0),
            .frequency_counter = self.frequency_counter,
            .lexicon_veto_payload = self.separating_predicate,
        };
    }

    pub fn getSeparator(self: *const FailureScar) []const u8 {
        var len: usize = 0;
        while (len < 64 and self.separating_predicate[len] != 0) : (len += 1) {}
        return self.separating_predicate[0..len];
    }

    pub fn getQuestion(self: *const FailureScar) []const u8 {
        var len: usize = 0;
        while (len < 128 and self.sharpened_grill_question[len] != 0) : (len += 1) {}
        return self.sharpened_grill_question[0..len];
    }
};

// ── 5. Living Lexicon Engine ────────────────────────────────────────────────

pub const LexiconEngine = struct {
    scars: [MAX_SCARS]FailureScar = undefined,
    scar_count: usize = 0,

    pub fn init() LexiconEngine {
        var engine = LexiconEngine{
            .scar_count = 0,
        };
        engine.seedHistoricalScars();
        return engine;
    }

    /// Seeds foundational failure scars into the living lexicon so the grill carries scars immediately.
    pub fn seedHistoricalScars(self: *LexiconEngine) void {
        // Scar 1: Machine author violation on conclusion records
        self.registerScar(FailureScar.init(
            1,
            .machine_author_violation,
            "claude-code",
            "assert_relation",
            0x0001,
            "refuse machine author on conclusions (trg_conclusions_no_machine_author)",
            "Does this work order specify human sovereign authorization or an authorized hub token?",
        )) catch unreachable;

        // Scar 2: Foreign SQLite work pool leak
        self.registerScar(FailureScar.init(
            2,
            .foreign_pool_leak,
            "fleet_pool",
            "write_sqlite",
            0x0002,
            "refuse external sqlite pool writes in tot_hybrid; use memory ring",
            "Why is this component writing to fleet_pool.sqlite instead of the Zig memory controller?",
        )) catch unreachable;

        // Scar 3: Recursive mitosis hop depth limit breach
        self.registerScar(FailureScar.init(
            3,
            .missing_bound,
            "mitosis",
            "branch_hop",
            0x0004,
            "branch depth > 4 violates Invariant A-11; RAISE(ABORT)",
            "What is the maximum recursion depth, and does it guarantee termination within 4 hops?",
        )) catch unreachable;

        // Scar 4: CaseMark legal ungrounded claim violation
        self.registerScar(FailureScar.init(
            4,
            .ungrounded_claim,
            "casemark_legal",
            "execute_skill",
            0x0008,
            "missing cite_key under GROUNDED-or-GAP mandate",
            "What is the exact cite_key supporting this rule or legal claim?",
        )) catch unreachable;

        // Scar 5: Substrate all-branches search omission (A-SUBSTRATE)
        self.registerScar(FailureScar.init(
            5,
            .substrate_search_bug,
            "git_log",
            "commit_window",
            0x0010,
            "git log without --all reports only default branch, omitting feature work",
            "Does this audit command use git log --all across branches to ensure complete coverage?",
        )) catch unreachable;

        // Scar 6: Three-host search omission (C-UNENFORCED)
        self.registerScar(FailureScar.init(
            6,
            .unenforced_policy_gap,
            "three_host",
            "search_absence",
            0x0020,
            "single-host NOT FOUND proves search failure, not entity absence",
            "Have you verified search presence across pop, brandys, and backup before claiming absence?",
        )) catch unreachable;

        // Scar 7: L1d cache hardware boundary breach (D-ARCHITECTURE)
        self.registerScar(FailureScar.init(
            7,
            .hardware_boundary_breach,
            "cell_geometry",
            "resize_cache",
            0x0040,
            "272x64B = 17,408B exact L1d cache residency is compile-time hardware law",
            "Does the cell size strictly match 17,408 bytes (272 cache lines) without reallocation?",
        )) catch unreachable;

        // Scar 8: Ledger append-only drift misclassified as refutation (E-LEDGER-EPISTEMICS)
        self.registerScar(FailureScar.init(
            8,
            .ledger_epistemic_drift,
            "append_ledger",
            "drift_refutation",
            0x0080,
            "monotonically increasing line count across concurrent writers is valid append-only operation",
            "Is the reported discrepancy an actual contradiction or concurrent append-only log growth?",
        )) catch unreachable;

        // Scar 9: Procedural pre-flight empty loop variable (B-DENOMINATOR)
        self.registerScar(FailureScar.init(
            9,
            .procedural_preflight_gap,
            "preflight_cmd",
            "empty_variable",
            0x0100,
            "unbound shell variable in repair loop triggers silent empty output or false pass",
            "Are all shell loop variables verified non-empty before executing repair/audit scripts?",
        )) catch unreachable;

        // Scar 10: Agent invented rules or gold standards without ground-truth authority (F-INVENTED-STANDARD)
        self.registerScar(FailureScar.init(
            10,
            .gold_ocr_invented_standard,
            "agent_eval",
            "invent_standard",
            0x0200,
            "agents never invent standards or gold datasets; ground truth is external",
            "Is this benchmark or evaluation standard grounded in external human authority, or was it invented by an agent?",
        )) catch unreachable;

        // Scar 11: Bare agent with no persistent role asking what's next (G-BARE-AGENT)
        self.registerScar(FailureScar.init(
            11,
            .bare_agent_no_role,
            "bare_agent",
            "whats_next_loop",
            0x0400,
            "bare agent resolves to done and loops; persistent role required",
            "Does this task have a persistent architectural role holding the plan, or is a bare agent asking what's next?",
        )) catch unreachable;

        // Scar 12: Fallback Python script masking broken compiled pipeline (H-PYTHON-FALLBACK)
        self.registerScar(FailureScar.init(
            12,
            .python_fallback_mask,
            "python_script",
            "mask_pipeline",
            0x0800,
            "concise python compresses to C/C++/Zig; no fallback patch",
            "Is this Python script a temporary prototype, or is it masking a broken compiled pipeline fallback?",
        )) catch unreachable;

        // Scar 13: Over-subscribing Brandys 12GB VRAM across base models (I-VRAM-OVERSUB)
        self.registerScar(FailureScar.init(
            13,
            .vram_oversubscription,
            "brandys_vram",
            "multi_model",
            0x1000,
            "never host multiple models in 12GB VRAM; sequential swap only",
            "Does this execution plan attempt to co-host multiple large models in 12GB VRAM instead of sequential swapping?",
        )) catch unreachable;

        // Scar 14: Prompt engineer writing loose prose instead of typed contracts (J-UNENFORCED-CONTRACT)
        self.registerScar(FailureScar.init(
            14,
            .prompt_as_prose,
            "ticket_prompt",
            "untyped_prose",
            0x2000,
            "prompt engineer writes tickets as strict typed contracts",
            "Is this ticket authored as an enforceable contract with typed preconditions, or is it untyped prose?",
        )) catch unreachable;

        // Scar 15: Substrate inversion - coupling to one app vs forensic compute (K-SUBSTRATE-INVERSION)
        self.registerScar(FailureScar.init(
            15,
            .forensic_substrate_inversion,
            "tot_hybrid",
            "app_lock",
            0x4000,
            "tot_hybrid is forensic substrate; apps consume it",
            "Is this system designed as a reusable forensic compute substrate, or is it locked to a single application?",
        )) catch unreachable;

        // Scar 16: Silent in-place cell overwrite masking content destruction (L-SILENT-CLOBBER)
        self.registerScar(FailureScar.init(
            16,
            .silent_in_place_overwrite,
            "memctl_post",
            "persist_cell",
            0x8000,
            "refuse unallocated cell overwrite; require CellSlotPacer atomic slot reservation and SHA-256 checksum",
            "Does the cell persistence verify SHA-256 content hashes and acquire atomic slot leases, or does count-only check mask silent clobbering?",
        )) catch unreachable;

        // Scar 17: SQLite file-level mutex / lock tax in hot memory path (M-SQLITE-LOCK-TAX)
        self.registerScar(FailureScar.init(
            17,
            .sqlite_lock_tax_leak,
            "sqlite_mutex",
            "acquire_lock",
            0x0001_0000,
            "veto file-level sqlite mutex in hot path; use lock-free ring",
            "Does this component introduce file-level database locks, WAL contention, or synchronous mutexes into the hot memory path?",
        )) catch unreachable;
    }

    pub fn registerScar(self: *LexiconEngine, scar: FailureScar) error{ScarRegistryFull}!void {
        if (self.scar_count >= MAX_SCARS) {
            return error.ScarRegistryFull;
        }
        self.scars[self.scar_count] = scar;
        self.scar_count += 1;
    }

    /// Records an occurrence of a scar by ID, escalating from Happenstance to Systemic if threshold reached
    pub fn recordIncident(self: *LexiconEngine, scar_id: u32) ?DefectSeverity {
        for (self.scars[0..self.scar_count]) |*scar| {
            if (scar.scar_id == scar_id) {
                return scar.recordOccurrence();
            }
        }
        return null;
    }

    /// Evaluates candidate intent against living scars.
    /// If candidate matches a known defect shape, returns the matching scar to sharpen the grill.
    pub fn matchScar(
        self: *const LexiconEngine,
        subject: []const u8,
        predicate: []const u8,
    ) ?FailureScar {
        var sub_buf: [16]u8 = @splat(0);
        const sub_len = @min(subject.len, 16);
        @memcpy(sub_buf[0..sub_len], subject[0..sub_len]);

        var pred_buf: [16]u8 = @splat(0);
        const pred_len = @min(predicate.len, 16);
        @memcpy(pred_buf[0..pred_len], predicate[0..pred_len]);

        for (self.scars[0..self.scar_count]) |scar| {
            if (std.mem.eql(u8, &scar.subject_pattern, &sub_buf) and
                std.mem.eql(u8, &scar.predicate_pattern, &pred_buf))
            {
                return scar;
            }
        }
        return null;
    }

    /// Evaluates an existing BytecodeHeader against registered negative affinity masks.
    pub fn evaluateHeader(
        self: *const LexiconEngine,
        header: *const geometry.BytecodeHeader,
    ) ?FailureScar {
        for (self.scars[0..self.scar_count]) |scar| {
            if (std.mem.eql(u8, &scar.subject_pattern, &header.subject_id) and
                std.mem.eql(u8, &scar.predicate_pattern, &header.predicate_op))
            {
                return scar;
            }
        }
        return null;
    }
};

// ── 6. Sentence -> Row Normalization ────────────────────────────────────────

pub const SentenceRow = struct {
    term_a: [16]u8,
    relation_op: [16]u8,
    term_b: [16]u8,
    provenance_flags: u64,

    pub fn toBytecodeHeader(self: SentenceRow, opcode: u64) geometry.BytecodeHeader {
        return geometry.BytecodeHeader{
            .opcode = opcode,
            .subject_id = self.term_a,
            .predicate_op = self.relation_op,
            .target_val = self.term_b,
            .provenance_flags = self.provenance_flags,
        };
    }
};

/// Losslessly normalizes a natural language intent proposition into a 64B instruction header.
pub fn normalizeSentence(
    subject: []const u8,
    relation: LogicOp,
    target: []const u8,
    provenance_flags: u64,
) SentenceRow {
    var row = SentenceRow{
        .term_a = @splat(0),
        .relation_op = relation.toId16(),
        .term_b = @splat(0),
        .provenance_flags = provenance_flags,
    };

    const s_len = @min(subject.len, 16);
    @memcpy(row.term_a[0..s_len], subject[0..s_len]);

    const t_len = @min(target.len, 16);
    @memcpy(row.term_b[0..t_len], target[0..t_len]);

    return row;
}

// ── 7. OCR Spoke Ingestion: Bronze Census Transcription -> Cell ─────────────
//
// Bronze transcription rows (USGenWeb-style fixed-width tables, e.g.
// bronze/census/*/transcriptions/*/pg*.txt) separate columns with runs of
// 2+ spaces. This does not touch Tesseract, hOCR/ALTO, or the live OCR desk
// at ~/worktrees/ocr-desk; it only normalizes already-transcribed plaintext
// lines into closed-grammar SentenceRow/BytecodeHeader tuples. No CER/gold
// standard is computed or invented here (Scar 10).

/// Splits `line` on runs of 2 or more spaces after trimming outer whitespace,
/// mirroring the column layout of USGenWeb fixed-width census transcriptions.
/// Returns the number of fields written into `out`.
pub fn splitFixedWidthFields(line: []const u8, out: [][]const u8) usize {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    var i: usize = 0;
    var count: usize = 0;
    while (i < trimmed.len and count < out.len) {
        while (i < trimmed.len and trimmed[i] == ' ') : (i += 1) {}
        if (i >= trimmed.len) break;
        const start = i;
        while (i < trimmed.len) : (i += 1) {
            if (trimmed[i] == ' ' and i + 1 < trimmed.len and trimmed[i + 1] == ' ') break;
        }
        out[count] = trimmed[start..i];
        count += 1;
        while (i < trimmed.len and trimmed[i] == ' ') : (i += 1) {}
    }
    return count;
}

/// Parses one bronze census transcription data row into a SentenceRow
/// asserting `<surname> <given-initial> assert_relation <birthplace>`.
/// Header rows, rule lines (`===`/`---`), and blank lines return null because
/// their leading LN column is not purely numeric.
pub fn parseCensusLine(line: []const u8) ?SentenceRow {
    var fields: [17][]const u8 = undefined;
    const n = splitFixedWidthFields(line, &fields);
    // Need columns through BIRTHPLACE: LN HN FN LAST FIRST AGE SEX RACE OCCUP REAL PERS BIRTHPLACE
    if (n < 12) return null;

    const ln_field = fields[0];
    if (ln_field.len == 0) return null;
    for (ln_field) |c| {
        if (c < '0' or c > '9') return null;
    }

    const last = fields[3];
    const first = fields[4];
    const birthplace = fields[11];
    if (last.len == 0) return null;

    var subject_buf: [16]u8 = undefined;
    var w: usize = @min(last.len, 14);
    @memcpy(subject_buf[0..w], last[0..w]);
    if (first.len > 0 and w < subject_buf.len) {
        subject_buf[w] = ' ';
        w += 1;
        if (w < subject_buf.len) {
            subject_buf[w] = first[0];
            w += 1;
        }
    }

    return normalizeSentence(subject_buf[0..w], .assert_relation, birthplace, 0);
}

/// Packs a SentenceRow, plus its verbatim source line for provenance, into a
/// full 17,408B geometry.Cell (Invariant A-1). Fingerprint vectors are left
/// zeroed here; embedding/fingerprinting is a separate concern from parsing.
pub fn packCensusCell(row: SentenceRow, source_line: []const u8) geometry.Cell {
    var cell: geometry.Cell = std.mem.zeroes(geometry.Cell);
    cell.header = row.toBytecodeHeader(@intFromEnum(LogicOp.assert_relation));
    const copy_len = @min(source_line.len, geometry.SEMANTIC_PAYLOAD_BYTES);
    @memcpy(cell.semantic_payload[0..copy_len], source_line[0..copy_len]);
    return cell;
}

// ── Unit Tests ───────────────────────────────────────────────────────────────

test "lexicon meets the committed-fixture size bound (50-100 entries)" {
    try std.testing.expect(WORDS.len >= 50);
    try std.testing.expect(WORDS.len <= 100);
    try std.testing.expectEqual(@as(usize, 90), WORDS.len);
}

test "lexicon carries the ALEXANDER tear-case anchor word" {
    try std.testing.expect(contains("ALEXANDER"));
    try std.testing.expect(containsIgnoreCase("alexander"));
}

test "lexicon entries are upper-case letters only, no duplicates" {
    for (WORDS) |w| {
        try std.testing.expect(w.len >= 3);
        for (w) |c| {
            try std.testing.expect(c >= 'A' and c <= 'Z');
        }
    }
    for (WORDS, 0..) |w, i| {
        for (WORDS[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, w, other));
        }
    }
}

test "Living Lexicon: Scars veto known defect shapes and surface sharpened questions" {
    const engine = LexiconEngine.init();

    // 1. Machine author defect matches Scar #1
    const scar1 = engine.matchScar("claude-code", "assert_relation");
    try std.testing.expect(scar1 != null);
    try std.testing.expectEqual(DefectClass.machine_author_violation, scar1.?.defect_class);
    try std.testing.expectEqualStrings(
        "Does this work order specify human sovereign authorization or an authorized hub token?",
        scar1.?.getQuestion(),
    );

    // 2. Foreign sqlite pool leak matches Scar #2
    const scar2 = engine.matchScar("fleet_pool", "write_sqlite");
    try std.testing.expect(scar2 != null);
    try std.testing.expectEqual(DefectClass.foreign_pool_leak, scar2.?.defect_class);
    try std.testing.expectEqualStrings(
        "Why is this component writing to fleet_pool.sqlite instead of the Zig memory controller?",
        scar2.?.getQuestion(),
    );

    // 3. Valid intent does not trigger scar veto
    const valid = engine.matchScar("human_sovereign", "assert_relation");
    try std.testing.expect(valid == null);
}

test "Living Lexicon: Sentence-to-Row normalization produces valid 64B BytecodeHeader" {
    const row = normalizeSentence(
        "human_agent",
        .requires_gate,
        "hub_write_token",
        0xA1B2C3D4E5F6,
    );

    const header = row.toBytecodeHeader(1003);

    try std.testing.expectEqual(@as(u64, 1003), header.opcode);
    try std.testing.expectEqualStrings("human_agent\x00\x00\x00\x00\x00", &header.subject_id);
    try std.testing.expectEqualStrings("requires_gate\x00\x00\x00", &header.predicate_op);
    try std.testing.expectEqualStrings("hub_write_token\x00", &header.target_val);
    try std.testing.expectEqual(@as(u64, 0xA1B2C3D4E5F6), header.provenance_flags);
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(geometry.BytecodeHeader));
}

test "Living Lexicon: Evaluates candidate BytecodeHeader against registered negative affinity" {
    const engine = LexiconEngine.init();

    const bad_row = normalizeSentence(
        "casemark_legal",
        .assert_relation, // will be mapped below
        "execute_skill",
        1,
    );
    // Construct header matching scar #4
    var bad_header = bad_row.toBytecodeHeader(1006);
    var pred_buf: [16]u8 = @splat(0);
    @memcpy(pred_buf[0..13], "execute_skill");
    bad_header.predicate_op = pred_buf;

    const veto = engine.evaluateHeader(&bad_header);
    try std.testing.expect(veto != null);
    try std.testing.expectEqual(DefectClass.ungrounded_claim, veto.?.defect_class);
    try std.testing.expectEqualStrings(
        "What is the exact cite_key supporting this rule or legal claim?",
        veto.?.getQuestion(),
    );
}

test "Living Lexicon: 5-family defect taxonomy scars veto search bugs and hardware breaches" {
    const engine = LexiconEngine.init();

    // 1. A-SUBSTRATE: git_log commit_window
    const scar5 = engine.matchScar("git_log", "commit_window");
    try std.testing.expect(scar5 != null);
    try std.testing.expectEqual(DefectClass.substrate_search_bug, scar5.?.defect_class);
    try std.testing.expectEqualStrings(
        "Does this audit command use git log --all across branches to ensure complete coverage?",
        scar5.?.getQuestion(),
    );

    // 2. C-UNENFORCED: three_host search_absence
    const scar6 = engine.matchScar("three_host", "search_absence");
    try std.testing.expect(scar6 != null);
    try std.testing.expectEqual(DefectClass.unenforced_policy_gap, scar6.?.defect_class);

    // 3. D-ARCHITECTURE: cell_geometry resize_cache
    const scar7 = engine.matchScar("cell_geometry", "resize_cache");
    try std.testing.expect(scar7 != null);
    try std.testing.expectEqual(DefectClass.hardware_boundary_breach, scar7.?.defect_class);

    // 4. E-LEDGER-EPISTEMICS: append_ledger drift_refutation
    const scar8 = engine.matchScar("append_ledger", "drift_refutation");
    try std.testing.expect(scar8 != null);
    try std.testing.expectEqual(DefectClass.ledger_epistemic_drift, scar8.?.defect_class);

    // 5. B-DENOMINATOR: preflight_cmd empty_variable
    const scar9 = engine.matchScar("preflight_cmd", "empty_variable");
    try std.testing.expect(scar9 != null);
    try std.testing.expectEqual(DefectClass.procedural_preflight_gap, scar9.?.defect_class);

    // 6. F-INVENTED-STANDARD: agent_eval invent_standard
    const scar10 = engine.matchScar("agent_eval", "invent_standard");
    try std.testing.expect(scar10 != null);
    try std.testing.expectEqual(DefectClass.gold_ocr_invented_standard, scar10.?.defect_class);

    // 7. G-BARE-AGENT: bare_agent whats_next_loop
    const scar11 = engine.matchScar("bare_agent", "whats_next_loop");
    try std.testing.expect(scar11 != null);
    try std.testing.expectEqual(DefectClass.bare_agent_no_role, scar11.?.defect_class);

    // 8. H-PYTHON-FALLBACK: python_script mask_pipeline
    const scar12 = engine.matchScar("python_script", "mask_pipeline");
    try std.testing.expect(scar12 != null);
    try std.testing.expectEqual(DefectClass.python_fallback_mask, scar12.?.defect_class);

    // 9. I-VRAM-OVERSUB: brandys_vram multi_model
    const scar13 = engine.matchScar("brandys_vram", "multi_model");
    try std.testing.expect(scar13 != null);
    try std.testing.expectEqual(DefectClass.vram_oversubscription, scar13.?.defect_class);

    // 10. J-UNENFORCED-CONTRACT: ticket_prompt untyped_prose
    const scar14 = engine.matchScar("ticket_prompt", "untyped_prose");
    try std.testing.expect(scar14 != null);
    try std.testing.expectEqual(DefectClass.prompt_as_prose, scar14.?.defect_class);

    // 11. K-SUBSTRATE-INVERSION: tot_hybrid app_lock
    const scar15 = engine.matchScar("tot_hybrid", "app_lock");
    try std.testing.expect(scar15 != null);
    try std.testing.expectEqual(DefectClass.forensic_substrate_inversion, scar15.?.defect_class);

    // 12. L-SILENT-CLOBBER: memctl_post persist_cell
    const scar16 = engine.matchScar("memctl_post", "persist_cell");
    try std.testing.expect(scar16 != null);
    try std.testing.expectEqual(DefectClass.silent_in_place_overwrite, scar16.?.defect_class);
    try std.testing.expectEqual(@as(u32, 16), scar16.?.scar_id);

    // 13. M-SQLITE-LOCK-TAX: sqlite_mutex acquire_lock
    const scar17 = engine.matchScar("sqlite_mutex", "acquire_lock");
    try std.testing.expect(scar17 != null);
    try std.testing.expectEqual(DefectClass.sqlite_lock_tax_leak, scar17.?.defect_class);
    try std.testing.expectEqual(@as(u32, 17), scar17.?.scar_id);
    try std.testing.expectEqualStrings(
        "veto file-level sqlite mutex in hot path; use lock-free ring",
        scar17.?.getSeparator(),
    );
    try std.testing.expectEqualStrings(
        "Does this component introduce file-level database locks, WAL contention, or synchronous mutexes into the hot memory path?",
        scar17.?.getQuestion(),
    );
}

test "Living Lexicon: Quality Management RCA frequency escalation (Happenstance vs Systemic)" {
    var engine = LexiconEngine.init();

    // Scar #1 starts at frequency 1 and HappenstancePatternShift
    const scar1_initial = engine.matchScar("claude-code", "assert_relation");
    try std.testing.expect(scar1_initial != null);
    try std.testing.expectEqual(@as(u32, 1), scar1_initial.?.frequency_counter);
    try std.testing.expectEqual(DefectSeverity.HappenstancePatternShift, scar1_initial.?.severity);

    // Record 2nd occurrence -> still HappenstancePatternShift (threshold is 3)
    const sev2 = engine.recordIncident(1);
    try std.testing.expectEqual(DefectSeverity.HappenstancePatternShift, sev2.?);

    // Record 3rd occurrence -> hits SYSTEMIC_FREQUENCY_THRESHOLD -> escalates to SystemicMethodFailure!
    const sev3 = engine.recordIncident(1);
    try std.testing.expectEqual(DefectSeverity.SystemicMethodFailure, sev3.?);

    // Verify scar record layout matches C-ABI contract
    const updated_scar = engine.matchScar("claude-code", "assert_relation");
    try std.testing.expect(updated_scar != null);
    try std.testing.expectEqual(@as(u32, 3), updated_scar.?.frequency_counter);
    try std.testing.expectEqual(DefectSeverity.SystemicMethodFailure, updated_scar.?.severity);

    const record = updated_scar.?.toRecord();
    try std.testing.expectEqual(DefectSeverity.SystemicMethodFailure, record.defect_severity);
    try std.testing.expectEqual(@as(u32, 3), record.frequency_counter);
    try std.testing.expectEqualStrings("claude-code\x00\x00\x00\x00\x00", &record.failed_component);
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(FailureScarRecord));
}

test "LexiconEngine: registerScar loud refusal on overflow (never silently drop)" {
    var engine = LexiconEngine{ .scar_count = 0 };
    // Verify registerScar adds scars cleanly
    try engine.registerScar(FailureScar.init(
        100,
        .hardware_boundary_breach,
        "test_sub",
        "test_pred",
        0x01,
        "test separator",
        "test question?",
    ));
    try std.testing.expectEqual(@as(usize, 1), engine.scar_count);

    // Fill to capacity
    while (engine.scar_count < MAX_SCARS) {
        try engine.registerScar(FailureScar.init(
            @intCast(engine.scar_count + 1),
            .hardware_boundary_breach,
            "fill",
            "fill",
            0x01,
            "sep",
            "q?",
        ));
    }
    try std.testing.expectEqual(MAX_SCARS, engine.scar_count);

    // Ensure it refuses loudly with error.ScarRegistryFull and NEVER silently drops
    const err = engine.registerScar(FailureScar.init(
        9999,
        .hardware_boundary_breach,
        "overflow",
        "overflow",
        0x01,
        "sep",
        "q?",
    ));
    try std.testing.expectError(error.ScarRegistryFull, err);
}

test "MinimalPerfectHash: 19th-century fixture O(1) closed vocabulary lookup and popcount compression" {
    // 1. Verify all 90 words in the ground truth fixture map uniquely to [0, 90)
    var seen_indices: [WORDS.len]bool = @splat(false);

    for (WORDS) |word| {
        const idx_opt = WordsPerfectHash.lookup(word);
        try std.testing.expect(idx_opt != null);
        const idx = idx_opt.?;
        try std.testing.expect(idx < WORDS.len);
        try std.testing.expect(!seen_indices[idx]); // Must be unique (minimal perfect hash)
        seen_indices[idx] = true;

        // Verify table slot stores exact word
        try std.testing.expectEqualStrings(word, WordsPerfectHash.table[idx]);
        try std.testing.expect(WordsPerfectHash.contains(word));
    }

    // Verify all 90 indices were filled
    for (seen_indices) |seen| {
        try std.testing.expect(seen);
    }

    // 2. Verify non-vocabulary tokens return null (zero false positives)
    try std.testing.expect(WordsPerfectHash.lookup("FOOBAR") == null);
    try std.testing.expect(WordsPerfectHash.lookup("ZIG") == null);
    try std.testing.expect(WordsPerfectHash.lookup("ALEXANDRIA") == null);
    try std.testing.expect(WordsPerfectHash.lookup("CLAUDE") == null);
    try std.testing.expect(WordsPerfectHash.lookup("") == null);
    try std.testing.expect(!WordsPerfectHash.contains("NOT_A_NAME"));

    // 3. Verify custom small closed vocabulary with MinimalPerfectHash
    const op_tokens = [_][]const u8{ "assert_relation", "contradicts", "requires_gate", "supersedes", "grounded_in" };
    const OpHash = MinimalPerfectHash(&op_tokens);

    try std.testing.expectEqual(@as(usize, 5), OpHash.key_count);
    for (op_tokens) |tok| {
        const o_idx = OpHash.lookup(tok);
        try std.testing.expect(o_idx != null);
        try std.testing.expect(o_idx.? < 5);
        try std.testing.expectEqualStrings(tok, OpHash.table[o_idx.?]);
        try std.testing.expect(OpHash.contains(tok));
    }
    try std.testing.expect(!OpHash.contains("unknown_operator"));
}

// ── OCR Spoke: Census Line -> Cell Tests ─────────────────────────────────────
// Fixtures are verbatim lines from bronze/census/.../va_gloucester_1860/pg00715.txt.

test "parseCensusLine: header ruler, separator, and blank lines are rejected" {
    const header_row = " LN  HN   FN  LAST NAME      FIRST NAME     AGE  SEX  RACE  OCCUP.       REAL VAL. PERS VAL.   BIRTHPLACE       MRD.  SCH.  R/W  DDB   REMARKS";
    const separator = "==============================================================================================================================================";
    const blank = "";
    const prose = "This Census was transcribed by Henry L. Rankin and proofread by Nanci W. Rankin";

    try std.testing.expect(parseCensusLine(header_row) == null);
    try std.testing.expect(parseCensusLine(separator) == null);
    try std.testing.expect(parseCensusLine(blank) == null);
    try std.testing.expect(parseCensusLine(prose) == null);
}

/// Builds an expected 16-byte zero-padded token for comparison against
/// term_a/relation_op/term_b arrays, avoiding hand-counted \x00 literals.
fn expectedToken16(text: []const u8) [16]u8 {
    var buf: [16]u8 = @splat(0);
    const len = @min(text.len, 16);
    @memcpy(buf[0..len], text[0..len]);
    return buf;
}

test "parseCensusLine: bronze census data row normalizes to a closed-grammar SentenceRow" {
    const line = " 01  1    1   Coleman        John F         38    M    W    Farmer         2,500     4,300     VA                .     .     .    .    .";

    const row = parseCensusLine(line);
    try std.testing.expect(row != null);

    try std.testing.expectEqualSlices(u8, &expectedToken16("Coleman J"), &row.?.term_a);
    try std.testing.expectEqualSlices(u8, &expectedToken16("assert_relation"), &row.?.relation_op);
    try std.testing.expectEqualSlices(u8, &expectedToken16("VA"), &row.?.term_b);
    try std.testing.expectEqual(@as(u64, 0), row.?.provenance_flags);
}

test "packCensusCell: bronze row packs into a geometry-legal 17,408B Cell (Invariant A-1)" {
    const line = " 02  1    1   Coleman        Mildred B      32    F    W    .              .         .         VA                .     .     .    .    .";
    const row = parseCensusLine(line).?;
    const cell = packCensusCell(row, line);

    try std.testing.expectEqual(@as(usize, 17408), @sizeOf(geometry.Cell));
    try std.testing.expectEqual(@as(u64, 1001), cell.header.opcode);
    try std.testing.expectEqualSlices(u8, &expectedToken16("Coleman M"), &cell.header.subject_id);
    try std.testing.expectEqualSlices(u8, &expectedToken16("VA"), &cell.header.target_val);

    try std.testing.expectEqualStrings(line, cell.semantic_payload[0..line.len]);

    // Fingerprint slots are left zeroed by the parser; embedding is a separate stage.
    for (cell.fingerprints) |fp| {
        for (fp.words) |word| {
            try std.testing.expectEqual(@as(u64, 0), word);
        }
    }
}

/// Streams `path` line-by-line and packs every parseable census data row into
/// a Cell, verifying Invariant A-1/A-2 on each one. Returns per-file counts
/// so callers (and the ingestion test below) can assert the run was real,
/// not vacuous. Zig-only (Scar 12): no Python fallback, no shelling out.
pub const IngestCounts = struct { lines_seen: usize, rows_parsed: usize, cells_packed: usize };

pub fn ingestCensusFile(io: std.Io, path: []const u8) !IngestCounts {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);

    var counts = IngestCounts{ .lines_seen = 0, .rows_parsed = 0, .cells_packed = 0 };
    while (try file_reader.interface.takeDelimiter('\n')) |line| {
        counts.lines_seen += 1;

        const row = parseCensusLine(line) orelse continue;
        counts.rows_parsed += 1;

        const cell = packCensusCell(row, line);
        counts.cells_packed += 1;

        // Invariant A-1 / A-2 must hold for every single packed cell.
        std.debug.assert(@sizeOf(geometry.Cell) == 17408);
        std.debug.assert(@sizeOf(geometry.BytecodeHeader) == 64);
        std.debug.assert(cell.header.opcode == 1001);
    }
    return counts;
}

test "ingestCensusFile: streams the real bronze va_gloucester_1860 pg00715.txt into geometry-legal Cells" {
    const path = "/home/christopherhamil/RAG Data/bronze/census/census1860_dataset_workcopy/transcriptions/va_gloucester_1860/pg00715.txt";

    const counts = ingestCensusFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => return, // bronze corpus not present on this host; not a failure
        else => return err,
    };

    // pg00715.txt is a real ~103KB transcription page; a genuine run scans
    // well over 100 lines and parses at least one data row. Not vacuous.
    try std.testing.expect(counts.lines_seen > 100);
    try std.testing.expect(counts.rows_parsed > 0);
    try std.testing.expectEqual(counts.rows_parsed, counts.cells_packed);

    std.debug.print(
        "\n[INGEST bronze census] {s}: {d} lines scanned, {d} rows parsed, {d} Cells packed (Invariant A-1/A-2 held for every cell)\n",
        .{ path, counts.lines_seen, counts.rows_parsed, counts.cells_packed },
    );
}

test "Task 19: FailureScarRecord lexicon_veto_payload negative space export" {
    // Task 19: Exactly 64-byte scar veto payload exported as 128 lowercase hex characters
    var scar = FailureScar.init(
        42,
        .hardware_boundary_breach,
        "TokenizerComp",
        "OverfitPredicate",
        0xDEADBEEF,
        "VETO_ARBITRARY_HALLUCINATION_MASK_RULE_01",
        "Did you verify with GBNF token mask?",
    );

    const rec = scar.toRecord();
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(FailureScarRecord));

    const hex_veto = rec.vetoPayloadHex();
    try std.testing.expectEqual(@as(usize, 128), hex_veto.len);

    // Verify round-trip hex decode equals the original 64-byte payload
    var decoded: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&decoded, &hex_veto);
    try std.testing.expectEqualSlices(u8, &rec.lexicon_veto_payload, &decoded);
    try std.testing.expectEqualStrings("VETO_ARBITRARY_HALLUCINATION_MASK_RULE_01", scar.getSeparator());
}

