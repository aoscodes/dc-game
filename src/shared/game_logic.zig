//! Pure resolution logic for the Slime Feast encounter: everything that maps
//! player CASTS onto game effects.
//!
//! Cast pipeline (driven by session.fire_expired_casts, once per batch of
//! casts that expire together):
//!   1. `match_recipes`   — convert the batch's casts into one AgentOutput
//!                          (team recipes → player recipes → flat fallback;
//!                          team recipes need distinct players in the SAME
//!                          batch).
//!   2. `apply_medicine`  — heal the hunger bar immediately, capped by the
//!                          per-color healable (modified-slime) portions.
//!   3. dispensed agents are then handed to `slime.SlimeField.neutralize`,
//!      which owns all slime state and all randomness.
//!
//! All functions here are pure/deterministic and unit-testable without a
//! session.  Slime-field mutation lives in `slime.zig`; hunger/score
//! bookkeeping helpers (`add_hunger`, `hunger_full`) live here.

const std = @import("std");
const c = @import("components.zig");
const balance = @import("balance.zig");

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
///   - dispense with an element → bal.units_per_slot agent units of that color
///   - medicine with an element → bal.medicine_per_slot medicine of that color
///   - either action with NO element → wasted (both are color-bound)
pub fn flat_convert(bal: *const balance.Balance, combo: c.ActionCombo) c.AgentOutput {
    var out = c.AgentOutput{};
    var ea_buf: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &ea_buf);
    for (ea_buf[0..n]) |ea| {
        const el = ea.element orelse continue; // colorless actions wasted
        switch (ea.action) {
            .dispense => out.units[@intFromEnum(el)] +|= bal.units_per_slot,
            .medicine => out.medicine[@intFromEnum(el)] +|= bal.medicine_per_slot,
        }
    }
    return out;
}

/// True if committing this combo could produce ANY output: either its flat
/// conversion yields agents/medicine, or it exactly matches a recipe pattern
/// (player recipes, or any single pattern of a team recipe — the partner may
/// commit in the same window).  Zero-output combos (e.g. a dangling element
/// token or colorless actions) FIZZLE instead of committing, so they never
/// waste one of the player's casts.
pub fn combo_has_output(bal: *const balance.Balance, combo: c.ActionCombo) bool {
    const flat = flat_convert(bal, combo);
    for (flat.units) |u| if (u > 0) return true;
    for (flat.medicine) |m| if (m > 0) return true;
    for (bal.player_recipes) |pr| {
        if (combos_equal(combo, pr.pattern)) return true;
    }
    for (bal.team_recipes) |tr| {
        for (tr.patterns) |pattern| {
            if (combos_equal(combo, pattern)) return true;
        }
    }
    return false;
}

/// One committed spell: the combo plus its caster (recipes that span players
/// must be cast by distinct players).
pub const Cast = struct {
    player_id: u8,
    combo: c.ActionCombo,
};

/// Maximum casts per round == max players × casts each; sized for the
/// consumed-flag arrays.
pub const MAX_CASTS: usize = 64;

/// How a cast was converted during recipe matching.
pub const ConsumedBy = enum(u8) { none, player_recipe, team_recipe };

/// team_instance value for casts not consumed by a team recipe.
pub const NO_TEAM_INSTANCE: u8 = 0xFF;

/// Per-round recipe-matching report for tuning stats.  Hit arrays are sized
/// by the wire caps; entries beyond the loaded table lengths stay zero.
pub const MatchReport = struct {
    /// Fire count per loaded player-recipe entry (table order).
    player_hits: [balance.MAX_PLAYER_RECIPES]u16 =
        [_]u16{0} ** balance.MAX_PLAYER_RECIPES,
    /// Fire count per loaded team-recipe entry (table order).
    team_hits: [balance.MAX_TEAM_RECIPES]u16 =
        [_]u16{0} ** balance.MAX_TEAM_RECIPES,
    /// Parallel to the casts slice: what consumed each cast.
    consumed: [MAX_CASTS]ConsumedBy = [_]ConsumedBy{.none} ** MAX_CASTS,
    /// Parallel to the casts slice: team-recipe INSTANCE id (counter across
    /// all fired team recipes; casts of the same instance share an id).
    /// NO_TEAM_INSTANCE for casts not consumed by a team recipe.  Lets the
    /// realtime server group exactly one recipe instance's casts.
    team_instance: [MAX_CASTS]u8 = [_]u8{NO_TEAM_INSTANCE} ** MAX_CASTS,
};

