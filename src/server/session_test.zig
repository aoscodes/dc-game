//! Integration tests for the Slime Feast game session.
//!
//! Tests drive Session directly — no network, no threads.  Transport is a
//! BufferTransport that accumulates outgoing bytes.
//!
//! Every session here is created with `Session.init_seeded` and a PINNED seed,
//! so cell placement, Lil Guy targeting and neutralize subsets are all
//! reproducible.  Where a test needs a specific grid layout it writes the
//! cells directly (`sess.field.grid.put`) after start, which is the only way
//! to assert exact per-cell outcomes without depending on the PRNG stream.
//!
//! Mechanics under test:
//!   - combo intake (latest preview wins, cancel clears)
//!   - realtime casting: per-cast buffer, cast lock, replacement, team-recipe
//!     grouping, batch conversion
//!   - neutralization: on-grid cohort only, random subset, residue multiplier
//!   - eating: one Lil Guy per connected player, bite timers, misses, refill
//!     from the reservoir
//!   - hunger accounting: normal (unhealable) vs extra (healable) portions
//!   - symmetrical medicine: color-X medicine heals only color-X healable
//!     hunger; asymmetric medicine and overheal are discarded
//!   - score = neutral + neutralized units eaten
//!   - end conditions: field cleared / hunger bar full
//!   - wire contents: grid, reservoir, lil guys, cast countdowns

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

const RED: usize = @intFromEnum(c.Element.red);
const GREEN: usize = @intFromEnum(c.Element.green);
const BLUE: usize = @intFromEnum(c.Element.blue);

// ---------------------------------------------------------------------------
// Minimal test encounters
//
// There is ONE slime pool per encounter now (the reservoir); the grid is sized
// globally by balance.slime_grid (6×10 = 60 cells in the fixture), so small
// encounters fit entirely on the grid and large ones exercise refill.
// ---------------------------------------------------------------------------

/// 20 red-modified units, roomy hunger budget.  Fits on the grid.
const enc_twenty_red = enc.Encounter{
    .label = "test_twenty_red",
    .hunger_max = 1000,
    .slime = .{ .modified = .{ 20, 0, 0, 0 } },
};

/// 30 red-modified units — exactly one twin_flames output.
const enc_thirty_red = enc.Encounter{
    .label = "test_thirty_red",
    .hunger_max = 1000,
    .slime = .{ .modified = .{ 30, 0, 0, 0 } },
};

/// 50 red-modified units (the partial-neutralization case).  Fits on the grid.
const enc_fifty_red = enc.Encounter{
    .label = "test_fifty_red",
    .hunger_max = 1000,
    .slime = .{ .modified = .{ 50, 0, 0, 0 } },
};

/// Mixed colors + neutral: 10 red + 8 green + 7 neutral = 25 units.
const enc_mixed = enc.Encounter{
    .label = "test_mixed",
    .hunger_max = 1000,
    .slime = .{ .modified = .{ 10, 8, 0, 0 }, .neutral = 7 },
};

/// Tiny hunger budget: eating the 10 red units un-neutralized costs
/// 10 normal + 20 extra = 30 ≥ 25, so idle play loses.
const enc_tight_budget = enc.Encounter{
    .label = "test_tight_budget",
    .hunger_max = 25,
    .slime = .{ .modified = .{ 10, 0, 0, 0 } },
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
    .slime = .{ .modified = .{ 40, 0, 0, 0 }, .neutral = 40 },
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
        .agents_dispensed => if (proto.decode_agents_dispensed(r)) |_| true else |_| false,
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

/// Sum of all per-color healable hunger buckets.
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
    try start(&s, &enc_fifty_red);

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
    try start(&s, &enc_fifty_red);

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
    try start(&s, &enc_fifty_red);

    const combo_a = mk(&.{ .{ .element = .red }, .{ .action = .dispense } });
    const combo_b = mk(&.{ .{ .element = .blue }, .{ .action = .dispense }, .{ .action = .dispense } });

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
    try start(&s, &enc_fifty_red);

    const combo = mk(&.{ .{ .element = .red }, .{ .action = .dispense } });
    try enqueue_combo(&s.sess, s.p[0].pid, combo);
    try flush(&s.sess);
    try enqueue_submit(&s.sess, s.p[0].pid, combo);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.action_pool[s.p[0].pid]);
    try std.testing.expect(logic.combos_equal(combo, s.sess.submitted_pool[s.p[0].pid].?));
}

