//! Pure resolution logic for the Slime Feast encounter.
//!
//! Round resolution pipeline (driven by session.resolve_round):
//!   1. `match_recipes`   — convert the round's committed casts into one
//!                          AgentOutput (team recipes → player recipes →
//!                          flat fallback; team recipes need distinct players).
//!   2. `apply_medicine`  — heal the hunger bar, capped by the healable
//!                          (modified-slime) portion.
//!   3. `resolve_zone`    — neutralize matching-color slime with the agent
//!                          units, then consume the whole zone: compute
//!                          hunger added (normal + extra) and score.
//!
//! All functions here are pure/deterministic and unit-testable without a
//! session.

const std = @import("std");
const c = @import("components.zig");
const balance = @import("balance.zig");

pub const ROUND_DURATION_DEFAULT_S: f32 = 15.0;

/// An action slot with its resolved element modifier (null = no element).
pub const ElementedAction = struct {
    action: c.ActionChoice,
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
            .action => |ac| {
                out[count] = .{ .action = ac, .element = current_element };
                count += 1;
                // Element persists — do NOT reset current_element here.
            },
        }
    }
    return count;
}

// ---------------------------------------------------------------------------
// Combo → AgentOutput conversion
// ---------------------------------------------------------------------------

/// Exact structural equality: same length, same slots in the same order.
pub fn combos_equal(a: c.ActionCombo, b: c.ActionCombo) bool {
    if (a.len != b.len) return false;
    for (a.slots[0..a.len], b.slots[0..b.len]) |x, y| {
        if (!std.meta.eql(x, y)) return false;
    }
    return true;
}

/// Flat per-slot conversion for combos that match no recipe:
///   - dispense with an element → UNITS_PER_SLOT agent units of that color
///   - medicine with an element → MEDICINE_PER_SLOT medicine of that color
///   - either action with NO element → wasted (both are color-bound)
pub fn flat_convert(combo: c.ActionCombo) c.AgentOutput {
    var out = c.AgentOutput{};
    var ea_buf: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &ea_buf);
    for (ea_buf[0..n]) |ea| {
        const el = ea.element orelse continue; // colorless actions wasted
        switch (ea.action) {
            .dispense => out.units[@intFromEnum(el)] +|= balance.UNITS_PER_SLOT,
            .medicine => out.medicine[@intFromEnum(el)] +|= balance.MEDICINE_PER_SLOT,
        }
    }
    return out;
}

/// One committed spell: the combo plus its caster (recipes that span players
/// must be cast by distinct players).
pub const Cast = struct {
    player_id: u8,
    combo: c.ActionCombo,
};

/// Maximum casts per round == max players × casts each; sized for the
/// consumed-flag arrays.
const MAX_CASTS: usize = 64;

/// Convert one round's committed casts into the team's combined AgentOutput.
///
/// Matching order (a cast is consumed by at most one recipe):
///   1. Team recipes, greedily in balance.team_recipes order.  Each pattern
///      must be matched exactly by a DISTINCT player's cast — one player
///      casting both halves does not trigger a team recipe.  A recipe
///      repeats while disjoint groups keep matching.
///   2. Player recipes in balance.player_recipes order (exact match).
///   3. Flat conversion fallback (flat_convert).
pub fn match_recipes(casts: []const Cast) c.AgentOutput {
    std.debug.assert(casts.len <= MAX_CASTS);
    var out = c.AgentOutput{};
    var consumed = [_]bool{false} ** MAX_CASTS;

    // 1. Team recipes — greedy, repeatable, table order, distinct players.
    for (balance.team_recipes) |tr| {
        matching: while (true) {
            var picks: [MAX_CASTS]usize = undefined;
            var picked = [_]bool{false} ** MAX_CASTS;
            for (tr.patterns, 0..) |pattern, pi| {
                const found = for (casts, 0..) |cast, ci| {
                    if (consumed[ci] or picked[ci]) continue;
                    // Distinct players: skip casts by anyone already picked
                    // for this recipe instance.
                    const player_taken = for (picks[0..pi]) |prev| {
                        if (casts[prev].player_id == cast.player_id) break true;
                    } else false;
                    if (player_taken) continue;
                    if (combos_equal(cast.combo, pattern)) break ci;
                } else null;
                const ci = found orelse break :matching;
                picks[pi] = ci;
                picked[ci] = true;
            }
            for (tr.patterns, 0..) |_, pi| consumed[picks[pi]] = true;
            out.add(tr.output);
        }
    }

    // 2. Player recipes.
    for (casts, 0..) |cast, ci| {
        if (consumed[ci]) continue;
        for (balance.player_recipes) |pr| {
            if (combos_equal(cast.combo, pr.pattern)) {
                out.add(pr.output);
                consumed[ci] = true;
                break;
            }
        }
    }

    // 3. Flat fallback.
    for (casts, 0..) |cast, ci| {
        if (consumed[ci]) continue;
        out.add(flat_convert(cast.combo));
    }

    return out;
}