/// Convert one round's committed casts into the team's combined AgentOutput.
/// When `report` is non-null it is filled with recipe fire counts and
/// per-cast consumption for stats.
///
/// Matching order (a cast is consumed by at most one recipe):
///   1. Team recipes, greedily in bal.team_recipes order.  Each pattern
///      must be matched exactly by a DISTINCT player's cast — one player
///      casting both halves does not trigger a team recipe.  A recipe
///      repeats while disjoint groups keep matching.
///   2. Player recipes in bal.player_recipes order (exact match).
///   3. Flat conversion fallback (flat_convert).
pub fn match_recipes(bal: *const balance.Balance, casts: []const Cast, report: ?*MatchReport) c.AgentOutput {
    std.debug.assert(casts.len <= MAX_CASTS);
    var out = c.AgentOutput{};
    var consumed = [_]bool{false} ** MAX_CASTS;
    var instance_counter: u8 = 0;

    // 1. Team recipes — greedy, repeatable, table order, distinct players.
    for (bal.team_recipes, 0..) |tr, ti| {
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
            for (tr.patterns, 0..) |_, pi| {
                consumed[picks[pi]] = true;
                if (report) |r| {
                    r.consumed[picks[pi]] = .team_recipe;
                    r.team_instance[picks[pi]] = instance_counter;
                }
            }
            if (report) |r| r.team_hits[ti] +|= 1;
            instance_counter +|= 1;
            out.add(tr.output);
        }
    }

    // 2. Player recipes.
    for (casts, 0..) |cast, ci| {
        if (consumed[ci]) continue;
        for (bal.player_recipes, 0..) |pr, pi| {
            if (combos_equal(cast.combo, pr.pattern)) {
                out.add(pr.output);
                consumed[ci] = true;
                if (report) |r| {
                    r.player_hits[pi] +|= 1;
                    r.consumed[ci] = .player_recipe;
                }
                break;
            }
        }
    }

    // 3. Flat fallback.
    for (casts, 0..) |cast, ci| {
        if (consumed[ci]) continue;
        out.add(flat_convert(bal, cast.combo));
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
/// Returns the amount actually healed per color (sum for the total).
pub fn apply_medicine(
    hunger: *c.Health,
    healable: *[c.Element.size]u16,
    pools: [c.Element.size]u32,
) [c.Element.size]u16 {
    var healed = [_]u16{0} ** c.Element.size;
    for (pools, 0..) |pool, i| {
        const cap = @min(@as(u32, healable[i]), @as(u32, hunger.current));
        const heal: u16 = @intCast(@min(pool, cap));
        hunger.current -= heal;
        healable[i] -= heal;
        healed[i] = heal;
    }
    return healed;
}

/// Sum a per-color u16 array (convenience for totals).
pub fn sum_u16(values: [c.Element.size]u16) u32 {
    var total: u32 = 0;
    for (values) |v| total += v;
    return total;
}

/// Sum a per-color u32 array — e.g. an AgentOutput's units/medicine pools.
pub fn sum_u32(values: [c.Element.size]u32) u32 {
    var total: u32 = 0;
    for (values) |v| total +|= v;
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const mk = c.make_combo;
const fixtures = @import("fixtures.zig");
/// Frozen fixture balance — designer edits to data/*.json can't break these.
const test_bal = &fixtures.test_config.balance;

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
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .action = .dispense },
    });
    var out: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(c.Element.red, out[0].element.?);
    try std.testing.expectEqual(c.Element.red, out[1].element.?);
}

test "parse_combo: second element overrides first" {
    const combo = mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .element = .blue },
        .{ .action = .dispense },
    });
    var out: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(c.Element.red, out[0].element.?);
    try std.testing.expectEqual(c.Element.blue, out[1].element.?);
}

test "parse_combo: trailing element is silently dropped" {
    const combo = mk(&.{
        .{ .action = .dispense },
        .{ .element = .red },
    });
    var out: [c.MAX_COMBO_LEN]ElementedAction = undefined;
    const n = parse_combo(combo, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(?c.Element, null), out[0].element);
}

test "combos_equal: identical combos match" {
    const a = mk(&.{ .{ .element = .red }, .{ .action = .dispense } });
    const b = mk(&.{ .{ .element = .red }, .{ .action = .dispense } });
    try std.testing.expect(combos_equal(a, b));
}

