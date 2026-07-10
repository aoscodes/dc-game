const std = @import("std");
const components = @import("components.zig");
const encounter = @import("encounter.zig");
const balance = @import("balance.zig");

pub const MsgTag = enum(u8) {
    join_lobby = 0x01,
    ready_up = 0x03,
    // 0x04 was the legacy single-action choose_action; retired.
    reconnect = 0x05,
    // 0x06 was the legacy set_statblock; retired (statblocks removed).
    choose_combo = 0x07,
    cancel_combo = 0x08,

    lobby_update = 0x10,
    game_start = 0x11,
    game_state = 0x12,
    action_result = 0x13,
    round_reset = 0x14,
    game_over = 0x15,
    /// A player's pending combo was committed as a spell (cast window closed).
    /// Payload: player_id.  The owning client clears its pending combo.
    cast_committed = 0x16,
    /// A player's pending combo had zero possible output and was DISCARDED at
    /// window close without consuming a cast.  Payload: player_id.
    cast_fizzled = 0x17,
    /// A recipe fired during a cast window.  Payload: kind (player/team) +
    /// index into the corresponding balance recipe table.
    recipe_fired = 0x18,
};

pub const JoinLobby = struct {
    name: [16]u8,
    name_len: u8,
};

pub const ChooseCombo = struct {
    combo: components.ActionCombo,
};

fn encode_combo_slot(w: anytype, slot: components.ComboSlot) !void {
    switch (slot) {
        .action => |a| try w.writeByte(@intFromEnum(a)),
        .element => |e| try w.writeByte(0x80 | @intFromEnum(e)),
    }
}

fn decode_combo_slot(byte: u8) !components.ComboSlot {
    if (byte & 0x80 != 0) {
        const raw: u8 = byte & 0x7F;
        const el = std.meta.intToEnum(components.Element, raw) catch
            return DecodeError.InvalidElement;
        return .{ .element = el };
    } else {
        const ac = std.meta.intToEnum(components.ActionChoice, byte) catch
            return DecodeError.InvalidActionChoice;
        return .{ .action = ac };
    }
}

pub const Reconnect = struct {
    player_id: u8,
};

pub const CastCommitted = struct {
    player_id: u8,
};

pub fn decode_cast_committed(reader: anytype) !CastCommitted {
    return .{ .player_id = try reader.readByte() };
}

pub const CastFizzled = struct {
    player_id: u8,
};

pub fn decode_cast_fizzled(reader: anytype) !CastFizzled {
    return .{ .player_id = try reader.readByte() };
}

pub const RecipeKind = enum(u8) {
    player = 0,
    team = 1,
};

/// A recipe fired: `index` refers to the balance table for `kind`
/// (player_recipes / team_recipes, table order — same convention as the
/// match-stats hit arrays and the JS mirror tables).
pub const RecipeFired = struct {
    kind: RecipeKind,
    index: u8,
};

pub fn decode_recipe_fired(reader: anytype) !RecipeFired {
    const kind_byte = try reader.readByte();
    const kind = std.meta.intToEnum(RecipeKind, kind_byte) catch
        return DecodeError.InvalidRecipeKind;
    return .{ .kind = kind, .index = try reader.readByte() };
}

pub const MAX_PLAYERS: u8 = 6;

pub const PlayerInfo = struct {
    player_id: u8,
    name: [16]u8,
    name_len: u8,
    kind: components.EntityKind,
    ready: bool,
    connected: bool,
};

pub const LobbyUpdate = struct {
    join_code: [6]u8,
    player_count: u8,
    players: [MAX_PLAYERS]PlayerInfo,
    player_id: u8,
    round_duration: f32,
};

pub const GameStart = struct {
    encounter_label: [32]u8,
    encounter_label_len: u8,
    player_id: u8,
    round_duration: f32,
    /// Spells each player may commit per round (from the server's balance
    /// data; clients must not hardcode it).
    casts_per_round: u8,
};

pub const EntitySnapshot = struct {
    entity: u32,
    kind: components.EntityKind,
    owner: u8,
    /// Spells already committed by this player this round (0..CASTS_PER_ROUND).
    casts_used: u8,
    combo_len: u8,
    combo_slots: [components.MAX_COMBO_LEN]components.ComboSlot,

    pub const blank = EntitySnapshot{
        .entity = 0,
        .kind = .player,
        .owner = 0xFF,
        .casts_used = 0,
        .combo_len = 0,
        .combo_slots = [_]components.ComboSlot{.{ .action = .dispense }} ** components.MAX_COMBO_LEN,
    };
};

pub const MAX_ENTITIES_WIRE: u16 = 64;
pub const MAX_ZONES_WIRE: u8 = encounter.MAX_ZONES;

/// A filled bar on the wire (currently only the Total Hunger bar).
pub const BarSummary = struct {
    current: u16,
    max: u16,
};

/// Per-zone slime contents on the wire.  `neutralized` = modified units
/// transmuted by agents this round (per original color), consumed at round
/// end.  Consumed zones are all zeros.
pub const ZoneSnapshot = struct {
    modified: [components.Element.size]u16,
    neutralized: [components.Element.size]u16,
    neutral: u16,

    pub const blank = ZoneSnapshot{
        .modified = [_]u16{0} ** components.Element.size,
        .neutralized = [_]u16{0} ** components.Element.size,
        .neutral = 0,
    };
};

