//! Integration tests for the Slime Feast game session.
//!
//! Tests drive Session directly — no network, no threads.  Transport is a
//! BufferTransport that accumulates outgoing bytes.
//!
//! Every session here is created with `Session.init_seeded` and a PINNED seed,
//! so cell placement is reproducible.  Where a test needs a specific grid
//! layout it writes the cells directly (`sess.field.grid.put`) after start,
//! which is the only way to assert exact per-cell outcomes without depending on
//! the PRNG stream.
//!
//! Mechanics under test:
//!   - shape selection: a server-owned wheel per player, cycled forward and
//!     backward, wrapping, persisting across bites
//!   - aiming: server-authoritative per-player cursor, clamped at the edges;
//!     a cast lands where the player aimed when the cast was ACCEPTED
//!   - realtime casting: a cast RESOLVES THE MOMENT it is pressed — priced,
//!     debited and stamped in the same drain; a press inside the per-player
//!     cast cooldown (`cast_cooldown_ms`) is silently dropped and does NOT
//!     restart the cooldown; a cast the pool cannot pay is REFUSED
//!     (over_budget to the caster alone) and starts no cooldown either
//!   - GROUPS forming in the rolling recent-cast WINDOW (`team_window_ms`):
//!     a cast that completes a team recipe's bag on its square — DISTINCT
//!     players, same square, everything within the window — fires the
//!     group's shape too, and pays the GROUP's cost INSTEAD of its own; the
//!     contributors already paid their own way as they landed
//!   - shape stamping: a matched recipe's footprint downgrades every covered
//!     hazard cell by exactly one tier (red→yellow→green→defused); cells off
//!     the grid edge are clipped, non-hazard cells are inert
//!   - the BITE CLOCK: every `bite_interval_ms` (sped up by seats past the
//!     first and by babies at the table) the Lil Guys chew the front
//!     `feast_width` columns cell by cell — edible units consumed, live
//!     hazards nibbled one tier, rocks skipped — then the leftward shift and
//!     the refill from the right edge, in that order; the timer disarms with
//!     nobody seated and while the session holds (pre-match, end screen)
//!   - the shared charge pool: one per game (canisters aside), per-move cost,
//!     a broke team's priced casts refused while the bite keeps the game
//!     moving, and the free move as the floor the economy cannot fall through
//!   - hunger accounting: a flat cost per BITE — consumed and nibbled alike
//!   - score = units CONSUMED (all of which are neutral, defused, or
//!     food-shaped specials); nibbles never score
//!   - end conditions: field cleared / the hunger clock filling, checked when
//!     a bite settles — plus the closing broadcast order, which clients
//!     replay their outro from
//!   - wire contents: grid, reservoir, bite, cursors, selections, cooldowns,
//!     charges, the bite countdown, and the recent-cast window

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;
const logic = shared.game_logic;
const enc = shared.encounter;
const fixtures = shared.fixtures;

const session_mod = @import("session.zig");
const Session = session_mod.Session;

/// Frozen fixture config — designer edits to data/*.json can't break these.
const TEST_CFG = &fixtures.test_config;
const BAL = &fixtures.test_config.balance;
const DEFAULT_ENC = fixtures.test_config.encounters.default();

/// Pinned seed for every test session: the match PRNG is deterministic, so
/// grid placement and target selection replay identically run to run.
const SEED: u64 = 0x5EED_FEA57;

/// A boardless player's baby tally: all zero.
const NO_BABIES = [_]u32{0} ** c.BabyType.size;

const RED: usize = @intFromEnum(c.Tier.red);
const YELLOW: usize = @intFromEnum(c.Tier.yellow);
const GREEN: usize = @intFromEnum(c.Tier.green);

/// Fixture move indices, by label — re-exported so a test reads as an intent
/// ("select the 3x3 block") rather than a table offset.  A move's index is its
/// wire identity, so these are what `cast_as` and `select` speak in.
const POKE = fixtures.POKE; // "#", 1 charge
const SWEEP = fixtures.SWEEP; // "###"
const BLOCK = fixtures.BLOCK; // 3x3
const CROSS = fixtures.CROSS;
const WEDGE = fixtures.WEDGE;
const TRICKLE = fixtures.TRICKLE; // "#", costs 0 charges — the free move
const DELUGE = fixtures.DELUGE; // 3x3, costs 9 charges — the expensive move

/// Fixture group indices, by label.
const TWIN_BLOOM = fixtures.TWIN_BLOOM; // poke + poke  -> 5x5 diamond
const CROSSFIRE = fixtures.CROSSFIRE; // sweep + block
const TRIAD = fixtures.TRIAD; // poke x3, deliberately unaffordable

/// A live hazard cell of the given tier — the thing casts downgrade.
fn tiered(tier: c.Tier) c.SlimeCell {
    return .{ .tiered = tier };
}

/// Shorthand for a SlimeCell expectation: `SC(.empty)`, `SC(.{ .special = … })`.
fn SC(cell: c.SlimeCell) c.SlimeCell {
    return cell;
}

// ---------------------------------------------------------------------------
// Minimal test encounters
//
// There is ONE slime pool per encounter now (the reservoir); the grid is sized
// globally by balance.slime_grid (6×10 = 60 cells in the fixture), so small
// encounters fit entirely on the grid and large ones exercise refill.
// ---------------------------------------------------------------------------

/// 20 green hazard units, roomy hunger budget.  Fits on the grid.  Green is
/// one downgrade from defused, so a single stamp finishes a cell.
const enc_twenty_green = enc.Encounter{
    .label = "test_twenty_green",
    .slime = .{ .tiered = .{ 0, 0, 20 } },
};

/// 20 red hazard units: red needs THREE stamps per cell to defuse.
const enc_twenty_red = enc.Encounter{
    .label = "test_twenty_red",
    .slime = .{ .tiered = .{ 20, 0, 0 } },
};

/// 50 green units — more than any single shape covers, so casts only ever
/// clear part of the field.
const enc_fifty_green = enc.Encounter{
    .label = "test_fifty_green",
    .slime = .{ .tiered = .{ 0, 0, 50 } },
};

/// Mixed tiers + neutral: 10 red + 8 green + 7 neutral = 25 units.
const enc_mixed = enc.Encounter{
    .label = "test_mixed",
    .slime = .{ .tiered = .{ 10, 0, 8 }, .neutral = 7 },
};

/// Exactly as many EDIBLE units as one `block` stamp covers (3x3 = 9).  Live,
/// they are nibbles: hunger for no score.  Under the default fixture config
/// the duo bar is 200, so hunger never binds here — the pressure is the
/// wasted bites.
const enc_tight_budget = enc.Encounter{
    .label = "test_tight_budget",
    .slime = .{ .neutral = 9 },
};

/// Nine edible units for the hunger_full tests.  Pair with `HungerBase(3)` —
/// a duo bar of 6 — so one modest feast overfills it: the shortest path to a
/// clean `hunger_full` loss with slime still on the board.
const enc_paper_stomach = enc.Encounter{
    .label = "test_paper_stomach",
    .slime = .{ .neutral = 9 },
};

/// Neutral-only: nothing needs defusing, so every bitten unit is consumed
/// and every unit scores.
const enc_neutral_only = enc.Encounter{
    .label = "test_neutral_only",
    .slime = .{ .neutral = 40 },
};

/// More slime than the 60-cell fixture grid holds: 80 units, so 20 always
/// start in the reservoir.
const enc_overflow = enc.Encounter{
    .label = "test_overflow",
    .slime = .{ .tiered = .{ 0, 0, 40 }, .neutral = 40 },
};

// ---------------------------------------------------------------------------
// Harness types
// ---------------------------------------------------------------------------

const TestPlayer = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    bt: shared.BufferTransport = undefined,
    pid: u8 = 0xFF,

    fn init(self: *TestPlayer, allocator: std.mem.Allocator) void {
        self.bt = shared.BufferTransport{ .buf = &self.buf, .allocator = allocator };
    }

    fn transport(self: *TestPlayer) shared.Transport {
        return self.bt.transport();
    }

    fn clear(self: *TestPlayer) void {
        self.buf.clearRetainingCapacity();
    }

    fn deinit(self: *TestPlayer, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }
};

const Msg = struct {
    tag: proto.MsgTag,
    /// Slice into the original `raw` buffer covering only the payload bytes
    /// (after the tag byte). Valid for the lifetime of the source buffer.
    payload: []const u8,
};

/// Walk `raw` decoding complete messages into `arena`-allocated Msg values.
/// Uses the canonical `proto.decode_*` functions so that any wire-format
/// change is caught here at compile time rather than via a hand-written
/// byte-offset table.
fn drain(raw: []const u8, arena: std.mem.Allocator) ![]Msg {
    var list: std.ArrayListUnmanaged(Msg) = .empty;
    var fbs = std.io.fixedBufferStream(raw);
    const r = fbs.reader();

    while (fbs.pos < raw.len) {
        const tag = proto.read_tag(r) catch break;
        const payload_start = fbs.pos;

        // Consume the payload using the canonical decoder; discard the result.
        // An error means the stream is truncated or corrupt — stop iterating.
        const ok = consume_payload(tag, r);
        if (!ok) break;

        try list.append(arena, .{ .tag = tag, .payload = raw[payload_start..fbs.pos] });
    }
    return list.toOwnedSlice(arena);
}

/// Consume one message payload from `r` using the canonical proto decoders.
/// Returns false if decoding fails (truncated stream).
fn consume_payload(tag: proto.MsgTag, r: anytype) bool {
    return switch (tag) {
        .take_slot => if (proto.decode_take_slot(r)) |_| true else |_| false,
        .leave_slot => true, // zero-payload
        .restart => true, // zero-payload
        .cycle_shape => if (proto.decode_cycle_shape(r)) |_| true else |_| false,
        .cast => true, // zero-payload
        .game_start => if (proto.decode_game_start(r)) |_| true else |_| false,
        .game_state => if (proto.decode_game_state(r)) |_| true else |_| false,
        .action_result => if (proto.decode_action_result(r)) |_| true else |_| false,
        .game_over => if (proto.decode_game_over(r)) |_| true else |_| false,
        .over_budget => if (proto.decode_over_budget(r)) |_| true else |_| false,
        .cast_refused => if (proto.decode_cast_refused(r)) |_| true else |_| false,
        .recipe_fired => if (proto.decode_recipe_fired(r)) |_| true else |_| false,
        .shape_cast => if (proto.decode_shape_cast(r)) |_| true else |_| false,
        .move_cursor => if (proto.decode_move_cursor(r)) |_| true else |_| false,
        .bite_settled => if (proto.decode_bite_settled(r)) |_| true else |_| false,
        .special_matched => if (proto.decode_special_matched(r)) |_| true else |_| false,
        .eggs_hatched => if (proto.decode_eggs_hatched(r)) |_| true else |_| false,
        .field_refilled => if (proto.decode_field_refilled(r)) |_| true else |_| false,
    };
}

fn find_tag(msgs: []const Msg, tag: proto.MsgTag) ?Msg {
    for (msgs) |m| if (m.tag == tag) return m;
    return null;
}

fn count_tag(msgs: []const Msg, tag: proto.MsgTag) usize {
    var n: usize = 0;
    for (msgs) |m| {
        if (m.tag == tag) n += 1;
    }
    return n;
}

/// The LAST game_state in a drained message list — the freshest snapshot.
fn last_game_state(msgs: []const Msg) !proto.GameState {
    var found: ?proto.GameState = null;
    for (msgs) |m| {
        if (m.tag != .game_state) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        found = try proto.decode_game_state(fbs.reader());
    }
    return found orelse error.NoGameState;
}

/// Decode the game_over payload from a drained message list.
fn game_over_msg(msgs: []const Msg) !proto.GameOver {
    const go_msg = find_tag(msgs, .game_over) orelse return error.NoGameOver;
    var fbs = std.io.fixedBufferStream(go_msg.payload);
    return try proto.decode_game_over(fbs.reader());
}

// ---------------------------------------------------------------------------
// Session setup helpers
// ---------------------------------------------------------------------------

/// Queue one wire message on a connection.  Harness sessions seat players in
/// connection order, so a TestPlayer's pid doubles as its connection id.
fn enqueue_msg(sess: *Session, conn_id: usize, comptime tag: proto.MsgTag, payload: anytype) !void {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), tag, payload);
    sess.enqueue_message(conn_id, fbs.getWritten());
}

/// Turn `pid`'s wheel one step.  Selection is server state, so tests steer it
/// the way a player does rather than assigning it.
fn enqueue_cycle(sess: *Session, pid: u8, dir: c.CycleDir) !void {
    try enqueue_msg(sess, pid, .cycle_shape, proto.CycleShape{ .dir = dir });
}

/// Queue a bare trigger: fires whatever `pid` currently has selected,
/// wherever they are currently aiming.  (There is no cancel any more: a
/// realtime cast resolves the moment the drain reaches it, so there is never
/// anything pending to take back.)
fn enqueue_cast(sess: *Session, pid: u8) !void {
    try enqueue_msg(sess, pid, .cast, {});
}

/// Point `pid`'s wheel AT `move`, by queueing forward turns.  Cheaper to read
/// than a hand-counted run of cycle messages, and it exercises the real path.
fn enqueue_select(sess: *Session, pid: u8, move: u8) !void {
    const moves = BAL.player_recipes.len;
    const have = sess.selected[pid];
    const steps = (@as(usize, move) +% moves -% have) % moves;
    for (0..steps) |_| try enqueue_cycle(sess, pid, .forward);
}

/// Queue "select `move`, then fire it" — the two-key sequence a player performs
/// for a single deliberate cast, which is what most tests actually mean.
fn enqueue_cast_as(sess: *Session, pid: u8, move: u8) !void {
    try enqueue_select(sess, pid, move);
    try enqueue_cast(sess, pid);
}

/// Drain queues and broadcast, WITHOUT advancing the session clock: `tick(0)`
/// adds no time, so casts land and state goes out but the bite timer never
/// comes due (it merely arms) and no cooldown or window entry can expire.
/// The workhorse for "apply the queued input, then look".
fn flush(sess: *Session) !void {
    try sess.tick(0.0);
}

/// The fixture's realtime pacing, restated here so a test reads as an intent
/// ("advance past the cooldown") rather than a magic number.  fixtures.zig
/// PINS these (cast_cooldown_ms = 100, team_window_ms = 500); if a fixture
/// edit ever unpins them, the assertions comparing against the balance will
/// say so loudly.
const COOLDOWN_MS: u64 = 100;
const WINDOW_MS: u64 = 500;

/// Walk the session clock forward by `ms`, in the 50ms driver-sized ticks the
/// production loop takes — never one giant leap, because the tick is where
/// the window prunes and the bite timer is checked, and a test that jumps the
/// clock in one go exercises a cadence the server never runs at.
///
/// NOTE: bites WILL fire whenever the walk crosses `next_bite_at`.  The timer
/// arms on the first seated tick at `bite_interval_effective(seated, babies)`
/// — for the usual two-player harness that is 1000 * 100/115 = 869ms — so a
/// test that must stay bite-free keeps its total advance under that.
fn advance(sess: *Session, ms: u64) !void {
    var left = ms;
    while (left > 0) {
        const step = @min(left, 50);
        try sess.tick(@as(f32, @floatFromInt(step)) / 1000.0);
        left -= step;
    }
}

/// Forgive every player their cast cooldown, directly.  `cooldown_until` is
/// server-owned state, so tests write it the same way they write cursors
/// (`aim_at`) and grid cells (`paint_grid`) — for tests that are NOT about
/// the cooldown but need several casts from one player without walking the
/// clock toward a bite.
fn clear_cooldowns(sess: *Session) void {
    sess.cooldown_until = [_]u64{0} ** session_mod.MAX_PLAYERS;
}

/// Settle one bite WITHOUT casting, through the public test seam, then flush
/// so the resulting state is broadcast.  This keeps "what the feast does"
/// separate from "what casts do" — and separate from the clock, which a
/// direct settle never touches.
fn settle_idly(sess: *Session) !void {
    try sess.settle_bite();
    try flush(sess);
}

/// Settle a bite that must NOT finish the encounter: a spare unit waits in
/// the reservoir, so the feast can never leave the field exhausted.  Use this
/// when the test still has moves to make after the bite settles.
fn settle_mid_game(sess: *Session) !void {
    if (sess.field.reservoir.is_empty()) sess.field.reservoir = .{ .neutral = 1 };
    try settle_idly(sess);
}

// ---------------------------------------------------------------------------
// Two-player session factory
// ---------------------------------------------------------------------------

const TwoPlayerSession = struct {
    sess: Session,
    p: [2]TestPlayer,
    allocator: std.mem.Allocator,

    fn deinit(self: *TwoPlayerSession) void {
        self.sess.deinit();
        self.p[0].deinit(self.allocator);
        self.p[1].deinit(self.allocator);
    }
};

fn init_two_player_session(
    self: *TwoPlayerSession,
    allocator: std.mem.Allocator,
) !void {
    return init_two_player_session_seeded(self, allocator, SEED);
}

/// As `init_two_player_session`, but with an explicit PRNG seed — for tests
/// that compare two runs, or that need a layout the pinned seed doesn't give.
fn init_two_player_session_seeded(
    self: *TwoPlayerSession,
    allocator: std.mem.Allocator,
    seed: u64,
) !void {
    return init_two_player_session_cfg(self, allocator, seed, TEST_CFG);
}

/// As `init_two_player_session_seeded`, but on an explicit config — for the
/// tests about running the pool dry, which need a move table without the
/// fixture's free `trickle` (see fixtures.priced_config).
fn init_two_player_session_cfg(
    self: *TwoPlayerSession,
    allocator: std.mem.Allocator,
    seed: u64,
    cfg: *const shared.config.Config,
) !void {
    self.allocator = allocator;
    self.p[0].buf = .empty;
    self.p[1].buf = .empty;
    self.p[0].init(allocator);
    self.p[1].init(allocator);

    self.sess = try Session.init_seeded(allocator, "TSTKEY".*, cfg, seed);

    // Connect two transports and seat both — directly, not over the wire,
    // because seating over the wire needs a tick and the encounter has not
    // started yet.  Connection ids and seat ids both count up from 0, so a
    // TestPlayer's pid doubles as its connection id everywhere below.
    const pid0 = try seat_player(&self.sess, self.p[0].transport(), 0);
    const pid1 = try seat_player(&self.sess, self.p[1].transport(), 0);
    self.p[0].pid = pid0;
    self.p[1].pid = pid1;
}

