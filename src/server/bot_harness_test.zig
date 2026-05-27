//! Bot test harness: injects bots into PlayerSlots in place of real clients.
//!
//! Each bot is driven by a `Profile` (a repeating action sequence from
//! bots.zig). On every round the harness encodes the bot's next `Move` as a
//! `choose_action` protocol message and enqueues it into the session, exactly
//! replicating what a real WebSocket client would send.
//!
//! ## Usage
//!
//!   var h = try BotHarness.init(allocator, &bots.team_all_damage, wave, "BOTKEY".*);
//!   defer h.deinit();
//!   // advance one full round (inject actions + tick past timer):
//!   try h.step();
//!   // check game state via h.session ...
//!
//! ## Relation to the wave harness
//!
//! The wave harness (waves.zig + session.spawn_wave) configures the *enemy*
//! side.  This harness configures the *player* side.  Both can be combined:
//! BotHarness.init accepts any *const waves.Wave, so you can test any
//! bot-team / enemy-wave pairing.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;
const waves = shared.waves;
const bots = shared.bots;

const session_mod = @import("session.zig");
const Session = session_mod.Session;
const GameWorld = session_mod.GameWorld;
const PlayerTeam = session_mod.PlayerTeam;

// ---------------------------------------------------------------------------
// BotHarness
// ---------------------------------------------------------------------------

/// Internal state for one injected bot.
const BotState = struct {
    player_id: u8,
    profile: *const bots.Profile,
    /// Accumulates outbound server messages; drained / ignored in harness tests.
    buf: std.ArrayListUnmanaged(u8),
    bt: shared.BufferTransport,

    fn init(self: *BotState, allocator: std.mem.Allocator, pid: u8, profile: *const bots.Profile) void {
        self.buf = .empty;
        self.player_id = pid;
        self.profile = profile;
        self.bt = shared.BufferTransport{ .buf = &self.buf, .allocator = allocator };
    }

    fn transport(self: *BotState) shared.Transport {
        return self.bt.transport();
    }

    fn deinit(self: *BotState, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }
};

/// Tunable parameters for BotHarness.  All fields have defaults so callers
/// can use `.{}` for standard behaviour.
pub const BotHarnessOptions = struct {
    /// Round duration in seconds applied to the session before the game starts.
    /// Default matches ROUND_DURATION_DEFAULT_S (3 s) — appropriate for
    /// real-time watching against a live server.  Set to a small value
    /// (e.g. 0.001) for fast headless CI runs.
    round_duration: f32 = shared.game_logic.ROUND_DURATION_DEFAULT_S,
};

