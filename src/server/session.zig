//! Game session: lobby management, authoritative game loop, enemy AI.
//!
//! One Session instance per active game room.  The session owns:
//!   - The ECS World (all game entities and components)
//!   - The per-player connection transports
//!   - The state machine (lobby → playing → ended)
//!
//! ## ECS layout
//!
//! Components: Class, Team, Owner (player entities); Health, Shield, Class, Team (enemy entities)
//! Systems:
//!   - PlayerTeam  — tracks every entity whose Team.id == .players
//!   - EnemyTeam   — tracks every living entity whose Team.id == .enemies
//!
//! Player entities carry no Health or Shield; player HP/shield lives in the
//! session-level `shared_hp` / `shared_shield` fields (shared party pool).
//!
//! System signatures are set at world-init time in `start_game_wave`.
//! Entities are added/removed from system sets automatically by the world
//! when components are added/removed.
//!
//! ## Round-based game loop
//!
//! All actors share a single countdown timer (`round_timer`).  During each
//! round players submit an `ActionChoice` (damage / shield / heal) which is
//! recorded in `action_pool`.  When the timer expires `resolve_round()` is
//! called, which:
//!   1. Applies the *player damage pool* to every living enemy.
//!   2. Applies the *player shield pool* to the shared party shield buffer.
//!   3. Applies the *player heal pool* to the shared party HP pool.
//!   4. Applies *enemy intent* (via `compute_enemy_intent`) to the shared
//!      party pool: shield absorbs first, remainder drains shared HP.
//!   5. Broadcasts all action results and checks win/loss.
//!
//! The party is defeated (enemies win) when `shared_hp.current` reaches 0.
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

// ---------------------------------------------------------------------------
// ECS system marker types
//
// A "system" in this ECS is a plain struct whose presence in World(...)
// causes a DynamicBitSet to be maintained for all matching entities.
// The struct itself carries no state; the World owns the entity set.
// ---------------------------------------------------------------------------

/// Tracks all living entities belonging to the players team.
pub const PlayerTeam = struct {};
pub const EnemyTeam = struct {};

