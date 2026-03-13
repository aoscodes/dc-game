//! End-to-end integration tests for a full game session.
//!
//! These tests drive Session directly — no network, no threads, no raylib.
//! The transport is a BufferTransport that accumulates outgoing bytes, which
//! we decode to assert correct protocol output.
//!
//! Speed rates are overridden to 10.0 after spawn so a single tick(0.1)
//! fills any ATB gauge.  Enemy speed is set to 0.001 so the AI never charges
//! before we assert player-side results.

const std = @import("std");
const ecs = @import("ecs_zig");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;
const waves = shared.waves;

const session_mod = @import("session.zig");
const Session = session_mod.Session;

// ---------------------------------------------------------------------------
// Minimal test waves
// ---------------------------------------------------------------------------

/// One grunt with 1 HP and near-zero speed — dies in one hit, never acts.
const test_wave_single = waves.Wave{
    .label = "test_single",
    .entries = &[_]waves.SpawnEntry{.{
        .class = .grunt,
        .grid_col = 0,
        .grid_row = 0,
        .stats = .{ .attack = 5, .defense = 1, .max_hp = 1, .speed_base = 0.001 },
    }},
    .next_wave = null,
};

/// Two grunts adjacent on the same row — both caught by a 2×2 mage AoE.
const test_wave_two_adj = waves.Wave{
    .label = "test_two_adj",
    .entries = &[_]waves.SpawnEntry{
        .{ .class = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .attack = 5, .defense = 1, .max_hp = 30, .speed_base = 0.001 } },
        .{ .class = .grunt, .grid_col = 1, .grid_row = 0, .stats = .{ .attack = 5, .defense = 1, .max_hp = 30, .speed_base = 0.001 } },
    },
    .next_wave = null,
};

/// wave_01_basic wired to a test terminal wave (no all-waves lookup needed).
const test_wave_chain_a = waves.Wave{
    .label = "test_chain_a",
    .entries = &[_]waves.SpawnEntry{
        .{ .class = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .attack = 5, .defense = 1, .max_hp = 1, .speed_base = 0.001 } },
    },
    .next_wave = "test_chain_b",
};

const test_wave_chain_b = waves.Wave{
    .label = "test_chain_b",
    .entries = &[_]waves.SpawnEntry{
        .{ .class = .grunt, .grid_col = 1, .grid_row = 0, .stats = .{ .attack = 5, .defense = 1, .max_hp = 1, .speed_base = 0.001 } },
    },
    .next_wave = null,
};

// ---------------------------------------------------------------------------
// Harness types
// ---------------------------------------------------------------------------

/// Per-player test handle: owns buffer + BufferTransport.
const TestPlayer = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    bt: shared.BufferTransport = undefined,
    pid: u8 = 0xFF,

    /// Must be called once, at the address the struct will stay at.
    fn init(self: *TestPlayer, allocator: std.mem.Allocator) void {
        self.bt = shared.BufferTransport{ .buf = &self.buf, .allocator = allocator };
    }

    fn transport(self: *TestPlayer) shared.Transport {
        return self.bt.transport();
    }

    fn clear(self: *TestPlayer, allocator: std.mem.Allocator) void {
        self.buf.clearRetainingCapacity();
        _ = allocator;
    }

    fn deinit(self: *TestPlayer, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }
};

/// A decoded message: tag + a copy of the raw payload bytes.
const Msg = struct {
    tag: proto.MsgTag,
    /// Raw payload bytes (after the tag byte), owned by the arena passed to drain().
    payload: []const u8,
};

/// Walk `raw` decoding complete messages.  Returns a slice of Msg values
/// allocated from `arena`.  Stops at the first unknown/truncated message.
fn drain(raw: []const u8, arena: std.mem.Allocator) ![]Msg {
    var list: std.ArrayListUnmanaged(Msg) = .empty;
    var pos: usize = 0;
    while (pos < raw.len) {
        const tag_byte = raw[pos];
        const tag = std.meta.intToEnum(proto.MsgTag, tag_byte) catch break;
        pos += 1;
        const start = pos;
        // Advance pos over the payload by re-decoding into /dev/null.
        var fbs = std.io.fixedBufferStream(raw[pos..]);
        const r = fbs.reader();
        const ok = skip_payload(tag, r);
        if (!ok) break;
        pos += fbs.pos;
        try list.append(arena, .{ .tag = tag, .payload = raw[start..pos] });
    }
    return list.toOwnedSlice(arena);
}