pub const BotHarness = struct {
    allocator: std.mem.Allocator,
    session: Session,
    /// One entry per bot in the team; slice is allocator-owned.
    bot_states: []BotState,
    /// Number of rounds that have been resolved (incremented by step()).
    round: u32,

    /// Initialise the harness.
    ///
    /// - Joins each bot from `team` as an occupied, connected PlayerSlot.
    /// - Sets HP from BotEntry.stats.max_hp (ClassTag is forced to .fighter
    ///   as a placeholder; class is otherwise irrelevant since stat overrides
    ///   are applied directly in spawn_bots below).
    /// - Starts the game against `wave` directly, bypassing the lobby ready flow.
    ///
    /// Asserts:
    ///   - team.bots.len >= 1
    ///   - team.bots.len <= MAX_PLAYERS
    ///   - every profile has at least one move
    pub fn init(
        allocator: std.mem.Allocator,
        team: *const bots.BotTeam,
        wave: *const waves.Wave,
        join_code: [6]u8,
        opts: BotHarnessOptions,
    ) !BotHarness {
        std.debug.assert(team.bots.len >= 1);
        std.debug.assert(team.bots.len <= session_mod.MAX_PLAYERS);
        for (team.bots) |b| std.debug.assert(b.profile.moves.len >= 1);

        const bot_states = try allocator.alloc(BotState, team.bots.len);
        errdefer allocator.free(bot_states);

        var sess = try Session.init(allocator, join_code);

        for (team.bots, 0..) |entry, i| {
            bot_states[i].init(allocator, 0xFF, entry.profile);
            const pid = sess.join(bot_states[i].transport(), entry.name) orelse {
                // Free already-initialised BotStates before returning the error.
                for (bot_states[0..i]) |*bs| bs.deinit(allocator);
                allocator.free(bot_states);
                sess.deinit();
                return error.SessionFull;
            };
            bot_states[i].player_id = pid;
        }

        // Apply timing options before starting the game.
        sess.round_duration = opts.round_duration;
        sess.round_timer = opts.round_duration;

        // Start the game, spawning enemies from `wave`.  Then replace player
        // entities with ones whose HP comes from BotStats rather than class defaults.
        try sess.start_game_wave(wave);
        try respawn_bots(&sess, team, bot_states);

        return BotHarness{
            .allocator = allocator,
            .session = sess,
            .bot_states = bot_states,
            .round = 0,
        };
    }

    pub fn deinit(self: *BotHarness) void {
        self.session.deinit();
        for (self.bot_states) |*bs| bs.deinit(self.allocator);
        self.allocator.free(self.bot_states);
    }

    /// Encode each bot's next move as a single-slot combo and enqueue it.
    /// Call this before ticking past the round timer, or use step() which
    /// does both.
    pub fn inject_actions(self: *BotHarness) !void {
        for (self.bot_states) |*bs| {
            const move = bs.profile.moves[self.round % bs.profile.moves.len];
            const combo = c.ActionCombo{
                .slots = [_]c.ComboSlot{.{ .action = move }} ++
                         [_]c.ComboSlot{.{ .action = .damage }} ** (c.MAX_COMBO_LEN - 1),
                .len = 1,
            };
            var buf: [8]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try proto.encode(fbs.writer(), .choose_combo, proto.ChooseCombo{ .combo = combo });
            self.session.enqueue_message(bs.player_id, fbs.getWritten());
        }
    }

    /// Advance the session by exactly one full round:
    ///   1. inject_actions() for every bot
    ///   2. tick past the round timer (small dt ticks until timer fires)
    ///
    /// Increments self.round after resolution.
    pub fn step(self: *BotHarness) !void {
        try self.inject_actions();
        // Tick with dt = round_duration + epsilon so the timer expires in one tick.
        const dt = self.session.round_duration + 0.001;
        try self.session.tick(dt);
        self.round += 1;
    }

    /// Convenience: run up to `max_rounds` steps, stopping early when the
    /// session leaves the playing phase (game over).
    /// Returns the number of rounds actually resolved.
    pub fn run_to_completion(self: *BotHarness, max_rounds: u32) !u32 {
        var r: u32 = 0;
        while (r < max_rounds and self.session.phase == .playing) : (r += 1) {
            try self.step();
        }
        return r;
    }

};

// ---------------------------------------------------------------------------
// Internal: respawn player entities with BotStats HP
// ---------------------------------------------------------------------------