pub const GameState = struct {
    tick: u32,
    round_timer: f32,
    /// Countdown of the current cast window (round_duration / CASTS_PER_ROUND).
    /// Pending combos commit when it reaches 0.
    cast_timer: f32,
    entity_count: u8,
    entities: [MAX_ENTITIES_WIRE]EntitySnapshot,
    /// Hunger bar: current fills toward max; full = encounter over.
    hunger: BarSummary,
    /// Portion of current hunger healable by medicine, per slime color
    /// (Element ordinal).  Only matching-color medicine heals each bucket.
    hunger_healable: [components.Element.size]u16,
    /// Shared team score: neutral slime units consumed so far.
    score: u32,
    /// Index of the zone being eaten this round (== rounds resolved).
    zone_index: u8,
    zone_count: u8,
    /// All zones (current + upcoming visible to players; consumed = zeros).
    zones: [MAX_ZONES_WIRE]ZoneSnapshot,

    pub const blank = GameState{
        .tick = 0,
        .round_timer = 0,
        .cast_timer = 0,
        .entity_count = 0,
        .entities = [_]EntitySnapshot{EntitySnapshot.blank} ** MAX_ENTITIES_WIRE,
        .hunger = .{ .current = 0, .max = 0 },
        .hunger_healable = [_]u16{0} ** components.Element.size,
        .score = 0,
        .zone_index = 0,
        .zone_count = 0,
        .zones = [_]ZoneSnapshot{ZoneSnapshot.blank} ** MAX_ZONES_WIRE,
    };
};

pub const ActionResultTag = enum(u8) {
    /// Hunger added by zone consumption this round (value = hunger).
    damage = 0,
    /// Medicine healed the hunger bar (value = amount healed).
    heal = 1,
    // 0x02 was `shield` (units neutralized per round); retired — clients
    // read transmutation live from zone snapshots instead.
    death = 4,
    /// A player's spell committed (cast window closed).  actor_entity = the
    /// caster's entity; clients play the cast/attack animation on it.
    cast = 5,
};

pub const ActionResult = struct {
    tag: ActionResultTag,
    actor_entity: u32,
    target_entity: u32,
    value: u16,
};

pub const EndReason = enum(u8) {
    hunger_full = 0,
    field_cleared = 1,
};

/// One resolved round's tuning numbers (all per-color arrays use Element
/// ordinal order: fire, earth, wind, water).
pub const RoundStats = struct {
    /// Spells committed this round.
    casts: u8 = 0,
    /// Team agent output after recipe conversion.
    agents_dispensed: [components.Element.size]u16 = [_]u16{0} ** components.Element.size,
    medicine_dispensed: [components.Element.size]u16 = [_]u16{0} ** components.Element.size,
    /// Actually healed; overheal = dispensed - healed (derived client-side).
    medicine_healed: [components.Element.size]u16 = [_]u16{0} ** components.Element.size,
    neutralized: [components.Element.size]u16 = [_]u16{0} ** components.Element.size,
    /// Modified slime eaten un-neutralized.
    modified_escaped: [components.Element.size]u16 = [_]u16{0} ** components.Element.size,
    neutral_consumed: u16 = 0,
    hunger_normal: u16 = 0,
    hunger_extra: u16 = 0,
    /// Hunger bar level after this round resolved.
    hunger_after: u16 = 0,
};

/// Per-player tuning numbers.  Slot counts are RAW (pre-recipe) per-color
/// counts from committed combos, so attribution is unambiguous.
pub const PlayerStats = struct {
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: u8 = 0,
    casts: u16 = 0,
    dispense_slots: [components.Element.size]u16 = [_]u16{0} ** components.Element.size,
    medicine_slots: [components.Element.size]u16 = [_]u16{0} ** components.Element.size,
    /// Casts consumed by any recipe (player or team).
    recipe_casts: u16 = 0,
    /// Zero-output combos discarded at window close (did not cost a cast).
    fizzles: u16 = 0,
};

/// Full-match tuning report broadcast with game_over.  Rounds are bounded by
/// MAX_ZONES (one zone per round).  Match totals are derived client-side by
/// summing round_stats.
pub const MatchStats = struct {
    reason: EndReason = .field_cleared,
    /// Rounds resolved; round_stats[0..rounds] are valid.
    rounds: u8 = 0,
    zone_count: u8 = 0,
    hunger_final: u16 = 0,
    hunger_max: u16 = 0,
    round_stats: [encounter.MAX_ZONES]RoundStats = [_]RoundStats{.{}} ** encounter.MAX_ZONES,
    player_count: u8 = 0,
    players: [MAX_PLAYERS]PlayerStats = [_]PlayerStats{.{}} ** MAX_PLAYERS,
    /// Number of valid entries in the recipe hit arrays — the size of the
    /// loaded balance recipe tables (runtime data, bounded by the caps).
    player_recipe_count: u8 = 0,
    team_recipe_count: u8 = 0,
    /// Fire counts per balance recipe table entry (table order — the browser
    /// resolves labels by index from the same data/balance.json).
    player_recipe_hits: [balance.MAX_PLAYER_RECIPES]u16 =
        [_]u16{0} ** balance.MAX_PLAYER_RECIPES,
    team_recipe_hits: [balance.MAX_TEAM_RECIPES]u16 =
        [_]u16{0} ** balance.MAX_TEAM_RECIPES,
    casts_total: u16 = 0,
};

