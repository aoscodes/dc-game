//! Pure resolution logic for the Slime Feast encounter: everything that maps
//! player CASTS onto game effects.
//!
//! Cast pipeline (driven by session.handle_cast, once per cast):
//!   1. `complete_group` — ask whether this cast, together with the casts
//!      already made on the same square this turn, completes a GROUP move.  If
//!      it does the cast is upgraded: it stamps the group's shape and pays the
//!      group's price instead of its own.
//!   2. the session checks the shared charge pool can afford the chosen stamp
//!      and debits it; a stamp the pool cannot pay for never happens.  An
//!      unaffordable group falls back to the plain move.
//!   3. the shape is handed to `slime.SlimeField.apply_shape` at the caster's
//!      aimed cursor, which owns all slime state.
//!
//! All functions here are pure/deterministic and unit-testable without a
//! session.  Slime-field mutation lives in `slime.zig`; hunger/score
//! bookkeeping helpers (`add_hunger`, `hunger_full`) live here.

const std = @import("std");
const c = @import("components.zig");
const balance = @import("balance.zig");

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

/// Step a selection one slot around the move cycle, wrapping at both ends.
/// `len` is the loaded move count and must be non-zero (config.zig rejects an
/// empty table, since a player with nothing selected could never cast).
pub fn cycle_selection(current: u8, dir: c.CycleDir, len: usize) u8 {
    std.debug.assert(len > 0);
    const n: u8 = @intCast(len);
    // A selection can outlive the table it indexed (a lobby reloading a smaller
    // custom config), so clamp before stepping rather than trusting it.
    const at: u8 = if (current >= n) 0 else current;
    return switch (dir) {
        .forward => if (at + 1 >= n) 0 else at + 1,
        .backward => if (at == 0) n - 1 else at - 1,
    };
}

// ---------------------------------------------------------------------------
// Casts → shapes
// ---------------------------------------------------------------------------

/// One cast already made this turn: who cast what, and where it landed.
/// Group moves are found among these (see `complete_group`).
pub const TurnCast = struct {
    player_id: u8,
    /// Index into balance.player_recipes — the move that was cast.
    move: u8,
    /// Flat grid index the cast was anchored at.
    square: u16,
};

/// Cap on the per-turn cast log: max players × casts each, with headroom.
pub const MAX_CASTS: usize = 64;

/// A group move completed by the cast under consideration.
pub const GroupHit = struct {
    /// Index into balance.team_recipes.
    recipe_index: u8,
    /// Indices into the `priors` slice: the earlier casts this group consumed.
    /// They have already stamped and paid; the session marks them spent so a
    /// single cast cannot be counted into two groups.
    consumed: [balance.MAX_TEAM_COMPONENTS]u8 =
        [_]u8{0} ** balance.MAX_TEAM_COMPONENTS,
    consumed_len: u8 = 0,

    pub fn spent(self: *const GroupHit) []const u8 {
        return self.consumed[0..self.consumed_len];
    }
};

/// Does `new_cast` complete a group move on its square?
///
/// A group needs its whole component bag present on ONE square, each component
/// supplied by a DIFFERENT player — that is what makes a group a coordination
/// move rather than a long combo.  `new_cast` supplies one component; `priors`
/// (this turn's earlier casts, in cast order) must supply the rest.
///
/// Groups are tried in table order and the first complete one wins, so an
/// earlier entry shadows a later one whose bag it contains.  Priors are matched
/// oldest-first, which keeps the choice deterministic and spends the casts that
/// have been waiting longest.
///
/// Returns null when nothing completes — the overwhelmingly common case, since
/// most casts are just a move landing on a cell.
pub fn complete_group(
    bal: *const balance.Balance,
    priors: []const TurnCast,
    new_cast: TurnCast,
) ?GroupHit {
    std.debug.assert(priors.len <= MAX_CASTS);

    groups: for (bal.team_recipes, 0..) |tr, ti| {
        // The new cast has to be part of the bag it completes, otherwise this
        // is a group somebody else's cast should have fired.
        const supplies = for (tr.components) |comp| {
            if (comp == new_cast.move) break true;
        } else false;
        if (!supplies) continue;

        var hit = GroupHit{ .recipe_index = @intCast(ti) };
        var used = [_]bool{false} ** MAX_CASTS;
        var new_cast_used = false;

        for (tr.components) |comp| {
            // Let the new cast cover one matching component before drawing on
            // the log: it is the reason we are here, and covering it first is
            // what makes "the completing cast" well defined.
            if (!new_cast_used and comp == new_cast.move) {
                new_cast_used = true;
                continue;
            }
            const found = for (priors, 0..) |p, pi| {
                if (used[pi]) continue;
                if (p.square != new_cast.square) continue;
                if (p.move != comp) continue;
                if (p.player_id == new_cast.player_id) continue;
                // Distinct players: a contributor already counted into this
                // group cannot supply a second component of it.
                const taken = for (hit.spent()) |s| {
                    if (priors[s].player_id == p.player_id) break true;
                } else false;
                if (taken) continue;
                break pi;
            } else null;
            const pi = found orelse continue :groups;
            used[pi] = true;
            hit.consumed[hit.consumed_len] = @intCast(pi);
            hit.consumed_len += 1;
        }
        return hit;
    }
    return null;
}

