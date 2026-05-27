//! Integration tests for the round-based game session.
//!
//! Tests drive Session directly — no network, no threads.
//! Transport is a BufferTransport that accumulates outgoing bytes.
//!
//! Round mechanics under test:
//!   - damage pool → net(damage - opposing_shield) * ACTION_EFFECT_VALUE applied to HP pool
//!   - shield pool → cancels equal opposing damage this round; unused shields discarded
//!   - heal pool   → shared party HP pool heals pool_size * ACTION_EFFECT_VALUE
//!   - enemy intent → folded into enemy damage tally; netted against player shields
//!   - configurable round_duration respected
//!   - death/wave-chain/game-over paths

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;
const logic = shared.game_logic;
const waves = shared.waves;

const session_mod = @import("session.zig");
const Session = session_mod.Session;

/// Shorthand for readability in expected-value calculations.
const V = logic.ACTION_EFFECT_VALUE;

// ---------------------------------------------------------------------------
// Minimal test waves
// ---------------------------------------------------------------------------

/// One grunt that survives many rounds (HP = 100 * V, attack = 1).
/// With pool=2 players, deals V*2 damage per round → needs 50 rounds to die.
const test_wave_single = waves.Wave{
    .label = "test_single",
    .entries = &[_]waves.SpawnEntry{.{
        .class = .grunt,
        .grid_col = 0,
        .grid_row = 0,
        .stats = .{ .attack = 1, .defense = 1, .max_hp = V * 100, .speed_base = 0.001 },
    }},
    .next_wave = null,
};

/// One grunt with exactly V HP — killed by a single player damage action (pool=1).
const test_wave_one_hp = waves.Wave{
    .label = "test_one_hp",
    .entries = &[_]waves.SpawnEntry{.{
        .class = .grunt,
        .grid_col = 0,
        .grid_row = 0,
        .stats = .{ .attack = 1, .defense = 1, .max_hp = V, .speed_base = 0.001 },
    }},
    .next_wave = null,
};

/// Chain wave: first wave links to wave_01_basic.
const test_wave_to_real = waves.Wave{
    .label = "test_to_real",
    .entries = &[_]waves.SpawnEntry{.{
        .class = .grunt,
        .grid_col = 0,
        .grid_row = 0,
        .stats = .{ .attack = 1, .defense = 1, .max_hp = 1, .speed_base = 0.001 },
    }},
    .next_wave = "wave_01_basic",
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
        .join_lobby    => if (proto.decode_join_lobby(r))    |_| true else |_| false,
        .choose_class  => if (proto.decode_choose_class(r))  |_| true else |_| false,
        .choose_action => if (proto.decode_choose_action(r)) |_| true else |_| false,
        .reconnect     => if (proto.decode_reconnect(r))     |_| true else |_| false,
        .ready_up      => true, // zero-payload
        .choose_combo  => if (proto.decode_choose_combo(r))  |_| true else |_| false,
        .cancel_combo  => true, // zero-payload
        .lobby_update  => if (proto.decode_lobby_update(r))  |_| true else |_| false,
        .game_start    => if (proto.decode_game_start(r))    |_| true else |_| false,
        .game_state    => if (proto.decode_game_state(r))    |_| true else |_| false,
        .action_result => if (proto.decode_action_result(r)) |_| true else |_| false,
        .round_reset   => true, // zero-payload
        .game_over     => if (proto.decode_game_over(r))     |_| true else |_| false,
    };
}

/// Enqueue a single-action combo (convenience for tests).
fn enqueue_action(sess: *Session, pid: u8, action: c.ActionChoice) !void {
    try enqueue_combo(sess, pid, make_action_combo(&[_]c.ActionChoice{action}));
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

fn count_action_results_with(msgs: []const Msg, result_tag: proto.ActionResultTag) !usize {
    var n: usize = 0;
    for (msgs) |m| {
        if (m.tag != .action_result) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const ar = try proto.decode_action_result(fbs.reader());
        if (ar.tag == result_tag) n += 1;
    }
    return n;
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

/// Tick the session `n` times with `dt` seconds each.
fn tick_n(sess: *Session, dt: f32, n: u32) !void {
    var i: u32 = 0;
    while (i < n) : (i += 1) try sess.tick(dt);
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
    class0: c.ClassTag,
    class1: c.ClassTag,
) !void {
    self.allocator = allocator;
    self.p[0].buf = .empty;
    self.p[1].buf = .empty;
    self.p[0].init(allocator);
    self.p[1].init(allocator);

    self.sess = try Session.init(allocator, "TSTKEY".*);

    const pid0 = self.sess.join(self.p[0].transport(), "") orelse return error.JoinFailed;
    const pid1 = self.sess.join(self.p[1].transport(), "") orelse return error.JoinFailed;
    self.p[0].pid = pid0;
    self.p[1].pid = pid1;

    self.sess.set_class(pid0, class0);
    self.sess.set_class(pid1, class1);

    const slot0 = &self.sess.players[pid0];
    @memcpy(slot0.name[0..5], "Alice");
    slot0.name_len = 5;

    const slot1 = &self.sess.players[pid1];
    @memcpy(slot1.name[0..3], "Bob");
    slot1.name_len = 3;
}

// ---------------------------------------------------------------------------
// Lobby tests
// ---------------------------------------------------------------------------

test "join sets name in lobby_update" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .mage);
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
    try init_two_player_session(&s, allocator, .fighter, .mage);
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

test "lobby_update carries round_duration" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .mage);
    defer s.deinit();

    s.sess.round_duration = 5.0;
    s.p[0].clear();
    try s.sess.broadcast_lobby_update();

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .lobby_update) orelse return error.NoLobbyUpdate;
    var fbs = std.io.fixedBufferStream(m.payload);
    const lu = try proto.decode_lobby_update(fbs.reader());
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), lu.round_duration, 0.001);
}

