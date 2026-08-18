//! Integration tests for the Slime Feast game session.
//!
//! Tests drive Session directly — no network, no threads.  Transport is a
//! BufferTransport that accumulates outgoing bytes.
//!
//! Every session here is created with `Session.init_seeded` and a PINNED seed,
//! so cell placement and Lil Guy targeting are both reproducible.  Where a test needs a specific grid layout it writes the
//! cells directly (`sess.field.grid.put`) after start, which is the only way
//! to assert exact per-cell outcomes without depending on the PRNG stream.
//!
//! Mechanics under test:
//!   - combo intake (latest preview wins, cancel clears)
//!   - aiming: server-authoritative per-player cursor, clamped at the edges;
//!     a cast is anchored where the player aimed at SUBMIT time
//!   - realtime casting: per-cast buffer, cast lock, replacement, team-recipe
//!     grouping, batch conversion
//!   - shape stamping: a matched recipe's footprint downgrades every covered
//!     hazard cell by exactly one tier (red→yellow→green→defused); cells off
//!     the grid edge are clipped, non-hazard cells are inert
//!   - eating: one Lil Guy per connected player, bite timers, misses, refill
//!     from the reservoir
//!   - hunger accounting: normal (unhealable) vs extra (healable) portions
//!   - symmetrical medicine: tier-X medicine heals only tier-X healable
//!     hunger; asymmetric medicine and overheal are discarded
//!   - score = neutral + defused units eaten
//!   - end conditions: field cleared / hunger bar full
//!   - wire contents: grid, reservoir, lil guys, cursors, cast countdowns

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
const TONIC = mk(&.{ M, M }); // "#" + medicine 6/6/6
const RED_TONIC = mk(&.{ M, M, M }); // "#" + medicine 10/0/0
const BLOOM_HALF = mk(&.{ D, M }); // half of team twin_bloom (5x5 diamond)
const CROSSFIRE_A = mk(&.{ M, D });
const CROSSFIRE_B = mk(&.{ M, D, D });
/// Matches nothing in the fixture tables.  There is NO flat fallback, so this
/// always fizzles — the recipe list is the complete move list.
const UNMATCHED = mk(&.{ D, D, D, D, D });

const D = c.ComboSlot{ .action = .dispense };
const M = c.ComboSlot{ .action = .medicine };

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

/// Tiny hunger budget, and exactly as many units as one `block` stamp covers
/// (3x3 = 9).  Eating them live costs 3 each, so the bar fills on the 8th unit
/// — BEFORE the field empties, which is what makes the loss unambiguous (a
/// simultaneous clear would win the tie).  Defusing them first costs 9 total,
/// a comfortable clear.
const enc_tight_budget = enc.Encounter{
    .label = "test_tight_budget",
    .hunger_max = 20,
    .slime = .{ .tiered = .{ 0, 0, 9 } },
};

/// Neutral-only: hunger from these units is never healable, and every unit
/// scores.
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
        .cast_grouped => if (proto.decode_cast_grouped(r)) |_| true else |_| false,
        .cast_replaced => if (proto.decode_cast_replaced(r)) |_| true else |_| false,
        .cast_fired => if (proto.decode_cast_fired(r)) |_| true else |_| false,
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

/// Drain queues and broadcast without advancing any timer — no bites, no cast
/// expiries.  The workhorse for "apply the queued input, then look".
fn flush(sess: *Session) !void {
    try sess.tick(0.0);
}

/// Sum of all per-tier healable hunger buckets.
fn total_healable(sess: *const Session) u32 {
    var t: u32 = 0;
    for (sess.hunger_healable) |h| t += h;
    return t;
}

/// Seconds one Lil Guy needs per bite under the fixture balance.
const BITE_S: f32 = 1.0 / 2.0; // eat_rate_units_per_s = 2.0

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

/// Stop the Lil Guys from eating during a cast-focused test: park every bite
/// timer far in the future.  (Their reservations stay valid; the cells they
/// hold are still neutralizable.)
fn freeze_bites(sess: *Session) void {
    const arr = &sess.world.component_arrays.lil_guy;
    for (arr.index_to_entity[0..arr.size]) |e| {
        sess.world.get_component(e, c.LilGuy).bite_timer = 1_000_000.0;
    }
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
    // The client needs the grid dimensions and buffer length up front.
    try std.testing.expectEqual(BAL.slime_grid.rows, gs.grid_rows);
    try std.testing.expectEqual(BAL.slime_grid.cols, gs.grid_cols);
    try std.testing.expectEqual(BAL.cast_buffer_ms, gs.cast_buffer_ms);

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

test "one Lil Guy per connected player, each with a reservation" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    try std.testing.expectEqual(@as(usize, 2), s.sess.world.component_arrays.lil_guy.size);
    for (&s.sess.players) |*slot| {
        if (!slot.connected) continue;
        try std.testing.expect(slot.lil_guy != session_mod.NO_ENTITY);
        const lg = s.sess.world.get_component(slot.lil_guy, c.LilGuy);
        try std.testing.expect(lg.has_target());
        try std.testing.expect(s.sess.field.grid.get(lg.target).is_slime());
    }
}

test "disconnect retires the Lil Guy; reconnect brings it back" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    s.sess.disconnect(s.p[1].pid);
    try flush(&s.sess); // sync_lil_guys runs inside the feast phase
    try std.testing.expectEqual(@as(usize, 1), s.sess.world.component_arrays.lil_guy.size);
    try std.testing.expectEqual(session_mod.NO_ENTITY, s.sess.players[s.p[1].pid].lil_guy);

    try std.testing.expect(s.sess.reconnect(s.p[1].pid, s.p[1].transport()));
    try flush(&s.sess);
    try std.testing.expectEqual(@as(usize, 2), s.sess.world.component_arrays.lil_guy.size);
    try std.testing.expect(s.sess.players[s.p[1].pid].lil_guy != session_mod.NO_ENTITY);
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

    const combo = BLOOM_HALF; // [dispense, medicine] — two distinguishable slots
    try enqueue_combo(&s.sess, s.p[0].pid, combo);
    try flush(&s.sess);
    try enqueue_submit(&s.sess, s.p[0].pid, combo);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.action_pool[s.p[0].pid]);
    try std.testing.expect(logic.combos_equal(combo, s.sess.submitted_pool[s.p[0].pid].?));
}

