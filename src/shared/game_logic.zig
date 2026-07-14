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
                if (report) |r| r.consumed[picks[pi]] = .team_recipe;
            }
            if (report) |r| r.team_hits[ti] +|= 1;
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

/// Result of Lil Guys eating `n` units from a zone (realtime mode).
/// Field semantics mirror ZoneOutcome, but scoped to the bites taken.
pub const EatOutcome = struct {
    /// Units actually eaten (== requested n unless the zone ran out).
    eaten: u32 = 0,
    /// Modified units eaten WITHOUT neutralization, per color.
    eaten_modified: [c.Element.size]u16 = [_]u16{0} ** c.Element.size,
    /// Neutralized (transmuted) units eaten, per original color.
    eaten_neutralized: [c.Element.size]u16 = [_]u16{0} ** c.Element.size,
    /// Naturally-neutral units eaten.
    eaten_neutral: u16 = 0,
    /// Hunger from eating every unit at the normal rate (never healable).
    hunger_normal: u32 = 0,
    /// Extra hunger per color from un-neutralized modified units eaten.
    /// Healable only by matching-color medicine.
    hunger_extra: [c.Element.size]u32 = [_]u32{0} ** c.Element.size,
    /// Score gained: neutralized + naturally-neutral units eaten.
    score: u32 = 0,

    pub fn hunger_extra_total(self: EatOutcome) u32 {
        var total: u32 = 0;
        for (self.hunger_extra) |e| total += e;
        return total;
    }
};

/// Which bucket a single bite comes from.
const Bite = union(enum) {
    neutral,
    neutralized: usize,
    modified: usize,
};

/// Pick the bucket the next bite comes from: the LARGEST remaining bucket
/// among neutral, neutralized[color], modified[color] (deterministic
/// tiebreak in that order, colors in Element ordinal order).  Eating the
/// biggest bucket first keeps consumption roughly proportional — every
/// bucket shrinks throughout the zone, so players have the whole zone
/// duration to transmute modified slime.  Returns null when the zone is
/// empty.
fn pick_bite(zone: *const c.ZoneDef) ?Bite {
    var best: ?Bite = null;
    var best_count: u16 = 0;
    if (zone.neutral > best_count) {
        best = .neutral;
        best_count = zone.neutral;
    }
    for (zone.neutralized, 0..) |count, i| {
        if (count > best_count) {
            best = .{ .neutralized = i };
            best_count = count;
        }
    }
    for (zone.modified, 0..) |count, i| {
        if (count > best_count) {
            best = .{ .modified = i };
            best_count = count;
        }
    }
    return best;
}