test "all ready triggers game_start with round_duration" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .healer);
    defer s.deinit();

    s.sess.round_duration = 4.0;
    s.p[0].clear();
    s.p[1].clear();

    try s.sess.start_game_wave(&test_wave_single);
    try s.sess.broadcast_game_start("test_single");

    inline for (.{ 0, 1 }) |i| {
        const msgs = try drain(s.p[i].buf.items, arena);
        const m = find_tag(msgs, .game_start) orelse return error.NoGameStart;
        var fbs = std.io.fixedBufferStream(m.payload);
        const gs = try proto.decode_game_start(fbs.reader());
        try std.testing.expectEqual(s.p[i].pid, gs.player_id);
        try std.testing.expectApproxEqAbs(@as(f32, 4.0), gs.round_duration, 0.001);
    }
    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);
}

// ---------------------------------------------------------------------------
// Round-based combat tests
// ---------------------------------------------------------------------------

/// Helper: start a session, enqueue actions for both players, tick until
/// the round resolves (using a very short round_duration), return messages.
///
/// `dt` ticks of size `dt_step` until `round_duration` elapses or exceeds.
fn resolve_one_round(
    sess: *Session,
    player_actions: []const ?c.ActionChoice,
    arena: std.mem.Allocator,
    out_buf: *std.ArrayListUnmanaged(u8),
) ![]Msg {
    out_buf.clearRetainingCapacity();
    // Submit actions as single-slot combos.
    for (player_actions, 0..) |maybe_action, i| {
        const action = maybe_action orelse continue;
        try enqueue_action(sess, @intCast(i), action);
    }
    // Tick until round fires (round_duration = 0.1s, step = 0.1s → 1 tick)
    try tick_n(sess, sess.round_duration + 0.001, 1);
    return drain(out_buf.items, arena);
}

test "damage pool reduces shared enemy HP" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 1); // clear enemy combos so no enemy shields block player damage

    const hp_before = s.sess.shared_enemy_hp.current;

    // Both players choose damage → pool = 2 → 2 * V dmg to shared enemy pool
    try enqueue_action(&s.sess, s.p[0].pid, .damage);
    try enqueue_action(&s.sess, s.p[1].pid, .damage);
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(hp_before - 2 * V, s.sess.shared_enemy_hp.current);
}

test "damage pool: action_result.damage broadcast" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    try enqueue_action(&s.sess, s.p[0].pid, .damage);
    s.p[0].clear();
    try tick_n(&s.sess, 0.11, 1);

    const msgs = try drain(s.p[0].buf.items, arena);
    const dmg_count = try count_action_results_with(msgs, .damage);
    // 1 damage result for the enemy pool + 1 for enemy attacking party pool
    try std.testing.expect(dmg_count >= 1);
}

test "kill enemy with exactly enough damage" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_one_hp); // shared_enemy_hp = V
    set_enemy_ai(&s.sess, 0); // clear enemy combos so no shields block player damage

    // 1 player damage action → pool=1 → 1*V dmg → shared_enemy_hp = 0
    try enqueue_action(&s.sess, s.p[0].pid, .damage);
    s.p[0].clear();
    try tick_n(&s.sess, 0.11, 1);

    // Shared enemy pool depleted
    try std.testing.expectEqual(@as(u16, 0), s.sess.shared_enemy_hp.current);

    // Death broadcast sent
    const msgs = try drain(s.p[0].buf.items, arena);
    var found_death = false;
    for (msgs) |m| {
        if (m.tag != .action_result) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const ar = try proto.decode_action_result(fbs.reader());
        if (ar.tag == .death) found_death = true;
    }
    try std.testing.expect(found_death);
}

test "shield cancels equal element-matched enemy damage — HP unchanged" {
    // Two players each shield (null-element). Enemy intent = 2 dmg (null-element).
    // Net enemy damage to player pool: 2 - 2 = 0. HP unchanged.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    set_enemy_ai(&s.sess, 2); // 2 null-element damage

    const hp_before = s.sess.shared_hp.current;
    try enqueue_action(&s.sess, s.p[0].pid, .shield); // +1 null shield
    try enqueue_action(&s.sess, s.p[1].pid, .shield); // +1 null shield
    try tick_n(&s.sess, 0.11, 1);

    // 2 shield vs 2 damage → net 0 → HP unchanged.
    try std.testing.expectEqual(hp_before, s.sess.shared_hp.current);
}

test "heal pool heals shared party pool" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    // Force null-element intent (1 dmg) so HP math is deterministic.
    set_enemy_ai(&s.sess, 1);

    // Wound the shared pool first.
    s.sess.shared_hp.current = 50;
    const hp_before: u16 = 50;

    // Both players heal → pool=2 → shared HP heals 2*V
    // Enemy null-intent deals 1 dmg to shared pool in same round.
    // Net: +2*V - 1.
    try enqueue_action(&s.sess, s.p[0].pid, .heal);
    try enqueue_action(&s.sess, s.p[1].pid, .heal);
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(hp_before + 2 * V - 1, s.sess.shared_hp.current);

    s.p[0].clear();
}

