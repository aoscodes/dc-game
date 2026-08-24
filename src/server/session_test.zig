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
//!     backward, wrapping, persisting across turns
//!   - aiming: server-authoritative per-player cursor, clamped at the edges;
//!     a cast lands where the player aimed when the cast was ACCEPTED
//!   - turn-based casting: a per-player per-turn budget, a cast LOCKING IN
//!     rather than resolving, Escape taking a lock-in back, and the whole
//!     pending list resolving at once when the last player has chosen —
//!     GROUPS forming wherever distinct players locked in a group's component
//!     bag on one square
//!   - shape stamping: a matched recipe's footprint downgrades every covered
//!     hazard cell by exactly one tier (red→yellow→green→defused); cells off
//!     the grid edge are clipped, non-hazard cells are inert
//!   - turn end: pending casts resolving, then the PATHED feast (flood from
//!     the left edge, live hazards and specials as walls), gravity collapse,
//!     refill, the pending list clearing and budgets reset — in that order
//!   - the shared charge pool: one per game, never refilled, per-move cost, a
//!     group priced at the GROUP cost INSTEAD of its components' costs, and the
//!     refusal of any lock-in that would take the turn's quote past the pool
//!   - hunger accounting: a flat cost per unit EATEN, and nothing else
//!   - score = units eaten (all of which are neutral or defused)
//!   - end conditions: field cleared / hunger bar full / a pool too empty for
//!     the cheapest move, all checked at turn end — plus the closing broadcast
//!     order, which clients replay their outro from
//!   - wire contents: grid, reservoir, turn, cursors, selections, cast budgets,
//!     charges, and the turn's pending casts

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
/// they are walls: no hunger, no score.  Under the default fixture config the
/// duo bar is 200, so hunger never binds here — the pressure is the walls.
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

/// Neutral-only: nothing walls the flood off, so the whole field is reachable
/// from the first turn and every unit scores.
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
        .join_lobby => if (proto.decode_join_lobby(r)) |_| true else |_| false,
        .reconnect => if (proto.decode_reconnect(r)) |_| true else |_| false,
        .ready_up => true, // zero-payload
        .cycle_shape => if (proto.decode_cycle_shape(r)) |_| true else |_| false,
        .cast => true, // zero-payload
        .cancel_cast => true, // zero-payload
        .lobby_update => if (proto.decode_lobby_update(r)) |_| true else |_| false,
        .game_start => if (proto.decode_game_start(r)) |_| true else |_| false,
        .game_state => if (proto.decode_game_state(r)) |_| true else |_| false,
        .action_result => if (proto.decode_action_result(r)) |_| true else |_| false,
        .game_over => if (proto.decode_game_over(r)) |_| true else |_| false,
        .over_budget => if (proto.decode_over_budget(r)) |_| true else |_| false,
        .recipe_fired => if (proto.decode_recipe_fired(r)) |_| true else |_| false,
        .shape_cast => if (proto.decode_shape_cast(r)) |_| true else |_| false,
        .move_cursor => if (proto.decode_move_cursor(r)) |_| true else |_| false,
        .turn_ended => if (proto.decode_turn_ended(r)) |_| true else |_| false,
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

fn enqueue_msg(sess: *Session, pid: u8, comptime tag: proto.MsgTag, payload: anytype) !void {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), tag, payload);
    sess.enqueue_message(pid, fbs.getWritten());
}

/// Turn `pid`'s wheel one step.  Selection is server state, so tests steer it
/// the way a player does rather than assigning it.
fn enqueue_cycle(sess: *Session, pid: u8, dir: c.CycleDir) !void {
    try enqueue_msg(sess, pid, .cycle_shape, proto.CycleShape{ .dir = dir });
}

/// Queue a bare trigger: locks in whatever `pid` currently has selected,
/// wherever they are currently aiming.
fn enqueue_cast(sess: *Session, pid: u8) !void {
    try enqueue_msg(sess, pid, .cast, {});
}

/// Queue an undo: takes back `pid`'s most recent pending cast.
fn enqueue_cancel(sess: *Session, pid: u8) !void {
    try enqueue_msg(sess, pid, .cancel_cast, {});
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

/// Drain queues and broadcast.  Casts resolve inside the drain, so this is the
/// workhorse for "apply the queued input, then look".  `dt` is unused by the
/// turn loop, so a flush advances nothing on its own.
fn flush(sess: *Session) !void {
    try sess.tick(0.0);
}

/// Apply queued input AND land whatever it locked in — the "everyone has
/// chosen, now look at the board" shorthand most stamp tests want.
fn flush_and_resolve(sess: *Session) !void {
    try flush(sess);
    try resolve_casts(sess);
}

/// Land the turn's locked-in casts WITHOUT ending the turn.
///
/// In play, resolution and the feast are one moment: the stamps land and the
/// Lil Guys immediately eat the board they made.  A test about what a stamp
/// DID needs to look in between, so it resolves the pending list on its own.
fn resolve_casts(sess: *Session) !void {
    try sess.resolve_pending();
}

/// Settle the turn WITHOUT casting: zero every budget directly, then flush so
/// the session notices.  Budgets are server-owned state, so tests write them
/// the same way they write cursors (`aim_at`) — and this keeps "what the feast
/// does" separate from "what casts do", which real casting cannot.
fn end_turn_idly(sess: *Session) !void {
    sess.casts_left = [_]u8{0} ** session_mod.MAX_PLAYERS;
    try flush(sess);
}

/// Settle a turn that must NOT finish the encounter: a spare unit waits in the
/// reservoir, so the feast can never leave the field exhausted.  Use this when
/// the test still has moves to make after the turn ends.
fn end_turn_mid_game(sess: *Session) !void {
    if (sess.field.reservoir.is_empty()) sess.field.reservoir = .{ .neutral = 1 };
    try end_turn_idly(sess);
}

/// Casts each player gets per turn under the fixture balance.
const BUDGET: u8 = 3;

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

    const pid0 = self.sess.join(self.p[0].transport(), "") orelse return error.JoinFailed;
    const pid1 = self.sess.join(self.p[1].transport(), "") orelse return error.JoinFailed;
    self.p[0].pid = pid0;
    self.p[1].pid = pid1;

    const slot0 = &self.sess.players[pid0];
    @memcpy(slot0.name[0..5], "Alice");
    slot0.name_len = 5;

    const slot1 = &self.sess.players[pid1];
    @memcpy(slot1.name[0..3], "Bob");
    slot1.name_len = 3;
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

/// Join one more player into an already-built session, for the few tests about
/// groups that need MORE than a pair.  The extra player has no TestPlayer, so
/// its outbound bytes go to the session's own sink and are not inspected —
/// these tests assert on session state, not on what the newcomer was told.
fn join_extra(s: *TwoPlayerSession, name: []const u8) !u8 {
    return s.sess.join(s.p[0].transport(), name) orelse error.JoinFailed;
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
// Lobby
// ---------------------------------------------------------------------------

test "join sets name in lobby_update" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();

    s.p[0].clear();
    try s.sess.broadcast_lobby_update();

    const msgs0 = try drain(s.p[0].buf.items, arena);
    const lu_msg = find_tag(msgs0, .lobby_update) orelse return error.NoLobbyUpdate;
    var fbs = std.io.fixedBufferStream(lu_msg.payload);
    const lu = try proto.decode_lobby_update(fbs.reader());

    try std.testing.expectEqual(@as(u8, 2), lu.player_count);
    try std.testing.expectEqualSlices(u8, "Alice", lu.players[0].name[0..lu.players[0].name_len]);
    try std.testing.expectEqualSlices(u8, "Bob", lu.players[1].name[0..lu.players[1].name_len]);
}

test "lobby_update carries correct player_id" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();

    s.p[0].clear();
    s.p[1].clear();
    try s.sess.broadcast_lobby_update();

    inline for (.{ 0, 1 }) |i| {
        const msgs = try drain(s.p[i].buf.items, arena);
        const m = find_tag(msgs, .lobby_update) orelse return error.NoLobbyUpdate;
        var fbs = std.io.fixedBufferStream(m.payload);
        const lu = try proto.decode_lobby_update(fbs.reader());
        try std.testing.expectEqual(s.p[i].pid, lu.player_id);
    }
}

