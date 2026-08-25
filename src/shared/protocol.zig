const std = @import("std");
const components = @import("components.zig");
const balance = @import("balance.zig");

pub const MsgTag = enum(u8) {
    // 0x01 was join_lobby, 0x03 was ready_up, 0x05 was reconnect: the lobby
    // is gone — a game is always running, connections observe by default and
    // take a player slot explicitly.
    take_slot = 0x02,
    leave_slot = 0x04,
    /// Advance the match from a HOLD: from the end screen into the next
    /// encounter's pre-match guide, and from the guide into play.  Sent by
    /// browser-tab clients when the screen's button is CLICKED (never a key
    /// press); ignored while a game is running.
    restart = 0x06,
    cycle_shape = 0x07,
    cast = 0x09,
    move_cursor = 0x0a,
    cancel_cast = 0x0b,
    // 0x10 was lobby_update.
    game_start = 0x11,
    game_state = 0x12,
    action_result = 0x13,
    game_over = 0x15,
    over_budget = 0x19,
    recipe_fired = 0x18,
    shape_cast = 0x1c,
    turn_ended = 0x1d,
};

/// The `player_id` a connection holds while it is only OBSERVING: it receives
/// every broadcast but owns no player slot, no entity and no shares.
pub const NO_PLAYER: u8 = 0xFF;

/// A connection asks to become a player in the running game.  SILENTLY
/// ignored when all MAX_PLAYERS slots are taken — the connection simply stays
/// an observer.  A granted slot is confirmed by a personalized `game_start`
/// (player_id != NO_PLAYER).
pub const TakeSlot = struct {
    /// The joining player's appetite stat — the board's persistent flash
    /// counter, forwarded through the bridge.  0 for players with no board
    /// (browsers, bots).  The server folds it into the hunger bar's capacity
    /// via game_logic.player_hunger.
    appetite: u32 = 0,
};

/// One step of the shape wheel.  A DIRECTION, not a destination, for the same
/// reason as `MoveCursor`: the server owns the selection, so a client can never
/// name a move that is not in the table.  `cast` then carries no payload at all
/// — what fires is whatever the server has selected for that player.
pub const CycleShape = struct {
    dir: components.CycleDir,
};

pub fn decode_cycle_shape(reader: anytype) !CycleShape {
    const byte = try reader.readByte();
    const dir = std.meta.intToEnum(components.CycleDir, byte) catch
        return DecodeError.InvalidCycleDir;
    return .{ .dir = dir };
}

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

/// A cast was refused because the turn's locked-in casts, WITH it, would cost
/// more than the shared pool holds.
///
/// Sent only to the player who tried it: nobody else did anything, and the turn
/// is unchanged — their cast simply never locked in.  The two numbers are the
/// whole explanation, so the client can say what it would have cost and what is
/// actually left without deriving either.
pub const OverBudget = struct {
    /// What the turn would have cost with this cast included.
    needed: u32,
    /// What the shared pool holds right now.
    have: u32,
};

pub fn decode_over_budget(reader: anytype) !OverBudget {
    return .{
        .needed = try reader.readInt(u32, .little),
        .have = try reader.readInt(u32, .little),
    };
}

/// The turn's cast phase is over and the feast has eaten its way in from the
/// left edge.
///
/// Sent after the feast, the collapse and the refill, so a client can animate
/// the devouring and float the resulting hunger/score without re-deriving any
/// of it.  This is the only place hunger and score move in the turn loop:
/// casting never feeds the Lil Guys, it only opens the path to what they eat.
///
/// `sheltered` is the message's most useful number for a player: it is the food
/// that a wall kept out of reach, i.e. what the turn's casts failed to expose.
pub const TurnEnded = struct {
    /// The turn that just ended (1-based); the next turn is this + 1.
    turn: u16,
    /// Slime units eaten off the grid.
    cells_eaten: u16,
    /// Total hunger added by the feast.
    hunger_added: u16,
    /// Edible units the feast could not reach behind a wall.
    sheltered: u16,
    /// Inedible cells (live hazards + specials) that held the feast back.
    walls: u16,
    /// Score added by the feast.
    score_added: u32,
    /// Charges left in the shared pool after the turn.  Sent here as well as in
    /// GameState so the end-of-turn summary is self-contained.
    charges_left: u32,
};

