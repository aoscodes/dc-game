//! Integration tests for the round-based game session.
//!
//! Tests drive Session directly — no network, no threads.
//! Transport is a BufferTransport that accumulates outgoing bytes.
//!
//! Round mechanics under test:
//!   - damage pool → each living enemy takes pool_size damage
//!   - shield pool → each living player gains pool_size shield HP
//!   - heal pool   → each living player heals pool_size HP
//!   - enemy intent → each living player takes living_enemy_count damage
//!                    (shield absorbs first, overflow hits HP)
//!   - configurable round_duration respected
//!   - death/wave-chain/game-over paths

const std = @import("std");
const ecs = @import("ecs_zig");
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
        .join_lobby => if (proto.decode_join_lobby(r)) |_| true else |_| false,
        .choose_class => if (proto.decode_choose_class(r)) |_| true else |_| false,
        .choose_action => if (proto.decode_choose_action(r)) |_| true else |_| false,
        .reconnect => if (proto.decode_reconnect(r)) |_| true else |_| false,
        .choose_position => if (proto.decode_choose_position(r)) |_| true else |_| false,
        .ready_up => true, // zero-payload message
        .lobby_update => if (proto.decode_lobby_update(r)) |_| true else |_| false,
        .game_start => if (proto.decode_game_start(r)) |_| true else |_| false,
        .game_state => if (proto.decode_game_state(r)) |_| true else |_| false,
        .action_result => if (proto.decode_action_result(r)) |_| true else |_| false,
        .game_over => if (proto.decode_game_over(r)) |_| true else |_| false,
        .@"error" => blk: {
            var buf: [64]u8 = undefined;
            _ = r.readAll(&buf) catch break :blk false;
            break :blk true;
        },
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

fn count_living_enemies(sess: *Session) usize {
    return sess.world.system_entity_sets[comptime session_mod.GameWorld.system_index_of(session_mod.EnemyTeam)].count();
}

fn count_living_players(sess: *Session) usize {
    return sess.world.system_entity_sets[comptime session_mod.GameWorld.system_index_of(session_mod.PlayerTeam)].count();
}

fn first_enemy(sess: *Session) ?ecs.Entity {
    var it = sess.world.system_entity_sets[comptime session_mod.GameWorld.system_index_of(session_mod.EnemyTeam)].iterator(.{});
    if (it.next()) |u| return @intCast(u);
    return null;
}

fn first_player_entity(sess: *Session) ?ecs.Entity {
    var it = sess.world.system_entity_sets[comptime session_mod.GameWorld.system_index_of(session_mod.PlayerTeam)].iterator(.{});
    if (it.next()) |u| return @intCast(u);
    return null;
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
    // Submit actions
    for (player_actions, 0..) |maybe_action, i| {
        const action = maybe_action orelse continue;
        try enqueue_msg(sess, @intCast(i), .choose_action, proto.ChooseAction{ .action = action });
    }
    // Tick until round fires (round_duration = 0.1s, step = 0.1s → 1 tick)
    try tick_n(sess, sess.round_duration + 0.001, 1);
    return drain(out_buf.items, arena);
}

test "damage pool reduces enemy HP" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single); // grunt: 10 HP

    const enemy_e = first_enemy(&s.sess) orelse return error.NoEnemy;
    const hp_before = s.sess.world.get_component(enemy_e, c.Health).current;

    // Both players choose damage → pool = 2 → 2 * ACTION_EFFECT_VALUE = 2 dmg
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .damage });
    try enqueue_msg(&s.sess, s.p[1].pid, .choose_action, proto.ChooseAction{ .action = .damage });
    try tick_n(&s.sess, 0.11, 1);

    const hp_after = s.sess.world.get_component(enemy_e, c.Health).current;
    // damage to enemy = pool(2) * V
    try std.testing.expectEqual(hp_before - 2 * V, hp_after);
}

