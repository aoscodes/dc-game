//! The slime field: a server-authoritative grid of individual slime units
//! plus the off-grid reservoir that refills it.
//!
//! ## Model
//!
//! `SlimeField` owns a `SlimeGrid` (fixed rows × cols of `SlimeCell`) and a
//! `SlimeReservoir` of slime waiting to enter.  The encounter's total slime
//! starts in the reservoir; `fill` moves as much as fits onto the grid.
//!
//! Every operation that needs a choice takes a `std.Random` explicitly — this
//! module is pure with respect to randomness, so callers (the session) own
//! the seed and tests can pin it.  All randomness is therefore reproducible
//! and, because the grid is transmitted rather than simulated client-side,
//! every client sees the identical field.
//!
//! ## Operations
//!
//!   fill        — move reservoir slime into empty cells, TOP ROW FIRST
//!                 (row 0 down), each unit's type drawn from the reservoir in
//!                 proportion to what remains.
//!   apply_shape — stamp a cast's footprint at an aimed anchor, DOWNGRADING
//!                 every covered hazard one tier.  Deterministic: the player
//!                 chose the cells, so nothing is random and nothing is
//!                 destroyed — only made safer.
//!   eat_all     — devour the whole field, reporting the hunger/score it cost.
//!
//! Neither the reservoir nor an off-grid unit can be neutralized: casting is a
//! grid-only operation by construction (`SlimeReservoir` has no neutralized
//! bucket), so slime waiting off-grid always arrives at full difficulty.

const std = @import("std");
const c = @import("components.zig");
const balance = @import("balance.zig");