// ---------------------------------------------------------------------------
// Neutralization (agents act on the ON-GRID cohort only)
//
// These tests pin the grid with `set_field` and fire casts with a zero buffer
// so the conversion is fully deterministic: the only randomness left is WHICH
// cells of the cohort are picked, which the assertions do not depend on.
// ---------------------------------------------------------------------------

/// Number of `neutralized` cells of one color on the grid.
fn count_neutralized(sess: *const Session, color: c.Element) u16 {
    var n: u16 = 0;
    for (sess.field.grid.live()) |cell| {
        if (cell == .neutralized and cell.neutralized == color) n += 1;
    }
    return n;
}

/// A fixture config with an immediate cast buffer, so a submit converts in the
/// same tick it is drained.
fn cfg_instant_cast() shared.config.Config {
    var cfg = TEST_CFG.*;
    cfg.balance.cast_buffer_ms = 0;
    return cfg;
}

test "dispensed agents neutralize matching-color cells in place" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_red);
    set_field(&s.sess, .{ .modified = .red }, 50);

    // crimson_flood: 20 red agents, residue 1.0 → 20 cells become neutralized.
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 30), s.sess.field.grid.modified_count(.red));
    try std.testing.expectEqual(@as(u16, 20), count_neutralized(&s.sess, .red));
    // Nothing eaten yet: hunger and score untouched, no slime destroyed.
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    try std.testing.expectEqual(@as(u32, 50), s.sess.field.remaining());
    // Stats record the dispensed agents and the cells transmuted.
    try std.testing.expectEqual(@as(u16, 20), s.sess.stats.feast.agents_dispensed[RED]);
    try std.testing.expectEqual(@as(u16, 20), s.sess.stats.feast.neutralized[RED]);
}

test "wrong-color agents neutralize nothing" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_red);
    set_field(&s.sess, .{ .modified = .red }, 50);

    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .blue },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 50), s.sess.field.grid.modified_count(.red));
    try std.testing.expectEqual(@as(u16, 0), count_neutralized(&s.sess, .red));
    // The agents were dispensed (and wasted) — the stats show both facts.
    try std.testing.expectEqual(@as(u16, 20), s.sess.stats.feast.agents_dispensed[BLUE]);
    for (s.sess.stats.feast.neutralized) |n| try std.testing.expectEqual(@as(u16, 0), n);
}

test "agents beyond the on-grid cohort are wasted, not applied to the reservoir" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    // 80 red units: 60 on the grid, 20 waiting off-grid.
    const encounter = enc.Encounter{
        .label = "test_red_overflow",
        .hunger_max = 1000,
        .slime = .{ .modified = .{ 80, 0, 0, 0 } },
    };
    try start(&s, &encounter);
    try std.testing.expectEqual(@as(u16, 60), s.sess.field.grid.modified_count(.red));

    // twin_flames from both players: 30 agents — under the 60-cell cohort.
    const half = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    try enqueue_submit(&s.sess, s.p[0].pid, half);
    try enqueue_submit(&s.sess, s.p[1].pid, half);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 30), count_neutralized(&s.sess, .red));
    try std.testing.expectEqual(@as(u16, 30), s.sess.field.grid.modified_count(.red));
    // The off-grid 20 are out of reach and untouched.
    try std.testing.expectEqual(@as(u16, 20), s.sess.field.reservoir.modified[RED]);
}