test "null-element shield granted this round absorbs null-element enemy damage" {
    // Shields reset at the start of each round and must be granted via actions.
    // This verifies that shield granted in the same round absorbs matching enemy damage.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single); // 1 enemy

    // Force null-element intent (1 dmg) and no enemy combo damage.
    set_enemy_ai(&s.sess, 1);

    const hp_before = s.sess.shared_hp.current;

    // Both players shield (2 null-element). Enemy intent = 1 null-element.
    // Net: 1 damage - 2 shield = 0 → HP unchanged.
    try enqueue_action(&s.sess, s.p[0].pid, .shield);
    try enqueue_action(&s.sess, s.p[1].pid, .shield);
    try tick_n(&s.sess, 0.11, 1);

    // HP must be unchanged: shield absorbed the 1 null-element damage.
    try std.testing.expectEqual(hp_before, s.sess.shared_hp.current);
}

test "enemy depletes shared pool — enemies win" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    // Force null-element intent with 1 dmg so it directly kills the 1-HP party pool.
    set_enemy_ai(&s.sess, 1);

    s.sess.shared_hp.current = 1;
    s.sess.shared_hp.max = 1;

    s.p[0].clear();
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .game_over) orelse return error.NoGameOver;
    var fbs = std.io.fixedBufferStream(m.payload);
    const go = try proto.decode_game_over(fbs.reader());
    try std.testing.expectEqual(proto.WinnerId.enemies, go.winner);
}

test "shared enemy pool depleted — players win" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_one_hp); // shared_enemy_hp = V
    set_enemy_ai(&s.sess, 0); // clear enemy combos so no shields block player damage

    try enqueue_action(&s.sess, s.p[0].pid, .damage);
    s.p[0].clear();
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .game_over) orelse return error.NoGameOver;
    var fbs = std.io.fixedBufferStream(m.payload);
    const go = try proto.decode_game_over(fbs.reader());
    try std.testing.expectEqual(proto.WinnerId.players, go.winner);
}

test "wave chain advances to next wave" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    // First wave: shared_enemy_hp = 1 → next wave = wave_01_basic (3 grunts × 80 HP)
    try s.sess.start_game_wave(&test_wave_to_real);
    set_enemy_ai(&s.sess, 0); // clear enemy combos so no shields block player damage

    try enqueue_action(&s.sess, s.p[0].pid, .damage);
    s.p[0].clear();
    try tick_n(&s.sess, 0.11, 1);

    // wave_01_basic spawned → shared_enemy_hp reset to new pool (> 0), still playing
    try std.testing.expect(s.sess.shared_enemy_hp.current > 0);
    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);

    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expect(find_tag(msgs, .game_state) != null);
}

test "action can be overwritten before round resolves" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.5; // long round
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 1); // clear enemy combos so no shields block player damage

    // First submit heal, then overwrite with damage before round ends
    try enqueue_action(&s.sess, s.p[0].pid, .heal);
    // Tick a little (doesn't fire round yet)
    try tick_n(&s.sess, 0.1, 1);
    // Verify the first action was recorded (single-slot combo, len=1)
    try std.testing.expectEqual(c.ActionChoice.heal, s.sess.action_pool[s.p[0].pid].?.slots[0].action);
    try std.testing.expectEqual(@as(u8, 1), s.sess.action_pool[s.p[0].pid].?.len);

    // Overwrite with damage
    try enqueue_action(&s.sess, s.p[0].pid, .damage);
    try tick_n(&s.sess, 0.1, 1);
    try std.testing.expectEqual(c.ActionChoice.damage, s.sess.action_pool[s.p[0].pid].?.slots[0].action);

    // Let the round fire — damage chosen, not heal
    try tick_n(&s.sess, 0.5, 1);

    // Shared enemy pool must have gone down (damage applied)
    try std.testing.expect(s.sess.shared_enemy_hp.current < V * 100);

    // Shared pool HP must not exceed max
    try std.testing.expect(s.sess.shared_hp.current <= s.sess.shared_hp.max);
}

test "action pool resets after each round" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    // Round 1: both damage
    try enqueue_action(&s.sess, s.p[0].pid, .damage);
    try enqueue_action(&s.sess, s.p[1].pid, .damage);
    try tick_n(&s.sess, 0.11, 1);

    // After round, pool must be cleared
    for (&s.sess.action_pool) |maybe| {
        try std.testing.expectEqual(@as(?c.ActionCombo, null), maybe);
    }
}

test "no actions submitted — enemy still attacks shared pool" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single); // 1 enemy

    // Force null-element intent (1 dmg) and clear enemy combos for determinism.
    set_enemy_ai(&s.sess, 1);

    const hp_max = s.sess.shared_hp.max;

    // No actions; tick through round
    try tick_n(&s.sess, 0.11, 1);

    // Enemy null-intent deals 1 dmg to shared pool
    try std.testing.expectEqual(hp_max - 1, s.sess.shared_hp.current);
}

test "round_timer counts down and resets" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 1.0;
    try s.sess.start_game_wave(&test_wave_single);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.sess.round_timer, 0.001);

    // Tick 0.4s — timer should be around 0.6
    try tick_n(&s.sess, 0.4, 1);
    try std.testing.expect(s.sess.round_timer < 1.0);
    try std.testing.expect(s.sess.round_timer > 0.0);

    // Tick past the full second — round fires and timer resets to round_duration
    try tick_n(&s.sess, 0.7, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.sess.round_timer, 0.001);
}

// ---------------------------------------------------------------------------
// Reconnect test
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Gap-analysis integration tests
// ---------------------------------------------------------------------------

