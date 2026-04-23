//! Pure game logic: combat math and round resolution.
//!
//! All functions are stateless and take component values by value or pointer.
//! No ECS World import here — callers pass in the data they need.

const std = @import("std");
const c = @import("components.zig");

/// Default round duration in seconds. Overridden per-session via lobby config.
pub const ROUND_DURATION_DEFAULT_S: f32 = 3.0;

/// Effect value of a single player action contribution (damage dealt,
/// shield HP granted, or HP healed).
pub const ACTION_EFFECT_VALUE: u16 = 10;

// ---------------------------------------------------------------------------
// Core health mutations
// ---------------------------------------------------------------------------

pub fn apply_damage(health: *c.Health, damage: u16) void {
    health.current = if (health.current > damage) health.current - damage else 0;
}

pub fn apply_heal(health: *c.Health, amount: u16) void {
    const restored = @as(u32, health.current) + @as(u32, amount);
    health.current = @intCast(@min(restored, @as(u32, health.max)));
}

pub fn is_dead(health: c.Health) bool {
    return health.current == 0;
}

// ---------------------------------------------------------------------------
// Pool resolution — player action pools applied at round end
// ---------------------------------------------------------------------------

/// Apply accumulated damage pool to a single target's health.
/// Returns actual damage dealt (after shield absorption).
/// `shield_hp` is modified in place; overflow hits `health`.
pub fn resolve_damage_pool(
    health: *c.Health,
    shield_hp: *u16,
    pool_size: u16,
) u16 {
    const total = pool_size * ACTION_EFFECT_VALUE;
    if (total == 0) return 0;
    const absorbed = @min(shield_hp.*, total);
    shield_hp.* -= absorbed;
    const remaining = total - absorbed;
    apply_damage(health, remaining);
    return total;
}

/// Grant flat shield HP to a single entity from the shield pool.
pub fn resolve_shield_pool(shield_hp: *u16, pool_size: u16) void {
    shield_hp.* +|= pool_size * ACTION_EFFECT_VALUE;
}

/// Apply heal pool to a single entity's health.
pub fn resolve_heal_pool(health: *c.Health, pool_size: u16) void {
    apply_heal(health, pool_size * ACTION_EFFECT_VALUE);
}

// ---------------------------------------------------------------------------
// Enemy intent abstraction
//
// `EnemyIntent` is the authoritative description of what the enemy side does
// each round.  Callers use only this struct — never raw enemy counts — so
// future AI extensions only need to change `compute_enemy_intent`.
// ---------------------------------------------------------------------------

pub const EnemyIntent = struct {
    /// Total damage dealt to each living player this round.
    damage_per_player: u16,
};

/// Compute the enemy intent for the current round.
///
/// Each living enemy deals exactly 1 damage per player, so
/// `damage_per_player = living_enemy_count`.
pub fn compute_enemy_intent(living_enemy_count: u16) EnemyIntent {
    return .{ .damage_per_player = living_enemy_count };
}