test "agents_dispensed reports the dispensed total and what it transmuted" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    // Cohort of 20 red on the grid.
    try start(&s, &enc_thirty_red);
    set_field(&s.sess, .{ .modified = .red }, 20);
    const cohort = s.sess.field.grid.modified_count(.red);

    s.p[0].clear();
    s.p[1].clear();
    // big_red: 3 dispense slots at 5 units, plus the recipe bonus -> 20
    // agents, exactly covering the 20-cell cohort.
    const combo = mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    });
    try enqueue_submit(&s.sess, s.p[0].pid, combo);
    try flush(&s.sess);

    const msgs = try drain(s.p[1].buf.items, arena);
    const msg = find_tag(msgs, .agents_dispensed) orelse
        return error.MissingAgentsDispensed;
    var fbs = std.io.fixedBufferStream(msg.payload);
    const ad = try proto.decode_agents_dispensed(fbs.reader());

    // Dispensed matches the recipe; transmuted matches what left `modified`.
    try std.testing.expectEqual(@as(u16, 20), ad.dispensed[RED]);
    const left = cohort - s.sess.field.grid.modified_count(.red);
    try std.testing.expectEqual(left, ad.transmuted[RED]);
    try std.testing.expectEqual(@as(u16, 20), ad.transmuted[RED]);
    // Under capacity: nothing wasted, and no other color is touched.
    try std.testing.expectEqual(ad.dispensed[RED], ad.transmuted[RED]);
    try std.testing.expectEqual(@as(u16, 0), ad.dispensed[BLUE]);
}

test "agents_dispensed exposes the wasted surplus when a cast overshoots" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_thirty_red);
    // Only 4 red cells for big_red's 20 agents to hit.
    set_field(&s.sess, .{ .modified = .red }, 4);

    s.p[0].clear();
    s.p[1].clear();
    const combo = mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    });
    try enqueue_submit(&s.sess, s.p[0].pid, combo);
    try flush(&s.sess);

    const msgs = try drain(s.p[1].buf.items, arena);
    const msg = find_tag(msgs, .agents_dispensed) orelse
        return error.MissingAgentsDispensed;
    var fbs = std.io.fixedBufferStream(msg.payload);
    const ad = try proto.decode_agents_dispensed(fbs.reader());

    // Transmuted is capped by the cohort, so the surplus is recoverable as
    // dispensed - transmuted: 16 red agents found nothing to convert.
    try std.testing.expectEqual(@as(u16, 20), ad.dispensed[RED]);
    try std.testing.expectEqual(@as(u16, 4), ad.transmuted[RED]);
    try std.testing.expectEqual(@as(u16, 16), ad.dispensed[RED] - ad.transmuted[RED]);
    try std.testing.expectEqual(@as(u16, 0), s.sess.field.grid.modified_count(.red));
}

test "a fizzled cast broadcasts no agents_dispensed" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_thirty_red);

    s.p[0].clear();
    s.p[1].clear();
    // Element only, no actions: zero output, so nothing to report.
    const empty_combo = mk(&.{.{ .element = .red }});
    try enqueue_submit(&s.sess, s.p[0].pid, empty_combo);
    try flush(&s.sess);

    const msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .agents_dispensed));
}

test "neutralize_residue_mult destroys the non-surviving portion" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    var cfg = cfg_instant_cast();
    cfg.balance.neutralize_residue_mult = 0.5;
    s.sess.cfg = &cfg;
    try start(&s, &enc_thirty_red);
    set_field(&s.sess, .{ .modified = .red }, 30);

    // twin_flames: 30 agents transmute all 30 cells; only 15 survive.
    const half = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    try enqueue_submit(&s.sess, s.p[0].pid, half);
    try enqueue_submit(&s.sess, s.p[1].pid, half);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 0), s.sess.field.grid.modified_count(.red));
    try std.testing.expectEqual(@as(u16, 15), count_neutralized(&s.sess, .red));
    try std.testing.expectEqual(@as(u16, 15), s.sess.field.grid.occupied());
    // Destroyed slime is gone from the match entirely.
    try std.testing.expectEqual(@as(u32, 15), s.sess.field.remaining());
}