// ---------------------------------------------------------------------------
// Shape stamping
//
// A matched recipe stamps its shape at the caster's cast anchor, downgrading
// every covered HAZARD cell by exactly one tier.  These tests pin the grid
// with `set_field`/`paint_grid` and fire casts with a zero cast buffer, so a
// stamp is fully deterministic: shape placement is arithmetic, not PRNG.
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

/// Seconds that expire a cast buffer under `cfg` (plus nothing — callers add
/// their own epsilon).
fn cast_buffer_s(cfg: *const shared.config.Config) f32 {
    return @as(f32, @floatFromInt(cfg.balance.cast_buffer_ms)) / 1000.0;
}

/// A fixture config with an immediate cast buffer, so a submit converts in the
/// same tick it is drained.
fn cfg_instant_cast() shared.config.Config {
    var cfg = TEST_CFG.*;
    cfg.balance.cast_buffer_ms = 0;
    return cfg;
}

test "a stamp downgrades exactly the cells its shape covers" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
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
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
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
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
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
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_twenty_red);
    paint_grid(&s.sess, tiered(.red));
    s.sess.field.reservoir = .{};
    freeze_bites(&s.sess);

    const pid = s.p[0].pid;
    aim_at(&s.sess, pid, 3, 4);

    // Cast 1: red → yellow.
    try enqueue_submit(&s.sess, pid, POKE);
    try flush(&s.sess);
    try std.testing.expectEqual(c.Tier.yellow, s.sess.field.grid.at(3, 4).tiered);

    // Cast 2: yellow → green.
    try s.sess.tick(1.0); // clear the cast lock
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
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
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
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
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
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
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
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
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
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
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

test "a team recipe stamps one big shape, out-covering the halves fired apart" {
    const allocator = std.testing.allocator;

    // Together (grouped): twin_bloom's 5x5 diamond = 13 cells, one stamp.
    var together: TwoPlayerSession = undefined;
    try init_two_player_session(&together, allocator);
    defer together.deinit();
    const cfg = cfg_instant_cast();
    together.sess.cfg = &cfg;
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

    // Apart: neither half matches a PLAYER recipe on its own, so both fizzle.
    var apart: TwoPlayerSession = undefined;
    try init_two_player_session(&apart, allocator);
    defer apart.deinit();
    apart.sess.cfg = &cfg;
    try start(&apart, &enc_fifty_green);
    paint_grid(&apart.sess, tiered(.green));
    apart.sess.field.reservoir = .{};
    // With a zero buffer p0's cast fires in the drain that accepted it, so
    // p1's later submit can never share the batch.
    try enqueue_submit(&apart.sess, apart.p[0].pid, BLOOM_HALF);
    try flush(&apart.sess);
    try enqueue_submit(&apart.sess, apart.p[1].pid, BLOOM_HALF);
    try flush(&apart.sess);

    try std.testing.expectEqual(@as(u16, 0), count_defused(&apart.sess));
    try std.testing.expectEqual(@as(u16, 0), apart.sess.stats.team_recipe_hits[0]);
}

test "the team shape is anchored at the joiner's cursor" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    var cfg = TEST_CFG.*;
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    freeze_bites(&s.sess);

    // The two halves aim at opposite ends of the field.  p1 submits second, so
    // p1 completes the group and p1's cursor places the combined shape.
    aim_at(&s.sess, s.p[0].pid, 1, 1);
    try enqueue_submit(&s.sess, s.p[0].pid, BLOOM_HALF);
    try flush(&s.sess);
    aim_at(&s.sess, s.p[1].pid, 3, 7);
    try enqueue_submit(&s.sess, s.p[1].pid, BLOOM_HALF);
    try flush(&s.sess);

    // Grouping fires them together at the joiner's expiry.
    try s.sess.tick(cast_buffer_s(&cfg) + 0.001);

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
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    freeze_bites(&s.sess);

    // The same player casts the twin_bloom half twice.  Team recipes need
    // DISTINCT players, so neither cast can complete the group — and the half
    // is not a player recipe, so both fizzle.
    try enqueue_submit(&s.sess, s.p[0].pid, BLOOM_HALF);
    try flush(&s.sess);
    try s.sess.tick(1.0); // lock expires
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

test "a committed cast keeps its anchor when the caster re-aims mid-buffer" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    var cfg = TEST_CFG.*;
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_green);
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};
    freeze_bites(&s.sess);
    const pid = s.p[0].pid;

    aim_at(&s.sess, pid, 4, 8);
    try enqueue_submit(&s.sess, pid, POKE);
    try flush(&s.sess);

    // Re-aim while the cast is still buffering: the pending spell must not
    // follow the cursor.
    aim_at(&s.sess, pid, 0, 0);
    try s.sess.tick(cast_buffer_s(&cfg) + 0.001);

    try std.testing.expect(s.sess.field.grid.at(4, 8) == .neutralized);
    try std.testing.expect(s.sess.field.grid.at(0, 0) == .tiered);
}

// ---------------------------------------------------------------------------
// Eating (Lil Guy bites)
//
// Fixture balance: eat_rate_units_per_s = 2.0 PER LIL GUY, so each Lil Guy
// bites every 0.5s and two connected players eat 4 units/s together.
// ---------------------------------------------------------------------------

/// Point every Lil Guy at `flat` with an about-to-land bite, so the next tick
/// resolves a known collision.
fn aim_all_at(sess: *Session, flat: u16) void {
    const arr = &sess.world.component_arrays.lil_guy;
    for (arr.index_to_entity[0..arr.size]) |e| {
        const lg = sess.world.get_component(e, c.LilGuy);
        lg.target = flat;
        lg.bite_timer = 0.001;
    }
}

