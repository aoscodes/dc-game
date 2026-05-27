const std = @import("std");
const c = @import("components.zig");

pub const ROUND_DURATION_DEFAULT_S: f32 = 3.0;
pub const ACTION_EFFECT_VALUE: u16 = 1;

/// An action slot with its resolved element modifier (null = no element).
pub const ElementedAction = struct {
    action:  c.ActionChoice,
    element: ?c.Element,
};

/// Parse a combo into a flat sequence of ElementedActions.
///
/// Rules:
///   - An element token sets the *current element*; it persists until the
///     next element token or end of combo.
///   - An action token consumes the current element (which may be null) and
///     emits one ElementedAction.
///   - Trailing element tokens with no following action are silently dropped.
///
/// Returns the number of entries written to `out`.  `out` must have capacity
/// >= combo.len (a combo of all-action slots is the worst case).
pub fn parse_combo(combo: c.ActionCombo, out: []ElementedAction) usize {
    var current_element: ?c.Element = null;
    var count: usize = 0;
    for (combo.slots[0..combo.len]) |slot| {
        switch (slot) {
            .element => |el| current_element = el,
            .action  => |ac| {
                out[count] = .{ .action = ac, .element = current_element };
                count += 1;
                // Element persists — do NOT reset current_element here.
            },
        }
    }
    return count;
}

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

pub fn resolve_damage_pool(
    health: *c.Health,
    shield: *c.Shield,
    pool_size: u16,
) u16 {
    const total = pool_size * ACTION_EFFECT_VALUE;
    if (total == 0) return 0;
    const absorbed = @min(shield.hp, total);
    shield.hp -= absorbed;
    const remaining = total - absorbed;
    apply_damage(health, remaining);
    return remaining;
}

pub fn resolve_shield_pool(shield: *c.Shield, pool_size: u16) void {
    shield.hp +|= pool_size * ACTION_EFFECT_VALUE;
}

pub fn resolve_heal_pool(health: *c.Health, pool_size: u16) void {
    apply_heal(health, pool_size * ACTION_EFFECT_VALUE);
}

pub const EnemyIntent = struct {
    damage_per_player: u16,
};

pub fn compute_enemy_intent(living_enemy_count: u16) EnemyIntent {
    return .{ .damage_per_player = living_enemy_count };
}

pub fn apply_enemy_intent(
    health: *c.Health,
    shield: *c.Shield,
    intent: EnemyIntent,
) u16 {
    const total = intent.damage_per_player;
    if (total == 0) return 0;
    const absorbed = @min(shield.hp, total);
    shield.hp -= absorbed;
    const remaining = total - absorbed;
    apply_damage(health, remaining);
    return remaining;
}

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
    // pool=1, no shield: all V damage lands on hp
    const V = ACTION_EFFECT_VALUE;
    var h = c.Health{ .current = V * 10, .max = V * 10 };
    var shield = c.Shield{ .hp = 0 };
    const dealt = resolve_damage_pool(&h, &shield, 1);
    try std.testing.expectEqual(V, dealt); // full V reaches HP
    try std.testing.expectEqual(V * 9, h.current);
    try std.testing.expectEqual(@as(u16, 0), shield.hp);
}

test "resolve_damage_pool: shield fully absorbs" {
    // pool=1, shield >= V: hp untouched, dealt = 0 (no HP damage)
    const V = ACTION_EFFECT_VALUE;
    var h = c.Health{ .current = V * 10, .max = V * 10 };
    var shield = c.Shield{ .hp = V + 5 };
    const dealt = resolve_damage_pool(&h, &shield, 1);
    try std.testing.expectEqual(@as(u16, 0), dealt); // shield ate it all
    try std.testing.expectEqual(V * 10, h.current); // hp untouched
    try std.testing.expectEqual(@as(u16, 5), shield.hp); // only excess remains
}

test "resolve_damage_pool: shield partially absorbs" {
    // pool=2 (total=2V), shield=V/2: shield absorbs V/2, remaining 3V/2 hits hp
    const V = ACTION_EFFECT_VALUE;
    const partial: u16 = V / 2;
    var h = c.Health{ .current = V * 10, .max = V * 10 };
    var shield = c.Shield{ .hp = partial };
    const total = 2 * V;
    const expected_hp_dmg = total - partial;
    const dealt = resolve_damage_pool(&h, &shield, 2);
    try std.testing.expectEqual(expected_hp_dmg, dealt); // only remainder lands on HP
    try std.testing.expectEqual(V * 10 - expected_hp_dmg, h.current);
    try std.testing.expectEqual(@as(u16, 0), shield.hp);
}