test "team recipe out-neutralizes the same two casts fired apart" {
    const allocator = std.testing.allocator;
    const half = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });

    // Together (grouped): twin_flames → 30 agents.
    var together: TwoPlayerSession = undefined;
    try init_two_player_session(&together, allocator);
    defer together.deinit();
    const cfg = cfg_instant_cast();
    together.sess.cfg = &cfg;
    try start(&together, &enc_fifty_red);
    set_field(&together.sess, .{ .modified = .red }, 50);
    try enqueue_submit(&together.sess, together.p[0].pid, half);
    try enqueue_submit(&together.sess, together.p[1].pid, half);
    try flush(&together.sess);
    try std.testing.expectEqual(@as(u16, 30), count_neutralized(&together.sess, .red));
    try std.testing.expectEqual(@as(u16, 1), together.sess.stats.team_recipe_hits[0]);

    // Apart: two flat conversions → 2 × 10 = 20 agents.
    var apart: TwoPlayerSession = undefined;
    try init_two_player_session(&apart, allocator);
    defer apart.deinit();
    apart.sess.cfg = &cfg;
    try start(&apart, &enc_fifty_red);
    set_field(&apart.sess, .{ .modified = .red }, 50);
    // With a zero buffer p0's cast fires in the drain that accepted it, so
    // p1's later submit can never share the batch.
    try enqueue_submit(&apart.sess, apart.p[0].pid, half);
    try flush(&apart.sess);
    try enqueue_submit(&apart.sess, apart.p[1].pid, half);
    try flush(&apart.sess);
    try std.testing.expectEqual(@as(u16, 20), count_neutralized(&apart.sess, .red));
    try std.testing.expectEqual(@as(u16, 0), apart.sess.stats.team_recipe_hits[0]);
}

test "same player's own recipe halves never fire the team recipe" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_red);
    set_field(&s.sess, .{ .modified = .red }, 50);

    // The same player casts the twin_flames half twice: distinct players are
    // required, so both fire as flat conversions (10 agents each).
    const half = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    try enqueue_submit(&s.sess, s.p[0].pid, half);
    try flush(&s.sess);
    freeze_bites(&s.sess);
    try s.sess.tick(1.0); // lock expires
    try enqueue_submit(&s.sess, s.p[0].pid, half);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 20), count_neutralized(&s.sess, .red));
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.team_recipe_hits[0]);
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

test "eating modified slime adds healable extra hunger; neutralized does not" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_twenty_red);

    // A grid of un-neutralized red: both bites cost normal + extra, no score.
    set_field(&s.sess, .{ .modified = .red }, 20);
    try s.sess.tick(BITE_S);
    const expected = 2 * (BAL.hunger_cost_normal + BAL.hunger_cost_modified_extra);
    try std.testing.expectEqual(@as(u16, @intCast(expected)), s.sess.hunger.current);
    try std.testing.expectEqual(
        @as(u16, @intCast(2 * BAL.hunger_cost_modified_extra)),
        s.sess.hunger_healable[RED],
    );
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    try std.testing.expectEqual(@as(u16, 2), s.sess.stats.feast.modified_escaped[RED]);

    // A grid of neutralized red: normal hunger only, and it scores.
    set_field(&s.sess, .{ .neutralized = .red }, 20);
    const hunger_before = s.sess.hunger.current;
    const healable_before = s.sess.hunger_healable[RED];
    try s.sess.tick(BITE_S);
    try std.testing.expectEqual(
        hunger_before + @as(u16, @intCast(2 * BAL.hunger_cost_normal)),
        s.sess.hunger.current,
    );
    try std.testing.expectEqual(healable_before, s.sess.hunger_healable[RED]);
    try std.testing.expectEqual(@as(u32, 2), s.sess.score);
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

test "a bite whose cell was neutralized away misses" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    var cfg = cfg_instant_cast();
    cfg.balance.neutralize_residue_mult = 0.0; // transmuted cells are destroyed
    s.sess.cfg = &cfg;
    try start(&s, &enc_twenty_red);
    set_field(&s.sess, .{ .modified = .red }, 20);

    // Aim both Lil Guys at cell 0, then destroy the whole red cohort with a
    // cast in the same tick: the bites land on emptiness.
    aim_all_at(&s.sess, 0);
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    })); // crimson_flood: 20 agents ≥ the 20-cell cohort
    try s.sess.tick(0.002);

    try std.testing.expectEqual(@as(u16, 0), s.sess.field.grid.occupied());
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);
    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.feast.hunger_normal);
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

