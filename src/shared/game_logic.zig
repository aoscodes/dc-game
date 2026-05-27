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

/// Apply `net_count` damage actions of the given element to `health`.
/// Caller is responsible for netting damage against shield actions before calling.
/// Returns HP damage dealt.
pub fn resolve_damage_pool(
    health: *c.Health,
    net_count: u16,
    element: ?c.Element,
) u16 {
    _ = element; // element is metadata only; callers track it for floaters/logs
    const total = net_count * ACTION_EFFECT_VALUE;
    if (total == 0) return 0;
    apply_damage(health, total);
    return total;
}

pub fn resolve_heal_pool(health: *c.Health, pool_size: u16) void {
    apply_heal(health, pool_size * ACTION_EFFECT_VALUE);
}

pub const EnemyIntent = struct {
    damage_per_player: u16,
    /// null = non-elemental.  Chosen per-round by the session; extensible for future AI.
    element: ?c.Element,
};

/// Returns a bitmask (bit i = `@intFromEnum(Element)` ordinal i, 0=fire…3=water)
/// of elements whose action group in `combo` is **exactly** one damage and one
/// heal — no other actions.  Groups are delimited by element tokens; actions
/// before the first element token are null-element and never trigger DoT.
///
/// Examples:
///   [♦, dmg, heal]           → fire bit set   (group = {dmg, heal})
///   [♦, dmg, heal, shield]   → 0              (group = {dmg, heal, shield})
///   [♦, dmg, heal, ≋, dmg]   → fire bit set   (fire group = {dmg,heal}; wind = {dmg})
///   [♦, dmg, dmg, heal]      → 0              (two dmg in fire group)
///   [♦, dmg, shield, heal]   → 0              (shield in fire group)
///
/// Used by `session.resolve_round` to determine which elemental DoT stacks to
/// apply to the receiving party after damage has cleared the opponent's shields.
pub fn detect_dot_triggers(combo: c.ActionCombo) u4 {
    var trigger_mask: u4 = 0;
    var current_el:   ?c.Element = null;
    var dmg_count:    u8 = 0;
    var heal_count:   u8 = 0;
    var other_count:  u8 = 0; // shields or any non-dmg/heal action

    const flush = struct {
        fn f(mask: *u4, el: c.Element, dc: u8, hc: u8, oc: u8) void {
            if (dc == 1 and hc == 1 and oc == 0)
                mask.* |= @as(u4, 1) << @as(u2, @intCast(@intFromEnum(el)));
        }
    }.f;

    for (combo.slots[0..combo.len]) |slot| {
        switch (slot) {
            .element => |el| {
                if (current_el) |prev| flush(&trigger_mask, prev, dmg_count, heal_count, other_count);
                current_el  = el;
                dmg_count   = 0;
                heal_count  = 0;
                other_count = 0;
            },
            .action => |ac| {
                if (current_el == null) continue; // null-element actions never trigger DoT
                switch (ac) {
                    .damage => dmg_count  +|= 1,
                    .heal   => heal_count +|= 1,
                    .shield => other_count +|= 1,
                }
            },
        }
    }
    if (current_el) |prev| flush(&trigger_mask, prev, dmg_count, heal_count, other_count);
    return trigger_mask;
}

/// Returns a bitmask (bit i = `@intFromEnum(Element)` ordinal i, 0=fire…3=water)
/// of elements whose action group in `combo` is **exactly** one heal and one
/// shield — no other actions.  Submitting this pattern consumes the heal and
/// shield (they are withheld from normal pools) and removes 1 DoT stack of
/// that element from the caster's own side.
///
/// Examples:
///   [♦, heal, shield]        → fire bit set
///   [♦, heal, shield, dmg]   → 0   (extra action in group)
///   [♦, heal, heal, shield]  → 0   (extra heal)
///   [♦, dmg, heal, shield]   → 0   (damage present)
///   [heal, shield]            → 0   (no element token)
pub fn detect_cleanse_triggers(combo: c.ActionCombo) u4 {
    var trigger_mask: u4 = 0;
    var current_el:   ?c.Element = null;
    var heal_count:   u8 = 0;
    var shield_count: u8 = 0;
    var other_count:  u8 = 0; // damage or any extra action beyond {heal, shield}

    const flush = struct {
        fn f(mask: *u4, el: c.Element, hc: u8, sc: u8, oc: u8) void {
            if (hc == 1 and sc == 1 and oc == 0)
                mask.* |= @as(u4, 1) << @as(u2, @intCast(@intFromEnum(el)));
        }
    }.f;

    for (combo.slots[0..combo.len]) |slot| {
        switch (slot) {
            .element => |el| {
                if (current_el) |prev| flush(&trigger_mask, prev, heal_count, shield_count, other_count);
                current_el    = el;
                heal_count    = 0;
                shield_count  = 0;
                other_count   = 0;
            },
            .action => |ac| {
                if (current_el == null) continue;
                switch (ac) {
                    .heal   => heal_count   +|= 1,
                    .shield => shield_count +|= 1,
                    .damage => other_count  +|= 1,
                }
            },
        }
    }
    if (current_el) |prev| flush(&trigger_mask, prev, heal_count, shield_count, other_count);
    return trigger_mask;
}

