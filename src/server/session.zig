//! Game session: lobby management + authoritative Slime Feast game loop.
//!
//! One Session instance per active game room.  The session owns:
//!   - The ECS World (player entities + Lil Guy entities)
//!   - The authoritative slime field (grid + reservoir)
//!   - The per-player connection transports
//!   - The state machine (lobby → playing → ended)
//!   - The match PRNG: every random choice in the game comes from this one
//!     seeded generator, so a session is reproducible from its seed.
//!
//! ## Slime Feast turn loop
//!
//! There is ONE slime grid per game (`slime.SlimeField`), sized by the global
//! `balance.slime_grid`.  The encounter's slime starts in the off-grid
//! reservoir; whatever fits is placed on the grid.  The grid is
//! server-authoritative and transmitted whole in `game_state`, so every client
//! renders identical slime.
//!
//! A TURN is: everyone spends their cast budget, then the Lil Guys eat the
//! WHOLE FIELD at once and a fresh field arrives.  Nothing is on a clock —
//! `tick` only drains input and broadcasts, so a session advances solely by
//! what players do.
//!
//! CASTING.  Each player gets `balance.casts_per_turn` casts per turn.  A
//! submit RESOLVES IMMEDIATELY:
//!   - It matches a player recipe → the shape stamps now and its medicine heals
//!     now.
//!   - It completes a team recipe against teammates' HELD halves → the whole
//!     group resolves now, anchored at the joiner's cursor.
//!   - It is an unpaired team half → it is HELD (`cast_committed`) until a
//!     partner completes it or the turn ends.
//!   - It matches nothing → `cast_fizzled`, and the budget is NOT spent.
//! Stamping downgrades every covered hazard cell one tier (red -> yellow ->
//! green -> defused); coverage off the grid edge, or on a cell with nothing
//! left to downgrade, is wasted.  A stamp never empties a cell.
//!
//! TURN END.  When every connected player's budget is spent, the field is eaten
//! in ONE bulk feast: normal hunger per unit plus healable extra per unit still
//! hazardous, and score for neutral + defused units.  Held halves then fizzle
//! (their budget stays spent), the grid is cleared and refilled from the
//! reservoir, budgets reset, and `turn_ended` is broadcast.
//!
//! The encounter's end is checked ONLY at turn end: the hunger bar filling is a
//! loss, an exhausted field + reservoir is a win.  Either way the final shared
//! score is broadcast via game_over.

const std = @import("std");
const ecs = @import("ecs_zig");
const shared = @import("shared");
const c = shared.components;
const proto = shared.protocol;
const logic = shared.game_logic;
const enc = shared.encounter;
const cfg_mod = shared.config;
const slime = shared.slime;
const dbg = @import("debug_zig");

/// Profiler phases of one tick.  The feast is not a tick phase: it happens at
/// turn end, driven by input, not by elapsed time.
pub const TickPhase = enum { drain, broadcast };

pub const PlayerTeam = struct {};

pub const GameWorld = ecs.World(
    .{
        .kind = c.Kind,
        .owner = c.Owner,
        .player_marker = c.PlayerMarker,
    },
    .{
        .player_team = PlayerTeam,
    },
);

pub const MAX_PLAYERS = proto.MAX_PLAYERS;

/// "No entity" sentinel for slot references.
pub const NO_ENTITY: ecs.Entity = std.math.maxInt(ecs.Entity);

pub const PlayerSlot = struct {
    occupied: bool = false,
    connected: bool = false,
    player_id: u8,
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: u8 = 0,
    ready: bool = false,
    entity: ecs.Entity = std.math.maxInt(ecs.Entity),
    transport: ?shared.Transport = null,
    queue_lock: std.Thread.Mutex = .{},
    msg_queue: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator = undefined,
};

pub const SessionPhase = enum { lobby, playing };

