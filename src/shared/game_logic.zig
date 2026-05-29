const std = @import("std");
const c = @import("components.zig");
const balance = @import("balance.zig");

pub const ROUND_DURATION_DEFAULT_S: f32 = 3.0;

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

/// Apply `net_damage` to `health`.
/// Caller is responsible for netting damage against shield actions before calling.
/// Returns HP damage dealt.
pub fn resolve_damage_pool(
    health: *c.Health,
    net_damage: u16,
    element: ?c.Element,
) u16 {
    _ = element; // element is metadata only; callers track it for floaters/logs
    if (net_damage == 0) return 0;
    apply_damage(health, net_damage);
    return net_damage;
}

pub fn resolve_heal_pool(health: *c.Health, heal_amount: u16) void {
    apply_heal(health, heal_amount);
}

pub const EnemyIntent = struct {
    damage_per_player: u16,
    /// null = non-elemental.  Chosen per-round by the session; extensible for future AI.
    element: ?c.Element,
};

pub fn compute_enemy_intent(living_enemy_count: u16, element: ?c.Element) EnemyIntent {
    return .{ .damage_per_player = living_enemy_count, .element = element };
}

/// Returns a bitmask (bit i = `@intFromEnum(Element)` ordinal i, 0=fire…3=water)
/// of elements whose elemental group in `combo` exactly matches the action counts
/// required by `trigger` (trigger.damage damage actions, trigger.shield shield
/// actions, trigger.heal heal actions — no others in that group).
///
/// Null-element groups (actions before the first element token) never trigger.
///
/// Used by session.resolve_round to determine which special combos fired and
/// which actions should be withheld from normal pools.
pub fn detect_triggers(combo: c.ActionCombo, trigger: balance.ComboTrigger) u4 {
    var trigger_mask: u4 = 0;
    var current_el:   ?c.Element = null;
    var dmg_count:    u8 = 0;
    var shd_count:    u8 = 0;
    var heal_count:   u8 = 0;

    const flush = struct {
        fn f(
            mask:    *u4,
            el:      c.Element,
            dc:      u8,
            sc:      u8,
            hc:      u8,
            t:       balance.ComboTrigger,
        ) void {
            if (dc == t.damage and sc == t.shield and hc == t.heal)
                mask.* |= @as(u4, 1) << @as(u2, @intCast(@intFromEnum(el)));
        }
    }.f;

    for (combo.slots[0..combo.len]) |slot| {
        switch (slot) {
            .element => |el| {
                if (current_el) |prev|
                    flush(&trigger_mask, prev, dmg_count, shd_count, heal_count, trigger);
                current_el  = el;
                dmg_count   = 0;
                shd_count   = 0;
                heal_count  = 0;
            },
            .action => |ac| {
                if (current_el == null) continue; // null-element groups never trigger
                switch (ac) {
                    .damage => dmg_count  +|= 1,
                    .shield => shd_count  +|= 1,
                    .heal   => heal_count +|= 1,
                }
            },
        }
    }
    if (current_el) |prev|
        flush(&trigger_mask, prev, dmg_count, shd_count, heal_count, trigger);
    return trigger_mask;
}

// ---------------------------------------------------------------------------
// Combo tallying
// ---------------------------------------------------------------------------

/// Map a bucket index back to an optional Element (inverse of element_key).
pub fn key_to_element(k: usize) ?c.Element {
    return if (k == 0) null else @enumFromInt(k - 1);
}

/// Return the Statblock field matching the given element (0 for null-element).
fn element_stat(sb: c.Statblock, el: ?c.Element) u16 {
    return if (el) |e| switch (e) {
        .fire  => sb.fire,
        .earth => sb.earth,
        .wind  => sb.wind,
        .water => sb.water,
    } else 0;
}

/// Build a FormulaCtx from a Statblock and optional element.
/// `base` is the ActionValues multiplier for this action type.
fn statblock_ctx(base: u16, sb: c.Statblock, el: ?c.Element) balance.FormulaCtx {
    return .{
        .base         = base,
        .attack       = sb.attack,
        .shield_stat  = sb.shield,
        .heal_stat    = sb.heal,
        .element_stat = element_stat(sb, el),
        .level        = sb.level,
    };
}