// ---------------------------------------------------------------------------
// Hunger + zone consumption
// ---------------------------------------------------------------------------

/// Heal the hunger bar with per-color medicine pools.  Medicine is
/// symmetrical: the color-X pool heals only `healable[X]` — the hunger
/// attributable to eating un-neutralized color-X Modified Slime — and is
/// further capped by the current hunger level.  Overheal is discarded.
/// Returns the total amount actually healed.
pub fn apply_medicine(
    hunger: *c.Health,
    healable: *[c.Element.size]u16,
    pools: [c.Element.size]u32,
) u16 {
    var total: u16 = 0;
    for (pools, 0..) |pool, i| {
        const cap = @min(@as(u32, healable[i]), @as(u32, hunger.current));
        const heal: u16 = @intCast(@min(pool, cap));
        hunger.current -= heal;
        healable[i] -= heal;
        total += heal;
    }
    return total;
}

/// Add hunger, clamping at max.
pub fn add_hunger(hunger: *c.Health, amount: u32) void {
    const total = @min(@as(u32, hunger.current) + amount, @as(u32, hunger.max));
    hunger.current = @intCast(total);
}

pub fn hunger_full(hunger: c.Health) bool {
    return hunger.max > 0 and hunger.current >= hunger.max;
}

pub const ZoneOutcome = struct {
    /// Modified units neutralized per color this round.
    neutralized: [c.Element.size]u16,
    /// Modified units consumed WITHOUT neutralization (extra hunger).
    modified_consumed: u32,
    /// Hunger from consuming every unit at the normal rate (never healable).
    hunger_normal: u32,
    /// Extra hunger per color from un-neutralized modified units of that
    /// color.  Healable only by matching-color medicine.
    hunger_extra: [c.Element.size]u32,
    /// Score gained: neutralized units + naturally-neutral units.
    score: u32,

    pub fn hunger_extra_total(self: ZoneOutcome) u32 {
        var total: u32 = 0;
        for (self.hunger_extra) |e| total += e;
        return total;
    }
};

/// Resolve the end-of-round consumption of `zone` given the team's agent
/// units.  `neutralized[color] = min(agents[color], zone.modified[color])`;
/// excess and wrong-color agents are wasted.  The ENTIRE zone is consumed:
/// every unit costs HUNGER_COST_NORMAL, and each un-neutralized modified
/// unit additionally costs HUNGER_COST_MODIFIED_EXTRA (healable, tracked
/// per color).
pub fn resolve_zone(zone: c.ZoneDef, agents: [c.Element.size]u32) ZoneOutcome {
    var neutralized = [_]u16{0} ** c.Element.size;
    var hunger_extra = [_]u32{0} ** c.Element.size;
    var neutralized_total: u32 = 0;
    var modified_consumed: u32 = 0;
    for (zone.modified, 0..) |mod, i| {
        const n: u16 = @intCast(@min(agents[i], @as(u32, mod)));
        neutralized[i] = n;
        neutralized_total += n;
        const missed = mod - n;
        modified_consumed += missed;
        hunger_extra[i] = @as(u32, missed) * balance.HUNGER_COST_MODIFIED_EXTRA;
    }
    return .{
        .neutralized = neutralized,
        .modified_consumed = modified_consumed,
        .hunger_normal = zone.total_units() * balance.HUNGER_COST_NORMAL,
        .hunger_extra = hunger_extra,
        .score = neutralized_total + zone.neutral,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const mk = c.make_combo;

test "parse_combo: action-only — element is null for all" {
    const combo = mk(&.{
        .{ .action = .dispense },
        .{ .action = .medicine },
    });
    var out: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(c.ActionChoice.dispense, out[0].action);
    try std.testing.expectEqual(@as(?c.Element, null), out[0].element);
    try std.testing.expectEqual(c.ActionChoice.medicine, out[1].action);
    try std.testing.expectEqual(@as(?c.Element, null), out[1].element);
}

test "parse_combo: element persists across following actions" {
    const combo = mk(&.{
        .{ .element = .fire },
        .{ .action = .dispense },
        .{ .action = .dispense },
    });
    var out: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(c.Element.fire, out[0].element.?);
    try std.testing.expectEqual(c.Element.fire, out[1].element.?);
}

test "parse_combo: second element overrides first" {
    const combo = mk(&.{
        .{ .element = .fire },
        .{ .action = .dispense },
        .{ .element = .water },
        .{ .action = .dispense },
    });
    var out: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(c.Element.fire, out[0].element.?);
    try std.testing.expectEqual(c.Element.water, out[1].element.?);
}

test "parse_combo: trailing element is silently dropped" {
    const combo = mk(&.{
        .{ .action = .dispense },
        .{ .element = .fire },
    });
    var out: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(?c.Element, null), out[0].element);
}

test "combos_equal: identical combos match" {
    const a = mk(&.{ .{ .element = .fire }, .{ .action = .dispense } });
    const b = mk(&.{ .{ .element = .fire }, .{ .action = .dispense } });
    try std.testing.expect(combos_equal(a, b));
}

test "combos_equal: different length / slot / order do not match" {
    const base = mk(&.{ .{ .element = .fire }, .{ .action = .dispense } });
    const longer = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } });
    const other_el = mk(&.{ .{ .element = .water }, .{ .action = .dispense } });
    const reordered = mk(&.{ .{ .action = .dispense }, .{ .element = .fire } });
    try std.testing.expect(!combos_equal(base, longer));
    try std.testing.expect(!combos_equal(base, other_el));
    try std.testing.expect(!combos_equal(base, reordered));
}