test "combos_equal: different length / slot / order do not match" {
    const base = mk(&.{ .{ .element = .red }, .{ .action = .dispense } });
    const longer = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    const other_el = mk(&.{ .{ .element = .blue }, .{ .action = .dispense } });
    const reordered = mk(&.{ .{ .action = .dispense }, .{ .element = .red } });
    try std.testing.expect(!combos_equal(base, longer));
    try std.testing.expect(!combos_equal(base, other_el));
    try std.testing.expect(!combos_equal(base, reordered));
}

test "flat_convert: elemental dispense yields UNITS_PER_SLOT per slot" {
    const out = flat_convert(test_bal, mk(&.{
        .{ .element = .green },
        .{ .action = .dispense },
        .{ .action = .dispense },
    }));
    try std.testing.expectEqual(2 * test_bal.units_per_slot, out.units[@intFromEnum(c.Element.green)]);
    for (out.medicine) |m| try std.testing.expectEqual(@as(u32, 0), m);
}

test "flat_convert: colorless dispense is wasted" {
    const out = flat_convert(test_bal, mk(&.{.{ .action = .dispense }}));
    for (out.units) |u| try std.testing.expectEqual(@as(u32, 0), u);
}

test "flat_convert: medicine is color-bound; colorless medicine wasted" {
    const out = flat_convert(test_bal, mk(&.{
        .{ .action = .medicine }, // colorless — wasted
        .{ .element = .red },
        .{ .action = .medicine },
        .{ .element = .blue },
        .{ .action = .medicine },
    }));
    try std.testing.expectEqual(test_bal.medicine_per_slot, out.medicine[@intFromEnum(c.Element.red)]);
    try std.testing.expectEqual(test_bal.medicine_per_slot, out.medicine[@intFromEnum(c.Element.blue)]);
    try std.testing.expectEqual(@as(u32, 0), out.medicine[@intFromEnum(c.Element.green)]);
    for (out.units) |u| try std.testing.expectEqual(@as(u32, 0), u);
}

test "match_recipes: player recipe replaces flat conversion" {
    // crimson_flood: [red, dispense×3] → 20 red units (flat would be 15).
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }) },
    };
    const out = match_recipes(test_bal, &casts, null);
    try std.testing.expectEqual(@as(u32, 20), out.units[@intFromEnum(c.Element.red)]);
}

test "match_recipes: non-recipe combo falls back to flat conversion" {
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = mk(&.{ .{ .element = .yellow }, .{ .action = .dispense } }) },
    };
    const out = match_recipes(test_bal, &casts, null);
    try std.testing.expectEqual(test_bal.units_per_slot, out.units[@intFromEnum(c.Element.yellow)]);
}

/// twin_flames (fixtures.team_recipes[0]) output, red channel — tests derive
/// expectations from the fixture table.
const twin_flames_units = fixtures.team_recipes[0].output.units[@intFromEnum(c.Element.red)];
const twin_flames_med = fixtures.team_recipes[0].output.medicine[@intFromEnum(c.Element.red)];

test "match_recipes: team recipe consumes both casts exactly once" {
    // twin_flames: 2 × [red, dispense, dispense] → one recipe output, once.
    const pat = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 1, .combo = pat },
    };
    const out = match_recipes(test_bal, &casts, null);
    try std.testing.expectEqual(twin_flames_units, out.units[@intFromEnum(c.Element.red)]);
    try std.testing.expectEqual(twin_flames_med, out.medicine[@intFromEnum(c.Element.red)]);
}

test "match_recipes: team recipe fires twice for two disjoint pairs" {
    const pat = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 1, .combo = pat },
        .{ .player_id = 2, .combo = pat },
        .{ .player_id = 3, .combo = pat },
    };
    const out = match_recipes(test_bal, &casts, null);
    try std.testing.expectEqual(2 * twin_flames_units, out.units[@intFromEnum(c.Element.red)]);
    try std.testing.expectEqual(2 * twin_flames_med, out.medicine[@intFromEnum(c.Element.red)]);
}