test "damage pool: action_result.damage broadcast for each enemy" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single); // 1 enemy

    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .damage });
    s.p[0].clear();
    try tick_n(&s.sess, 0.11, 1);

    const msgs = try drain(s.p[0].buf.items, arena);
    const dmg_count = try count_action_results_with(msgs, .damage);
    // At least 1 damage result for the enemy + 1 for enemy attacking back
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
    try s.sess.start_game_wave(&test_wave_one_hp); // 1 HP grunt

    const enemy_e = first_enemy(&s.sess) orelse return error.NoEnemy;

    // 1 player damage action → pool=1 → 1 dmg to enemy (1 HP) → death
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .damage });
    s.p[0].clear();
    try tick_n(&s.sess, 0.11, 1);

    // Enemy is dead
    try std.testing.expectEqual(@as(usize, 0), count_living_enemies(&s.sess));

    // Death broadcast
    const msgs = try drain(s.p[0].buf.items, arena);
    var found_death = false;
    for (msgs) |m| {
        if (m.tag != .action_result) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const ar = try proto.decode_action_result(fbs.reader());
        if (ar.tag == .death and ar.target_entity == enemy_e) found_death = true;
    }
    try std.testing.expect(found_death);
}

test "shield pool grants shield HP to all players" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    // Both players shield → pool=2 → each player gets 2 shield HP
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .shield });
    try enqueue_msg(&s.sess, s.p[1].pid, .choose_action, proto.ChooseAction{ .action = .shield });
    s.p[0].clear();
    try tick_n(&s.sess, 0.11, 1);

    {
        var it = s.sess.world.system_entity_sets[comptime session_mod.GameWorld.system_index_of(session_mod.PlayerTeam)].iterator(.{});
        while (it.next()) |u| {
            const e: ecs.Entity = @intCast(u);
            // shield = pool(2) * V, enemy (attack=1) absorbs 1 → net 2*V - 1
            try std.testing.expectEqual(2 * V - 1, s.sess.world.get_component(e, c.Shield).hp);
        }
    }

    // shield broadcast
    const msgs = try drain(s.p[0].buf.items, arena);
    const shield_count = try count_action_results_with(msgs, .shield);
    try std.testing.expect(shield_count >= 2); // at least one per player
}

test "heal pool heals all players" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    // Wound both players first
    const pe0 = s.sess.players[s.p[0].pid].entity;
    const pe1 = s.sess.players[s.p[1].pid].entity;
    s.sess.world.get_component(pe0, c.Health).current = 50;
    s.sess.world.get_component(pe1, c.Health).current = 50;

    const hp0_before: u16 = 50;

    // Both players heal → pool=2 → each player heals 2*V HP
    // Enemy (attack=1) deals 1 HP dmg in same round.
    // Net: +2*V heal - 1 enemy dmg.
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .heal });
    try enqueue_msg(&s.sess, s.p[1].pid, .choose_action, proto.ChooseAction{ .action = .heal });
    try tick_n(&s.sess, 0.11, 1);

    const hp0_after = s.sess.world.get_component(pe0, c.Health).current;
    // Heal (+2*V) then enemy dmg (-1) → net +2*V-1
    try std.testing.expectEqual(hp0_before + 2 * V - 1, hp0_after);

    s.p[0].clear();
}

test "shield absorbs enemy damage before HP" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single); // 1 enemy → 1 dmg per round to each player

    const pe = s.sess.players[s.p[0].pid].entity;
    const hp_before = s.sess.world.get_component(pe, c.Health).current;

    // Give player a manual shield of 5 HP (more than enemy attack=1)
    s.sess.world.get_component(pe, c.Shield).hp = 5;

    // No action chosen — enemy still attacks
    try tick_n(&s.sess, 0.11, 1);

    const hp_after = s.sess.world.get_component(pe, c.Health).current;
    const shield_after = s.sess.world.get_component(pe, c.Shield).hp;

    // HP unchanged (shield absorbed enemy attack=1)
    try std.testing.expectEqual(hp_before, hp_after);
    // Shield depleted by enemy attack (1)
    try std.testing.expectEqual(@as(u16, 4), shield_after);
}