pub const GameOver = struct {
    /// Final shared score: neutral slime units consumed.
    score: u32,
    stats: MatchStats = .{},
};

pub fn encode(writer: anytype, comptime tag: MsgTag, payload: anytype) !void {
    try writer.writeByte(@intFromEnum(tag));
    const T = @TypeOf(payload);

    if (T == void) return;

    switch (tag) {
        .join_lobby => try encode_join_lobby(writer, payload),
        .ready_up => {},
        .reconnect => try writer.writeByte(payload.player_id),
        .choose_combo => {
            try writer.writeByte(payload.combo.len);
            for (payload.combo.slots[0..payload.combo.len]) |slot|
                try encode_combo_slot(writer, slot);
        },
        .cancel_combo => {},
        .round_reset => {},
        .cast_committed => try writer.writeByte(payload.player_id),
        .cast_fizzled => try writer.writeByte(payload.player_id),
        .recipe_fired => {
            try writer.writeByte(@intFromEnum(payload.kind));
            try writer.writeByte(payload.index);
        },

        .lobby_update => try encode_lobby_update(writer, payload),
        .game_start => try encode_game_start(writer, payload),
        .game_state => try encode_game_state(writer, payload),
        .action_result => try encode_action_result(writer, payload),
        .game_over => {
            try writer.writeInt(u32, payload.score, .little);
            try encode_match_stats(writer, payload.stats);
        },
    }
}

fn encode_join_lobby(w: anytype, p: JoinLobby) !void {
    try w.writeByte(p.name_len);
    try w.writeAll(p.name[0..p.name_len]);
}

fn encode_lobby_update(w: anytype, p: LobbyUpdate) !void {
    try w.writeAll(&p.join_code);
    try w.writeByte(p.player_count);
    try w.writeByte(p.player_id);
    try w.writeInt(u32, @bitCast(p.round_duration), .little);
    var i: u8 = 0;
    while (i < p.player_count) : (i += 1) {
        const pl = p.players[i];
        try w.writeByte(pl.player_id);
        try w.writeByte(pl.name_len);
        try w.writeAll(pl.name[0..pl.name_len]);
        try w.writeByte(@intFromEnum(pl.kind));
        try w.writeByte(if (pl.ready) 1 else 0);
        try w.writeByte(if (pl.connected) 1 else 0);
    }
}

fn encode_game_start(w: anytype, p: GameStart) !void {
    try w.writeByte(p.encounter_label_len);
    try w.writeAll(p.encounter_label[0..p.encounter_label_len]);
    try w.writeByte(p.player_id);
    try w.writeInt(u32, @bitCast(p.round_duration), .little);
    try w.writeByte(p.casts_per_round);
}

fn encode_bar_summary(w: anytype, s: BarSummary) !void {
    try w.writeInt(u16, s.current, .little);
    try w.writeInt(u16, s.max, .little);
}

fn encode_zone_snapshot(w: anytype, z: ZoneSnapshot) !void {
    for (z.modified) |m| try w.writeInt(u16, m, .little);
    for (z.neutralized) |n| try w.writeInt(u16, n, .little);
    try w.writeInt(u16, z.neutral, .little);
}

fn encode_game_state(w: anytype, p: GameState) !void {
    try w.writeInt(u32, p.tick, .little);
    try w.writeInt(u32, @bitCast(p.round_timer), .little);
    try w.writeInt(u32, @bitCast(p.cast_timer), .little);
    try w.writeByte(p.entity_count);
    var i: u8 = 0;
    while (i < p.entity_count) : (i += 1) {
        const e = p.entities[i];
        try w.writeInt(u32, e.entity, .little);
        try w.writeByte(@intFromEnum(e.kind));
        try w.writeByte(e.owner);
        try w.writeByte(e.casts_used);
        try w.writeByte(e.combo_len);
        var j: u8 = 0;
        while (j < e.combo_len) : (j += 1)
            try encode_combo_slot(w, e.combo_slots[j]);
    }
    try encode_bar_summary(w, p.hunger);
    for (p.hunger_healable) |h| try w.writeInt(u16, h, .little);
    try w.writeInt(u32, p.score, .little);
    try w.writeByte(p.zone_index);
    try w.writeByte(p.zone_count);
    var z: u8 = 0;
    while (z < p.zone_count) : (z += 1)
        try encode_zone_snapshot(w, p.zones[z]);
}

fn encode_u16_colors(w: anytype, values: [components.Element.size]u16) !void {
    for (values) |v| try w.writeInt(u16, v, .little);
}

fn decode_u16_colors(r: anytype) ![components.Element.size]u16 {
    var values: [components.Element.size]u16 = undefined;
    for (&values) |*v| v.* = try r.readInt(u16, .little);
    return values;
}

fn encode_round_stats(w: anytype, rs: RoundStats) !void {
    try w.writeByte(rs.casts);
    try encode_u16_colors(w, rs.agents_dispensed);
    try encode_u16_colors(w, rs.medicine_dispensed);
    try encode_u16_colors(w, rs.medicine_healed);
    try encode_u16_colors(w, rs.neutralized);
    try encode_u16_colors(w, rs.modified_escaped);
    try w.writeInt(u16, rs.neutral_consumed, .little);
    try w.writeInt(u16, rs.hunger_normal, .little);
    try w.writeInt(u16, rs.hunger_extra, .little);
    try w.writeInt(u16, rs.hunger_after, .little);
}

