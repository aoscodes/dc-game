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
//!   - combo intake (latest preview wins, cancel clears)
//!   - aiming: server-authoritative per-player cursor, clamped at the edges;
//!     a cast is anchored where the player aimed at SUBMIT time
//!   - turn-based casting: a per-player per-turn budget, casts resolving
//!     IMMEDIATELY, unpaired team halves HELD until a partner or turn end
//!   - shape stamping: a matched recipe's footprint downgrades every covered
//!     hazard cell by exactly one tier (red→yellow→green→defused); cells off
//!     the grid edge are clipped, non-hazard cells are inert
//!   - turn end: the PATHED feast (flood from the left edge, live hazards and
//!     specials as walls), gravity collapse, refill, held halves fizzling and
//!     budgets reset — in that order
//!   - the shared charge pool: one per game, never refilled, per-recipe cost,
//!     team recipes charged once for the group, and the fizzle-but-spend rule
//!     when the pool cannot pay
//!   - hunger accounting: a flat cost per unit EATEN, and nothing else
//!   - score = units eaten (all of which are neutral or defused)
//!   - end conditions: field cleared / hunger bar full / dead position with an
//!     empty pool, all checked at turn end
//!   - wire contents: grid, reservoir, turn, cursors, cast budgets, charges

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;
const logic = shared.game_logic;
const enc = shared.encounter;
const fixtures = shared.fixtures;

const session_mod = @import("session.zig");
const Session = session_mod.Session;

const mk = c.make_combo;

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

/// Fixture recipe combos, by the shape they stamp.  Kept as named consts so a
/// test reads as an intent ("stamp a 3x3 block") rather than a slot soup.
const POKE = mk(&.{D}); // "#"
const SWEEP = mk(&.{ D, D }); // "###"
const BLOCK = mk(&.{ D, D, D }); // 3x3
const TRICKLE = mk(&.{ M, M }); // "#", costs 0 charges — the free move
const DELUGE = mk(&.{ M, M, M }); // 3x3, costs 9 charges — the expensive move
const BLOOM_HALF = mk(&.{ D, M }); // half of team twin_bloom (5x5 diamond)
const CROSSFIRE_A = mk(&.{ M, D });
const CROSSFIRE_B = mk(&.{ M, D, D });
/// Matches nothing in the fixture tables.  There is NO flat fallback, so this
/// always fizzles — the recipe list is the complete move list.
const UNMATCHED = mk(&.{ D, D, D, D, D });

const D = c.ComboSlot{ .action = .dispense };
const M = c.ComboSlot{ .action = .catalyst };

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
    .hunger_max = 1000,
    .slime = .{ .tiered = .{ 0, 0, 20 } },
};

/// 20 red hazard units: red needs THREE stamps per cell to defuse.
const enc_twenty_red = enc.Encounter{
    .label = "test_twenty_red",
    .hunger_max = 1000,
    .slime = .{ .tiered = .{ 20, 0, 0 } },
};

/// 50 green units — more than any single shape covers, so casts only ever
/// clear part of the field.
const enc_fifty_green = enc.Encounter{
    .label = "test_fifty_green",
    .hunger_max = 1000,
    .slime = .{ .tiered = .{ 0, 0, 50 } },
};

/// Mixed tiers + neutral: 10 red + 8 green + 7 neutral = 25 units.
const enc_mixed = enc.Encounter{
    .label = "test_mixed",
    .hunger_max = 1000,
    .slime = .{ .tiered = .{ 10, 0, 8 }, .neutral = 7 },
};

/// Tiny hunger budget of EDIBLE units, so one feast overfills the bar.  Live
/// hazards would be walls and cost nothing, so this has to be neutral slime.
/// Retained shape: exactly as many units as one `block` stamp covers
/// (3x3 = 9).  Eating them live costs 3 each, so the bar fills on the 8th unit
/// — BEFORE the field empties, which is what makes the loss unambiguous (a
/// simultaneous clear would win the tie).  Defusing them first costs 9 total,
/// a comfortable clear.
const enc_tight_budget = enc.Encounter{
    .label = "test_tight_budget",
    .hunger_max = 20,
    .slime = .{ .neutral = 9 },
};

/// A bar so small that one modest feast overfills it — the shortest path to a
/// clean `hunger_full` loss with slime still on the board.
const enc_paper_stomach = enc.Encounter{
    .label = "test_paper_stomach",
    .hunger_max = 5,
    .slime = .{ .neutral = 9 },
};