/// Realtime mode: eat `n` units from the zone in place (one bite at a time
/// via `pick_bite`), stopping early if the zone empties.  Every unit costs
/// bal.hunger_cost_normal; each un-neutralized modified unit additionally
/// costs bal.hunger_cost_modified_extra (healable, tracked per color);
/// neutralized + naturally-neutral units score.  Equivalent in totals to
/// consume_zone once the zone is fully eaten with no further transmutation.
pub fn eat_units(bal: *const balance.Balance, zone: *c.ZoneDef, n: u32) EatOutcome {
    var out = EatOutcome{};
    var remaining = n;
    while (remaining > 0) : (remaining -= 1) {
        const bite = pick_bite(zone) orelse break;
        out.eaten += 1;
        out.hunger_normal += bal.hunger_cost_normal;
        switch (bite) {
            .neutral => {
                zone.neutral -= 1;
                out.eaten_neutral += 1;
                out.score += 1;
            },
            .neutralized => |i| {
                zone.neutralized[i] -= 1;
                out.eaten_neutralized[i] += 1;
                out.score += 1;
            },
            .modified => |i| {
                zone.modified[i] -= 1;
                out.eaten_modified[i] += 1;
                out.hunger_extra[i] += bal.hunger_cost_modified_extra;
            },
        }
    }
    return out;
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
/// cast window (see `transmute`); every unit costs bal.hunger_cost_normal,
/// and each remaining modified unit additionally costs
/// bal.hunger_cost_modified_extra (healable, tracked per color).
pub fn consume_zone(bal: *const balance.Balance, zone: c.ZoneDef) ZoneOutcome {
    var hunger_extra = [_]u32{0} ** c.Element.size;
    var neutralized_total: u32 = 0;
    var modified_consumed: u32 = 0;
    for (zone.modified, zone.neutralized, 0..) |missed, neut, i| {
        neutralized_total += neut;
        modified_consumed += missed;
        hunger_extra[i] = @as(u32, missed) * bal.hunger_cost_modified_extra;
    }
    return .{
        .neutralized = zone.neutralized,
        .modified_missed = zone.modified,
        .modified_consumed = modified_consumed,
        .hunger_normal = zone.total_units() * bal.hunger_cost_normal,
        .hunger_extra = hunger_extra,
        .score = neutralized_total + zone.neutral,
    };
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

test "transmute: partial neutralization (25 of 50) moves units in place" {
    var zone = c.ZoneDef{};
    zone.modified[@intFromEnum(c.Element.red)] = 50;
    var agents = [_]u32{0} ** c.Element.size;
    agents[@intFromEnum(c.Element.red)] = 25;
    const moved = transmute(&zone, agents);
    try std.testing.expectEqual(@as(u16, 25), moved[@intFromEnum(c.Element.red)]);
    try std.testing.expectEqual(@as(u16, 25), zone.modified[@intFromEnum(c.Element.red)]);
    try std.testing.expectEqual(@as(u16, 25), zone.neutralized[@intFromEnum(c.Element.red)]);
    // Total units unchanged: transmutation converts, never consumes.
    try std.testing.expectEqual(@as(u32, 50), zone.total_units());

    const outcome = consume_zone(test_bal, zone);
    try std.testing.expectEqual(@as(u16, 25), outcome.neutralized[@intFromEnum(c.Element.red)]);
    try std.testing.expectEqual(@as(u32, 25), outcome.modified_consumed);
    try std.testing.expectEqual(50 * test_bal.hunger_cost_normal, outcome.hunger_normal);
    try std.testing.expectEqual(25 * test_bal.hunger_cost_modified_extra, outcome.hunger_extra[@intFromEnum(c.Element.red)]);
    try std.testing.expectEqual(25 * test_bal.hunger_cost_modified_extra, outcome.hunger_extra_total());
    try std.testing.expectEqual(@as(u32, 25), outcome.score);
}

test "transmute: excess agents in a window are wasted" {
    var zone = c.ZoneDef{};
    zone.modified[@intFromEnum(c.Element.blue)] = 10;
    var agents = [_]u32{0} ** c.Element.size;
    agents[@intFromEnum(c.Element.blue)] = 999;
    const moved = transmute(&zone, agents);
    try std.testing.expectEqual(@as(u16, 10), moved[@intFromEnum(c.Element.blue)]);
    try std.testing.expectEqual(@as(u16, 0), zone.modified[@intFromEnum(c.Element.blue)]);

    const outcome = consume_zone(test_bal, zone);
    try std.testing.expectEqual(@as(u32, 0), outcome.modified_consumed);
    try std.testing.expectEqual(@as(u32, 0), outcome.hunger_extra_total());
    try std.testing.expectEqual(@as(u32, 10), outcome.score);
}

test "transmute: wrong-color agents have no effect" {
    var zone = c.ZoneDef{};
    zone.modified[@intFromEnum(c.Element.red)] = 20;
    var agents = [_]u32{0} ** c.Element.size;
    agents[@intFromEnum(c.Element.blue)] = 20;
    const moved = transmute(&zone, agents);
    for (moved) |m| try std.testing.expectEqual(@as(u16, 0), m);

    const outcome = consume_zone(test_bal, zone);
    try std.testing.expectEqual(@as(u32, 20), outcome.modified_consumed);
    try std.testing.expectEqual(20 * test_bal.hunger_cost_modified_extra, outcome.hunger_extra[@intFromEnum(c.Element.red)]);
    try std.testing.expectEqual(@as(u32, 0), outcome.hunger_extra[@intFromEnum(c.Element.blue)]);
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
    const oa = consume_zone(test_bal, zone_a);
    const ob = consume_zone(test_bal, zone_b);
    try std.testing.expectEqual(oa.score, ob.score);
    try std.testing.expectEqual(oa.hunger_extra_total(), ob.hunger_extra_total());
}

test "eat_units: largest bucket eaten first, deterministic tiebreak order" {
    var zone = c.ZoneDef{ .neutral = 2 };
    zone.modified[@intFromEnum(c.Element.red)] = 3;
    // First bite: modified red (3 is largest).
    const o1 = eat_units(test_bal, &zone, 1);
    try std.testing.expectEqual(@as(u16, 1), o1.eaten_modified[@intFromEnum(c.Element.red)]);
    // Now 2 vs 2: tiebreak order picks neutral before modified.
    const o2 = eat_units(test_bal, &zone, 1);
    try std.testing.expectEqual(@as(u16, 1), o2.eaten_neutral);
}

test "eat_units: hunger and score accrue per unit" {
    var zone = c.ZoneDef{ .neutral = 1 };
    zone.modified[@intFromEnum(c.Element.blue)] = 2;
    zone.neutralized[@intFromEnum(c.Element.green)] = 1;
    const out = eat_units(test_bal, &zone, 4);
    try std.testing.expectEqual(@as(u32, 4), out.eaten);
    try std.testing.expectEqual(4 * test_bal.hunger_cost_normal, out.hunger_normal);
    try std.testing.expectEqual(2 * test_bal.hunger_cost_modified_extra, out.hunger_extra[@intFromEnum(c.Element.blue)]);
    // Score: 1 neutral + 1 neutralized.
    try std.testing.expectEqual(@as(u32, 2), out.score);
    try std.testing.expectEqual(@as(u32, 0), zone.total_units());
}

test "eat_units: stops early when the zone empties" {
    var zone = c.ZoneDef{ .neutral = 3 };
    const out = eat_units(test_bal, &zone, 10);
    try std.testing.expectEqual(@as(u32, 3), out.eaten);
    try std.testing.expectEqual(@as(u32, 3), out.score);
    try std.testing.expectEqual(@as(u32, 0), zone.total_units());
    // Eating an empty zone is a no-op.
    const again = eat_units(test_bal, &zone, 5);
    try std.testing.expectEqual(@as(u32, 0), again.eaten);
    try std.testing.expectEqual(@as(u32, 0), again.hunger_normal);
}

test "eat_units: incremental bites total the same as consume_zone" {
    var zone_inc = c.ZoneDef{ .neutral = 7 };
    zone_inc.modified = .{ 10, 4, 0, 0 };
    zone_inc.neutralized = .{ 0, 0, 6, 0 };
    const zone_batch = zone_inc;

    var total = EatOutcome{};
    while (zone_inc.total_units() > 0) {
        const bite = eat_units(test_bal, &zone_inc, 3);
        total.eaten += bite.eaten;
        total.hunger_normal += bite.hunger_normal;
        total.score += bite.score;
        for (&total.hunger_extra, bite.hunger_extra) |*acc, e| acc.* += e;
    }

    const batch = consume_zone(test_bal, zone_batch);
    try std.testing.expectEqual(zone_batch.total_units(), total.eaten);
    try std.testing.expectEqual(batch.hunger_normal, total.hunger_normal);
    try std.testing.expectEqual(batch.hunger_extra_total(), total.hunger_extra_total());
    try std.testing.expectEqual(batch.score, total.score);
}

test "eat_units: interleaved transmutation neutralizes remaining modified slime" {
    // 10 modified red; eat 4, then transmute the rest, then eat the rest.
    var zone = c.ZoneDef{};
    zone.modified[@intFromEnum(c.Element.red)] = 10;
    const first = eat_units(test_bal, &zone, 4);
    try std.testing.expectEqual(4 * test_bal.hunger_cost_modified_extra, first.hunger_extra_total());
    var agents = [_]u32{0} ** c.Element.size;
    agents[@intFromEnum(c.Element.red)] = 99;
    _ = transmute(&zone, agents);
    const rest = eat_units(test_bal, &zone, 99);
    try std.testing.expectEqual(@as(u32, 6), rest.eaten);
    try std.testing.expectEqual(@as(u32, 0), rest.hunger_extra_total());
    try std.testing.expectEqual(@as(u32, 6), rest.score);
}

test "consume_zone: naturally-neutral slime counts toward score, costs normal hunger" {
    const zone = c.ZoneDef{ .neutral = 15 };
    const outcome = consume_zone(test_bal, zone);
    try std.testing.expectEqual(@as(u32, 15), outcome.score);
    try std.testing.expectEqual(15 * test_bal.hunger_cost_normal, outcome.hunger_normal);
    try std.testing.expectEqual(@as(u32, 0), outcome.hunger_extra_total());
}

test "consume_zone: fully transmuted mixed zone" {
    var zone = c.ZoneDef{ .neutral = 5 };
    zone.modified = .{ 10, 20, 0, 0 };
    const agents = [_]u32{ 10, 20, 0, 0 };
    _ = transmute(&zone, agents);
    const outcome = consume_zone(test_bal, zone);
    try std.testing.expectEqual(@as(u32, 0), outcome.modified_consumed);
    try std.testing.expectEqual(@as(u32, 35), outcome.score);
    try std.testing.expectEqual(35 * test_bal.hunger_cost_normal, outcome.hunger_normal);
    try std.testing.expectEqual(@as(u32, 0), outcome.hunger_extra_total());
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