test "ready flow starts the default encounter with the configured grid" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();

    try enqueue_msg(&s.sess, s.p[0].pid, .ready_up, {});
    try flush(&s.sess);
    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);

    s.p[0].clear();
    try enqueue_msg(&s.sess, s.p[1].pid, .ready_up, {});
    try flush(&s.sess);
    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);

    const msgs = try drain(s.p[0].buf.items, arena);
    const gs_msg = find_tag(msgs, .game_start) orelse return error.NoGameStart;
    var fbs = std.io.fixedBufferStream(gs_msg.payload);
    const gs = try proto.decode_game_start(fbs.reader());
    try std.testing.expectEqualSlices(
        u8,
        DEFAULT_ENC.label,
        gs.encounter_label[0..gs.encounter_label_len],
    );
    // The client needs the grid dimensions and the cast budget up front.
    try std.testing.expectEqual(BAL.slime_grid.rows, gs.grid_rows);
    try std.testing.expectEqual(BAL.slime_grid.cols, gs.grid_cols);
    try std.testing.expectEqual(BAL.casts_per_turn, gs.casts_per_turn);

    // The bar is the players' appetite contributions summed — two appetite-0
    // players here, so twice the base.
    try std.testing.expectEqual(2 * logic.player_hunger(BAL, 0), s.sess.hunger.max);
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);
    try std.testing.expectEqual(DEFAULT_ENC.total_units(), s.sess.slime_total);
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
    // Filled top-first, so the top rows hold the slime.
    for (s.sess.field.grid.live(), 0..) |cell, i| {
        try std.testing.expectEqual(i < 20, cell.is_slime());
    }
}

test "every player starts the first turn with a full cast budget" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    try std.testing.expectEqual(@as(u16, 1), s.sess.turn);
    for (&s.sess.players, 0..) |*slot, pid| {
        if (!slot.connected) continue;
        try std.testing.expectEqual(BUDGET, s.sess.casts_left[pid]);
    }
}

test "a disconnected player no longer holds the turn open" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    // Nothing on the grid to eat, so the turn can end without ending the game.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{ .neutral = 5 };

    // P0 spends everything; P1 is still holding the turn open.
    aim_at(&s.sess, s.p[0].pid, 0, 0);
    for (0..BUDGET) |_| {
        try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
        try flush(&s.sess);
    }
    try std.testing.expectEqual(@as(u16, 1), s.sess.turn);
    try std.testing.expectEqual(@as(u8, 0), s.sess.casts_left[s.p[0].pid]);
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[s.p[1].pid]);

    // P1 drops out: the turn is no longer waiting on anyone.
    s.sess.disconnect(s.p[1].pid);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 2), s.sess.turn);
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[s.p[0].pid]);
}

test "an empty room never ends turns on its own" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    s.sess.disconnect(s.p[0].pid);
    s.sess.disconnect(s.p[1].pid);
    for (0..5) |_| try flush(&s.sess);

    // With nobody present the feast must not run unattended.
    try std.testing.expectEqual(@as(u16, 1), s.sess.turn);
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);
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
    // player may deliberate as long as they like.
    try std.testing.expectEqual(charges_before, s.sess.charges);
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[pid]);
    try std.testing.expectEqual(@as(usize, 0), s.sess.pending_count);
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
    try end_turn_mid_game(&s.sess);

    try std.testing.expectEqual(@as(u16, 2), s.sess.turn);
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
    aim_at(&s.sess, pid, 3, 3);
    try enqueue_cast_as(&s.sess, pid, SWEEP);
    try flush_and_resolve(&s.sess);

    // `sweep` is "###", so exactly three cells defused — the wheel, not the
    // keystrokes, decided the shape.
    try std.testing.expectEqual(@as(u16, 3), count_defused(&s.sess));
    try std.testing.expectEqual(
        BAL.player_recipes[SWEEP].cost,
        enc_fifty_green.charges - s.sess.charges,
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
    try flush_and_resolve(&s.sess);

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
    try flush_and_resolve(&s.sess);

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
    try flush_and_resolve(&s.sess);

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
    try flush_and_resolve(&s.sess);

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
    try flush_and_resolve(&s.sess);
    try std.testing.expectEqual(c.Tier.yellow, s.sess.field.grid.at(3, 4).tiered);

    // Cast 2: yellow → green.
    aim_at(&s.sess, pid, 3, 4);
    try enqueue_cast_as(&s.sess, pid, POKE);
    try flush_and_resolve(&s.sess);
    try std.testing.expectEqual(c.Tier.green, s.sess.field.grid.at(3, 4).tiered);

    // Cast 3: green → defused, and no further.
    aim_at(&s.sess, pid, 3, 4);
    try enqueue_cast_as(&s.sess, pid, POKE);
    try flush_and_resolve(&s.sess);
    try std.testing.expect(s.sess.field.grid.at(3, 4) == .neutralized);

    // A fourth cast is inert: a defused cell cannot be downgraded further.
    // Hand the budget back rather than turn the page — ending the turn would
    // send the Lil Guys after the very cell under test.
    s.sess.casts_left[pid] = 1;
    aim_at(&s.sess, pid, 3, 4);
    try enqueue_cast_as(&s.sess, pid, POKE);
    try flush_and_resolve(&s.sess);
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
    try flush_and_resolve(&s.sess);

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
    try flush_and_resolve(&s.sess);

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
    try flush_and_resolve(&s.sess);

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
    try flush_and_resolve(&s.sess);

    const msgs = try drain(s.p[1].buf.items, arena);
    const msg = find_tag(msgs, .shape_cast) orelse return error.MissingShapeCast;
    var fbs = std.io.fixedBufferStream(msg.payload);
    const sc = try proto.decode_shape_cast(fbs.reader());

    try std.testing.expectEqual(@as(u16, 4), sc.cell_count); // only in-bounds cells
    try std.testing.expectEqual(@as(u16, 5), sc.off_grid);
    try std.testing.expectEqual(@as(u16, 3), sc.inert);
    try std.testing.expectEqual(@as(u16, 1), sc.downgraded[GREEN]);
}

test "a cast the turn cannot afford is refused, and only the caster hears it" {
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
    // `deluge` costs 9 against a pool of 2: the turn's quote would overshoot,
    // so the lock-in never happens.
    s.sess.charges = 2;
    try enqueue_cast_as(&s.sess, s.p[0].pid, DELUGE);
    try flush(&s.sess);

    // Refused means UNCHANGED: no pending entry, no budget spent, no debit.
    try std.testing.expectEqual(@as(usize, 0), s.sess.pending_count);
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[s.p[0].pid]);
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

test "a refused cast leaves the turn open for something affordable" {
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
    try std.testing.expectEqual(@as(usize, 0), s.sess.pending_count);

    // A refusal is not a spent turn: the player picks something they can pay
    // for and that cast lands normally.
    try enqueue_cast_as(&s.sess, pid, POKE);
    try flush_and_resolve(&s.sess);

    try std.testing.expectEqual(@as(u16, 1), count_defused(&s.sess));
    try std.testing.expectEqual(BUDGET - 1, s.sess.casts_left[pid]);
}