/// Neutral-only: nothing walls the flood off, so the whole field is reachable
/// from the first turn and every unit scores.
const enc_neutral_only = enc.Encounter{
    .label = "test_neutral_only",
    .hunger_max = 1000,
    .slime = .{ .neutral = 40 },
};

/// More slime than the 60-cell fixture grid holds: 80 units, so 20 always
/// start in the reservoir.
const enc_overflow = enc.Encounter{
    .label = "test_overflow",
    .hunger_max = 1000,
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
        .choose_combo => if (proto.decode_choose_combo(r)) |_| true else |_| false,
        .submit_spell => if (proto.decode_submit_spell(r)) |_| true else |_| false,
        .cancel_combo => true, // zero-payload
        .lobby_update => if (proto.decode_lobby_update(r)) |_| true else |_| false,
        .game_start => if (proto.decode_game_start(r)) |_| true else |_| false,
        .game_state => if (proto.decode_game_state(r)) |_| true else |_| false,
        .action_result => if (proto.decode_action_result(r)) |_| true else |_| false,
        .game_over => if (proto.decode_game_over(r)) |_| true else |_| false,
        .cast_committed => if (proto.decode_cast_committed(r)) |_| true else |_| false,
        .cast_fizzled => if (proto.decode_cast_fizzled(r)) |_| true else |_| false,
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

fn enqueue_combo(sess: *Session, pid: u8, combo: c.ActionCombo) !void {
    try enqueue_msg(sess, pid, .choose_combo, proto.ChooseCombo{ .combo = combo });
}

fn enqueue_submit(sess: *Session, pid: u8, combo: c.ActionCombo) !void {
    try enqueue_msg(sess, pid, .submit_spell, proto.SubmitSpell{ .combo = combo });
}

/// Drain queues and broadcast.  Casts resolve inside the drain, so this is the
/// workhorse for "apply the queued input, then look".  `dt` is unused by the
/// turn loop, so a flush advances nothing on its own.
fn flush(sess: *Session) !void {
    try sess.tick(0.0);
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
    self.allocator = allocator;
    self.p[0].buf = .empty;
    self.p[1].buf = .empty;
    self.p[0].init(allocator);
    self.p[1].init(allocator);

    self.sess = try Session.init_seeded(allocator, "TSTKEY".*, TEST_CFG, seed);

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

    try std.testing.expectEqual(@as(u16, DEFAULT_ENC.hunger_max), s.sess.hunger.max);
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
        try enqueue_submit(&s.sess, s.p[0].pid, POKE);
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
// Combo intake (live preview)
// ---------------------------------------------------------------------------

test "choose_combo stores the latest preview; cancel clears it" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    const combo_a = POKE;
    const combo_b = SWEEP;

    try enqueue_combo(&s.sess, s.p[0].pid, combo_a);
    try flush(&s.sess);
    try std.testing.expect(logic.combos_equal(combo_a, s.sess.action_pool[s.p[0].pid].?));

    // Latest edit wins.
    try enqueue_combo(&s.sess, s.p[0].pid, combo_b);
    try flush(&s.sess);
    try std.testing.expect(logic.combos_equal(combo_b, s.sess.action_pool[s.p[0].pid].?));

    try enqueue_msg(&s.sess, s.p[0].pid, .cancel_combo, {});
    try flush(&s.sess);
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.action_pool[s.p[0].pid]);
}

test "submitting clears the live preview" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    const combo = BLOOM_HALF; // [dispense, catalyst] — two distinguishable slots
    try enqueue_combo(&s.sess, s.p[0].pid, combo);
    try flush(&s.sess);
    try enqueue_submit(&s.sess, s.p[0].pid, combo);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.action_pool[s.p[0].pid]);
    // BLOOM_HALF is an unpaired team half, so it is HELD rather than resolved.
    try std.testing.expect(logic.combos_equal(combo, s.sess.held_pool[s.p[0].pid].?));
}

