//! Integration tests for the Slime Feast game session.
//!
//! Tests drive Session directly — no network, no threads.
//! Transport is a BufferTransport that accumulates outgoing bytes.
//!
//! Round mechanics under test:
//!   - combo intake (latest cast wins, cancel clears) → recipe/flat conversion
//!   - zone consumption: neutralization, partial/wrong-color/excess agents
//!   - hunger accounting: normal (unhealable) vs extra (healable) portions
//!   - symmetrical medicine: color-X medicine heals only color-X healable
//!     hunger; asymmetric medicine and overheal are discarded
//!   - score = neutralized + naturally-neutral units
//!   - end conditions: all zones consumed / hunger bar full
//!   - configurable round_duration respected

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;
const logic = shared.game_logic;
const balance = shared.balance;
const enc = shared.encounter;

const session_mod = @import("session.zig");
const Session = session_mod.Session;

const mk = c.make_combo;

// ---------------------------------------------------------------------------
// Minimal test encounters
// ---------------------------------------------------------------------------

/// One zone: 20 fire-modified units, no neutral.  Roomy hunger budget.
const enc_single_fire = enc.Encounter{
    .label = "test_single_fire",
    .hunger_max = 1000,
    .zones = &[_]c.ZoneDef{
        .{ .modified = .{ 20, 0, 0, 0 } },
    },
};

/// One zone: 50 fire-modified units (the 25-of-50 partial case).
const enc_fifty_fire = enc.Encounter{
    .label = "test_fifty_fire",
    .hunger_max = 1000,
    .zones = &[_]c.ZoneDef{
        .{ .modified = .{ 50, 0, 0, 0 } },
    },
};

/// Two zones with modified + neutral mix.
const enc_two_zones = enc.Encounter{
    .label = "test_two_zones",
    .hunger_max = 1000,
    .zones = &[_]c.ZoneDef{
        .{ .modified = .{ 10, 0, 0, 0 }, .neutral = 5 },
        .{ .modified = .{ 0, 8, 0, 0 }, .neutral = 2 },
    },
};

/// Tiny hunger budget: consuming zone 1 un-neutralized fills the bar
/// (10 normal + 20 extra = 30 ≥ 25) with a second zone never reached.
const enc_tight_budget = enc.Encounter{
    .label = "test_tight_budget",
    .hunger_max = 25,
    .zones = &[_]c.ZoneDef{
        .{ .modified = .{ 10, 0, 0, 0 } },
        .{ .modified = .{ 0, 0, 0, 0 }, .neutral = 40 },
    },
};

/// Neutral-only zones: hunger from these is never healable.
const enc_neutral_only = enc.Encounter{
    .label = "test_neutral_only",
    .hunger_max = 1000,
    .zones = &[_]c.ZoneDef{
        .{ .neutral = 30 },
        .{ .neutral = 10 },
    },
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
        .set_statblock => if (proto.decode_set_statblock(r)) |_| true else |_| false,
        .cancel_combo => true, // zero-payload
        .lobby_update => if (proto.decode_lobby_update(r)) |_| true else |_| false,
        .game_start => if (proto.decode_game_start(r)) |_| true else |_| false,
        .game_state => if (proto.decode_game_state(r)) |_| true else |_| false,
        .action_result => if (proto.decode_action_result(r)) |_| true else |_| false,
        .round_reset => true, // zero-payload
        .game_over => if (proto.decode_game_over(r)) |_| true else |_| false,
        .cast_committed => if (proto.decode_cast_committed(r)) |_| true else |_| false,
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

/// Drain queues without expiring the round timer.
fn flush(sess: *Session) !void {
    try sess.tick(0.0);
}

/// Tick once past the round timer so the round resolves.
fn resolve(sess: *Session) !void {
    try sess.tick(sess.round_duration + 0.001);
}

/// Sum of all per-color healable hunger buckets.
fn total_healable(sess: *const Session) u32 {
    var t: u32 = 0;
    for (sess.hunger_healable) |h| t += h;
    return t;
}

const FIRE: usize = @intFromEnum(c.Element.fire);
const EARTH: usize = @intFromEnum(c.Element.earth);

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

    const slot0 = &self.sess.players[pid0];
    @memcpy(slot0.name[0..5], "Alice");
    slot0.name_len = 5;

    const slot1 = &self.sess.players[pid1];
    @memcpy(slot1.name[0..3], "Bob");
    slot1.name_len = 3;
}

