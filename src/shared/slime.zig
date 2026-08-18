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
//!   neutralize  — a dispensed color's agents transmute a RANDOM SUBSET of
//!                 the matching-color `modified` cells CURRENTLY ON THE GRID.
//!                 Agents beyond that on-grid cohort are wasted, and the
//!                 residue multiplier destroys a portion outright.
//!   bite        — empty one cell, reporting the hunger/score it produced.
//!
//! Neither the reservoir nor an off-grid unit can be neutralized: transmuting
//! is a grid-only operation by construction (`SlimeReservoir` has no
//! neutralized bucket).

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
        for (&self.reservoir.modified, 0..) |*count, i| {
            if (pick < count.*) {
                count.* -= 1;
                return .{ .modified = @enumFromInt(i) };
            }
            pick -= count.*;
        }
        unreachable; // `total` is the sum of the buckets just walked.
    }

    /// Flat indices of every `modified` cell of `color` — the cohort a
    /// dispensed agent of that color may transmute.  Returns the slice of
    /// `out` written; `out` must have capacity for the whole grid.
    fn modified_cells(
        self: *const SlimeField,
        color: c.Element,
        out: *[c.MAX_GRID_CELLS]u16,
    ) []u16 {
        var n: u16 = 0;
        for (self.grid.live(), 0..) |cell, i| {
            if (cell == .modified and cell.modified == color) {
                out[n] = @intCast(i);
                n += 1;
            }
        }
        return out[0..n];
    }

    /// Transmute matching-color modified slime with one cast's agent units.
    ///
    /// `agents[e]` units of color `e` act on the color-`e` modified cells
    /// CURRENTLY ON THE GRID: `t = min(agents, cohort)` cells are picked at
    /// random and leave the modified state.  Of those, `floor(residue_mult *
    /// t)` become `neutralized` (still edible, no extra hunger, still score);
    /// the rest are destroyed outright, emptying the cell.  Agents beyond the
    /// on-grid cohort, and wrong-color agents, are wasted.
    ///
    /// Returns cells transmuted (i.e. removed from `modified`) per color.
    pub fn neutralize(
        self: *SlimeField,
        agents: [c.Element.size]u32,
        residue_mult: f32,
        rand: std.Random,
    ) [c.Element.size]u16 {
        var transmuted = [_]u16{0} ** c.Element.size;
        var buf: [c.MAX_GRID_CELLS]u16 = undefined;

        for (agents, 0..) |pool, i| {
            if (pool == 0) continue;
            const color: c.Element = @enumFromInt(i);
            const cohort = self.modified_cells(color, &buf);
            if (cohort.len == 0) continue;

            const n: u16 = @intCast(@min(pool, cohort.len));
            // Random subset of size n: partial Fisher-Yates over the cohort.
            for (0..n) |k| {
                const j = k + rand.uintLessThan(usize, cohort.len - k);
                std.mem.swap(u16, &cohort[k], &cohort[j]);
            }
            const survivors: u16 =
                @intFromFloat(@floor(residue_mult * @as(f32, @floatFromInt(n))));
            for (cohort[0..n], 0..) |flat, k| {
                self.grid.put(flat, if (k < survivors)
                    .{ .neutralized = color }
                else
                    .empty);
            }
            transmuted[i] = n;
        }
        return transmuted;
    }

    /// Pick a random occupied cell — what a Lil Guy targets.  Returns its
    /// flat index, or null when the grid holds no slime.
    pub fn pick_target(self: *const SlimeField, rand: std.Random) ?u16 {
        const occupied = self.grid.occupied();
        if (occupied == 0) return null;
        // Choose the k-th occupied cell so every unit is equally likely
        // regardless of how holes are distributed.
        var k = rand.uintLessThan(u16, occupied);
        for (self.grid.live(), 0..) |cell, i| {
            if (!cell.is_slime()) continue;
            if (k == 0) return @intCast(i);
            k -= 1;
        }
        unreachable; // `occupied` counted the cells just walked.
    }

    /// Eat the cell at `flat`, emptying it.  Returns null if the cell was
    /// already empty (its slime was neutralized-away or eaten by another Lil
    /// Guy before this bite landed) — callers re-target instead of eating.
    pub fn bite(
        self: *SlimeField,
        bal: *const balance.Balance,
        flat: u16,
    ) ?BiteOutcome {
        const cell = self.grid.get(flat);
        if (!cell.is_slime()) return null;
        self.grid.put(flat, .empty);

        var out = BiteOutcome{ .hunger_normal = bal.hunger_cost_normal };
        switch (cell) {
            .empty => unreachable, // guarded above
            .neutral => {
                out.eaten = .neutral;
                out.score = 1;
            },
            .neutralized => |color| {
                out.eaten = .{ .neutralized = color };
                out.score = 1;
            },
            .modified => |color| {
                out.eaten = .{ .modified = color };
                out.hunger_extra = bal.hunger_cost_modified_extra;
            },
        }
        return out;
    }
};

