//! Bot test harness: injects bots into PlayerSlots in place of real clients.
//!
//! Each bot is driven by a `Profile` (a repeating combo sequence from
//! bots.zig). On every round the harness encodes the bot's next combo as a
//! `choose_combo` protocol message and enqueues it into the session, exactly
//! replicating what a real WebSocket client would send.
//!
//! ## Usage
//!
//!   var h = try BotHarness.init(allocator, &bots.team_mixed, encounter, "BOTKEY".*, .{});
//!   defer h.deinit();
//!   // advance one full round (inject combos + tick past timer):
//!   try h.step();
//!   // check game state via h.session ...

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;
const enc = shared.encounter;
const bots = shared.bots;
const balance = shared.balance;

const session_mod = @import("session.zig");
const Session = session_mod.Session;

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
    /// Set to a small value (e.g. 0.001) for fast headless CI runs.
    round_duration: f32 = 0.001,
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
    /// - Starts the game against `encounter` directly, bypassing the lobby
    ///   ready flow.
    ///
    /// Asserts:
    ///   - team.bots.len >= 1
    ///   - team.bots.len <= MAX_PLAYERS
    ///   - every profile has at least one combo
    pub fn init(
        allocator: std.mem.Allocator,
        team: *const bots.BotTeam,
        encounter: *const enc.Encounter,
        join_code: [6]u8,
        opts: BotHarnessOptions,
    ) !BotHarness {
        std.debug.assert(team.bots.len >= 1);
        std.debug.assert(team.bots.len <= session_mod.MAX_PLAYERS);
        for (team.bots) |b| std.debug.assert(b.profile.combos.len >= 1);

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

        try sess.start_game_encounter(encounter);

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

    /// Encode each bot's combo for this round and enqueue it.
    /// Call this before ticking past the round timer, or use step() which
    /// does both.
    pub fn inject_actions(self: *BotHarness) !void {
        for (self.bot_states) |*bs| {
            const combo = bs.profile.combos[self.round % bs.profile.combos.len];
            var buf: [16]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try proto.encode(fbs.writer(), .choose_combo, proto.ChooseCombo{ .combo = combo });
            self.session.enqueue_message(bs.player_id, fbs.getWritten());
        }
    }

    /// Advance the session by exactly one full round:
    ///   1. inject_actions() for every bot
    ///   2. tick past the round timer (round resolves, then reset_round)
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
// Test encounters
// ---------------------------------------------------------------------------

/// Fire-only field: exactly matched by two twin_flames rounds (30 agents/round).
const enc_fire_field = enc.Encounter{
    .label = "bot_fire_field",
    .hunger_max = 1000,
    .zones = &[_]c.ZoneDef{
        .{ .modified = .{ 30, 0, 0, 0 } },
        .{ .modified = .{ 30, 0, 0, 0 } },
    },
};

/// Un-winnable hunger budget when idle; survivable when neutralized:
/// idle: 20 normal + 40 extra = 60 ≥ 50.  Neutralized: 20 < 50.
const enc_survival = enc.Encounter{
    .label = "bot_survival",
    .hunger_max = 50,
    .zones = &[_]c.ZoneDef{
        .{ .modified = .{ 20, 0, 0, 0 } },
    },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "twin_flames pair fully neutralizes the fire field" {
    const allocator = std.testing.allocator;
    var h = try BotHarness.init(allocator, &bots.team_fire_pair, &enc_fire_field, "BOTKEY".*, .{});
    defer h.deinit();

    const rounds = try h.run_to_completion(10);

    // One zone per round; ends when both zones are consumed.
    try std.testing.expectEqual(@as(u32, 2), rounds);
    try std.testing.expectEqual(session_mod.SessionPhase.lobby, h.session.phase);
    // Every modified unit neutralized → full score, zero healable hunger.
    try std.testing.expectEqual(@as(u32, 60), h.session.score);
    for (h.session.hunger_healable) |healable|
        try std.testing.expectEqual(@as(u16, 0), healable);
    try std.testing.expectEqual(
        @as(u16, @intCast(60 * balance.HUNGER_COST_NORMAL)),
        h.session.hunger.current,
    );
}

test "neutralizing bots survive a hunger budget that idle play fails" {
    const allocator = std.testing.allocator;

    // Idle team: submits nothing (empty session, no combos injected).
    var idle_sess = try Session.init(allocator, "BOTK01".*);
    defer idle_sess.deinit();
    var idle_bot = BotState{ .player_id = 0xFF, .profile = &bots.profile_fire_dispenser, .buf = .empty, .bt = undefined };
    idle_bot.init(allocator, 0xFF, &bots.profile_fire_dispenser);
    defer idle_bot.deinit(allocator);
    _ = idle_sess.join(idle_bot.transport(), "Idle") orelse return error.JoinFailed;
    idle_sess.round_duration = 0.001;
    idle_sess.round_timer = 0.001;
    try idle_sess.start_game_encounter(&enc_survival);
    try idle_sess.tick(0.01); // round resolves with no combos
    try std.testing.expectEqual(session_mod.SessionPhase.lobby, idle_sess.phase);
    try std.testing.expect(idle_sess.hunger.current >= idle_sess.hunger.max);
    try std.testing.expectEqual(@as(u32, 0), idle_sess.score);

    // Active pair: twin_flames neutralizes everything → survives with full score.
    var h = try BotHarness.init(allocator, &bots.team_fire_pair, &enc_survival, "BOTK02".*, .{});
    defer h.deinit();
    const rounds = try h.run_to_completion(10);
    try std.testing.expectEqual(@as(u32, 1), rounds);
    try std.testing.expectEqual(@as(u32, 20), h.session.score);
    try std.testing.expect(h.session.hunger.current < h.session.hunger.max);
}

test "mixed team completes the default encounter with a positive score" {
    const allocator = std.testing.allocator;
    var h = try BotHarness.init(allocator, &bots.team_mixed, enc.DEFAULT_ENCOUNTER, "BOTKEY".*, .{});
    defer h.deinit();

    const rounds = try h.run_to_completion(@intCast(enc.DEFAULT_ENCOUNTER.zones.len + 2));

    try std.testing.expect(rounds <= enc.DEFAULT_ENCOUNTER.zones.len);
    try std.testing.expectEqual(session_mod.SessionPhase.lobby, h.session.phase);
    // Naturally-neutral slime alone guarantees score > 0 on any consumed zone.
    try std.testing.expect(h.session.score > 0);
}

test "profile cycles correctly across rounds" {
    // Verify the rainbow profile cycles through its combos round by round.
    //
    // Injection flow: enqueue_message() places bytes in the slot's msg_queue.
    // The session only drains msg_queue during tick() via drain_queues(), so
    // action_pool is populated only after a tick call.  We inject, tick with
    // dt=0 to flush the queue without firing round resolution, then read.
    const allocator = std.testing.allocator;

    const rainbow_team = bots.BotTeam{
        .label = "rainbow_cycle",
        .bots = &[_]bots.BotEntry{.{
            .name = "RainBot",
            .profile = &bots.profile_rainbow,
        }},
    };

    // Big field so the game outlasts the checks.
    const big_field = enc.Encounter{
        .label = "bot_big_field",
        .hunger_max = 60000,
        .zones = &[_]c.ZoneDef{
            .{ .neutral = 1 }, .{ .neutral = 1 }, .{ .neutral = 1 },
            .{ .neutral = 1 }, .{ .neutral = 1 }, .{ .neutral = 1 },
        },
    };

    var h = try BotHarness.init(allocator, &rainbow_team, &big_field, "BOTKEY".*, .{ .round_duration = 1.0 });
    defer h.deinit();

    for (0..5) |i| {
        const expected = bots.profile_rainbow.combos[i % bots.profile_rainbow.combos.len];
        // 1. Enqueue the bot's combo message for this round.
        try h.inject_actions();
        // 2. Tick with dt=0: drains msg_queue (populating action_pool) without
        //    expiring the round timer (round_timer > 0 after reset).
        try h.session.tick(0.0);
        // 3. Verify the pool was set correctly before round resolution fires.
        const pid = h.bot_states[0].player_id;
        const got = h.session.action_pool[pid] orelse return error.NoAction;
        try std.testing.expect(shared.game_logic.combos_equal(expected, got));
        // 4. Fire round resolution by ticking past the timer, then advance h.round.
        try h.session.tick(h.session.round_duration + 0.001);
        h.round += 1;
    }
}
