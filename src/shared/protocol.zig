const std = @import("std");
const components = @import("components.zig");
const balance = @import("balance.zig");

pub const MsgTag = enum(u8) {
    join_lobby = 0x01,
    ready_up = 0x03,
    reconnect = 0x05,
    choose_combo = 0x07,
    cancel_combo = 0x08,
    submit_spell = 0x09,
    move_cursor = 0x0a,
    lobby_update = 0x10,
    game_start = 0x11,
    game_state = 0x12,
    action_result = 0x13,
    game_over = 0x15,
    cast_committed = 0x16,
    cast_fizzled = 0x17,
    recipe_fired = 0x18,
    cast_grouped = 0x19,
    cast_replaced = 0x1a,
    cast_fired = 0x1b,
    shape_cast = 0x1c,
};

pub const JoinLobby = struct {
    name: [16]u8,
    name_len: u8,
};

pub const ChooseCombo = struct {
    combo: components.ActionCombo,
};

pub const SubmitSpell = struct {
    combo: components.ActionCombo,
};

/// One d-pad step of the aiming cursor.  A DIRECTION, not a destination: the
/// server owns the cursor and clamps it at the field edge, so a client can
/// never aim off-grid no matter how many steps it sends.
pub const CursorDir = enum(u8) {
    up = 0,
    down = 1,
    left = 2,
    right = 3,

    /// Row/column delta of one step in this direction.
    pub fn delta(self: CursorDir) struct { d_row: i8, d_col: i8 } {
        return switch (self) {
            .up => .{ .d_row = -1, .d_col = 0 },
            .down => .{ .d_row = 1, .d_col = 0 },
            .left => .{ .d_row = 0, .d_col = -1 },
            .right => .{ .d_row = 0, .d_col = 1 },
        };
    }
};

pub const MoveCursor = struct {
    dir: CursorDir,
};

pub fn decode_move_cursor(reader: anytype) !MoveCursor {
    const byte = try reader.readByte();
    const dir = std.meta.intToEnum(CursorDir, byte) catch
        return DecodeError.InvalidCursorDir;
    return .{ .dir = dir };
}

fn encode_combo_slot(w: anytype, slot: components.ComboSlot) !void {
    switch (slot) {
        .action => |a| try w.writeByte(@intFromEnum(a)),
    }
}

fn decode_combo_slot(byte: u8) !components.ComboSlot {
    const ac = std.meta.intToEnum(components.ActionChoice, byte) catch
        return DecodeError.InvalidActionChoice;
    return .{ .action = ac };
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

/// Realtime: a newly accepted cast COMPLETED a team recipe with pending
/// casts — the instance's members now share one fire time (the joiner's
/// buffer expiry).  Cast-loop trace: cast_committed →
/// [cast_replaced | cast_grouped]* → cast_fired.
pub const CastGrouped = struct {
    /// Bit i set = player_id i's pending cast is in the group (MAX_PLAYERS <= 8).
    player_mask: u8,
    /// The group fires this many ms after this event (the joiner's buffer).
    fires_in_ms: u32,
};

pub fn decode_cast_grouped(reader: anytype) !CastGrouped {
    return .{
        .player_mask = try reader.readByte(),
        .fires_in_ms = try reader.readInt(u32, .little),
    };
}

/// Realtime: an unlocked resubmit REPLACED the player's pending cast — its
/// buffer restarts (no second cast_committed is sent).
pub const CastReplaced = struct {
    player_id: u8,
};

pub fn decode_cast_replaced(reader: anytype) !CastReplaced {
    return .{ .player_id = try reader.readByte() };
}

/// Realtime: pending casts whose buffers expired converted as one batch —
/// sent just before conversion (so it precedes the batch's recipe_fired /
/// action_result messages).  Grouped casts share an expiry and fire
/// together; a solo cast fires with spell_count = 1.
pub const CastFired = struct {
    /// Spells in the converting batch.
    spell_count: u8,
    /// Bit i set = player_id i contributed a spell (MAX_PLAYERS <= 8).
    player_mask: u8,
};

pub fn decode_cast_fired(reader: anytype) !CastFired {
    return .{
        .spell_count = try reader.readByte(),
        .player_mask = try reader.readByte(),
    };
}

pub const RecipeKind = enum(u8) {
    player = 0,
    team = 1,
};

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

/// Wire cap on a broadcast shape footprint.  Matches the authoring cap, so
/// any loadable recipe fits on the wire.
pub const MAX_SHAPE_CELLS_WIRE: u16 = balance.MAX_SHAPE_CELLS;

/// One stamped shape, broadcast so every client can draw the same splash on
/// the same cells and see what the cast actually accomplished.
///
/// The footprint travels as absolute grid cells rather than recipe index +
/// anchor: clipping at the field edge already happened server-side, so
/// sending the resolved cells means clients never re-derive placement and
/// cannot disagree with the server about what was hit.
///
/// `downgraded[t]` counts cells that stepped DOWN from tier `t`; `neutralized`
/// counts how many of those landed on defused.  `off_grid` (clipped by the
/// edge) and `inert` (hit empty/neutral/neutralized cells) are the two ways
/// coverage is wasted — the headline aiming signal, which is why they travel
/// alongside rather than being inferred.
pub const ShapeCast = struct {
    /// Player whose cursor anchored this shape (the last joiner, for a team
    /// recipe).
    caster: u8 = 0,
    /// Cells actually covered, as flat grid indices (already clipped).
    cell_count: u16 = 0,
    cells: [MAX_SHAPE_CELLS_WIRE]u16 = [_]u16{0} ** MAX_SHAPE_CELLS_WIRE,
    downgraded: [components.Tier.size]u16 = [_]u16{0} ** components.Tier.size,
    neutralized: u16 = 0,
    off_grid: u16 = 0,
    inert: u16 = 0,
};

pub fn decode_shape_cast(reader: anytype) !ShapeCast {
    var p = ShapeCast{};
    p.caster = try reader.readByte();
    p.cell_count = try reader.readInt(u16, .little);
    if (p.cell_count > MAX_SHAPE_CELLS_WIRE) return DecodeError.TooManyShapeCells;
    for (p.cells[0..p.cell_count]) |*cell| cell.* = try reader.readInt(u16, .little);
    p.downgraded = try decode_u16_tiers(reader);
    p.neutralized = try reader.readInt(u16, .little);
    p.off_grid = try reader.readInt(u16, .little);
    p.inert = try reader.readInt(u16, .little);
    return p;
}

pub const MAX_PLAYERS: u8 = 6;

// CastWaveFired.player_mask packs one bit per player.
comptime {
    std.debug.assert(MAX_PLAYERS <= 8);
}

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
};