test "each Lil Guy bites once per bite interval" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    set_field(&s.sess, .neutral, 40);

    // One interval: two Lil Guys, two bites.
    try s.sess.tick(BITE_S);
    try std.testing.expectEqual(@as(u16, 38), s.sess.field.grid.occupied());
    try std.testing.expectEqual(@as(u32, 2), s.sess.score);
    try std.testing.expectEqual(@as(u16, @intCast(2 * BAL.hunger_cost_normal)), s.sess.hunger.current);

    // Four more intervals: 8 more units.
    for (0..4) |_| try s.sess.tick(BITE_S);
    try std.testing.expectEqual(@as(u16, 30), s.sess.field.grid.occupied());
    try std.testing.expectEqual(@as(u32, 10), s.sess.score);
}

test "no bite lands before the interval elapses" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    set_field(&s.sess, .neutral, 40);

    try s.sess.tick(BITE_S * 0.4);
    try s.sess.tick(BITE_S * 0.4);
    try std.testing.expectEqual(@as(u16, 40), s.sess.field.grid.occupied());
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);

    try s.sess.tick(BITE_S * 0.4); // 1.2 intervals total → both have bitten
    try std.testing.expectEqual(@as(u16, 38), s.sess.field.grid.occupied());
}

test "eating live hazard slime adds healable extra hunger; defused does not" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);

    // A grid of live green: both bites cost normal + extra, and score nothing.
    set_field(&s.sess, tiered(.green), 20);
    try s.sess.tick(BITE_S);
    const expected = 2 * (BAL.hunger_cost_normal + BAL.hunger_cost_hazard_extra);
    try std.testing.expectEqual(@as(u16, @intCast(expected)), s.sess.hunger.current);
    // Healable hunger is bucketed by the TIER that caused it, so only green
    // medicine can undo this.
    try std.testing.expectEqual(
        @as(u16, @intCast(2 * BAL.hunger_cost_hazard_extra)),
        s.sess.hunger_healable[GREEN],
    );
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger_healable[RED]);
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.feast.hazard_escaped[GREEN]);

    // A grid of defused slime: normal hunger only, and it scores.
    set_field(&s.sess, .neutralized, 20);
    const hunger_before = s.sess.hunger.current;
    const healable_before = s.sess.hunger_healable[GREEN];
    try s.sess.tick(BITE_S);
    try std.testing.expectEqual(
        hunger_before + @as(u16, @intCast(2 * BAL.hunger_cost_normal)),
        s.sess.hunger.current,
    );
    try std.testing.expectEqual(healable_before, s.sess.hunger_healable[GREEN]);
    try std.testing.expectEqual(@as(u32, 2), s.sess.score);
}

test "healable hunger is bucketed by the tier that was eaten" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_red);

    // Red slime fills the red bucket; green slime fills the green one.  They
    // never mix, which is what makes tier-targeted medicine meaningful.
    set_field(&s.sess, tiered(.red), 20);
    try s.sess.tick(BITE_S);
    try std.testing.expect(s.sess.hunger_healable[RED] > 0);
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger_healable[GREEN]);

    const red_before = s.sess.hunger_healable[RED];
    set_field(&s.sess, tiered(.green), 20);
    try s.sess.tick(BITE_S);
    try std.testing.expectEqual(red_before, s.sess.hunger_healable[RED]);
    try std.testing.expect(s.sess.hunger_healable[GREEN] > 0);
}

test "neutral slime scores but is never healable" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    set_field(&s.sess, .neutral, 40);

    for (0..5) |_| try s.sess.tick(BITE_S);
    try std.testing.expectEqual(@as(u32, 10), s.sess.score);
    try std.testing.expectEqual(@as(u32, 0), total_healable(&s.sess));
    try std.testing.expectEqual(@as(u16, 10), s.sess.stats.feast.neutral_consumed);
}

test "a reservation is not exclusive: the loser's bite misses" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_neutral_only);
    set_field(&s.sess, .neutral, 40);

    // Both Lil Guys reserve the SAME cell and bite in the same tick: the first
    // eats it, the second finds an empty cell and simply re-targets.
    aim_all_at(&s.sess, 0);
    try s.sess.tick(0.002);

    try std.testing.expectEqual(@as(u16, 39), s.sess.field.grid.occupied());
    try std.testing.expectEqual(@as(u32, 1), s.sess.score);
    try std.testing.expectEqual(@as(u16, @intCast(BAL.hunger_cost_normal)), s.sess.hunger.current);
    // Both are re-targeted onto live slime for the next bite.
    for (&s.sess.players) |*slot| {
        if (!slot.connected) continue;
        const lg = s.sess.world.get_component(slot.lil_guy, c.LilGuy);
        try std.testing.expect(lg.has_target());
        try std.testing.expect(s.sess.field.grid.get(lg.target).is_slime());
    }
}

test "a stamp never destroys a cell, so a reserved bite still lands" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_twenty_green);
    set_field(&s.sess, tiered(.green), 20);

    // Aim both Lil Guys at cell 0 and stamp over it in the same tick.  A
    // downgrade REWRITES the cell, so the bite still finds slime there —
    // it just eats a defused unit (score, no extra hunger) instead of a
    // hazard.
    aim_all_at(&s.sess, 0);
    aim_at(&s.sess, s.p[0].pid, 0, 0);
    try enqueue_submit(&s.sess, s.p[0].pid, POKE);
    try s.sess.tick(0.002);

    try std.testing.expectEqual(@as(u32, 1), s.sess.score);
    try std.testing.expectEqual(@as(u16, @intCast(BAL.hunger_cost_normal)), s.sess.hunger.current);
    // No healable hunger: the cell was defused before the bite landed.
    try std.testing.expectEqual(@as(u32, 0), total_healable(&s.sess));
    // 20 painted, 1 eaten: the stamp itself removed nothing.
    try std.testing.expectEqual(@as(u16, 19), s.sess.field.grid.occupied());
}

test "emptied cells refill from the reservoir, keeping the grid full" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_overflow); // 80 units: 60 on-grid, 20 waiting

    try s.sess.tick(BITE_S); // 2 units eaten
    // The grid is topped back up from the reservoir in the same tick.
    try std.testing.expectEqual(@as(u16, 60), s.sess.field.grid.occupied());
    try std.testing.expectEqual(@as(u32, 18), s.sess.field.reservoir.total());
    try std.testing.expectEqual(@as(u32, 78), s.sess.field.remaining());

    // Once the reservoir runs dry the grid starts thinning out.
    for (0..14) |_| try s.sess.tick(BITE_S); // 28 more units
    try std.testing.expect(s.sess.field.reservoir.is_empty());
    try std.testing.expectEqual(@as(u32, 50), s.sess.field.remaining());
    try std.testing.expectEqual(@as(u16, 50), s.sess.field.grid.occupied());
}

