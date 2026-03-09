//! Game session: lobby management, authoritative game loop, enemy AI.
//!
//! One Session instance per active game room.  The session owns:
//!   - The ECS World (all game entities and components)
//!   - The per-player connection transports
//!   - The state machine (lobby → playing → ended)
//!
//! The game loop runs on a dedicated thread (spawned by main.zig) at a fixed
//! tick rate (TICK_HZ).  All network I/O is non-blocking: incoming client
//! messages are pushed into a per-player queue by the websocket handler
//! thread and drained each tick.

const std = @import("std");
const ecs = @import("ecs_zig");
const shared = @import("shared");
const c = shared.components;
const proto = shared.protocol;
const logic = shared.game_logic;
const waves = shared.waves;

const ws_server = @import("net/ws_server.zig");

// ---------------------------------------------------------------------------
// ECS World definition
// ---------------------------------------------------------------------------
//
// Both the server and client must instantiate World with the exact same
// component tuple so comptime bit indices match.

pub const GameWorld = ecs.World(
    .{
        .grid_pos = c.GridPos,
        .health = c.Health,
        .speed = c.Speed,
        .class = c.Class,
        .team = c.Team,
        .owner = c.Owner,
        .stats = c.Stats,
        .action_state = c.ActionState,
    },
    .{
        .atb = AtbSystem,
        .ai = AiSystem,
        .effect = EffectSystem,
    },
);

// ---------------------------------------------------------------------------
// Systems (state structs only; logic in free functions called via each())
// ---------------------------------------------------------------------------

pub const AtbSystem = struct { dt: f32 = 0 };
pub const AiSystem = struct {};
pub const EffectSystem = struct { dt: f32 = 0 };

// ---------------------------------------------------------------------------
// Per-entity active effects (stored separately from ECS, indexed by entity)
// ---------------------------------------------------------------------------

pub const MAX_EFFECTS_PER_ENTITY: usize = 4;
pub const EffectSlot = struct {
    effects: [MAX_EFFECTS_PER_ENTITY]c.ActiveEffect = undefined,
    count: usize = 0,
};

// ---------------------------------------------------------------------------
// Player slot
// ---------------------------------------------------------------------------

pub const MAX_PLAYERS = proto.MAX_PLAYERS;

pub const PlayerSlot = struct {
    occupied: bool = false,
    connected: bool = false,
    player_id: u8,
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: u8 = 0,
    class: c.ClassTag = .fighter,
    ready: bool = false,
    entity: ecs.Entity = std.math.maxInt(ecs.Entity),
    transport: ?shared.Transport = null,
    /// Lock protecting `msg_queue` (written by WS handler, read by tick thread).
    queue_lock: std.Thread.Mutex = .{},
    msg_queue: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator = undefined,
};

// ---------------------------------------------------------------------------
// Session state machine
// ---------------------------------------------------------------------------

pub const SessionPhase = enum { lobby, playing, ended };