/// Two players in game against `encounter`, with a fast round timer.
fn start_playing(s: *TwoPlayerSession, encounter: *const enc.Encounter) !void {
    s.sess.round_duration = 0.05;
    s.sess.round_timer = 0.05;
    try s.sess.start_game_encounter(encounter);
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

test "ready flow starts the default encounter" {
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
        enc.DEFAULT_ENCOUNTER.label,
        gs.encounter_label[0..gs.encounter_label_len],
    );

    try std.testing.expectEqual(@as(u16, enc.DEFAULT_ENCOUNTER.hunger_max), s.sess.hunger.max);
    try std.testing.expectEqual(@as(u16, 0), s.sess.hunger.current);
    try std.testing.expectEqual(@as(u8, enc.DEFAULT_ENCOUNTER.zones.len), s.sess.zone_count);
}

// ---------------------------------------------------------------------------
// Combo intake
// ---------------------------------------------------------------------------

test "choose_combo stores latest cast; cancel clears it" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_single_fire);

    const combo_a = mk(&.{ .{ .element = .fire }, .{ .action = .dispense } });
    const combo_b = mk(&.{ .{ .element = .water }, .{ .action = .dispense }, .{ .action = .dispense } });

    try enqueue_combo(&s.sess, s.p[0].pid, combo_a);
    try flush(&s.sess);
    try std.testing.expect(logic.combos_equal(combo_a, s.sess.action_pool[s.p[0].pid].?));

    // Latest cast wins (one cast per round).
    try enqueue_combo(&s.sess, s.p[0].pid, combo_b);
    try flush(&s.sess);
    try std.testing.expect(logic.combos_equal(combo_b, s.sess.action_pool[s.p[0].pid].?));

    try enqueue_msg(&s.sess, s.p[0].pid, .cancel_combo, {});
    try flush(&s.sess);
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.action_pool[s.p[0].pid]);
}

test "action pool clears after round resolution" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_two_zones);

    try enqueue_combo(&s.sess, s.p[0].pid, mk(&.{ .{ .element = .fire }, .{ .action = .dispense } }));
    try flush(&s.sess);
    try std.testing.expect(s.sess.action_pool[s.p[0].pid] != null);

    try resolve(&s.sess);
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.action_pool[s.p[0].pid]);
}

// ---------------------------------------------------------------------------
// Zone consumption + neutralization
// ---------------------------------------------------------------------------

test "full neutralization: no extra hunger, full score" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_single_fire); // 20 fire units

    // crimson_flood recipe (20 fire agents) covers the zone exactly.
    try enqueue_combo(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .fire },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
    try resolve(&s.sess);

    try std.testing.expectEqual(@as(u32, 20), s.sess.score);
    try std.testing.expectEqual(
        @as(u16, @intCast(20 * balance.HUNGER_COST_NORMAL)),
        s.sess.hunger.current,
    );
    try std.testing.expectEqual(@as(u32, 0), total_healable(&s.sess));
}

test "partial neutralization: 25 of 50 — split hunger and score" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_fifty_fire); // 50 fire units

    // 25 fire agents: crimson_flood (20) from p0 + one flat dispense (5) from p1.
    try enqueue_combo(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .fire },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
    try enqueue_combo(&s.sess, s.p[1].pid, mk(&.{
        .{ .element = .fire },
        .{ .action = .dispense },
    }));
    try resolve(&s.sess);

    // 25 neutralized + 25 modified consumed.
    try std.testing.expectEqual(@as(u32, 25), s.sess.score);
    const expected_normal = 50 * balance.HUNGER_COST_NORMAL;
    const expected_extra = 25 * balance.HUNGER_COST_MODIFIED_EXTRA;
    try std.testing.expectEqual(
        @as(u16, @intCast(expected_normal + expected_extra)),
        s.sess.hunger.current,
    );
    try std.testing.expectEqual(@as(u16, @intCast(expected_extra)), s.sess.hunger_healable[FIRE]);
}

test "wrong-color agents have no effect on the zone" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_single_fire); // 20 fire units

    // Water agents vs fire slime: wasted.
    try enqueue_combo(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .water },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
    try resolve(&s.sess);

    try std.testing.expectEqual(@as(u32, 0), s.sess.score);
    const expected = 20 * balance.HUNGER_COST_NORMAL + 20 * balance.HUNGER_COST_MODIFIED_EXTRA;
    try std.testing.expectEqual(@as(u16, @intCast(expected)), s.sess.hunger.current);
    try std.testing.expectEqual(
        @as(u16, @intCast(20 * balance.HUNGER_COST_MODIFIED_EXTRA)),
        s.sess.hunger_healable[FIRE],
    );
}