pub const GameStart = struct {
    encounter_label: [32]u8,
    encounter_label_len: u8,
    player_id: u8,
    /// Per-cast buffer length (balance.cast_buffer_ms).
    cast_buffer_ms: u32 = 0,
    /// Slime grid dimensions, so the client can lay out the playfield the
    /// moment the game starts (before the first game_state arrives).
    grid_rows: u8 = 0,
    grid_cols: u8 = 0,
};

pub const EntitySnapshot = struct {
    entity: u32,
    kind: components.EntityKind,
    owner: u8,
    /// 1 = this player has a cast pending, 0 = none.  (Kept as a count for
    /// the existing client "casts used" indicator.)
    casts_used: u8,
    /// Remaining cast-lock cooldown in ms (saturated to u16); 0 = may submit.
    lock_ms: u16,
    /// Remaining buffer of this player's PENDING cast in ms (saturated to
    /// u16); 0 = no cast pending.
    cast_ms: u16,
    /// The combo this player is CURRENTLY TYPING (server `action_pool`).
    /// Cleared on submit, so it is empty while a cast buffers.
    combo_len: u8,
    combo_slots: [components.MAX_COMBO_LEN]components.ComboSlot,
    /// The combo this player has COMMITTED and that is now buffering (server
    /// `submitted_pool`), so clients can keep showing what is about to fire
    /// for the whole cast buffer and any team-grouping extension.
    ///
    /// Independent of `combo_*`, not a replacement for it: submitting clears
    /// `action_pool` but the player may immediately start typing a new combo,
    /// so both can be non-empty at once.
    submitted_len: u8,
    submitted_slots: [components.MAX_COMBO_LEN]components.ComboSlot,
    /// Where this player is aiming.  Server-owned and always in bounds, and
    /// snapshotted for EVERY player (not just the receiver) so teammates can
    /// see each other's cursors and shape previews.
    cursor_row: u8,
    cursor_col: u8,

    pub const blank = EntitySnapshot{
        .entity = 0,
        .kind = .player,
        .owner = 0xFF,
        .casts_used = 0,
        .lock_ms = 0,
        .cast_ms = 0,
        .combo_len = 0,
        .combo_slots = [_]components.ComboSlot{.{ .action = .dispense }} ** components.MAX_COMBO_LEN,
        .submitted_len = 0,
        .submitted_slots = [_]components.ComboSlot{.{ .action = .dispense }} ** components.MAX_COMBO_LEN,
        .cursor_row = 0,
        .cursor_col = 0,
    };
};

pub const MAX_ENTITIES_WIRE: u16 = 64;
/// Wire cap on the Lil Guy list — one per player, so MAX_PLAYERS suffices.
pub const MAX_LIL_GUYS_WIRE: u8 = MAX_PLAYERS;

pub const BarSummary = struct {
    current: u16,
    max: u16,
};

/// One Lil Guy on the wire: which grid cell it has reserved and how soon its
/// bite lands, so the client can animate the walk and time the chomp to the
/// authoritative bite.
pub const LilGuySnapshot = struct {
    entity: u32,
    /// Flat grid index being approached, or components.LilGuy.NO_TARGET.
    target: u16,
    /// Milliseconds until the bite lands (saturated to u16).
    bite_ms: u16,

    pub const blank = LilGuySnapshot{
        .entity = 0,
        .target = components.LilGuy.NO_TARGET,
        .bite_ms = 0,
    };
};

pub const GameState = struct {
    tick: u32,
    /// Remaining buffer of the SOONEST pending cast in seconds, or -1 when
    /// nothing is pending (the idle sentinel).
    cast_timer: f32,
    entity_count: u8,
    entities: [MAX_ENTITIES_WIRE]EntitySnapshot,
    hunger: BarSummary,
    hunger_healable: [components.Tier.size]u16,
    score: u32,
    /// The authoritative slime grid.  Cells are sent as one byte each (see
    /// components.SlimeCell), so every client renders identical slime.
    grid_rows: u8,
    grid_cols: u8,
    grid: [components.MAX_GRID_CELLS]components.SlimeCell,
    /// Slime still waiting off-grid — drives the "incoming" indicator.
    reservoir: u32,
    lil_guy_count: u8,
    lil_guys: [MAX_LIL_GUYS_WIRE]LilGuySnapshot,

    pub const blank = GameState{
        .tick = 0,
        .cast_timer = -1,
        .entity_count = 0,
        .entities = [_]EntitySnapshot{EntitySnapshot.blank} ** MAX_ENTITIES_WIRE,
        .hunger = .{ .current = 0, .max = 0 },
        .hunger_healable = [_]u16{0} ** components.Tier.size,
        .score = 0,
        .grid_rows = 0,
        .grid_cols = 0,
        .grid = [_]components.SlimeCell{.empty} ** components.MAX_GRID_CELLS,
        .reservoir = 0,
        .lil_guy_count = 0,
        .lil_guys = [_]LilGuySnapshot{LilGuySnapshot.blank} ** MAX_LIL_GUYS_WIRE,
    };

    /// Live cell count of the transmitted grid.
    pub fn grid_len(self: *const GameState) u16 {
        return @as(u16, self.grid_rows) * @as(u16, self.grid_cols);
    }
};

