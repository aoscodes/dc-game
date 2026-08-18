//! Pure resolution logic for the Slime Feast encounter: everything that maps
//! player CASTS onto game effects.
//!
//! Cast pipeline (driven by session.fire_expired_casts, once per batch of
//! casts that expire together):
//!   1. `match_recipes`   — resolve the batch's casts into the SHAPES to stamp
//!                          (each with the player whose cursor anchors it) and
//!                          the medicine brewed.  Team recipes → player
//!                          recipes; team recipes need distinct players in the
//!                          SAME batch.  Unmatched casts produce nothing.
//!   2. `apply_medicine`  — heal the hunger bar immediately, capped by the
//!                          per-tier healable (hazard-slime) portions.
//!   3. each shape is handed to `slime.SlimeField.apply_shape` at its caster's
//!      aimed cursor, which owns all slime state.
//!
//! All functions here are pure/deterministic and unit-testable without a
//! session.  Slime-field mutation lives in `slime.zig`; hunger/score
//! bookkeeping helpers (`add_hunger`, `hunger_full`) live here.

const std = @import("std");
const c = @import("components.zig");
const balance = @import("balance.zig");

// ---------------------------------------------------------------------------
// Combo → shapes + medicine
// ---------------------------------------------------------------------------

/// Exact structural equality: same length, same slots in the same order.
pub fn combos_equal(a: c.ActionCombo, b: c.ActionCombo) bool {
    if (a.len != b.len) return false;
    for (a.slots[0..a.len], b.slots[0..b.len]) |x, y| {
        if (!std.meta.eql(x, y)) return false;
    }
    return true;
}

/// True if committing this combo could produce ANY effect: it exactly matches
/// a player recipe, or any single pattern of a team recipe (the partner may
/// commit in the same window).  Since there is no flat fallback, the recipe
/// tables are the complete move list, and a combo naming no recipe FIZZLES
/// instead of committing — so a mistyped sequence never wastes a cast.
pub fn combo_has_output(bal: *const balance.Balance, combo: c.ActionCombo) bool {
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

/// One shape a batch resolved to, and who aims it.
pub const ShapeCast = struct {
    shape: balance.Shape,
    /// The player whose cursor anchors this stamp.  For a player recipe that
    /// is the caster; for a team recipe it is the LAST JOINER — the player
    /// whose submit completed the group, since they chose to close the circuit.
    anchor_player: u8,
    /// Index into the table this came from, for the recipe_fired broadcast.
    recipe_index: u8,
    is_team: bool,
};

/// Everything a batch of casts resolves to: the shapes to stamp (in fire
/// order) and the medicine brewed.
pub const BatchOutcome = struct {
    shapes: [MAX_CASTS]ShapeCast = undefined,
    shape_count: usize = 0,
    medicine: c.MedicineOutput = .{},

    pub fn stamps(self: *const BatchOutcome) []const ShapeCast {
        return self.shapes[0..self.shape_count];
    }
};

/// Resolve one round's committed casts into shapes to stamp plus medicine.
/// When `report` is non-null it is filled with recipe fire counts and
/// per-cast consumption for stats.
///
/// Matching order (a cast is consumed by at most one recipe):
///   1. Team recipes, greedily in bal.team_recipes order.  Each pattern
///      must be matched exactly by a DISTINCT player's cast — one player
///      casting both halves does not trigger a team recipe.  A recipe
///      repeats while disjoint groups keep matching.  The combined shape is
///      anchored at the last joiner's cursor.
///   2. Player recipes in bal.player_recipes order (exact match), anchored at
///      the caster's own cursor.
/// Casts matching nothing produce no effect (no flat fallback).
///
/// `last_joiner` is the player whose submit triggered this batch, used to
/// anchor team shapes; pass null when no single player closed the group (e.g.
/// a batch fired purely by buffer expiry), in which case the team shape falls
/// back to the first contributor's cursor.
pub fn match_recipes(
    bal: *const balance.Balance,
    casts: []const Cast,
    last_joiner: ?u8,
    report: ?*MatchReport,
) BatchOutcome {
    std.debug.assert(casts.len <= MAX_CASTS);
    var out = BatchOutcome{};
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
            // The last joiner aims the combined shape — but only if they are
            // actually in THIS instance; otherwise the first contributor does.
            var anchor = casts[picks[0]].player_id;
            if (last_joiner) |lj| {
                for (tr.patterns, 0..) |_, pi| {
                    if (casts[picks[pi]].player_id == lj) {
                        anchor = lj;
                        break;
                    }
                }
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
            out.medicine.add(tr.medicine);
            out.shapes[out.shape_count] = .{
                .shape = tr.shape,
                .anchor_player = anchor,
                .recipe_index = @intCast(ti),
                .is_team = true,
            };
            out.shape_count += 1;
        }
    }

    // 2. Player recipes — each anchored at its own caster's cursor.
    for (casts, 0..) |cast, ci| {
        if (consumed[ci]) continue;
        for (bal.player_recipes, 0..) |pr, pi| {
            if (combos_equal(cast.combo, pr.pattern)) {
                out.medicine.add(pr.medicine);
                out.shapes[out.shape_count] = .{
                    .shape = pr.shape,
                    .anchor_player = cast.player_id,
                    .recipe_index = @intCast(pi),
                    .is_team = false,
                };
                out.shape_count += 1;
                consumed[ci] = true;
                if (report) |r| {
                    r.player_hits[pi] +|= 1;
                    r.consumed[ci] = .player_recipe;
                }
                break;
            }
        }
    }

    return out;
}