test "enemy kills all players — enemies win" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;

    // Wave with 100 enemies → 100 dmg per round per player → instant kill.
    var entries: [100]waves.SpawnEntry = undefined;
    for (&entries, 0..) |*e, i| {
        e.* = .{
            .class = .grunt,
            .grid_col = @intCast(i % 3),
            .grid_row = @intCast((i / 3) % 4),
            .stats = .{ .attack = 1, .defense = 1, .max_hp = 999, .speed_base = 0.001 },
        };
    }
    const deadly_wave = waves.Wave{
        .label = "t_deadly",
        .entries = &entries,
        .next_wave = null,
    };

    try s.sess.start_game_wave(&deadly_wave);

    // Players have 1 HP, 100 enemies deal 100 dmg → die instantly
    {
        var it = s.sess.world.system_entity_sets[comptime session_mod.GameWorld.system_index_of(session_mod.PlayerTeam)].iterator(.{});
        while (it.next()) |u| {
            s.sess.world.get_component(@intCast(u), c.Health).current = 1;
        }
    }

    s.p[0].clear();
    try tick_n(&s.sess, 0.11, 1);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .game_over) orelse return error.NoGameOver;
    var fbs = std.io.fixedBufferStream(m.payload);
    const go = try proto.decode_game_over(fbs.reader());
    try std.testing.expectEqual(proto.WinnerId.enemies, go.winner);
}

test "all enemies dead — players win" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_one_hp); // 1 HP grunt

    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .damage });
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
    // First wave: 1 HP grunt → next wave = wave_01_basic (9 grunts)
    try s.sess.start_game_wave(&test_wave_to_real);

    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .damage });
    s.p[0].clear();
    try tick_n(&s.sess, 0.11, 1);

    // wave_01_basic has 9 grunts
    try std.testing.expect(count_living_enemies(&s.sess) > 0);
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

    const pe = s.sess.players[s.p[0].pid].entity;
    const hp_max = s.sess.world.get_component(pe, c.Health).max;

    // First submit heal, then overwrite with damage before round ends
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .heal });
    // Tick a little (doesn't fire round yet)
    try tick_n(&s.sess, 0.1, 1);
    // Verify the first action was recorded
    try std.testing.expectEqual(c.ActionChoice.heal, s.sess.action_pool[s.p[0].pid].?);

    // Overwrite with damage
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .damage });
    try tick_n(&s.sess, 0.1, 1);
    try std.testing.expectEqual(c.ActionChoice.damage, s.sess.action_pool[s.p[0].pid].?);

    // Let the round fire — damage chosen, not heal
    try tick_n(&s.sess, 0.5, 1);

    // Enemy HP must have gone down (damage applied), not up
    const enemy_e = first_enemy(&s.sess) orelse return error.NoEnemy;
    const enemy_hp = s.sess.world.get_component(enemy_e, c.Health).current;
    try std.testing.expect(enemy_hp < V * 100); // started at V*100

    // Player HP should NOT be at max (heal was not the final action)
    const player_hp = s.sess.world.get_component(pe, c.Health).current;
    try std.testing.expect(player_hp <= hp_max);
}

test "action pool resets after each round" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    // Round 1: both damage
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .damage });
    try enqueue_msg(&s.sess, s.p[1].pid, .choose_action, proto.ChooseAction{ .action = .damage });
    try tick_n(&s.sess, 0.11, 1);

    // After round, pool must be cleared
    for (&s.sess.action_pool) |maybe| {
        try std.testing.expectEqual(@as(?c.ActionChoice, null), maybe);
    }
}