pub const ActionResultTag = enum(u8) {
    damage = 0,
    heal = 1,
    death = 4,
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

/// Match-wide consumption/dispense tallies for the tuning report.  There are
/// no rounds any more, so this accumulates over the whole encounter.
pub const FeastStats = struct {
    /// Cells covered by cast shapes, per tier they were standing at.
    cells_covered: [components.Tier.size]u16 = [_]u16{0} ** components.Tier.size,
    medicine_dispensed: [components.Tier.size]u16 = [_]u16{0} ** components.Tier.size,
    medicine_healed: [components.Tier.size]u16 = [_]u16{0} ** components.Tier.size,
    /// Cells taken all the way to defused, per tier they STARTED at.
    neutralized: [components.Tier.size]u16 = [_]u16{0} ** components.Tier.size,
    /// Hazard cells eaten while still a hazard, per tier.
    hazard_escaped: [components.Tier.size]u16 = [_]u16{0} ** components.Tier.size,
    neutral_consumed: u16 = 0,
    hunger_normal: u16 = 0,
    hunger_extra: u16 = 0,
};

pub const PlayerStats = struct {
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: u8 = 0,
    casts: u16 = 0,
    /// Cells this player's shapes covered, and cells taken to defused.
    cells_covered: u16 = 0,
    cells_neutralized: u16 = 0,
    recipe_casts: u16 = 0,
    fizzles: u16 = 0,
};

pub const MatchStats = struct {
    reason: EndReason = .field_cleared,
    /// Slime units the encounter started with (grid + reservoir).
    slime_total: u32 = 0,
    /// Slime units left unconsumed when the encounter ended (non-zero only
    /// when the hunger bar filled first).
    slime_left: u32 = 0,
    hunger_final: u16 = 0,
    hunger_max: u16 = 0,
    feast: FeastStats = .{},
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
        .submit_spell => {
            try writer.writeByte(payload.combo.len);
            for (payload.combo.slots[0..payload.combo.len]) |slot|
                try encode_combo_slot(writer, slot);
        },
        .cancel_combo => {},
        .cast_committed => try writer.writeByte(payload.player_id),
        .cast_fizzled => try writer.writeByte(payload.player_id),
        .move_cursor => try writer.writeByte(@intFromEnum(payload.dir)),
        .shape_cast => {
            const p: ShapeCast = payload;
            try writer.writeByte(p.caster);
            try writer.writeInt(u16, p.cell_count, .little);
            for (p.cells[0..p.cell_count]) |cell| try writer.writeInt(u16, cell, .little);
            try encode_u16_tiers(writer, p.downgraded);
            try writer.writeInt(u16, p.neutralized, .little);
            try writer.writeInt(u16, p.off_grid, .little);
            try writer.writeInt(u16, p.inert, .little);
        },
        .recipe_fired => {
            try writer.writeByte(@intFromEnum(payload.kind));
            try writer.writeByte(payload.index);
        },
        .cast_grouped => {
            try writer.writeByte(payload.player_mask);
            try writer.writeInt(u32, payload.fires_in_ms, .little);
        },
        .cast_replaced => try writer.writeByte(payload.player_id),
        .cast_fired => {
            try writer.writeByte(payload.spell_count);
            try writer.writeByte(payload.player_mask);
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
    try w.writeInt(u32, p.cast_buffer_ms, .little);
    try w.writeByte(p.grid_rows);
    try w.writeByte(p.grid_cols);
}

fn encode_bar_summary(w: anytype, s: BarSummary) !void {
    try w.writeInt(u16, s.current, .little);
    try w.writeInt(u16, s.max, .little);
}

/// One slime cell as a single byte: 0x00 empty, 0x01 neutral,
/// 0x02 neutralized, 0x10|t tiered (see components.SlimeCell).
fn encode_slime_cell(cell: components.SlimeCell) u8 {
    return switch (cell) {
        .empty => 0x00,
        .neutral => 0x01,
        .neutralized => 0x02,
        .tiered => |t| 0x10 | @intFromEnum(t),
    };
}

fn decode_slime_cell(byte: u8) !components.SlimeCell {
    return switch (byte & 0xF0) {
        0x00 => switch (byte) {
            0x00 => .empty,
            0x01 => .neutral,
            0x02 => .neutralized,
            else => DecodeError.InvalidSlimeCell,
        },
        0x10 => .{
            .tiered = std.meta.intToEnum(components.Tier, byte & 0x0F) catch
                return DecodeError.InvalidTier,
        },
        else => DecodeError.InvalidSlimeCell,
    };
}

fn encode_game_state(w: anytype, p: GameState) !void {
    try w.writeInt(u32, p.tick, .little);
    try w.writeInt(u32, @bitCast(p.cast_timer), .little);
    try w.writeByte(p.entity_count);
    var i: u8 = 0;
    while (i < p.entity_count) : (i += 1) {
        const e = p.entities[i];
        try w.writeInt(u32, e.entity, .little);
        try w.writeByte(@intFromEnum(e.kind));
        try w.writeByte(e.owner);
        try w.writeByte(e.casts_used);
        try w.writeInt(u16, e.lock_ms, .little);
        try w.writeInt(u16, e.cast_ms, .little);
        try w.writeByte(e.combo_len);
        var j: u8 = 0;
        while (j < e.combo_len) : (j += 1)
            try encode_combo_slot(w, e.combo_slots[j]);
        try w.writeByte(e.submitted_len);
        var k: u8 = 0;
        while (k < e.submitted_len) : (k += 1)
            try encode_combo_slot(w, e.submitted_slots[k]);
        try w.writeByte(e.cursor_row);
        try w.writeByte(e.cursor_col);
    }
    try encode_bar_summary(w, p.hunger);
    for (p.hunger_healable) |h| try w.writeInt(u16, h, .little);
    try w.writeInt(u32, p.score, .little);
    try w.writeByte(p.grid_rows);
    try w.writeByte(p.grid_cols);
    for (p.grid[0..p.grid_len()]) |cell| try w.writeByte(encode_slime_cell(cell));
    try w.writeInt(u32, p.reservoir, .little);
    try w.writeByte(p.lil_guy_count);
    var g: u8 = 0;
    while (g < p.lil_guy_count) : (g += 1) {
        const lg = p.lil_guys[g];
        try w.writeInt(u32, lg.entity, .little);
        try w.writeInt(u16, lg.target, .little);
        try w.writeInt(u16, lg.bite_ms, .little);
    }
}

fn encode_u16_tiers(w: anytype, values: [components.Tier.size]u16) !void {
    for (values) |v| try w.writeInt(u16, v, .little);
}

fn decode_u16_tiers(r: anytype) ![components.Tier.size]u16 {
    var values: [components.Tier.size]u16 = undefined;
    for (&values) |*v| v.* = try r.readInt(u16, .little);
    return values;
}

fn encode_feast_stats(w: anytype, rs: FeastStats) !void {
    try encode_u16_tiers(w, rs.cells_covered);
    try encode_u16_tiers(w, rs.medicine_dispensed);
    try encode_u16_tiers(w, rs.medicine_healed);
    try encode_u16_tiers(w, rs.neutralized);
    try encode_u16_tiers(w, rs.hazard_escaped);
    try w.writeInt(u16, rs.neutral_consumed, .little);
    try w.writeInt(u16, rs.hunger_normal, .little);
    try w.writeInt(u16, rs.hunger_extra, .little);
}

fn decode_feast_stats(r: anytype) !FeastStats {
    return .{
        .cells_covered = try decode_u16_tiers(r),
        .medicine_dispensed = try decode_u16_tiers(r),
        .medicine_healed = try decode_u16_tiers(r),
        .neutralized = try decode_u16_tiers(r),
        .hazard_escaped = try decode_u16_tiers(r),
        .neutral_consumed = try r.readInt(u16, .little),
        .hunger_normal = try r.readInt(u16, .little),
        .hunger_extra = try r.readInt(u16, .little),
    };
}

fn encode_player_stats(w: anytype, ps: PlayerStats) !void {
    try w.writeByte(ps.name_len);
    try w.writeAll(ps.name[0..ps.name_len]);
    try w.writeInt(u16, ps.casts, .little);
    try w.writeInt(u16, ps.cells_covered, .little);
    try w.writeInt(u16, ps.cells_neutralized, .little);
    try w.writeInt(u16, ps.recipe_casts, .little);
    try w.writeInt(u16, ps.fizzles, .little);
}

fn decode_player_stats(r: anytype) !PlayerStats {
    var ps = PlayerStats{};
    ps.name_len = try r.readByte();
    if (ps.name_len > 16) return DecodeError.NameTooLong;
    _ = try r.readAll(ps.name[0..ps.name_len]);
    ps.casts = try r.readInt(u16, .little);
    ps.cells_covered = try r.readInt(u16, .little);
    ps.cells_neutralized = try r.readInt(u16, .little);
    ps.recipe_casts = try r.readInt(u16, .little);
    ps.fizzles = try r.readInt(u16, .little);
    return ps;
}

fn encode_match_stats(w: anytype, ms: MatchStats) !void {
    try w.writeByte(@intFromEnum(ms.reason));
    try w.writeInt(u32, ms.slime_total, .little);
    try w.writeInt(u32, ms.slime_left, .little);
    try w.writeInt(u16, ms.hunger_final, .little);
    try w.writeInt(u16, ms.hunger_max, .little);
    try encode_feast_stats(w, ms.feast);
    try w.writeByte(ms.player_count);
    var i: u8 = 0;
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
    ms.slime_total = try r.readInt(u32, .little);
    ms.slime_left = try r.readInt(u32, .little);
    ms.hunger_final = try r.readInt(u16, .little);
    ms.hunger_max = try r.readInt(u16, .little);
    ms.feast = try decode_feast_stats(r);
    ms.player_count = try r.readByte();
    if (ms.player_count > MAX_PLAYERS) return DecodeError.TooManyEntities;
    var i: u8 = 0;
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
    InvalidCursorDir,
    InvalidTier,
    TooManyShapeCells,
    InvalidActionResultTag,
    NameTooLong,
    TooManyEntities,
    InvalidComboLen,
    InvalidEndReason,
    TooManyRecipes,
    InvalidRecipeKind,
    InvalidSlimeCell,
    InvalidGridDims,
    TooManyLilGuys,
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

fn decode_combo_payload(reader: anytype) !components.ActionCombo {
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
    return combo;
}

pub fn decode_choose_combo(reader: anytype) !ChooseCombo {
    return .{ .combo = try decode_combo_payload(reader) };
}

pub fn decode_submit_spell(reader: anytype) !SubmitSpell {
    return .{ .combo = try decode_combo_payload(reader) };
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
    p.cast_buffer_ms = try reader.readInt(u32, .little);
    p.grid_rows = try reader.readByte();
    p.grid_cols = try reader.readByte();
    if (p.grid_rows > components.MAX_GRID_ROWS or p.grid_cols > components.MAX_GRID_COLS)
        return DecodeError.InvalidGridDims;
    return p;
}

fn decode_bar_summary(reader: anytype) !BarSummary {
    return .{
        .current = try reader.readInt(u16, .little),
        .max = try reader.readInt(u16, .little),
    };
}

pub fn decode_game_state(reader: anytype) !GameState {
    var p: GameState = undefined;
    p.tick = try reader.readInt(u32, .little);
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
        e.lock_ms = try reader.readInt(u16, .little);
        e.cast_ms = try reader.readInt(u16, .little);
        e.combo_len = try reader.readByte();
        if (e.combo_len > components.MAX_COMBO_LEN) return DecodeError.InvalidComboLen;
        e.combo_slots = [_]components.ComboSlot{.{ .action = .dispense }} ** components.MAX_COMBO_LEN;
        var j: u8 = 0;
        while (j < e.combo_len) : (j += 1) {
            const ab = try reader.readByte();
            e.combo_slots[j] = try decode_combo_slot(ab);
        }
        e.submitted_len = try reader.readByte();
        if (e.submitted_len > components.MAX_COMBO_LEN) return DecodeError.InvalidComboLen;
        e.submitted_slots = [_]components.ComboSlot{.{ .action = .dispense }} ** components.MAX_COMBO_LEN;
        var k: u8 = 0;
        while (k < e.submitted_len) : (k += 1) {
            const sb = try reader.readByte();
            e.submitted_slots[k] = try decode_combo_slot(sb);
        }
        e.cursor_row = try reader.readByte();
        e.cursor_col = try reader.readByte();
        p.entities[i] = e;
    }
    p.hunger = try decode_bar_summary(reader);
    for (&p.hunger_healable) |*h| h.* = try reader.readInt(u16, .little);
    p.score = try reader.readInt(u32, .little);
    p.grid_rows = try reader.readByte();
    p.grid_cols = try reader.readByte();
    if (p.grid_rows > components.MAX_GRID_ROWS or p.grid_cols > components.MAX_GRID_COLS)
        return DecodeError.InvalidGridDims;
    p.grid = [_]components.SlimeCell{.empty} ** components.MAX_GRID_CELLS;
    for (p.grid[0..p.grid_len()]) |*cell|
        cell.* = try decode_slime_cell(try reader.readByte());
    p.reservoir = try reader.readInt(u32, .little);
    p.lil_guy_count = try reader.readByte();
    if (p.lil_guy_count > MAX_LIL_GUYS_WIRE) return DecodeError.TooManyLilGuys;
    p.lil_guys = [_]LilGuySnapshot{LilGuySnapshot.blank} ** MAX_LIL_GUYS_WIRE;
    var g: u8 = 0;
    while (g < p.lil_guy_count) : (g += 1) {
        p.lil_guys[g] = .{
            .entity = try reader.readInt(u32, .little),
            .target = try reader.readInt(u16, .little),
            .bite_ms = try reader.readInt(u16, .little),
        };
    }
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
    go.stats.slime_total = 110;
    go.stats.slime_left = 7;
    go.stats.hunger_final = 199;
    go.stats.hunger_max = 200;
    go.stats.feast = .{
        .cells_covered = .{ 30, 0, 5 },
        .medicine_dispensed = .{ 2, 0, 10 },
        .medicine_healed = .{ 2, 0, 3 },
        .neutralized = .{ 10, 0, 5 },
        .hazard_escaped = .{ 0, 8, 0 },
        .neutral_consumed = 15,
        .hunger_normal = 38,
        .hunger_extra = 16,
    };
    go.stats.player_count = 2;
    go.stats.players[0] = .{ .casts = 3, .cells_covered = 27, .cells_neutralized = 6, .recipe_casts = 2, .fizzles = 1 };
    @memcpy(go.stats.players[0].name[0..5], "Alice");
    go.stats.players[0].name_len = 5;
    go.stats.players[1] = .{ .casts = 2, .cells_covered = 4 };
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
    try std.testing.expectEqual(@as(u32, 110), d.stats.slime_total);
    try std.testing.expectEqual(@as(u32, 7), d.stats.slime_left);
    try std.testing.expectEqual(@as(u16, 199), d.stats.hunger_final);
    try std.testing.expectEqual(@as(u16, 30), d.stats.feast.cells_covered[0]);
    try std.testing.expectEqual(@as(u16, 3), d.stats.feast.medicine_healed[2]);
    try std.testing.expectEqual(@as(u16, 8), d.stats.feast.hazard_escaped[1]);
    try std.testing.expectEqual(@as(u16, 15), d.stats.feast.neutral_consumed);
    try std.testing.expectEqual(@as(u16, 16), d.stats.feast.hunger_extra);
    try std.testing.expectEqual(@as(u8, 2), d.stats.player_count);
    try std.testing.expectEqualSlices(u8, "Alice", d.stats.players[0].name[0..d.stats.players[0].name_len]);
    try std.testing.expectEqual(@as(u16, 3), d.stats.players[0].casts);
    try std.testing.expectEqual(@as(u16, 27), d.stats.players[0].cells_covered);
    try std.testing.expectEqual(@as(u16, 6), d.stats.players[0].cells_neutralized);
    try std.testing.expectEqual(@as(u16, 2), d.stats.players[0].recipe_casts);
    try std.testing.expectEqual(@as(u16, 1), d.stats.players[0].fizzles);
    try std.testing.expectEqual(@as(u16, 4), d.stats.players[1].cells_covered);
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

test "round-trip: game_state — hunger, score, grid, lil guys, and combo survive" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState.blank;
    gs.tick = 42;
    gs.cast_timer = 0.6;
    gs.entity_count = 1;
    gs.hunger = .{ .current = 80, .max = 200 };
    gs.hunger_healable = .{ 30, 0, 6 };
    gs.score = 55;
    // A 2x3 grid holding one cell of every kind.
    gs.grid_rows = 2;
    gs.grid_cols = 3;
    gs.grid[0] = .empty;
    gs.grid[1] = .neutral;
    gs.grid[2] = .{ .tiered = .red };
    gs.grid[3] = .{ .tiered = .green };
    gs.grid[4] = .neutralized;
    gs.grid[5] = .{ .tiered = .yellow };
    gs.reservoir = 44;
    gs.lil_guy_count = 2;
    gs.lil_guys[0] = .{ .entity = 11, .target = 4, .bite_ms = 750 };
    gs.lil_guys[1] = .{ .entity = 12, .target = components.LilGuy.NO_TARGET, .bite_ms = 0 };
    gs.entities[0] = EntitySnapshot{
        .entity = 7,
        .kind = .player,
        .owner = 0,
        .casts_used = 2,
        .lock_ms = 350,
        .cast_ms = 420,
        .combo_len = 2,
        .combo_slots = [_]components.ComboSlot{
            .{ .action = .medicine },
            .{ .action = .dispense },
            .{ .action = .dispense },
            .{ .action = .dispense },
            .{ .action = .dispense },
        },
        // A DIFFERENT combo is already committed and buffering: both pools
        // must survive the round trip independently.
        .submitted_len = 3,
        .submitted_slots = [_]components.ComboSlot{
            .{ .action = .medicine },
            .{ .action = .medicine },
            .{ .action = .dispense },
            .{ .action = .dispense },
            .{ .action = .dispense },
        },
        .cursor_row = 2,
        .cursor_col = 5,
    };

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.game_state, tag);
    const decoded = try decode_game_state(fbs.reader());

    try std.testing.expectEqual(@as(u32, 42), decoded.tick);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), decoded.cast_timer, 0.001);
    try std.testing.expectEqual(@as(u8, 1), decoded.entity_count);
    try std.testing.expectEqual(@as(u8, 2), decoded.entities[0].casts_used);
    try std.testing.expectEqual(@as(u16, 350), decoded.entities[0].lock_ms);
    try std.testing.expectEqual(@as(u16, 420), decoded.entities[0].cast_ms);
    try std.testing.expectEqual(@as(u16, 80), decoded.hunger.current);
    try std.testing.expectEqual(@as(u16, 200), decoded.hunger.max);
    try std.testing.expectEqual(@as(u16, 30), decoded.hunger_healable[0]);
    try std.testing.expectEqual(@as(u16, 6), decoded.hunger_healable[2]);
    try std.testing.expectEqual(@as(u32, 55), decoded.score);
    try std.testing.expectEqual(@as(u8, 2), decoded.grid_rows);
    try std.testing.expectEqual(@as(u8, 3), decoded.grid_cols);
    try std.testing.expectEqualSlices(
        components.SlimeCell,
        gs.grid[0..6],
        decoded.grid[0..decoded.grid_len()],
    );
    // Cells beyond the live area stay empty rather than carrying stale data.
    try std.testing.expectEqual(components.SlimeCell.empty, decoded.grid[6]);
    try std.testing.expectEqual(@as(u32, 44), decoded.reservoir);
    try std.testing.expectEqual(@as(u8, 2), decoded.lil_guy_count);
    try std.testing.expectEqual(@as(u32, 11), decoded.lil_guys[0].entity);
    try std.testing.expectEqual(@as(u16, 4), decoded.lil_guys[0].target);
    try std.testing.expectEqual(@as(u16, 750), decoded.lil_guys[0].bite_ms);
    const idle = components.LilGuy{ .target = decoded.lil_guys[1].target };
    try std.testing.expect(!idle.has_target());
    try std.testing.expectEqual(@as(u8, 2), decoded.entities[0].combo_len);
    try std.testing.expectEqual(components.ActionChoice.medicine, decoded.entities[0].combo_slots[0].action);
    try std.testing.expectEqual(components.ActionChoice.dispense, decoded.entities[0].combo_slots[1].action);
    // The committed pool round-trips separately from the typed one.
    try std.testing.expectEqual(@as(u8, 3), decoded.entities[0].submitted_len);
    try std.testing.expectEqual(components.ActionChoice.medicine, decoded.entities[0].submitted_slots[0].action);
    try std.testing.expectEqual(components.ActionChoice.medicine, decoded.entities[0].submitted_slots[1].action);
    try std.testing.expectEqual(components.ActionChoice.dispense, decoded.entities[0].submitted_slots[2].action);
    // The aiming cursor travels with the rest of the player's state.
    try std.testing.expectEqual(@as(u8, 2), decoded.entities[0].cursor_row);
    try std.testing.expectEqual(@as(u8, 5), decoded.entities[0].cursor_col);
}

