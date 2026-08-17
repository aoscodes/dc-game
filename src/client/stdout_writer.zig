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
        game.cast_event_count = 0;
        game.agents_dispensed_count = 0;
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

/// Cast-loop lifecycle event (transient, drained per frame).
/// Trace: committed → (replaced | grouped)* → fired.
pub const CastEvent = union(enum) {
    grouped: proto.CastGrouped,
    replaced: proto.CastReplaced,
    fired: proto.CastFired,
};

pub const GameState = struct {
    snapshot: proto.GameState = proto.GameState.blank,
    player_id: u8 = 0xFF,
    pending_combo: inp.ComboBuffer = .{},
    /// Per-cast buffer length in ms, as announced by the server in game_start.
    cast_buffer_ms: u32 = 0,
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
    /// Cast-loop events since the last render write (transient).
    cast_events: [16]CastEvent = undefined,
    cast_event_count: u8 = 0,
    /// Dispense outcomes since the last render write (transient): what each
    /// converted batch's agents were able to transmute.
    agents_dispensed: [16]proto.AgentsDispensed = undefined,
    agents_dispensed_count: u8 = 0,
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
            .casts_used = e.casts_used,
            .lock_ms = e.lock_ms,
            .cast_ms = e.cast_ms,
            .last_action = anim,
            .combo = slot_bufs[i][0..e.combo_len],
            .submitted = sub_slot_bufs[i][0..e.submitted_len],
        };
    }

    // Convert transient recipe-fired events for JSON.
    var recipes_buf: [16]JsonRecipeFired = undefined;
    for (game.recipes_fired[0..game.recipe_count], 0..) |rf, i| {
        recipes_buf[i] = .{ .kind = rf.kind, .index = rf.index };
    }

    // Convert transient dispense outcomes for JSON.  One entry PER COLOR per
    // event (colors with no agents are skipped), so the renderer can float a
    // separate label per element without re-deriving anything.
    var dispensed_buf: [16 * c.Element.size]JsonAgentsDispensed = undefined;
    var dispensed_len: usize = 0;
    for (game.agents_dispensed[0..game.agents_dispensed_count]) |ad| {
        for (ad.dispensed, ad.transmuted, 0..) |n, t, ci| {
            if (n == 0) continue;
            const color: c.Element = @enumFromInt(ci);
            dispensed_buf[dispensed_len] = .{
                .color = color,
                .dispensed = n,
                .transmuted = t,
            };
            dispensed_len += 1;
        }
    }

    // Convert transient cast-loop events for JSON.
    var cast_events_buf: [16]JsonCastEvent = undefined;
    for (game.cast_events[0..game.cast_event_count], 0..) |ev, i| {
        cast_events_buf[i] = switch (ev) {
            .grouped => |g| .{
                .type = "grouped",
                .player_mask = g.player_mask,
                .fires_in_ms = g.fires_in_ms,
            },
            .replaced => |rp| .{ .type = "replaced", .player_id = rp.player_id },
            .fired => |f| .{
                .type = "fired",
                .spell_count = f.spell_count,
                .player_mask = f.player_mask,
            },
        };
    }

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

    // Lil Guys: which flat cell index each is biting, and how soon.
    var lil_guys_buf: [proto.MAX_LIL_GUYS_WIRE]JsonLilGuy = undefined;
    for (game.snapshot.lil_guys[0..game.snapshot.lil_guy_count], 0..) |lg, i| {
        lil_guys_buf[i] = .{
            .id = lg.entity,
            .target = if (lg.target == c.LilGuy.NO_TARGET) null else lg.target,
            .bite_ms = lg.bite_ms,
        };
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
                    .dispense = colors(ps.dispense_slots),
                    .medicine = colors(ps.medicine_slots),
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
                    .agents = colors(ms.feast.agents_dispensed),
                    .medicine = colors(ms.feast.medicine_dispensed),
                    .healed = colors(ms.feast.medicine_healed),
                    .neutralized = colors(ms.feast.neutralized),
                    .escaped = colors(ms.feast.modified_escaped),
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
            .cast_buffer_ms = game.cast_buffer_ms,
            .pending_combo = pending_slots_buf[0..game.pending_combo.len],
            .cast_timer = game.snapshot.cast_timer,
            .tick = game.snapshot.tick,
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
            .grid_rows = game.snapshot.grid_rows,
            .grid_cols = game.snapshot.grid_cols,
            .grid = grid_buf[0..grid_len],
            .reservoir = game.snapshot.reservoir,
            .lil_guys = lil_guys_buf[0..game.snapshot.lil_guy_count],
            .fizzles = game.fizzles[0..game.fizzle_count],
            .recipes_fired = recipes_buf[0..game.recipe_count],
            .cast_events = cast_events_buf[0..game.cast_event_count],
            .agents_dispensed = dispensed_buf[0..dispensed_len],
        } else null,
        .score = if (phase == .game_over) game.final_score else null,
        .stats = json_stats,
    };

    try std.json.Stringify.value(frame, .{ .emit_null_optional_fields = false }, w);
}