test "refills enter from the top row" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_overflow);

    // Clear the top row, leave the rest full, and keep slime in the reservoir.
    const cols = s.sess.field.grid.cols;
    var col: u8 = 0;
    while (col < cols) : (col += 1) s.sess.field.grid.set(0, col, .empty);
    // A tick with no bite landing still refills.
    freeze_bites(&s.sess);
    try s.sess.tick(0.0);

    col = 0;
    while (col < cols) : (col += 1) {
        try std.testing.expect(s.sess.field.grid.at(0, col).is_slime());
    }
}

test "defusing before the bite lands removes the healable hunger" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_twenty_green);
    // A 3x3 patch of green — exactly what one `block` stamp covers.
    set_block_field(&s.sess, tiered(.green), 2, 5);

    // One stamp defuses all 9 cells, then everything is eaten: normal hunger
    // only, no healable portion at all, and every unit scores.
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));

    var guard: usize = 0;
    while (s.sess.phase == .playing and guard < 40) : (guard += 1) try s.sess.tick(BITE_S);

    try std.testing.expectEqual(@as(u32, 9), s.sess.score);
    try std.testing.expectEqual(@as(u32, 0), total_healable(&s.sess));
    try std.testing.expectEqual(@as(u16, @intCast(9 * BAL.hunger_cost_normal)), s.sess.hunger.current);
}

// ---------------------------------------------------------------------------
// Casting: buffer, lock, replacement, grouping
//
// Fixture balance: cast_buffer_ms = 500 (per-cast buffer), cast_lock_ms = 500
// (per-player cooldown).  Bites are frozen where they would disturb the
// assertions.
// ---------------------------------------------------------------------------

test "accepted cast starts its buffer and lock; a locked resubmit is ignored" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    freeze_bites(&s.sess);

    // No submits yet: nothing counting down.
    try std.testing.expectEqual(@as(?f32, null), s.sess.cast_fire_timers[s.p[0].pid]);

    const combo = POKE;
    const combo_b = POKE;

    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, combo);
    try flush(&s.sess);

    // Accepted: pool holds the spell, on-wire marker set, live preview
    // cleared, the cast's own buffer counting down, lock cooling.
    try std.testing.expect(logic.combos_equal(combo, s.sess.submitted_pool[s.p[0].pid].?));
    try std.testing.expectEqual(@as(u8, 1), s.sess.casts_used[s.p[0].pid]);
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.action_pool[s.p[0].pid]);
    try std.testing.expect(s.sess.cast_fire_timers[s.p[0].pid] != null);
    try std.testing.expect(s.sess.cast_locks[s.p[0].pid] > 0.0);

    var msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_committed));
    // A flat cast completes no team recipe: no grouping.
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_grouped));
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

    // Resubmit while the lock is cooling: silent ignore, first spell kept.
    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, combo_b);
    try flush(&s.sess);

    msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_committed));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_replaced));
    try std.testing.expect(logic.combos_equal(combo, s.sess.submitted_pool[s.p[0].pid].?));
}

test "a solo cast fires at its own expiry only" {
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
    freeze_bites(&s.sess);

    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);

    // Before expiry (buffer 0.5s): nothing fires, nothing stamps.
    s.p[1].clear();
    try s.sess.tick(0.3);
    var msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_fired));
    try std.testing.expect(s.sess.submitted_pool[s.p[0].pid] != null);
    try std.testing.expectEqual(@as(u16, 0), count_defused(&s.sess));

    // At expiry: fires solo, stamping the 3x3 block.
    s.p[1].clear();
    try s.sess.tick(0.3);
    msgs = try drain(s.p[1].buf.items, arena);
    const cf_msg = find_tag(msgs, .cast_fired) orelse return error.MissingCastFired;
    var cf_fbs = std.io.fixedBufferStream(cf_msg.payload);
    const cf = try proto.decode_cast_fired(cf_fbs.reader());
    try std.testing.expectEqual(@as(u8, 1), cf.spell_count);
    try std.testing.expectEqual(@as(u8, 1) << @intCast(s.p[0].pid), cf.player_mask);
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.submitted_pool[s.p[0].pid]);
    try std.testing.expectEqual(@as(?f32, null), s.sess.cast_fire_timers[s.p[0].pid]);
    try std.testing.expectEqual(@as(u8, 0), s.sess.casts_used[s.p[0].pid]);
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));
}

test "nothing pending means ticks never fire a cast" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    freeze_bites(&s.sess);

    s.p[1].clear();
    try s.sess.tick(1.0);
    try s.sess.tick(1.0);

    const msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_fired));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_grouped));
}

test "a zero-output submit fizzles: no buffer, no lock" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    freeze_bites(&s.sess);

    // No recipe covers this combo, so it fizzles: no buffer, no lock.
    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, UNMATCHED);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.submitted_pool[s.p[0].pid]);
    try std.testing.expectEqual(@as(u8, 0), s.sess.casts_used[s.p[0].pid]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].fizzles);
    try std.testing.expectEqual(@as(?f32, null), s.sess.cast_fire_timers[s.p[0].pid]);
    try std.testing.expectEqual(@as(f32, 0.0), s.sess.cast_locks[s.p[0].pid]);

    var msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_fizzled));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_committed));

    // A valid submit right after is accepted and starts its buffer.
    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);

    try std.testing.expect(s.sess.submitted_pool[s.p[0].pid] != null);
    try std.testing.expect(s.sess.cast_fire_timers[s.p[0].pid] != null);
    msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_committed));
}