/// After start_game_wave() spawns players using class_defaults, this function
/// destroys those entities and recreates them with the HP values from BotStats.
/// This is done after start_game_wave (not before) so the world is fully
/// initialised and system signatures are set.
fn respawn_bots(
    sess: *Session,
    team: *const bots.BotTeam,
    bot_states: []const BotState,
) !void {
    // Rebuild player entities with bot-specific class/owner but no Health/Shield
    // (HP lives in the shared pool).  Also recompute shared_hp from bot stats.
    sess.shared_hp = .{ .current = 0, .max = 0 };
    sess.shared_shield = .{ .hp = 0 };
    for (team.bots, bot_states) |entry, bs| {
        const slot = &sess.players[bs.player_id];
        // Destroy the entity created by spawn_players().
        if (slot.entity != std.math.maxInt(u32)) {
            sess.world.destroy_entity(slot.entity);
        }
        // Create a fresh entity.  No Health/Shield — shared pool tracks HP.
        const e = sess.world.create_entity();
        slot.entity = e;
        // ClassTag is required by the system signature; .fighter is used as a
        // no-op placeholder — bots.zig has no ClassTag concept.
        sess.world.add_component(e, c.Class{ .tag = .fighter });
        sess.world.add_component(e, c.Team{ .id = .players });
        sess.world.add_component(e, c.Owner{ .player_id = bs.player_id });
        sess.world.add_component(e, c.PlayerMarker{});
        // Accumulate this bot's max HP into the shared pool.
        const new_max = @as(u32, sess.shared_hp.max) + @as(u32, entry.stats.max_hp);
        sess.shared_hp.max = @intCast(@min(new_max, @as(u32, std.math.maxInt(u16))));
        sess.shared_hp.current = sess.shared_hp.max;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// One enemy with HP = V so a single damage action depletes the shared enemy pool.
const wave_one_shot = waves.Wave{
    .label = "bot_one_shot",
    .entries = &[_]waves.SpawnEntry{.{
        .class = .grunt,
        .grid_col = 0,
        .grid_row = 0,
        .stats = .{ .max_hp = shared.game_logic.ACTION_EFFECT_VALUE, .attack = 1 },
    }},
    .next_wave = null,
};

/// Single tanky grunt that cannot be killed — used to test multi-round survival.
/// HP set high enough that no realistic bot team kills it within test rounds.
const wave_unkillable = waves.Wave{
    .label = "bot_unkillable",
    .entries = &[_]waves.SpawnEntry{.{
        .class = .grunt,
        .grid_col = 0,
        .grid_row = 0,
        .stats = .{ .max_hp = 60_000, .attack = 1 },
    }},
    .next_wave = null,
};

/// Unkillable enemy pool — shared_enemy_hp far too high to deplete in tests.
/// Enemy intent = 1 dmg/round to party (pool is alive, entity count irrelevant).
/// Used by survival tests that need a permanent attacker.
const wave_overwhelming = waves.Wave{
    .label = "bot_overwhelming",
    .entries = &[_]waves.SpawnEntry{
        .{ .class = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .max_hp = 60_000, .attack = 1 } },
    },
    .next_wave = null,
};

const wave_lethal_pack = wave_overwhelming;

/// Two killable grunts — shared_enemy_hp = 160 (2 × 80).
/// Used to verify mixed teams can actually win.
const wave_two_grunts = waves.Wave{
    .label = "bot_two_grunts",
    .entries = &[_]waves.SpawnEntry{
        .{ .class = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .max_hp = 80, .attack = 1 } },
        .{ .class = .grunt, .grid_col = 1, .grid_row = 0, .stats = .{ .max_hp = 80, .attack = 1 } },
    },
    .next_wave = null,
};

test "all_damage team beats a beatable wave" {
    // Two damage bots vs a single 40-HP grunt.
    // shared_enemy_hp = 40. damage_pool = 2/round → 20 rounds to deplete.
    // Party pool = 2 × fighter_hp. 1 enemy deals 1 dmg/round → party survives easily.
    const allocator = std.testing.allocator;
    const wave_beatable = waves.Wave{
        .label = "bot_beatable",
        .entries = &[_]waves.SpawnEntry{.{
            .class = .grunt,
            .grid_col = 0,
            .grid_row = 0,
            .stats = .{ .max_hp = 40, .attack = 1 },
        }},
        .next_wave = null,
    };
    var h = try BotHarness.init(allocator, &bots.team_all_damage, &wave_beatable, "BOTKEY".*, .{});
    defer h.deinit();

    const rounds = try h.run_to_completion(200);

    try std.testing.expect(rounds < 200);
    try std.testing.expectEqual(session_mod.SessionPhase.lobby, h.session.phase);
    try std.testing.expectEqual(@as(u16, 0), h.session.shared_enemy_hp.current);
}


test "mixed team beats two-grunt wave" {
    // team_mixed: tank (damage), medic (heal), cannon (damage).
    // wave_two_grunts: 2 grunts × 80 HP = 160 shared_enemy_hp.
    // damage_pool = 2/round → 80 rounds to deplete.
    const allocator = std.testing.allocator;
    var h = try BotHarness.init(allocator, &bots.team_mixed, &wave_two_grunts, "BOTKEY".*, .{});
    defer h.deinit();

    const rounds = try h.run_to_completion(200);

    try std.testing.expect(rounds < 200);
    try std.testing.expectEqual(session_mod.SessionPhase.lobby, h.session.phase);
    try std.testing.expectEqual(@as(u16, 0), h.session.shared_enemy_hp.current);
}

