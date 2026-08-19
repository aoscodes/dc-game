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
//!   eat_all     — the turn-end feast: eat every EDIBLE unit REACHABLE from the
//!                 left edge.  Live hazards and specials are inedible walls.
//!   collapse    — drop every surviving unit to the bottom of its column, so
//!                 the holes the feast made rise to the top.
//!
//! ## The path
//!
//! The feast is not a bulk operation over the whole grid: it is a flood fill
//! that ENTERS FROM THE LEFT EDGE and can only travel through cells it eats or
//! cells that are already empty.  A live hazard or a special therefore shelters
//! everything behind it, and the strategic question of a turn becomes *which
//! wall to open*, not merely *how much slime to clean*.
//!
//! Turn-end order is `eat_all` → `collapse` → `fill`: eat along the path, let
//! the survivors fall into the holes, then top the column up from the
//! reservoir.  Falling matters because it re-sorts which cells touch the left
//! edge, so a wall that sheltered slime this turn may not next turn.
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

    /// Slime still in play that is NOT an objective placeholder — the units
    /// the team can actually act on or eat.
    pub fn remaining_playable(self: *const SlimeField) u32 {
        return @as(u32, self.grid.non_special_count()) + self.reservoir.non_special();
    }

    /// True when nothing but `special` units is left anywhere.
    ///
    /// This is the WIN, not "the grid is empty": specials can never be removed
    /// by any play, so demanding an empty grid would make every encounter
    /// containing one unwinnable.  Clearing all the real slime is the
    /// achievement; the objectives left standing are the next feature's problem.
    pub fn is_exhausted(self: *const SlimeField) bool {
        return self.remaining_playable() == 0;
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
        if (pick < self.reservoir.special) {
            self.reservoir.special -= 1;
            return .special;
        }
        pick -= self.reservoir.special;
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
    ///                   neutral, already neutralized, or a `special`, which no
    ///                   cast can ever change)
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

    /// The turn-end feast: eat every EDIBLE unit the Lil Guys can REACH.
    ///
    /// They enter from the LEFT EDGE (column 0) and spread 4-connected through
    /// cells that let them pass: empty cells, and edible cells, which they eat
    /// on the way through.  A live hazard or a `special` is a WALL — inedible,
    /// impassable, and therefore a shelter for everything behind it.  This is
    /// the whole tactical core: a cast's value is the path it opens, and slime
    /// the team cannot expose survives the turn untouched.
    ///
    /// Only reached cells are emptied, so the grid comes back with its walls
    /// and its sheltered slime intact.  The caller's next steps are `collapse`
    /// then `fill`.
    ///
    /// Deterministic: reachability is a property of the grid, so no randomness
    /// and no dependence on the order cells happen to be visited in.
    pub fn eat_all(self: *SlimeField, bal: *const balance.Balance) FeastOutcome {
        var out = FeastOutcome{};

        // Breadth-first from the left edge.  `queue` doubles as the visited
        // marker's backing store: a cell is enqueued exactly once, so the
        // frontier can never exceed the grid.
        var visited = [_]bool{false} ** c.MAX_GRID_CELLS;
        var queue: [c.MAX_GRID_CELLS]u16 = undefined;
        var head: u16 = 0;
        var tail: u16 = 0;

        var row: u8 = 0;
        while (row < self.grid.rows) : (row += 1) {
            const flat = self.grid.index(row, 0);
            if (self.grid.get(flat).blocks_feast()) continue; // walled off at the door
            visited[flat] = true;
            queue[tail] = flat;
            tail += 1;
        }

        while (head < tail) {
            const flat = queue[head];
            head += 1;
            self.consume(flat, bal, &out);

            const r = self.grid.row_of(flat);
            const cl = self.grid.col_of(flat);
            const steps = [_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
            for (steps) |step| {
                const nr = @as(i32, r) + step[0];
                const nc = @as(i32, cl) + step[1];
                if (nr < 0 or nr >= self.grid.rows or nc < 0 or nc >= self.grid.cols) continue;
                const next = self.grid.index(@intCast(nr), @intCast(nc));
                if (visited[next]) continue;
                if (self.grid.get(next).blocks_feast()) continue;
                visited[next] = true;
                queue[tail] = next;
                tail += 1;
            }
        }

        // Everything the flood never reached: the walls that held, and the food
        // they saved.  Counted for the players' feedback — "you left N units
        // behind a wall" is the lesson the next turn is built on.
        var flat: u16 = 0;
        while (flat < self.grid.len()) : (flat += 1) {
            if (visited[flat]) continue;
            const cell = self.grid.get(flat);
            if (cell.is_edible()) out.sheltered += 1;
            if (cell.blocks_feast()) out.walls += 1;
        }
        return out;
    }

    /// Eat the unit at `flat` if it is edible, accruing hunger and score.
    /// Empty cells are simply corridor and cost nothing.  Never called on a
    /// blocking cell: the flood refuses to enter one.
    fn consume(
        self: *SlimeField,
        flat: u16,
        bal: *const balance.Balance,
        out: *FeastOutcome,
    ) void {
        const cell = self.grid.get(flat);
        switch (cell) {
            .empty => return, // corridor
            .neutral => out.neutral += 1,
            .neutralized => out.defused += 1,
            .special, .tiered => unreachable, // blocks_feast kept the flood out
        }
        out.cells += 1;
        out.score += 1;
        out.hunger += bal.hunger_cost_normal;
        self.grid.put(flat, .empty);
    }

    /// Drop every surviving unit to the bottom of its column, preserving the
    /// order within the column, so the holes the feast punched rise to the top
    /// for `fill` to refill.
    ///
    /// Gravity is what keeps the field from silting up: without it, slime
    /// sheltered deep behind a wall would sit in the same cell forever and the
    /// left edge would show the same faces every turn.  Falling continually
    /// re-presents the field to the feast.
    ///
    /// Returns the number of units that moved (0 when everything already rests
    /// on the bottom).
    pub fn collapse(self: *SlimeField) u16 {
        var moved: u16 = 0;
        var col: u8 = 0;
        while (col < self.grid.cols) : (col += 1) {
            // Walk upward, packing units against the bottom: `write` is the
            // lowest cell still free to receive one.
            var write: i32 = @as(i32, self.grid.rows) - 1;
            var read: i32 = write;
            while (read >= 0) : (read -= 1) {
                const cell = self.grid.at(@intCast(read), col);
                if (!cell.is_slime()) continue;
                if (read != write) {
                    self.grid.set(@intCast(write), col, cell);
                    self.grid.set(@intCast(read), col, .empty);
                    moved += 1;
                }
                write -= 1;
            }
        }
        return moved;
    }
};

/// What one feast produced.
///
/// Hunger is a single flat rate now: only edible units are ever swallowed, so
/// there is no "ate something dangerous" penalty to account for separately.
/// The interesting numbers are the ones about the PATH — `sheltered` and
/// `walls` say why the feast stopped where it did.
pub const FeastOutcome = struct {
    /// Slime units eaten.
    cells: u16 = 0,
    /// Of those, units that were never hazardous.
    neutral: u16 = 0,
    /// Of those, units a cast had taken all the way to defused.
    defused: u16 = 0,
    /// Edible units the flood could NOT reach — food saved by a wall.  The
    /// team's main feedback: high here means the casts opened no path.
    sheltered: u16 = 0,
    /// Inedible cells (live hazards and specials) the flood never got past.
    walls: u16 = 0,
    /// Hunger added: `hunger_cost_normal` per unit eaten.
    hunger: u32 = 0,
    /// Score: 1 per unit eaten (all eaten units are neutral or defused).
    score: u32 = 0,

    /// Total hunger the feast added.  Kept as a method so callers read the same
    /// way they did when hunger had several components.
    pub fn hunger_total(self: FeastOutcome) u32 {
        return self.hunger;
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

test "eat_all eats the edible cells it can reach from the left edge" {
    var field = empty_field(1, 3);
    field.grid.put(0, .neutral);
    field.grid.put(1, .neutralized);
    field.grid.put(2, .neutral);

    const feast = field.eat_all(test_bal);

    // Nothing blocks, so the flood walks the whole row.
    try testing.expectEqual(@as(u16, 3), feast.cells);
    try testing.expectEqual(@as(u16, 2), feast.neutral);
    try testing.expectEqual(@as(u16, 1), feast.defused);
    try testing.expectEqual(3 * test_bal.hunger_cost_normal, feast.hunger);
    try testing.expectEqual(@as(u32, 3), feast.score);
    try testing.expectEqual(@as(u16, 0), feast.sheltered);
    try testing.expectEqual(@as(u16, 0), feast.walls);
    try testing.expect(field.is_exhausted());
}

test "a live hazard is never eaten and shelters everything behind it" {
    // The central mechanic: the wall survives, and so does the food it guards.
    var field = empty_field(1, 4);
    field.grid.put(0, .neutral);
    field.grid.put(1, .{ .tiered = .red });
    field.grid.put(2, .neutral);
    field.grid.put(3, .neutral);

    const feast = field.eat_all(test_bal);

    try testing.expectEqual(@as(u16, 1), feast.cells);
    try testing.expectEqual(@as(u16, 2), feast.sheltered);
    try testing.expectEqual(@as(u16, 1), feast.walls);
    try testing.expectEqual(test_bal.hunger_cost_normal, feast.hunger);
    // The hazard and both sheltered units are untouched; only cell 0 opened.
    try testing.expectEqual(c.SlimeCell.empty, field.grid.get(0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.get(1));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.get(2));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.get(3));
}

test "a special walls the feast off exactly like a hazard" {
    var field = empty_field(1, 3);
    field.grid.put(0, .neutral);
    field.grid.put(1, .special);
    field.grid.put(2, .neutral);

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 1), feast.cells);
    try testing.expectEqual(@as(u16, 1), feast.sheltered);
    try testing.expectEqual(@as(u16, 1), feast.walls);
    try testing.expectEqual(c.SlimeCell.special, field.grid.get(1));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.get(2));
}