test "round-trip: lobby_update — roster survives" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var lu = LobbyUpdate{
        .join_code = "ABCDEF".*,
        .player_count = 1,
        .players = [_]PlayerInfo{std.mem.zeroes(PlayerInfo)} ** MAX_PLAYERS,
        .player_id = 0,
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

    try std.testing.expectEqual(@as(u8, 0), decoded.player_id);
    try std.testing.expectEqual(@as(u8, 1), decoded.player_count);
}

test "round-trip: game_start — grid dims and cast buffer survive" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const label = "slime_feast_01";
    var gs = GameStart{
        .encounter_label = [_]u8{0} ** 32,
        .encounter_label_len = @intCast(label.len),
        .player_id = 3,
        .cast_buffer_ms = 1200,
        .grid_rows = 6,
        .grid_cols = 10,
    };
    @memcpy(gs.encounter_label[0..label.len], label);

    try encode(fbs.writer(), .game_start, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_start(fbs.reader());

    try std.testing.expectEqual(@as(u8, 3), decoded.player_id);
    try std.testing.expectEqual(@as(u32, 1200), decoded.cast_buffer_ms);
    try std.testing.expectEqual(@as(u8, 6), decoded.grid_rows);
    try std.testing.expectEqual(@as(u8, 10), decoded.grid_cols);
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

test "round-trip: a mixed action combo survives in order" {
    // Order is the whole identity of a combo, so it must survive exactly.
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const combo = components.make_combo(&.{
        .{ .action = .medicine },
        .{ .action = .dispense },
        .{ .action = .medicine },
    });
    try encode(fbs.writer(), .choose_combo, ChooseCombo{ .combo = combo });
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_choose_combo(fbs.reader());
    try std.testing.expectEqual(@as(u8, 3), decoded.combo.len);
    try std.testing.expectEqual(components.ActionChoice.medicine, decoded.combo.slots[0].action);
    try std.testing.expectEqual(components.ActionChoice.dispense, decoded.combo.slots[1].action);
    try std.testing.expectEqual(components.ActionChoice.medicine, decoded.combo.slots[2].action);
}

test "round-trip: submit_spell carries the combo" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const combo = components.make_combo(&.{
        .{ .action = .medicine },
        .{ .action = .dispense },
        .{ .action = .dispense },
    });
    try encode(fbs.writer(), .submit_spell, SubmitSpell{ .combo = combo });
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.submit_spell, tag);
    const decoded = try decode_submit_spell(fbs.reader());
    try std.testing.expectEqual(@as(u8, 3), decoded.combo.len);
    try std.testing.expectEqual(components.ActionChoice.medicine, decoded.combo.slots[0].action);
    try std.testing.expectEqual(components.ActionChoice.dispense, decoded.combo.slots[1].action);
}