/// The shape a cast resolves to: its footprint, its price, and what fired.
pub const ShapeCast = struct {
    shape: balance.Shape,
    /// Charges this stamp costs the shared pool.  Copied from the move so the
    /// session can price it without looking the table up again.
    cost: u16,
    /// The player whose cursor anchors this stamp — always the caster, since a
    /// group is anchored by the cast that completed it.
    anchor_player: u8,
    /// Index into the table this came from, for the recipe_fired broadcast.
    recipe_index: u8,
    is_team: bool,
};

/// The stamp a plain (ungrouped) cast of `move` by `player` produces.
pub fn move_stamp(bal: *const balance.Balance, move: u8, player_id: u8) ShapeCast {
    const pr = bal.player_recipes[move];
    return .{
        .shape = pr.shape,
        .cost = pr.cost,
        .anchor_player = player_id,
        .recipe_index = move,
        .is_team = false,
    };
}

/// The stamp a cast produces when it completes `hit`: the group's shape at the
/// completing caster, priced as the group.
pub fn group_stamp(bal: *const balance.Balance, hit: GroupHit, player_id: u8) ShapeCast {
    const tr = bal.team_recipes[hit.recipe_index];
    return .{
        .shape = tr.shape,
        .cost = tr.cost,
        .anchor_player = player_id,
        .recipe_index = hit.recipe_index,
        .is_team = true,
    };
}

// ---------------------------------------------------------------------------
// Hunger
// ---------------------------------------------------------------------------