test "a team-recipe match groups the casts; they fire together at the joiner's expiry" {
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
    freeze_bites(&s.sess);

    // Each half is [dispense, medicine] — the twin_bloom team recipe.
    const half = BLOOM_HALF;

    // p0 casts; 0.3s later (inside p0's 0.5s buffer) p1 completes twin_bloom.
    try enqueue_submit(&s.sess, s.p[0].pid, half);
    try flush(&s.sess);
    try s.sess.tick(0.3);

    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[1].pid, half);
    try flush(&s.sess);

    // Grouped: both timers equalised to the joiner's full buffer.
    var msgs = try drain(s.p[1].buf.items, arena);
    const g_msg = find_tag(msgs, .cast_grouped) orelse return error.MissingCastGrouped;
    var g_fbs = std.io.fixedBufferStream(g_msg.payload);
    const g = try proto.decode_cast_grouped(g_fbs.reader());
    const expected_mask = (@as(u8, 1) << @intCast(s.p[0].pid)) |
        (@as(u8, 1) << @intCast(s.p[1].pid));
    try std.testing.expectEqual(expected_mask, g.player_mask);
    try std.testing.expectEqual(@as(u32, 500), g.fires_in_ms);

    // p0's ORIGINAL expiry (0.2s away) passes without firing — extended.
    s.p[1].clear();
    try s.sess.tick(0.3);
    msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_fired));
    try std.testing.expect(s.sess.submitted_pool[s.p[0].pid] != null);

    // Joiner's expiry (0.5s after grouping): both fire as ONE batch, so the
    // team's 5x5 diamond (13 cells) is stamped once.  Fired apart, neither
    // half matches anything at all.
    s.p[1].clear();
    try s.sess.tick(0.25);

    try std.testing.expectEqual(@as(u16, 13), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[0]);
    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);

    // Fired: pools + timers + markers reset, stats recorded once per spell.
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.submitted_pool[s.p[0].pid]);
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.submitted_pool[s.p[1].pid]);
    try std.testing.expectEqual(@as(?f32, null), s.sess.cast_fire_timers[s.p[0].pid]);
    try std.testing.expectEqual(@as(?f32, null), s.sess.cast_fire_timers[s.p[1].pid]);
    try std.testing.expectEqual(@as(u8, 0), s.sess.casts_used[s.p[0].pid]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].casts);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[1].pid].casts);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.casts_total);

    msgs = try drain(s.p[1].buf.items, arena);

    // cast_fired announces the batch: both players, two spells.
    const cf_msg = find_tag(msgs, .cast_fired) orelse return error.MissingCastFired;
    var cf_fbs = std.io.fixedBufferStream(cf_msg.payload);
    const cf = try proto.decode_cast_fired(cf_fbs.reader());
    try std.testing.expectEqual(@as(u8, 2), cf.spell_count);
    try std.testing.expectEqual(expected_mask, cf.player_mask);

    // Exactly one TEAM recipe fire broadcast.
    var team_fires: usize = 0;
    for (msgs) |m| {
        if (m.tag != .recipe_fired) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const rf = try proto.decode_recipe_fired(fbs.reader());
        try std.testing.expectEqual(proto.RecipeKind.team, rf.kind);
        try std.testing.expectEqual(@as(u8, 0), rf.index); // twin_flames
        team_fires += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), team_fires);
}

test "non-matching overlapping casts fire separately, with no group" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    freeze_bites(&s.sess);

    // p0 red flat cast; p1 blue flat cast 0.3s later — no team recipe.
    try enqueue_submit(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    try s.sess.tick(0.3);

    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[1].pid, POKE);
    try flush(&s.sess);
    var msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_grouped));

    // p0 fires alone at its own expiry (t=0.5)...
    s.p[1].clear();
    try s.sess.tick(0.25);
    msgs = try drain(s.p[1].buf.items, arena);
    var cf_msg = find_tag(msgs, .cast_fired) orelse return error.MissingCastFired;
    var cf_fbs = std.io.fixedBufferStream(cf_msg.payload);
    var cf = try proto.decode_cast_fired(cf_fbs.reader());
    try std.testing.expectEqual(@as(u8, 1), cf.spell_count);
    try std.testing.expectEqual(@as(u8, 1) << @intCast(s.p[0].pid), cf.player_mask);
    try std.testing.expect(s.sess.submitted_pool[s.p[1].pid] != null); // p1 still pending

    // ...and p1 alone at its own (t=0.8).
    s.p[1].clear();
    try s.sess.tick(0.3);
    msgs = try drain(s.p[1].buf.items, arena);
    cf_msg = find_tag(msgs, .cast_fired) orelse return error.MissingCastFired;
    cf_fbs = std.io.fixedBufferStream(cf_msg.payload);
    cf = try proto.decode_cast_fired(cf_fbs.reader());
    try std.testing.expectEqual(@as(u8, 1), cf.spell_count);
    try std.testing.expectEqual(@as(u8, 1) << @intCast(s.p[1].pid), cf.player_mask);
}

test "a matching cast arriving after the first fired does not group" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_green);
    freeze_bites(&s.sess);

    // A team half, so the ONLY way it can produce anything is by grouping.
    const half = BLOOM_HALF;
    try enqueue_submit(&s.sess, s.p[0].pid, half);
    try flush(&s.sess);
    try s.sess.tick(0.55); // p0's buffer expires and it fires alone, matching nothing

    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[1].pid, half);
    try flush(&s.sess);
    var msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_grouped));

    s.p[1].clear();
    try s.sess.tick(0.55); // p1 fires alone too — no team recipe ever
    msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .recipe_fired));
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[0]);
}