// ---------------------------------------------------------------------------
// Shape stamping
//
// A matched recipe stamps its shape at the caster's cast anchor, downgrading
// every covered HAZARD cell by exactly one tier.  These tests pin the grid with
// `set_field`/`paint_grid`; a cast resolves the moment it is drained, so a stamp
// is fully deterministic: shape placement is arithmetic, not PRNG.
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
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK);
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
    try enqueue_submit(&s.sess, s.p[0].pid, POKE);
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
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK);
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
    try enqueue_submit(&s.sess, pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(c.Tier.yellow, s.sess.field.grid.at(3, 4).tiered);

    // Cast 2: yellow → green.
    aim_at(&s.sess, pid, 3, 4);
    try enqueue_submit(&s.sess, pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(c.Tier.green, s.sess.field.grid.at(3, 4).tiered);

    // Cast 3: green → defused, and no further.
    try s.sess.tick(1.0);
    aim_at(&s.sess, pid, 3, 4);
    try enqueue_submit(&s.sess, pid, POKE);
    try flush(&s.sess);
    try std.testing.expect(s.sess.field.grid.at(3, 4) == .neutralized);

    // A fourth cast is inert: a defused cell cannot be downgraded further.
    try s.sess.tick(1.0);
    aim_at(&s.sess, pid, 3, 4);
    try enqueue_submit(&s.sess, pid, POKE);
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
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK);
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
        .hunger_max = 1000,
        .slime = .{ .tiered = .{ 0, 0, 80 } },
    };
    try start(&s, &encounter);
    try std.testing.expectEqual(@as(u16, 60), count_tier(&s.sess, .green));

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK);
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
    try enqueue_submit(&s.sess, s.p[0].pid, SWEEP);
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
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK);
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

test "a fizzled cast broadcasts no shape_cast" {
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
    // No recipe table entry matches this combo, and there is no flat
    // fallback — the recipe list IS the move list, so this is a no-op.
    const unmatched = mk(&.{ D, D, D, D, D });
    try enqueue_submit(&s.sess, s.p[0].pid, unmatched);
    try flush(&s.sess);

    const msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .shape_cast));
    try std.testing.expect(find_tag(msgs, .cast_fizzled) != null);
}

test "a team recipe stamps one big shape; a half alone stamps nothing" {
    const allocator = std.testing.allocator;

    // Together: twin_bloom's 5x5 diamond = 13 cells, one stamp.
    var together: TwoPlayerSession = undefined;
    try init_two_player_session(&together, allocator);
    defer together.deinit();
    try start(&together, &enc_fifty_green);
    paint_grid(&together.sess, tiered(.green));
    together.sess.field.reservoir = .{};
    aim_at(&together.sess, together.p[0].pid, 2, 5);
    aim_at(&together.sess, together.p[1].pid, 2, 5);
    try enqueue_submit(&together.sess, together.p[0].pid, BLOOM_HALF);
    try enqueue_submit(&together.sess, together.p[1].pid, BLOOM_HALF);
    try flush(&together.sess);

    try std.testing.expectEqual(@as(u16, 13), count_defused(&together.sess));
    try std.testing.expectEqual(@as(u16, 1), together.sess.stats.team_recipe_hits[0]);

    // Alone: a single half matches no PLAYER recipe, so it stamps nothing and
    // simply waits to be held.
    var alone: TwoPlayerSession = undefined;
    try init_two_player_session(&alone, allocator);
    defer alone.deinit();
    try start(&alone, &enc_fifty_green);
    paint_grid(&alone.sess, tiered(.green));
    alone.sess.field.reservoir = .{};
    try enqueue_submit(&alone.sess, alone.p[0].pid, BLOOM_HALF);
    try flush(&alone.sess);

    try std.testing.expectEqual(@as(u16, 0), count_defused(&alone.sess));
    try std.testing.expectEqual(@as(u16, 0), alone.sess.stats.team_recipe_hits[0]);
    try std.testing.expect(alone.sess.held_pool[alone.p[0].pid] != null);
}

test "a held half resolves the moment a partner completes it" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // The halves arrive in SEPARATE drains, turns apart in wall-clock terms —
    // there is no window to miss, only a partner to wait for.
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_submit(&s.sess, s.p[0].pid, BLOOM_HALF);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 0), count_defused(&s.sess));

    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_submit(&s.sess, s.p[1].pid, BLOOM_HALF);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 13), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[0]);
    // Both halves have left the table.
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.held_pool[s.p[0].pid]);
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.held_pool[s.p[1].pid]);
}