/// Connect `transport` and take a seat with `appetite`.  Returns the seat id,
/// which equals the connection id for sessions built strictly this way.
fn seat_player(sess: *Session, transport: shared.Transport, appetite: u32) !u8 {
    const conn_id = sess.connect(transport) orelse return error.JoinFailed;
    try sess.take_slot(conn_id, .{ .appetite = appetite });
    const pid = sess.connections[conn_id].player_id orelse return error.JoinFailed;
    std.debug.assert(@as(usize, pid) == conn_id);
    return pid;
}

/// Start `encounter` with the pinned seed.
fn start(s: *TwoPlayerSession, encounter: *const enc.Encounter) !void {
    try s.sess.start_game_encounter(encounter);
}

/// A config identical to the fixture except for `hunger_base` — for tests
/// that need a hunger bar of a specific size.  Appetites are 0 in these
/// sessions, so a two-player bar is exactly `2 * base`.
fn HungerBase(comptime base: u16) type {
    return struct {
        const cfg = shared.config.Config{
            .balance = blk: {
                var b = fixtures.test_config.balance;
                b.hunger_base = base;
                break :blk b;
            },
            .encounters = fixtures.test_config.encounters,
        };
    };
}

/// A config identical to the fixture except the bite spans the WHOLE grid,
/// optionally with a custom `hunger_base` — for tests about "everything
/// edible is eaten this turn" that are not themselves about the bite's
/// width.  `WholeBite(0)` keeps the fixture bar.
fn WholeBite(comptime base: u16) type {
    return struct {
        const cfg = shared.config.Config{
            .balance = blk: {
                var b = fixtures.test_config.balance;
                b.feast_columns = b.slime_grid.cols;
                if (base != 0) b.hunger_base = base;
                break :blk b;
            },
            .encounters = fixtures.test_config.encounters,
        };
    };
}

/// Overwrite the whole grid with one cell value — the deterministic setup for
/// tests that assert exact per-cell outcomes.  The reservoir is left alone.
fn paint_grid(sess: *Session, cell: c.SlimeCell) void {
    var flat: u16 = 0;
    while (flat < sess.field.grid.len()) : (flat += 1) sess.field.grid.put(flat, cell);
}

/// Cell-by-cell grid comparison.  `SlimeCell` is a tagged union, so it has no
/// `==` and `std.mem.eql` will not take it.
fn grids_equal(a: c.SlimeGrid, b: c.SlimeGrid) bool {
    if (a.len() != b.len()) return false;
    for (a.live(), b.live()) |x, y| {
        if (!std.meta.eql(x, y)) return false;
    }
    return true;
}

/// Replace the whole field with EXACTLY `count` cells of `cell` and nothing
/// in the reservoir, so bites and neutralize counts are fully predictable.
/// `count` must fit on the grid.
fn set_field(sess: *Session, cell: c.SlimeCell, count: u16) void {
    std.debug.assert(count <= sess.field.grid.len());
    paint_grid(sess, .empty);
    var flat: u16 = 0;
    while (flat < count) : (flat += 1) sess.field.grid.put(flat, cell);
    sess.field.reservoir = .{};
}

/// Replace the whole field with a 3x3 patch of `cell` centred on (row, col)
/// and nothing else — exactly the footprint of the fixture `block` recipe, so
/// ONE stamp covers the entire remaining field.  The reservoir is emptied so
/// no refill can reintroduce slime mid-test.
fn set_block_field(sess: *Session, cell: c.SlimeCell, row: u8, col: u8) void {
    paint_grid(sess, .empty);
    for (0..3) |dr| {
        for (0..3) |dc| {
            sess.field.grid.set(row - 1 + @as(u8, @intCast(dr)), col - 1 + @as(u8, @intCast(dc)), cell);
        }
    }
    sess.field.reservoir = .{};
}

// ---------------------------------------------------------------------------
// Connections, seats and observers
// ---------------------------------------------------------------------------

test "a new connection is an observer and is told so by game_start" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    var watcher = TestPlayer{};
    watcher.init(allocator);
    defer watcher.deinit(allocator);
    _ = s.sess.connect(watcher.transport()) orelse return error.JoinFailed;

    const msgs = try drain(watcher.buf.items, arena);
    const gs_msg = find_tag(msgs, .game_start) orelse return error.NoGameStart;
    var fbs = std.io.fixedBufferStream(gs_msg.payload);
    const gs = try proto.decode_game_start(fbs.reader());
    try std.testing.expectEqual(proto.NO_PLAYER, gs.player_id);
    // The game id travels with it, so the observer can show who to tell.
    try std.testing.expectEqualSlices(u8, "TSTKEY", &gs.join_code);
}

test "an observer receives game_state broadcasts but its game input is ignored" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    var watcher = TestPlayer{};
    watcher.init(allocator);
    defer watcher.deinit(allocator);
    const conn_id = s.sess.connect(watcher.transport()) orelse return error.JoinFailed;

    // A burst of gameplay input from a seatless connection: the stream stays
    // in sync (the cycle decodes) and nothing changes — no cast lands, no
    // charge leaves the pool, nothing joins the recent-cast window.
    const charges_before = s.sess.charges;
    var buf: [16]u8 = undefined;
    var wfbs = std.io.fixedBufferStream(&buf);
    try proto.encode(wfbs.writer(), .cycle_shape, proto.CycleShape{ .dir = .forward });
    try proto.encode(wfbs.writer(), .cast, {});
    s.sess.enqueue_message(conn_id, wfbs.getWritten());
    watcher.clear();
    try flush(&s.sess);
    try std.testing.expectEqual(@as(usize, 0), s.sess.recent_count);
    try std.testing.expectEqual(charges_before, s.sess.charges);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.casts_total);

    // But the broadcasts flow: observers watch the same game.
    const msgs = try drain(watcher.buf.items, arena);
    try std.testing.expect(find_tag(msgs, .game_state) != null);
}

test "the session starts its encounter with the configured grid and seats sum the bar" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();

    s.p[0].clear();
    try s.sess.start_game(DEFAULT_ENC.label);
    try s.sess.broadcast_game_start(DEFAULT_ENC.label);

    const msgs = try drain(s.p[0].buf.items, arena);
    const gs_msg = find_tag(msgs, .game_start) orelse return error.NoGameStart;
    var fbs = std.io.fixedBufferStream(gs_msg.payload);
    const gs = try proto.decode_game_start(fbs.reader());
    try std.testing.expectEqualSlices(
        u8,
        DEFAULT_ENC.label,
        gs.encounter_label[0..gs.encounter_label_len],
    );
    // A seated receiver is addressed by seat, not as an observer.
    try std.testing.expectEqual(s.p[0].pid, gs.player_id);
    // The client needs the grid dimensions and the realtime pacing up front:
    // the cooldown it must draw and the window a group must land inside are
    // both fixed for the encounter, so they travel once here.
    try std.testing.expectEqual(BAL.slime_grid.rows, gs.grid_rows);
    try std.testing.expectEqual(BAL.slime_grid.cols, gs.grid_cols);
    try std.testing.expectEqual(BAL.cast_cooldown_ms, gs.cast_cooldown_ms);
    try std.testing.expectEqual(BAL.team_window_ms, gs.team_window_ms);
    try std.testing.expectEqual(s.sess.charges, gs.charges);

    // The bar is the players' appetite contributions summed — two appetite-0
    // players here, so twice the base.
    try std.testing.expectEqual(2 * logic.player_hunger(BAL, 0, 0), s.sess.hunger.max);
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);
    try std.testing.expectEqual(DEFAULT_ENC.total_units(), s.sess.slime_total);
}

test "the fifth take_slot is silently ignored" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    // Fill the remaining seats (MAX_PLAYERS = 4; two are taken).
    var extra_conns: [3]usize = undefined;
    for (&extra_conns) |*cid| {
        cid.* = s.sess.connect(s.p[0].transport()) orelse return error.JoinFailed;
    }
    try s.sess.take_slot(extra_conns[0], .{});
    try s.sess.take_slot(extra_conns[1], .{});
    try std.testing.expectEqual(@as(u8, 4), s.sess.seated_players());

    // The fifth asker: no error, no seat, still an observer.
    const bar_before = s.sess.hunger.max;
    const charges_before = s.sess.charges;
    try s.sess.take_slot(extra_conns[2], .{});
    try std.testing.expectEqual(@as(u8, 4), s.sess.seated_players());
    try std.testing.expectEqual(@as(?u8, null), s.sess.connections[extra_conns[2]].player_id);
    try std.testing.expectEqual(bar_before, s.sess.hunger.max);
    try std.testing.expectEqual(charges_before, s.sess.charges);
}

test "leave_slot frees the seat, keeps the connection observing" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    s.p[1].clear();
    try enqueue_msg(&s.sess, s.p[1].pid, .leave_slot, {});
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u8, 1), s.sess.seated_players());
    try std.testing.expectEqual(@as(?u8, null), s.sess.connections[@as(usize, s.p[1].pid)].player_id);
    // The connection stays: it is told it now observes, and keeps receiving
    // the game.
    const msgs = try drain(s.p[1].buf.items, arena);
    const gs_msg = find_tag(msgs, .game_start) orelse return error.NoGameStart;
    var fbs = std.io.fixedBufferStream(gs_msg.payload);
    const gs = try proto.decode_game_start(fbs.reader());
    try std.testing.expectEqual(proto.NO_PLAYER, gs.player_id);
    try std.testing.expect(find_tag(msgs, .game_state) != null);
}

// ---------------------------------------------------------------------------
// Field setup at game start
// ---------------------------------------------------------------------------

test "start sizes the grid from balance and fills it from the reservoir" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_overflow); // 80 units, 60 cells

    try std.testing.expectEqual(BAL.slime_grid.rows, s.sess.field.grid.rows);
    try std.testing.expectEqual(BAL.slime_grid.cols, s.sess.field.grid.cols);
    try std.testing.expectEqual(@as(u16, 60), s.sess.field.grid.occupied());
    try std.testing.expectEqual(@as(u32, 20), s.sess.field.reservoir.total());
    try std.testing.expectEqual(@as(u32, 80), s.sess.field.remaining());
    try std.testing.expectEqual(@as(u32, 80), s.sess.slime_total);
}

test "a small encounter fits entirely on the grid, leaving holes" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_red); // 20 units on a 60-cell grid

    try std.testing.expectEqual(@as(u16, 20), s.sess.field.grid.occupied());
    try std.testing.expect(s.sess.field.reservoir.is_empty());
    // Filled from the right, so the back columns hold the slime: 20 units
    // fill the rightmost 3 columns of the 6-row grid, plus 2 cells of the
    // next one in.
    const grid = &s.sess.field.grid;
    for (grid.live(), 0..) |cell, i| {
        const col = grid.col_of(@intCast(i));
        const row = grid.row_of(@intCast(i));
        const expected = col >= grid.cols - 3 or
            (col == grid.cols - 4 and row < 2);
        try std.testing.expectEqual(expected, cell.is_slime());
    }
}

test "every player starts a fresh encounter with a cold cooldown" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    // Nobody owes a cooldown from a previous game: everyone may cast the
    // instant play begins.
    try std.testing.expectEqual(@as(u16, 1), s.sess.bite);
    for (&s.sess.players, 0..) |*slot, pid| {
        if (!slot.occupied) continue;
        try std.testing.expectEqual(@as(u64, 0), s.sess.cooldown_until[pid]);
    }
}

test "a leave never stalls the bite clock" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    // Nothing on the grid to eat, so a bite cannot end the game.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{ .neutral = 5 };

    // The first live tick arms the timer at the two-player rate (869ms)...
    try flush(&s.sess);

    // ...then P1 drops out mid-game.  The bite is on a CLOCK, not on
    // anyone's input, so play simply continues for whoever stayed: the
    // armed bite still comes due.
    s.sess.disconnect(s.p[1].pid);
    try advance(&s.sess, 900);
    try std.testing.expectEqual(@as(u16, 2), s.sess.bite);
}

test "an empty room never bites on its own" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    s.sess.disconnect(s.p[0].pid);
    s.sess.disconnect(s.p[1].pid);
    // Three base intervals of wall time: with nobody present the feast must
    // not run unattended, however long the room sits.
    try advance(&s.sess, 3000);

    try std.testing.expectEqual(@as(u16, 1), s.sess.bite);
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);
    // The timer is DISARMED, not merely late — the wire shows no countdown.
    try std.testing.expectEqual(@as(u64, 0), s.sess.next_bite_at);
}

// ---------------------------------------------------------------------------
// The bite clock
//
// The Lil Guys chew on a TIMER: every `bite_interval_effective(seated,
// babies)` ms of play time the field settles.  The timer arms on the first
// live tick with someone seated, reschedules from the DUE time at the
// crowd's CURRENT rate, and disarms while the session holds or the table is
// empty.
// ---------------------------------------------------------------------------

test "the bite fires on the clock" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    paint_grid(&s.sess, .neutral);
    s.sess.field.reservoir = .{ .neutral = 20 };

    // The first live tick arms the timer: the two-player interval is 869ms
    // (1000 * 100/115), so 900ms of wall time crosses it exactly once.
    try flush(&s.sess);
    s.p[0].clear();
    try advance(&s.sess, 900);

    try std.testing.expectEqual(@as(u16, 2), s.sess.bite);
    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .bite_settled));
    // The bite ate the front column: hunger moved without anyone casting.
    try std.testing.expect(s.sess.hunger.current > 0);
}

test "the countdown on the wire is the crowd's effective interval" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two seats: each guy past the first speeds the base rate by 15%.
    var duo: TwoPlayerSession = undefined;
    try init_two_player_session(&duo, allocator);
    defer duo.deinit();
    try start(&duo, &enc_fifty_green);
    duo.p[0].clear();
    try flush(&duo.sess); // the first live tick arms the timer
    const duo_gs = try last_game_state(try drain(duo.p[0].buf.items, arena));
    try std.testing.expectEqual(BAL.bite_interval_effective(2, 0), duo_gs.next_bite_ms);
    try std.testing.expectEqual(@as(u32, 869), duo_gs.next_bite_ms);

    // Solo: one guy is the baseline — no speedup at all.
    var solo: TwoPlayerSession = undefined;
    try init_two_player_session(&solo, allocator);
    defer solo.deinit();
    try start(&solo, &enc_fifty_green);
    solo.sess.disconnect(solo.p[1].pid);
    solo.p[0].clear();
    try flush(&solo.sess);
    const solo_gs = try last_game_state(try drain(solo.p[0].buf.items, arena));
    try std.testing.expectEqual(BAL.bite_interval_effective(1, 0), solo_gs.next_bite_ms);
    try std.testing.expectEqual(@as(u32, 1000), solo_gs.next_bite_ms);
}

test "babies at the table speed the bite: board-brought and hatched alike" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    // Three babies on p0's board and two hatched this encounter: all five
    // are eaters at the table, so all five speed the same base rate.  Both
    // counts are server-owned state, written directly the way tests write
    // cursors and grids.
    s.sess.players[s.p[0].pid].babies = .{ 3, 0, 0, 0, 0 };
    s.sess.hatched = .{ 2, 0, 0, 0, 0 };

    s.p[0].clear();
    try flush(&s.sess); // arms at the CURRENT crowd's rate
    const gs = try last_game_state(try drain(s.p[0].buf.items, arena));
    // 2 guys + 5 babies: 100 + 15 + 5*5 = 140 -> 1000*100/140 = 714ms.
    try std.testing.expectEqual(BAL.bite_interval_effective(2, 5), gs.next_bite_ms);
    try std.testing.expectEqual(@as(u32, 714), gs.next_bite_ms);
}

test "the pre-match hold freezes the clock" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    s.sess.prematch = true; // as the server boot (and every restart) sets it

    // Two seconds of wall time pass while everyone reads the guide: nothing
    // may move — not the bite, not the clock the cooldowns and the group
    // window are measured on.
    try advance(&s.sess, 2000);
    try std.testing.expectEqual(@as(u16, 1), s.sess.bite);
    try std.testing.expectEqual(@as(u64, 0), s.sess.now_ms());
    try std.testing.expectEqual(@as(u64, 0), s.sess.next_bite_at);

    // The hold lifts, the next live tick arms the timer FROM NOW — the
    // guide's dead time is not billed to the first meal — and play resumes.
    s.sess.prematch = false;
    try flush(&s.sess);
    try advance(&s.sess, 900);
    try std.testing.expectEqual(@as(u16, 2), s.sess.bite);
}

// ---------------------------------------------------------------------------
// Shape selection (the wheel)
// ---------------------------------------------------------------------------

test "the wheel starts on the first move for every player" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    // Move 0 is where everyone begins, so a player who never touches the wheel
    // still has something castable — there is no unselected state.
    try std.testing.expectEqual(@as(u8, 0), s.sess.selected[s.p[0].pid]);
    try std.testing.expectEqual(@as(u8, 0), s.sess.selected[s.p[1].pid]);
}

test "cycling forward walks the move table in order and wraps at the end" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    const pid = s.p[0].pid;
    const moves = BAL.player_recipes.len;
    for (1..moves) |want| {
        try enqueue_cycle(&s.sess, pid, .forward);
        try flush(&s.sess);
        try std.testing.expectEqual(@as(u8, @intCast(want)), s.sess.selected[pid]);
    }
    // One more turn past the last move returns to the first: the wheel is a
    // ring, so no amount of cycling can strand a player on nothing.
    try enqueue_cycle(&s.sess, pid, .forward);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u8, 0), s.sess.selected[pid]);
}

test "cycling backward from the first move wraps to the last" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    const pid = s.p[0].pid;
    const last: u8 = @intCast(BAL.player_recipes.len - 1);

    try enqueue_cycle(&s.sess, pid, .backward);
    try flush(&s.sess);
    try std.testing.expectEqual(last, s.sess.selected[pid]);

    // And back again: forward and backward are exact inverses.
    try enqueue_cycle(&s.sess, pid, .forward);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u8, 0), s.sess.selected[pid]);
}

test "each player turns their own wheel independently" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    try enqueue_select(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);

    try std.testing.expectEqual(BLOCK, s.sess.selected[s.p[0].pid]);
    try std.testing.expectEqual(@as(u8, 0), s.sess.selected[s.p[1].pid]);
}

test "cycling costs nothing: it is not a cast" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    const pid = s.p[0].pid;
    const charges_before = s.sess.charges;
    for (0..10) |_| try enqueue_cycle(&s.sess, pid, .forward);
    try flush(&s.sess);

    // Nothing spent, nothing stamped, nothing logged: choosing is free, and a
    // player may deliberate as long as they like — no charge, no cooldown,
    // nothing in the group window.
    try std.testing.expectEqual(charges_before, s.sess.charges);
    try std.testing.expectEqual(@as(u64, 0), s.sess.cooldown_until[pid]);
    try std.testing.expectEqual(@as(usize, 0), s.sess.recent_count);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.casts_total);
}

