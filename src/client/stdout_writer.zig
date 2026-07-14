const std = @import("std");
const proto = @import("shared").protocol;
const c = @import("shared").components;
const inp = @import("input.zig");

/// JSON serialisation for ComboSlot.
/// Emits {"action":"damage"} or {"element":"red"} so game.js can branch.
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
        game.fizzle_count = 0;
        game.recipe_count = 0;
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
    mode: c.GameMode = .classic,
};

pub const LastActionEntry = struct { entity: u32, anim: c.ActionAnimation };

pub const GameState = struct {
    snapshot: proto.GameState = proto.GameState.blank,
    player_id: u8 = 0xFF,
    pending_combo: inp.ComboBuffer = .{},
    round_timer: f32 = 0.0,
    round_duration: f32 = 0.0,
    /// Spells per round, as announced by the server in game_start.
    casts_per_round: u8 = 0,
    /// Play mode, as announced by the server in game_start.
    mode: c.GameMode = .classic,
    /// Realtime mode: cast window length in ms (0 in classic mode).
    cast_window_ms: u32 = 0,
    encounter_label: [32]u8 = [_]u8{0} ** 32,
    encounter_label_len: u8 = 0,
    /// Final score from game_over (null until the encounter ends).
    final_score: ?u32 = null,
    /// Full tuning report from game_over (null until the encounter ends).
    final_stats: ?proto.MatchStats = null,
    last_action_count: u8 = 0,
    last_actions: [proto.MAX_ENTITIES_WIRE]LastActionEntry = undefined,
    /// Incremented each time a round_reset message is received.
    /// JS detects a change in this value to know a round just resolved.
    round: u32 = 0,
    /// Player ids whose spells fizzled since the last render write
    /// (transient, drained per frame like last_actions).
    fizzles: [proto.MAX_PLAYERS]u8 = undefined,
    fizzle_count: u8 = 0,
    /// Recipes fired since the last render write (transient).
    recipes_fired: [16]proto.RecipeFired = undefined,
    recipe_count: u8 = 0,
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

    // Convert transient recipe-fired events for JSON.
    var recipes_buf: [16]JsonRecipeFired = undefined;
    for (game.recipes_fired[0..game.recipe_count], 0..) |rf, i| {
        recipes_buf[i] = .{ .kind = rf.kind, .index = rf.index };
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
            .red = z.modified[0],
            .green = z.modified[1],
            .yellow = z.modified[2],
            .blue = z.modified[3],
            .neutralized = colors(z.neutralized),
            .neutral = z.neutral,
        };
    }

    // Build the game-over tuning report (per-round + per-player + recipes).
    var rounds_buf: [proto.MAX_ZONES_WIRE]JsonRoundStats = undefined;
    var pstats_buf: [proto.MAX_PLAYERS]JsonPlayerStats = undefined;
    var json_stats: ?JsonMatchStats = null;
    if (phase == .game_over) {
        if (game.final_stats) |*ms| {
            for (ms.round_stats[0..ms.rounds], 0..) |rs, i| {
                rounds_buf[i] = .{
                    .casts = rs.casts,
                    .agents = colors(rs.agents_dispensed),
                    .medicine = colors(rs.medicine_dispensed),
                    .healed = colors(rs.medicine_healed),
                    .neutralized = colors(rs.neutralized),
                    .escaped = colors(rs.modified_escaped),
                    .neutral = rs.neutral_consumed,
                    .hunger_normal = rs.hunger_normal,
                    .hunger_extra = rs.hunger_extra,
                    .hunger_after = rs.hunger_after,
                };
            }
            for (ms.players[0..ms.player_count], 0..) |ps, i| {
                pstats_buf[i] = .{
                    .name = ps.name[0..ps.name_len],
                    .casts = ps.casts,
                    .dispense = colors(ps.dispense_slots),
                    .medicine = colors(ps.medicine_slots),
                    .recipe_casts = ps.recipe_casts,
                    .fizzles = ps.fizzles,
                };
            }
            json_stats = .{
                .reason = ms.reason,
                .zone_count = ms.zone_count,
                .hunger_final = ms.hunger_final,
                .hunger_max = ms.hunger_max,
                .rounds = rounds_buf[0..ms.rounds],
                .players = pstats_buf[0..ms.player_count],
                .player_recipe_hits = ms.player_recipe_hits[0..ms.player_recipe_count],
                .team_recipe_hits = ms.team_recipe_hits[0..ms.team_recipe_count],
                .casts_total = ms.casts_total,
            };
        }
    }

    const frame = JsonRenderFrame{
        .tag = "render",
        .phase = phase,
        .lobby = if (phase == .lobby) JsonLobby{
            .join_code = lobby.update.join_code[0..jc_end],
            .player_id = lobby.update.player_id,
            .ready = lobby.ready,
            .mode = lobby.mode,
            .round_duration = lobby.update.round_duration,
            .players = players_buf[0..lobby.update.player_count],
        } else null,
        .game = if (phase == .game) JsonGame{
            .encounter = game.encounter_label[0..game.encounter_label_len],
            .player_id = game.player_id,
            .mode = game.mode,
            .cast_window_ms = game.cast_window_ms,
            .pending_combo = pending_slots_buf[0..game.pending_combo.len],
            .round_timer = game.round_timer,
            .round_duration = game.round_duration,
            .cast_timer = game.snapshot.cast_timer,
            .casts_per_round = game.casts_per_round,
            .tick = game.snapshot.tick,
            .round = game.round,
            .entities = entities_buf[0..game.snapshot.entity_count],
            .hunger = .{
                .current = game.snapshot.hunger.current,
                .max = game.snapshot.hunger.max,
                .healable = .{
                    .red = game.snapshot.hunger_healable[0],
                    .green = game.snapshot.hunger_healable[1],
                    .yellow = game.snapshot.hunger_healable[2],
                    .blue = game.snapshot.hunger_healable[3],
                },
            },
            .score = game.snapshot.score,
            .zone_index = game.snapshot.zone_index,
            .zones = zones_buf[0..game.snapshot.zone_count],
            .fizzles = game.fizzles[0..game.fizzle_count],
            .recipes_fired = recipes_buf[0..game.recipe_count],
        } else null,
        .score = if (phase == .game_over) game.final_score else null,
        .stats = json_stats,
    };

    try std.json.Stringify.value(frame, .{ .emit_null_optional_fields = false }, w);
}

