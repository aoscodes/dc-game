const std = @import("std");
const proto = @import("shared").protocol;
const c = @import("shared").components;

/// Room for the widest render frame the wire caps admit.
///
/// Not hand-derived: the theoretical worst case is dominated by the 16 stored
/// per-pass refills, each of which may name every one of MAX_GRID_CELLS cells,
/// and it measures ~260 KB at 16x32 — far past what belongs on a stack, and
/// far past what a realistic frame costs (~22 KB for a full board alone,
/// ~61 KB with a full refill and heavy match/cast traffic on top).
///
/// So the buffer is static rather than stack, and the bound is PINNED BY A
/// TEST ("the widest frame the wire caps admit fits frame_buf") that builds a
/// maximal frame and measures it, because the grid caps are a tuning knob and
/// arithmetic done by hand here rots the moment they move.
const RENDER_BUF_BYTES = 320 * 1024;

/// Guarded by `Writer.mu`: `write_render` is the only reader or writer, and
/// it holds the lock across the whole encode-and-emit.
var render_buf: [RENDER_BUF_BYTES]u8 = undefined;

pub const Writer = struct {
    mu: *std.Thread.Mutex,

    pub fn write_render(
        self: Writer,
        phase: ClientPhaseTag,
        game: *GameState,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();
        var w = std.io.Writer.fixed(&render_buf);
        // Overflow here would be SILENT — these drop the frame, so a buffer
        // that cannot hold the widest frame presents as a renderer that
        // freezes under load rather than as an error.  RENDER_BUF_BYTES is
        // sized so it cannot happen; the catches are for the writev.
        write_render_inner(&w, phase, game) catch return;
        w.writeByte('\n') catch return;
        const out = std.fs.File.stdout();
        out.writeAll(w.buffered()) catch return;
        game.last_action_count = 0;
        game.over_budget = null;
        game.cast_refused = null;
        game.recipe_count = 0;
        game.bite_settled = null;
        game.shape_cast_count = 0;
        game.special_match_count = 0;
        game.eggs_hatched = null;
        game.refill_count = 0;
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

/// Decides WHEN a render frame goes out.
///
/// The server ends every tick by broadcasting `game_state` (unconditionally —
/// see the session's tick, and `end_game` for the closing board), so that
/// message is a reliable END-OF-TICK MARKER: everything the tick had to say —
/// the casts, the matches, the settled feast — was already sent, and the board
/// that reflects it has now landed.  Emitting on THAT is what keeps a tick's
/// transients in the same frame as the board they describe.
///
/// A wall-clock timer cannot do this, and that was the bug: the events and the
/// board are separate socket writes, so a timer firing between them SPLIT them
/// — the events into one frame against the pre-event board, the board into the
/// next with the transients already drained.  The renderer, which keeps only
/// the newest frame, then dropped whichever half it saw second, and the
/// animation simply did not play.  It also emitted every tick's board three
/// times (60Hz out, 20Hz in), which is what made the loss look intermittent.
///
/// STRICT BY DESIGN: no heartbeat.  A frame goes out only when the client has
/// something new to say, so a held game costs nothing — and both holds (the
/// pre-match guide and the end screen) stop broadcasting `game_state`
/// entirely, which is why `note_standing` exists.  The renderer keeps drawing
/// the last frame it was given, so one emit is all a static screen needs.
pub const RenderGate = struct {
    pending: bool = false,

    /// A tick's board arrived: every event that tick sent is now complete and
    /// the board that reflects them is in hand.
    pub fn note_state(self: *RenderGate) void {
        self.pending = true;
    }

    /// This connection's STANDING changed — phase, seat, or encounter identity
    /// (game_start, game_over).  The held screens broadcast no `game_state`,
    /// so this is the only thing that ever gets them drawn.
    pub fn note_standing(self: *RenderGate) void {
        self.pending = true;
    }

    /// Take the pending emit, if any.  Checked ONCE PER LOOP ITERATION, after
    /// the whole recv queue is drained, so a tick's `game_state` and the
    /// `game_over` behind it coalesce into a single frame instead of two.
    pub fn take(self: *RenderGate) bool {
        defer self.pending = false;
        return self.pending;
    }
};

pub const ClientPhaseTag = enum { connecting, pre_match, game, game_over };

pub const LastActionEntry = struct { entity: u32, anim: c.ActionAnimation };

pub const GameState = struct {
    snapshot: proto.GameState = proto.GameState.blank,
    /// The seat this connection holds, or NO_PLAYER while observing.
    player_id: u8 = proto.NO_PLAYER,
    /// The session's join code — the game id, from game_start.
    join_code: [6]u8 = [_]u8{'-'} ** 6,
    /// Ms between one player's casts, as announced in game_start.  Constant
    /// for the whole encounter, so the renderer can scale its cooldown dial.
    cast_cooldown_ms: u32 = 0,
    /// Ms a landed cast stays able to complete a team recipe, from
    /// game_start.  Constant for the whole encounter.
    team_window_ms: u32 = 0,
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
    /// A numberless refusal this player's last cast earned, if any, since the
    /// last render write (transient, drained per frame like `over_budget`).
    /// At most one per frame, for the same reason.
    cast_refused: ?proto.CastRefused = null,
    /// Recipes fired since the last render write (transient).
    recipes_fired: [16]proto.RecipeFired = undefined,
    recipe_count: u8 = 0,
    /// The feast that settled, if a bite settled since the last render
    /// write (transient).  At most one per frame: when a frame swallows two,
    /// the later wins — it describes the next snapshot's board.
    ///
    /// A frame now covers exactly one server tick (see RenderGate), so this
    /// collapses only when the server settles two bites in ONE tick — a
    /// catch-up path that needs the tick to overrun a whole bite interval
    /// (seconds).  When it does, the earlier bite's per-pass events below are
    /// dropped with it, so the replay never mixes two feasts' passes.
    bite_settled: ?proto.BiteSettled = null,
    /// Shapes stamped since the last render write (transient): the resolved
    /// footprint of each landed cast, so the renderer can flash exactly the
    /// cells the server hit without re-deriving placement.
    shape_casts: [16]proto.ShapeCast = undefined,
    shape_cast_count: u8 = 0,
    /// Special matches resolved since the last render write (transient):
    /// the popped run and the effect it released, per match.
    special_matches: [16]proto.SpecialMatched = undefined,
    special_match_count: u8 = 0,
    /// The eggs the turn's feast hatched, if any hatched since the last
    /// render write (transient) — at most one batch per turn end.
    eggs_hatched: ?proto.EggsHatched = null,
    /// Per-pass reservoir refills since the last render write (transient),
    /// in pass order — the one part of a cascading settle the renderer
    /// cannot derive.  16 passes is far beyond any real cascade.
    refills: [16]proto.FieldRefilled = undefined,
    refill_count: u8 = 0,
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
            .cooldown_ms = e.cooldown_ms,
            .last_action = anim,
            .selected_shape = e.selected_shape,
            .cursor_row = e.cursor_row,
            .cursor_col = e.cursor_col,
            .babies = babies(e.babies),
            .powerups = powerups(e.powerups),
            .critter = critter_name(e.appearance.critter),
            // Null and "black" are DIFFERENT pictures downstream (null draws
            // the art's authored greys), so this travels unflattened.
            .led = e.appearance.led,
            .brood_seed = e.appearance.brood_seed,
        };
    }

    // The group window as it stands: every cast still young enough to help
    // a teammate spell a team recipe.
    var recent_buf: [proto.MAX_RECENT_WIRE]JsonRecent = undefined;
    for (game.snapshot.recent[0..game.snapshot.recent_count], 0..) |rc, i| {
        recent_buf[i] = .{
            .player_id = rc.player_id,
            .move = rc.move,
            .square = rc.square,
            .age_ms = rc.age_ms,
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
            .anchor = sc.anchor,
            .cells = cells_bufs[i][0..sc.cell_count],
            .downgraded = tiers(sc.downgraded),
            .neutralized = sc.neutralized,
            .off_grid = sc.off_grid,
            .inert = sc.inert,
            .rocks_broken = sc.rocks_broken,
        };
    }

    // Convert this frame's settled bite (if any) for JSON.
    const bite_settled: ?JsonBiteSettled = if (game.bite_settled) |bs| .{
        .bite = bs.bite,
        .cells_eaten = bs.cells_eaten,
        .hunger_added = bs.hunger_added,
        .hazards_bitten = bs.hazards_bitten,
        .score_added = bs.score_added,
        .charges_left = bs.charges_left,
        .passes = bs.passes,
    } else null;

    // Convert transient special matches for JSON.  Cell lists pass through
    // verbatim: the server resolved the runs, the renderer just pops them.
    var match_buf: [16]JsonSpecialMatched = undefined;
    var match_cells_bufs: [16][proto.MAX_MATCH_CELLS_WIRE]u16 = undefined;
    for (game.special_matches[0..game.special_match_count], 0..) |sm, i| {
        @memcpy(match_cells_bufs[i][0..sm.cell_count], sm.cells[0..sm.cell_count]);
        match_buf[i] = .{
            .kind = @tagName(sm.kind),
            .pass = sm.pass,
            .center = sm.center,
            .cells = match_cells_bufs[i][0..sm.cell_count],
            .downgraded = tiers(sm.downgraded),
            .neutralized = sm.neutralized,
            .rocks_broken = sm.rocks_broken,
        };
    }

    // Convert transient per-pass refills for JSON: cells plus their contents
    // as the same names the grid uses, so the renderer can drop them onto its
    // replay board verbatim.
    var refill_buf: [16]JsonRefill = undefined;
    var refill_cells_bufs: [16][proto.MAX_REFILL_WIRE]u16 = undefined;
    var refill_names_bufs: [16][proto.MAX_REFILL_WIRE][]const u8 = undefined;
    for (game.refills[0..game.refill_count], 0..) |fr, i| {
        @memcpy(refill_cells_bufs[i][0..fr.count], fr.cells[0..fr.count]);
        for (fr.contents[0..fr.count], 0..) |cell, j| {
            refill_names_bufs[i][j] = cell_name(cell);
        }
        refill_buf[i] = .{
            .pass = fr.pass,
            .cells = refill_cells_bufs[i][0..fr.count],
            .contents = refill_names_bufs[i][0..fr.count],
        };
    }

    // Convert this frame's hatches (if any) for JSON: parallel cell/type
    // lists, types by placeholder colour name.
    var hatch_types_buf: [proto.MAX_HATCHES_WIRE][]const u8 = undefined;
    const eggs_hatched: ?JsonEggsHatched = if (game.eggs_hatched) |eh| blk: {
        for (eh.types[0..eh.count], 0..) |t, i| hatch_types_buf[i] = @tagName(t);
        break :blk .{
            .cells = eh.cells[0..eh.count],
            .types = hatch_types_buf[0..eh.count],
        };
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
                    .hazards_bitten = ms.feast.hazards_bitten,
                    .neutral = ms.feast.neutral_consumed,
                    .defused = ms.feast.defused_consumed,
                    .agents = ms.feast.agents_consumed,
                    .hunger_normal = ms.feast.hunger_normal,
                    .charges_spent = ms.feast.charges_spent,
                    .charges_left = ms.feast.charges_left,
                    .rocks_broken = ms.feast.rocks_broken,
                },
                .eggs_hatched = babies_u16(ms.eggs_hatched),
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
        // settle gets: the post-feast board plus the `bite_settled` that
        // describes it.  Both are already on the snapshot — the server sends a
        // final `game_state` before `game_over` for exactly this — so it costs
        // nothing but the bytes.  `bite_settled` is cleared after one write,
        // so the outro starts once and the frames after it are static.
        // Carried in `pre_match` too: the guide screen needs the game id and
        // the viewer's standing (seats can be taken while it holds).
        .game = if (phase != .connecting) JsonGame{
            .encounter = game.encounter_label[0..game.encounter_label_len],
            .join_code = &game.join_code,
            .player_id = game.player_id,
            .observer = game.player_id == proto.NO_PLAYER,
            .cast_cooldown_ms = game.cast_cooldown_ms,
            .team_window_ms = game.team_window_ms,
            .bite = game.snapshot.bite,
            .next_bite_ms = game.snapshot.next_bite_ms,
            .cast_locked_ms = game.snapshot.cast_locked_ms,
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
            .hatched = babies_u16(game.snapshot.hatched),
            .recent = recent_buf[0..game.snapshot.recent_count],
            .over_budget = if (game.over_budget) |ob|
                JsonOverBudget{ .needed = ob.needed, .have = ob.have }
            else
                null,
            .cast_refused = if (game.cast_refused) |cr|
                JsonCastRefused{ .reason = @tagName(cr.reason) }
            else
                null,
            .recipes_fired = recipes_buf[0..game.recipe_count],
            .bite_settled = bite_settled,
            .shape_casts = shape_cast_buf[0..game.shape_cast_count],
            .special_matches = match_buf[0..game.special_match_count],
            .eggs_hatched = eggs_hatched,
            .refills = refill_buf[0..game.refill_count],
        } else null,
        .score = if (phase == .game_over) game.final_score else null,
        .stats = json_stats,
    };

    try std.json.Stringify.value(frame, .{ .emit_null_optional_fields = false }, w);
}

