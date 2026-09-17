//! Native Pointer + STT Packet Assembler & Voice Ducking Engine
//!
//! Subsystem: tot_hybrid/src/stt_pointer.zig
//! Toolchain: Zig 0.17 compatible.
//!
//! Architectural Invariants:
//!   - Strict 17,408B cell size ceiling (Invariant A-1, geometry.CELL_BYTES).
//!   - Strict 64B BytecodeHeader (Invariant A-2).
//!   - Emits structured JSON linking human/agent coordinate interactions to speech transcripts.
//!   - PipeWire volume ducking state machine (0.30 duck -> aplay speech -> 0.90 restore).
//!   - Endian-safe standard 44-byte RIFF/WAVE header generator.

const std = @import("std");
const geometry = @import("geometry");

pub const MAX_CELL_BYTES: usize = geometry.CELL_BYTES; // 17,408
pub const OP_STT_POINTER: u64 = 0x5301; // 'S' << 8 | 0x01
pub const OP_TTS_REQUEST: u64 = 0x5401; // 'T' << 8 | 0x01

pub const PointerData = struct {
    client_x: f64 = 0.0,
    client_y: f64 = 0.0,
    viewport_w: f64 = 1920.0,
    viewport_h: f64 = 1080.0,
    note: []const u8 = "",

    /// Normalized [0.0, 1.0] coordinate relative to viewport width
    pub fn normalizedX(self: PointerData) f64 {
        if (self.viewport_w <= 0.0) return 0.0;
        return self.client_x / self.viewport_w;
    }

    /// Normalized [0.0, 1.0] coordinate relative to viewport height
    pub fn normalizedY(self: PointerData) f64 {
        if (self.viewport_h <= 0.0) return 0.0;
        return self.client_y / self.viewport_h;
    }

    /// Normalized Device Coordinates [-1.0, 1.0] matching graph layout space (y-up)
    pub fn toNdc(self: PointerData) struct { x: f32, y: f32 } {
        const nx: f32 = if (self.viewport_w > 0.0)
            @floatCast((self.client_x / self.viewport_w) * 2.0 - 1.0)
        else
            0.0;
        const ny: f32 = if (self.viewport_h > 0.0)
            @floatCast(1.0 - (self.client_y / self.viewport_h) * 2.0)
        else
            0.0;
        return .{ .x = nx, .y = ny };
    }

    /// Bounding box test
    pub fn isInside(self: PointerData, x1: f64, y1: f64, x2: f64, y2: f64) bool {
        return self.client_x >= x1 and self.client_x <= x2 and
            self.client_y >= y1 and self.client_y <= y2;
    }
};