test "round-trip: a full MAX grid of every cell kind survives" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState.blank;
    gs.grid_rows = components.MAX_GRID_ROWS;
    gs.grid_cols = components.MAX_GRID_COLS;
    // Cycle through all 6 distinct cell values so every encoding is covered.
    const kinds = [_]components.SlimeCell{
        .empty,
        .neutral,
        .neutralized,
        .{ .tiered = .red },
        .{ .tiered = .yellow },
        .{ .tiered = .green },
    };
    for (gs.grid[0..gs.grid_len()], 0..) |*cell, i| cell.* = kinds[i % kinds.len];

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_state(fbs.reader());
    try std.testing.expectEqualSlices(
        components.SlimeCell,
        gs.grid[0..gs.grid_len()],
        decoded.grid[0..decoded.grid_len()],
    );
}

test "decode_game_state: an unknown slime cell byte is rejected" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var gs = GameState.blank;
    gs.grid_rows = 1;
    gs.grid_cols = 1;
    try encode(fbs.writer(), .game_state, gs);
    const written = fbs.getWritten();
    // The last byte before reservoir+lil_guy_count is the single cell.
    written[written.len - 6] = 0x7F;
    fbs.reset();
    _ = try read_tag(fbs.reader());
    try std.testing.expectError(DecodeError.InvalidSlimeCell, decode_game_state(fbs.reader()));
}