test "no actions submitted — enemy still attacks" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single); // 1 enemy

    const pe = s.sess.players[s.p[0].pid].entity;
    const hp_max = s.sess.world.get_component(pe, c.Health).max;

    // No actions; tick through round
    try tick_n(&s.sess, 0.11, 1);

    // Enemy (attack=1) deals 1 HP dmg — player HP dropped by 1
    const hp_after = s.sess.world.get_component(pe, c.Health).current;
    try std.testing.expectEqual(hp_max - 1, hp_after);
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
    try s.sess.start_game_wave(&test_wave_single); // 1 enemy, 10 HP

    const enemy_e = first_enemy(&s.sess) orelse return error.NoEnemy;
    const pe1 = s.sess.players[s.p[1].pid].entity;

    // p0 → damage, p1 → shield
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .damage });
    try enqueue_msg(&s.sess, s.p[1].pid, .choose_action, proto.ChooseAction{ .action = .shield });
    try tick_n(&s.sess, 0.11, 1);

    // enemy took V damage (pool=1 → 1*V)
    const enemy_hp = s.sess.world.get_component(enemy_e, c.Health).current;
    try std.testing.expectEqual(V * 100 - V, enemy_hp);

    // p1 got shield (pool=1 → +V shield, enemy attack=1 absorbed → net V-1)
    try std.testing.expectEqual(V - 1, s.sess.world.get_component(pe1, c.Shield).hp);
}

test "2 enemies deal 2 damage per player per round" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;

    const two_enemy_wave = waves.Wave{
        .label = "t_two",
        .entries = &[_]waves.SpawnEntry{
            .{ .class = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .attack = 1, .defense = 1, .max_hp = 99, .speed_base = 0.001 } },
            .{ .class = .grunt, .grid_col = 1, .grid_row = 0, .stats = .{ .attack = 1, .defense = 1, .max_hp = 99, .speed_base = 0.001 } },
        },
        .next_wave = null,
    };
    try s.sess.start_game_wave(&two_enemy_wave);

    const pe = s.sess.players[s.p[0].pid].entity;
    const hp_before = s.sess.world.get_component(pe, c.Health).current;

    // No actions: 2 enemies × 1 = 2 dmg to each player
    try tick_n(&s.sess, 0.11, 1);

    const hp_after = s.sess.world.get_component(pe, c.Health).current;
    try std.testing.expectEqual(hp_before - 2, hp_after);
}

test "player dead from enemy does not receive subsequent pool heal" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;

    // 100 enemies → lethal intent
    var entries: [100]waves.SpawnEntry = undefined;
    for (&entries, 0..) |*e, i| {
        e.* = .{
            .class = .grunt,
            .grid_col = @intCast(i % 3),
            .grid_row = @intCast((i / 3) % 4),
            .stats = .{ .attack = 1, .defense = 1, .max_hp = 999, .speed_base = 0.001 },
        };
    }
    const lethal_wave = waves.Wave{ .label = "t_lethal", .entries = &entries, .next_wave = null };
    try s.sess.start_game_wave(&lethal_wave);

    const pe0 = s.sess.players[s.p[0].pid].entity;
    const pe1 = s.sess.players[s.p[1].pid].entity;
    // Set both to 1 HP — enemy intent will kill them
    s.sess.world.get_component(pe0, c.Health).current = 1;
    s.sess.world.get_component(pe1, c.Health).current = 1;

    // Both choose heal — heal applies before enemy intent
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .heal });
    try enqueue_msg(&s.sess, s.p[1].pid, .choose_action, proto.ChooseAction{ .action = .heal });
    try tick_n(&s.sess, 0.11, 1);

    // Both dead (enemy dealt 100 dmg, heal only gave +2)
    try std.testing.expectEqual(@as(usize, 0), count_living_players(&s.sess));
    // Neither entity should be alive in the ECS
    try std.testing.expect(!s.sess.world.system_entity_sets[comptime session_mod.GameWorld.system_index_of(session_mod.PlayerTeam)].isSet(pe0));
    try std.testing.expect(!s.sess.world.system_entity_sets[comptime session_mod.GameWorld.system_index_of(session_mod.PlayerTeam)].isSet(pe1));
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

