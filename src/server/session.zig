//! Game session: lobby management, authoritative game loop, enemy AI.
//!
//! One Session instance per active game room.  The session owns:
//!   - The ECS World (all game entities and components)
//!   - The per-player connection transports
//!   - The state machine (lobby → playing → ended)
//!
//! ## ECS layout
//!
//! Components: Class, Team, Owner, PlayerMarker (player entities)
//!             Class, Team, EnemyMarker            (enemy entities)
//! Systems:
//!   - PlayerTeam — tracks every entity whose Team.id == .players
//!   - EnemyTeam  — tracks every entity whose Team.id == .enemies
//!
//! Neither side carries Health components in the ECS.  All HP lives in
//! two session-level fields:
//!   - `shared_hp`       — party pool (players)
//!   - `shared_enemy_hp` — enemy pool
//!
//! System signatures are set at world-init time in `start_game_wave`.
//! Entities are never destroyed during play; system sets remain stable.
//!
//! ## Round-based game loop
//!
//! All actors share a single countdown timer (`round_timer`).  During each
//! round players submit an `ActionChoice` (damage / shield / heal) which is
//! recorded in `action_pool`.  When the timer expires `resolve_round()` is
//! called, which:
//!   1. Applies the *player damage pool* to the shared enemy HP pool.
//!   2. Applies the *player shield pool* to the shared party shield buffer.
//!   3. Applies the *player heal pool* to the shared party HP pool.
//!   4. Applies *enemy intent* to the shared party pool (shield absorbs first).
//!   5. Broadcasts all action results and checks win/loss.
//!
//! Players win when `shared_enemy_hp.current` reaches 0.
//! Enemies win when `shared_hp.current` reaches 0.
//!
//! The round timer duration is configurable per session (`round_duration`) and
//! is sent to clients at game start so they can display a countdown.

const std = @import("std");
const ecs = @import("ecs_zig");
const shared = @import("shared");
const c = shared.components;
const proto = shared.protocol;
const logic = shared.game_logic;
const balance = shared.balance;
const waves = shared.waves;
const dbg = @import("debug_zig");

const ws_server = @import("net/ws_server.zig");

pub const TickZones = enum { drain, round, broadcast, check_win };

pub const PlayerTeam = struct {};
pub const EnemyTeam = struct {};