test "two pokes on one square become the group shape; one poke stays a poke" {
    const allocator = std.testing.allocator;

    // Together: the two pokes complete twin_bloom's bag, so the turn stamps its
    // 5x5 diamond (13 cells) INSTEAD of the pokes — the components are spent on
    // the group, not fired alongside it.
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
    try flush_and_resolve(&together.sess);

    try std.testing.expectEqual(@as(u16, 13), count_defused(&together.sess));
    try std.testing.expectEqual(@as(u16, 1), together.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    // Neither poke fired on its own: both were consumed by the group.
    try std.testing.expectEqual(@as(u16, 0), together.sess.stats.player_recipe_hits[POKE]);

    // Alone: nothing to group with, so a poke is just a poke.  The central
    // change from the old design — a lone contribution is never wasted.
    var alone: TwoPlayerSession = undefined;
    try init_two_player_session(&alone, allocator);
    defer alone.deinit();
    try start(&alone, &enc_fifty_green);
    paint_grid(&alone.sess, tiered(.green));
    alone.sess.field.reservoir = .{};
    try enqueue_cast_as(&alone.sess, alone.p[0].pid, POKE);
    try flush_and_resolve(&alone.sess);

    try std.testing.expectEqual(@as(u16, 1), count_defused(&alone.sess));
    try std.testing.expectEqual(@as(u16, 0), alone.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(u16, 1), alone.sess.stats.player_recipe_hits[POKE]);
}

test "a contribution waits across drains for a partner to join it" {
    // A group is not a same-tick coincidence: the two lock-ins may arrive in
    // separate drains, and neither means anything until the turn resolves.
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
    // Locked in, and that is all: the board is untouched until the turn ends.
    try std.testing.expectEqual(@as(usize, 1), s.sess.pending_count);
    try std.testing.expectEqual(@as(u16, 0), count_defused(&s.sess));

    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush_and_resolve(&s.sess);

    try std.testing.expectEqual(@as(u16, 13), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
}

test "a group's components are consumed, so a third poke starts a fresh bag" {
    // Four pokes on one square are two twin_blooms, not four pokes and not one
    // group with two spare contributions: the bag is filled, emptied and filled
    // again inside the same resolution.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try enqueue_cast(&s.sess, s.p[0].pid);
    try flush(&s.sess);

    // Three pokes: one full bag and one leftover, which would fire as a plain
    // poke.  Read the quote rather than resolving — resolving here would spend
    // the very contributions the fourth cast is about to complete.
    const three = logic.resolve_batch(BAL, s.sess.pending[0..s.sess.pending_count]);
    try std.testing.expectEqual(@as(usize, 2), three.count);

    // The fourth fills a SECOND bag from the two unspent pokes.
    try enqueue_cast(&s.sess, s.p[1].pid);
    try flush_and_resolve(&s.sess);

    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.player_recipe_hits[POKE]);
    // The bag is emptied with the group, so nothing carries into the next turn.
    try std.testing.expectEqual(@as(usize, 0), s.sess.pending_count);
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
    try flush_and_resolve(&s.sess);

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
    try flush_and_resolve(&s.sess);

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
    // would simply buy the big shape at a discount by pressing twice.
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try enqueue_cast(&s.sess, s.p[0].pid);
    try flush_and_resolve(&s.sess);

    // Two pokes on one cell: the cell is defused once and nothing more.
    try std.testing.expectEqual(@as(u16, 1), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.player_recipe_hits[POKE]);
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
        try flush_and_resolve(&s.sess);

        try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[CROSSFIRE]);
    }
}

test "the pending list clears at turn end, so a partner cannot join yesterday" {
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
    try std.testing.expectEqual(@as(usize, 1), s.sess.pending_count);

    try end_turn_idly(&s.sess);
    try std.testing.expectEqual(@as(u16, 2), s.sess.turn);
    // The turn resolved that poke on its way out; the feast has been and gone,
    // so last turn's aim means nothing now.
    try std.testing.expectEqual(@as(usize, 0), s.sess.pending_count);

    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush_and_resolve(&s.sess);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
}

test "a lone contribution fires as its own move and is never refunded" {
    // A partnerless contribution is not a failure: it resolves as the move the
    // player actually chose, at that move's price.  There is nothing to give
    // back, because nothing went wrong.
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
    // A lock-in spends the budget slot immediately, but not the charges.
    try std.testing.expectEqual(BUDGET - 1, s.sess.casts_left[pid]);
    try std.testing.expectEqual(before, s.sess.charges);

    try end_turn_idly(&s.sess);

    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.player_recipe_hits[POKE]);
    try std.testing.expectEqual(before - BAL.player_recipes[POKE].cost, s.sess.charges);
    // The new turn's budget is a NEW turn's, not a refund of the old one.
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[pid]);
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
    try flush_and_resolve(&s.sess);

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
    try flush_and_resolve(&s.sess);

    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(@as(u16, 2), count_defused(&s.sess));
}

// ---------------------------------------------------------------------------
// Turn end: the pathed feast, gravity, and the refill
//
// The Lil Guys enter from the LEFT edge (column 0) and flood 4-connected
// through empty cells and edible slime (neutral / defused).  Live hazards and
// specials are WALLS: the flood never enters one, so everything behind it is
// sheltered.  Survivors then fall to the bottom of their column, and only then
// does the reservoir refill the rows that opened up at the top.
//
// Nothing here depends on elapsed time — `end_turn_idly` settles the turn by
// exhausting budgets.
// ---------------------------------------------------------------------------

test "an edible field is eaten whole and refilled from the reservoir" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    // 80 NEUTRAL units: nothing blocks, so the flood reaches the whole grid.
    const enc_all_neutral = enc.Encounter{
        .label = "test_all_neutral",
        .slime = .{ .neutral = 80 },
    };
    try start(&s, &enc_all_neutral); // 60 on-grid, 20 waiting

    try end_turn_idly(&s.sess);

    // All 60 on-grid units are gone, and the 20 reserves have taken the field.
    try std.testing.expectEqual(@as(u32, 20), s.sess.field.remaining());
    try std.testing.expectEqual(@as(u16, 20), s.sess.field.grid.occupied());
    try std.testing.expect(s.sess.field.reservoir.is_empty());
    try std.testing.expectEqual(@as(u16, 2), s.sess.turn);
}

test "refills enter from the top row" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only); // 40 neutral, all edible
    // Clear the board so the refill has the whole grid to itself and the test
    // is not reading survivors the collapse moved.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{ .neutral = 20 };

    try end_turn_idly(&s.sess);

    // 20 units into a 10-wide grid: the top two rows, and nothing below.
    const cols = s.sess.field.grid.cols;
    var col: u8 = 0;
    while (col < cols) : (col += 1) {
        try std.testing.expect(s.sess.field.grid.at(0, col).is_slime());
        try std.testing.expect(s.sess.field.grid.at(1, col).is_slime());
        try std.testing.expect(!s.sess.field.grid.at(2, col).is_slime());
    }
}

test "a live hazard is a wall, not a meal: the flood never touches it" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);

    // A field of live green: not one unit is edible, so the feast is empty.
    set_field(&s.sess, tiered(.green), 20);
    try end_turn_mid_game(&s.sess);

    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    // All 20 are still there, and none of them counted as sheltered food:
    // a wall is not something the team was denied, it is the obstacle itself.
    try std.testing.expectEqual(@as(u16, 20), s.sess.field.grid.hazard_count());
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.feast.sheltered);

    // Defuse the same field and it becomes 20 units of dinner.
    set_field(&s.sess, .neutralized, 20);
    try end_turn_mid_game(&s.sess);

    try std.testing.expectEqual(
        @as(u16, @intCast(20 * BAL.hunger_cost_normal)),
        s.sess.hunger.current,
    );
    try std.testing.expectEqual(@as(u32, 20), s.sess.score);
    try std.testing.expectEqual(@as(u16, 20), s.sess.stats.feast.defused_consumed);
}

test "food behind a wall is sheltered, and one defusal opens the whole road" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);

    // Column 0 is a solid green wall; columns 1..9 are neutral food.  The door
    // is shut, so a whole grid of dinner goes untouched.
    //
    //   col:  0  1  2 ... 9
    //         G  n  n ... n     (every row)
    paint_grid(&s.sess, .neutral);
    s.sess.field.reservoir = .{};
    const grid = &s.sess.field.grid;
    var row: u8 = 0;
    while (row < grid.rows) : (row += 1) grid.set(row, 0, tiered(.green));

    try end_turn_idly(&s.sess);
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    // 54 neutral units the team could see and not reach, behind 6 walls.
    try std.testing.expectEqual(@as(u16, 54), s.sess.stats.feast.sheltered);
    try std.testing.expectEqual(@as(u16, 6), s.sess.field.grid.hazard_count());

    // Now knock ONE hole in the wall.  4-connectivity means a single doorway
    // is enough: the flood goes in and takes everything.
    paint_grid(&s.sess, .neutral);
    row = 0;
    while (row < grid.rows) : (row += 1) grid.set(row, 0, tiered(.green));
    grid.set(3, 0, .neutralized);

    try end_turn_idly(&s.sess);
    // The doorway cell plus all 54 behind it: 55 units, from zero last turn.
    try std.testing.expectEqual(@as(u32, 55), s.sess.score);
    // And not one unit was shut out this time.
    try std.testing.expectEqual(@as(u16, 54), s.sess.stats.feast.sheltered);
}