test "round-trip: cast_grouped carries player mask and fire delay" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .cast_grouped, CastGrouped{
        .player_mask = 0b0000_0011,
        .fires_in_ms = 500,
    });
    fbs.reset();
    try std.testing.expectEqual(MsgTag.cast_grouped, try read_tag(fbs.reader()));
    const decoded = try decode_cast_grouped(fbs.reader());
    try std.testing.expectEqual(@as(u8, 0b0000_0011), decoded.player_mask);
    try std.testing.expectEqual(@as(u32, 500), decoded.fires_in_ms);
}

test "round-trip: cast_replaced carries player_id" {
    var buf: [8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .cast_replaced, CastReplaced{ .player_id = 4 });
    fbs.reset();
    try std.testing.expectEqual(MsgTag.cast_replaced, try read_tag(fbs.reader()));
    const decoded = try decode_cast_replaced(fbs.reader());
    try std.testing.expectEqual(@as(u8, 4), decoded.player_id);
}

test "round-trip: cast_fired carries count and player mask" {
    var buf: [8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .cast_fired, CastFired{
        .spell_count = 2,
        .player_mask = 0b0000_0101,
    });
    fbs.reset();
    try std.testing.expectEqual(MsgTag.cast_fired, try read_tag(fbs.reader()));
    const decoded = try decode_cast_fired(fbs.reader());
    try std.testing.expectEqual(@as(u8, 2), decoded.spell_count);
    try std.testing.expectEqual(@as(u8, 0b0000_0101), decoded.player_mask);
}

