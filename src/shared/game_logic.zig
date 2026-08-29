//! Pure resolution logic for the Slime Feast encounter: everything that maps
//! player CASTS onto game effects.
//!
//! Cast pipeline (driven by session, REALTIME):
//!   1. a cast RESOLVES THE MOMENT it is pressed: the session prices it,
//!      debits the pool and hands the move's stamp to
//!      `slime.SlimeField.apply_shape` at the aimed square.
//!   2. the landed cast joins a rolling WINDOW of recent casts
//!      (`balance.team_window_ms` deep).  `complete_group` checks whether the
//!      new cast just completed a team recipe's bag on its square — DISTINCT
//!      players, same square, all within the window.  If so the group's
//!      shape fires too, and the completing cast pays the GROUP's cost
//!      instead of its own: the contributors already paid their own way as
//!      they landed, so the group price is the price of the upgrade.
//!   3. consumed contributors leave the window — a cast feeds at most one
//!      group.
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

/// One cast that has already LANDED, kept in the session's rolling window so
/// later casts can complete a team recipe with it (see `complete_group`).
pub const RecentCast = struct {
    player_id: u8,
    /// Index into balance.player_recipes — the move that was cast.
    move: u8,
    /// Flat grid index the cast was anchored at.
    square: u16,
    /// Session clock (ms) when the cast landed.  The window is measured
    /// between landing times, so lag between two contributors is exactly the
    /// time between their stamps.
    at_ms: u64,
};

/// Cap on the rolling recent-cast window: max players × a generous burst,
/// with headroom.  The session evicts oldest-first past this.
pub const MAX_RECENT: usize = 64;

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

/// The stamp a fired group produces: the group's shape, priced as the group,
/// credited to `player_id` (the contributor whose cast completed the bag —
/// see `complete_group`).
pub fn group_stamp(bal: *const balance.Balance, recipe_index: u8, player_id: u8) ShapeCast {
    const tr = bal.team_recipes[recipe_index];
    return .{
        .shape = tr.shape,
        .cost = tr.cost,
        .anchor_player = player_id,
        .recipe_index = recipe_index,
        .is_team = true,
    };
}

// ---------------------------------------------------------------------------
// Group completion (realtime window)
// ---------------------------------------------------------------------------

/// What a completing cast fired: which team recipe, and which entries of the
/// recent-cast window it consumed as contributors.
pub const GroupFire = struct {
    /// Index into balance.team_recipes.
    recipe_index: u8,
    /// Indices INTO THE `recent` SLICE handed to `complete_group` — the
    /// contributors the group consumed.  The completing cast itself is not
    /// in `recent` and so not listed.  The session must evict these from its
    /// window: a cast feeds at most one group.
    consumed: [balance.MAX_TEAM_COMPONENTS]usize = undefined,
    consumed_count: usize = 0,
};