// ---------------------------------------------------------------------------
// Hunger + zone consumption
// ---------------------------------------------------------------------------

/// Heal the hunger bar with per-tier medicine pools.  Medicine is
/// symmetrical: the tier-T pool heals only `healable[T]` — the hunger
/// attributable to eating un-neutralized tier-T hazard slime — and is
/// further capped by the current hunger level.  Overheal is discarded.
/// Returns the amount actually healed per tier (sum for the total).
pub fn apply_medicine(
    hunger: *c.Health,
    healable: *[c.Tier.size]u16,
    pools: [c.Tier.size]u32,
) [c.Tier.size]u16 {
    var healed = [_]u16{0} ** c.Tier.size;
    for (pools, 0..) |pool, i| {
        const cap = @min(@as(u32, healable[i]), @as(u32, hunger.current));
        const heal: u16 = @intCast(@min(pool, cap));
        hunger.current -= heal;
        healable[i] -= heal;
        healed[i] = heal;
    }
    return healed;
}

/// Sum a per-tier u16 array (convenience for totals).
pub fn sum_u16(values: [c.Tier.size]u16) u32 {
    var total: u32 = 0;
    for (values) |v| total += v;
    return total;
}

/// Sum a per-tier u32 array — e.g. a MedicineOutput's pools.
pub fn sum_u32(values: [c.Tier.size]u32) u32 {
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

const D = c.ComboSlot{ .action = .dispense };
const M = c.ComboSlot{ .action = .medicine };

fn tier_ix(t: c.Tier) usize {
    return @intFromEnum(t);
}

/// Fixture recipe patterns, by label, so tests read as intent not as keystrokes.
const POKE = mk(&.{D});
const SWEEP = mk(&.{ D, D });
const BLOCK = mk(&.{ D, D, D });
const TONIC = mk(&.{ M, M });
const RED_TONIC = mk(&.{ M, M, M });
const BLOOM_HALF = mk(&.{ D, M });
const CROSSFIRE_A = mk(&.{ M, D });
const CROSSFIRE_B = mk(&.{ M, D, D });

test "combos_equal: identical combos match" {
    try std.testing.expect(combos_equal(SWEEP, mk(&.{ D, D })));
}

test "combos_equal: different length / slot / order do not match" {
    try std.testing.expect(!combos_equal(SWEEP, BLOCK));
    try std.testing.expect(!combos_equal(SWEEP, mk(&.{ D, M })));
    try std.testing.expect(!combos_equal(mk(&.{ D, M }), mk(&.{ M, D })));
}

test "match_recipes: a player recipe stamps its shape at its own caster" {
    const casts = [_]Cast{.{ .player_id = 3, .combo = BLOCK }};
    const out = match_recipes(test_bal, &casts, null, null);

    try std.testing.expectEqual(@as(usize, 1), out.shape_count);
    const stamp = out.stamps()[0];
    try std.testing.expectEqual(@as(u8, 3), stamp.anchor_player);
    try std.testing.expect(!stamp.is_team);
    // `block` is the 3x3.
    try std.testing.expectEqual(@as(usize, 9), stamp.shape.size());
}

test "match_recipes: an unmatched combo produces nothing" {
    // No flat fallback: the recipe tables are the whole move list.
    const nonsense = mk(&.{ M, D, M, D, M });
    const casts = [_]Cast{.{ .player_id = 0, .combo = nonsense }};
    const out = match_recipes(test_bal, &casts, null, null);
    try std.testing.expectEqual(@as(usize, 0), out.shape_count);
    try std.testing.expectEqual(@as(u32, 0), out.medicine.total());
}

test "match_recipes: a recipe's medicine is brewed alongside its shape" {
    const casts = [_]Cast{.{ .player_id = 0, .combo = TONIC }};
    const out = match_recipes(test_bal, &casts, null, null);
    try std.testing.expectEqual(@as(usize, 1), out.shape_count);
    try std.testing.expectEqual(@as(u32, 18), out.medicine.total());
    for (0..c.Tier.size) |t| {
        try std.testing.expectEqual(@as(u32, 6), out.medicine.medicine[t]);
    }
}

test "match_recipes: tier-targeted medicine only fills its own pool" {
    const casts = [_]Cast{.{ .player_id = 0, .combo = RED_TONIC }};
    const out = match_recipes(test_bal, &casts, null, null);
    try std.testing.expectEqual(@as(u32, 10), out.medicine.medicine[tier_ix(.red)]);
    try std.testing.expectEqual(@as(u32, 0), out.medicine.medicine[tier_ix(.yellow)]);
    try std.testing.expectEqual(@as(u32, 0), out.medicine.medicine[tier_ix(.green)]);
}

test "match_recipes: team recipe consumes both casts and stamps ONE shape" {
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = BLOOM_HALF },
        .{ .player_id = 1, .combo = BLOOM_HALF },
    };
    var report = MatchReport{};
    const out = match_recipes(test_bal, &casts, null, &report);

    // Two casts, one combined shape — not one shape each.
    try std.testing.expectEqual(@as(usize, 1), out.shape_count);
    try std.testing.expect(out.stamps()[0].is_team);
    try std.testing.expectEqual(@as(u16, 1), report.team_hits[0]);
    try std.testing.expectEqual(ConsumedBy.team_recipe, report.consumed[0]);
    try std.testing.expectEqual(ConsumedBy.team_recipe, report.consumed[1]);
}