test "excess agents are wasted (no carryover to next zone)" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_two_zones); // zone 0: 10 fire + 5 neutral

    // 20 fire agents vs 10 fire units — 10 wasted.
    try enqueue_combo(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .fire },
        .{ .action = .dispense },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
    try resolve(&s.sess);

    // Score: 10 neutralized + 5 naturally-neutral.
    try std.testing.expectEqual(@as(u32, 15), s.sess.score);
    try std.testing.expectEqual(@as(u32, 0), total_healable(&s.sess));
    try std.testing.expectEqual(@as(u8, 1), s.sess.zone_index);

    // Zone 1 (8 earth) untouched by the excess: consume with nothing.
    try resolve(&s.sess);
    try std.testing.expectEqual(@as(u32, 15 + 2), s.sess.score); // only neutral counts
    try std.testing.expectEqual(
        @as(u16, @intCast(8 * balance.HUNGER_COST_MODIFIED_EXTRA)),
        s.sess.hunger_healable[EARTH],
    );
}

test "team recipe (twin_flames) neutralizes more than two flat casts" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_fifty_fire); // 50 fire units

    // Both players cast the twin_flames half: 2 × [fire, dispense, dispense].
    // Team recipe → 30 fire agents (flat would be 2 × 10 = 20).
    const half = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } });
    try enqueue_combo(&s.sess, s.p[0].pid, half);
    try enqueue_combo(&s.sess, s.p[1].pid, half);
    try resolve(&s.sess);

    try std.testing.expectEqual(@as(u32, 30), s.sess.score);
    try std.testing.expectEqual(
        @as(u16, @intCast(20 * balance.HUNGER_COST_MODIFIED_EXTRA)),
        s.sess.hunger_healable[FIRE],
    );
}

// ---------------------------------------------------------------------------
// Cast windows (CASTS_PER_ROUND spells per round)
// ---------------------------------------------------------------------------

test "cast window commits pending combo mid-round" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    s.sess.round_duration = 3.0;
    s.sess.round_timer = 3.0;
    try s.sess.start_game_encounter(&enc_fifty_fire); // window = 1.0s

    const combo = mk(&.{ .{ .element = .fire }, .{ .action = .dispense } });
    try enqueue_combo(&s.sess, s.p[0].pid, combo);
    s.p[1].clear();

    // Window 1 closes: pending combo commits, pool clears, round continues.
    try s.sess.tick(1.05);
    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);
    try std.testing.expectEqual(@as(?c.ActionCombo, null), s.sess.action_pool[s.p[0].pid]);
    try std.testing.expectEqual(@as(u8, 1), s.sess.committed_count);
    try std.testing.expectEqual(@as(u8, 1), s.sess.casts_used[s.p[0].pid]);

    const msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .cast_committed));
}

test "three casts across windows all feed round resolution" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    s.sess.round_duration = 3.0;
    s.sess.round_timer = 3.0;
    try s.sess.start_game_encounter(&enc_fifty_fire); // 50 fire units

    const combo = mk(&.{ .{ .element = .fire }, .{ .action = .dispense } }); // 5 agents flat

    // Window 1 + 2 commit; the third combo commits at round resolution.
    try enqueue_combo(&s.sess, s.p[0].pid, combo);
    try s.sess.tick(1.05);
    try enqueue_combo(&s.sess, s.p[0].pid, combo);
    try s.sess.tick(1.0);
    try std.testing.expectEqual(@as(u8, 2), s.sess.committed_count);
    try enqueue_combo(&s.sess, s.p[0].pid, combo);
    try s.sess.tick(1.0); // round timer expires → resolve

    // 3 casts × 5 fire agents = 15 neutralized of 50.
    try std.testing.expectEqual(@as(u32, 15), s.sess.score);
    try std.testing.expectEqual(@as(u8, 0), s.sess.committed_count); // reset for next round
    try std.testing.expectEqual(@as(u8, 0), s.sess.casts_used[s.p[0].pid]);
}