/// What one bite produced.  `hunger_extra` is healable by medicine matching
/// the eaten cell's color; `hunger_normal` never is.
pub const BiteOutcome = struct {
    /// The cell that was eaten (never `.empty`).
    eaten: c.SlimeCell = .neutral,
    /// Hunger from eating a unit at all.
    hunger_normal: u32 = 0,
    /// Extra hunger, non-zero only for un-neutralized modified slime.
    hunger_extra: u32 = 0,
    /// Score: 1 for neutral/neutralized slime, 0 for modified.
    score: u32 = 0,

    /// The color whose medicine can heal `hunger_extra`, or null when this
    /// bite produced no healable hunger.
    pub fn healable_color(self: BiteOutcome) ?c.Element {
        return switch (self.eaten) {
            .modified => |color| color,
            else => null,
        };
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

const el = struct {
    fn i(e: c.Element) usize {
        return @intFromEnum(e);
    }
}.i;

test "init fills the grid from the reservoir and keeps the overflow" {
    var rng = prng(1);
    var res = c.SlimeReservoir{ .neutral = 20 };
    res.modified[el(.red)] = 30;
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
    try testing.expectEqual(@as(u32, 5), field.remaining());
    // Filled top-first: the first 5 flat cells hold the slime.
    for (field.grid.live(), 0..) |cell, i| {
        try testing.expectEqual(i < 5, cell.is_slime());
    }
}

test "fill refills empty cells from the top row downward" {
    var rng = prng(3);
    var field = SlimeField.init(.{ .rows = 3, .cols = 2 }, .{ .neutral = 6 }, rng.random());
    try testing.expect(field.reservoir.is_empty());

    // Empty the top row and one bottom cell, then top the reservoir back up.
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
    res.modified[el(.red)] = 4;
    res.modified[el(.blue)] = 4;
    const field = SlimeField.init(.{ .rows = 3, .cols = 4 }, res, rng.random());

    try testing.expectEqual(@as(u16, 12), field.grid.occupied());
    try testing.expect(field.reservoir.is_empty());
    // Composition is preserved exactly (only the placement is random).
    var neutral: u16 = 0;
    for (field.grid.live()) |cell| {
        if (cell == .neutral) neutral += 1;
    }
    try testing.expectEqual(@as(u16, 4), neutral);
    try testing.expectEqual(@as(u16, 4), field.grid.modified_count(.red));
    try testing.expectEqual(@as(u16, 4), field.grid.modified_count(.blue));
}

test "neutralize converts matching-color cells and wastes excess agents" {
    var rng = prng(5);
    var res = c.SlimeReservoir{};
    res.modified[el(.red)] = 9;
    var field = SlimeField.init(.{ .rows = 3, .cols = 3 }, res, rng.random());
    try testing.expectEqual(@as(u16, 9), field.grid.modified_count(.red));

    var agents = [_]u32{0} ** c.Element.size;
    agents[el(.red)] = 4;
    const moved = field.neutralize(agents, 1.0, rng.random());

    try testing.expectEqual(@as(u16, 4), moved[el(.red)]);
    try testing.expectEqual(@as(u16, 5), field.grid.modified_count(.red));
    // residue 1.0: every transmuted cell survives, so the grid is still full.
    try testing.expectEqual(@as(u16, 9), field.grid.occupied());

    // Far more agents than the remaining cohort: the excess is wasted.
    agents[el(.red)] = 999;
    const rest = field.neutralize(agents, 1.0, rng.random());
    try testing.expectEqual(@as(u16, 5), rest[el(.red)]);
    try testing.expectEqual(@as(u16, 0), field.grid.modified_count(.red));
}

test "neutralize reach is limited to the on-grid cohort" {
    var rng = prng(6);
    var res = c.SlimeReservoir{};
    res.modified[el(.red)] = 100; // only 4 fit on the grid
    var field = SlimeField.init(.{ .rows = 2, .cols = 2 }, res, rng.random());

    var agents = [_]u32{0} ** c.Element.size;
    agents[el(.red)] = 100;
    const moved = field.neutralize(agents, 1.0, rng.random());

    // Reach is the 4 on-grid cells; the 96 reservoir units are untouched.
    try testing.expectEqual(@as(u16, 4), moved[el(.red)]);
    try testing.expectEqual(@as(u16, 96), field.reservoir.modified[el(.red)]);
    try testing.expectEqual(@as(u16, 0), field.grid.modified_count(.red));
}

test "neutralize ignores wrong-color and already-neutralized cells" {
    var rng = prng(7);
    var res = c.SlimeReservoir{};
    res.modified[el(.red)] = 4;
    var field = SlimeField.init(.{ .rows = 2, .cols = 2 }, res, rng.random());

    var wrong = [_]u32{0} ** c.Element.size;
    wrong[el(.blue)] = 99;
    const none = field.neutralize(wrong, 1.0, rng.random());
    for (none) |n| try testing.expectEqual(@as(u16, 0), n);
    try testing.expectEqual(@as(u16, 4), field.grid.modified_count(.red));

    // Neutralize all red, then dispense red again: nothing left in the cohort.
    var red = [_]u32{0} ** c.Element.size;
    red[el(.red)] = 4;
    _ = field.neutralize(red, 1.0, rng.random());
    const again = field.neutralize(red, 1.0, rng.random());
    try testing.expectEqual(@as(u16, 0), again[el(.red)]);
}

test "neutralize residue_mult destroys the non-surviving portion" {
    var rng = prng(8);
    var res = c.SlimeReservoir{};
    res.modified[el(.green)] = 8;
    var field = SlimeField.init(.{ .rows = 2, .cols = 4 }, res, rng.random());

    var agents = [_]u32{0} ** c.Element.size;
    agents[el(.green)] = 8;
    const moved = field.neutralize(agents, 0.5, rng.random());

    try testing.expectEqual(@as(u16, 8), moved[el(.green)]);
    // floor(0.5 × 8) = 4 survive as neutralized; the other 4 cells are empty.
    try testing.expectEqual(@as(u16, 4), field.grid.occupied());
    try testing.expectEqual(@as(u16, 0), field.grid.modified_count(.green));
    for (field.grid.live()) |cell| {
        try testing.expect(cell == .empty or cell == .neutralized);
    }
}

test "neutralize residue_mult 0 empties every transmuted cell" {
    var rng = prng(9);
    var res = c.SlimeReservoir{};
    res.modified[el(.yellow)] = 4;
    var field = SlimeField.init(.{ .rows = 2, .cols = 2 }, res, rng.random());

    var agents = [_]u32{0} ** c.Element.size;
    agents[el(.yellow)] = 4;
    _ = field.neutralize(agents, 0.0, rng.random());
    try testing.expectEqual(@as(u16, 0), field.grid.occupied());
    try testing.expect(field.is_exhausted());
}

test "neutralize picks a random subset, not a fixed prefix" {
    // Same grid, different seeds → different cells chosen.  (Sampling a few
    // seeds; a fixed-prefix implementation would make all runs identical.)
    var seen_distinct = false;
    var first: ?[4]bool = null;
    for (0..8) |seed| {
        var rng = prng(@intCast(100 + seed));
        var res = c.SlimeReservoir{};
        res.modified[el(.red)] = 4;
        var field = SlimeField.init(.{ .rows = 2, .cols = 2 }, res, rng.random());
        var agents = [_]u32{0} ** c.Element.size;
        agents[el(.red)] = 2;
        _ = field.neutralize(agents, 1.0, rng.random());

        var pattern: [4]bool = undefined;
        for (field.grid.live(), 0..) |cell, i| pattern[i] = cell == .neutralized;
        if (first) |f| {
            if (!std.mem.eql(bool, &f, &pattern)) seen_distinct = true;
        } else {
            first = pattern;
        }
    }
    try testing.expect(seen_distinct);
}

test "pick_target returns an occupied cell and null on an empty grid" {
    var rng = prng(10);
    var field = SlimeField.init(.{ .rows = 2, .cols = 3 }, .{ .neutral = 2 }, rng.random());

    for (0..16) |_| {
        const flat = field.pick_target(rng.random()).?;
        try testing.expect(field.grid.get(flat).is_slime());
    }

    // Empty every cell: no target remains.
    for (0..field.grid.len()) |i| field.grid.put(@intCast(i), .empty);
    try testing.expectEqual(@as(?u16, null), field.pick_target(rng.random()));
}

test "pick_target reaches every occupied cell across draws" {
    var rng = prng(11);
    var field = SlimeField.init(.{ .rows = 1, .cols = 4 }, .{ .neutral = 4 }, rng.random());
    // Leave a hole so the k-th-occupied walk has to skip it.
    field.grid.set(0, 1, .empty);

    var hit = [_]bool{false} ** 4;
    for (0..200) |_| hit[field.pick_target(rng.random()).?] = true;
    try testing.expect(hit[0] and hit[2] and hit[3]);
    try testing.expect(!hit[1]);
}

test "bite empties the cell and reports hunger and score per cell kind" {
    var rng = prng(12);
    var field = SlimeField.init(.{ .rows = 1, .cols = 3 }, .{ .neutral = 3 }, rng.random());
    field.grid.set(0, 0, .neutral);
    field.grid.set(0, 1, .{ .modified = .red });
    field.grid.set(0, 2, .{ .neutralized = .blue });

    const neutral = field.bite(test_bal, 0).?;
    try testing.expectEqual(test_bal.hunger_cost_normal, neutral.hunger_normal);
    try testing.expectEqual(@as(u32, 0), neutral.hunger_extra);
    try testing.expectEqual(@as(u32, 1), neutral.score);
    try testing.expectEqual(@as(?c.Element, null), neutral.healable_color());
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 0));

    const modified = field.bite(test_bal, 1).?;
    try testing.expectEqual(test_bal.hunger_cost_normal, modified.hunger_normal);
    try testing.expectEqual(test_bal.hunger_cost_modified_extra, modified.hunger_extra);
    try testing.expectEqual(@as(u32, 0), modified.score);
    try testing.expectEqual(c.Element.red, modified.healable_color().?);

    const neutralized = field.bite(test_bal, 2).?;
    try testing.expectEqual(test_bal.hunger_cost_normal, neutralized.hunger_normal);
    try testing.expectEqual(@as(u32, 0), neutralized.hunger_extra);
    try testing.expectEqual(@as(u32, 1), neutralized.score);
    try testing.expectEqual(@as(?c.Element, null), neutralized.healable_color());

    try testing.expect(field.is_exhausted());
}