/// Per-side accumulation of one round's combo contributions, bucketed by
/// element.  Produced by repeated `tally_combo` calls; consumed by the
/// netting/application steps in session.resolve_round.
pub const SideTally = struct {
    /// Direct damage per ElementKey bucket (0=none,1=fire…4=water).
    damage_by_key:      [c.ElementKey.size]u16 = [_]u16{0} ** c.ElementKey.size,
    /// Shield absorb per ElementKey bucket.
    shield_by_key:      [c.ElementKey.size]u16 = [_]u16{0} ** c.ElementKey.size,
    /// Withheld DoT-trigger damage per ElementKey bucket (peek-net in Step 3).
    dot_dmg_by_key:     [c.ElementKey.size]u16 = [_]u16{0} ** c.ElementKey.size,
    /// Stacks to add per Element if withheld damage survives shields (Step 3).
    dot_stacks_pending: [c.Element.size]u16 = [_]u16{0} ** c.Element.size,
    /// Cleanse stacks removed from own side per Element (Step 2.5).
    cleanse_by_el:      [c.Element.size]u16 = [_]u16{0} ** c.Element.size,
    /// Flat heal pool contributed this round.
    heal_pool:          u16 = 0,
};

/// Tally one combo cast by an entity with statblock `sb` into `tally`.
///
/// Each action is checked against every trigger in balance.combo_triggers.
/// Actions whose element matches a fired trigger's pattern are withheld from
/// the normal pools per trigger.withheld_*.  Withheld DoT damage/stacks and
/// cleanse stacks are accumulated separately for later resolution.  The
/// caster's Statblock scales each surviving action's contribution.
pub fn tally_combo(tally: *SideTally, combo: c.ActionCombo, sb: c.Statblock) void {
    var ea_buf: [c.MAX_COMBO_LEN]ElementedAction = undefined;

    // Compute per-trigger bitmasks once per combo.
    var trigger_masks: [balance.combo_triggers.len]u4 = undefined;
    inline for (balance.combo_triggers, 0..) |trigger, ti| {
        trigger_masks[ti] = detect_triggers(combo, trigger);
    }

    const n = parse_combo(combo, &ea_buf);
    for (ea_buf[0..n]) |ea| {
        const k = @intFromEnum(c.element_key(ea.element));
        const el_bit: u4 = if (ea.element) |el|
            @as(u4, 1) << @as(u2, @intCast(@intFromEnum(el)))
        else
            0;

        // Check if this action is withheld by any fired trigger.
        var withheld = false;
        if (el_bit != 0) {
            inline for (balance.combo_triggers, 0..) |trigger, ti| {
                if ((trigger_masks[ti] & el_bit) != 0) {
                    const consumed = switch (ea.action) {
                        .damage => trigger.withheld_damage,
                        .shield => trigger.withheld_shield,
                        .heal   => trigger.withheld_heal,
                    };
                    if (consumed) {
                        withheld = true;
                        if (trigger.kind == .dot and ea.action == .damage) {
                            // Accumulate withheld dmg (peek-net) and pending stacks.
                            const dmg_ctx = statblock_ctx(balance.basic.damage, sb, ea.element);
                            tally.dot_dmg_by_key[k] +|= balance.scale_damage(dmg_ctx);
                            const stk_ctx = statblock_ctx(trigger.dot_stacks_base, sb, ea.element);
                            const el_i: usize = @intFromEnum(ea.element.?);
                            tally.dot_stacks_pending[el_i] +|= balance.scale_dot_stacks(stk_ctx);
                        }
                        // Cleanse-withheld heal counted for Step 2.5.
                        if (trigger.kind == .cleanse and ea.action == .heal) {
                            const i: usize = @intFromEnum(ea.element.?);
                            tally.cleanse_by_el[i] +|= trigger.cleanse_stacks_removed;
                        }
                    }
                }
            }
        }

        if (!withheld) {
            const ctx = statblock_ctx(0, sb, ea.element);
            switch (ea.action) {
                .damage => tally.damage_by_key[k] +|= balance.scale_damage(
                    .{ .base = balance.basic.damage, .attack = ctx.attack,
                       .shield_stat = ctx.shield_stat, .heal_stat = ctx.heal_stat,
                       .element_stat = ctx.element_stat, .level = ctx.level }),
                .shield => tally.shield_by_key[k] +|= balance.scale_shield(
                    .{ .base = balance.basic.shield, .attack = ctx.attack,
                       .shield_stat = ctx.shield_stat, .heal_stat = ctx.heal_stat,
                       .element_stat = ctx.element_stat, .level = ctx.level }),
                .heal   => tally.heal_pool +|= balance.scale_heal(
                    .{ .base = balance.basic.heal, .attack = ctx.attack,
                       .shield_stat = ctx.shield_stat, .heal_stat = ctx.heal_stat,
                       .element_stat = ctx.element_stat, .level = ctx.level }),
            }
        }
    }
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

test "resolve_damage_pool: applies net damage" {
    var h = c.Health{ .current = 10, .max = 10 };
    const dealt = resolve_damage_pool(&h, 3, null);
    try std.testing.expectEqual(@as(u16, 3), dealt);
    try std.testing.expectEqual(@as(u16, 7), h.current);
}

test "resolve_damage_pool: zero net — no change" {
    var h = c.Health{ .current = 10, .max = 10 };
    const dealt = resolve_damage_pool(&h, 0, null);
    try std.testing.expectEqual(@as(u16, 0), dealt);
    try std.testing.expectEqual(@as(u16, 10), h.current);
}

test "resolve_damage_pool: element arg is ignored (metadata only)" {
    var h = c.Health{ .current = 5, .max = 5 };
    const dealt = resolve_damage_pool(&h, 2, .fire);
    try std.testing.expectEqual(@as(u16, 2), dealt);
    try std.testing.expectEqual(@as(u16, 3), h.current);
}

test "resolve_heal_pool: heals" {
    var h = c.Health{ .current = 5, .max = 10 };
    resolve_heal_pool(&h, 1);
    try std.testing.expectEqual(@as(u16, 6), h.current);
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
// detect_triggers tests — using the balance.combo_triggers table entries
// ---------------------------------------------------------------------------

const dot_trigger     = balance.combo_triggers[0]; // damage=1, shield=0, heal=1
const cleanse_trigger = balance.combo_triggers[1]; // damage=0, shield=1, heal=1

test "detect_triggers(dot): [fire,dmg,heal] → fire bit set" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    }), dot_trigger);
    try std.testing.expectEqual(@as(u4, 0b0001), mask);
}