test "one feast can mix every cell kind, pricing each on its own terms" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_red);

    // Row 0 of the 6x10 grid, left to right:
    //   n  n  .  .  .  x  x  .  .  .      (n neutral, x defused, . empty)
    // and a neutral unit sealed into the bottom-right corner by two hazards:
    //   (4,9) red above it, (5,8) green beside it, grid edges on the other two
    //   sides.  A pocket needs a full seal — an open cell anywhere on its
    //   border lets the flood in, since empty space conducts.
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

    try end_turn_idly(&s.sess);

    // Eaten: 2 neutral + 2 defused.  The hazards are walls, and the corner
    // neutral has no route to the left edge at all.
    try std.testing.expectEqual(
        @as(u16, @intCast(4 * BAL.hunger_cost_normal)),
        s.sess.hunger.current,
    );
    try std.testing.expectEqual(@as(u32, 4), s.sess.score);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.feast.neutral_consumed);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.feast.defused_consumed);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.feast.sheltered);
    // Both hazards survive, so the field is not exhausted.
    try std.testing.expectEqual(@as(u16, 2), s.sess.field.grid.hazard_count());
    try std.testing.expect(!s.sess.field.is_exhausted());
}

test "survivors fall to the bottom of their column after the feast" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);

    // Column 3, top to bottom: neutral, green, empty, empty, empty, empty.
    // The neutral is edible but unreachable (column 0 is empty corridor, so the
    // flood arrives along row 0 and eats it) — check the green's fall instead.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{};
    const grid = &s.sess.field.grid;
    grid.set(1, 3, tiered(.green));
    grid.set(2, 3, tiered(.red));

    try end_turn_idly(&s.sess);

    // Both hazards packed against the bottom, in the order they were stacked.
    try std.testing.expectEqual(c.SlimeCell.empty, grid.at(1, 3));
    try std.testing.expectEqual(c.SlimeCell.empty, grid.at(2, 3));
    try std.testing.expectEqual(c.SlimeCell{ .tiered = .green }, grid.at(4, 3));
    try std.testing.expectEqual(c.SlimeCell{ .tiered = .red }, grid.at(5, 3));
}

test "neutral slime is the only thing on the field that needs no work" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    set_field(&s.sess, .neutral, 10);

    try end_turn_idly(&s.sess);
    try std.testing.expectEqual(@as(u32, 10), s.sess.score);
    try std.testing.expectEqual(@as(u16, 10), s.sess.stats.feast.neutral_consumed);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.feast.sheltered);
}

test "a stamp destroys nothing: it converts a wall into a meal" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    // A 3x3 patch of green anchored on column 1, so the patch touches the left
    // edge and the flood can reach it the moment it is defused.
    set_block_field(&s.sess, tiered(.green), 2, 1);

    aim_at(&s.sess, s.p[0].pid, 2, 1);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK);
    try flush_and_resolve(&s.sess);
    // The stamp defused all 9 and removed none.
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 9), s.sess.field.grid.occupied());

    try end_turn_idly(&s.sess);

    // Defusal is what makes a unit food at all: 9 eaten, 9 scored.
    try std.testing.expectEqual(@as(u32, 9), s.sess.score);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.feast.sheltered);
    try std.testing.expectEqual(
        @as(u16, @intCast(9 * BAL.hunger_cost_normal)),
        s.sess.hunger.current,
    );
}

test "turn_ended reports the feast the clients must animate" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    // Row 0: 2 neutral at the door.  Bottom-right: 1 neutral sealed into the
    // corner by 2 hazards.  Reserves keep the game alive past the turn.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{ .neutral = 3 };
    const grid = &s.sess.field.grid;
    grid.set(0, 0, .neutral);
    grid.set(0, 1, .neutral);
    grid.set(4, 9, tiered(.green));
    grid.set(5, 8, tiered(.green));
    grid.set(5, 9, .neutral);

    const charges_before = s.sess.charges;
    s.p[1].clear();
    try end_turn_idly(&s.sess);

    const msgs = try drain(s.p[1].buf.items, arena);
    const te_msg = find_tag(msgs, .turn_ended) orelse return error.NoTurnEnded;
    var fbs = std.io.fixedBufferStream(te_msg.payload);
    const te = try proto.decode_turn_ended(fbs.reader());

    try std.testing.expectEqual(@as(u16, 1), te.turn);
    try std.testing.expectEqual(@as(u16, 2), te.cells_eaten);
    try std.testing.expectEqual(
        @as(u16, @intCast(2 * BAL.hunger_cost_normal)),
        te.hunger_added,
    );
    // The two numbers the next turn is planned around: what a wall cost them,
    // and how many walls there were.
    try std.testing.expectEqual(@as(u16, 1), te.sheltered);
    try std.testing.expectEqual(@as(u16, 2), te.walls);
    try std.testing.expectEqual(@as(u32, 2), te.score_added);
    // The broadcast agrees with the session it describes.
    try std.testing.expectEqual(te.hunger_added, s.sess.hunger.current);
    try std.testing.expectEqual(te.score_added, s.sess.score);
    try std.testing.expectEqual(charges_before, te.charges_left);
}

test "a turn with no slime on the field is a free turn" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{ .neutral = 4 };

    try end_turn_idly(&s.sess);

    // Nothing was there to eat, so nothing was charged — and the reserves
    // arrive for the next turn.
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    try std.testing.expectEqual(@as(u16, 4), s.sess.field.grid.occupied());
    try std.testing.expectEqual(@as(u16, 2), s.sess.turn);
}

// ---------------------------------------------------------------------------
// Casting: the per-turn budget
//
// Fixture balance: casts_per_turn = 3 per PLAYER.  A cast LOCKS IN — it spends
// a budget slot and joins the turn's pending list, and nothing reaches the
// board until every connected player has finished choosing.  A lock-in the
// turn's quote cannot afford is refused outright rather than downgraded.
// ---------------------------------------------------------------------------

test "a lock-in spends a budget slot and lands when the turn resolves" {
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

    // Chosen, not cast: the slot is spent and the intent is on the pending
    // list, but the board is exactly as the player found it.
    try std.testing.expectEqual(@as(u16, 0), count_defused(&s.sess));
    try std.testing.expectEqual(BUDGET - 1, s.sess.casts_left[s.p[0].pid]);
    try std.testing.expectEqual(@as(usize, 1), s.sess.pending_count);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].casts);

    // Resolution is where the 3x3 block reaches the grid.
    try resolve_casts(&s.sess);
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));

    const msgs = try drain(s.p[1].buf.items, arena);
    // One shape_cast, sent when the stamp actually happened.
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

test "a player may cast their whole budget in one turn, then no more" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_red);
    // Red needs three casts to defuse, so the whole budget goes into one cell
    // and the grid shows exactly how many casts actually landed.
    paint_grid(&s.sess, tiered(.red));
    s.sess.field.reservoir = .{};
    const pid = s.p[0].pid;
    aim_at(&s.sess, pid, 3, 4);

    for (0..BUDGET) |_| {
        try enqueue_cast_as(&s.sess, pid, POKE);
        try flush(&s.sess);
    }
    try std.testing.expectEqual(@as(u8, 0), s.sess.casts_left[pid]);
    try std.testing.expectEqual(@as(usize, BUDGET), s.sess.pending_count);

    // A fourth submit is silently ignored: not refused for price, just not
    // theirs to make — no pending entry, no effect, no wire noise.
    s.p[1].clear();
    try enqueue_cast_as(&s.sess, pid, POKE);
    try flush(&s.sess);

    const msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .shape_cast));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .over_budget));
    try std.testing.expectEqual(@as(usize, BUDGET), s.sess.pending_count);
    try std.testing.expectEqual(@as(u16, BUDGET), s.sess.stats.players[pid].casts);

    // Three pokes by one player never group (a group needs distinct players),
    // so they step the red cell down one tier each, all the way to defused.
    try resolve_casts(&s.sess);
    try std.testing.expect(s.sess.field.grid.at(3, 4) == .neutralized);
}