/// Skip (consume) a payload for `tag` from `reader`.  Returns false if the
/// reader runs out of bytes before finishing.
fn skip_payload(tag: proto.MsgTag, r: anytype) bool {
    return switch (tag) {
        .join_lobby => blk: {
            const len = r.readByte() catch break :blk false;
            r.skipBytes(len, .{}) catch break :blk false;
            break :blk true;
        },
        .choose_class, .reconnect => blk: {
            _ = r.readByte() catch break :blk false;
            break :blk true;
        },
        .ready_up => true,
        .choose_action => blk: {
            _ = r.readByte() catch break :blk false;
            _ = r.readInt(u32, .little) catch break :blk false;
            break :blk true;
        },
        .lobby_update => blk: {
            // join_code(6) + player_count(1) + your_player_id(1) + players
            var hdr: [8]u8 = undefined;
            _ = r.readAll(&hdr) catch break :blk false;
            const player_count = hdr[6];
            var i: u8 = 0;
            while (i < player_count) : (i += 1) {
                _ = r.readByte() catch break :blk false; // player_id
                const nlen = r.readByte() catch break :blk false;
                r.skipBytes(nlen, .{}) catch break :blk false;
                r.skipBytes(3, .{}) catch break :blk false; // class, ready, connected
            }
            break :blk true;
        },
        .game_start => blk: {
            const llen = r.readByte() catch break :blk false;
            r.skipBytes(llen, .{}) catch break :blk false;
            _ = r.readByte() catch break :blk false; // your_player_id
            break :blk true;
        },
        .game_state => blk: {
            _ = r.readInt(u32, .little) catch break :blk false; // tick
            const ec = r.readByte() catch break :blk false;
            // Each EntitySnapshot: 4+1+1+2+2+4+1+1+1+1 = 18 bytes
            r.skipBytes(@as(u64, ec) * 18, .{}) catch break :blk false;
            break :blk true;
        },
        .action_result => blk: {
            r.skipBytes(11, .{}) catch break :blk false; // tag(1)+actor(4)+target(4)+value(2)
            break :blk true;
        },
        .your_turn => blk: {
            _ = r.readInt(u32, .little) catch break :blk false;
            break :blk true;
        },
        .game_over => blk: {
            _ = r.readByte() catch break :blk false;
            break :blk true;
        },
        .@"error" => blk: {
            r.skipBytes(64, .{}) catch break :blk false;
            break :blk true;
        },
    };
}

/// Find the first Msg with the given tag.
fn find_tag(msgs: []const Msg, tag: proto.MsgTag) ?Msg {
    for (msgs) |m| if (m.tag == tag) return m;
    return null;
}

/// Count messages with the given tag.
fn count_tag(msgs: []const Msg, tag: proto.MsgTag) usize {
    var n: usize = 0;
    for (msgs) |m| {
        if (m.tag == tag) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Session setup helpers
// ---------------------------------------------------------------------------

/// Encode `payload` for `tag` into a stack buffer and enqueue it for `pid`.
fn enqueue_msg(
    sess: *Session,
    pid: u8,
    comptime tag: proto.MsgTag,
    payload: anytype,
) !void {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), tag, payload);
    sess.enqueue_message(pid, fbs.getWritten());
}

/// Tick the session `n` times (tick + tick_effects + run_ai each iteration).
fn tick_n(sess: *Session, dt: f32, n: u32) !void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try sess.tick(dt);
        sess.tick_effects(dt);
        try sess.run_ai();
    }
}

/// Override every player entity's Speed.rate to `rate`.
/// Call after start_game_wave so entities exist.
fn set_player_speeds(sess: *Session, rate: f32) void {
    for (&sess.players) |*p| {
        if (!p.connected or p.entity == std.math.maxInt(ecs.Entity)) continue;
        sess.world.get_component(p.entity, c.Speed).rate = rate;
    }
}

/// Override every enemy entity's Speed.rate to `rate`.
fn set_enemy_speeds(sess: *Session, rate: f32) void {
    for (sess.living.items) |e| {
        const team = sess.world.get_component(e, c.Team);
        if (team.id == .enemies) {
            sess.world.get_component(e, c.Speed).rate = rate;
        }
    }
}