test "a selection survives the turn that used it" {
    // The wheel is not a per-turn choice: a player who found their move keeps
    // it, and pays no keystrokes to cast it again next turn.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    const pid = s.p[0].pid;
    try enqueue_select(&s.sess, pid, SWEEP);
    try flush(&s.sess);
    try settle_mid_game(&s.sess);

    try std.testing.expectEqual(@as(u16, 2), s.sess.bite);
    try std.testing.expectEqual(SWEEP, s.sess.selected[pid]);
}

test "a cast fires the selected move" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));

    const pid = s.p[0].pid;
    const pool_before = s.sess.charges;
    aim_at(&s.sess, pid, 3, 3);
    try enqueue_cast_as(&s.sess, pid, SWEEP);
    try flush(&s.sess);

    // `sweep` is "###", so exactly three cells defused — the wheel, not the
    // keystrokes, decided the shape.
    try std.testing.expectEqual(@as(u16, 3), count_defused(&s.sess));
    try std.testing.expectEqual(
        BAL.player_recipes[SWEEP].cost,
        pool_before - s.sess.charges,
    );
}

test "a cast with the wheel untouched fires the first move" {
    // There is no "nothing selected" to guard against: pressing cast on a fresh
    // session is a legal, cheap poke rather than an error.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));

    const pid = s.p[0].pid;
    aim_at(&s.sess, pid, 3, 3);
    try enqueue_cast(&s.sess, pid);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 1), count_defused(&s.sess));
}

// ---------------------------------------------------------------------------
// Shape stamping
//
// A matched recipe stamps its shape at the caster's cast anchor, downgrading
// every covered HAZARD cell by exactly one tier.  These tests pin the grid with
// `set_field`/`paint_grid` and resolve the turn by hand, so a stamp is fully
// deterministic: shape placement is arithmetic, not PRNG.
// ---------------------------------------------------------------------------

/// Number of live hazard cells of one tier on the grid.
fn count_tier(sess: *const Session, tier: c.Tier) u16 {
    return sess.field.grid.tier_count(tier);
}

/// Number of defused (`neutralized`) cells on the grid.
fn count_defused(sess: *const Session) u16 {
    var n: u16 = 0;
    for (sess.field.grid.live()) |cell| {
        if (cell == .neutralized) n += 1;
    }
    return n;
}

/// Park a player's cursor on an exact cell, bypassing the d-pad.  Cursors are
/// server-owned, so tests set them the same way the server does.
fn aim_at(sess: *Session, pid: u8, row: u8, col: u8) void {
    sess.cursors[pid] = sess.field.grid.index(row, col);
}

test "a stamp downgrades exactly the cells its shape covers" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // `block` is 3x3 = 9 cells, centred on the anchor and fully in-bounds here.
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);

    // Green is one step from defused, so all 9 covered cells defuse and the
    // rest of the grid is untouched.
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 60 - 9), count_tier(&s.sess, .green));
    // Nothing is destroyed: a downgrade rewrites a cell, it never empties it.
    try std.testing.expectEqual(@as(u16, 60), s.sess.field.grid.occupied());
    try std.testing.expectEqual(@as(u32, 60), s.sess.field.remaining());
    // Nothing eaten yet.
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    // Stats see the coverage and the defusals.
    try std.testing.expectEqual(@as(u16, 9), s.sess.stats.feast.cells_covered[GREEN]);
    try std.testing.expectEqual(@as(u16, 9), s.sess.stats.feast.neutralized[GREEN]);
    try std.testing.expectEqual(@as(u16, 9), s.sess.stats.players[s.p[0].pid].cells_covered);
    try std.testing.expectEqual(@as(u16, 9), s.sess.stats.players[s.p[0].pid].cells_neutralized);
}

test "a stamp lands at the caster's cursor, not at a fixed spot" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // `poke` is a single cell, so the anchor IS the footprint.
    aim_at(&s.sess, s.p[0].pid, 4, 7);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);

    try std.testing.expect(s.sess.field.grid.at(4, 7) == .neutralized);
    try std.testing.expectEqual(@as(u16, 1), count_defused(&s.sess));
}

test "a shape hanging off the edge is clipped, and the surplus is reported" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // 3x3 anchored in the top-left corner: only the bottom-right 2x2 quadrant
    // is on the grid.  Clipping must not wrap to the far edge.
    aim_at(&s.sess, s.p[0].pid, 0, 0);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 4), count_defused(&s.sess));
    try std.testing.expect(s.sess.field.grid.at(0, 0) == .neutralized);
    try std.testing.expect(s.sess.field.grid.at(1, 1) == .neutralized);
    // The opposite corner is untouched — nothing wrapped around.
    try std.testing.expect(s.sess.field.grid.at(5, 9) == .tiered);
}

test "a stamp steps a red cell down one tier at a time, taking three casts" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_red);
    paint_grid(&s.sess, tiered(.red));
    s.sess.field.reservoir = .{};

    const pid = s.p[0].pid;
    aim_at(&s.sess, pid, 3, 4);

    // Cast 1: red → yellow.
    try enqueue_cast_as(&s.sess, pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(c.Tier.yellow, s.sess.field.grid.at(3, 4).tiered);

    // Cast 2: yellow → green.  (Forgive the cooldown rather than walk the
    // clock — walking it would eventually march the Lil Guys onto the very
    // cell under test.)
    clear_cooldowns(&s.sess);
    aim_at(&s.sess, pid, 3, 4);
    try enqueue_cast_as(&s.sess, pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(c.Tier.green, s.sess.field.grid.at(3, 4).tiered);

    // Cast 3: green → defused, and no further.
    clear_cooldowns(&s.sess);
    aim_at(&s.sess, pid, 3, 4);
    try enqueue_cast_as(&s.sess, pid, POKE);
    try flush(&s.sess);
    try std.testing.expect(s.sess.field.grid.at(3, 4) == .neutralized);

    // A fourth cast is inert: a defused cell cannot be downgraded further.
    clear_cooldowns(&s.sess);
    aim_at(&s.sess, pid, 3, 4);
    try enqueue_cast_as(&s.sess, pid, POKE);
    try flush(&s.sess);
    try std.testing.expect(s.sess.field.grid.at(3, 4) == .neutralized);
    // Three tiers covered, one per tier — the fourth cast covered nothing.
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.feast.cells_covered[RED]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.feast.cells_covered[YELLOW]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.feast.cells_covered[GREEN]);
}

test "empty and neutral cells under a shape are inert" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    // Half neutral, half empty: neither is a hazard, so neither can downgrade.
    paint_grid(&s.sess, .empty);
    var flat: u16 = 0;
    while (flat < 30) : (flat += 1) s.sess.field.grid.put(flat, .neutral);
    s.sess.field.reservoir = .{};

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 0), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 30), s.sess.field.grid.occupied());
    for (s.sess.stats.feast.cells_covered) |n|
        try std.testing.expectEqual(@as(u16, 0), n);
}

test "a stamp only reaches the grid; the reservoir is out of range" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    // 80 green units: 60 on the grid, 20 waiting off-grid.
    const encounter = enc.Encounter{
        .label = "test_green_overflow",
        .slime = .{ .tiered = .{ 0, 0, 80 } },
    };
    try start(&s, &encounter);
    try std.testing.expectEqual(@as(u16, 60), count_tier(&s.sess, .green));

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));
    // The off-grid 20 are untouched: shapes address cells, not the pool.
    try std.testing.expectEqual(@as(u16, 20), s.sess.field.reservoir.tiered[GREEN]);
}

test "shape_cast reports the resolved footprint and the tiers it downgraded" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    s.p[0].clear();
    s.p[1].clear();
    // `sweep` is a horizontal run of three, centred on the anchor.
    aim_at(&s.sess, s.p[0].pid, 3, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, SWEEP);
    try flush(&s.sess);

    // Broadcast to everyone, so teammates can animate the hit.
    const msgs = try drain(s.p[1].buf.items, arena);
    const msg = find_tag(msgs, .shape_cast) orelse return error.MissingShapeCast;
    var fbs = std.io.fixedBufferStream(msg.payload);
    const sc = try proto.decode_shape_cast(fbs.reader());

    try std.testing.expectEqual(s.p[0].pid, sc.caster);
    try std.testing.expectEqual(@as(u16, 3), sc.cell_count);
    // Absolute flat indices, already clipped: the client never re-derives them.
    const grid = &s.sess.field.grid;
    try std.testing.expectEqual(grid.index(3, 4), sc.cells[0]);
    try std.testing.expectEqual(grid.index(3, 5), sc.cells[1]);
    try std.testing.expectEqual(grid.index(3, 6), sc.cells[2]);
    try std.testing.expectEqual(@as(u16, 3), sc.downgraded[GREEN]);
    try std.testing.expectEqual(@as(u16, 3), sc.neutralized);
    try std.testing.expectEqual(@as(u16, 0), sc.off_grid);
    try std.testing.expectEqual(@as(u16, 0), sc.inert);
}

test "shape_cast counts clipped cells as off_grid and dead cells as inert" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    // Only the anchor row carries slime; everything else is empty.
    paint_grid(&s.sess, .empty);
    s.sess.field.grid.set(0, 0, tiered(.green));
    s.sess.field.reservoir = .{};

    s.p[0].clear();
    s.p[1].clear();
    // 3x3 in the corner: 5 of 9 cells fall off the grid, 3 of the remaining 4
    // are empty, and only (0,0) is a hazard.
    aim_at(&s.sess, s.p[0].pid, 0, 0);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);

    const msgs = try drain(s.p[1].buf.items, arena);
    const msg = find_tag(msgs, .shape_cast) orelse return error.MissingShapeCast;
    var fbs = std.io.fixedBufferStream(msg.payload);
    const sc = try proto.decode_shape_cast(fbs.reader());

    try std.testing.expectEqual(@as(u16, 4), sc.cell_count); // only in-bounds cells
    try std.testing.expectEqual(@as(u16, 5), sc.off_grid);
    try std.testing.expectEqual(@as(u16, 3), sc.inert);
    try std.testing.expectEqual(@as(u16, 1), sc.downgraded[GREEN]);
}

test "a cast the pool cannot afford is refused, and only the caster hears it" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);

    s.p[0].clear();
    s.p[1].clear();
    // `deluge` costs 9 against a pool of 2: the cast is refused outright.
    s.sess.charges = 2;
    try enqueue_cast_as(&s.sess, s.p[0].pid, DELUGE);
    try flush(&s.sess);

    // Refused means UNCHANGED: nothing landed, nothing joined the window,
    // no debit — and no cooldown, so the player may retry immediately.
    try std.testing.expectEqual(@as(usize, 0), s.sess.recent_count);
    try std.testing.expectEqual(@as(u64, 0), s.sess.cooldown_until[s.p[0].pid]);
    try std.testing.expectEqual(@as(u32, 2), s.sess.charges);

    // The caster is told the price and the purse, so the client can say why.
    const own = try drain(s.p[0].buf.items, arena);
    const msg = find_tag(own, .over_budget) orelse return error.MissingOverBudget;
    var fbs = std.io.fixedBufferStream(msg.payload);
    const ob = try proto.decode_over_budget(fbs.reader());
    try std.testing.expectEqual(@as(u32, 9), ob.needed);
    try std.testing.expectEqual(@as(u32, 2), ob.have);

    // Nobody else's screen changes: a refusal is a private "no".
    const others = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(others, .shape_cast));
    try std.testing.expectEqual(@as(usize, 0), count_tag(others, .over_budget));
}

test "a refused cast starts no cooldown: something affordable lands at once" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    s.sess.charges = 2;

    const pid = s.p[0].pid;
    aim_at(&s.sess, pid, 2, 5);
    try enqueue_cast_as(&s.sess, pid, DELUGE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 0), count_defused(&s.sess));

    // The refusal cost nothing — not even TIME: with no cooldown started,
    // the cheaper retry lands in the very next drain, at the same instant.
    try enqueue_cast_as(&s.sess, pid, POKE);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 1), count_defused(&s.sess));
    try std.testing.expectEqual(
        @as(u64, s.sess.now_ms() + COOLDOWN_MS),
        s.sess.cooldown_until[pid],
    );
}

test "two pokes on one square fire the group shape; one poke stays a poke" {
    const allocator = std.testing.allocator;

    // Together: p1's poke completes twin_bloom's bag, so the 5x5 diamond
    // (13 cells) fires TOO — on top of the pokes, which landed as
    // themselves the moment they were pressed.
    var together: TwoPlayerSession = undefined;
    try init_two_player_session(&together, allocator);
    defer together.deinit();
    try start(&together, &enc_fifty_green);
    paint_grid(&together.sess, tiered(.green));
    together.sess.field.reservoir = .{};
    aim_at(&together.sess, together.p[0].pid, 2, 5);
    aim_at(&together.sess, together.p[1].pid, 2, 5);
    try enqueue_cast_as(&together.sess, together.p[0].pid, POKE);
    try enqueue_cast_as(&together.sess, together.p[1].pid, POKE);
    try flush(&together.sess);

    // The diamond covers both poke cells, so 13 cells end defused.
    try std.testing.expectEqual(@as(u16, 13), count_defused(&together.sess));
    try std.testing.expectEqual(@as(u16, 1), together.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    // Both pokes ALSO fired as themselves: in realtime a contribution lands
    // when it is pressed, and the group is the upgrade on top.
    try std.testing.expectEqual(@as(u16, 2), together.sess.stats.player_recipe_hits[POKE]);
    // Consumed contributors leave the window; the completer never enters it.
    try std.testing.expectEqual(@as(usize, 0), together.sess.recent_count);

    // Alone: nothing to group with, so a poke is just a poke.
    var alone: TwoPlayerSession = undefined;
    try init_two_player_session(&alone, allocator);
    defer alone.deinit();
    try start(&alone, &enc_fifty_green);
    paint_grid(&alone.sess, tiered(.green));
    alone.sess.field.reservoir = .{};
    try enqueue_cast_as(&alone.sess, alone.p[0].pid, POKE);
    try flush(&alone.sess);

    try std.testing.expectEqual(@as(u16, 1), count_defused(&alone.sess));
    try std.testing.expectEqual(@as(u16, 0), alone.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(u16, 1), alone.sess.stats.player_recipe_hits[POKE]);
    // ...and it WAITS in the window for a partner who may yet come.
    try std.testing.expectEqual(@as(usize, 1), alone.sess.recent_count);
}

test "a contribution waits across drains for a partner to join it" {
    // A group is not a same-tick coincidence: the window holds a landed cast
    // for team_window_ms, so the two presses may arrive in separate drains.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    // Landed AND remembered: the poke defused its cell the moment it was
    // pressed, and sits in the window as a group component.
    try std.testing.expectEqual(@as(usize, 1), s.sess.recent_count);
    try std.testing.expectEqual(@as(u16, 1), count_defused(&s.sess));

    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 13), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
}

test "a contribution expires out of the window: yesterday cannot be joined" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(usize, 1), s.sess.recent_count);

    // The window is 500ms deep; 600ms later the poke has expired (and the
    // tick's prune has already swept it).  Under the two-player bite
    // interval of 869ms, no bite interferes.
    try advance(&s.sess, WINDOW_MS + 100);
    try std.testing.expectEqual(@as(usize, 0), s.sess.recent_count);
    try std.testing.expectEqual(@as(u16, 1), s.sess.bite);

    // The would-be partner is 100ms too late: two pokes, no diamond.
    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.player_recipe_hits[POKE]);
}

test "a group's components are consumed, so a third poke starts a fresh bag" {
    // Four pokes on one square are two twin_blooms, not one group and two
    // spares: each completion empties the window of what it used, and the
    // next pair fills a fresh bag.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    aim_at(&s.sess, s.p[1].pid, 2, 5);
    // Pair one: p0 contributes, p1 completes — the window empties with the
    // group.
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(usize, 0), s.sess.recent_count);

    // Pair two, same square, same instant (cooldowns forgiven): a SECOND
    // bag fills from scratch — nothing of the first group lingered to make
    // this a three-poke miscount.
    clear_cooldowns(&s.sess);
    try enqueue_cast(&s.sess, s.p[0].pid);
    try enqueue_cast(&s.sess, s.p[1].pid);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(u16, 4), s.sess.stats.player_recipe_hits[POKE]);
    try std.testing.expectEqual(@as(usize, 0), s.sess.recent_count);
}

test "contributions on different squares never group" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // A group is agreed on by AIM: the whole coordination problem is pointing
    // at the same cell, so two pokes one cell apart are simply two pokes.
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    aim_at(&s.sess, s.p[1].pid, 2, 6);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 2), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
}

test "the group shape is anchored at the completing player's cursor" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // Same square, reached from both sides: p1 casts second, so p1 completes
    // the group.  (The square is what matches; the anchor is where the group
    // lands, and they are the same cell by construction.)
    aim_at(&s.sess, s.p[0].pid, 3, 7);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    aim_at(&s.sess, s.p[1].pid, 3, 7);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(u16, 13), count_defused(&s.sess));
    // The diamond's tip is two rows above the anchor.
    try std.testing.expect(s.sess.field.grid.at(1, 7) == .neutralized);
    // ...and the row above THAT is untouched: the shape is placed, not smeared.
    try std.testing.expect(s.sess.field.grid.at(0, 7) == .tiered);
}

test "one player casting twice never forms a group with themselves" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // A group is a COOPERATION: it needs distinct players, or a solo player
    // would simply buy the big shape by pressing twice.  Both pokes sit in
    // the window together (cooldown forgiven between them), and still
    // nothing fires.
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    clear_cooldowns(&s.sess);
    try enqueue_cast(&s.sess, s.p[0].pid);
    try flush(&s.sess);

    // Two pokes on one cell: the cell is defused once and nothing more.
    try std.testing.expectEqual(@as(u16, 1), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.player_recipe_hits[POKE]);
    try std.testing.expectEqual(@as(usize, 2), s.sess.recent_count);
}

test "an asymmetric group fires from either side" {
    // crossfire is sweep + block, so it must not matter who brings which.
    const allocator = std.testing.allocator;

    for ([_][2]u8{ .{ SWEEP, BLOCK }, .{ BLOCK, SWEEP } }) |order| {
        var s: TwoPlayerSession = undefined;
        try init_two_player_session(&s, allocator);
        defer s.deinit();
        try start(&s, &enc_fifty_green);
        paint_grid(&s.sess, tiered(.green));
        s.sess.field.reservoir = .{};

        aim_at(&s.sess, s.p[0].pid, 2, 5);
        aim_at(&s.sess, s.p[1].pid, 2, 5);
        try enqueue_cast_as(&s.sess, s.p[0].pid, order[0]);
        try enqueue_cast_as(&s.sess, s.p[1].pid, order[1]);
        try flush(&s.sess);

        try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[CROSSFIRE]);
    }
}