test "neutralizing before the bite lands removes the healable hunger" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_twenty_red);
    set_field(&s.sess, .{ .modified = .red }, 20);

    // crimson_flood neutralizes all 20 cells (residue 1.0), then everything is
    // eaten: normal hunger only, and every unit scores.
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 20), count_neutralized(&s.sess, .red));

    var guard: usize = 0;
    while (s.sess.phase == .playing and guard < 40) : (guard += 1) try s.sess.tick(BITE_S);

    try std.testing.expectEqual(@as(u32, 20), s.sess.score);
    try std.testing.expectEqual(@as(u32, 0), total_healable(&s.sess));
    try std.testing.expectEqual(@as(u16, @intCast(20 * BAL.hunger_cost_normal)), s.sess.hunger.current);
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
    try start(&s, &enc_fifty_red);
    freeze_bites(&s.sess);

    // No submits yet: nothing counting down.
    try std.testing.expectEqual(@as(?f32, null), s.sess.cast_fire_timers[s.p[0].pid]);

    const combo = mk(&.{ .{ .element = .red }, .{ .action = .dispense } });
    const combo_b = mk(&.{ .{ .element = .blue }, .{ .action = .dispense } });

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
    try start(&s, &enc_fifty_red);
    set_field(&s.sess, .{ .modified = .red }, 50);
    freeze_bites(&s.sess);

    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{ .{ .element = .red }, .{ .action = .dispense } }));
    try flush(&s.sess);

    // Before expiry (buffer 0.5s): nothing fires, nothing transmutes.
    s.p[1].clear();
    try s.sess.tick(0.3);
    var msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 0), count_tag(msgs, .cast_fired));
    try std.testing.expect(s.sess.submitted_pool[s.p[0].pid] != null);
    try std.testing.expectEqual(@as(u16, 0), count_neutralized(&s.sess, .red));

    // At expiry: fires solo (5 red agents), everything clears.
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
    try std.testing.expectEqual(@as(u16, 5), count_neutralized(&s.sess, .red));
}

test "nothing pending means ticks never fire a cast" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start(&s, &enc_fifty_red);
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
    try start(&s, &enc_fifty_red);
    freeze_bites(&s.sess);

    // Dangling element token: no output → fizzle, nothing else happens.
    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{.{ .element = .red }}));
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
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{ .{ .element = .red }, .{ .action = .dispense } }));
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
    try start(&s, &enc_thirty_red);
    set_field(&s.sess, .{ .modified = .red }, 30);
    freeze_bites(&s.sess);

    const half = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });

    // p0 casts; 0.3s later (inside p0's 0.5s buffer) p1 completes twin_flames.
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

    // Joiner's expiry (0.5s after grouping): both fire as ONE batch, so
    // twin_flames' 30 agents cover the whole 30-cell cohort (flat conversion
    // would only reach 20).
    s.p[1].clear();
    try s.sess.tick(0.25);

    try std.testing.expectEqual(@as(u16, 0), s.sess.field.grid.modified_count(.red));
    try std.testing.expectEqual(@as(u16, 30), count_neutralized(&s.sess, .red));
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
    try start(&s, &enc_fifty_red);
    freeze_bites(&s.sess);

    // p0 red flat cast; p1 blue flat cast 0.3s later — no team recipe.
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{ .{ .element = .red }, .{ .action = .dispense } }));
    try flush(&s.sess);
    try s.sess.tick(0.3);

    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[1].pid, mk(&.{ .{ .element = .blue }, .{ .action = .dispense } }));
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
    try start(&s, &enc_thirty_red);
    freeze_bites(&s.sess);

    const half = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    try enqueue_submit(&s.sess, s.p[0].pid, half);
    try flush(&s.sess);
    try s.sess.tick(0.55); // p0 fires alone (flat: 2 slots × 5 = 10 red agents)

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
    try start(&s, &enc_fifty_red);
    set_field(&s.sess, .{ .modified = .red }, 50);
    freeze_bites(&s.sess);

    const combo_a = mk(&.{ .{ .element = .red }, .{ .action = .dispense } });
    const combo_b = mk(&.{ .{ .element = .blue }, .{ .action = .dispense } });

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

    // Stats counted once (at fire time), and the batch used B (blue dispense),
    // not A: flat blue agents cannot neutralize red slime.
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].casts);
    try std.testing.expectEqual(@as(u16, 1), s.sess.stats.players[s.p[0].pid].dispense_slots[BLUE]);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.players[s.p[0].pid].dispense_slots[RED]);
    try std.testing.expectEqual(@as(u16, 0), count_neutralized(&s.sess, .red));

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
    try start(&s, &enc_fifty_red);
    set_field(&s.sess, .{ .modified = .red }, 50);

    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{ .{ .element = .red }, .{ .action = .dispense } }));
    try flush(&s.sess);

    // Accepted AND fired within one tick: 5 red cells neutralized.
    try std.testing.expectEqual(@as(u16, 5), count_neutralized(&s.sess, .red));
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
    try start(&s, &enc_thirty_red);
    set_field(&s.sess, .{ .modified = .red }, 30);

    // Both twin_flames halves land in ONE drain: both timers hit 0 in the same
    // tick, so they convert as one batch and the recipe fires.
    const half = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, half);
    try enqueue_submit(&s.sess, s.p[1].pid, half);
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 0), s.sess.field.grid.modified_count(.red));
    try std.testing.expectEqual(@as(u16, 30), count_neutralized(&s.sess, .red));
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
    try start(&s, &enc_fifty_red);
    freeze_bites(&s.sess);

    const combo = mk(&.{ .{ .element = .red }, .{ .action = .dispense } });
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
    try start(&s, &enc_fifty_red);
    set_field(&s.sess, .{ .modified = .red }, 50);

    s.p[1].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    })); // crimson_flood = player_recipes[0]
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