/// Grid + reservoir.  The single source of truth for slime state.
pub const SlimeField = struct {
    grid: c.SlimeGrid,
    reservoir: c.SlimeReservoir,

    /// Build a field of `dims` holding `total` slime: as much as fits is
    /// placed on the grid (top row first), the remainder stays in the
    /// reservoir.
    pub fn init(
        dims: balance.SlimeGridDims,
        total: c.SlimeReservoir,
        rand: std.Random,
    ) SlimeField {
        var self = SlimeField{
            .grid = c.SlimeGrid.init(dims.rows, dims.cols),
            .reservoir = total,
        };
        _ = self.fill(rand);
        return self;
    }

    /// Total slime still in play: on the grid plus in the reservoir.
    pub fn remaining(self: *const SlimeField) u32 {
        return @as(u32, self.grid.occupied()) + self.reservoir.total();
    }

    /// True when there is nothing left to eat anywhere.
    pub fn is_exhausted(self: *const SlimeField) bool {
        return self.remaining() == 0;
    }

    /// Move reservoir slime into every empty cell, walking row 0 (the top)
    /// downward so refills visibly enter from above.  Stops when the grid is
    /// full or the reservoir runs dry.  Returns the number of cells filled.
    pub fn fill(self: *SlimeField, rand: std.Random) u16 {
        var filled: u16 = 0;
        var flat: u16 = 0;
        const n = self.grid.len();
        while (flat < n) : (flat += 1) {
            if (self.grid.get(flat).is_slime()) continue;
            const cell = self.take_from_reservoir(rand) orelse break;
            self.grid.put(flat, cell);
            filled += 1;
        }
        return filled;
    }

    /// Draw one unit from the reservoir, chosen uniformly among the units
    /// remaining (so the grid mixes in proportion to the reservoir's
    /// composition).  Returns null when the reservoir is empty.
    fn take_from_reservoir(self: *SlimeField, rand: std.Random) ?c.SlimeCell {
        const total = self.reservoir.total();
        if (total == 0) return null;

        var pick = rand.uintLessThan(u32, total);
        if (pick < self.reservoir.neutral) {
            self.reservoir.neutral -= 1;
            return .neutral;
        }
        pick -= self.reservoir.neutral;
        for (&self.reservoir.tiered, 0..) |*count, i| {
            if (pick < count.*) {
                count.* -= 1;
                return .{ .tiered = @enumFromInt(i) };
            }
            pick -= count.*;
        }
        unreachable; // `total` is the sum of the buckets just walked.
    }

    /// Stamp one cast's shape on the grid, anchored at (`row`, `col`).
    ///
    /// Every covered cell holding a hazard is DOWNGRADED one tier
    /// (red -> yellow -> green -> neutralized).  Nothing is destroyed: a
    /// neutralized unit stays on the grid, edible, scoring, and costing only
    /// normal hunger — clearing the field is the Lil Guys' job, not the cast's.
    ///
    /// Cells the shape covers that cannot be downgraded are WASTED, and the
    /// distinction is the player's aiming feedback:
    ///   - `off_grid`  — the offset fell outside the playfield (clipped)
    ///   - `inert`     — a real cell with nothing to neutralize (empty,
    ///                   neutral, or already neutralized)
    ///
    /// Deterministic: no randomness, because the player chose the cells.
    pub fn apply_shape(
        self: *SlimeField,
        shape: balance.Shape,
        row: u8,
        col: u8,
    ) ShapeOutcome {
        std.debug.assert(row < self.grid.rows and col < self.grid.cols);
        var out = ShapeOutcome{};

        for (shape.offsets) |off| {
            const r = @as(i32, row) + off.d_row;
            const cl = @as(i32, col) + off.d_col;
            if (r < 0 or r >= self.grid.rows or cl < 0 or cl >= self.grid.cols) {
                out.off_grid += 1;
                continue;
            }
            const flat = self.grid.index(@intCast(r), @intCast(cl));
            const cell = self.grid.get(flat);
            if (cell != .tiered) {
                out.inert += 1;
                continue;
            }
            const tier = cell.tiered;
            if (tier.downgrade()) |next| {
                self.grid.put(flat, .{ .tiered = next });
                out.downgraded[@intFromEnum(tier)] += 1;
            } else {
                self.grid.put(flat, .neutralized);
                out.downgraded[@intFromEnum(tier)] += 1;
                out.neutralized += 1;
            }
        }
        return out;
    }

    /// Devour the ENTIRE field in one feast and empty it.
    ///
    /// This is the turn-end settlement: every remaining unit is eaten at once,
    /// so casting during the turn is purely about *what condition* the slime is
    /// in when this runs.  Ordering is irrelevant (each cell is independent),
    /// which is why the whole grid collapses into one outcome instead of a
    /// stream of per-cell bites.
    ///
    /// The grid is left empty; refilling from the reservoir is the caller's
    /// next step so it can broadcast the feast before the new field appears.
    pub fn eat_all(self: *SlimeField, bal: *const balance.Balance) FeastOutcome {
        var out = FeastOutcome{};
        for (self.grid.live(), 0..) |cell, i| {
            if (!cell.is_slime()) continue;
            out.cells += 1;
            out.hunger_normal += bal.hunger_cost_normal;
            switch (cell) {
                .empty => unreachable, // guarded above
                .neutral => {
                    out.neutral += 1;
                    out.score += 1;
                },
                .neutralized => {
                    out.defused += 1;
                    out.score += 1;
                },
                .tiered => |tier| {
                    // A live hazard hurts the same whatever its tier: the tier
                    // only says how many casts it needed, and it decides which
                    // medicine can heal the damage afterwards.
                    out.hunger_extra[@intFromEnum(tier)] += bal.hunger_cost_hazard_extra;
                    out.escaped[@intFromEnum(tier)] += 1;
                },
            }
            self.grid.put(@intCast(i), .empty);
        }
        return out;
    }
};

/// What one whole-field feast produced.
///
/// Hunger is split so healing stays honest: `hunger_normal` is the unavoidable
/// cost of the Lil Guys eating at all, while `hunger_extra` is the punishment
/// for leaving hazards live — bucketed by the tier that was eaten, because only
/// medicine of that same tier can heal it.
pub const FeastOutcome = struct {
    /// Slime units eaten.
    cells: u16 = 0,
    /// Of those, units that were never hazardous.
    neutral: u16 = 0,
    /// Of those, units a cast had taken all the way to defused.
    defused: u16 = 0,
    /// Units eaten while STILL hazardous, per tier — the ones the team failed
    /// to defuse in time.
    escaped: [c.Tier.size]u16 = [_]u16{0} ** c.Tier.size,
    /// Hunger from eating units at all — never healable.
    hunger_normal: u32 = 0,
    /// Healable extra hunger, indexed by the tier of the hazard eaten.
    hunger_extra: [c.Tier.size]u32 = [_]u32{0} ** c.Tier.size,
    /// Score: 1 per neutral or defused unit, 0 per live hazard.
    score: u32 = 0,

    /// Total hunger the feast added.
    pub fn hunger_total(self: FeastOutcome) u32 {
        var n: u32 = self.hunger_normal;
        for (self.hunger_extra) |e| n += e;
        return n;
    }
};

