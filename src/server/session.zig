//! Game session: lobby management + authoritative Slime Feast game loop.
//!
//! One Session instance per active game room.  The session owns:
//!   - The ECS World (player entities; Lil Guys/slime are session-level data)
//!   - The per-player connection transports
//!   - The state machine (lobby → playing → ended)
//!
//! ## Slime Feast round loop
//!
//! All players share a single countdown timer (`round_timer`).  The round is
//! split into `balance.CASTS_PER_ROUND` cast windows (`cast_timer`, each
//! round_duration / CASTS_PER_ROUND long).  During a window players compose
//! a combo in `action_pool` (latest edit wins; Escape cancels).  When the
//! window closes the pending combo is COMMITTED as a spell (broadcasting
//! `cast_committed` + a `.cast` action_result) — up to CASTS_PER_ROUND
//! spells per player per round.  When the round timer expires
//! `resolve_round()`:
//!   1. Commits any final pending combos, then converts all committed casts
//!      into one AgentOutput (team recipes → player recipes → flat
//!      conversion; see game_logic.match_recipes).
//!   2. Applies the per-color medicine pools to the hunger bar.  Medicine is
//!      symmetrical: color-X medicine heals only the healable hunger caused
//!      by color-X modified slime; overheal discarded.
//!   3. Neutralizes matching-color Modified Slime in the CURRENT zone
//!      (excess / wrong-color agents wasted), then consumes the entire zone:
//!      every unit adds normal hunger; un-neutralized modified units add
//!      extra (healable) hunger.  Score += neutral units consumed
//!      (neutralized + naturally-neutral).
//!   4. Advances to the next zone.
//!
//! The encounter ends when all zones are consumed OR the hunger bar fills.
//! Either way the final shared score is broadcast via game_over.

const std = @import("std");
const ecs = @import("ecs_zig");
const shared = @import("shared");
const c = shared.components;
const proto = shared.protocol;
const logic = shared.game_logic;
const balance = shared.balance;
const enc = shared.encounter;
const dbg = @import("debug_zig");

pub const TickZones = enum { drain, round, broadcast, check_end };

pub const PlayerTeam = struct {};

pub const GameWorld = ecs.World(
    .{
        .kind = c.Kind,
        .statblock = c.Statblock,
        .owner = c.Owner,
        .player_marker = c.PlayerMarker,
    },
    .{
        .player_team = PlayerTeam,
    },
);

pub const MAX_PLAYERS = proto.MAX_PLAYERS;
pub const MAX_CASTS_PER_ROUND: usize =
    @as(usize, MAX_PLAYERS) * @as(usize, shared.balance.CASTS_PER_ROUND);

pub const PlayerSlot = struct {
    occupied: bool = false,
    connected: bool = false,
    player_id: u8,
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: u8 = 0,
    statblock: c.Statblock = .{ .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .hp = 120, .level = 1 },
    ready: bool = false,
    entity: ecs.Entity = std.math.maxInt(ecs.Entity),
    transport: ?shared.Transport = null,
    queue_lock: std.Thread.Mutex = .{},
    msg_queue: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator = undefined,
};

pub const SessionPhase = enum { lobby, playing };