/// Sum a per-tier u16 array (convenience for totals).
pub fn sum_u16(values: [c.Tier.size]u16) u32 {
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixtures = @import("fixtures.zig");
/// Frozen fixture balance — designer edits to data/*.json can't break these.
const test_bal = &fixtures.test_config.balance;

const POKE = fixtures.POKE;
const SWEEP = fixtures.SWEEP;
const BLOCK = fixtures.BLOCK;
const TRICKLE = fixtures.TRICKLE;
const DELUGE = fixtures.DELUGE;
const TWIN_BLOOM = fixtures.TWIN_BLOOM;
const CROSSFIRE = fixtures.CROSSFIRE;

/// An arbitrary square; group membership is about SHARING a square, so which
/// one it is never matters.
const SQ: u16 = 17;
const OTHER_SQ: u16 = 18;

// --- selection -------------------------------------------------------------

test "cycle_selection: forward and backward step one slot" {
    try std.testing.expectEqual(@as(u8, 1), cycle_selection(0, .forward, 7));
    try std.testing.expectEqual(@as(u8, 3), cycle_selection(4, .backward, 7));
}

test "cycle_selection: the wheel wraps at both ends" {
    // No dead stop: cycling past the last move returns to the first, and
    // stepping back from the first reaches the last.
    try std.testing.expectEqual(@as(u8, 0), cycle_selection(6, .forward, 7));
    try std.testing.expectEqual(@as(u8, 6), cycle_selection(0, .backward, 7));
}

test "cycle_selection: a single-move table stays put" {
    try std.testing.expectEqual(@as(u8, 0), cycle_selection(0, .forward, 1));
    try std.testing.expectEqual(@as(u8, 0), cycle_selection(0, .backward, 1));
}

test "cycle_selection: an out-of-range selection is clamped, not wrapped past" {
    // A selection can outlive its table when a lobby loads a smaller custom
    // config; it must land somewhere valid rather than index off the end.
    try std.testing.expectEqual(@as(u8, 1), cycle_selection(200, .forward, 7));
    try std.testing.expectEqual(@as(u8, 6), cycle_selection(200, .backward, 7));
}

// --- plain casts -----------------------------------------------------------

test "move_stamp: a move stamps its own shape at its own caster" {
    const stamp = move_stamp(test_bal, BLOCK, 3);
    try std.testing.expectEqual(@as(u8, 3), stamp.anchor_player);
    try std.testing.expect(!stamp.is_team);
    try std.testing.expectEqual(BLOCK, stamp.recipe_index);
    // `block` is the 3x3.
    try std.testing.expectEqual(@as(usize, 9), stamp.shape.size());
}

test "move_stamp: a stamp carries the charge cost of its move" {
    try std.testing.expectEqual(@as(u16, 9), move_stamp(test_bal, DELUGE, 0).cost);
    try std.testing.expectEqual(@as(u16, 0), move_stamp(test_bal, TRICKLE, 0).cost);
}

test "cheapest_cost is the floor of the whole move list" {
    // The session compares the pool against this to spot a dead position, so it
    // must see the free move and conclude the team is never truly bankrupt.
    try std.testing.expectEqual(@as(u16, 0), test_bal.cheapest_cost());
}

// --- groups ----------------------------------------------------------------

test "complete_group: a lone cast completes nothing" {
    // The first component to land is just a move landing.
    const hit = complete_group(test_bal, &.{}, .{ .player_id = 0, .move = POKE, .square = SQ });
    try std.testing.expect(hit == null);
}

test "complete_group: a second player on the same square completes the group" {
    const priors = [_]TurnCast{.{ .player_id = 0, .move = POKE, .square = SQ }};
    const hit = complete_group(test_bal, &priors, .{ .player_id = 1, .move = POKE, .square = SQ }).?;

    try std.testing.expectEqual(TWIN_BLOOM, hit.recipe_index);
    // The prior cast is spent, so it cannot be counted into a second group.
    try std.testing.expectEqualSlices(u8, &.{0}, hit.spent());
}

test "complete_group: the completing cast anchors and prices the group" {
    const priors = [_]TurnCast{.{ .player_id = 0, .move = POKE, .square = SQ }};
    const hit = complete_group(test_bal, &priors, .{ .player_id = 1, .move = POKE, .square = SQ }).?;
    const stamp = group_stamp(test_bal, hit, 1);

    // Player 1 closed the circuit, so player 1 aims it.
    try std.testing.expectEqual(@as(u8, 1), stamp.anchor_player);
    try std.testing.expect(stamp.is_team);
    try std.testing.expectEqual(TWIN_BLOOM, stamp.recipe_index);
    // Priced as the group, not as the poke that completed it.
    try std.testing.expectEqual(@as(u16, 4), stamp.cost);
    try std.testing.expectEqual(@as(usize, 13), stamp.shape.size());
}

test "complete_group: a different square is a different group" {
    // Casts must converge on ONE cell; scattering them coordinates nothing.
    const priors = [_]TurnCast{.{ .player_id = 0, .move = POKE, .square = OTHER_SQ }};
    const hit = complete_group(test_bal, &priors, .{ .player_id = 1, .move = POKE, .square = SQ });
    try std.testing.expect(hit == null);
}

test "complete_group: one player cannot supply two components" {
    // A group is a COOPERATION requirement, not a repeat-press.
    const priors = [_]TurnCast{.{ .player_id = 0, .move = POKE, .square = SQ }};
    const hit = complete_group(test_bal, &priors, .{ .player_id = 0, .move = POKE, .square = SQ });
    try std.testing.expect(hit == null);
}

test "complete_group: a distinct player still completes alongside a duplicate" {
    const priors = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 0, .move = POKE, .square = SQ }, // same player again
    };
    const hit = complete_group(test_bal, &priors, .{ .player_id = 1, .move = POKE, .square = SQ }).?;
    try std.testing.expectEqual(TWIN_BLOOM, hit.recipe_index);
    // Oldest-first: the earliest usable prior is the one spent.
    try std.testing.expectEqualSlices(u8, &.{0}, hit.spent());
}