test "tank bot absorbs incoming damage with shield rotation" {
    // One bot with the 'tank' profile ({shield, shield, damage}).
    // wave_lethal_pack: unkillable enemy pool → 1 dmg/round to party pool.
    // Shield grants ACTION_EFFECT_VALUE = 1 HP to shared shield buffer per action.
    //
    // Damage-only bot (pool = 30 HP, no shields):
    //   Takes 1 damage every round → pool gone in 30 rounds.
    //
    // Tank bot (pool = 30 HP, {shield, shield, damage} cycle):
    //   Round 1: +1 shield, -1 → shield 0, pool 30 (no net loss)
    //   Round 2: +1 shield, -1 → shield 0, pool 30
    //   Round 3: damage, -1    → pool 29
    //   ... cycles: shield rounds break even; damage rounds cost 1 HP.
    //   Survives at least as many rounds as the damage-only bot.
    //
    // We assert tank_rounds >= dmg_rounds (not exact values, robust to tuning).

    const allocator = std.testing.allocator;

    const tank_team = bots.BotTeam{
        .label = "tank_only",
        .bots = &[_]bots.BotEntry{.{
            .name = "TankBot",
            .stats = .{ .max_hp = 30 },
            .profile = &bots.profile_tank,
        }},
    };

    const damage_team = bots.BotTeam{
        .label = "damage_only",
        .bots = &[_]bots.BotEntry{.{
            .name = "DmgBot",
            .stats = .{ .max_hp = 30 },
            .profile = &bots.profile_all_damage,
        }},
    };

    var h_tank = try BotHarness.init(allocator, &tank_team, &wave_lethal_pack, "BOTK01".*, .{});
    defer h_tank.deinit();
    var h_dmg = try BotHarness.init(allocator, &damage_team, &wave_lethal_pack, "BOTK02".*, .{});
    defer h_dmg.deinit();

    const tank_rounds = try h_tank.run_to_completion(100);
    const dmg_rounds = try h_dmg.run_to_completion(100);

    // Both must finish (not time out).
    try std.testing.expect(tank_rounds < 100);
    try std.testing.expect(dmg_rounds < 100);
    // The tank profile must buy more time than pure damage.
    try std.testing.expect(tank_rounds >= dmg_rounds);
}

test "profile cycles correctly across rounds" {
    // Verify the balanced profile (damage, damage, shield, heal) cycles:
    // round 0 → damage, round 1 → damage, round 2 → shield, round 3 → heal,
    // round 4 → damage again.
    //
    // Injection flow: enqueue_message() places bytes in the slot's msg_queue.
    // The session only drains msg_queue during tick() via drain_queues(), so
    // action_pool is populated only after a tick call.  We inject, tick with
    // dt=0 to flush the queue without firing round resolution, then read.
    const allocator = std.testing.allocator;

    const balanced_team = bots.BotTeam{
        .label = "balanced_cycle",
        .bots = &[_]bots.BotEntry{.{
            .name = "BalBot",
            .stats = .{ .max_hp = 1000 },
            .profile = &bots.profile_balanced,
        }},
    };

    var h = try BotHarness.init(allocator, &balanced_team, &wave_unkillable, "BOTKEY".*, .{});
    defer h.deinit();

    const expected = [_]c.ActionChoice{ .damage, .damage, .shield, .heal, .damage };

    for (expected, 0..) |want, i| {
        _ = i;
        // 1. Enqueue the bot's action message for this round.
        try h.inject_actions();
        // 2. Tick with dt=0: drains msg_queue (populating action_pool) without
        //    expiring the round timer (round_timer > 0 after reset).
        try h.session.tick(0.0);
        // 3. Verify the pool was set correctly before round resolution fires.
        const pid = h.bot_states[0].player_id;
        const got = h.session.action_pool[pid] orelse return error.NoAction;
        try std.testing.expectEqual(@as(u8, 1), got.len);
        try std.testing.expectEqual(want, got.slots[0].action);
        // 4. Fire round resolution by ticking past the timer, then advance h.round.
        try h.session.tick(h.session.round_duration + 0.001);
        h.round += 1;
    }
}
