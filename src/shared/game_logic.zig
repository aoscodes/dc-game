//! Pure resolution logic for the Slime Feast encounter.
//!
//! Cast-window pipeline (driven by session.commit_pending_casts, once per
//! cast window):
//!   1. `match_recipes`   — convert the window's committed casts into one
//!                          AgentOutput (team recipes → player recipes →
//!                          flat fallback; team recipes need distinct players
//!                          casting in the SAME window).
//!   2. `apply_medicine`  — heal the hunger bar immediately, capped by the
//!                          per-color healable (modified-slime) portions.
//!   3. `transmute`       — convert matching-color Modified Slime into
//!                          Neutralized Slime in place (visible live).
//!
//! Round-end (session.resolve_round):
//!   4. `consume_zone`    — eat the whole zone: hunger added (normal +
//!                          extra for remaining modified) and score.
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

/// True if committing this combo could produce ANY output: either its flat
/// conversion yields agents/medicine, or it exactly matches a recipe pattern
/// (player recipes, or any single pattern of a team recipe — the partner may
/// commit in the same window).  Zero-output combos (e.g. a dangling element
/// token or colorless actions) FIZZLE instead of committing, so they never
/// waste one of the player's casts.
pub fn combo_has_output(combo: c.ActionCombo) bool {
    const flat = flat_convert(combo);
    for (flat.units) |u| if (u > 0) return true;
    for (flat.medicine) |m| if (m > 0) return true;
    for (balance.player_recipes) |pr| {
        if (combos_equal(combo, pr.pattern)) return true;
    }
    for (balance.team_recipes) |tr| {
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

/// Per-round recipe-matching report for tuning stats.
pub const MatchReport = struct {
    /// Fire count per balance.player_recipes entry (table order).
    player_hits: [balance.player_recipes.len]u16 =
        [_]u16{0} ** balance.player_recipes.len,
    /// Fire count per balance.team_recipes entry (table order).
    team_hits: [balance.team_recipes.len]u16 =
        [_]u16{0} ** balance.team_recipes.len,
    /// Parallel to the casts slice: what consumed each cast.
    consumed: [MAX_CASTS]ConsumedBy = [_]ConsumedBy{.none} ** MAX_CASTS,
};

/// Convert one round's committed casts into the team's combined AgentOutput.
/// When `report` is non-null it is filled with recipe fire counts and
/// per-cast consumption for stats.
///
/// Matching order (a cast is consumed by at most one recipe):
///   1. Team recipes, greedily in balance.team_recipes order.  Each pattern
///      must be matched exactly by a DISTINCT player's cast — one player
///      casting both halves does not trigger a team recipe.  A recipe
///      repeats while disjoint groups keep matching.
///   2. Player recipes in balance.player_recipes order (exact match).
///   3. Flat conversion fallback (flat_convert).
pub fn match_recipes(casts: []const Cast, report: ?*MatchReport) c.AgentOutput {
    std.debug.assert(casts.len <= MAX_CASTS);
    var out = c.AgentOutput{};
    var consumed = [_]bool{false} ** MAX_CASTS;

    // 1. Team recipes — greedy, repeatable, table order, distinct players.
    for (balance.team_recipes, 0..) |tr, ti| {
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
                if (report) |r| r.consumed[picks[pi]] = .team_recipe;
            }
            if (report) |r| r.team_hits[ti] +|= 1;
            out.add(tr.output);
        }
    }

    // 2. Player recipes.
    for (casts, 0..) |cast, ci| {
        if (consumed[ci]) continue;
        for (balance.player_recipes, 0..) |pr, pi| {
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

/// Add hunger, clamping at max.
pub fn add_hunger(hunger: *c.Health, amount: u32) void {
    const total = @min(@as(u32, hunger.current) + amount, @as(u32, hunger.max));
    hunger.current = @intCast(total);
}

pub fn hunger_full(hunger: c.Health) bool {
    return hunger.max > 0 and hunger.current >= hunger.max;
}

/// Transmute matching-color Modified Slime into Neutralized Slime using this
/// cast window's agent units: per color `min(agents, modified)` moves from
/// `zone.modified` to `zone.neutralized`.  Excess and wrong-color agents are
/// wasted (no carry-over between windows).  Returns units transmuted per
/// color this window.
pub fn transmute(zone: *c.ZoneDef, agents: [c.Element.size]u32) [c.Element.size]u16 {
    var transmuted = [_]u16{0} ** c.Element.size;
    for (agents, 0..) |pool, i| {
        const n: u16 = @intCast(@min(pool, @as(u32, zone.modified[i])));
        zone.modified[i] -= n;
        zone.neutralized[i] +|= n;
        transmuted[i] = n;
    }
    return transmuted;
}

pub const ZoneOutcome = struct {
    /// Neutralized (transmuted) units consumed per original color.
    neutralized: [c.Element.size]u16,
    /// Modified units consumed WITHOUT neutralization, per color.
    modified_missed: [c.Element.size]u16,
    /// Total of modified_missed (extra-hunger units).
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

/// Consume the ENTIRE zone at round end.  Transmutation already happened per
/// cast window (see `transmute`); every unit costs HUNGER_COST_NORMAL, and
/// each remaining modified unit additionally costs
/// HUNGER_COST_MODIFIED_EXTRA (healable, tracked per color).
pub fn consume_zone(zone: c.ZoneDef) ZoneOutcome {
    var hunger_extra = [_]u32{0} ** c.Element.size;
    var neutralized_total: u32 = 0;
    var modified_consumed: u32 = 0;
    for (zone.modified, zone.neutralized, 0..) |missed, neut, i| {
        neutralized_total += neut;
        modified_consumed += missed;
        hunger_extra[i] = @as(u32, missed) * balance.HUNGER_COST_MODIFIED_EXTRA;
    }
    return .{
        .neutralized = zone.neutralized,
        .modified_missed = zone.modified,
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
    const out = match_recipes(&casts, null);
    try std.testing.expectEqual(@as(u32, 20), out.units[@intFromEnum(c.Element.fire)]);
}

test "match_recipes: non-recipe combo falls back to flat conversion" {
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = mk(&.{ .{ .element = .wind }, .{ .action = .dispense } }) },
    };
    const out = match_recipes(&casts, null);
    try std.testing.expectEqual(balance.UNITS_PER_SLOT, out.units[@intFromEnum(c.Element.wind)]);
}

/// twin_flames (balance.team_recipes[0]) output, fire channel — tests derive
/// expectations from the table so balance tuning can't break them.
const twin_flames_units = balance.team_recipes[0].output.units[@intFromEnum(c.Element.fire)];
const twin_flames_med = balance.team_recipes[0].output.medicine[@intFromEnum(c.Element.fire)];

test "match_recipes: team recipe consumes both casts exactly once" {
    // twin_flames: 2 × [fire, dispense, dispense] → one recipe output, once.
    const pat = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 1, .combo = pat },
    };
    const out = match_recipes(&casts, null);
    try std.testing.expectEqual(twin_flames_units, out.units[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(twin_flames_med, out.medicine[@intFromEnum(c.Element.fire)]);
}

test "match_recipes: team recipe fires twice for two disjoint pairs" {
    const pat = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 1, .combo = pat },
        .{ .player_id = 2, .combo = pat },
        .{ .player_id = 3, .combo = pat },
    };
    const out = match_recipes(&casts, null);
    try std.testing.expectEqual(2 * twin_flames_units, out.units[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(2 * twin_flames_med, out.medicine[@intFromEnum(c.Element.fire)]);
}

test "match_recipes: same player casting both halves does NOT fire team recipe" {
    // Team recipes require distinct players; one player's two twin_flames
    // halves fall back to flat conversion (2 × 2 × UNITS_PER_SLOT fire).
    const pat = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = pat },
        .{ .player_id = 0, .combo = pat },
    };
    const out = match_recipes(&casts, null);
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
    const out = match_recipes(&casts, null);
    try std.testing.expectEqual(twin_flames_units + 2 * balance.UNITS_PER_SLOT, out.units[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(twin_flames_med, out.medicine[@intFromEnum(c.Element.fire)]);
}

test "match_recipes: lone half of a team recipe falls back to flat" {
    // One [fire, dispense, dispense] alone: no team match, no player recipe
    // (crimson_flood needs 3 dispenses) → flat 2 × UNITS_PER_SLOT.
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } }) },
    };
    const out = match_recipes(&casts, null);
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
    const out = match_recipes(&casts, null);
    try std.testing.expectEqual(twin_flames_units, out.units[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(balance.UNITS_PER_SLOT, out.units[@intFromEnum(c.Element.water)]);
}

test "apply_medicine: capped by matching-color healable portion" {
    var hunger = c.Health{ .current = 50, .max = 100 };
    var healable = [_]u16{0} ** c.Element.size;
    healable[@intFromEnum(c.Element.fire)] = 10;
    var pools = [_]u32{0} ** c.Element.size;
    pools[@intFromEnum(c.Element.fire)] = 25;
    const healed = apply_medicine(&hunger, &healable, pools);
    try std.testing.expectEqual(@as(u16, 10), healed[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(@as(u32, 10), sum_u16(healed));
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
    try std.testing.expectEqual(@as(u32, 0), sum_u16(healed));
    try std.testing.expectEqual(@as(u16, 50), hunger.current);
    try std.testing.expectEqual(@as(u16, 20), healable[@intFromEnum(c.Element.fire)]);
}

test "apply_medicine: multiple colors heal independently" {
    var hunger = c.Health{ .current = 50, .max = 100 };
    var healable = [_]u16{ 10, 0, 4, 8 };
    const pools = [_]u32{ 3, 99, 99, 8 };
    const healed = apply_medicine(&hunger, &healable, pools);
    // fire 3 + earth 0 + wind 4 + water 8 = 15.
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
    healable[@intFromEnum(c.Element.fire)] = 50;
    var pools = [_]u32{0} ** c.Element.size;
    pools[@intFromEnum(c.Element.fire)] = 25;
    const healed = apply_medicine(&hunger, &healable, pools);
    try std.testing.expectEqual(@as(u32, 3), sum_u16(healed));
    try std.testing.expectEqual(@as(u16, 0), hunger.current);
    try std.testing.expectEqual(@as(u16, 47), healable[@intFromEnum(c.Element.fire)]);
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

test "transmute: partial neutralization (25 of 50) moves units in place" {
    var zone = c.ZoneDef{};
    zone.modified[@intFromEnum(c.Element.fire)] = 50;
    var agents = [_]u32{0} ** c.Element.size;
    agents[@intFromEnum(c.Element.fire)] = 25;
    const moved = transmute(&zone, agents);
    try std.testing.expectEqual(@as(u16, 25), moved[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(@as(u16, 25), zone.modified[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(@as(u16, 25), zone.neutralized[@intFromEnum(c.Element.fire)]);
    // Total units unchanged: transmutation converts, never consumes.
    try std.testing.expectEqual(@as(u32, 50), zone.total_units());

    const outcome = consume_zone(zone);
    try std.testing.expectEqual(@as(u16, 25), outcome.neutralized[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(@as(u32, 25), outcome.modified_consumed);
    try std.testing.expectEqual(50 * balance.HUNGER_COST_NORMAL, outcome.hunger_normal);
    try std.testing.expectEqual(25 * balance.HUNGER_COST_MODIFIED_EXTRA, outcome.hunger_extra[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(25 * balance.HUNGER_COST_MODIFIED_EXTRA, outcome.hunger_extra_total());
    try std.testing.expectEqual(@as(u32, 25), outcome.score);
}

test "transmute: excess agents in a window are wasted" {
    var zone = c.ZoneDef{};
    zone.modified[@intFromEnum(c.Element.water)] = 10;
    var agents = [_]u32{0} ** c.Element.size;
    agents[@intFromEnum(c.Element.water)] = 999;
    const moved = transmute(&zone, agents);
    try std.testing.expectEqual(@as(u16, 10), moved[@intFromEnum(c.Element.water)]);
    try std.testing.expectEqual(@as(u16, 0), zone.modified[@intFromEnum(c.Element.water)]);

    const outcome = consume_zone(zone);
    try std.testing.expectEqual(@as(u32, 0), outcome.modified_consumed);
    try std.testing.expectEqual(@as(u32, 0), outcome.hunger_extra_total());
    try std.testing.expectEqual(@as(u32, 10), outcome.score);
}

test "transmute: wrong-color agents have no effect" {
    var zone = c.ZoneDef{};
    zone.modified[@intFromEnum(c.Element.fire)] = 20;
    var agents = [_]u32{0} ** c.Element.size;
    agents[@intFromEnum(c.Element.water)] = 20;
    const moved = transmute(&zone, agents);
    for (moved) |m| try std.testing.expectEqual(@as(u16, 0), m);

    const outcome = consume_zone(zone);
    try std.testing.expectEqual(@as(u32, 20), outcome.modified_consumed);
    try std.testing.expectEqual(20 * balance.HUNGER_COST_MODIFIED_EXTRA, outcome.hunger_extra[@intFromEnum(c.Element.fire)]);
    try std.testing.expectEqual(@as(u32, 0), outcome.hunger_extra[@intFromEnum(c.Element.water)]);
    try std.testing.expectEqual(@as(u32, 0), outcome.score);
}

test "transmute: sequential windows equal one batched application" {
    // 25 agents in one window == 10 + 15 across two windows.
    var zone_a = c.ZoneDef{};
    zone_a.modified[0] = 50;
    var zone_b = zone_a;

    var batch = [_]u32{0} ** c.Element.size;
    batch[0] = 25;
    _ = transmute(&zone_a, batch);

    var w1 = [_]u32{0} ** c.Element.size;
    w1[0] = 10;
    var w2 = [_]u32{0} ** c.Element.size;
    w2[0] = 15;
    _ = transmute(&zone_b, w1);
    _ = transmute(&zone_b, w2);

    try std.testing.expectEqual(zone_a.modified[0], zone_b.modified[0]);
    try std.testing.expectEqual(zone_a.neutralized[0], zone_b.neutralized[0]);
    const oa = consume_zone(zone_a);
    const ob = consume_zone(zone_b);
    try std.testing.expectEqual(oa.score, ob.score);
    try std.testing.expectEqual(oa.hunger_extra_total(), ob.hunger_extra_total());
}

test "consume_zone: naturally-neutral slime counts toward score, costs normal hunger" {
    const zone = c.ZoneDef{ .neutral = 15 };
    const outcome = consume_zone(zone);
    try std.testing.expectEqual(@as(u32, 15), outcome.score);
    try std.testing.expectEqual(15 * balance.HUNGER_COST_NORMAL, outcome.hunger_normal);
    try std.testing.expectEqual(@as(u32, 0), outcome.hunger_extra_total());
}

test "consume_zone: fully transmuted mixed zone" {
    var zone = c.ZoneDef{ .neutral = 5 };
    zone.modified = .{ 10, 20, 0, 0 };
    const agents = [_]u32{ 10, 20, 0, 0 };
    _ = transmute(&zone, agents);
    const outcome = consume_zone(zone);
    try std.testing.expectEqual(@as(u32, 0), outcome.modified_consumed);
    try std.testing.expectEqual(@as(u32, 35), outcome.score);
    try std.testing.expectEqual(35 * balance.HUNGER_COST_NORMAL, outcome.hunger_normal);
    try std.testing.expectEqual(@as(u32, 0), outcome.hunger_extra_total());
}

test "match_recipes: report records fire counts and per-cast consumption" {
    const half = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } });
    const flood = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } });
    const plain = mk(&.{ .{ .element = .water }, .{ .action = .dispense } });
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = half }, // team pair w/ p1
        .{ .player_id = 1, .combo = half },
        .{ .player_id = 2, .combo = flood }, // crimson_flood (player recipe 0)
        .{ .player_id = 3, .combo = plain }, // flat
    };
    var report = MatchReport{};
    _ = match_recipes(&casts, &report);

    try std.testing.expectEqual(@as(u16, 1), report.team_hits[0]); // twin_flames
    try std.testing.expectEqual(@as(u16, 1), report.player_hits[0]); // crimson_flood
    try std.testing.expectEqual(ConsumedBy.team_recipe, report.consumed[0]);
    try std.testing.expectEqual(ConsumedBy.team_recipe, report.consumed[1]);
    try std.testing.expectEqual(ConsumedBy.player_recipe, report.consumed[2]);
    try std.testing.expectEqual(ConsumedBy.none, report.consumed[3]);
}

test "combo_has_output: dangling element token fizzles" {
    try std.testing.expect(!combo_has_output(mk(&.{.{ .element = .fire }})));
}

test "combo_has_output: colorless actions fizzle" {
    try std.testing.expect(!combo_has_output(mk(&.{
        .{ .action = .dispense },
        .{ .action = .medicine },
    })));
}

test "combo_has_output: colored dispense has output" {
    try std.testing.expect(combo_has_output(mk(&.{
        .{ .element = .fire },
        .{ .action = .dispense },
    })));
}

test "combo_has_output: recipe patterns have output" {
    // twin_flames half (team pattern) and panacea (player recipe).
    try std.testing.expect(combo_has_output(mk(&.{
        .{ .element = .fire },
        .{ .action = .dispense },
        .{ .action = .dispense },
    })));
    try std.testing.expect(combo_has_output(mk(&.{
        .{ .element = .water },
        .{ .action = .medicine },
        .{ .action = .medicine },
    })));
}
