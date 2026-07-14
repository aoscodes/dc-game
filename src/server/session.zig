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
//! split into `casts_per_round` cast windows (`cast_timer`, each
//! round_duration / casts_per_round long).  During a window players compose
//! a combo in `action_pool` (latest edit wins; Escape cancels).  When the
//! window closes the pending combo is COMMITTED as a spell (broadcasting
//! `cast_committed` + a `.cast` action_result) — up to casts_per_round
//! spells per player per round — and the window's batch CONVERTS
//! immediately: recipes match within the batch (team recipes require
//! distinct players in the SAME window), medicine heals the hunger bar
//! right away, and agents transmute matching-color Modified Slime into
//! Neutralized Slime in the current zone (visible live in game_state).
//! When the round timer expires `resolve_round()`:
//!   1. Closes the final cast window (conversion as above).
//!   2. Consumes the entire zone: every unit adds normal hunger;
//!      still-modified units add extra (healable) hunger.  Score += neutral
//!      units consumed (neutralized + naturally-neutral).
//!   3. Advances to the next zone.
//!
//! The round loop above is CLASSIC mode.  In REALTIME mode (`mode =
//! .realtime`) there is no round timer and no repeating cast timer: the Lil
//! Guys eat the current zone continuously (`eat_rate_units_per_s` per
//! connected player) and casts fire on demand (`submit_spell`).  Each
//! accepted cast gets its OWN `cast_buffer_ms` countdown and fires solo at
//! its expiry — UNLESS a newly accepted cast COMPLETES a team recipe with
//! pending casts: that recipe instance's members then share the joiner's
//! expiry (`cast_grouped`) and fire together.  Expired casts convert as one
//! batch (`cast_fired`) through the same pipeline as classic (recipes,
//! medicine, transmutation).  Each accepted submit also starts a per-player
//! `cast_lock_ms` cooldown: locked submits are silently ignored, and an
//! unlocked resubmit REPLACES the player's pending cast, restarting its
//! buffer (`cast_replaced`).  An emptied zone advances immediately
//! (round_reset).
//!
//! The encounter ends when all zones are consumed OR the hunger bar fills.
//! Either way the final shared score is broadcast via game_over.

const std = @import("std");
const ecs = @import("ecs_zig");
const shared = @import("shared");
const c = shared.components;
const proto = shared.protocol;
const logic = shared.game_logic;
const enc = shared.encounter;
const cfg_mod = shared.config;
const dbg = @import("debug_zig");

pub const TickZones = enum { drain, round, broadcast, check_end };

pub const PlayerTeam = struct {};

pub const GameWorld = ecs.World(
    .{
        .kind = c.Kind,
        .owner = c.Owner,
        .player_marker = c.PlayerMarker,
    },
    .{
        .player_team = PlayerTeam,
    },
);

pub const MAX_PLAYERS = proto.MAX_PLAYERS;