fn decode_round_stats(r: anytype) !RoundStats {
    return .{
        .casts = try r.readByte(),
        .agents_dispensed = try decode_u16_colors(r),
        .medicine_dispensed = try decode_u16_colors(r),
        .medicine_healed = try decode_u16_colors(r),
        .neutralized = try decode_u16_colors(r),
        .modified_escaped = try decode_u16_colors(r),
        .neutral_consumed = try r.readInt(u16, .little),
        .hunger_normal = try r.readInt(u16, .little),
        .hunger_extra = try r.readInt(u16, .little),
        .hunger_after = try r.readInt(u16, .little),
    };
}

fn encode_player_stats(w: anytype, ps: PlayerStats) !void {
    try w.writeByte(ps.name_len);
    try w.writeAll(ps.name[0..ps.name_len]);
    try w.writeInt(u16, ps.casts, .little);
    try encode_u16_colors(w, ps.dispense_slots);
    try encode_u16_colors(w, ps.medicine_slots);
    try w.writeInt(u16, ps.recipe_casts, .little);
    try w.writeInt(u16, ps.fizzles, .little);
}

fn decode_player_stats(r: anytype) !PlayerStats {
    var ps = PlayerStats{};
    ps.name_len = try r.readByte();
    if (ps.name_len > 16) return DecodeError.NameTooLong;
    _ = try r.readAll(ps.name[0..ps.name_len]);
    ps.casts = try r.readInt(u16, .little);
    ps.dispense_slots = try decode_u16_colors(r);
    ps.medicine_slots = try decode_u16_colors(r);
    ps.recipe_casts = try r.readInt(u16, .little);
    ps.fizzles = try r.readInt(u16, .little);
    return ps;
}

fn encode_match_stats(w: anytype, ms: MatchStats) !void {
    try w.writeByte(@intFromEnum(ms.reason));
    try w.writeByte(ms.rounds);
    try w.writeByte(ms.zone_count);
    try w.writeInt(u16, ms.hunger_final, .little);
    try w.writeInt(u16, ms.hunger_max, .little);
    var i: u8 = 0;
    while (i < ms.rounds) : (i += 1)
        try encode_round_stats(w, ms.round_stats[i]);
    try w.writeByte(ms.player_count);
    i = 0;
    while (i < ms.player_count) : (i += 1)
        try encode_player_stats(w, ms.players[i]);
    // Recipe hit arrays are length-prefixed with the loaded table sizes.
    try w.writeByte(ms.player_recipe_count);
    for (ms.player_recipe_hits[0..ms.player_recipe_count]) |h| try w.writeInt(u16, h, .little);
    try w.writeByte(ms.team_recipe_count);
    for (ms.team_recipe_hits[0..ms.team_recipe_count]) |h| try w.writeInt(u16, h, .little);
    try w.writeInt(u16, ms.casts_total, .little);
}

fn decode_match_stats(r: anytype) !MatchStats {
    var ms = MatchStats{};
    const reason_byte = try r.readByte();
    ms.reason = std.meta.intToEnum(EndReason, reason_byte) catch
        return DecodeError.InvalidEndReason;
    ms.rounds = try r.readByte();
    if (ms.rounds > encounter.MAX_ZONES) return DecodeError.TooManyZones;
    ms.zone_count = try r.readByte();
    ms.hunger_final = try r.readInt(u16, .little);
    ms.hunger_max = try r.readInt(u16, .little);
    var i: u8 = 0;
    while (i < ms.rounds) : (i += 1)
        ms.round_stats[i] = try decode_round_stats(r);
    ms.player_count = try r.readByte();
    if (ms.player_count > MAX_PLAYERS) return DecodeError.TooManyEntities;
    i = 0;
    while (i < ms.player_count) : (i += 1)
        ms.players[i] = try decode_player_stats(r);
    ms.player_recipe_count = try r.readByte();
    if (ms.player_recipe_count > balance.MAX_PLAYER_RECIPES) return DecodeError.TooManyRecipes;
    for (ms.player_recipe_hits[0..ms.player_recipe_count]) |*h| h.* = try r.readInt(u16, .little);
    ms.team_recipe_count = try r.readByte();
    if (ms.team_recipe_count > balance.MAX_TEAM_RECIPES) return DecodeError.TooManyRecipes;
    for (ms.team_recipe_hits[0..ms.team_recipe_count]) |*h| h.* = try r.readInt(u16, .little);
    ms.casts_total = try r.readInt(u16, .little);
    return ms;
}

fn encode_action_result(w: anytype, p: ActionResult) !void {
    try w.writeByte(@intFromEnum(p.tag));
    try w.writeInt(u32, p.actor_entity, .little);
    try w.writeInt(u32, p.target_entity, .little);
    try w.writeInt(u16, p.value, .little);
}

pub const DecodeError = error{
    UnknownTag,
    InvalidKind,
    InvalidActionChoice,
    InvalidElement,
    InvalidActionResultTag,
    NameTooLong,
    TooManyEntities,
    TooManyZones,
    InvalidComboLen,
    InvalidEndReason,
    TooManyRecipes,
    InvalidRecipeKind,
};