test "detect_triggers(dot): [fire,dmg,earth,heal] → 0 (split group)" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .element = .earth  },
        .{ .action  = .heal   },
    }), dot_trigger);
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_triggers(dot): [fire,dmg,shield] — no heal → 0" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .shield },
    }), dot_trigger);
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_triggers(dot): [fire,dmg,shield,heal] → 0 (shield in group blocks)" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .shield },
        .{ .action  = .heal   },
    }), dot_trigger);
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_triggers(dot): [fire,dmg,heal,wind] → fire bit only (trailing wind empty)" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .heal   },
        .{ .element = .wind   },
    }), dot_trigger);
    try std.testing.expectEqual(@as(u4, 0b0001), mask);
}

test "detect_triggers(dot): [fire,dmg,dmg,heal] → 0 (extra dmg)" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    }), dot_trigger);
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_triggers(dot): null-element dmg+heal → 0 (no element)" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .action = .damage },
        .{ .action = .heal   },
    }), dot_trigger);
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_triggers(cleanse): [fire,heal,shield] → fire bit set" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    }), cleanse_trigger);
    try std.testing.expectEqual(@as(u4, 0b0001), mask);
}

test "detect_triggers(cleanse): [fire,heal,shield,wind] → fire bit only" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
        .{ .element = .wind   },
    }), cleanse_trigger);
    try std.testing.expectEqual(@as(u4, 0b0001), mask);
}

test "detect_triggers(cleanse): [fire,heal,shield,dmg] → 0 (extra action)" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
        .{ .action  = .damage },
    }), cleanse_trigger);
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_triggers(cleanse): [fire,heal,heal,shield] → 0 (extra heal)" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    }), cleanse_trigger);
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_triggers(cleanse): [fire,dmg,heal,shield] → 0 (damage present)" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    }), cleanse_trigger);
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_triggers(cleanse): [heal,shield] → 0 (no element token)" {
    const mask = detect_triggers(make_combo(&[_]c.ComboSlot{
        .{ .action = .heal   },
        .{ .action = .shield },
    }), cleanse_trigger);
    try std.testing.expectEqual(@as(u4, 0), mask);
}

test "detect_triggers: dot does not match cleanse pattern and vice versa" {
    const dot_combo = make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    });
    const cleanse_combo = make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    });
    // dot combo should not match cleanse trigger
    try std.testing.expectEqual(@as(u4, 0), detect_triggers(dot_combo, cleanse_trigger));
    // cleanse combo should not match dot trigger
    try std.testing.expectEqual(@as(u4, 0), detect_triggers(cleanse_combo, dot_trigger));
}