pub const GameWorld = ecs.World(
    .{
        .health = c.Health,
        .shield = c.Shield,
        .class = c.Class,
        .team = c.Team,
        .owner = c.Owner,
        .player_marker = c.PlayerMarker,
        .enemy_marker = c.EnemyMarker,
    },
    .{
        .player_team = PlayerTeam,
        .enemy_team = EnemyTeam,
    },
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

    tick_count: u32 = 0,
    current_wave: ?*const waves.Wave = null,

    /// Countdown timer for the current round (seconds remaining).
    round_timer: f32 = logic.ROUND_DURATION_DEFAULT_S,

    /// Duration of each round in seconds. Configurable in lobby; sent to
    /// clients at game start so they can display the countdown.
    round_duration: f32 = logic.ROUND_DURATION_DEFAULT_S,

    /// Shared party HP pool.  Initialised to the sum of all player max HPs at
    /// game start.  Enemy intent drains this pool (shield absorbs first).
    /// The party is defeated when `shared_hp.current` reaches 0.
    shared_hp: c.Health = .{ .current = 0, .max = 0 },

    /// Shared party shield buffer.  Shield actions add to this; enemy damage
    /// absorbs from it before touching `shared_hp`.
    shared_shield: c.Shield = .{ .hp = 0 },

    /// Per-player combo submitted this round.  Null = player hasn't acted yet.
    /// Overwritten freely until the round ends via choose_combo/choose_action;
    /// nulled by cancel_combo.
    action_pool: [MAX_PLAYERS]?c.ActionCombo,

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
        var world = try GameWorld.init(allocator);
        // System signatures set once here; maintained automatically by world.
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
        self.world.deinit();
        self.world = try GameWorld.init(self.allocator);
        set_world_system_signatures(&self.world);
        for (&self.action_pool) |*a| a.* = @as(?c.ActionCombo, null);
        self.tick_count = 0;

        self.phase = .playing;
        self.current_wave = wave;
        self.round_timer = self.round_duration;
        std.log.info("game start — wave: {s} round_duration={d:.1}s", .{ wave.label, self.round_duration });
        try self.spawn_players();
        // Shared pool = sum of all player max HPs.  Accumulated in spawn_players.
        self.shared_shield = .{ .hp = 0 };
        std.log.info("shared party pool: {}/{}", .{ self.shared_hp.current, self.shared_hp.max });
        try self.spawn_wave(wave);
    }

    fn spawn_players(self: *Session) !void {
        // Reset shared pool before accumulating player HPs.
        self.shared_hp = .{ .current = 0, .max = 0 };
        for (&self.players) |*p| {
            if (!p.occupied or !p.connected) continue;
            const d = waves.class_defaults(p.class);
            const e = self.world.create_entity();
            p.entity = e;
            // Player entities carry no Health/Shield — HP lives in shared_hp.
            self.world.add_component(e, c.Class{ .tag = p.class });
            self.world.add_component(e, c.Team{ .id = .players });
            self.world.add_component(e, c.Owner{ .player_id = p.player_id });
            self.world.add_component(e, c.PlayerMarker{});
            // Accumulate into the shared party HP pool.
            const new_max = @as(u32, self.shared_hp.max) + @as(u32, d.max_hp);
            self.shared_hp.max = @intCast(@min(new_max, @as(u32, std.math.maxInt(u16))));
            self.shared_hp.current = self.shared_hp.max;
        }
    }

    fn spawn_wave(self: *Session, wave: *const waves.Wave) !void {
        std.log.info("spawning wave: {s} ({} enemies)", .{ wave.label, wave.entries.len });
        for (wave.entries) |entry| {
            const d = waves.resolve_stats(entry.class, entry.stats);
            const e = self.world.create_entity();
            self.world.add_component(e, c.Health{ .current = d.max_hp, .max = d.max_hp });
            self.world.add_component(e, c.Shield{ .hp = 0 });
            self.world.add_component(e, c.Class{ .tag = entry.class });
            self.world.add_component(e, c.Team{ .id = .enemies });
            self.world.add_component(e, c.EnemyMarker{});
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

    /// Clear the action pool, reset the round timer, and tell all clients to
    /// clear their pending combos.
    fn reset_round(self: *Session) void {
        for (&self.action_pool) |*a| a.* = null;
        self.round_timer = self.round_duration;
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
                    var combo = c.ActionCombo{
                        .actions = [_]c.ActionChoice{.damage} ** c.MAX_COMBO_LEN,
                        .len = 1,
                    };
                    combo.actions[0] = p.action;
                    self.action_pool[player_id] = combo;
                    std.log.debug("player {} action (single): {s}", .{ player_id, @tagName(p.action) });
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
            .reconnect => {},
            else => {},
        }
    }

    fn resolve_round(self: *Session) !void {
        // Count player actions — each slot in every player's combo contributes.
        var damage_pool: u16 = 0;
        var shield_pool: u16 = 0;
        var heal_pool: u16 = 0;
        for (&self.action_pool) |maybe_combo| {
            const combo = maybe_combo orelse continue;
            for (combo.actions[0..combo.len]) |action| {
                switch (action) {
                    .damage => damage_pool += 1,
                    .shield => shield_pool += 1,
                    .heal => heal_pool += 1,
                }
            }
        }
        std.log.info("round resolve — dmg={} shld={} heal={}", .{ damage_pool, shield_pool, heal_pool });

        var enemy_buf: [64]ecs.Entity = undefined;
        var n_enemies: usize = 0;
        {
            var it = self.world.system_entity_sets[comptime GameWorld.system_index_of(EnemyTeam)].iterator(.{});
            while (it.next()) |u| {
                if (n_enemies < enemy_buf.len) {
                    enemy_buf[n_enemies] = @intCast(u);
                    n_enemies += 1;
                }
            }
        }

        if (damage_pool > 0) {
            for (enemy_buf[0..n_enemies]) |e| {
                const hp = self.world.get_component(e, c.Health);
                const sh = self.world.get_component(e, c.Shield);
                const dealt = logic.resolve_damage_pool(hp, sh, damage_pool);
                try self.broadcast_action_result(.{
                    .tag = .damage,
                    .actor_entity = std.math.maxInt(u32),
                    .target_entity = e,
                    .value = dealt,
                });
                if (logic.is_dead(hp.*)) {
                    std.log.info("enemy entity {} killed by damage pool", .{e});
                    self.kill_entity(e);
                    try self.broadcast_action_result(.{
                        .tag = .death,
                        .actor_entity = std.math.maxInt(u32),
                        .target_entity = e,
                        .value = 0,
                    });
                }
            }
        }

        // 2. Shield pool → shared party shield buffer.
        if (shield_pool > 0) {
            logic.resolve_shield_pool(&self.shared_shield, shield_pool);
            try self.broadcast_action_result(.{
                .tag = .shield,
                .actor_entity = std.math.maxInt(u32),
                .target_entity = std.math.maxInt(u32),
                .value = shield_pool * logic.ACTION_EFFECT_VALUE,
            });
        }

        // 3. Heal pool → shared party HP pool.
        if (heal_pool > 0) {
            logic.resolve_heal_pool(&self.shared_hp, heal_pool);
            try self.broadcast_action_result(.{
                .tag = .heal,
                .actor_entity = std.math.maxInt(u32),
                .target_entity = std.math.maxInt(u32),
                .value = heal_pool * logic.ACTION_EFFECT_VALUE,
            });
        }

        // 4. Enemy intent → shared party pool (shield absorbs first, then HP).
        // Each living enemy deals 1 damage to the shared pool.
        const living_enemy_count: u16 = blk: {
            var count: u16 = 0;
            var it = self.world.system_entity_sets[comptime GameWorld.system_index_of(EnemyTeam)].iterator(.{});
            while (it.next()) |_| count += 1;
            break :blk count;
        };
        if (living_enemy_count > 0) {
            const intent = logic.compute_enemy_intent(living_enemy_count);
            const hp_dmg = logic.apply_enemy_intent(&self.shared_hp, &self.shared_shield, intent);
            if (hp_dmg > 0) {
                try self.broadcast_action_result(.{
                    .tag = .damage,
                    .actor_entity = std.math.maxInt(u32),
                    .target_entity = std.math.maxInt(u32),
                    .value = hp_dmg,
                });
            }
            if (logic.is_dead(self.shared_hp)) {
                std.log.info("shared party pool depleted — enemies win", .{});
                try self.broadcast_action_result(.{
                    .tag = .death,
                    .actor_entity = std.math.maxInt(u32),
                    .target_entity = std.math.maxInt(u32),
                    .value = 0,
                });
            }
        }
    }

    /// Returns true if `entity` is a living enemy (tracked by EnemyTeam).
    /// Player entities are never removed from PlayerTeam; use shared_hp for their death.
    fn entity_is_alive(self: *const Session, entity: ecs.Entity) bool {
        return self.world.system_entity_sets[comptime GameWorld.system_index_of(EnemyTeam)].isSet(entity);
    }

    fn kill_entity(self: *Session, entity: ecs.Entity) void {
        self.world.destroy_entity(entity);
    }

    fn check_win(self: *Session) !void {
        const ei = comptime GameWorld.system_index_of(EnemyTeam);
        const enemies_alive = self.world.system_entity_sets[ei].count();

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
        } else if (logic.is_dead(self.shared_hp)) {
            std.log.info("shared party pool depleted — enemies win", .{});
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

        // Pass 1: player entities (no Health/Shield component — use shared pool).
        const pm_arr = &self.world.component_arrays.player_marker;
        for (pm_arr.index_to_entity[0..pm_arr.size]) |e| {
            if (snap.entity_count >= proto.MAX_ENTITIES_WIRE) break;
            const cl = self.world.get_component(e, c.Class);
            const own = self.world.get_component(e, c.Owner).player_id;
            const combo_len: u8 = if (self.action_pool[own]) |combo| combo.len else 0;
            const combo_actions = if (combo_len > 0)
                self.action_pool[own].?.actions
            else
                [_]c.ActionChoice{.damage} ** c.MAX_COMBO_LEN;

            snap.entities[snap.entity_count] = .{
                .entity = e,
                .slot = snap.entity_count,
                // Every player entity snapshot carries the shared pool values so
                // the client can read HP/shield from whichever entity it picks.
                .hp_current = self.shared_hp.current,
                .hp_max = self.shared_hp.max,
                .shield_hp = self.shared_shield.hp,
                .class = cl.tag,
                .team = .players,
                .owner = own,
                .combo_len = combo_len,
                .combo_actions = combo_actions,
            };
            snap.entity_count += 1;
        }

        // Pass 2: enemy entities (still have Health/Shield components).
        const health_arr = &self.world.component_arrays.health;
        for (health_arr.index_to_entity[0..health_arr.size]) |e| {
            if (snap.entity_count >= proto.MAX_ENTITIES_WIRE) break;
            // Skip any entity that also has a PlayerMarker — they were emitted above.
            if (self.world.component_arrays.player_marker.has(e)) continue;
            const hp = self.world.get_component(e, c.Health);
            const sh = self.world.get_component(e, c.Shield);
            const cl = self.world.get_component(e, c.Class);
            const tm = self.world.get_component(e, c.Team);

            snap.entities[snap.entity_count] = .{
                .entity = e,
                .slot = snap.entity_count,
                .hp_current = hp.current,
                .hp_max = hp.max,
                .shield_hp = sh.hp,
                .class = cl.tag,
                .team = tm.id,
                .owner = 0xFF,
                .combo_len = 0,
                .combo_actions = [_]c.ActionChoice{.damage} ** c.MAX_COMBO_LEN,
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

// ---------------------------------------------------------------------------
// Internal helpers — comptime world configuration
// ---------------------------------------------------------------------------

fn set_world_system_signatures(world: *GameWorld) void {
    // PlayerTeam: requires PlayerMarker, which only player entities carry.
    //   Player entities have no Health/Shield — HP lives in shared_hp/shared_shield.
    // EnemyTeam:  requires EnemyMarker + Health/Shield (enemies still die individually).
    {
        var sig = @import("ecs_zig").Signature.initEmpty();
        sig.set(GameWorld.component_type(c.Class));
        sig.set(GameWorld.component_type(c.Team));
        sig.set(GameWorld.component_type(c.Owner));
        sig.set(GameWorld.component_type(c.PlayerMarker));
        world.set_system_signature(PlayerTeam, sig);
    }
    {
        var sig = @import("ecs_zig").Signature.initEmpty();
        sig.set(GameWorld.component_type(c.Health));
        sig.set(GameWorld.component_type(c.Shield));
        sig.set(GameWorld.component_type(c.Class));
        sig.set(GameWorld.component_type(c.Team));
        sig.set(GameWorld.component_type(c.EnemyMarker));
        world.set_system_signature(EnemyTeam, sig);
    }
}
