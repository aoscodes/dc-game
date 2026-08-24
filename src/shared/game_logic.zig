//! Pure resolution logic for the Slime Feast encounter: everything that maps
//! player CASTS onto game effects.
//!
//! Cast pipeline (driven by session):
//!   1. a cast is LOCKED IN — appended to the turn's pending list.  Nothing is
//!      charged and nothing touches the grid yet.
//!   2. once every connected player has locked in, `resolve_batch` turns the
//!      WHOLE pending list into the stamps it produces and the single price
//!      they cost together: same-square casts by distinct players collapse into
//!      the group moves they spell, and only the group's price is paid for
//!      them.
//!   3. the session debits that price once and hands each stamp to
//!      `slime.SlimeField.apply_shape` at its square, which owns all slime
//!      state.
//!
//! Resolving the turn as a BATCH rather than cast by cast is what makes a group
//! a joint purchase: the contributors never pay for their own moves, so the
//! team is quoted one price for the turn and can back out (see the session's
//! cancel path) before any of it is spent.
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

/// One cast locked in this turn: who cast what, and where it is aimed.
/// Group moves are found among these (see `resolve_batch`).
pub const TurnCast = struct {
    player_id: u8,
    /// Index into balance.player_recipes — the move that was cast.
    move: u8,
    /// Flat grid index the cast was anchored at.
    square: u16,
};

/// Cap on the per-turn cast log: max players × casts each, with headroom.
pub const MAX_CASTS: usize = 64;

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
/// credited to `player_id` (the contributor who locked in last — see
/// `resolve_batch`).
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
// Batch resolution
// ---------------------------------------------------------------------------

/// One stamp the turn produces, and the square it lands on.
pub const BatchStamp = struct {
    stamp: ShapeCast,
    /// Flat grid index this stamp is anchored at.
    square: u16,
};

/// Everything a turn's locked-in casts resolve to.
pub const Batch = struct {
    stamps: [MAX_CASTS]BatchStamp = undefined,
    count: usize = 0,
    /// What the whole turn costs the shared pool — group prices INSTEAD of
    /// their components', not on top of them.
    total_cost: u32 = 0,

    pub fn slice(self: *const Batch) []const BatchStamp {
        return self.stamps[0..self.count];
    }

    fn push(self: *Batch, stamp: ShapeCast, square: u16) void {
        // Unreachable for any sane config: a batch produces at most one stamp
        // per cast, and `casts` is already capped at MAX_CASTS.
        if (self.count >= MAX_CASTS) return;
        self.stamps[self.count] = .{ .stamp = stamp, .square = square };
        self.count += 1;
        self.total_cost += stamp.cost;
    }
};

