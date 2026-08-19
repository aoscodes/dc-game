const std = @import("std");
const proto = @import("shared").protocol;
const c = @import("shared").components;
const inp = @import("input.zig");

/// JSON serialisation for ComboSlot.  Emits {"action":"dispense"}.
///
/// Kept as an object (rather than a bare string) because slots are keyed by
/// field name on the JS side, and a combo slot may grow more attributes.
const JsonComboSlot = struct {
    slot: c.ComboSlot,

    pub fn jsonStringify(self: JsonComboSlot, jws: anytype) !void {
        try jws.beginObject();
        switch (self.slot) {
            .action => |a| {
                try jws.objectField("action");
                try jws.write(@tagName(a));
            },
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
        // Sized for the largest render frame: a MAX_GRID_CELLS grid of cell
        // strings plus the full entity/stats payload.
        var frame_buf: [32768]u8 = undefined;
        var w = std.io.Writer.fixed(&frame_buf);
        write_render_inner(&w, phase, lobby, game) catch return;
        w.writeByte('\n') catch return;
        const out = std.fs.File.stdout();
        out.writeAll(w.buffered()) catch return;
        game.last_action_count = 0;
        game.fizzle_count = 0;
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
    /// Player ids whose spells fizzled since the last render write
    /// (transient, drained per frame like last_actions).
    fizzles: [proto.MAX_PLAYERS]u8 = undefined,
    fizzle_count: u8 = 0,
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

    // Per-entity slot buffers for JSON serialisation.  Typed and submitted
    // combos are independent (a player may hold both), so each gets a buffer.
    var slot_bufs: [proto.MAX_ENTITIES_WIRE][c.MAX_COMBO_LEN]JsonComboSlot = undefined;
    var sub_slot_bufs: [proto.MAX_ENTITIES_WIRE][c.MAX_COMBO_LEN]JsonComboSlot = undefined;
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
        for (e.submitted_slots[0..e.submitted_len], 0..) |s, j| {
            sub_slot_bufs[i][j] = .{ .slot = s };
        }
        entities_buf[i] = .{
            .id = e.entity,
            .kind = e.kind,
            .owner = e.owner,
            .casts_left = e.casts_left,
            .last_action = anim,
            .combo = slot_bufs[i][0..e.combo_len],
            .submitted = sub_slot_bufs[i][0..e.submitted_len],
            .cursor_row = e.cursor_row,
            .cursor_col = e.cursor_col,
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
        .healable = tiers(te.healable),
        .score_added = te.score_added,
    } else null;

    // Convert pending combo slots for JSON.
    var pending_slots_buf: [c.MAX_COMBO_LEN]JsonComboSlot = undefined;
    for (game.pending_combo.slots[0..game.pending_combo.len], 0..) |s, i| {
        pending_slots_buf[i] = .{ .slot = s };
    }

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
                    .name = ps.name[0..ps.name_len],
                    .casts = ps.casts,
                    .cells_covered = ps.cells_covered,
                    .cells_neutralized = ps.cells_neutralized,
                    .recipe_casts = ps.recipe_casts,
                    .fizzles = ps.fizzles,
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
                    .medicine = tiers(ms.feast.medicine_dispensed),
                    .healed = tiers(ms.feast.medicine_healed),
                    .neutralized = tiers(ms.feast.neutralized),
                    .escaped = tiers(ms.feast.hazard_escaped),
                    .neutral = ms.feast.neutral_consumed,
                    .hunger_normal = ms.feast.hunger_normal,
                    .hunger_extra = ms.feast.hunger_extra,
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
        .lobby = if (phase == .lobby) JsonLobby{
            .join_code = lobby.update.join_code[0..jc_end],
            .player_id = lobby.update.player_id,
            .ready = lobby.ready,
            .players = players_buf[0..lobby.update.player_count],
        } else null,
        .game = if (phase == .game) JsonGame{
            .encounter = game.encounter_label[0..game.encounter_label_len],
            .player_id = game.player_id,
            .casts_per_turn = game.casts_per_turn,
            .pending_combo = pending_slots_buf[0..game.pending_combo.len],
            .turn = game.snapshot.turn,
            .tick = game.snapshot.tick,
            .entities = entities_buf[0..game.snapshot.entity_count],
            .hunger = .{
                .current = game.snapshot.hunger.current,
                .max = game.snapshot.hunger.max,
                .healable = tiers(game.snapshot.hunger_healable),
            },
            .score = game.snapshot.score,
            .grid_rows = game.snapshot.grid_rows,
            .grid_cols = game.snapshot.grid_cols,
            .grid = grid_buf[0..grid_len],
            .reservoir = game.snapshot.reservoir,
            .fizzles = game.fizzles[0..game.fizzle_count],
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
fn cell_name(cell: c.SlimeCell) []const u8 {
    return switch (cell) {
        .empty => "empty",
        .neutral => "neutral",
        .neutralized => "defused",
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
    lobby: ?JsonLobby,
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
    medicine: JsonTiers,
    healed: JsonTiers,
    neutralized: JsonTiers,
    escaped: JsonTiers,
    neutral: u16,
    hunger_normal: u16,
    hunger_extra: u16,
};

const JsonPlayerStats = struct {
    name: []const u8,
    casts: u16,
    /// Hazard cells this player's stamps downgraded, and how many of those
    /// went all the way to defused.
    cells_covered: u16,
    cells_neutralized: u16,
    recipe_casts: u16,
    fizzles: u16,
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

const JsonLobby = struct {
    join_code: []const u8,
    player_id: u8,
    ready: bool,
    players: []const JsonPlayer,
};

const JsonPlayer = struct {
    id: u8,
    name: []const u8,
    kind: c.EntityKind,
    ready: bool,
    connected: bool,
};

/// Hunger bar: current fills toward max; `healable` = the per-tier portions
/// medicine can heal.  Healing is symmetrical: only tier-X medicine touches
/// the tier-X bucket.
const JsonHunger = struct {
    current: u16,
    max: u16,
    healable: JsonTiers,
};

const JsonGame = struct {
    encounter: []const u8,
    player_id: u8,
    /// Casts each player gets per turn, from game_start.
    casts_per_turn: u8,
    pending_combo: []const JsonComboSlot,
    /// The turn now being played, 1-based.
    turn: u16,
    tick: u32,
    entities: []const JsonEntity,
    hunger: JsonHunger,
    score: u32,
    /// The authoritative slime grid: `grid_rows * grid_cols` cell names in
    /// row-major order, row 0 = TOP.  Index a cell as row * grid_cols + col.
    grid_rows: u8,
    grid_cols: u8,
    grid: []const []const u8,
    /// Slime still waiting off-grid; it refills the field after each feast.
    reservoir: u32,
    /// Player ids whose spells fizzled since the previous frame (transient).
    fizzles: []const u8,
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

/// The turn-end feast: the whole field was devoured at once.  `healable` is the
/// part of `hunger_added` that medicine can still undo, split by the tier that
/// caused it.  This is what drives the client's devour animation.
const JsonTurnEnded = struct {
    /// The turn that just ended (the frame after it carries turn + 1).
    turn: u16,
    cells_eaten: u16,
    hunger_added: u16,
    healable: JsonTiers,
    score_added: u32,
};

const JsonEntity = struct {
    id: u32,
    kind: c.EntityKind,
    owner: u8,
    /// Casts this player has left in the current turn.
    casts_left: u8,
    last_action: ?c.ActionAnimation,
    /// The combo being typed right now.
    combo: []const JsonComboSlot,
    /// The team-recipe half this player is holding, waiting for a partner to
    /// complete it (empty when none).  Clients preview from this in preference
    /// to `combo`: it is what a partner would complete.
    submitted: []const JsonComboSlot,
    /// Where this player is aiming.  While a half is held this is the captured
    /// ANCHOR (where the completed shape will land); otherwise it is the live
    /// cursor.  Sent for every player so teammates can see each other's aim.
    cursor_row: u8,
    cursor_col: u8,
};