test "resolve_shield_pool: grants shield" {
    // pool=1 grants ACTION_EFFECT_VALUE shield HP
    const V = ACTION_EFFECT_VALUE;
    var shield = c.Shield{ .hp = 3 };
    resolve_shield_pool(&shield, 1);
    try std.testing.expectEqual(@as(u16, 3 + V), shield.hp);
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
    var shield = c.Shield{ .hp = 7 };
    const intent = EnemyIntent{ .damage_per_player = 15 };
    const hp_dmg = apply_enemy_intent(&h, &shield, intent);
    try std.testing.expectEqual(@as(u16, 8), hp_dmg);
    try std.testing.expectEqual(@as(u16, 92), h.current);
    try std.testing.expectEqual(@as(u16, 0), shield.hp);
}

test "resolve_damage_pool: zero pool — no change" {
    var h = c.Health{ .current = 10, .max = 10 };
    var shield = c.Shield{ .hp = 3 };
    const dealt = resolve_damage_pool(&h, &shield, 0);
    try std.testing.expectEqual(@as(u16, 0), dealt);
    try std.testing.expectEqual(@as(u16, 10), h.current);
    try std.testing.expectEqual(@as(u16, 3), shield.hp);
}

test "resolve_shield_pool: saturation — no overflow past maxInt(u16)" {
    var shield = c.Shield{ .hp = std.math.maxInt(u16) - 2 };
    resolve_shield_pool(&shield, 5); // would overflow without saturating add
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), shield.hp);
}

test "apply_enemy_intent: zero damage — no change" {
    var h = c.Health{ .current = 8, .max = 10 };
    var shield = c.Shield{ .hp = 4 };
    const intent = EnemyIntent{ .damage_per_player = 0 };
    const hp_dmg = apply_enemy_intent(&h, &shield, intent);
    try std.testing.expectEqual(@as(u16, 0), hp_dmg);
    try std.testing.expectEqual(@as(u16, 8), h.current);
    try std.testing.expectEqual(@as(u16, 4), shield.hp);
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

// ---------------------------------------------------------------------------
// parse_combo tests
// ---------------------------------------------------------------------------

fn make_combo(comptime slots: []const c.ComboSlot) c.ActionCombo {
    var combo = c.ActionCombo{
        .slots = [_]c.ComboSlot{.{ .action = .damage }} ** c.MAX_COMBO_LEN,
        .len   = @intCast(slots.len),
    };
    @memcpy(combo.slots[0..slots.len], slots);
    return combo;
}

test "parse_combo: action-only — element is null for all" {
    const combo = make_combo(&[_]c.ComboSlot{
        .{ .action = .damage },
        .{ .action = .shield },
        .{ .action = .heal },
    });
    var out: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(c.ActionChoice.damage, out[0].action);
    try std.testing.expectEqual(@as(?c.Element, null), out[0].element);
    try std.testing.expectEqual(c.ActionChoice.shield, out[1].action);
    try std.testing.expectEqual(@as(?c.Element, null), out[1].element);
    try std.testing.expectEqual(c.ActionChoice.heal, out[2].action);
    try std.testing.expectEqual(@as(?c.Element, null), out[2].element);
}

test "parse_combo: element persists across following actions" {
    // [fire, damage, damage] → both actions are fire
    const combo = make_combo(&[_]c.ComboSlot{
        .{ .element = .fire },
        .{ .action  = .damage },
        .{ .action  = .damage },
    });
    var out: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(c.Element.fire, out[0].element.?);
    try std.testing.expectEqual(c.Element.fire, out[1].element.?);
}

test "parse_combo: second element overrides first" {
    // [fire, damage, water, shield] → fire-damage, water-shield
    const combo = make_combo(&[_]c.ComboSlot{
        .{ .element = .fire  },
        .{ .action  = .damage },
        .{ .element = .water },
        .{ .action  = .shield },
    });
    var out: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(c.Element.fire,  out[0].element.?);
    try std.testing.expectEqual(c.Element.water, out[1].element.?);
}

test "parse_combo: trailing element is silently dropped" {
    // [damage, fire] → 1 action (no element), fire token dropped
    const combo = make_combo(&[_]c.ComboSlot{
        .{ .action  = .damage },
        .{ .element = .fire   },
    });
    var out: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(?c.Element, null), out[0].element);
}

test "parse_combo: mixed — fire persists, water overrides" {
    // [fire, damage, damage, water, shield] — but MAX_COMBO_LEN=4 so truncate:
    // [fire, damage, water, shield] → fire-damage, water-shield
    const combo = make_combo(&[_]c.ComboSlot{
        .{ .element = .fire  },
        .{ .action  = .damage },
        .{ .element = .water },
        .{ .action  = .shield },
    });
    var out: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(c.ActionChoice.damage, out[0].action);
    try std.testing.expectEqual(c.Element.fire,        out[0].element.?);
    try std.testing.expectEqual(c.ActionChoice.shield, out[1].action);
    try std.testing.expectEqual(c.Element.water,       out[1].element.?);
}