test "no cast can ever change a special" {
    var field = empty_field(1, 1);
    field.grid.put(0, .special);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const out = field.apply_shape(DOT, 0, 0);
        try testing.expectEqual(@as(u16, 0), out.total_downgraded());
        try testing.expectEqual(@as(u16, 1), out.inert);
    }
    try testing.expectEqual(c.SlimeCell.special, field.grid.get(0));
}

test "the feast flows around a wall that does not span the grid" {
    // A wall only shelters what it actually covers: the flood goes around.
    //   col: 0 1 2
    //   r0:  n # n
    //   r1:  n . n
    var field = empty_field(2, 3);
    field.grid.set(0, 0, .neutral);
    field.grid.set(0, 1, .{ .tiered = .green });
    field.grid.set(0, 2, .neutral);
    field.grid.set(1, 0, .neutral);
    field.grid.set(1, 1, .empty);
    field.grid.set(1, 2, .neutral);

    const feast = field.eat_all(test_bal);
    // All four neutrals fall: row 1 is an open corridor to column 2.
    try testing.expectEqual(@as(u16, 4), feast.cells);
    try testing.expectEqual(@as(u16, 0), feast.sheltered);
    try testing.expectEqual(@as(u16, 1), feast.walls);
    try testing.expectEqual(c.SlimeCell{ .tiered = .green }, field.grid.at(0, 1));
}

