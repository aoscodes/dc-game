//! Game session: lobby management, authoritative game loop, enemy AI.
//!
//! One Session instance per active game room.  The session owns:
//!   - The ECS World (all game entities and components)
//!   - The per-player connection transports
//!   - The state machine (lobby → playing → ended)
//!
//! ## Round-based game loop
//!
//! All actors share a single countdown timer (`round_timer`).  During each
//! round players submit an `ActionChoice` (damage / shield / heal) which is
//! recorded in `action_pool`.  When the timer expires `resolve_round()` is
//! called, which:
//!   1. Applies the *player damage pool* to every living enemy.
//!   2. Applies the *player shield pool* to every living player (flat HP).
//!   3. Applies the *player heal pool* to every living player.
//!   4. Applies *enemy intent* (via `compute_enemy_intent`) to every living
//!      player, first absorbing from shield, then HP.
//!   5. Broadcasts all action results and checks win/loss.
//!
//! The round timer duration is configurable per session (`round_duration`) and
//! is sent to clients at game start so they can display a countdown.

const std = @import("std");
const ecs = @import("ecs_zig");
const shared = @import("shared");
const c = shared.components;
const proto = shared.protocol;
const logic = shared.game_logic;
const waves = shared.waves;
const dbg = @import("debug_zig");

const ws_server = @import("net/ws_server.zig");

/// Zones measured by the per-session tick profiler.
pub const TickZones = enum { drain, round, broadcast, check_win };

pub const GameWorld = ecs.World(
    .{
        .health = c.Health,
        .class = c.Class,
        .team = c.Team,
        .owner = c.Owner,
        .stats = c.Stats,
    },
    .{},
);

pub const MAX_PLAYERS = proto.MAX_PLAYERS;

/// Cosmetic grid position stored in the lobby (no gameplay effect).
pub const LobbyGridPos = struct { col: u2 = 0, row: u2 = 0 };

pub const PlayerSlot = struct {
    occupied: bool = false,
    connected: bool = false,
    player_id: u8,
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: u8 = 0,
    class: c.ClassTag = .fighter,
    ready: bool = false,
    /// Cosmetic lobby grid position — no gameplay effect.
    grid_pos: LobbyGridPos = .{},
    entity: ecs.Entity = std.math.maxInt(ecs.Entity),
    transport: ?shared.Transport = null,
    queue_lock: std.Thread.Mutex = .{},
    msg_queue: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator = undefined,
};

pub const SessionPhase = enum { lobby, playing, ended };

