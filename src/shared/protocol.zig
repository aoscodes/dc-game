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
    // 0x0b was cancel_cast: retired with the turn loop — a realtime cast
    // resolves the moment it is pressed, so there is nothing pending to take
    // back.
    // 0x10 was lobby_update.
    game_start = 0x11,
    game_state = 0x12,
    action_result = 0x13,
    game_over = 0x15,
    over_budget = 0x19,
    cast_refused = 0x1a,
    recipe_fired = 0x18,
    shape_cast = 0x1c,
    // 0x1d was turn_ended: retired with the turn loop — the same settle now
    // arrives as bite_settled (0x21), on the bite clock instead of at a
    // turn's end.
    /// A run of matchable specials lined up and fired: the matched cells
    /// popped and the kind's effect landed.  One message per match, broadcast
    /// before `bite_settled` so clients animate the reaction on the settled
    /// field they are about to summarize.  Tagged with the settle PASS it
    /// fired in (see field_refilled): a match re-opens the feast, so a bite
    /// settles in passes and the client replays them in order.
    special_matched = 0x1e,
    /// The feast ate one or more eggs: a baby hatched per entry.  Broadcast
    /// before `bite_settled`; carries cells + rolled types so every client
    /// hatches identical babies in identical places.  Aggregated over every
    /// pass of the bite's settle.
    eggs_hatched = 0x1f,
    /// One settle pass's reservoir refill: which cells filled and with what.
    /// The draw comes out of the session's PRNG, so this is the ONE part of
    /// a settle a client cannot derive — and with it, a client can replay a
    /// whole cascading settle exactly (bite, shift and match effects are
    /// all mirrored rules).  One message per pass, in pass order, before
    /// `bite_settled`.
    field_refilled = 0x20,
    bite_settled = 0x21,
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
    /// The babies banked on the joining player's board, per BabyType — they
    /// join the encounter with their owner (and leave with them), each adding
    /// balance.baby_hunger to the bar's capacity.  All zero for boardless
    /// players.
    babies: components.BabyCounts = [_]u32{0} ** components.BabyType.size,
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

/// A cast was refused because it would cost more than the shared pool holds.
///
/// Sent only to the player who tried it: nobody else did anything and nothing
/// landed.  The two numbers are the whole explanation, so the client can say
/// what it would have cost and what is actually left without deriving either.
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

/// Why a cast was turned away.  An enum rather than a bare message so the
/// next reason to refuse extends this instead of burning another opcode —
/// and so a client must handle the reasons exhaustively.
///
/// `over_budget` stays its own message: it carries the two numbers that
/// explain it, and a refusal with no numbers has nothing to say.
pub const CastRefusal = enum(u8) {
    /// The Lil Guys are still chewing (see balance.settle_lockout_ms).  The
    /// board is mid-settle and not the player's to write on yet.
    settling = 0,
};

/// A cast was refused for a reason with no numbers attached.
///
/// Sent only to the player who tried it, and deliberately NOT silent: unlike
/// the per-player cast cooldown — which drops a press without comment because
/// the seat panel is already counting it down — a refusal here has no visible
/// countdown of its own, so the client is told and shakes the panel.
pub const CastRefused = struct {
    reason: CastRefusal,
};

pub fn decode_cast_refused(reader: anytype) !CastRefused {
    const byte = try reader.readByte();
    const reason = std.meta.intToEnum(CastRefusal, byte) catch
        return DecodeError.InvalidCastRefusal;
    return .{ .reason = reason };
}

/// The bite clock fired and the Lil Guys have bitten the front columns of
/// the field.
///
/// Sent after the bite, the shift and the refill, so a client can animate
/// the devouring and float the resulting hunger/score without re-deriving any
/// of it.  This is the only place hunger and score move: casting never feeds
/// the Lil Guys, it only defuses what they are about to bite.
///
/// `hazards_bitten` is the message's most useful number for a player: every
/// one is a nibble that filled the hunger clock and scored nothing — the
/// front the team's casts failed to defuse in time.
pub const BiteSettled = struct {
    /// The bite that just settled (1-based); the next bite is this + 1.
    bite: u16,
    /// Slime units eaten off the grid.
    cells_eaten: u16,
    /// Total hunger added by the feast.
    hunger_added: u16,
    /// Live hazards the bite NIBBLED — downgraded one tier in place, hunger
    /// for no score.
    hazards_bitten: u16,
    /// Score added by the feast.
    score_added: u32,
    /// Charges left in the shared pool after the bite.  Sent here as well as
    /// in GameState so the settle summary is self-contained.
    charges_left: u32,
    /// Settle passes this bite took (>= 1).  Every special match re-opens the
    /// feast, so a bite is a CASCADE of bite/shift/fill passes; the summary
    /// numbers above are totals over all of them, and the per-pass events
    /// (field_refilled, special_matched) preceded this message.
    passes: u8 = 1,
};

pub fn decode_bite_settled(reader: anytype) !BiteSettled {
    return .{
        .bite = try reader.readInt(u16, .little),
        .cells_eaten = try reader.readInt(u16, .little),
        .hunger_added = try reader.readInt(u16, .little),
        .hazards_bitten = try reader.readInt(u16, .little),
        .score_added = try reader.readInt(u32, .little),
        .charges_left = try reader.readInt(u32, .little),
        .passes = try reader.readByte(),
    };
}