test "bite on an already-empty cell returns null" {
    var rng = prng(13);
    var field = SlimeField.init(.{ .rows = 1, .cols = 2 }, .{ .neutral = 1 }, rng.random());
    try testing.expect(field.bite(test_bal, 0) != null);
    try testing.expectEqual(@as(?BiteOutcome, null), field.bite(test_bal, 0));
    // The cell the reservoir never filled is empty too.
    try testing.expectEqual(@as(?BiteOutcome, null), field.bite(test_bal, 1));
}

test "eating the whole field totals hunger and score over every unit" {
    var rng = prng(14);
    var res = c.SlimeReservoir{ .neutral = 7 };
    res.modified[el(.red)] = 10;
    res.modified[el(.green)] = 4;
    const total_units = res.total();
    var field = SlimeField.init(.{ .rows = 3, .cols = 3 }, res, rng.random());

    var eaten: u32 = 0;
    var hunger_normal: u32 = 0;
    var hunger_extra: u32 = 0;
    var score: u32 = 0;
    while (!field.is_exhausted()) {
        const flat = field.pick_target(rng.random()) orelse {
            _ = field.fill(rng.random());
            continue;
        };
        const outcome = field.bite(test_bal, flat).?;
        eaten += 1;
        hunger_normal += outcome.hunger_normal;
        hunger_extra += outcome.hunger_extra;
        score += outcome.score;
        _ = field.fill(rng.random()); // reservoir tops the grid back up
    }

    // Every unit is eaten exactly once, wherever it started.
    try testing.expectEqual(total_units, eaten);
    try testing.expectEqual(total_units * test_bal.hunger_cost_normal, hunger_normal);
    // 14 modified units were never neutralized; 7 neutral units scored.
    try testing.expectEqual(14 * test_bal.hunger_cost_modified_extra, hunger_extra);
    try testing.expectEqual(@as(u32, 7), score);
}