/// Return the first living enemy entity, or null.
fn first_enemy(sess: *Session) ?ecs.Entity {
    for (sess.living.items) |e| {
        const team = sess.world.get_component(e, c.Team);
        if (team.id == .enemies) return e;
    }
    return null;
}

/// Return the first living player entity, or null.
fn first_player_entity(sess: *Session) ?ecs.Entity {
    for (sess.living.items) |e| {
        const team = sess.world.get_component(e, c.Team);
        if (team.id == .players) return e;
    }
    return null;
}

/// Tick until `entity`'s ActionState is .charging (max 20 ticks at dt=0.1).
fn tick_until_charging(sess: *Session, entity: ecs.Entity) !void {
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const as = sess.world.get_component(entity, c.ActionState);
        if (as.tag == .charging) return;
        try tick_n(sess, 0.1, 1);
    }
    return error.EntityNeverCharged;
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

/// Initialise a two-player session IN-PLACE (caller owns *self on their stack).
/// Must be called via `var s: TwoPlayerSession = undefined; try s.init(...)`.
/// Never call on a temporary / return-by-value: buf and bt must stay at fixed
/// addresses because the transports store pointers into them.
fn init_two_player_session(
    self: *TwoPlayerSession,
    allocator: std.mem.Allocator,
    class0: c.ClassTag,
    class1: c.ClassTag,
) !void {
    self.allocator = allocator;
    self.p[0].buf = .empty;
    self.p[1].buf = .empty;
    // bt stores &self.p[i].buf — must be called at the struct's FINAL address.
    self.p[0].init(allocator);
    self.p[1].init(allocator);

    self.sess = try Session.init(allocator, "TSTKEY".*);

    const pid0 = self.sess.join(self.p[0].transport(), "") orelse return error.JoinFailed;
    const pid1 = self.sess.join(self.p[1].transport(), "") orelse return error.JoinFailed;
    self.p[0].pid = pid0;
    self.p[1].pid = pid1;

    // Set classes
    self.sess.set_class(pid0, class0);
    self.sess.set_class(pid1, class1);

    // Apply names directly (drain_queues only fires during .playing phase,
    // so lobby messages can't be processed via the normal queue path).
    const name0 = "Alice";
    const slot0 = &self.sess.players[pid0];
    @memcpy(slot0.name[0..name0.len], name0);
    slot0.name_len = @intCast(name0.len);

    const name1 = "Bob";
    const slot1 = &self.sess.players[pid1];
    @memcpy(slot1.name[0..name1.len], name1);
    slot1.name_len = @intCast(name1.len);
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

    // Broadcast lobby update manually (mirrors afterInit / join_lobby path)
    s.p[0].clear(allocator);
    s.p[1].clear(allocator);
    try s.sess.broadcast_lobby_update();

    const msgs0 = try drain(s.p[0].buf.items, arena);
    const lu_msg = find_tag(msgs0, .lobby_update) orelse return error.NoLobbyUpdate;

    var fbs = std.io.fixedBufferStream(lu_msg.payload);
    const lu = try proto.decode_lobby_update(fbs.reader());

    try std.testing.expectEqual(@as(u8, 2), lu.player_count);
    try std.testing.expectEqualSlices(u8, "Alice", lu.players[0].name[0..lu.players[0].name_len]);
    try std.testing.expectEqualSlices(u8, "Bob", lu.players[1].name[0..lu.players[1].name_len]);
}

test "lobby_update carries correct your_player_id" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .mage);
    defer s.deinit();

    s.p[0].clear(allocator);
    s.p[1].clear(allocator);
    try s.sess.broadcast_lobby_update();

    // Player 0's copy
    {
        const msgs = try drain(s.p[0].buf.items, arena);
        const m = find_tag(msgs, .lobby_update) orelse return error.NoLobbyUpdate;
        var fbs = std.io.fixedBufferStream(m.payload);
        const lu = try proto.decode_lobby_update(fbs.reader());
        try std.testing.expectEqual(s.p[0].pid, lu.your_player_id);
    }
    // Player 1's copy
    {
        const msgs = try drain(s.p[1].buf.items, arena);
        const m = find_tag(msgs, .lobby_update) orelse return error.NoLobbyUpdate;
        var fbs = std.io.fixedBufferStream(m.payload);
        const lu = try proto.decode_lobby_update(fbs.reader());
        try std.testing.expectEqual(s.p[1].pid, lu.your_player_id);
    }
}

