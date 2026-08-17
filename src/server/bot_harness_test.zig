//! Bot test harness: injects bots into PlayerSlots in place of real clients.
//!
//! Each bot is driven by a `Profile` (a repeating combo sequence from
//! bots.zig). On every cast cycle the harness encodes the bot's next combo as
//! a `submit_spell` protocol message and enqueues it into the session, exactly
//! replicating what a real WebSocket client would send.
//!
//! A "cycle" is one submit + one tick past the cast buffer, which is also long
//! enough to expire the cast lock (so the next cycle is accepted) and to fire
//! exactly one bite per Lil Guy.
//!
//! ## Usage
//!
//!   var h = try BotHarness.init(allocator, &bots.team_mixed, encounter, "BOTKEY".*, .{});
//!   defer h.deinit();
//!   // advance one full cast cycle (inject combos + tick past the buffer):
//!   try h.step();
//!   // check game state via h.session ...

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;
const enc = shared.encounter;
const bots = shared.bots;
const fixtures = shared.fixtures;

const session_mod = @import("session.zig");
const Session = session_mod.Session;

/// Frozen fixture config — designer edits to data/*.json can't break these.
const TEST_CFG = &fixtures.test_config;
const BAL = &fixtures.test_config.balance;
const DEFAULT_ENC = fixtures.test_config.encounters.default();

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
    /// Pins the session's match PRNG so bot runs are reproducible.
    seed: u64 = 0xB07_5EED,
};

pub const BotHarness = struct {
    allocator: std.mem.Allocator,
    session: Session,
    /// One entry per bot in the team; slice is allocator-owned.
    bot_states: []BotState,
    /// Number of cast cycles that have been run (incremented by step()).
    cycle: u32,

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

        var sess = try Session.init_seeded(allocator, join_code, TEST_CFG, opts.seed);

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

        try sess.start_game_encounter(encounter);

        return BotHarness{
            .allocator = allocator,
            .session = sess,
            .bot_states = bot_states,
            .cycle = 0,
        };
    }

    pub fn deinit(self: *BotHarness) void {
        self.session.deinit();
        for (self.bot_states) |*bs| bs.deinit(self.allocator);
        self.allocator.free(self.bot_states);
    }

    /// Seconds that retire a cycle: past the cast buffer (casts fire) AND past
    /// the cast lock (next cycle's submits are accepted).
    fn cycle_dt(self: *const BotHarness) f32 {
        const bal = &self.session.cfg.balance;
        const longest = @max(bal.cast_buffer_ms, bal.cast_lock_ms);
        return @as(f32, @floatFromInt(longest)) / 1000.0 + 0.001;
    }

    /// Enqueue each bot's cast for this cycle as a `submit_spell`.
    /// Call this before ticking past the cast buffer, or use step() which
    /// does both.
    pub fn inject_actions(self: *BotHarness) !void {
        try self.inject_tag(.submit_spell);
    }

    /// Enqueue each bot's combo as a live preview (`choose_combo`), which
    /// lands in `session.action_pool` without committing a cast.
    pub fn inject_previews(self: *BotHarness) !void {
        try self.inject_tag(.choose_combo);
    }

    fn inject_tag(self: *BotHarness, tag: proto.MsgTag) !void {
        for (self.bot_states) |*bs| {
            const combo = bs.profile.combos[self.cycle % bs.profile.combos.len];
            var buf: [16]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            switch (tag) {
                .submit_spell => try proto.encode(
                    fbs.writer(),
                    .submit_spell,
                    proto.SubmitSpell{ .combo = combo },
                ),
                .choose_combo => try proto.encode(
                    fbs.writer(),
                    .choose_combo,
                    proto.ChooseCombo{ .combo = combo },
                ),
                else => unreachable,
            }
            self.session.enqueue_message(bs.player_id, fbs.getWritten());
        }
    }

    /// Advance the session by exactly one cast cycle:
    ///   1. inject_actions() for every bot
    ///   2. tick(0) so the queue drains and every cast is accepted together
    ///   3. tick past the cast buffer: the batch fires (team recipes group),
    ///      then each Lil Guy takes one bite
    ///
    /// Increments self.cycle afterwards.
    pub fn step(self: *BotHarness) !void {
        try self.inject_actions();
        try self.session.tick(0.0);
        try self.session.tick(self.cycle_dt());
        self.cycle += 1;
    }

    /// Convenience: run up to `max_cycles` steps, stopping early when the
    /// session leaves the playing phase (game over).
    /// Returns the number of cycles actually run.
    pub fn run_to_completion(self: *BotHarness, max_cycles: u32) !u32 {
        var r: u32 = 0;
        while (r < max_cycles and self.session.phase == .playing) : (r += 1) {
            try self.step();
        }
        return r;
    }
};

/// Sum a per-color stats array.
fn color_total(values: [c.Element.size]u16) u32 {
    var t: u32 = 0;
    for (values) |v| t += v;
    return t;
}

// ---------------------------------------------------------------------------
// Test encounters
// ---------------------------------------------------------------------------

/// Red-only field, exactly the size of the 6x10 fixture grid, so every unit is
/// on-grid (in agent reach) from the first tick.
const enc_red_field = enc.Encounter{
    .label = "bot_red_field",
    .hunger_max = 1000,
    .slime = .{ .modified = .{ 60, 0, 0, 0 } },
};