test "a full-height wall in column 0 stops the feast at the door" {
    var field = empty_field(3, 2);
    var row: u8 = 0;
    while (row < 3) : (row += 1) {
        field.grid.set(row, 0, .{ .tiered = .red });
        field.grid.set(row, 1, .neutral);
    }

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 0), feast.cells);
    try testing.expectEqual(@as(u16, 3), feast.sheltered);
    try testing.expectEqual(@as(u16, 3), feast.walls);
    try testing.expectEqual(@as(u32, 0), feast.hunger_total());
}

test "defusing a wall opens the path on the following feast" {
    // The turn loop in miniature: this turn the wall holds, the team spends a
    // cast on it, next turn the food behind it is reachable.
    var field = empty_field(1, 3);
    field.grid.put(0, .{ .tiered = .green });
    field.grid.put(1, .neutral);
    field.grid.put(2, .neutral);

    const blocked = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 0), blocked.cells);
    try testing.expectEqual(@as(u16, 2), blocked.sheltered);

    // One cast takes green to defused — which also makes the wall itself food.
    _ = field.apply_shape(DOT, 0, 0);
    const opened = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 3), opened.cells);
    try testing.expectEqual(@as(u16, 1), opened.defused);
    try testing.expectEqual(@as(u16, 2), opened.neutral);
    try testing.expectEqual(@as(u16, 0), opened.sheltered);
}

test "empty cells conduct the feast without feeding it" {
    var field = empty_field(1, 3);
    field.grid.put(0, .empty);
    field.grid.put(1, .empty);
    field.grid.put(2, .neutral);

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 1), feast.cells);
    try testing.expectEqual(test_bal.hunger_cost_normal, feast.hunger);
}