pub const GameWorld = ecs.World(
    .{
        .kind = c.Kind,
        .statblock = c.Statblock,
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
    round_timer: f32 = logic.ROUND_DURATION_DEFAULT_S,
    round_duration: f32 = logic.ROUND_DURATION_DEFAULT_S,
    shared_hp: c.Health = .{ .current = 0, .max = 0 },
    shared_enemy_hp: c.Health = .{ .current = 0, .max = 0 },
    action_pool: [MAX_PLAYERS]?c.ActionCombo,
    /// Per-enemy combos generated at round start by the AI.
    /// Indexed by enemy order in the ECS enemy_marker component array.
    enemy_combos: [proto.MAX_ENTITIES_WIRE]?c.ActionCombo =
        [_]?c.ActionCombo{null} ** proto.MAX_ENTITIES_WIRE,
    /// Enemy intent chosen at round start; broadcast every frame so clients
    /// can display it during the countdown.
    pending_enemy_intent: logic.EnemyIntent = .{ .damage_per_player = 0, .element = null },
    /// Damage-over-time stacks on the player party, indexed by Element ordinal
    /// (0=fire,1=earth,2=wind,3=water).  Sticky: persist until game ends.
    player_dot_stacks: [4]u16 = [_]u16{0} ** 4,
    /// DoT stacks on the enemy side; same layout.
    enemy_dot_stacks: [4]u16 = [_]u16{0} ** 4,
    /// Number of rounds resolved so far in the current game.
    /// Reset to 0 on wave start; incremented in reset_round before generate_enemy_combos.
    /// Even = DoT phase; odd = cleanse phase.
    round_count: u32 = 0,
    /// PRNG seeded once at init; drives enemy AI randomness.
    prng: std.Random.DefaultPrng,
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
        const seed = std.crypto.random.int(u64);
        return Session{
            .allocator = allocator,
            .join_code = join_code,
            .players = players,
            .world = world,
            .action_pool = [_]?c.ActionCombo{null} ** MAX_PLAYERS,
            .prng = std.Random.DefaultPrng.init(seed),
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

    pub fn start_game(self: *Session, wave_label: []const u8) !void {
        const wave = waves.find_wave(wave_label) orelse waves.find_wave("wave_01_basic").?;
        try self.start_game_wave(wave);
    }

    pub fn start_game_wave(self: *Session, wave: *const waves.Wave) !void {
        self.world.deinit();
        self.world = try GameWorld.init(self.allocator);
        set_world_system_signatures(&self.world);
        for (&self.action_pool) |*a| a.* = @as(?c.ActionCombo, null);
        for (&self.enemy_combos) |*a| a.* = null;
        self.player_dot_stacks = [_]u16{0} ** 4;
        self.enemy_dot_stacks = [_]u16{0} ** 4;
        self.tick_count = 0;
        self.round_count = 0;

        self.phase = .playing;
        self.current_wave = wave;
        self.round_timer = self.round_duration;
        std.log.info("game start — wave: {s} round_duration={d:.1}s", .{ wave.label, self.round_duration });
        try self.spawn_players();
        std.log.info("shared party pool: {}/{}", .{ self.shared_hp.current, self.shared_hp.max });
        try self.spawn_wave(wave);
        // Choose intent and enemy combos for the very first round.
        self.generate_enemy_combos();
        self.pending_enemy_intent = self.generate_enemy_intent();
    }

    fn spawn_players(self: *Session) !void {
        self.shared_hp = .{ .current = 0, .max = 0 };
        for (&self.players) |*p| {
            if (!p.occupied or !p.connected) continue;
            const e = self.world.create_entity();
            p.entity = e;
            self.world.add_component(e, c.Kind{ .tag = .player });
            self.world.add_component(e, p.statblock);
            self.world.add_component(e, c.Team{ .id = .players });
            self.world.add_component(e, c.Owner{ .player_id = p.player_id });
            self.world.add_component(e, c.PlayerMarker{});
            const new_max = @as(u32, self.shared_hp.max) + @as(u32, p.statblock.hp);
            self.shared_hp.max = @intCast(@min(new_max, @as(u32, std.math.maxInt(u16))));
            self.shared_hp.current = self.shared_hp.max;
        }
    }

    fn spawn_wave(self: *Session, wave: *const waves.Wave) !void {
        std.log.info("spawning wave: {s} ({} enemies)", .{ wave.label, wave.entries.len });
        self.shared_enemy_hp = .{ .current = 0, .max = 0 };
        for (wave.entries) |entry| {
            const e = self.world.create_entity();
            self.world.add_component(e, c.Kind{ .tag = entry.kind });
            self.world.add_component(e, entry.stats);
            self.world.add_component(e, c.Team{ .id = .enemies });
            self.world.add_component(e, c.EnemyMarker{});
            const new_max = @as(u32, self.shared_enemy_hp.max) + @as(u32, entry.stats.hp);
            self.shared_enemy_hp.max = @intCast(@min(new_max, @as(u32, std.math.maxInt(u16))));
            self.shared_enemy_hp.current = self.shared_enemy_hp.max;
        }
        std.log.info("shared enemy pool: {}/{}", .{ self.shared_enemy_hp.current, self.shared_enemy_hp.max });
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

    fn reset_round(self: *Session) void {
        for (&self.action_pool) |*a| a.* = null;
        self.round_timer = self.round_duration;
        self.round_count += 1;
        // Generate next round's AI before broadcasting round_reset so the
        // intent is available in the very first broadcast after reset.
        self.generate_enemy_combos();
        self.pending_enemy_intent = self.generate_enemy_intent();
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
                    // Late joiner: spawn their entity, extend the HP pool max
                    // only, then send them a game_start so their client enters
                    // game phase.  Existing players are unaffected — no
                    // lobby_update is broadcast.
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
                    try self.start_game("wave_01_basic");
                    try self.broadcast_game_start("wave_01_basic");
                }
            },
            .choose_action => {
                // Legacy single-action path removed; combo-only protocol.
                // Consume the payload byte so the stream stays aligned.
                _ = try proto.decode_choose_action(fbs.reader());
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
                if (self.phase == .ended) {
                    std.log.warn("player {} sent set_statblock in ended phase — ignored", .{player_id});
                } else if (player_id < MAX_PLAYERS) {
                    self.players[player_id].statblock = p.statblock;
                    std.log.info("player {} statblock updated hp={} atk={}", .{
                        player_id, p.statblock.hp, p.statblock.attack,
                    });
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

    /// Resolve one round: tally both sides, apply cleanses/DoT, then net and
    /// apply HP changes.  Order is significant — player offense, player heal,
    /// enemy offense, enemy heal — and matches the broadcast sequence clients
    /// rely on for floaters/animations.
    fn resolve_round(self: *Session) !void {
        var players = self.tally_players();
        var enemies = self.tally_enemies();

        self.apply_cleanses(&players, &enemies);
        self.apply_dot_triggers(&players, &enemies);

        try self.apply_player_offense(&players, &enemies);
        try self.apply_player_heal(players);
        try self.apply_enemy_offense(&players, &enemies);
        try self.apply_enemy_heal(enemies);
    }

    /// Step 1: tally every submitted player combo into a SideTally.
    fn tally_players(self: *Session) logic.SideTally {
        var tally = logic.SideTally{};
        for (&self.action_pool, 0..) |maybe_combo, player_idx| {
            const combo = maybe_combo orelse continue;
            logic.tally_combo(&tally, combo, self.players[player_idx].statblock);
        }
        return tally;
    }

    /// Step 2: tally every enemy combo (statblock from the ECS) into a
    /// SideTally, then fold the structured enemy intent into its damage pool.
    /// Structured intent is never elemental dmg+heal so it never triggers DoT.
    fn tally_enemies(self: *Session) logic.SideTally {
        var tally = logic.SideTally{};
        const em_arr = &self.world.component_arrays.enemy_marker;
        for (self.enemy_combos[0..em_arr.size], 0..) |maybe_combo, enemy_idx| {
            const combo = maybe_combo orelse continue;
            const enemy_entity = em_arr.index_to_entity[enemy_idx];
            const sb = self.world.get_component(enemy_entity, c.Statblock).*;
            logic.tally_combo(&tally, combo, sb);
        }
        if (!logic.is_dead(self.shared_enemy_hp)) {
            const ik = @intFromEnum(c.element_key(self.pending_enemy_intent.element));
            tally.damage_by_key[ik] +|= self.pending_enemy_intent.damage_per_player;
        }
        return tally;
    }

    /// Step 2.5: each cleanse combo removes stacks of the matching DoT element
    /// from its own side, unconditionally.  Runs before DoT-tick injection so
    /// this round's ticks are reduced accordingly.
    fn apply_cleanses(self: *Session, players: *logic.SideTally, enemies: *logic.SideTally) void {
        for (0..c.Element.size) |i| {
            self.player_dot_stacks[i] -|= players.cleanse_by_el[i];
            self.enemy_dot_stacks[i] -|= enemies.cleanse_by_el[i];
        }
    }

    /// Steps 3+4: a DoT trigger fires for element i when the withheld elemental
    /// damage survives the opponent's elemental shields; on success the pending
    /// stacks are placed on the opponent.  Then all live stacks (including the
    /// new ones) inject flat tick damage into the damage pools so shields net
    /// against the combined total in the application steps.
    fn apply_dot_triggers(self: *Session, players: *logic.SideTally, enemies: *logic.SideTally) void {
        // Step 3: peek-net stack placement.
        for (0..c.Element.size) |i| {
            const k: usize = i + 1; // element keys are 1-indexed; 0 = none

            const player_dot_net = players.dot_dmg_by_key[k] -| enemies.shield_by_key[k];
            if (player_dot_net > 0) {
                self.enemy_dot_stacks[i] +|= players.dot_stacks_pending[i];
            }

            const enemy_dot_net = enemies.dot_dmg_by_key[k] -| players.shield_by_key[k];
            if (enemy_dot_net > 0) {
                self.player_dot_stacks[i] +|= enemies.dot_stacks_pending[i];
            }
        }

        // Step 4: inject DoT ticks into the damage pools.
        for (0..c.Element.size) |i| {
            const k: usize = i + 1;
            players.damage_by_key[k] +|= self.enemy_dot_stacks[i] * balance.basic.dot_tick;
            enemies.damage_by_key[k] +|= self.player_dot_stacks[i] * balance.basic.dot_tick;
        }
    }

    /// Step 5a: player damage (including DoT ticks on enemy) net against enemy
    /// shields → enemy HP; broadcast each elemental hit and a death if depleted.
    fn apply_player_offense(self: *Session, players: *logic.SideTally, enemies: *logic.SideTally) !void {
        for (0..c.ElementKey.size) |k| {
            const net = players.damage_by_key[k] -| enemies.shield_by_key[k];
            if (net == 0) continue;
            const dealt = logic.resolve_damage_pool(&self.shared_enemy_hp, net, logic.key_to_element(k));
            if (dealt > 0) {
                try self.broadcast_action_result(.{
                    .tag = .damage,
                    .actor_entity = std.math.maxInt(u32),
                    .target_entity = std.math.maxInt(u32),
                    .value = dealt,
                });
            }
        }
        if (logic.is_dead(self.shared_enemy_hp)) {
            std.log.info("shared enemy pool depleted — players win", .{});
            try self.broadcast_action_result(.{
                .tag = .death,
                .actor_entity = std.math.maxInt(u32),
                .target_entity = std.math.maxInt(u32),
                .value = 0,
            });
        }
    }

    /// Step 5b: apply the player heal pool to the shared party HP.
    fn apply_player_heal(self: *Session, players: logic.SideTally) !void {
        if (players.heal_pool == 0) return;
        logic.resolve_heal_pool(&self.shared_hp, players.heal_pool);
        try self.broadcast_action_result(.{
            .tag = .heal,
            .actor_entity = std.math.maxInt(u32),
            .target_entity = std.math.maxInt(u32),
            .value = players.heal_pool,
        });
    }

    /// Step 5c: enemy damage (including DoT ticks on players) net against player
    /// shields → party HP; broadcast each hit and a death if depleted.  Skipped
    /// entirely if the enemies were already wiped out this round.
    fn apply_enemy_offense(self: *Session, players: *logic.SideTally, enemies: *logic.SideTally) !void {
        if (logic.is_dead(self.shared_enemy_hp)) return;
        for (0..c.ElementKey.size) |k| {
            const net = enemies.damage_by_key[k] -| players.shield_by_key[k];
            if (net == 0) continue;
            const dealt = logic.resolve_damage_pool(&self.shared_hp, net, logic.key_to_element(k));
            if (dealt > 0) {
                try self.broadcast_action_result(.{
                    .tag = .damage,
                    .actor_entity = std.math.maxInt(u32),
                    .target_entity = std.math.maxInt(u32),
                    .value = dealt,
                });
            }
        }
        if (logic.is_dead(self.shared_hp)) {
            std.log.info("shared party pool depleted — anemies win", .{});
            try self.broadcast_action_result(.{
                .tag = .death,
                .actor_entity = std.math.maxInt(u32),
                .target_entity = std.math.maxInt(u32),
                .value = 0,
            });
        }
    }

    /// Step 5d: apply the enemy heal pool to the shared party HP.
    fn apply_enemy_heal(self: *Session, enemies: logic.SideTally) !void {
        if (enemies.heal_pool == 0) return;
        logic.resolve_heal_pool(&self.shared_hp, enemies.heal_pool);
        try self.broadcast_action_result(.{
            .tag = .heal,
            .actor_entity = std.math.maxInt(u32),
            .target_entity = std.math.maxInt(u32),
            .value = enemies.heal_pool,
        });
    }

    /// Count living enemies (by ECS array size — enemies are never removed, just die via HP).
    fn count_living_enemies(self: *const Session) u16 {
        return @intCast(self.world.component_arrays.enemy_marker.size);
    }

    /// Choose a random element (or null) for the enemy intent this round.
    fn generate_enemy_intent(self: *Session) logic.EnemyIntent {
        const living = self.count_living_enemies();
        const roll = self.prng.random().intRangeAtMost(u8, 0, 4);
        const element: ?c.Element = if (roll == 0) null else @enumFromInt(roll - 1);
        return logic.compute_enemy_intent(living, element);
    }

    /// Generate the enemy combo for the current round.
    ///
    /// Pattern is chosen from balance.enemy_sequences per element, cycling by
    /// round_count.  All enemies share the same combo each round.
    /// Null-element enemies use the fire sequence (index 0) as default.
    fn generate_enemy_combos(self: *Session) void {
        const em_arr = &self.world.component_arrays.enemy_marker;
        // Use fire sequence (0) as the default for all enemies for now.
        // Future: per-entity element drives which sequence to use.
        const seq = balance.enemy_sequences[0];
        const pattern_idx = seq[self.round_count % seq.len];
        const pattern = balance.enemy_patterns[pattern_idx];
        for (0..em_arr.size) |i| {
            self.enemy_combos[i] = .{ .slots = pattern.slots, .len = pattern.len };
        }
    }

    fn check_win(self: *Session) !void {
        if (logic.is_dead(self.shared_enemy_hp)) {
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

    /// Spawn an ECS entity for a player who joined while the game is in progress.
    /// Extends shared_hp.max by the player's statblock hp but leaves current unchanged,
    /// preserving the party's current health state.
    fn spawn_player_midgame(self: *Session, player_id: u8) !void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        const e = self.world.create_entity();
        slot.entity = e;
        self.world.add_component(e, c.Kind{ .tag = .player });
        self.world.add_component(e, slot.statblock);
        self.world.add_component(e, c.Team{ .id = .players });
        self.world.add_component(e, c.Owner{ .player_id = slot.player_id });
        self.world.add_component(e, c.PlayerMarker{});
        const new_max = @as(u32, self.shared_hp.max) + @as(u32, slot.statblock.hp);
        self.shared_hp.max = @intCast(@min(new_max, @as(u32, std.math.maxInt(u16))));
        std.log.info("player {} joined mid-game — party pool now {}/{}", .{
            player_id, self.shared_hp.current, self.shared_hp.max,
        });
    }

    /// Send a game_start message to a single player so their client transitions
    /// to game phase.  Used for late joiners while the session is already playing.
    fn send_game_start_to(self: *Session, player_id: u8) !void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        const t = slot.transport orelse return;
        const wave = self.current_wave orelse return;
        var buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        var gs_msg = proto.GameStart{
            .wave_label = [_]u8{0} ** 32,
            .wave_label_len = @intCast(@min(wave.label.len, 32)),
            .player_id = slot.player_id,
            .round_duration = self.round_duration,
        };
        @memcpy(gs_msg.wave_label[0..gs_msg.wave_label_len], wave.label[0..gs_msg.wave_label_len]);
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
                .grid_col = 0,
                .grid_row = 0,
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
        const intent_element_byte: u8 = if (self.pending_enemy_intent.element) |el|
            @intFromEnum(el)
        else
            proto.GameState.INTENT_ELEMENT_NONE;

        var snap = proto.GameState{
            .tick = self.tick_count,
            .round_timer = @max(self.round_timer, 0.0),
            .entity_count = 0,
            .entities = [_]proto.EntitySnapshot{proto.EntitySnapshot.blank} ** proto.MAX_ENTITIES_WIRE,
            .players = .{
                .hp_current = self.shared_hp.current,
                .hp_max = self.shared_hp.max,
            },
            .enemies = .{
                .hp_current = self.shared_enemy_hp.current,
                .hp_max = self.shared_enemy_hp.max,
            },
            .enemy_intent_damage = self.pending_enemy_intent.damage_per_player,
            .enemy_intent_element = intent_element_byte,
            .player_dot_stacks = .{
                @intCast(@min(self.player_dot_stacks[0], 255)),
                @intCast(@min(self.player_dot_stacks[1], 255)),
                @intCast(@min(self.player_dot_stacks[2], 255)),
                @intCast(@min(self.player_dot_stacks[3], 255)),
            },
            .enemy_dot_stacks = .{
                @intCast(@min(self.enemy_dot_stacks[0], 255)),
                @intCast(@min(self.enemy_dot_stacks[1], 255)),
                @intCast(@min(self.enemy_dot_stacks[2], 255)),
                @intCast(@min(self.enemy_dot_stacks[3], 255)),
            },
        };

        const pm_arr = &self.world.component_arrays.player_marker;
        for (pm_arr.index_to_entity[0..pm_arr.size]) |e| {
            if (snap.entity_count >= proto.MAX_ENTITIES_WIRE) break;
            const kd = self.world.get_component(e, c.Kind);
            const own = self.world.get_component(e, c.Owner).player_id;
            const combo_len: u8 = if (self.action_pool[own]) |combo| combo.len else 0;
            const combo_slots = if (combo_len > 0)
                self.action_pool[own].?.slots
            else
                [_]c.ComboSlot{.{ .action = .damage }} ** c.MAX_COMBO_LEN;

            snap.entities[snap.entity_count] = .{
                .entity = e,
                .kind = kd.tag,
                .team = .players,
                .owner = own,
                .combo_len = combo_len,
                .combo_slots = combo_slots,
            };
            snap.entity_count += 1;
        }

        const em_arr = &self.world.component_arrays.enemy_marker;
        for (em_arr.index_to_entity[0..em_arr.size], 0..) |e, i| {
            if (snap.entity_count >= proto.MAX_ENTITIES_WIRE) break;
            const kd = self.world.get_component(e, c.Kind);
            const enemy_combo = self.enemy_combos[i];
            const combo_len: u8 = if (enemy_combo) |ec| ec.len else 0;
            const combo_slots = if (enemy_combo) |ec| ec.slots else [_]c.ComboSlot{.{ .action = .damage }} ** c.MAX_COMBO_LEN;

            snap.entities[snap.entity_count] = .{
                .entity = e,
                .kind = kd.tag,
                .team = .enemies,
                .owner = 0xFF,
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
    {
        var sig = @import("ecs_zig").Signature.initEmpty();
        sig.set(GameWorld.component_type(c.Kind));
        sig.set(GameWorld.component_type(c.Team));
        sig.set(GameWorld.component_type(c.Owner));
        sig.set(GameWorld.component_type(c.PlayerMarker));
        world.set_system_signature(PlayerTeam, sig);
    }
    {
        var sig = @import("ecs_zig").Signature.initEmpty();
        sig.set(GameWorld.component_type(c.Kind));
        sig.set(GameWorld.component_type(c.Team));
        sig.set(GameWorld.component_type(c.EnemyMarker));
        world.set_system_signature(EnemyTeam, sig);
    }
}
