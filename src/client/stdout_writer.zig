const std = @import("std");
const proto = @import("shared").protocol;
const c = @import("shared").components;
const inp = @import("input.zig");

/// JSON serialisation for ComboSlot.
/// Emits {"action":"damage"} or {"element":"fire"} so game.js can branch.
const JsonComboSlot = struct {
    slot: c.ComboSlot,

    pub fn jsonStringify(self: JsonComboSlot, jws: anytype) !void {
        try jws.beginObject();
        switch (self.slot) {
            .action  => |a| { try jws.objectField("action");  try jws.write(@tagName(a)); },
            .element => |e| { try jws.objectField("element"); try jws.write(@tagName(e)); },
        }
        try jws.endObject();
    }
};

pub const Writer = struct {
    mu: *std.Thread.Mutex,

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
};

pub const LastActionEntry = struct { entity: u32, anim: c.ActionAnimation };

pub const GameState = struct {
    snapshot: proto.GameState = proto.GameState.blank,
    player_id: u8 = 0xFF,
    pending_combo: inp.ComboBuffer = .{},
    round_timer: f32 = 0.0,
    round_duration: f32 = 0.0,
    wave_label: [32]u8 = [_]u8{0} ** 32,
    wave_label_len: u8 = 0,
    winner: ?proto.WinnerId = null,
    last_action_count: u8 = 0,
    last_actions: [proto.MAX_ENTITIES_WIRE]LastActionEntry = undefined,
    /// Incremented each time a round_reset message is received.
    /// JS detects a change in this value to know a round just resolved.
    round: u32 = 0,
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

    // Per-entity slot buffers for JSON serialisation.
    var slot_bufs: [proto.MAX_ENTITIES_WIRE][c.MAX_COMBO_LEN]JsonComboSlot = undefined;
    var entities_buf: [proto.MAX_ENTITIES_WIRE]JsonEntity = undefined;
    for (0..game.snapshot.entity_count) |i| {
        const e = &game.snapshot.entities[i];
        var anim: ?c.ActionAnimation = null;
        for (game.last_actions[0..game.last_action_count]) |la| {
            if (la.entity == e.entity) {
                anim = la.anim;
                break;
            }
        }
        for (e.combo_slots[0..e.combo_len], 0..) |s, j| {
            slot_bufs[i][j] = .{ .slot = s };
        }
        entities_buf[i] = .{
            .id = e.entity,
            .class = e.class,
            .team = e.team,
            .owner = e.owner,
            .last_action = anim,
            .combo = slot_bufs[i][0..e.combo_len],
        };
    }

    // Convert pending combo slots for JSON.
    var pending_slots_buf: [c.MAX_COMBO_LEN]JsonComboSlot = undefined;
    for (game.pending_combo.slots[0..game.pending_combo.len], 0..) |s, i| {
        pending_slots_buf[i] = .{ .slot = s };
    }

    const frame = JsonRenderFrame{
        .tag = "render",
        .phase = phase,
        .lobby = if (phase == .lobby) JsonLobby{
            .join_code = lobby.update.join_code[0..jc_end],
            .player_id = lobby.update.player_id,
            .ready = lobby.ready,
            .round_duration = lobby.update.round_duration,
            .players = players_buf[0..lobby.update.player_count],
        } else null,
        .game = if (phase == .game) JsonGame{
            .wave = game.wave_label[0..game.wave_label_len],
            .player_id = game.player_id,
            .pending_combo = pending_slots_buf[0..game.pending_combo.len],
            .round_timer = game.round_timer,
            .round_duration = game.round_duration,
            .tick = game.snapshot.tick,
            .round = game.round,
            .entities = entities_buf[0..game.snapshot.entity_count],
            .players = .{
                .hp_current = game.snapshot.players.hp_current,
                .hp_max = game.snapshot.players.hp_max,
            },
            .enemies = .{
                .hp_current = game.snapshot.enemies.hp_current,
                .hp_max = game.snapshot.enemies.hp_max,
            },
            .enemy_intent = .{
                .damage      = game.snapshot.enemy_intent_damage,
                .element_raw = game.snapshot.enemy_intent_element,
            },
            .dot_stacks = .{
                .players = .{
                    .fire  = game.snapshot.player_dot_stacks[0],
                    .earth = game.snapshot.player_dot_stacks[1],
                    .wind  = game.snapshot.player_dot_stacks[2],
                    .water = game.snapshot.player_dot_stacks[3],
                },
                .enemies = .{
                    .fire  = game.snapshot.enemy_dot_stacks[0],
                    .earth = game.snapshot.enemy_dot_stacks[1],
                    .wind  = game.snapshot.enemy_dot_stacks[2],
                    .water = game.snapshot.enemy_dot_stacks[3],
                },
            },
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

const JsonTeamSummary = struct {
    hp_current: u16,
    hp_max: u16,
};

/// DoT stacks broadcast each frame so the client can display and floater them.
/// Named by element so Zig's JSON layer emits a proper object, not a byte-string.
const JsonDotStackSide = struct {
    fire:  u16,
    earth: u16,
    wind:  u16,
    water: u16,
};
const JsonDotStacks = struct {
    players: JsonDotStackSide,
    enemies: JsonDotStackSide,
};

/// Serialises enemy intent as `{"damage":N,"element":"fire"}` or `{"damage":N}` when non-elemental.
const JsonEnemyIntent = struct {
    damage: u16,
    /// Raw element byte from protocol: 0xFF = non-elemental (omitted), 0–3 = Element ordinal.
    element_raw: u8,

    pub fn jsonStringify(self: JsonEnemyIntent, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("damage");
        try jws.write(self.damage);
        if (self.element_raw != proto.GameState.INTENT_ELEMENT_NONE) {
            const el = std.meta.intToEnum(c.Element, self.element_raw) catch null;
            if (el) |e| {
                try jws.objectField("element");
                try jws.write(@tagName(e));
            }
        }
        try jws.endObject();
    }
};

const JsonGame = struct {
    wave: []const u8,
    player_id: u8,
    pending_combo: []const JsonComboSlot,
    round_timer: f32,
    round_duration: f32,
    tick: u32,
    round: u32,
    entities: []const JsonEntity,
    players: JsonTeamSummary,
    enemies: JsonTeamSummary,
    enemy_intent: JsonEnemyIntent,
    dot_stacks: JsonDotStacks,
};

const JsonEntity = struct {
    id: u32,
    class: c.ClassTag,
    team: c.TeamId,
    owner: u8,
    last_action: ?c.ActionAnimation,
    combo: []const JsonComboSlot,
};