test "the window is measured in TIME, so a group can straddle a bite" {
    // The old turn loop cleared its pending list at every settle; the window
    // is a clock, not a turn artifact, so a bite between two contributions
    // changes nothing — only the 500ms do.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, .empty); // nothing to eat, so the game cannot end here
    s.sess.field.reservoir = .{ .neutral = 5 };

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(usize, 1), s.sess.recent_count);

    // The Lil Guys bite between the two presses (no clock walked: the
    // window's age is still zero).
    try settle_idly(&s.sess);
    try std.testing.expectEqual(@as(u16, 2), s.sess.bite);
    try std.testing.expectEqual(@as(usize, 1), s.sess.recent_count);

    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
}

test "a lone contribution fires as its own move and is never refunded" {
    // A partnerless contribution is not a failure: it landed as the move the
    // player actually chose, at that move's price, the moment it was
    // pressed.  Its expiry from the window gives nothing back, because
    // nothing went wrong.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{ .neutral = 5 };

    const pid = s.p[0].pid;
    const before = s.sess.charges;
    try enqueue_cast_as(&s.sess, pid, POKE);
    try flush(&s.sess);
    // Priced and paid the moment it fired.
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.player_recipe_hits[POKE]);
    try std.testing.expectEqual(before - BAL.player_recipes[POKE].cost, s.sess.charges);

    // The whole window expires with no partner having come: the charge
    // stays spent.
    try advance(&s.sess, WINDOW_MS + 100);
    try std.testing.expectEqual(@as(usize, 0), s.sess.recent_count);
    try std.testing.expectEqual(before - BAL.player_recipes[POKE].cost, s.sess.charges);
}

// ---------------------------------------------------------------------------
// Aiming (the cursor)
// ---------------------------------------------------------------------------

test "the cursor starts at the middle of the field for every player" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);

    const grid = &s.sess.field.grid;
    for ([_]u8{ s.p[0].pid, s.p[1].pid }) |pid| {
        try std.testing.expectEqual(@as(u8, 3), grid.row_of(s.sess.cursors[pid]));
        try std.testing.expectEqual(@as(u8, 5), grid.col_of(s.sess.cursors[pid]));
    }
}

test "move_cursor steps one cell per message and clamps at the edges" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    const pid = s.p[0].pid;
    const grid = &s.sess.field.grid;

    try enqueue_msg(&s.sess, pid, .move_cursor, proto.MoveCursor{ .dir = .up });
    try enqueue_msg(&s.sess, pid, .move_cursor, proto.MoveCursor{ .dir = .left });
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u8, 2), grid.row_of(s.sess.cursors[pid]));
    try std.testing.expectEqual(@as(u8, 4), grid.col_of(s.sess.cursors[pid]));

    // Walk hard into the top-left corner: clamping parks the cursor rather
    // than wrapping (which would make the d-pad unusable).
    for (0..20) |_| {
        try enqueue_msg(&s.sess, pid, .move_cursor, proto.MoveCursor{ .dir = .up });
        try enqueue_msg(&s.sess, pid, .move_cursor, proto.MoveCursor{ .dir = .left });
    }
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 0), s.sess.cursors[pid]);

    // And into the opposite corner.
    for (0..20) |_| {
        try enqueue_msg(&s.sess, pid, .move_cursor, proto.MoveCursor{ .dir = .down });
        try enqueue_msg(&s.sess, pid, .move_cursor, proto.MoveCursor{ .dir = .right });
    }
    try flush(&s.sess);
    try std.testing.expectEqual(grid.len() - 1, s.sess.cursors[pid]);
}

test "each player aims their own cursor independently" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);

    const before = s.sess.cursors[s.p[1].pid];
    try enqueue_msg(&s.sess, s.p[0].pid, .move_cursor, proto.MoveCursor{ .dir = .right });
    try flush(&s.sess);

    try std.testing.expect(s.sess.cursors[s.p[0].pid] != before);
    try std.testing.expectEqual(before, s.sess.cursors[s.p[1].pid]);
}

test "a contribution keeps the square it was cast on when its caster re-aims" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // p0 pokes low-right, then wanders to the corner.  The cast is logged
    // against the square it was AIMED at, not against p0's live cursor, or a
    // player could drag their contribution around after paying for it.
    aim_at(&s.sess, s.p[0].pid, 4, 8);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    aim_at(&s.sess, s.p[0].pid, 0, 0);

    // p1 pokes where p0's contribution actually sits, and the group forms
    // there.
    aim_at(&s.sess, s.p[1].pid, 4, 8);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    // The diamond is centred on the shared square...
    try std.testing.expect(s.sess.field.grid.at(4, 8) == .neutralized);
    try std.testing.expect(s.sess.field.grid.at(2, 8) == .neutralized);
    // ...and nothing followed p0 to the corner.
    try std.testing.expect(s.sess.field.grid.at(0, 0) == .tiered);
}

test "chasing a partner's stale cursor does not form a group" {
    // The other half of the rule above: aim is matched against where a
    // contribution WAS CAST, so pointing at where a teammate has since moved TO
    // is not agreement.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    aim_at(&s.sess, s.p[0].pid, 4, 8);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    aim_at(&s.sess, s.p[0].pid, 1, 1);

    aim_at(&s.sess, s.p[1].pid, 1, 1);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(u16, 2), count_defused(&s.sess));
}

// ---------------------------------------------------------------------------
// The settle: the column bite, the leftward shift, and the refill
//
// The Lil Guys stand at the LEFT edge and bite the front `feast_width`
// columns cell by cell: edible units (neutral / defused / consumable
// specials) are consumed, live hazards are NIBBLED one tier softer (hunger,
// no score), rocks are skipped.  Survivors then pack LEFT along their row,
// and only then does the reservoir refill the columns that opened up on the
// right.  The fixture width is 1 column; tests about "the whole field is
// eaten" run on WholeBite, whose bite spans the grid.
//
// Nothing here depends on elapsed time — `settle_idly` runs one settle
// through the public seam without walking the clock.
// ---------------------------------------------------------------------------

test "an edible field is eaten whole and refilled from the reservoir" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(0).cfg);
    defer s.deinit();
    // 80 NEUTRAL units under a whole-board bite: everything on-grid goes.
    const enc_all_neutral = enc.Encounter{
        .label = "test_all_neutral",
        .slime = .{ .neutral = 80 },
    };
    try start(&s, &enc_all_neutral); // 60 on-grid, 20 waiting

    try settle_idly(&s.sess);

    // All 60 on-grid units are gone, and the 20 reserves have taken the field.
    try std.testing.expectEqual(@as(u32, 20), s.sess.field.remaining());
    try std.testing.expectEqual(@as(u16, 20), s.sess.field.grid.occupied());
    try std.testing.expect(s.sess.field.reservoir.is_empty());
    try std.testing.expectEqual(@as(u16, 2), s.sess.bite);
}

test "the bite takes only the front columns; the rest of the field waits" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator); // fixture width: 1 column
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    paint_grid(&s.sess, .neutral);
    s.sess.field.reservoir = .{};

    try settle_idly(&s.sess);

    // One 6-cell column eaten; the shift then walks every row one step left
    // and nothing refills (the reservoir is dry), so the RIGHT column opens.
    try std.testing.expectEqual(@as(u32, 6), s.sess.score);
    try std.testing.expectEqual(@as(u16, 54), s.sess.field.grid.occupied());
    const grid = &s.sess.field.grid;
    var row: u8 = 0;
    while (row < grid.rows) : (row += 1) {
        try std.testing.expect(grid.at(row, 0).is_slime());
        try std.testing.expect(!grid.at(row, grid.cols - 1).is_slime());
    }
}

test "refills enter from the right edge" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only); // 40 neutral, all edible
    // Clear the board so the refill has the whole grid to itself and the test
    // is not reading survivors the shift moved.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{ .neutral = 20 };

    try settle_idly(&s.sess);

    // 20 units into a 6-row grid: the rightmost three columns fill whole,
    // the fourth-from-right takes the remaining two, and the front stays
    // open — new slime enters at the far end of the conveyor.
    const grid = &s.sess.field.grid;
    const last = grid.cols - 1;
    var row: u8 = 0;
    while (row < grid.rows) : (row += 1) {
        try std.testing.expect(grid.at(row, last).is_slime());
        try std.testing.expect(grid.at(row, last - 1).is_slime());
        try std.testing.expect(grid.at(row, last - 2).is_slime());
        try std.testing.expect(!grid.at(row, 0).is_slime());
    }
    try std.testing.expect(grid.at(0, last - 3).is_slime());
    try std.testing.expect(grid.at(1, last - 3).is_slime());
    try std.testing.expect(!grid.at(2, last - 3).is_slime());
}

test "a live hazard is nibbled, never consumed: hunger for no score" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(0).cfg);
    defer s.deinit();
    try start(&s, &enc_twenty_green);

    // A field of live green under a whole-board bite: every unit is nibbled
    // — 20 hunger, zero score — and every green steps to defused in place.
    set_field(&s.sess, tiered(.green), 20);
    try settle_mid_game(&s.sess);

    try std.testing.expectEqual(
        @as(u16, @intCast(20 * BAL.hunger_cost_normal)),
        s.sess.hunger.current,
    );
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    try std.testing.expectEqual(@as(u32, 20), s.sess.stats.feast.hazards_bitten);
    try std.testing.expectEqual(@as(u16, 0), s.sess.field.grid.hazard_count());

    // Defused (by the nibbles or by casts), the same field is 20 units of
    // dinner — consumed AND scored this time.
    set_field(&s.sess, .neutralized, 20);
    try settle_mid_game(&s.sess);

    try std.testing.expectEqual(
        @as(u16, @intCast(40 * BAL.hunger_cost_normal)),
        s.sess.hunger.current,
    );
    try std.testing.expectEqual(@as(u32, 20), s.sess.score);
    try std.testing.expectEqual(@as(u16, 20), s.sess.stats.feast.defused_consumed);
}

test "a hot front is nibbled this turn and eaten the next" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator); // fixture width: 1 column
    defer s.deinit();
    try start(&s, &enc_twenty_green);

    // Column 0 is a solid green wall; columns 1..9 are neutral food.
    //
    //   col:  0  1  2 ... 9
    //         G  n  n ... n     (every row)
    paint_grid(&s.sess, .neutral);
    s.sess.field.reservoir = .{};
    const grid = &s.sess.field.grid;
    var row: u8 = 0;
    while (row < grid.rows) : (row += 1) grid.set(row, 0, tiered(.green));

    try settle_idly(&s.sess);
    // Six nibbles: the greens step to defused in place, fill the hunger
    // clock, and score nothing.  Nothing behind them is touched.
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    try std.testing.expectEqual(@as(u32, 6), s.sess.stats.feast.hazards_bitten);
    try std.testing.expectEqual(@as(u16, 0), s.sess.field.grid.hazard_count());
    try std.testing.expectEqual(
        @as(u16, @intCast(6 * BAL.hunger_cost_normal)),
        s.sess.hunger.current,
    );

    // The next bite finds the front defused and CONSUMES it.
    try settle_idly(&s.sess);
    try std.testing.expectEqual(@as(u32, 6), s.sess.score);
    try std.testing.expectEqual(@as(u16, 6), s.sess.stats.feast.defused_consumed);
}

test "one bite can mix every cell kind, pricing each on its own terms" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(0).cfg);
    defer s.deinit();
    try start(&s, &enc_twenty_red);

    // Row 0 of the 6x10 grid, left to right:
    //   n  n  .  .  .  x  x  .  .  .      (n neutral, x defused, . empty)
    // plus a red at (4,9), a green at (5,8) and a neutral at (5,9).  The
    // whole-board bite visits every cell: food is consumed, hazards are
    // nibbled where they stand.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{};
    const grid = &s.sess.field.grid;
    grid.set(0, 0, .neutral);
    grid.set(0, 1, .neutral);
    grid.set(0, 5, .neutralized);
    grid.set(0, 6, .neutralized);
    grid.set(4, 9, tiered(.red));
    grid.set(5, 8, tiered(.green));
    grid.set(5, 9, .neutral);

    try settle_idly(&s.sess);

    // Consumed: 3 neutral + 2 defused, one score each.  Nibbled: the red
    // (to yellow) and the green (to defused) — hunger, no score.
    try std.testing.expectEqual(
        @as(u16, @intCast(7 * BAL.hunger_cost_normal)),
        s.sess.hunger.current,
    );
    try std.testing.expectEqual(@as(u32, 5), s.sess.score);
    try std.testing.expectEqual(@as(u16, 3), s.sess.stats.feast.neutral_consumed);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.feast.defused_consumed);
    try std.testing.expectEqual(@as(u32, 2), s.sess.stats.feast.hazards_bitten);
    // The red survives one tier softer; the green went all the way to
    // defused, so it is no longer a hazard — but it IS still on the board.
    try std.testing.expectEqual(@as(u16, 1), s.sess.field.grid.hazard_count());
    try std.testing.expect(!s.sess.field.is_exhausted());
}

test "survivors pack left along their row after the bite" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);

    // Two hazards deep in row 1 and row 2; column 0 is empty, so the bite
    // gets nothing and the shift is the whole story.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{};
    const grid = &s.sess.field.grid;
    grid.set(1, 3, tiered(.green));
    grid.set(1, 5, tiered(.red));
    grid.set(2, 7, tiered(.red));

    try settle_idly(&s.sess);

    // Each row packed against the left edge, order preserved, no lane change.
    try std.testing.expectEqual(c.SlimeCell{ .tiered = .green }, grid.at(1, 0));
    try std.testing.expectEqual(c.SlimeCell{ .tiered = .red }, grid.at(1, 1));
    try std.testing.expectEqual(c.SlimeCell{ .tiered = .red }, grid.at(2, 0));
    try std.testing.expectEqual(c.SlimeCell.empty, grid.at(1, 3));
    try std.testing.expectEqual(c.SlimeCell.empty, grid.at(1, 5));
    try std.testing.expectEqual(c.SlimeCell.empty, grid.at(2, 7));
}

test "neutral slime is the only thing on the field that needs no work" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(0).cfg);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    set_field(&s.sess, .neutral, 10);

    try settle_idly(&s.sess);
    try std.testing.expectEqual(@as(u32, 10), s.sess.score);
    try std.testing.expectEqual(@as(u16, 10), s.sess.stats.feast.neutral_consumed);
    try std.testing.expectEqual(@as(u32, 0), s.sess.stats.feast.hazards_bitten);
}

test "a stamp destroys nothing: it converts a nibble into a meal" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(0).cfg);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    // A 3x3 patch of green anchored on column 1.
    set_block_field(&s.sess, tiered(.green), 2, 1);

    aim_at(&s.sess, s.p[0].pid, 2, 1);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);
    // The stamp defused all 9 and removed none.
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 9), s.sess.field.grid.occupied());

    try settle_idly(&s.sess);

    // Defusal is what makes a unit SCORE at all: 9 eaten, 9 scored, and not
    // one nibble wasted.
    try std.testing.expectEqual(@as(u32, 9), s.sess.score);
    try std.testing.expectEqual(@as(u32, 0), s.sess.stats.feast.hazards_bitten);
    try std.testing.expectEqual(
        @as(u16, @intCast(9 * BAL.hunger_cost_normal)),
        s.sess.hunger.current,
    );
}

test "bite_settled reports the feast the clients must animate" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator); // fixture width: 1 column
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    // Column 0: one neutral and one green.  Reserves keep the game alive
    // past the turn.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{ .neutral = 3 };
    const grid = &s.sess.field.grid;
    grid.set(0, 0, .neutral);
    grid.set(1, 0, tiered(.green));

    const charges_before = s.sess.charges;
    s.p[1].clear();
    try settle_idly(&s.sess);

    const msgs = try drain(s.p[1].buf.items, arena);
    const te_msg = find_tag(msgs, .bite_settled) orelse return error.NoTurnEnded;
    var fbs = std.io.fixedBufferStream(te_msg.payload);
    const te = try proto.decode_bite_settled(fbs.reader());

    try std.testing.expectEqual(@as(u16, 1), te.bite);
    try std.testing.expectEqual(@as(u16, 1), te.cells_eaten);
    // One consume plus one nibble: both fill the clock.
    try std.testing.expectEqual(
        @as(u16, @intCast(2 * BAL.hunger_cost_normal)),
        te.hunger_added,
    );
    // The number the next turn is planned around: hunger spent on a cell no
    // cast defused in time.
    try std.testing.expectEqual(@as(u16, 1), te.hazards_bitten);
    try std.testing.expectEqual(@as(u32, 1), te.score_added);
    // The broadcast agrees with the session it describes.
    try std.testing.expectEqual(te.hunger_added, s.sess.hunger.current);
    try std.testing.expectEqual(te.score_added, s.sess.score);
    try std.testing.expectEqual(charges_before, te.charges_left);
}

test "a swallowed canister refills the team's charge pool at turn end" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);

    // A canister in the bitten column, with reserves so the game outlives
    // the turn.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{ .neutral = 3 };
    const grid = &s.sess.field.grid;
    grid.set(0, 0, .neutral);
    grid.set(1, 0, .{ .special = .canister });

    const charges_before = s.sess.charges;
    try settle_idly(&s.sess);

    // Free equipment: the canister is eaten (no score beyond the neutral's)
    // and its agent energy lands back in the pool.
    const refill = BAL.special_tuning(.canister).charge_refill;
    try std.testing.expectEqual(charges_before + refill, s.sess.charges);
    try std.testing.expectEqual(@as(u32, 1), s.sess.score);
}

test "a turn with no slime on the field is a free turn" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{ .neutral = 4 };

    try settle_idly(&s.sess);

    // Nothing was there to eat, so nothing was charged — and the reserves
    // arrive for the next turn.
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    try std.testing.expectEqual(@as(u16, 4), s.sess.field.grid.occupied());
    try std.testing.expectEqual(@as(u16, 2), s.sess.bite);
}