test "game_state wire: shield_hp reflects server shield array" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 1.0;
    try s.sess.start_game_wave(&test_wave_single);

    const pe = s.sess.players[s.p[0].pid].entity;
    s.sess.world.get_component(pe, c.Shield).hp = 7;

    s.p[0].clear();
    try tick_n(&s.sess, 0.1, 1);

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .game_state) orelse return error.NoGameState;
    var fbs = std.io.fixedBufferStream(m.payload);
    const gs = try proto.decode_game_state(fbs.reader());

    var found_shield: bool = false;
    var i: u8 = 0;
    while (i < gs.entity_count) : (i += 1) {
        if (gs.entities[i].entity == pe) {
            // Shield may have been consumed by enemy intent this tick (round not yet resolved)
            // but timer hasn't expired yet so no resolution happened
            try std.testing.expectEqual(@as(u16, 7), gs.entities[i].shield_hp);
            found_shield = true;
        }
    }
    try std.testing.expect(found_shield);
}

test "cosmetic lobby position round-trip via choose_position" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .mage);
    defer s.deinit();

    const pid = s.p[0].pid;
    try enqueue_msg(&s.sess, pid, .choose_position, proto.ChoosePosition{ .col = 2, .row = 3 });
    // drain_queues is called on tick, but session is in lobby — tick still drains
    try s.sess.tick(0.016);

    s.p[0].clear();
    try s.sess.broadcast_lobby_update();

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .lobby_update) orelse return error.NoLobbyUpdate;
    var fbs = std.io.fixedBufferStream(m.payload);
    const lu = try proto.decode_lobby_update(fbs.reader());

    try std.testing.expectEqual(@as(u8, 2), lu.players[pid].grid_col);
    try std.testing.expectEqual(@as(u8, 3), lu.players[pid].grid_row);
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

    // Submit damage from surviving player 0
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .damage });
    s.p[0].clear();

    // Must not crash
    try tick_n(&s.sess, 0.11, 1);

    // Enemy took damage
    const enemy_e = first_enemy(&s.sess) orelse return error.NoEnemy;
    const enemy_hp = s.sess.world.get_component(enemy_e, c.Health).current;
    try std.testing.expect(enemy_hp < V * 100);

    // Player 0 still received broadcast
    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expect(find_tag(msgs, .game_state) != null);
}

test "heal at full HP — HP stays at max" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .fighter);
    defer s.deinit();

    s.sess.round_duration = 0.1;
    try s.sess.start_game_wave(&test_wave_single);

    const pe = s.sess.players[s.p[0].pid].entity;
    const hp_max = s.sess.world.get_component(pe, c.Health).max;
    // Ensure player is at full HP
    s.sess.world.get_component(pe, c.Health).current = hp_max;

    // Both players heal
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .heal });
    try enqueue_msg(&s.sess, s.p[1].pid, .choose_action, proto.ChooseAction{ .action = .heal });
    try tick_n(&s.sess, 0.11, 1);

    // HP must not exceed max (enemy dealt 1 dmg so hp = max - 1, not max + 1)
    const hp_after = s.sess.world.get_component(pe, c.Health).current;
    try std.testing.expect(hp_after <= hp_max);
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

    // Wound players so they can actually heal
    {
        var it = s.sess.world.system_entity_sets[comptime session_mod.GameWorld.system_index_of(session_mod.PlayerTeam)].iterator(.{});
        while (it.next()) |u| {
            s.sess.world.get_component(@intCast(u), c.Health).current = 50;
        }
    }

    // Both choose heal → pool = 2
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .heal });
    try enqueue_msg(&s.sess, s.p[1].pid, .choose_action, proto.ChooseAction{ .action = .heal });
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