test "match_recipes: the last joiner aims the team shape" {
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = BLOOM_HALF },
        .{ .player_id = 1, .combo = BLOOM_HALF },
    };
    // Player 1 closed the circuit, so player 1 aims it...
    const p1 = match_recipes(test_bal, &casts, 1, null);
    try std.testing.expectEqual(@as(u8, 1), p1.stamps()[0].anchor_player);

    // ...and player 0 aims it when they were the one to complete the group.
    const p0 = match_recipes(test_bal, &casts, 0, null);
    try std.testing.expectEqual(@as(u8, 0), p0.stamps()[0].anchor_player);
}

test "match_recipes: team shape falls back to the first contributor" {
    const casts = [_]Cast{
        .{ .player_id = 2, .combo = BLOOM_HALF },
        .{ .player_id = 5, .combo = BLOOM_HALF },
    };
    // No joiner (pure buffer expiry): the first contributor aims it.
    const none = match_recipes(test_bal, &casts, null, null);
    try std.testing.expectEqual(@as(u8, 2), none.stamps()[0].anchor_player);

    // A joiner who is not in this instance cannot aim it either.
    const outsider = match_recipes(test_bal, &casts, 7, null);
    try std.testing.expectEqual(@as(u8, 2), outsider.stamps()[0].anchor_player);
}

test "match_recipes: an asymmetric team recipe matches either cast order" {
    const forward = [_]Cast{
        .{ .player_id = 0, .combo = CROSSFIRE_A },
        .{ .player_id = 1, .combo = CROSSFIRE_B },
    };
    const backward = [_]Cast{
        .{ .player_id = 0, .combo = CROSSFIRE_B },
        .{ .player_id = 1, .combo = CROSSFIRE_A },
    };
    try std.testing.expectEqual(@as(usize, 1), match_recipes(test_bal, &forward, null, null).shape_count);
    try std.testing.expectEqual(@as(usize, 1), match_recipes(test_bal, &backward, null, null).shape_count);
}

test "match_recipes: team recipe fires twice for two disjoint pairs" {
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = BLOOM_HALF },
        .{ .player_id = 1, .combo = BLOOM_HALF },
        .{ .player_id = 2, .combo = BLOOM_HALF },
        .{ .player_id = 3, .combo = BLOOM_HALF },
    };
    var report = MatchReport{};
    const out = match_recipes(test_bal, &casts, null, &report);
    try std.testing.expectEqual(@as(usize, 2), out.shape_count);
    try std.testing.expectEqual(@as(u16, 2), report.team_hits[0]);
    // Medicine accrues per instance.
    try std.testing.expectEqual(@as(u32, 8), out.medicine.medicine[tier_ix(.red)]);
}

