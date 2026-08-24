const std = @import("std");
const proto = @import("shared").protocol;
const c = @import("shared").components;

pub const Writer = struct {
    mu: *std.Thread.Mutex,

    pub fn write_render(
        self: Writer,
        phase: ClientPhaseTag,
        game: *GameState,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();
        // Sized for the largest render frame: a MAX_GRID_CELLS grid of cell
        // strings plus the full entity/stats payload.
        var frame_buf: [32768]u8 = undefined;
        var w = std.io.Writer.fixed(&frame_buf);
        write_render_inner(&w, phase, game) catch return;
        w.writeByte('\n') catch return;
        const out = std.fs.File.stdout();
        out.writeAll(w.buffered()) catch return;
        game.last_action_count = 0;
        game.over_budget = null;
        game.recipe_count = 0;
        game.turn_ended = null;
        game.shape_cast_count = 0;
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

pub const ClientPhaseTag = enum { connecting, game, game_over };

pub const LastActionEntry = struct { entity: u32, anim: c.ActionAnimation };

pub const GameState = struct {
    snapshot: proto.GameState = proto.GameState.blank,
    /// The seat this connection holds, or NO_PLAYER while observing.
    player_id: u8 = proto.NO_PLAYER,
    /// The session's join code — the game id, from game_start.
    join_code: [6]u8 = [_]u8{'-'} ** 6,
    /// Casts each player gets per turn, as announced in game_start.  Constant
    /// for the whole encounter, so the renderer can draw a budget gauge.
    casts_per_turn: u8 = 0,
    encounter_label: [32]u8 = [_]u8{0} ** 32,
    encounter_label_len: u8 = 0,
    /// Final score from game_over (null until the encounter ends).
    final_score: ?u32 = null,
    /// Full tuning report from game_over (null until the encounter ends).
    final_stats: ?proto.MatchStats = null,
    last_action_count: u8 = 0,
    last_actions: [proto.MAX_ENTITIES_WIRE]LastActionEntry = undefined,
    /// The refusal this player's last cast earned, if it earned one since the
    /// last render write (transient, drained per frame like last_actions).
    /// At most one per frame: a refused cast changes nothing, so a second in
    /// the same frame would say the same thing about the same turn.
    over_budget: ?proto.OverBudget = null,
    /// Recipes fired since the last render write (transient).
    recipes_fired: [16]proto.RecipeFired = undefined,
    recipe_count: u8 = 0,
    /// The feast that settled the turn, if one settled since the last render
    /// write (transient).  At most one per frame: a turn cannot end twice
    /// without the frames in between being written.
    turn_ended: ?proto.TurnEnded = null,
    /// Shapes stamped since the last render write (transient): the resolved
    /// footprint of each landed cast, so the renderer can flash exactly the
    /// cells the server hit without re-deriving placement.
    shape_casts: [16]proto.ShapeCast = undefined,
    shape_cast_count: u8 = 0,
};

fn write_render_inner(
    w: *std.io.Writer,
    phase: ClientPhaseTag,
    game: *const GameState,
) !void {
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
        entities_buf[i] = .{
            .id = e.entity,
            .kind = e.kind,
            .owner = e.owner,
            .casts_left = e.casts_left,
            .last_action = anim,
            .selected_shape = e.selected_shape,
            .cursor_row = e.cursor_row,
            .cursor_col = e.cursor_col,
        };
    }

    // The turn as it stands: every cast locked in and still unresolved.
    var pending_buf: [proto.MAX_PENDING_WIRE]JsonPending = undefined;
    for (game.snapshot.pending[0..game.snapshot.pending_count], 0..) |pc, i| {
        pending_buf[i] = .{
            .player_id = pc.player_id,
            .move = pc.move,
            .square = pc.square,
        };
    }

    // Convert transient recipe-fired events for JSON.
    var recipes_buf: [16]JsonRecipeFired = undefined;
    for (game.recipes_fired[0..game.recipe_count], 0..) |rf, i| {
        recipes_buf[i] = .{ .kind = rf.kind, .index = rf.index };
    }

    // Convert transient shape stamps for JSON.  The cell list is passed
    // through verbatim: the server already clipped it to the grid, so the
    // renderer flashes exactly the cells that were hit.
    var shape_cast_buf: [16]JsonShapeCast = undefined;
    var cells_bufs: [16][proto.MAX_SHAPE_CELLS_WIRE]u16 = undefined;
    for (game.shape_casts[0..game.shape_cast_count], 0..) |sc, i| {
        @memcpy(cells_bufs[i][0..sc.cell_count], sc.cells[0..sc.cell_count]);
        shape_cast_buf[i] = .{
            .caster = sc.caster,
            .cells = cells_bufs[i][0..sc.cell_count],
            .downgraded = tiers(sc.downgraded),
            .neutralized = sc.neutralized,
            .off_grid = sc.off_grid,
            .inert = sc.inert,
        };
    }

    // Convert this frame's turn end (if any) for JSON.
    const turn_ended: ?JsonTurnEnded = if (game.turn_ended) |te| .{
        .turn = te.turn,
        .cells_eaten = te.cells_eaten,
        .hunger_added = te.hunger_added,
        .sheltered = te.sheltered,
        .walls = te.walls,
        .score_added = te.score_added,
        .charges_left = te.charges_left,
    } else null;

    // The slime grid as one compact string per cell (row-major, row 0 = top),
    // so JS can index it directly as grid[row * cols + col].
    var grid_buf: [c.MAX_GRID_CELLS][]const u8 = undefined;
    const grid_len = game.snapshot.grid_len();
    for (game.snapshot.grid[0..grid_len], 0..) |cell, i| {
        grid_buf[i] = cell_name(cell);
    }

    // Build the game-over tuning report (per-round + per-player + recipes).
    var pstats_buf: [proto.MAX_PLAYERS]JsonPlayerStats = undefined;
    var json_stats: ?JsonMatchStats = null;
    if (phase == .game_over) {
        if (game.final_stats) |*ms| {
            for (ms.players[0..ms.player_count], 0..) |ps, i| {
                pstats_buf[i] = .{
                    .casts = ps.casts,
                    .cells_covered = ps.cells_covered,
                    .cells_neutralized = ps.cells_neutralized,
                    .recipe_casts = ps.recipe_casts,
                };
            }
            json_stats = .{
                .reason = ms.reason,
                .hunger_final = ms.hunger_final,
                .hunger_max = ms.hunger_max,
                .slime_total = ms.slime_total,
                .slime_left = ms.slime_left,
                .feast = .{
                    .covered = tiers(ms.feast.cells_covered),
                    .neutralized = tiers(ms.feast.neutralized),
                    .sheltered = ms.feast.sheltered,
                    .neutral = ms.feast.neutral_consumed,
                    .defused = ms.feast.defused_consumed,
                    .hunger_normal = ms.feast.hunger_normal,
                    .charges_spent = ms.feast.charges_spent,
                    .charges_left = ms.feast.charges_left,
                },
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
        // Carried in `game_over` too, not just `game`.  The renderer plays the
        // closing feast as its outro, and that needs the same payload a normal
        // turn end gets: the post-feast board plus the `turn_ended` that
        // describes it.  Both are already on the snapshot — the server sends a
        // final `game_state` before `game_over` for exactly this — so it costs
        // nothing but the bytes.  `turn_ended` is cleared after one write, so
        // the outro starts once and the frames after it are static.
        .game = if (phase == .game or phase == .game_over) JsonGame{
            .encounter = game.encounter_label[0..game.encounter_label_len],
            .join_code = &game.join_code,
            .player_id = game.player_id,
            .observer = game.player_id == proto.NO_PLAYER,
            .casts_per_turn = game.casts_per_turn,
            .turn = game.snapshot.turn,
            .tick = game.snapshot.tick,
            .entities = entities_buf[0..game.snapshot.entity_count],
            .hunger = .{
                .current = game.snapshot.hunger.current,
                .max = game.snapshot.hunger.max,
            },
            .charges = game.snapshot.charges,
            .score = game.snapshot.score,
            .grid_rows = game.snapshot.grid_rows,
            .grid_cols = game.snapshot.grid_cols,
            .grid = grid_buf[0..grid_len],
            .reservoir = game.snapshot.reservoir,
            .pending = pending_buf[0..game.snapshot.pending_count],
            .over_budget = if (game.over_budget) |ob|
                JsonOverBudget{ .needed = ob.needed, .have = ob.have }
            else
                null,
            .recipes_fired = recipes_buf[0..game.recipe_count],
            .turn_ended = turn_ended,
            .shape_casts = shape_cast_buf[0..game.shape_cast_count],
        } else null,
        .score = if (phase == .game_over) game.final_score else null,
        .stats = json_stats,
    };

    try std.json.Stringify.value(frame, .{ .emit_null_optional_fields = false }, w);
}

/// One slime cell as a compact renderer-facing name.  Hazards are named by
/// their difficulty TIER ("red" = 3 casts from harmless, "green" = 1);
/// "defused" is a fully neutralized cell, which is harmless but still edible.
/// "special" is the objective slime: inert to casts, inedible, and a permanent
/// wall, so the renderer must never draw it as either food or a hazard.
fn cell_name(cell: c.SlimeCell) []const u8 {
    return switch (cell) {
        .empty => "empty",
        .neutral => "neutral",
        .neutralized => "defused",
        .special => "special",
        .tiered => |t| switch (t) {
            .red => "red",
            .yellow => "yellow",
            .green => "green",
        },
    };
}

/// Convert a per-tier u16 array into named JSON fields.
fn tiers(values: [c.Tier.size]u16) JsonTiers {
    return .{
        .red = values[0],
        .yellow = values[1],
        .green = values[2],
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
    game: ?JsonGame,
    score: ?u32,
    stats: ?JsonMatchStats,
};

/// Per-tier values with named fields (Tier ordinal order: hardest first).
const JsonTiers = struct {
    red: u16,
    yellow: u16,
    green: u16,
};

/// Match-wide feast totals over the whole encounter.  `covered` counts cells a
/// stamp downgraded, bucketed by the tier they were BEFORE the downgrade.
const JsonFeastStats = struct {
    covered: JsonTiers,
    neutralized: JsonTiers,
    /// Edible units the flood never reached, summed over the match: the team's
    /// running tally of food a wall kept from them.
    sheltered: u32,
    neutral: u16,
    defused: u16,
    hunger_normal: u16,
    charges_spent: u32,
    charges_left: u32,
};

const JsonPlayerStats = struct {
    casts: u16,
    /// Hazard cells this player's stamps downgraded, and how many of those
    /// went all the way to defused.
    cells_covered: u16,
    cells_neutralized: u16,
    recipe_casts: u16,
};

/// End-of-game tuning report.  Recipe hit arrays are in balance table order;
/// web/game.js resolves labels by index from the fetched data/balance.json.
const JsonMatchStats = struct {
    reason: proto.EndReason,
    hunger_final: u16,
    hunger_max: u16,
    /// Slime the encounter started with, and how much was left unneaten.
    slime_total: u32,
    slime_left: u32,
    feast: JsonFeastStats,
    players: []const JsonPlayerStats,
    player_recipe_hits: []const u16,
    team_recipe_hits: []const u16,
    casts_total: u16,
};

/// Hunger bar: current fills toward max, one point per unit eaten, and never
/// falls.  Nothing in the game undoes hunger — the only question is whether the
/// team clears the field before the bar does.
const JsonHunger = struct {
    current: u16,
    max: u16,
};

const JsonGame = struct {
    encounter: []const u8,
    /// The session's join code — the game id, shown so others can join.
    join_code: []const u8,
    /// The viewer's seat, or 0xFF when observing.
    player_id: u8,
    /// True while this connection holds no seat: input is P-to-join only.
    observer: bool,
    /// Casts each player gets per turn, from game_start.
    casts_per_turn: u8,
    /// The turn now being played, 1-based.
    turn: u16,
    tick: u32,
    entities: []const JsonEntity,
    hunger: JsonHunger,
    /// The team's shared charge pool: one budget for the whole encounter, never
    /// refilled.  This is the number every casting decision is weighed against.
    charges: u32,
    score: u32,
    /// The authoritative slime grid: `grid_rows * grid_cols` cell names in
    /// row-major order, row 0 = TOP.  Index a cell as row * grid_cols + col.
    grid_rows: u8,
    grid_cols: u8,
    grid: []const []const u8,
    /// Slime still waiting off-grid; it refills the field after each feast.
    reservoir: u32,
    /// Casts locked in this turn and not yet resolved, in lock-in order.  This
    /// IS the turn as it stands: the renderer marks each one on the board and
    /// previews the whole list plus the viewer's own live aim.
    pending: []const JsonPending,
    /// The refusal the viewer's last cast earned, if any (transient).  Absent
    /// on every other frame, and never sent to anyone else — it is about a
    /// cast that never happened.
    over_budget: ?JsonOverBudget,
    /// Recipes fired since the previous frame (transient).  `index` refers
    /// to the balance recipe table for `kind` (JS resolves labels from the
    /// fetched data/balance.json, same order).
    recipes_fired: []const JsonRecipeFired,
    /// The feast that ended the turn, if the turn ended since the previous
    /// frame (transient).  Absent on every other frame.
    turn_ended: ?JsonTurnEnded,
    /// Shapes stamped since the previous frame (transient), one per landed
    /// cast.
    shape_casts: []const JsonShapeCast,
};

/// One landed stamp.  `cells` are ABSOLUTE flat grid indices, already clipped
/// to the grid by the server, so the renderer never re-derives placement.
/// `downgraded` is bucketed by each cell's tier BEFORE the downgrade.
const JsonShapeCast = struct {
    caster: u8,
    cells: []const u16,
    downgraded: JsonTiers,
    /// Cells that reached defused (they were green).
    neutralized: u16,
    /// Shape cells that fell off the grid edge and were clipped away.
    off_grid: u16,
    /// In-bounds cells that held nothing downgradable (empty/neutral/defused).
    inert: u16,
};

const JsonRecipeFired = struct {
    kind: proto.RecipeKind,
    index: u8,
};

/// One cast locked in but not yet resolved.  `square` is a flat grid index
/// (row * grid_cols + col), frozen when the cast was locked in.
const JsonPending = struct {
    player_id: u8,
    move: u8,
    square: u16,
};

/// A cast refused for price: what the turn would have cost with it, against
/// what the shared pool actually holds.
const JsonOverBudget = struct {
    needed: u32,
    have: u32,
};

/// The turn-end feast: everything the Lil Guys could REACH from the left edge
/// was devoured at once.  `sheltered` is the food `walls` kept from them — the
/// number the next turn's casts exist to shrink.  This drives the client's
/// devour animation.
const JsonTurnEnded = struct {
    /// The turn that just ended (the frame after it carries turn + 1).
    turn: u16,
    cells_eaten: u16,
    hunger_added: u16,
    sheltered: u16,
    walls: u16,
    score_added: u32,
    /// The shared pool AFTER this turn: the client's running budget readout.
    charges_left: u32,
};

const JsonEntity = struct {
    id: u32,
    kind: c.EntityKind,
    owner: u8,
    /// Casts this player has left in the current turn.
    casts_left: u8,
    last_action: ?c.ActionAnimation,
    /// Index into the move table of the shape this player would cast.  Sent for
    /// every player, not just the local one: seeing what a teammate has chosen
    /// is how a group gets agreed on before anyone spends a charge.
    selected_shape: u8,
    /// Where this player is aiming: the live cursor, sent for every player so
    /// teammates can see each other's aim.
    cursor_row: u8,
    cursor_col: u8,
};