pub const SttPointerPacket = struct {
    ts: []const u8 = "2026-09-08T00:00:00Z",
    agent_id: []const u8,
    raw_transcript: []const u8,
    harper_transcript: []const u8 = "",
    pointer: PointerData,
    hovered_node: []const u8 = "",
    screenshot_path: []const u8 = "",

    pub fn formatPacket(self: SttPointerPacket, buf: []u8) ![]const u8 {
        const pct_x = self.pointer.normalizedX() * 100.0;
        const pct_y = self.pointer.normalizedY() * 100.0;
        const effective_transcript = if (self.harper_transcript.len > 0)
            self.harper_transcript
        else
            self.raw_transcript;

        return std.fmt.bufPrint(
            buf,
            \\{{"ts":"{s}","agent_id":"{s}","transcript":"{s}","raw_transcript":"{s}","cursor_client":[{d:.1},{d:.1}],"viewport":[{d:.0},{d:.0}],"relative_pct":[{d:.1},{d:.1}],"hovered_node":"{s}","note":"{s}","screenshot":"{s}"}}
        ,
            .{
                self.ts,
                self.agent_id,
                effective_transcript,
                self.raw_transcript,
                self.pointer.client_x,
                self.pointer.client_y,
                self.pointer.viewport_w,
                self.pointer.viewport_h,
                pct_x,
                pct_y,
                self.hovered_node,
                self.pointer.note,
                self.screenshot_path,
            },
        );
    }

    /// Packs the packet into an exact Invariant A-1 (17,408B) cell with 64B BytecodeHeader.
    pub fn packToCell(self: SttPointerPacket, cell_out: *geometry.Cell) !void {
        cell_out.* = std.mem.zeroes(geometry.Cell);

        var subj: [16]u8 = @splat(0);
        const subj_len = @min(self.agent_id.len, 16);
        @memcpy(subj[0..subj_len], self.agent_id[0..subj_len]);

        var pred: [16]u8 = @splat(0);
        const pred_len = @min(self.hovered_node.len, 16);
        @memcpy(pred[0..pred_len], self.hovered_node[0..pred_len]);

        var target: [16]u8 = @splat(0);
        const ndc = self.pointer.toNdc();
        std.mem.writeInt(u32, target[0..4], @bitCast(ndc.x), .little);
        std.mem.writeInt(u32, target[4..8], @bitCast(ndc.y), .little);

        const effective_transcript = if (self.harper_transcript.len > 0)
            self.harper_transcript
        else
            self.raw_transcript;

        cell_out.header = geometry.BytecodeHeader{
            .opcode = OP_STT_POINTER,
            .subject_id = subj,
            .predicate_op = pred,
            .target_val = target,
            .provenance_flags = @as(u64, @intCast(@min(effective_transcript.len, 0xFFFF))),
        };

        _ = try self.formatPacket(&cell_out.semantic_payload);
    }
};

pub const TtsVoice = enum {
    af_heart,
    af_sky,
    am_adam,

    pub const default_voice: TtsVoice = .af_heart;

    pub fn name(self: TtsVoice) []const u8 {
        return switch (self) {
            .af_heart => "af_heart",
            .af_sky => "af_sky",
            .am_adam => "am_adam",
        };
    }
};

pub const TtsState = enum {
    idle,
    ducking,
    speaking,
    restoring,

    pub fn name(self: TtsState) []const u8 {
        return switch (self) {
            .idle => "idle",
            .ducking => "ducking",
            .speaking => "speaking",
            .restoring => "restoring",
        };
    }
};

/// Physics-tick durations for the TTS ducking state machine.
/// Ducking and restore are short so the physics loop never waits on aplay.
pub const TTS_DUCK_FRAMES: u32 = 2;
pub const TTS_SPEAK_FRAMES: u32 = 4;
pub const TTS_RESTORE_FRAMES: u32 = 2;