test "decode_game_state: oversized grid dimensions are rejected" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var gs = GameState.blank;
    gs.grid_rows = 1;
    gs.grid_cols = 1;
    try encode(fbs.writer(), .game_state, gs);
    const written = fbs.getWritten();
    // grid_rows sits right after score: tick(4) cast_timer(4) entity_count(1)
    // hunger(4) healable(3 tiers x 2) score(4) = offset 23 after the tag byte.
    written[1 + 23] = components.MAX_GRID_ROWS + 1;
    fbs.reset();
    _ = try read_tag(fbs.reader());
    try std.testing.expectError(DecodeError.InvalidGridDims, decode_game_state(fbs.reader()));
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

test "round-trip: a blank game_state (pre-start, no grid) survives" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState.blank;
    gs.tick = 7;

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_state(fbs.reader());

    try std.testing.expectEqual(@as(u32, 7), decoded.tick);
    try std.testing.expectEqual(@as(u16, 0), decoded.grid_len());
    try std.testing.expectEqual(@as(u8, 0), decoded.lil_guy_count);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), decoded.cast_timer, 0.001);
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

test "shape_cast round-trips its footprint and outcome" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var sc = ShapeCast{ .caster = 3, .cell_count = 4 };
    sc.cells = [_]u16{0} ** MAX_SHAPE_CELLS_WIRE;
    sc.cells[0] = 0;
    sc.cells[1] = 17;
    sc.cells[2] = 59;
    sc.cells[3] = 255;
    sc.downgraded[@intFromEnum(components.Tier.red)] = 2;
    sc.downgraded[@intFromEnum(components.Tier.green)] = 1;
    sc.neutralized = 1;
    sc.off_grid = 5;
    sc.inert = 3;
    try encode(fbs.writer(), .shape_cast, sc);

    var rfbs = std.io.fixedBufferStream(fbs.getWritten());
    const r = rfbs.reader();
    try std.testing.expectEqual(MsgTag.shape_cast, try read_tag(r));
    const got = try decode_shape_cast(r);
    try std.testing.expectEqual(@as(u8, 3), got.caster);
    try std.testing.expectEqual(@as(u16, 4), got.cell_count);
    try std.testing.expectEqualSlices(u16, sc.cells[0..4], got.cells[0..4]);
    try std.testing.expectEqual(@as(u16, 2), got.downgraded[@intFromEnum(components.Tier.red)]);
    try std.testing.expectEqual(@as(u16, 0), got.downgraded[@intFromEnum(components.Tier.yellow)]);
    try std.testing.expectEqual(@as(u16, 1), got.downgraded[@intFromEnum(components.Tier.green)]);
    try std.testing.expectEqual(@as(u16, 1), got.neutralized);
    // Wasted coverage travels explicitly, never inferred.
    try std.testing.expectEqual(@as(u16, 5), got.off_grid);
    try std.testing.expectEqual(@as(u16, 3), got.inert);
}