test "casts beyond CASTS_PER_ROUND are dropped" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_fifty_fire);

    // White-box: player already used all casts this round; a pending combo
    // must not commit at resolution.
    s.sess.casts_used[s.p[0].pid] = balance.CASTS_PER_ROUND;
    try enqueue_combo(&s.sess, s.p[0].pid, mk(&.{ .{ .element = .fire }, .{ .action = .dispense } }));
    try resolve(&s.sess);

    try std.testing.expectEqual(@as(u32, 0), s.sess.score); // nothing neutralized
}

test "same player's own twin_flames halves do not fire the team recipe" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    s.sess.round_duration = 3.0;
    s.sess.round_timer = 3.0;
    try s.sess.start_game_encounter(&enc_fifty_fire);

    // Player 0 casts the twin_flames half in two separate windows.
    const half = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } });
    try enqueue_combo(&s.sess, s.p[0].pid, half);
    try s.sess.tick(1.05);
    try enqueue_combo(&s.sess, s.p[0].pid, half);
    try s.sess.tick(1.0);
    try s.sess.tick(1.0); // resolve

    // Distinct players required: flat conversion only (2 × 10 = 20), not 30.
    try std.testing.expectEqual(@as(u32, 20), s.sess.score);
}

// ---------------------------------------------------------------------------
// Medicine
// ---------------------------------------------------------------------------

test "symmetrical medicine heals matching-color healable hunger" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_two_zones); // zone 0: 10 fire + 5 neutral

    // Round 1: no combos → 10 fire modified consumed → fire healable.
    try resolve(&s.sess);
    const fire_healable_r1 = s.sess.hunger_healable[FIRE];
    try std.testing.expectEqual(
        @as(u16, @intCast(10 * balance.HUNGER_COST_MODIFIED_EXTRA)),
        fire_healable_r1,
    );
    const hunger_after_r1 = s.sess.hunger.current;

    // Round 2: FIRE medicine (flat: 2 × MEDICINE_PER_SLOT) matches the fire
    // healable bucket.
    s.p[0].clear();
    try enqueue_combo(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .fire },
        .{ .action = .medicine },
        .{ .action = .medicine },
    }));
    try resolve(&s.sess);

    const expected_heal: u16 = @intCast(@min(2 * balance.MEDICINE_PER_SLOT, fire_healable_r1));
    // Round 2 also consumed zone 1 (8 earth modified + 2 neutral).
    const zone1_hunger = 10 * balance.HUNGER_COST_NORMAL + 8 * balance.HUNGER_COST_MODIFIED_EXTRA;
    try std.testing.expectEqual(
        hunger_after_r1 - expected_heal + @as(u16, @intCast(zone1_hunger)),
        s.sess.hunger.current,
    );
    try std.testing.expectEqual(fire_healable_r1 - expected_heal, s.sess.hunger_healable[FIRE]);

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
    try start_playing(&s, &enc_two_zones); // zone 0: 10 fire + 5 neutral

    // Round 1: no combos → fire healable hunger accrues.
    try resolve(&s.sess);
    const fire_healable_r1 = s.sess.hunger_healable[FIRE];
    try std.testing.expect(fire_healable_r1 > 0);
    const hunger_after_r1 = s.sess.hunger.current;

    // Round 2: panacea is WATER medicine — wrong color, fully wasted.
    try enqueue_combo(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .water },
        .{ .action = .medicine },
        .{ .action = .medicine },
    }));
    try resolve(&s.sess);

    // No healing: hunger only grew by zone 1 consumption; fire bucket intact.
    const zone1_hunger = 10 * balance.HUNGER_COST_NORMAL + 8 * balance.HUNGER_COST_MODIFIED_EXTRA;
    try std.testing.expectEqual(
        hunger_after_r1 + @as(u16, @intCast(zone1_hunger)),
        s.sess.hunger.current,
    );
    try std.testing.expectEqual(fire_healable_r1, s.sess.hunger_healable[FIRE]);
}