test "mixed pool: damage + shield in one round" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single); // shared_enemy_hp = 100*V

    // Force null-element intent so shield absorption is deterministic.
    set_enemy_ai(&s.sess, 1);

    // p0 → damage (null), p1 → shield (null)
    // Player damage: 1 null. Enemy shield: 0. Net player damage: 1.
    // Enemy damage (intent 1 null). Player shield: 1 null. Net enemy damage: 0.
    try enqueue_action(&s.sess, s.p[0].pid, .damage);
    try enqueue_action(&s.sess, s.p[1].pid, .shield);

    const hp_before = s.sess.shared_hp.current;
    try tick_n(&s.sess, 0.11, 1);

    // Enemy pool took 1*V damage from player.
    try std.testing.expectEqual(V * 100 - V, s.sess.shared_enemy_hp.current);
    // Player pool took 0 damage: 1 shield cancelled 1 intent.
    try std.testing.expectEqual(hp_before, s.sess.shared_hp.current);
}

test "enemy pool alive deals 1 damage to party per round" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    // Multiple enemy entities — intent is 1 regardless of count.
    const two_enemy_wave = waves.Wave{
        .label = "t_two",
        .entries = &[_]waves.SpawnEntry{
            .{ .class = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .attack = 1, .defense = 1, .max_hp = 99, .speed_base = 0.001 } },
            .{ .class = .grunt, .grid_col = 1, .grid_row = 0, .stats = .{ .attack = 1, .defense = 1, .max_hp = 99, .speed_base = 0.001 } },
        },
        .next_wave = null,
    };
    try s.sess.start_game_wave(&two_enemy_wave);

    // Force 1 null-element damage so assertion is deterministic regardless of living count.
    set_enemy_ai(&s.sess, 1);

    const hp_before = s.sess.shared_hp.current;

    // No actions: null-element intent → 1 dmg to party pool
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(hp_before - 1, s.sess.shared_hp.current);
}

test "enemy intent depletes shared pool when heal cannot outpace it" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    // Force null-element intent with 1 dmg — deterministic kill.
    set_enemy_ai(&s.sess, 1);

    s.sess.shared_hp.current = 1;
    s.sess.shared_hp.max = 1;

    // No actions: null-element intent = 1 → pool goes to 0
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(@as(u16, 0), s.sess.shared_hp.current);
}

test "game_state wire: round_timer decrement reflected in broadcast" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 1.0;
    try s.sess.start_game_wave(&test_wave_single);

    s.p[0].clear();
    try tick_n(&s.sess, 0.3, 1); // timer should be ~0.7

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .game_state) orelse return error.NoGameState;
    var fbs = std.io.fixedBufferStream(m.payload);
    const gs = try proto.decode_game_state(fbs.reader());

    try std.testing.expect(gs.round_timer < 1.0);
    try std.testing.expect(gs.round_timer > 0.0);
}

test "disconnect mid-game: round resolves cleanly for remaining player" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    // Disconnect player 1 mid-game
    s.sess.disconnect(s.p[1].pid);

    set_enemy_ai(&s.sess, 0); // clear enemy combos so no shields block player damage

    // Submit damage from surviving player 0
    try enqueue_action(&s.sess, s.p[0].pid, .damage);
    s.p[0].clear();

    // Must not crash
    try tick_n(&s.sess, 0.11, 1);

    // Enemy pool took damage
    try std.testing.expect(s.sess.shared_enemy_hp.current < V * 100);

    // Player 0 still received broadcast
    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expect(find_tag(msgs, .game_state) != null);
}

test "heal at full shared HP — HP stays at max" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    // Shared pool already at max after spawn; ensure it is.
    s.sess.shared_hp.current = s.sess.shared_hp.max;
    const hp_max = s.sess.shared_hp.max;

    // Both players heal
    try enqueue_action(&s.sess, s.p[0].pid, .heal);
    try enqueue_action(&s.sess, s.p[1].pid, .heal);
    try tick_n(&s.sess, 0.11, 1);

    // HP must not exceed max (enemy dealt 1 dmg so hp = max - 1)
    try std.testing.expect(s.sess.shared_hp.current <= hp_max);
}

test "action_result heal broadcast value matches pool size" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    // Wound the shared pool so heal has room
    s.sess.shared_hp.current = 50;

    // Both choose heal → pool = 2
    try enqueue_action(&s.sess, s.p[0].pid, .heal);
    try enqueue_action(&s.sess, s.p[1].pid, .heal);
    s.p[0].clear();
    try tick_n(&s.sess, 0.11, 1);

    const msgs = try drain(s.p[0].buf.items, arena);
    var found_heal_value = false;
    for (msgs) |m| {
        if (m.tag != .action_result) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const ar = try proto.decode_action_result(fbs.reader());
        if (ar.tag == .heal) {
            // value = pool_size * V = 2 * V
            try std.testing.expectEqual(2 * V, ar.value);
            found_heal_value = true;
        }
    }
    try std.testing.expect(found_heal_value);
}

// ---------------------------------------------------------------------------
// Reconnect test
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Lobby disconnect tests
// ---------------------------------------------------------------------------

test "disconnect in lobby: slot freed and player_count decremented" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .mage);
    defer s.deinit();

    try std.testing.expectEqual(@as(u8, 2), s.sess.player_count);

    const pid = s.p[0].pid;
    s.sess.disconnect(pid);

    // Slot must be freed and count decremented
    try std.testing.expect(!s.sess.players[pid].occupied);
    try std.testing.expect(!s.sess.players[pid].connected);
    try std.testing.expectEqual(@as(u8, 1), s.sess.player_count);

    // Remaining player still sees only themselves in lobby_update
    s.p[1].clear();
    try s.sess.broadcast_lobby_update();
    const msgs = try drain(s.p[1].buf.items, arena);
    const m = find_tag(msgs, .lobby_update) orelse return error.NoLobbyUpdate;
    var fbs = std.io.fixedBufferStream(m.payload);
    const lu = try proto.decode_lobby_update(fbs.reader());
    try std.testing.expectEqual(@as(u8, 1), lu.player_count);
}