test "eat_all on an empty field is a free no-op" {
    var field = empty_field(2, 2);
    field.grid.put(3, .neutral);

    // (1,1) is reachable across the empty corridor.
    const some = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 1), some.cells);

    const none = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 0), none.cells);
    try testing.expectEqual(@as(u32, 0), none.hunger_total());
    try testing.expectEqual(@as(u32, 0), none.score);
    try testing.expectEqual(@as(u16, 0), none.walls);
}

test "every eaten unit costs the same flat hunger" {
    // Difficulty decides how many casts a unit needs, not what it costs to eat:
    // by the time anything is eaten it is edible, so the price is uniform.
    for ([_]c.SlimeCell{ .neutral, .neutralized }) |cell| {
        var field = empty_field(1, 1);
        field.grid.put(0, cell);
        const feast = field.eat_all(test_bal);
        try testing.expectEqual(test_bal.hunger_cost_normal, feast.hunger_total());
        try testing.expectEqual(@as(u32, 1), feast.score);
    }
}

test "collapse drops survivors to the bottom, preserving column order" {
    var field = empty_field(4, 1);
    field.grid.put(0, .neutral);            // top
    field.grid.put(1, .empty);
    field.grid.put(2, .{ .tiered = .red });
    field.grid.put(3, .empty);             // bottom

    const moved = field.collapse();
    try testing.expectEqual(@as(u16, 2), moved);
    // Order top-to-bottom is preserved: neutral was above the red, still is.
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 0));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(2, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(3, 0));
}

test "collapse is per-column: slime never slides sideways" {
    var field = empty_field(2, 2);
    field.grid.set(0, 0, .neutral);
    field.grid.set(1, 0, .empty);
    field.grid.set(0, 1, .empty);
    field.grid.set(1, 1, .empty);

    _ = field.collapse();
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(1, 1));
}

test "collapse on a packed column moves nothing and is idempotent" {
    var field = empty_field(3, 2);
    paint(&field, .neutral);
    try testing.expectEqual(@as(u16, 0), field.collapse());

    var field2 = empty_field(3, 1);
    field2.grid.put(0, .neutral);
    _ = field2.collapse();
    const snapshot = field2.grid;
    try testing.expectEqual(@as(u16, 0), field2.collapse());
    try testing.expectEqualSlices(c.SlimeCell, snapshot.live(), field2.grid.live());
}

test "collapse conserves every unit" {
    var rng = prng(21);
    var res = c.SlimeReservoir{ .neutral = 6, .special = 2 };
    res.tiered[ti(.red)] = 4;
    var field = SlimeField.init(.{ .rows = 4, .cols = 3 }, res, rng.random());
    _ = field.eat_all(test_bal);
    const before = field.grid.occupied();
    _ = field.collapse();
    try testing.expectEqual(before, field.grid.occupied());
}

test "turn settlement is eat, collapse, then refill from the top" {
    // Whatever the feast takes, collapse drags the survivors down after it, so
    // the holes always surface at the TOP — exactly where `fill` puts new
    // slime.  The field therefore keeps its layered look turn after turn.
    //
    //   . = empty   n = neutral   R = live red
    //        col0 col1
    //   row0   R    n     <- the n is sealed in: R to its left, R below
    //   row1   R    R
    //   row2   n    .     <- on the left edge, so this one is dinner
    var field = empty_field(3, 2);
    field.grid.put(field.grid.index(0, 0), .{ .tiered = .red });
    field.grid.put(field.grid.index(0, 1), .neutral);
    field.grid.put(field.grid.index(1, 0), .{ .tiered = .red });
    field.grid.put(field.grid.index(1, 1), .{ .tiered = .red });
    field.grid.put(field.grid.index(2, 0), .neutral);
    field.reservoir.neutral = 1;

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 1), feast.cells);
    try testing.expectEqual(@as(u16, 1), feast.sheltered);
    try testing.expectEqual(@as(u16, 3), feast.walls);

    // Four survivors, each with a hole under it, so each falls one row.
    try testing.expectEqual(@as(u16, 4), field.collapse());
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 0));
    try testing.expectEqual(c.SlimeCell.empty, field.grid.at(0, 1));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(1, 0));
    try testing.expectEqual(c.SlimeCell.neutral, field.grid.at(1, 1));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(2, 0));
    try testing.expectEqual(c.SlimeCell{ .tiered = .red }, field.grid.at(2, 1));

    // The one refill lands in the row the collapse just cleared.
    var rng = prng(5);
    try testing.expectEqual(@as(u16, 1), field.fill(rng.random()));
    const top_filled = @intFromBool(field.grid.at(0, 0) != .empty) +
        @intFromBool(field.grid.at(0, 1) != .empty);
    try testing.expectEqual(@as(u8, 1), top_filled);
}