test "an unlocked resubmit replaces the pending cast and restarts its buffer" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    // Lock (0.1s) shorter than the buffer (0.5s) so a replace window exists.
    var custom_cfg = TEST_CFG.*;
    custom_cfg.balance.cast_lock_ms = 100;
    s.sess.cfg = &custom_cfg;
    try start(&s, &enc_fifty_green);
    set_field(&s.sess, tiered(.green), 50);
    freeze_bites(&s.sess);

    // A stamps a single cell; B stamps a 3x3 block.  Different footprints, so
    // the grid itself shows WHICH cast actually fired.
    const combo_a = POKE;
    const combo_b = BLOCK;
    aim_at(&s.sess, s.p[0].pid, 2, 5);

    try enqueue_submit(&s.sess, s.p[0].pid, combo_a);
    try flush(&s.sess);
    try s.sess.tick(0.2); // lock (0.1s) expires; buffer has 0.3s left

    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, combo_b);
    try flush(&s.sess);

    // Replaced: pool holds B, no duplicate commit, buffer restarted.
    try std.testing.expect(logic.combos_equal(combo_b, s.sess.submitted_pool[s.p[0].pid].?));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.sess.cast_fire_timers[s.p[0].pid].?, 0.001);
    var msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_replaced));
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_committed));
    const rp_msg = find_tag(msgs, .cast_replaced) orelse return error.MissingReplaced;
    var rp_fbs = std.io.fixedBufferStream(rp_msg.payload);
    const rp = try proto.decode_cast_replaced(rp_fbs.reader());
    try std.testing.expectEqual(s.p[0].pid, rp.player_id);

    // A's original expiry (0.3s away) passes without firing — restarted.
    s.p[1].clear();
    try s.sess.tick(0.35);
    msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_fired));

    s.p[1].clear();
    try s.sess.tick(0.2); // the restarted buffer expires → fires the REPLACEMENT

    // Stats counted once (at fire time), and B's 9-cell block landed — not
    // A's single cell.  Only one spell ever converted.
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].casts);
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 9), s.sess.stats.players[s.p[0].pid].cells_covered);

    msgs = try drain(s.p[1].buf.items, arena);
    const cf_msg = find_tag(msgs, .cast_fired) orelse return error.MissingCastFired;
    var cf_fbs = std.io.fixedBufferStream(cf_msg.payload);
    const cf = try proto.decode_cast_fired(cf_fbs.reader());
    try std.testing.expectEqual(@as(u8, 1), cf.spell_count);
}

test "zero cast_buffer_ms fires the cast in the same tick" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_green);
    set_field(&s.sess, tiered(.green), 50);

    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);

    // Accepted AND fired within one tick: `poke`'s single cell is defused.
    try std.testing.expectEqual(@as(u16, 1), count_defused(&s.sess));
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.submitted_pool[s.p[0].pid]);
    try std.testing.expectEqual(@as(?f32, null), s.sess.cast_fire_timers[s.p[0].pid]);
    const msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_committed));
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_fired));
}

test "zero cast_buffer_ms: a same-drain pair still fires the team recipe" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_twenty_green);
    // The whole grid, so the 5x5 diamond has a hazard under every cell.
    paint_grid(&s.sess, tiered(.green));
    s.sess.field.reservoir = .{};

    // Both twin_bloom halves land in ONE drain: both timers hit 0 in the same
    // tick, so they convert as one batch and the recipe fires.
    const half = BLOOM_HALF;
    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, half);
    try enqueue_submit(&s.sess, s.p[1].pid, half);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 13), count_defused(&s.sess));
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.team_recipe_hits[0]);
    const msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_fired));
}

test "cast_lock_ms above the buffer throttles the next cast" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    var custom_cfg = TEST_CFG.*;
    custom_cfg.balance.cast_buffer_ms = 100;
    custom_cfg.balance.cast_lock_ms = 1000;
    s.sess.cfg = &custom_cfg;
    try start(&s, &enc_fifty_green);
    freeze_bites(&s.sess);

    const combo = POKE;
    try enqueue_submit(&s.sess, s.p[0].pid, combo);
    try flush(&s.sess);
    try s.sess.tick(0.2); // cast fired; the lock has 0.8s left

    // Still locked after the fire: resubmit ignored.
    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, combo);
    try flush(&s.sess);
    var msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_committed));
    try std.testing.expectEqual(@as(?f32, null), s.sess.cast_fire_timers[s.p[0].pid]);

    // Lock expires → the next cast is accepted.
    try s.sess.tick(0.9);
    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, combo);
    try flush(&s.sess);
    msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_committed));
    try std.testing.expect(s.sess.cast_fire_timers[s.p[0].pid] != null);
}

test "player recipe fires are broadcast when the cast converts" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
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
// Medicine (symmetrical healing)
// ---------------------------------------------------------------------------

/// Accrue healable hunger of one tier by letting the Lil Guys eat that tier
/// while it is still a live hazard, then freeze them.  Returns the healable
/// amount accrued.
fn accrue_healable(sess: *Session, tier: c.Tier, bites: usize) !u16 {
    set_field(sess, tiered(tier), @intCast(sess.field.grid.len()));
    for (0..bites) |_| try sess.tick(BITE_S);
    freeze_bites(sess);
    return sess.hunger_healable[@intFromEnum(tier)];
}

test "symmetrical medicine heals matching-tier healable hunger" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_green);

    // 3 intervals x 2 Lil Guys = 6 red units eaten as live hazards.
    const red_healable = try accrue_healable(&s.sess, .red, 3);
    try std.testing.expectEqual(@as(u16, @intCast(6 * BAL.hunger_cost_hazard_extra)), red_healable);
    const hunger_before = s.sess.hunger.current;

    // `tonic` brews 6 medicine for EVERY tier, so the red bucket is served.
    s.p[0].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, TONIC);
    try flush(&s.sess);

    const expected_heal: u16 = @min(6, red_healable);
    try std.testing.expectEqual(hunger_before - expected_heal, s.sess.hunger.current);
    try std.testing.expectEqual(red_healable - expected_heal, s.sess.hunger_healable[RED]);
    try std.testing.expectEqual(expected_heal, s.sess.stats.feast.medicine_healed[RED]);

    // A heal action_result was broadcast with the healed amount.
    const msgs = try drain(s.p[0].buf.items, arena);
    var found_heal = false;
    for (msgs) |m| {
        if (m.tag != .action_result) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const ar = try proto.decode_action_result(fbs.reader());
        if (ar.tag == .heal) {
            found_heal = true;
            try std.testing.expectEqual(expected_heal, ar.value);
        }
    }
    try std.testing.expect(found_heal);
}