test "neutral-slime hunger is not healable" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_neutral_only); // zone 0: 30 neutral

    // Round 1 consumes 30 neutral units — none of that hunger is healable.
    try resolve(&s.sess);
    try std.testing.expectEqual(@as(u32, 0), total_healable(&s.sess));
    const hunger_after_r1 = s.sess.hunger.current;

    // Round 2: heavy medicine — nothing to heal, overheal discarded.
    try enqueue_combo(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .water },
        .{ .action = .medicine },
        .{ .action = .medicine },
    }));
    try enqueue_combo(&s.sess, s.p[1].pid, mk(&.{
        .{ .element = .water },
        .{ .action = .medicine },
        .{ .action = .medicine },
    }));
    try resolve(&s.sess);

    // Hunger only grew (zone 1: 10 neutral); no healing happened.
    try std.testing.expectEqual(
        hunger_after_r1 + @as(u16, @intCast(10 * balance.HUNGER_COST_NORMAL)),
        s.sess.hunger.current,
    );
}

// ---------------------------------------------------------------------------
// End conditions + scoring
// ---------------------------------------------------------------------------

test "all zones consumed ends the game with final score" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_two_zones);

    try resolve(&s.sess); // zone 0
    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);

    s.p[0].clear();
    try resolve(&s.sess); // zone 1 → all consumed
    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);

    // Score = naturally-neutral units only (no agents dispensed): 5 + 2.
    const msgs = try drain(s.p[0].buf.items, arena);
    const go_msg = find_tag(msgs, .game_over) orelse return error.NoGameOver;
    var fbs = std.io.fixedBufferStream(go_msg.payload);
    const go = try proto.decode_game_over(fbs.reader());
    try std.testing.expectEqual(@as(u32, 7), go.score);
}

test "hunger bar full ends the game early" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_tight_budget); // zone 0 un-neutralized = 30 ≥ 25

    s.p[0].clear();
    try resolve(&s.sess);

    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);
    try std.testing.expectEqual(@as(u16, 25), s.sess.hunger.current); // clamped at max
    // Zone 1 was never consumed.
    try std.testing.expectEqual(@as(u8, 1), s.sess.zone_index);

    const msgs = try drain(s.p[0].buf.items, arena);
    const go_msg = find_tag(msgs, .game_over) orelse return error.NoGameOver;
    var fbs = std.io.fixedBufferStream(go_msg.payload);
    const go = try proto.decode_game_over(fbs.reader());
    try std.testing.expectEqual(@as(u32, 0), go.score);
}

test "neutralizing the tight budget zone survives it" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_tight_budget);

    // 10 fire agents (2 flat dispenses) neutralize the whole zone:
    // hunger = 10 normal only < 25 → game continues.
    try enqueue_combo(&s.sess, s.p[0].pid, mk(&.{
        .{ .element = .fire },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
    try resolve(&s.sess);

    try std.testing.expectEqual(session_mod.SessionPhase.playing, s.sess.phase);
    try std.testing.expectEqual(@as(u32, 10), s.sess.score);
    try std.testing.expectEqual(@as(u16, 10), s.sess.hunger.current);
}

test "game_over resets ready flags" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    s.sess.players[s.p[0].pid].ready = true;
    s.sess.players[s.p[1].pid].ready = true;
    try start_playing(&s, &enc_neutral_only);

    try resolve(&s.sess);
    try resolve(&s.sess);
    try std.testing.expectEqual(session_mod.SessionPhase.lobby, s.sess.phase);
    try std.testing.expect(!s.sess.players[s.p[0].pid].ready);
    try std.testing.expect(!s.sess.players[s.p[1].pid].ready);
}

// ---------------------------------------------------------------------------
// Round timing + broadcast contents
// ---------------------------------------------------------------------------

test "round does not resolve before round_duration elapses" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    s.sess.round_duration = 10.0;
    s.sess.round_timer = 10.0;
    try s.sess.start_game_encounter(&enc_two_zones);

    try s.sess.tick(3.0);
    try s.sess.tick(3.0);
    try std.testing.expectEqual(@as(u8, 0), s.sess.zone_index);
    try std.testing.expectEqual(@as(u32, 0), s.sess.round_count);

    try s.sess.tick(5.0); // 11s total > 10s
    try std.testing.expectEqual(@as(u8, 1), s.sess.zone_index);
    try std.testing.expectEqual(@as(u32, 1), s.sess.round_count);
}

test "round_reset broadcast after each resolution" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_two_zones);

    s.p[1].clear();
    try resolve(&s.sess);
    const msgs = try drain(s.p[1].buf.items, arena);
    try std.testing.expectEqual(@as(usize, 1), count_tag(msgs, .round_reset));
}