test "the turn ends only when EVERY connected player is out of casts" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    // Nothing to eat, so turn end cannot end the game.
    paint_grid(&s.sess, .empty);
    s.sess.field.reservoir = .{ .neutral = 5 };
    aim_at(&s.sess, s.p[0].pid, 0, 0);
    aim_at(&s.sess, s.p[1].pid, 0, 0);

    // p0 empties their budget: the turn is still p1's to finish.
    for (0..BUDGET) |_| {
        try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
        try flush(&s.sess);
    }
    try std.testing.expectEqual(@as(u16, 1), s.sess.turn);

    // p1 spends all but one: still turn 1.
    for (0..BUDGET - 1) |_| {
        try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
        try flush(&s.sess);
    }
    try std.testing.expectEqual(@as(u16, 1), s.sess.turn);

    // The last cast in the room settles the turn and refills both budgets.
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 2), s.sess.turn);
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[s.p[0].pid]);
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[s.p[1].pid]);
}

test "a cast the pool cannot pay for costs nothing, not even the budget slot" {
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

    // Nothing is committed until the turn resolves, so an unaffordable choice
    // costs the player nothing: they simply have not chosen yet.
    s.sess.charges = 0;
    s.p[1].clear();
    try enqueue_cast_as(&s.sess, s.p[0].pid, DELUGE);
    try flush(&s.sess);

    try std.testing.expectEqual(BUDGET, s.sess.casts_left[s.p[0].pid]);
    try std.testing.expectEqual(@as(usize, 0), s.sess.pending_count);

    var msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .shape_cast));

    // The FREE move still works with the pool at zero: the economy has a floor
    // a team can never fall through.
    s.p[1].clear();
    try enqueue_cast_as(&s.sess, s.p[0].pid, TRICKLE);
    try flush_and_resolve(&s.sess);

    try std.testing.expectEqual(@as(u16, 1), count_defused(&s.sess));
    msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .shape_cast));
}

test "escape takes back a lock-in, refunding the slot and the budget it held" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    s.sess.charges = 9;

    const pid = s.p[0].pid;
    aim_at(&s.sess, pid, 2, 5);
    try enqueue_cast_as(&s.sess, pid, DELUGE); // 9: the whole pool
    try flush(&s.sess);
    try std.testing.expectEqual(@as(usize, 1), s.sess.pending_count);

    // Taking it back frees the slot AND the charges it had reserved, so the
    // turn can spend them on something else.
    try enqueue_cancel(&s.sess, pid);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(usize, 0), s.sess.pending_count);
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[pid]);

    try enqueue_cast_as(&s.sess, pid, BLOCK);
    try flush_and_resolve(&s.sess);
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));
}

test "escape takes back one cast per press, newest first, and only your own" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // p0 locks in a poke then a sweep; p1 locks in a block in between.
    aim_at(&s.sess, s.p[0].pid, 2, 2);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    aim_at(&s.sess, s.p[1].pid, 4, 7);
    try enqueue_cast_as(&s.sess, s.p[1].pid, BLOCK);
    try flush(&s.sess);
    aim_at(&s.sess, s.p[0].pid, 0, 4);
    try enqueue_cast_as(&s.sess, s.p[0].pid, SWEEP);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(usize, 3), s.sess.pending_count);

    // One press undoes p0's NEWEST — the sweep — and leaves p1's block alone.
    try enqueue_cancel(&s.sess, s.p[0].pid);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(usize, 2), s.sess.pending_count);

    try resolve_casts(&s.sess);
    // p0's poke and p1's block landed; the sweep never happened.
    try std.testing.expectEqual(@as(u16, 1 + 9), count_defused(&s.sess));
    try std.testing.expect(s.sess.field.grid.at(0, 4) == .tiered);
}

test "escape with nothing pending is a no-op, not a free cast" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    const pid = s.p[0].pid;
    for (0..3) |_| try enqueue_cancel(&s.sess, pid);
    try flush(&s.sess);

    // A budget cannot grow past its allowance by pressing undo.
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[pid]);
    try std.testing.expectEqual(@as(usize, 0), s.sess.pending_count);
    try std.testing.expectEqual(@as(u16, 1), s.sess.turn);
}

test "a group broadcasts one shape_cast and one team recipe fire" {
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
    try flush_and_resolve(&s.sess);

    // ONE stamp of the team's 5x5 diamond (13 cells), and it replaces the two
    // pokes that bought it.
    try std.testing.expectEqual(@as(u16, 13), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);

    // Each player was charged exactly one cast slot: a group is one purchase
    // made together, not an extra one.
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].casts);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[1].pid].casts);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.casts_total);

    const msgs = try drain(s.p[1].buf.items, arena);
    // Resolution broadcasts exactly one stamp, announced as the TEAM recipe —
    // the solo pokes it would otherwise have been never happened.
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .shape_cast));
    var team_fires: usize = 0;
    for (msgs) |m| {
        if (m.tag != .recipe_fired) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const rf = try proto.decode_recipe_fired(fbs.reader());
        try std.testing.expectEqual(proto.RecipeKind.team, rf.kind);
        try std.testing.expectEqual(TWIN_BLOOM, rf.index);
        team_fires += 1;
    }
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
    try std.testing.expectEqual(@as(usize, 2), s.sess.pending_count);

    // Both land as themselves: a square with no full bag on it is just a list
    // of moves.
    try resolve_casts(&s.sess);
    try std.testing.expectEqual(@as(u16, 4), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[CROSSFIRE]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.player_recipe_hits[SWEEP]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.player_recipe_hits[POKE]);
}

test "a group the turn cannot afford refuses the cast that would form it" {
    // There is no fallback: joining a square turns the whole square into the
    // group, so a group out of reach makes the JOINING cast out of reach too.
    // The player is told and keeps their slot; the square stays as it was.
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

    // Three charges: three pokes' worth, but one short of twin_bloom's 4.
    s.sess.charges = 3;
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(usize, 1), s.sess.pending_count);

    s.p[1].clear();
    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    // Refused at 4-against-3, not quietly downgraded to a second poke.
    try std.testing.expectEqual(@as(usize, 1), s.sess.pending_count);
    const msgs = try drain(s.p[1].buf.items, arena);
    const msg = find_tag(msgs, .over_budget) orelse return error.MissingOverBudget;
    var fbs = std.io.fixedBufferStream(msg.payload);
    const ob = try proto.decode_over_budget(fbs.reader());
    try std.testing.expectEqual(@as(u32, 4), ob.needed);
    try std.testing.expectEqual(@as(u32, 3), ob.have);

    // The same poke one cell over is affordable, because it forms nothing.
    aim_at(&s.sess, s.p[1].pid, 2, 7);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush_and_resolve(&s.sess);

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
    try flush_and_resolve(&s.sess);

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
// recipe has a cost; a team recipe is charged once for the whole group.  The
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

test "the pool starts at the encounter's charges and is not refilled by a turn" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    try std.testing.expectEqual(@as(u32, 10), s.sess.charges);

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK); // costs the default 1
    try flush_and_resolve(&s.sess);
    try std.testing.expectEqual(@as(u32, 9), s.sess.charges);

    // Crossing a turn boundary must NOT hand the charge back: the pool is the
    // budget for the whole encounter, not for the turn.
    try end_turn_mid_game(&s.sess);
    try std.testing.expectEqual(@as(u32, 9), s.sess.charges);
}