/// Resolve a whole turn's locked-in casts into the stamps they produce and the
/// single price they cost together.
///
/// GROUPS FIRST.  A group needs its whole component bag on ONE square, each
/// component from a DIFFERENT player — that is what makes it a coordination
/// move rather than a long combo.  Squares are visited in the order they first
/// appear, groups are tried in table order, and each is fired REPEATEDLY while
/// its bag can still be filled from the casts left on that square; so an
/// earlier table entry shadows a later one whose bag it contains, and six
/// players on one square can spell the same pair three times.
///
/// A fired group CONSUMES its contributors: they do not also stamp their own
/// moves, and they pay nothing.  Only the group's price is charged, which is
/// what makes coordinating a discount on the whole bag rather than on its last
/// member.  The group is credited to the contributor who locked in LAST — the
/// one whose choice completed it — which is who the client shows as the caster.
///
/// Everything not swallowed by a group stamps its own move, in lock-in order.
/// Every stamp on a square lands at that square, so ordering matters only where
/// two stamps overlap: groups resolve before plain moves.
pub fn resolve_batch(bal: *const balance.Balance, casts: []const TurnCast) Batch {
    std.debug.assert(casts.len <= MAX_CASTS);
    var out = Batch{};
    var consumed = [_]bool{false} ** MAX_CASTS;

    for (casts, 0..) |head, hi| {
        // One hunt per square: a later cast on a square already searched would
        // only re-run the same search over the same remaining casts.
        const first_on_square = for (casts[0..hi]) |earlier| {
            if (earlier.square == head.square) break false;
        } else true;
        if (!first_on_square) continue;

        for (bal.team_recipes, 0..) |tr, ti| {
            // A componentless group is spelled by nothing, so it would fire
            // forever.  config.zig rejects one; guard rather than trust.
            if (tr.components.len == 0) continue;
            fire: while (true) {
                var picks: [balance.MAX_TEAM_COMPONENTS]usize = undefined;
                var picked: usize = 0;
                for (tr.components) |comp| {
                    const found = for (casts, 0..) |cand, ci| {
                        if (consumed[ci]) continue;
                        if (cand.square != head.square) continue;
                        if (cand.move != comp) continue;
                        // Distinct players: one player cannot supply two
                        // components of the same group, however many casts
                        // they have locked in.
                        const taken = for (picks[0..picked]) |pi| {
                            if (casts[pi].player_id == cand.player_id) break true;
                        } else false;
                        if (taken) continue;
                        break ci;
                    } else break :fire;
                    picks[picked] = found;
                    picked += 1;
                }

                var last: usize = picks[0];
                for (picks[0..picked]) |pi| {
                    consumed[pi] = true;
                    last = @max(last, pi);
                }
                out.push(group_stamp(bal, @intCast(ti), casts[last].player_id), head.square);
            }
        }
    }

    for (casts, 0..) |cast, ci| {
        if (consumed[ci]) continue;
        out.push(move_stamp(bal, cast.move, cast.player_id), cast.square);
    }

    return out;
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
/// bar capacity.  Linear in the player's appetite stat, capped per player:
///
///     contribution = min(hunger_base + appetite * appetite_scale,
///                        hunger_player_cap)
///
/// The game's hunger max is the SUM of this over every player in the game,
/// whatever kind of game it is — so group hunger is always the players'
/// hunger totals added together.  A player with no board (or a board with a
/// fresh flash) has appetite 0 and contributes exactly `hunger_base`.
///
/// MIRRORED by the board firmware for its on-board game
/// (board/src/game/balance.c `balance_player_hunger`); change both together.
pub fn player_hunger(bal: *const balance.Balance, appetite: u32) u16 {
    // 64-bit so no appetite a board can bank (u32) can overflow the product.
    const raw = @as(u64, bal.hunger_base) +
        @as(u64, appetite) * @as(u64, bal.appetite_scale);
    return @intCast(@min(raw, @as(u64, bal.hunger_player_cap)));
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

// --- batch resolution ------------------------------------------------------

/// The single stamp `casts` resolves to, or an error if it produced any other
/// number — every batch test below is about exactly what came out.
fn only_stamp(bal: *const balance.Balance, casts: []const TurnCast) !BatchStamp {
    const batch = resolve_batch(bal, casts);
    try std.testing.expectEqual(@as(usize, 1), batch.count);
    return batch.stamps[0];
}

test "resolve_batch: an empty turn resolves to nothing, for nothing" {
    const batch = resolve_batch(test_bal, &.{});
    try std.testing.expectEqual(@as(usize, 0), batch.count);
    try std.testing.expectEqual(@as(u32, 0), batch.total_cost);
}

test "resolve_batch: a lone cast is just its own move, at its own square" {
    const one = [_]TurnCast{.{ .player_id = 0, .move = POKE, .square = SQ }};
    const got = try only_stamp(test_bal, &one);
    try std.testing.expect(!got.stamp.is_team);
    try std.testing.expectEqual(POKE, got.stamp.recipe_index);
    try std.testing.expectEqual(SQ, got.square);
}

test "resolve_batch: the turn's price is the sum of what actually lands" {
    const two = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = DELUGE, .square = OTHER_SQ },
    };
    const batch = resolve_batch(test_bal, &two);
    try std.testing.expectEqual(@as(usize, 2), batch.count);
    try std.testing.expectEqual(@as(u32, 1 + 9), batch.total_cost);
}

test "resolve_batch: two players on one square fire the group instead" {
    const pair = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
    };
    const got = try only_stamp(test_bal, &pair);
    try std.testing.expect(got.stamp.is_team);
    try std.testing.expectEqual(TWIN_BLOOM, got.stamp.recipe_index);
    try std.testing.expectEqual(SQ, got.square);
    try std.testing.expectEqual(@as(usize, 13), got.stamp.shape.size());
}