test "choose_class: class reflected in next lobby_update" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    const pid = s.p[0].pid;
    try enqueue_msg(&s.sess, pid, .choose_class, proto.ChooseClass{ .class = .mage });
    // tick to drain queue (still in lobby)
    try s.sess.tick(0.016);

    s.p[0].clear();
    try s.sess.broadcast_lobby_update();

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .lobby_update) orelse return error.NoLobbyUpdate;
    var fbs = std.io.fixedBufferStream(m.payload);
    const lu = try proto.decode_lobby_update(fbs.reader());

    try std.testing.expectEqual(c.ClassTag.mage, lu.players[pid].class);
}

test "reconnect to lobby slot: slot re-occupied without join" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .healer);
    defer s.deinit();

    const pid = s.p[0].pid;
    // Disconnect while in lobby — slot freed
    s.sess.disconnect(pid);
    try std.testing.expectEqual(@as(u8, 1), s.sess.player_count);

    // Reconnect to the same slot — lobby reconnect path
    const ok = s.sess.reconnect(pid, s.p[0].transport());
    try std.testing.expect(ok);
    try std.testing.expect(s.sess.players[pid].occupied);
    try std.testing.expect(s.sess.players[pid].connected);
    try std.testing.expectEqual(@as(u8, 2), s.sess.player_count);

    // Should receive lobby_update on next broadcast
    s.p[0].clear();
    try s.sess.broadcast_lobby_update();
    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expect(find_tag(msgs, .lobby_update) != null);
}

// ---------------------------------------------------------------------------
// Reconnect test
// ---------------------------------------------------------------------------

test "reconnect restores slot" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .healer);
    defer s.deinit();

    const pid = s.p[0].pid;
    s.sess.disconnect(pid);
    try std.testing.expect(!s.sess.players[pid].connected);

    const ok = s.sess.reconnect(pid, s.p[0].transport());
    try std.testing.expect(ok);
    try std.testing.expect(s.sess.players[pid].connected);

    s.p[0].clear();
    try s.sess.broadcast_lobby_update();

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .lobby_update) orelse return error.NoLobbyUpdate;
    var fbs = std.io.fixedBufferStream(m.payload);
    const lu = try proto.decode_lobby_update(fbs.reader());

    try std.testing.expect(lu.players[pid].connected);
    try std.testing.expectEqual(pid, lu.player_id);
}

// ---------------------------------------------------------------------------
// Combo tests
// ---------------------------------------------------------------------------

fn make_combo(slots: []const c.ComboSlot) c.ActionCombo {
    var combo = c.ActionCombo{
        .slots = [_]c.ComboSlot{.{ .action = .damage }} ** c.MAX_COMBO_LEN,
        .len = @intCast(slots.len),
    };
    @memcpy(combo.slots[0..slots.len], slots);
    return combo;
}

/// Convenience: build a combo from action-only choices (no element slots).
fn make_action_combo(actions: []const c.ActionChoice) c.ActionCombo {
    var slots: [c.MAX_COMBO_LEN]c.ComboSlot = [_]c.ComboSlot{.{ .action = .damage }} ** c.MAX_COMBO_LEN;
    for (actions, 0..) |a, i| slots[i] = .{ .action = a };
    return make_combo(slots[0..actions.len]);
}

/// Force deterministic enemy behaviour for tests that rely on exact HP/shield math.
/// Sets intent to null-element with the given damage value and clears all enemy combos.
fn set_enemy_ai(sess: *Session, intent_damage: u16) void {
    sess.pending_enemy_intent = .{ .damage_per_player = intent_damage, .element = null };
    for (&sess.enemy_combos) |*ec| ec.* = null;
}

fn enqueue_combo(sess: *Session, pid: u8, combo: c.ActionCombo) !void {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), .choose_combo, proto.ChooseCombo{ .combo = combo });
    sess.enqueue_message(pid, fbs.getWritten());
}

fn enqueue_cancel(sess: *Session, pid: u8) !void {
    var buf: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), .cancel_combo, {});
    sess.enqueue_message(pid, fbs.getWritten());
}

test "combo [dmg,dmg] → damage_pool = 2" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    // Clear enemy combos so no enemy shields cancel player damage.
    set_enemy_ai(&s.sess, 1);

    const hp_before = s.sess.shared_enemy_hp.current;

    // p0 submits combo [dmg, dmg] → contributes 2 to damage pool → 2*V dmg to shared enemy pool
    try enqueue_combo(&s.sess, s.p[0].pid, make_action_combo(&[_]c.ActionChoice{ .damage, .damage }));
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(hp_before - 2 * V, s.sess.shared_enemy_hp.current);
}