test "neutralizing before eating removes the extra hunger" {
    var rng = prng(15);
    var res = c.SlimeReservoir{};
    res.modified[el(.red)] = 9;
    var field = SlimeField.init(.{ .rows = 3, .cols = 3 }, res, rng.random());

    var agents = [_]u32{0} ** c.Element.size;
    agents[el(.red)] = 9;
    _ = field.neutralize(agents, 1.0, rng.random());

    var hunger_extra: u32 = 0;
    var score: u32 = 0;
    while (field.pick_target(rng.random())) |flat| {
        const outcome = field.bite(test_bal, flat).?;
        hunger_extra += outcome.hunger_extra;
        score += outcome.score;
    }
    try testing.expectEqual(@as(u32, 0), hunger_extra);
    try testing.expectEqual(@as(u32, 9), score);
}

test "field ops are reproducible for a given seed" {
    const run = struct {
        fn go(seed: u64) SlimeField {
            var rng = prng(seed);
            var res = c.SlimeReservoir{ .neutral = 10 };
            res.modified[el(.red)] = 10;
            var field = SlimeField.init(.{ .rows = 3, .cols = 4 }, res, rng.random());
            var agents = [_]u32{0} ** c.Element.size;
            agents[el(.red)] = 3;
            _ = field.neutralize(agents, 1.0, rng.random());
            const flat = field.pick_target(rng.random()).?;
            _ = field.bite(test_bal, flat);
            _ = field.fill(rng.random());
            return field;
        }
    }.go;

    const a = run(42);
    const b = run(42);
    try testing.expectEqualSlices(c.SlimeCell, a.grid.live(), b.grid.live());
    try testing.expectEqual(a.reservoir, b.reservoir);
}