/// What stamping one shape did.  The three wasted-cell kinds are kept apart
/// because they mean different things to the player: `off_grid` says "you
/// aimed off the edge", `inert` says "you hit clean slime".
pub const ShapeOutcome = struct {
    /// Cells downgraded, indexed by the tier they were AT before the cast.
    downgraded: [c.Tier.size]u16 = [_]u16{0} ** c.Tier.size,
    /// Of those, how many were fully defused (green -> neutralized).
    neutralized: u16 = 0,
    /// Covered offsets that fell outside the grid.
    off_grid: u16 = 0,
    /// Covered cells with nothing to neutralize.
    inert: u16 = 0,

    /// Total cells the cast changed.
    pub fn total_downgraded(self: ShapeOutcome) u16 {
        var n: u16 = 0;
        for (self.downgraded) |d| n += d;
        return n;
    }

    /// Covered cells the cast achieved nothing on.
    pub fn wasted(self: ShapeOutcome) u16 {
        return self.off_grid + self.inert;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const test_bal = &fixtures.test_config.balance;

/// Deterministic randomness for tests.
fn prng(seed: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(seed);
}

fn ti(t: c.Tier) usize {
    return @intFromEnum(t);
}

/// A shape from authored rows, for tests only (config.zig does this at load).
/// `rows` are `#`/`.` strings; anchor is the bounding box centre, rounded down.
/// The offsets live in a generated namespace so the returned slice is static.
fn Shaped(comptime rows: []const []const u8) type {
    return struct {
        const offsets = blk: {
            var offs: [balance.MAX_SHAPE_CELLS]balance.ShapeOffset = undefined;
            var n: usize = 0;
            const anchor_r: i8 = @intCast(rows.len / 2);
            const anchor_c: i8 = @intCast(rows[0].len / 2);
            for (rows, 0..) |line, r| {
                for (line, 0..) |ch, cl| {
                    if (ch != '#') continue;
                    offs[n] = .{
                        .d_row = @as(i8, @intCast(r)) - anchor_r,
                        .d_col = @as(i8, @intCast(cl)) - anchor_c,
                    };
                    n += 1;
                }
            }
            break :blk offs[0..n].*;
        };
        const shape = balance.Shape{
            .offsets = &offsets,
            .rows = @intCast(rows.len),
            .cols = @intCast(rows[0].len),
        };
    };
}

fn test_shape(comptime rows: []const []const u8) balance.Shape {
    return Shaped(rows).shape;
}

const SQUARE_3X3 = test_shape(&.{ "###", "###", "###" });
const DOT = test_shape(&.{"#"});
const PLUS = test_shape(&.{ ".#.", "###", ".#." });

/// Paint every live cell of a field, bypassing the reservoir.
fn paint(field: *SlimeField, cell: c.SlimeCell) void {
    var flat: u16 = 0;
    while (flat < field.grid.len()) : (flat += 1) field.grid.put(flat, cell);
}

fn empty_field(rows: u8, cols: u8) SlimeField {
    return .{ .grid = c.SlimeGrid.init(rows, cols), .reservoir = .{} };
}

test "Tier.downgrade walks red -> yellow -> green -> defused" {
    try testing.expectEqual(c.Tier.yellow, c.Tier.red.downgrade().?);
    try testing.expectEqual(c.Tier.green, c.Tier.yellow.downgrade().?);
    // Green has no lower tier: the next application defuses the unit.
    try testing.expectEqual(@as(?c.Tier, null), c.Tier.green.downgrade());
}

test "init fills the grid from the reservoir and keeps the overflow" {
    var rng = prng(1);
    var res = c.SlimeReservoir{ .neutral = 20 };
    res.tiered[ti(.red)] = 30;
    const field = SlimeField.init(.{ .rows = 2, .cols = 3 }, res, rng.random());

    // 6 cells filled, 50 - 6 = 44 left in the reservoir.
    try testing.expectEqual(@as(u16, 6), field.grid.occupied());
    try testing.expectEqual(@as(u32, 44), field.reservoir.total());
    try testing.expectEqual(@as(u32, 50), field.remaining());
    try testing.expect(!field.is_exhausted());
}

test "init leaves cells empty when the reservoir cannot fill the grid" {
    var rng = prng(2);
    const field = SlimeField.init(.{ .rows = 4, .cols = 4 }, .{ .neutral = 5 }, rng.random());
    try testing.expectEqual(@as(u16, 5), field.grid.occupied());
    try testing.expect(field.reservoir.is_empty());
    // Filled top-first: the first 5 flat cells hold the slime.
    for (field.grid.live(), 0..) |cell, i| {
        try testing.expectEqual(i < 5, cell.is_slime());
    }
}

test "fill refills empty cells from the top row downward" {
    var rng = prng(3);
    var field = SlimeField.init(.{ .rows = 3, .cols = 2 }, .{ .neutral = 6 }, rng.random());
    try testing.expect(field.reservoir.is_empty());

    field.grid.set(0, 0, .empty);
    field.grid.set(0, 1, .empty);
    field.grid.set(2, 1, .empty);
    field.reservoir.neutral = 2;

    const filled = field.fill(rng.random());
    // Only 2 units available, and they go to the two TOPMOST empty cells.
    try testing.expectEqual(@as(u16, 2), filled);
    try testing.expect(field.grid.at(0, 0).is_slime());
    try testing.expect(field.grid.at(0, 1).is_slime());
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(2, 1));
}

test "fill draws every reservoir bucket and exhausts it exactly" {
    var rng = prng(4);
    var res = c.SlimeReservoir{ .neutral = 4 };
    res.tiered[ti(.red)] = 4;
    res.tiered[ti(.green)] = 4;
    const field = SlimeField.init(.{ .rows = 3, .cols = 4 }, res, rng.random());

    try testing.expectEqual(@as(u16, 12), field.grid.occupied());
    try testing.expect(field.reservoir.is_empty());
    // Composition is preserved exactly (only the placement is random).
    var neutral: u16 = 0;
    for (field.grid.live()) |cell| {
        if (cell == .neutral) neutral += 1;
    }
    try testing.expectEqual(@as(u16, 4), neutral);
    try testing.expectEqual(@as(u16, 4), field.grid.tier_count(.red));
    try testing.expectEqual(@as(u16, 4), field.grid.tier_count(.green));
}

test "reservoir slime always arrives at full difficulty" {
    // Casting cannot reach off-grid slime, so a refill after a cast brings in
    // an un-neutralized unit even though the grid was just cleaned.
    var rng = prng(16);
    var field = empty_field(1, 2);
    field.grid.put(0, .{ .tiered = .green });
    field.reservoir.tiered[ti(.red)] = 1;

    _ = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.get(0));

    _ = field.fill(rng.random());
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.get(1));
}