test "eating an egg hatches a baby: capacity grows, the brood is tallied and announced" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    // One egg and one neutral in the bitten column; reserves keep the game
    // alive.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{ .neutral = 3 };
    const grid = &s.sess.field.grid;
    grid.set(0, 0, .{ .special = .egg });
    grid.set(1, 0, .neutral);
    const egg_cell = grid.index(0, 0);
    const max_before = s.sess.hunger.max;

    s.p[1].clear();
    try settle_idly(&s.sess);

    // The egg was ordinary food (flat rate, ordinary score) plus a hatch.
    try std.testing.expectEqual(
        @as(u16, @intCast(2 * BAL.hunger_cost_normal)),
        s.sess.hunger.current,
    );
    try std.testing.expectEqual(@as(u32, 2), s.sess.score);
    // The baby joined the feast that freed it: the bar grew by baby_hunger,
    // and the brood is tallied for the game_over banking.
    try std.testing.expectEqual(max_before + BAL.baby_hunger, s.sess.hunger.max);
    var brood: u32 = 0;
    for (s.sess.hatched) |n| brood += n;
    try std.testing.expectEqual(@as(u32, 1), brood);
    var banked: u32 = 0;
    for (s.sess.stats.eggs_hatched) |n| banked += n;
    try std.testing.expectEqual(@as(u32, 1), banked);

    // The hatch was announced — cell and rolled type — BEFORE the turn
    // summary, so clients animate it on the board bite_settled describes.
    const msgs = try drain(s.p[1].buf.items, arena);
    var hatch_at: ?usize = null;
    var turn_at: ?usize = null;
    for (msgs, 0..) |m, i| {
        if (m.tag == .eggs_hatched and hatch_at == null) hatch_at = i;
        if (m.tag == .bite_settled and turn_at == null) turn_at = i;
    }
    const hi = hatch_at orelse return error.NoEggsHatched;
    const ti_ = turn_at orelse return error.NoTurnEnded;
    try std.testing.expect(hi < ti_);
    var fbs = std.io.fixedBufferStream(msgs[hi].payload);
    const eh = try proto.decode_eggs_hatched(fbs.reader());
    try std.testing.expectEqual(@as(u16, 1), eh.count);
    try std.testing.expectEqual(egg_cell, eh.cells[0]);
    try std.testing.expectEqual(@as(u32, 1), s.sess.hatched[@intFromEnum(eh.types[0])]);

    // The next game_state carries the brood, so a reconnect recovers it.
    const gs_msg = find_tag(msgs, .game_state) orelse return error.NoGameState;
    var gs_fbs = std.io.fixedBufferStream(gs_msg.payload);
    const gs = try proto.decode_game_state(gs_fbs.reader());
    try std.testing.expectEqual(s.sess.hatched, gs.hatched);
}

test "eaten neutralizers fire 3x3 Agent blocks and are FREE food" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    // Column 0: three neutralizers spaced two rows apart, so their 3x3
    // blocks never overlap on the red parked one column deep at (0,1).  The
    // bite swallows all three for FREE; only the first one's block reaches
    // the red, stepping it exactly one tier.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{};
    const grid = &s.sess.field.grid;
    grid.set(0, 0, .{ .special = .neutralizer });
    grid.set(2, 0, .{ .special = .neutralizer });
    grid.set(4, 0, .{ .special = .neutralizer });
    grid.set(0, 1, tiered(.red));

    s.p[0].clear();
    try settle_idly(&s.sess);

    // All three swallowed; the yellow (one column deep, out of the bite and
    // shifted to the front by the settle) is the only survivor.
    try std.testing.expectEqual(tiered(.yellow), grid.at(0, 0));
    try std.testing.expectEqual(@as(u16, 0), grid.special_count());
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);

    const msgs = try drain(s.p[0].buf.items, arena);
    // Match machinery is DORMANT: nothing lined-up fires, so no
    // special_matched ever leaves the server.
    try std.testing.expectEqual(@as(?Msg, null), find_tag(msgs, .special_matched));
    const te_msg = find_tag(msgs, .bite_settled) orelse return error.NoTurnEnded;
    var fbs = std.io.fixedBufferStream(te_msg.payload);
    const te = try proto.decode_bite_settled(fbs.reader());
    try std.testing.expectEqual(@as(u16, 3), te.cells_eaten);
    try std.testing.expectEqual(@as(u32, 0), te.score_added);
    try std.testing.expectEqual(@as(u16, 0), te.hunger_added);
    try std.testing.expectEqual(@as(u8, 1), te.passes);
}

test "a swallowed neutralizer defuses a cell later in the SAME bite, which is consumed" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{};
    const grid = &s.sess.field.grid;
    // Column 0, top-down: neutralizer, green, neutral.  The bite walks
    // top-down, so the neutralizer's 3x3 defuses the green BEFORE the walk
    // reaches it — the same bite then consumes it whole instead of nibbling.
    grid.set(0, 0, .{ .special = .neutralizer });
    grid.set(1, 0, tiered(.green));
    grid.set(2, 0, .neutral);

    s.p[0].clear();
    try settle_idly(&s.sess);

    // One pass, one continuous bite: the neutralizer (free), the defused
    // green, and the neutral — the column empties, nothing was nibbled.
    try std.testing.expectEqual(SC(.empty), grid.at(0, 0));
    try std.testing.expectEqual(SC(.empty), grid.at(1, 0));
    try std.testing.expectEqual(SC(.empty), grid.at(2, 0));
    try std.testing.expectEqual(@as(u32, 2), s.sess.score); // defused + neutral
    try std.testing.expectEqual(@as(u32, 0), s.sess.stats.feast.hazards_bitten);

    const msgs = try drain(s.p[0].buf.items, arena);
    const te_msg = find_tag(msgs, .bite_settled) orelse return error.NoTurnEnded;
    var fbs = std.io.fixedBufferStream(te_msg.payload);
    const te = try proto.decode_bite_settled(fbs.reader());
    // Three cells left the board in ONE pass — the continuation is inline,
    // not a cascade of settle passes.
    try std.testing.expectEqual(@as(u16, 3), te.cells_eaten);
    try std.testing.expectEqual(@as(u8, 1), te.passes);
    try std.testing.expectEqual(@as(u16, 0), te.hazards_bitten);
}

test "a refilled line of neutralizers stays put: matches are dormant" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    paint_grid(&s.sess, .empty);
    const grid = &s.sess.field.grid;
    const bottom = grid.rows - 1;
    // A red on the floor keeps the encounter alive; the reservoir holds
    // EXACTLY three neutralizers, so the right-to-left refill lands them
    // down the RIGHTMOST column — a vertical line the moment they arrive.
    // Nothing fires: match machinery is dormant, and refills are never
    // eaten same-turn.
    grid.set(bottom, 0, tiered(.red));
    s.sess.field.reservoir = .{};
    s.sess.field.reservoir.special[@intFromEnum(c.SpecialKind.neutralizer)] = 3;

    s.p[0].clear();
    try settle_idly(&s.sess);

    const last = grid.cols - 1;
    try std.testing.expectEqual(SC(.{ .special = .neutralizer }), grid.at(0, last));
    try std.testing.expectEqual(SC(.{ .special = .neutralizer }), grid.at(1, last));
    try std.testing.expectEqual(SC(.{ .special = .neutralizer }), grid.at(2, last));
    try std.testing.expectEqual(@as(u16, 3), grid.special_count());

    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expectEqual(@as(?Msg, null), find_tag(msgs, .special_matched));
    const fr_msg = find_tag(msgs, .field_refilled) orelse return error.NoRefill;
    var fbs = std.io.fixedBufferStream(fr_msg.payload);
    const fr = try proto.decode_field_refilled(fbs.reader());
    try std.testing.expectEqual(@as(u8, 0), fr.pass);
    try std.testing.expectEqual(@as(u16, 3), fr.count);
    try std.testing.expectEqualSlices(u16, &[_]u16{
        grid.index(0, last), grid.index(1, last), grid.index(2, last),
    }, fr.cells[0..3]);
    for (fr.contents[0..3]) |cell| {
        try std.testing.expectEqual(SC(.{ .special = .neutralizer }), cell);
    }

    const te_msg = find_tag(msgs, .bite_settled) orelse return error.NoTurnEnded;
    var tfbs = std.io.fixedBufferStream(te_msg.payload);
    const te = try proto.decode_bite_settled(tfbs.reader());
    try std.testing.expectEqual(@as(u8, 1), te.passes);
    try std.testing.expectEqual(@as(u16, 0), te.cells_eaten);
}

test "a board's babies join the bar with their owner and leave with them" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, DEFAULT_ENC);
    const max_before = s.sess.hunger.max;

    // A third player sits down with a board carrying 3 babies: their share is
    // the appetite formula plus baby_hunger per baby.
    var extra = TestPlayer{};
    extra.init(allocator);
    defer extra.deinit(allocator);
    const conn_id = s.sess.connect(extra.transport()) orelse return error.JoinFailed;
    try s.sess.take_slot(conn_id, .{ .appetite = 2, .babies = .{ 1, 0, 2, 0, 0 } });

    const share = logic.player_hunger(BAL, 2, 3);
    try std.testing.expectEqual(max_before + share, s.sess.hunger.max);
    try std.testing.expectEqual(
        share,
        logic.player_hunger(BAL, 2, 0) + 3 * BAL.baby_hunger,
    );

    // The babies travel in game_state with their owner...
    try s.sess.tick(1.0 / 60.0);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const msgs = try drain(extra.buf.items, arena_state.allocator());
    const gs_msg = find_tag(msgs, .game_state) orelse return error.NoGameState;
    var fbs = std.io.fixedBufferStream(gs_msg.payload);
    const gs = try proto.decode_game_state(fbs.reader());
    const pid = s.sess.connections[conn_id].player_id orelse return error.JoinFailed;
    const snap = for (gs.entities[0..gs.entity_count]) |e| {
        if (e.owner == pid) break e;
    } else return error.NoSnapshot;
    try std.testing.expectEqual([_]u32{ 1, 0, 2, 0, 0 }, snap.babies);

    // ...and leave with him: the unused share (untouched bar) comes back off.
    s.sess.disconnect(conn_id);
    try std.testing.expectEqual(max_before, s.sess.hunger.max);
}

// ---------------------------------------------------------------------------
// Casting: the cooldown
//
// Fixture balance: cast_cooldown_ms = 100 per PLAYER.  A cast resolves the
// moment it is pressed — priced, debited and stamped in one drain — and
// starts the caster's cooldown; a press inside the cooldown is silently
// dropped and does NOT restart it.  A refused (over_budget) cast starts no
// cooldown either.  cancel_cast is retired: nothing is ever pending, so
// there is nothing an undo could take back.
// ---------------------------------------------------------------------------

test "a cast lands the moment it is pressed" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    s.p[1].clear();
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);

    // Pressed IS cast: the 3x3 block is on the grid in the same drain, the
    // charge is out of the pool, and the caster's cooldown is running.
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].casts);
    try std.testing.expectEqual(
        @as(u64, s.sess.now_ms() + COOLDOWN_MS),
        s.sess.cooldown_until[s.p[0].pid],
    );

    const msgs = try drain(s.p[1].buf.items, arena);
    // One shape_cast, sent when the stamp happened — which is immediately.
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .shape_cast));
    var cast_count: usize = 0;
    for (msgs) |m| {
        if (m.tag != .action_result) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const ar = try proto.decode_action_result(fbs.reader());
        if (ar.tag == .cast) {
            cast_count += 1;
            try std.testing.expectEqual(s.sess.players[s.p[0].pid].entity, ar.actor_entity);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), cast_count);
}

test "a press inside the cooldown is silently dropped and restarts nothing" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_red);
    // Red needs three stamps to defuse, so the cell records exactly how many
    // presses actually landed.
    paint_grid(&s.sess, tiered(.red));
    s.sess.field.reservoir = .{};
    const pid = s.p[0].pid;
    const pool_before = s.sess.charges;
    aim_at(&s.sess, pid, 3, 4);

    // Three presses in one drain, all at the same instant: the first lands
    // (red -> yellow) and starts the cooldown; the other two are dropped —
    // no debit, no stamp, no wire noise, and NOT a refusal.
    s.p[1].clear();
    try enqueue_cast_as(&s.sess, pid, POKE);
    try enqueue_cast(&s.sess, pid);
    try enqueue_cast(&s.sess, pid);
    try flush(&s.sess);

    try std.testing.expectEqual(c.Tier.yellow, s.sess.field.grid.at(3, 4).tiered);
    try std.testing.expectEqual(pool_before - BAL.player_recipes[POKE].cost, s.sess.charges);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[pid].casts);
    const msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .shape_cast));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .over_budget));
    // The dropped presses did not RESTART the clock: the cooldown still ends
    // exactly one COOLDOWN_MS after the press that landed.
    try std.testing.expectEqual(
        @as(u64, s.sess.now_ms() + COOLDOWN_MS),
        s.sess.cooldown_until[pid],
    );

    // Once the cooldown passes, the next press lands (yellow -> green).
    try advance(&s.sess, COOLDOWN_MS);
    aim_at(&s.sess, pid, 3, 4);
    try enqueue_cast(&s.sess, pid);
    try flush(&s.sess);
    try std.testing.expectEqual(c.Tier.green, s.sess.field.grid.at(3, 4).tiered);
}

test "cooldowns are per player: the whole team may cast in one instant" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // Both players press at the same instant, at different squares: one
    // player's cooldown is nobody else's.
    aim_at(&s.sess, s.p[0].pid, 1, 2);
    aim_at(&s.sess, s.p[1].pid, 4, 7);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 2), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].casts);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[1].pid].casts);
}

test "a cast the pool cannot pay for costs nothing, not even time" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // An unaffordable choice is refused whole: no stamp, no debit, and no
    // cooldown — the player simply has not cast yet.
    s.sess.charges = 0;
    s.p[1].clear();
    try enqueue_cast_as(&s.sess, s.p[0].pid, DELUGE);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u64, 0), s.sess.cooldown_until[s.p[0].pid]);
    try std.testing.expectEqual(@as(usize, 0), s.sess.recent_count);

    var msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .shape_cast));

    // The FREE move still works with the pool at zero — in the very same
    // instant, because the refusal started no cooldown: the economy has a
    // floor a team can never fall through.
    s.p[1].clear();
    try enqueue_cast_as(&s.sess, s.p[0].pid, TRICKLE);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 1), count_defused(&s.sess));
    msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .shape_cast));
}

test "a completing cast broadcasts its own stamp and then the group's" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    // The whole grid, so the 5x5 diamond has a hazard under every cell.
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);

    s.p[1].clear();
    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    // The diamond covers the poke cells: 13 defused in all.
    try std.testing.expectEqual(@as(u16, 13), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expect(!s.sess.restart_pending);

    // Each player pressed once; the completer's press counts twice in
    // recipe participation (their poke AND the group it finished).
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].casts);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[1].pid].casts);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.casts_total);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.players[s.p[1].pid].recipe_casts);

    // The completing drain broadcasts TWO stamps — p1's own poke, then the
    // group shape OVER it (the upgrade is the headline) — and announces the
    // poke as a player fire and the diamond as a team fire.
    const msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 2), count_tag(msgs, .shape_cast));
    var player_fires: usize = 0;
    var team_fires: usize = 0;
    for (msgs) |m| {
        if (m.tag != .recipe_fired) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const rf = try proto.decode_recipe_fired(fbs.reader());
        switch (rf.kind) {
            .player => {
                try std.testing.expectEqual(POKE, rf.index);
                player_fires += 1;
            },
            .team => {
                try std.testing.expectEqual(TWIN_BLOOM, rf.index);
                team_fires += 1;
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 1), player_fires);
    try std.testing.expectEqual(@as(usize, 1), team_fires);
}

test "a cast that forms no group leaves an unrelated contribution untouched" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // p0 puts a sweep down at one end — a crossfire component, but p1 is about
    // to do something unrelated somewhere else.
    aim_at(&s.sess, s.p[0].pid, 1, 2);
    try enqueue_cast_as(&s.sess, s.p[0].pid, SWEEP);
    try flush(&s.sess);

    aim_at(&s.sess, s.p[1].pid, 4, 8);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    // Both landed as themselves, and BOTH still wait in the window: a
    // square with no full bag on it is just a list of moves.
    try std.testing.expectEqual(@as(usize, 2), s.sess.recent_count);
    try std.testing.expectEqual(@as(u16, 4), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[CROSSFIRE]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.player_recipe_hits[SWEEP]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.player_recipe_hits[POKE]);
}

test "a group the pool cannot afford refuses the cast that would complete it" {
    // There is no fallback: joining a ripe square turns the press into the
    // group, so a group out of reach makes the COMPLETING cast out of reach
    // too.  The player is told; the square stays as it was.
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // Three charges: p0's poke takes one, leaving 2 — poke money, but one
    // short of twin_bloom's 4.
    s.sess.charges = 3;
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 2), s.sess.charges);
    try std.testing.expectEqual(@as(usize, 1), s.sess.recent_count);

    s.p[1].clear();
    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    // Refused at 4-against-2, not quietly downgraded to a second poke — and
    // the ripe contribution is NOT consumed by the attempt.
    try std.testing.expectEqual(@as(usize, 1), s.sess.recent_count);
    const msgs = try drain(s.p[1].buf.items, arena);
    const msg = find_tag(msgs, .over_budget) orelse return error.MissingOverBudget;
    var fbs = std.io.fixedBufferStream(msg.payload);
    const ob = try proto.decode_over_budget(fbs.reader());
    try std.testing.expectEqual(@as(u32, 4), ob.needed);
    try std.testing.expectEqual(@as(u32, 2), ob.have);

    // The same poke one cell over is affordable, because it forms nothing.
    aim_at(&s.sess, s.p[1].pid, 2, 7);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.player_recipe_hits[POKE]);
    try std.testing.expectEqual(@as(u16, 2), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u32, 1), s.sess.charges);
}

test "player recipe fires are broadcast when the cast converts" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    set_field(&s.sess, tiered(.green), 50);

    s.p[1].clear();
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE); // `poke` = player_recipes[0]
    try flush(&s.sess);

    const msgs = try drain(s.p[1].buf.items, arena);
    var player_fires: usize = 0;
    for (msgs) |m| {
        if (m.tag != .recipe_fired) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const rf = try proto.decode_recipe_fired(fbs.reader());
        try std.testing.expectEqual(proto.RecipeKind.player, rf.kind);
        try std.testing.expectEqual(@as(u8, 0), rf.index);
        player_fires += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), player_fires);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.player_recipe_hits[0]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].recipe_casts);
}

// ---------------------------------------------------------------------------
// The shared charge pool
//
// One pool per GAME, seeded from `encounter.charges` and never refilled.  Every
// recipe has a cost, debited the moment the cast lands; a completed team
// recipe bills its completer the GROUP's cost instead of their own.  The
// fixture tables put a 0-cost recipe (`trickle`) and a 9-cost one (`deluge`) at
// the extremes so both "always affordable" and "cannot afford" are reachable.
// ---------------------------------------------------------------------------

/// Encounter with a deliberately tiny pool: enough for one `deluge` (9) and a
/// single charge over, so a second expensive cast must be refused.
const enc_thin_pool = enc.Encounter{
    .label = "test_thin_pool",
    .charges = 10,
    .slime = .{ .tiered = .{ 0, 0, 50 } },
};