pub fn decode_turn_ended(reader: anytype) !TurnEnded {
    return .{
        .turn = try reader.readInt(u16, .little),
        .cells_eaten = try reader.readInt(u16, .little),
        .hunger_added = try reader.readInt(u16, .little),
        .sheltered = try reader.readInt(u16, .little),
        .walls = try reader.readInt(u16, .little),
        .score_added = try reader.readInt(u32, .little),
        .charges_left = try reader.readInt(u32, .little),
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
    /// Player whose cursor anchored this shape (the completing caster, for a
    /// group).
    caster: u8 = 0,
    /// The cell the caster was aiming at, as a flat grid index.  Travels
    /// separately because it is NOT derivable from `cells`: clipping can drop
    /// the anchor itself, and a group forms per-square, so clients need the
    /// square a cast claimed in order to hint at a group coming together.
    anchor: u16 = 0,
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
    p.anchor = try reader.readInt(u16, .little);
    p.cell_count = try reader.readInt(u16, .little);
    if (p.cell_count > MAX_SHAPE_CELLS_WIRE) return DecodeError.TooManyShapeCells;
    for (p.cells[0..p.cell_count]) |*cell| cell.* = try reader.readInt(u16, .little);
    p.downgraded = try decode_u16_tiers(reader);
    p.neutralized = try reader.readInt(u16, .little);
    p.off_grid = try reader.readInt(u16, .little);
    p.inert = try reader.readInt(u16, .little);
    return p;
}

/// Hard cap on simultaneous PLAYERS in a game.  Connections beyond this can
/// only observe: a take_slot with all slots taken is silently ignored.
pub const MAX_PLAYERS: u8 = 4;

/// Sent to every connection the moment it connects (a game is ALWAYS
/// running), and again personalized whenever its slot binding changes or a
/// fresh encounter auto-starts.
pub const GameStart = struct {
    encounter_label: [32]u8,
    encounter_label_len: u8,
    /// The receiver's player slot, or NO_PLAYER when it is observing.
    player_id: u8,
    /// The session's join code — the game id, shown by clients so others can
    /// join or observe.
    join_code: [6]u8 = [_]u8{'-'} ** 6,
    /// True while the encounter is holding at its PRE-MATCH screen (the
    /// recipe guide): everything is set up and seats can be taken, but play
    /// waits for a browser tab's `restart` click.
    prematch: bool = false,
    /// Casts each player gets per turn (balance.casts_per_turn).  Sent once at
    /// start because it never changes mid-encounter.
    casts_per_turn: u8 = 0,
    /// Charges the team's shared pool starts with (encounter.charges), so the
    /// client can draw the gauge full before the first game_state arrives.
    charges: u32 = 0,
    /// Slime grid dimensions, so the client can lay out the playfield the
    /// moment the game starts (before the first game_state arrives).
    grid_rows: u8 = 0,
    grid_cols: u8 = 0,
};

pub const EntitySnapshot = struct {
    entity: u32,
    kind: components.EntityKind,
    owner: u8,
    /// Casts this player has left this turn.  The turn ends when this reaches
    /// 0 for every connected player, so it is both a budget readout and the
    /// only turn-progress signal a client needs.
    casts_left: u8,
    /// This player's index into `balance.player_recipes` — the move that `cast`
    /// will fire.  Snapshotted for EVERY player so teammates can see what each
    /// other is holding and coordinate a group before anyone spends a cast;
    /// that visibility is the whole point of a server-owned selection.
    selected_shape: u8,
    /// Where this player is aiming.  Server-owned and always in bounds, and
    /// snapshotted for EVERY player (not just the receiver) so teammates can
    /// see each other's cursors and shape previews.
    cursor_row: u8,
    cursor_col: u8,

    pub const blank = EntitySnapshot{
        .entity = 0,
        .kind = .player,
        .owner = 0xFF,
        .casts_left = 0,
        .selected_shape = 0,
        .cursor_row = 0,
        .cursor_col = 0,
    };
};

pub const MAX_ENTITIES_WIRE: u16 = 64;

/// Cap on the pending-cast list carried in a `GameState`.  Matches
/// `game_logic.MAX_CASTS`, which is itself max players x casts each with
/// headroom; it is restated here because protocol.zig knows nothing of the
/// game's resolution logic.
pub const MAX_PENDING_WIRE: u16 = 64;

/// One cast a player has LOCKED IN this turn but which has not resolved yet.
///
/// Sent to everyone: the whole team needs to see what is already committed to
/// decide what to add, and the client previews the turn from this list plus the
/// viewer's own live aim.  Nothing here has been charged or stamped — a pending
/// cast is a promise, and it can still be taken back (see `cancel_cast`).
pub const PendingCast = struct {
    player_id: u8,
    /// Index into balance.player_recipes — the move that was locked in.
    move: u8,
    /// Flat grid index it is aimed at, frozen at lock-in.
    square: u16,
};

pub const BarSummary = struct {
    current: u16,
    max: u16,
};

pub const GameState = struct {
    tick: u32,
    /// The turn now being played (1-based).  Cast budgets refresh and the whole
    /// field is replaced between turns, so this is the client's clock.
    turn: u16,
    entity_count: u8,
    entities: [MAX_ENTITIES_WIRE]EntitySnapshot,
    hunger: BarSummary,
    /// Charges left in the team's shared pool — the encounter's whole budget for
    /// casting, spent across every turn and never refilled.
    charges: u32,
    score: u32,
    /// The authoritative slime grid.  Cells are sent as one byte each (see
    /// components.SlimeCell), so every client renders identical slime.
    grid_rows: u8,
    grid_cols: u8,
    grid: [components.MAX_GRID_CELLS]components.SlimeCell,
    /// Slime still waiting off-grid — drives the "incoming" indicator.  The win
    /// needs this AND the grid to hold nothing but specials.
    reservoir: u32,
    /// Casts locked in this turn and not yet resolved, in lock-in order.
    pending_count: u8,
    pending: [MAX_PENDING_WIRE]PendingCast,

    pub const blank = GameState{
        .tick = 0,
        .turn = 0,
        .entity_count = 0,
        .entities = [_]EntitySnapshot{EntitySnapshot.blank} ** MAX_ENTITIES_WIRE,
        .hunger = .{ .current = 0, .max = 0 },
        .charges = 0,
        .score = 0,
        .grid_rows = 0,
        .grid_cols = 0,
        .grid = [_]components.SlimeCell{.empty} ** components.MAX_GRID_CELLS,
        .reservoir = 0,
        .pending_count = 0,
        .pending = [_]PendingCast{.{ .player_id = 0, .move = 0, .square = 0 }} ** MAX_PENDING_WIRE,
    };

    /// Live cell count of the transmitted grid.
    pub fn grid_len(self: *const GameState) u16 {
        return @as(u16, self.grid_rows) * @as(u16, self.grid_cols);
    }
};

/// Transient cues the client floats over the field.  `heal` is gone with
/// medicine: nothing reduces the hunger bar any more, it is a one-way clock.
pub const ActionResultTag = enum(u8) {
    damage = 0,
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
    /// Every playable unit was eaten — specials may remain, since no play can
    /// remove them.
    field_cleared = 1,
    /// A dead position: the feast reached nothing, the shared charge pool can no
    /// longer afford the cheapest recipe, and slime is still walled in.  No
    /// sequence of moves can change the field again, so the encounter is called
    /// rather than looping empty turns forever.
    out_of_charges = 2,
};

/// Match-wide consumption/dispense tallies for the tuning report.  There are
/// no rounds any more, so this accumulates over the whole encounter.
pub const FeastStats = struct {
    /// Cells covered by cast shapes, per tier they were standing at.
    cells_covered: [components.Tier.size]u16 = [_]u16{0} ** components.Tier.size,
    /// Cells taken all the way to defused, per tier they STARTED at.
    neutralized: [components.Tier.size]u16 = [_]u16{0} ** components.Tier.size,
    /// Edible units the feast could never reach, summed over every turn — the
    /// headline tuning number, since it measures how much of the encounter the
    /// team's charges failed to open up.
    sheltered: u32 = 0,
    neutral_consumed: u16 = 0,
    defused_consumed: u16 = 0,
    hunger_normal: u16 = 0,
    /// Charges spent over the whole encounter, and what was left at the end.
    charges_spent: u32 = 0,
    charges_left: u32 = 0,
};

pub const PlayerStats = struct {
    casts: u16 = 0,
    /// Cells this player's shapes covered, and cells taken to defused.
    cells_covered: u16 = 0,
    cells_neutralized: u16 = 0,
    recipe_casts: u16 = 0,
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
        .take_slot => try writer.writeInt(u32, payload.appetite, .little),
        .leave_slot => {},
        .restart => {},
        .cycle_shape => try writer.writeByte(@intFromEnum(payload.dir)),
        .cast => {},
        .cancel_cast => {},
        .over_budget => {
            try writer.writeInt(u32, payload.needed, .little);
            try writer.writeInt(u32, payload.have, .little);
        },
        .move_cursor => try writer.writeByte(@intFromEnum(payload.dir)),
        .shape_cast => {
            const p: ShapeCast = payload;
            try writer.writeByte(p.caster);
            try writer.writeInt(u16, p.anchor, .little);
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
        .turn_ended => {
            const p: TurnEnded = payload;
            try writer.writeInt(u16, p.turn, .little);
            try writer.writeInt(u16, p.cells_eaten, .little);
            try writer.writeInt(u16, p.hunger_added, .little);
            try writer.writeInt(u16, p.sheltered, .little);
            try writer.writeInt(u16, p.walls, .little);
            try writer.writeInt(u32, p.score_added, .little);
            try writer.writeInt(u32, p.charges_left, .little);
        },

        .game_start => try encode_game_start(writer, payload),
        .game_state => try encode_game_state(writer, payload),
        .action_result => try encode_action_result(writer, payload),
        .game_over => {
            try writer.writeInt(u32, payload.score, .little);
            try encode_match_stats(writer, payload.stats);
        },
    }
}

fn encode_game_start(w: anytype, p: GameStart) !void {
    try w.writeByte(p.encounter_label_len);
    try w.writeAll(p.encounter_label[0..p.encounter_label_len]);
    try w.writeByte(p.player_id);
    try w.writeAll(&p.join_code);
    try w.writeByte(if (p.prematch) 1 else 0);
    try w.writeByte(p.casts_per_turn);
    try w.writeInt(u32, p.charges, .little);
    try w.writeByte(p.grid_rows);
    try w.writeByte(p.grid_cols);
}

fn encode_bar_summary(w: anytype, s: BarSummary) !void {
    try w.writeInt(u16, s.current, .little);
    try w.writeInt(u16, s.max, .little);
}

/// One slime cell as a single byte: 0x00 empty, 0x01 neutral,
/// 0x02 neutralized, 0x03 special, 0x10|t tiered (see components.SlimeCell).
fn encode_slime_cell(cell: components.SlimeCell) u8 {
    return switch (cell) {
        .empty => 0x00,
        .neutral => 0x01,
        .neutralized => 0x02,
        .special => 0x03,
        .tiered => |t| 0x10 | @intFromEnum(t),
    };
}

fn decode_slime_cell(byte: u8) !components.SlimeCell {
    return switch (byte & 0xF0) {
        0x00 => switch (byte) {
            0x00 => .empty,
            0x01 => .neutral,
            0x02 => .neutralized,
            0x03 => .special,
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
    try w.writeInt(u16, p.turn, .little);
    try w.writeByte(p.entity_count);
    var i: u8 = 0;
    while (i < p.entity_count) : (i += 1) {
        const e = p.entities[i];
        try w.writeInt(u32, e.entity, .little);
        try w.writeByte(@intFromEnum(e.kind));
        try w.writeByte(e.owner);
        try w.writeByte(e.casts_left);
        try w.writeByte(e.selected_shape);
        try w.writeByte(e.cursor_row);
        try w.writeByte(e.cursor_col);
    }
    try encode_bar_summary(w, p.hunger);
    try w.writeInt(u32, p.charges, .little);
    try w.writeInt(u32, p.score, .little);
    try w.writeByte(p.grid_rows);
    try w.writeByte(p.grid_cols);
    for (p.grid[0..p.grid_len()]) |cell| try w.writeByte(encode_slime_cell(cell));
    try w.writeInt(u32, p.reservoir, .little);
    try w.writeByte(p.pending_count);
    for (p.pending[0..p.pending_count]) |pc| {
        try w.writeByte(pc.player_id);
        try w.writeByte(pc.move);
        try w.writeInt(u16, pc.square, .little);
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
    try encode_u16_tiers(w, rs.neutralized);
    try w.writeInt(u32, rs.sheltered, .little);
    try w.writeInt(u16, rs.neutral_consumed, .little);
    try w.writeInt(u16, rs.defused_consumed, .little);
    try w.writeInt(u16, rs.hunger_normal, .little);
    try w.writeInt(u32, rs.charges_spent, .little);
    try w.writeInt(u32, rs.charges_left, .little);
}

fn decode_feast_stats(r: anytype) !FeastStats {
    return .{
        .cells_covered = try decode_u16_tiers(r),
        .neutralized = try decode_u16_tiers(r),
        .sheltered = try r.readInt(u32, .little),
        .neutral_consumed = try r.readInt(u16, .little),
        .defused_consumed = try r.readInt(u16, .little),
        .hunger_normal = try r.readInt(u16, .little),
        .charges_spent = try r.readInt(u32, .little),
        .charges_left = try r.readInt(u32, .little),
    };
}

fn encode_player_stats(w: anytype, ps: PlayerStats) !void {
    try w.writeInt(u16, ps.casts, .little);
    try w.writeInt(u16, ps.cells_covered, .little);
    try w.writeInt(u16, ps.cells_neutralized, .little);
    try w.writeInt(u16, ps.recipe_casts, .little);
}

fn decode_player_stats(r: anytype) !PlayerStats {
    var ps = PlayerStats{};
    ps.casts = try r.readInt(u16, .little);
    ps.cells_covered = try r.readInt(u16, .little);
    ps.cells_neutralized = try r.readInt(u16, .little);
    ps.recipe_casts = try r.readInt(u16, .little);
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
    InvalidCycleDir,
    InvalidCursorDir,
    InvalidTier,
    TooManyShapeCells,
    InvalidActionResultTag,
    NameTooLong,
    TooManyEntities,
    TooManyPending,
    InvalidEndReason,
    TooManyRecipes,
    InvalidRecipeKind,
    InvalidSlimeCell,
    InvalidGridDims,
};

pub fn read_tag(reader: anytype) !MsgTag {
    const byte = try reader.readByte();
    return std.meta.intToEnum(MsgTag, byte) catch return DecodeError.UnknownTag;
}

pub fn decode_take_slot(reader: anytype) !TakeSlot {
    return .{ .appetite = try reader.readInt(u32, .little) };
}

pub fn decode_game_start(reader: anytype) !GameStart {
    var p: GameStart = undefined;
    const llen = try reader.readByte();
    if (llen > 32) return DecodeError.NameTooLong;
    p.encounter_label = [_]u8{0} ** 32;
    p.encounter_label_len = llen;
    _ = try reader.readAll(p.encounter_label[0..llen]);
    p.player_id = try reader.readByte();
    _ = try reader.readAll(&p.join_code);
    p.prematch = (try reader.readByte()) != 0;
    p.casts_per_turn = try reader.readByte();
    p.charges = try reader.readInt(u32, .little);
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
    p.turn = try reader.readInt(u16, .little);
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
        e.casts_left = try reader.readByte();
        // Not range-checked against the move table: protocol.zig does not see
        // the loaded balance.  The server only ever sends a valid index, and a
        // client that receives a stale one clamps at render time.
        e.selected_shape = try reader.readByte();
        e.cursor_row = try reader.readByte();
        e.cursor_col = try reader.readByte();
        p.entities[i] = e;
    }
    p.hunger = try decode_bar_summary(reader);
    p.charges = try reader.readInt(u32, .little);
    p.score = try reader.readInt(u32, .little);
    p.grid_rows = try reader.readByte();
    p.grid_cols = try reader.readByte();
    if (p.grid_rows > components.MAX_GRID_ROWS or p.grid_cols > components.MAX_GRID_COLS)
        return DecodeError.InvalidGridDims;
    p.grid = [_]components.SlimeCell{.empty} ** components.MAX_GRID_CELLS;
    for (p.grid[0..p.grid_len()]) |*cell|
        cell.* = try decode_slime_cell(try reader.readByte());
    p.reservoir = try reader.readInt(u32, .little);
    p.pending_count = try reader.readByte();
    if (p.pending_count > MAX_PENDING_WIRE) return DecodeError.TooManyPending;
    p.pending = [_]PendingCast{.{ .player_id = 0, .move = 0, .square = 0 }} ** MAX_PENDING_WIRE;
    for (p.pending[0..p.pending_count]) |*pc| {
        pc.player_id = try reader.readByte();
        pc.move = try reader.readByte();
        pc.square = try reader.readInt(u16, .little);
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

test "read_tag: retired lobby-era tags are UnknownTag" {
    // 0x01 join_lobby, 0x03 ready_up, 0x05 reconnect, 0x10 lobby_update: the
    // lobby is gone — games run from the moment the session exists.
    for ([_]u8{ 0x01, 0x03, 0x05, 0x10 }) |byte| {
        var fbs = std.io.fixedBufferStream(&[_]u8{byte});
        try std.testing.expectError(DecodeError.UnknownTag, read_tag(fbs.reader()));
    }
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
        .neutralized = .{ 10, 0, 5 },
        .sheltered = 21,
        .neutral_consumed = 15,
        .defused_consumed = 9,
        .hunger_normal = 38,
        .charges_spent = 27,
        .charges_left = 13,
    };
    go.stats.player_count = 2;
    go.stats.players[0] = .{ .casts = 3, .cells_covered = 27, .cells_neutralized = 6, .recipe_casts = 2 };
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
    try std.testing.expectEqual(@as(u16, 5), d.stats.feast.neutralized[2]);
    try std.testing.expectEqual(@as(u32, 21), d.stats.feast.sheltered);
    try std.testing.expectEqual(@as(u16, 15), d.stats.feast.neutral_consumed);
    try std.testing.expectEqual(@as(u16, 9), d.stats.feast.defused_consumed);
    try std.testing.expectEqual(@as(u32, 27), d.stats.feast.charges_spent);
    try std.testing.expectEqual(@as(u32, 13), d.stats.feast.charges_left);
    try std.testing.expectEqual(@as(u8, 2), d.stats.player_count);
    try std.testing.expectEqual(@as(u16, 3), d.stats.players[0].casts);
    try std.testing.expectEqual(@as(u16, 27), d.stats.players[0].cells_covered);
    try std.testing.expectEqual(@as(u16, 6), d.stats.players[0].cells_neutralized);
    try std.testing.expectEqual(@as(u16, 2), d.stats.players[0].recipe_casts);
    try std.testing.expectEqual(@as(u16, 4), d.stats.players[1].cells_covered);
    try std.testing.expectEqual(@as(u8, 6), d.stats.player_recipe_count);
    try std.testing.expectEqual(@as(u8, 2), d.stats.team_recipe_count);
    try std.testing.expectEqual(@as(u16, 1), d.stats.player_recipe_hits[0]);
    try std.testing.expectEqual(@as(u16, 2), d.stats.team_recipe_hits[0]);
    try std.testing.expectEqual(@as(u16, 5), d.stats.casts_total);
}

test "round-trip: take_slot carries the appetite stat" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try encode(fbs.writer(), .take_slot, TakeSlot{ .appetite = 17 });
    fbs.reset();
    try std.testing.expectEqual(MsgTag.take_slot, try read_tag(fbs.reader()));
    const decoded = try decode_take_slot(fbs.reader());
    try std.testing.expectEqual(@as(u32, 17), decoded.appetite);
}

test "round-trip: leave_slot carries no payload" {
    var buf: [8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .leave_slot, {});
    try std.testing.expectEqual(@as(usize, 1), fbs.pos);
    fbs.reset();
    try std.testing.expectEqual(MsgTag.leave_slot, try read_tag(fbs.reader()));
}

test "round-trip: restart carries no payload" {
    var buf: [8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .restart, {});
    try std.testing.expectEqual(@as(usize, 1), fbs.pos);
    fbs.reset();
    try std.testing.expectEqual(MsgTag.restart, try read_tag(fbs.reader()));
}

test "round-trip: game_state — turn, hunger, score, grid, and selection survive" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState.blank;
    gs.tick = 42;
    gs.turn = 3;
    gs.entity_count = 1;
    gs.hunger = .{ .current = 80, .max = 200 };
    gs.charges = 17;
    gs.score = 55;
    // A 2x4 grid holding one cell of every kind, specials included.
    gs.grid_rows = 2;
    gs.grid_cols = 4;
    gs.grid[0] = .empty;
    gs.grid[1] = .neutral;
    gs.grid[2] = .{ .tiered = .red };
    gs.grid[3] = .special;
    gs.grid[4] = .{ .tiered = .green };
    gs.grid[5] = .neutralized;
    gs.grid[6] = .{ .tiered = .yellow };
    gs.grid[7] = .special;
    gs.reservoir = 44;
    gs.entities[0] = EntitySnapshot{
        .entity = 7,
        .kind = .player,
        .owner = 0,
        .casts_left = 2,
        .selected_shape = 4,
        .cursor_row = 2,
        .cursor_col = 5,
    };

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.game_state, tag);
    const decoded = try decode_game_state(fbs.reader());

    try std.testing.expectEqual(@as(u32, 42), decoded.tick);
    try std.testing.expectEqual(@as(u16, 3), decoded.turn);
    try std.testing.expectEqual(@as(u8, 1), decoded.entity_count);
    try std.testing.expectEqual(@as(u8, 2), decoded.entities[0].casts_left);
    try std.testing.expectEqual(@as(u16, 80), decoded.hunger.current);
    try std.testing.expectEqual(@as(u16, 200), decoded.hunger.max);
    try std.testing.expectEqual(@as(u32, 17), decoded.charges);
    try std.testing.expectEqual(@as(u32, 55), decoded.score);
    try std.testing.expectEqual(@as(u8, 2), decoded.grid_rows);
    try std.testing.expectEqual(@as(u8, 4), decoded.grid_cols);
    try std.testing.expectEqualSlices(
        components.SlimeCell,
        gs.grid[0..8],
        decoded.grid[0..decoded.grid_len()],
    );
    // Cells beyond the live 2x4 area stay empty rather than carrying stale data.
    try std.testing.expectEqual(components.SlimeCell.empty, decoded.grid[8]);
    try std.testing.expectEqual(@as(u32, 44), decoded.reservoir);
    // The move this player would fire travels with them, so teammates can see
    // it before anyone spends a cast.
    try std.testing.expectEqual(@as(u8, 4), decoded.entities[0].selected_shape);
    // The aiming cursor travels with the rest of the player's state.
    try std.testing.expectEqual(@as(u8, 2), decoded.entities[0].cursor_row);
    try std.testing.expectEqual(@as(u8, 5), decoded.entities[0].cursor_col);
}

test "round-trip: game_start — join code, grid dims and cast buffer survive" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const label = "slime_feast_01";
    var gs = GameStart{
        .encounter_label = [_]u8{0} ** 32,
        .encounter_label_len = @intCast(label.len),
        .player_id = 3,
        .join_code = "ABCDEF".*,
        .prematch = true,
        .casts_per_turn = 3,
        .charges = 40,
        .grid_rows = 6,
        .grid_cols = 10,
    };
    @memcpy(gs.encounter_label[0..label.len], label);

    try encode(fbs.writer(), .game_start, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_start(fbs.reader());

    try std.testing.expectEqual(@as(u8, 3), decoded.player_id);
    try std.testing.expectEqualSlices(u8, "ABCDEF", &decoded.join_code);
    try std.testing.expect(decoded.prematch);
    try std.testing.expectEqual(@as(u8, 3), decoded.casts_per_turn);
    try std.testing.expectEqual(@as(u32, 40), decoded.charges);
    try std.testing.expectEqual(@as(u8, 6), decoded.grid_rows);
    try std.testing.expectEqual(@as(u8, 10), decoded.grid_cols);
    try std.testing.expectEqualSlices(u8, label, decoded.encounter_label[0..decoded.encounter_label_len]);
}

test "round-trip: an observer game_start carries NO_PLAYER" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var gs = GameStart{
        .encounter_label = [_]u8{0} ** 32,
        .encounter_label_len = 1,
        .player_id = NO_PLAYER,
    };
    gs.encounter_label[0] = 'x';
    try encode(fbs.writer(), .game_start, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_start(fbs.reader());
    try std.testing.expectEqual(NO_PLAYER, decoded.player_id);
}

test "round-trip: cycle_shape carries the direction" {
    for ([_]components.CycleDir{ .forward, .backward }) |dir| {
        var buf: [8]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try encode(fbs.writer(), .cycle_shape, CycleShape{ .dir = dir });
        fbs.reset();
        try std.testing.expectEqual(MsgTag.cycle_shape, try read_tag(fbs.reader()));
        const decoded = try decode_cycle_shape(fbs.reader());
        try std.testing.expectEqual(dir, decoded.dir);
    }
}

test "decode_cycle_shape: an unknown direction byte is rejected" {
    var fbs = std.io.fixedBufferStream(&[_]u8{9});
    try std.testing.expectError(DecodeError.InvalidCycleDir, decode_cycle_shape(fbs.reader()));
}

test "round-trip: cast carries no payload" {
    // What fires is whatever the server has selected, so the message is a bare
    // tag — a client cannot name a move, only ask to fire the one it holds.
    var buf: [8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .cast, {});
    try std.testing.expectEqual(@as(usize, 1), fbs.pos);
    fbs.reset();
    try std.testing.expectEqual(MsgTag.cast, try read_tag(fbs.reader()));
}

test "retired combo tags no longer decode" {
    // 0x08 was cancel_combo and 0x16 was cast_committed.  Both are gone: there
    // is no half-typed combo to cancel and no cast that waits for a partner.
    for ([_]u8{ 0x08, 0x16 }) |byte| {
        var fbs = std.io.fixedBufferStream(&[_]u8{byte});
        try std.testing.expectError(DecodeError.UnknownTag, read_tag(fbs.reader()));
    }
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
    // The single grid cell sits just before the tail: the u32 reservoir and
    // the pending-cast count, which is 0 here so no entries follow it.
    const tail = @sizeOf(u32) + 1;
    written[written.len - tail - 1] = 0x7F;
    fbs.reset();
    _ = try read_tag(fbs.reader());
    try std.testing.expectError(DecodeError.InvalidSlimeCell, decode_game_state(fbs.reader()));
}

test "round-trip: turn_ended carries the feast and what walled it off" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .turn_ended, TurnEnded{
        .turn = 7,
        .cells_eaten = 41,
        .hunger_added = 41,
        .sheltered = 12,
        .walls = 7,
        .score_added = 41,
        .charges_left = 18,
    });
    fbs.reset();
    try std.testing.expectEqual(MsgTag.turn_ended, try read_tag(fbs.reader()));
    const decoded = try decode_turn_ended(fbs.reader());
    try std.testing.expectEqual(@as(u16, 7), decoded.turn);
    try std.testing.expectEqual(@as(u16, 41), decoded.cells_eaten);
    try std.testing.expectEqual(@as(u16, 41), decoded.hunger_added);
    try std.testing.expectEqual(@as(u16, 12), decoded.sheltered);
    try std.testing.expectEqual(@as(u16, 7), decoded.walls);
    try std.testing.expectEqual(@as(u32, 41), decoded.score_added);
    try std.testing.expectEqual(@as(u32, 18), decoded.charges_left);
}