test "complete_group: an asymmetric group completes from either side" {
    // crossfire = sweep + block; whoever brings the second half completes it.
    const sweep_first = [_]TurnCast{.{ .player_id = 0, .move = SWEEP, .square = SQ }};
    const a = complete_group(test_bal, &sweep_first, .{ .player_id = 1, .move = BLOCK, .square = SQ }).?;
    try std.testing.expectEqual(CROSSFIRE, a.recipe_index);

    const block_first = [_]TurnCast{.{ .player_id = 0, .move = BLOCK, .square = SQ }};
    const b = complete_group(test_bal, &block_first, .{ .player_id = 1, .move = SWEEP, .square = SQ }).?;
    try std.testing.expectEqual(CROSSFIRE, b.recipe_index);
}

test "complete_group: the completing cast must supply a component" {
    // A wedge is in no group's bag, so landing it on a waiting poke completes
    // nothing — the group belongs to whoever brings the move it actually needs.
    const priors = [_]TurnCast{.{ .player_id = 0, .move = POKE, .square = SQ }};
    const hit = complete_group(test_bal, &priors, .{ .player_id = 1, .move = fixtures.WEDGE, .square = SQ });
    try std.testing.expect(hit == null);
}

test "complete_group: an incomplete bag fires nothing" {
    // crossfire needs a block too; a lone sweep partner is not enough.
    const priors = [_]TurnCast{.{ .player_id = 0, .move = SWEEP, .square = SQ }};
    const hit = complete_group(test_bal, &priors, .{ .player_id = 1, .move = SWEEP, .square = SQ });
    try std.testing.expect(hit == null);
}

test "complete_group: an earlier group shadows a later one containing its bag" {
    // triad (3 pokes) contains twin_bloom's bag (2 pokes) and is listed after
    // it, so the second poke fires twin_bloom and triad can never be reached.
    // Table order is the tiebreak, which is why it is designer-visible.
    const priors = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
    };
    const hit = complete_group(test_bal, &priors, .{ .player_id = 2, .move = POKE, .square = SQ }).?;
    try std.testing.expectEqual(TWIN_BLOOM, hit.recipe_index);
    try std.testing.expectEqual(@as(u8, 1), hit.consumed_len);
}

test "complete_group: three distinct players fire two pairs, not one triple" {
    // Following on from the shadowing above: the session marks spent priors, so
    // the third poke pairs with the one the second left behind.
    const first = [_]TurnCast{.{ .player_id = 0, .move = POKE, .square = SQ }};
    const pair_a = complete_group(test_bal, &first, .{ .player_id = 1, .move = POKE, .square = SQ }).?;
    try std.testing.expectEqual(@as(u8, 1), pair_a.consumed_len);

    // Player 1's completing cast is itself logged, and player 0's is spent.
    const remaining = [_]TurnCast{.{ .player_id = 1, .move = POKE, .square = SQ }};
    const pair_b = complete_group(test_bal, &remaining, .{ .player_id = 2, .move = POKE, .square = SQ }).?;
    try std.testing.expectEqual(TWIN_BLOOM, pair_b.recipe_index);
}

test "complete_group: an empty group table completes nothing" {
    var bal = test_bal.*;
    bal.team_recipes = &.{};
    const priors = [_]TurnCast{.{ .player_id = 0, .move = POKE, .square = SQ }};
    try std.testing.expect(complete_group(&bal, &priors, .{ .player_id = 1, .move = POKE, .square = SQ }) == null);
}

test "complete_group: a three-component group needs three distinct players" {
    var bal = test_bal.*;
    // Only `triad` loaded, so nothing shadows it.
    bal.team_recipes = fixtures.team_recipes[fixtures.TRIAD..];
    const two = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
    };
    const hit = complete_group(&bal, &two, .{ .player_id = 2, .move = POKE, .square = SQ }).?;
    try std.testing.expectEqual(@as(u8, 2), hit.consumed_len);

    // The same two casts plus a REPEAT of player 1 leaves the bag one short.
    const dup = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
    };
    try std.testing.expect(complete_group(&bal, &dup, .{ .player_id = 1, .move = POKE, .square = SQ }) == null);
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