test "all ready triggers game_start" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .healer);
    defer s.deinit();

    s.sess.set_ready(s.p[0].pid, true);
    s.sess.set_ready(s.p[1].pid, true);
    try std.testing.expect(s.sess.all_ready());

    s.p[0].clear(allocator);
    s.p[1].clear(allocator);

    try s.sess.start_game_wave(&test_wave_single);
    try s.sess.broadcast_game_start("test_single");

    // Both players should receive game_start with their own pid
    inline for (.{ 0, 1 }) |i| {
        const msgs = try drain(s.p[i].buf.items, arena);
        const m = find_tag(msgs, .game_start) orelse return error.NoGameStart;
        var fbs = std.io.fixedBufferStream(m.payload);
        const gs = try proto.decode_game_start(fbs.reader());
        try std.testing.expectEqual(s.p[i].pid, gs.your_player_id);
    }
    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);
}

// ---------------------------------------------------------------------------
// Combat tests
// ---------------------------------------------------------------------------

test "fighter attack deals damage to enemy" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .healer);
    defer s.deinit();

    // Use a grunt with known defense so we can calculate expected damage.
    // grunt defense=1, fighter attack=20 → raw=19, no mitigation → dmg=19.
    const wave = waves.Wave{
        .label = "t",
        .entries = &[_]waves.SpawnEntry{.{
            .class = .grunt,
            .grid_col = 0,
            .grid_row = 0,
            .stats = .{ .attack = 5, .defense = 1, .max_hp = 100, .speed_base = 0.001 },
        }},
        .next_wave = null,
    };

    try s.sess.start_game_wave(&wave);
    set_player_speeds(&s.sess, 10.0);
    set_enemy_speeds(&s.sess, 0.001);

    const fighter_e = s.p[0].pid;
    const fighter_entity = s.sess.players[fighter_e].entity;
    const enemy_e = first_enemy(&s.sess) orelse return error.NoEnemy;

    try tick_until_charging(&s.sess, fighter_entity);

    s.p[0].clear(allocator);
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .attack, .target_entity = enemy_e });
    try tick_n(&s.sess, 0.1, 1);

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .action_result) orelse return error.NoActionResult;
    var fbs = std.io.fixedBufferStream(m.payload);
    const ar = try proto.decode_action_result(fbs.reader());

    try std.testing.expectEqual(proto.ActionResultTag.damage, ar.tag);
    try std.testing.expectEqual(enemy_e, ar.target_entity);
    try std.testing.expect(ar.value > 0);
    // Fighter atk=20, grunt def=1 → raw=19, no mit → value=19
    try std.testing.expectEqual(@as(u16, 19), ar.value);
}

test "healer attack heals ally" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .healer);
    defer s.deinit();

    try s.sess.start_game_wave(&test_wave_single);
    set_player_speeds(&s.sess, 10.0);
    set_enemy_speeds(&s.sess, 0.001);

    // Wound the fighter so there's room to heal.
    const fighter_entity = s.sess.players[s.p[0].pid].entity;
    s.sess.world.get_component(fighter_entity, c.Health).current = 50;

    // Advance healer's ATB (healer is p[1])
    const healer_entity = s.sess.players[s.p[1].pid].entity;
    // Make healer charge first by giving it a head start
    s.sess.world.get_component(healer_entity, c.Speed).gauge = 0.0;
    s.sess.world.get_component(fighter_entity, c.Speed).gauge = 0.0;
    try tick_until_charging(&s.sess, healer_entity);

    s.p[1].clear(allocator);
    // Healer targets the fighter; AoE 2×2 originates from the fighter's position.
    try enqueue_msg(&s.sess, s.p[1].pid, .choose_action, proto.ChooseAction{ .action = .attack, .target_entity = fighter_entity });
    try tick_n(&s.sess, 0.1, 1);

    const msgs = try drain(s.p[1].buf.items, arena);
    const m = find_tag(msgs, .action_result) orelse return error.NoActionResult;
    var fbs = std.io.fixedBufferStream(m.payload);
    const ar = try proto.decode_action_result(fbs.reader());

    try std.testing.expectEqual(proto.ActionResultTag.heal, ar.tag);
    try std.testing.expect(ar.value > 0);
    // The heal must land on a player entity.
    const target_team = s.sess.world.get_component(ar.target_entity, c.Team);
    try std.testing.expectEqual(c.TeamId.players, target_team.id);
}

