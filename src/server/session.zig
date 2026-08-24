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
//! CASTING.  A cast is LOCKED IN, not resolved: it joins the turn's pending
//! list, and nothing is charged and nothing touches the grid until the whole
//! team has committed.  Locking in spends a CAST, which is what moves the turn
//! along; it spends no CHARGES.
//!
//! A pending cast can be taken back (`cancel_cast`), which returns the cast
//! budget it spent.  A player cancels their OWN most recent pending, one per
//! press — so a turn is a proposal the team can revise until the last player
//! commits.
//!
//! PRICING IS QUOTED FOR THE WHOLE TURN.  `game_logic.resolve_batch` reads the
//! pending list and answers with the stamps it produces and the single price
//! they cost together: same-square casts by DISTINCT players collapse into the
//! group moves they spell, and only the group's price is charged for them.  So
//! a group is a JOINT PURCHASE — its contributors never pay for their own moves
//! — rather than a discount on whoever happened to cast last.
//!
//! Every lock-in re-quotes the turn, and one that would take the quote past the
//! pool is REFUSED: the cast never joins the list, its budget is not spent, and
//! the player is told `over_budget`.  The turn simply stays open, so the team
//! can cancel something, aim somewhere cheaper, or spell a group that costs
//! less than its parts.
//!
//! RESOLUTION.  The moment every connected player's budget is spent, the
//! pending list is resolved: the quoted price is debited ONCE and each stamp is
//! applied at its own square, groups before plain moves.  Stamping downgrades
//! every covered hazard cell one tier (red -> yellow -> green -> defused);
//! coverage off the grid edge, or on a cell with nothing left to downgrade, is
//! wasted.  A stamp never empties a cell.
//!
//! TURN END.  Resolution runs straight into the feast, and the field settles
//! in three ordered steps (see slime.zig):
//!   1. EAT — the Lil Guys enter from the LEFT edge and flood through empty
//!      cells and edible slime.  Live hazards and specials are walls: what is
//!      behind them is sheltered and survives.  Opening a path is the whole
//!      point of a cast.
//!   2. COLLAPSE — survivors fall straight down into the holes the feast left.
//!   3. FILL — the reservoir tops the field up from the row the collapse
//!      cleared.
//! The pending list is then cleared — groups form WITHIN a turn only, so a
//! contribution nobody joined is simply a move that landed on its own — budgets
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
    /// The player's appetite stat, from join_lobby: a board's persistent
    /// flash counter, or 0 for browsers/bots.  Read when the player is folded
    /// into the hunger bar (game start or mid-game join).
    appetite: u32 = 0,
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
    ///
    /// Its CAPACITY is the sum of every counted player's appetite-derived
    /// contribution (see `hunger_share` and game_logic.player_hunger) — group
    /// hunger is the players' hunger totals added together, so the bar grows
    /// when a player joins and gives back its unused share when one leaves.
    hunger: c.Health = .{ .current = 0, .max = 0 },
    /// What each player currently contributes to `hunger.max`.  0 = not
    /// counted (empty slot, or left mid-game).  Never 0 for a counted player:
    /// config.zig validates hunger_base >= 1, so a contribution is always
    /// positive and 0 is unambiguous.
    hunger_share: [MAX_PLAYERS]u16 = [_]u16{0} ** MAX_PLAYERS,
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
    /// Casts locked in THIS TURN and not yet resolved, in lock-in order.
    ///
    /// This is the turn: it is what `logic.resolve_batch` is quoted against,
    /// what the clients preview, and what a cancel pops from.  Nothing in it
    /// has been charged or stamped.  Emptied at turn end, because groups form
    /// within a turn only.
    pending: [logic.MAX_CASTS]logic.TurnCast = undefined,
    pending_count: usize = 0,
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
        // Rejoining a live game counts them back into the bar.  Their FULL
        // share, not the sliver their departure gave back: a returning eater
        // brings a whole appetite, and the asymmetry is deliberate.
        if (self.phase == .playing) self.count_hunger_share(player_id);
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
        } else {
            // Mid-game: the bar gives back this player's unused share.
            self.uncount_hunger_share(player_id);
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
        self.pending_count = 0;
        // Everyone opens on the first move in the table: the encounter is a
        // fresh start, so a selection carried over from a previous game would
        // be state the players never chose here.
        self.selected = [_]u8{0} ** MAX_PLAYERS;
        self.turn = 1;
        self.reset_budgets();

        // The bar's capacity is the SUM of every present player's
        // appetite-derived contribution — there is no per-encounter budget
        // any more, so a bigger or hungrier team simply has more room to eat.
        self.hunger = .{ .current = 0, .max = 0 };
        self.hunger_share = [_]u16{0} ** MAX_PLAYERS;
        for (&self.players) |*p| {
            if (!p.occupied or !p.connected) continue;
            self.count_hunger_share(p.player_id);
        }
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

    /// Fold one player into the hunger bar's capacity.  IDEMPOTENT: a player
    /// already counted (share non-zero) is left alone, so a repeated
    /// join_lobby or reconnect can never inflate the bar.  The share is
    /// FROZEN at count time — a later appetite update changes nothing until
    /// the next game.
    fn count_hunger_share(self: *Session, player_id: u8) void {
        if (player_id >= MAX_PLAYERS) return;
        if (self.hunger_share[player_id] != 0) return;
        const share = logic.player_hunger(&self.cfg.balance, self.players[player_id].appetite);
        self.hunger_share[player_id] = share;
        self.hunger.max +|= share;
    }

    /// A counted player left mid-game: give back their share of the UNUSED
    /// capacity only (see game_logic.shrink_hunger_max).  What was already
    /// eaten stays eaten, so the bar never drops below `current`; a departure
    /// that leaves it exactly full ends the game through the ordinary
    /// hunger_full check at the next turn end.
    fn uncount_hunger_share(self: *Session, player_id: u8) void {
        if (player_id >= MAX_PLAYERS) return;
        const share = self.hunger_share[player_id];
        if (share == 0) return;
        self.hunger_share[player_id] = 0;
        logic.shrink_hunger_max(&self.hunger, share);
        std.log.info("player {} left mid-game — hunger bar now {}/{}", .{
            player_id, self.hunger.current, self.hunger.max,
        });
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

    /// What the turn's pending casts, plus `extra` if given, would cost the
    /// shared pool — the quote a lock-in is judged against.
    fn quote(self: *const Session, extra: ?logic.TurnCast) u32 {
        var casts: [logic.MAX_CASTS]logic.TurnCast = undefined;
        const n = @min(self.pending_count, logic.MAX_CASTS);
        @memcpy(casts[0..n], self.pending[0..n]);
        var len = n;
        if (extra) |e| {
            if (len >= logic.MAX_CASTS) return std.math.maxInt(u32);
            casts[len] = e;
            len += 1;
        }
        return logic.resolve_batch(&self.cfg.balance, casts[0..len]).total_cost;
    }

    /// Take back a player's most recent pending cast, refunding the budget it
    /// spent.  Does nothing if they have none.
    ///
    /// NEWEST FIRST, one per press: a player revising a plan undoes it in the
    /// order they made it, and each press is one visible step.  Only their OWN
    /// casts are reachable — a teammate's commitment is not yours to withdraw.
    fn cancel_pending(self: *Session, player_id: u8) bool {
        var i = self.pending_count;
        while (i > 0) {
            i -= 1;
            if (self.pending[i].player_id != player_id) continue;
            std.mem.copyForwards(
                logic.TurnCast,
                self.pending[i .. self.pending_count - 1],
                self.pending[i + 1 .. self.pending_count],
            );
            self.pending_count -= 1;
            self.casts_left[player_id] +|= 1;
            return true;
        }
        return false;
    }

    /// Resolve the whole turn: debit the quoted price ONCE, then land every
    /// stamp it bought.
    ///
    /// Public only as a test seam: in play this runs from `maybe_end_turn`, an
    /// instant before the feast, and a test that wants to look at the board the
    /// casts made needs to stop between the two.
    ///
    /// Called only when the lock-in phase is over, so the quote is final.  It is
    /// affordable by construction — every lock-in that would have taken it past
    /// the pool was refused — so there is no price check and no fallback here:
    /// the team was quoted this turn and the team is buying it.
    pub fn resolve_pending(self: *Session) !void {
        const bal = &self.cfg.balance;
        const batch = logic.resolve_batch(bal, self.pending[0..self.pending_count]);

        self.charges -= @min(batch.total_cost, self.charges);
        self.stats.feast.charges_spent +|= stat_u16(batch.total_cost);

        for (batch.slice()) |b| {
            const stamp = b.stamp;
            if (stamp.is_team) {
                self.stats.team_recipe_hits[stamp.recipe_index] +|= 1;
            } else {
                self.stats.player_recipe_hits[stamp.recipe_index] +|= 1;
            }
            self.stats.players[stamp.anchor_player].recipe_casts +|= 1;
            const kind: proto.RecipeKind = if (stamp.is_team) .team else .player;
            try self.broadcast_recipe_fired(kind, stamp.recipe_index, 1);
            try self.stamp_shape(stamp, b.square);
        }

        self.pending_count = 0;
    }

    /// Close the lock-in phase early once the pool cannot afford anything more.
    ///
    /// Whatever headroom the quote leaves is all the turn has left to spend, so
    /// once it is under the cheapest move in the table every further lock-in
    /// could only be refused — leaving the turn waiting on players who have no
    /// legal move to make.  Zeroing the remaining budgets settles the turn on
    /// what is already committed instead of hanging on what cannot be.
    ///
    /// This is also how the game ends: the headroom that stranded the turn is
    /// exactly the pool that will be left after it resolves, so `check_end`
    /// calls `out_of_charges` on this turn rather than the next one.
    ///
    /// A zero-cost move config never reaches this: `cheapest_cost` is 0, so
    /// there is always something the team can still add.
    fn strand_budgets_if_broke(self: *Session) void {
        const committed = self.quote(null);
        const headroom = if (committed >= self.charges) 0 else self.charges - committed;
        if (headroom >= self.cfg.balance.cheapest_cost()) return;
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

    /// Settle the turn once every connected player has locked in: resolve the
    /// pending casts, then run the feast over the board they left.
    ///
    /// Called after each lock-in and whenever the connected set shrinks,
    /// because both can make the condition true.  Casts locked in by a player
    /// who has since dropped still resolve: they committed, and the team priced
    /// the turn around them.
    fn maybe_end_turn(self: *Session) !void {
        if (self.phase != .playing) return;
        if (!self.budgets_spent()) return;
        try self.resolve_pending();
        try self.end_turn();
    }

    /// Settle the turn: eat, collapse, refill, then refill budgets.
    ///
    /// The turn's stamps have already landed (see `resolve_pending`), so the
    /// board this reads is the one the team bought.
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

        // Groups form within a turn only.  Resolution already emptied this;
        // clearing it again costs nothing and keeps the invariant local to the
        // turn boundary that owns it.
        self.pending_count = 0;

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

    /// Tell one player their cast was refused, and by how much.
    ///
    /// Sent to the caster alone: nothing about the turn changed, so there is
    /// nothing for anyone else to redraw.
    fn send_over_budget(self: *Session, player_id: u8, needed: u32) !void {
        const slot = &self.players[player_id];
        const t = slot.transport orelse return;
        var buf: [16]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .over_budget, proto.OverBudget{
            .needed = needed,
            .have = self.charges,
        });
        t.send(fbs.getWritten()) catch {};
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
                slot.appetite = p.appetite;
                std.log.info("player {} name set: {s} (appetite {})", .{
                    player_id, slot.name[0..slot.name_len], slot.appetite,
                });
                if (self.phase == .playing) {
                    // Late joiner: spawn their entity, fold them into the
                    // hunger bar, then send them a game_start so their client
                    // enters game phase.  Existing players are unaffected —
                    // no lobby_update is broadcast.
                    try self.spawn_player_midgame(player_id);
                    self.count_hunger_share(player_id);
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
                // The list is capped well above any real turn, so a full one
                // means a pathological config rather than a play worth
                // reporting.
                if (self.pending_count >= logic.MAX_CASTS) return;
                // Every selection names a real move, so there is no "this
                // spells nothing" case: a cast always has something to lock in.

                const cast = logic.TurnCast{
                    .player_id = player_id,
                    .move = self.selected[player_id],
                    // Freeze the aim now: this cast lands where the player was
                    // pointing when they pressed it, however they move next.
                    .square = self.cursors[player_id],
                };

                // Re-quote the turn WITH this cast.  Refused rather than
                // downgraded: the team is spending one pooled budget, and the
                // player who tripped it is the one who can still choose
                // differently.
                const needed = self.quote(cast);
                if (needed > self.charges) {
                    std.log.debug("player {} cast refused — turn would cost {}, pool holds {}", .{
                        player_id, needed, self.charges,
                    });
                    try self.send_over_budget(player_id, needed);
                    return;
                }

                self.pending[self.pending_count] = cast;
                self.pending_count += 1;
                self.casts_left[player_id] -= 1;
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

                std.log.debug("player {} locked in '{s}' ({} left this turn, turn quoted at {})", .{
                    player_id,
                    self.cfg.balance.player_recipes[cast.move].label,
                    self.casts_left[player_id],
                    needed,
                });

                self.strand_budgets_if_broke();

                // Spending the last budget in the room settles the turn.
                try self.maybe_end_turn();
            },
            .cancel_cast => {
                if (self.phase != .playing or player_id >= MAX_PLAYERS) return;
                // Nothing of their own to take back: silent, because a player
                // pressing undo on an empty plan has made no mistake.
                if (!self.cancel_pending(player_id)) return;
                std.log.debug("player {} cancelled a cast ({} left this turn)", .{
                    player_id, self.casts_left[player_id],
                });
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
    /// nothing between turns can FILL the hunger bar, move the slime count or
    /// the charge pool.  A mid-game leave can shrink the bar's capacity down
    /// to `current` (see uncount_hunger_share), but never below it, so the
    /// verdict still cannot change until the next turn settles.
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
        // remaining cast would be refused and every remaining feast would eat
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

        // The turn as it stands.  Sent to everyone: a player deciding what to
        // add needs to see what is already committed, and the client previews
        // the turn from this list plus its own live aim.
        snap.pending_count = @intCast(@min(self.pending_count, proto.MAX_PENDING_WIRE));
        for (self.pending[0..snap.pending_count], 0..) |pc, i| {
            snap.pending[i] = .{
                .player_id = pc.player_id,
                .move = pc.move,
                .square = pc.square,
            };
        }

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