test "match_recipes: team_instance groups each recipe instance's casts" {
    // Two disjoint twin_flames pairs + one flat cast: instances {0,1} and
    // {2,3} get distinct shared ids; the flat cast stays unassigned.
    const pat = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 1, .combo = pat },
        .{ .player_id = 2, .combo = pat },
        .{ .player_id = 3, .combo = pat },
        .{ .player_id = 4, .combo = mk(&.{ .{ .element = .blue }, .{ .action = .dispense } }) },
    };
    var report = MatchReport{};
    _ = match_recipes(test_bal, &casts, &report);

    try std.testing.expectEqual(report.team_instance[0], report.team_instance[1]);
    try std.testing.expectEqual(report.team_instance[2], report.team_instance[3]);
    try std.testing.expect(report.team_instance[0] != report.team_instance[2]);
    try std.testing.expect(report.team_instance[0] != NO_TEAM_INSTANCE);
    try std.testing.expect(report.team_instance[2] != NO_TEAM_INSTANCE);
    try std.testing.expectEqual(NO_TEAM_INSTANCE, report.team_instance[4]);
}

test "match_recipes: same player casting both halves does NOT fire team recipe" {
    // Team recipes require distinct players; one player's two twin_flames
    // halves fall back to flat conversion (2 × 2 × UNITS_PER_SLOT red).
    const pat = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 0, .combo = pat },
    };
    const out = match_recipes(test_bal, &casts, null);
    try std.testing.expectEqual(4 * test_bal.units_per_slot, out.units[@intFromEnum(c.Element.red)]);
    for (out.medicine) |m| try std.testing.expectEqual(@as(u32, 0), m);
}

test "match_recipes: distinct-player pair still fires alongside same-player extras" {
    // Players 0 and 1 form one twin_flames pair; player 0's second half has
    // no distinct partner left and converts flat.
    const pat = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 1, .combo = pat },
    };
    const out = match_recipes(test_bal, &casts, null);
    try std.testing.expectEqual(twin_flames_units + 2 * test_bal.units_per_slot, out.units[@intFromEnum(c.Element.red)]);
    try std.testing.expectEqual(twin_flames_med, out.medicine[@intFromEnum(c.Element.red)]);
}

test "match_recipes: lone half of a team recipe falls back to flat" {
    // One [red, dispense, dispense] alone: no team match, no player recipe
    // (crimson_flood needs 3 dispenses) → flat 2 × UNITS_PER_SLOT.
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } }) },
    };
    const out = match_recipes(test_bal, &casts, null);
    try std.testing.expectEqual(2 * test_bal.units_per_slot, out.units[@intFromEnum(c.Element.red)]);
    for (out.medicine) |m| try std.testing.expectEqual(@as(u32, 0), m);
}

test "match_recipes: mixed — team pair + independent flat combo" {
    const pat = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    const flat = mk(&.{ .{ .element = .blue }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 1, .combo = flat },
        .{ .player_id = 2, .combo = pat },
    };
    const out = match_recipes(test_bal, &casts, null);
    try std.testing.expectEqual(twin_flames_units, out.units[@intFromEnum(c.Element.red)]);
    try std.testing.expectEqual(test_bal.units_per_slot, out.units[@intFromEnum(c.Element.blue)]);
}

test "apply_medicine: capped by matching-color healable portion" {
    var hunger = c.Health{ .current = 50, .max = 100 };
    var healable = [_]u16{0} ** c.Element.size;
    healable[@intFromEnum(c.Element.red)] = 10;
    var pools = [_]u32{0} ** c.Element.size;
    pools[@intFromEnum(c.Element.red)] = 25;
    const healed = apply_medicine(&hunger, &healable, pools);
    try std.testing.expectEqual(@as(u16, 10), healed[@intFromEnum(c.Element.red)]);
    try std.testing.expectEqual(@as(u32, 10), sum_u16(healed));
    try std.testing.expectEqual(@as(u16, 40), hunger.current);
    try std.testing.expectEqual(@as(u16, 0), healable[@intFromEnum(c.Element.red)]);
}

test "apply_medicine: asymmetric medicine heals nothing" {
    // Blue medicine vs red healable hunger: no effect.
    var hunger = c.Health{ .current = 50, .max = 100 };
    var healable = [_]u16{0} ** c.Element.size;
    healable[@intFromEnum(c.Element.red)] = 20;
    var pools = [_]u32{0} ** c.Element.size;
    pools[@intFromEnum(c.Element.blue)] = 99;
    const healed = apply_medicine(&hunger, &healable, pools);
    try std.testing.expectEqual(@as(u32, 0), sum_u16(healed));
    try std.testing.expectEqual(@as(u16, 50), hunger.current);
    try std.testing.expectEqual(@as(u16, 20), healable[@intFromEnum(c.Element.red)]);
}

