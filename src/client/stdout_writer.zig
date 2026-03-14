//! Serialises client state to newline-delimited JSON frames written to stdout.
//!
//! Two frame kinds:
//!
//!   render  — full UI snapshot sent every tick so the browser can redraw.
//!   send    — request for the bridge to forward bytes to the game server.
//!
//! The bridge reads these frames from the child process stdout.

const std = @import("std");
const proto = @import("shared").protocol;
const c = @import("shared").components;
const inp = @import("input.zig");

/// Writer wraps stdout with a mutex so stdin-reader and game loop don't race.
/// Uses a local stack buffer to batch writes into a single syscall per frame.
pub const Writer = struct {
    mu: *std.Thread.Mutex,

    /// Serialise the full render state as a single JSON line.
    pub fn write_render(
        self: Writer,
        phase: ClientPhaseTag,
        lobby: *const LobbyState,
        game: *const GameState,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();
        // Stack-allocated frame buffer — large enough for all entity data.
        var frame_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&frame_buf);
        const w = fbs.writer();
        write_render_inner(w, phase, lobby, game) catch return;
        w.writeByte('\n') catch return;
        const out = std.fs.File.stdout();
        out.writeAll(fbs.getWritten()) catch return;
    }

    /// Emit a `send` frame carrying hex-encoded bytes for the bridge to
    /// forward to the game server.
    pub fn write_send(self: Writer, bytes: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        var frame_buf: [2048]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&frame_buf);
        const w = fbs.writer();
        w.writeAll("{\"tag\":\"send\",\"bytes\":\"") catch return;
        for (bytes) |b| {
            w.print("{x:0>2}", .{b}) catch return;
        }
        w.writeAll("\"}\n") catch return;
        const out = std.fs.File.stdout();
        out.writeAll(fbs.getWritten()) catch return;
    }
};

pub const ClientPhaseTag = enum { connecting, lobby, game, game_over };

pub const LobbyState = struct {
    update: proto.LobbyUpdate = std.mem.zeroes(proto.LobbyUpdate),
    our_player_id: u8 = 0xFF,
    selected_class: c.ClassTag = .fighter,
    ready: bool = false,
};

pub const GameState = struct {
    snapshot: proto.GameState = std.mem.zeroes(proto.GameState),
    our_player_id: u8 = 0xFF,
    our_entity: u32 = std.math.maxInt(u32),
    cursor: inp.InputState = .{},
    targeting_enemy: bool = true,
    action_selected: ?proto.ActionTag = null,
    wave_label: [32]u8 = [_]u8{0} ** 32,
    wave_label_len: u8 = 0,
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn write_render_inner(
    w: anytype,
    phase: ClientPhaseTag,
    lobby: *const LobbyState,
    game: *const GameState,
) !void {
    try w.writeAll("{\"tag\":\"render\",\"phase\":\"");
    try w.writeAll(@tagName(phase));
    try w.writeAll("\"");

    switch (phase) {
        .lobby => try write_lobby(w, lobby),
        .game => try write_game(w, game),
        .game_over => {},
        .connecting => {},
    }

    try w.writeByte('}');
}

fn write_lobby(w: anytype, s: *const LobbyState) !void {
    try w.writeAll(",\"lobby\":{");
    try w.writeAll("\"join_code\":\"");
    // join_code is a fixed [6]u8 zero-padded buffer; only emit the non-NUL prefix
    // so that zero-initialised state produces valid JSON ("") rather than a string
    // containing NUL bytes that breaks JSON.parse in both Node and the browser.
    const jc_end = std.mem.indexOfScalar(u8, &s.update.join_code, 0) orelse s.update.join_code.len;
    try write_escaped(w, s.update.join_code[0..jc_end]);
    try w.writeAll("\",\"our_player_id\":");
    try w.print("{}", .{s.update.your_player_id});
    try w.writeAll(",\"selected_class\":\"");
    try w.writeAll(@tagName(s.selected_class));
    try w.writeAll("\",\"ready\":");
    try w.writeAll(if (s.ready) "true" else "false");
    try w.writeAll(",\"players\":[");
    var i: u8 = 0;
    while (i < s.update.player_count) : (i += 1) {
        if (i > 0) try w.writeByte(',');
        const p = s.update.players[i];
        try w.writeAll("{\"id\":");
        try w.print("{}", .{p.player_id});
        try w.writeAll(",\"name\":\"");
        try write_escaped(w, p.name[0..p.name_len]);
        try w.writeAll("\",\"class\":\"");
        try w.writeAll(@tagName(p.class));
        try w.writeAll("\",\"ready\":");
        try w.writeAll(if (p.ready) "true" else "false");
        try w.writeAll(",\"connected\":");
        try w.writeAll(if (p.connected) "true" else "false");
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

fn write_game(w: anytype, s: *const GameState) !void {
    try w.writeAll(",\"game\":{");
    try w.writeAll("\"wave\":\"");
    try write_escaped(w, s.wave_label[0..s.wave_label_len]);
    try w.writeAll("\",\"our_player_id\":");
    try w.print("{}", .{s.our_player_id});
    try w.writeAll(",\"our_entity\":");
    try w.print("{}", .{s.our_entity});
    try w.writeAll(",\"is_our_turn\":");
    try w.writeAll(if (s.cursor.is_our_turn) "true" else "false");
    try w.writeAll(",\"action_selected\":");
    if (s.action_selected) |act| {
        try w.writeByte('"');
        try w.writeAll(@tagName(act));
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"targeting_enemy\":");
    try w.writeAll(if (s.targeting_enemy) "true" else "false");
    try w.writeAll(",\"cursor\":{\"col\":");
    try w.print("{}", .{s.cursor.cursor_col});
    try w.writeAll(",\"row\":");
    try w.print("{}", .{s.cursor.cursor_row});
    try w.writeByte('}');
    try w.writeAll(",\"tick\":");
    try w.print("{}", .{s.snapshot.tick});
    try w.writeAll(",\"entities\":[");
    var i: u8 = 0;
    while (i < s.snapshot.entity_count) : (i += 1) {
        if (i > 0) try w.writeByte(',');
        const e = s.snapshot.entities[i];
        try w.writeAll("{\"id\":");
        try w.print("{}", .{e.entity});
        try w.writeAll(",\"col\":");
        try w.print("{}", .{e.grid_col});
        try w.writeAll(",\"row\":");
        try w.print("{}", .{e.grid_row});
        try w.writeAll(",\"hp\":");
        try w.print("{}", .{e.hp_current});
        try w.writeAll(",\"hp_max\":");
        try w.print("{}", .{e.hp_max});
        try w.writeAll(",\"atb\":");
        try w.print("{d:.3}", .{e.atb_gauge});
        try w.writeAll(",\"state\":\"");
        try w.writeAll(@tagName(e.action_state));
        try w.writeAll("\",\"class\":\"");
        try w.writeAll(@tagName(e.class));
        try w.writeAll("\",\"team\":\"");
        try w.writeAll(@tagName(e.team));
        try w.writeAll("\",\"owner\":");
        try w.print("{}", .{e.owner});
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

/// Write a string with JSON escaping.
/// Handles backslash, double-quote, and ASCII control characters (0x00–0x1F)
/// using \uXXXX escapes so the output is always valid JSON.
fn write_escaped(w: anytype, s: []const u8) !void {
    for (s) |b| {
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            // remaining control chars (excludes \n=0x0A, \r=0x0D, \t=0x09)
            0x00...0x08, 0x0B...0x0C, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{b}),
            else => try w.writeByte(b),
        }
    }
}