test "asymmetric medicine heals nothing" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_green);

    // Green hunger accrued...
    const green_healable = try accrue_healable(&s.sess, .green, 3);
    try std.testing.expect(green_healable > 0);
    const hunger_before = s.sess.hunger.current;

    // ...but `red_tonic` brews 10 RED medicine and nothing else, so it is
    // entirely wasted: healing is symmetrical by tier.
    try enqueue_submit(&s.sess, s.p[0].pid, RED_TONIC);
    try flush(&s.sess);

    try std.testing.expectEqual(hunger_before, s.sess.hunger.current);
    try std.testing.expectEqual(green_healable, s.sess.hunger_healable[GREEN]);
    // Brewed but healed nothing — the waste is visible in the stats.
    try std.testing.expectEqual(@as(u16, 10), s.sess.stats.feast.medicine_dispensed[RED]);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.feast.medicine_healed[RED]);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.feast.medicine_healed[GREEN]);
}

test "medicine cannot heal neutral-slime hunger" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_neutral_only);
    set_field(&s.sess, .neutral, 40);

    for (0..3) |_| try s.sess.tick(BITE_S); // 6 neutral units eaten
    freeze_bites(&s.sess);
    const hunger_before = s.sess.hunger.current;
    try std.testing.expect(hunger_before > 0);
    try std.testing.expectEqual(@as(u32, 0), total_healable(&s.sess));

    // Medicine from both players: neutral slime's hunger is not healable by
    // ANY tier, so all of it is discarded.
    try enqueue_submit(&s.sess, s.p[0].pid, TONIC);
    try enqueue_submit(&s.sess, s.p[1].pid, TONIC);
    try flush(&s.sess);

    try std.testing.expectEqual(hunger_before, s.sess.hunger.current);
}

test "medicine heals only up to the healable bucket (overheal discarded)" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_green);

    // One interval: 2 red units eaten → 4 healable, less than red_tonic's 10.
    const red_healable = try accrue_healable(&s.sess, .red, 1);
    try std.testing.expectEqual(@as(u16, @intCast(2 * BAL.hunger_cost_hazard_extra)), red_healable);
    const hunger_before = s.sess.hunger.current;

    try enqueue_submit(&s.sess, s.p[0].pid, RED_TONIC);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger_healable[RED]);
    try std.testing.expectEqual(hunger_before - red_healable, s.sess.hunger.current);
    try std.testing.expectEqual(@as(u16, 10), s.sess.stats.feast.medicine_dispensed[RED]);
    // The surplus 6 is discarded, not banked against future hunger.
    try std.testing.expectEqual(red_healable, s.sess.stats.feast.medicine_healed[RED]);
}

test "a medicine recipe both heals and stamps its shape" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_green);

    const red_healable = try accrue_healable(&s.sess, .red, 1);
    try std.testing.expect(red_healable > 0);
    // Repaint as green so the stamp has something to defuse.
    set_field(&s.sess, tiered(.green), 50);
    freeze_bites(&s.sess);

    // `tonic` is a 1x1 shape AND 6/6/6 medicine: every recipe stamps, even the
    // healing ones.
    aim_at(&s.sess, s.p[0].pid, 0, 3);
    try enqueue_submit(&s.sess, s.p[0].pid, TONIC);
    try flush(&s.sess);

    try std.testing.expect(s.sess.field.grid.at(0, 3) == .neutralized);
    try std.testing.expect(s.sess.hunger_healable[RED] < red_healable);
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
    var guard: usize = 0;
    while (s.sess.phase == .playing and guard < 40) : (guard += 1) try s.sess.tick(BITE_S);

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
    // 9 live green units = 27 hunger, and the bar (20) fills on the 8th.
    try start(&s, &enc_tight_budget);

    s.p[0].clear();
    var guard: usize = 0;
    while (s.sess.phase == .playing and guard < 20) : (guard += 1) try s.sess.tick(BITE_S);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);
    try std.testing.expectEqual(@as(u16, 20), s.sess.hunger.current); // clamped at max

    const go = try game_over_msg(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(proto.EndReason.hunger_full, go.stats.reason);
    try std.testing.expectEqual(@as(u16, 20), go.stats.hunger_final);
    try std.testing.expectEqual(@as(u16, 20), go.stats.hunger_max);
    try std.testing.expectEqual(@as(u32, 9), go.stats.slime_total);
    // The bar filled before the field was cleared, so slime survives.
    try std.testing.expect(go.stats.slime_left > 0);
}

test "defusing the tight budget survives what idle play loses" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_tight_budget); // 9 green, hunger_max 20
    set_block_field(&s.sess, tiered(.green), 2, 5);

    // One `block` stamp defuses the whole field, so it costs 9 normal hunger
    // and every unit scores — where idle play would spend 27 and lose.
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 9), count_defused(&s.sess));

    var guard: usize = 0;
    while (s.sess.phase == .playing and guard < 20) : (guard += 1) try s.sess.tick(BITE_S);

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
    try s.sess.tick(BITE_S); // both Lil Guys bite: 2 units, 2 hunger

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

    var guard: usize = 0;
    while (s.sess.phase == .playing and guard < 40) : (guard += 1) try s.sess.tick(BITE_S);

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
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_mixed); // 10 red + 8 green + 7 neutral = 25 units

    // Pin a layout the stamps can address exactly: the green run sits in the
    // top-left corner, the red run beside it, neutral after that.
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

    var guard: usize = 0;
    while (s.sess.phase == .playing and guard < 40) : (guard += 1) try s.sess.tick(BITE_S);

    const go = try game_over_msg(try drain(s.p[0].buf.items, arena));
    const st = go.stats;

    try std.testing.expectEqual(proto.EndReason.field_cleared, st.reason);
    try std.testing.expectEqual(@as(u32, 25), st.slime_total);
    try std.testing.expectEqual(@as(u32, 0), st.slime_left);
    try std.testing.expectEqual(@as(u16, 2), st.casts_total);

    // Coverage: 4 green cells covered (1 poke + 3 sweep), all defused since
    // green is one step from harmless.  No red was ever covered.
    try std.testing.expectEqual(@as(u16, 4), st.feast.cells_covered[GREEN]);
    try std.testing.expectEqual(@as(u16, 0), st.feast.cells_covered[RED]);
    try std.testing.expectEqual(@as(u16, 4), st.feast.neutralized[GREEN]);
    // Escapes: the 4 untouched green plus all 10 red were eaten live.
    try std.testing.expectEqual(@as(u16, 4), st.feast.hazard_escaped[GREEN]);
    try std.testing.expectEqual(@as(u16, 10), st.feast.hazard_escaped[RED]);
    try std.testing.expectEqual(@as(u16, 7), st.feast.neutral_consumed);
    try std.testing.expectEqual(@as(u16, @intCast(25 * BAL.hunger_cost_normal)), st.feast.hunger_normal);
    try std.testing.expectEqual(
        @as(u16, @intCast(14 * BAL.hunger_cost_hazard_extra)),
        st.feast.hunger_extra,
    );
    // Score = defused units + neutral units.
    try std.testing.expectEqual(@as(u32, 11), go.score);

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
    freeze_bites(&s.sess);

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