test "the pool starts at the seed grown per seat and is not refilled by a bite" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    // The encounter seeds 10; the second seat grows it by its proportion
    // (see logic.grow_charges), so the pair opens with 20.
    try std.testing.expectEqual(@as(u32, 20), s.sess.charges);

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK); // costs the default 1
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 19), s.sess.charges);

    // A settling bite must NOT hand the charge back: the pool is the budget
    // for the whole encounter.
    try settle_mid_game(&s.sess);
    try std.testing.expectEqual(@as(u32, 19), s.sess.charges);
}

test "each recipe debits its own cost, and a free recipe debits nothing" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    s.sess.charges = 10; // pin the pool; growth is covered elsewhere

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, TRICKLE); // cost 0
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 10), s.sess.charges);
    // Free does not mean inert: the shape still landed.
    try std.testing.expectEqual(c.SlimeCell.neutralized, s.sess.field.grid.at(2, 5));

    aim_at(&s.sess, s.p[1].pid, 2, 2);
    try enqueue_cast_as(&s.sess, s.p[1].pid, DELUGE); // cost 9
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 1), s.sess.charges);
    try std.testing.expectEqual(@as(u16, 9), s.sess.stats.feast.charges_spent);
}

test "a cast the pool cannot afford changes nothing at all" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    s.sess.charges = 10; // pin the pool; growth is covered elsewhere

    // Drain the pool to 1 with one deluge.
    aim_at(&s.sess, s.p[0].pid, 2, 2);
    try enqueue_cast_as(&s.sess, s.p[0].pid, DELUGE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 1), s.sess.charges);

    const before = s.sess.field.grid;
    s.p[0].clear();
    // Forgive the cooldown so the refusal — not the cooldown — is what the
    // second press meets.
    clear_cooldowns(&s.sess);

    // A second deluge costs 9 against a pool of 1.
    aim_at(&s.sess, s.p[0].pid, 4, 7);
    try enqueue_cast_as(&s.sess, s.p[0].pid, DELUGE);
    try flush(&s.sess);

    // Nothing happened to the field, nothing left the pool, and no cooldown
    // started: the player is free to try something cheaper at once.  (A
    // team that can afford NOTHING is not left hanging either — the bite
    // clock keeps the game moving, see the pool-dry tests below.)
    try std.testing.expect(grids_equal(before, s.sess.field.grid));
    try std.testing.expectEqual(@as(u32, 1), s.sess.charges);
    try std.testing.expectEqual(@as(u64, 0), s.sess.cooldown_until[s.p[0].pid]);

    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .over_budget));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .shape_cast));
}

test "a free recipe still works with the pool at zero" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    s.sess.charges = 0;

    aim_at(&s.sess, s.p[0].pid, 3, 4);
    try enqueue_cast_as(&s.sess, s.p[0].pid, TRICKLE);
    try flush(&s.sess);

    // 0 <= 0, so the pool can pay.  A zero-cost recipe is the floor the
    // economy can never fall through.
    try std.testing.expectEqual(c.SlimeCell.neutralized, s.sess.field.grid.at(3, 4));
    try std.testing.expectEqual(@as(u32, 0), s.sess.charges);
}

test "a completing cast is charged the group cost INSTEAD of its own" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    s.sess.charges = 10; // pin the pool; growth is covered elsewhere

    // The contribution pays its own way as it lands: a poke is a poke until
    // someone completes something with it.
    aim_at(&s.sess, s.p[0].pid, 3, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    const poke_cost = BAL.player_recipes[POKE].cost;
    try std.testing.expectEqual(@as(u32, 10) - poke_cost, s.sess.charges);

    // The pair becomes twin_bloom: the COMPLETER is billed the group's 4
    // instead of their poke's 1 — the group price is the price of the
    // upgrade, not a refund on the contribution already made.
    aim_at(&s.sess, s.p[1].pid, 3, 5);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    const group_cost = BAL.team_recipes[TWIN_BLOOM].cost;
    try std.testing.expectEqual(@as(u32, 10) - poke_cost - group_cost, s.sess.charges);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
}

test "a completion is priced as the group even when the pool is exact" {
    // The completing press costs the group's 4, never the poke's 1 — so a
    // pool holding exactly poke + group covers the whole play, with nothing
    // to spare.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    s.sess.charges =
        BAL.player_recipes[POKE].cost + BAL.team_recipes[TWIN_BLOOM].cost; // 1 + 4

    aim_at(&s.sess, s.p[0].pid, 3, 5);
    aim_at(&s.sess, s.p[1].pid, 3, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(u16, 13), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u32, 0), s.sess.charges);
}

// ---------------------------------------------------------------------------
// End conditions
// ---------------------------------------------------------------------------

test "eating everything ends the game with reason field_cleared" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(0).cfg);
    defer s.deinit();
    try start(&s, &enc_neutral_only); // 40 neutral, roomy budget

    s.p[0].clear();
    // One whole-board bite eats all 40 and the reservoir has nothing to
    // send back.
    try settle_idly(&s.sess);

    try std.testing.expect(s.sess.restart_pending);
    try std.testing.expectEqual(@as(u32, 40), s.sess.score); // every neutral unit scores
    try std.testing.expect(s.sess.field.is_exhausted());

    const go = try game_over_msg(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(proto.EndReason.field_cleared, go.stats.reason);
    try std.testing.expectEqual(@as(u32, 40), go.score);
    try std.testing.expectEqual(@as(u32, 40), go.stats.slime_total);
    try std.testing.expectEqual(@as(u32, 0), go.stats.slime_left);
}

test "a full hunger bar ends the game with slime left over" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    // hunger_base 3 → the pair's bar is 6; the bite spans the board.
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(3).cfg);
    defer s.deinit();
    // 9 edible units on the field against a bar of 6: the feast overfills it.
    try start(&s, &enc_paper_stomach);
    // Keep a reserve so the field is NOT cleared by the feast: the clock has
    // to be what unambiguously calls the game.
    s.sess.field.reservoir = .{ .neutral = 1 };

    s.p[0].clear();
    try settle_idly(&s.sess);

    try std.testing.expect(s.sess.restart_pending);
    try std.testing.expectEqual(@as(u16, 6), s.sess.hunger.current); // clamped at max

    const go = try game_over_msg(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(proto.EndReason.hunger_full, go.stats.reason);
    try std.testing.expectEqual(@as(u16, 6), go.stats.hunger_final);
    try std.testing.expectEqual(@as(u16, 6), go.stats.hunger_max);
    try std.testing.expectEqual(@as(u32, 9), go.stats.slime_total);
    // The bar filled before the field was cleared, so slime survives.
    try std.testing.expect(go.stats.slime_left > 0);
}

test "defusing the tight budget survives what idle play loses" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(0).cfg);
    defer s.deinit();
    try start(&s, &enc_tight_budget); // duo bar 200 — hunger never binds here
    set_block_field(&s.sess, tiered(.green), 2, 5);

    // One `block` stamp defuses the whole field.  Left alone, those 9 cells
    // would each cost a wasted nibble before scoring.  Defused, they are 9
    // units of clean food — the difference between playing and not playing
    // is the hunger-clock saved.
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));

    try settle_idly(&s.sess);

    try std.testing.expectEqual(@as(u32, 9), s.sess.score);
    try std.testing.expectEqual(@as(u16, 9), s.sess.hunger.current);
    try std.testing.expect(!logic.hunger_full(s.sess.hunger));
}

test "field_cleared wins the tie when the last bite fills the bar" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    // 2 neutral units against a bar of exactly 2 (hunger_base 1 × two
    // players), whole-board bite: the field empties as the bar fills.
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(1).cfg);
    defer s.deinit();
    const encounter = enc.Encounter{
        .label = "test_exact",
        .slime = .{ .neutral = 2 },
    };
    try start(&s, &encounter);

    s.p[0].clear();
    try settle_idly(&s.sess); // the feast eats 2 units for 2 hunger

    try std.testing.expect(s.sess.restart_pending);
    const go = try game_over_msg(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(proto.EndReason.field_cleared, go.stats.reason);
}

// ---------------------------------------------------------------------------
// Running the pool dry
//
// These use `priced_config`, whose cheapest move costs 1.  The default fixture
// has the free `trickle`, so its `cheapest_cost` is 0 and a team there can
// never be broke — which is deliberate, and which makes these tests
// impossible to write against it.  Going broke never ENDS anything: a broke
// team's priced casts are refused while the bite clock plays the game out.
// ---------------------------------------------------------------------------

/// A pair on the priced table, mid-encounter, with a pool the test sets itself.
fn init_priced_session(s: *TwoPlayerSession, allocator: std.mem.Allocator) !void {
    try init_two_player_session_cfg(s, allocator, SEED, &fixtures.priced_config);
}

test "an empty pool does not end the game: casts refuse, the bite chews on" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_priced_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only); // 40 neutral, roomy bar

    // Food on the field, room on the bar, and not one charge in the pool.
    // The team cannot cast — but the bite still chews, so the game goes on.
    paint_grid(&s.sess, .neutral);
    s.sess.field.reservoir = .{ .neutral = 5 }; // field cannot clear
    s.sess.charges = 0;

    s.p[0].clear();
    // Every press is REFUSED — priced, found unpayable, and answered with
    // over_budget to its own caster.  Nothing lands.
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    var msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .over_budget));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .shape_cast));

    // ...and the game CONTINUES regardless: the bite settles on the clock's
    // schedule, eating the field down — broke is not an ending.
    s.p[0].clear();
    try settle_idly(&s.sess);
    try std.testing.expect(!s.sess.restart_pending);
    try std.testing.expectEqual(@as(u16, 2), s.sess.bite);
    msgs = try drain(s.p[0].buf.items, arena);
    const te_msg = find_tag(msgs, .bite_settled) orelse return error.NoBiteSettled;
    var te_fbs = std.io.fixedBufferStream(te_msg.payload);
    const te = try proto.decode_bite_settled(te_fbs.reader());
    try std.testing.expect(te.cells_eaten > 0); // the bite DID eat
}

test "a pool that can still afford the cheapest move takes casts, not refusals" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_priced_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    paint_grid(&s.sess, .neutral);
    s.sess.field.reservoir = .{ .neutral = 5 };

    // Two charges against a cheapest move of one: the team is NOT broke, so
    // a press is a real cast — priced, paid, landed.  This is the boundary
    // the refusal rule is written against.
    s.sess.charges = 2;
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 1), s.sess.charges);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].casts);
    try std.testing.expect(!s.sess.restart_pending);
}

test "a free move keeps a bankrupt team playing" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator); // fixture table: trickle is free
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    set_field(&s.sess, .{ .neutral = {} }, 10);
    s.sess.field.reservoir = .{ .neutral = 5 };
    s.sess.charges = 0;

    // `cheapest_cost` is 0, so "cannot afford anything" is not a state this
    // config can reach — the economy has a floor and the game always has
    // somewhere to go.
    try enqueue_cast_as(&s.sess, s.p[0].pid, TRICKLE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].casts);

    try settle_idly(&s.sess);
    try std.testing.expect(!s.sess.restart_pending);
}

// ---------------------------------------------------------------------------
// The closing broadcast
// ---------------------------------------------------------------------------

test "the game-ending bite sends the post-feast board before game_over" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    // hunger_base 3 → a duo bar of 6, and a whole-board bite: one feast
    // overfills it.
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(3).cfg);
    defer s.deinit();
    try start(&s, &enc_paper_stomach);
    s.sess.field.reservoir = .{ .neutral = 1 };

    s.p[0].clear();
    try settle_idly(&s.sess);

    const msgs = try drain(s.p[0].buf.items, arena);

    // ORDER IS THE POINT.  `tick` stops broadcasting state once the session
    // leaves `.playing`, so without the explicit send in `end_game` the last
    // board a client ever sees is the one from before the closing feast: it
    // would be told the game ended on a board still holding the slime that
    // ended it.  Clients replay that feast as their outro and need the board it
    // lands on.
    var saw_bite_settled = false;
    var saw_state_after = false;
    var saw_game_over = false;
    for (msgs) |m| switch (m.tag) {
        .bite_settled => saw_bite_settled = true,
        .game_state => if (saw_bite_settled and !saw_game_over) {
            saw_state_after = true;
        },
        .game_over => saw_game_over = true,
        else => {},
    };
    try std.testing.expect(saw_bite_settled);
    try std.testing.expect(saw_state_after);
    try std.testing.expect(saw_game_over);

    // And it is the FINAL board, not a stale one: what the wire carried is what
    // the field holds now that the bite, the shift and the refill are done.
    const gs = try last_game_state(msgs);
    try std.testing.expectEqual(s.sess.field.grid.rows, gs.grid_rows);
    try std.testing.expectEqual(s.sess.field.grid.cols, gs.grid_cols);
    for (s.sess.field.grid.live(), gs.grid[0..gs.grid_len()]) |have, sent| {
        try std.testing.expect(std.meta.eql(have, sent));
    }
    try std.testing.expectEqual(s.sess.hunger.current, gs.hunger.current);
}

test "the end screen holds — no new game, no broadcasts — until a restart arrives" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(0).cfg);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    s.sess.hunger.current = 7; // some progress, to prove the later reset
    try settle_idly(&s.sess); // the whole-board bite eats everything -> field_cleared
    try std.testing.expect(s.sess.restart_pending);

    // Ticks pass; nothing moves and nothing is sent — the final board and the
    // report already went out, and the room is waiting on a human.
    s.p[0].clear();
    try flush(&s.sess);
    try flush(&s.sess);
    try std.testing.expect(s.sess.restart_pending);
    try std.testing.expectEqual(@as(usize, 0), s.p[0].buf.items.len);

    // A restart (any connection — in play it is the browser tab) begins the
    // config's default encounter, HOLDING at its pre-match guide; nobody
    // re-joins.
    try enqueue_msg(&s.sess, s.p[0].pid, .restart, {});
    try flush(&s.sess);
    try std.testing.expect(!s.sess.restart_pending);
    try std.testing.expect(s.sess.prematch);
    try std.testing.expectEqual(@as(u16, 1), s.sess.bite);
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);
    try std.testing.expectEqual(@as(u8, 2), s.sess.seated_players());
    try std.testing.expectEqual(2 * logic.player_hunger(BAL, 0, 0), s.sess.hunger.max);
    try std.testing.expectEqual(DEFAULT_ENC.total_units(), s.sess.slime_total);
    // The pool re-seeds exactly as if the pair had taken fresh seats one by
    // one: seed, grown once for the second player.
    var want_pool: u32 = DEFAULT_ENC.charges;
    logic.grow_charges(&want_pool, 1);
    try std.testing.expectEqual(want_pool, s.sess.charges);

    // Everyone is told, from their own standing, with the hold flagged.
    const msgs = try drain(s.p[0].buf.items, arena);
    const gs_msg = find_tag(msgs, .game_start) orelse return error.NoGameStart;
    var fbs = std.io.fixedBufferStream(gs_msg.payload);
    const gs = try proto.decode_game_start(fbs.reader());
    try std.testing.expectEqual(s.p[0].pid, gs.player_id);
    try std.testing.expect(gs.prematch);
    try std.testing.expectEqualSlices(u8, DEFAULT_ENC.label, gs.encounter_label[0..gs.encounter_label_len]);

    // A second click dismisses the guide and play begins.
    s.p[0].clear();
    try enqueue_msg(&s.sess, s.p[0].pid, .restart, {});
    try flush(&s.sess);
    try std.testing.expect(!s.sess.prematch);
    const msgs2 = try drain(s.p[0].buf.items, arena);
    const gs2_msg = find_tag(msgs2, .game_start) orelse return error.NoGameStart;
    var fbs2 = std.io.fixedBufferStream(gs2_msg.payload);
    const gs2 = try proto.decode_game_start(fbs2.reader());
    try std.testing.expect(!gs2.prematch);
}

test "the pre-match hold ignores gameplay input but seats freely" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    s.sess.prematch = true; // as the server boot (and every restart) sets it

    // Casting during the guide does nothing — nothing lands, nothing is
    // debited, nothing joins the window.
    const charges_before = s.sess.charges;
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(usize, 0), s.sess.recent_count);
    try std.testing.expectEqual(charges_before, s.sess.charges);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.casts_total);

    // But a newcomer can still take a seat while everyone reads.
    var late = TestPlayer{};
    late.init(allocator);
    defer late.deinit(allocator);
    const conn_id = s.sess.connect(late.transport()) orelse return error.JoinFailed;
    try enqueue_msg(&s.sess, conn_id, .take_slot, proto.TakeSlot{});
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u8, 3), s.sess.seated_players());

    // The click begins play; the queued-up team can now cast.
    try enqueue_msg(&s.sess, s.p[0].pid, .restart, {});
    try flush(&s.sess);
    try std.testing.expect(!s.sess.prematch);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.casts_total);
}

test "a restart mid-game is a stray key and changes nothing" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    const turn_before = s.sess.bite;
    const field_before = s.sess.field.remaining();

    try enqueue_msg(&s.sess, s.p[0].pid, .restart, {});
    try flush(&s.sess);

    try std.testing.expect(!s.sess.restart_pending);
    try std.testing.expectEqual(turn_before, s.sess.bite);
    try std.testing.expectEqual(field_before, s.sess.field.remaining());
}

test "an observer's restart works at the end screen" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(0).cfg);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    try settle_idly(&s.sess);
    try std.testing.expect(s.sess.restart_pending);

    // The room's display is an observer connection; its key starts the round.
    var watcher = TestPlayer{};
    watcher.init(allocator);
    defer watcher.deinit(allocator);
    const conn_id = s.sess.connect(watcher.transport()) orelse return error.JoinFailed;
    try enqueue_msg(&s.sess, conn_id, .restart, {});
    try flush(&s.sess);
    try std.testing.expect(!s.sess.restart_pending);
    try std.testing.expectEqual(@as(u16, 1), s.sess.bite);
}

// ---------------------------------------------------------------------------
// Match stats (end-of-game tuning report)
// ---------------------------------------------------------------------------