/// Did `cast` just complete a team recipe?
///
/// A group needs its whole component bag on ONE square, each component from a
/// DIFFERENT player, every contribution landing within `team_window_ms` of
/// the completing cast — that is what makes it a coordination move rather
/// than a long combo.  Groups are tried in TABLE ORDER and the first whose
/// bag fills wins, so an earlier entry shadows a later one whose bag it
/// contains — the same designer-visible tiebreak the turn loop had.
///
/// The NEW cast must itself supply one component (a group completes on a
/// contribution, never on a bystander), and the rest are drawn oldest-first
/// from `recent` casts on the same square.  One player can supply only one
/// component, however many casts they have in the window — including the
/// completer: their window entries never feed a group they are completing.
///
/// Pure: nothing is consumed here.  The session evicts `consumed` from its
/// window and fires `group_stamp(recipe_index, cast.player_id)` — the group
/// is credited (and billed) to the player who completed it.
pub fn complete_group(
    bal: *const balance.Balance,
    recent: []const RecentCast,
    cast: RecentCast,
) ?GroupFire {
    std.debug.assert(recent.len <= MAX_RECENT);
    for (bal.team_recipes, 0..) |tr, ti| {
        // A componentless group is spelled by nothing.  config.zig rejects
        // one; guard rather than trust.
        if (tr.components.len == 0) continue;

        // The new cast must cover one instance of its own move in the bag.
        const own = for (tr.components, 0..) |comp, i| {
            if (comp == cast.move) break i;
        } else continue;

        var fire = GroupFire{ .recipe_index = @intCast(ti) };
        const filled = for (tr.components, 0..) |comp, slot| {
            if (slot == own) continue;
            const found = for (recent, 0..) |cand, ci| {
                if (cand.square != cast.square) continue;
                if (cand.move != comp) continue;
                // Within the window, measured landing-to-landing.  The
                // session prunes its window every tick, but check anyway so
                // correctness never depends on pruning cadence.
                if (cand.at_ms + bal.team_window_ms < cast.at_ms) continue;
                // Distinct players: one player supplies one component, and
                // the completer's own earlier casts never count.
                if (cand.player_id == cast.player_id) continue;
                const taken = for (fire.consumed[0..fire.consumed_count]) |pi| {
                    if (recent[pi].player_id == cand.player_id) break true;
                } else false;
                if (taken) continue;
                break ci;
            } else break false;
            fire.consumed[fire.consumed_count] = found;
            fire.consumed_count += 1;
        } else true;

        if (filled) return fire;
    }
    return null;
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

/// THE appetite → hunger formula: what ONE player adds to the game's hunger
/// bar capacity.  Linear in the player's appetite stat, capped per player,
/// plus the babies their board brings along — each baby is another (small)
/// eater, so babies sit OUTSIDE the cap:
///
///     contribution = min(hunger_base + appetite * appetite_scale,
///                        hunger_player_cap)
///                    + babies * baby_hunger
///
/// The game's hunger max is the SUM of this over every player in the game,
/// whatever kind of game it is — so group hunger is always the players'
/// hunger totals added together.  A player with no board (or a board with a
/// fresh flash) has appetite 0, babies 0, and contributes exactly
/// `hunger_base`.  Babies hatched MID-game belong to no player and are added
/// straight onto the bar by the session instead (see `hatch_hunger`).
///
/// MIRRORED by the board firmware for its on-board game
/// (board/src/game/balance.c `balance_player_hunger`); change both together.
pub fn player_hunger(bal: *const balance.Balance, appetite: u32, babies: u32) u16 {
    // 64-bit so no stat a board can bank (u32) can overflow the products.
    const raw = @as(u64, bal.hunger_base) +
        @as(u64, appetite) * @as(u64, bal.appetite_scale);
    const capped = @min(raw, @as(u64, bal.hunger_player_cap));
    const with_babies = capped + @as(u64, babies) * @as(u64, bal.baby_hunger);
    return @intCast(@min(with_babies, std.math.maxInt(u16)));
}

/// Hunger capacity `count` freshly-hatched babies add to the bar.  Hatched
/// babies belong to the ENCOUNTER, not to a player's share: they are never
/// given back when someone leaves, and they reset with the next game.
///
/// Mirrored by the board firmware (board/src/game/balance.c); change both
/// together.
pub fn hatch_hunger(bal: *const balance.Balance, count: u32) u16 {
    const raw = @as(u64, count) * @as(u64, bal.baby_hunger);
    return @intCast(@min(raw, std.math.maxInt(u16)));
}

/// A player carrying `contribution` of the bar's capacity left mid-game:
/// remove their share of the UNUSED capacity only.
///
///     shrink = floor(contribution * (max - current) / max)
///
/// Proportional to the hunger still remaining, so what has already been
/// eaten stays eaten: the bar never drops below `current`, and a departure
/// that leaves `current == max` ends the game through the ordinary
/// hunger_full check rather than a special case here.
pub fn shrink_hunger_max(hunger: *c.Health, contribution: u16) void {
    if (hunger.max == 0) return;
    const remaining: u64 = hunger.max - hunger.current;
    const shrink = (@as(u64, contribution) * remaining) / @as(u64, hunger.max);
    hunger.max -= @intCast(shrink);
}

/// One of `counted` players left mid-game: remove their proportion of the
/// REMAINING charge pool.
///
///     shrink = floor(charges / counted)
///
/// Charges are pooled — spent (and injected) as a group, with no per-player
/// ledger — so the leaver's proportion is simply 1/n of whatever is left.
/// What the team already spent stays spent.  `counted` includes the leaver.
/// NOTE: the session never calls this for the LAST player out (counted == 1
/// would drain the pool to 0); their share stays in trust for the next taker.
pub fn shrink_charges(charges: *u32, counted: u32) void {
    if (counted == 0) return;
    charges.* -= charges.* / counted;
}

/// A player joined a game that already counted `counted_before` players:
/// grow the remaining pool by their proportion.
///
///     grow = floor(charges / counted_before)
///
/// The exact inverse of `shrink_charges` (modulo floor), so a join followed
/// by a leave — or the reverse — cannot be farmed for charges.  The FIRST
/// player to join (`counted_before == 0`) grows nothing: the pool starts at
/// the encounter's seed and that seed is theirs.
pub fn grow_charges(charges: *u32, counted_before: u32) void {
    if (counted_before == 0) return;
    charges.* +|= charges.* / counted_before;
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

// --- group completion --------------------------------------------------------

/// A recent poke by `player` at `square`, landed at `at_ms`.
fn rc(player: u8, move: u8, square: u16, at_ms: u64) RecentCast {
    return .{ .player_id = player, .move = move, .square = square, .at_ms = at_ms };
}

test "complete_group: a lone cast against an empty window fires nothing" {
    try std.testing.expectEqual(
        @as(?GroupFire, null),
        complete_group(test_bal, &.{}, rc(0, POKE, SQ, 100)),
    );
}

test "complete_group: two players on one square within the window fire the group" {
    const recent = [_]RecentCast{rc(0, POKE, SQ, 100)};
    const fire = complete_group(test_bal, &recent, rc(1, POKE, SQ, 300)) orelse
        return error.TestExpectedGroup;
    try std.testing.expectEqual(TWIN_BLOOM, fire.recipe_index);
    try std.testing.expectEqual(@as(usize, 1), fire.consumed_count);
    try std.testing.expectEqual(@as(usize, 0), fire.consumed[0]);
    // The completer is credited (and billed): group_stamp carries the
    // group's own cost, INSTEAD of the completing move's.
    const stamp = group_stamp(test_bal, fire.recipe_index, 1);
    try std.testing.expect(stamp.is_team);
    try std.testing.expectEqual(@as(u8, 1), stamp.anchor_player);
    try std.testing.expectEqual(@as(u16, 4), stamp.cost);
    try std.testing.expectEqual(@as(usize, 13), stamp.shape.size());
}

test "complete_group: a contribution outside the window has expired" {
    // Fixture window is 500ms.  599 - 98 > 500: too stale to coordinate with.
    const recent = [_]RecentCast{rc(0, POKE, SQ, 98)};
    try std.testing.expectEqual(
        @as(?GroupFire, null),
        complete_group(test_bal, &recent, rc(1, POKE, SQ, 599)),
    );
    // Exactly AT the window edge still counts: the window is inclusive.
    const edge = [_]RecentCast{rc(0, POKE, SQ, 99)};
    try std.testing.expect(complete_group(test_bal, &edge, rc(1, POKE, SQ, 599)) != null);
}

test "complete_group: scattered casts coordinate nothing" {
    // A group is casts CONVERGING on one cell; two pokes on two squares are
    // two pokes.
    const recent = [_]RecentCast{rc(0, POKE, OTHER_SQ, 100)};
    try std.testing.expectEqual(
        @as(?GroupFire, null),
        complete_group(test_bal, &recent, rc(1, POKE, SQ, 200)),
    );
}

test "complete_group: one player cannot spell a group alone" {
    // A group is a COOPERATION requirement, not a repeat-press — the
    // completer's own earlier casts never feed their group.
    const recent = [_]RecentCast{rc(0, POKE, SQ, 100)};
    try std.testing.expectEqual(
        @as(?GroupFire, null),
        complete_group(test_bal, &recent, rc(0, POKE, SQ, 200)),
    );
}

test "complete_group: a distinct player still groups alongside a duplicate" {
    // Player 0 poked twice; player 1's poke completes with ONE of them —
    // oldest first — and the duplicate stays in the window.
    const recent = [_]RecentCast{
        rc(0, POKE, SQ, 100),
        rc(0, POKE, SQ, 150),
    };
    const fire = complete_group(test_bal, &recent, rc(1, POKE, SQ, 300)) orelse
        return error.TestExpectedGroup;
    try std.testing.expectEqual(TWIN_BLOOM, fire.recipe_index);
    try std.testing.expectEqual(@as(usize, 1), fire.consumed_count);
    try std.testing.expectEqual(@as(usize, 0), fire.consumed[0]);
}

test "complete_group: an asymmetric group fires from either landing order" {
    const sweep_first = [_]RecentCast{rc(0, SWEEP, SQ, 100)};
    const a = complete_group(test_bal, &sweep_first, rc(1, BLOCK, SQ, 200)) orelse
        return error.TestExpectedGroup;
    try std.testing.expectEqual(CROSSFIRE, a.recipe_index);

    const block_first = [_]RecentCast{rc(0, BLOCK, SQ, 100)};
    const b = complete_group(test_bal, &block_first, rc(1, SWEEP, SQ, 200)) orelse
        return error.TestExpectedGroup;
    try std.testing.expectEqual(CROSSFIRE, b.recipe_index);
}

test "complete_group: an incomplete bag fires nothing" {
    // crossfire needs a block too; two sweeps spell no group at all.
    const recent = [_]RecentCast{rc(0, SWEEP, SQ, 100)};
    try std.testing.expectEqual(
        @as(?GroupFire, null),
        complete_group(test_bal, &recent, rc(1, SWEEP, SQ, 200)),
    );
}

test "complete_group: a bystander's cast completes nothing" {
    // The completing cast must itself supply a component: a wedge landing on
    // two pokes is just a wedge, however ripe the square.
    const recent = [_]RecentCast{
        rc(0, POKE, SQ, 100),
        rc(1, POKE, SQ, 150),
    };
    try std.testing.expectEqual(
        @as(?GroupFire, null),
        complete_group(test_bal, &recent, rc(2, fixtures.WEDGE, SQ, 200)),
    );
}

test "complete_group: an earlier group shadows a later one containing its bag" {
    // triad (3 pokes) contains twin_bloom's bag (2 pokes) and is listed after
    // it, so a third poke on two ripe pokes fires twin_bloom — table order is
    // the tiebreak, which is why it is designer-visible.
    const recent = [_]RecentCast{
        rc(0, POKE, SQ, 100),
        rc(1, POKE, SQ, 150),
    };
    const fire = complete_group(test_bal, &recent, rc(2, POKE, SQ, 200)) orelse
        return error.TestExpectedGroup;
    try std.testing.expectEqual(TWIN_BLOOM, fire.recipe_index);
    try std.testing.expectEqual(@as(usize, 1), fire.consumed_count);
}

test "complete_group: an empty group table completes nothing" {
    var bal = test_bal.*;
    bal.team_recipes = &.{};
    const recent = [_]RecentCast{rc(0, POKE, SQ, 100)};
    try std.testing.expectEqual(
        @as(?GroupFire, null),
        complete_group(&bal, &recent, rc(1, POKE, SQ, 200)),
    );
}

test "complete_group: a three-component group needs three distinct players" {
    var bal = test_bal.*;
    // Only `triad` loaded, so nothing shadows it.
    bal.team_recipes = fixtures.team_recipes[fixtures.TRIAD..];
    const recent = [_]RecentCast{
        rc(0, POKE, SQ, 100),
        rc(1, POKE, SQ, 150),
    };
    const fire = complete_group(&bal, &recent, rc(2, POKE, SQ, 200)) orelse
        return error.TestExpectedGroup;
    // Index into the table AS LOADED, which here starts at triad.
    try std.testing.expectEqual(@as(u8, 0), fire.recipe_index);
    try std.testing.expectEqual(@as(usize, 2), fire.consumed_count);
    try std.testing.expectEqual(@as(u16, 12), group_stamp(&bal, fire.recipe_index, 2).cost);

    // The same square with player 1 supplying both ripe pokes leaves the bag
    // one player short.
    const dup = [_]RecentCast{
        rc(1, POKE, SQ, 100),
        rc(1, POKE, SQ, 150),
    };
    try std.testing.expectEqual(
        @as(?GroupFire, null),
        complete_group(&bal, &dup, rc(2, POKE, SQ, 200)),
    );
}

test "player_hunger: linear in appetite from the base" {
    var bal = test_bal.*;
    bal.hunger_base = 30;
    bal.appetite_scale = 5;
    bal.hunger_player_cap = 500;
    try std.testing.expectEqual(@as(u16, 30), player_hunger(&bal, 0, 0));
    try std.testing.expectEqual(@as(u16, 35), player_hunger(&bal, 1, 0));
    try std.testing.expectEqual(@as(u16, 80), player_hunger(&bal, 10, 0));
}

test "player_hunger: capped per player, even for an absurd appetite" {
    var bal = test_bal.*;
    bal.hunger_base = 30;
    bal.appetite_scale = 5;
    bal.hunger_player_cap = 500;
    // 30 + 94*5 = 500 exactly; one more point changes nothing.
    try std.testing.expectEqual(@as(u16, 500), player_hunger(&bal, 94, 0));
    try std.testing.expectEqual(@as(u16, 500), player_hunger(&bal, 95, 0));
    // The full u32 range must not overflow the arithmetic either.
    try std.testing.expectEqual(@as(u16, 500), player_hunger(&bal, std.math.maxInt(u32), 0));
}

test "player_hunger: babies add baby_hunger each, OUTSIDE the appetite cap" {
    var bal = test_bal.*;
    bal.hunger_base = 30;
    bal.appetite_scale = 5;
    bal.hunger_player_cap = 500;
    bal.baby_hunger = 10;
    try std.testing.expectEqual(@as(u16, 40), player_hunger(&bal, 0, 1));
    try std.testing.expectEqual(@as(u16, 80), player_hunger(&bal, 0, 5));
    // A capped appetite still gets its babies on top.
    try std.testing.expectEqual(@as(u16, 530), player_hunger(&bal, 95, 3));
    // An absurd baby hoard saturates the u16 rather than overflowing.
    try std.testing.expectEqual(
        @as(u16, std.math.maxInt(u16)),
        player_hunger(&bal, 0, std.math.maxInt(u32)),
    );
}

test "hatch_hunger: baby_hunger per hatch, saturating" {
    var bal = test_bal.*;
    bal.baby_hunger = 10;
    try std.testing.expectEqual(@as(u16, 0), hatch_hunger(&bal, 0));
    try std.testing.expectEqual(@as(u16, 30), hatch_hunger(&bal, 3));
    try std.testing.expectEqual(
        @as(u16, std.math.maxInt(u16)),
        hatch_hunger(&bal, std.math.maxInt(u32)),
    );
}

test "shrink_hunger_max: removes the leaver's share of the UNUSED capacity" {
    // Two players of 30 each; half the bar eaten.  The leaver's 30 covers the
    // bar in the same ratio it was contributed, so half of it (15) is still
    // unused and comes off the max.
    var hunger = c.Health{ .current = 30, .max = 60 };
    shrink_hunger_max(&hunger, 30);
    try std.testing.expectEqual(@as(u16, 45), hunger.max);
    try std.testing.expectEqual(@as(u16, 30), hunger.current);
}

test "shrink_hunger_max: never drops the max below what was already eaten" {
    // Bar nearly full: almost none of the leaver's share is unused, so almost
    // none is removed — and current is untouched.
    var hunger = c.Health{ .current = 59, .max = 60 };
    shrink_hunger_max(&hunger, 30);
    try std.testing.expectEqual(@as(u16, 60), hunger.max); // floor(30*1/60) = 0
    try std.testing.expect(hunger.max >= hunger.current);

    // The sole contributor leaving an untouched bar removes all of it.
    var fresh = c.Health{ .current = 0, .max = 30 };
    shrink_hunger_max(&fresh, 30);
    try std.testing.expectEqual(@as(u16, 0), fresh.max);
}

test "shrink_hunger_max: a full or empty bar is left alone" {
    // current == max: no unused capacity to remove; hunger_full still holds.
    var full = c.Health{ .current = 60, .max = 60 };
    shrink_hunger_max(&full, 30);
    try std.testing.expectEqual(@as(u16, 60), full.max);
    try std.testing.expect(hunger_full(full));
    // max == 0 (pre-game): nothing to divide by, nothing to shrink.
    var blank = c.Health{ .current = 0, .max = 0 };
    shrink_hunger_max(&blank, 30);
    try std.testing.expectEqual(@as(u16, 0), blank.max);
}

test "shrink_charges: the leaver takes 1/n of the remaining pool" {
    // Four players, 100 charges left: the leaver's proportion is 25.
    var pool: u32 = 100;
    shrink_charges(&pool, 4);
    try std.testing.expectEqual(@as(u32, 75), pool);
    // A second leaver is now one of three: floor(75/3) = 25 again.
    shrink_charges(&pool, 3);
    try std.testing.expectEqual(@as(u32, 50), pool);
}

test "shrink_charges: rounding favours the players who stay" {
    // floor(10/3) = 3 comes off, not 4: the indivisible remainder stays with
    // the group.
    var pool: u32 = 10;
    shrink_charges(&pool, 3);
    try std.testing.expectEqual(@as(u32, 7), pool);
}

test "shrink_charges: counted == 1 drains the pool (why the session skips it)" {
    var pool: u32 = 42;
    shrink_charges(&pool, 1);
    try std.testing.expectEqual(@as(u32, 0), pool);
}

test "shrink_charges: an empty pool and a zero count are left alone" {
    var pool: u32 = 0;
    shrink_charges(&pool, 3);
    try std.testing.expectEqual(@as(u32, 0), pool);
    // counted == 0 cannot happen for a counted leaver, but must not divide
    // by zero if it ever does.
    var untouched: u32 = 9;
    shrink_charges(&untouched, 0);
    try std.testing.expectEqual(@as(u32, 9), untouched);
}

test "grow_charges: a joiner adds their proportion of the remaining pool" {
    // Two players hold 60: a third joining brings the pool to 90 — everyone
    // now owns 30, the same as before.
    var pool: u32 = 60;
    grow_charges(&pool, 2);
    try std.testing.expectEqual(@as(u32, 90), pool);
}

test "grow_charges: the first joiner inherits the seed unchanged" {
    var pool: u32 = 40;
    grow_charges(&pool, 0);
    try std.testing.expectEqual(@as(u32, 40), pool);
}

test "grow_charges and shrink_charges round-trip (no join/leave farming)" {
    // join (2 -> 3 players) then leave (3 -> 2): back where we started.
    var pool: u32 = 60;
    grow_charges(&pool, 2); // 90
    shrink_charges(&pool, 3); // 60
    try std.testing.expectEqual(@as(u32, 60), pool);
    // With an indivisible pool the floors only ever round DOWN, so cycling
    // can never mint charges.
    var odd: u32 = 61;
    grow_charges(&odd, 2); // 61 + 30 = 91
    shrink_charges(&odd, 3); // 91 - 30 = 61
    try std.testing.expect(odd <= 61);
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