test "match_recipes: team_instance groups each recipe instance's casts" {
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = BLOOM_HALF },
        .{ .player_id = 1, .combo = BLOOM_HALF },
        .{ .player_id = 2, .combo = BLOOM_HALF },
        .{ .player_id = 3, .combo = BLOOM_HALF },
    };
    var report = MatchReport{};
    _ = match_recipes(test_bal, &casts, null, &report);
    // Two instances of two casts each; members share an id, instances differ.
    try std.testing.expectEqual(report.team_instance[0], report.team_instance[1]);
    try std.testing.expectEqual(report.team_instance[2], report.team_instance[3]);
    try std.testing.expect(report.team_instance[0] != report.team_instance[2]);
}

test "match_recipes: same player casting both halves does NOT fire team recipe" {
    // A team recipe is a COOPERATION requirement, not a combo length.
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = BLOOM_HALF },
        .{ .player_id = 0, .combo = BLOOM_HALF },
    };
    const out = match_recipes(test_bal, &casts, null, null);
    // No team shape fired; `[D,M]` matches no player recipe either.
    try std.testing.expectEqual(@as(usize, 0), out.shape_count);
}

test "match_recipes: distinct-player pair still fires alongside a duplicate" {
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = BLOOM_HALF },
        .{ .player_id = 0, .combo = BLOOM_HALF },
        .{ .player_id = 1, .combo = BLOOM_HALF },
    };
    var report = MatchReport{};
    const out = match_recipes(test_bal, &casts, null, &report);
    // Exactly one pair can be formed across distinct players.
    try std.testing.expectEqual(@as(usize, 1), out.shape_count);
    try std.testing.expectEqual(@as(u16, 1), report.team_hits[0]);
}

test "match_recipes: a lone half of a team recipe does nothing" {
    const casts = [_]Cast{.{ .player_id = 0, .combo = BLOOM_HALF }};
    const out = match_recipes(test_bal, &casts, null, null);
    try std.testing.expectEqual(@as(usize, 0), out.shape_count);
}

test "match_recipes: team pair plus an independent player recipe" {
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = BLOOM_HALF },
        .{ .player_id = 1, .combo = BLOOM_HALF },
        .{ .player_id = 2, .combo = POKE },
    };
    const out = match_recipes(test_bal, &casts, 1, null);
    try std.testing.expectEqual(@as(usize, 2), out.shape_count);
    // Team shape first (table order), then the player recipe.
    try std.testing.expect(out.stamps()[0].is_team);
    try std.testing.expectEqual(@as(u8, 1), out.stamps()[0].anchor_player);
    try std.testing.expect(!out.stamps()[1].is_team);
    try std.testing.expectEqual(@as(u8, 2), out.stamps()[1].anchor_player);
    try std.testing.expectEqual(@as(usize, 1), out.stamps()[1].shape.size());
}

test "match_recipes: every cast in a batch gets its own anchor" {
    const casts = [_]Cast{
        .{ .player_id = 4, .combo = POKE },
        .{ .player_id = 7, .combo = SWEEP },
    };
    const out = match_recipes(test_bal, &casts, null, null);
    try std.testing.expectEqual(@as(usize, 2), out.shape_count);
    try std.testing.expectEqual(@as(u8, 4), out.stamps()[0].anchor_player);
    try std.testing.expectEqual(@as(u8, 7), out.stamps()[1].anchor_player);
}

test "match_recipes: report records fire counts and per-cast consumption" {
    const casts = [_]Cast{
        .{ .player_id = 0, .combo = BLOCK },
        .{ .player_id = 1, .combo = mk(&.{ M, D, M, D, M }) }, // matches nothing
    };
    var report = MatchReport{};
    _ = match_recipes(test_bal, &casts, null, &report);
    // `block` is index 2 in the fixture player table.
    try std.testing.expectEqual(@as(u16, 1), report.player_hits[2]);
    try std.testing.expectEqual(ConsumedBy.player_recipe, report.consumed[0]);
    try std.testing.expectEqual(ConsumedBy.none, report.consumed[1]);
    try std.testing.expectEqual(NO_TEAM_INSTANCE, report.team_instance[0]);
}

test "combo_has_output: a combo naming no recipe fizzles" {
    try std.testing.expect(!combo_has_output(test_bal, mk(&.{ M, D, M, D, M })));
    try std.testing.expect(!combo_has_output(test_bal, mk(&.{ M, M, M, M })));
}