pub const Session = struct {
    allocator: std.mem.Allocator,
    join_code: [6]u8,
    players: [MAX_PLAYERS]PlayerSlot,
    player_count: u8 = 0,
    phase: SessionPhase = .lobby,
    world: GameWorld,
    tick_count: u32 = 0,
    current_encounter: ?*const enc.Encounter = null,
    round_timer: f32 = logic.ROUND_DURATION_DEFAULT_S,
    round_duration: f32 = logic.ROUND_DURATION_DEFAULT_S,
    /// Total Hunger bar.  Fills as slime is consumed; full = encounter over.
    hunger: c.Health = .{ .current = 0, .max = 0 },
    /// Portion of `hunger.current` attributable to un-neutralized modified
    /// slime, tracked per slime color (Element ordinal).  Only matching-color
    /// (symmetrical) Medicine can heal each bucket.
    hunger_healable: [c.Element.size]u16 = [_]u16{0} ** c.Element.size,
    /// Mutable copy of the encounter's zones; consumed zones are zeroed.
    zones: [enc.MAX_ZONES]c.ZoneDef = [_]c.ZoneDef{.{}} ** enc.MAX_ZONES,
    zone_count: u8 = 0,
    /// Zone being eaten this round (== rounds resolved so far).
    zone_index: u8 = 0,
    /// Shared team score: neutral slime units consumed.
    score: u32 = 0,
    action_pool: [MAX_PLAYERS]?c.ActionCombo,
    /// Countdown of the current cast window; pending combos commit at 0.
    cast_timer: f32 = 0,
    /// Spells committed so far this round (in commit order).
    committed_casts: [MAX_CASTS_PER_ROUND]logic.Cast = undefined,
    committed_count: u8 = 0,
    /// Per-player committed-spell count this round (capped CASTS_PER_ROUND).
    casts_used: [MAX_PLAYERS]u8 = [_]u8{0} ** MAX_PLAYERS,
    /// Number of rounds resolved so far in the current game.
    round_count: u32 = 0,
    profiler: dbg.Profiler(TickZones) = dbg.Profiler(TickZones).init(),

    pub fn init(allocator: std.mem.Allocator, join_code: [6]u8) !Session {
        var players: [MAX_PLAYERS]PlayerSlot = undefined;
        for (&players, 0..) |*p, i| {
            p.* = PlayerSlot{
                .player_id = @intCast(i),
                .allocator = allocator,
            };
        }
        var world = try GameWorld.init(allocator);
        set_world_system_signatures(&world);
        return Session{
            .allocator = allocator,
            .join_code = join_code,
            .players = players,
            .world = world,
            .action_pool = [_]?c.ActionCombo{null} ** MAX_PLAYERS,
        };
    }

    pub fn deinit(self: *Session) void {
        self.world.deinit();
        for (&self.players) |*p| {
            p.queue_lock.lock();
            p.msg_queue.deinit(p.allocator);
            p.queue_lock.unlock();
        }
    }

    pub fn join(self: *Session, transport: shared.Transport, name: []const u8) ?u8 {
        for (&self.players) |*p| {
            if (!p.occupied) {
                p.occupied = true;
                p.connected = true;
                p.transport = transport;
                const n = @min(name.len, 16);
                @memcpy(p.name[0..n], name[0..n]);
                p.name_len = @intCast(n);
                p.ready = false;
                self.player_count += 1;
                return p.player_id;
            }
        }
        return null;
    }

    pub fn reconnect(self: *Session, player_id: u8, transport: shared.Transport) bool {
        if (player_id >= MAX_PLAYERS) return false;
        const p = &self.players[player_id];
        if (!p.occupied) {
            if (self.phase != .lobby) return false;
            p.occupied = true;
            self.player_count += 1;
        }
        p.connected = true;
        p.transport = transport;
        return true;
    }

    pub fn disconnect(self: *Session, player_id: u8) void {
        if (player_id >= MAX_PLAYERS) return;
        const p = &self.players[player_id];
        p.connected = false;
        p.transport = null;
        if (self.phase == .lobby) {
            p.occupied = false;
            p.ready = false;
            p.name_len = 0;
            self.player_count -= 1;
        }
    }

    pub fn all_ready(self: *const Session) bool {
        var connected: u8 = 0;
        var ready: u8 = 0;
        for (&self.players) |*p| {
            if (!p.connected) continue;
            connected += 1;
            if (p.ready) ready += 1;
        }
        return connected > 0 and connected == ready;
    }

    pub fn start_game(self: *Session, encounter_label: []const u8) !void {
        const encounter = enc.find_encounter(encounter_label) orelse enc.DEFAULT_ENCOUNTER;
        try self.start_game_encounter(encounter);
    }

    pub fn start_game_encounter(self: *Session, encounter: *const enc.Encounter) !void {
        std.debug.assert(encounter.zones.len <= enc.MAX_ZONES);
        self.world.deinit();
        self.world = try GameWorld.init(self.allocator);
        set_world_system_signatures(&self.world);
        for (&self.action_pool) |*a| a.* = @as(?c.ActionCombo, null);
        self.committed_count = 0;
        self.casts_used = [_]u8{0} ** MAX_PLAYERS;
        self.tick_count = 0;
        self.round_count = 0;

        self.phase = .playing;
        self.current_encounter = encounter;
        self.round_timer = self.round_duration;
        self.cast_timer = self.cast_duration();

        self.hunger = .{ .current = 0, .max = encounter.hunger_max };
        self.hunger_healable = [_]u16{0} ** c.Element.size;
        self.score = 0;
        self.zone_index = 0;
        self.zone_count = @intCast(encounter.zones.len);
        self.zones = [_]c.ZoneDef{.{}} ** enc.MAX_ZONES;
        @memcpy(self.zones[0..encounter.zones.len], encounter.zones);

        std.log.info("game start — encounter: {s} zones={} hunger_max={} round_duration={d:.1}s", .{
            encounter.label, self.zone_count, self.hunger.max, self.round_duration,
        });
        try self.spawn_players();
    }

    fn spawn_players(self: *Session) !void {
        for (&self.players) |*p| {
            if (!p.occupied or !p.connected) continue;
            const e = self.world.create_entity();
            p.entity = e;
            self.world.add_component(e, c.Kind{ .tag = .player });
            self.world.add_component(e, p.statblock);
            self.world.add_component(e, c.Owner{ .player_id = p.player_id });
            self.world.add_component(e, c.PlayerMarker{});
        }
    }

    pub fn tick(self: *Session, dt: f32) !void {
        self.profiler.begin(.drain);
        try self.drain_queues();
        self.profiler.end(.drain);

        if (self.phase != .playing) return;

        self.tick_count += 1;

        self.profiler.begin(.round);
        self.round_timer -= dt;
        self.cast_timer -= dt;
        if (self.round_timer <= 0.0) {
            try self.resolve_round();
            self.reset_round();
        } else if (self.cast_timer <= 0.0) {
            // Cast window closed mid-round: commit pending spells and open
            // the next window (round resolution commits the final window).
            try self.commit_pending_casts();
            self.cast_timer += self.cast_duration();
        }
        self.profiler.end(.round);

        self.profiler.begin(.broadcast);
        try self.broadcast_game_state();
        self.profiler.end(.broadcast);

        self.profiler.begin(.check_end);
        try self.check_end();
        self.profiler.end(.check_end);

        if (self.profiler.should_report(200)) {
            self.profiler.report_stderr("session tick");
        }
    }

    /// Length of one cast window: the round divided into CASTS_PER_ROUND slots.
    fn cast_duration(self: *const Session) f32 {
        return self.round_duration / @as(f32, @floatFromInt(balance.CASTS_PER_ROUND));
    }

    /// Commit every pending combo as a spell (up to CASTS_PER_ROUND per
    /// player per round).  Broadcasts cast_committed (so the owning client
    /// clears its pending combo) and a .cast action_result per commit.
    fn commit_pending_casts(self: *Session) !void {
        for (&self.players, 0..) |*slot, pid| {
            const combo = self.action_pool[pid] orelse continue;
            self.action_pool[pid] = null;

            if (self.casts_used[pid] >= balance.CASTS_PER_ROUND) continue; // cap reached
            if (self.committed_count >= MAX_CASTS_PER_ROUND) continue;

            self.committed_casts[self.committed_count] = .{
                .player_id = @intCast(pid),
                .combo = combo,
            };
            self.committed_count += 1;
            self.casts_used[pid] += 1;

            var buf: [4]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try proto.encode(fbs.writer(), .cast_committed, proto.CastCommitted{
                .player_id = @intCast(pid),
            });
            try self.broadcast_raw(fbs.getWritten());

            if (slot.entity != std.math.maxInt(ecs.Entity)) {
                try self.broadcast_action_result(.{
                    .tag = .cast,
                    .actor_entity = slot.entity,
                    .target_entity = std.math.maxInt(u32),
                    .value = 0,
                });
            }
        }
    }

    fn reset_round(self: *Session) void {
        for (&self.action_pool) |*a| a.* = null;
        self.committed_count = 0;
        self.casts_used = [_]u8{0} ** MAX_PLAYERS;
        self.round_timer = self.round_duration;
        self.cast_timer = self.cast_duration();
        self.round_count += 1;
        var buf: [2]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        proto.encode(fbs.writer(), .round_reset, {}) catch return;
        self.broadcast_raw(fbs.getWritten()) catch {};
    }

    fn drain_queues(self: *Session) !void {
        for (&self.players) |*p| {
            if (!p.connected) continue;
            p.queue_lock.lock();
            const data = p.msg_queue.items;
            if (data.len == 0) {
                p.queue_lock.unlock();
                continue;
            }
            var local_buf: [4096]u8 = undefined;
            const len = @min(data.len, local_buf.len);
            @memcpy(local_buf[0..len], data[0..len]);
            p.msg_queue.clearRetainingCapacity();
            p.queue_lock.unlock();

            var fbs = std.io.fixedBufferStream(local_buf[0..len]);
            while (fbs.pos < len) {
                const tag = proto.read_tag(fbs.reader()) catch break;
                self.handle_client_message(p.player_id, tag, &fbs) catch {};
            }
        }
    }

    fn handle_client_message(
        self: *Session,
        player_id: u8,
        tag: proto.MsgTag,
        fbs: *std.io.FixedBufferStream([]u8),
    ) !void {
        switch (tag) {
            .join_lobby => {
                const p = try proto.decode_join_lobby(fbs.reader());
                const slot = &self.players[player_id];
                const n = @min(p.name_len, 16);
                @memcpy(slot.name[0..n], p.name[0..n]);
                slot.name_len = @intCast(n);
                std.log.info("player {} name set: {s}", .{ player_id, slot.name[0..slot.name_len] });
                if (self.phase == .playing) {
                    // Late joiner: spawn their entity, then send them a
                    // game_start so their client enters game phase.  Existing
                    // players are unaffected — no lobby_update is broadcast.
                    try self.spawn_player_midgame(player_id);
                    try self.send_game_start_to(player_id);
                } else {
                    try self.broadcast_lobby_update();
                }
            },
            .ready_up => {
                const slot = &self.players[player_id];
                slot.ready = !slot.ready;
                std.log.info("player {} ready: {}", .{ player_id, slot.ready });
                try self.broadcast_lobby_update();
                if (self.all_ready()) {
                    std.log.info("all players ready — starting game", .{});
                    try self.start_game(enc.DEFAULT_ENCOUNTER.label);
                    try self.broadcast_game_start(enc.DEFAULT_ENCOUNTER.label);
                }
            },
            .choose_combo => {
                if (self.phase == .playing and player_id < MAX_PLAYERS) {
                    const p = try proto.decode_choose_combo(fbs.reader());
                    self.action_pool[player_id] = p.combo;
                    std.log.debug("player {} combo len={}", .{ player_id, p.combo.len });
                }
            },
            .cancel_combo => {
                if (self.phase == .playing and player_id < MAX_PLAYERS) {
                    self.action_pool[player_id] = null;
                    std.log.debug("player {} cancelled combo", .{player_id});
                }
            },
            .set_statblock => {
                const p = try proto.decode_set_statblock(fbs.reader());
                if (player_id < MAX_PLAYERS) {
                    self.players[player_id].statblock = p.statblock;
                    if (self.phase == .playing) {
                        // Apply to live entity if already spawned.
                        const slot = &self.players[player_id];
                        if (slot.entity != std.math.maxInt(ecs.Entity) and
                            self.world.component_arrays.statblock.has(slot.entity))
                        {
                            self.world.get_component(slot.entity, c.Statblock).* = p.statblock;
                        }
                    }
                }
            },
            .reconnect => {},
            else => {},
        }
    }

    /// Resolve one round of the Slime Feast (see module doc for the order).
    fn resolve_round(self: *Session) !void {
        // Final cast window closes with the round: commit remaining pending
        // combos (broadcasts cast_committed + .cast per commit).
        try self.commit_pending_casts();

        const output = logic.match_recipes(self.committed_casts[0..self.committed_count]);

        // Medicine first: heals hunger from PREVIOUS rounds' modified slime.
        const healed = logic.apply_medicine(&self.hunger, &self.hunger_healable, output.medicine);
        if (healed > 0) {
            try self.broadcast_action_result(.{
                .tag = .heal,
                .actor_entity = std.math.maxInt(u32),
                .target_entity = std.math.maxInt(u32),
                .value = healed,
            });
        }

        if (self.zone_index >= self.zone_count) return;

        // Neutralize + consume the entire current zone.
        const zone = self.zones[self.zone_index];
        const outcome = logic.resolve_zone(zone, output.units);

        var neutralized_total: u32 = 0;
        for (outcome.neutralized) |n| neutralized_total += n;
        if (neutralized_total > 0) {
            try self.broadcast_action_result(.{
                .tag = .shield,
                .actor_entity = std.math.maxInt(u32),
                .target_entity = std.math.maxInt(u32),
                .value = @intCast(@min(neutralized_total, std.math.maxInt(u16))),
            });
        }

        const hunger_added = outcome.hunger_normal + outcome.hunger_extra_total();
        logic.add_hunger(&self.hunger, hunger_added);
        for (&self.hunger_healable, outcome.hunger_extra) |*healable, extra| {
            const grown = @as(u32, healable.*) + extra;
            healable.* = @intCast(@min(grown, @as(u32, std.math.maxInt(u16))));
        }
        self.score += outcome.score;

        if (hunger_added > 0) {
            try self.broadcast_action_result(.{
                .tag = .damage,
                .actor_entity = std.math.maxInt(u32),
                .target_entity = std.math.maxInt(u32),
                .value = @intCast(@min(hunger_added, std.math.maxInt(u16))),
            });
        }

        std.log.info("round {}: zone {} consumed — neutralized={} hunger +{} ({}/{} healable={any}) score={}", .{
            self.round_count,       self.zone_index,    neutralized_total, hunger_added,
            self.hunger.current,    self.hunger.max,    self.hunger_healable,
            self.score,
        });

        // Zone fully consumed.
        self.zones[self.zone_index] = .{};
        self.zone_index += 1;
    }

    fn check_end(self: *Session) !void {
        if (self.phase != .playing) return;
        if (logic.hunger_full(self.hunger)) {
            std.log.info("hunger bar full — encounter over, score={}", .{self.score});
            try self.end_game();
        } else if (self.zone_index >= self.zone_count) {
            std.log.info("all slime consumed — encounter over, score={}", .{self.score});
            try self.end_game();
        }
    }

    fn end_game(self: *Session) !void {
        std.log.info("game over — score: {}", .{self.score});
        self.phase = .lobby;
        // Reset ready flags so players must opt-in to the next game.
        for (&self.players) |*p| p.ready = false;
        var buf: [8]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .game_over, proto.GameOver{ .score = self.score });
        try self.broadcast_raw(fbs.getWritten());
        try self.broadcast_lobby_update();
    }

    /// Spawn an ECS entity for a player who joined while the game is in progress.
    fn spawn_player_midgame(self: *Session, player_id: u8) !void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        const e = self.world.create_entity();
        slot.entity = e;
        self.world.add_component(e, c.Kind{ .tag = .player });
        self.world.add_component(e, slot.statblock);
        self.world.add_component(e, c.Owner{ .player_id = slot.player_id });
        self.world.add_component(e, c.PlayerMarker{});
        std.log.info("player {} joined mid-game", .{player_id});
    }

    /// Send a game_start message to a single player so their client transitions
    /// to game phase.  Used for late joiners while the session is already playing.
    fn send_game_start_to(self: *Session, player_id: u8) !void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        const t = slot.transport orelse return;
        const encounter = self.current_encounter orelse return;
        var buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        var gs_msg = proto.GameStart{
            .encounter_label = [_]u8{0} ** 32,
            .encounter_label_len = @intCast(@min(encounter.label.len, 32)),
            .player_id = slot.player_id,
            .round_duration = self.round_duration,
        };
        @memcpy(gs_msg.encounter_label[0..gs_msg.encounter_label_len], encounter.label[0..gs_msg.encounter_label_len]);
        try proto.encode(fbs.writer(), .game_start, gs_msg);
        try t.send(fbs.getWritten());
    }

    pub fn broadcast_lobby_update(self: *Session) !void {
        var base = proto.LobbyUpdate{
            .join_code = self.join_code,
            .player_count = self.player_count,
            .players = [_]proto.PlayerInfo{std.mem.zeroes(proto.PlayerInfo)} ** proto.MAX_PLAYERS,
            .player_id = 0xFF,
            .round_duration = self.round_duration,
        };
        for (&self.players, 0..) |*slot, i| {
            if (!slot.occupied) continue;
            base.players[i] = .{
                .player_id = slot.player_id,
                .name = slot.name,
                .name_len = slot.name_len,
                .kind = .player,
                .ready = slot.ready,
                .connected = slot.connected,
            };
        }
        for (&self.players) |*slot| {
            if (!slot.connected) continue;
            const t = slot.transport orelse continue;
            var msg = base;
            msg.player_id = slot.player_id;
            var buf: [512]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try proto.encode(fbs.writer(), .lobby_update, msg);
            t.send(fbs.getWritten()) catch {};
        }
    }

    pub fn broadcast_game_start(self: *Session, encounter_label: []const u8) !void {
        for (&self.players) |*slot| {
            if (!slot.connected) continue;
            const t = slot.transport orelse continue;
            var buf: [64]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            var gs_msg = proto.GameStart{
                .encounter_label = [_]u8{0} ** 32,
                .encounter_label_len = @intCast(@min(encounter_label.len, 32)),
                .player_id = slot.player_id,
                .round_duration = self.round_duration,
            };
            @memcpy(gs_msg.encounter_label[0..gs_msg.encounter_label_len], encounter_label[0..gs_msg.encounter_label_len]);
            try proto.encode(fbs.writer(), .game_start, gs_msg);
            try t.send(fbs.getWritten());
        }
    }

    fn broadcast_game_state(self: *Session) !void {
        var snap = proto.GameState.blank;
        snap.tick = self.tick_count;
        snap.round_timer = @max(self.round_timer, 0.0);
        snap.cast_timer = @max(self.cast_timer, 0.0);
        snap.hunger = .{
            .current = self.hunger.current,
            .max = self.hunger.max,
        };
        snap.hunger_healable = self.hunger_healable;
        snap.score = self.score;
        snap.zone_index = self.zone_index;
        snap.zone_count = self.zone_count;
        for (self.zones[0..self.zone_count], 0..) |zone, i| {
            snap.zones[i] = .{ .modified = zone.modified, .neutral = zone.neutral };
        }

        const pm_arr = &self.world.component_arrays.player_marker;
        for (pm_arr.index_to_entity[0..pm_arr.size]) |e| {
            if (snap.entity_count >= proto.MAX_ENTITIES_WIRE) break;
            const kd = self.world.get_component(e, c.Kind);
            const own = self.world.get_component(e, c.Owner).player_id;
            const combo_len: u8 = if (self.action_pool[own]) |combo| combo.len else 0;
            const combo_slots = if (combo_len > 0)
                self.action_pool[own].?.slots
            else
                [_]c.ComboSlot{.{ .action = .dispense }} ** c.MAX_COMBO_LEN;

            snap.entities[snap.entity_count] = .{
                .entity = e,
                .kind = kd.tag,
                .owner = own,
                .casts_used = self.casts_used[own],
                .combo_len = combo_len,
                .combo_slots = combo_slots,
            };
            snap.entity_count += 1;
        }

        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .game_state, snap);
        try self.broadcast_raw(fbs.getWritten());
    }

    fn broadcast_action_result(self: *Session, result: proto.ActionResult) !void {
        var buf: [32]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .action_result, result);
        try self.broadcast_raw(fbs.getWritten());
    }

    fn broadcast_raw(self: *Session, data: []const u8) !void {
        for (&self.players) |*slot| {
            if (!slot.connected) continue;
            const t = slot.transport orelse continue;
            t.send(data) catch {};
        }
    }

    pub fn enqueue_message(self: *Session, player_id: u8, data: []const u8) void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        slot.queue_lock.lock();
        defer slot.queue_lock.unlock();
        slot.msg_queue.appendSlice(slot.allocator, data) catch {};
    }
};

fn set_world_system_signatures(world: *GameWorld) void {
    var sig = @import("ecs_zig").Signature.initEmpty();
    sig.set(GameWorld.component_type(c.Kind));
    sig.set(GameWorld.component_type(c.Owner));
    sig.set(GameWorld.component_type(c.PlayerMarker));
    world.set_system_signature(PlayerTeam, sig);
}