/// Wire cap on one matched run's cell list: a run lives in a single row or
/// column, so the grid's longest possible line bounds it.
pub const MAX_MATCH_CELLS_WIRE: u8 =
    @max(components.MAX_GRID_ROWS, components.MAX_GRID_COLS);

/// One special-kind match, resolved server-side and broadcast so every client
/// can pop the same cells and flash the same effect.  Cells travel absolute
/// (already resolved), like ShapeCast's, so clients never re-derive the run.
pub const SpecialMatched = struct {
    kind: components.SpecialKind,
    /// Which settle pass this match fired in (0-based; see field_refilled).
    /// Matches re-open the feast, so the client replays passes in order and
    /// this is how it knows which meal the reaction belongs to.
    pass: u8 = 0,
    /// The run's central cell — where the effect landed.
    center: u16 = 0,
    /// The popped cells, in line order.
    cell_count: u8 = 0,
    cells: [MAX_MATCH_CELLS_WIRE]u16 = [_]u16{0} ** MAX_MATCH_CELLS_WIRE,
    /// What the effect downgraded, per tier it was AT (neutralize_block).
    downgraded: [components.Tier.size]u16 = [_]u16{0} ** components.Tier.size,
    /// Of those, cells taken all the way to defused.
    neutralized: u16 = 0,
    /// Rocks the effect BROKE into red slime (see slime.ShapeOutcome).
    rocks_broken: u16 = 0,
};

pub fn decode_special_matched(reader: anytype) !SpecialMatched {
    const kind_byte = try reader.readByte();
    var p = SpecialMatched{
        .kind = std.meta.intToEnum(components.SpecialKind, kind_byte) catch
            return DecodeError.InvalidSpecialKind,
    };
    p.pass = try reader.readByte();
    p.center = try reader.readInt(u16, .little);
    p.cell_count = try reader.readByte();
    if (p.cell_count > MAX_MATCH_CELLS_WIRE) return DecodeError.TooManyMatchCells;
    for (p.cells[0..p.cell_count]) |*cell| cell.* = try reader.readInt(u16, .little);
    p.downgraded = try decode_u16_tiers(reader);
    p.neutralized = try reader.readInt(u16, .little);
    p.rocks_broken = try reader.readInt(u16, .little);
    return p;
}

/// Wire cap on hatches in one feast: every egg occupies a grid cell, so the
/// grid bounds how many can be eaten at once.
pub const MAX_HATCHES_WIRE: u16 = components.MAX_GRID_CELLS;

/// The turn's hatches: where each eaten egg sat and what type of baby came
/// out.  Types are rolled server-side (uniform, from the session's seed) so
/// every client — and every board banking them at game_over — agrees.
pub const EggsHatched = struct {
    count: u16 = 0,
    cells: [MAX_HATCHES_WIRE]u16 = [_]u16{0} ** MAX_HATCHES_WIRE,
    types: [MAX_HATCHES_WIRE]components.BabyType =
        [_]components.BabyType{.rose} ** MAX_HATCHES_WIRE,
};

pub fn decode_eggs_hatched(reader: anytype) !EggsHatched {
    var p = EggsHatched{};
    p.count = try reader.readInt(u16, .little);
    if (p.count > MAX_HATCHES_WIRE) return DecodeError.TooManyHatches;
    for (p.cells[0..p.count]) |*cell| cell.* = try reader.readInt(u16, .little);
    for (p.types[0..p.count]) |*t| {
        t.* = std.meta.intToEnum(components.BabyType, try reader.readByte()) catch
            return DecodeError.InvalidBabyType;
    }
    return p;
}

/// Wire cap on one refill: a fill can at most cover the grid.
pub const MAX_REFILL_WIRE: u16 = components.MAX_GRID_CELLS;

/// One settle pass's reservoir refill, resolved server-side.  `cells[i]` was
/// filled with `contents[i]`.  Cells travel in ascending flat (row-major)
/// order — NOT the fill's own right-to-left draw order — and contents use
/// the same one-byte encoding as the grid, so a client can apply the refill
/// to its replay board verbatim.
pub const FieldRefilled = struct {
    /// Which settle pass this refill belongs to (0-based).  A turn settles in
    /// passes while special matches keep re-opening the feast; every pass
    /// fills, so a turn broadcasts `passes` of these, in order.
    pass: u8 = 0,
    count: u16 = 0,
    cells: [MAX_REFILL_WIRE]u16 = [_]u16{0} ** MAX_REFILL_WIRE,
    contents: [MAX_REFILL_WIRE]components.SlimeCell =
        [_]components.SlimeCell{.empty} ** MAX_REFILL_WIRE,
};