pub fn read_tag(reader: anytype) !MsgTag {
    const byte = try reader.readByte();
    return std.meta.intToEnum(MsgTag, byte) catch return DecodeError.UnknownTag;
}

pub fn decode_join_lobby(reader: anytype) !JoinLobby {
    const len = try reader.readByte();
    if (len == 0 or len > 16) return DecodeError.NameTooLong;
    var p = JoinLobby{ .name = [_]u8{0} ** 16, .name_len = len };
    _ = try reader.readAll(p.name[0..len]);
    return p;
}

pub fn decode_choose_combo(reader: anytype) !ChooseCombo {
    const len = try reader.readByte();
    if (len == 0 or len > components.MAX_COMBO_LEN) return DecodeError.InvalidComboLen;
    var combo = components.ActionCombo{
        .slots = [_]components.ComboSlot{.{ .action = .dispense }} ** components.MAX_COMBO_LEN,
        .len = len,
    };
    var i: u8 = 0;
    while (i < len) : (i += 1) {
        const byte = try reader.readByte();
        combo.slots[i] = try decode_combo_slot(byte);
    }
    return .{ .combo = combo };
}

pub fn decode_reconnect(reader: anytype) !Reconnect {
    return .{ .player_id = try reader.readByte() };
}

pub fn decode_lobby_update(reader: anytype) !LobbyUpdate {
    var p: LobbyUpdate = undefined;
    _ = try reader.readAll(&p.join_code);
    p.player_count = try reader.readByte();
    p.player_id = try reader.readByte();
    if (p.player_count > MAX_PLAYERS) return DecodeError.TooManyEntities;
    p.round_duration = @bitCast(try reader.readInt(u32, .little));
    var i: u8 = 0;
    while (i < p.player_count) : (i += 1) {
        p.players[i].player_id = try reader.readByte();
        const nlen = try reader.readByte();
        if (nlen > 16) return DecodeError.NameTooLong;
        p.players[i].name = [_]u8{0} ** 16;
        p.players[i].name_len = nlen;
        _ = try reader.readAll(p.players[i].name[0..nlen]);
        const kind_byte = try reader.readByte();
        p.players[i].kind = std.meta.intToEnum(components.EntityKind, kind_byte) catch
            return DecodeError.InvalidKind;
        p.players[i].ready = (try reader.readByte()) != 0;
        p.players[i].connected = (try reader.readByte()) != 0;
    }
    return p;
}

pub fn decode_game_start(reader: anytype) !GameStart {
    var p: GameStart = undefined;
    const llen = try reader.readByte();
    p.encounter_label = [_]u8{0} ** 32;
    p.encounter_label_len = llen;
    _ = try reader.readAll(p.encounter_label[0..llen]);
    p.player_id = try reader.readByte();
    p.round_duration = @bitCast(try reader.readInt(u32, .little));
    p.casts_per_round = try reader.readByte();
    return p;
}

fn decode_bar_summary(reader: anytype) !BarSummary {
    return .{
        .current = try reader.readInt(u16, .little),
        .max = try reader.readInt(u16, .little),
    };
}

fn decode_zone_snapshot(reader: anytype) !ZoneSnapshot {
    var z = ZoneSnapshot.blank;
    for (&z.modified) |*m| m.* = try reader.readInt(u16, .little);
    for (&z.neutralized) |*n| n.* = try reader.readInt(u16, .little);
    z.neutral = try reader.readInt(u16, .little);
    return z;
}

pub fn decode_game_state(reader: anytype) !GameState {
    var p: GameState = undefined;
    p.tick = try reader.readInt(u32, .little);
    p.round_timer = @bitCast(try reader.readInt(u32, .little));
    p.cast_timer = @bitCast(try reader.readInt(u32, .little));
    p.entity_count = try reader.readByte();
    if (p.entity_count > MAX_ENTITIES_WIRE) return DecodeError.TooManyEntities;
    var i: u8 = 0;
    while (i < p.entity_count) : (i += 1) {
        var e: EntitySnapshot = undefined;
        e.entity = try reader.readInt(u32, .little);
        const kind_byte = try reader.readByte();
        e.kind = std.meta.intToEnum(components.EntityKind, kind_byte) catch
            return DecodeError.InvalidKind;
        e.owner = try reader.readByte();
        e.casts_used = try reader.readByte();
        e.combo_len = try reader.readByte();
        if (e.combo_len > components.MAX_COMBO_LEN) return DecodeError.InvalidComboLen;
        e.combo_slots = [_]components.ComboSlot{.{ .action = .dispense }} ** components.MAX_COMBO_LEN;
        var j: u8 = 0;
        while (j < e.combo_len) : (j += 1) {
            const ab = try reader.readByte();
            e.combo_slots[j] = try decode_combo_slot(ab);
        }
        p.entities[i] = e;
    }
    p.hunger = try decode_bar_summary(reader);
    for (&p.hunger_healable) |*h| h.* = try reader.readInt(u16, .little);
    p.score = try reader.readInt(u32, .little);
    p.zone_index = try reader.readByte();
    p.zone_count = try reader.readByte();
    if (p.zone_count > MAX_ZONES_WIRE) return DecodeError.TooManyZones;
    p.zones = [_]ZoneSnapshot{ZoneSnapshot.blank} ** MAX_ZONES_WIRE;
    var z: u8 = 0;
    while (z < p.zone_count) : (z += 1)
        p.zones[z] = try decode_zone_snapshot(reader);
    return p;
}