pub const Session = struct {
    allocator: std.mem.Allocator,
    join_code: [6]u8,
    players: [MAX_PLAYERS]PlayerSlot,
    player_count: u8 = 0,
    phase: SessionPhase = .lobby,
    world: GameWorld,

    /// Per-entity shield HP (flat damage absorption). Indexed by ECS entity ID.
    shield: [ecs.MAX_ENTITIES]u16,

    tick_count: u32 = 0,
    current_wave: ?*const waves.Wave = null,
    living: std.ArrayListUnmanaged(ecs.Entity) = .empty,

    /// Countdown timer for the current round (seconds remaining).
    round_timer: f32 = logic.ROUND_DURATION_DEFAULT_S,

    /// Duration of each round in seconds. Configurable in lobby; sent to
    /// clients at game start so they can display the countdown.
    round_duration: f32 = logic.ROUND_DURATION_DEFAULT_S,

    /// Per-player action submitted this round.  Null = player hasn't acted yet.
    /// Overwritten freely until the round ends.
    action_pool: [MAX_PLAYERS]?c.ActionChoice,

    /// Per-tick timing profiler.
    profiler: dbg.Profiler(TickZones) = dbg.Profiler(TickZones).init(),

    /// Optional GameState replay recorder.
    recorder: ?dbg.replay.Recorder(std.io.AnyWriter) = null,

    pub fn init(allocator: std.mem.Allocator, join_code: [6]u8) !Session {
        const default_positions = [MAX_PLAYERS]LobbyGridPos{
            .{ .col = 0, .row = 0 }, .{ .col = 1, .row = 1 },
            .{ .col = 2, .row = 2 }, .{ .col = 0, .row = 3 },
            .{ .col = 1, .row = 3 }, .{ .col = 2, .row = 3 },
        };
        var players: [MAX_PLAYERS]PlayerSlot = undefined;
        for (&players, 0..) |*p, i| {
            p.* = PlayerSlot{
                .player_id = @intCast(i),
                .grid_pos = default_positions[i],
                .allocator = allocator,
            };
        }
        return Session{
            .allocator = allocator,
            .join_code = join_code,
            .players = players,
            .world = try GameWorld.init(allocator),
            .shield = [_]u16{0} ** ecs.MAX_ENTITIES,
            .action_pool = [_]?c.ActionChoice{null} ** MAX_PLAYERS,
        };
    }

    pub fn deinit(self: *Session) void {
        self.world.deinit();
        self.living.deinit(self.allocator);
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

    pub fn set_class(self: *Session, player_id: u8, class: c.ClassTag) void {
        if (player_id >= MAX_PLAYERS) return;
        self.players[player_id].class = class;
    }

    pub fn set_ready(self: *Session, player_id: u8, ready: bool) void {
        if (player_id >= MAX_PLAYERS) return;
        self.players[player_id].ready = ready;
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

    pub fn start_game(self: *Session, wave_label: []const u8) !void {
        const wave = waves.find_wave(wave_label) orelse waves.find_wave("wave_01_basic").?;
        try self.start_game_wave(wave);
    }

    pub fn start_game_wave(self: *Session, wave: *const waves.Wave) !void {
        // Destroy all entities from any previous game so state is clean.
        self.living.clearRetainingCapacity();
        self.world.deinit();
        self.world = try GameWorld.init(self.allocator);
        @memset(&self.shield, 0);
        for (&self.action_pool) |*a| a.* = null;
        self.tick_count = 0;

        self.phase = .playing;
        self.current_wave = wave;
        self.round_timer = self.round_duration;
        std.log.info("game start — wave: {s} round_duration={d:.1}s", .{ wave.label, self.round_duration });
        try self.spawn_players();
        try self.spawn_wave(wave);
    }

    fn spawn_players(self: *Session) !void {
        var slot_idx: u8 = 0;
        for (&self.players) |*p| {
            if (!p.occupied or !p.connected) continue;
            const d = waves.class_defaults(p.class);
            const e = self.world.create_entity();
            p.entity = e;
            self.world.add_component(e, c.Health{ .current = d.max_hp, .max = d.max_hp });
            self.world.add_component(e, c.Class{ .tag = p.class });
            self.world.add_component(e, c.Team{ .id = .players });
            self.world.add_component(e, c.Owner{ .player_id = p.player_id });
            self.world.add_component(e, c.Stats{
                .attack = d.attack,
                .defense = d.defense,
                .speed_base = d.speed_base,
                .max_hp = d.max_hp,
            });
            self.shield[e] = 0;
            try self.living.append(self.allocator, e);
            slot_idx += 1;
        }
    }

    fn spawn_wave(self: *Session, wave: *const waves.Wave) !void {
        std.log.info("spawning wave: {s} ({} enemies)", .{ wave.label, wave.entries.len });
        for (wave.entries, 0..) |entry, i| {
            const d = waves.resolve_stats(entry.class, entry.stats);
            const e = self.world.create_entity();
            self.world.add_component(e, c.Health{ .current = d.max_hp, .max = d.max_hp });
            self.world.add_component(e, c.Class{ .tag = entry.class });
            self.world.add_component(e, c.Team{ .id = .enemies });
            self.world.add_component(e, c.Stats{
                .attack = d.attack,
                .defense = d.defense,
                .speed_base = d.speed_base,
                .max_hp = d.max_hp,
            });
            self.shield[e] = 0;
            try self.living.append(self.allocator, e);
            _ = i; // slot index unused for enemies (no owner component)
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
        if (self.round_timer <= 0.0) {
            try self.resolve_round();
            self.reset_round();
        }
        self.profiler.end(.round);

        self.profiler.begin(.broadcast);
        try self.broadcast_game_state();
        self.profiler.end(.broadcast);

        self.profiler.begin(.check_win);
        try self.check_win();
        self.profiler.end(.check_win);

        if (self.profiler.should_report(200)) {
            self.profiler.report_stderr("session tick");
        }
    }

    /// Clear the action pool and reset the round timer for the next round.
    fn reset_round(self: *Session) void {
        for (&self.action_pool) |*a| a.* = null;
        self.round_timer = self.round_duration;
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
                try self.broadcast_lobby_update();
            },
            .choose_class => {
                const p = try proto.decode_choose_class(fbs.reader());
                self.set_class(player_id, p.class);
                std.log.info("player {} class: {s}", .{ player_id, @tagName(p.class) });
                try self.broadcast_lobby_update();
            },
            .ready_up => {
                const slot = &self.players[player_id];
                slot.ready = !slot.ready;
                std.log.info("player {} ready: {}", .{ player_id, slot.ready });
                try self.broadcast_lobby_update();
                if (self.all_ready()) {
                    std.log.info("all players ready — starting game", .{});
                    try self.start_game("wave_01_basic");
                    try self.broadcast_game_start("wave_01_basic");
                }
            },
            .choose_position => {
                if (self.phase == .lobby) {
                    const p = try proto.decode_choose_position(fbs.reader());
                    if (p.col < 3 and p.row < 4) {
                        var taken = false;
                        for (&self.players) |*other| {
                            if (!other.occupied or other.player_id == player_id) continue;
                            if (other.grid_pos.col == @as(u2, @intCast(p.col)) and
                                other.grid_pos.row == @as(u2, @intCast(p.row)))
                            {
                                taken = true;
                                break;
                            }
                        }
                        if (!taken) {
                            self.players[player_id].grid_pos = LobbyGridPos{
                                .col = @intCast(p.col),
                                .row = @intCast(p.row),
                            };
                            std.log.info("player {} position: col={} row={}", .{ player_id, p.col, p.row });
                            try self.broadcast_lobby_update();
                        }
                    }
                }
            },
            .choose_action => {
                if (self.phase == .playing and player_id < MAX_PLAYERS) {
                    const p = try proto.decode_choose_action(fbs.reader());
                    self.action_pool[player_id] = p.action;
                    std.log.debug("player {} action: {s}", .{ player_id, @tagName(p.action) });
                }
            },
            .reconnect => {},
            else => {},
        }
    }

    // -------------------------------------------------------------------------
    // Round resolution
    // -------------------------------------------------------------------------

    fn resolve_round(self: *Session) !void {
        // Count player actions.
        var damage_pool: u16 = 0;
        var shield_pool: u16 = 0;
        var heal_pool: u16 = 0;
        for (&self.action_pool) |maybe_action| {
            const action = maybe_action orelse continue;
            switch (action) {
                .damage => damage_pool += 1,
                .shield => shield_pool += 1,
                .heal => heal_pool += 1,
            }
        }
        std.log.info("round resolve — dmg={} shld={} heal={}", .{ damage_pool, shield_pool, heal_pool });

        // Collect living enemies and players (snapshot to avoid mutation during iteration).
        var enemy_buf: [64]ecs.Entity = undefined;
        var player_buf: [MAX_PLAYERS]ecs.Entity = undefined;
        var n_enemies: usize = 0;
        var n_players: usize = 0;
        for (self.living.items) |e| {
            const team = self.world.get_component(e, c.Team);
            switch (team.id) {
                .enemies => if (n_enemies < enemy_buf.len) {
                    enemy_buf[n_enemies] = e;
                    n_enemies += 1;
                },
                .players => if (n_players < player_buf.len) {
                    player_buf[n_players] = e;
                    n_players += 1;
                },
            }
        }

        // 1. Damage pool → each living enemy.
        if (damage_pool > 0) {
            for (enemy_buf[0..n_enemies]) |e| {
                const hp = self.world.get_component(e, c.Health);
                const dealt = logic.resolve_damage_pool(hp, &self.shield[e], damage_pool);
                try self.broadcast_action_result(.{
                    .tag = .damage,
                    .actor_entity = std.math.maxInt(u32),
                    .target_entity = e,
                    .value = dealt,
                });
                if (logic.is_dead(hp.*)) {
                    std.log.info("enemy entity {} killed by damage pool", .{e});
                    try self.kill_entity(e);
                    try self.broadcast_action_result(.{
                        .tag = .death,
                        .actor_entity = std.math.maxInt(u32),
                        .target_entity = e,
                        .value = 0,
                    });
                }
            }
        }

        // 2. Shield pool → each living player.
        if (shield_pool > 0) {
            for (player_buf[0..n_players]) |e| {
                if (self.find_living(e) == null) continue;
                logic.resolve_shield_pool(&self.shield[e], shield_pool);
                try self.broadcast_action_result(.{
                    .tag = .shield,
                    .actor_entity = std.math.maxInt(u32),
                    .target_entity = e,
                    .value = shield_pool * logic.ACTION_EFFECT_VALUE,
                });
            }
        }

        // 3. Heal pool → each living player.
        if (heal_pool > 0) {
            for (player_buf[0..n_players]) |e| {
                if (self.find_living(e) == null) continue;
                const hp = self.world.get_component(e, c.Health);
                logic.resolve_heal_pool(hp, heal_pool);
                try self.broadcast_action_result(.{
                    .tag = .heal,
                    .actor_entity = std.math.maxInt(u32),
                    .target_entity = e,
                    .value = heal_pool * logic.ACTION_EFFECT_VALUE,
                });
            }
        }

        // 4. Enemy intent → each living player.
        // Each living enemy deals 1 damage per player per round.
        const living_enemy_count: u16 = blk: {
            var count: u16 = 0;
            for (self.living.items) |e| {
                if (self.world.get_component(e, c.Team).id == .enemies) count += 1;
            }
            break :blk count;
        };
        if (living_enemy_count > 0) {
            const intent = logic.compute_enemy_intent(living_enemy_count);
            for (player_buf[0..n_players]) |e| {
                if (self.find_living(e) == null) continue;
                const hp = self.world.get_component(e, c.Health);
                const hp_dmg = logic.apply_enemy_intent(hp, &self.shield[e], intent);
                if (hp_dmg > 0) {
                    try self.broadcast_action_result(.{
                        .tag = .damage,
                        .actor_entity = std.math.maxInt(u32),
                        .target_entity = e,
                        .value = hp_dmg,
                    });
                }
                if (logic.is_dead(hp.*)) {
                    std.log.info("player entity {} killed by enemies", .{e});
                    try self.kill_entity(e);
                    try self.broadcast_action_result(.{
                        .tag = .death,
                        .actor_entity = std.math.maxInt(u32),
                        .target_entity = e,
                        .value = 0,
                    });
                }
            }
        }
    }

    fn find_living(self: *Session, entity: ecs.Entity) ?ecs.Entity {
        for (self.living.items) |e| {
            if (e == entity) return e;
        }
        return null;
    }

    fn kill_entity(self: *Session, entity: ecs.Entity) !void {
        for (self.living.items, 0..) |e, i| {
            if (e == entity) {
                _ = self.living.swapRemove(i);
                break;
            }
        }
        self.shield[entity] = 0;
        self.world.destroy_entity(entity);
    }

    fn check_win(self: *Session) !void {
        var players_alive: u8 = 0;
        var enemies_alive: u8 = 0;
        for (self.living.items) |e| {
            const t = self.world.get_component(e, c.Team);
            switch (t.id) {
                .players => players_alive += 1,
                .enemies => enemies_alive += 1,
            }
        }

        if (enemies_alive == 0) {
            if (self.current_wave) |wave| {
                if (wave.next_wave) |next_label| {
                    const next = waves.find_wave(next_label);
                    if (next) |w| {
                        std.log.info("wave cleared — next: {s}", .{next_label});
                        self.current_wave = w;
                        try self.spawn_wave(w);
                        return;
                    }
                }
            }
            std.log.info("all waves cleared — players win", .{});
            try self.end_game(.players);
        } else if (players_alive == 0) {
            std.log.info("all players dead — enemies win", .{});
            try self.end_game(.enemies);
        }
    }

    fn end_game(self: *Session, winner: proto.WinnerId) !void {
        std.log.info("game over — winner: {s}", .{@tagName(winner)});
        self.phase = .lobby;
        // Reset ready flags so players must opt-in to the next game.
        for (&self.players) |*p| p.ready = false;
        var buf: [8]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .game_over, proto.GameOver{ .winner = winner });
        try self.broadcast_raw(fbs.getWritten());
        try self.broadcast_lobby_update();
    }

    // -------------------------------------------------------------------------
    // Broadcast helpers
    // -------------------------------------------------------------------------

    pub fn broadcast_lobby_update(self: *Session) !void {
        var base = proto.LobbyUpdate{
            .join_code = self.join_code,
            .player_count = self.player_count,
            .players = [_]proto.PlayerInfo{std.mem.zeroes(proto.PlayerInfo)} ** proto.MAX_PLAYERS,
            .player_id = 0xFF,
            .round_duration = self.round_duration,
        };
        for (&self.players) |*slot| {
            if (!slot.occupied) continue;
            const pi = &base.players[slot.player_id];
            pi.player_id = slot.player_id;
            pi.name = slot.name;
            pi.name_len = slot.name_len;
            pi.class = slot.class;
            pi.ready = slot.ready;
            pi.connected = slot.connected;
            pi.grid_col = slot.grid_pos.col;
            pi.grid_row = slot.grid_pos.row;
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

    pub fn broadcast_game_start(self: *Session, wave_label: []const u8) !void {
        for (&self.players) |*slot| {
            if (!slot.connected) continue;
            const t = slot.transport orelse continue;
            var buf: [64]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            var gs_msg = proto.GameStart{
                .wave_label = [_]u8{0} ** 32,
                .wave_label_len = @intCast(@min(wave_label.len, 32)),
                .player_id = slot.player_id,
                .round_duration = self.round_duration,
            };
            @memcpy(gs_msg.wave_label[0..gs_msg.wave_label_len], wave_label[0..gs_msg.wave_label_len]);
            try proto.encode(fbs.writer(), .game_start, gs_msg);
            try t.send(fbs.getWritten());
        }
    }

    fn broadcast_game_state(self: *Session) !void {
        var snap = proto.GameState{
            .tick = self.tick_count,
            .round_timer = @max(self.round_timer, 0.0),
            .entity_count = 0,
            .entities = [_]proto.EntitySnapshot{std.mem.zeroes(proto.EntitySnapshot)} ** proto.MAX_ENTITIES_WIRE,
        };

        for (self.living.items, 0..) |e, slot_idx| {
            if (snap.entity_count >= proto.MAX_ENTITIES_WIRE) break;
            const hp = self.world.get_component(e, c.Health);
            const cl = self.world.get_component(e, c.Class);
            const tm = self.world.get_component(e, c.Team);
            const own: u8 = if (self.world.component_arrays.owner.has(e))
                self.world.get_component(e, c.Owner).player_id
            else
                0xFF;

            snap.entities[snap.entity_count] = .{
                .entity = e,
                .slot = @intCast(@min(slot_idx, 0xFF)),
                .hp_current = hp.current,
                .hp_max = hp.max,
                .shield_hp = self.shield[e],
                .class = cl.tag,
                .team = tm.id,
                .owner = own,
            };
            snap.entity_count += 1;
        }

        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .game_state, snap);
        try self.broadcast_raw(fbs.getWritten());

        if (self.recorder) |*rec| {
            rec.record(snap) catch |err| {
                std.log.warn("replay recorder error: {}", .{err});
            };
        }
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