test "apply_medicine: multiple colors heal independently" {
    var hunger = c.Health{ .current = 50, .max = 100 };
    var healable = [_]u16{ 10, 0, 4, 8 };
    const pools = [_]u32{ 3, 99, 99, 8 };
    const healed = apply_medicine(&hunger, &healable, pools);
    // red 3 + green 0 + yellow 4 + blue 8 = 15.
    try std.testing.expectEqual(@as(u32, 15), sum_u16(healed));
    try std.testing.expectEqual(@as(u16, 3), healed[0]);
    try std.testing.expectEqual(@as(u16, 8), healed[3]);
    try std.testing.expectEqual(@as(u16, 35), hunger.current);
    try std.testing.expectEqual(@as(u16, 7), healable[0]);
    try std.testing.expectEqual(@as(u16, 0), healable[2]);
    try std.testing.expectEqual(@as(u16, 0), healable[3]);
}

test "apply_medicine: capped by current hunger" {
    var hunger = c.Health{ .current = 3, .max = 100 };
    var healable = [_]u16{0} ** c.Element.size;
    healable[@intFromEnum(c.Element.red)] = 50;
    var pools = [_]u32{0} ** c.Element.size;
    pools[@intFromEnum(c.Element.red)] = 25;
    const healed = apply_medicine(&hunger, &healable, pools);
    try std.testing.expectEqual(@as(u32, 3), sum_u16(healed));
    try std.testing.expectEqual(@as(u16, 0), hunger.current);
    try std.testing.expectEqual(@as(u16, 47), healable[@intFromEnum(c.Element.red)]);
}

test "apply_medicine: zero healable — neutral consumption not healable" {
    var hunger = c.Health{ .current = 80, .max = 100 };
    var healable = [_]u16{0} ** c.Element.size;
    const pools = [_]u32{99} ** c.Element.size;
    const healed = apply_medicine(&hunger, &healable, pools);
    try std.testing.expectEqual(@as(u32, 0), sum_u16(healed));
    try std.testing.expectEqual(@as(u16, 80), hunger.current);
}

test "add_hunger: clamps at max" {
    var hunger = c.Health{ .current = 190, .max = 200 };
    add_hunger(&hunger, 50);
    try std.testing.expectEqual(@as(u16, 200), hunger.current);
    try std.testing.expect(hunger_full(hunger));
}

test "match_recipes: report records fire counts and per-cast consumption" {
    const half = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } });
    const flood = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } });
    const plain = mk(&.{ .{ .element = .blue }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = half }, // team pair w/ p1
        .{ .player_id = 1, .combo = half },
        .{ .player_id = 2, .combo = flood }, // crimson_flood (player recipe 0)
        .{ .player_id = 3, .combo = plain }, // flat
    };
    var report = MatchReport{};
    _ = match_recipes(test_bal, &casts, &report);

    try std.testing.expectEqual(@as(u16, 1), report.team_hits[0]); // twin_flames
    try std.testing.expectEqual(@as(u16, 1), report.player_hits[0]); // crimson_flood
    try std.testing.expectEqual(ConsumedBy.team_recipe, report.consumed[0]);
    try std.testing.expectEqual(ConsumedBy.team_recipe, report.consumed[1]);
    try std.testing.expectEqual(ConsumedBy.player_recipe, report.consumed[2]);
    try std.testing.expectEqual(ConsumedBy.none, report.consumed[3]);
}

test "combo_has_output: dangling element token fizzles" {
    try std.testing.expect(!combo_has_output(test_bal, mk(&.{.{ .element = .red }})));
}

test "combo_has_output: colorless actions fizzle" {
    try std.testing.expect(!combo_has_output(test_bal, mk(&.{
        .{ .action = .dispense },
        .{ .action = .medicine },
    })));
}

test "combo_has_output: colored dispense has output" {
    try std.testing.expect(combo_has_output(test_bal, mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
    })));
}

test "combo_has_output: recipe patterns have output" {
    // twin_flames half (team pattern) and panacea (player recipe).
    try std.testing.expect(combo_has_output(test_bal, mk(&.{
        .{ .element = .red },
        .{ .action = .dispense },
        .{ .action = .dispense },
    })));
    try std.testing.expect(combo_has_output(test_bal, mk(&.{
        .{ .element = .blue },
        .{ .action = .medicine },
        .{ .action = .medicine },
    })));
}