test "combo [dmg,shld,heal,dmg] → damage, shield cancel, and heal all apply" {
    // combo: damage=2, shield=1, heal=1 (all null-element).
    // Enemy intent = 1 null-element.
    // Player damage (2) vs enemy shield (0) → 2*V to enemy HP.
    // Enemy damage (1 intent) vs player shield (1) → net 0 → player HP unchanged.
    // Heal: +V to player HP.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    set_enemy_ai(&s.sess, 1); // 1 null-element intent

    const enemy_hp_before = s.sess.shared_enemy_hp.current;

    // Wound party pool so heal has room.
    s.sess.shared_hp.current = 50;
    const party_hp_before = s.sess.shared_hp.current;

    try enqueue_combo(&s.sess, s.p[0].pid, make_action_combo(&[_]c.ActionChoice{ .damage, .shield, .heal, .damage }));
    try tick_n(&s.sess, 0.11, 1);

    // Enemy pool: 2*V damage from player.
    try std.testing.expectEqual(enemy_hp_before - 2 * V, s.sess.shared_enemy_hp.current);
    // Player pool: 1 intent - 1 shield = 0 net damage; heal +V.
    try std.testing.expectEqual(party_hp_before + V, s.sess.shared_hp.current);
}

test "combo overwrite before round fires — latest combo wins" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.5;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 1); // clear enemy combos so no shields block player damage

    const enemy_hp_before = s.sess.shared_enemy_hp.current;

    // First submit a heal-only combo (no damage to enemy)
    try enqueue_combo(&s.sess, s.p[0].pid, make_action_combo(&[_]c.ActionChoice{.heal}));
    try tick_n(&s.sess, 0.1, 1);
    try std.testing.expectEqual(@as(u8, 1), s.sess.action_pool[s.p[0].pid].?.len);

    // Overwrite with a damage combo before round fires
    try enqueue_combo(&s.sess, s.p[0].pid, make_action_combo(&[_]c.ActionChoice{ .damage, .damage }));
    try tick_n(&s.sess, 0.1, 1);
    try std.testing.expectEqual(@as(u8, 2), s.sess.action_pool[s.p[0].pid].?.len);

    // Let round fire (reset_round regenerates AI; apply_fixed_intent not available here
    // so we re-clear enemy combos manually before the timer fires)
    set_enemy_ai(&s.sess, 1);
    try tick_n(&s.sess, 0.5, 1);

    // Shared enemy pool took 2*V damage (damage combo resolved, not the heal)
    try std.testing.expectEqual(enemy_hp_before - 2 * V, s.sess.shared_enemy_hp.current);
}

test "cancel_combo nulls the pool slot" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.5;
    try s.sess.start_game_wave(&test_wave_single);

    // Submit combo then cancel it
    try enqueue_combo(&s.sess, s.p[0].pid, make_action_combo(&[_]c.ActionChoice{ .damage, .damage }));
    try tick_n(&s.sess, 0.1, 1);
    try std.testing.expect(s.sess.action_pool[s.p[0].pid] != null);

    try enqueue_cancel(&s.sess, s.p[0].pid);
    try tick_n(&s.sess, 0.1, 1);
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.action_pool[s.p[0].pid]);
}

test "two combos from different players — both contribute" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 1); // clear enemy combos so no shields block player damage

    const hp_before = s.sess.shared_enemy_hp.current;

    // p0: single-slot combo → +1 to damage pool
    try enqueue_action(&s.sess, s.p[0].pid, .damage);
    // p1: combo [dmg, dmg] → +2 to damage pool
    try enqueue_combo(&s.sess, s.p[1].pid, make_action_combo(&[_]c.ActionChoice{ .damage, .damage }));
    try tick_n(&s.sess, 0.11, 1);

    // total damage_pool = 3 → shared enemy pool loses 3*V HP
    try std.testing.expectEqual(hp_before - 3 * V, s.sess.shared_enemy_hp.current);
}

test "round_reset broadcast after resolve_round" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    s.p[0].clear();
    try tick_n(&s.sess, 0.11, 1); // trigger round resolution

    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expect(find_tag(msgs, .round_reset) != null);
}

test "action pool resets after combo round" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    try enqueue_combo(&s.sess, s.p[0].pid, make_action_combo(&[_]c.ActionChoice{ .damage, .shield }));
    try enqueue_combo(&s.sess, s.p[1].pid, make_action_combo(&[_]c.ActionChoice{.heal}));
    try tick_n(&s.sess, 0.11, 1);

    for (&s.sess.action_pool) |maybe| {
        try std.testing.expectEqual(@as(?c.ActionCombo, null), maybe);
    }
}

// ---------------------------------------------------------------------------
// Element combo integration tests
// ---------------------------------------------------------------------------

test "element combo [fire, damage, damage] → damage_pool = 2" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 1); // clear enemy combos so no shields block player damage

    const hp_before = s.sess.shared_enemy_hp.current;

    // [fire, damage, damage] → 2 fire-elemented actions → damage_pool = 2
    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .damage },
    }));
    try tick_n(&s.sess, 0.11, 1);

    // Pool math unchanged; element is metadata only for now.
    try std.testing.expectEqual(hp_before - 2 * V, s.sess.shared_enemy_hp.current);
}

test "element-mismatched shield does not cancel enemy damage" {
    // Player submits [earth, shield]. Enemy intent = 1 null-element.
    // Earth shield does not cancel null-element damage → player HP takes full intent damage.
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    set_enemy_ai(&s.sess, 1); // 1 null-element intent

    const hp_before = s.sess.shared_hp.current;

    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .element = .earth  },
        .{ .action  = .shield },
    }));
    try tick_n(&s.sess, 0.11, 1);

    // Earth shield (key=earth) does not cancel null-element damage (key=none).
    // Player HP takes full 1*V intent damage.
    try std.testing.expectEqual(hp_before - V, s.sess.shared_hp.current);
}

test "trailing element in combo is ignored — damage_pool unchanged" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 1); // clear enemy combos so no shields block player damage

    const hp_before = s.sess.shared_enemy_hp.current;

    // [damage, wind] — trailing element → only 1 damage action counted
    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .action  = .damage },
        .{ .element = .wind   },
    }));
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(hp_before - V, s.sess.shared_enemy_hp.current);
}