test "match stats: feast tallies, players and recipes are reported" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    // Same 25-unit mix as `enc_mixed`, on a whole-board bite with a hunger
    // bar the single feast below OVERFILLS (hunger_base 2 × two players = 4,
    // against 25 bites) — that is what makes the game end and the report get
    // sent in one turn.
    try init_two_player_session_cfg(&s, allocator, SEED, &WholeBite(2).cfg);
    defer s.deinit();
    const enc_stats_mixed = enc.Encounter{
        .label = "test_stats_mixed",
        .charges = 50,
        .slime = .{ .tiered = .{ 10, 0, 8 }, .neutral = 7 },
    };
    try start(&s, &enc_stats_mixed);

    // Pin a layout the stamps can address exactly.  On the 6x10 grid this is:
    //
    //   row 0:  G G G G G G G G R R
    //   row 1:  R R R R R R R R n n
    //   row 2:  n n n n n . . . . .
    //   rows 3-5: empty
    paint_grid(&s.sess, .empty);
    var flat: u16 = 0;
    while (flat < 8) : (flat += 1) s.sess.field.grid.put(flat, tiered(.green));
    while (flat < 18) : (flat += 1) s.sess.field.grid.put(flat, tiered(.red));
    while (flat < 25) : (flat += 1) s.sess.field.grid.put(flat, .neutral);
    s.sess.field.reservoir = .{};

    s.p[0].clear();

    // Alice pokes one green cell (defusing it); Bob sweeps three more.
    aim_at(&s.sess, s.p[0].pid, 0, 0);
    aim_at(&s.sess, s.p[1].pid, 0, 4);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try enqueue_cast_as(&s.sess, s.p[1].pid, SWEEP);
    try flush(&s.sess);

    // The turn ends and the whole-board bite visits every cell:
    //   consumed: the 4 defused greens (Alice's poke + Bob's sweep) and the
    //             7 neutrals — 11 cells, 11 points;
    //   nibbled:  the 4 still-green cells and the 10 reds — 14 bites of
    //             hunger for nothing.
    try settle_idly(&s.sess);

    const go = try game_over_msg(try drain(s.p[0].buf.items, arena));
    const st = go.stats;

    try std.testing.expectEqual(proto.EndReason.hunger_full, st.reason);
    try std.testing.expectEqual(@as(u32, 25), st.slime_total);
    // 11 of 25 eaten; the nibbled hazards all survive in place.
    try std.testing.expectEqual(@as(u32, 14), st.slime_left);
    try std.testing.expectEqual(@as(u16, 2), st.casts_total);

    // Coverage: 4 green cells covered (1 poke + 3 sweep), all defused since
    // green is one step from harmless.  No red was ever covered.
    try std.testing.expectEqual(@as(u16, 4), st.feast.cells_covered[GREEN]);
    try std.testing.expectEqual(@as(u16, 0), st.feast.cells_covered[RED]);
    try std.testing.expectEqual(@as(u16, 4), st.feast.neutralized[GREEN]);
    // Consumed: all seven neutrals plus the four cells the casts defused.
    try std.testing.expectEqual(@as(u16, 7), st.feast.neutral_consumed);
    try std.testing.expectEqual(@as(u16, 4), st.feast.defused_consumed);
    // Every hazard no cast reached was nibbled — the headline tuning number.
    try std.testing.expectEqual(@as(u32, 14), st.feast.hazards_bitten);
    try std.testing.expectEqual(@as(u16, @intCast(25 * BAL.hunger_cost_normal)), st.feast.hunger_normal);
    // Two casts at the fixture default of 1 charge each, out of a pool of
    // 100 (the encounter's 50, grown once for the second seat).
    try std.testing.expectEqual(@as(u16, 2), st.feast.charges_spent);
    try std.testing.expectEqual(@as(u32, 98), st.feast.charges_left);
    // Score = every unit CONSUMED, defused or neutral alike.
    try std.testing.expectEqual(@as(u32, 11), go.score);

    // Players: dense, coverage attribution + recipe participation.
    try std.testing.expectEqual(@as(u8, 2), st.player_count);
    try std.testing.expectEqual(@as(u16, 1), st.players[0].casts);
    try std.testing.expectEqual(@as(u16, 1), st.players[0].cells_covered);
    try std.testing.expectEqual(@as(u16, 1), st.players[0].cells_neutralized);
    try std.testing.expectEqual(@as(u16, 1), st.players[0].recipe_casts);
    try std.testing.expectEqual(@as(u16, 3), st.players[1].cells_covered);
    try std.testing.expectEqual(@as(u16, 1), st.players[1].recipe_casts);

    // `poke` is player_recipes[0] and `sweep` is [1]; no team recipes fired.
    try std.testing.expectEqual(@as(u16, 1), st.player_recipe_hits[0]);
    try std.testing.expectEqual(@as(u16, 1), st.player_recipe_hits[1]);
    for (st.team_recipe_hits) |h| try std.testing.expectEqual(@as(u16, 0), h);
    // Table sizes travel with the report so the browser can resolve labels.
    try std.testing.expectEqual(@as(u8, fixtures.player_recipes.len), st.player_recipe_count);
    try std.testing.expectEqual(@as(u8, fixtures.team_recipes.len), st.team_recipe_count);
}

// ---------------------------------------------------------------------------
// Wire contents
// ---------------------------------------------------------------------------

test "game_state carries the whole grid, the reservoir and the hunger bar" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_overflow); // 80 units: 60 on-grid, 20 reserved

    // A recognisable layout.  The grid stays FULL so the refill pass has no
    // hole to fill and the reservoir keeps its 20 held-back units.
    paint_grid(&s.sess, .neutral);
    s.sess.field.grid.put(0, .neutral);
    s.sess.field.grid.put(1, tiered(.green));
    s.sess.field.grid.put(2, .neutralized);

    s.p[0].clear();
    try flush(&s.sess);
    const gs = try last_game_state(try drain(s.p[0].buf.items, arena));

    try std.testing.expectEqual(BAL.slime_grid.rows, gs.grid_rows);
    try std.testing.expectEqual(BAL.slime_grid.cols, gs.grid_cols);
    try std.testing.expectEqual(@as(u16, 60), gs.grid_len());
    try std.testing.expectEqual(c.SlimeCell.neutral, gs.grid[0]);
    try std.testing.expectEqual(c.SlimeCell{ .tiered = .green }, gs.grid[1]);
    try std.testing.expectEqual(c.SlimeCell.neutralized, gs.grid[2]);
    for (gs.grid[3..gs.grid_len()]) |cell| try std.testing.expectEqual(c.SlimeCell.neutral, cell);

    // The off-grid remainder drives the client's "incoming" indicator.
    try std.testing.expectEqual(s.sess.field.reservoir.total(), gs.reservoir);
    try std.testing.expectEqual(2 * logic.player_hunger(BAL, 0, 0), gs.hunger.max);
    try std.testing.expectEqual(@as(u16, 0), gs.hunger.current);
    try std.testing.expectEqual(@as(u32, 0), gs.score);
}

test "game_state reflects the bite counter and the stamps casts landed" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    set_field(&s.sess, tiered(.green), 50);

    s.p[0].clear();
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK); // 3x3 = 9 cells defused
    try flush(&s.sess);
    s.p[0].clear();
    try flush(&s.sess); // the snapshot AFTER the stamps landed

    const gs = try last_game_state(try drain(s.p[0].buf.items, arena));
    var neutralized: u16 = 0;
    var hazard: u16 = 0;
    var occupied: u16 = 0;
    for (gs.grid[0..gs.grid_len()]) |cell| {
        if (cell.is_slime()) occupied += 1;
        if (cell == .neutralized) neutralized += 1;
        if (cell.is_hazard()) hazard += 1;
    }
    // 50 cells, 9 defused — a stamp downgrades, it never destroys.
    try std.testing.expectEqual(@as(u16, 50), occupied);
    try std.testing.expectEqual(@as(u16, 9), neutralized);
    try std.testing.expectEqual(neutralized + hazard, occupied);
    try std.testing.expectEqual(s.sess.field.grid.occupied(), occupied);
    // No bite has settled: nothing has been eaten yet, and the bite number
    // is on the wire.
    try std.testing.expectEqual(@as(u16, 1), gs.bite);
    try std.testing.expectEqual(@as(u16, 0), gs.hunger.current);
    try std.testing.expectEqual(s.sess.score, gs.score);
    try std.testing.expectEqual(@as(u32, 0), gs.reservoir);
}

test "game_state carries every player's selection, not just the viewer's" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    try enqueue_select(&s.sess, s.p[0].pid, BLOCK);
    try enqueue_select(&s.sess, s.p[1].pid, WEDGE);

    s.p[0].clear();
    try flush(&s.sess);
    const gs = try last_game_state(try drain(s.p[0].buf.items, arena));

    // p0 is the VIEWER here and still sees p1's choice: knowing what a teammate
    // has lined up is the whole basis for agreeing on a group, so it cannot be
    // private.
    var seen: [2]bool = .{ false, false };
    for (gs.entities[0..gs.entity_count]) |e| {
        if (e.owner == s.p[0].pid) {
            try std.testing.expectEqual(BLOCK, e.selected_shape);
            seen[0] = true;
        } else if (e.owner == s.p[1].pid) {
            try std.testing.expectEqual(WEDGE, e.selected_shape);
            seen[1] = true;
        }
    }
    try std.testing.expect(seen[0] and seen[1]);
}

test "game_state keeps reporting a selection after it has been cast" {
    // A cast does not clear the wheel, so the preview a client draws under the
    // cursor stays truthful — and a second press of the same move needs no
    // keystrokes to set up.
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    try enqueue_cast_as(&s.sess, s.p[0].pid, SWEEP);
    s.p[0].clear();
    try flush(&s.sess);
    const gs = try last_game_state(try drain(s.p[0].buf.items, arena));

    var found = false;
    for (gs.entities[0..gs.entity_count]) |e| {
        if (e.owner != s.p[0].pid) continue;
        try std.testing.expectEqual(SWEEP, e.selected_shape);
        found = true;
    }
    try std.testing.expect(found);
}

test "game_state carries the bite number and each player's cast cooldown" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    // Bite 1, nobody has cast: everyone shows a cold cooldown.
    s.p[1].clear();
    try flush(&s.sess);
    var gs = try last_game_state(try drain(s.p[1].buf.items, arena));
    try std.testing.expectEqual(@as(u16, 1), gs.bite);
    for (gs.entities[0..gs.entity_count]) |e| {
        try std.testing.expectEqual(@as(u32, 0), e.cooldown_ms);
    }

    // After one cast only the CASTER's cooldown runs: cooldowns are per
    // player.  The snapshot goes out in the same tick, before any time has
    // passed, so it shows the full cooldown exactly.
    s.p[1].clear();
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    gs = try last_game_state(try drain(s.p[1].buf.items, arena));
    try std.testing.expectEqual(@as(u16, 1), gs.bite);
    var found_caster = false;
    for (gs.entities[0..gs.entity_count]) |e| {
        if (e.owner == s.p[0].pid) {
            try std.testing.expectEqual(@as(u32, COOLDOWN_MS), e.cooldown_ms);
            found_caster = true;
        } else {
            try std.testing.expectEqual(@as(u32, 0), e.cooldown_ms);
        }
    }
    try std.testing.expect(found_caster);

    // A bite settles: a fresh bite number on the wire — and the cooldown
    // readout DRAINS with real time, not with the meal (no clock was walked
    // here, so it still shows in full).
    s.p[1].clear();
    try settle_mid_game(&s.sess);
    gs = try last_game_state(try drain(s.p[1].buf.items, arena));
    try std.testing.expectEqual(@as(u16, 2), gs.bite);

    // 50ms of real time later, half the cooldown is gone from the wire.
    s.p[1].clear();
    try advance(&s.sess, 50);
    gs = try last_game_state(try drain(s.p[1].buf.items, arena));
    for (gs.entities[0..gs.entity_count]) |e| {
        if (e.owner == s.p[0].pid) {
            try std.testing.expectEqual(@as(u32, COOLDOWN_MS - 50), e.cooldown_ms);
        }
    }
}

test "game_state carries the shared charge pool as it drains" {
    // The pool is the only resource a player cannot recover, so the client must
    // never be shown a stale figure for it.
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    s.sess.charges = 10; // pin the pool; growth is covered elsewhere

    s.p[0].clear();
    try flush(&s.sess);
    const before = try last_game_state(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(@as(u32, 10), before.charges);

    // The cast pays the moment it lands, and the very same tick's snapshot
    // already shows the drained figure.
    aim_at(&s.sess, s.p[0].pid, 2, 2);
    try enqueue_cast_as(&s.sess, s.p[0].pid, DELUGE); // cost 9
    try flush(&s.sess);

    const after = try last_game_state(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(@as(u32, 1), after.charges);
    try std.testing.expectEqual(s.sess.charges, after.charges);
}

test "game_state carries the recent-cast window, so everyone sees what is ripe" {
    // The window is the only thing a teammate can coordinate around — which
    // squares already hold group components — so the snapshot has to carry
    // all of it, not just yours, each entry with its age.
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK);
    aim_at(&s.sess, s.p[1].pid, 4, 8);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    s.p[0].clear();
    try flush(&s.sess);

    const grid = &s.sess.field.grid;
    const gs = try last_game_state(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(@as(u8, 2), gs.recent_count);
    // In landing order, each naming its caster, its move, its square and how
    // long ago it landed (just now: age 0).
    try std.testing.expectEqual(s.p[0].pid, gs.recent[0].player_id);
    try std.testing.expectEqual(BLOCK, gs.recent[0].move);
    try std.testing.expectEqual(grid.index(2, 5), gs.recent[0].square);
    try std.testing.expectEqual(@as(u32, 0), gs.recent[0].age_ms);
    try std.testing.expectEqual(s.p[1].pid, gs.recent[1].player_id);
    try std.testing.expectEqual(POKE, gs.recent[1].move);
    try std.testing.expectEqual(grid.index(4, 8), gs.recent[1].square);
    try std.testing.expectEqual(@as(u32, 0), gs.recent[1].age_ms);

    // The entries AGE with real time...
    s.p[0].clear();
    try advance(&s.sess, 200);
    const aged = try last_game_state(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(@as(u8, 2), aged.recent_count);
    try std.testing.expectEqual(@as(u32, 200), aged.recent[0].age_ms);

    // ...and expire off the wire with the window (600ms > the 500ms window,
    // still short of the 869ms bite).
    s.p[0].clear();
    try advance(&s.sess, 400);
    const done = try last_game_state(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(@as(u8, 0), done.recent_count);
}

// ---------------------------------------------------------------------------
// Late join / disconnect
// ---------------------------------------------------------------------------

test "a late joiner gets game_start with the grid dimensions and an entity" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_mixed);

    var late = TestPlayer{};
    late.init(allocator);
    defer late.deinit(allocator);
    const conn_id = s.sess.connect(late.transport()) orelse return error.JoinFailed;

    try enqueue_msg(&s.sess, conn_id, .take_slot, proto.TakeSlot{});
    try flush(&s.sess);
    const late_pid = s.sess.connections[conn_id].player_id orelse return error.JoinFailed;
    late.pid = late_pid;

    const msgs = try drain(late.buf.items, arena);
    // Two game_starts: the observer one from connect, then the seat grant.
    var start_msg: ?proto.GameStart = null;
    for (msgs) |m| {
        if (m.tag != .game_start) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        start_msg = try proto.decode_game_start(fbs.reader());
    }
    const granted = start_msg orelse return error.NoGameStart;
    try std.testing.expectEqual(BAL.slime_grid.rows, granted.grid_rows);
    try std.testing.expectEqual(BAL.slime_grid.cols, granted.grid_cols);
    try std.testing.expectEqual(late_pid, granted.player_id);
    try std.testing.expect(s.sess.players[late_pid].entity != session_mod.NO_ENTITY);

    // The realtime pacing travels with the grant — the cooldown the client
    // must draw and the window a group must land inside — and the joiner
    // arrives cold, free to cast at once.
    try std.testing.expectEqual(BAL.cast_cooldown_ms, granted.cast_cooldown_ms);
    try std.testing.expectEqual(BAL.team_window_ms, granted.team_window_ms);
    try std.testing.expectEqual(@as(u64, 0), s.sess.cooldown_until[late_pid]);
}

test "a repeated take_slot does not duplicate the player's entity" {
    // One player MUST own exactly one player_marker entity: snapshots are built
    // by walking that array, and both the client's batch projection and the
    // group matcher treat one entity as one caster.  A duplicate would project
    // a player's selection twice and fake a two-player group.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_mixed);

    var late = TestPlayer{};
    late.init(allocator);
    defer late.deinit(allocator);
    const conn_id = s.sess.connect(late.transport()) orelse return error.JoinFailed;

    const before = s.sess.world.component_arrays.player_marker.size;
    try enqueue_msg(&s.sess, conn_id, .take_slot, proto.TakeSlot{});
    try flush(&s.sess);
    const after_first = s.sess.world.component_arrays.player_marker.size;
    try std.testing.expectEqual(before + 1, after_first);

    // A client that re-asks for a seat (retry, duplicate input) must not gain
    // a second body — nor a second seat.
    const seated_before = s.sess.seated_players();
    try enqueue_msg(&s.sess, conn_id, .take_slot, proto.TakeSlot{});
    try flush(&s.sess);
    try std.testing.expectEqual(after_first, s.sess.world.component_arrays.player_marker.size);
    try std.testing.expectEqual(seated_before, s.sess.seated_players());

    // ...and no two player entities may report the same owner.
    const pm = &s.sess.world.component_arrays.player_marker;
    var seen = [_]bool{false} ** session_mod.MAX_PLAYERS;
    for (pm.index_to_entity[0..pm.size]) |e| {
        const own = s.sess.world.get_component(e, c.Owner).player_id;
        try std.testing.expect(!seen[own]);
        seen[own] = true;
    }
}

test "a closed connection frees its seat and entity" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    try std.testing.expectEqual(@as(u8, 2), s.sess.seated_players());
    const entity = s.sess.players[s.p[1].pid].entity;
    try std.testing.expect(entity != session_mod.NO_ENTITY);

    s.sess.disconnect(@as(usize, s.p[1].pid));
    try std.testing.expectEqual(@as(u8, 1), s.sess.seated_players());
    try std.testing.expect(!s.sess.players[s.p[1].pid].occupied);
    try std.testing.expect(!s.sess.connections[@as(usize, s.p[1].pid)].active);
    try std.testing.expectEqual(session_mod.NO_ENTITY, s.sess.players[s.p[1].pid].entity);
}

// ---------------------------------------------------------------------------
// Determinism
// ---------------------------------------------------------------------------

test "the same seed replays the same field; a different seed diverges" {
    const allocator = std.testing.allocator;

    const run = struct {
        /// Play `enc_overflow` (grid + reservoir + refills) through one full
        /// turn and return the resulting grid.  The refill after the feast is
        /// the only randomised step, so it is what the seed must control.
        fn go(alloc: std.mem.Allocator, seed: u64) !c.SlimeGrid {
            var s: TwoPlayerSession = undefined;
            try init_two_player_session_seeded(&s, alloc, seed);
            defer s.deinit();
            try s.sess.start_game_encounter(&enc_overflow);
            try s.sess.settle_bite();
            return s.sess.field.grid;
        }
    }.go;

    const a = try run(allocator, 12345);
    const b = try run(allocator, 12345);
    try std.testing.expectEqualSlices(c.SlimeCell, a.live(), b.live());

    // Different seed, same inputs: the shuffle and the target picks differ, so
    // the layout must not be identical (else the seed is being ignored).
    const d = try run(allocator, 99);
    try std.testing.expect(!grids_equal(a, d));
}

// ---------------------------------------------------------------------------
// Appetite → hunger capacity, and the pools on join/leave
//
// The bar's capacity is the SUM of every seated player's contribution,
// min(hunger_base + appetite * appetite_scale, hunger_player_cap) each — see
// game_logic.player_hunger.  Appetite arrives with take_slot (a board's
// persistent flash stat, forwarded by the bridge); everyone else is 0.
// ---------------------------------------------------------------------------

test "the hunger bar sums each player's appetite contribution" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();

    // Alice's board banked an appetite of 4; Bob has none.  The start
    // recounts from the seats, so setting the slot stat directly is the same
    // as having seated with it.
    s.sess.players[s.p[0].pid].appetite = 4;

    try start(&s, &enc_fifty_green);

    // 100 + 4*5 = 120 for Alice, 100 for Bob.
    const want = logic.player_hunger(BAL, 4, 0) + logic.player_hunger(BAL, 0, 0);
    try std.testing.expectEqual(want, s.sess.hunger.max);
    try std.testing.expectEqual(@as(u16, 220), s.sess.hunger.max);
}

