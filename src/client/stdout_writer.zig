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
        var w = std.io.Writer.fixed(&frame_buf);
        write_render_inner(&w, phase, lobby, game) catch return;
        w.writeByte('\n') catch return;
        const out = std.fs.File.stdout();
        out.writeAll(w.buffered()) catch return;
    }

    /// Emit a `send` frame carrying hex-encoded bytes for the bridge to
    /// forward to the game server.
    pub fn write_send(self: Writer, bytes: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        var frame_buf: [2048]u8 = undefined;
        var w = std.io.Writer.fixed(&frame_buf);
        const frame = JsonSendFrame{ .tag = "send", .bytes = .{ .data = bytes } };
        std.json.Stringify.value(frame, .{}, &w) catch return;
        w.writeByte('\n') catch return;
        const out = std.fs.File.stdout();
        out.writeAll(w.buffered()) catch return;
    }
};

pub const ClientPhaseTag = enum { connecting, lobby, game, game_over };

pub const LobbyState = struct {
    update: proto.LobbyUpdate = std.mem.zeroes(proto.LobbyUpdate),
    our_player_id: u8 = 0xFF,
    selected_class: c.ClassTag = .fighter,
    ready: bool = false,
    /// Cursor position in the lobby position-picker grid (col 0–2, row 0–1).
    chosen_pos: c.GridPos = .{ .col = 0, .row = 0 },
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
    w: *std.io.Writer,
    phase: ClientPhaseTag,
    lobby: *const LobbyState,
    game: *const GameState,
) !void {
    const jc_end = std.mem.indexOfScalar(u8, &lobby.update.join_code, 0) orelse lobby.update.join_code.len;

    var players_buf: [proto.MAX_PLAYERS]JsonPlayer = undefined;
    for (0..lobby.update.player_count) |i| {
        const p = lobby.update.players[i];
        const name_end = p.name_len;
        players_buf[i] = .{
            .id = p.player_id,
            .name = p.name[0..name_end],
            .class = p.class,
            .ready = p.ready,
            .connected = p.connected,
            .grid_col = p.grid_col,
            .grid_row = p.grid_row,
        };
    }

    var entities_buf: [proto.MAX_ENTITIES_WIRE]JsonEntity = undefined;
    for (0..game.snapshot.entity_count) |i| {
        const e = game.snapshot.entities[i];
        entities_buf[i] = .{
            .id = e.entity,
            .col = e.grid_col,
            .row = e.grid_row,
            .hp = e.hp_current,
            .hp_max = e.hp_max,
            .atb = e.atb_gauge,
            .state = e.action_state,
            .class = e.class,
            .team = e.team,
            .owner = e.owner,
        };
    }

    const frame = JsonRenderFrame{
        .tag = "render",
        .phase = phase,
        .lobby = if (phase == .lobby) JsonLobby{
            .join_code = lobby.update.join_code[0..jc_end],
            .our_player_id = lobby.update.your_player_id,
            .selected_class = lobby.selected_class,
            .ready = lobby.ready,
            .chosen_col = lobby.chosen_pos.col,
            .chosen_row = lobby.chosen_pos.row,
            .players = players_buf[0..lobby.update.player_count],
        } else null,
        .game = if (phase == .game) JsonGame{
            .wave = game.wave_label[0..game.wave_label_len],
            .our_player_id = game.our_player_id,
            .our_entity = game.our_entity,
            .is_our_turn = game.cursor.is_our_turn,
            .action_selected = game.action_selected,
            .targeting_enemy = game.targeting_enemy,
            .cursor = .{ .col = game.cursor.cursor_col, .row = game.cursor.cursor_row },
            .tick = game.snapshot.tick,
            .entities = entities_buf[0..game.snapshot.entity_count],
        } else null,
    };

    try std.json.Stringify.value(frame, .{ .emit_null_optional_fields = false }, w);
}

// ---------------------------------------------------------------------------
// JSON frame shapes — serialisation-only, private to this file.
// ---------------------------------------------------------------------------

const JsonSendFrame = struct {
    tag: []const u8,
    bytes: HexBytes,
};

const HexBytes = struct {
    data: []const u8,

    /// Emits the bytes as a hex-encoded JSON string without buffering the
    /// full encoded form — writes directly to the underlying writer.
    pub fn jsonStringify(self: HexBytes, jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.writer.writeByte('"');
        for (self.data) |b| try jws.writer.print("{x:0>2}", .{b});
        try jws.writer.writeByte('"');
        jws.endWriteRaw();
    }
};

const JsonRenderFrame = struct {
    tag: []const u8,
    phase: ClientPhaseTag,
    lobby: ?JsonLobby,
    game: ?JsonGame,
};

const JsonLobby = struct {
    join_code: []const u8,
    our_player_id: u8,
    selected_class: c.ClassTag,
    ready: bool,
    chosen_col: u8,
    chosen_row: u8,
    players: []const JsonPlayer,
};

const JsonPlayer = struct {
    id: u8,
    name: []const u8,
    class: c.ClassTag,
    ready: bool,
    connected: bool,
    grid_col: u8,
    grid_row: u8,
};

const JsonGame = struct {
    wave: []const u8,
    our_player_id: u8,
    our_entity: u32,
    is_our_turn: bool,
    action_selected: ?proto.ActionTag,
    targeting_enemy: bool,
    cursor: struct { col: u8, row: u8 },
    tick: u32,
    entities: []const JsonEntity,
};

const JsonEntity = struct {
    id: u32,
    col: u8,
    row: u8,
    hp: u16,
    hp_max: u16,
    atb: f32,
    state: c.ActionStateTag,
    class: c.ClassTag,
    team: c.TeamId,
    owner: u8,

    /// Custom serialiser: emits `atb` as a 3-decimal-place number rather than
    /// the full float representation that `std.json.write` would produce.
    pub fn jsonStringify(self: JsonEntity, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("col");
        try jws.write(self.col);
        try jws.objectField("row");
        try jws.write(self.row);
        try jws.objectField("hp");
        try jws.write(self.hp);
        try jws.objectField("hp_max");
        try jws.write(self.hp_max);
        try jws.objectField("atb");
        try jws.print("{d:.3}", .{self.atb});
        try jws.objectField("state");
        try jws.write(self.state);
        try jws.objectField("class");
        try jws.write(self.class);
        try jws.objectField("team");
        try jws.write(self.team);
        try jws.objectField("owner");
        try jws.write(self.owner);
        try jws.endObject();
    }
};