test "a held half nobody completes fizzles at turn end, and is not refunded" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, .empty); // nothing to eat, so the game cannot end here
    s.sess.field.reservoir = .{ .neutral = 5 };

    const pid = s.p[0].pid;
    try enqueue_submit(&s.sess, pid, BLOOM_HALF);
    try flush(&s.sess);
    try std.testing.expect(s.sess.held_pool[pid] != null);
    try std.testing.expectEqual(BUDGET - 1, s.sess.casts_left[pid]);

    s.p[0].clear();
    try end_turn_idly(&s.sess);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msgs = try drain(s.p[0].buf.items, arena);

    // The half is gone and it announced its own failure...
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.held_pool[pid]);
    try std.testing.expect(find_tag(msgs, .cast_fizzled) != null);
    // ...and the cast it cost stays spent: the fresh budget is a NEW turn's,
    // not a refund of the old one.
    try std.testing.expectEqual(@as(u16, 2), s.sess.turn);
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[pid]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[pid].fizzles);
}

test "the team shape is anchored at the joiner's cursor" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // The two halves aim at opposite ends of the field.  p1 submits second, so
    // p1 completes the recipe and p1's cursor places the combined shape.
    aim_at(&s.sess, s.p[0].pid, 1, 1);
    try enqueue_submit(&s.sess, s.p[0].pid, BLOOM_HALF);
    try flush(&s.sess);
    aim_at(&s.sess, s.p[1].pid, 3, 7);
    try enqueue_submit(&s.sess, s.p[1].pid, BLOOM_HALF);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[0]);
    try std.testing.expectEqual(@as(u16, 13), count_defused(&s.sess));
    // The diamond's tip is two rows above the joiner's anchor...
    try std.testing.expect(s.sess.field.grid.at(1, 7) == .neutralized);
    // ...and nothing landed at the OTHER caster's cursor.
    try std.testing.expect(s.sess.field.grid.at(1, 1) == .tiered);
}

test "same player's own recipe halves never fire the team recipe" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // The same player casts the twin_bloom half twice.  Team recipes need
    // DISTINCT players, so the second cast cannot complete the recipe with the
    // player's own held half — it simply REPLACES it, still waiting.
    try enqueue_submit(&s.sess, s.p[0].pid, BLOOM_HALF);
    try flush(&s.sess);
    try enqueue_submit(&s.sess, s.p[0].pid, BLOOM_HALF);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 0), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[0]);
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

test "a held half keeps its anchor when the caster re-aims before the partner" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // p0's half is committed aiming low-right, then p0 wanders to the corner.
    aim_at(&s.sess, s.p[0].pid, 4, 8);
    try enqueue_submit(&s.sess, s.p[0].pid, BLOOM_HALF);
    try flush(&s.sess);
    aim_at(&s.sess, s.p[0].pid, 0, 0);

    // p1 completes it, so the JOINER aims: the combined shape lands on p1's
    // cursor and, crucially, not on p0's new one.
    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_submit(&s.sess, s.p[1].pid, BLOOM_HALF);
    try flush(&s.sess);

    try std.testing.expect(s.sess.field.grid.at(2, 5) == .neutralized);
    try std.testing.expect(s.sess.field.grid.at(0, 0) == .tiered);
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
        .hunger_max = 1000,
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
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);
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
// Fixture balance: casts_per_turn = 3 per PLAYER.  A cast resolves in the drain
// that accepts it; a team half with no partner is held; a combo that matches
// nothing fizzles for free.
// ---------------------------------------------------------------------------

test "an accepted cast resolves immediately and spends one budget slot" {
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
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);

    // The 3x3 block landed in the same drain that accepted it.
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));
    try std.testing.expectEqual(BUDGET - 1, s.sess.casts_left[s.p[0].pid]);
    // A resolved cast is not held: there is nothing left waiting.
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.held_pool[s.p[0].pid]);
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.action_pool[s.p[0].pid]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].casts);

    const msgs = try drain(s.p[1].buf.items, arena);
    // A cast that resolves announces its SHAPE, not a pending commitment.
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .shape_cast));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_committed));
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
        try enqueue_submit(&s.sess, pid, POKE);
        try flush(&s.sess);
    }
    try std.testing.expectEqual(@as(u8, 0), s.sess.casts_left[pid]);
    try std.testing.expect(s.sess.field.grid.at(3, 4) == .neutralized);

    // A fourth submit is silently ignored: no fizzle, no effect, no wire noise.
    s.p[1].clear();
    try enqueue_submit(&s.sess, pid, POKE);
    try flush(&s.sess);

    const msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .shape_cast));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_fizzled));
    try std.testing.expectEqual(@as(u16, BUDGET), s.sess.stats.players[pid].casts);
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
        try enqueue_submit(&s.sess, s.p[0].pid, POKE);
        try flush(&s.sess);
    }
    try std.testing.expectEqual(@as(u16, 1), s.sess.turn);

    // p1 spends all but one: still turn 1.
    for (0..BUDGET - 1) |_| {
        try enqueue_submit(&s.sess, s.p[1].pid, POKE);
        try flush(&s.sess);
    }
    try std.testing.expectEqual(@as(u16, 1), s.sess.turn);

    // The last cast in the room settles the turn and refills both budgets.
    try enqueue_submit(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 2), s.sess.turn);
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[s.p[0].pid]);
    try std.testing.expectEqual(BUDGET, s.sess.casts_left[s.p[1].pid]);
}

