//! Bot test harness: injects bots into PlayerSlots in place of real clients.
//!
//! Each bot is driven by a `Profile` (a repeating combo sequence, plus an
//! optional repeating aim sequence, from bots.zig). On every cast cycle the
//! harness encodes the bot's cursor steps as `move_cursor` messages and its
//! next combo as a `submit_spell`, enqueueing both into the session — exactly
//! replicating what a real WebSocket client would send.
//!
//! A "cycle" is one submit per bot, drained in a single tick.  Casts resolve as
//! they are accepted, so a cycle is exactly one round of casting — NOT a turn.
//! A turn only ends once every bot has spent its whole `casts_per_turn` budget,
//! so `casts_per_turn` cycles retire one turn (and one feast).
//!
//! ## Usage
//!
//!   var h = try BotHarness.init(allocator, &bots.team_mixed, encounter, "BOTKEY".*, .{});
//!   defer h.deinit();
//!   // advance one cast cycle (inject combos + drain them):
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

    /// Enqueue each bot's cast for this cycle as a `submit_spell`.
    /// Call this before the tick that drains them, or use step() which does
    /// both.
    pub fn inject_actions(self: *BotHarness) !void {
        try self.inject_tag(.submit_spell);
    }

    /// Enqueue each bot's combo as a live preview (`choose_combo`), which
    /// lands in `session.action_pool` without committing a cast.
    pub fn inject_previews(self: *BotHarness) !void {
        try self.inject_tag(.choose_combo);
    }

    /// Enqueue this cycle's cursor steps for every bot, so their next cast
    /// lands somewhere new.  Aiming is a separate input axis from the combo,
    /// so this is separable from inject_actions.
    pub fn inject_aim(self: *BotHarness) !void {
        for (self.bot_states) |*bs| {
            for (bs.profile.aim_for(self.cycle)) |dir| {
                var buf: [4]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                try proto.encode(fbs.writer(), .move_cursor, proto.MoveCursor{ .dir = dir });
                self.session.enqueue_message(bs.player_id, fbs.getWritten());
            }
        }
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
    ///   1. inject_aim() then inject_actions() for every bot — aim first, so
    ///      the cast is anchored at this cycle's new cursor
    ///   2. tick() so the queue drains and every cast resolves
    ///
    /// If that drain exhausts every bot's budget, the session ends the turn
    /// inside the same tick: the field is devoured and refilled.
    ///
    /// Increments self.cycle afterwards.
    pub fn step(self: *BotHarness) !void {
        try self.inject_aim();
        try self.inject_actions();
        try self.session.tick(0.0);
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

/// Sum a per-tier stats array.
fn tier_total(values: [c.Tier.size]u16) u32 {
    var t: u32 = 0;
    for (values) |v| t += v;
    return t;
}

// ---------------------------------------------------------------------------
// Test encounters
// ---------------------------------------------------------------------------

/// Green-only field, exactly the size of the 6x10 fixture grid, so every unit
/// is on-grid (in cursor reach) from the first tick and NOTHING is edible: the
/// whole board is one live wall until a cast opens it.  Green is one downgrade
/// from defused, so a single stamp per cell suffices.  Charges are generous
/// because this encounter is about whether bots make progress at all, not about
/// rationing.
const enc_green_field = enc.Encounter{
    .label = "bot_green_field",
    .hunger_max = 1000,
    .charges = 500,
    .slime = .{ .tiered = .{ 0, 0, 60 } },
};

/// The same solid green wall, used to contrast a team that casts with one that
/// does not.  The hunger budget is roomy on purpose: this encounter is about
/// what the two teams can REACH, not about who fills the bar first.
const enc_survival = enc.Encounter{
    .label = "bot_survival",
    .hunger_max = 1000,
    .charges = 500,
    .slime = .{ .tiered = .{ 0, 0, 60 } },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sweeping bots eat their way into a field that starts completely walled" {
    const allocator = std.testing.allocator;
    var h = try BotHarness.init(allocator, &bots.team_mixed, &enc_green_field, "BOTKEY".*, .{});
    defer h.deinit();

    _ = try h.run_to_completion(400);

    // `stats.slime_total` is only finalised by end_game, and a walled field may
    // well outlast the run, so the live counter is what this asserts against.
    try std.testing.expectEqual(@as(u32, 60), h.session.slime_total);
    // A unit is EITHER eaten (and therefore scored, 1 point each) or still
    // sitting somewhere.  Nothing else can consume one, so this holds at any
    // point in the run — including a run that never finished.
    try std.testing.expectEqual(
        @as(u32, 60),
        h.session.score + h.session.field.remaining(),
    );
    // The board opened: stamps defused cells and the flood got in behind them.
    try std.testing.expect(tier_total(h.session.stats.feast.cells_covered) > 0);
    try std.testing.expect(h.session.score > 0);
    // Charges are spent, never conjured.
    try std.testing.expect(h.session.charges <= enc_green_field.charges);
    try std.testing.expectEqual(
        enc_green_field.charges - h.session.charges,
        @as(u32, h.session.stats.feast.charges_spent),
    );
}

test "a live wall feeds nobody: only casting turns slime into score" {
    // The central change from the old design: a hazard is no longer eaten at a
    // premium, it is not eaten AT ALL.  A team that never casts therefore makes
    // literally zero progress, however many turns pass.  Same field, same seed,
    // one team stamping and one not.
    const allocator = std.testing.allocator;

    // Idle side: a joined player who never casts would stall the turn forever,
    // so its budget is retired directly.  Nothing is ever defused.
    var idle_sess = try Session.init_seeded(allocator, "BOTK01".*, TEST_CFG, 0xB07_5EED);
    defer idle_sess.deinit();
    var idle_bot: BotState = undefined;
    idle_bot.init(allocator, 0xFF, &bots.profile_sweeper);
    defer idle_bot.deinit(allocator);
    idle_bot.player_id = idle_sess.join(idle_bot.transport(), "Idle") orelse
        return error.JoinFailed;
    try idle_sess.start_game_encounter(&enc_survival);

    var turns: u32 = 0;
    while (idle_sess.phase == .playing and turns < 200) : (turns += 1) {
        idle_sess.casts_left = [_]u8{0} ** session_mod.MAX_PLAYERS;
        try idle_sess.tick(0.0);
    }
    // 200 turns of nothing.  The wall never opens, so the encounter cannot end:
    // no hunger to fill the bar, no slime eaten to clear the field, and a full
    // charge pool so it is not a dead position either.  A stalemate is the
    // honest outcome of refusing to play.
    try std.testing.expectEqual(session_mod.SessionPhase.playing, idle_sess.phase);
    try std.testing.expectEqual(@as(u32, 0), idle_sess.score);
    try std.testing.expectEqual(@as(u16, 0), idle_sess.hunger.current);
    try std.testing.expectEqual(enc_survival.charges, idle_sess.charges);
    try std.testing.expectEqual(@as(u32, 60), idle_sess.field.remaining());

    // Active side: the same field, but cast at.
    var h = try BotHarness.init(allocator, &bots.team_mixed, &enc_survival, "BOTK02".*, .{});
    defer h.deinit();
    _ = try h.run_to_completion(200);

    try std.testing.expect(h.session.score > 0);
    try std.testing.expect(h.session.hunger.current > 0);
    try std.testing.expect(h.session.charges < enc_survival.charges);
    try std.testing.expect(tier_total(h.session.stats.feast.cells_covered) > 0);
    // Hunger is now exactly one point per unit eaten — no hazard surcharge, and
    // score counts the same units, so the two readings must agree.
    try std.testing.expectEqual(
        @as(u32, h.session.hunger.current) * BAL.hunger_cost_normal,
        h.session.score,
    );
}

test "mixed team makes real progress on the default encounter" {
    const allocator = std.testing.allocator;
    var h = try BotHarness.init(allocator, &bots.team_mixed, DEFAULT_ENC, "BOTKEY".*, .{});
    defer h.deinit();

    _ = try h.run_to_completion(400);

    try std.testing.expectEqual(DEFAULT_ENC.total_units(), h.session.slime_total);
    // The encounter's 30 neutral units are edible from the start, so the flood
    // always finds something even before a single cast lands.
    try std.testing.expect(h.session.score > 0);
    // Casts landed: the tuning report saw them.
    try std.testing.expect(h.session.stats.casts_total > 0);
    // Conservation holds mid-run as well as at the end.
    try std.testing.expectEqual(
        DEFAULT_ENC.total_units(),
        h.session.score + h.session.field.remaining(),
    );
}

test "profile cycles correctly across cast cycles" {
    // Verify a multi-combo profile cycles through its combos cycle by cycle.
    //
    // Injection flow: enqueue_message() places bytes in the slot's msg_queue.
    // The session only drains msg_queue during tick() via drain_queues(), so
    // action_pool is populated only after a tick call.  `choose_combo` is a
    // preview, not a cast, so no budget is spent and no turn can end — the
    // previews stay observable.
    const allocator = std.testing.allocator;

    const snake_team = bots.BotTeam{
        .label = "snake_cycle",
        .bots = &[_]bots.BotEntry{.{
            .name = "SnakeBot",
            .profile = &bots.profile_snake,
        }},
    };

    const big_field = enc.Encounter{
        .label = "bot_big_field",
        .hunger_max = 60000,
        .slime = .{ .neutral = 6 },
    };

    var h = try BotHarness.init(allocator, &snake_team, &big_field, "BOTKEY".*, .{});
    defer h.deinit();

    for (0..5) |i| {
        const expected = bots.profile_snake.combos[i % bots.profile_snake.combos.len];
        try h.inject_previews();
        try h.session.tick(0.0);
        const pid = h.bot_states[0].player_id;
        const got = h.session.action_pool[pid] orelse return error.NoAction;
        try std.testing.expect(shared.game_logic.combos_equal(expected, got));
        h.cycle += 1;
    }
    // Previews only: no cast was ever committed, so no turn ended and the
    // field is untouched.
    try std.testing.expectEqual(session_mod.SessionPhase.playing, h.session.phase);
    try std.testing.expectEqual(@as(u32, 6), h.session.field.remaining());
}

test "aim injection walks the cursor and anchors casts where the bot aimed" {
    // profile_sweeper steps right three times per cycle; the cursor starts at
    // the grid centre and clamps at the right edge.
    const allocator = std.testing.allocator;

    const solo = bots.BotTeam{
        .label = "solo_sweeper",
        .bots = &[_]bots.BotEntry{.{ .name = "Sweep", .profile = &bots.profile_sweeper }},
    };
    const big_field = enc.Encounter{
        .label = "bot_aim_field",
        .hunger_max = 60000,
        .slime = .{ .neutral = 60 },
    };

    var h = try BotHarness.init(allocator, &solo, &big_field, "BOTKEY".*, .{});
    defer h.deinit();
    const pid = h.bot_states[0].player_id;
    const grid = &h.session.field.grid;

    const start = h.session.cursors[pid];
    try std.testing.expectEqual(@as(u8, 5), grid.col_of(start));

    try h.inject_aim();
    try h.session.tick(0.0);
    const moved = h.session.cursors[pid];
    // Three LEFT steps, same row: the sweeper heads for the feeding edge.
    try std.testing.expectEqual(grid.row_of(start), grid.row_of(moved));
    try std.testing.expectEqual(@as(u8, 2), grid.col_of(moved));

    // Aiming past the edge parks against it rather than wrapping.
    for (0..3) |_| {
        try h.inject_aim();
        try h.session.tick(0.0);
    }
    const parked = h.session.cursors[pid];
    try std.testing.expectEqual(@as(u8, 0), grid.col_of(parked));
    try std.testing.expectEqual(grid.row_of(start), grid.row_of(parked));
}

test "a submitted cast is anchored where the bot aimed, not where it ends up" {
    // The cast_anchors snapshot exists so a spell resolves at the cursor as it
    // was WHEN SUBMITTED, even if later messages in the same drain move it.
    const allocator = std.testing.allocator;

    const solo = bots.BotTeam{
        .label = "solo_poker",
        .bots = &[_]bots.BotEntry{.{ .name = "Poke", .profile = &bots.profile_poker }},
    };
    const big_field = enc.Encounter{
        .label = "bot_anchor_field",
        .hunger_max = 60000,
        .slime = .{ .tiered = .{ 0, 0, 60 } },
    };

    var h = try BotHarness.init(allocator, &solo, &big_field, "BOTKEY".*, .{});
    defer h.deinit();
    const pid = h.bot_states[0].player_id;

    const aimed = h.session.cursors[pid];

    // Submit, then walk away — all in ONE drain, so the moves are processed
    // after the cast has already been anchored.
    try h.inject_actions();
    for (0..3) |_| {
        var buf: [4]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .move_cursor, proto.MoveCursor{ .dir = .up });
        h.session.enqueue_message(pid, fbs.getWritten());
    }
    try h.session.tick(0.0);

    try std.testing.expectEqual(aimed, h.session.cast_anchors[pid]);
    try std.testing.expect(h.session.cursors[pid] != aimed);

    // `poke` is 1x1 and the field is all-green, so the stamp downgraded
    // exactly one green cell — at the anchor, not the moved-to cursor.
    try std.testing.expect(h.session.field.grid.get(aimed) == .neutralized);
    const covered = h.session.stats.feast.cells_covered;
    try std.testing.expectEqual(@as(u16, 1), covered[@intFromEnum(c.Tier.green)]);
    try std.testing.expectEqual(@as(u16, 1), h.session.stats.players[pid].cells_covered);
}