pub fn decode_field_refilled(reader: anytype) !FieldRefilled {
    var p = FieldRefilled{};
    p.pass = try reader.readByte();
    p.count = try reader.readInt(u16, .little);
    if (p.count > MAX_REFILL_WIRE) return DecodeError.TooManyRefills;
    for (p.cells[0..p.count]) |*cell| cell.* = try reader.readInt(u16, .little);
    for (p.contents[0..p.count]) |*c| c.* = try decode_slime_cell(try reader.readByte());
    return p;
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
/// counts how many of those landed on defused; `rocks_broken` counts rocks
/// the Agent cracked into red (accomplishment, not waste — a rock has no
/// tier, so it travels apart from `downgraded`).  `off_grid` (clipped by the
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
    rocks_broken: u16 = 0,
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
    p.rocks_broken = try reader.readInt(u16, .little);
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
    /// Ms a player waits between casts (balance.cast_cooldown_ms).  Sent once
    /// at start because it never changes mid-encounter.
    cast_cooldown_ms: u32 = 0,
    /// Ms window in which a team recipe's component casts must land
    /// (balance.team_window_ms).  Sent once at start, like the cooldown.
    team_window_ms: u32 = 0,
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
    /// Ms until this player may cast again; 0 = ready now.  Server-owned so
    /// every client draws the same cooldown, the owner's and teammates' alike.
    cooldown_ms: u32,
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
    /// The babies this player's board brought to the encounter, per BabyType
    /// (from take_slot).  Snapshotted so every client renders every player's
    /// babies — and a reconnect recovers them.
    babies: components.BabyCounts,

    pub const blank = EntitySnapshot{
        .entity = 0,
        .kind = .player,
        .owner = 0xFF,
        .cooldown_ms = 0,
        .selected_shape = 0,
        .cursor_row = 0,
        .cursor_col = 0,
        .babies = [_]u32{0} ** components.BabyType.size,
    };
};

pub const MAX_ENTITIES_WIRE: u16 = 64;

/// Cap on the recent-cast list carried in a `GameState`.  Matches
/// `game_logic.MAX_RECENT`; it is restated here because protocol.zig knows
/// nothing of the game's resolution logic.
pub const MAX_RECENT_WIRE: u16 = 64;

/// One cast that LANDED recently — still inside the team-recipe window, so a
/// teammate's matching cast on the same square could complete a group with it.
///
/// Sent to everyone: the whole team needs to see which squares are ripe to
/// decide where to aim, and the client previews group potential from this
/// list plus the viewer's own live aim.  Everything here has already been
/// charged and stamped; what remains is only its power to coordinate.
pub const RecentCastWire = struct {
    player_id: u8,
    /// Index into balance.player_recipes — the move that was cast.
    move: u8,
    /// Flat grid index it landed on.
    square: u16,
    /// Ms since it landed.  The entry expires from the window when this
    /// reaches the game_start's team_window_ms.
    age_ms: u32,
};

pub const BarSummary = struct {
    current: u16,
    max: u16,
};