/// One slime cell as a compact renderer-facing name.  Hazards are named by
/// their difficulty TIER ("red" = 3 casts from harmless, "green" = 1);
/// "defused" is a fully neutralized cell, which is harmless but still edible.
/// Specials are named per kind: "special_neutralizer" fires a 3x3 Agent
/// block when eaten; "special_egg" is edible and hatches a baby, so the
/// renderer must draw it as food with a prize inside; "special_rock" is the
/// permanent wall nothing can touch; "special_canister" refills the team's
/// charge pool when swallowed; "special_bomb" destroys its 3x3 surroundings
/// (or just the rocks in it, per balance) when swallowed.
fn cell_name(cell: c.SlimeCell) []const u8 {
    return switch (cell) {
        .empty => "empty",
        .neutral => "neutral",
        .neutralized => "defused",
        .special => |kind| switch (kind) {
            .neutralizer => "special_neutralizer",
            .egg => "special_egg",
            .rock => "special_rock",
            .canister => "special_canister",
            .bomb => "special_bomb",
        },
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

/// Convert a per-BabyType u32 array into named JSON fields.
fn babies(values: c.BabyCounts) JsonBabies {
    return .{
        .rose = values[0],
        .mint = values[1],
        .sky = values[2],
        .gold = values[3],
        .plum = values[4],
    };
}

/// Convert a per-PowerupKind u8 array into named JSON fields.
fn powerups(values: c.PowerupCounts) JsonPowerups {
    return .{ .neutralizer_canister = values[0] };
}

/// The critter name the renderer keys its sprite sheets by, or null when the
/// board never said (browsers, bots, old firmware).  The NAME rather than the
/// ordinal because game.js already names the five types and looks its atlases
/// up by them; a number here would put the enum order in two places.
fn critter_name(ct: ?c.BabyType) ?[]const u8 {
    return if (ct) |t| @tagName(t) else null;
}

/// Same, from the u16 tallies (session hatches, match stats).
fn babies_u16(values: [c.BabyType.size]u16) JsonBabies {
    return .{
        .rose = values[0],
        .mint = values[1],
        .sky = values[2],
        .gold = values[3],
        .plum = values[4],
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

/// Per-baby-type counts with named fields (BabyType ordinal order).  The
/// names are the placeholder colours; the renderer keys its 5 glyph styles
/// off them.
const JsonBabies = struct {
    rose: u32,
    mint: u32,
    sky: u32,
    gold: u32,
    plum: u32,
};

/// Per-powerup-kind counts with NAMED fields (PowerupKind ordinal order), so
/// the renderer reads `e.powerups.neutralizer_canister` rather than indexing a
/// bare array — a name it cannot silently get wrong when a kind is appended.
const JsonPowerups = struct {
    neutralizer_canister: u8,
};

/// Match-wide feast totals over the whole encounter.  `covered` counts cells a
/// stamp downgraded, bucketed by the tier they were BEFORE the downgrade.
const JsonFeastStats = struct {
    covered: JsonTiers,
    neutralized: JsonTiers,
    /// Live hazards the bites nibbled, summed over the match: the team's
    /// running tally of hunger-clock spent on cells no cast defused in time.
    hazards_bitten: u32,
    neutral: u16,
    defused: u16,
    /// Neutralizers swallowed — free equipment, never scored.
    agents: u16,
    hunger_normal: u16,
    charges_spent: u32,
    charges_left: u32,
    /// Rocks broken into red slime over the match — Agent spent on boulders.
    rocks_broken: u32,
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
    /// Babies hatched over the whole encounter, per type — what every board
    /// that completed it banks into its flash.
    eggs_hatched: JsonBabies,
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
    /// Ms between one player's casts, from game_start.
    cast_cooldown_ms: u32,
    /// Ms a landed cast stays able to complete a team recipe, from game_start.
    team_window_ms: u32,
    /// The bite now being chewed toward, 1-based.
    bite: u16,
    /// Ms until the Lil Guys bite again; 0 while the timer is disarmed
    /// (nobody seated, or the session is holding).
    next_bite_ms: u32,
    /// Ms left in the post-bite settle window, during which no player may
    /// cast; 0 while casting is open.  Table-wide, so every seat panel counts
    /// the same window down.
    cast_locked_ms: u32,
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
    /// Babies hatched so far this encounter, per type.  Session-owned — a
    /// reconnecting renderer rebuilds its brood from this.
    hatched: JsonBabies,
    /// Casts still inside the team-recipe window, in landing order.  The
    /// renderer marks each one on the board and previews group potential
    /// from this list plus the viewer's own live aim.
    recent: []const JsonRecent,
    /// The refusal the viewer's last cast earned, if any (transient).  Absent
    /// on every other frame, and never sent to anyone else — it is about a
    /// cast that never happened.
    over_budget: ?JsonOverBudget,
    /// A numberless refusal the viewer's last cast earned, if any
    /// (transient).  Separate from `over_budget` because it carries no
    /// quote: the `reason` tag is the whole explanation.
    cast_refused: ?JsonCastRefused,
    /// Recipes fired since the previous frame (transient).  `index` refers
    /// to the balance recipe table for `kind` (JS resolves labels from the
    /// fetched data/balance.json, same order).
    recipes_fired: []const JsonRecipeFired,
    /// The feast that settled, if a bite settled since the previous frame
    /// (transient).  Absent on every other frame.
    bite_settled: ?JsonBiteSettled,
    /// Shapes stamped since the previous frame (transient), one per landed
    /// cast.
    shape_casts: []const JsonShapeCast,
    /// Special matches resolved since the previous frame (transient): the
    /// renderer pops `cells` and flashes the effect at `center`.
    special_matches: []const JsonSpecialMatched,
    /// The eggs the turn's feast hatched, if any hatched since the previous
    /// frame (transient).  Parallel lists: `cells[i]` hatched a `types[i]`.
    eggs_hatched: ?JsonEggsHatched,
    /// Per-pass reservoir refills (transient), in pass order.  A turn's
    /// settle CASCADES while matches keep re-opening the feast; these are
    /// the only unknowable step, so with them the renderer replays every
    /// pass exactly.
    refills: []const JsonRefill,
};

/// One settle pass's refill: `cells[i]` was filled with a unit whose grid
/// name is `contents[i]`.
const JsonRefill = struct {
    pass: u8,
    cells: []const u16,
    contents: []const []const u8,
};

/// One resolved special match.  `cells` are absolute flat grid indices (the
/// popped run, already resolved server-side); `center` is where the effect
/// landed; `downgraded`/`neutralized` describe what a neutralize_block did;
/// `pass` is the settle pass it fired in.
const JsonSpecialMatched = struct {
    /// SpecialKind name, e.g. "neutralizer".
    kind: []const u8,
    pass: u8,
    center: u16,
    cells: []const u16,
    downgraded: JsonTiers,
    neutralized: u16,
    rocks_broken: u16,
};

/// One turn's hatches: `cells[i]` (flat grid index of the eaten egg) hatched
/// a baby of `types[i]` (BabyType placeholder colour name).
const JsonEggsHatched = struct {
    cells: []const u16,
    types: []const []const u8,
};

/// One landed stamp.  `cells` are ABSOLUTE flat grid indices, already clipped
/// to the grid by the server, so the renderer never re-derives placement.
/// `downgraded` is bucketed by each cell's tier BEFORE the downgrade.
const JsonShapeCast = struct {
    caster: u8,
    /// The cell the cast was aimed at.  Travels even though `cells` is
    /// absolute, because it is NOT derivable from them: clipping can drop the
    /// anchor itself.  The renderer needs it to rebuild the shape's OFFSETS,
    /// which is what lets it re-run the stamp locally and see the chain a
    /// cast set off — the cell list alone only names the footprint, never
    /// what a blast took outside it.
    anchor: u16,
    cells: []const u16,
    downgraded: JsonTiers,
    /// Cells that reached defused (they were green).
    neutralized: u16,
    /// Shape cells that fell off the grid edge and were clipped away.
    off_grid: u16,
    /// In-bounds cells that held nothing downgradable (empty/neutral/defused).
    inert: u16,
    /// Rocks the Agent BROKE into red slime — accomplishment, not waste.
    rocks_broken: u16,
};

const JsonRecipeFired = struct {
    kind: proto.RecipeKind,
    index: u8,
};

/// One landed cast still inside the team-recipe window.  `square` is a flat
/// grid index (row * grid_cols + col); `age_ms` is how long ago it landed.
const JsonRecent = struct {
    player_id: u8,
    move: u8,
    square: u16,
    age_ms: u32,
};

/// A cast refused for price: what it would have cost, against what the
/// shared pool actually holds.
const JsonOverBudget = struct {
    needed: u32,
    have: u32,
};

/// A cast turned away for a reason with no numbers attached.  `reason` is the
/// `proto.CastRefusal` tag name, so a new reason reaches the renderer as a
/// new string rather than a number it would have to know a table for.
const JsonCastRefused = struct {
    reason: []const u8,
};

/// A settled bite: the Lil Guys bit the front columns of the field.
/// `hazards_bitten` counts the nibbles — hunger spent on hazards no cast
/// defused in time, the number the next bite's casts exist to shrink.  This
/// drives the client's devour animation.
const JsonBiteSettled = struct {
    /// The bite that just settled (the frame after it carries bite + 1).
    bite: u16,
    cells_eaten: u16,
    hunger_added: u16,
    hazards_bitten: u16,
    score_added: u32,
    /// The shared pool AFTER this bite: the client's running budget readout.
    charges_left: u32,
    /// Settle passes the bite took (>= 1; matches re-open the feast).
    passes: u8,
};

const JsonEntity = struct {
    id: u32,
    kind: c.EntityKind,
    owner: u8,
    /// Ms until this player may cast again; 0 = ready now.
    cooldown_ms: u32,
    last_action: ?c.ActionAnimation,
    /// Index into the move table of the shape this player would cast.  Sent for
    /// every player, not just the local one: seeing what a teammate has chosen
    /// is how a group gets agreed on before anyone spends a charge.
    selected_shape: u8,
    /// Where this player is aiming: the live cursor, sent for every player so
    /// teammates can see each other's aim.
    cursor_row: u8,
    cursor_col: u8,
    /// The babies this player's board brought, per type — drawn beside their
    /// owner and gone when they leave.
    babies: JsonBabies,
    /// The powerups this player's board brought, per kind — drawn on their
    /// seat panel and gone when they leave.  Sent for every player (zeros
    /// included): unlike the cosmetic fields below there is no "never said"
    /// state, because a boardless player genuinely carries none.
    powerups: JsonPowerups,
    /// Which of the five critters this player's board keeps, by name, or null
    /// when it never said — the renderer falls back to a default creature
    /// rather than drawing nothing.
    critter: ?[]const u8,
    /// The board's three LED colours, `[[r,g,b], [r,g,b], [r,g,b]]`, or null
    /// for a badge that never onboarded.  The renderer repaints its Lil Guy
    /// in these; null means it draws the art as authored.
    led: ?[proto.LED_COUNT][3]u8,
    /// The board's brood seed, or null for a badge that never said.  The
    /// renderer rolls this owner's BABY palette from it (web/palette.js
    /// rollBroodPalette) — one palette per badge, so a player's babies are a
    /// matching set and a stranger's are visibly not.  Null draws them in the
    /// art's authored greys, same rule as `led`.
    brood_seed: ?u32,
};

// ---------------------------------------------------------------------------
// Render-frame CONTRACT tests
// ---------------------------------------------------------------------------
// The browser renderer (web/game.js) reads this JSON and nothing else.  The
// binary protocol is therefore not the contract with it — THIS is, and the
// two can drift silently: a field can travel the whole way from the session
// to `proto.ShapeCast` and still never reach the tab, because building the
// Json* mirror above is a hand copy.
//
// That is not hypothetical.  `anchor` was added to proto.ShapeCast, carried
// correctly, and simply not copied here; game.js read `ev.anchor`, got
// undefined, computed NaN offsets, and every bounds test it fed silently
// passed (NaN comparisons are false).  The whole feature was dead and
// nothing failed.  These tests assert the fields the renderer names are
// really in the bytes it receives.

const testing = std.testing;

/// Render one GameState to JSON, as `write_render` does.
fn render_to_json(buf: []u8, game: *const GameState) ![]const u8 {
    var w = std.io.Writer.fixed(buf);
    try write_render_inner(&w, .game, game);
    return w.buffered();
}

test "a landed cast reaches the renderer with its ANCHOR" {
    // The anchor is not derivable from `cells` — clipping can drop the
    // anchor cell itself — so a renderer that wants the shape's offsets back
    // has only this field to rebuild them from.
    var game = GameState{};
    game.snapshot.grid_rows = 3;
    game.snapshot.grid_cols = 3;
    game.shape_cast_count = 1;
    game.shape_casts[0] = .{
        .caster = 2,
        .anchor = 4,
        .cell_count = 2,
        .cells = blk: {
            var cells = [_]u16{0} ** proto.MAX_SHAPE_CELLS_WIRE;
            cells[0] = 4;
            cells[1] = 5;
            break :blk cells;
        },
        .neutralized = 1,
        .off_grid = 3,
        .inert = 0,
        .rocks_broken = 1,
    };

    var buf: [32768]u8 = undefined;
    const json = try render_to_json(&buf, &game);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    const casts = parsed.value.object.get("game").?.object
        .get("shape_casts").?.array;
    try testing.expectEqual(@as(usize, 1), casts.items.len);
    const cast = casts.items[0].object;

    // Every field web/game.js names on a shape_cast event.  Read as a list
    // of what the renderer is allowed to rely on.
    try testing.expectEqual(@as(i64, 2), cast.get("caster").?.integer);
    try testing.expectEqual(@as(i64, 4), cast.get("anchor").?.integer);
    try testing.expectEqual(@as(i64, 1), cast.get("neutralized").?.integer);
    try testing.expectEqual(@as(i64, 3), cast.get("off_grid").?.integer);
    try testing.expectEqual(@as(i64, 0), cast.get("inert").?.integer);
    try testing.expectEqual(@as(i64, 1), cast.get("rocks_broken").?.integer);
    try testing.expect(cast.get("downgraded") != null);

    // The footprint arrives pre-clipped and verbatim.
    const cells = cast.get("cells").?.array;
    try testing.expectEqual(@as(usize, 2), cells.items.len);
    try testing.expectEqual(@as(i64, 4), cells.items[0].integer);
    try testing.expectEqual(@as(i64, 5), cells.items[1].integer);
}

test "the anchor survives even when clipping drops it from the cell list" {
    // The case the field exists FOR: aimed off the board's edge, so the
    // anchor cell is not among the cells that landed.  A renderer deriving
    // the anchor from `cells` would place the shape wrong here; one reading
    // it gets the aim the player actually took.
    var game = GameState{};
    game.snapshot.grid_rows = 3;
    game.snapshot.grid_cols = 3;
    game.shape_cast_count = 1;
    game.shape_casts[0] = .{
        .caster = 0,
        .anchor = 8, // bottom-right corner
        .cell_count = 1,
        .cells = blk: {
            var cells = [_]u16{0} ** proto.MAX_SHAPE_CELLS_WIRE;
            cells[0] = 4; // the only offset that stayed in bounds
            break :blk cells;
        },
        .off_grid = 8,
    };

    var buf: [32768]u8 = undefined;
    const json = try render_to_json(&buf, &game);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    const cast = parsed.value.object.get("game").?.object
        .get("shape_casts").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 8), cast.get("anchor").?.integer);
    // ...and the anchor is genuinely absent from the footprint, which is the
    // whole reason it cannot be re-derived.
    const cells = cast.get("cells").?.array;
    try testing.expectEqual(@as(usize, 1), cells.items.len);
    try testing.expectEqual(@as(i64, 4), cells.items[0].integer);
}

test "the settle window and a settling refusal both reach the renderer" {
    // The renderer cannot derive either of these.  `cast_locked_ms` is the
    // server's own countdown — the client's chew animation only approximates
    // it — and the refusal is about a cast that left no trace on the board.
    var game = GameState{};
    game.snapshot.grid_rows = 1;
    game.snapshot.grid_cols = 1;
    game.snapshot.cast_locked_ms = 640;
    game.cast_refused = .{ .reason = .settling };

    var buf: [32768]u8 = undefined;
    const json = try render_to_json(&buf, &game);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    const g = parsed.value.object.get("game").?.object;
    try testing.expectEqual(@as(i64, 640), g.get("cast_locked_ms").?.integer);
    // The reason travels as its tag NAME: a new refusal reaches the renderer
    // as a new string, not as a number it would need a table to read.
    const refused = g.get("cast_refused").?.object;
    try testing.expectEqualStrings("settling", refused.get("reason").?.string);
}

test "an open board reports no settle window and no refusal" {
    // The negative control for the test above: both fields are transient or
    // conditional, so a frame that always claimed a lock (or always carried a
    // refusal) would pass the assertions above while telling the renderer the
    // table is permanently frozen.
    var game = GameState{};
    game.snapshot.grid_rows = 1;
    game.snapshot.grid_cols = 1;

    var buf: [32768]u8 = undefined;
    const json = try render_to_json(&buf, &game);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    const g = parsed.value.object.get("game").?.object;
    try testing.expectEqual(@as(i64, 0), g.get("cast_locked_ms").?.integer);
    // Absent, not null: transient fields are omitted from the frame entirely,
    // which is what lets `game.cast_refused` read as falsy in the renderer.
    try testing.expect(g.get("cast_refused") == null);
}

// ---------------------------------------------------------------------------
// RenderGate
// ---------------------------------------------------------------------------

test "RenderGate: a fresh gate has nothing to say" {
    // The loop wakes 60 times a second.  If an idle wake emitted, the gate
    // would be a timer with extra steps.
    var gate: RenderGate = .{};
    try testing.expect(!gate.take());
    try testing.expect(!gate.take());
}

test "RenderGate: a tick's board arms exactly one frame" {
    var gate: RenderGate = .{};
    gate.note_state();
    try testing.expect(gate.take());
    // Drained.  The server ticks at 20Hz and the loop wakes at 60, so the two
    // wakes that follow must stay silent — emitting on them is what sent every
    // board three times over.
    try testing.expect(!gate.take());
    try testing.expect(!gate.take());
}

test "RenderGate: a tick's messages coalesce into one frame" {
    // The closing tick sends the board and then the report, and a settling
    // tick sends its events before the board.  All of it is drained before the
    // gate is read, so the whole tick costs ONE frame — that co-arrival is the
    // entire point: transients and the board they describe stay together.
    var gate: RenderGate = .{};
    gate.note_state();
    gate.note_standing();
    gate.note_state();
    try testing.expect(gate.take());
    try testing.expect(!gate.take());
}

test "RenderGate: standing alone arms a frame, with no board" {
    // Both holds — the pre-match guide and the end screen — return from the
    // session tick BEFORE it broadcasts game_state, so a gate that waited for
    // a board would leave those screens undrawn forever.
    var gate: RenderGate = .{};
    gate.note_standing();
    try testing.expect(gate.take());
    try testing.expect(!gate.take());
}

test "the widest frame the wire caps admit fits render_buf" {
    // write_render drops a frame it cannot encode, in silence, so an
    // undersized render_buf does not fail — it just stops drawing, under
    // exactly the load that matters.  The grid caps that dominate this are a
    // tuning knob (components.MAX_GRID_*), so the bound is measured here
    // rather than reasoned about at the declaration.
    //
    // Every count is pushed to its wire cap at once.  No real session reaches
    // this — 16 passes each refilling the entire grid is not a board that can
    // happen — which is the point: it is the bound the TYPES allow, so
    // nothing a server can legally send overflows.
    const alloc = testing.allocator;
    const buf = try alloc.alloc(u8, 4 * RENDER_BUF_BYTES);
    defer alloc.free(buf);

    var game = GameState{};
    game.snapshot.grid_rows = c.MAX_GRID_ROWS;
    game.snapshot.grid_cols = c.MAX_GRID_COLS;
    // Specials encode wider than plain slime, so a board of them is the
    // expensive board.
    for (0..c.MAX_GRID_CELLS) |i| game.snapshot.grid[i] = .{ .special = .neutralizer };
    game.snapshot.entity_count = proto.MAX_ENTITIES_WIRE;
    game.last_action_count = proto.MAX_ENTITIES_WIRE;
    for (0..proto.MAX_ENTITIES_WIRE) |i|
        game.last_actions[i] = .{ .entity = 1, .anim = .attack };
    game.refill_count = game.refills.len;
    for (&game.refills, 0..) |*r, i| {
        r.* = .{ .pass = @intCast(i), .count = proto.MAX_REFILL_WIRE };
        for (0..proto.MAX_REFILL_WIRE) |k| {
            r.cells[k] = @intCast(k);
            r.contents[k] = .{ .special = .neutralizer };
        }
    }
    game.special_match_count = game.special_matches.len;
    for (&game.special_matches) |*m|
        m.* = .{ .kind = .neutralizer, .cell_count = proto.MAX_MATCH_CELLS_WIRE };
    game.shape_cast_count = game.shape_casts.len;
    for (&game.shape_casts) |*sc|
        sc.* = .{ .caster = 1, .anchor = 1, .cell_count = proto.MAX_SHAPE_CELLS_WIRE };
    game.recipe_count = game.recipes_fired.len;
    for (&game.recipes_fired) |*r| r.* = .{ .kind = .player, .index = 0 };
    game.eggs_hatched = .{ .count = proto.MAX_HATCHES_WIRE };

    // +1 for the newline write_render appends after the payload.
    const len = (try render_to_json(buf, &game)).len + 1;
    try testing.expect(len <= RENDER_BUF_BYTES);
}

test "a player's critter and colours reach the renderer" {
    // web/game.js `appearance()` reads exactly `e.critter` and `e.led`, and
    // dresses that player's Lil Guy from them. Both are hand-copied into
    // JsonEntity, which is the drift this file's tests exist to catch.
    // `brood_seed` rides along for the same reason: see the brood seed test
    // below.
    var game = GameState{};
    game.snapshot.grid_rows = 3;
    game.snapshot.grid_cols = 3;
    game.snapshot.entity_count = 1;
    game.snapshot.entities[0] = blk: {
        var e = proto.EntitySnapshot.blank;
        e.entity = 9;
        e.owner = 0;
        e.appearance = .{ .critter = .gold, .led = .{
            .{ 0xD4, 0x50, 0x6E }, .{ 0x7A, 0xC0, 0xA0 }, .{ 0xE8, 0xC4, 0x6A },
        } };
        break :blk e;
    };

    var buf: [32768]u8 = undefined;
    const json = try render_to_json(&buf, &game);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    const ent = parsed.value.object.get("game").?.object
        .get("entities").?.array.items[0].object;

    // The NAME, not the ordinal: game.js keys its sprite sheets by it.
    try testing.expectEqualStrings("gold", ent.get("critter").?.string);

    const led = ent.get("led").?.array;
    try testing.expectEqual(@as(usize, 3), led.items.len);
    try testing.expectEqual(@as(i64, 0xD4), led.items[0].array.items[0].integer);
    try testing.expectEqual(@as(i64, 0x6E), led.items[0].array.items[2].integer);
    try testing.expectEqual(@as(i64, 0xA0), led.items[1].array.items[2].integer);
    try testing.expectEqual(@as(i64, 0xE8), led.items[2].array.items[0].integer);
}

test "a player's carried powerups reach the renderer, by name" {
    // web/game.js `drawSeatPowerups` reads exactly
    // `e.powerups.neutralizer_canister` and stamps that many squares through
    // the seat panel's top border.  The field is hand-copied into JsonEntity
    // from a bare array, which is the drift this file's tests exist to catch:
    // a kind appended to PowerupKind without a matching field here would
    // silently keep drawing the old one.
    var game = GameState{};
    game.snapshot.grid_rows = 3;
    game.snapshot.grid_cols = 3;
    game.snapshot.entity_count = 1;
    game.snapshot.entities[0] = blk: {
        var e = proto.EntitySnapshot.blank;
        e.entity = 9;
        e.owner = 0;
        e.powerups[@intFromEnum(c.PowerupKind.neutralizer_canister)] = 4;
        break :blk e;
    };

    var buf: [32768]u8 = undefined;
    const json = try render_to_json(&buf, &game);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    const ent = parsed.value.object.get("game").?.object
        .get("entities").?.array.items[0].object;
    try testing.expectEqual(
        @as(i64, 4),
        ent.get("powerups").?.object.get("neutralizer_canister").?.integer,
    );
}

test "a boardless player carries no powerups, not an absent field" {
    // Unlike the cosmetic fields, "carries none" is a REAL answer rather than
    // a missing one: a browser tab has no badge and so genuinely has zero
    // canisters.  The renderer draws no squares either way, but the field has
    // to be there for it to read — an absent one would be a JS undefined
    // walking into the square count.
    var game = GameState{};
    game.snapshot.grid_rows = 3;
    game.snapshot.grid_cols = 3;
    game.snapshot.entity_count = 1;
    game.snapshot.entities[0] = blk: {
        var e = proto.EntitySnapshot.blank;
        e.entity = 9;
        e.owner = 0;
        break :blk e;
    };

    var buf: [32768]u8 = undefined;
    const json = try render_to_json(&buf, &game);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    const ent = parsed.value.object.get("game").?.object
        .get("entities").?.array.items[0].object;
    try testing.expectEqual(
        @as(i64, 0),
        ent.get("powerups").?.object.get("neutralizer_canister").?.integer,
    );
}

test "a boardless player's appearance is absent, not black" {
    // The whole point of the optional. A browser tab has no badge, and the
    // renderer must be able to tell that apart from a badge whose LEDs are
    // genuinely off — the first draws the authored art, the second would
    // paint the creature solid black.
    //
    // The frame is written with `emit_null_optional_fields = false`, so
    // "absent" is a MISSING KEY rather than a null. game.js reads both the
    // same way (`e.led ?? null`), and this pins which one it actually gets.
    var game = GameState{};
    game.snapshot.grid_rows = 3;
    game.snapshot.grid_cols = 3;
    game.snapshot.entity_count = 1;
    game.snapshot.entities[0] = proto.EntitySnapshot.blank;

    var buf: [32768]u8 = undefined;
    const json = try render_to_json(&buf, &game);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    const ent = parsed.value.object.get("game").?.object
        .get("entities").?.array.items[0].object;
    try testing.expect(ent.get("critter") == null);
    try testing.expect(ent.get("led") == null);
    try testing.expect(ent.get("brood_seed") == null);
}

test "a player's brood seed reaches the renderer, whole" {
    // web/game.js rolls this owner's BABY palette from `e.brood_seed`, so the
    // number has to arrive EXACTLY: the roll is a PRNG walk, and a seed that
    // is off by one bit is not a near-miss colour, it is a different family.
    //
    // Two hazards this pins down, both of which JSON invites:
    //   - it must be a NUMBER, not a hex string — game.js feeds it straight
    //     to mulberry32, and "1f3c9a04" would seed as NaN;
    //   - it must survive the top of the u32 range, where a signedness slip
    //     anywhere on the path shows up as a negative and nowhere else.
    var game = GameState{};
    game.snapshot.grid_rows = 3;
    game.snapshot.grid_cols = 3;
    game.snapshot.entity_count = 1;
    game.snapshot.entities[0] = blk: {
        var e = proto.EntitySnapshot.blank;
        e.entity = 9;
        e.owner = 0;
        e.appearance = .{ .brood_seed = 0xFFEE_DDCC };
        break :blk e;
    };

    var buf: [32768]u8 = undefined;
    const json = try render_to_json(&buf, &game);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    const ent = parsed.value.object.get("game").?.object
        .get("entities").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 0xFFEE_DDCC), ent.get("brood_seed").?.integer);

    // And it travels INDEPENDENTLY of the adult palette. The badge derives
    // its seed from its uid, so it has one before anyone onboards it and the
    // wire has no business deciding when that counts. Whether a brood with no
    // LEDs behind it is actually painted is the renderer's call, and it
    // declines (web/game.js broodPalette) — but it gets to make that call
    // only because the seat arrives with both facts, not one.
    try testing.expect(ent.get("led") == null);
}