test "shape_cast: a fully-clipped cast carries no cells" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const sc = ShapeCast{ .caster = 1, .cell_count = 0, .off_grid = 9 };
    try encode(fbs.writer(), .shape_cast, sc);

    var rfbs = std.io.fixedBufferStream(fbs.getWritten());
    const r = rfbs.reader();
    _ = try read_tag(r);
    const got = try decode_shape_cast(r);
    try std.testing.expectEqual(@as(u16, 0), got.cell_count);
    try std.testing.expectEqual(@as(u16, 9), got.off_grid);
}

test "round-trip: move_cursor carries each direction" {
    for ([_]CursorDir{ .up, .down, .left, .right }) |dir| {
        var buf: [4]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try encode(fbs.writer(), .move_cursor, MoveCursor{ .dir = dir });
        fbs.reset();
        try std.testing.expectEqual(MsgTag.move_cursor, try read_tag(fbs.reader()));
        try std.testing.expectEqual(dir, (try decode_move_cursor(fbs.reader())).dir);
    }
}

test "decode_move_cursor: an unknown direction is rejected" {
    var buf = [_]u8{ @intFromEnum(MsgTag.move_cursor), 9 };
    var fbs = std.io.fixedBufferStream(buf[0..]);
    _ = try read_tag(fbs.reader());
    try std.testing.expectError(DecodeError.InvalidCursorDir, decode_move_cursor(fbs.reader()));
}

test "CursorDir.delta steps exactly one cell" {
    try std.testing.expectEqual(@as(i8, -1), CursorDir.up.delta().d_row);
    try std.testing.expectEqual(@as(i8, 0), CursorDir.up.delta().d_col);
    try std.testing.expectEqual(@as(i8, 1), CursorDir.down.delta().d_row);
    try std.testing.expectEqual(@as(i8, -1), CursorDir.left.delta().d_col);
    try std.testing.expectEqual(@as(i8, 1), CursorDir.right.delta().d_col);
}

test "round-trip: a cursor position survives per entity" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var gs = GameState.blank;
    gs.entity_count = 2;
    gs.entities[0] = EntitySnapshot.blank;
    gs.entities[0].cursor_row = 3;
    gs.entities[0].cursor_col = 7;
    gs.entities[1] = EntitySnapshot.blank;
    gs.entities[1].cursor_row = 0;
    gs.entities[1].cursor_col = 0;
    gs.grid_rows = 6;
    gs.grid_cols = 10;

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_state(fbs.reader());
    try std.testing.expectEqual(@as(u8, 3), decoded.entities[0].cursor_row);
    try std.testing.expectEqual(@as(u8, 7), decoded.entities[0].cursor_col);
    try std.testing.expectEqual(@as(u8, 0), decoded.entities[1].cursor_row);
    try std.testing.expectEqual(@as(u8, 0), decoded.entities[1].cursor_col);
}