test "combo_has_output: player and team patterns both count" {
    try std.testing.expect(combo_has_output(test_bal, BLOCK));
    try std.testing.expect(combo_has_output(test_bal, TONIC));
    // A team half commits: the partner may still complete it this window.
    try std.testing.expect(combo_has_output(test_bal, BLOOM_HALF));
    try std.testing.expect(combo_has_output(test_bal, CROSSFIRE_B));
}

test "apply_medicine: capped by the matching tier's healable portion" {
    var hunger = c.Health{ .current = 50, .max = 100 };
    var healable = [_]u16{0} ** c.Tier.size;
    healable[tier_ix(.red)] = 8;

    var pools = [_]u32{0} ** c.Tier.size;
    pools[tier_ix(.red)] = 20;
    const healed = apply_medicine(&hunger, &healable, pools);

    // Only the 8 healable points were red's doing; the other 12 are wasted.
    try std.testing.expectEqual(@as(u16, 8), healed[tier_ix(.red)]);
    try std.testing.expectEqual(@as(u16, 42), hunger.current);
    try std.testing.expectEqual(@as(u16, 0), healable[tier_ix(.red)]);
}

test "apply_medicine: asymmetric medicine heals nothing" {
    // Green medicine cannot undo what red slime did.
    var hunger = c.Health{ .current = 50, .max = 100 };
    var healable = [_]u16{0} ** c.Tier.size;
    healable[tier_ix(.red)] = 10;

    var pools = [_]u32{0} ** c.Tier.size;
    pools[tier_ix(.green)] = 30;
    const healed = apply_medicine(&hunger, &healable, pools);

    try std.testing.expectEqual(@as(u32, 0), sum_u16(healed));
    try std.testing.expectEqual(@as(u16, 50), hunger.current);
    try std.testing.expectEqual(@as(u16, 10), healable[tier_ix(.red)]);
}

test "apply_medicine: tiers heal independently" {
    var hunger = c.Health{ .current = 30, .max = 100 };
    var healable = [_]u16{0} ** c.Tier.size;
    healable[tier_ix(.red)] = 5;
    healable[tier_ix(.yellow)] = 7;
    healable[tier_ix(.green)] = 2;

    var pools = [_]u32{0} ** c.Tier.size;
    pools[tier_ix(.red)] = 5;
    pools[tier_ix(.yellow)] = 3;
    const healed = apply_medicine(&hunger, &healable, pools);

    try std.testing.expectEqual(@as(u16, 5), healed[tier_ix(.red)]);
    try std.testing.expectEqual(@as(u16, 3), healed[tier_ix(.yellow)]);
    try std.testing.expectEqual(@as(u16, 0), healed[tier_ix(.green)]);
    try std.testing.expectEqual(@as(u16, 22), hunger.current);
    // Yellow keeps the 4 points the pool could not reach.
    try std.testing.expectEqual(@as(u16, 4), healable[tier_ix(.yellow)]);
}

test "apply_medicine: capped by current hunger" {
    var hunger = c.Health{ .current = 3, .max = 100 };
    var healable = [_]u16{0} ** c.Tier.size;
    healable[tier_ix(.red)] = 50;

    var pools = [_]u32{0} ** c.Tier.size;
    pools[tier_ix(.red)] = 50;
    const healed = apply_medicine(&hunger, &healable, pools);

    try std.testing.expectEqual(@as(u16, 3), healed[tier_ix(.red)]);
    try std.testing.expectEqual(@as(u16, 0), hunger.current);
}

test "apply_medicine: zero healable — eating clean slime is not healable" {
    var hunger = c.Health{ .current = 40, .max = 100 };
    var healable = [_]u16{0} ** c.Tier.size;
    var pools = [_]u32{0} ** c.Tier.size;
    pools[tier_ix(.red)] = 25;
    const healed = apply_medicine(&hunger, &healable, pools);
    try std.testing.expectEqual(@as(u32, 0), sum_u16(healed));
    try std.testing.expectEqual(@as(u16, 40), hunger.current);
}

test "add_hunger: clamps at max" {
    var hunger = c.Health{ .current = 95, .max = 100 };
    add_hunger(&hunger, 3);
    try std.testing.expectEqual(@as(u16, 98), hunger.current);
    try std.testing.expect(!hunger_full(hunger));
    add_hunger(&hunger, 999);
    try std.testing.expectEqual(@as(u16, 100), hunger.current);
    try std.testing.expect(hunger_full(hunger));
}