/// One slime cell as a compact renderer-facing name: "empty", "neutral", or
/// a color suffixed with its state ("red", "red_n" for neutralized red).
fn cell_name(cell: c.SlimeCell) []const u8 {
    return switch (cell) {
        .empty => "empty",
        .neutral => "neutral",
        .modified => |e| switch (e) {
            .red => "red",
            .green => "green",
            .yellow => "yellow",
            .blue => "blue",
        },
        .neutralized => |e| switch (e) {
            .red => "red_n",
            .green => "green_n",
            .yellow => "yellow_n",
            .blue => "blue_n",
        },
    };
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

/// Match-wide feast totals: what was dispensed, healed, neutralized and eaten
/// over the whole encounter.
const JsonFeastStats = struct {
    agents: JsonColors,
    medicine: JsonColors,
    healed: JsonColors,
    neutralized: JsonColors,
    escaped: JsonColors,
    neutral: u16,
    hunger_normal: u16,
    hunger_extra: u16,
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

/// One Lil Guy: the flat grid index it is biting (null = nothing to bite,
/// the grid is empty) and how long until the bite lands.
const JsonLilGuy = struct {
    id: u32,
    target: ?u16,
    bite_ms: u16,
};

const JsonGame = struct {
    encounter: []const u8,
    player_id: u8,
    /// Per-cast buffer length in ms, from game_start.
    cast_buffer_ms: u32,
    pending_combo: []const JsonComboSlot,
    /// The SOONEST pending cast's remaining buffer, or -1 when nothing is
    /// pending (idle).
    cast_timer: f32,
    tick: u32,
    entities: []const JsonEntity,
    hunger: JsonHunger,
    score: u32,
    /// The authoritative slime grid: `grid_rows * grid_cols` cell names in
    /// row-major order, row 0 = TOP.  Index a cell as row * grid_cols + col.
    grid_rows: u8,
    grid_cols: u8,
    grid: []const []const u8,
    /// Slime still waiting off-grid; it refills emptied cells from the top.
    reservoir: u32,
    /// One Lil Guy per connected player, each biting a real grid cell.
    lil_guys: []const JsonLilGuy,
    /// Player ids whose spells fizzled since the previous frame (transient).
    fizzles: []const u8,
    /// Recipes fired since the previous frame (transient).  `index` refers
    /// to the balance recipe table for `kind` (JS resolves labels from the
    /// fetched data/balance.json, same order).
    recipes_fired: []const JsonRecipeFired,
    /// Cast-loop events since the previous frame (transient).
    cast_events: []const JsonCastEvent,
    /// Dispense outcomes since the previous frame (transient), one per color
    /// per converted batch.
    agents_dispensed: []const JsonAgentsDispensed,
};

/// One color's dispense outcome.  `dispensed - transmuted` is the surplus that
/// found no on-grid target and was wasted.
const JsonAgentsDispensed = struct {
    color: c.Element,
    dispensed: u16,
    transmuted: u16,
};

const JsonRecipeFired = struct {
    kind: proto.RecipeKind,
    index: u8,
};

/// One cast-loop event.  `type` is "grouped" | "replaced" |
/// "fired"; unused fields are omitted (emit_null_optional_fields=false).
const JsonCastEvent = struct {
    type: []const u8,
    player_id: ?u8 = null,
    fires_in_ms: ?u32 = null,
    spell_count: ?u8 = null,
    player_mask: ?u8 = null,
};

const JsonEntity = struct {
    id: u32,
    kind: c.EntityKind,
    owner: u8,
    /// 1 if this player has a cast pending, else 0.
    casts_used: u8,
    /// Remaining cast-lock cooldown in ms (0 = unlocked).
    lock_ms: u16,
    /// Remaining buffer of this player's pending cast in ms (0 = none pending).
    cast_ms: u16,
    last_action: ?c.ActionAnimation,
    /// The combo being typed right now (empty while a cast buffers).
    combo: []const JsonComboSlot,
    /// The committed combo currently buffering (empty when none pending).
    /// Clients preview from this in preference to `combo`: it is what will
    /// actually fire.
    submitted: []const JsonComboSlot,
};