/// Accrue healable hunger of one color by letting the Lil Guys eat that color
/// un-neutralized, then freeze them.  Returns the healable amount accrued.
fn accrue_healable(sess: *Session, color: c.Element, bites: usize) !u16 {
    set_field(sess, .{ .modified = color }, @intCast(sess.field.grid.len()));
    for (0..bites) |_| try sess.tick(BITE_S);
    freeze_bites(sess);
    return sess.hunger_healable[@intFromEnum(color)];
}

test "symmetrical medicine heals matching-color healable hunger" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_fifty_red);

    // 3 intervals × 2 Lil Guys = 6 red units eaten un-neutralized.
    const red_healable = try accrue_healable(&s.sess, .red, 3);
    try std.testing.expectEqual(@as(u16, @intCast(6 * BAL.hunger_cost_modified_extra)), red_healable);
    const hunger_before = s.sess.hunger.current;

    // RED medicine, flat: 2 slots × medicine_per_slot.
    s.p[0].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .red },
        .{ .action = .medicine },
        .{ .action = .medicine },
    }));
    try flush(&s.sess);

    const expected_heal: u16 = @intCast(@min(2 * BAL.medicine_per_slot, red_healable));
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
    try start(&s, &enc_fifty_red);

    const red_healable = try accrue_healable(&s.sess, .red, 3);
    try std.testing.expect(red_healable > 0);
    const hunger_before = s.sess.hunger.current;

    // panacea is BLUE medicine — wrong color for red hunger, fully wasted.
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .blue },
        .{ .action = .medicine },
        .{ .action = .medicine },
    }));
    try flush(&s.sess);

    try std.testing.expectEqual(hunger_before, s.sess.hunger.current);
    try std.testing.expectEqual(red_healable, s.sess.hunger_healable[RED]);
    // Dispensed but healed nothing — the overheal is visible in the stats.
    try std.testing.expectEqual(@as(u16, 10), s.sess.stats.feast.medicine_dispensed[BLUE]);
    try std.testing.expectEqual(@as(u16, 0), s.sess.stats.feast.medicine_healed[BLUE]);
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

    // Heavy medicine from both players: nothing is healable, all discarded.
    const medicine = mk(&.{ .{ .element = .blue }, .{ .action = .medicine }, .{ .action = .medicine } });
    try enqueue_submit(&s.sess, s.p[0].pid, medicine);
    try enqueue_submit(&s.sess, s.p[1].pid, medicine);
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
    try start(&s, &enc_fifty_red);

    // One interval: 2 red units eaten → 4 healable.
    const red_healable = try accrue_healable(&s.sess, .red, 1);
    try std.testing.expectEqual(@as(u16, @intCast(2 * BAL.hunger_cost_modified_extra)), red_healable);
    const hunger_before = s.sess.hunger.current;

    // 4 red medicine slots = 12 medicine against 4 healable.
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .red },
        .{ .action = .medicine },
        .{ .action = .medicine },
        .{ .action = .medicine },
        .{ .action = .medicine },
    }));
    try flush(&s.sess);

    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger_healable[RED]);
    try std.testing.expectEqual(hunger_before - red_healable, s.sess.hunger.current);
    try std.testing.expectEqual(@as(u16, 12), s.sess.stats.feast.medicine_dispensed[RED]);
    try std.testing.expectEqual(red_healable, s.sess.stats.feast.medicine_healed[RED]);
    try std.testing.expectEqual(@as(u16, 4), s.sess.stats.players[s.p[0].pid].medicine_slots[RED]);
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
    // 10 red units un-neutralized = 30 hunger ≥ max 25.
    try start(&s, &enc_tight_budget);

    s.p[0].clear();
    var guard: usize = 0;
    while (s.sess.phase == .playing and guard < 20) : (guard += 1) try s.sess.tick(BITE_S);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);
    try std.testing.expectEqual(@as(u16, 25), s.sess.hunger.current); // clamped at max

    const go = try game_over_msg(try drain(s.p[0].buf.items, arena));
    try std.testing.expectEqual(proto.EndReason.hunger_full, go.stats.reason);
    try std.testing.expectEqual(@as(u16, 25), go.stats.hunger_final);
    try std.testing.expectEqual(@as(u16, 25), go.stats.hunger_max);
    try std.testing.expectEqual(@as(u32, 10), go.stats.slime_total);
    // The bar filled before the field was cleared, so slime survives.
    try std.testing.expect(go.stats.slime_left > 0);
}

