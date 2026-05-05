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
pub const Writer = struct {
    mu: *std.Thread.Mutex,

    /// Serialise the full render state as a single JSON line.
    /// Clears game.last_action_count after flushing so each animation fires once.
    pub fn write_render(
        self: Writer,
        phase: ClientPhaseTag,
        lobby: *const LobbyState,
        game: *GameState,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();
        var frame_buf: [8192]u8 = undefined;
        var w = std.io.Writer.fixed(&frame_buf);
        write_render_inner(&w, phase, lobby, game) catch return;
        w.writeByte('\n') catch return;
        const out = std.fs.File.stdout();
        out.writeAll(w.buffered()) catch return;
        game.last_action_count = 0;
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
    player_id: u8 = 0xFF,
    ready: bool = false,
    /// Cosmetic lobby position cursor (col 0–2, row 0–3).
    chosen_pos: struct { col: u8 = 0, row: u8 = 0 } = .{},
};

pub const LastActionEntry = struct { entity: u32, anim: c.ActionAnimation };

pub const GameState = struct {
    snapshot: proto.GameState = std.mem.zeroes(proto.GameState),
    player_id: u8 = 0xFF,
    /// Actions the player has queued this round (0–4 slots).
    /// Cleared when the server broadcasts round_reset.
    pending_combo: inp.ComboBuffer = .{},
    round_timer: f32 = 0.0,
    round_duration: f32 = 0.0,
    wave_label: [32]u8 = [_]u8{0} ** 32,
    wave_label_len: u8 = 0,
    winner: ?proto.WinnerId = null,
    /// Animations triggered this tick by action_result messages.
    /// Cleared by write_render() after each flush so each animation fires once.
    last_action_count: u8 = 0,
    last_actions: [proto.MAX_ENTITIES_WIRE]LastActionEntry = undefined,
};

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
        players_buf[i] = .{
            .id = p.player_id,
            .name = p.name[0..p.name_len],
            .class = p.class,
            .ready = p.ready,
            .connected = p.connected,
            .grid_col = p.grid_col,
            .grid_row = p.grid_row,
        };
    }

    var entities_buf: [proto.MAX_ENTITIES_WIRE]JsonEntity = undefined;
    for (0..game.snapshot.entity_count) |i| {
        // Use a pointer so combo slice remains valid for the lifetime of entities_buf.
        const e = &game.snapshot.entities[i];
        // Find any animation triggered for this entity this tick.
        var anim: ?c.ActionAnimation = null;
        for (game.last_actions[0..game.last_action_count]) |la| {
            if (la.entity == e.entity) { anim = la.anim; break; }
        }
        entities_buf[i] = .{
            .id = e.entity,
            .slot = e.slot,
            .hp = e.hp_current,
            .hp_max = e.hp_max,
            .shield_hp = e.shield_hp,
            .class = e.class,
            .team = e.team,
            .owner = e.owner,
            .last_action = anim,
            .combo = e.combo_actions[0..e.combo_len],
        };
    }

    const frame = JsonRenderFrame{
        .tag = "render",
        .phase = phase,
        .lobby = if (phase == .lobby) JsonLobby{
            .join_code = lobby.update.join_code[0..jc_end],
            .player_id = lobby.update.player_id,
            .ready = lobby.ready,
            .chosen_col = lobby.chosen_pos.col,
            .chosen_row = lobby.chosen_pos.row,
            .round_duration = lobby.update.round_duration,
            .players = players_buf[0..lobby.update.player_count],
        } else null,
        .game = if (phase == .game) JsonGame{
            .wave = game.wave_label[0..game.wave_label_len],
            .player_id = game.player_id,
            .pending_combo = game.pending_combo.actions[0..game.pending_combo.len],
            .round_timer = game.round_timer,
            .round_duration = game.round_duration,
            .tick = game.snapshot.tick,
            .entities = entities_buf[0..game.snapshot.entity_count],
        } else null,
        .winner = if (phase == .game_over) game.winner else null,
    };

    try std.json.Stringify.value(frame, .{ .emit_null_optional_fields = false }, w);
}

const JsonSendFrame = struct {
    tag: []const u8,
    bytes: HexBytes,
};

const HexBytes = struct {
    data: []const u8,

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
    winner: ?proto.WinnerId,
};

const JsonLobby = struct {
    join_code: []const u8,
    player_id: u8,
    ready: bool,
    chosen_col: u8,
    chosen_row: u8,
    round_duration: f32,
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
    player_id: u8,
    /// Filled prefix of the player's current combo (0–4 entries).
    /// Empty slice when no combo is pending.
    pending_combo: []const c.ActionChoice,
    round_timer: f32,
    round_duration: f32,
    tick: u32,
    entities: []const JsonEntity,
};

const JsonEntity = struct {
    id: u32,
    slot: u8,
    hp: u16,
    hp_max: u16,
    shield_hp: u16,
    class: c.ClassTag,
    team: c.TeamId,
    owner: u8,
    /// Animation to play this tick; null if none.  Omitted from JSON when null.
    last_action: ?c.ActionAnimation,
    /// Filled prefix of the owning player's pending combo (0–4 entries).
    /// Empty slice for enemy entities or players with no pending combo.
    combo: []const c.ActionChoice,
};
