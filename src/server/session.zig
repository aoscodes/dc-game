//! Game session: the authoritative Slime Feast game loop.
//!
//! One Session instance per active game room.  A game is ALWAYS either
//! running or holding at its end screen: the session starts its first
//! encounter the moment it is created, and a finished encounter waits on a
//! `restart` message (a browser tab clicking the report's button) before
//! the next one begins.  There is no lobby.
//!
//! CONNECTIONS and PLAYERS are decoupled.  Every websocket is a Connection:
//! it receives every broadcast (the game is a spectator sport by default)
//! and holds no game state.  A connection becomes a player by sending
//! `take_slot`, which binds it to one of MAX_PLAYERS PlayerSlots — silently
//! ignored when all slots are taken.  `leave_slot` (or the socket closing)
//! releases the slot: the leaver's hunger/charge shares go back to the
//! group and play continues for everyone else.
//!
//! The session owns:
//!   - The connection registry (transports + per-connection input queues)
//!   - The ECS World (player entities)
//!   - The authoritative slime field (grid + reservoir)
//!   - The match PRNG: every random choice in the game comes from this one
//!     seeded generator, so a session is reproducible from its seed.
//!
//! ## Slime Feast realtime loop
//!
//! There is ONE slime grid per game (`slime.SlimeField`), sized by the global
//! `balance.slime_grid`.  The encounter's slime starts in the off-grid
//! reservoir; whatever fits is placed on the grid.  The grid is
//! server-authoritative and transmitted whole in `game_state`, so every client
//! renders identical slime.
//!
//! Everything runs on the SESSION CLOCK: `tick(dt)` accumulates wall time
//! into `clock_ms`, and the clock drives two timers —
//!
//!   THE BITE.  Every `balance.bite_interval_ms` (sped up by the crowd: each
//!   seated Lil Guy past the first and each baby at the table adds its
//!   percent, see balance.bite_interval_effective) the Lil Guys BITE the
//!   front `feast_width` columns and the field settles.  An empty table
//!   never bites: with nobody seated the timer disarms, and it re-arms from
//!   scratch when someone sits down or a hold (pre-match, end screen) lifts.
//!
//!   THE COOLDOWN.  Each player may cast once per `balance.cast_cooldown_ms`;
//!   a press inside the cooldown is silently dropped (the client shows the
//!   timer, so an early press is impatience, not a mistake).
//!
//! CHARGES are ONE pool shared by the whole team for the WHOLE GAME
//! (`encounter.charges`, plus what swallowed canisters give back).  Every
//! recipe has a `cost`, so the pool is the real resource: the team is not
//! asked "what can you do right now?" but "what is this play worth out of
//! everything you will ever have?".  Running the pool dry does NOT end the
//! game — a broke team's casts are refused (`over_budget`) while the bite
//! keeps chewing; the hunger bar is the clock that eventually calls it.
//!
//! SELECTING.  Each player holds ONE selected move: an index into
//! `balance.player_recipes` that they step around with `cycle_shape` and fire
//! with `cast`.  The selection is SERVER-OWNED — a client sends a direction,
//! never a move — so no client can name a move that is not in the table.  It
//! persists across bites (a player who found their move keeps it) and is
//! snapshotted for everyone, so a team can see what each other is holding and
//! agree on a group before spending anything.
//!
//! CASTING resolves IMMEDIATELY: the cast is priced, the pool debited, and
//! the move's shape stamped at the aimed square in the same instant.
//! Stamping downgrades every covered hazard cell one tier (red -> yellow ->
//! green -> defused); coverage off the grid edge, or on a cell with nothing
//! left to downgrade, is wasted.  A stamp never empties a cell.  A cast the
//! pool cannot afford is REFUSED — nothing lands, no cooldown starts, and
//! the caster alone is told `over_budget`.
//!
//! GROUPS form in a rolling WINDOW.  Every landed cast is remembered for
//! `balance.team_window_ms`; when a cast completes a team recipe's bag on
//! its square — DISTINCT players, same square, all within the window (see
//! game_logic.complete_group) — the group's shape fires too, and the
//! completing cast pays the GROUP's cost INSTEAD of its own.  The
//! contributors already paid their own way as they landed, so the group
//! price is the price of the upgrade; consumed contributors leave the
//! window, so a cast feeds at most one group.
//!
//! THE BITE settles the field in three ordered steps (see slime.zig):
//!   1. BITE — the Lil Guys chew the front `feast_width` columns cell by
//!      cell: edible units are consumed (scoring), live hazards are NIBBLED
//!      one tier softer (hunger for nothing), rocks are skipped.  Defusing
//!      the front before the bite lands is the whole point of a cast.
//!   2. SHIFT — every row's survivors pack LEFT into the space the bite
//!      opened: the conveyor advances.
//!   3. FILL — the reservoir tops the field up from the RIGHT edge.
//! `bite_settled` is broadcast and the next bite is scheduled at the
//! crowd's CURRENT rate — seats taken and babies hatched since the last
//! bite speed the very next one.
//!
//! The encounter's end is checked ONLY when a bite settles: the hunger bar
//! is the game's CLOCK — every bite fills it, and a full bar simply calls
//! time — while a field holding nothing but inconsumable specials is the
//! win.  Either way the settled board is broadcast FIRST and the final
//! shared score follows via game_over, so the client can play the closing
//! feast out before it shows the report.

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

/// Profiler phases of one tick.  The feast is not its own phase: a due bite
/// settles between the two, and profiling has never needed to isolate it.
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

/// Connection registry size.  Comfortably above the bridge's tab cap plus
/// every board that could plausibly plug in; a connection beyond this is
/// refused outright.
pub const MAX_CONNECTIONS = 16;

/// "No entity" sentinel for slot references.
pub const NO_ENTITY: ecs.Entity = std.math.maxInt(ecs.Entity);

/// One websocket attached to the session.  Pure transport + input queue:
/// game state lives on the PlayerSlot a connection may (or may not) hold.
pub const Connection = struct {
    active: bool = false,
    transport: ?shared.Transport = null,
    /// The player slot this connection holds, or null while observing.
    player_id: ?u8 = null,
    queue_lock: std.Thread.Mutex = .{},
    msg_queue: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator = undefined,
};