test "specials keep a field from ever being exhausted of cells, but it is won" {
    // The special sits to the RIGHT of the food, so it walls off nothing and
    // the feast still clears the board of everything playable.
    var field = empty_field(1, 2);
    field.grid.put(0, .neutral);
    field.grid.put(1, .special);
    try testing.expect(!field.is_exhausted());

    try testing.expectEqual(@as(u16, 1), field.eat_all(test_bal).cells);
    // A special still occupies a cell, yet the encounter is won: nothing
    // playable is left anywhere.
    try testing.expectEqual(@as(u16, 1), field.grid.occupied());
    try testing.expectEqual(@as(u32, 0), field.remaining_playable());
    try testing.expect(field.is_exhausted());
}

test "a field walled off with charges gone is not won" {
    // The dead position the session must detect: slime remains, unreachable.
    var field = empty_field(1, 2);
    field.grid.put(0, .{ .tiered = .red });
    field.grid.put(1, .neutral);

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 0), feast.cells);
    try testing.expect(!field.is_exhausted());
    try testing.expectEqual(@as(u32, 2), field.remaining_playable());
}

test "turn after turn, gravity and refills eventually feed every unit" {
    // Liveness: with casts available the whole reservoir does get consumed, so
    // the pathed feast is not a way to stall forever.
    var rng = prng(14);
    var res = c.SlimeReservoir{ .neutral = 7 };
    res.tiered[ti(.red)] = 6;
    res.tiered[ti(.green)] = 4;
    const total_units = res.total();
    var field = SlimeField.init(.{ .rows = 3, .cols = 3 }, res, rng.random());

    var eaten: u32 = 0;
    var hunger: u32 = 0;
    var score: u32 = 0;
    var turns: u32 = 0;
    while (!field.is_exhausted() and turns < 200) : (turns += 1) {
        // A generous team: defuse the whole grid every turn, then feast.
        var pass: u8 = 0;
        while (pass < 3) : (pass += 1) {
            var r: u8 = 0;
            while (r < field.grid.rows) : (r += 1) {
                var cl: u8 = 0;
                while (cl < field.grid.cols) : (cl += 1) _ = field.apply_shape(DOT, r, cl);
            }
        }
        const feast = field.eat_all(test_bal);
        eaten += feast.cells;
        hunger += feast.hunger_total();
        score += feast.score;
        _ = field.collapse();
        _ = field.fill(rng.random());
    }

    try testing.expect(field.is_exhausted());
    try testing.expectEqual(total_units, eaten);
    try testing.expectEqual(total_units * test_bal.hunger_cost_normal, hunger);
    // Every unit was defused before it was eaten, so every unit scored.
    try testing.expectEqual(total_units, score);
}

test "leaving hazards up costs the team the food, not extra hunger" {
    var rng = prng(9);
    var res = c.SlimeReservoir{ .neutral = 4 };
    res.tiered[ti(.red)] = 5;
    var field = SlimeField.init(.{ .rows = 3, .cols = 3 }, res, rng.random());

    const feast = field.eat_all(test_bal);
    // Whatever it managed to eat, it paid the flat rate and nothing more.
    try testing.expectEqual(feast.cells * test_bal.hunger_cost_normal, feast.hunger_total());
    try testing.expectEqual(@as(u32, feast.cells), feast.score);
    // And the reds are all still standing.
    try testing.expectEqual(@as(u16, 5), field.grid.hazard_count());
}

test "defusing before the feast turns a wall into food" {
    var field = empty_field(3, 3);
    paint(&field, .{ .tiered = .green });

    // One cast over the whole 3x3 defuses all nine, so all nine are edible and
    // nothing blocks the flood.
    _ = field.apply_shape(SQUARE_3X3, 1, 1);

    const feast = field.eat_all(test_bal);
    try testing.expectEqual(@as(u16, 9), feast.cells);
    try testing.expectEqual(@as(u32, 9), feast.score);
    try testing.expectEqual(@as(u16, 0), feast.walls);
    try testing.expectEqual(9 * test_bal.hunger_cost_normal, feast.hunger_total());
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
            _ = field.collapse();
            _ = field.fill(rng.random());
            return field;
        }
    }.go;

    const a = run(42);
    const b = run(42);
    try testing.expectEqualSlices(c.SlimeCell, a.grid.live(), b.grid.live());
    try testing.expectEqual(a.reservoir, b.reservoir);
}