pub const GameState = struct {
    tick: u32,
    /// The bite now being chewed toward (1-based): how many times the Lil
    /// Guys have settled, plus one.
    bite: u16,
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
    /// needs this AND the grid to hold nothing but inconsumable specials.
    reservoir: u32,
    /// Babies hatched so far THIS encounter, per BabyType.  Session-owned (a
    /// hatched baby belongs to no player), so it travels beside the other
    /// session totals and a reconnect recovers the brood.
    hatched: [components.BabyType.size]u16,
    /// Ms until the Lil Guys bite again — the countdown clients draw.
    next_bite_ms: u32,
    /// Ms left in the post-bite settle window, during which NO player may
    /// cast (see balance.settle_lockout_ms).  0 when casting is open.
    ///
    /// Table-wide, not per-player: unlike the per-seat `cooldown_ms` on an
    /// EntitySnapshot, one number covers everyone, so every seat panel counts
    /// the same window down together.  Sent rather than derived because the
    /// client's chew animation only APPROXIMATES the window — the server owns
    /// when casting reopens.
    cast_locked_ms: u32,
    /// Casts still inside the team-recipe window, in landing order.
    recent_count: u8,
    recent: [MAX_RECENT_WIRE]RecentCastWire,

    pub const blank = GameState{
        .tick = 0,
        .bite = 0,
        .entity_count = 0,
        .entities = [_]EntitySnapshot{EntitySnapshot.blank} ** MAX_ENTITIES_WIRE,
        .hunger = .{ .current = 0, .max = 0 },
        .charges = 0,
        .score = 0,
        .grid_rows = 0,
        .grid_cols = 0,
        .grid = [_]components.SlimeCell{.empty} ** components.MAX_GRID_CELLS,
        .reservoir = 0,
        .hatched = [_]u16{0} ** components.BabyType.size,
        .next_bite_ms = 0,
        .cast_locked_ms = 0,
        .recent_count = 0,
        .recent = [_]RecentCastWire{
            .{ .player_id = 0, .move = 0, .square = 0, .age_ms = 0 },
        } ** MAX_RECENT_WIRE,
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
    /// The hunger bar — the game's clock — filled: the Lil Guys are sated
    /// and the encounter ends on whatever the team scored.  Not a defeat.
    hunger_full = 0,
    /// Everything was eaten — grid and reservoir empty.  Nothing is exempt:
    /// even a rock is clearable (the Agent breaks it into red slime).
    field_cleared = 1,
    // 2 was out_of_charges: retired — a broke team keeps playing on the
    // bite's nibbles (cast presses become passes), so the pool running dry
    // no longer ends anything.
};

/// Match-wide consumption/dispense tallies for the tuning report.  There are
/// no rounds any more, so this accumulates over the whole encounter.
pub const FeastStats = struct {
    /// Cells covered by cast shapes, per tier they were standing at.
    cells_covered: [components.Tier.size]u16 = [_]u16{0} ** components.Tier.size,
    /// Cells taken all the way to defused, per tier they STARTED at.
    neutralized: [components.Tier.size]u16 = [_]u16{0} ** components.Tier.size,
    /// Live hazards the bites NIBBLED, summed over every turn — the headline
    /// tuning number, since every nibble is hunger-clock spent on a cell the
    /// team's charges failed to defuse in time.
    hazards_bitten: u32 = 0,
    /// Rocks BROKEN into red slime over the encounter — Agent spent on
    /// boulders, by cast and by swallowed neutralizer alike.  The rock
    /// tuning number: high here means the field was more quarry than meal.
    rocks_broken: u32 = 0,
    neutral_consumed: u16 = 0,
    defused_consumed: u16 = 0,
    /// Neutralizers the feasts swallowed — free equipment, not food, so they
    /// appear here and never in the score.  With them the ledger closes:
    /// slime_total = score + slime_left + agents_consumed.
    agents_consumed: u16 = 0,
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
    /// Babies hatched over the whole encounter, per BabyType.  Every board
    /// that COMPLETES the encounter (receives game_over) banks these into its
    /// flash — each hatched baby is saved to every connected board.
    eggs_hatched: [components.BabyType.size]u16 =
        [_]u16{0} ** components.BabyType.size,
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
        .take_slot => {
            try writer.writeInt(u32, payload.appetite, .little);
            for (payload.babies) |b| try writer.writeInt(u32, b, .little);
        },
        .leave_slot => {},
        .restart => {},
        .cycle_shape => try writer.writeByte(@intFromEnum(payload.dir)),
        .cast => {},
        .over_budget => {
            try writer.writeInt(u32, payload.needed, .little);
            try writer.writeInt(u32, payload.have, .little);
        },
        .cast_refused => try writer.writeByte(@intFromEnum(payload.reason)),
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
            try writer.writeInt(u16, p.rocks_broken, .little);
        },
        .recipe_fired => {
            try writer.writeByte(@intFromEnum(payload.kind));
            try writer.writeByte(payload.index);
        },
        .bite_settled => {
            const p: BiteSettled = payload;
            try writer.writeInt(u16, p.bite, .little);
            try writer.writeInt(u16, p.cells_eaten, .little);
            try writer.writeInt(u16, p.hunger_added, .little);
            try writer.writeInt(u16, p.hazards_bitten, .little);
            try writer.writeInt(u32, p.score_added, .little);
            try writer.writeInt(u32, p.charges_left, .little);
            try writer.writeByte(p.passes);
        },
        .special_matched => {
            const p: SpecialMatched = payload;
            try writer.writeByte(@intFromEnum(p.kind));
            try writer.writeByte(p.pass);
            try writer.writeInt(u16, p.center, .little);
            try writer.writeByte(p.cell_count);
            for (p.cells[0..p.cell_count]) |cell| try writer.writeInt(u16, cell, .little);
            try encode_u16_tiers(writer, p.downgraded);
            try writer.writeInt(u16, p.neutralized, .little);
            try writer.writeInt(u16, p.rocks_broken, .little);
        },
        .eggs_hatched => {
            const p: EggsHatched = payload;
            try writer.writeInt(u16, p.count, .little);
            for (p.cells[0..p.count]) |cell| try writer.writeInt(u16, cell, .little);
            for (p.types[0..p.count]) |t| try writer.writeByte(@intFromEnum(t));
        },
        .field_refilled => {
            const p: FieldRefilled = payload;
            try writer.writeByte(p.pass);
            try writer.writeInt(u16, p.count, .little);
            for (p.cells[0..p.count]) |cell| try writer.writeInt(u16, cell, .little);
            for (p.contents[0..p.count]) |c| try writer.writeByte(encode_slime_cell(c));
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
    try w.writeInt(u32, p.cast_cooldown_ms, .little);
    try w.writeInt(u32, p.team_window_ms, .little);
    try w.writeInt(u32, p.charges, .little);
    try w.writeByte(p.grid_rows);
    try w.writeByte(p.grid_cols);
}

fn encode_bar_summary(w: anytype, s: BarSummary) !void {
    try w.writeInt(u16, s.current, .little);
    try w.writeInt(u16, s.max, .little);
}

/// One slime cell as a single byte: 0x00 empty, 0x01 neutral,
/// 0x02 neutralized, 0x10|t tiered, 0x20|k special of kind k (see
/// components.SlimeCell).  0x03 was the old kindless special; retired, so a
/// stale sender fails loudly rather than rendering the wrong kind.
fn encode_slime_cell(cell: components.SlimeCell) u8 {
    return switch (cell) {
        .empty => 0x00,
        .neutral => 0x01,
        .neutralized => 0x02,
        .tiered => |t| 0x10 | @intFromEnum(t),
        .special => |k| 0x20 | @intFromEnum(k),
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
        0x20 => .{
            .special = std.meta.intToEnum(components.SpecialKind, byte & 0x0F) catch
                return DecodeError.InvalidSpecialKind,
        },
        else => DecodeError.InvalidSlimeCell,
    };
}

fn encode_game_state(w: anytype, p: GameState) !void {
    try w.writeInt(u32, p.tick, .little);
    try w.writeInt(u16, p.bite, .little);
    try w.writeByte(p.entity_count);
    var i: u8 = 0;
    while (i < p.entity_count) : (i += 1) {
        const e = p.entities[i];
        try w.writeInt(u32, e.entity, .little);
        try w.writeByte(@intFromEnum(e.kind));
        try w.writeByte(e.owner);
        try w.writeInt(u32, e.cooldown_ms, .little);
        try w.writeByte(e.selected_shape);
        try w.writeByte(e.cursor_row);
        try w.writeByte(e.cursor_col);
        for (e.babies) |b| try w.writeInt(u32, b, .little);
    }
    try encode_bar_summary(w, p.hunger);
    try w.writeInt(u32, p.charges, .little);
    try w.writeInt(u32, p.score, .little);
    try w.writeByte(p.grid_rows);
    try w.writeByte(p.grid_cols);
    for (p.grid[0..p.grid_len()]) |cell| try w.writeByte(encode_slime_cell(cell));
    try w.writeInt(u32, p.reservoir, .little);
    for (p.hatched) |h| try w.writeInt(u16, h, .little);
    try w.writeInt(u32, p.next_bite_ms, .little);
    try w.writeInt(u32, p.cast_locked_ms, .little);
    try w.writeByte(p.recent_count);
    for (p.recent[0..p.recent_count]) |rc| {
        try w.writeByte(rc.player_id);
        try w.writeByte(rc.move);
        try w.writeInt(u16, rc.square, .little);
        try w.writeInt(u32, rc.age_ms, .little);
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
    try w.writeInt(u32, rs.hazards_bitten, .little);
    try w.writeInt(u16, rs.neutral_consumed, .little);
    try w.writeInt(u16, rs.defused_consumed, .little);
    try w.writeInt(u16, rs.agents_consumed, .little);
    try w.writeInt(u16, rs.hunger_normal, .little);
    try w.writeInt(u32, rs.charges_spent, .little);
    try w.writeInt(u32, rs.charges_left, .little);
    try w.writeInt(u32, rs.rocks_broken, .little);
}

fn decode_feast_stats(r: anytype) !FeastStats {
    return .{
        .cells_covered = try decode_u16_tiers(r),
        .neutralized = try decode_u16_tiers(r),
        .hazards_bitten = try r.readInt(u32, .little),
        .neutral_consumed = try r.readInt(u16, .little),
        .defused_consumed = try r.readInt(u16, .little),
        .agents_consumed = try r.readInt(u16, .little),
        .hunger_normal = try r.readInt(u16, .little),
        .charges_spent = try r.readInt(u32, .little),
        .charges_left = try r.readInt(u32, .little),
        .rocks_broken = try r.readInt(u32, .little),
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
    for (ms.eggs_hatched) |h| try w.writeInt(u16, h, .little);
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
    for (&ms.eggs_hatched) |*h| h.* = try r.readInt(u16, .little);
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
    TooManyRecent,
    InvalidEndReason,
    TooManyRecipes,
    InvalidRecipeKind,
    InvalidSlimeCell,
    InvalidGridDims,
    InvalidSpecialKind,
    InvalidBabyType,
    TooManyMatchCells,
    TooManyHatches,
    TooManyRefills,
    InvalidCastRefusal,
};

pub fn read_tag(reader: anytype) !MsgTag {
    const byte = try reader.readByte();
    return std.meta.intToEnum(MsgTag, byte) catch return DecodeError.UnknownTag;
}

pub fn decode_take_slot(reader: anytype) !TakeSlot {
    var p = TakeSlot{ .appetite = try reader.readInt(u32, .little) };
    for (&p.babies) |*b| b.* = try reader.readInt(u32, .little);
    return p;
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
    p.cast_cooldown_ms = try reader.readInt(u32, .little);
    p.team_window_ms = try reader.readInt(u32, .little);
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
    p.bite = try reader.readInt(u16, .little);
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
        e.cooldown_ms = try reader.readInt(u32, .little);
        // Not range-checked against the move table: protocol.zig does not see
        // the loaded balance.  The server only ever sends a valid index, and a
        // client that receives a stale one clamps at render time.
        e.selected_shape = try reader.readByte();
        e.cursor_row = try reader.readByte();
        e.cursor_col = try reader.readByte();
        for (&e.babies) |*b| b.* = try reader.readInt(u32, .little);
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
    for (&p.hatched) |*h| h.* = try reader.readInt(u16, .little);
    p.next_bite_ms = try reader.readInt(u32, .little);
    p.cast_locked_ms = try reader.readInt(u32, .little);
    p.recent_count = try reader.readByte();
    if (p.recent_count > MAX_RECENT_WIRE) return DecodeError.TooManyRecent;
    p.recent = [_]RecentCastWire{
        .{ .player_id = 0, .move = 0, .square = 0, .age_ms = 0 },
    } ** MAX_RECENT_WIRE;
    for (p.recent[0..p.recent_count]) |*rc| {
        rc.player_id = try reader.readByte();
        rc.move = try reader.readByte();
        rc.square = try reader.readInt(u16, .little);
        rc.age_ms = try reader.readInt(u32, .little);
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

test "read_tag: retired turn-era tags are UnknownTag" {
    // 0x0b cancel_cast (nothing is pending in realtime, so nothing can be
    // taken back) and 0x1d turn_ended (the settle now arrives as
    // bite_settled): both retired with the turn loop, so a stale sender
    // fails loudly rather than replaying the wrong shape of game.
    for ([_]u8{ 0x0b, 0x1d }) |byte| {
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
        .hazards_bitten = 21,
        .neutral_consumed = 15,
        .defused_consumed = 9,
        .agents_consumed = 2,
        .hunger_normal = 38,
        .charges_spent = 27,
        .charges_left = 13,
        .rocks_broken = 6,
    };
    go.stats.player_count = 2;
    go.stats.players[0] = .{ .casts = 3, .cells_covered = 27, .cells_neutralized = 6, .recipe_casts = 2 };
    go.stats.players[1] = .{ .casts = 2, .cells_covered = 4 };
    go.stats.player_recipe_count = 6;
    go.stats.team_recipe_count = 2;
    go.stats.player_recipe_hits[0] = 1;
    go.stats.team_recipe_hits[0] = 2;
    go.stats.casts_total = 5;
    go.stats.eggs_hatched = .{ 3, 0, 0, 1, 0 };

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
    try std.testing.expectEqual(@as(u32, 21), d.stats.feast.hazards_bitten);
    try std.testing.expectEqual(@as(u16, 15), d.stats.feast.neutral_consumed);
    try std.testing.expectEqual(@as(u16, 9), d.stats.feast.defused_consumed);
    try std.testing.expectEqual(@as(u16, 2), d.stats.feast.agents_consumed);
    try std.testing.expectEqual(@as(u32, 27), d.stats.feast.charges_spent);
    try std.testing.expectEqual(@as(u32, 13), d.stats.feast.charges_left);
    try std.testing.expectEqual(@as(u32, 6), d.stats.feast.rocks_broken);
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
    // The brood every completing board banks: per-type hatch counts.
    try std.testing.expectEqual([_]u16{ 3, 0, 0, 1, 0 }, d.stats.eggs_hatched);
}

test "round-trip: take_slot carries the appetite stat and the board's babies" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try encode(fbs.writer(), .take_slot, TakeSlot{
        .appetite = 17,
        .babies = .{ 1, 0, 2, 0, 5 },
    });
    fbs.reset();
    try std.testing.expectEqual(MsgTag.take_slot, try read_tag(fbs.reader()));
    const decoded = try decode_take_slot(fbs.reader());
    try std.testing.expectEqual(@as(u32, 17), decoded.appetite);
    try std.testing.expectEqual([_]u32{ 1, 0, 2, 0, 5 }, decoded.babies);
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

test "round-trip: game_state — bite, hunger, score, grid, and selection survive" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState.blank;
    gs.tick = 42;
    gs.bite = 3;
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
    gs.grid[3] = .{ .special = .neutralizer };
    gs.grid[4] = .{ .tiered = .green };
    gs.grid[5] = .neutralized;
    gs.grid[6] = .{ .tiered = .yellow };
    gs.grid[7] = .{ .special = .egg };
    gs.reservoir = 44;
    gs.hatched = .{ 2, 0, 1, 0, 0 };
    gs.next_bite_ms = 1234;
    gs.cast_locked_ms = 777;
    gs.recent_count = 1;
    gs.recent[0] = .{ .player_id = 1, .move = 2, .square = 5, .age_ms = 250 };
    gs.entities[0] = EntitySnapshot{
        .entity = 7,
        .kind = .player,
        .owner = 0,
        .cooldown_ms = 450,
        .selected_shape = 4,
        .cursor_row = 2,
        .cursor_col = 5,
        .babies = .{ 0, 4, 0, 0, 1 },
    };

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.game_state, tag);
    const decoded = try decode_game_state(fbs.reader());

    try std.testing.expectEqual(@as(u32, 42), decoded.tick);
    try std.testing.expectEqual(@as(u16, 3), decoded.bite);
    try std.testing.expectEqual(@as(u8, 1), decoded.entity_count);
    try std.testing.expectEqual(@as(u32, 450), decoded.entities[0].cooldown_ms);
    // The bite countdown, the settle window and the group window all travel
    // with every snapshot.
    try std.testing.expectEqual(@as(u32, 1234), decoded.next_bite_ms);
    try std.testing.expectEqual(@as(u32, 777), decoded.cast_locked_ms);
    try std.testing.expectEqual(@as(u8, 1), decoded.recent_count);
    try std.testing.expectEqual(@as(u8, 1), decoded.recent[0].player_id);
    try std.testing.expectEqual(@as(u8, 2), decoded.recent[0].move);
    try std.testing.expectEqual(@as(u16, 5), decoded.recent[0].square);
    try std.testing.expectEqual(@as(u32, 250), decoded.recent[0].age_ms);
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
    try std.testing.expectEqual([_]u16{ 2, 0, 1, 0, 0 }, decoded.hatched);
    // The move this player would fire travels with them, so teammates can see
    // it before anyone spends a cast.
    try std.testing.expectEqual(@as(u8, 4), decoded.entities[0].selected_shape);
    // The aiming cursor travels with the rest of the player's state.
    try std.testing.expectEqual(@as(u8, 2), decoded.entities[0].cursor_row);
    try std.testing.expectEqual(@as(u8, 5), decoded.entities[0].cursor_col);
    // The board's babies travel with their owner.
    try std.testing.expectEqual([_]u32{ 0, 4, 0, 0, 1 }, decoded.entities[0].babies);
}

test "round-trip: game_start — join code, grid dims and realtime pacing survive" {
    var buf: [80]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const label = "slime_feast_01";
    var gs = GameStart{
        .encounter_label = [_]u8{0} ** 32,
        .encounter_label_len = @intCast(label.len),
        .player_id = 3,
        .join_code = "ABCDEF".*,
        .prematch = true,
        .cast_cooldown_ms = 750,
        .team_window_ms = 3000,
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
    try std.testing.expectEqual(@as(u32, 750), decoded.cast_cooldown_ms);
    try std.testing.expectEqual(@as(u32, 3000), decoded.team_window_ms);
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
    // Cycle through all 8 distinct cell values so every encoding is covered.
    const kinds = [_]components.SlimeCell{
        .empty,
        .neutral,
        .neutralized,
        .{ .tiered = .red },
        .{ .tiered = .yellow },
        .{ .tiered = .green },
        .{ .special = .neutralizer },
        .{ .special = .egg },
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

/// Bytes a `game_state` frame writes AFTER the grid, for a snapshot with no
/// recent casts: the u32 reservoir, the per-type hatched u16s, the u32 bite
/// countdown, the u32 settle window, and the recent-cast count itself.
///
/// The corruption tests below reach backwards past this to land on the last
/// grid cell, so a new tail field must be added here or they poke the wrong
/// byte and stop testing what they claim to.
const GAME_STATE_TAIL_BYTES = @sizeOf(u32) + 2 * components.BabyType.size +
    @sizeOf(u32) + @sizeOf(u32) + 1;

test "decode_game_state: an unknown slime cell byte is rejected" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var gs = GameState.blank;
    gs.grid_rows = 1;
    gs.grid_cols = 1;
    try encode(fbs.writer(), .game_state, gs);
    const written = fbs.getWritten();
    written[written.len - GAME_STATE_TAIL_BYTES - 1] = 0x7F;
    fbs.reset();
    _ = try read_tag(fbs.reader());
    try std.testing.expectError(DecodeError.InvalidSlimeCell, decode_game_state(fbs.reader()));
}

test "decode_game_state: the retired kindless special byte 0x03 is rejected" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var gs = GameState.blank;
    gs.grid_rows = 1;
    gs.grid_cols = 1;
    try encode(fbs.writer(), .game_state, gs);
    const written = fbs.getWritten();
    written[written.len - GAME_STATE_TAIL_BYTES - 1] = 0x03;
    fbs.reset();
    _ = try read_tag(fbs.reader());
    try std.testing.expectError(DecodeError.InvalidSlimeCell, decode_game_state(fbs.reader()));
}

test "round-trip: special_matched carries the run, its centre and its effect" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var sm = SpecialMatched{ .kind = .neutralizer, .pass = 2, .center = 22, .cell_count = 3 };
    sm.cells[0] = 21;
    sm.cells[1] = 22;
    sm.cells[2] = 23;
    sm.downgraded[@intFromEnum(components.Tier.red)] = 12;
    sm.neutralized = 4;
    sm.rocks_broken = 1;
    try encode(fbs.writer(), .special_matched, sm);
    fbs.reset();
    try std.testing.expectEqual(MsgTag.special_matched, try read_tag(fbs.reader()));
    const got = try decode_special_matched(fbs.reader());
    try std.testing.expectEqual(components.SpecialKind.neutralizer, got.kind);
    try std.testing.expectEqual(@as(u8, 2), got.pass);
    try std.testing.expectEqual(@as(u16, 22), got.center);
    try std.testing.expectEqual(@as(u8, 3), got.cell_count);
    try std.testing.expectEqualSlices(u16, sm.cells[0..3], got.cells[0..3]);
    try std.testing.expectEqual(@as(u16, 12), got.downgraded[@intFromEnum(components.Tier.red)]);
    try std.testing.expectEqual(@as(u16, 4), got.neutralized);
    try std.testing.expectEqual(@as(u16, 1), got.rocks_broken);
}

test "round-trip: eggs_hatched carries each hatch's cell and rolled type" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var eh = EggsHatched{ .count = 2 };
    eh.cells[0] = 5;
    eh.cells[1] = 40;
    eh.types[0] = .plum;
    eh.types[1] = .mint;
    try encode(fbs.writer(), .eggs_hatched, eh);
    fbs.reset();
    try std.testing.expectEqual(MsgTag.eggs_hatched, try read_tag(fbs.reader()));
    const got = try decode_eggs_hatched(fbs.reader());
    try std.testing.expectEqual(@as(u16, 2), got.count);
    try std.testing.expectEqual(@as(u16, 5), got.cells[0]);
    try std.testing.expectEqual(@as(u16, 40), got.cells[1]);
    try std.testing.expectEqual(components.BabyType.plum, got.types[0]);
    try std.testing.expectEqual(components.BabyType.mint, got.types[1]);
}

test "round-trip: field_refilled carries each cell and its contents, per pass" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var fr = FieldRefilled{ .pass = 1, .count = 3 };
    fr.cells[0] = 0;
    fr.cells[1] = 5;
    fr.cells[2] = 9;
    fr.contents[0] = .neutral;
    fr.contents[1] = .{ .tiered = .red };
    fr.contents[2] = .{ .special = .egg };
    try encode(fbs.writer(), .field_refilled, fr);
    fbs.reset();
    try std.testing.expectEqual(MsgTag.field_refilled, try read_tag(fbs.reader()));
    const got = try decode_field_refilled(fbs.reader());
    try std.testing.expectEqual(@as(u8, 1), got.pass);
    try std.testing.expectEqual(@as(u16, 3), got.count);
    try std.testing.expectEqualSlices(u16, fr.cells[0..3], got.cells[0..3]);
    try std.testing.expectEqualSlices(
        components.SlimeCell,
        fr.contents[0..3],
        got.contents[0..3],
    );
}

test "decode_field_refilled: a bad cell byte or oversize count is rejected" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var fr = FieldRefilled{ .pass = 0, .count = 1 };
    fr.cells[0] = 4;
    fr.contents[0] = .neutral;
    try encode(fbs.writer(), .field_refilled, fr);
    const written = fbs.getWritten();
    written[written.len - 1] = 0x7F; // the lone contents byte is the tail
    fbs.reset();
    _ = try read_tag(fbs.reader());
    try std.testing.expectError(
        DecodeError.InvalidSlimeCell,
        decode_field_refilled(fbs.reader()),
    );

    var big: [8]u8 = .{ 0, 0xFF, 0xFF, 0, 0, 0, 0, 0 }; // pass 0, count 0xFFFF
    var bfbs = std.io.fixedBufferStream(big[0..]);
    try std.testing.expectError(
        DecodeError.TooManyRefills,
        decode_field_refilled(bfbs.reader()),
    );
}