pub fn decode_action_result(reader: anytype) !ActionResult {
    const tag_byte = try reader.readByte();
    const tag = std.meta.intToEnum(ActionResultTag, tag_byte) catch
        return DecodeError.InvalidActionResultTag;
    return .{
        .tag = tag,
        .actor_entity = try reader.readInt(u32, .little),
        .target_entity = try reader.readInt(u32, .little),
        .value = try reader.readInt(u16, .little),
    };
}

pub fn decode_game_over(reader: anytype) !GameOver {
    return .{
        .score = try reader.readInt(u32, .little),
        .stats = try decode_match_stats(reader),
    };
}

test "read_tag: retired choose_action byte (0x04) is UnknownTag" {
    var buf: [1]u8 = .{0x04};
    var fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(DecodeError.UnknownTag, read_tag(fbs.reader()));
}

test "round-trip: game_over carries score and match stats" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var go = GameOver{ .score = 12345 };
    go.stats.reason = .hunger_full;
    go.stats.rounds = 2;
    go.stats.zone_count = 3;
    go.stats.hunger_final = 199;
    go.stats.hunger_max = 200;
    go.stats.round_stats[0] = .{
        .casts = 4,
        .agents_dispensed = .{ 30, 0, 5, 0 },
        .medicine_dispensed = .{ 2, 0, 0, 10 },
        .medicine_healed = .{ 2, 0, 0, 3 },
        .neutralized = .{ 10, 0, 5, 0 },
        .modified_escaped = .{ 0, 8, 0, 0 },
        .neutral_consumed = 15,
        .hunger_normal = 38,
        .hunger_extra = 16,
        .hunger_after = 49,
    };
    go.stats.round_stats[1] = .{ .casts = 1, .hunger_after = 99 };
    go.stats.player_count = 2;
    go.stats.players[0] = .{ .casts = 3, .dispense_slots = .{ 6, 0, 0, 0 }, .recipe_casts = 2, .fizzles = 1 };
    @memcpy(go.stats.players[0].name[0..5], "Alice");
    go.stats.players[0].name_len = 5;
    go.stats.players[1] = .{ .casts = 2, .medicine_slots = .{ 0, 0, 0, 4 } };
    go.stats.player_recipe_count = 6;
    go.stats.team_recipe_count = 2;
    go.stats.player_recipe_hits[0] = 1;
    go.stats.team_recipe_hits[0] = 2;
    go.stats.casts_total = 5;

    try encode(fbs.writer(), .game_over, go);
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.game_over, tag);
    const d = try decode_game_over(fbs.reader());

    try std.testing.expectEqual(@as(u32, 12345), d.score);
    try std.testing.expectEqual(EndReason.hunger_full, d.stats.reason);
    try std.testing.expectEqual(@as(u8, 2), d.stats.rounds);
    try std.testing.expectEqual(@as(u8, 3), d.stats.zone_count);
    try std.testing.expectEqual(@as(u16, 199), d.stats.hunger_final);
    try std.testing.expectEqual(@as(u8, 4), d.stats.round_stats[0].casts);
    try std.testing.expectEqual(@as(u16, 30), d.stats.round_stats[0].agents_dispensed[0]);
    try std.testing.expectEqual(@as(u16, 3), d.stats.round_stats[0].medicine_healed[3]);
    try std.testing.expectEqual(@as(u16, 8), d.stats.round_stats[0].modified_escaped[1]);
    try std.testing.expectEqual(@as(u16, 15), d.stats.round_stats[0].neutral_consumed);
    try std.testing.expectEqual(@as(u16, 99), d.stats.round_stats[1].hunger_after);
    try std.testing.expectEqual(@as(u8, 2), d.stats.player_count);
    try std.testing.expectEqualSlices(u8, "Alice", d.stats.players[0].name[0..d.stats.players[0].name_len]);
    try std.testing.expectEqual(@as(u16, 3), d.stats.players[0].casts);
    try std.testing.expectEqual(@as(u16, 6), d.stats.players[0].dispense_slots[0]);
    try std.testing.expectEqual(@as(u16, 2), d.stats.players[0].recipe_casts);
    try std.testing.expectEqual(@as(u16, 1), d.stats.players[0].fizzles);
    try std.testing.expectEqual(@as(u16, 4), d.stats.players[1].medicine_slots[3]);
    try std.testing.expectEqual(@as(u8, 6), d.stats.player_recipe_count);
    try std.testing.expectEqual(@as(u8, 2), d.stats.team_recipe_count);
    try std.testing.expectEqual(@as(u16, 1), d.stats.player_recipe_hits[0]);
    try std.testing.expectEqual(@as(u16, 2), d.stats.team_recipe_hits[0]);
    try std.testing.expectEqual(@as(u16, 5), d.stats.casts_total);
}