test "each recipe debits its own cost, and a free recipe debits nothing" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, TRICKLE); // cost 0
    try flush_and_resolve(&s.sess);
    try std.testing.expectEqual(@as(u32, 10), s.sess.charges);
    // Free does not mean inert: the shape still landed.
    try std.testing.expectEqual(c.SlimeCell.neutralized, s.sess.field.grid.at(2, 5));

    aim_at(&s.sess, s.p[1].pid, 2, 2);
    try enqueue_cast_as(&s.sess, s.p[1].pid, DELUGE); // cost 9
    try flush_and_resolve(&s.sess);
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

    // Drain the pool to 1 with one deluge.
    aim_at(&s.sess, s.p[0].pid, 2, 2);
    try enqueue_cast_as(&s.sess, s.p[0].pid, DELUGE);
    try flush_and_resolve(&s.sess);
    try std.testing.expectEqual(@as(u32, 1), s.sess.charges);

    const before = s.sess.field.grid;
    s.p[0].clear();
    const budget_before = s.sess.casts_left[s.p[0].pid];

    // A second deluge costs 9 against a pool of 1.
    aim_at(&s.sess, s.p[0].pid, 4, 7);
    try enqueue_cast_as(&s.sess, s.p[0].pid, DELUGE);
    try flush(&s.sess);

    // Nothing happened to the field, nothing left the pool, and the slot is
    // still theirs to spend on something cheaper.  (A team that can afford
    // NOTHING is not left hanging either — see the stranding test below.)
    try std.testing.expect(grids_equal(before, s.sess.field.grid));
    try std.testing.expectEqual(@as(u32, 1), s.sess.charges);
    try std.testing.expectEqual(budget_before, s.sess.casts_left[s.p[0].pid]);

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
    try flush_and_resolve(&s.sess);

    // 0 <= 0, so the pool can pay.  A zero-cost recipe is the floor the
    // economy can never fall through.
    try std.testing.expectEqual(c.SlimeCell.neutralized, s.sess.field.grid.at(3, 4));
    try std.testing.expectEqual(@as(u32, 0), s.sess.charges);
}

test "a group is charged the group cost INSTEAD of its components' costs" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // A lock-in reserves nothing on its own: the pool is untouched until the
    // whole turn is priced.
    aim_at(&s.sess, s.p[0].pid, 3, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 10), s.sess.charges);

    // The pair becomes twin_bloom, and twin_bloom's 4 is the WHOLE bill: the
    // pokes are what the group is made of, not an extra line item.
    aim_at(&s.sess, s.p[1].pid, 3, 5);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush_and_resolve(&s.sess);

    const group_cost = BAL.team_recipes[TWIN_BLOOM].cost;
    try std.testing.expectEqual(@as(u32, 10) - group_cost, s.sess.charges);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[TWIN_BLOOM]);
}

test "a group is affordable at the group price, not at its components' price" {
    // The quote is what the turn will actually cost, so a pair that could not
    // pay for two pokes AND a diamond can still buy the diamond.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    s.sess.charges = BAL.team_recipes[TWIN_BLOOM].cost; // exactly 4

    aim_at(&s.sess, s.p[0].pid, 3, 5);
    aim_at(&s.sess, s.p[1].pid, 3, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try enqueue_cast_as(&s.sess, s.p[1].pid, POKE);
    try flush_and_resolve(&s.sess);

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
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only); // 40 neutral, roomy budget

    s.p[0].clear();
    // One feast eats all 40 and the reservoir has nothing to send back.
    try end_turn_idly(&s.sess);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);
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
    // hunger_base 3 → the pair's bar is 6.
    try init_two_player_session_cfg(&s, allocator, SEED, &HungerBase(3).cfg);
    defer s.deinit();
    // 8 edible units on the field against a bar of 6: the feast overfills it.
    try start(&s, &enc_paper_stomach);
    // Hold one unit back so the field is NOT cleared by the feast: the loss has
    // to be unambiguous.
    s.sess.field.grid.put(8, .empty);
    s.sess.field.reservoir = .{ .neutral = 1 };

    s.p[0].clear();
    try end_turn_idly(&s.sess);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);
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
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_tight_budget); // duo bar 200 — hunger never binds here
    set_block_field(&s.sess, tiered(.green), 2, 5);

    // One `block` stamp defuses the whole field.  Left alone, those 9 cells are
    // walls: no hunger, no score, and the encounter never ends.  Defused, they
    // are 9 units of reachable food — the entire difference between playing and
    // not playing.
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_cast_as(&s.sess, s.p[0].pid, BLOCK);
    try flush_and_resolve(&s.sess);
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));

    try end_turn_idly(&s.sess);

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
    // players): the field empties as the bar fills.
    try init_two_player_session_cfg(&s, allocator, SEED, &HungerBase(1).cfg);
    defer s.deinit();
    const encounter = enc.Encounter{
        .label = "test_exact",
        .slime = .{ .neutral = 2 },
    };
    try start(&s, &encounter);

    s.p[0].clear();
    try end_turn_idly(&s.sess); // the feast eats 2 units for 2 hunger

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);
    const go = try game_over_msg(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(proto.EndReason.field_cleared, go.stats.reason);
}

// ---------------------------------------------------------------------------
// Running the pool dry
//
// These use `priced_config`, whose cheapest move costs 1.  The default fixture
// has the free `trickle`, so its `cheapest_cost` is 0 and a team there can
// never be unable to act — which is deliberate, and which makes these tests
// impossible to write against it.
// ---------------------------------------------------------------------------

/// A pair on the priced table, mid-encounter, with a pool the test sets itself.
fn init_priced_session(s: *TwoPlayerSession, allocator: std.mem.Allocator) !void {
    try init_two_player_session_cfg(s, allocator, SEED, &fixtures.priced_config);
}

test "an empty pool ends the game even when the feast is still eating" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_priced_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only); // 40 neutral, roomy bar

    // Plenty of food left and plenty of room to eat it — the ONLY thing wrong
    // is that the team cannot cast.  A feast that eats is not a reprieve: with
    // no charges there are no decisions left to make, so the encounter is over.
    set_field(&s.sess, .{ .neutral = {} }, 10);
    s.sess.field.reservoir = .{ .neutral = 5 }; // field cannot clear
    s.sess.charges = 0;

    s.p[0].clear();
    try end_turn_idly(&s.sess);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);
    const msgs = try drain(s.p[0].buf.items, arena);
    const te_msg = find_tag(msgs, .turn_ended) orelse return error.NoTurnEnded;
    var te_fbs = std.io.fixedBufferStream(te_msg.payload);
    const te = try proto.decode_turn_ended(te_fbs.reader());
    try std.testing.expect(te.cells_eaten > 0); // the closing feast DID eat

    const go = try game_over_msg(msgs);
    try std.testing.expectEqual(proto.EndReason.out_of_charges, go.stats.reason);
    try std.testing.expect(go.stats.slime_left > 0);
}

test "a pool that can still afford the cheapest move keeps the game going" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_priced_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    set_field(&s.sess, .{ .neutral = {} }, 10);
    s.sess.field.reservoir = .{ .neutral = 5 };

    // One charge, and `poke` costs exactly one: the team has a move, so it has
    // a game.  This is the boundary the end condition is written against.
    s.sess.charges = fixtures.priced_config.balance.cheapest_cost();
    try end_turn_idly(&s.sess);

    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);
}

test "going broke mid-turn strands the casts still owed and settles the turn" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_priced_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    set_field(&s.sess, .{ .neutral = {} }, 10);
    s.sess.field.reservoir = .{ .neutral = 5 };

    // Exactly one poke's worth.  Alice commits it; Bob's three casts and
    // Alice's remaining two could then only be refused, so the turn must not
    // wait on them.
    s.sess.charges = 1;
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[s.p[1].pid]);

    s.p[0].clear();
    aim_at(&s.sess, s.p[0].pid, 0, 0);
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);

    // Settled in the same drain as the cast: no second flush, and Bob was never
    // asked for input he had no way to spend.
    try std.testing.expectEqual(@as(u32, 0), s.sess.charges);
    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);

    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expect(find_tag(msgs, .turn_ended) != null);
    // Stranded, not refused: the casts were never attempted, so nobody is told
    // they could not pay for one.
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .over_budget));

    const go = try game_over_msg(msgs);
    try std.testing.expectEqual(proto.EndReason.out_of_charges, go.stats.reason);
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
    try end_turn_idly(&s.sess);

    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[s.p[0].pid]);
}

// ---------------------------------------------------------------------------
// The closing broadcast
// ---------------------------------------------------------------------------