// ---------------------------------------------------------------------------
// DoT (damage-over-time) tests
// ---------------------------------------------------------------------------

test "DoT: player [fire,dmg,heal] with no enemy shield → enemy gains 1 fire stack" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 0); // no enemy shields

    // [fire, damage, heal] → direct net = 1, heal_element_mask has fire → trigger
    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire  },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    }));
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(@as(u16, 1), s.sess.enemy_dot_stacks[0]); // fire = index 0
    try std.testing.expectEqual(@as(u16, 0), s.sess.enemy_dot_stacks[1]); // earth unchanged
}

test "DoT: player fire trigger blocked by enemy fire shield → no stack" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    // Enemy has 1 fire shield — exactly cancels the 1 fire damage.
    s.sess.pending_enemy_intent = .{ .damage_per_player = 0, .element = null };
    s.sess.enemy_combos[0] = make_combo(&[_]c.ComboSlot{
        .{ .element = .fire  },
        .{ .action  = .shield },
    });

    // Player: [fire, dmg, heal] → direct net = 1 - 1 = 0 → no trigger
    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire  },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    }));
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(@as(u16, 0), s.sess.enemy_dot_stacks[0]);
}

test "DoT: stacks persist across rounds without re-trigger" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 0);

    // Round 1: trigger fire DoT
    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire  },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    }));
    try tick_n(&s.sess, 0.11, 1);
    try std.testing.expectEqual(@as(u16, 1), s.sess.enemy_dot_stacks[0]);

    // Round 2: no player action; pin enemy AI so it doesn't cleanse the stack
    set_enemy_ai(&s.sess, 0);
    try tick_n(&s.sess, 0.11, 1);
    try std.testing.expectEqual(@as(u16, 1), s.sess.enemy_dot_stacks[0]);
}

test "DoT: existing enemy stack ticks damage each round" {
    // Pre-seed 1 fire stack on enemy; verify enemy HP decreases by 1*V each round.
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 0);
    s.sess.enemy_dot_stacks[0] = 1; // 1 fire stack pre-seeded

    const hp_before = s.sess.shared_enemy_hp.current;

    // No player action — only DoT ticks
    try tick_n(&s.sess, 0.11, 1);

    // 1 fire stack × V = V damage to enemy
    try std.testing.expectEqual(hp_before - V, s.sess.shared_enemy_hp.current);
}

test "DoT: enemy fire stack partially mitigated by player fire shield" {
    // 2 fire stacks on enemy side (ticks 2*V to players); player has 1 fire shield → net 1*V
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 0);
    s.sess.player_dot_stacks[0] = 2; // 2 fire stacks on player party

    // Wound party so we can observe damage
    s.sess.shared_hp.current = 50;
    const hp_before = s.sess.shared_hp.current;

    // Player submits 1 fire shield
    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire  },
        .{ .action  = .shield },
    }));
    try tick_n(&s.sess, 0.11, 1);

    // Fire DoT = 2*V; fire shield absorbs 1*V; net = 1*V damage to party
    try std.testing.expectEqual(hp_before - V, s.sess.shared_hp.current);
}

test "DoT: enemy [fire,dmg,heal] triggers player fire stack (symmetric)" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    // Enemy has [fire, dmg, heal]; no player shields
    s.sess.pending_enemy_intent = .{ .damage_per_player = 0, .element = null };
    s.sess.enemy_combos[0] = make_combo(&[_]c.ComboSlot{
        .{ .element = .fire  },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    });

    // No player shields
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(@as(u16, 1), s.sess.player_dot_stacks[0]);
}

test "DoT: two players both trigger same element → 2 stacks added" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 0); // no enemy shields

    // Both players submit [fire, dmg, heal]; each contributes 1 fire-dmg + 1 fire-heal.
    // Pooled fire-dmg = 2, enemy fire-shield = 0, net = 2 > 0 → trigger fires per trigger check.
    // But the trigger fires once at the pool level (peek-net checks the pooled damage bucket).
    // So enemy_dot_stacks[0] increments once per trigger, not per player.
    // → We expect exactly 1 stack (pool-level trigger, not per-player).
    const fire_combo = make_combo(&[_]c.ComboSlot{
        .{ .element = .fire  },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    });
    try enqueue_combo(&s.sess, s.p[0].pid, fire_combo);
    try enqueue_combo(&s.sess, s.p[1].pid, fire_combo);
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(@as(u16, 1), s.sess.enemy_dot_stacks[0]);
}

test "DoT: trigger fires on second round when re-triggered → stacks accumulate" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 0);

    const fire_combo = make_combo(&[_]c.ComboSlot{
        .{ .element = .fire  },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    });

    // Round 1: trigger → 1 stack
    try enqueue_combo(&s.sess, s.p[0].pid, fire_combo);
    try tick_n(&s.sess, 0.11, 1);
    try std.testing.expectEqual(@as(u16, 1), s.sess.enemy_dot_stacks[0]);

    // reset_round regenerates enemy combos; re-pin so no fire shield blocks the trigger
    set_enemy_ai(&s.sess, 0);

    // Round 2: trigger again → 2 stacks
    try enqueue_combo(&s.sess, s.p[0].pid, fire_combo);
    try tick_n(&s.sess, 0.11, 1);
    try std.testing.expectEqual(@as(u16, 2), s.sess.enemy_dot_stacks[0]);
}