test "apply_shape downgrades every covered hazard one tier" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .red });

    const out = field.apply_shape(SQUARE_3X3, 1, 1);
    try testing.expectEqual(@as(u16, 9), out.total_downgraded());
    try testing.expectEqual(@as(u16, 9), out.downgraded[ti(.red)]);
    try testing.expectEqual(@as(u16, 0), out.neutralized);
    try testing.expectEqual(@as(u16, 0), out.wasted());
    // All nine are now yellow — one step, not straight to defused.
    try testing.expectEqual(@as(u16, 9), field.grid.tier_count(.yellow));
    try testing.expectEqual(@as(u16, 0), field.grid.tier_count(.red));
}

test "a red cell takes three casts to defuse" {
    var field = empty_field(1, 1);
    field.grid.put(0, .{ .tiered = .red });

    const first = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(c.SlimeCell{ .tiered = .yellow }, field.grid.get(0));
    try testing.expectEqual(@as(u16, 0), first.neutralized);

    _ = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.get(0));

    const third = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.get(0));
    try testing.expectEqual(@as(u16, 1), third.neutralized);
    try testing.expectEqual(@as(u16, 1), third.downgraded[ti(.green)]);

    // A fourth cast finds nothing left to neutralize.
    const fourth = field.apply_shape(DOT, 0, 0);
    try testing.expectEqual(@as(u16, 0), fourth.total_downgraded());
    try testing.expectEqual(@as(u16, 1), fourth.inert);
}

