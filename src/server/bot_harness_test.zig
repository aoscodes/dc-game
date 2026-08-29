//! Bot test harness: injects bots into PlayerSlots in place of real clients.
//!
//! Each bot is driven by a `Profile` (a repeating sequence of move labels, plus
//! an optional repeating aim sequence, from bots.zig). On every cast cycle the
//! harness encodes the bot's cursor steps as `move_cursor` messages, the turns
//! of its shape wheel as `cycle_shape` messages, and the trigger as a `cast`,
//! enqueueing them into the session — exactly replicating what a real WebSocket
//! client would send.
//!
//! Selection is server-side state, so the harness cannot simply assign it: it
//! must steer the wheel the way a player does.  `inject_select` computes the
//! shortest run of forward or backward steps from the session's CURRENT
//! selection to the one the profile wants, which is both fewer messages and a
//! genuine exercise of the cycling code.
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
//!   // advance one cast cycle (aim, turn the wheel, cast, drain):
//!   try h.step();
//!   // check game state via h.session ...

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;
const enc = shared.encounter;
const bots = shared.bots;
const fixtures = shared.fixtures;
const logic = shared.game_logic;

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
    /// - Connects each bot from `team` and seats it in a PlayerSlot.
    /// - Starts the game against `encounter` directly.
    ///
    /// Asserts:
    ///   - team.bots.len >= 1
    ///   - team.bots.len <= MAX_PLAYERS
    ///   - every profile names at least one move
    ///   - every move a profile names exists in the fixture config
    pub fn init(
        allocator: std.mem.Allocator,
        team: *const bots.BotTeam,
        encounter: *const enc.Encounter,
        join_code: [6]u8,
        opts: BotHarnessOptions,
    ) !BotHarness {
        std.debug.assert(team.bots.len >= 1);
        std.debug.assert(team.bots.len <= session_mod.MAX_PLAYERS);
        for (team.bots) |b| {
            std.debug.assert(b.profile.moves.len >= 1);
            // A typo'd label would otherwise surface as a bot silently casting
            // move 0 forever, which reads as a balance result rather than a bug.
            for (b.profile.moves) |label| std.debug.assert(move_index(label) != null);
        }

        const bot_states = try allocator.alloc(BotState, team.bots.len);
        errdefer allocator.free(bot_states);

        var sess = try Session.init_seeded(allocator, join_code, TEST_CFG, opts.seed);

        for (team.bots, 0..) |entry, i| {
            bot_states[i].init(allocator, 0xFF, entry.profile);
            const pid = seat_bot(&sess, bot_states[i].transport()) orelse {
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

    /// Enqueue each bot's trigger for this cycle as a `cast`.
    /// Call this after inject_select (or use step(), which orders them), or the
    /// bot fires whatever its wheel happened to be left on.
    pub fn inject_actions(self: *BotHarness) !void {
        for (self.bot_states) |*bs| {
            var buf: [4]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try proto.encode(fbs.writer(), .cast, {});
            self.session.enqueue_message(bs.player_id, fbs.getWritten());
        }
    }

    /// Turn every bot's shape wheel to the move its profile wants this cycle.
    ///
    /// Steps whichever way is shorter; a bot already on its move sends nothing.
    /// This is a preview in its own right: selection is broadcast, so a client
    /// watching sees the choice without a cast being committed.
    pub fn inject_select(self: *BotHarness) !void {
        const moves = BAL.player_recipes.len;
        for (self.bot_states) |*bs| {
            const want = move_index(bs.profile.move_for(self.cycle)) orelse continue;
            const have = self.session.selected[bs.player_id];
            if (want == have) continue;
            // Distance each way round the ring; ties go forward.
            const fwd = (@as(usize, want) +% moves -% have) % moves;
            const back = moves - fwd;
            const dir: c.CycleDir = if (fwd <= back) .forward else .backward;
            const steps = @min(fwd, back);
            for (0..steps) |_| {
                var buf: [4]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                try proto.encode(fbs.writer(), .cycle_shape, proto.CycleShape{ .dir = dir });
                self.session.enqueue_message(bs.player_id, fbs.getWritten());
            }
        }
    }

    /// Enqueue this cycle's cursor steps for every bot, so their next cast
    /// lands somewhere new.  Aiming is a separate input axis from the wheel, so
    /// this is separable from inject_select and inject_actions.
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

    /// Advance the session by exactly one cast cycle:
    ///   1. inject_aim(), inject_select(), then inject_actions() for every bot
    ///      — aim and wheel first, so the cast fires this cycle's move at this
    ///      cycle's cursor
    ///   2. tick() so the queue drains and every cast resolves
    ///
    /// If that drain exhausts every bot's budget, the session ends the turn
    /// inside the same tick: the field is devoured and refilled.
    ///
    /// Increments self.cycle afterwards.
    pub fn step(self: *BotHarness) !void {
        try self.inject_aim();
        try self.inject_select();
        try self.inject_actions();
        try self.session.tick(0.0);
        self.cycle += 1;
    }

    /// Convenience: run up to `max_cycles` steps, stopping early once an
    /// encounter has ended (a restart is pending).
    /// Returns the number of cycles actually run.
    pub fn run_to_completion(self: *BotHarness, max_cycles: u32) !u32 {
        var r: u32 = 0;
        while (r < max_cycles and !self.session.restart_pending) : (r += 1) {
            try self.step();
        }
        return r;
    }
};

/// Connect `transport` and seat it, bot-style: connection ids and seat ids
/// both count up from 0.  Returns the seat id, or null when the game is full.
fn seat_bot(sess: *Session, transport: shared.Transport) ?u8 {
    const conn_id = sess.connect(transport) orelse return null;
    const no_babies = [_]u32{0} ** shared.components.BabyType.size;
    sess.take_slot(conn_id, 0, no_babies) catch return null;
    return sess.connections[conn_id].player_id;
}

/// Fixture-table index of a move label, or null if the fixture has no such
/// move.  Bots name moves by label (see bots.zig), and this is the one place
/// that mapping happens.
fn move_index(label: []const u8) ?u8 {
    for (BAL.player_recipes, 0..) |r, i| {
        if (std.mem.eql(u8, r.label, label)) return @intCast(i);
    }
    return null;
}

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
    .charges = 500,
    .slime = .{ .tiered = .{ 0, 0, 60 } },
};

/// The same solid green wall, used to contrast a team that casts with one that
/// does not.  The hunger budget is roomy on purpose: this encounter is about
/// what the two teams can REACH, not about who fills the bar first.
const enc_survival = enc.Encounter{
    .label = "bot_survival",
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

    // The seeded pool, grown once per seat past the first (three bots here).
    const pool_start = h.session.charges;
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
    // The board opened: stamps defused cells for the bite to consume.
    try std.testing.expect(tier_total(h.session.stats.feast.cells_covered) > 0);
    try std.testing.expect(h.session.score > 0);
    // Charges are spent, never conjured.
    try std.testing.expect(h.session.charges <= pool_start);
    try std.testing.expectEqual(
        pool_start - h.session.charges,
        @as(u32, h.session.stats.feast.charges_spent),
    );
}

test "an idle team is still fed: the bite nibbles the wall down turn by turn" {
    // The central change of the conveyor design: a live hazard is no longer
    // a wall the feast cannot touch — the bite NIBBLES it one tier per turn.
    // A team that never casts therefore still makes progress, it just pays
    // hunger-clock for nibbles that score nothing: every green costs a
    // nibble AND a consuming bite (2 hunger for 1 point), so the idle game
    // ends by the clock with slime left on the board.
    const allocator = std.testing.allocator;

    // Idle side: a joined player who never casts would stall the turn forever,
    // so its budget is retired directly.  Nothing is ever defused by a cast.
    var idle_sess = try Session.init_seeded(allocator, "BOTK01".*, TEST_CFG, 0xB07_5EED);
    defer idle_sess.deinit();
    var idle_bot: BotState = undefined;
    idle_bot.init(allocator, 0xFF, &bots.profile_sweeper);
    defer idle_bot.deinit(allocator);
    idle_bot.player_id = seat_bot(&idle_sess, idle_bot.transport()) orelse
        return error.JoinFailed;
    try idle_sess.start_game_encounter(&enc_survival);

    var turns: u32 = 0;
    while (!idle_sess.restart_pending and turns < 200) : (turns += 1) {
        idle_sess.casts_left = [_]u8{0} ** session_mod.MAX_PLAYERS;
        try idle_sess.tick(0.0);
    }
    // 60 greens at 2 hunger each against a solo bar of 100: the clock fills
    // before the field clears.  The game ENDED — idle play cannot stall the
    // conveyor — but it ended by time, having scored less than it swallowed.
    try std.testing.expect(idle_sess.restart_pending);
    try std.testing.expect(idle_sess.score > 0);
    try std.testing.expect(logic.hunger_full(idle_sess.hunger));
    try std.testing.expect(idle_sess.field.remaining() > 0);
    // Every nibble filled the bar without scoring, so hunger strictly
    // outran the score.
    try std.testing.expect(@as(u32, idle_sess.hunger.current) > idle_sess.score);
    // Not one charge was spent doing it.
    try std.testing.expectEqual(enc_survival.charges, idle_sess.charges);

    // Active side: the same field, but cast at — the casts pre-chew the
    // front, converting would-be nibbles into points.
    var h = try BotHarness.init(allocator, &bots.team_mixed, &enc_survival, "BOTK02".*, .{});
    defer h.deinit();
    const pool_start = h.session.charges;
    _ = try h.run_to_completion(200);

    try std.testing.expect(h.session.score > 0);
    try std.testing.expect(h.session.hunger.current > 0);
    try std.testing.expect(h.session.charges < pool_start);
    try std.testing.expect(tier_total(h.session.stats.feast.cells_covered) > 0);
    // A consumed unit is 1 hunger for 1 score; a nibble is 1 hunger for
    // nothing — so score can never outrun the bar.
    try std.testing.expect(
        h.session.score <= @as(u32, h.session.hunger.current) * BAL.hunger_cost_normal,
    );
}

test "mixed team makes real progress on the default encounter" {
    const allocator = std.testing.allocator;
    var h = try BotHarness.init(allocator, &bots.team_mixed, DEFAULT_ENC, "BOTKEY".*, .{});
    defer h.deinit();

    _ = try h.run_to_completion(400);

    try std.testing.expectEqual(DEFAULT_ENC.total_units(), h.session.slime_total);
    // The encounter's 30 neutral units are edible from the start, so the bite
    // always finds something even before a single cast lands.
    try std.testing.expect(h.session.score > 0);
    // Casts landed: the tuning report saw them.
    try std.testing.expect(h.session.stats.casts_total > 0);
    // Conservation holds mid-run as well as at the end.  Neutralizers are
    // swallowed WITHOUT scoring (they are equipment, not food), so the ledger
    // closes over score + what is left + the agents consumed.
    try std.testing.expectEqual(
        DEFAULT_ENC.total_units(),
        h.session.score + h.session.field.remaining() +
            h.session.stats.feast.agents_consumed,
    );
}

test "profile cycles correctly across cast cycles" {
    // Verify a multi-move profile walks its wheel to a different move each
    // cycle, and that the harness's shortest-path steering actually lands on
    // the move the profile named.
    //
    // Injection flow: enqueue_message() places bytes in the slot's msg_queue.
    // The session only drains msg_queue during tick() via drain_queues(), so
    // `selected` only changes after a tick call.  Selecting is not casting, so
    // no budget is spent and no turn can end — the choices stay observable.
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
        .slime = .{ .neutral = 6 },
    };

    var h = try BotHarness.init(allocator, &snake_team, &big_field, "BOTKEY".*, .{});
    defer h.deinit();

    const pid = h.bot_states[0].player_id;
    for (0..5) |i| {
        const want = bots.profile_snake.move_for(i);
        try h.inject_select();
        try h.session.tick(0.0);
        const got = BAL.player_recipes[h.session.selected[pid]].label;
        try std.testing.expectEqualStrings(want, got);
        h.cycle += 1;
    }
    // Selection only: no cast was ever committed, so no turn ended and the
    // field is untouched.
    try std.testing.expect(!h.session.restart_pending);
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

test "a cast lands where the bot aimed, not where it ends up" {
    // A cast captures the cursor when it is ACCEPTED, so a spell resolves where
    // the player was pointing even if later messages in the same drain move
    // them.
    const allocator = std.testing.allocator;

    const solo = bots.BotTeam{
        .label = "solo_poker",
        .bots = &[_]bots.BotEntry{.{ .name = "Poke", .profile = &bots.profile_poker }},
    };
    const big_field = enc.Encounter{
        .label = "bot_anchor_field",
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

    try std.testing.expect(h.session.cursors[pid] != aimed);

    // Land the lock-in without ending the turn: the feast would eat the very
    // cell this test is about.
    try h.session.resolve_pending();

    // `poke` is 1x1 and the field is all-green, so the stamp downgraded
    // exactly one green cell — at the anchor, not the moved-to cursor.
    try std.testing.expect(h.session.field.grid.get(aimed) == .neutralized);
    const covered = h.session.stats.feast.cells_covered;
    try std.testing.expectEqual(@as(u16, 1), covered[@intFromEnum(c.Tier.green)]);
    try std.testing.expectEqual(@as(u16, 1), h.session.stats.players[pid].cells_covered);
}