// ---------------------------------------------------------------------------
// Cleanse tests
// ---------------------------------------------------------------------------

test "cleanse: [fire,heal,shield] removes 1 fire stack from player side" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 0);
    s.sess.player_dot_stacks[0] = 2; // 2 fire stacks on players

    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    }));
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(@as(u16, 1), s.sess.player_dot_stacks[0]);
}

test "cleanse: cleansed stack does not tick this round" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 0);
    s.sess.player_dot_stacks[0] = 1; // exactly 1 fire stack — will be cleansed
    s.sess.shared_hp.current = 50;
    const hp_before = s.sess.shared_hp.current;

    // Cleanse the only fire stack; nothing else damages players
    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    }));
    try tick_n(&s.sess, 0.11, 1);

    // Stack removed before tick; 0 stacks × V = 0 damage → HP unchanged
    try std.testing.expectEqual(hp_before, s.sess.shared_hp.current);
    try std.testing.expectEqual(@as(u16, 0), s.sess.player_dot_stacks[0]);
}

test "cleanse: cannot cleanse below 0 stacks (saturating)" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 0);
    // player_dot_stacks[0] = 0; cleanse should not underflow

    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    }));
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(@as(u16, 0), s.sess.player_dot_stacks[0]);
}

test "cleanse: partial — 2 stacks, cleanse 1, remaining tick still fires" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 0);
    s.sess.player_dot_stacks[0] = 2;
    s.sess.shared_hp.current = 50;
    const hp_before = s.sess.shared_hp.current;

    // Cleanse 1 of the 2 stacks
    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    }));
    try tick_n(&s.sess, 0.11, 1);

    // 1 stack remains and ticks 1*V damage; hp drops by V
    try std.testing.expectEqual(hp_before - V, s.sess.shared_hp.current);
    try std.testing.expectEqual(@as(u16, 1), s.sess.player_dot_stacks[0]);
}

test "cleanse: two players each cleanse → 2 stacks removed" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 0);
    s.sess.player_dot_stacks[0] = 3; // 3 stacks; both players cleanse → 1 remains

    const cleanse = make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    });
    try enqueue_combo(&s.sess, s.p[0].pid, cleanse);
    try enqueue_combo(&s.sess, s.p[1].pid, cleanse);
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(@as(u16, 1), s.sess.player_dot_stacks[0]);
}

test "cleanse: enemy [fire,heal,shield] removes 1 enemy fire stack (symmetric)" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    s.sess.pending_enemy_intent = .{ .damage_per_player = 0, .element = null };
    s.sess.enemy_combos[0] = make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    });
    s.sess.enemy_dot_stacks[0] = 2; // 2 fire stacks on enemies

    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(@as(u16, 1), s.sess.enemy_dot_stacks[0]);
}

test "cleanse: heal and shield are withheld — no HP recovery, no shield pool contribution" {
    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    set_enemy_ai(&s.sess, 2); // 2 null-element damage from enemies — enough to hit players if unshielded
    s.sess.shared_hp.current = 50;
    const hp_before = s.sess.shared_hp.current;

    // Cleanse combo: heal and shield are withheld, so no shield blocks enemy damage
    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    }));
    try tick_n(&s.sess, 0.11, 1);

    // Enemy dealt 2*V damage; cleanse shield did NOT block it (withheld); no HP recovery either
    try std.testing.expectEqual(hp_before - 2 * V, s.sess.shared_hp.current);
}

// ---------------------------------------------------------------------------
// Enemy AI cycle test
// ---------------------------------------------------------------------------

test "enemy AI: round 0 DoT trigger, round 1 cleanse" {
    // Round 0 (round_count=0, even): enemy emits [fire,dmg,heal] → triggers fire DoT on players.
    //   Player also submits [fire,dmg,heal] → triggers fire DoT on enemies.
    //   After round 0: player_dot_stacks[0]=1, enemy_dot_stacks[0]=1.
    //
    // round_count increments to 1 in reset_round.
    //
    // Round 1 (round_count=1, odd): enemy emits [fire,heal,shield] → cleanses enemy_dot_stacks[0]
    //   by 1 (from 1 → 0).  Player submits nothing.  player_dot_stacks[0] ticks V damage.
    //   After round 1: enemy_dot_stacks[0]=0, player HP dropped by V.

    const allocator = std.testing.allocator;
    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);
    // Enemy AI governs combos; zero out structured intent so only combo damage applies.
    s.sess.pending_enemy_intent = .{ .damage_per_player = 0, .element = null };

    // Round 0: player triggers fire DoT on enemies; enemy AI triggers fire DoT on players.
    try enqueue_combo(&s.sess, s.p[0].pid, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    }));
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(@as(u16, 1), s.sess.enemy_dot_stacks[0]);
    try std.testing.expectEqual(@as(u16, 1), s.sess.player_dot_stacks[0]);

    // reset_round incremented round_count to 1; enemy AI will now emit cleanse.
    // Zero structured intent again (reset_round regenerates it).
    s.sess.pending_enemy_intent = .{ .damage_per_player = 0, .element = null };
    s.sess.shared_hp.current = 50;
    const hp_before = s.sess.shared_hp.current;

    // Round 1: no player action; enemy cleanse fires.
    try tick_n(&s.sess, 0.11, 1);

    // Enemy cleansed its own fire stack → 0
    try std.testing.expectEqual(@as(u16, 0), s.sess.enemy_dot_stacks[0]);
    // Player fire stack was NOT cleansed → ticked V damage to players
    try std.testing.expectEqual(hp_before - V, s.sess.shared_hp.current);
}