test "game_state broadcasts hunger, zones, score, and pending combos" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_two_zones);

    const combo = mk(&.{ .{ .element = .fire }, .{ .action = .dispense } });
    try enqueue_combo(&s.sess, s.p[0].pid, combo);

    s.p[0].clear();
    try flush(&s.sess);

    const msgs = try drain(s.p[0].buf.items, arena);
    const gs_msg = find_tag(msgs, .game_state) orelse return error.NoGameState;
    var fbs = std.io.fixedBufferStream(gs_msg.payload);
    const gs = try proto.decode_game_state(fbs.reader());

    try std.testing.expectEqual(@as(u16, enc_two_zones.hunger_max), gs.hunger.max);
    try std.testing.expectEqual(@as(u16, 0), gs.hunger.current);
    try std.testing.expectEqual(@as(u32, 0), gs.score);
    try std.testing.expectEqual(@as(u8, 0), gs.zone_index);
    try std.testing.expectEqual(@as(u8, 2), gs.zone_count);
    // Zone contents visible (current + upcoming).
    try std.testing.expectEqual(@as(u16, 10), gs.zones[0].modified[0]);
    try std.testing.expectEqual(@as(u16, 5), gs.zones[0].neutral);
    try std.testing.expectEqual(@as(u16, 8), gs.zones[1].modified[1]);

    // Player 0's pending combo rides along on their entity snapshot.
    var found = false;
    var i: u8 = 0;
    while (i < gs.entity_count) : (i += 1) {
        const e = gs.entities[i];
        if (e.owner == s.p[0].pid) {
            found = true;
            try std.testing.expectEqual(combo.len, e.combo_len);
            try std.testing.expectEqual(c.Element.fire, e.combo_slots[0].element);
            try std.testing.expectEqual(c.ActionChoice.dispense, e.combo_slots[1].action);
        }
    }
    try std.testing.expect(found);
}

test "resolution broadcasts one cast per player who submitted a combo" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_two_zones);

    // Only player 0 casts this round.
    try enqueue_combo(&s.sess, s.p[0].pid, mk(&.{ .{ .element = .fire }, .{ .action = .dispense } }));
    s.p[1].clear();
    try resolve(&s.sess);

    const msgs = try drain(s.p[1].buf.items, arena);
    var cast_count: usize = 0;
    for (msgs) |m| {
        if (m.tag != .action_result) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        const ar = try proto.decode_action_result(fbs.reader());
        if (ar.tag == .cast) {
            cast_count += 1;
            // Actor is the caster's real entity, not the aggregate sentinel.
            try std.testing.expectEqual(s.sess.players[s.p[0].pid].entity, ar.actor_entity);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), cast_count);
}

test "consumed zone is zeroed in subsequent game_state" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_two_zones);

    s.p[0].clear();
    try resolve(&s.sess);

    const msgs = try drain(s.p[0].buf.items, arena);
    // Last game_state after resolution reflects the consumed zone.
    var last_gs: ?proto.GameState = null;
    for (msgs) |m| {
        if (m.tag != .game_state) continue;
        var fbs = std.io.fixedBufferStream(m.payload);
        last_gs = try proto.decode_game_state(fbs.reader());
    }
    const gs = last_gs orelse return error.NoGameState;
    try std.testing.expectEqual(@as(u8, 1), gs.zone_index);
    try std.testing.expectEqual(@as(u16, 0), gs.zones[0].modified[0]);
    try std.testing.expectEqual(@as(u16, 0), gs.zones[0].neutral);
    try std.testing.expectEqual(@as(u16, 8), gs.zones[1].modified[1]);
}

// ---------------------------------------------------------------------------
// Late join / reconnect
// ---------------------------------------------------------------------------

test "late joiner gets game_start and an entity" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();
    try start_playing(&s, &enc_two_zones);

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
    try std.testing.expect(find_tag(msgs, .game_start) != null);
    try std.testing.expect(s.sess.players[late_pid].entity != std.math.maxInt(u32));
}

test "disconnect in lobby frees the slot" {
    const allocator = std.testing.allocator;

    var s: TwoPlayerSession = undefined;
    try init_two_player_session(&s, allocator);
    defer s.deinit();

    try std.testing.expectEqual(@as(u8, 2), s.sess.player_count);
    s.sess.disconnect(s.p[1].pid);
    try std.testing.expectEqual(@as(u8, 1), s.sess.player_count);
    try std.testing.expect(!s.sess.players[s.p[1].pid].occupied);
}