test "apply_shape clips at the grid edge and reports the loss" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .green });

    // Anchored at the top-left corner, a 3x3 lands only its bottom-right
    // quadrant: 4 cells on, 5 offsets clipped away.
    const out = field.apply_shape(SQUARE_3X3, 0, 0);
    try testing.expectEqual(@as(u16, 4), out.total_downgraded());
    try testing.expectEqual(@as(u16, 5), out.off_grid);
    try testing.expectEqual(@as(u16, 0), out.inert);
    try testing.expectEqual(@as(u16, 5), out.wasted());
    try testing.expectEqual(@as(u16, 4), out.neutralized);

    // Exactly the 2x2 block around the anchor was defused.
    for (0..3) |r| {
        for (0..3) |cl| {
            const expect_defused = r <= 1 and cl <= 1;
            const cell = field.grid.at(@intCast(r), @intCast(cl));
            try testing.expectEqual(expect_defused, cell == .neutralized);
        }
    }
}

test "apply_shape counts inert cells but leaves them untouched" {
    var field = empty_field(1, 3);
    field.grid.put(0, .neutral);
    field.grid.put(1, .neutralized);
    field.grid.put(2, .empty);

    const out = field.apply_shape(test_shape(&.{"###"}), 0, 1);
    try testing.expectEqual(@as(u16, 0), out.total_downgraded());
    try testing.expectEqual(@as(u16, 3), out.inert);
    try testing.expectEqual(@as(u16, 0), out.off_grid);
    // Untouched: neutral stays neutral, defused stays defused, empty stays empty.
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.get(0));
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.get(1));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.get(2));
}

test "apply_shape hits exactly the shape's footprint" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .green });

    const out = field.apply_shape(PLUS, 1, 1);
    try testing.expectEqual(@as(u16, 5), out.total_downgraded());
    // The four diagonals are untouched; the plus arms are defused.
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.at(0, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.at(0, 2));
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.at(2, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.at(2, 2));
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.at(0, 1));
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.at(1, 1));
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.at(1, 2));
    try testing.expectEqual(c.SlimeCell.neutralized, field.grid.at(2, 1));
}

test "apply_shape destroys nothing: the unit count is unchanged" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .red });
    const before = field.remaining();

    _ = field.apply_shape(SQUARE_3X3, 1, 1);
    _ = field.apply_shape(SQUARE_3X3, 1, 1);
    _ = field.apply_shape(SQUARE_3X3, 1, 1);

    // Every cell is defused, and every unit is still there to be eaten.
    try testing.expectEqual(before, field.remaining());
    try testing.expectEqual(@as(u16, 9), field.grid.occupied());
    try testing.expectEqual(@as(u16, 0), field.grid.hazard_count());
}

test "apply_shape is deterministic — the same aim gives the same field" {
    const run = struct {
        fn go() SlimeField {
            var field = empty_field(4, 4);
            paint(&field, .{ .tiered = .red });
            _ = field.apply_shape(PLUS, 2, 2);
            return field;
        }
    }.go;
    const a = run();
    const b = run();
    try testing.expectEqualSlices(c.SlimeCell, a.grid.live(), b.grid.live());
}