/// Un-winnable hunger budget when idle; survivable when neutralized:
/// idle: 20 normal + 40 extra = 60 >= 50.  Neutralized: 20 < 50.
const enc_survival = enc.Encounter{
    .label = "bot_survival",
    .hunger_max = 50,
    .slime = .{ .modified = .{ 20, 0, 0, 0 } },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "twin_flames pair clears the red field" {
    const allocator = std.testing.allocator;
    var h = try BotHarness.init(allocator, &bots.team_red_pair, &enc_red_field, "BOTKEY".*, .{});
    defer h.deinit();

    _ = try h.run_to_completion(200);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, h.session.phase);
    try std.testing.expectEqual(proto.EndReason.field_cleared, h.session.stats.reason);
    try std.testing.expectEqual(@as(u32, 60), h.session.stats.slime_total);
    try std.testing.expectEqual(@as(u32, 0), h.session.stats.slime_left);

    // Every unit was either scored (neutralized before its bite) or escaped as
    // still-modified slime; nothing else can consume a unit.
    const escaped = color_total(h.session.stats.feast.modified_escaped);
    try std.testing.expectEqual(@as(u32, 60), h.session.score + escaped);
    // The pair out-paces the horde by a wide margin: 30 agents per cycle vs
    // two bites, so escapes are the rare exception.
    try std.testing.expect(escaped < 10);
}

test "neutralizing bots survive a hunger budget that idle play fails" {
    const allocator = std.testing.allocator;

    // Idle team: joined but never casts, so all 20 modified units are eaten
    // raw (1 normal + 2 extra each = 60 hunger) against a 50 budget.
    var idle_sess = try Session.init_seeded(allocator, "BOTK01".*, TEST_CFG, 0xB07_5EED);
    defer idle_sess.deinit();
    var idle_bot: BotState = undefined;
    idle_bot.init(allocator, 0xFF, &bots.profile_red_dispenser);
    defer idle_bot.deinit(allocator);
    idle_bot.player_id = idle_sess.join(idle_bot.transport(), "Idle") orelse
        return error.JoinFailed;
    try idle_sess.start_game_encounter(&enc_survival);

    var ticks: u32 = 0;
    while (idle_sess.phase == .playing and ticks < 200) : (ticks += 1) {
        try idle_sess.tick(0.501);
    }
    try std.testing.expectEqual(session_mod.SessionPhase.lobby, idle_sess.phase);
    try std.testing.expectEqual(proto.EndReason.hunger_full, idle_sess.stats.reason);
    try std.testing.expect(idle_sess.hunger.current >= idle_sess.hunger.max);
    // Raw modified slime scores nothing.
    try std.testing.expectEqual(@as(u32, 0), idle_sess.score);
    try std.testing.expect(idle_sess.stats.slime_left > 0);

    // Active pair: twin_flames neutralizes the whole field on the first cast,
    // so every unit is eaten at the normal hunger cost only.
    var h = try BotHarness.init(allocator, &bots.team_red_pair, &enc_survival, "BOTK02".*, .{});
    defer h.deinit();
    _ = try h.run_to_completion(200);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, h.session.phase);
    try std.testing.expectEqual(proto.EndReason.field_cleared, h.session.stats.reason);
    try std.testing.expectEqual(@as(u32, 20), h.session.score);
    try std.testing.expectEqual(@as(u16, 20), h.session.hunger.current);
    try std.testing.expect(h.session.hunger.current < h.session.hunger.max);
    // Nothing escaped, so no healable hunger accrued.
    for (h.session.hunger_healable) |healable|
        try std.testing.expectEqual(@as(u16, 0), healable);
}

test "mixed team finishes the default encounter with a positive score" {
    const allocator = std.testing.allocator;
    var h = try BotHarness.init(allocator, &bots.team_mixed, DEFAULT_ENC, "BOTKEY".*, .{});
    defer h.deinit();

    _ = try h.run_to_completion(400);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, h.session.phase);
    try std.testing.expectEqual(DEFAULT_ENC.total_units(), h.session.stats.slime_total);
    // The reservoir feeds the grid, so the horde always reaches neutral slime.
    try std.testing.expect(h.session.score > 0);
    // Casts landed: the tuning report saw them.
    try std.testing.expect(h.session.stats.casts_total > 0);
}

test "profile cycles correctly across cast cycles" {
    // Verify the rainbow profile cycles through its combos cycle by cycle.
    //
    // Injection flow: enqueue_message() places bytes in the slot's msg_queue.
    // The session only drains msg_queue during tick() via drain_queues(), so
    // action_pool is populated only after a tick call.  Ticking with dt=0
    // flushes the queue without advancing any cast buffer or bite timer, so
    // the previews stay observable.
    const allocator = std.testing.allocator;

    const rainbow_team = bots.BotTeam{
        .label = "rainbow_cycle",
        .bots = &[_]bots.BotEntry{.{
            .name = "RainBot",
            .profile = &bots.profile_rainbow,
        }},
    };

    const big_field = enc.Encounter{
        .label = "bot_big_field",
        .hunger_max = 60000,
        .slime = .{ .neutral = 6 },
    };

    var h = try BotHarness.init(allocator, &rainbow_team, &big_field, "BOTKEY".*, .{});
    defer h.deinit();

    for (0..5) |i| {
        const expected = bots.profile_rainbow.combos[i % bots.profile_rainbow.combos.len];
        try h.inject_previews();
        try h.session.tick(0.0);
        const pid = h.bot_states[0].player_id;
        const got = h.session.action_pool[pid] orelse return error.NoAction;
        try std.testing.expect(shared.game_logic.combos_equal(expected, got));
        h.cycle += 1;
    }
    // No cast ever committed and no bite timer advanced: the field is intact.
    try std.testing.expectEqual(session_mod.SessionPhase.playing, h.session.phase);
    try std.testing.expectEqual(@as(u32, 6), h.session.field.remaining());
}