test "flat_convert: elemental dispense yields UNITS_PER_SLOT per slot" {
    const out = flat_convert(mk(&.{
        .{ .element = .earth },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
    try std.testing.expectEqual(2 * balance.UNITS_PER_SLOT, out.units[@intFromEnum(c.Element.earth)]);
    for (out.medicine) |m| try std.testing.expectEqual(@as(u32, 0), m);
}

test "flat_convert: colorless dispense is wasted" {
    const out = flat_convert(mk(&.{.{ .action = .dispense }}));
    for (out.units) |u| try std.testing.expectEqual(@as(u32, 0), u);
}

test "flat_convert: medicine is color-bound; colorless medicine wasted" {
    const out = flat_convert(mk(&.{
        .{ .action = .medicine }, // colorless — wasted
        .{ .element = .fire },
        .{ .action = .medicine },
        .{ .element = .water },
        .{ .action = .medicine },
    }));
    try std.testing.expectEqual(balance.MEDICINE_PER_SLOT, out.medicine[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(balance.MEDICINE_PER_SLOT, out.medicine[@intFromEnum(c.Element.water)]);
    try std.testing.expectEqual(@as(u32, 0), out.medicine[@intFromEnum(c.Element.earth)]);
    for (out.units) |u| try std.testing.expectEqual(@as(u32, 0), u);
}

test "match_recipes: player recipe replaces flat conversion" {
    // crimson_flood: [fire, dispense×3] → 20 fire units (flat would be 15).
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }) },
    };
    const out = match_recipes(&casts);
    try std.testing.expectEqual(@as(u32, 20), out.units[@intFromEnum(c.Element.fire)]);
}

test "match_recipes: non-recipe combo falls back to flat conversion" {
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = mk(&.{ .{ .element = .wind }, .{ .action = .dispense } }) },
    };
    const out = match_recipes(&casts);
    try std.testing.expectEqual(balance.UNITS_PER_SLOT, out.units[@intFromEnum(c.Element.wind)]);
}

test "match_recipes: team recipe consumes both casts exactly once" {
    // twin_flames: 2 × [fire, dispense, dispense] → 30 fire + 2 fire medicine.
    const pat = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 1, .combo = pat },
    };
    const out = match_recipes(&casts);
    try std.testing.expectEqual(@as(u32, 30), out.units[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(@as(u32, 2), out.medicine[@intFromEnum(c.Element.fire)]);
}

test "match_recipes: team recipe fires twice for two disjoint pairs" {
    const pat = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 1, .combo = pat },
        .{ .player_id = 2, .combo = pat },
        .{ .player_id = 3, .combo = pat },
    };
    const out = match_recipes(&casts);
    try std.testing.expectEqual(@as(u32, 60), out.units[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(@as(u32, 4), out.medicine[@intFromEnum(c.Element.fire)]);
}

test "match_recipes: same player casting both halves does NOT fire team recipe" {
    // Team recipes require distinct players; one player's two twin_flames
    // halves fall back to flat conversion (2 × 2 × UNITS_PER_SLOT fire).
    const pat = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 0, .combo = pat },
    };
    const out = match_recipes(&casts);
    try std.testing.expectEqual(4 * balance.UNITS_PER_SLOT, out.units[@intFromEnum(c.Element.fire)]);
    for (out.medicine) |m| try std.testing.expectEqual(@as(u32, 0), m);
}

