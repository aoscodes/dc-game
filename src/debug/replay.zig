//! GameState replay recorder and player.
//!
//! Records a sequence of proto.GameState frames to any std.io.Writer, and
//! plays them back frame-by-frame from any std.io.Reader.  Reuses the
//! existing wire-protocol encoders/decoders; no extra dependencies.
//!
//! File format:
//!
//!   [4]  magic    "RPLY"
//!   [4]  version  u32 (= 1)
//!   per frame:
//!     [4]  frame_len  u32  — total byte count of the encoded game_state msg
//!     [frame_len]          — proto.encode(.game_state, ...) output
//!   [4]  sentinel  0x00000000  — marks end of stream
//!
//! Usage:
//!
//!   // record
//!   var rec = try Recorder.init(file.writer());
//!   try rec.record(game_state);
//!   try rec.finish();
//!
//!   // play back
//!   var play = try Player.init(file.reader(), allocator);
//!   while (try play.next()) |gs| { ... }

const std = @import("std");
const proto = @import("shared").protocol;

const MAGIC: [4]u8 = "RPLY".*;
const VERSION: u32 = 1;
const SENTINEL: u32 = 0;

/// Write a u32 as 4 little-endian bytes without requiring writeInt on the writer.
inline fn int_to_le(comptime T: type, val: T) [@sizeOf(T)]u8 {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, val, .little);
    return buf;
}

/// Read a u32 from 4 little-endian bytes without requiring readInt on the reader.
inline fn read_le_u32(reader: anytype) !u32 {
    var buf: [4]u8 = undefined;
    _ = try reader.readAll(&buf);
    return std.mem.readInt(u32, &buf, .little);
}

// ---------------------------------------------------------------------------
// Recorder
// ---------------------------------------------------------------------------

/// Wraps any std.io.Writer.  Not thread-safe; caller must serialise calls.
pub fn Recorder(comptime WriterType: type) type {
    return struct {
        const Self = @This();

        writer: WriterType,
        frame_count: u32 = 0,
        finished: bool = false,

        pub fn init(writer: WriterType) !Self {
            var self = Self{ .writer = writer };
            try self.writer.writeAll(&MAGIC);
            try self.writer.writeAll(&int_to_le(u32, VERSION));
            return self;
        }

        /// Encode and append one GameState frame.
        pub fn record(self: *Self, state: proto.GameState) !void {
            // Encode into a temporary buffer to measure length first.
            var frame_buf: [4096]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&frame_buf);
            try proto.encode(fbs.writer(), .game_state, state);
            const encoded = fbs.getWritten();

            try self.writer.writeAll(&int_to_le(u32, @intCast(encoded.len)));
            try self.writer.writeAll(encoded);
            self.frame_count += 1;
        }

        /// Write the sentinel and mark the stream as complete.
        pub fn finish(self: *Self) !void {
            try self.writer.writeAll(&int_to_le(u32, SENTINEL));
            self.finished = true;
        }
    };
}

// ---------------------------------------------------------------------------
// Player
// ---------------------------------------------------------------------------

/// Wraps any std.io.Reader.  Reads frames sequentially.
pub fn Player(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        reader: ReaderType,
        done: bool = false,

        pub fn init(reader: ReaderType) !Self {
            var magic: [4]u8 = undefined;
            _ = try reader.readAll(&magic);
            if (!std.mem.eql(u8, &magic, &MAGIC)) return error.BadMagic;
            const ver = try read_le_u32(reader);
            if (ver != VERSION) return error.UnsupportedVersion;
            return Self{ .reader = reader };
        }

        /// Returns the next GameState, or null at end-of-stream.
        pub fn next(self: *Self) !?proto.GameState {
            if (self.done) return null;
            const frame_len = try read_le_u32(self.reader);
            if (frame_len == SENTINEL) {
                self.done = true;
                return null;
            }
            if (frame_len > 4096) return error.FrameTooLarge;
            var frame_buf: [4096]u8 = undefined;
            _ = try self.reader.readAll(frame_buf[0..frame_len]);
            var fbs = std.io.fixedBufferStream(frame_buf[0..frame_len]);
            _ = try proto.read_tag(fbs.reader()); // consume the .game_state tag byte
            return try proto.decode_game_state(fbs.reader());
        }
    };
}

// ---------------------------------------------------------------------------
// Convenience constructors (infer generic params from arguments)
// ---------------------------------------------------------------------------

pub fn recorder(writer: anytype) !Recorder(@TypeOf(writer)) {
    return Recorder(@TypeOf(writer)).init(writer);
}

pub fn player(reader: anytype) !Player(@TypeOf(reader)) {
    return Player(@TypeOf(reader)).init(reader);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "replay: record then play back" {
    const components = @import("shared").components;
    var buf: [65536]u8 = undefined;
    var fbs_w = std.io.fixedBufferStream(&buf);

    var rec = try recorder(fbs_w.writer());

    // Build two dummy GameState frames
    var gs1 = proto.GameState{
        .tick = 1,
        .entity_count = 1,
        .entities = [_]proto.EntitySnapshot{std.mem.zeroes(proto.EntitySnapshot)} ** proto.MAX_ENTITIES_WIRE,
    };
    gs1.entities[0] = .{
        .entity = 0,
        .grid_col = 1,
        .grid_row = 0,
        .hp_current = 100,
        .hp_max = 100,
        .atb_gauge = 0.5,
        .action_state = .idle,
        .class = .fighter,
        .team = .players,
        .owner = 0,
    };
    var gs2 = gs1;
    gs2.tick = 2;
    gs2.entities[0].atb_gauge = 0.75;

    try rec.record(gs1);
    try rec.record(gs2);
    try rec.finish();

    // Play back
    var fbs_r = std.io.fixedBufferStream(fbs_w.getWritten());
    var play = try player(fbs_r.reader());

    const f1 = (try play.next()) orelse return error.ExpectedFrame;
    try std.testing.expectEqual(@as(u32, 1), f1.tick);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), f1.entities[0].atb_gauge, 0.001);

    const f2 = (try play.next()) orelse return error.ExpectedFrame;
    try std.testing.expectEqual(@as(u32, 2), f2.tick);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), f2.entities[0].atb_gauge, 0.001);

    try std.testing.expect((try play.next()) == null);
    _ = components; // suppress unused import warning
}