test "a zero-output submit fizzles for free" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    // No recipe covers this combo, so it fizzles and costs no budget: a typo
    // must not be able to burn a turn.
    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, UNMATCHED);
    try flush(&s.sess);

    try std.testing.expectEqual(BUDGET, s.sess.casts_left[s.p[0].pid]);
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.held_pool[s.p[0].pid]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].fizzles);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.players[s.p[0].pid].casts);

    var msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_fizzled));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .shape_cast));

    // A valid submit right after is accepted normally.
    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);

    try std.testing.expectEqual(BUDGET - 1, s.sess.casts_left[s.p[0].pid]);
    msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .shape_cast));
}

test "an unpaired team half is held and announced, not resolved" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, BLOOM_HALF);
    try flush(&s.sess);

    // Held: budget spent, nothing stamped, and the room is told to expect it.
    try std.testing.expect(s.sess.held_pool[s.p[0].pid] != null);
    try std.testing.expectEqual(BUDGET - 1, s.sess.casts_left[s.p[0].pid]);
    try std.testing.expectEqual(@as(u16, 0), count_defused(&s.sess));

    const msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_committed));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .shape_cast));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_fizzled));
}

test "completing a team recipe resolves both halves as one recipe fire" {
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

    const half = BLOOM_HALF; // [dispense, catalyst] — the twin_bloom recipe
    try enqueue_submit(&s.sess, s.p[0].pid, half);
    try flush(&s.sess);

    s.p[1].clear();
    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_submit(&s.sess, s.p[1].pid, half);
    try flush(&s.sess);

    // ONE stamp of the team's 5x5 diamond (13 cells), not two half-stamps.
    try std.testing.expectEqual(@as(u16, 13), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[0]);
    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);

    // Both halves left the table; each player was charged exactly one cast.
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.held_pool[s.p[0].pid]);
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.held_pool[s.p[1].pid]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].casts);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[1].pid].casts);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.casts_total);

    const msgs = try drain(s.p[1].buf.items, arena);
    // Exactly one TEAM recipe fire broadcast, and one stamp.
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .shape_cast));
    var team_fires: usize = 0;
    for (msgs) |m| {
        if (m.tag != .recipe_fired) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const rf = try proto.decode_recipe_fired(fbs.reader());
        try std.testing.expectEqual(proto.RecipeKind.team, rf.kind);
        try std.testing.expectEqual(@as(u8, 0), rf.index); // twin_bloom
        team_fires += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), team_fires);
}

test "a cast that resolves on its own leaves a teammate's unrelated half held" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // p0 holds a crossfire half — nothing p1 is about to do can complete it.
    try enqueue_submit(&s.sess, s.p[0].pid, CROSSFIRE_A);
    try flush(&s.sess);
    try std.testing.expect(s.sess.held_pool[s.p[0].pid] != null);

    // p1 casts a PLAYER recipe: it resolves on its own merits and must not
    // consume the bystanding half.
    aim_at(&s.sess, s.p[1].pid, 2, 5);
    try enqueue_submit(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);

    try std.testing.expect(s.sess.field.grid.at(2, 5) == .neutralized);
    try std.testing.expectEqual(@as(u16, 1), count_defused(&s.sess));
    try std.testing.expect(s.sess.held_pool[s.p[0].pid] != null);
}