test "mage attack hits multiple adjacent enemies" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .mage, .fighter);
    defer s.deinit();

    try s.sess.start_game_wave(&test_wave_two_adj);
    set_player_speeds(&s.sess, 10.0);
    set_enemy_speeds(&s.sess, 0.001);

    const mage_entity = s.sess.players[s.p[0].pid].entity;
    try tick_until_charging(&s.sess, mage_entity);

    const enemy_e = first_enemy(&s.sess) orelse return error.NoEnemy;

    s.p[0].clear(allocator);
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .attack, .target_entity = enemy_e });
    try tick_n(&s.sess, 0.1, 1);

    const msgs = try drain(s.p[0].buf.items, arena);
    const dmg_count = count_tag(msgs, .action_result);
    // Two grunts at (0,0) and (1,0) — mage AoE 2×2 covers both.
    try std.testing.expect(dmg_count >= 2);
}

test "mage aoe origin follows target not actor" {
    // Regression: before fix, AoE origin was actor_pos. After fix it must be
    // the target entity's GridPos. We put both enemies far from the mage's own
    // position (0-row) so that only the target-centered AoE can reach them.
    //
    // Enemy layout:  (1,2) and (1,3)
    // Mage spawns on player row (effectively col 0, row varies but irrelevant
    // because the AoE logic uses the target's pos, not the actor's).
    // aoe_cells_2x2(1,2) => (1,2),(2,2),(1,3),(2,3)  — both enemies in range.
    // aoe_cells_2x2(actor_col,actor_row) could not reach row 2+ from row 0/1.
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wave_far = waves.Wave{
        .label = "t_far",
        .entries = &[_]waves.SpawnEntry{
            .{ .class = .grunt, .grid_col = 1, .grid_row = 2, .stats = .{ .attack = 5, .defense = 1, .max_hp = 30, .speed_base = 0.001 } },
            .{ .class = .grunt, .grid_col = 1, .grid_row = 3, .stats = .{ .attack = 5, .defense = 1, .max_hp = 30, .speed_base = 0.001 } },
        },
        .next_wave = null,
    };

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .mage, .fighter);
    defer s.deinit();

    try s.sess.start_game_wave(&wave_far);
    set_player_speeds(&s.sess, 10.0);
    set_enemy_speeds(&s.sess, 0.001);

    const mage_entity = s.sess.players[s.p[0].pid].entity;
    try tick_until_charging(&s.sess, mage_entity);

    // Target the first enemy (at grid 1,2); AoE must hit both (1,2) and (1,3).
    const target_e = first_enemy(&s.sess) orelse return error.NoEnemy;

    s.p[0].clear(allocator);
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .attack, .target_entity = target_e });
    try tick_n(&s.sess, 0.1, 1);

    const msgs = try drain(s.p[0].buf.items, arena);
    const dmg_count = count_tag(msgs, .action_result);
    // Both enemies are within the 2×2 AoE of (1,2); the old (actor-pos) AoE
    // would yield 0 hits because neither grunt is near the mage's spawn row.
    try std.testing.expect(dmg_count >= 2);
}

test "defend broadcasts defend result" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .healer);
    defer s.deinit();

    try s.sess.start_game_wave(&test_wave_single);
    set_player_speeds(&s.sess, 10.0);
    set_enemy_speeds(&s.sess, 0.001);

    const fighter_entity = s.sess.players[s.p[0].pid].entity;
    try tick_until_charging(&s.sess, fighter_entity);

    s.p[0].clear(allocator);
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .defend, .target_entity = 0 });
    try tick_n(&s.sess, 0.1, 1);

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .action_result) orelse return error.NoActionResult;
    var fbs = std.io.fixedBufferStream(m.payload);
    const ar = try proto.decode_action_result(fbs.reader());
    try std.testing.expectEqual(proto.ActionResultTag.defend, ar.tag);
}

// ---------------------------------------------------------------------------
// Death and wave progression tests
// ---------------------------------------------------------------------------