test "a repeated take_slot cannot inflate the bar" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    const before = s.sess.hunger.max;
    const pool_before = s.sess.charges;

    // A duplicate ask from a connection that already holds a seat: the share
    // is frozen at count time, so nothing may move — not the bar, not the
    // pool.
    try enqueue_msg(&s.sess, s.p[0].pid, .take_slot, proto.TakeSlot{ .appetite = 9 });
    try flush(&s.sess);
    try std.testing.expectEqual(before, s.sess.hunger.max);
    try std.testing.expectEqual(pool_before, s.sess.charges);
}

test "a mid-game joiner grows the bar by their contribution and the pool by their proportion" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    const before = s.sess.hunger.max; // 200: two appetite-0 players
    s.sess.charges = 60; // two players hold 30 each

    var late = TestPlayer{};
    late.init(allocator);
    defer late.deinit(allocator);
    const conn_id = s.sess.connect(late.transport()) orelse return error.JoinFailed;
    try enqueue_msg(&s.sess, conn_id, .take_slot, proto.TakeSlot{ .appetite = 2 });
    try flush(&s.sess);

    try std.testing.expectEqual(
        before + logic.player_hunger(BAL, 2, 0),
        s.sess.hunger.max,
    );
    // The pool grows by the joiner's proportion of what remains: 60/2 = 30,
    // so all three now hold 30 each (see logic.grow_charges).
    try std.testing.expectEqual(@as(u32, 90), s.sess.charges);
}

test "a mid-game leave gives back the leaver's UNUSED hunger share and 1/n of the charges" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green); // bar 200 (100 each)

    // Half the bar already eaten and part of the pool already spent when Bob
    // leaves.  Half of his 100 hunger was still unused, so exactly 50 comes
    // off; charges are pooled, so as one of two counted players he takes half
    // of what REMAINS — what the team spent stays spent.
    s.sess.hunger.current = 100;
    s.sess.charges = 30;
    s.sess.disconnect(@as(usize, s.p[1].pid));
    try std.testing.expectEqual(@as(u16, 150), s.sess.hunger.max);
    try std.testing.expectEqual(@as(u16, 100), s.sess.hunger.current);
    try std.testing.expectEqual(@as(u32, 15), s.sess.charges);

    // The game rolls on for whoever stayed.
    try std.testing.expect(!s.sess.restart_pending);
}

test "an observer's disconnect touches neither pool" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    // A transport connects mid-game but never takes a seat: no share of
    // either pool, so its disconnect gives nothing back.
    var lurker = TestPlayer{};
    lurker.init(allocator);
    defer lurker.deinit(allocator);
    const conn_id = s.sess.connect(lurker.transport()) orelse return error.JoinFailed;

    const hunger_before = s.sess.hunger.max;
    const charges_before = s.sess.charges;
    s.sess.disconnect(conn_id);
    try std.testing.expectEqual(hunger_before, s.sess.hunger.max);
    try std.testing.expectEqual(charges_before, s.sess.charges);
    try std.testing.expect(!s.sess.restart_pending);
}

test "the last player out leaves the pool in trust for the next taker" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    s.sess.charges = 24;

    // Both leave.  The first takes their half; the LAST takes nothing — a
    // pool that went to 0 here would greet the next joiner with an
    // unplayable game (the first joiner inherits the pool as their seed).
    s.sess.disconnect(@as(usize, s.p[0].pid));
    try std.testing.expectEqual(@as(u32, 12), s.sess.charges);
    s.sess.disconnect(@as(usize, s.p[1].pid));
    try std.testing.expectEqual(@as(u32, 12), s.sess.charges);
    try std.testing.expectEqual(@as(u8, 0), s.sess.seated_players());

    // The next taker inherits it unchanged.
    var next = TestPlayer{};
    next.init(allocator);
    defer next.deinit(allocator);
    const conn_id = s.sess.connect(next.transport()) orelse return error.JoinFailed;
    try s.sess.take_slot(conn_id, .{});
    try std.testing.expectEqual(@as(u32, 12), s.sess.charges);
}

test "a freed seat can be taken by a NEW connection, which counts in fresh" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green); // bar 200, two seats
    s.sess.charges = 40;

    // Bob leaves: bar 100 (his unused share gone), pool 20.
    s.sess.disconnect(@as(usize, s.p[1].pid));
    try std.testing.expectEqual(@as(u16, 100), s.sess.hunger.max);
    try std.testing.expectEqual(@as(u32, 20), s.sess.charges);

    // A newcomer takes the freed seat: their FULL share joins the bar and
    // the pool grows by their proportion of what remains.
    var next = TestPlayer{};
    next.init(allocator);
    defer next.deinit(allocator);
    const conn_id = s.sess.connect(next.transport()) orelse return error.JoinFailed;
    try enqueue_msg(&s.sess, conn_id, .take_slot, proto.TakeSlot{});
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u8, 2), s.sess.seated_players());
    try std.testing.expectEqual(@as(u16, 200), s.sess.hunger.max);
    try std.testing.expectEqual(@as(u32, 40), s.sess.charges);
}

// ---------------------------------------------------------------------------
// POWERUPS the badge carries in.
//
// A badge only COUNTS its powerups; what they are worth is decided here.  The
// one kind today is the Neutralizer Canister, worth
// `balance.powerups.neutralizer_canister_charges` (10 in the fixture) to the
// team pool for as long as its owner is seated.
//
// The grant is a LOAN, not income: it lands after the joiner's share has
// grown the pool and is reclaimed before the leaver's share shrinks it, so a
// player who sits down and stands up again leaves the pool exactly as they
// found it.  These tests exist to pin that ordering — reversed, the round
// trip mints charges and a badge could farm the pool by replugging.
// ---------------------------------------------------------------------------

test "a carried canister pays into the pool on sitting down and is reclaimed on standing up" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    s.sess.charges = 60; // pin the pool; growth is covered elsewhere

    var late = TestPlayer{};
    late.init(allocator);
    defer late.deinit(allocator);
    const conn_id = s.sess.connect(late.transport()) orelse return error.JoinFailed;
    try enqueue_msg(&s.sess, conn_id, .take_slot, proto.TakeSlot{ .powerups = .{2} });
    try flush(&s.sess);

    // Their share first (60 + 60/2 = 90), THEN their two cans on top.
    try std.testing.expectEqual(@as(u32, 90 + 2 * 10), s.sess.charges);

    // Out again with nothing spent in between: the cans come off first
    // (110 - 20 = 90), and only then does their 1/3 share shrink what is
    // left (90 - 30 = 60).  Back exactly where it started — which is the
    // whole point of the ordering.
    s.sess.disconnect(conn_id);
    try std.testing.expectEqual(@as(u32, 60), s.sess.charges);
}

test "a leaver can only reclaim what is LEFT of their canister grant" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    s.sess.charges = 60;

    var late = TestPlayer{};
    late.init(allocator);
    defer late.deinit(allocator);
    const conn_id = s.sess.connect(late.transport()) orelse return error.JoinFailed;
    try enqueue_msg(&s.sess, conn_id, .take_slot, proto.TakeSlot{ .powerups = .{2} });
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 110), s.sess.charges);

    // The team spends nearly everything, then the donor walks.  Charges that
    // were spent are SPENT — the same rule eaten hunger lives by — so the
    // pool gives back the 5 it still holds rather than going negative, and
    // the share shrink then divides nothing.
    s.sess.charges = 5;
    s.sess.disconnect(conn_id);
    try std.testing.expectEqual(@as(u32, 0), s.sess.charges);
}

test "a player carrying no canisters moves the pool by their share alone" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    s.sess.charges = 60;

    // The control case: identical to the test above but with an empty badge.
    // A zero grant must be a genuine no-op, not a rounding of one.
    var late = TestPlayer{};
    late.init(allocator);
    defer late.deinit(allocator);
    const conn_id = s.sess.connect(late.transport()) orelse return error.JoinFailed;
    try enqueue_msg(&s.sess, conn_id, .take_slot, proto.TakeSlot{});
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 90), s.sess.charges);

    s.sess.disconnect(conn_id);
    try std.testing.expectEqual(@as(u32, 60), s.sess.charges);
}

test "a repeated take_slot cannot pay the same canisters twice" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    s.sess.charges = 60;

    var late = TestPlayer{};
    late.init(allocator);
    defer late.deinit(allocator);
    const conn_id = s.sess.connect(late.transport()) orelse return error.JoinFailed;
    try enqueue_msg(&s.sess, conn_id, .take_slot, proto.TakeSlot{ .powerups = .{2} });
    try flush(&s.sess);
    const after_join = s.sess.charges;

    // The second request is refused at the door (the connection already holds
    // a seat), exactly as the hunger bar's equivalent test checks.  Belt and
    // braces: the grant is recorded, so even a request that got through would
    // find it already counted.
    try enqueue_msg(&s.sess, conn_id, .take_slot, proto.TakeSlot{ .powerups = .{2} });
    try flush(&s.sess);
    try std.testing.expectEqual(after_join, s.sess.charges);
}

test "a new encounter pays the seated team's canisters again" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();

    // The canisters are on the badge, not on the encounter: a team that
    // starts a second encounter still has them, so the fresh pool is the
    // seed grown per seat PLUS what they carry.
    s.sess.players[s.p[1].pid].powerups = .{3};
    try start(&s, &enc_fifty_green);

    // Seed 30, grown once for the second seat = 60, then 3 cans = 30 more.
    try std.testing.expectEqual(@as(u32, 60 + 3 * 10), s.sess.charges);

    // And again, from a pool the previous encounter left in any state: the
    // grant is rebuilt from the badge, never carried over.
    s.sess.charges = 7;
    try start(&s, &enc_fifty_green);
    try std.testing.expectEqual(@as(u32, 60 + 3 * 10), s.sess.charges);
}

test "a player's carried canisters reach every client's snapshot" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    // Alice's badge, seen from BOB's connection: the seat HUD draws every
    // player's canisters, so they have to travel to clients that do not own
    // them.
    s.sess.players[s.p[0].pid].powerups = .{4};
    s.p[1].clear();
    try s.sess.tick(1.0 / 60.0);

    const msgs = try drain(s.p[1].buf.items, arena);
    const gs = try last_game_state(msgs);
    const ent = for (gs.entities[0..gs.entity_count]) |e| {
        if (e.owner == s.p[0].pid) break e;
    } else return error.NoEntity;
    try std.testing.expectEqual(@as(u8, 4), ent.powerups[
        @intFromEnum(c.PowerupKind.neutralizer_canister)
    ]);
}

// ---------------------------------------------------------------------------
// The post-bite settle window (balance.settle_lockout_ms).
//
// While the Lil Guys chew, the board is theirs: every cast is refused, table
// wide, and the caster is TOLD so — unlike the per-player cast cooldown,
// which drops a press in silence because the seat panel already counts it
// down.  A refused cast is a cast that never happened: nothing lands, no
// cooldown starts, the pool is untouched and the team window does not age.
//
// These use `settling_config` (window ON at 200ms).  The default fixture
// leaves it at 0 — the shipped default — so every test above casts straight
// through a settle exactly as it always did.
// ---------------------------------------------------------------------------

/// A pair with the settle window switched on, mid-encounter.
fn init_settling_session(s: *TwoPlayerSession, allocator: std.mem.Allocator) !void {
    try init_two_player_session_cfg(s, allocator, SEED, &fixtures.settling_config);
}

test "a cast while the Lil Guys chew is refused, and the caster is told" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_settling_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    paint_grid(&s.sess, .neutral);
    s.sess.field.reservoir = .{ .neutral = 5 }; // field cannot clear
    s.sess.charges = 50;

    try settle_idly(&s.sess);
    const charges_after_bite = s.sess.charges;

    s.p[0].clear();
    s.p[1].clear();
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);

    // Refused, out loud, and nothing reached the board.
    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_refused));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .shape_cast));
    const refusal = find_tag(msgs, .cast_refused) orelse return error.NoRefusal;
    var rfbs = std.io.fixedBufferStream(refusal.payload);
    const decoded = try proto.decode_cast_refused(rfbs.reader());
    try std.testing.expectEqual(proto.CastRefusal.settling, decoded.reason);

    // A refused cast is a cast that never happened: the pool is untouched,
    // no cooldown started (so the player may try again the instant the
    // window lifts), and the team window took no entry.
    try std.testing.expectEqual(charges_after_bite, s.sess.charges);
    try std.testing.expectEqual(@as(u64, 0), s.sess.cooldown_until[s.p[0].pid]);
    try std.testing.expectEqual(@as(u8, 0), s.sess.recent_count);

    // The OTHER player hears nothing about it: nothing landed, so there is
    // nothing for anyone else to redraw.
    const other = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(other, .cast_refused));
}

test "once the chewing stops, the same cast lands" {
    // The negative control for the refusal above.  A lockout that never
    // lifted would pass every assertion there while making the game
    // unplayable, so the window must be shown to EXPIRE.
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_settling_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    paint_grid(&s.sess, .neutral);
    s.sess.field.reservoir = .{ .neutral = 5 };
    s.sess.charges = 50;

    try settle_idly(&s.sess);
    // Past the window.  Well under the 869ms two-player bite interval, so no
    // second meal muddies the result.
    try advance(&s.sess, fixtures.SETTLE_LOCKOUT_MS + 50);

    s.p[0].clear();
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);

    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_refused));
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .shape_cast));
}

test "the settle window outlasts the cast cooldown it is not" {
    // The two refusals are different rules with different answers, and the
    // fixture pins the window (200ms) at double the cooldown (100ms) so they
    // can be told apart.  Here the cooldown has expired and the window has
    // not: a press must still be refused, and refused OUT LOUD.
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_settling_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    paint_grid(&s.sess, .neutral);
    s.sess.field.reservoir = .{ .neutral = 5 };
    s.sess.charges = 50;

    try settle_idly(&s.sess);
    try advance(&s.sess, COOLDOWN_MS + 50); // past the cooldown, inside the window
    try std.testing.expect(s.sess.now_ms() < s.sess.cast_locked_until);

    s.p[0].clear();
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);

    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_refused));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .shape_cast));
}

test "with the window off, a cast lands the instant the bite settles" {
    // The negative control for the FIXTURE: everything above is driven by one
    // balance knob, and `test_config` leaves it at the shipped default of 0.
    // Without this, a bug that locked the board unconditionally would look
    // exactly like the feature working.
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator); // default config: window OFF
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    paint_grid(&s.sess, .neutral);
    s.sess.field.reservoir = .{ .neutral = 5 };
    s.sess.charges = 50;

    try std.testing.expectEqual(@as(u32, 0), TEST_CFG.balance.settle_lockout_ms);
    try settle_idly(&s.sess);
    try std.testing.expectEqual(@as(u64, 0), s.sess.cast_locked_until);

    s.p[0].clear();
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);

    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_refused));
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .shape_cast));
}

test "the settle window counts down on the wire, and reaches zero" {
    // Clients draw this number, so it must both APPEAR and DRAIN.  A field
    // pinned at its full value would have every seat panel stuck mid-chew.
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_settling_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    paint_grid(&s.sess, .neutral);
    s.sess.field.reservoir = .{ .neutral = 5 };

    s.p[0].clear();
    try settle_idly(&s.sess);
    const at_settle = try latest_cast_locked_ms(s.p[0].buf.items, arena);
    try std.testing.expectEqual(@as(u32, fixtures.SETTLE_LOCKOUT_MS), at_settle);

    // Halfway: still running, but strictly less than it was.
    s.p[0].clear();
    try advance(&s.sess, fixtures.SETTLE_LOCKOUT_MS / 2);
    const midway = try latest_cast_locked_ms(s.p[0].buf.items, arena);
    try std.testing.expect(midway > 0);
    try std.testing.expect(midway < at_settle);

    // Past the end: zero, on the same "0 means not happening" convention the
    // bite countdown uses.
    s.p[0].clear();
    try advance(&s.sess, fixtures.SETTLE_LOCKOUT_MS);
    try std.testing.expectEqual(@as(u32, 0), try latest_cast_locked_ms(s.p[0].buf.items, arena));
}

/// The `cast_locked_ms` on the last game_state in `raw`.  The window drains
/// every tick, so a test that read the FIRST snapshot of a multi-tick advance
/// would be reading the clock before the walk it just took.
fn latest_cast_locked_ms(raw: []const u8, arena: std.mem.Allocator) !u32 {
    const msgs = try drain(raw, arena);
    var last: ?u32 = null;
    for (msgs) |m| {
        if (m.tag != .game_state) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const gs = try proto.decode_game_state(fbs.reader());
        last = gs.cast_locked_ms;
    }
    return last orelse error.NoGameState;
}

test "a restart does not resume into chewing that a previous game left behind" {
    // The hold FREEZES the session clock, so a window standing when the game
    // ended could never retire on its own: without the explicit clear, the
    // next encounter would open with the board locked by a meal nobody at the
    // table ever saw.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_settling_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    paint_grid(&s.sess, .neutral);
    s.sess.field.reservoir = .{ .neutral = 5 };

    try settle_idly(&s.sess);
    try std.testing.expect(s.sess.cast_locked_until > 0); // mid-chew

    s.sess.restart_pending = true;
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u64, 0), s.sess.cast_locked_until);
}