pub const Session = struct {
    allocator: std.mem.Allocator,
    join_code: [6]u8,
    players: [MAX_PLAYERS]PlayerSlot,
    player_count: u8 = 0,
    phase: SessionPhase = .lobby,
    world: GameWorld,
    effects: [ecs.MAX_ENTITIES]EffectSlot,
    tick_count: u32 = 0,
    current_wave: ?*const waves.Wave = null,
    /// All living character entities (player + enemy) for quick iteration.
    living: std.ArrayListUnmanaged(ecs.Entity) = .empty,

    pub fn init(allocator: std.mem.Allocator, join_code: [6]u8) !Session {
        var players: [MAX_PLAYERS]PlayerSlot = undefined;
        for (&players, 0..) |*p, i| {
            p.* = PlayerSlot{
                .player_id = @intCast(i),
                .allocator = allocator,
            };
        }
        return Session{
            .allocator = allocator,
            .join_code = join_code,
            .players = players,
            .world = try GameWorld.init(allocator),
            .effects = [_]EffectSlot{.{}} ** ecs.MAX_ENTITIES,
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

    // ------------------------------------------------------------------
    // Lobby
    // ------------------------------------------------------------------

    /// Register a new connection.  Returns the assigned player_id, or null
    /// if the session is full.
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

    /// Reconnect a previously-seen player_id.
    pub fn reconnect(self: *Session, player_id: u8, transport: shared.Transport) bool {
        if (player_id >= MAX_PLAYERS) return false;
        const p = &self.players[player_id];
        if (!p.occupied) return false;
        p.connected = true;
        p.transport = transport;
        return true;
    }

    pub fn disconnect(self: *Session, player_id: u8) void {
        if (player_id >= MAX_PLAYERS) return;
        self.players[player_id].connected = false;
        self.players[player_id].transport = null;
    }

    pub fn set_class(self: *Session, player_id: u8, class: c.ClassTag) void {
        if (player_id >= MAX_PLAYERS) return;
        self.players[player_id].class = class;
    }

    pub fn set_ready(self: *Session, player_id: u8, ready: bool) void {
        if (player_id >= MAX_PLAYERS) return;
        self.players[player_id].ready = ready;
    }

    /// Returns true when all connected players have readied up.
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

    // ------------------------------------------------------------------
    // Game start
    // ------------------------------------------------------------------

    pub fn start_game(self: *Session, wave_label: []const u8) !void {
        const wave = waves.find_wave(wave_label) orelse waves.find_wave("wave_01_basic").?;
        try self.start_game_wave(wave);
    }

    /// Start the game with an explicit wave pointer.  Used by tests to inject
    /// a minimal wave not present in waves.ALL_WAVES.
    pub fn start_game_wave(self: *Session, wave: *const waves.Wave) !void {
        self.phase = .playing;
        self.current_wave = wave;
        std.log.info("game start — wave: {s}", .{wave.label});
        try self.spawn_players();
        try self.spawn_wave(wave);
        self.register_system_signatures();
    }

    fn register_system_signatures(self: *Session) void {
        {
            var sig = ecs.Signature.initEmpty();
            sig.set(GameWorld.component_type(c.Speed));
            sig.set(GameWorld.component_type(c.ActionState));
            self.world.set_system_signature(AtbSystem, sig);
        }
        {
            var sig = ecs.Signature.initEmpty();
            sig.set(GameWorld.component_type(c.Team));
            sig.set(GameWorld.component_type(c.ActionState));
            sig.set(GameWorld.component_type(c.Class));
            self.world.set_system_signature(AiSystem, sig);
        }
        {
            // EffectSystem iterates all entities (uses a minimal sig).
            var sig = ecs.Signature.initEmpty();
            sig.set(GameWorld.component_type(c.Health));
            self.world.set_system_signature(EffectSystem, sig);
        }
    }

    fn spawn_players(self: *Session) !void {
        // Place players on a 3×4 grid (left side): cols 0-2, rows 0-2.
        // Up to 6 players fill top-to-bottom, left-to-right.
        const positions = [6]c.GridPos{
            .{ .col = 0, .row = 0 }, .{ .col = 1, .row = 0 }, .{ .col = 2, .row = 0 },
            .{ .col = 0, .row = 1 }, .{ .col = 1, .row = 1 }, .{ .col = 2, .row = 1 },
        };
        var idx: u8 = 0;
        for (&self.players) |*p| {
            if (!p.occupied or !p.connected) continue;
            const pos = positions[idx % 6];
            const d = waves.class_defaults(p.class);
            const e = self.world.create_entity();
            p.entity = e;
            self.world.add_component(e, c.GridPos{ .col = pos.col, .row = pos.row });
            self.world.add_component(e, c.Health{ .current = d.max_hp, .max = d.max_hp });
            self.world.add_component(e, c.Speed{ .gauge = 0, .rate = d.speed_base });
            self.world.add_component(e, c.Class{ .tag = p.class });
            self.world.add_component(e, c.Team{ .id = .players });
            self.world.add_component(e, c.Owner{ .player_id = p.player_id });
            self.world.add_component(e, c.Stats{
                .attack = d.attack,
                .defense = d.defense,
                .speed_base = d.speed_base,
                .max_hp = d.max_hp,
            });
            self.world.add_component(e, c.ActionState{ .tag = .idle });
            try self.living.append(self.allocator, e);
            idx += 1;
        }
    }

    fn spawn_wave(self: *Session, wave: *const waves.Wave) !void {
        std.log.info("spawning wave: {s} ({} enemies)", .{ wave.label, wave.entries.len });
        for (wave.entries) |entry| {
            const d = waves.resolve_stats(entry.class, entry.stats);
            const e = self.world.create_entity();
            self.world.add_component(e, c.GridPos{ .col = entry.grid_col, .row = entry.grid_row });
            self.world.add_component(e, c.Health{ .current = d.max_hp, .max = d.max_hp });
            self.world.add_component(e, c.Speed{ .gauge = 0, .rate = d.speed_base });
            self.world.add_component(e, c.Class{ .tag = entry.class });
            self.world.add_component(e, c.Team{ .id = .enemies });
            self.world.add_component(e, c.Stats{
                .attack = d.attack,
                .defense = d.defense,
                .speed_base = d.speed_base,
                .max_hp = d.max_hp,
            });
            self.world.add_component(e, c.ActionState{ .tag = .idle });
            try self.living.append(self.allocator, e);
        }
    }

    // ------------------------------------------------------------------
    // Tick
    // ------------------------------------------------------------------

    pub fn tick(self: *Session, dt: f32) !void {
        // Always drain queues so lobby messages (join_lobby, choose_class,
        // ready_up) are processed even before the game starts.
        try self.drain_queues();

        if (self.phase != .playing) return;

        self.tick_count += 1;

        // Tick ATB
        self.world.get_system(AtbSystem).dt = dt;
        self.world.each(AtbSystem, atb_step);

        // Check who just became ready to act and notify owners
        try self.notify_ready_actors();

        // Tick effects
        self.world.get_system(EffectSystem).dt = dt;
        self.world.each(EffectSystem, effect_step_trampoline);

        // Run enemy AI
        self.world.each(AiSystem, ai_step_trampoline);

        // Broadcast game state
        try self.broadcast_game_state();

        // Check win condition
        try self.check_win();
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
            // Copy out and clear
            var local_buf: [4096]u8 = undefined;
            const len = @min(data.len, local_buf.len);
            @memcpy(local_buf[0..len], data[0..len]);
            p.msg_queue.clearRetainingCapacity();
            p.queue_lock.unlock();

            // Process all messages in the copied buffer.
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
            .choose_action => {
                const p = try proto.decode_choose_action(fbs.reader());
                std.log.info("player {} action: {s} target={}", .{ player_id, @tagName(p.action), p.target_entity });
                try self.resolve_action(player_id, p);
            },
            .reconnect => {
                // Already handled at the connection layer; ignore here.
            },
            else => {},
        }
    }

    // ------------------------------------------------------------------
    // ATB / actor notification
    // ------------------------------------------------------------------

    fn notify_ready_actors(self: *Session) !void {
        for (self.living.items) |e| {
            if (!self.world.entity_manager.signatures[e].eql(ecs.Signature.initEmpty())) {
                const as = self.world.get_component(e, c.ActionState);
                const sp = self.world.get_component(e, c.Speed);
                if (as.tag == .idle and sp.gauge >= 1.0) {
                    as.tag = .charging;
                    const team = self.world.get_component(e, c.Team);
                    if (team.id == .players) {
                        // Notify the owning client
                        const owner = self.world.get_component(e, c.Owner);
                        try self.send_your_turn(owner.player_id, e);
                    }
                    // AI will act in ai_step on the next tick
                }
            }
        }
    }

    fn send_your_turn(self: *Session, player_id: u8, entity: ecs.Entity) !void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        const t = slot.transport orelse return;
        var buf: [16]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .your_turn, proto.YourTurn{ .entity = entity });
        try t.send(fbs.getWritten());
    }

    // ------------------------------------------------------------------
    // Action resolution
    // ------------------------------------------------------------------

    fn resolve_action(self: *Session, player_id: u8, msg: proto.ChooseAction) !void {
        const slot = &self.players[player_id];
        const actor = slot.entity;
        if (actor == std.math.maxInt(ecs.Entity)) return;

        const as = self.world.get_component(actor, c.ActionState);
        if (as.tag != .charging) return; // not this player's turn

        // Consume the turn unconditionally: reset ATB now so the entity
        // re-enters the idle→charging cycle even if the chosen target is
        // already dead (avoids permanent `.charging` lock-out).
        logic.reset_atb(self.world.get_component(actor, c.Speed));
        as.tag = .idle;

        const actor_stats = self.world.get_component(actor, c.Stats);
        const actor_class = self.world.get_component(actor, c.Class);
        const actor_pos = self.world.get_component(actor, c.GridPos);

        switch (msg.action) {
            .attack => {
                switch (actor_class.tag) {
                    .fighter => try self.resolve_fighter_attack(actor, actor_stats, msg.target_entity),
                    .mage => try self.resolve_mage_attack(actor, actor_stats, actor_pos.*),
                    .healer => try self.resolve_healer_heal(actor, actor_stats, actor_pos.*),
                    else => {},
                }
            },
            .defend => {
                try self.resolve_defend(actor, actor_class.tag, actor_pos.*);
            },
        }
    }

    fn resolve_fighter_attack(
        self: *Session,
        actor: ecs.Entity,
        actor_stats: *c.Stats,
        target_entity: u32,
    ) !void {
        // Find the target in living entities
        const target = self.find_living(target_entity) orelse return;
        const tgt_stats = self.world.get_component(target, c.Stats);
        const tgt_health = self.world.get_component(target, c.Health);

        const raw = logic.raw_damage(actor_stats.attack, tgt_stats.defense);
        const mit = logic.sum_mitigation(self.effects[target].effects[0..self.effects[target].count]);
        const dmg = logic.mitigated_damage(raw, mit);
        logic.apply_damage(tgt_health, dmg);
        std.log.debug("entity {} -> entity {}: {} dmg (raw={} mit={})", .{ actor, target, dmg, raw, mit });

        try self.broadcast_action_result(.{
            .tag = .damage,
            .actor_entity = actor,
            .target_entity = target,
            .value = dmg,
        });

        if (logic.is_dead(tgt_health.*)) {
            std.log.info("entity {} killed by entity {}", .{ target, actor });
            try self.kill_entity(target);
            try self.broadcast_action_result(.{
                .tag = .death,
                .actor_entity = actor,
                .target_entity = target,
                .value = 0,
            });
        }
    }

    fn resolve_mage_attack(
        self: *Session,
        actor: ecs.Entity,
        actor_stats: *c.Stats,
        actor_pos: c.GridPos,
    ) !void {
        // AoE 2×2 on enemy grid centred on actor_pos (clamped)
        var cells: [4]c.GridPos = undefined;
        const n = logic.aoe_cells_2x2(actor_pos.col, actor_pos.row, &cells);
        for (cells[0..n]) |cell| {
            const target = self.entity_at(cell, .enemies) orelse continue;
            const tgt_stats = self.world.get_component(target, c.Stats);
            const tgt_health = self.world.get_component(target, c.Health);
            const raw = logic.raw_damage(actor_stats.attack, tgt_stats.defense);
            const mit = logic.sum_mitigation(self.effects[target].effects[0..self.effects[target].count]);
            const dmg = logic.mitigated_damage(raw, mit);
            logic.apply_damage(tgt_health, dmg);
            std.log.debug("mage entity {} -> entity {}: {} dmg (aoe)", .{ actor, target, dmg });
            try self.broadcast_action_result(.{
                .tag = .damage,
                .actor_entity = actor,
                .target_entity = target,
                .value = dmg,
            });
            if (logic.is_dead(tgt_health.*)) {
                std.log.info("entity {} killed by mage entity {}", .{ target, actor });
                try self.kill_entity(target);
                try self.broadcast_action_result(.{
                    .tag = .death,
                    .actor_entity = actor,
                    .target_entity = target,
                    .value = 0,
                });
            }
        }
    }

    fn resolve_healer_heal(
        self: *Session,
        actor: ecs.Entity,
        actor_stats: *c.Stats,
        actor_pos: c.GridPos,
    ) !void {
        // AoE 2×2 on player grid
        var cells: [4]c.GridPos = undefined;
        const n = logic.aoe_cells_2x2(actor_pos.col, actor_pos.row, &cells);
        for (cells[0..n]) |cell| {
            const target = self.entity_at(cell, .players) orelse continue;
            const tgt_health = self.world.get_component(target, c.Health);
            const amount: u16 = actor_stats.attack;
            logic.apply_heal(tgt_health, amount);
            std.log.debug("healer entity {} -> entity {}: +{} hp", .{ actor, target, amount });
            try self.broadcast_action_result(.{
                .tag = .heal,
                .actor_entity = actor,
                .target_entity = target,
                .value = amount,
            });
        }
    }

    fn resolve_defend(
        self: *Session,
        actor: ecs.Entity,
        class: c.ClassTag,
        actor_pos: c.GridPos,
    ) !void {
        const as = self.world.get_component(actor, c.ActionState);
        as.tag = .defending;
        try self.broadcast_action_result(.{
            .tag = .defend,
            .actor_entity = actor,
            .target_entity = actor,
            .value = 0,
        });

        switch (class) {
            .fighter => {
                // Apply mitigation to 1×3 projection behind actor
                var cells: [3]c.GridPos = undefined;
                const n = logic.fighter_defend_cells(actor_pos.col, actor_pos.row, &cells);
                for (cells[0..n]) |cell| {
                    const target = self.entity_at(cell, .players) orelse continue;
                    self.add_effect(target, .{
                        .tag = .mitigation,
                        .duration = c.DEFEND_DURATION_S,
                        .magnitude = c.DEFEND_MITIGATION,
                    });
                }
                // Self-mitigation too
                self.add_effect(actor, .{
                    .tag = .mitigation,
                    .duration = c.DEFEND_DURATION_S,
                    .magnitude = c.DEFEND_MITIGATION,
                });
            },
            .mage, .healer => {
                // Self-mitigation only
                self.add_effect(actor, .{
                    .tag = .mitigation,
                    .duration = c.DEFEND_DURATION_S,
                    .magnitude = c.DEFEND_MITIGATION,
                });
            },
            else => {},
        }
    }

    fn add_effect(self: *Session, entity: ecs.Entity, effect: c.ActiveEffect) void {
        const slot = &self.effects[entity];
        if (slot.count < MAX_EFFECTS_PER_ENTITY) {
            slot.effects[slot.count] = effect;
            slot.count += 1;
        }
    }

    // ------------------------------------------------------------------
    // Entity queries
    // ------------------------------------------------------------------

    fn find_living(self: *Session, entity_id: u32) ?ecs.Entity {
        for (self.living.items) |e| {
            if (e == entity_id) return e;
        }
        return null;
    }

    fn entity_at(self: *Session, pos: c.GridPos, team: c.TeamId) ?ecs.Entity {
        for (self.living.items) |e| {
            const ep = self.world.get_component(e, c.GridPos);
            const et = self.world.get_component(e, c.Team);
            if (ep.col == pos.col and ep.row == pos.row and et.id == team) return e;
        }
        return null;
    }

    fn kill_entity(self: *Session, entity: ecs.Entity) !void {
        // Remove from living list
        for (self.living.items, 0..) |e, i| {
            if (e == entity) {
                _ = self.living.swapRemove(i);
                break;
            }
        }
        self.effects[entity].count = 0;
        self.world.destroy_entity(entity);
    }

    // ------------------------------------------------------------------
    // Effect tick
    // ------------------------------------------------------------------

    fn effect_step_trampoline(world: *GameWorld, entity: ecs.Entity, _: *EffectSystem) void {
        // We can't access `self` from an ECS callback directly; use a global.
        // Instead, effect ticking is done outside ECS in tick().
        _ = world;
        _ = entity;
    }

    pub fn tick_effects(self: *Session, dt: f32) void {
        for (self.living.items) |e| {
            const slot = &self.effects[e];
            slot.count = logic.tick_effects(slot.effects[0..slot.count], dt);
        }
    }

    // ------------------------------------------------------------------
    // AI
    // ------------------------------------------------------------------

    fn ai_step_trampoline(world: *GameWorld, entity: ecs.Entity, _: *AiSystem) void {
        _ = world;
        _ = entity;
        // AI is driven outside ECS in tick() to access full session context.
    }

    pub fn run_ai(self: *Session) !void {
        // Collect entities that are charging (ATB full) and are enemies.
        var actors: [32]ecs.Entity = undefined;
        var n_actors: usize = 0;
        for (self.living.items) |e| {
            const team = self.world.get_component(e, c.Team);
            if (team.id != .enemies) continue;
            const as = self.world.get_component(e, c.ActionState);
            if (as.tag != .charging) continue;
            if (n_actors < actors.len) {
                actors[n_actors] = e;
                n_actors += 1;
            }
        }

        for (actors[0..n_actors]) |actor| {
            // The actor may have been killed by an AoE from a previous actor
            // in this same batch (e.g. archers dealing self-splash).  Skip it.
            if (self.find_living(actor) == null) continue;

            const actor_class = self.world.get_component(actor, c.Class);
            const actor_stats = self.world.get_component(actor, c.Stats);
            const actor_pos = self.world.get_component(actor, c.GridPos);

            std.log.debug("AI entity {} ({s}) acting", .{ actor, @tagName(actor_class.tag) });
            switch (actor_class.tag) {
                .shaman => try self.ai_shaman(actor, actor_stats, actor_pos.*),
                .archer => try self.resolve_mage_attack(actor, actor_stats, actor_pos.*),
                else => try self.ai_attack_front_rank(actor, actor_stats),
            }

            // Re-check: AoE may have killed the actor itself.
            if (self.find_living(actor) == null) continue;
            logic.reset_atb(self.world.get_component(actor, c.Speed));
            self.world.get_component(actor, c.ActionState).tag = .idle;
        }
    }

    fn ai_attack_front_rank(self: *Session, actor: ecs.Entity, actor_stats: *c.Stats) !void {
        // Find the player entity with the lowest row index (front rank).
        // If none, pick any living player.
        var best: ?ecs.Entity = null;
        var best_row: u8 = 255;
        for (self.living.items) |e| {
            const t = self.world.get_component(e, c.Team);
            if (t.id != .players) continue;
            const p = self.world.get_component(e, c.GridPos);
            if (p.row < best_row) {
                best_row = p.row;
                best = e;
            }
        }
        if (best) |target| {
            try self.resolve_fighter_attack(actor, actor_stats, target);
        }
    }

    fn ai_shaman(self: *Session, actor: ecs.Entity, actor_stats: *c.Stats, actor_pos: c.GridPos) !void {
        // Heal lowest-HP ally if any are below 50%; otherwise attack.
        var lowest: ?ecs.Entity = null;
        var lowest_frac: f32 = 0.5; // only heal if below 50%
        for (self.living.items) |e| {
            const t = self.world.get_component(e, c.Team);
            if (t.id != .enemies) continue;
            const h = self.world.get_component(e, c.Health);
            const frac = @as(f32, @floatFromInt(h.current)) / @as(f32, @floatFromInt(h.max));
            if (frac < lowest_frac) {
                lowest_frac = frac;
                lowest = e;
            }
        }
        if (lowest != null) {
            // Heal 2×2 around self on enemy grid
            try self.resolve_enemy_heal(actor, actor_stats, actor_pos);
        } else {
            try self.resolve_mage_attack(actor, actor_stats, actor_pos);
        }
    }

    fn resolve_enemy_heal(
        self: *Session,
        actor: ecs.Entity,
        actor_stats: *c.Stats,
        actor_pos: c.GridPos,
    ) !void {
        var cells: [4]c.GridPos = undefined;
        const n = logic.aoe_cells_2x2(actor_pos.col, actor_pos.row, &cells);
        for (cells[0..n]) |cell| {
            const target = self.entity_at(cell, .enemies) orelse continue;
            const tgt_health = self.world.get_component(target, c.Health);
            const amount: u16 = actor_stats.attack;
            logic.apply_heal(tgt_health, amount);
            try self.broadcast_action_result(.{
                .tag = .heal,
                .actor_entity = actor,
                .target_entity = target,
                .value = amount,
            });
        }
    }

    // ------------------------------------------------------------------
    // Win condition
    // ------------------------------------------------------------------

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
            // Wave cleared
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
            // All waves cleared
            std.log.info("all waves cleared — players win", .{});
            try self.end_game(.players);
        } else if (players_alive == 0) {
            std.log.info("all players dead — enemies win", .{});
            try self.end_game(.enemies);
        }
    }

    fn end_game(self: *Session, winner: proto.WinnerId) !void {
        std.log.info("game over — winner: {s}", .{@tagName(winner)});
        self.phase = .ended;
        var buf: [8]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .game_over, proto.GameOver{ .winner = winner });
        try self.broadcast_raw(fbs.getWritten());
    }

    // ------------------------------------------------------------------
    // Broadcasts
    // ------------------------------------------------------------------

    pub fn broadcast_lobby_update(self: *Session) !void {
        // Build the shared player list once.
        var base = proto.LobbyUpdate{
            .join_code = self.join_code,
            .player_count = self.player_count,
            .players = [_]proto.PlayerInfo{std.mem.zeroes(proto.PlayerInfo)} ** proto.MAX_PLAYERS,
            .your_player_id = 0xFF,
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
        }
        // Send each connected player a copy personalised with their own id.
        for (&self.players) |*slot| {
            if (!slot.connected) continue;
            const t = slot.transport orelse continue;
            var msg = base;
            msg.your_player_id = slot.player_id;
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
                .your_player_id = slot.player_id,
            };
            @memcpy(gs_msg.wave_label[0..gs_msg.wave_label_len], wave_label[0..gs_msg.wave_label_len]);
            try proto.encode(fbs.writer(), .game_start, gs_msg);
            try t.send(fbs.getWritten());
        }
    }

    fn broadcast_game_state(self: *Session) !void {
        var snap = proto.GameState{
            .tick = self.tick_count,
            .entity_count = 0,
            .entities = [_]proto.EntitySnapshot{std.mem.zeroes(proto.EntitySnapshot)} ** proto.MAX_ENTITIES_WIRE,
        };

        for (self.living.items) |e| {
            if (snap.entity_count >= proto.MAX_ENTITIES_WIRE) break;
            const pos = self.world.get_component(e, c.GridPos);
            const hp = self.world.get_component(e, c.Health);
            const sp = self.world.get_component(e, c.Speed);
            const cl = self.world.get_component(e, c.Class);
            const tm = self.world.get_component(e, c.Team);
            const as = self.world.get_component(e, c.ActionState);
            const own: u8 = if (self.world.component_arrays.owner.has(e))
                self.world.get_component(e, c.Owner).player_id
            else
                0xFF;

            snap.entities[snap.entity_count] = .{
                .entity = e,
                .grid_col = pos.col,
                .grid_row = pos.row,
                .hp_current = hp.current,
                .hp_max = hp.max,
                .atb_gauge = sp.gauge,
                .action_state = as.tag,
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
            t.send(data) catch {}; // don't abort broadcast on one broken connection
        }
    }

    // ------------------------------------------------------------------
    // Incoming message queue (called from WS handler thread)
    // ------------------------------------------------------------------

    /// Thread-safe enqueue of a raw message for player `player_id`.
    pub fn enqueue_message(self: *Session, player_id: u8, data: []const u8) void {
        if (player_id >= MAX_PLAYERS) return;
        const slot = &self.players[player_id];
        slot.queue_lock.lock();
        defer slot.queue_lock.unlock();
        slot.msg_queue.appendSlice(slot.allocator, data) catch {};
    }
};

// ---------------------------------------------------------------------------
// ATB step (ECS callback)
// ---------------------------------------------------------------------------

fn atb_step(world: *GameWorld, entity: ecs.Entity, sys: *AtbSystem) void {
    const sp = world.get_component(entity, c.Speed);
    const as = world.get_component(entity, c.ActionState);
    if (as.tag == .idle) {
        _ = logic.tick_atb(sp, sys.dt);
    }
}