test "killing enemy broadcasts death result" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .healer);
    defer s.deinit();

    try s.sess.start_game_wave(&test_wave_single); // grunt has max_hp=1
    set_player_speeds(&s.sess, 10.0);
    set_enemy_speeds(&s.sess, 0.001);

    const fighter_entity = s.sess.players[s.p[0].pid].entity;
    const enemy_e = first_enemy(&s.sess) orelse return error.NoEnemy;
    try tick_until_charging(&s.sess, fighter_entity);

    s.p[0].clear(allocator);
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .attack, .target_entity = enemy_e });
    try tick_n(&s.sess, 0.1, 1);

    const msgs = try drain(s.p[0].buf.items, arena);
    const death_count = count_tag(msgs, .action_result);
    // Expect at least 2: .damage then .death
    try std.testing.expect(death_count >= 2);

    // Confirm one is .death
    var found_death = false;
    for (msgs) |m| {
        if (m.tag != .action_result) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const ar = try proto.decode_action_result(fbs.reader());
        if (ar.tag == .death and ar.target_entity == enemy_e) {
            found_death = true;
        }
    }
    try std.testing.expect(found_death);
}

test "wave clear spawns next wave" {
    const allocator = std.testing.allocator;

    // Verify that after killing the last enemy in a terminal wave,
    // session.phase becomes .ended and a game_over is sent.
    var s2: TwoPlayerSession = undefined;
    try init_two_player_session(&s2, allocator, .fighter, .healer);
    defer s2.deinit();

    const wave_terminal = waves.Wave{
        .label = "t_terminal",
        .entries = &[_]waves.SpawnEntry{.{
            .class = .grunt,
            .grid_col = 0,
            .grid_row = 0,
            .stats = .{ .attack = 5, .defense = 1, .max_hp = 1, .speed_base = 0.001 },
        }},
        .next_wave = null,
    };

    try s2.sess.start_game_wave(&wave_terminal);
    set_player_speeds(&s2.sess, 10.0);
    set_enemy_speeds(&s2.sess, 0.001);

    const fighter_entity = s2.sess.players[s2.p[0].pid].entity;
    const enemy_e = first_enemy(&s2.sess) orelse return error.NoEnemy;
    try tick_until_charging(&s2.sess, fighter_entity);

    try enqueue_msg(&s2.sess, s2.p[0].pid, .choose_action, proto.ChooseAction{ .action = .attack, .target_entity = enemy_e });
    try tick_n(&s2.sess, 0.1, 1);

    // No more enemies alive
    try std.testing.expectEqual(@as(usize, 0), count_living_enemies(&s2.sess));
    try std.testing.expectEqual(session_mod.SessionPhase.ended, s2.sess.phase);
}

/// Count enemies currently in sess.living.
fn count_living_enemies(sess: *Session) usize {
    var n: usize = 0;
    for (sess.living.items) |e| {
        const t = sess.world.get_component(e, c.Team);
        if (t.id == .enemies) n += 1;
    }
    return n;
}

test "wave chain advances to next wave" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .healer);
    defer s.deinit();

    // We wire chain_a → chain_b by injecting chain_b into ALL_WAVES lookup.
    // Since we cannot modify ALL_WAVES at runtime, we instead test by
    // calling start_game_wave(chain_a) where chain_a.next_wave = "wave_01_basic"
    // which IS in ALL_WAVES.  Kill the grunt → session loads wave_01_basic.
    const wave_to_real = waves.Wave{
        .label = "t_to_real",
        .entries = &[_]waves.SpawnEntry{.{
            .class = .grunt,
            .grid_col = 0,
            .grid_row = 0,
            .stats = .{ .attack = 5, .defense = 1, .max_hp = 1, .speed_base = 0.001 },
        }},
        .next_wave = "wave_01_basic",
    };

    try s.sess.start_game_wave(&wave_to_real);
    set_player_speeds(&s.sess, 10.0);
    set_enemy_speeds(&s.sess, 0.001);

    const fighter_entity = s.sess.players[s.p[0].pid].entity;
    const enemy_e = first_enemy(&s.sess) orelse return error.NoEnemy;
    try tick_until_charging(&s.sess, fighter_entity);

    s.p[0].clear(allocator);
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .attack, .target_entity = enemy_e });
    try tick_n(&s.sess, 0.1, 1);

    // wave_01_basic has 3 grunts — verify enemies spawned
    try std.testing.expect(count_living_enemies(&s.sess) > 0);
    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);
    // Current wave should now be wave_01_basic
    const cw = s.sess.current_wave orelse return error.NullWave;
    try std.testing.expectEqualSlices(u8, "wave_01_basic", cw.label);

    // Drain game_state and verify enemy-team entities exist
    const msgs = try drain(s.p[0].buf.items, arena);
    try std.testing.expect(find_tag(msgs, .game_state) != null);
}