test "decode_game_state: oversized grid dimensions are rejected" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var gs = GameState.blank;
    gs.grid_rows = 1;
    gs.grid_cols = 1;
    try encode(fbs.writer(), .game_state, gs);
    const written = fbs.getWritten();
    // grid_rows sits right after score: tick(4) turn(2) entity_count(1)
    // hunger(4) charges(4) score(4) = offset 19 after the tag byte.
    written[1 + 19] = components.MAX_GRID_ROWS + 1;
    fbs.reset();
    _ = try read_tag(fbs.reader());
    try std.testing.expectError(DecodeError.InvalidGridDims, decode_game_state(fbs.reader()));
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
    try std.testing.expectEqual(@as(u16, 0), decoded.turn);
}

test "round-trip: over_budget carries the quote and the pool" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .over_budget, OverBudget{ .needed = 11, .have = 4 });
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.over_budget, tag);
    const decoded = try decode_over_budget(fbs.reader());
    try std.testing.expectEqual(@as(u32, 11), decoded.needed);
    try std.testing.expectEqual(@as(u32, 4), decoded.have);
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

test "round-trip: action_result damage (the feast) tag" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    // The feast is pool-level: no actor, no target, just the hunger it cost.
    const ar = ActionResult{
        .tag = .damage,
        .actor_entity = std.math.maxInt(u32),
        .target_entity = std.math.maxInt(u32),
        .value = 9,
    };
    try encode(fbs.writer(), .action_result, ar);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_action_result(fbs.reader());

    try std.testing.expectEqual(ActionResultTag.damage, decoded.tag);
    try std.testing.expectEqual(@as(u16, 9), decoded.value);
}

test "shape_cast round-trips its footprint and outcome" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var sc = ShapeCast{ .caster = 3, .anchor = 17, .cell_count = 4 };
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
    try std.testing.expectEqual(@as(u16, 17), got.anchor);
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
    const sc = ShapeCast{ .caster = 1, .anchor = 42, .cell_count = 0, .off_grid = 9 };
    try encode(fbs.writer(), .shape_cast, sc);

    var rfbs = std.io.fixedBufferStream(fbs.getWritten());
    const r = rfbs.reader();
    _ = try read_tag(r);
    const got = try decode_shape_cast(r);
    try std.testing.expectEqual(@as(u16, 0), got.cell_count);
    try std.testing.expectEqual(@as(u16, 9), got.off_grid);
    // The square aimed at survives even when nothing landed on it — which is
    // exactly the case `cells` could never carry.
    try std.testing.expectEqual(@as(u16, 42), got.anchor);
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