// ---------------------------------------------------------------------------
// key_to_element tests
// ---------------------------------------------------------------------------

test "key_to_element: 0 → null, 1..4 → fire..water" {
    try std.testing.expectEqual(@as(?c.Element, null), key_to_element(0));
    try std.testing.expectEqual(c.Element.fire,  key_to_element(1).?);
    try std.testing.expectEqual(c.Element.earth, key_to_element(2).?);
    try std.testing.expectEqual(c.Element.wind,  key_to_element(3).?);
    try std.testing.expectEqual(c.Element.water, key_to_element(4).?);
}

test "key_to_element: round-trips element_key" {
    inline for (.{ null, c.Element.fire, c.Element.earth, c.Element.wind, c.Element.water }) |el| {
        const k = @intFromEnum(c.element_key(el));
        try std.testing.expectEqual(@as(?c.Element, el), key_to_element(k));
    }
}

// ---------------------------------------------------------------------------
// tally_combo tests
// ---------------------------------------------------------------------------

/// Unit statblock: every scaling stat is 1, so each surviving action
/// contributes exactly its `basic` base value (also 1).
const unit_sb = c.Statblock{
    .attack = 1, .shield = 1, .heal = 1,
    .fire = 1, .earth = 1, .wind = 1, .water = 1,
    .hp = 120, .level = 1,
};

test "tally_combo: plain elemental damage lands in damage bucket" {
    var t = SideTally{};
    tally_combo(&t, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
    }), unit_sb);
    const fire_k = @intFromEnum(c.element_key(.fire));
    try std.testing.expectEqual(@as(u16, balance.basic.damage), t.damage_by_key[fire_k]);
    try std.testing.expectEqual(@as(u16, 0), t.heal_pool);
}

test "tally_combo: null-element shield + heal" {
    var t = SideTally{};
    tally_combo(&t, make_combo(&[_]c.ComboSlot{
        .{ .action = .shield },
        .{ .action = .heal   },
    }), unit_sb);
    const none_k = @intFromEnum(c.element_key(null));
    try std.testing.expectEqual(@as(u16, balance.basic.shield), t.shield_by_key[none_k]);
    try std.testing.expectEqual(@as(u16, balance.basic.heal), t.heal_pool);
}

test "tally_combo: DoT trigger withholds dmg+heal, records pending stacks" {
    var t = SideTally{};
    // [fire, damage, heal] matches the dot trigger.
    tally_combo(&t, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
        .{ .action  = .heal   },
    }), unit_sb);
    const fire_k = @intFromEnum(c.element_key(.fire));
    const fire_i: usize = @intFromEnum(c.Element.fire);
    // Withheld: nothing in normal pools.
    try std.testing.expectEqual(@as(u16, 0), t.damage_by_key[fire_k]);
    try std.testing.expectEqual(@as(u16, 0), t.heal_pool);
    // Withheld dmg recorded for peek-net, and pending stacks set.
    try std.testing.expectEqual(@as(u16, balance.basic.damage), t.dot_dmg_by_key[fire_k]);
    try std.testing.expect(t.dot_stacks_pending[fire_i] > 0);
}

test "tally_combo: cleanse trigger withholds heal+shield, records cleanse" {
    var t = SideTally{};
    // [fire, heal, shield] matches the cleanse trigger.
    tally_combo(&t, make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .heal   },
        .{ .action  = .shield },
    }), unit_sb);
    const fire_k = @intFromEnum(c.element_key(.fire));
    const fire_i: usize = @intFromEnum(c.Element.fire);
    try std.testing.expectEqual(@as(u16, 0), t.heal_pool);
    try std.testing.expectEqual(@as(u16, 0), t.shield_by_key[fire_k]);
    try std.testing.expectEqual(
        @as(u16, balance.combo_triggers[1].cleanse_stacks_removed),
        t.cleanse_by_el[fire_i],
    );
}

test "tally_combo: accumulates across multiple calls" {
    var t = SideTally{};
    const dmg_combo = make_combo(&[_]c.ComboSlot{
        .{ .element = .fire   },
        .{ .action  = .damage },
    });
    tally_combo(&t, dmg_combo, unit_sb);
    tally_combo(&t, dmg_combo, unit_sb);
    const fire_k = @intFromEnum(c.element_key(.fire));
    try std.testing.expectEqual(@as(u16, 2 * balance.basic.damage), t.damage_by_key[fire_k]);
}