test "eat_all empties the field and prices every cell kind" {
    var field = empty_field(1, 3);
    field.grid.put(0, .neutral);
    field.grid.put(1, .{ .tiered = .red });
    field.grid.put(2, .neutralized);

    const feast = field.eat_all(test_bal);

    try testing.expectEqual(@as(u16, 3), feast.cells);
    try testing.expectEqual(3 * test_bal.hunger_cost_normal, feast.hunger_normal);
    // Only the live red hazard adds extra, and it lands in the red bucket.
    try testing.expectEqual(test_bal.hunger_cost_hazard_extra, feast.hunger_extra[ti(.red)]);
    try testing.expectEqual(@as(u32, 0), feast.hunger_extra[ti(.yellow)]);
    try testing.expectEqual(@as(u32, 0), feast.hunger_extra[ti(.green)]);
    // Neutral and defused both score; the hazard does not.
    try testing.expectEqual(@as(u32, 2), feast.score);
    try testing.expect(field.is_exhausted());
}

test "eat_all skips empty cells and reports an empty field as a no-op feast" {
    var field = empty_field(2, 2);
    field.grid.put(3, .neutral);

    const some = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 1), some.cells);

    // Nothing left: a second feast costs nothing rather than being an error.
    const none = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 0), none.cells);
    try testing.expectEqual(@as(u32, 0), none.hunger_total());
    try testing.expectEqual(@as(u32, 0), none.score);
}

test "every tier costs the same to eat, but heals from its own bucket" {
    // Difficulty is how many casts a unit needs, NOT how badly it hurts:
    // the eating penalty is identical for red, yellow and green.
    for ([_]c.Tier{ .red, .yellow, .green }) |tier| {
        var field = empty_field(1, 1);
        field.grid.put(0, .{ .tiered = tier });
        const feast = field.eat_all(test_bal);
        try testing.expectEqual(
            test_bal.hunger_cost_hazard_extra,
            feast.hunger_extra[ti(tier)],
        );
        try testing.expectEqual(test_bal.hunger_cost_hazard_extra, feast.hunger_total() -
            feast.hunger_normal);
        try testing.expectEqual(@as(u32, 0), feast.score);
    }
}

test "feasting turn after turn totals hunger and score over every unit" {
    var rng = prng(14);
    var res = c.SlimeReservoir{ .neutral = 7 };
    res.tiered[ti(.red)] = 10;
    res.tiered[ti(.green)] = 4;
    const total_units = res.total();
    var field = SlimeField.init(.{ .rows = 3, .cols = 3 }, res, rng.random());

    var eaten: u32 = 0;
    var hunger_normal: u32 = 0;
    var hunger_extra: u32 = 0;
    var score: u32 = 0;
    // One iteration = one turn with no casts: feast, then refill.
    while (!field.is_exhausted()) {
        const feast = field.eat_all(test_bal);
        eaten += feast.cells;
        hunger_normal += feast.hunger_normal;
        hunger_extra += feast.hunger_total() - feast.hunger_normal;
        score += feast.score;
        _ = field.fill(rng.random());
    }

    try testing.expectEqual(total_units, eaten);
    try testing.expectEqual(total_units * test_bal.hunger_cost_normal, hunger_normal);
    // 14 hazard units were never neutralized; 7 neutral units scored.
    try testing.expectEqual(14 * test_bal.hunger_cost_hazard_extra, hunger_extra);
    try testing.expectEqual(@as(u32, 7), score);
}

test "defusing before the feast removes the extra hunger and earns the score" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .green });

    // One cast over the whole 3x3 defuses all nine.
    _ = field.apply_shape(SQUARE_3X3, 1, 1);

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(feast.hunger_normal, feast.hunger_total());
    try testing.expectEqual(@as(u32, 9), feast.score);
}

test "field ops are reproducible for a given seed" {
    const run = struct {
        fn go(seed: u64) SlimeField {
            var rng = prng(seed);
            var res = c.SlimeReservoir{ .neutral = 10 };
            res.tiered[ti(.red)] = 10;
            var field = SlimeField.init(.{ .rows = 3, .cols = 4 }, res, rng.random());
            _ = field.apply_shape(PLUS, 1, 1);
            _ = field.eat_all(test_bal);
            _ = field.fill(rng.random());
            return field;
        }
    }.go;

    const a = run(42);
    const b = run(42);
    try testing.expectEqualSlices(c.SlimeCell, a.grid.live(), b.grid.live());
    try testing.expectEqual(a.reservoir, b.reservoir);
}
