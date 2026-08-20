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
//! A TURN is: everyone spends their cast budget, then the Lil Guys eat every
//! unit they can REACH and the field settles.  Nothing is on a clock — `tick`
//! only drains input and broadcasts, so a session advances solely by what
//! players do.
//!
//! ## Two currencies
//!
//! CASTS are per player, per turn (`balance.casts_per_turn`): they meter the
//! pace of a turn and decide when it ends.
//!
//! CHARGES are ONE pool shared by the whole team for the WHOLE GAME
//! (`encounter.charges`).  Nothing ever refills them.  Every recipe has a
//! `cost`, so the pool is the real resource: the team is not asked "what can
//! you do this turn?" but "what is this play worth out of everything you will
//! ever have?".  Running the pool dry is a loss (`out_of_charges`) the moment
//! the team can no longer afford its cheapest move — see check_end.
//!
//! SELECTING.  Each player holds ONE selected move: an index into
//! `balance.player_recipes` that they step around with `cycle_shape` and fire
//! with `cast`.  The selection is SERVER-OWNED — a client sends a direction,
//! never a move — so no client can name a move that is not in the table.  It
//! persists across turns (a player who found their move keeps it) and is
//! snapshotted for everyone, so a team can see what each other is holding and
//! agree on a group before spending anything.
//!
//! CASTING.  Every cast RESOLVES IMMEDIATELY — there is no held state and
//! nothing to wait for:
//!   - It completes a GROUP against casts teammates already made on the SAME
//!     square this turn → it stamps the group's shape and pays the group's
//!     price instead of its own.  The priors it consumed have already stamped
//!     and paid for themselves; they leave the log so they cannot be counted
//!     into a second group.
//!   - Otherwise → it stamps its own move's shape for its own cost.
//!   - The pool cannot pay for the group → it falls back to the plain move.
//!     The player cast something legal; downgrading beats refusing.
//!   - The pool cannot pay even for that → `cast_fizzled`, and the budget IS
//!     spent.  A bankrupt team still burns through turns, so the game keeps
//!     moving to its conclusion instead of hanging.
//! Stamping downgrades every covered hazard cell one tier (red -> yellow ->
//! green -> defused); coverage off the grid edge, or on a cell with nothing
//! left to downgrade, is wasted.  A stamp never empties a cell.
//!
//! Because every cast pays as it lands, a group is a DISCOUNT ON THE LAST
//! CONTRIBUTION, not a joint purchase: coordinating turns the completing
//! player's small move into the group's big one for the group's price.
//!
//! TURN END.  When every connected player's budget is spent, the field settles
//! in three ordered steps (see slime.zig):
//!   1. EAT — the Lil Guys enter from the LEFT edge and flood through empty
//!      cells and edible slime.  Live hazards and specials are walls: what is
//!      behind them is sheltered and survives.  Opening a path is the whole
//!      point of a cast.
//!   2. COLLAPSE — survivors fall straight down into the holes the feast left.
//!   3. FILL — the reservoir tops the field up from the row the collapse
//!      cleared.
//! The turn's cast log is then cleared — groups form WITHIN a turn only, so a
//! contribution nobody joined is simply a move that already landed — budgets
//! reset, and `turn_ended` is broadcast.
//!
//! The encounter's end is checked ONLY at turn end: the hunger bar filling is a
//! loss, a pool that can no longer afford the cheapest move is a loss (however
//! well the feast just went), and a field holding nothing but specials is a
//! win.  Either way the settled board is broadcast FIRST and the final shared
//! score follows via game_over, so the client can play the closing feast out
//! before it shows the report.

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
    /// The team's shared charge pool for the WHOLE game.  Seeded from
    /// `encounter.charges` and never replenished: every charge spent is gone
    /// for good, which is what makes an efficient shape worth aiming.
    charges: u32 = 0,
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
    /// Each player's selected move, as an index into
    /// `balance.player_recipes`.  SERVER-OWNED: clients send a cycle DIRECTION,
    /// so this is always a valid index and no client can name a move outside
    /// the loaded table.  Persists across turns; reset to 0 per encounter.
    selected: [MAX_PLAYERS]u8 = [_]u8{0} ** MAX_PLAYERS,
    /// Each player's aiming cursor, as a flat grid index.  SERVER-OWNED: the
    /// client sends directions and this clamps, so a cursor is always a valid
    /// cell of the current grid and no client can aim out of bounds.
    cursors: [MAX_PLAYERS]u16 = [_]u16{0} ** MAX_PLAYERS,
    /// Every cast made THIS TURN that is still available to a group, in cast
    /// order — the pool a group is completed against (see
    /// logic.complete_group).  Casts a group consumed are REMOVED, so one
    /// contribution can never count toward two groups.  Cleared at turn end:
    /// groups form within a turn only.
    turn_casts: [logic.MAX_CASTS]logic.TurnCast = undefined,
    turn_cast_count: usize = 0,
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
        self.stats = .{
            .player_recipe_count = @intCast(self.cfg.balance.player_recipes.len),
            .team_recipe_count = @intCast(self.cfg.balance.team_recipes.len),
        };
        self.tick_count = 0;

        self.phase = .playing;
        self.current_encounter = encounter;
        self.turn_cast_count = 0;
        // Everyone opens on the first move in the table: the encounter is a
        // fresh start, so a selection carried over from a previous game would
        // be state the players never chose here.
        self.selected = [_]u8{0} ** MAX_PLAYERS;
        self.turn = 1;
        self.reset_budgets();

        self.hunger = .{ .current = 0, .max = encounter.hunger_max };
        self.charges = encounter.charges;
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

        std.log.info("game start — encounter: {s} slime={} grid={}x{} hunger_max={} charges={} casts/turn={}", .{
            encounter.label,
            self.slime_total,
            self.field.grid.rows,
            self.field.grid.cols,
            self.hunger.max,
            self.charges,
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

    /// Resolve one cast IMMEDIATELY: pick its stamp, pay for it, land it.
    ///
    /// The cast's own move is the baseline.  If it completes a GROUP against
    /// this turn's earlier casts on the same square it is upgraded to the
    /// group's shape at the group's price — the coordination payoff.
    ///
    /// Pricing is a two-step fallback, from best to worst, because a player who
    /// pressed cast deserves the most the pool can actually buy:
    ///   1. the group, if one completed and the pool can pay for it;
    ///   2. the plain move, if the pool can pay for that;
    ///   3. nothing — the cast fizzles (`false`), with the budget already gone.
    ///
    /// A group that fires consumes its WHOLE bag — the contributing priors AND
    /// the cast that completed it — so no cast is ever counted into two groups.
    /// Leaving the trigger behind would let two players alternate contributions
    /// and collect a group on every press after the first, which is a chain, not
    /// a coordination.  Consumed casts are NOT refunded: each prior already
    /// stamped and paid for itself when it landed, and the trigger paid the
    /// group price.
    ///
    /// Returns false only for case 3, so the caller can announce the fizzle.
    fn resolve_cast(self: *Session, player_id: u8, square: u16) !bool {
        const bal = &self.cfg.balance;
        const move = self.selected[player_id];
        const cast = logic.TurnCast{
            .player_id = player_id,
            .move = move,
            .square = square,
        };

        const priors = self.turn_casts[0..self.turn_cast_count];
        const group = logic.complete_group(bal, priors, cast);

        // The group is only worth having if the pool can pay for it; otherwise
        // the plain move still stands.
        const stamp = blk: {
            if (group) |hit| {
                const gs = logic.group_stamp(bal, hit, player_id);
                if (gs.cost <= self.charges) break :blk gs;
                std.log.debug("group '{s}' costs {} charges, pool holds {} — falling back to '{s}'", .{
                    bal.team_recipes[hit.recipe_index].label,
                    gs.cost,
                    self.charges,
                    bal.player_recipes[move].label,
                });
            }
            break :blk logic.move_stamp(bal, move, player_id);
        };

        if (stamp.cost > self.charges) {
            std.log.debug("'{s}' costs {} charges, pool holds {} — fizzled", .{
                bal.player_recipes[move].label, stamp.cost, self.charges,
            });
            // The cast is still logged: it did happen, and a teammate may yet
            // build a group on the square even though this stamp never landed.
            self.log_turn_cast(cast);
            return false;
        }

        // A group swallows its whole bag: the priors it matched, and this cast.
        // Otherwise only the plain move landed, and this cast joins the log as a
        // component a teammate can still build on.
        if (stamp.is_team) {
            if (group) |hit| self.consume_priors(hit.spent());
        } else {
            self.log_turn_cast(cast);
        }

        self.charges -= stamp.cost;
        self.stats.feast.charges_spent +|= stat_u16(stamp.cost);
        const kind: proto.RecipeKind = if (stamp.is_team) .team else .player;
        if (stamp.is_team) {
            self.stats.team_recipe_hits[stamp.recipe_index] +|= 1;
        } else {
            self.stats.player_recipe_hits[stamp.recipe_index] +|= 1;
        }
        self.stats.players[player_id].recipe_casts +|= 1;
        try self.broadcast_recipe_fired(kind, stamp.recipe_index, 1);

        try self.stamp_shape(stamp, square);
        return true;
    }

    /// Append a cast to this turn's log, dropping it if the log is full.
    ///
    /// Overflow needs no ceremony: MAX_CASTS covers every player spending every
    /// cast of a turn with headroom, so a full log means a pathological config,
    /// and the only consequence is that a late cast cannot anchor a group.
    fn log_turn_cast(self: *Session, cast: logic.TurnCast) void {
        if (self.turn_cast_count >= logic.MAX_CASTS) return;
        self.turn_casts[self.turn_cast_count] = cast;
        self.turn_cast_count += 1;
    }

    /// Remove the casts a group consumed from this turn's log.
    ///
    /// `indices` are into the log as it stood when the group was matched, so
    /// removal walks HIGH to LOW: taking a lower index first would shift the
    /// higher ones and delete the wrong casts.
    fn consume_priors(self: *Session, indices: []const u8) void {
        var sorted: [shared.balance.MAX_TEAM_COMPONENTS]u8 = undefined;
        const n = @min(indices.len, sorted.len);
        @memcpy(sorted[0..n], indices[0..n]);
        std.mem.sort(u8, sorted[0..n], {}, std.sort.desc(u8));
        for (sorted[0..n]) |idx| {
            if (idx >= self.turn_cast_count) continue;
            // Order-preserving: the log is matched oldest-first, so shuffling
            // it would change which cast a later group picks up.
            std.mem.copyForwards(
                logic.TurnCast,
                self.turn_casts[idx .. self.turn_cast_count - 1],
                self.turn_casts[idx + 1 .. self.turn_cast_count],
            );
            self.turn_cast_count -= 1;
        }
    }

    /// Strand every remaining cast once the pool cannot afford the cheapest
    /// move.
    ///
    /// A broke turn is already over in fact: every cast still owed would fizzle,
    /// spending budget for nothing and asking players to press keys to no
    /// effect.  Zeroing the budgets makes it over in form, so the feast plays
    /// and `check_end` calls the game on this turn rather than the next one.
    ///
    /// A zero-cost move config never reaches this: `cheapest_cost` is 0, so the
    /// pool can always afford something.
    fn strand_budgets_if_broke(self: *Session) void {
        if (self.charges >= self.cfg.balance.cheapest_cost()) return;
        for (&self.casts_left) |*n| n.* = 0;
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

    /// Settle the turn: eat, collapse, refill, then fizzle held halves and
    /// refill budgets.
    ///
    /// Order matters and is the whole mechanic.  `eat_all` is priced against
    /// the field exactly as the casts left it, `collapse` drags the survivors
    /// down into the holes it made, and only then does `fill` top the field up
    /// — so refills always land ABOVE the survivors.  The end condition is
    /// checked last, because "field cleared" means the reservoir had nothing
    /// left to send either.
    fn end_turn(self: *Session) !void {
        const feast = self.field.eat_all(&self.cfg.balance);
        const hunger_added = feast.hunger_total();
        logic.add_hunger(&self.hunger, hunger_added);
        self.score += feast.score;
        self.record_feast(feast);

        // The feast is the ONLY thing that adds hunger, so it is the only
        // damage event in the game — announced pool-level (no actor).  Sent
        // even at zero so the client's damage cue is not silently conditional
        // on the field having been reachable.
        try self.broadcast_action_result(.{
            .tag = .damage,
            .actor_entity = std.math.maxInt(u32),
            .target_entity = std.math.maxInt(u32),
            .value = stat_u16(hunger_added),
        });

        // Groups form within a turn only: a contribution nobody joined was
        // still a move that landed and paid, so there is nothing to fizzle —
        // clearing the log is the whole of it.
        self.turn_cast_count = 0;

        // Gravity, THEN the refill: survivors settle to the bottom of their
        // column first so the new slime has the cleared top rows to land in.
        _ = self.field.collapse();
        _ = self.field.fill(self.rand());

        var buf: [32]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .turn_ended, proto.TurnEnded{
            .turn = self.turn,
            .cells_eaten = feast.cells,
            .hunger_added = stat_u16(hunger_added),
            .sheltered = feast.sheltered,
            .walls = feast.walls,
            .score_added = feast.score,
            .charges_left = self.charges,
        });
        try self.broadcast_raw(fbs.getWritten());

        std.log.info("turn {} ended — ate {} sheltered {} behind {} walls, hunger+{} score+{} charges={} reservoir={}", .{
            self.turn,
            feast.cells,
            feast.sheltered,
            feast.walls,
            hunger_added,
            feast.score,
            self.charges,
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

    /// Apply one shape to the grid at `anchor` (a flat grid index), then
    /// broadcast the resolved footprint and outcome.
    ///
    /// The anchor is passed in rather than read from the cursor: it is the
    /// square captured when the cast was accepted, so a stamp lands where the
    /// player was pointing even if they re-aim in the same tick.
    fn stamp_shape(self: *Session, stamp: logic.ShapeCast, anchor: u16) !void {
        const grid = &self.field.grid;
        const row = grid.row_of(anchor);
        const col = grid.col_of(anchor);

        const outcome = self.field.apply_shape(stamp.shape, row, col);

        var msg = proto.ShapeCast{
            .caster = stamp.anchor_player,
            .anchor = anchor,
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
        fs.hunger_normal +|= stat_u16(feast.hunger_total());
        fs.sheltered +|= feast.sheltered;
        fs.neutral_consumed +|= feast.neutral;
        fs.defused_consumed +|= feast.defused;
        fs.charges_left = self.charges;
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
    /// later, when the shape actually lands (see stamp_shape) — a cast that
    /// cannot be paid for covers nothing.
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
            .cycle_shape => {
                // Always decode so the stream stays in sync for messages
                // queued after this one.
                const p = try proto.decode_cycle_shape(fbs.reader());
                if (self.phase != .playing or player_id >= MAX_PLAYERS) return;
                const moves = self.cfg.balance.player_recipes.len;
                // An empty move table is impossible (config.zig rejects it),
                // but cycling would divide by zero, so guard rather than trust.
                if (moves == 0) return;
                self.selected[player_id] =
                    logic.cycle_selection(self.selected[player_id], p.dir, moves);
                std.log.debug("player {} selected '{s}'", .{
                    player_id,
                    self.cfg.balance.player_recipes[self.selected[player_id]].label,
                });
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
            .cast => {
                if (self.phase != .playing or player_id >= MAX_PLAYERS) return;
                // Out of casts this turn: silent ignore.  The turn is waiting
                // on someone else, and this player has nothing left to say.
                if (self.casts_left[player_id] == 0) return;
                // Every selection names a real move, so unlike the old combo
                // buffer there is no "this spells nothing" case: a cast always
                // has something to attempt.

                self.casts_left[player_id] -= 1;
                // Freeze the aim now: this cast lands where the player was
                // pointing when they pressed it, however they move next.
                const square = self.cursors[player_id];
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

                // Lands as a group if one completed, else as the plain move.
                // Only a pool too empty for either fizzles, budget already gone.
                if (!try self.resolve_cast(player_id, square)) {
                    self.stats.players[player_id].fizzles +|= 1;
                    try self.broadcast_fizzles(@as(u8, 1) << @intCast(player_id));
                }

                std.log.debug("player {} cast ({} left this turn)", .{
                    player_id, self.casts_left[player_id],
                });

                self.strand_budgets_if_broke();

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
    /// nothing between turns can move the hunger bar, the slime count or the
    /// charge pool, so there is no other moment where the answer can change.
    fn check_end(self: *Session) !void {
        if (self.phase != .playing) return;
        // Field-cleared wins ties: if the final feast fills the bar exactly,
        // the players still ate everything they could.
        if (self.field.is_exhausted()) {
            std.log.info("all slime consumed — encounter over, score={}", .{self.score});
            try self.end_game(.field_cleared);
            return;
        }
        if (logic.hunger_full(self.hunger)) {
            std.log.info("hunger bar full — encounter over, score={}", .{self.score});
            try self.end_game(.hunger_full);
            return;
        }
        // OUT OF ENERGY.  Slime is left and the pool cannot afford even the
        // cheapest move, so no future turn can differ from this one: every
        // remaining cast would fizzle and every remaining feast would eat
        // whatever the Lil Guys can already reach.  Ending here beats letting
        // the room spin turns that no input can change.
        //
        // Note this does NOT require the feast to have eaten nothing.  A team
        // that is broke but still feeding the Lil Guys is not in a stalemate,
        // but it has no decisions left either — the rest is bookkeeping, and
        // playing it out turn by turn is not a game.
        //
        // A config with a zero-cost move can never trip this: there is always
        // a move, so the game always has somewhere to go.  That is intentional.
        if (self.charges < self.cfg.balance.cheapest_cost()) {
            std.log.info("charges exhausted — encounter over, score={}", .{self.score});
            try self.end_game(.out_of_charges);
        }
    }

    fn end_game(self: *Session, reason: proto.EndReason) !void {
        std.log.info("game over — score: {} reason: {s}", .{ self.score, @tagName(reason) });

        // The final board, before the phase flips.  `tick` stops broadcasting
        // state the moment the session leaves `.playing`, so without this the
        // last state clients ever saw is the one from BEFORE the closing feast:
        // they would be told the game ended on a board that still holds the
        // slime it just ate.  Clients replay that feast as their outro, and
        // they need the board it lands on to do it.
        try self.broadcast_game_state();

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
    /// Snapshots walk the player_marker array and the client's selection
    /// projection treats one entity as one caster, so a second body would show
    /// a phantom teammate with a wheel of their own.
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
        snap.charges = self.charges;
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
            snap.entities[snap.entity_count] = .{
                .entity = e,
                .kind = kd.tag,
                .owner = own,
                .casts_left = self.casts_left[own],
                // The move this player would fire, so every client can preview
                // its footprint under their cursor — theirs AND their
                // teammates', which is how a group gets agreed on.
                .selected_shape = self.selected[own],
                .cursor_row = self.field.grid.row_of(self.cursors[own]),
                .cursor_col = self.field.grid.col_of(self.cursors[own]),
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