pub const TtsEngine = struct {
    state: TtsState = .idle,
    active_voice: TtsVoice = .af_heart,
    duck_volume: []const u8 = "0.30",
    normal_volume: []const u8 = "0.90",
    ticks_in_state: u32 = 0,

    /// PipeWire headphone volume ducking command
    pub fn formatDuckCommand(self: TtsEngine, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "wpctl set-volume @DEFAULT_AUDIO_SINK@ {s}", .{self.duck_volume});
    }

    /// PipeWire headphone volume restore command
    pub fn formatRestoreCommand(self: TtsEngine, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "wpctl set-volume @DEFAULT_AUDIO_SINK@ {s}", .{self.normal_volume});
    }

    /// Playback command via ALSA aplay
    pub fn formatAplayCommand(wav_path: []const u8, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "aplay -q {s}", .{wav_path});
    }

    /// Advance ducking → speaking → restoring → idle on one physics tick.
    /// Never blocks, never allocates, never shells out to aplay/wpctl.
    pub fn tickPhysics(self: *TtsEngine) TtsState {
        if (self.state == .idle) return .idle;
        self.ticks_in_state += 1;
        const limit: u32 = switch (self.state) {
            .idle => 0,
            .ducking => TTS_DUCK_FRAMES,
            .speaking => TTS_SPEAK_FRAMES,
            .restoring => TTS_RESTORE_FRAMES,
        };
        if (self.ticks_in_state >= limit) {
            self.ticks_in_state = 0;
            self.state = switch (self.state) {
                .idle => .idle,
                .ducking => .speaking,
                .speaking => .restoring,
                .restoring => .idle,
            };
        }
        return self.state;
    }

    /// Endian-safe standard 44-byte RIFF/WAVE header generator in pure Zig
    pub fn generateWavHeader(sample_rate: u32, channels: u16, bits_per_sample: u16, data_len: u32, header_out: *[44]u8) void {
        const byte_rate = sample_rate * @as(u32, channels) * (@as(u32, bits_per_sample) / 8);
        const block_align = channels * (bits_per_sample / 8);
        const file_size_minus_8 = 36 + data_len;

        @memcpy(header_out[0..4], "RIFF");
        std.mem.writeInt(u32, header_out[4..8], file_size_minus_8, .little);
        @memcpy(header_out[8..12], "WAVE");

        @memcpy(header_out[12..16], "fmt ");
        std.mem.writeInt(u32, header_out[16..20], 16, .little);
        std.mem.writeInt(u16, header_out[20..22], 1, .little);
        std.mem.writeInt(u16, header_out[22..24], channels, .little);
        std.mem.writeInt(u32, header_out[24..28], sample_rate, .little);
        std.mem.writeInt(u32, header_out[28..32], byte_rate, .little);
        std.mem.writeInt(u16, header_out[32..34], block_align, .little);
        std.mem.writeInt(u16, header_out[34..36], bits_per_sample, .little);

        @memcpy(header_out[36..40], "data");
        std.mem.writeInt(u32, header_out[40..44], data_len, .little);
    }

    /// Pack a TTS request into an Invariant A-1 cell
    pub fn packTtsCell(self: *TtsEngine, text: []const u8, voice: TtsVoice, cell_out: *geometry.Cell) !void {
        self.active_voice = voice;
        cell_out.* = std.mem.zeroes(geometry.Cell);

        var subj: [16]u8 = @splat(0);
        const voice_name = voice.name();
        @memcpy(subj[0..@min(voice_name.len, 16)], voice_name[0..@min(voice_name.len, 16)]);

        cell_out.header = geometry.BytecodeHeader{
            .opcode = OP_TTS_REQUEST,
            .subject_id = subj,
            .predicate_op = @splat(0),
            .target_val = @splat(0),
            .provenance_flags = @as(u64, @intCast(@min(text.len, 0xFFFF))),
        };

        const copy_len = @min(text.len, geometry.SEMANTIC_PAYLOAD_BYTES);
        @memcpy(cell_out.semantic_payload[0..copy_len], text[0..copy_len]);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stderr = std.Io.File.stderr().writer(init.io, &.{});
    var stdout = std.Io.File.stdout().writer(init.io, &.{});

    if (args.len < 4) {
        try stderr.interface.print("Usage: stt_pointer_cli <agent_id> <transcript> <client_x> <client_y> [viewport_w] [viewport_h] [note] [screenshot_path] [ts]\n", .{});
        std.process.exit(1);
    }

    const agent_id = args[1];
    const transcript = args[2];
    const client_x = std.fmt.parseFloat(f64, args[3]) catch 0.0;
    const client_y = std.fmt.parseFloat(f64, args[4]) catch 0.0;
    const viewport_w = if (args.len > 5) std.fmt.parseFloat(f64, args[5]) catch 1920.0 else 1920.0;
    const viewport_h = if (args.len > 6) std.fmt.parseFloat(f64, args[6]) catch 1080.0 else 1080.0;
    const note = if (args.len > 7) args[7] else "";
    const screenshot = if (args.len > 8) args[8] else "";
    const ts = if (args.len > 9) args[9] else "2026-08-08T00:40:00Z";

    const packet = SttPointerPacket{
        .ts = ts,
        .agent_id = agent_id,
        .raw_transcript = transcript,
        .pointer = .{
            .client_x = client_x,
            .client_y = client_y,
            .viewport_w = viewport_w,
            .viewport_h = viewport_h,
            .note = note,
        },
        .screenshot_path = screenshot,
    };

    var buf: [2048]u8 = undefined;
    const json = try packet.formatPacket(&buf);
    try stdout.interface.print("{s}\n", .{json});
}