test "decode_eggs_hatched: an unknown baby type is rejected" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var eh = EggsHatched{ .count = 1 };
    eh.cells[0] = 3;
    try encode(fbs.writer(), .eggs_hatched, eh);
    const written = fbs.getWritten();
    written[written.len - 1] = 0xEE; // the lone type byte is the tail
    fbs.reset();
    _ = try read_tag(fbs.reader());
    try std.testing.expectError(DecodeError.InvalidBabyType, decode_eggs_hatched(fbs.reader()));
}

test "round-trip: bite_settled carries the feast and what it nibbled" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .bite_settled, BiteSettled{
        .bite = 7,
        .cells_eaten = 41,
        .hunger_added = 53,
        .hazards_bitten = 12,
        .score_added = 41,
        .charges_left = 18,
        .passes = 3,
    });
    fbs.reset();
    try std.testing.expectEqual(MsgTag.bite_settled, try read_tag(fbs.reader()));
    const decoded = try decode_bite_settled(fbs.reader());
    try std.testing.expectEqual(@as(u16, 7), decoded.bite);
    try std.testing.expectEqual(@as(u16, 41), decoded.cells_eaten);
    try std.testing.expectEqual(@as(u16, 53), decoded.hunger_added);
    try std.testing.expectEqual(@as(u16, 12), decoded.hazards_bitten);
    try std.testing.expectEqual(@as(u32, 41), decoded.score_added);
    try std.testing.expectEqual(@as(u32, 18), decoded.charges_left);
    // A cascade bite: three settle passes preceded this summary.
    try std.testing.expectEqual(@as(u8, 3), decoded.passes);
}