test "round-trip: join_lobby" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const name = "Alice";
    var p = JoinLobby{ .name = [_]u8{0} ** 16, .name_len = @intCast(name.len) };
    @memcpy(p.name[0..name.len], name);

    try encode(fbs.writer(), .join_lobby, p);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_join_lobby(fbs.reader());
    try std.testing.expectEqual(p.name_len, decoded.name_len);
    try std.testing.expectEqualSlices(u8, name, decoded.name[0..decoded.name_len]);
}

test "round-trip: game_state — hunger, score, zones, and combo survive" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState.blank;
    gs.tick = 42;
    gs.round_timer = 1.75;
    gs.cast_timer = 0.6;
    gs.entity_count = 1;
    gs.hunger = .{ .current = 80, .max = 200 };
    gs.hunger_healable = .{ 30, 0, 6, 0 };
    gs.score = 55;
    gs.zone_index = 1;
    gs.zone_count = 3;
    gs.zones[0] = ZoneSnapshot.blank; // consumed
    gs.zones[1] = .{ .modified = .{ 10, 0, 5, 0 }, .neutralized = .{ 4, 0, 0, 0 }, .neutral = 15 };
    gs.zones[2] = .{ .modified = .{ 0, 20, 0, 8 }, .neutralized = [_]u16{0} ** 4, .neutral = 5 };
    gs.entities[0] = EntitySnapshot{
        .entity = 7,
        .kind = .player,
        .owner = 0,
        .casts_used = 2,
        .combo_len = 2,
        .combo_slots = [_]components.ComboSlot{
            .{ .element = .fire },
            .{ .action = .dispense },
            .{ .action = .dispense },
            .{ .action = .dispense },
            .{ .action = .dispense },
        },
    };

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.game_state, tag);
    const decoded = try decode_game_state(fbs.reader());

    try std.testing.expectEqual(@as(u32, 42), decoded.tick);
    try std.testing.expectApproxEqAbs(@as(f32, 1.75), decoded.round_timer, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), decoded.cast_timer, 0.001);
    try std.testing.expectEqual(@as(u8, 1), decoded.entity_count);
    try std.testing.expectEqual(@as(u8, 2), decoded.entities[0].casts_used);
    try std.testing.expectEqual(@as(u16, 80), decoded.hunger.current);
    try std.testing.expectEqual(@as(u16, 200), decoded.hunger.max);
    try std.testing.expectEqual(@as(u16, 30), decoded.hunger_healable[0]);
    try std.testing.expectEqual(@as(u16, 6), decoded.hunger_healable[2]);
    try std.testing.expectEqual(@as(u32, 55), decoded.score);
    try std.testing.expectEqual(@as(u8, 1), decoded.zone_index);
    try std.testing.expectEqual(@as(u8, 3), decoded.zone_count);
    try std.testing.expectEqual(@as(u16, 10), decoded.zones[1].modified[0]);
    try std.testing.expectEqual(@as(u16, 4), decoded.zones[1].neutralized[0]);
    try std.testing.expectEqual(@as(u16, 15), decoded.zones[1].neutral);
    try std.testing.expectEqual(@as(u16, 8), decoded.zones[2].modified[3]);
    try std.testing.expectEqual(@as(u8, 2), decoded.entities[0].combo_len);
    try std.testing.expectEqual(components.Element.fire, decoded.entities[0].combo_slots[0].element);
    try std.testing.expectEqual(components.ActionChoice.dispense, decoded.entities[0].combo_slots[1].action);
}

test "round-trip: lobby_update — round_duration survives" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var lu = LobbyUpdate{
        .join_code = "ABCDEF".*,
        .player_count = 1,
        .players = [_]PlayerInfo{std.mem.zeroes(PlayerInfo)} ** MAX_PLAYERS,
        .player_id = 0,
        .round_duration = 2.5,
    };
    lu.players[0] = PlayerInfo{
        .player_id = 0,
        .name = [_]u8{0} ** 16,
        .name_len = 3,
        .kind = .player,
        .ready = false,
        .connected = true,
    };
    @memcpy(lu.players[0].name[0..3], "Bob");

    try encode(fbs.writer(), .lobby_update, lu);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_lobby_update(fbs.reader());

    try std.testing.expectApproxEqAbs(@as(f32, 2.5), decoded.round_duration, 0.001);
    try std.testing.expectEqual(@as(u8, 0), decoded.player_id);
    try std.testing.expectEqual(@as(u8, 1), decoded.player_count);
}

test "round-trip: game_start — round_duration survives" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const label = "slime_feast_01";
    var gs = GameStart{
        .encounter_label = [_]u8{0} ** 32,
        .encounter_label_len = @intCast(label.len),
        .player_id = 3,
        .round_duration = 4.0,
        .casts_per_round = 3,
    };
    @memcpy(gs.encounter_label[0..label.len], label);

    try encode(fbs.writer(), .game_start, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_start(fbs.reader());

    try std.testing.expectApproxEqAbs(@as(f32, 4.0), decoded.round_duration, 0.001);
    try std.testing.expectEqual(@as(u8, 3), decoded.player_id);
    try std.testing.expectEqual(@as(u8, 3), decoded.casts_per_round);
    try std.testing.expectEqualSlices(u8, label, decoded.encounter_label[0..decoded.encounter_label_len]);
}