pub const Session = struct {
    allocator: std.mem.Allocator,
    join_code: [6]u8,
    /// Loaded balance + encounter data; owned by the caller and must outlive
    /// the session.
    cfg: *const cfg_mod.Config,
    players: [MAX_PLAYERS]PlayerSlot,
    player_count: u8 = 0,
    phase: SessionPhase = .lobby,
    world: GameWorld,
    tick_count: u32 = 0,
    current_encounter: ?*const enc.Encounter = null,
    /// Total Hunger bar.  Fills as slime is consumed; full = encounter over.
    hunger: c.Health = .{ .current = 0, .max = 0 },
    /// Portion of `hunger.current` attributable to hazard slime eaten while
    /// still a hazard, tracked per difficulty tier (Tier ordinal).  Only
    /// matching-tier (symmetrical) Medicine can heal each bucket.
    hunger_healable: [c.Tier.size]u16 = [_]u16{0} ** c.Tier.size,
    /// The authoritative slime field: grid + off-grid reservoir.  Empty until
    /// start_game_encounter sizes it from balance.slime_grid.
    field: slime.SlimeField,
    /// Slime the encounter started with — the denominator of the final report.
    slime_total: u32 = 0,
    /// Shared team score: neutral slime units consumed.
    score: u32 = 0,
    /// The turn now being played (1-based; 0 until the game starts).
    turn: u16 = 0,
    /// Casts each player has left this turn.  The turn ends when every
    /// CONNECTED player's entry is 0, so this is the only turn-progress state.
    casts_left: [MAX_PLAYERS]u8 = [_]u8{0} ** MAX_PLAYERS,
    /// Live combo preview per player (latest edit wins; Escape cancels).
    action_pool: [MAX_PLAYERS]?c.ActionCombo,
    /// Each player's HELD team half: a cast that was accepted but needs a
    /// partner to resolve (null = none).  Cleared when a partner completes the
    /// recipe, and at turn end (where it fizzles).
    held_pool: [MAX_PLAYERS]?c.ActionCombo = [_]?c.ActionCombo{null} ** MAX_PLAYERS,
    /// Each player's aiming cursor, as a flat grid index.  SERVER-OWNED: the
    /// client sends directions and this clamps, so a cursor is always a valid
    /// cell of the current grid and no client can aim out of bounds.
    cursors: [MAX_PLAYERS]u16 = [_]u16{0} ** MAX_PLAYERS,
    /// Where each cast was aimed, captured at SUBMIT time.  A held half lands
    /// where the player was aiming when they committed it, so re-aiming while
    /// waiting for a partner cannot retarget it.
    cast_anchors: [MAX_PLAYERS]u16 = [_]u16{0} ** MAX_PLAYERS,
    /// Tuning stats accumulated over the match; broadcast with game_over.
    /// `players` is indexed by player_id during play and compacted (dense,
    /// names filled) in end_game.
    stats: proto.MatchStats = .{},
    /// The ONE source of randomness for the match: cell placement, target
    /// selection and neutralize subsets all draw from it, so a session
    /// replays exactly from its seed.
    prng: std.Random.DefaultPrng,
    profiler: dbg.Profiler(TickPhase) = dbg.Profiler(TickPhase).init(),

    /// `seed` pins the match PRNG.  Callers that want reproducible games
    /// (tests, replays) pass a fixed value; production passes a clock seed
    /// via `init`.
    pub fn init_seeded(
        allocator: std.mem.Allocator,
        join_code: [6]u8,
        cfg: *const cfg_mod.Config,
        seed: u64,
    ) !Session {
        var players: [MAX_PLAYERS]PlayerSlot = undefined;
        for (&players, 0..) |*p, i| {
            p.* = PlayerSlot{
                .player_id = @intCast(i),
                .allocator = allocator,
            };
        }
        var world = try GameWorld.init(allocator);
        set_world_system_signatures(&world);
        return Session{
            .allocator = allocator,
            .join_code = join_code,
            .cfg = cfg,
            .players = players,
            .world = world,
            // Sized properly at game start; a 1x1 empty field until then.
            .field = .{ .grid = c.SlimeGrid.init(1, 1), .reservoir = .{} },
            .action_pool = [_]?c.ActionCombo{null} ** MAX_PLAYERS,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn init(
        allocator: std.mem.Allocator,
        join_code: [6]u8,
        cfg: *const cfg_mod.Config,
    ) !Session {
        return init_seeded(allocator, join_code, cfg, @bitCast(std.time.milliTimestamp()));
    }

    /// The match PRNG's interface.  Every random choice in the session goes
    /// through here so the whole game is reproducible from the seed.
    fn rand(self: *Session) std.Random {
        return self.prng.random();
    }

    pub fn deinit(self: *Session) void {
        self.world.deinit();
        for (&self.players) |*p| {
            p.queue_lock.lock();
            p.msg_queue.deinit(p.allocator);
            p.queue_lock.unlock();
        }
    }

    pub fn join(self: *Session, transport: shared.Transport, name: []const u8) ?u8 {
        for (&self.players) |*p| {
            if (!p.occupied) {
                p.occupied = true;
                p.connected = true;
                p.transport = transport;
                const n = @min(name.len, 16);
                @memcpy(p.name[0..n], name[0..n]);
                p.name_len = @intCast(n);
                p.ready = false;
                self.player_count += 1;
                return p.player_id;
            }
        }
        return null;
    }

    pub fn reconnect(self: *Session, player_id: u8, transport: shared.Transport) bool {
        if (player_id >= MAX_PLAYERS) return false;
        const p = &self.players[player_id];
        if (!p.occupied) {
            if (self.phase != .lobby) return false;
            p.occupied = true;
            self.player_count += 1;
        }
        p.connected = true;
        p.transport = transport;
        return true;
    }

    pub fn disconnect(self: *Session, player_id: u8) void {
        if (player_id >= MAX_PLAYERS) return;
        const p = &self.players[player_id];
        p.connected = false;
        p.transport = null;
        if (self.phase == .lobby) {
            p.occupied = false;
            p.ready = false;
            p.name_len = 0;
            self.player_count -= 1;
        }
    }

    pub fn all_ready(self: *const Session) bool {
        var connected: u8 = 0;
        var ready: u8 = 0;
        for (&self.players) |*p| {
            if (!p.connected) continue;
            connected += 1;
            if (p.ready) ready += 1;
        }
        return connected > 0 and connected == ready;
    }

    pub fn start_game(self: *Session, encounter_label: []const u8) !void {
        const encounter = self.cfg.encounters.find(encounter_label) orelse
            self.cfg.encounters.default();
        try self.start_game_encounter(encounter);
    }

    pub fn start_game_encounter(self: *Session, encounter: *const enc.Encounter) !void {
        self.world.deinit();
        self.world = try GameWorld.init(self.allocator);
        set_world_system_signatures(&self.world);
        for (&self.action_pool) |*a| a.* = @as(?c.ActionCombo, null);
        self.stats = .{
            .player_recipe_count = @intCast(self.cfg.balance.player_recipes.len),
            .team_recipe_count = @intCast(self.cfg.balance.team_recipes.len),
        };
        self.tick_count = 0;

        self.phase = .playing;
        self.current_encounter = encounter;
        for (&self.held_pool) |*hp| hp.* = null;
        self.cast_anchors = [_]u16{0} ** MAX_PLAYERS;
        self.turn = 1;
        self.reset_budgets();

        self.hunger = .{ .current = 0, .max = encounter.hunger_max };
        self.hunger_healable = [_]u16{0} ** c.Tier.size;
        self.score = 0;
        self.slime_total = encounter.total_units();
        self.field = slime.SlimeField.init(
            self.cfg.balance.slime_grid,
            encounter.slime,
            self.rand(),
        );
        // Everyone starts aiming at the middle of the field: the least
        // arbitrary opening position, and always a valid cell.
        const centre = self.field.grid.index(
            self.cfg.balance.slime_grid.rows / 2,
            self.cfg.balance.slime_grid.cols / 2,
        );
        self.cursors = [_]u16{centre} ** MAX_PLAYERS;

        std.log.info("game start — encounter: {s} slime={} grid={}x{} hunger_max={} casts/turn={}", .{
            encounter.label,
            self.slime_total,
            self.field.grid.rows,
            self.field.grid.cols,
            self.hunger.max,
            self.cfg.balance.casts_per_turn,
        });
        try self.spawn_players();
    }

    /// Give every connected player their avatar entity.
    ///
    /// The Lil Guys have no server representation: they eat the whole field at
    /// turn end regardless of how many there are, so they are purely a client
    /// animation of `turn_ended`.
    fn spawn_players(self: *Session) !void {
        for (&self.players) |*p| {
            if (!p.occupied or !p.connected) {
                p.entity = NO_ENTITY;
                continue;
            }
            const e = self.world.create_entity();
            p.entity = e;
            self.world.add_component(e, c.Kind{ .tag = .player });
            self.world.add_component(e, c.Owner{ .player_id = p.player_id });
            self.world.add_component(e, c.PlayerMarker{});
        }
    }

    /// Refill every player's cast budget for a new turn.  Budgets are set for
    /// ALL slots, connected or not: a player who joins or reconnects mid-turn
    /// gets a usable budget rather than a stuck 0.
    fn reset_budgets(self: *Session) void {
        self.casts_left = [_]u8{self.cfg.balance.casts_per_turn} ** MAX_PLAYERS;
    }

    /// One server tick: drain queued client input (which is what actually
    /// advances the game) and broadcast the resulting state.
    ///
    /// `dt` is unused: the turn loop has no timers.  It stays in the signature
    /// because the server's tick driver is time-based, and dropping it would
    /// only push the same unused value up a layer.
    pub fn tick(self: *Session, dt: f32) !void {
        _ = dt;

        self.profiler.begin(.drain);
        try self.drain_queues();
        self.profiler.end(.drain);

        if (self.phase != .playing) return;

        self.tick_count += 1;

        // A disconnect can be what makes every REMAINING player spent, and
        // disconnects arrive outside the cast path — so re-check here, after
        // input is drained, rather than only on submit.
        try self.maybe_end_turn();
        if (self.phase != .playing) return;

        self.profiler.begin(.broadcast);
        try self.broadcast_game_state();
        self.profiler.end(.broadcast);

        if (self.profiler.should_report(200)) {
            self.profiler.report_stderr("session tick");
        }
    }

    /// Resolve one submitted cast IMMEDIATELY.
    ///
    /// Returns whether the cast consumed a budget slot.  Three outcomes:
    ///   - It matches something on its own (a player recipe) → resolved now.
    ///   - It completes a team recipe against held halves → that whole group
    ///     resolves now, anchored at this player (the joiner).
    ///   - It is an unpaired team half → HELD (budget still spent, because the
    ///     player did commit it).
    /// A cast that matches nothing at all never reaches here: `submit_spell`
    /// fizzles it and keeps the budget.
    fn resolve_cast(self: *Session, player_id: u8, combo: c.ActionCombo) !void {
        // Everything currently on the table: this cast plus every held half.
        var batch: [MAX_PLAYERS]logic.Cast = undefined;
        var batch_len: usize = 0;
        var joiner_index: usize = 0;
        for (&self.held_pool, 0..) |*hp, pid| {
            const held = hp.* orelse continue;
            batch[batch_len] = .{ .player_id = @intCast(pid), .combo = held };
            batch_len += 1;
        }
        joiner_index = batch_len;
        batch[batch_len] = .{ .player_id = player_id, .combo = combo };
        batch_len += 1;

        var report = logic.MatchReport{};
        _ = logic.match_recipes(&self.cfg.balance, batch[0..batch_len], player_id, &report);

        if (report.consumed[joiner_index] == .none) {
            // Nothing this cast can do yet: it is a team half waiting for a
            // partner.  (A combo that matches nothing at all was already
            // fizzled by the caller.)
            self.held_pool[player_id] = combo;
            var buf: [4]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try proto.encode(fbs.writer(), .cast_committed, proto.CastCommitted{
                .player_id = player_id,
            });
            try self.broadcast_raw(fbs.getWritten());
            return;
        }

        // This cast resolves.  Everything it consumed leaves the table with it;
        // halves that contributed nothing stay held for a future partner.
        var resolved: [MAX_PLAYERS]logic.Cast = undefined;
        var resolved_len: usize = 0;
        for (batch[0..batch_len], 0..) |cast, bi| {
            if (report.consumed[bi] == .none) continue;
            if (cast.player_id != player_id) self.held_pool[cast.player_id] = null;
            resolved[resolved_len] = cast;
            resolved_len += 1;
        }

        try self.convert_batch(resolved[0..resolved_len], player_id);
    }

    /// True once every CONNECTED player has spent their budget.  Disconnected
    /// slots are ignored, so a player dropping out unblocks the turn instead of
    /// stalling it forever.
    ///
    /// An EMPTY room is never "spent": with nobody to cast, ending turns would
    /// spin the feast every tick and eat the encounter unattended.
    fn budgets_spent(self: *const Session) bool {
        var connected: u8 = 0;
        for (&self.players, 0..) |*p, pid| {
            if (!p.occupied or !p.connected) continue;
            connected += 1;
            if (self.casts_left[pid] > 0) return false;
        }
        return connected > 0;
    }

    /// End the turn if every connected player is out of casts.
    ///
    /// Called after each accepted cast and whenever the connected set shrinks,
    /// because both can make the condition true.
    fn maybe_end_turn(self: *Session) !void {
        if (self.phase != .playing) return;
        if (!self.budgets_spent()) return;
        try self.end_turn();
    }

    /// Settle the turn: the Lil Guys devour the WHOLE field, held halves
    /// fizzle, a fresh field arrives from the reservoir, and budgets refill.
    ///
    /// Order matters.  The feast is priced against the field as the casts left
    /// it, so it must happen BEFORE the refill; and the end condition is
    /// checked after the refill, because "field cleared" means the reservoir
    /// had nothing left to send.
    fn end_turn(self: *Session) !void {
        const feast = self.field.eat_all(&self.cfg.balance);
        const hunger_added = feast.hunger_total();
        logic.add_hunger(&self.hunger, hunger_added);
        for (&self.hunger_healable, feast.hunger_extra) |*bucket, extra| {
            const grown = @as(u32, bucket.*) + extra;
            bucket.* = @intCast(@min(grown, @as(u32, std.math.maxInt(u16))));
        }
        self.score += feast.score;
        self.record_feast(feast);

        // The feast is the ONLY thing that adds hunger, so it is the only
        // damage event in the game — announced pool-level (no actor), exactly
        // like medicine's heal.  Sent even at zero so the client's damage cue
        // is not silently conditional on the field having been dangerous.
        try self.broadcast_action_result(.{
            .tag = .damage,
            .actor_entity = std.math.maxInt(u32),
            .target_entity = std.math.maxInt(u32),
            .value = stat_u16(hunger_added),
        });

        // Halves nobody completed are lost — and the casts they cost are NOT
        // refunded: committing to a team play you could not finish is the risk.
        var fizzled_mask: u8 = 0;
        for (&self.held_pool, 0..) |*hp, pid| {
            if (hp.* == null) continue;
            hp.* = null;
            fizzled_mask |= @as(u8, 1) << @intCast(pid);
            self.stats.players[pid].fizzles +|= 1;
        }
        if (fizzled_mask != 0) try self.broadcast_fizzles(fizzled_mask);

        var healable: [c.Tier.size]u16 = undefined;
        for (&healable, feast.hunger_extra) |*h, extra| h.* = stat_u16(extra);

        var buf: [32]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .turn_ended, proto.TurnEnded{
            .turn = self.turn,
            .cells_eaten = feast.cells,
            .hunger_added = stat_u16(hunger_added),
            .healable = healable,
            .score_added = feast.score,
        });
        try self.broadcast_raw(fbs.getWritten());

        // A fresh field for the next turn; an empty reservoir simply means the
        // grid stays empty, which check_end reads as the encounter won.
        _ = self.field.fill(self.rand());

        std.log.info("turn {} ended — ate {} hunger+{} score+{} reservoir={}", .{
            self.turn,
            feast.cells,
            hunger_added,
            feast.score,
            self.field.reservoir.total(),
        });

        try self.check_end();
        if (self.phase != .playing) return;

        self.turn +|= 1;
        self.reset_budgets();
    }

    /// Broadcast one cast_fizzled per player in `mask`.
    fn broadcast_fizzles(self: *Session, mask: u8) !void {
        for (0..MAX_PLAYERS) |pid| {
            if (mask & (@as(u8, 1) << @intCast(pid)) == 0) continue;
            var buf: [4]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try proto.encode(fbs.writer(), .cast_fizzled, proto.CastFizzled{
                .player_id = @intCast(pid),
            });
            try self.broadcast_raw(fbs.getWritten());
        }
    }

    /// CONVERT one batch of resolving casts: recipes match within the batch,
    /// medicine heals right away (broadcasting a .heal action_result), and each
    /// matched recipe STAMPS its shape on the grid at the anchoring player's
    /// cursor — downgrading every covered hazard cell by one tier.  Each recipe
    /// fire and each stamp is broadcast.
    ///
    /// `joiner` is the player whose submit triggered this conversion; they aim
    /// any combined team shape (see match_recipes).
    fn convert_batch(self: *Session, batch: []const logic.Cast, joiner: ?u8) !void {
        if (batch.len == 0) return;

        var report = logic.MatchReport{};
        const outcome = logic.match_recipes(&self.cfg.balance, batch, joiner, &report);

        // Recipe stats: fire counts + per-player participation.  Each fire is
        // also broadcast so clients can show recipe floaters live.  Only the
        // loaded tables' entries are meaningful (arrays are cap-sized).
        for (self.cfg.balance.player_recipes, 0..) |_, ri| {
            const hit = report.player_hits[ri];
            self.stats.player_recipe_hits[ri] +|= hit;
            try self.broadcast_recipe_fired(.player, @intCast(ri), hit);
        }
        for (self.cfg.balance.team_recipes, 0..) |_, ri| {
            const hit = report.team_hits[ri];
            self.stats.team_recipe_hits[ri] +|= hit;
            try self.broadcast_recipe_fired(.team, @intCast(ri), hit);
        }
        for (batch, 0..) |cast, ci| {
            if (report.consumed[ci] != .none) {
                self.stats.players[cast.player_id].recipe_casts +|= 1;
            }
        }

        // Medicine heals immediately (already-accrued hazard-slime hunger).
        const healed = logic.apply_medicine(&self.hunger, &self.hunger_healable, outcome.medicine.medicine);
        const healed_total = logic.sum_u16(healed);
        if (healed_total > 0) {
            try self.broadcast_action_result(.{
                .tag = .heal,
                .actor_entity = std.math.maxInt(u32),
                .target_entity = std.math.maxInt(u32),
                .value = stat_u16(healed_total),
            });
        }

        // Stamp each shape where its caster was aiming when they committed.
        for (outcome.stamps()) |stamp| {
            try self.stamp_shape(stamp);
        }

        const fs = &self.stats.feast;
        for (&fs.medicine_dispensed, outcome.medicine.medicine) |*d, m| d.* +|= stat_u16(m);
        for (&fs.medicine_healed, healed) |*d, h| d.* +|= h;
    }

    /// Apply one matched shape to the grid at its anchoring player's cast
    /// cursor, then broadcast the resolved footprint and outcome.
    ///
    /// Anchoring uses `cast_anchors` (where the player aimed at SUBMIT time),
    /// not the live cursor: a cast that is already in flight must not follow
    /// the player as they re-aim for their next one.
    fn stamp_shape(self: *Session, stamp: logic.ShapeCast) !void {
        const anchor = self.cast_anchors[stamp.anchor_player];
        const grid = &self.field.grid;
        const row = grid.row_of(anchor);
        const col = grid.col_of(anchor);

        const outcome = self.field.apply_shape(stamp.shape, row, col);

        var msg = proto.ShapeCast{
            .caster = stamp.anchor_player,
            .downgraded = outcome.downgraded,
            .neutralized = outcome.neutralized,
            .off_grid = outcome.off_grid,
            .inert = outcome.inert,
        };
        // Send the RESOLVED cells so clients never re-derive placement and
        // cannot disagree with the server about what was hit.
        for (stamp.shape.offsets) |off| {
            const r = @as(i16, row) + off.d_row;
            const cl = @as(i16, col) + off.d_col;
            if (r < 0 or cl < 0 or r >= grid.rows or cl >= grid.cols) continue;
            if (msg.cell_count >= proto.MAX_SHAPE_CELLS_WIRE) break;
            msg.cells[msg.cell_count] = grid.index(@intCast(r), @intCast(cl));
            msg.cell_count += 1;
        }

        const fs = &self.stats.feast;
        for (&fs.cells_covered, outcome.downgraded) |*d, n| d.* +|= n;
        // Only a green cell can step all the way to defused, so every
        // neutralization is attributable to the green bucket.
        fs.neutralized[@intFromEnum(c.Tier.green)] +|= outcome.neutralized;
        const ps = &self.stats.players[stamp.anchor_player];
        ps.cells_covered +|= stat_u16(outcome.total_downgraded());
        ps.cells_neutralized +|= outcome.neutralized;

        var buf: [8 + 2 * proto.MAX_SHAPE_CELLS_WIRE + 4 * c.Tier.size + 8]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .shape_cast, msg);
        try self.broadcast_raw(fbs.getWritten());
    }

    /// Fold one whole-field feast into the match tuning stats.
    ///
    /// `neutralized` slime is deliberately NOT counted here: a defusal is
    /// credited to the cast that achieved it (see stamp_shape), so counting it
    /// again at the feast would double-count the same unit.
    fn record_feast(self: *Session, feast: slime.FeastOutcome) void {
        const fs = &self.stats.feast;
        fs.hunger_normal +|= stat_u16(feast.hunger_normal);
        for (feast.hunger_extra) |extra| fs.hunger_extra +|= stat_u16(extra);
        for (&fs.hazard_escaped, feast.escaped) |*d, e| d.* +|= e;
        // Defused units are NOT counted here: the cast that achieved the
        // defusal already recorded it (see stamp_shape), so counting them again
        // would double-count the same unit.
        fs.neutral_consumed +|= feast.neutral;
    }

    /// Broadcast `count` recipe_fired messages for one recipe table entry.
    fn broadcast_recipe_fired(self: *Session, kind: proto.RecipeKind, index: u8, count: u16) !void {
        var fired: u16 = 0;
        while (fired < count) : (fired += 1) {
            var buf: [4]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try proto.encode(fbs.writer(), .recipe_fired, proto.RecipeFired{
                .kind = kind,
                .index = index,
            });
            try self.broadcast_raw(fbs.getWritten());
        }
    }

    /// Record a committed cast into the tuning stats.  Coverage is credited
    /// later, when the shape actually lands (see stamp_shape) — a combo is
    /// just a name until then.
    fn record_cast_stats(self: *Session, pid: usize) void {
        self.stats.casts_total +|= 1;
        self.stats.players[pid].casts +|= 1;
    }

    fn drain_queues(self: *Session) !void {
        for (&self.players) |*p| {
            if (!p.connected) continue;
            p.queue_lock.lock();
            const data = p.msg_queue.items;
            if (data.len == 0) {
                p.queue_lock.unlock();
                continue;
            }
            var local_buf: [16384]u8 = undefined;
            const len = @min(data.len, local_buf.len);
            @memcpy(local_buf[0..len], data[0..len]);
            p.msg_queue.clearRetainingCapacity();
            p.queue_lock.unlock();

            var fbs = std.io.fixedBufferStream(local_buf[0..len]);
            while (fbs.pos < len) {
                const tag = proto.read_tag(fbs.reader()) catch break;
                self.handle_client_message(p.player_id, tag, &fbs) catch {};
            }
        }
    }

    fn handle_client_message(
        self: *Session,
        player_id: u8,
        tag: proto.MsgTag,
        fbs: *std.io.FixedBufferStream([]u8),
    ) !void {
        switch (tag) {
            .join_lobby => {
                const p = try proto.decode_join_lobby(fbs.reader());
                const slot = &self.players[player_id];
                const n = @min(p.name_len, 16);
                @memcpy(slot.name[0..n], p.name[0..n]);
                slot.name_len = @intCast(n);
                std.log.info("player {} name set: {s}", .{ player_id, slot.name[0..slot.name_len] });
                if (self.phase == .playing) {
                    // Late joiner: spawn their entity, then send them a
                    // game_start so their client enters game phase.  Existing
                    // players are unaffected — no lobby_update is broadcast.
                    try self.spawn_player_midgame(player_id);
                    try self.send_game_start_to(player_id);
                } else {
                    try self.broadcast_lobby_update();
                }
            },
            .ready_up => {
                const slot = &self.players[player_id];
                slot.ready = !slot.ready;
                std.log.info("player {} ready: {}", .{ player_id, slot.ready });
                try self.broadcast_lobby_update();
                if (self.all_ready()) {
                    std.log.info("all players ready — starting game", .{});
                    const default_label = self.cfg.encounters.default().label;
                    try self.start_game(default_label);
                    try self.broadcast_game_start(default_label);
                }
            },
            .choose_combo => {
                if (self.phase == .playing and player_id < MAX_PLAYERS) {
                    const p = try proto.decode_choose_combo(fbs.reader());
                    self.action_pool[player_id] = p.combo;
                    std.log.debug("player {} combo len={}", .{ player_id, p.combo.len });
                }
            },
            .cancel_combo => {
                if (self.phase == .playing and player_id < MAX_PLAYERS) {
                    self.action_pool[player_id] = null;
                    std.log.debug("player {} cancelled combo", .{player_id});
                }
            },
            .move_cursor => {
                // Always decode so the stream stays in sync for messages
                // queued after this one.
                const p = try proto.decode_move_cursor(fbs.reader());
                if (self.phase != .playing or player_id >= MAX_PLAYERS) return;
                const d = p.dir.delta();
                // Clamped, so any number of steps in any direction leaves the
                // cursor on a real cell.
                self.cursors[player_id] =
                    self.field.grid.step(self.cursors[player_id], d.d_row, d.d_col);
            },
            .submit_spell => {
                // Always decode so the stream stays in sync for any
                // messages queued after this one.
                const p = try proto.decode_submit_spell(fbs.reader());
                if (self.phase != .playing or player_id >= MAX_PLAYERS) return;
                // Out of casts this turn: silent ignore.  The turn is waiting
                // on someone else, and this player has nothing left to say.
                if (self.casts_left[player_id] == 0) return;

                // A combo that can produce nothing FIZZLES and costs nothing:
                // the budget only pays for casts that do something.
                if (!logic.combo_has_output(&self.cfg.balance, p.combo)) {
                    self.stats.players[player_id].fizzles +|= 1;
                    try self.broadcast_fizzles(@as(u8, 1) << @intCast(player_id));
                    return;
                }

                self.casts_left[player_id] -= 1;
                // Freeze the aim now: this cast lands where the player was
                // pointing when they committed it, however they move next.
                self.cast_anchors[player_id] = self.cursors[player_id];
                self.action_pool[player_id] = null; // clears the live preview
                self.record_cast_stats(player_id);

                const slot = &self.players[player_id];
                if (slot.entity != NO_ENTITY) {
                    try self.broadcast_action_result(.{
                        .tag = .cast,
                        .actor_entity = slot.entity,
                        .target_entity = std.math.maxInt(u32),
                        .value = 0,
                    });
                }

                // Resolves now, or is held as a team half awaiting a partner.
                try self.resolve_cast(player_id, p.combo);

                std.log.debug("player {} cast ({} left this turn)", .{
                    player_id, self.casts_left[player_id],
                });

                // Spending the last budget in the room settles the turn.
                try self.maybe_end_turn();
            },
            .reconnect => {},
            else => {},
        }
    }

    /// Saturating u32 → u16 for stats fields.
    fn stat_u16(v: u32) u16 {
        return @intCast(@min(v, std.math.maxInt(u16)));
    }

    /// Decide whether the encounter is over.  Called ONLY from `end_turn`:
    /// nothing between turns can move the hunger bar or the slime count, so
    /// there is no other moment where the answer can change.
    fn check_end(self: *Session) !void {
        if (self.phase != .playing) return;
        // Field-cleared wins ties: if the final feast fills the bar exactly,
        // the players still ate everything.
        if (self.field.is_exhausted()) {
            std.log.info("all slime consumed — encounter over, score={}", .{self.score});
            try self.end_game(.field_cleared);
        } else if (logic.hunger_full(self.hunger)) {
            std.log.info("hunger bar full — encounter over, score={}", .{self.score});
            try self.end_game(.hunger_full);
        }
    }

    fn end_game(self: *Session, reason: proto.EndReason) !void {
        std.log.info("game over — score: {} reason: {s}", .{ self.score, @tagName(reason) });
        self.phase = .lobby;
        // Reset ready flags so players must opt-in to the next game.
        for (&self.players) |*p| p.ready = false;

        // Finalise the tuning report.
        self.stats.reason = reason;
        self.stats.slime_total = self.slime_total;
        self.stats.slime_left = self.field.remaining();
        self.stats.hunger_final = self.hunger.current;
        self.stats.hunger_max = self.hunger.max;
        // Compact per-player stats (indexed by player_id during play) into a
        // dense list with names for the wire.
        var compacted = [_]proto.PlayerStats{.{}} ** MAX_PLAYERS;
        var dense: u8 = 0;
        for (&self.players, 0..) |*slot, pid| {
            if (!slot.occupied) continue;
            var ps = self.stats.players[pid];
            ps.name = slot.name;
            ps.name_len = slot.name_len;
            compacted[dense] = ps;
            dense += 1;
        }
        self.stats.players = compacted;
        self.stats.player_count = dense;

        var buf: [2048]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .game_over, proto.GameOver{
            .score = self.score,
            .stats = self.stats,
        });
        try self.broadcast_raw(fbs.getWritten());
        try self.broadcast_lobby_update();
    }

    /// Spawn an ECS entity for a player who joined while the game is in
    /// progress.  IDEMPOTENT: a player owns at most one entity, so a repeated
    /// `join_lobby` (reconnect handshake, retry, duplicated input) is a no-op.
    /// Snapshots walk the player_marker array and both the client's combo
    /// projection and the team-recipe matcher treat one entity as one caster,
    /// so a second body would fake a team recipe from a single player.
    fn spawn_player_midgame(self: *Session, player_id: u8) !void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        if (slot.entity != NO_ENTITY) return;
        const e = self.world.create_entity();
        slot.entity = e;
        self.world.add_component(e, c.Kind{ .tag = .player });
        self.world.add_component(e, c.Owner{ .player_id = slot.player_id });
        self.world.add_component(e, c.PlayerMarker{});
        std.log.info("player {} joined mid-game", .{player_id});
    }

    /// The game_start payload for one player: encounter label, their id, the
    /// per-turn cast budget and the grid dimensions the client must render.
    fn game_start_msg(self: *const Session, label: []const u8, player_id: u8) proto.GameStart {
        var msg = proto.GameStart{
            .encounter_label = [_]u8{0} ** 32,
            .encounter_label_len = @intCast(@min(label.len, 32)),
            .player_id = player_id,
            .casts_per_turn = self.cfg.balance.casts_per_turn,
            .grid_rows = self.field.grid.rows,
            .grid_cols = self.field.grid.cols,
        };
        @memcpy(msg.encounter_label[0..msg.encounter_label_len], label[0..msg.encounter_label_len]);
        return msg;
    }

    /// Send a game_start message to a single player so their client transitions
    /// to game phase.  Used for late joiners while the session is already playing.
    fn send_game_start_to(self: *Session, player_id: u8) !void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        const t = slot.transport orelse return;
        const encounter = self.current_encounter orelse return;
        var buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .game_start, self.game_start_msg(encounter.label, slot.player_id));
        try t.send(fbs.getWritten());
    }

    pub fn broadcast_lobby_update(self: *Session) !void {
        var base = proto.LobbyUpdate{
            .join_code = self.join_code,
            .player_count = self.player_count,
            .players = [_]proto.PlayerInfo{std.mem.zeroes(proto.PlayerInfo)} ** proto.MAX_PLAYERS,
            .player_id = 0xFF,
        };
        for (&self.players, 0..) |*slot, i| {
            if (!slot.occupied) continue;
            base.players[i] = .{
                .player_id = slot.player_id,
                .name = slot.name,
                .name_len = slot.name_len,
                .kind = .player,
                .ready = slot.ready,
                .connected = slot.connected,
            };
        }
        for (&self.players) |*slot| {
            if (!slot.connected) continue;
            const t = slot.transport orelse continue;
            var msg = base;
            msg.player_id = slot.player_id;
            var buf: [512]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try proto.encode(fbs.writer(), .lobby_update, msg);
            t.send(fbs.getWritten()) catch {};
        }
    }

    pub fn broadcast_game_start(self: *Session, encounter_label: []const u8) !void {
        for (&self.players) |*slot| {
            if (!slot.connected) continue;
            const t = slot.transport orelse continue;
            var buf: [64]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try proto.encode(fbs.writer(), .game_start, self.game_start_msg(encounter_label, slot.player_id));
            try t.send(fbs.getWritten());
        }
    }

    fn broadcast_game_state(self: *Session) !void {
        var snap = proto.GameState.blank;
        snap.tick = self.tick_count;
        snap.turn = self.turn;
        snap.hunger = .{
            .current = self.hunger.current,
            .max = self.hunger.max,
        };
        snap.hunger_healable = self.hunger_healable;
        snap.score = self.score;

        // The whole authoritative grid, plus the off-grid remainder, so every
        // client draws identical slime.
        snap.grid_rows = self.field.grid.rows;
        snap.grid_cols = self.field.grid.cols;
        @memcpy(snap.grid[0..self.field.grid.len()], self.field.grid.cells[0..self.field.grid.len()]);
        snap.reservoir = self.field.reservoir.total();

        const pm_arr = &self.world.component_arrays.player_marker;
        for (pm_arr.index_to_entity[0..pm_arr.size]) |e| {
            if (snap.entity_count >= proto.MAX_ENTITIES_WIRE) break;
            const kd = self.world.get_component(e, c.Kind);
            const own = self.world.get_component(e, c.Owner).player_id;
            const blank_slots =
                [_]c.ComboSlot{.{ .action = .dispense }} ** c.MAX_COMBO_LEN;
            // What the player is TYPING (cleared on submit).
            const combo_len: u8 = if (self.action_pool[own]) |combo| combo.len else 0;
            const combo_slots = if (self.action_pool[own]) |combo|
                combo.slots
            else
                blank_slots;
            // The half this player is HOLDING for a partner, so clients keep
            // previewing what is standing by.
            const sub_len: u8 = if (self.held_pool[own]) |combo| combo.len else 0;
            const sub_slots = if (self.held_pool[own]) |combo|
                combo.slots
            else
                blank_slots;
            const cursor = if (self.held_pool[own] != null)
                self.cast_anchors[own]
            else
                self.cursors[own];

            snap.entities[snap.entity_count] = .{
                .entity = e,
                .kind = kd.tag,
                .owner = own,
                .casts_left = self.casts_left[own],
                .combo_len = combo_len,
                .combo_slots = combo_slots,
                .submitted_len = sub_len,
                .submitted_slots = sub_slots,
                // A HELD half shows where it will LAND (its captured anchor);
                // otherwise the player's live aim.  Snapshotted for every
                // player so teammates see each other's previews.
                .cursor_row = self.field.grid.row_of(cursor),
                .cursor_col = self.field.grid.col_of(cursor),
            };
            snap.entity_count += 1;
        }

        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .game_state, snap);
        try self.broadcast_raw(fbs.getWritten());
    }

    fn broadcast_action_result(self: *Session, result: proto.ActionResult) !void {
        var buf: [32]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .action_result, result);
        try self.broadcast_raw(fbs.getWritten());
    }

    fn broadcast_raw(self: *Session, data: []const u8) !void {
        for (&self.players) |*slot| {
            if (!slot.connected) continue;
            const t = slot.transport orelse continue;
            t.send(data) catch {};
        }
    }

    pub fn enqueue_message(self: *Session, player_id: u8, data: []const u8) void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        slot.queue_lock.lock();
        defer slot.queue_lock.unlock();
        slot.msg_queue.appendSlice(slot.allocator, data) catch {};
    }
};

fn set_world_system_signatures(world: *GameWorld) void {
    var sig = @import("ecs_zig").Signature.initEmpty();
    sig.set(GameWorld.component_type(c.Kind));
    sig.set(GameWorld.component_type(c.Owner));
    sig.set(GameWorld.component_type(c.PlayerMarker));
    world.set_system_signature(PlayerTeam, sig);

}