test "neutralizing the tight budget survives what idle play loses" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_tight_budget); // 10 red, hunger_max 25

    // 10 red agents (2 flat dispense slots) neutralize the whole cohort, so
    // the field costs 10 normal hunger only and every unit scores.
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
    try flush(&s.sess);
    try std.testing.expectEqual(@as(u16, 10), count_neutralized(&s.sess, .red));

    var guard: usize = 0;
    while (s.sess.phase == .playing and guard < 20) : (guard += 1) try s.sess.tick(BITE_S);

    try std.testing.expectEqual(@as(u32, 10), s.sess.score);
    try std.testing.expectEqual(@as(u16, 10), s.sess.hunger.current);
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

    s.p[0].clear();

    // Alice: crimson_flood (player recipe → 20 red agents) covers all 10 red.
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
    // Bob: a flat blue dispense — wrong color for everything here, wasted.
    try enqueue_submit(&s.sess, s.p[1].pid, mk(&.{
        .{ .element = .blue },
        .{ .action = .dispense },
    }));
    try flush(&s.sess);

    var guard: usize = 0;
    while (s.sess.phase == .playing and guard < 40) : (guard += 1) try s.sess.tick(BITE_S);

    const go = try game_over_msg(try drain(s.p[0].buf.items, arena));
    const st = go.stats;

    try std.testing.expectEqual(proto.EndReason.field_cleared, st.reason);
    try std.testing.expectEqual(@as(u32, 25), st.slime_total);
    try std.testing.expectEqual(@as(u32, 0), st.slime_left);
    try std.testing.expectEqual(@as(u16, 2), st.casts_total);

    // Feast tallies: agents dispensed (including the wasted blue), the red
    // cohort neutralized, the green slime that escaped, neutral consumed.
    try std.testing.expectEqual(@as(u16, 20), st.feast.agents_dispensed[RED]);
    try std.testing.expectEqual(@as(u16, 5), st.feast.agents_dispensed[BLUE]);
    try std.testing.expectEqual(@as(u16, 10), st.feast.neutralized[RED]);
    try std.testing.expectEqual(@as(u16, 0), st.feast.modified_escaped[RED]);
    try std.testing.expectEqual(@as(u16, 8), st.feast.modified_escaped[GREEN]);
    try std.testing.expectEqual(@as(u16, 7), st.feast.neutral_consumed);
    try std.testing.expectEqual(@as(u16, @intCast(25 * BAL.hunger_cost_normal)), st.feast.hunger_normal);
    try std.testing.expectEqual(
        @as(u16, @intCast(8 * BAL.hunger_cost_modified_extra)),
        st.feast.hunger_extra,
    );
    // Score = neutralized red + neutral units.
    try std.testing.expectEqual(@as(u32, 17), go.score);

    // Players: dense, named, raw slot attribution + recipe participation.
    try std.testing.expectEqual(@as(u8, 2), st.player_count);
    try std.testing.expectEqualSlices(u8, "Alice", st.players[0].name[0..st.players[0].name_len]);
    try std.testing.expectEqual(@as(u16, 1), st.players[0].casts);
    try std.testing.expectEqual(@as(u16, 3), st.players[0].dispense_slots[RED]);
    try std.testing.expectEqual(@as(u16, 1), st.players[0].recipe_casts);
    try std.testing.expectEqualSlices(u8, "Bob", st.players[1].name[0..st.players[1].name_len]);
    try std.testing.expectEqual(@as(u16, 1), st.players[1].dispense_slots[BLUE]);
    try std.testing.expectEqual(@as(u16, 0), st.players[1].recipe_casts);

    // crimson_flood is player_recipes[0]; no team recipes fired.
    try std.testing.expectEqual(@as(u16, 1), st.player_recipe_hits[0]);
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
    s.sess.field.grid.put(1, .{ .modified = .green });
    s.sess.field.grid.put(2, .{ .neutralized = .blue });

    s.p[0].clear();
    try flush(&s.sess);
    const gs = try last_game_state(try drain(s.p[0].buf.items, arena));

    try std.testing.expectEqual(BAL.slime_grid.rows, gs.grid_rows);
    try std.testing.expectEqual(BAL.slime_grid.cols, gs.grid_cols);
    try std.testing.expectEqual(@as(u16, 60), gs.grid_len());
    try std.testing.expectEqual(c.SlimeCell.neutral, gs.grid[0]);
    try std.testing.expectEqual(c.SlimeCell{ .modified = .green }, gs.grid[1]);
    try std.testing.expectEqual(c.SlimeCell{ .neutralized = .blue }, gs.grid[2]);
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
    try start(&s, &enc_fifty_red);

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
    try start(&s, &enc_fifty_red);
    set_field(&s.sess, .{ .modified = .red }, 50);

    s.p[0].clear();
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    })); // 20 agents, residue 1.0
    try s.sess.tick(BITE_S); // convert, then both Lil Guys bite

    const gs = try last_game_state(try drain(s.p[0].buf.items, arena));
    var neutralized: u16 = 0;
    var modified: u16 = 0;
    var occupied: u16 = 0;
    for (gs.grid[0..gs.grid_len()]) |cell| {
        if (cell.is_slime()) occupied += 1;
        if (cell == .neutralized) neutralized += 1;
        if (cell == .modified) modified += 1;
    }
    // 50 cells, 20 transmuted, 2 eaten (nothing left to refill with).
    try std.testing.expectEqual(@as(u16, 48), occupied);
    try std.testing.expectEqual(neutralized + modified, occupied);
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
    try start(&s, &enc_fifty_red);

    const combo = mk(&.{ .{ .element = .red }, .{ .action = .dispense } });
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
        try std.testing.expectEqual(c.Element.red, e.combo_slots[0].element);
        try std.testing.expectEqual(c.ActionChoice.dispense, e.combo_slots[1].action);
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
    try start(&s, &enc_fifty_red);
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
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{ .{ .element = .red }, .{ .action = .dispense } }));
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

test "an all-neutralized grid broadcasts zero healable hunger in every color" {
    // Wire-level regression for "modified slime showing in the hunger bar
    // after neutralizing everything".
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    const cfg = cfg_instant_cast();
    s.sess.cfg = &cfg;
    try start(&s, &enc_twenty_red);
    set_field(&s.sess, .{ .modified = .red }, 20);

    // crimson_flood covers the 20-cell cohort exactly, then everything is eaten.
    try enqueue_submit(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
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