test "match_recipes: distinct-player pair still fires alongside same-player extras" {
    // Players 0 and 1 form one twin_flames pair; player 0's second half has
    // no distinct partner left and converts flat.
    const pat = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 1, .combo = pat },
    };
    const out = match_recipes(&casts);
    try std.testing.expectEqual(30 + 2 * balance.UNITS_PER_SLOT, out.units[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(@as(u32, 2), out.medicine[@intFromEnum(c.Element.fire)]);
}

test "match_recipes: lone half of a team recipe falls back to flat" {
    // One [fire, dispense, dispense] alone: no team match, no player recipe
    // (crimson_flood needs 3 dispenses) → flat 2 × UNITS_PER_SLOT.
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } }) },
    };
    const out = match_recipes(&casts);
    try std.testing.expectEqual(2 * balance.UNITS_PER_SLOT, out.units[@intFromEnum(c.Element.fire)]);
    for (out.medicine) |m| try std.testing.expectEqual(@as(u32, 0), m);
}

test "match_recipes: mixed — team pair + independent flat combo" {
    const pat = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } });
    const flat = mk(&.{ .{ .element = .water }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 1, .combo = flat },
        .{ .player_id = 2, .combo = pat },
    };
    const out = match_recipes(&casts);
    try std.testing.expectEqual(@as(u32, 30), out.units[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(balance.UNITS_PER_SLOT, out.units[@intFromEnum(c.Element.water)]);
}

test "apply_medicine: capped by matching-color healable portion" {
    var hunger = c.Health{ .current = 50, .max = 100 };
    var healable = [_]u16{0} ** c.Element.size;
    healable[@intFromEnum(c.Element.fire)] = 10;
    var pools = [_]u32{0} ** c.Element.size;
    pools[@intFromEnum(c.Element.fire)] = 25;
    const healed = apply_medicine(&hunger, &healable, pools);
    try std.testing.expectEqual(@as(u16, 10), healed);
    try std.testing.expectEqual(@as(u16, 40), hunger.current);
    try std.testing.expectEqual(@as(u16, 0), healable[@intFromEnum(c.Element.fire)]);
}

test "apply_medicine: asymmetric medicine heals nothing" {
    // Water medicine vs fire healable hunger: no effect.
    var hunger = c.Health{ .current = 50, .max = 100 };
    var healable = [_]u16{0} ** c.Element.size;
    healable[@intFromEnum(c.Element.fire)] = 20;
    var pools = [_]u32{0} ** c.Element.size;
    pools[@intFromEnum(c.Element.water)] = 99;
    const healed = apply_medicine(&hunger, &healable, pools);
    try std.testing.expectEqual(@as(u16, 0), healed);
    try std.testing.expectEqual(@as(u16, 50), hunger.current);
    try std.testing.expectEqual(@as(u16, 20), healable[@intFromEnum(c.Element.fire)]);
}

test "apply_medicine: multiple colors heal independently" {
    var hunger = c.Health{ .current = 50, .max = 100 };
    var healable = [_]u16{ 10, 0, 4, 8 };
    const pools = [_]u32{ 3, 99, 99, 8 };
    const healed = apply_medicine(&hunger, &healable, pools);
    // fire 3 + earth 0 + wind 4 + water 8 = 15.
    try std.testing.expectEqual(@as(u16, 15), healed);
    try std.testing.expectEqual(@as(u16, 35), hunger.current);
    try std.testing.expectEqual(@as(u16, 7), healable[0]);
    try std.testing.expectEqual(@as(u16, 0), healable[2]);
    try std.testing.expectEqual(@as(u16, 0), healable[3]);
}

test "apply_medicine: capped by current hunger" {
    var hunger = c.Health{ .current = 3, .max = 100 };
    var healable = [_]u16{0} ** c.Element.size;
    healable[@intFromEnum(c.Element.fire)] = 50;
    var pools = [_]u32{0} ** c.Element.size;
    pools[@intFromEnum(c.Element.fire)] = 25;
    const healed = apply_medicine(&hunger, &healable, pools);
    try std.testing.expectEqual(@as(u16, 3), healed);
    try std.testing.expectEqual(@as(u16, 0), hunger.current);
    try std.testing.expectEqual(@as(u16, 47), healable[@intFromEnum(c.Element.fire)]);
}

test "apply_medicine: zero healable — neutral consumption not healable" {
    var hunger = c.Health{ .current = 80, .max = 100 };
    var healable = [_]u16{0} ** c.Element.size;
    const pools = [_]u32{99} ** c.Element.size;
    const healed = apply_medicine(&hunger, &healable, pools);
    try std.testing.expectEqual(@as(u16, 0), healed);
    try std.testing.expectEqual(@as(u16, 80), hunger.current);
}

test "add_hunger: clamps at max" {
    var hunger = c.Health{ .current = 190, .max = 200 };
    add_hunger(&hunger, 50);
    try std.testing.expectEqual(@as(u16, 200), hunger.current);
    try std.testing.expect(hunger_full(hunger));
}

test "resolve_zone: partial neutralization (25 of 50)" {
    var zone = c.ZoneDef{};
    zone.modified[@intFromEnum(c.Element.fire)] = 50;
    var agents = [_]u32{0} ** c.Element.size;
    agents[@intFromEnum(c.Element.fire)] = 25;
    const outcome = resolve_zone(zone, agents);
    try std.testing.expectEqual(@as(u16, 25), outcome.neutralized[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(@as(u32, 25), outcome.modified_consumed);
    try std.testing.expectEqual(50 * balance.HUNGER_COST_NORMAL, outcome.hunger_normal);
    try std.testing.expectEqual(25 * balance.HUNGER_COST_MODIFIED_EXTRA, outcome.hunger_extra[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(25 * balance.HUNGER_COST_MODIFIED_EXTRA, outcome.hunger_extra_total());
    try std.testing.expectEqual(@as(u32, 25), outcome.score);
}

test "resolve_zone: excess agents are wasted" {
    var zone = c.ZoneDef{};
    zone.modified[@intFromEnum(c.Element.water)] = 10;
    var agents = [_]u32{0} ** c.Element.size;
    agents[@intFromEnum(c.Element.water)] = 999;
    const outcome = resolve_zone(zone, agents);
    try std.testing.expectEqual(@as(u16, 10), outcome.neutralized[@intFromEnum(c.Element.water)]);
    try std.testing.expectEqual(@as(u32, 0), outcome.modified_consumed);
    try std.testing.expectEqual(@as(u32, 0), outcome.hunger_extra_total());
    try std.testing.expectEqual(@as(u32, 10), outcome.score);
}

test "resolve_zone: wrong-color agents have no effect" {
    var zone = c.ZoneDef{};
    zone.modified[@intFromEnum(c.Element.fire)] = 20;
    var agents = [_]u32{0} ** c.Element.size;
    agents[@intFromEnum(c.Element.water)] = 20;
    const outcome = resolve_zone(zone, agents);
    try std.testing.expectEqual(@as(u16, 0), outcome.neutralized[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(@as(u32, 20), outcome.modified_consumed);
    try std.testing.expectEqual(20 * balance.HUNGER_COST_MODIFIED_EXTRA, outcome.hunger_extra[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(@as(u32, 0), outcome.hunger_extra[@intFromEnum(c.Element.water)]);
    try std.testing.expectEqual(@as(u32, 0), outcome.score);
}

test "resolve_zone: naturally-neutral slime counts toward score, costs normal hunger" {
    const zone = c.ZoneDef{ .neutral = 15 };
    const agents = [_]u32{0} ** c.Element.size;
    const outcome = resolve_zone(zone, agents);
    try std.testing.expectEqual(@as(u32, 15), outcome.score);
    try std.testing.expectEqual(15 * balance.HUNGER_COST_NORMAL, outcome.hunger_normal);
    try std.testing.expectEqual(@as(u32, 0), outcome.hunger_extra_total());
}

test "resolve_zone: mixed zone full clear" {
    var zone = c.ZoneDef{ .neutral = 5 };
    zone.modified = .{ 10, 20, 0, 0 };
    const agents = [_]u32{ 10, 20, 0, 0 };
    const outcome = resolve_zone(zone, agents);
    try std.testing.expectEqual(@as(u32, 0), outcome.modified_consumed);
    try std.testing.expectEqual(@as(u32, 35), outcome.score);
    try std.testing.expectEqual(35 * balance.HUNGER_COST_NORMAL, outcome.hunger_normal);
    try std.testing.expectEqual(@as(u32, 0), outcome.hunger_extra_total());
}