test "the game-ending turn sends the post-feast board before game_over" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    // hunger_base 3 → a duo bar of 6, so one feast overfills it.
    try init_two_player_session_cfg(&s, allocator, SEED, &HungerBase(3).cfg);
    defer s.deinit();
    try start(&s, &enc_paper_stomach);
    s.sess.field.grid.put(8, .empty);
    s.sess.field.reservoir = .{ .neutral = 1 };

    s.p[0].clear();
    try end_turn_idly(&s.sess);

    const msgs = try drain(s.p[0].buf.items, arena);

    // ORDER IS THE POINT.  `tick` stops broadcasting state once the session
    // leaves `.playing`, so without the explicit send in `end_game` the last
    // board a client ever sees is the one from before the closing feast: it
    // would be told the game ended on a board still holding the slime that
    // ended it.  Clients replay that feast as their outro and need the board it
    // lands on.
    var saw_turn_ended = false;
    var saw_state_after = false;
    var saw_game_over = false;
    for (msgs) |m| switch (m.tag) {
        .turn_ended => saw_turn_ended = true,
        .game_state => if (saw_turn_ended and !saw_game_over) {
            saw_state_after = true;
        },
        .game_over => saw_game_over = true,
        else => {},
    };
    try std.testing.expect(saw_turn_ended);
    try std.testing.expect(saw_state_after);
    try std.testing.expect(saw_game_over);

    // And it is the FINAL board, not a stale one: what the wire carried is what
    // the field holds now that the feast, the collapse and the refill are done.
    const gs = try last_game_state(msgs);
    try std.testing.expectEqual(s.sess.field.grid.rows, gs.grid_rows);
    try std.testing.expectEqual(s.sess.field.grid.cols, gs.grid_cols);
    for (s.sess.field.grid.live(), gs.grid[0..gs.grid_len()]) |have, sent| {
        try std.testing.expect(std.meta.eql(have, sent));
    }
    try std.testing.expectEqual(s.sess.hunger.current, gs.hunger.current);
}

test "game over resets ready flags" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    s.sess.players[s.p[0].pid].ready = true;
    s.sess.players[s.p[1].pid].ready = true;
    try start(&s, &enc_neutral_only);

    try end_turn_idly(&s.sess);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);
    try std.testing.expect(!s.sess.players[s.p[0].pid].ready);
    try std.testing.expect(!s.sess.players[s.p[1].pid].ready);
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
    // Same 25-unit mix as `enc_mixed`, but with a hunger bar the single feast
    // below fills exactly (hunger_base 4 × two players = 8) — that is what
    // makes the game end and the report get sent inside one turn.
    try init_two_player_session_cfg(&s, allocator, SEED, &HungerBase(4).cfg);
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
    //
    // Row 1's red run is a near-total wall, which is the point: it decides who
    // gets eaten and who merely watches.
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

    // The turn ends.  The flood enters at column 0 and finds:
    //   (0,0) defused by Alice -> eaten, but boxed in by green and red.
    //   (2,0) neutral -> eaten, and it opens the row-2 corridor rightwards,
    //         which wraps up column 9 to eat the two neutrals at (1,8)/(1,9).
    //   Bob's three defused cells at (0,3..5) are walled off on every side.
    try end_turn_idly(&s.sess);

    const go = try game_over_msg(try drain(s.p[0].buf.items, arena));
    const st = go.stats;

    try std.testing.expectEqual(proto.EndReason.hunger_full, st.reason);
    try std.testing.expectEqual(@as(u32, 25), st.slime_total);
    // 8 of 25 eaten; the other 17 are walls or shut in behind them.
    try std.testing.expectEqual(@as(u32, 17), st.slime_left);
    try std.testing.expectEqual(@as(u16, 2), st.casts_total);

    // Coverage: 4 green cells covered (1 poke + 3 sweep), all defused since
    // green is one step from harmless.  No red was ever covered.
    try std.testing.expectEqual(@as(u16, 4), st.feast.cells_covered[GREEN]);
    try std.testing.expectEqual(@as(u16, 0), st.feast.cells_covered[RED]);
    try std.testing.expectEqual(@as(u16, 4), st.feast.neutralized[GREEN]);
    // Eaten: 7 neutral plus Alice's single defused cell.
    try std.testing.expectEqual(@as(u16, 7), st.feast.neutral_consumed);
    try std.testing.expectEqual(@as(u16, 1), st.feast.defused_consumed);
    // Bob defused three cells that nothing could reach.  Work that scores
    // nothing is the report's most useful number, so it is tracked on its own.
    try std.testing.expectEqual(@as(u16, 3), st.feast.sheltered);
    try std.testing.expectEqual(@as(u16, @intCast(8 * BAL.hunger_cost_normal)), st.feast.hunger_normal);
    // Two casts at the fixture default of 1 charge each, out of a pool of 50.
    try std.testing.expectEqual(@as(u16, 2), st.feast.charges_spent);
    try std.testing.expectEqual(@as(u32, 48), st.feast.charges_left);
    // Score = every unit eaten, defused or neutral alike.
    try std.testing.expectEqual(@as(u32, 8), go.score);

    // Players: dense, named, coverage attribution + recipe participation.
    try std.testing.expectEqual(@as(u8, 2), st.player_count);
    try std.testing.expectEqualSlices(u8, "Alice", st.players[0].name[0..st.players[0].name_len]);
    try std.testing.expectEqual(@as(u16, 1), st.players[0].casts);
    try std.testing.expectEqual(@as(u16, 1), st.players[0].cells_covered);
    try std.testing.expectEqual(@as(u16, 1), st.players[0].cells_neutralized);
    try std.testing.expectEqual(@as(u16, 1), st.players[0].recipe_casts);
    try std.testing.expectEqualSlices(u8, "Bob", st.players[1].name[0..st.players[1].name_len]);
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
    try std.testing.expectEqual(2 * logic.player_hunger(BAL, 0), gs.hunger.max);
    try std.testing.expectEqual(@as(u16, 0), gs.hunger.current);
    try std.testing.expectEqual(@as(u32, 0), gs.score);
}