// ── Unit Tests ───────────────────────────────────────────────────────────────

test "PointerData normalized and NDC coordinates" {
    const ptr = PointerData{
        .client_x = 960.0,
        .client_y = 540.0,
        .viewport_w = 1920.0,
        .viewport_h = 1080.0,
    };

    try std.testing.expectApproxEqAbs(ptr.normalizedX(), 0.5, 0.001);
    try std.testing.expectApproxEqAbs(ptr.normalizedY(), 0.5, 0.001);

    const ndc = ptr.toNdc();
    try std.testing.expectApproxEqAbs(ndc.x, 0.0, 0.001);
    try std.testing.expectApproxEqAbs(ndc.y, 0.0, 0.001);

    // Top-left
    const tl = PointerData{
        .client_x = 0.0,
        .client_y = 0.0,
        .viewport_w = 1920.0,
        .viewport_h = 1080.0,
    };
    const tl_ndc = tl.toNdc();
    try std.testing.expectApproxEqAbs(tl_ndc.x, -1.0, 0.001);
    try std.testing.expectApproxEqAbs(tl_ndc.y, 1.0, 0.001);

    // Bottom-right
    const br = PointerData{
        .client_x = 1920.0,
        .client_y = 1080.0,
        .viewport_w = 1920.0,
        .viewport_h = 1080.0,
    };
    const br_ndc = br.toNdc();
    try std.testing.expectApproxEqAbs(br_ndc.x, 1.0, 0.001);
    try std.testing.expectApproxEqAbs(br_ndc.y, -1.0, 0.001);

    // Inside test
    try std.testing.expect(ptr.isInside(500.0, 200.0, 1200.0, 800.0));
    try std.testing.expect(!ptr.isInside(0.0, 0.0, 100.0, 100.0));
}

test "SttPointerPacket formatPacket formatting and 17KB cell ceiling" {
    const packet = SttPointerPacket{
        .ts = "2026-08-08T00:00:00Z",
        .agent_id = "agent_15",
        .raw_transcript = "fix button layout and link to tot_hybrid",
        .pointer = .{
            .client_x = 640.0,
            .client_y = 360.0,
            .viewport_w = 1280.0,
            .viewport_h = 720.0,
            .note = "click target",
        },
        .hovered_node = "brain-1-cell",
        .screenshot_path = "/tmp/shot.png",
    };

    var buf: [1024]u8 = undefined;
    const json = try packet.formatPacket(&buf);
    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"relative_pct\":[50.0,50.0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hovered_node\":\"brain-1-cell\"") != null);
    try std.testing.expect(json.len <= MAX_CELL_BYTES);

    // Test packing to exact Invariant A-1 (17,408B) cell
    var cell: geometry.Cell = undefined;
    try packet.packToCell(&cell);
    try std.testing.expectEqual(@as(usize, 17408), @sizeOf(geometry.Cell));
    try std.testing.expectEqual(OP_STT_POINTER, cell.header.opcode);
    try std.testing.expectEqualStrings("agent_15", std.mem.sliceTo(&cell.header.subject_id, 0));
    try std.testing.expectEqualStrings("brain-1-cell", std.mem.sliceTo(&cell.header.predicate_op, 0));
}

test "SttPointerPacket with Harper auto-corrected transcript" {
    const packet = SttPointerPacket{
        .ts = "2026-09-08T22:30:00Z",
        .agent_id = "seat_0_claude",
        .raw_transcript = "we will wants to check the databaes",
        .harper_transcript = "We will want to check the database",
        .pointer = .{
            .client_x = 100.0,
            .client_y = 200.0,
            .viewport_w = 1920.0,
            .viewport_h = 1080.0,
        },
        .hovered_node = "database-config",
    };

    var buf: [1024]u8 = undefined;
    const json = try packet.formatPacket(&buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"transcript\":\"We will want to check the database\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"raw_transcript\":\"we will wants to check the databaes\"") != null);

    var cell: geometry.Cell = undefined;
    try packet.packToCell(&cell);
    try std.testing.expectEqual(OP_STT_POINTER, cell.header.opcode);
    try std.testing.expectEqual(@as(u64, "We will want to check the database".len), cell.header.provenance_flags);
}