/// Apply enemy intent damage to a single player, absorbing from shield first.
/// Returns the raw HP damage that landed (post-shield).
pub fn apply_enemy_intent(
    health: *c.Health,
    shield_hp: *u16,
    intent: EnemyIntent,
) u16 {
    const total = intent.damage_per_player;
    if (total == 0) return 0;
    const absorbed = @min(shield_hp.*, total);
    shield_hp.* -= absorbed;
    const remaining = total - absorbed;
    apply_damage(health, remaining);
    return remaining;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "apply_damage: no underflow" {
    var h = c.Health{ .current = 5, .max = 100 };
    apply_damage(&h, 999);
    try std.testing.expectEqual(@as(u16, 0), h.current);
}

test "apply_heal: no overflow" {
    var h = c.Health{ .current = 95, .max = 100 };
    apply_heal(&h, 999);
    try std.testing.expectEqual(@as(u16, 100), h.current);
}

test "resolve_damage_pool: no shield" {
    // pool=1 deals ACTION_EFFECT_VALUE total; all hits hp
    const V = ACTION_EFFECT_VALUE;
    var h = c.Health{ .current = V * 10, .max = V * 10 };
    var shield: u16 = 0;
    const dealt = resolve_damage_pool(&h, &shield, 1);
    try std.testing.expectEqual(V, dealt);
    try std.testing.expectEqual(V * 9, h.current);
    try std.testing.expectEqual(@as(u16, 0), shield);
}

test "resolve_damage_pool: shield fully absorbs" {
    // pool=1, shield >= V: hp untouched, shield reduced by V
    const V = ACTION_EFFECT_VALUE;
    var h = c.Health{ .current = V * 10, .max = V * 10 };
    var shield: u16 = V + 5;
    const dealt = resolve_damage_pool(&h, &shield, 1);
    try std.testing.expectEqual(V, dealt);
    try std.testing.expectEqual(V * 10, h.current); // hp untouched
    try std.testing.expectEqual(@as(u16, 5), shield); // only excess remains
}

test "resolve_damage_pool: shield partially absorbs" {
    // pool=2, shield=V/2 (round down): shield absorbs V/2, rest hits hp
    const V = ACTION_EFFECT_VALUE;
    const partial: u16 = V / 2;
    var h = c.Health{ .current = V * 10, .max = V * 10 };
    var shield: u16 = partial;
    const total = 2 * V;
    const dealt = resolve_damage_pool(&h, &shield, 2);
    try std.testing.expectEqual(total, dealt);
    try std.testing.expectEqual(V * 10 - (total - partial), h.current);
    try std.testing.expectEqual(@as(u16, 0), shield);
}

test "resolve_shield_pool: grants shield" {
    // pool=1 grants ACTION_EFFECT_VALUE shield HP
    const V = ACTION_EFFECT_VALUE;
    var shield: u16 = 3;
    resolve_shield_pool(&shield, 1);
    try std.testing.expectEqual(@as(u16, 3 + V), shield);
}

test "resolve_heal_pool: heals" {
    // pool=1 heals ACTION_EFFECT_VALUE HP
    const V = ACTION_EFFECT_VALUE;
    var h = c.Health{ .current = 5, .max = V * 10 };
    resolve_heal_pool(&h, 1);
    try std.testing.expectEqual(@as(u16, 5 + V), h.current);
}

test "compute_enemy_intent: 1 dmg per living enemy" {
    const intent = compute_enemy_intent(42);
    try std.testing.expectEqual(@as(u16, 42), intent.damage_per_player);
}

test "apply_enemy_intent: shield absorbs first" {
    // intent deals 15 damage; 7 shield absorbs first → 8 hp damage
    var h = c.Health{ .current = 100, .max = 100 };
    var shield: u16 = 7;
    const intent = EnemyIntent{ .damage_per_player = 15 };
    const hp_dmg = apply_enemy_intent(&h, &shield, intent);
    try std.testing.expectEqual(@as(u16, 8), hp_dmg);
    try std.testing.expectEqual(@as(u16, 92), h.current);
    try std.testing.expectEqual(@as(u16, 0), shield);
}

test "resolve_damage_pool: zero pool — no change" {
    var h = c.Health{ .current = 10, .max = 10 };
    var shield: u16 = 3;
    const dealt = resolve_damage_pool(&h, &shield, 0);
    try std.testing.expectEqual(@as(u16, 0), dealt);
    try std.testing.expectEqual(@as(u16, 10), h.current);
    try std.testing.expectEqual(@as(u16, 3), shield);
}

test "resolve_shield_pool: saturation — no overflow past maxInt(u16)" {
    var shield: u16 = std.math.maxInt(u16) - 2;
    resolve_shield_pool(&shield, 5); // would overflow without saturating add
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), shield);
}

test "apply_enemy_intent: zero damage — no change" {
    var h = c.Health{ .current = 8, .max = 10 };
    var shield: u16 = 4;
    const intent = EnemyIntent{ .damage_per_player = 0 };
    const hp_dmg = apply_enemy_intent(&h, &shield, intent);
    try std.testing.expectEqual(@as(u16, 0), hp_dmg);
    try std.testing.expectEqual(@as(u16, 8), h.current);
    try std.testing.expectEqual(@as(u16, 4), shield);
}

test "resolve_heal_pool: at max HP — no overflow" {
    var h = c.Health{ .current = 100, .max = 100 };
    resolve_heal_pool(&h, 10);
    try std.testing.expectEqual(@as(u16, 100), h.current);
}

test "compute_enemy_intent: zero enemies — zero damage" {
    const intent = compute_enemy_intent(0);
    try std.testing.expectEqual(@as(u16, 0), intent.damage_per_player);
}