test "game_state reflects the turn counter and the stamps a turn resolved" {
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
    try flush_and_resolve(&s.sess);
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
    // Mid-turn: nothing has been eaten yet, and the turn number is on the wire.
    try std.testing.expectEqual(@as(u16, 1), gs.turn);
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

test "game_state carries the turn number and each player's remaining casts" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    // Turn 1, nobody has cast: everyone shows a full budget.
    s.p[1].clear();
    try flush(&s.sess);
    var gs = try last_game_state(try drain(s.p[1].buf.items, arena));
    try std.testing.expectEqual(@as(u16, 1), gs.turn);
    for (gs.entities[0..gs.entity_count]) |e| {
        try std.testing.expectEqual(BUDGET, e.casts_left);
    }

    // After one cast only the caster's budget drops: budgets are per player.
    s.p[1].clear();
    try enqueue_cast_as(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    gs = try last_game_state(try drain(s.p[1].buf.items, arena));
    try std.testing.expectEqual(@as(u16, 1), gs.turn);
    var found_caster = false;
    for (gs.entities[0..gs.entity_count]) |e| {
        if (e.owner == s.p[0].pid) {
            try std.testing.expectEqual(BUDGET - 1, e.casts_left);
            found_caster = true;
        } else {
            try std.testing.expectEqual(BUDGET, e.casts_left);
        }
    }
    try std.testing.expect(found_caster);

    // The turn rolls over: a fresh number and refilled budgets on the wire.
    s.p[1].clear();
    try end_turn_mid_game(&s.sess);
    gs = try last_game_state(try drain(s.p[1].buf.items, arena));
    try std.testing.expectEqual(@as(u16, 2), gs.turn);
    for (gs.entities[0..gs.entity_count]) |e| {
        try std.testing.expectEqual(BUDGET, e.casts_left);
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

    s.p[0].clear();
    try flush(&s.sess);
    const before = try last_game_state(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(@as(u32, 10), before.charges);

    aim_at(&s.sess, s.p[0].pid, 2, 2);
    try enqueue_cast_as(&s.sess, s.p[0].pid, DELUGE); // cost 9
    try flush(&s.sess);

    // Locked in is not paid for: the figure only moves when the turn resolves.
    const locked = try last_game_state(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(@as(u32, 10), locked.charges);

    try resolve_casts(&s.sess);
    s.p[0].clear();
    try flush(&s.sess);

    const after = try last_game_state(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(@as(u32, 1), after.charges);
    try std.testing.expectEqual(s.sess.charges, after.charges);
}

test "game_state carries the turn's pending casts, so everyone sees the plan" {
    // Lock-ins are the only thing a teammate can coordinate around before the
    // turn resolves, so the snapshot has to carry all of them, not just yours.
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
    try std.testing.expectEqual(@as(u8, 2), gs.pending_count);
    // In lock-in order, each naming its caster, its move and its square.
    try std.testing.expectEqual(s.p[0].pid, gs.pending[0].player_id);
    try std.testing.expectEqual(BLOCK, gs.pending[0].move);
    try std.testing.expectEqual(grid.index(2, 5), gs.pending[0].square);
    try std.testing.expectEqual(s.p[1].pid, gs.pending[1].player_id);
    try std.testing.expectEqual(POKE, gs.pending[1].move);
    try std.testing.expectEqual(grid.index(4, 8), gs.pending[1].square);

    // Resolved and gone: the plan is only ever the CURRENT turn's.
    try resolve_casts(&s.sess);
    s.p[0].clear();
    try flush(&s.sess);
    const done = try last_game_state(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(@as(u8, 0), done.pending_count);
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
    const late_pid = s.sess.join(late.transport(), "Zed") orelse return error.JoinFailed;
    late.pid = late_pid;

    var name = proto.JoinLobby{ .name = [_]u8{0} ** 16, .name_len = 3 };
    @memcpy(name.name[0..3], "Zed");
    try enqueue_msg(&s.sess, late_pid, .join_lobby, name);
    try flush(&s.sess);

    const msgs = try drain(late.buf.items, arena);
    const gs_msg = find_tag(msgs, .game_start) orelse return error.NoGameStart;
    var fbs = std.io.fixedBufferStream(gs_msg.payload);
    const start_msg = try proto.decode_game_start(fbs.reader());
    try std.testing.expectEqual(BAL.slime_grid.rows, start_msg.grid_rows);
    try std.testing.expectEqual(BAL.slime_grid.cols, start_msg.grid_cols);
    try std.testing.expectEqual(late_pid, start_msg.player_id);
    try std.testing.expect(s.sess.players[late_pid].entity != session_mod.NO_ENTITY);

    // The joiner arrives with a full budget for the turn already in progress,
    // and holds it open until they have cast.
    try std.testing.expectEqual(BAL.casts_per_turn, start_msg.casts_per_turn);
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[late_pid]);
}

test "a repeated join_lobby does not duplicate the player's entity" {
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
    const late_pid = s.sess.join(late.transport(), "Zed") orelse return error.JoinFailed;
    late.pid = late_pid;

    var name = proto.JoinLobby{ .name = [_]u8{0} ** 16, .name_len = 3 };
    @memcpy(name.name[0..3], "Zed");

    const before = s.sess.world.component_arrays.player_marker.size;
    try enqueue_msg(&s.sess, late_pid, .join_lobby, name);
    try flush(&s.sess);
    const after_first = s.sess.world.component_arrays.player_marker.size;
    try std.testing.expectEqual(before + 1, after_first);

    // A client that re-sends its name (reconnect handshake, retry, duplicate
    // input) must not gain a second body.
    try enqueue_msg(&s.sess, late_pid, .join_lobby, name);
    try flush(&s.sess);
    try std.testing.expectEqual(after_first, s.sess.world.component_arrays.player_marker.size);

    // ...and no two player entities may report the same owner.
    const pm = &s.sess.world.component_arrays.player_marker;
    var seen = [_]bool{false} ** session_mod.MAX_PLAYERS;
    for (pm.index_to_entity[0..pm.size]) |e| {
        const own = s.sess.world.get_component(e, c.Owner).player_id;
        try std.testing.expect(!seen[own]);
        seen[own] = true;
    }
}

test "disconnect in the lobby frees the slot" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();

    try std.testing.expectEqual(@as(u8, 2), s.sess.player_count);
    s.sess.disconnect(s.p[1].pid);
    try std.testing.expectEqual(@as(u8, 1), s.sess.player_count);
    try std.testing.expect(!s.sess.players[s.p[1].pid].occupied);
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
            s.sess.casts_left = [_]u8{0} ** session_mod.MAX_PLAYERS;
            try s.sess.tick(0.0);
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
// Appetite → hunger capacity
//
// The bar's capacity is the SUM of every present player's contribution,
// min(hunger_base + appetite * appetite_scale, hunger_player_cap) each — see
// game_logic.player_hunger.  Appetite arrives with join_lobby (a board's
// persistent flash stat, forwarded by the bridge); everyone else is 0.
// ---------------------------------------------------------------------------

/// Send `pid`'s join_lobby carrying `appetite` — the wire path a board-backed
/// player's stat actually takes.
fn enqueue_join(sess: *Session, pid: u8, name: []const u8, appetite: u32) !void {
    var p = proto.JoinLobby{
        .name = [_]u8{0} ** 16,
        .name_len = @intCast(name.len),
        .appetite = appetite,
    };
    @memcpy(p.name[0..name.len], name);
    try enqueue_msg(sess, pid, .join_lobby, p);
}

test "the hunger bar sums each player's appetite contribution" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();

    // Alice joins with a board that has banked an appetite of 4; Bob has none.
    try enqueue_join(&s.sess, s.p[0].pid, "Alice", 4);
    try enqueue_join(&s.sess, s.p[1].pid, "Bob", 0);
    try flush(&s.sess);

    try start(&s, &enc_fifty_green);

    // 100 + 4*5 = 120 for Alice, 100 for Bob.
    const want = logic.player_hunger(BAL, 4) + logic.player_hunger(BAL, 0);
    try std.testing.expectEqual(want, s.sess.hunger.max);
    try std.testing.expectEqual(@as(u16, 220), s.sess.hunger.max);
}

test "a repeated join_lobby cannot inflate the bar" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try enqueue_join(&s.sess, s.p[0].pid, "Alice", 4);
    try flush(&s.sess);
    try start(&s, &enc_fifty_green);
    const before = s.sess.hunger.max;

    // The Zig client re-sends join_lobby when a stat line lands late; the
    // share is frozen at count time, so nothing may move.
    try enqueue_join(&s.sess, s.p[0].pid, "Alice", 9);
    try flush(&s.sess);
    try std.testing.expectEqual(before, s.sess.hunger.max);
}

test "a mid-game joiner grows the bar by their own contribution" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    const before = s.sess.hunger.max; // 200: two appetite-0 players

    var late = TestPlayer{};
    late.init(allocator);
    defer late.deinit(allocator);
    const late_pid = s.sess.join(late.transport(), "Zed") orelse return error.JoinFailed;
    try enqueue_join(&s.sess, late_pid, "Zed", 2);
    try flush(&s.sess);

    try std.testing.expectEqual(
        before + logic.player_hunger(BAL, 2),
        s.sess.hunger.max,
    );
}

test "a mid-game leave gives back the leaver's UNUSED share; a rejoin brings it all back" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green); // bar 200 (100 each)

    // Half the bar already eaten when Bob leaves: half of his 100 was still
    // unused, so exactly 50 comes off — and nothing already eaten moves.
    s.sess.hunger.current = 100;
    s.sess.disconnect(s.p[1].pid);
    try std.testing.expectEqual(@as(u16, 150), s.sess.hunger.max);
    try std.testing.expectEqual(@as(u16, 100), s.sess.hunger.current);

    // Bob returns: his FULL share rejoins the bar (the asymmetry is the
    // deliberate price of leaving), and a second reconnect changes nothing.
    try std.testing.expect(s.sess.reconnect(s.p[1].pid, s.p[1].transport()));
    try std.testing.expectEqual(@as(u16, 250), s.sess.hunger.max);
    try std.testing.expect(s.sess.reconnect(s.p[1].pid, s.p[1].transport()));
    try std.testing.expectEqual(@as(u16, 250), s.sess.hunger.max);
}

test "a lobby disconnect does not touch hunger accounting" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();

    // Still in the lobby: the slot simply empties; the next start recomputes
    // the bar from whoever is present.
    s.sess.disconnect(s.p[1].pid);
    try start(&s, &enc_fifty_green);
    try std.testing.expectEqual(logic.player_hunger(BAL, 0), s.sess.hunger.max);
}