test "TtsEngine ducking and restore commands" {
    var tts = TtsEngine{};
    try std.testing.expectEqual(TtsState.idle, tts.state);

    var duck_cmd_buf: [128]u8 = undefined;
    const duck_cmd = try tts.formatDuckCommand(&duck_cmd_buf);
    try std.testing.expectEqualStrings("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.30", duck_cmd);

    var restore_cmd_buf: [128]u8 = undefined;
    const restore_cmd = try tts.formatRestoreCommand(&restore_cmd_buf);
    try std.testing.expectEqualStrings("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.90", restore_cmd);

    var aplay_cmd_buf: [128]u8 = undefined;
    const aplay_cmd = try TtsEngine.formatAplayCommand("/tmp/speech.wav", &aplay_cmd_buf);
    try std.testing.expectEqualStrings("aplay -q /tmp/speech.wav", aplay_cmd);
}

test "TtsEngine WAV header generator and cell packing" {
    var header: [44]u8 = undefined;
    TtsEngine.generateWavHeader(16000, 1, 16, 32000, &header);

    try std.testing.expectEqualStrings("RIFF", header[0..4]);
    try std.testing.expectEqualStrings("WAVE", header[8..12]);
    try std.testing.expectEqualStrings("fmt ", header[12..16]);
    try std.testing.expectEqualStrings("data", header[36..40]);

    // Subchunk1Size = 16
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, header[16..20], .little));
    // AudioFormat = 1 (PCM)
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, header[20..22], .little));
    // Channels = 1
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, header[22..24], .little));
    // SampleRate = 16000
    try std.testing.expectEqual(@as(u32, 16000), std.mem.readInt(u32, header[24..28], .little));
    // ByteRate = 16000 * 1 * 2 = 32000
    try std.testing.expectEqual(@as(u32, 32000), std.mem.readInt(u32, header[28..32], .little));
    // DataLen = 32000
    try std.testing.expectEqual(@as(u32, 32000), std.mem.readInt(u32, header[40..44], .little));

    // Cell packing test
    var tts = TtsEngine{};
    var cell: geometry.Cell = undefined;
    try tts.packTtsCell("Cockpit layout converged. All invariants green.", .af_heart, &cell);

    try std.testing.expectEqual(OP_TTS_REQUEST, cell.header.opcode);
    try std.testing.expectEqualStrings("af_heart", std.mem.sliceTo(&cell.header.subject_id, 0));
    try std.testing.expect(std.mem.startsWith(u8, &cell.semantic_payload, "Cockpit layout converged."));
}

test "TtsEngine tickPhysics advances ducking without blocking" {
    var tts = TtsEngine{};
    tts.state = .ducking;
    tts.ticks_in_state = 0;

    var i: u32 = 0;
    while (i < TTS_DUCK_FRAMES) : (i += 1) {
        _ = tts.tickPhysics();
    }
    try std.testing.expectEqual(TtsState.speaking, tts.state);

    i = 0;
    while (i < TTS_SPEAK_FRAMES) : (i += 1) {
        _ = tts.tickPhysics();
    }
    try std.testing.expectEqual(TtsState.restoring, tts.state);

    i = 0;
    while (i < TTS_RESTORE_FRAMES) : (i += 1) {
        _ = tts.tickPhysics();
    }
    try std.testing.expectEqual(TtsState.idle, tts.state);
    try std.testing.expectEqual(TtsState.idle, tts.tickPhysics());
}

comptime {
    std.debug.assert(MAX_CELL_BYTES == 17408);
    std.debug.assert(geometry.BYTECODE_HEADER_BYTES == 64);
}