test "resolve_batch: a group is charged INSTEAD of its components, not on top" {
    // The whole point of locking casts in: contributors never pay their own
    // way, so coordinating is a discount on the entire bag.
    const pair = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
    };
    // twin_bloom costs 4; the two pokes it swallowed would have cost 1 each.
    try std.testing.expectEqual(@as(u32, 4), resolve_batch(test_bal, &pair).total_cost);
}

test "resolve_batch: the last contributor to lock in is credited with the group" {
    const pair = [_]TurnCast{
        .{ .player_id = 3, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
    };
    // Player 1 completed it, so player 1 is the caster the clients see.
    try std.testing.expectEqual(@as(u8, 1), (try only_stamp(test_bal, &pair)).stamp.anchor_player);
}

test "resolve_batch: an asymmetric group fires from either lock-in order" {
    const sweep_first = [_]TurnCast{
        .{ .player_id = 0, .move = SWEEP, .square = SQ },
        .{ .player_id = 1, .move = BLOCK, .square = SQ },
    };
    try std.testing.expectEqual(CROSSFIRE, (try only_stamp(test_bal, &sweep_first)).stamp.recipe_index);

    const block_first = [_]TurnCast{
        .{ .player_id = 0, .move = BLOCK, .square = SQ },
        .{ .player_id = 1, .move = SWEEP, .square = SQ },
    };
    try std.testing.expectEqual(CROSSFIRE, (try only_stamp(test_bal, &block_first)).stamp.recipe_index);
}

test "resolve_batch: scattered casts coordinate nothing" {
    // A group is casts CONVERGING on one cell; two pokes on two squares are
    // two pokes.
    const apart = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = OTHER_SQ },
    };
    const batch = resolve_batch(test_bal, &apart);
    try std.testing.expectEqual(@as(usize, 2), batch.count);
    for (batch.slice()) |b| try std.testing.expect(!b.stamp.is_team);
}

test "resolve_batch: one player cannot spell a group alone" {
    // A group is a COOPERATION requirement, not a repeat-press — true however
    // many casts a single player has locked in.
    const solo = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 0, .move = POKE, .square = SQ },
    };
    const batch = resolve_batch(test_bal, &solo);
    try std.testing.expectEqual(@as(usize, 2), batch.count);
    for (batch.slice()) |b| try std.testing.expect(!b.stamp.is_team);
}

test "resolve_batch: a distinct player still groups alongside a duplicate" {
    const casts = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 0, .move = POKE, .square = SQ }, // same player again
        .{ .player_id = 1, .move = POKE, .square = SQ },
    };
    const batch = resolve_batch(test_bal, &casts);
    // The group takes one cast from each player; the duplicate is left over and
    // lands as a plain poke.
    try std.testing.expectEqual(@as(usize, 2), batch.count);
    try std.testing.expectEqual(TWIN_BLOOM, batch.stamps[0].stamp.recipe_index);
    try std.testing.expect(batch.stamps[0].stamp.is_team);
    try std.testing.expect(!batch.stamps[1].stamp.is_team);
    try std.testing.expectEqual(@as(u32, 4 + 1), batch.total_cost);
}

test "resolve_batch: an incomplete bag fires nothing" {
    // crossfire needs a block too; two sweeps spell no group at all.
    const casts = [_]TurnCast{
        .{ .player_id = 0, .move = SWEEP, .square = SQ },
        .{ .player_id = 1, .move = SWEEP, .square = SQ },
    };
    const batch = resolve_batch(test_bal, &casts);
    try std.testing.expectEqual(@as(usize, 2), batch.count);
    for (batch.slice()) |b| try std.testing.expect(!b.stamp.is_team);
}

test "resolve_batch: an earlier group shadows a later one containing its bag" {
    // triad (3 pokes) contains twin_bloom's bag (2 pokes) and is listed after
    // it, so three pokes fire twin_bloom and leave a poke over rather than
    // reaching triad.  Table order is the tiebreak, which is why it is
    // designer-visible.
    const three = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
        .{ .player_id = 2, .move = POKE, .square = SQ },
    };
    const batch = resolve_batch(test_bal, &three);
    try std.testing.expectEqual(@as(usize, 2), batch.count);
    try std.testing.expectEqual(TWIN_BLOOM, batch.stamps[0].stamp.recipe_index);
    try std.testing.expect(!batch.stamps[1].stamp.is_team);
}