pub fn compute_enemy_intent(living_enemy_count: u16, element: ?c.Element) EnemyIntent {
    return .{ .damage_per_player = living_enemy_count, .element = element };
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

test "resolve_damage_pool: applies net_count * V damage" {
    const V = ACTION_EFFECT_VALUE;
    var h = c.Health{ .current = V * 10, .max = V * 10 };
    const dealt = resolve_damage_pool(&h, 3, null);
    try std.testing.expectEqual(3 * V, dealt);
    try std.testing.expectEqual(V * 7, h.current);
}

test "resolve_damage_pool: zero net_count — no change" {
    var h = c.Health{ .current = 10, .max = 10 };
    const dealt = resolve_damage_pool(&h, 0, null);
    try std.testing.expectEqual(@as(u16, 0), dealt);
    try std.testing.expectEqual(@as(u16, 10), h.current);
}

test "resolve_damage_pool: element arg is ignored (metadata only)" {
    const V = ACTION_EFFECT_VALUE;
    var h = c.Health{ .current = V * 5, .max = V * 5 };
    const dealt = resolve_damage_pool(&h, 2, .fire);
    try std.testing.expectEqual(2 * V, dealt);
    try std.testing.expectEqual(V * 3, h.current);
}

test "resolve_heal_pool: heals" {
    const V = ACTION_EFFECT_VALUE;
    var h = c.Health{ .current = 5, .max = V * 10 };
    resolve_heal_pool(&h, 1);
    try std.testing.expectEqual(@as(u16, 5 + V), h.current);
}

test "resolve_heal_pool: at max HP — no overflow" {
    var h = c.Health{ .current = 100, .max = 100 };
    resolve_heal_pool(&h, 10);
    try std.testing.expectEqual(@as(u16, 100), h.current);
}

test "compute_enemy_intent: 1 dmg per living enemy" {
    const intent = compute_enemy_intent(42, null);
    try std.testing.expectEqual(@as(u16, 42), intent.damage_per_player);
    try std.testing.expectEqual(@as(?c.Element, null), intent.element);
}

test "compute_enemy_intent: zero enemies — zero damage" {
    const intent = compute_enemy_intent(0, null);
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

// ---------------------------------------------------------------------------
// detect_dot_triggers tests
// ---------------------------------------------------------------------------

test "detect_dot_triggers: [fire,dmg,heal] → fire bit set" {
    const mask = detect_dot_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    }));
    try std.testing.expectEqual(@as(u4, 0b0001), mask); // bit 0 = fire
}

test "detect_dot_triggers: [fire,dmg,earth,heal] → 0 (dmg and heal in different groups)" {
    const mask = detect_dot_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .element = .earth  },
        .{ .action  = .heal   },
    }));
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_dot_triggers: [fire,dmg,shield] — no heal → 0" {
    const mask = detect_dot_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .shield },
    }));
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_dot_triggers: [fire,dmg,shield,heal] → 0 (shield in group blocks DoT)" {
    // MAX_COMBO_LEN=4 fits all four slots exactly
    const mask = detect_dot_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .shield },
        .{ .action  = .heal   },
    }));
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_dot_triggers: [fire,dmg,heal,wind] → fire bit only (wind group empty)" {
    // fire group = {dmg,heal} → triggers; wind token is trailing with no action → no trigger
    const mask = detect_dot_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .heal   },
        .{ .element = .wind   },
    }));
    try std.testing.expectEqual(@as(u4, 0b0001), mask);
}

test "detect_dot_triggers: [fire,dmg,dmg,heal] → 0 (extra dmg blocks)" {
    const mask = detect_dot_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    }));
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_dot_triggers: null-element dmg+heal → 0 (no element = no DoT)" {
    const mask = detect_dot_triggers(make_combo(&[_]c.ComboSlot{
        .{ .action = .damage },
        .{ .action = .heal   },
    }));
    try std.testing.expectEqual(@as(u4, 0), mask);
}

// ---------------------------------------------------------------------------
// detect_cleanse_triggers tests
// ---------------------------------------------------------------------------

test "detect_cleanse_triggers: [fire,heal,shield] → fire bit set" {
    const mask = detect_cleanse_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    }));
    try std.testing.expectEqual(@as(u4, 0b0001), mask);
}

test "detect_cleanse_triggers: [fire,heal,shield,wind] → fire bit only (wind group empty)" {
    const mask = detect_cleanse_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
        .{ .element = .wind   },
    }));
    try std.testing.expectEqual(@as(u4, 0b0001), mask);
}

test "detect_cleanse_triggers: [fire,heal,shield,dmg] → 0 (extra action in group)" {
    const mask = detect_cleanse_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
        .{ .action  = .damage },
    }));
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_cleanse_triggers: [fire,heal,heal,shield] → 0 (extra heal)" {
    const mask = detect_cleanse_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    }));
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_cleanse_triggers: [fire,dmg,heal,shield] → 0 (damage present)" {
    const mask = detect_cleanse_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    }));
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_cleanse_triggers: [heal,shield] → 0 (no element token)" {
    const mask = detect_cleanse_triggers(make_combo(&[_]c.ComboSlot{
        .{ .action = .heal   },
        .{ .action = .shield },
    }));
    try std.testing.expectEqual(@as(u4, 0), mask);
}