test "game_state carries one lil guy per player with target and bite countdown" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);

    s.p[0].clear();
    try flush(&s.sess);
    const gs = try last_game_state(try drain(s.p[0].buf.items, arena));

    try std.testing.expectEqual(@as(u8, 2), gs.lil_guy_count);
    for (gs.lil_guys[0..gs.lil_guy_count]) |lg| {
        // A live reservation on a real slime cell, counting down a full bite.
        try std.testing.expect(lg.target < gs.grid_len());
        try std.testing.expect(gs.grid[lg.target].is_slime());
        try std.testing.expectEqual(@as(u16, 500), lg.bite_ms); // 1 / 2.0 units_per_s
    }
    // The entity ids match the session's Lil Guy entities.
    for (&s.sess.players) |*slot| {
        if (!slot.connected) continue;
        var found = false;
        for (gs.lil_guys[0..gs.lil_guy_count]) |lg| {
            if (lg.entity == slot.lil_guy) found = true;
        }
        try std.testing.expect(found);
    }
}

test "game_state reflects neutralization and bites as they happen" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_green);
    set_field(&s.sess, tiered(.green), 50);

    s.p[0].clear();
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK); // 3x3 = 9 cells defused
    try s.sess.tick(BITE_S); // convert, then both Lil Guys bite

    const gs = try last_game_state(try drain(s.p[0].buf.items, arena));
    var neutralized: u16 = 0;
    var hazard: u16 = 0;
    var occupied: u16 = 0;
    for (gs.grid[0..gs.grid_len()]) |cell| {
        if (cell.is_slime()) occupied += 1;
        if (cell == .neutralized) neutralized += 1;
        if (cell.is_hazard()) hazard += 1;
    }
    // 50 cells, 9 defused (not destroyed), 2 eaten (nothing left to refill).
    try std.testing.expectEqual(@as(u16, 48), occupied);
    try std.testing.expectEqual(neutralized + hazard, occupied);
    try std.testing.expectEqual(s.sess.field.grid.occupied(), occupied);
    try std.testing.expectEqual(s.sess.hunger.current, gs.hunger.current);
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

    const combo = BLOOM_HALF; // [dispense, medicine] — two distinguishable slots
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
        try std.testing.expectEqual(c.ActionChoice.medicine, e.combo_slots[1].action);
    }
    try std.testing.expect(found);
}

test "game_state carries the soonest cast countdown (idle = -1), lock_ms and cast_ms" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_green);
    freeze_bites(&s.sess);

    // Idle: cast_timer sentinel -1, no locks, no pending casts.
    s.p[1].clear();
    try flush(&s.sess);
    var gs = try last_game_state(try drain(s.p[1].buf.items, arena));
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), gs.cast_timer, 0.001);
    for (gs.entities[0..gs.entity_count]) |e| {
        try std.testing.expectEqual(@as(u16, 0), e.lock_ms);
        try std.testing.expectEqual(@as(u16, 0), e.cast_ms);
        try std.testing.expectEqual(@as(u8, 0), e.casts_used);
    }

    // Cast pending: the soonest countdown is positive; the submitter's lock_ms
    // and cast_ms count down, everyone else's stay 0.
    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, POKE);
    try flush(&s.sess);
    gs = try last_game_state(try drain(s.p[1].buf.items, arena));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), gs.cast_timer, 0.001);
    var found_submitter = false;
    for (gs.entities[0..gs.entity_count]) |e| {
        if (e.owner == s.p[0].pid) {
            try std.testing.expectEqual(@as(u16, 500), e.lock_ms);
            try std.testing.expectEqual(@as(u16, 500), e.cast_ms);
            try std.testing.expectEqual(@as(u8, 1), e.casts_used);
            found_submitter = true;
        } else {
            try std.testing.expectEqual(@as(u16, 0), e.lock_ms);
            try std.testing.expectEqual(@as(u16, 0), e.cast_ms);
        }
    }
    try std.testing.expect(found_submitter);
}

test "a fully defused grid broadcasts zero healable hunger in every tier" {
    // Wire-level regression for "hazard slime showing in the hunger bar after
    // defusing everything".
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_twenty_green);
    set_block_field(&s.sess, tiered(.green), 2, 5);

    // One `block` stamp covers the whole 9-cell field, then it is all eaten.
    aim_at(&s.sess, s.p[0].pid, 2, 5);
    try enqueue_submit(&s.sess, s.p[0].pid, BLOCK);
    try flush(&s.sess);
    s.p[0].clear();
    var guard: usize = 0;
    while (s.sess.phase == .playing and guard < 40) : (guard += 1) try s.sess.tick(BITE_S);

    try std.testing.expectEqual(@as(u32, 0), total_healable(&s.sess));
    const gs = try last_game_state(try drain(s.p[0].buf.items, arena));
    for (gs.hunger_healable) |h| try std.testing.expectEqual(@as(u16, 0), h);
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

    // The joiner also gets a Lil Guy, so the team eats faster.
    try flush(&s.sess);
    try std.testing.expectEqual(@as(usize, 3), s.sess.world.component_arrays.lil_guy.size);
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
        /// Play `enc_overflow` (grid + reservoir + refills) for four bite
        /// intervals and return the resulting grid.
        fn go(alloc: std.mem.Allocator, seed: u64) !c.SlimeGrid {
            var s: TwoPlayerSession = undefined;
            try init_two_player_session_seeded(&s, alloc, seed);
            defer s.deinit();
            try s.sess.start_game_encounter(&enc_overflow);
            for (0..4) |_| try s.sess.tick(BITE_S);
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