test "resubmitting replaces a held half rather than stacking one up" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    const pid = s.p[0].pid;

    // Two DIFFERENT team halves in a row: a player holds at most one, so the
    // second replaces the first — and both casts are still charged.
    try enqueue_submit(&s.sess, pid, BLOOM_HALF);
    try flush(&s.sess);
    try enqueue_submit(&s.sess, pid, CROSSFIRE_A);
    try flush(&s.sess);

    try std.testing.expect(logic.combos_equal(CROSSFIRE_A, s.sess.held_pool[pid].?));
    try std.testing.expectEqual(BUDGET - 2, s.sess.casts_left[pid]);
    try std.testing.expectEqual(@as(u16, 0), count_defused(&s.sess));
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
    try enqueue_submit(&s.sess, s.p[0].pid, POKE); // `poke` = player_recipes[0]
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
// recipe has a cost; a team recipe is charged once for the whole group.  The
// fixture tables put a 0-cost recipe (`trickle`) and a 9-cost one (`deluge`) at
// the extremes so both "always affordable" and "cannot afford" are reachable.
// ---------------------------------------------------------------------------

/// Encounter with a deliberately tiny pool: enough for one `deluge` (9) and a
/// single charge over, so a second expensive cast must be refused.
const enc_thin_pool = enc.Encounter{
    .label = "test_thin_pool",
    .hunger_max = 1000,
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
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK); // costs the default 1
    try flush(&s.sess);
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
    try enqueue_submit(&s.sess, s.p[0].pid, TRICKLE); // cost 0
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 10), s.sess.charges);
    // Free does not mean inert: the shape still landed.
    try std.testing.expectEqual(c.SlimeCell.neutralized, s.sess.field.grid.at(2, 5));

    aim_at(&s.sess, s.p[1].pid, 2, 2);
    try enqueue_submit(&s.sess, s.p[1].pid, DELUGE); // cost 9
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 1), s.sess.charges);
    try std.testing.expectEqual(@as(u16, 9), s.sess.stats.feast.charges_spent);
}

test "a cast the pool cannot afford fizzles, and the cast budget is still spent" {
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
    try enqueue_submit(&s.sess, s.p[0].pid, DELUGE);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 1), s.sess.charges);

    const before = s.sess.field.grid;
    s.p[0].clear();
    const budget_before = s.sess.casts_left[s.p[0].pid];

    // A second deluge costs 9 against a pool of 1.
    aim_at(&s.sess, s.p[0].pid, 4, 7);
    try enqueue_submit(&s.sess, s.p[0].pid, DELUGE);
    try flush(&s.sess);

    // Nothing happened to the field and nothing left the pool...
    try std.testing.expect(grids_equal(before, s.sess.field.grid));
    try std.testing.expectEqual(@as(u32, 1), s.sess.charges);
    // ...but the turn moved on regardless.  This is the rule that keeps a
    // bankrupt team from stalling the room forever: being broke costs time.
    try std.testing.expectEqual(budget_before - 1, s.sess.casts_left[s.p[0].pid]);

    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_fizzled));
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
    try enqueue_submit(&s.sess, s.p[0].pid, TRICKLE);
    try flush(&s.sess);

    // 0 <= 0, so the pool can pay.  A zero-cost recipe is the floor the
    // economy can never fall through.
    try std.testing.expectEqual(c.SlimeCell.neutralized, s.sess.field.grid.at(3, 4));
    try std.testing.expectEqual(@as(u32, 0), s.sess.charges);
}

test "a team recipe is charged once for the group, not once per player" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // The first half is HELD, which must cost nothing: a player waiting for a
    // partner has not committed the team's charges yet.
    try enqueue_submit(&s.sess, s.p[0].pid, BLOOM_HALF);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 10), s.sess.charges);

    // The partner completes it: twin_bloom costs 4, once.
    aim_at(&s.sess, s.p[1].pid, 3, 5);
    try enqueue_submit(&s.sess, s.p[1].pid, BLOOM_HALF);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u32, 6), s.sess.charges);
}