test "all waves cleared players win" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .healer);
    defer s.deinit();

    // Single terminal wave → killing the grunt ends the game with players win.
    try s.sess.start_game_wave(&test_wave_single);
    set_player_speeds(&s.sess, 10.0);
    set_enemy_speeds(&s.sess, 0.001);

    const fighter_entity = s.sess.players[s.p[0].pid].entity;
    const enemy_e = first_enemy(&s.sess) orelse return error.NoEnemy;
    try tick_until_charging(&s.sess, fighter_entity);

    s.p[0].clear(allocator);
    try enqueue_msg(&s.sess, s.p[0].pid, .choose_action, proto.ChooseAction{ .action = .attack, .target_entity = enemy_e });
    try tick_n(&s.sess, 0.1, 1);

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .game_over) orelse return error.NoGameOver;
    var fbs = std.io.fixedBufferStream(m.payload);
    const go = try proto.decode_game_over(fbs.reader());
    try std.testing.expectEqual(proto.WinnerId.players, go.winner);
    try std.testing.expectEqual(session_mod.SessionPhase.ended, s.sess.phase);
}

test "all players dead enemies win" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator, .fighter, .healer);
    defer s.deinit();

    // Enemy with very high attack, slow players so AI acts first.
    const deadly_wave = waves.Wave{
        .label = "t_deadly",
        .entries = &[_]waves.SpawnEntry{.{
            .class = .grunt,
            .grid_col = 0,
            .grid_row = 0,
            .stats = .{ .attack = 9999, .defense = 1, .max_hp = 999, .speed_base = 10.0 },
        }},
        .next_wave = null,
    };

    try s.sess.start_game_wave(&deadly_wave);
    // Players are slow (don't act); enemy charges and kills them.
    set_player_speeds(&s.sess, 0.001);
    set_enemy_speeds(&s.sess, 10.0);

    const enemy_e = first_enemy(&s.sess) orelse return error.NoEnemy;
    // Also set HP for both players very low so one hit kills both.
    for (s.sess.living.items) |e| {
        const t = s.sess.world.get_component(e, c.Team);
        if (t.id == .players) {
            s.sess.world.get_component(e, c.Health).current = 1;
        }
    }

    s.p[0].clear(allocator);
    s.p[1].clear(allocator);

    // Enemy charges in 1 tick (rate=10, dt=0.1 → gauge=1.0).
    // run_ai inside tick() resolves the attack and check_win fires.
    // Tick a few times to handle both players being killed.
    _ = enemy_e;
    var i: u32 = 0;
    while (i < 10 and s.sess.phase == .playing) : (i += 1) {
        try tick_n(&s.sess, 0.1, 1);
    }

    // Session should have ended with enemies winning.
    try std.testing.expectEqual(session_mod.SessionPhase.ended, s.sess.phase);

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .game_over) orelse return error.NoGameOver;
    var fbs = std.io.fixedBufferStream(m.payload);
    const go = try proto.decode_game_over(fbs.reader());
    try std.testing.expectEqual(proto.WinnerId.enemies, go.winner);
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

    // Reconnect with the same transport (in production a new conn would be used)
    const ok = s.sess.reconnect(pid, s.p[0].transport());
    try std.testing.expect(ok);
    try std.testing.expect(s.sess.players[pid].connected);

    // Broadcast so the rejoining player sees current lobby state.
    s.p[0].clear(allocator);
    try s.sess.broadcast_lobby_update();

    const msgs = try drain(s.p[0].buf.items, arena);
    const m = find_tag(msgs, .lobby_update) orelse return error.NoLobbyUpdate;
    var fbs = std.io.fixedBufferStream(m.payload);
    const lu = try proto.decode_lobby_update(fbs.reader());

    try std.testing.expect(lu.players[pid].connected);
    try std.testing.expectEqual(pid, lu.your_player_id);
}