test "decode_game_state: oversized grid dimensions are rejected" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var gs = GameState.blank;
    gs.grid_rows = 1;
    gs.grid_cols = 1;
    try encode(fbs.writer(), .game_state, gs);
    const written = fbs.getWritten();
    // grid_rows sits right after score: tick(4) bite(2) entity_count(1)
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
    try std.testing.expectEqual(@as(u16, 0), decoded.bite);
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

test "round-trip: cast_refused carries the reason" {
    var buf: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .cast_refused, CastRefused{ .reason = .settling });
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.cast_refused, tag);
    const decoded = try decode_cast_refused(fbs.reader());
    try std.testing.expectEqual(CastRefusal.settling, decoded.reason);
}

test "decode_cast_refused: an unknown reason is rejected, not guessed" {
    // A newer server refusing for a reason this build has no name for must
    // fail loudly.  Silently coercing to `settling` would have the client
    // blame the Lil Guys for a refusal they had nothing to do with.
    var fbs = std.io.fixedBufferStream(&[_]u8{0xEE});
    try std.testing.expectError(DecodeError.InvalidCastRefusal, decode_cast_refused(fbs.reader()));
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
    sc.rocks_broken = 2;
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
    // Wasted coverage travels explicitly, never inferred — and a broken
    // rock travels apart from both waste and the per-tier downgrades.
    try std.testing.expectEqual(@as(u16, 5), got.off_grid);
    try std.testing.expectEqual(@as(u16, 3), got.inert);
    try std.testing.expectEqual(@as(u16, 2), got.rocks_broken);
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