test "resolve_batch: a group repeats while the square can still spell it" {
    // Four pokes on one square are TWO twin_blooms, not one plus leftovers.
    const four = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
        .{ .player_id = 2, .move = POKE, .square = SQ },
        .{ .player_id = 3, .move = POKE, .square = SQ },
    };
    const batch = resolve_batch(test_bal, &four);
    try std.testing.expectEqual(@as(usize, 2), batch.count);
    for (batch.slice()) |b| try std.testing.expectEqual(TWIN_BLOOM, b.stamp.recipe_index);
    try std.testing.expectEqual(@as(u32, 8), batch.total_cost);
}

test "resolve_batch: groups land before the plain moves they share a turn with" {
    // Two stamps can overlap, so the order they are applied in is observable.
    // Groups first: the coordinated shape is the turn's headline, and the
    // leftovers step down whatever it leaves standing.
    const casts = [_]TurnCast{
        .{ .player_id = 0, .move = SWEEP, .square = OTHER_SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
        .{ .player_id = 2, .move = POKE, .square = SQ },
    };
    const batch = resolve_batch(test_bal, &casts);
    try std.testing.expectEqual(@as(usize, 2), batch.count);
    try std.testing.expect(batch.stamps[0].stamp.is_team);
    try std.testing.expectEqual(SWEEP, batch.stamps[1].stamp.recipe_index);
}

test "resolve_batch: an empty group table leaves every cast as its own move" {
    var bal = test_bal.*;
    bal.team_recipes = &.{};
    const pair = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
    };
    const batch = resolve_batch(&bal, &pair);
    try std.testing.expectEqual(@as(usize, 2), batch.count);
    for (batch.slice()) |b| try std.testing.expect(!b.stamp.is_team);
}

test "resolve_batch: a three-component group needs three distinct players" {
    var bal = test_bal.*;
    // Only `triad` loaded, so nothing shadows it.
    bal.team_recipes = fixtures.team_recipes[fixtures.TRIAD..];
    const three = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
        .{ .player_id = 2, .move = POKE, .square = SQ },
    };
    const fired = try only_stamp(&bal, &three);
    try std.testing.expect(fired.stamp.is_team);
    // Index into the table AS LOADED, which here starts at triad.
    try std.testing.expectEqual(@as(u8, 0), fired.stamp.recipe_index);
    try std.testing.expectEqual(@as(u16, 12), fired.stamp.cost);

    // The same three casts with player 1 supplying two of them leaves the bag
    // one player short, so all three land as plain pokes.
    const dup = [_]TurnCast{
        .{ .player_id = 0, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
        .{ .player_id = 1, .move = POKE, .square = SQ },
    };
    const batch = resolve_batch(&bal, &dup);
    try std.testing.expectEqual(@as(usize, 3), batch.count);
    for (batch.slice()) |b| try std.testing.expect(!b.stamp.is_team);
}

test "player_hunger: linear in appetite from the base" {
    var bal = test_bal.*;
    bal.hunger_base = 30;
    bal.appetite_scale = 5;
    bal.hunger_player_cap = 500;
    try std.testing.expectEqual(@as(u16, 30), player_hunger(&bal, 0));
    try std.testing.expectEqual(@as(u16, 35), player_hunger(&bal, 1));
    try std.testing.expectEqual(@as(u16, 80), player_hunger(&bal, 10));
}

test "player_hunger: capped per player, even for an absurd appetite" {
    var bal = test_bal.*;
    bal.hunger_base = 30;
    bal.appetite_scale = 5;
    bal.hunger_player_cap = 500;
    // 30 + 94*5 = 500 exactly; one more point changes nothing.
    try std.testing.expectEqual(@as(u16, 500), player_hunger(&bal, 94));
    try std.testing.expectEqual(@as(u16, 500), player_hunger(&bal, 95));
    // The full u32 range must not overflow the arithmetic either.
    try std.testing.expectEqual(@as(u16, 500), player_hunger(&bal, std.math.maxInt(u32)));
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

test "add_hunger: clamps at max" {
    var hunger = c.Health{ .current = 95, .max = 100 };
    add_hunger(&hunger, 3);
    try std.testing.expectEqual(@as(u16, 98), hunger.current);
    try std.testing.expect(!hunger_full(hunger));
    add_hunger(&hunger, 999);
    try std.testing.expectEqual(@as(u16, 100), hunger.current);
    try std.testing.expect(hunger_full(hunger));
}