pub const PlayerSlot = struct {
    occupied: bool = false,
    connected: bool = false,
    player_id: u8,
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: u8 = 0,
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
    /// Loaded balance + encounter data; owned by the caller and must outlive
    /// the session.
    cfg: *const cfg_mod.Config,
    players: [MAX_PLAYERS]PlayerSlot,
    player_count: u8 = 0,
    phase: SessionPhase = .lobby,
    world: GameWorld,
    tick_count: u32 = 0,
    current_encounter: ?*const enc.Encounter = null,
    round_timer: f32,
    round_duration: f32,
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
    /// Play style: classic timed rounds or realtime continuous eating.
    mode: c.GameMode = .classic,
    /// Realtime: each player's PENDING cast (null = none).  Cleared when the
    /// cast fires and on game start.
    submitted_pool: [MAX_PLAYERS]?c.ActionCombo = [_]?c.ActionCombo{null} ** MAX_PLAYERS,
    /// Realtime: fractional eaten-units carried between ticks.
    eat_accum: f32 = 0,
    /// Classic: countdown of the current cast window; pending combos commit
    /// at 0.
    cast_timer: f32 = 0,
    /// Realtime: per-player countdown of the pending cast's buffer (null =
    /// no cast pending, parallel to submitted_pool).  A cast fires when its
    /// timer reaches 0; team-recipe grouping equalises members' timers so
    /// they expire (and convert) together.
    cast_fire_timers: [MAX_PLAYERS]?f32 = [_]?f32{null} ** MAX_PLAYERS,
    /// Realtime: per-player cast-lock cooldowns (seconds remaining).
    cast_locks: [MAX_PLAYERS]f32 = [_]f32{0} ** MAX_PLAYERS,
    /// Per-player committed-spell count this round (capped casts_per_round).
    casts_used: [MAX_PLAYERS]u8 = [_]u8{0} ** MAX_PLAYERS,
    /// Tuning stats accumulated over the match; broadcast with game_over.
    /// `players` is indexed by player_id during play and compacted (dense,
    /// names filled) in end_game.
    stats: proto.MatchStats = .{},
    /// Number of rounds resolved so far in the current game.
    round_count: u32 = 0,
    profiler: dbg.Profiler(TickZones) = dbg.Profiler(TickZones).init(),

    pub fn init(
        allocator: std.mem.Allocator,
        join_code: [6]u8,
        cfg: *const cfg_mod.Config,
    ) !Session {
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
            .cfg = cfg,
            .players = players,
            .world = world,
            .round_timer = cfg.balance.round_duration_default_s,
            .round_duration = cfg.balance.round_duration_default_s,
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
        const encounter = self.cfg.encounters.find(encounter_label) orelse
            self.cfg.encounters.default();
        try self.start_game_encounter(encounter);
    }

    pub fn start_game_encounter(self: *Session, encounter: *const enc.Encounter) !void {
        std.debug.assert(encounter.zones.len <= enc.MAX_ZONES);
        self.world.deinit();
        self.world = try GameWorld.init(self.allocator);
        set_world_system_signatures(&self.world);
        for (&self.action_pool) |*a| a.* = @as(?c.ActionCombo, null);
        self.casts_used = [_]u8{0} ** MAX_PLAYERS;
        self.stats = .{
            .player_recipe_count = @intCast(self.cfg.balance.player_recipes.len),
            .team_recipe_count = @intCast(self.cfg.balance.team_recipes.len),
        };
        self.tick_count = 0;
        self.round_count = 0;

        self.phase = .playing;
        self.current_encounter = encounter;
        self.round_timer = self.round_duration;
        self.cast_timer = self.cast_duration();
        self.cast_fire_timers = [_]?f32{null} ** MAX_PLAYERS;
        self.cast_locks = [_]f32{0} ** MAX_PLAYERS;
        for (&self.submitted_pool) |*sp| sp.* = null;
        self.eat_accum = 0;

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
        switch (self.mode) {
            .classic => {
                self.round_timer -= dt;
                self.cast_timer -= dt;
                if (self.round_timer <= 0.0) {
                    try self.resolve_round();
                    self.reset_round();
                } else if (self.cast_timer <= 0.0) {
                    // Cast window closed mid-round: commit pending spells and
                    // open the next window (round resolution commits the
                    // final window).
                    try self.commit_pending_casts();
                    self.cast_timer += self.cast_duration();
                }
            },
            .realtime => {
                for (&self.cast_locks) |*lock| lock.* = @max(lock.* - dt, 0.0);
                var any_expired = false;
                for (&self.cast_fire_timers) |*t| {
                    if (t.*) |*remaining| {
                        remaining.* -= dt;
                        if (remaining.* <= 0.0) any_expired = true;
                    }
                }
                if (any_expired) try self.fire_expired_casts();
                try self.eat_tick(dt);
            },
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

    /// Length of one cast window: the round divided into casts_per_round slots.
    fn cast_duration(self: *const Session) f32 {
        return self.round_duration / @as(f32, @floatFromInt(self.cfg.balance.casts_per_round));
    }

    /// Realtime group-cast buffer length in seconds (from balance data).
    fn cast_buffer_s(self: *const Session) f32 {
        return @as(f32, @floatFromInt(self.cfg.balance.cast_buffer_ms)) / 1000.0;
    }

    /// Realtime per-player cast-lock cooldown in seconds (from balance data).
    fn cast_lock_s(self: *const Session) f32 {
        return @as(f32, @floatFromInt(self.cfg.balance.cast_lock_ms)) / 1000.0;
    }

    /// Classic: commit every pending combo as a spell (up to casts_per_round
    /// per player per round; zero-output combos fizzle for free) and CONVERT
    /// the window's batch immediately via `convert_batch`.  Broadcasts
    /// cast_committed + a .cast action_result per commit.
    fn commit_pending_casts(self: *Session) !void {
        var batch: [MAX_PLAYERS]logic.Cast = undefined;
        var batch_len: usize = 0;

        for (&self.players, 0..) |*slot, pid| {
            const combo = self.action_pool[pid] orelse continue;
            self.action_pool[pid] = null;

            if (self.casts_used[pid] >= self.cfg.balance.casts_per_round) continue; // cap reached

            // Zero-output combos FIZZLE: discarded without costing a cast.
            if (!logic.combo_has_output(&self.cfg.balance, combo)) {
                self.stats.players[pid].fizzles +|= 1;
                var fbuf: [4]u8 = undefined;
                var ffbs = std.io.fixedBufferStream(&fbuf);
                try proto.encode(ffbs.writer(), .cast_fizzled, proto.CastFizzled{
                    .player_id = @intCast(pid),
                });
                try self.broadcast_raw(ffbs.getWritten());
                continue;
            }

            batch[batch_len] = .{ .player_id = @intCast(pid), .combo = combo };
            batch_len += 1;
            self.casts_used[pid] += 1;
            self.record_cast_stats(pid, combo);

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

        try self.convert_batch(batch[0..batch_len]);
    }

    /// Realtime: collect every pending cast whose buffer expired (timer <=
    /// 0) into one batch — grouped casts share an expiry, so a team recipe's
    /// members convert together — clearing their pool slots, timers and
    /// on-wire submission markers (`casts_used`).  Records cast stats (here,
    /// not at submit time, so replacements count once), broadcasts
    /// cast_fired (before conversion, so it precedes the batch's
    /// recipe_fired / action_result messages), and converts the batch
    /// through the same pipeline as classic cast windows.
    fn fire_expired_casts(self: *Session) !void {
        var batch: [MAX_PLAYERS]logic.Cast = undefined;
        var batch_len: usize = 0;
        var player_mask: u8 = 0;
        for (&self.cast_fire_timers, 0..) |*t, pid| {
            const remaining = t.* orelse continue;
            if (remaining > 0.0) continue;
            t.* = null;
            const combo = self.submitted_pool[pid] orelse continue;
            self.submitted_pool[pid] = null;
            self.casts_used[pid] = 0;
            batch[batch_len] = .{ .player_id = @intCast(pid), .combo = combo };
            batch_len += 1;
            player_mask |= @as(u8, 1) << @intCast(pid);
            self.record_cast_stats(pid, combo);
        }
        if (batch_len == 0) return;

        var buf: [8]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .cast_fired, proto.CastFired{
            .spell_count = @intCast(batch_len),
            .player_mask = player_mask,
        });
        try self.broadcast_raw(fbs.getWritten());

        try self.convert_batch(batch[0..batch_len]);
    }

    /// Realtime: after accepting `player_id`'s cast, check whether it
    /// COMPLETES a team recipe with the other pending casts (dry-run of the
    /// same matcher used at fire time).  If so, equalise that recipe
    /// INSTANCE's fire timers to the joiner's full buffer — the group fires
    /// together at the newest joiner's expiry — and broadcast cast_grouped.
    /// Partial matches never hold casts.
    fn group_team_casts(self: *Session, player_id: u8) !void {
        var pending: [MAX_PLAYERS]logic.Cast = undefined;
        var pending_len: usize = 0;
        var joiner_index: ?usize = null;
        for (&self.submitted_pool, 0..) |*sp, pid| {
            const combo = sp.* orelse continue;
            if (pid == player_id) joiner_index = pending_len;
            pending[pending_len] = .{ .player_id = @intCast(pid), .combo = combo };
            pending_len += 1;
        }
        const ji = joiner_index orelse return;

        var report = logic.MatchReport{};
        _ = logic.match_recipes(&self.cfg.balance, pending[0..pending_len], &report);
        const instance = report.team_instance[ji];
        if (instance == logic.NO_TEAM_INSTANCE) return;

        var player_mask: u8 = 0;
        for (pending[0..pending_len], 0..) |cast, ci| {
            if (report.team_instance[ci] != instance) continue;
            self.cast_fire_timers[cast.player_id] = self.cast_buffer_s();
            player_mask |= @as(u8, 1) << @intCast(cast.player_id);
        }

        var buf: [8]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .cast_grouped, proto.CastGrouped{
            .player_mask = player_mask,
            .fires_in_ms = self.cfg.balance.cast_buffer_ms,
        });
        try self.broadcast_raw(fbs.getWritten());
    }

    /// CONVERT one cast window's batch of committed spells (shared by
    /// classic's commit_pending_casts and realtime's window commit):
    /// recipes match within the batch (team recipes = same window only),
    /// medicine heals right away (broadcasting a .heal action_result), and
    /// agents transmute matching-color Modified Slime into Neutralized
    /// Slime in the current zone.  Each recipe fire is broadcast.
    fn convert_batch(self: *Session, batch: []const logic.Cast) !void {
        if (batch.len == 0) return;

        var report = logic.MatchReport{};
        const output = logic.match_recipes(&self.cfg.balance, batch, &report);

        // Recipe stats: fire counts + per-player participation.  Each fire is
        // also broadcast so clients can show recipe floaters live.  Only the
        // loaded tables' entries are meaningful (arrays are cap-sized).
        for (self.cfg.balance.player_recipes, 0..) |_, ri| {
            const hit = report.player_hits[ri];
            self.stats.player_recipe_hits[ri] +|= hit;
            try self.broadcast_recipe_fired(.player, @intCast(ri), hit);
        }
        for (self.cfg.balance.team_recipes, 0..) |_, ri| {
            const hit = report.team_hits[ri];
            self.stats.team_recipe_hits[ri] +|= hit;
            try self.broadcast_recipe_fired(.team, @intCast(ri), hit);
        }
        for (batch, 0..) |cast, ci| {
            if (report.consumed[ci] != .none) {
                self.stats.players[cast.player_id].recipe_casts +|= 1;
            }
        }

        // Medicine heals immediately (previous rounds' modified-slime hunger).
        const healed = logic.apply_medicine(&self.hunger, &self.hunger_healable, output.medicine);
        const healed_total = logic.sum_u16(healed);
        if (healed_total > 0) {
            try self.broadcast_action_result(.{
                .tag = .heal,
                .actor_entity = std.math.maxInt(u32),
                .target_entity = std.math.maxInt(u32),
                .value = stat_u16(healed_total),
            });
        }

        // Agents transmute the current zone's slime in place (visible live).
        if (self.zone_index < self.zone_count) {
            _ = logic.transmute(
                &self.zones[self.zone_index],
                output.units,
                self.cfg.balance.neutralize_residue_mult,
            );
        }

        // Per-round tuning stats accumulate per window.
        if (self.zone_index < enc.MAX_ZONES) {
            const rs = &self.stats.round_stats[self.zone_index];
            for (&rs.agents_dispensed, output.units) |*d, u| d.* +|= stat_u16(u);
            for (&rs.medicine_dispensed, output.medicine) |*d, m| d.* +|= stat_u16(m);
            for (&rs.medicine_healed, healed) |*d, h| d.* +|= h;
        }
    }

    /// Realtime: the Lil Guys eat the current zone continuously.  Whole
    /// units accumulate at `eat_rate_units_per_s` per connected player;
    /// each batch of bites adds hunger (normal + healable extra), score,
    /// and per-round stats, broadcasting a .damage action_result.  An
    /// emptied zone advances immediately (round_reset) — the cast window
    /// keeps running across zone boundaries.
    fn eat_tick(self: *Session, dt: f32) !void {
        var connected: u32 = 0;
        for (&self.players) |*p| {
            if (p.occupied and p.connected) connected += 1;
        }
        if (connected == 0) connected = 1;

        self.eat_accum += self.cfg.balance.eat_rate_units_per_s *
            @as(f32, @floatFromInt(connected)) * dt;
        const n: u32 = @intFromFloat(@floor(self.eat_accum));
        if (n < 1) return;
        self.eat_accum -= @floatFromInt(n);

        if (self.zone_index >= self.zone_count) return;
        const zone = &self.zones[self.zone_index];
        const out = logic.eat_units(&self.cfg.balance, zone, n);

        const hunger_added = out.hunger_normal + out.hunger_extra_total();
        logic.add_hunger(&self.hunger, hunger_added);
        for (&self.hunger_healable, out.hunger_extra) |*healable, extra| {
            const grown = @as(u32, healable.*) + extra;
            healable.* = @intCast(@min(grown, @as(u32, std.math.maxInt(u16))));
        }
        self.score += out.score;

        // Per-round consumption stats accumulate bite by bite (round index
        // == zone index, as in classic).
        if (self.zone_index < enc.MAX_ZONES) {
            const rs = &self.stats.round_stats[self.zone_index];
            for (&rs.neutralized, out.eaten_neutralized) |*d, v| d.* +|= v;
            for (&rs.modified_escaped, out.eaten_modified) |*d, v| d.* +|= v;
            rs.neutral_consumed +|= out.eaten_neutral;
            rs.hunger_normal +|= stat_u16(out.hunger_normal);
            rs.hunger_extra +|= stat_u16(out.hunger_extra_total());
            rs.hunger_after = self.hunger.current;
        }

        if (hunger_added > 0) {
            try self.broadcast_action_result(.{
                .tag = .damage,
                .actor_entity = std.math.maxInt(u32),
                .target_entity = std.math.maxInt(u32),
                .value = @intCast(@min(hunger_added, std.math.maxInt(u16))),
            });
        }

        if (zone.total_units() == 0) {
            // Zone fully eaten: advance immediately.  The cast window and
            // locked-in spells are independent of zone boundaries.
            self.zones[self.zone_index] = .{};
            self.zone_index += 1;
            self.round_count += 1;
            self.casts_used = [_]u8{0} ** MAX_PLAYERS;
            var buf: [2]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            proto.encode(fbs.writer(), .round_reset, {}) catch return;
            self.broadcast_raw(fbs.getWritten()) catch {};
        }
    }

    /// Broadcast `count` recipe_fired messages for one recipe table entry.
    fn broadcast_recipe_fired(self: *Session, kind: proto.RecipeKind, index: u8, count: u16) !void {
        var fired: u16 = 0;
        while (fired < count) : (fired += 1) {
            var buf: [4]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            try proto.encode(fbs.writer(), .recipe_fired, proto.RecipeFired{
                .kind = kind,
                .index = index,
            });
            try self.broadcast_raw(fbs.getWritten());
        }
    }

    /// Record a committed cast into the tuning stats: total + per-player
    /// counts and RAW per-color slot tallies (pre-recipe attribution).
    fn record_cast_stats(self: *Session, pid: usize, combo: c.ActionCombo) void {
        self.stats.casts_total +|= 1;
        if (self.zone_index < enc.MAX_ZONES) {
            self.stats.round_stats[self.zone_index].casts +|= 1;
        }
        const ps = &self.stats.players[pid];
        ps.casts +|= 1;
        var ea_buf: [c.MAX_COMBO_LEN]logic.ElementedAction = undefined;
        const n = logic.parse_combo(combo, &ea_buf);
        for (ea_buf[0..n]) |ea| {
            const el = ea.element orelse continue; // colorless slots are wasted
            switch (ea.action) {
                .dispense => ps.dispense_slots[@intFromEnum(el)] +|= 1,
                .medicine => ps.medicine_slots[@intFromEnum(el)] +|= 1,
            }
        }
    }

    fn reset_round(self: *Session) void {
        for (&self.action_pool) |*a| a.* = null;
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
                    const default_label = self.cfg.encounters.default().label;
                    try self.start_game(default_label);
                    try self.broadcast_game_start(default_label);
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
            .submit_spell => {
                // Always decode so the stream stays in sync for any
                // messages queued after this one.
                const p = try proto.decode_submit_spell(fbs.reader());
                if (self.phase != .playing or self.mode != .realtime or player_id >= MAX_PLAYERS) return;
                // Cast lock still cooling down: silent ignore.
                if (self.cast_locks[player_id] > 0.0) return;

                // Zero-output combos FIZZLE without starting a lock or
                // a cast buffer.
                if (!logic.combo_has_output(&self.cfg.balance, p.combo)) {
                    self.stats.players[player_id].fizzles +|= 1;
                    var fbuf: [4]u8 = undefined;
                    var ffbs = std.io.fixedBufferStream(&fbuf);
                    try proto.encode(ffbs.writer(), .cast_fizzled, proto.CastFizzled{
                        .player_id = player_id,
                    });
                    try self.broadcast_raw(ffbs.getWritten());
                    return;
                }

                const replacing = self.submitted_pool[player_id] != null;
                self.submitted_pool[player_id] = p.combo;
                self.action_pool[player_id] = null; // clears the live preview
                self.cast_locks[player_id] = self.cast_lock_s();
                // The cast's own buffer: fires at expiry unless a later
                // joiner completes a team recipe (group_team_casts).  A
                // replacement is a NEW cast — its buffer restarts.
                self.cast_fire_timers[player_id] = self.cast_buffer_s();
                // On-wire submission marker (game_start announces
                // casts_per_round = 1 in realtime, so the existing
                // "casts used" client UI reads correctly).
                self.casts_used[player_id] = 1;

                // New vs replace: a resubmit swaps the pending spell and
                // announces cast_replaced (no duplicate cast_committed).
                var buf: [4]u8 = undefined;
                var cfbs = std.io.fixedBufferStream(&buf);
                if (replacing) {
                    try proto.encode(cfbs.writer(), .cast_replaced, proto.CastReplaced{
                        .player_id = player_id,
                    });
                } else {
                    try proto.encode(cfbs.writer(), .cast_committed, proto.CastCommitted{
                        .player_id = player_id,
                    });
                }
                try self.broadcast_raw(cfbs.getWritten());

                // Completed a team recipe with pending casts? Group them.
                try self.group_team_casts(player_id);

                const slot = &self.players[player_id];
                if (slot.entity != std.math.maxInt(ecs.Entity)) {
                    try self.broadcast_action_result(.{
                        .tag = .cast,
                        .actor_entity = slot.entity,
                        .target_entity = std.math.maxInt(u32),
                        .value = 0,
                    });
                }
                std.log.debug("player {} submitted spell (realtime, {s})", .{
                    player_id, if (replacing) "replaced" else "joined",
                });
            },
            .reconnect => {},
            else => {},
        }
    }

    /// Saturating u32 → u16 for stats fields.
    fn stat_u16(v: u32) u16 {
        return @intCast(@min(v, std.math.maxInt(u16)));
    }

    /// Remaining countdown (seconds) → whole milliseconds on the wire,
    /// saturated to u16 (caps at ~65s; both ms tunables are capped at 60s).
    fn wire_ms(seconds: f32) u16 {
        const ms = @ceil(@max(seconds, 0.0) * 1000.0);
        return @intFromFloat(@min(ms, @as(f32, std.math.maxInt(u16))));
    }

    /// Resolve one round: close the final cast window (conversion happens in
    /// commit_pending_casts), then consume the entire current zone.
    fn resolve_round(self: *Session) !void {
        try self.commit_pending_casts();

        if (self.zone_index >= self.zone_count) return;

        // Consume the zone: transmutation already happened per cast window.
        const zone = self.zones[self.zone_index];
        const outcome = logic.consume_zone(&self.cfg.balance, zone);

        var neutralized_total: u32 = 0;
        for (outcome.neutralized) |n| neutralized_total += n;

        const hunger_added = outcome.hunger_normal + outcome.hunger_extra_total();
        logic.add_hunger(&self.hunger, hunger_added);
        for (&self.hunger_healable, outcome.hunger_extra) |*healable, extra| {
            const grown = @as(u32, healable.*) + extra;
            healable.* = @intCast(@min(grown, @as(u32, std.math.maxInt(u16))));
        }
        self.score += outcome.score;

        // Per-round consumption stats (round index == zone index).
        const rs = &self.stats.round_stats[self.zone_index];
        rs.neutralized = outcome.neutralized;
        rs.modified_escaped = outcome.modified_missed;
        rs.neutral_consumed = zone.neutral;
        rs.hunger_normal = stat_u16(outcome.hunger_normal);
        rs.hunger_extra = stat_u16(outcome.hunger_extra_total());
        rs.hunger_after = self.hunger.current;

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
        // Field-cleared wins ties: if the final zone fills the bar exactly,
        // the players still ate everything.
        if (self.zone_index >= self.zone_count) {
            std.log.info("all slime consumed — encounter over, score={}", .{self.score});
            try self.end_game(.field_cleared);
        } else if (logic.hunger_full(self.hunger)) {
            std.log.info("hunger bar full — encounter over, score={}", .{self.score});
            try self.end_game(.hunger_full);
        }
    }

    fn end_game(self: *Session, reason: proto.EndReason) !void {
        std.log.info("game over — score: {} reason: {s}", .{ self.score, @tagName(reason) });
        self.phase = .lobby;
        // Reset ready flags so players must opt-in to the next game.
        for (&self.players) |*p| p.ready = false;

        // Finalise the tuning report.
        self.stats.reason = reason;
        self.stats.rounds = self.zone_index; // one zone consumed per round
        self.stats.zone_count = self.zone_count;
        self.stats.hunger_final = self.hunger.current;
        self.stats.hunger_max = self.hunger.max;
        // Compact per-player stats (indexed by player_id during play) into a
        // dense list with names for the wire.
        var compacted = [_]proto.PlayerStats{.{}} ** MAX_PLAYERS;
        var dense: u8 = 0;
        for (&self.players, 0..) |*slot, pid| {
            if (!slot.occupied) continue;
            var ps = self.stats.players[pid];
            ps.name = slot.name;
            ps.name_len = slot.name_len;
            compacted[dense] = ps;
            dense += 1;
        }
        self.stats.players = compacted;
        self.stats.player_count = dense;

        var buf: [2048]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try proto.encode(fbs.writer(), .game_over, proto.GameOver{
            .score = self.score,
            .stats = self.stats,
        });
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
            .casts_per_round = if (self.mode == .realtime) 1 else self.cfg.balance.casts_per_round,
            .mode = self.mode,
            .cast_buffer_ms = if (self.mode == .realtime) self.cfg.balance.cast_buffer_ms else 0,
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
            .mode = self.mode,
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
                .casts_per_round = if (self.mode == .realtime) 1 else self.cfg.balance.casts_per_round,
                .mode = self.mode,
                .cast_buffer_ms = if (self.mode == .realtime) self.cfg.balance.cast_buffer_ms else 0,
            };
            @memcpy(gs_msg.encounter_label[0..gs_msg.encounter_label_len], encounter_label[0..gs_msg.encounter_label_len]);
            try proto.encode(fbs.writer(), .game_start, gs_msg);
            try t.send(fbs.getWritten());
        }
    }

    fn broadcast_game_state(self: *Session) !void {
        var snap = proto.GameState.blank;
        snap.tick = self.tick_count;
        snap.round_timer = if (self.mode == .realtime) 0.0 else @max(self.round_timer, 0.0);
        // Realtime: cast_timer carries the SOONEST pending cast's remaining
        // buffer, or -1 when nothing is pending (the idle sentinel clients
        // key off).  Per-player countdowns ride on each entity's cast_ms.
        snap.cast_timer = if (self.mode == .realtime) blk: {
            var soonest: f32 = -1.0;
            for (self.cast_fire_timers) |t| {
                const remaining = @max(t orelse continue, 0.0);
                if (soonest < 0.0 or remaining < soonest) soonest = remaining;
            }
            break :blk soonest;
        } else @max(self.cast_timer, 0.0);
        snap.hunger = .{
            .current = self.hunger.current,
            .max = self.hunger.max,
        };
        snap.hunger_healable = self.hunger_healable;
        snap.score = self.score;
        snap.zone_index = self.zone_index;
        snap.zone_count = self.zone_count;
        for (self.zones[0..self.zone_count], 0..) |zone, i| {
            snap.zones[i] = .{
                .modified = zone.modified,
                .neutralized = zone.neutralized,
                .neutral = zone.neutral,
            };
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
                .lock_ms = wire_ms(self.cast_locks[own]),
                .cast_ms = wire_ms(self.cast_fire_timers[own] orelse 0.0),
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
