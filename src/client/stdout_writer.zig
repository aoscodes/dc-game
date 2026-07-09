const std = @import("std");
const proto = @import("shared").protocol;
const c = @import("shared").components;
const balance = @import("shared").balance;
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
    encounter_label: [32]u8 = [_]u8{0} ** 32,
    encounter_label_len: u8 = 0,
    /// Final score from game_over (null until the encounter ends).
    final_score: ?u32 = null,
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
            .kind = p.kind,
            .ready = p.ready,
            .connected = p.connected,
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
            .kind = e.kind,
            .owner = e.owner,
            .casts_used = e.casts_used,
            .last_action = anim,
            .combo = slot_bufs[i][0..e.combo_len],
        };
    }

    // Convert pending combo slots for JSON.
    var pending_slots_buf: [c.MAX_COMBO_LEN]JsonComboSlot = undefined;
    for (game.pending_combo.slots[0..game.pending_combo.len], 0..) |s, i| {
        pending_slots_buf[i] = .{ .slot = s };
    }

    // Convert zone snapshots for JSON (named per agent color).
    var zones_buf: [proto.MAX_ZONES_WIRE]JsonZone = undefined;
    for (game.snapshot.zones[0..game.snapshot.zone_count], 0..) |z, i| {
        zones_buf[i] = .{
            .fire = z.modified[0],
            .earth = z.modified[1],
            .wind = z.modified[2],
            .water = z.modified[3],
            .neutral = z.neutral,
        };
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
            .encounter = game.encounter_label[0..game.encounter_label_len],
            .player_id = game.player_id,
            .pending_combo = pending_slots_buf[0..game.pending_combo.len],
            .round_timer = game.round_timer,
            .round_duration = game.round_duration,
            .cast_timer = game.snapshot.cast_timer,
            .casts_per_round = balance.CASTS_PER_ROUND,
            .tick = game.snapshot.tick,
            .round = game.round,
            .entities = entities_buf[0..game.snapshot.entity_count],
            .hunger = .{
                .current = game.snapshot.hunger.current,
                .max = game.snapshot.hunger.max,
                .healable = .{
                    .fire = game.snapshot.hunger_healable[0],
                    .earth = game.snapshot.hunger_healable[1],
                    .wind = game.snapshot.hunger_healable[2],
                    .water = game.snapshot.hunger_healable[3],
                },
            },
            .score = game.snapshot.score,
            .zone_index = game.snapshot.zone_index,
            .zones = zones_buf[0..game.snapshot.zone_count],
        } else null,
        .score = if (phase == .game_over) game.final_score else null,
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
    score: ?u32,
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
    kind: c.EntityKind,
    ready: bool,
    connected: bool,
};

/// Portion of hunger healable by medicine, per slime color.  Only
/// matching-color (symmetrical) medicine heals each bucket.
const JsonHealable = struct {
    fire: u16,
    earth: u16,
    wind: u16,
    water: u16,
};

/// Hunger bar: current fills toward max; `healable` = per-color portions
/// medicine can heal.
const JsonHunger = struct {
    current: u16,
    max: u16,
    healable: JsonHealable,
};

/// One zone's remaining slime, named per agent color + naturally-neutral.
const JsonZone = struct {
    fire: u16,
    earth: u16,
    wind: u16,
    water: u16,
    neutral: u16,
};

const JsonGame = struct {
    encounter: []const u8,
    player_id: u8,
    pending_combo: []const JsonComboSlot,
    round_timer: f32,
    round_duration: f32,
    /// Countdown of the current cast window (round_duration / casts_per_round).
    cast_timer: f32,
    casts_per_round: u8,
    tick: u32,
    round: u32,
    entities: []const JsonEntity,
    hunger: JsonHunger,
    score: u32,
    zone_index: u8,
    zones: []const JsonZone,
};

const JsonEntity = struct {
    id: u32,
    kind: c.EntityKind,
    owner: u8,
    /// Spells committed this round (0..casts_per_round).
    casts_used: u8,
    last_action: ?c.ActionAnimation,
    combo: []const JsonComboSlot,
};