/// Convert a per-color u16 array into named JSON fields.
fn colors(values: [c.Element.size]u16) JsonColors {
    return .{
        .red = values[0],
        .green = values[1],
        .yellow = values[2],
        .blue = values[3],
    };
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
    stats: ?JsonMatchStats,
};

/// Per-color values with named fields (Element ordinal order).
const JsonColors = struct {
    red: u16,
    green: u16,
    yellow: u16,
    blue: u16,
};

const JsonRoundStats = struct {
    casts: u8,
    agents: JsonColors,
    medicine: JsonColors,
    healed: JsonColors,
    neutralized: JsonColors,
    escaped: JsonColors,
    neutral: u16,
    hunger_normal: u16,
    hunger_extra: u16,
    hunger_after: u16,
};

const JsonPlayerStats = struct {
    name: []const u8,
    casts: u16,
    dispense: JsonColors,
    medicine: JsonColors,
    recipe_casts: u16,
    fizzles: u16,
};

/// End-of-game tuning report.  Recipe hit arrays are in balance table order;
/// web/game.js resolves labels by index from the fetched data/balance.json.
const JsonMatchStats = struct {
    reason: proto.EndReason,
    zone_count: u8,
    hunger_final: u16,
    hunger_max: u16,
    rounds: []const JsonRoundStats,
    players: []const JsonPlayerStats,
    player_recipe_hits: []const u16,
    team_recipe_hits: []const u16,
    casts_total: u16,
};

const JsonLobby = struct {
    join_code: []const u8,
    player_id: u8,
    ready: bool,
    /// Play mode the host selected ("classic" | "realtime").
    mode: c.GameMode,
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
    red: u16,
    green: u16,
    yellow: u16,
    blue: u16,
};

/// Hunger bar: current fills toward max; `healable` = per-color portions
/// medicine can heal.
const JsonHunger = struct {
    current: u16,
    max: u16,
    healable: JsonHealable,
};

/// One zone's remaining slime: modified units named per agent color, plus
/// transmuted (`neutralized`, per original color) and naturally-neutral.
const JsonZone = struct {
    red: u16,
    green: u16,
    yellow: u16,
    blue: u16,
    neutralized: JsonColors,
    neutral: u16,
};

const JsonGame = struct {
    encounter: []const u8,
    player_id: u8,
    /// Play mode ("classic" | "realtime").
    mode: c.GameMode,
    /// Realtime mode: cast window length in ms (0 in classic mode).
    cast_window_ms: u32,
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
    /// Player ids whose spells fizzled since the previous frame (transient).
    fizzles: []const u8,
    /// Recipes fired since the previous frame (transient).  `index` refers
    /// to the balance recipe table for `kind` (JS resolves labels from the
    /// fetched data/balance.json, same order).
    recipes_fired: []const JsonRecipeFired,
};

const JsonRecipeFired = struct {
    kind: proto.RecipeKind,
    index: u8,
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