test "round-trip: choose_combo [dispense, medicine]" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const combo = components.make_combo(&.{
        .{ .action = .dispense },
        .{ .action = .medicine },
    });

    try encode(fbs.writer(), .choose_combo, ChooseCombo{ .combo = combo });
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.choose_combo, tag);
    const decoded = try decode_choose_combo(fbs.reader());
    try std.testing.expectEqual(@as(u8, 2), decoded.combo.len);
    try std.testing.expectEqual(components.ActionChoice.dispense, decoded.combo.slots[0].action);
    try std.testing.expectEqual(components.ActionChoice.medicine, decoded.combo.slots[1].action);
}

test "round-trip: choose_combo max-length all dispense" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const combo = components.ActionCombo{
        .slots = [_]components.ComboSlot{.{ .action = .dispense }} ** components.MAX_COMBO_LEN,
        .len = components.MAX_COMBO_LEN,
    };
    try encode(fbs.writer(), .choose_combo, ChooseCombo{ .combo = combo });
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_choose_combo(fbs.reader());
    try std.testing.expectEqual(components.MAX_COMBO_LEN, decoded.combo.len);
    for (decoded.combo.slots[0..decoded.combo.len]) |s|
        try std.testing.expectEqual(components.ActionChoice.dispense, s.action);
}

test "round-trip: choose_combo with element slots [fire, dispense, water, dispense]" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const combo = components.make_combo(&.{
        .{ .element = .fire },
        .{ .action = .dispense },
        .{ .element = .water },
        .{ .action = .dispense },
    });
    try encode(fbs.writer(), .choose_combo, ChooseCombo{ .combo = combo });
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_choose_combo(fbs.reader());
    try std.testing.expectEqual(@as(u8, 4), decoded.combo.len);
    try std.testing.expectEqual(components.Element.fire, decoded.combo.slots[0].element);
    try std.testing.expectEqual(components.ActionChoice.dispense, decoded.combo.slots[1].action);
    try std.testing.expectEqual(components.Element.water, decoded.combo.slots[2].element);
    try std.testing.expectEqual(components.ActionChoice.dispense, decoded.combo.slots[3].action);
}

test "decode_choose_combo: len=0 returns InvalidComboLen" {
    var buf: [2]u8 = .{ 0x00, 0x00 };
    var fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(DecodeError.InvalidComboLen, decode_choose_combo(fbs.reader()));
}

test "decode_choose_combo: len over max returns InvalidComboLen" {
    var buf: [2]u8 = .{ components.MAX_COMBO_LEN + 1, 0x00 };
    var fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(DecodeError.InvalidComboLen, decode_choose_combo(fbs.reader()));
}

test "decode_choose_combo: legacy heal byte (0x02) is rejected" {
    // Old protocol had 3 actions; byte 0x02 is no longer a valid ActionChoice.
    var buf: [3]u8 = .{ 0x01, 0x02, 0x00 };
    var fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(DecodeError.InvalidActionChoice, decode_choose_combo(fbs.reader()));
}

test "round-trip: cancel_combo (zero payload)" {
    var buf: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .cancel_combo, {});
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.cancel_combo, tag);
}

test "round-trip: round_reset (zero payload)" {
    var buf: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .round_reset, {});
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.round_reset, tag);
}

test "round-trip: game_state with zero zones" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState.blank;
    gs.tick = 7;

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_state(fbs.reader());

    try std.testing.expectEqual(@as(u32, 7), decoded.tick);
    try std.testing.expectEqual(@as(u8, 0), decoded.zone_count);
}

test "round-trip: cast_committed carries player_id" {
    var buf: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .cast_committed, CastCommitted{ .player_id = 3 });
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.cast_committed, tag);
    const decoded = try decode_cast_committed(fbs.reader());
    try std.testing.expectEqual(@as(u8, 3), decoded.player_id);
}

test "round-trip: cast_fizzled carries player_id" {
    var buf: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .cast_fizzled, CastFizzled{ .player_id = 4 });
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.cast_fizzled, tag);
    const decoded = try decode_cast_fizzled(fbs.reader());
    try std.testing.expectEqual(@as(u8, 4), decoded.player_id);
}

test "round-trip: recipe_fired carries kind and table index" {
    var buf: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .recipe_fired, RecipeFired{ .kind = .team, .index = 1 });
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.recipe_fired, tag);
    const decoded = try decode_recipe_fired(fbs.reader());
    try std.testing.expectEqual(RecipeKind.team, decoded.kind);
    try std.testing.expectEqual(@as(u8, 1), decoded.index);
}

test "round-trip: action_result cast tag carries actor entity" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const ar = ActionResult{
        .tag = .cast,
        .actor_entity = 42,
        .target_entity = std.math.maxInt(u32),
        .value = 0,
    };
    try encode(fbs.writer(), .action_result, ar);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_action_result(fbs.reader());

    try std.testing.expectEqual(ActionResultTag.cast, decoded.tag);
    try std.testing.expectEqual(@as(u32, 42), decoded.actor_entity);
}

test "round-trip: action_result heal (medicine) tag" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const ar = ActionResult{
        .tag = .heal,
        .actor_entity = std.math.maxInt(u32),
        .target_entity = std.math.maxInt(u32),
        .value = 9,
    };
    try encode(fbs.writer(), .action_result, ar);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_action_result(fbs.reader());

    try std.testing.expectEqual(ActionResultTag.heal, decoded.tag);
    try std.testing.expectEqual(@as(u16, 9), decoded.value);
}