test "an unaffordable team recipe fizzles as a whole, leaving no partial stamp" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_thin_pool);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    s.sess.charges = 3; // twin_bloom costs 4

    try enqueue_submit(&s.sess, s.p[0].pid, BLOOM_HALF);
    try flush(&s.sess);
    const before = s.sess.field.grid;

    aim_at(&s.sess, s.p[1].pid, 3, 5);
    try enqueue_submit(&s.sess, s.p[1].pid, BLOOM_HALF);
    try flush(&s.sess);

    // All or nothing: a group that cannot be paid for leaves the board alone.
    try std.testing.expect(grids_equal(before, s.sess.field.grid));
    try std.testing.expectEqual(@as(u32, 3), s.sess.charges);
    // The held half is released rather than silently re-held — the players saw
    // it fire, so the server must not keep it on the table behind their backs.
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.held_pool[s.p[0].pid]);
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
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    // 8 edible units on the field against a bar of 5: the feast overfills it.
    try start(&s, &enc_paper_stomach);
    // Hold one unit back so the field is NOT cleared by the feast: the loss has
    // to be unambiguous.
    s.sess.field.grid.put(8, .empty);
    s.sess.field.reservoir = .{ .neutral = 1 };

    s.p[0].clear();
    try end_turn_idly(&s.sess);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);
    try std.testing.expectEqual(@as(u16, 5), s.sess.hunger.current); // clamped at max

    const go = try game_over_msg(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(proto.EndReason.hunger_full, go.stats.reason);
    try std.testing.expectEqual(@as(u16, 5), go.stats.hunger_final);
    try std.testing.expectEqual(@as(u16, 5), go.stats.hunger_max);
    try std.testing.expectEqual(@as(u32, 9), go.stats.slime_total);
    // The bar filled before the field was cleared, so slime survives.
    try std.testing.expect(go.stats.slime_left > 0);
}

test "defusing the tight budget survives what idle play loses" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_tight_budget); // hunger_max 20
    set_block_field(&s.sess, tiered(.green), 2, 5);

    // One `block` stamp defuses the whole field.  Left alone, those 9 cells are
    // walls: no hunger, no score, and the encounter never ends.  Defused, they
    // are 9 units of reachable food — the entire difference between playing and
    // not playing.
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);
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
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    // 2 neutral units, hunger_max exactly 2: the field empties as the bar fills.
    const encounter = enc.Encounter{
        .label = "test_exact",
        .hunger_max = 2,
        .slime = .{ .neutral = 2 },
    };
    try start(&s, &encounter);

    s.p[0].clear();
    try end_turn_idly(&s.sess); // the feast eats 2 units for 2 hunger

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);
    const go = try game_over_msg(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(proto.EndReason.field_cleared, go.stats.reason);
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
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    // Same 25-unit mix as `enc_mixed`, but with a hunger bar the single feast
    // below fills exactly — that is what makes the game end and the report get
    // sent inside one turn.
    const enc_stats_mixed = enc.Encounter{
        .label = "test_stats_mixed",
        .hunger_max = 8,
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
    try enqueue_submit(&s.sess, s.p[0].pid, POKE);
    try enqueue_submit(&s.sess, s.p[1].pid, SWEEP);
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
    try std.testing.expectEqual(@as(u16, enc_overflow.hunger_max), gs.hunger.max);
    try std.testing.expectEqual(@as(u16, 0), gs.hunger.current);
    try std.testing.expectEqual(@as(u32, 0), gs.score);
}

test "game_state reflects the turn counter and stamps as they happen" {
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
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK); // 3x3 = 9 cells defused
    try flush(&s.sess);

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

test "game_state carries the live combo preview on the owner's entity" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    const combo = BLOOM_HALF; // [dispense, catalyst] — two distinguishable slots
    try enqueue_combo(&s.sess, s.p[0].pid, combo);

    s.p[0].clear();
    try flush(&s.sess);
    const gs = try last_game_state(try drain(s.p[0].buf.items, arena));

    var found = false;
    for (gs.entities[0..gs.entity_count]) |e| {
        if (e.owner != s.p[0].pid) {
            try std.testing.expectEqual(@as(u8, 0), e.combo_len);
            continue;
        }
        found = true;
        try std.testing.expectEqual(combo.len, e.combo_len);
        try std.testing.expectEqual(c.ActionChoice.dispense, e.combo_slots[0].action);
        try std.testing.expectEqual(c.ActionChoice.catalyst, e.combo_slots[1].action);
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
    try enqueue_submit(&s.sess, s.p[0].pid, POKE);
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
    try enqueue_submit(&s.sess, s.p[0].pid, DELUGE); // cost 9
    s.p[0].clear();
    try flush(&s.sess);

    const after = try last_game_state(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(@as(u32, 1), after.charges);
    try std.testing.expectEqual(s.sess.charges, after.charges);
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
    // by walking that array, and both the client's combo projection and the
    // team-recipe matcher treat one entity as one caster.  A duplicate would
    // project a player's combo twice and fake a two-player team recipe.
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