/// One of the MAX_PLAYERS seats in the game.  Bound to a connection while
/// occupied; everything a player IS (entity, shares, budgets) hangs off the
/// slot index, so releasing the seat is what makes a player leave.
pub const PlayerSlot = struct {
    occupied: bool = false,
    player_id: u8,
    /// The player's appetite stat, from take_slot: a board's persistent
    /// flash counter, or 0 for browsers/bots.  Read when the player is folded
    /// into the hunger bar.
    appetite: u32 = 0,
    /// The babies banked on this player's board, per BabyType (take_slot).
    /// They join the encounter with their owner — each adds baby_hunger to
    /// the bar via the owner's share — and leave with them.
    babies: c.BabyCounts = [_]u32{0} ** c.BabyType.size,
    /// What this player's Lil Guy looks like (take_slot).  COSMETIC ONLY: it
    /// is copied into the snapshot for the renderer and read nowhere else, so
    /// it can never affect who wins.
    appearance: proto.Appearance = .{},
    /// The powerups banked on this player's board, per PowerupKind
    /// (take_slot).  Like the babies they join the encounter with their owner
    /// and leave with them.  The badge only COUNTS these; what each one is
    /// worth is decided here (see `count_charge_grant`).
    powerups: c.PowerupCounts = [_]u8{0} ** c.PowerupKind.size,
    /// Charges this player's carried powerups put INTO the team pool, granted
    /// when they were counted.  Recorded rather than recomputed so the number
    /// given back on leaving is exactly the number granted, even if the
    /// tuning is reloaded or their powerups change underneath us — the pool
    /// must not be mintable by a mismatch between the two.
    charge_grant: u32 = 0,
    entity: ecs.Entity = std.math.maxInt(ecs.Entity),
    /// Index into the session's connection registry; meaningful only while
    /// occupied.
    conn: usize = 0,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    join_code: [6]u8,
    /// Loaded balance + encounter data; owned by the caller and must outlive
    /// the session.
    cfg: *const cfg_mod.Config,
    connections: [MAX_CONNECTIONS]Connection,
    players: [MAX_PLAYERS]PlayerSlot,
    /// An encounter just ended: the session is holding at the END SCREEN.
    /// Turn machinery and state broadcasts pause (the final board already
    /// went out with game_over); input still drains, because the `restart`
    /// that starts the next encounter — and seat changes — arrive through
    /// it.  Cleared by start_game.
    restart_pending: bool = false,
    /// The encounter is holding at its PRE-MATCH screen (the browser's
    /// recipe guide): everything is seeded and seats can be taken, but
    /// gameplay input is ignored and no state is broadcast until a browser
    /// tab's `restart` click begins play.  Entered at server boot and on
    /// every end-screen restart, NOT by start_game itself — the test seam
    /// (and the bot harness) start encounters that play immediately.
    prematch: bool = false,
    world: GameWorld,
    tick_count: u32 = 0,
    current_encounter: ?*const enc.Encounter = null,
    /// Total Hunger bar — the game's CLOCK.  Every bite fills it (consumed
    /// food and nibbled hazards alike); full = time is up and the encounter
    /// ends on whatever the score is.
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
    /// Babies hatched THIS encounter, per BabyType.  Session-owned: a hatched
    /// baby belongs to no player, its capacity is never given back mid-game,
    /// and the brood resets with the next encounter.  At game_over every
    /// board that completes the encounter banks these (stats.eggs_hatched).
    hatched: [c.BabyType.size]u16 = [_]u16{0} ** c.BabyType.size,
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
    /// The bite now being chewed toward (1-based; 0 until the game starts):
    /// how many times the field has settled, plus one.
    bite: u16 = 0,
    /// The session clock, in accumulated milliseconds of PLAY time.  Fed by
    /// `tick(dt)` and FROZEN while the session holds (pre-match, end
    /// screen), so cooldowns and the group window never expire while nobody
    /// can play.  f64 so sub-ms ticks accumulate without loss; read through
    /// `now_ms`.
    clock_ms: f64 = 0,
    /// Session clock time (ms) the next bite fires at, or 0 while the bite
    /// timer is DISARMED (holding, or nobody seated).  0 is unambiguous: an
    /// armed timer is always now + interval, and the interval is >= 100.
    next_bite_at: u64 = 0,
    /// Session clock time (ms) each player may cast again at.  A press
    /// before this is silently dropped.
    cooldown_until: [MAX_PLAYERS]u64 = [_]u64{0} ** MAX_PLAYERS,
    /// Session clock time (ms) casting reopens after a bite settles, or 0
    /// while the board is free.  TABLE-WIDE, not per-player: the Lil Guys are
    /// chewing and nobody's spell reaches the board through it.
    ///
    /// Distinct from `cooldown_until` in what a refusal costs the player: a
    /// cooldown press is dropped in silence because the seat panel is already
    /// counting it down, while a press in here is answered with
    /// `cast_refused` so the client can say so.  See
    /// `balance.settle_lockout_ms`; 0 there leaves this permanently clear.
    cast_locked_until: u64 = 0,
    /// Each player's selected move, as an index into
    /// `balance.player_recipes`.  SERVER-OWNED: clients send a cycle DIRECTION,
    /// so this is always a valid index and no client can name a move outside
    /// the loaded table.  Persists across turns; reset to 0 per encounter.
    selected: [MAX_PLAYERS]u8 = [_]u8{0} ** MAX_PLAYERS,
    /// Each player's aiming cursor, as a flat grid index.  SERVER-OWNED: the
    /// client sends directions and this clamps, so a cursor is always a valid
    /// cell of the current grid and no client can aim out of bounds.
    cursors: [MAX_PLAYERS]u16 = [_]u16{0} ** MAX_PLAYERS,
    /// The rolling recent-cast window, in landing order: every cast still
    /// young enough (`balance.team_window_ms`) to help a teammate spell a
    /// team recipe.  Everything in it has already been charged and stamped;
    /// what remains is only its power to coordinate.  Pruned every tick,
    /// and consumed contributors are evicted when a group fires.
    recent: [logic.MAX_RECENT]logic.RecentCast = undefined,
    recent_count: usize = 0,
    /// Tuning stats accumulated over the match; broadcast with game_over.
    /// `players` is indexed by player_id during play and compacted (dense)
    /// in end_game.
    stats: proto.MatchStats = .{},
    /// The ONE source of randomness for the match: cell placement, target
    /// selection and neutralize subsets all draw from it, so a session
    /// replays exactly from its seed.
    prng: std.Random.DefaultPrng,
    profiler: dbg.Profiler(TickPhase) = dbg.Profiler(TickPhase).init(),

    /// `seed` pins the match PRNG.  Callers that want reproducible games
    /// (tests, replays) pass a fixed value; production passes a clock seed
    /// via `init`.
    ///
    /// The session is returned BEFORE its first encounter runs: callers must
    /// follow up with `start_game` (a game is always running from then on).
    /// Split this way because the encounter machinery needs the session at
    /// its final address.
    pub fn init_seeded(
        allocator: std.mem.Allocator,
        join_code: [6]u8,
        cfg: *const cfg_mod.Config,
        seed: u64,
    ) !Session {
        var players: [MAX_PLAYERS]PlayerSlot = undefined;
        for (&players, 0..) |*p, i| {
            p.* = PlayerSlot{ .player_id = @intCast(i) };
        }
        var connections: [MAX_CONNECTIONS]Connection = undefined;
        for (&connections) |*conn| {
            conn.* = Connection{ .allocator = allocator };
        }
        var world = try GameWorld.init(allocator);
        set_world_system_signatures(&world);
        return Session{
            .allocator = allocator,
            .join_code = join_code,
            .cfg = cfg,
            .connections = connections,
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
        for (&self.connections) |*conn| {
            conn.queue_lock.lock();
            conn.msg_queue.deinit(conn.allocator);
            conn.queue_lock.unlock();
        }
    }

    /// Register a new websocket as an observer and send it a personalized
    /// game_start (player_id = NO_PLAYER) so its client can render the game
    /// that is already running.  Returns the connection id, or null when the
    /// registry is full.
    pub fn connect(self: *Session, transport: shared.Transport) ?usize {
        for (&self.connections, 0..) |*conn, i| {
            if (conn.active) continue;
            conn.active = true;
            conn.transport = transport;
            conn.player_id = null;
            self.send_game_start_to_conn(i) catch {};
            return i;
        }
        return null;
    }

    /// A websocket closed: release its player slot (if it held one) and drop
    /// the connection.  Play continues for everyone else.
    pub fn disconnect(self: *Session, conn_id: usize) void {
        if (conn_id >= MAX_CONNECTIONS) return;
        const conn = &self.connections[conn_id];
        if (!conn.active) return;
        if (conn.player_id) |pid| self.release_slot(pid);
        conn.active = false;
        conn.transport = null;
        conn.player_id = null;
        conn.queue_lock.lock();
        conn.msg_queue.clearRetainingCapacity();
        conn.queue_lock.unlock();
    }

    /// A player gives up their seat: their unused hunger share and their
    /// proportion of the remaining charges go back to the group, their
    /// entity disappears, and the seat opens up.  Only a COUNTED player
    /// (non-zero hunger share) takes anything with them.
    fn release_slot(self: *Session, player_id: u8) void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        if (!slot.occupied) return;
        // The powerups leave with their owner, and they leave FIRST: the 1/n
        // shrink below must divide the pool the team would have had WITHOUT
        // this player's canisters, or an unplug/replug cycle would mint
        // charges.  Granting last on the way in and reclaiming first on the
        // way out makes the round trip exact (see `count_charge_grant`).
        self.uncount_charge_grant(player_id);
        if (self.hunger_share[player_id] != 0) {
            // The leaver's proportion is 1/n of the REMAINING pool, where n
            // includes them.  The LAST player out takes nothing: the pool is
            // left in trust for whoever sits down next (the first joiner
            // inherits it as their seed, see take_slot/grow_charges), so an
            // empty game never becomes an unplayable one.
            const n = self.counted_players();
            if (n > 1) {
                const before = self.charges;
                logic.shrink_charges(&self.charges, n);
                std.log.info("player {} left — charges {} -> {} ({} players counted)", .{
                    player_id, before, self.charges, n,
                });
            }
        }
        self.uncount_hunger_share(player_id);
        if (slot.entity != NO_ENTITY) {
            self.world.destroy_entity(slot.entity);
            slot.entity = NO_ENTITY;
        }
        slot.occupied = false;
        slot.appetite = 0;
        slot.babies = [_]u32{0} ** c.BabyType.size;
        slot.appearance = .{};
        slot.powerups = [_]u8{0} ** c.PowerupKind.size;
        slot.charge_grant = 0;
        self.connections[slot.conn].player_id = null;
    }

    /// How many players currently hold a share of the pools (see
    /// `hunger_share`: non-zero exactly for counted players).
    fn counted_players(self: *const Session) u32 {
        var n: u32 = 0;
        for (&self.hunger_share) |share| {
            if (share != 0) n += 1;
        }
        return n;
    }

    /// How many seats are taken.
    pub fn seated_players(self: *const Session) u8 {
        var n: u8 = 0;
        for (&self.players) |*p| {
            if (p.occupied) n += 1;
        }
        return n;
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
        // Hatched babies live for one encounter; the boards banked them at
        // the last game_over, so the next brood starts empty.
        self.hatched = [_]u16{0} ** c.BabyType.size;

        self.restart_pending = false;
        self.prematch = false;
        self.current_encounter = encounter;
        self.recent_count = 0;
        // Everyone opens on the first move in the table: the encounter is a
        // fresh start, so a selection carried over from a previous game would
        // be state the players never chose here.
        self.selected = [_]u8{0} ** MAX_PLAYERS;
        self.bite = 1;
        // Fresh timers: nobody owes a cooldown from a previous game, and the
        // bite arms itself on the first live tick with someone seated.
        self.cooldown_until = [_]u64{0} ** MAX_PLAYERS;
        self.next_bite_at = 0;
        self.cast_locked_until = 0;

        // The bar's capacity is the SUM of every seated player's
        // appetite-derived contribution — there is no per-encounter budget
        // any more, so a bigger or hungrier team simply has more room to eat.
        self.hunger = .{ .current = 0, .max = 0 };
        self.hunger_share = [_]u16{0} ** MAX_PLAYERS;
        for (&self.players) |*p| {
            p.charge_grant = 0;
            if (!p.occupied) continue;
            self.count_hunger_share(p.player_id);
        }
        // The pool a seated team opens with is exactly what it would hold had
        // they taken their seats one by one into a fresh game: the encounter's
        // seed, grown once per player past the first (see logic.grow_charges).
        // An EMPTY game holds the bare seed until someone sits down.
        self.charges = encounter.charges;
        var grown: u32 = 1;
        while (grown < self.counted_players()) : (grown += 1) {
            logic.grow_charges(&self.charges, grown);
        }
        // Carried powerups pay out again for the new encounter, and LAST for
        // the same reason as on a mid-game join: the seed above is what the
        // team would have grown to on its own, and the canisters top it up.
        for (&self.players) |*p| {
            if (!p.occupied) continue;
            self.count_charge_grant(p.player_id);
        }
        self.score = 0;
        self.slime_total = encounter.total_units();
        self.field = slime.SlimeField.init(
            self.cfg.balance.slime_grid,
            encounter.slime,
            &self.cfg.balance,
            self.rand(),
        );
        // Everyone starts aiming at the middle of the field: the least
        // arbitrary opening position, and always a valid cell.
        const centre = self.field.grid.index(
            self.cfg.balance.slime_grid.rows / 2,
            self.cfg.balance.slime_grid.cols / 2,
        );
        self.cursors = [_]u16{centre} ** MAX_PLAYERS;

        std.log.info("game start — encounter: {s} slime={} grid={}x{} hunger_max={} charges={} bite_interval={}ms cooldown={}ms", .{
            encounter.label,
            self.slime_total,
            self.field.grid.rows,
            self.field.grid.cols,
            self.hunger.max,
            self.charges,
            self.cfg.balance.bite_interval_ms,
            self.cfg.balance.cast_cooldown_ms,
        });
        try self.spawn_players();
    }

    /// Fold one player into the hunger bar's capacity.  IDEMPOTENT: a player
    /// already counted (share non-zero) is left alone, so a repeated
    /// take_slot can never inflate the bar.  The share is FROZEN at count
    /// time — a later appetite update changes nothing until the next game.
    fn count_hunger_share(self: *Session, player_id: u8) void {
        if (player_id >= MAX_PLAYERS) return;
        if (self.hunger_share[player_id] != 0) return;
        const slot = &self.players[player_id];
        const share = logic.player_hunger(
            &self.cfg.balance,
            slot.appetite,
            c.baby_total(slot.babies),
        );
        self.hunger_share[player_id] = share;
        self.hunger.max +|= share;
    }

    /// Pay a player's carried powerups into the team charge pool.  IDEMPOTENT
    /// on the same terms as `count_hunger_share`: a player whose grant is
    /// already recorded is left alone, so a repeated count can never mint
    /// charges.  A player carrying nothing records a grant of 0, which makes
    /// "already counted" and "counted, contributed nothing" the same no-op.
    ///
    /// Today the one powerup is the Neutralizer Canister: spare Neutralizing
    /// Agent, worth `balance.powerups.neutralizer_canister_charges` a can.
    /// Saturating throughout — a badge may carry up to 255 of them, and the
    /// pool is a u32 that must never wrap into a small number.
    fn count_charge_grant(self: *Session, player_id: u8) void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        if (slot.charge_grant != 0) return;
        const cans = slot.powerups[@intFromEnum(c.PowerupKind.neutralizer_canister)];
        if (cans == 0) return;
        const grant = @as(u32, cans) *| self.cfg.balance.powerups.neutralizer_canister_charges;
        slot.charge_grant = grant;
        const before = self.charges;
        self.charges +|= grant;
        std.log.info("player {} brought {} canister(s) — charges {} -> {}", .{
            player_id, cans, before, self.charges,
        });
    }

    /// A player takes their powerups away again: the pool gives back what
    /// they granted, or whatever is LEFT of it if the team has already spent
    /// past that — charges that were spent are spent, exactly as eaten hunger
    /// stays eaten (see `uncount_hunger_share`).  A depleted pool can
    /// therefore give back less than was granted, and never goes negative.
    fn uncount_charge_grant(self: *Session, player_id: u8) void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        const grant = slot.charge_grant;
        if (grant == 0) return;
        slot.charge_grant = 0;
        const taken = @min(grant, self.charges);
        const before = self.charges;
        self.charges -= taken;
        std.log.info("player {} took {} canister charge(s) back — charges {} -> {}", .{
            player_id, taken, before, self.charges,
        });
    }

    /// A counted player left the game: give back their share of the UNUSED
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
        std.log.info("player {} left — hunger bar now {}/{}", .{
            player_id, self.hunger.current, self.hunger.max,
        });
    }

    /// Give every seated player their avatar entity.
    ///
    /// The Lil Guys have no server representation: their one mechanical
    /// trace is the HEADCOUNT, which widens the bite via
    /// `balance.feast_width` and speeds it via
    /// `balance.bite_interval_effective` — everything else about them is
    /// client animation of `bite_settled`.
    fn spawn_players(self: *Session) !void {
        for (&self.players) |*p| {
            if (!p.occupied) {
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

    /// The session clock, in whole milliseconds of play time.
    pub fn now_ms(self: *const Session) u64 {
        return @intFromFloat(self.clock_ms);
    }

    /// All babies at the table: what every seated board brought, plus what
    /// this encounter hatched.  Both kinds speed the bite alike.
    fn babies_at_table(self: *const Session) u32 {
        var n: u32 = 0;
        for (&self.players) |*p| {
            if (!p.occupied) continue;
            n += c.baby_total(p.babies);
        }
        for (self.hatched) |h| n += h;
        return n;
    }

    /// Ms between bites for the table as seated RIGHT NOW.
    fn bite_interval_now(self: *const Session) u32 {
        return self.cfg.balance.bite_interval_effective(
            self.seated_players(),
            self.babies_at_table(),
        );
    }

    /// Drop every recent cast too old to help complete a group.  Run every
    /// tick so the window clients see (and the one complete_group scans)
    /// never carries expired entries.
    fn prune_recent(self: *Session) void {
        const now = self.now_ms();
        const window = self.cfg.balance.team_window_ms;
        var keep: usize = 0;
        for (0..self.recent_count) |i| {
            if (self.recent[i].at_ms + window < now) continue;
            self.recent[keep] = self.recent[i];
            keep += 1;
        }
        self.recent_count = keep;
    }

    /// Remember a landed cast so teammates can group with it.  A full window
    /// evicts its OLDEST entry: the one nearest expiry is the least likely
    /// to still complete anything.
    fn push_recent(self: *Session, cast: logic.RecentCast) void {
        if (self.recent_count >= logic.MAX_RECENT) {
            std.mem.copyForwards(
                logic.RecentCast,
                self.recent[0 .. self.recent_count - 1],
                self.recent[1..self.recent_count],
            );
            self.recent_count -= 1;
        }
        self.recent[self.recent_count] = cast;
        self.recent_count += 1;
    }

    /// Evict the window entries a fired group consumed.  `fire.consumed`
    /// indexes the window as it stood when `complete_group` scanned it, so
    /// this must run before anything else reorders it.
    fn consume_recent(self: *Session, fire: logic.GroupFire) void {
        var gone = [_]bool{false} ** logic.MAX_RECENT;
        for (fire.consumed[0..fire.consumed_count]) |i| gone[i] = true;
        var keep: usize = 0;
        for (0..self.recent_count) |i| {
            if (gone[i]) continue;
            self.recent[keep] = self.recent[i];
            keep += 1;
        }
        self.recent_count = keep;
    }

    /// One server tick: drain queued client input, advance the session clock
    /// by `dt` (seconds), fire any bite that came due, and broadcast the
    /// resulting state.
    pub fn tick(self: *Session, dt: f32) !void {
        self.profiler.begin(.drain);
        try self.drain_queues();
        self.profiler.end(.drain);

        // Holding — at the end screen (board final, already broadcast) or at
        // the pre-match guide (board seeded, nothing moving yet): nothing
        // below has anything to add, and the CLOCK FREEZES so cooldowns and
        // the group window cannot expire while nobody can play.  The drain
        // above is what lets a `restart` (or a seat change) through — a
        // restart clears its flag inside the drain and play resumes this
        // same tick.  The bite timer disarms so the hold's dead time is not
        // billed to the next meal.
        if (self.restart_pending or self.prematch) {
            self.next_bite_at = 0;
            // A frozen clock can never retire a settle window, so a lock left
            // over from before the hold would still be standing on resume —
            // chewing that finished a whole game ago.
            self.cast_locked_until = 0;
            return;
        }

        self.tick_count += 1;
        self.clock_ms += @as(f64, dt) * std.time.ms_per_s;
        self.prune_recent();

        // The bite timer.  Disarmed while nobody is seated: with nobody to
        // cast, biting would eat the encounter unattended — so an empty game
        // simply idles until someone takes a seat, and the first seated tick
        // arms the timer from now.
        if (self.seated_players() == 0) {
            self.next_bite_at = 0;
        } else {
            if (self.next_bite_at == 0) {
                self.next_bite_at = self.now_ms() + self.bite_interval_now();
            }
            // A slow tick can owe more than one bite; each settles in turn
            // (dt is capped by the driver, so this can never spin long).
            while (self.now_ms() >= self.next_bite_at) {
                try self.settle_bite();
                if (self.restart_pending) return;
                // Scheduled from the DUE time, not from now, so pacing does
                // not drift with tick jitter — and at the CURRENT crowd's
                // rate, so a seat taken or a baby hatched since the last
                // bite speeds the very next one.
                self.next_bite_at += self.bite_interval_now();
            }
        }

        self.profiler.begin(.broadcast);
        try self.broadcast_game_state();
        self.profiler.end(.broadcast);

        if (self.profiler.should_report(200)) {
            self.profiler.report_stderr("session tick");
        }
    }

    /// Settle one bite: bite, shift, refill, resolve special matches.
    ///
    /// Every cast has already landed the moment it was pressed, so the board
    /// this reads is exactly what the team defused in time.
    ///
    /// Order matters and is the whole mechanic.  The bite is priced against
    /// the field exactly as the casts left it, `shift_left` packs the
    /// survivors into the space it opened, and only then does `fill` top the
    /// field up — so refills always land BEHIND the survivors, at the right
    /// edge.  Matches resolve LAST, on the refilled field, because the
    /// refill is what lines new specials up.  The end condition is checked
    /// after all of it, because "field cleared" means the reservoir had
    /// nothing left to send either.
    ///
    /// Public only as a test seam: in play this runs from `tick` when the
    /// bite timer comes due, and a test that wants a settle without walking
    /// the clock needs to invoke it directly.
    /// Hard ceiling on settle passes, purely defensive.  Every pass past the
    /// first requires a match, every match pops at least two specials, and
    /// specials only ever leave play — so the real bound is half the
    /// encounter's special count.  This cap exists so a future rule change
    /// cannot turn settle_bite into an infinite loop.
    const MAX_SETTLE_PASSES: u8 = 64;

    pub fn settle_bite(self: *Session) !void {
        // The bite settles as a CASCADE: bite, shift, refill, resolve
        // matches — and when a match fired, its pops and its 5x5 changed the
        // front, so the Lil Guys bite AGAIN.  The loop runs until a pass
        // ends with no match; the summary numbers total over every pass.
        var cells_total: u16 = 0;
        var hunger_total: u32 = 0;
        var score_total: u32 = 0;
        var bitten_total: u16 = 0;
        var hatch_msg = proto.EggsHatched{};
        var passes: u8 = 0;

        // The bite's width is decided by the crowd at the table: the seats
        // held at THIS settle.
        const width = self.cfg.balance.feast_width(self.seated_players());

        while (passes < MAX_SETTLE_PASSES) {
            const feast = self.field.feast(&self.cfg.balance, width);

            // Hatch BEFORE the hunger lands: the babies joined the feast
            // that freed them, so their capacity is on the bar when it
            // fills.  Types are rolled here (uniform, from the session's
            // seed) so every client and every board sees the same brood.
            for (feast.hatched_cells[0..feast.hatched]) |cell| {
                const t = self.rand().enumValue(c.BabyType);
                if (hatch_msg.count < proto.MAX_HATCHES_WIRE) {
                    hatch_msg.cells[hatch_msg.count] = cell;
                    hatch_msg.types[hatch_msg.count] = t;
                    hatch_msg.count += 1;
                }
                self.hatched[@intFromEnum(t)] +|= 1;
                self.stats.eggs_hatched[@intFromEnum(t)] +|= 1;
            }
            if (feast.hatched > 0) {
                self.hunger.max +|= logic.hatch_hunger(&self.cfg.balance, feast.hatched);
            }

            logic.add_hunger(&self.hunger, feast.hunger_total());
            self.score += feast.score;
            // Swallowed canisters refill the team's Neutralizing Agent
            // energy — credited before check_end so a feast that both
            // drained the wallet and drank a canister is judged on the
            // refilled pool.
            if (feast.charges_refilled > 0) {
                const before = self.charges;
                self.charges +|= feast.charges_refilled;
                std.log.info("feast drank {} canister{s} — charges {} -> {}", .{
                    feast.canisters,
                    if (feast.canisters == 1) "" else "s",
                    before,
                    self.charges,
                });
            }
            self.record_feast(feast);
            cells_total +|= feast.cells;
            hunger_total +|= feast.hunger_total();
            score_total +|= feast.score;
            bitten_total +|= feast.total_bitten();

            // The conveyor advances: every row's survivors pack left into
            // the space the bite (or a match pass's pops) opened.  Then
            // the refill: the one part of a settle a client cannot derive
            // (it comes out of the session's PRNG), so which cells filled —
            // and with what — is captured and broadcast.
            _ = self.field.shift_left();
            var was_empty = [_]bool{false} ** c.MAX_GRID_CELLS;
            for (0..self.field.grid.len()) |flat| {
                was_empty[flat] = !self.field.grid.get(@intCast(flat)).is_slime();
            }
            _ = self.field.fill(&self.cfg.balance, self.rand());
            var refill = proto.FieldRefilled{ .pass = passes };
            for (0..self.field.grid.len()) |flat| {
                const cell = self.field.grid.get(@intCast(flat));
                if (!was_empty[flat] or !cell.is_slime()) continue;
                refill.cells[refill.count] = @intCast(flat);
                refill.contents[refill.count] = cell;
                refill.count += 1;
            }
            var rbuf: [proto.FieldRefilled.MAX_ENCODED]u8 = undefined;
            var rfbs = std.io.fixedBufferStream(&rbuf);
            try proto.encode(rfbs.writer(), .field_refilled, refill);
            try self.broadcast_raw(rfbs.getWritten());

            // Matches fire on the REFILLED field — the refill is what lines
            // new specials up.  Pops leave holes; whether the next turn's
            // shift tidies them or the next PASS eats through them is
            // decided right here.
            const matched = self.field.resolve_matches(&self.cfg.balance);
            for (matched.matches[0..matched.count]) |m| {
                var msg = proto.SpecialMatched{
                    .kind = m.kind,
                    .pass = passes,
                    .center = m.center,
                    .cell_count = m.len,
                    .downgraded = m.downgraded,
                    .neutralized = m.neutralized,
                    .rocks_broken = m.rocks_broken,
                };
                @memcpy(msg.cells[0..m.len], m.cells[0..m.len]);
                var mbuf: [proto.SpecialMatched.MAX_ENCODED]u8 = undefined;
                var mfbs = std.io.fixedBufferStream(&mbuf);
                try proto.encode(mfbs.writer(), .special_matched, msg);
                try self.broadcast_raw(mfbs.getWritten());
                std.log.info("special match (pass {}): {} {s}s popped at cell {}", .{
                    passes, m.len, @tagName(m.kind), m.center,
                });
            }

            passes += 1;
            // No match: nothing re-opened, the meal is over.
            if (matched.count == 0) break;
        }

        // The meal is over, so the settle window opens: for the next
        // `settle_lockout_ms` the board is the Lil Guys', and every cast is
        // refused.  Set AFTER the whole cascade, not per pass — one window
        // covers the entire meal however many times it re-opened, so a long
        // chain does not stack lockouts on top of each other.
        //
        // Clients animate the chewing over roughly this window, but the
        // animation only approximates it; this is the number that decides.
        self.cast_locked_until = self.now_ms() + self.cfg.balance.settle_lockout_ms;

        // The feast is the ONLY thing that adds hunger, so it is the only
        // damage event in the game — announced pool-level (no actor).  Sent
        // even at zero so the client's damage cue is not silently conditional
        // on the field having been reachable.
        try self.broadcast_action_result(.{
            .tag = .damage,
            .actor_entity = std.math.maxInt(u32),
            .target_entity = std.math.maxInt(u32),
            .value = stat_u16(hunger_total),
        });

        // Announce the bite's hatches (aggregated over every pass) before
        // the summary, so clients animate them on the board it describes.
        if (hatch_msg.count > 0) {
            var hbuf: [proto.EggsHatched.MAX_ENCODED]u8 = undefined;
            var hfbs = std.io.fixedBufferStream(&hbuf);
            try proto.encode(hfbs.writer(), .eggs_hatched, hatch_msg);
            try self.broadcast_raw(hfbs.getWritten());
            std.log.info("hatched {} bab{s} from the feast's eggs", .{
                hatch_msg.count, if (hatch_msg.count == 1) "y" else "ies",
            });
        }

        var buf: [32]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .bite_settled, proto.BiteSettled{
            .bite = self.bite,
            .cells_eaten = cells_total,
            .hunger_added = stat_u16(hunger_total),
            .hazards_bitten = bitten_total,
            .score_added = score_total,
            .charges_left = self.charges,
            .passes = passes,
        });
        try self.broadcast_raw(fbs.getWritten());

        std.log.info("bite {} settled — ate {} and nibbled {} over {} pass(es), hunger+{} score+{} charges={} reservoir={}", .{
            self.bite,
            cells_total,
            bitten_total,
            passes,
            hunger_total,
            score_total,
            self.charges,
            self.field.reservoir.total(),
        });

        try self.check_end();
        if (self.restart_pending) return;

        self.bite +|= 1;
    }

    /// Tell one player their cast was refused, and by how much.
    ///
    /// Sent to the caster alone: nothing landed, so there is nothing for
    /// anyone else to redraw.
    fn send_over_budget(self: *Session, player_id: u8, needed: u32) !void {
        const slot = &self.players[player_id];
        if (!slot.occupied) return;
        const t = self.connections[slot.conn].transport orelse return;
        var buf: [16]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .over_budget, proto.OverBudget{
            .needed = needed,
            .have = self.charges,
        });
        t.send(fbs.getWritten()) catch {};
    }

    /// Tell one player their cast was refused for a reason with no numbers.
    ///
    /// Sent to the caster alone, for the same reason as `send_over_budget`:
    /// nothing landed, so there is nothing for anyone else to redraw.
    fn send_cast_refused(self: *Session, player_id: u8, reason: proto.CastRefusal) !void {
        const slot = &self.players[player_id];
        if (!slot.occupied) return;
        const t = self.connections[slot.conn].transport orelse return;
        var buf: [8]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .cast_refused, proto.CastRefused{ .reason = reason });
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

        const outcome = self.field.apply_shape(&self.cfg.balance, stamp.shape, row, col);

        var msg = proto.ShapeCast{
            .caster = stamp.anchor_player,
            .anchor = anchor,
            .downgraded = outcome.downgraded,
            .neutralized = outcome.neutralized,
            .off_grid = outcome.off_grid,
            .inert = outcome.inert,
            .rocks_broken = outcome.rocks_broken,
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
        fs.rocks_broken +|= outcome.rocks_broken;
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
        fs.hazards_bitten +|= feast.total_bitten();
        fs.neutral_consumed +|= feast.neutral;
        fs.defused_consumed +|= feast.defused;
        fs.agents_consumed +|= feast.agents;
        fs.rocks_broken +|= feast.agent_rocks_broken;
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
        for (&self.connections, 0..) |*conn, conn_id| {
            if (!conn.active) continue;
            conn.queue_lock.lock();
            const data = conn.msg_queue.items;
            if (data.len == 0) {
                conn.queue_lock.unlock();
                continue;
            }
            var local_buf: [16384]u8 = undefined;
            const len = @min(data.len, local_buf.len);
            @memcpy(local_buf[0..len], data[0..len]);
            conn.msg_queue.clearRetainingCapacity();
            conn.queue_lock.unlock();

            var fbs = std.io.fixedBufferStream(local_buf[0..len]);
            while (fbs.pos < len) {
                const tag = proto.read_tag(fbs.reader()) catch break;
                self.handle_client_message(conn_id, tag, &fbs) catch {};
            }
        }
    }

    fn handle_client_message(
        self: *Session,
        conn_id: usize,
        tag: proto.MsgTag,
        fbs: *std.io.FixedBufferStream([]u8),
    ) !void {
        // Gameplay messages need a seat; slot messages do not.  EVERY arm
        // decodes its payload before deciding anything, so an ignored message
        // (observer input, mid-restart input) still leaves the stream in sync
        // for whatever is queued behind it.
        const seat: ?u8 = self.connections[conn_id].player_id;
        switch (tag) {
            .take_slot => {
                const p = try proto.decode_take_slot(fbs.reader());
                try self.take_slot(conn_id, p);
            },
            .leave_slot => {
                const pid = seat orelse return;
                self.release_slot(pid);
                // Confirm the new standing: the client is an observer again.
                try self.send_game_start_to_conn(conn_id);
            },
            .restart => {
                // Advances a HOLD; mid-game it is a stray click.  Any
                // connection is honored — the browser tab that sends it may
                // well be the room's observer display.
                if (self.restart_pending) {
                    // End screen -> next encounter's PRE-MATCH guide.  Seats
                    // are kept; the pool and the bar re-seed from them.
                    const label = self.cfg.encounters.default().label;
                    std.log.info("restart requested — next encounter, holding at pre-match", .{});
                    try self.start_game(label);
                    self.prematch = true;
                    try self.broadcast_game_start(label);
                } else if (self.prematch) {
                    // Pre-match guide -> play.
                    std.log.info("pre-match dismissed — play begins", .{});
                    self.prematch = false;
                    const encounter = self.current_encounter orelse return;
                    try self.broadcast_game_start(encounter.label);
                }
            },
            .cycle_shape => {
                const p = try proto.decode_cycle_shape(fbs.reader());
                const player_id = seat orelse return;
                if (self.restart_pending or self.prematch) return;
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
                const player_id = seat orelse return;
                if (self.restart_pending or self.prematch) return;
                const d = p.dir.delta();
                // Clamped, so any number of steps in any direction leaves the
                // cursor on a real cell.
                self.cursors[player_id] =
                    self.field.grid.step(self.cursors[player_id], d.d_row, d.d_col);
            },
            .cast => {
                const player_id = seat orelse return;
                if (self.restart_pending or self.prematch) return;
                const bal = &self.cfg.balance;
                const now = self.now_ms();
                // Still cooling down: silent ignore.  The client draws the
                // timer, so an early press is impatience, not a mistake —
                // and it must not restart the cooldown.
                if (now < self.cooldown_until[player_id]) return;

                // The Lil Guys are still chewing.  Refused OUT LOUD, unlike
                // the cooldown above: this window has no countdown of its own
                // on the panel, so a silent drop would read as the game
                // dropping inputs.  Checked before the group window is pruned
                // and before anything is priced — a refused cast is a cast
                // that never happened, so it must not age the team window or
                // touch the pool.
                if (now < self.cast_locked_until) {
                    std.log.debug("player {} cast refused — settling for {}ms more", .{
                        player_id, self.cast_locked_until - now,
                    });
                    try self.send_cast_refused(player_id, .settling);
                    return;
                }

                // Every selection names a real move, so there is no "this
                // spells nothing" case: a cast always fires something.
                const cast = logic.RecentCast{
                    .player_id = player_id,
                    .move = self.selected[player_id],
                    .square = self.cursors[player_id],
                    .at_ms = now,
                };

                // Does this cast complete a team recipe?  Decided BEFORE the
                // price check, because a completed group is priced as the
                // group — the whole upgrade may be cheaper than the move.
                self.prune_recent();
                const fire = logic.complete_group(bal, self.recent[0..self.recent_count], cast);
                const cost: u32 = if (fire) |f|
                    bal.team_recipes[f.recipe_index].cost
                else
                    bal.player_recipes[cast.move].cost;

                // The pool cannot pay: refused outright.  Nothing lands, no
                // cooldown starts, and the caster alone is told what it
                // would have taken.  The bite clock keeps the game moving,
                // so a broke team plays on the nibbles alone.
                if (cost > self.charges) {
                    std.log.debug("player {} cast refused — costs {}, pool holds {}", .{
                        player_id, cost, self.charges,
                    });
                    try self.send_over_budget(player_id, cost);
                    return;
                }

                self.charges -= cost;
                self.stats.feast.charges_spent +|= stat_u16(cost);
                self.cooldown_until[player_id] = now + bal.cast_cooldown_ms;
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

                // The cast's own move lands first, then the group it
                // completed stamps OVER it — the upgrade is the headline.
                self.stats.player_recipe_hits[cast.move] +|= 1;
                self.stats.players[player_id].recipe_casts +|= 1;
                try self.broadcast_recipe_fired(.player, cast.move, 1);
                try self.stamp_shape(logic.move_stamp(bal, cast.move, player_id), cast.square);

                if (fire) |f| {
                    // Consumed contributors leave the window — a cast feeds
                    // at most one group — and the completer's cast never
                    // enters it: it has already done its coordinating.
                    self.consume_recent(f);
                    self.stats.team_recipe_hits[f.recipe_index] +|= 1;
                    self.stats.players[player_id].recipe_casts +|= 1;
                    try self.broadcast_recipe_fired(.team, f.recipe_index, 1);
                    try self.stamp_shape(
                        logic.group_stamp(bal, f.recipe_index, player_id),
                        cast.square,
                    );
                    std.log.debug("player {} completed group '{s}' (cost {}, pool {})", .{
                        player_id,
                        bal.team_recipes[f.recipe_index].label,
                        cost,
                        self.charges,
                    });
                } else {
                    self.push_recent(cast);
                    std.log.debug("player {} cast '{s}' (cost {}, pool {})", .{
                        player_id,
                        bal.player_recipes[cast.move].label,
                        cost,
                        self.charges,
                    });
                }
            },
            else => {},
        }
    }

    /// Bind a connection to a free player seat.  SILENT no-ops: a connection
    /// that already holds a seat, and a game whose four seats are all taken —
    /// the asker simply stays what it was.
    ///
    /// Public as a test seam: in play this runs from the `take_slot` wire
    /// message.  Takes the decoded payload whole rather than its fields, so
    /// that what a board reports about itself can grow without every caller
    /// (mostly tests) being rewritten to pass another zero.
    pub fn take_slot(self: *Session, conn_id: usize, req: proto.TakeSlot) !void {
        const conn = &self.connections[conn_id];
        if (conn.player_id != null) return;
        const slot = for (&self.players) |*p| {
            if (!p.occupied) break p;
        } else {
            std.log.debug("take_slot ignored — all {} seats taken", .{MAX_PLAYERS});
            return;
        };

        slot.occupied = true;
        slot.appetite = req.appetite;
        slot.babies = req.babies;
        slot.appearance = req.appearance;
        slot.powerups = req.powerups;
        slot.conn = conn_id;
        conn.player_id = slot.player_id;
        // A freed seat keeps nothing of its previous owner.
        self.stats.players[slot.player_id] = .{};

        // Fold them into the running game: pool first (their proportion of
        // what remains, see logic.grow_charges), then the bar, then a body.
        logic.grow_charges(&self.charges, self.counted_players());
        // The grant lands AFTER the growth, so what the newcomer's share is
        // computed from is the pool the team already had — see the matching
        // note in release_slot for why the order is the whole mechanism.
        self.count_charge_grant(slot.player_id);
        self.count_hunger_share(slot.player_id);
        try self.spawn_player_midgame(slot.player_id);
        try self.send_game_start_to_conn(conn_id);
        // Appearance is logged because it is invisible otherwise: a missing
        // critter or palette is a legal state that still renders a creature,
        // so a break anywhere upstream of here looks exactly like a player
        // who never onboarded.  This line is the one place to tell them apart.
        std.log.info(
            "player {} took a seat (appetite {}, babies {}, critter {?}, palette {}, {} seated)",
            .{
                slot.player_id,             req.appetite,
                c.baby_total(req.babies),   req.appearance.critter,
                req.appearance.led != null, self.seated_players(),
            },
        );
    }

    /// Saturating u32 → u16 for stats fields.
    fn stat_u16(v: u32) u16 {
        return @intCast(@min(v, std.math.maxInt(u16)));
    }

    /// Decide whether the encounter is over.  Called ONLY from
    /// `settle_bite`: nothing between bites can FILL the hunger bar or move
    /// the slime count.  A mid-game leave can shrink the bar's capacity down
    /// to `current` (see uncount_hunger_share), but never below it, so the
    /// verdict still cannot change until the next bite settles.
    ///
    /// Running out of charges is deliberately NOT an ending: a broke team's
    /// casts are refused (see the cast handler) while the bite's nibbles
    /// keep softening the field, so the game always moves — the bar is the
    /// clock that eventually calls it.
    fn check_end(self: *Session) !void {
        if (self.restart_pending) return;
        // Field-cleared wins ties: if the final feast fills the bar exactly,
        // the players still ate everything they could.
        if (self.field.is_exhausted()) {
            std.log.info("all slime consumed — encounter over, score={}", .{self.score});
            try self.end_game(.field_cleared);
            return;
        }
        // TIME IS UP.  The bar is not a loss, it is the clock that bounds
        // the game: the Lil Guys are sated and the encounter ends on
        // whatever the team scored.
        if (logic.hunger_full(self.hunger)) {
            std.log.info("hunger bar full — encounter over, score={}", .{self.score});
            try self.end_game(.hunger_full);
            return;
        }
    }

    fn end_game(self: *Session, reason: proto.EndReason) !void {
        std.log.info("game over — score: {} reason: {s}", .{ self.score, @tagName(reason) });

        // The final board, before the report.  Without this the last state
        // clients ever saw is the one from BEFORE the closing feast: they
        // would be told the game ended on a board that still holds the slime
        // it just ate.  Clients replay that feast as their outro, and they
        // need the board it lands on to do it.
        try self.broadcast_game_state();

        // Finalise the tuning report.
        self.stats.reason = reason;
        self.stats.slime_total = self.slime_total;
        self.stats.slime_left = self.field.remaining();
        self.stats.hunger_final = self.hunger.current;
        self.stats.hunger_max = self.hunger.max;
        // Compact per-player stats (indexed by player_id during play) into a
        // dense list for the wire.
        var compacted = [_]proto.PlayerStats{.{}} ** MAX_PLAYERS;
        var dense: u8 = 0;
        for (&self.players, 0..) |*slot, pid| {
            if (!slot.occupied) continue;
            compacted[dense] = self.stats.players[pid];
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

        // Hold at the end screen until a `restart` arrives; seated players
        // keep their seats.
        self.restart_pending = true;
    }

    /// Spawn an ECS entity for a player who took a seat while the game is in
    /// progress.  IDEMPOTENT: a player owns at most one entity, so a repeated
    /// `take_slot` (retry, duplicated input) is a no-op.  Snapshots walk the
    /// player_marker array and the client's selection projection treats one
    /// entity as one caster, so a second body would show a phantom teammate
    /// with a wheel of their own.
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

    /// The game_start payload for one connection: encounter label, join code
    /// (the game id), the receiver's standing (their seat, or NO_PLAYER for
    /// an observer), the realtime pacing (cast cooldown + group window), the
    /// charge pool and the grid dimensions the client must render.
    fn game_start_msg(self: *const Session, label: []const u8, player_id: u8) proto.GameStart {
        var msg = proto.GameStart{
            .encounter_label = [_]u8{0} ** 32,
            .encounter_label_len = @intCast(@min(label.len, 32)),
            .player_id = player_id,
            .join_code = self.join_code,
            .prematch = self.prematch,
            .cast_cooldown_ms = self.cfg.balance.cast_cooldown_ms,
            .team_window_ms = self.cfg.balance.team_window_ms,
            .charges = self.charges,
            .grid_rows = self.field.grid.rows,
            .grid_cols = self.field.grid.cols,
        };
        @memcpy(msg.encounter_label[0..msg.encounter_label_len], label[0..msg.encounter_label_len]);
        return msg;
    }

    /// Send one connection a game_start describing its CURRENT standing —
    /// on connect, after a take_slot is granted, and after a leave_slot.
    fn send_game_start_to_conn(self: *Session, conn_id: usize) !void {
        if (conn_id >= MAX_CONNECTIONS) return;
        const conn = &self.connections[conn_id];
        const t = conn.transport orelse return;
        const encounter = self.current_encounter orelse return;
        const pid = conn.player_id orelse proto.NO_PLAYER;
        var buf: [80]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .game_start, self.game_start_msg(encounter.label, pid));
        try t.send(fbs.getWritten());
    }

    /// Tell every connection a fresh encounter began, each from its own
    /// standing (seat or observer).
    pub fn broadcast_game_start(self: *Session, encounter_label: []const u8) !void {
        for (&self.connections) |*conn| {
            if (!conn.active) continue;
            const t = conn.transport orelse continue;
            const pid = conn.player_id orelse proto.NO_PLAYER;
            var buf: [80]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try proto.encode(fbs.writer(), .game_start, self.game_start_msg(encounter_label, pid));
            try t.send(fbs.getWritten());
        }
    }

    fn broadcast_game_state(self: *Session) !void {
        const now = self.now_ms();
        var snap = proto.GameState.blank;
        snap.tick = self.tick_count;
        snap.bite = self.bite;
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
        snap.hatched = self.hatched;

        // The bite countdown clients draw.  0 while the timer is disarmed
        // (nobody seated), which the client reads as "not coming".
        snap.next_bite_ms = if (self.next_bite_at > now)
            @intCast(@min(self.next_bite_at - now, std.math.maxInt(u32)))
        else
            0;

        // What is left of the settle window, on the same "0 means not
        // happening" convention as the bite countdown above.  Table-wide, so
        // every seat panel counts down the same number.
        snap.cast_locked_ms = if (self.cast_locked_until > now)
            @intCast(@min(self.cast_locked_until - now, std.math.maxInt(u32)))
        else
            0;

        // The group window as it stands.  Sent to everyone: a player
        // deciding where to aim needs to see which squares are ripe, and the
        // client previews group potential from this list plus its own live
        // aim.
        snap.recent_count = @intCast(@min(self.recent_count, proto.MAX_RECENT_WIRE));
        for (self.recent[0..snap.recent_count], 0..) |rc, i| {
            snap.recent[i] = .{
                .player_id = rc.player_id,
                .move = rc.move,
                .square = rc.square,
                .age_ms = @intCast(@min(now -| rc.at_ms, std.math.maxInt(u32))),
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
                .cooldown_ms = @intCast(@min(
                    self.cooldown_until[own] -| now,
                    std.math.maxInt(u32),
                )),
                // The move this player would fire, so every client can preview
                // its footprint under their cursor — theirs AND their
                // teammates', which is how a group gets agreed on.
                .selected_shape = self.selected[own],
                .cursor_row = self.field.grid.row_of(self.cursors[own]),
                .cursor_col = self.field.grid.col_of(self.cursors[own]),
                .babies = self.players[own].babies,
                .appearance = self.players[own].appearance,
                .powerups = self.players[own].powerups,
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

    /// Send to EVERY active connection — observers included: the game is a
    /// spectator sport by default.
    fn broadcast_raw(self: *Session, data: []const u8) !void {
        for (&self.connections) |*conn| {
            if (!conn.active) continue;
            const t = conn.transport orelse continue;
            t.send(data) catch {};
        }
    }

    pub fn enqueue_message(self: *Session, conn_id: usize, data: []const u8) void {
        if (conn_id >= MAX_CONNECTIONS) return;
        const conn = &self.connections[conn_id];
        conn.queue_lock.lock();
        defer conn.queue_lock.unlock();
        conn.msg_queue.appendSlice(conn.allocator, data) catch {};
    }
};

fn set_world_system_signatures(world: *GameWorld) void {
    var sig = @import("ecs_zig").Signature.initEmpty();
    sig.set(GameWorld.component_type(c.Kind));
    sig.set(GameWorld.component_type(c.Owner));
    sig.set(GameWorld.component_type(c.PlayerMarker));
    world.set_system_signature(PlayerTeam, sig);
}
