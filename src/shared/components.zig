//! All ECS component types shared between client and server.
//!
//! Component identity is determined by comptime index in the World(...)
//! instantiation, so this file is the single source of truth for both.
//! Neither client nor server may define additional game-state components
//! outside this file.
//!
//! ## Slime Feast model
//!
//! The slime field is a fixed `rows` × `cols` grid of INDIVIDUAL slime units
//! (`SlimeGrid` of `SlimeCell`), plus an off-grid `SlimeReservoir` that
//! refills emptied cells from the top row.  One grid per game.
//!
//! Play is TURN-BASED.  Each player gets `casts_per_turn` casts; once every
//! connected player has spent theirs the turn ends and the field is EATEN
//! ALONG A PATH: the feast enters from the LEFT edge and consumes every
//! edible unit it can reach, so live hazards and `special` units wall it off
//! and protect whatever hides behind them.  Survivors then fall to the bottom
//! of their column and the reservoir refills from the top.
//!
//! Casting costs CHARGES from one team-shared, whole-game pool (each recipe
//! prices its own cost), so the campaign's real resource is charges and the
//! per-turn cast budget only paces how fast they can be spent.
//!
//! The "Lil Guys" who do the eating are a CLIENT-SIDE animation over that bulk
//! feast — there is no Lil Guy entity, timer or target anywhere on the server.
//!
//! ## Shapes and tiers
//!
//! A cell's COLOR is its difficulty, not its type: a cast downgrades a cell
//! one step along `red -> yellow -> green -> neutralized`, so red slime needs
//! three applications and green needs one.
//!
//! A cast's power is its SHAPE.  Each player aims a cursor at a grid cell
//! (server-authoritative, moved with the d-pad) and a recipe stamps a fixed
//! footprint — a 3×3 block, a plus, a line — anchored there, downgrading every
//! hazard it covers.  Cells outside the grid or holding nothing to neutralize
//! are wasted, which is the player's aiming feedback.
//!
//! ## Move selection model
//!
//! There is no input alphabet to learn: the move list (balance.player_recipes)
//! is a CYCLE, each player has exactly one move selected in it, and the two
//! buttons step that selection forward and backward.  A selection is therefore
//! just an index, always valid, and a cast is always a legal move — the only
//! way to fail is being unable to pay for it.

const std = @import("std");

pub const Health = struct {
    current: u16,
    max: u16,
};

/// Kind of entity on the wire's PLAYER list.  Players are the only entities
/// the server simulates; the Lil Guys on screen are pure client animation.
pub const EntityKind = enum(u8) {
    player = 0,
};

pub const Kind = struct {
    tag: EntityKind,
};

/// Zero-size marker component. Present on every player entity; drives the
/// PlayerTeam system signature.
pub const PlayerMarker = struct {};

pub const Owner = struct {
    player_id: u8,
};

/// Which way a button steps the move selection through the move cycle.  The
/// wheel wraps in both directions, so neither end is a dead stop.
pub const CycleDir = enum(u8) {
    forward = 0,
    backward = 1,
};

/// Slime DIFFICULTY, not slime type: how many Neutralizing Agent applications
/// a unit still needs.  A cast downgrades a cell one step along
/// `red -> yellow -> green -> neutralized`, so red is the toughest slime and
/// green is one hit from being defused.
///
/// Ordinals are the tier order, so `downgrade` is just "next ordinal".
pub const Tier = enum(u8) {
    red = 0,
    yellow = 1,
    green = 2,

    pub const size = @typeInfo(Tier).@"enum".fields.len;

    /// The tier one Neutralizing Agent application below this one, or null
    /// when the unit is defused outright (green's step is `neutralized`).
    pub fn downgrade(self: Tier) ?Tier {
        const next = @intFromEnum(self) + 1;
        if (next >= size) return null;
        return @enumFromInt(next);
    }
};

/// Upper bounds on the slime grid (wire + array sizing).  The config loader
/// rejects `slime_grid` dimensions exceeding these.
pub const MAX_GRID_ROWS: u8 = 16;
pub const MAX_GRID_COLS: u8 = 16;
pub const MAX_GRID_CELLS: u16 = @as(u16, MAX_GRID_ROWS) * @as(u16, MAX_GRID_COLS);

/// One cell of the slime grid — exactly one slime unit, or nothing.
///
/// This is the whole slime state model: there are no scalar bucket counts.
/// A cell is:
///   empty       — eaten (or never filled); refilled from the reservoir
///   neutral     — naturally-neutral slime; edible
///   tiered      — hazardous slime at difficulty `Tier`.  INEDIBLE: the feast
///                 will not eat it and cannot pass through it.  A cast
///                 downgrades it one tier (red -> yellow -> green -> defused),
///                 which is the only way to open the path it blocks.
///   neutralized — defused: a `tiered` cell downgraded past green.  Edible and
///                 scores like neutral, but kept distinct so the render can
///                 show the team earned it.
///   special     — an objective placeholder.  PERMANENT: no cast affects it,
///                 the feast never eats it, and it blocks the path like a live
///                 hazard.  Objective behaviour will be built on top of this
///                 cell later; until then it is terrain.
///
/// The edible/blocking split is the heart of the game: see `is_edible` and
/// `blocks_feast`, which `slime.eat_all` flood-fills over.
///
/// Wire encoding (one byte, see protocol.zig):
///   0x00 = empty, 0x01 = neutral, 0x02 = neutralized, 0x03 = special,
///   0x10|t = tiered.
pub const SlimeCell = union(enum) {
    empty,
    neutral,
    neutralized,
    special,
    tiered: Tier,

    /// True if this cell holds a slime unit of any kind — anything that
    /// occupies space and must fall when the column collapses.
    pub fn is_slime(self: SlimeCell) bool {
        return self != .empty;
    }

    /// True if the turn-end feast will eat this unit once it can reach it.
    /// Defused slime counts: taking a hazard to `neutralized` is precisely
    /// what turns it into food.
    pub fn is_edible(self: SlimeCell) bool {
        return self == .neutral or self == .neutralized;
    }

    /// True if this cell stops the feast advancing through it — a live hazard
    /// or a special.  Everything else (empty, edible) conducts the path, since
    /// an edible cell is eaten and therefore opens.
    pub fn blocks_feast(self: SlimeCell) bool {
        return self == .tiered or self == .special;
    }

    /// True if this cell still needs neutralizing — the only kind a cast
    /// affects.  Specials are NOT hazards: nothing can change them.
    pub fn is_hazard(self: SlimeCell) bool {
        return self == .tiered;
    }
};

/// The slime field: a fixed `rows` × `cols` grid of individual slime units.
///
/// Row 0 is the TOP row (the side the reservoir refills from); Lil Guys
/// approach from below.  `cells` is row-major with a compile-time capacity;
/// only the first `rows * cols` entries are live — always go through the
/// accessors, which assert the bounds.
///
/// The grid is server-authoritative: the session owns the only instance and
/// transmits it, so every client renders identical slime.
pub const SlimeGrid = struct {
    rows: u8,
    cols: u8,
    cells: [MAX_GRID_CELLS]SlimeCell = [_]SlimeCell{.empty} ** MAX_GRID_CELLS,

    /// An all-empty grid of the given dimensions.
    pub fn init(rows: u8, cols: u8) SlimeGrid {
        std.debug.assert(rows >= 1 and rows <= MAX_GRID_ROWS);
        std.debug.assert(cols >= 1 and cols <= MAX_GRID_COLS);
        return .{ .rows = rows, .cols = cols };
    }

    /// Number of live cells (`rows * cols`).
    pub fn len(self: *const SlimeGrid) u16 {
        return @as(u16, self.rows) * @as(u16, self.cols);
    }

    /// Row-major flat index of (row, col).
    pub fn index(self: *const SlimeGrid, row: u8, col: u8) u16 {
        std.debug.assert(row < self.rows and col < self.cols);
        return @as(u16, row) * @as(u16, self.cols) + col;
    }

    /// Row of a flat index — the inverse of `index` (must be < len()).
    pub fn row_of(self: *const SlimeGrid, flat: u16) u8 {
        std.debug.assert(flat < self.len());
        return @intCast(flat / @as(u16, self.cols));
    }

    /// Column of a flat index — the inverse of `index` (must be < len()).
    pub fn col_of(self: *const SlimeGrid, flat: u16) u8 {
        std.debug.assert(flat < self.len());
        return @intCast(flat % @as(u16, self.cols));
    }

    /// Step a flat index one cell in a direction, CLAMPED at the grid edge:
    /// aiming into a wall parks the cursor against it rather than wrapping to
    /// the far side (which would make the d-pad unusable) or going invalid.
    pub fn step(self: *const SlimeGrid, flat: u16, d_row: i8, d_col: i8) u16 {
        const row = @as(i16, self.row_of(flat)) + d_row;
        const col = @as(i16, self.col_of(flat)) + d_col;
        const r = std.math.clamp(row, 0, @as(i16, self.rows) - 1);
        const cl = std.math.clamp(col, 0, @as(i16, self.cols) - 1);
        return self.index(@intCast(r), @intCast(cl));
    }

    pub fn at(self: *const SlimeGrid, row: u8, col: u8) SlimeCell {
        return self.cells[self.index(row, col)];
    }

    pub fn set(self: *SlimeGrid, row: u8, col: u8, cell: SlimeCell) void {
        self.cells[self.index(row, col)] = cell;
    }

    /// Cell at a flat index (must be < len()).
    pub fn get(self: *const SlimeGrid, flat: u16) SlimeCell {
        std.debug.assert(flat < self.len());
        return self.cells[flat];
    }

    pub fn put(self: *SlimeGrid, flat: u16, cell: SlimeCell) void {
        std.debug.assert(flat < self.len());
        self.cells[flat] = cell;
    }

    /// Live cells in row-major order — the canonical iteration slice.
    pub fn live(self: *const SlimeGrid) []const SlimeCell {
        return self.cells[0..self.len()];
    }

    /// Count of non-empty cells (slime units currently on the grid).
    pub fn occupied(self: *const SlimeGrid) u16 {
        var n: u16 = 0;
        for (self.live()) |cell| {
            if (cell.is_slime()) n += 1;
        }
        return n;
    }

    /// Count of un-neutralized `tiered` cells at one difficulty.
    pub fn tier_count(self: *const SlimeGrid, tier: Tier) u16 {
        var n: u16 = 0;
        for (self.live()) |cell| {
            if (cell == .tiered and cell.tiered == tier) n += 1;
        }
        return n;
    }

    /// Count of cells that still need neutralizing, at any tier.
    pub fn hazard_count(self: *const SlimeGrid) u16 {
        var n: u16 = 0;
        for (self.live()) |cell| {
            if (cell.is_hazard()) n += 1;
        }
        return n;
    }

    /// Count of `special` cells — objective placeholders, which no play can
    /// remove.
    pub fn special_count(self: *const SlimeGrid) u16 {
        var n: u16 = 0;
        for (self.live()) |cell| {
            if (cell == .special) n += 1;
        }
        return n;
    }

    /// Occupied cells that are not specials: the slime still genuinely in play.
    /// Zero here (with an equally special-only reservoir) is the win.
    pub fn non_special_count(self: *const SlimeGrid) u16 {
        return self.occupied() - self.special_count();
    }
};

/// Off-grid slime waiting to enter the grid from the top.
///
/// The reservoir only ever holds slime in its ORIGINAL state — neutralizing
/// happens on the grid, so no `neutralized` bucket exists here.  `tiered[t]`
/// is indexed by Tier ordinal.  Specials enter from here too, so an encounter
/// can hold its objectives back rather than opening with all of them.
pub const SlimeReservoir = struct {
    tiered: [Tier.size]u16 = [_]u16{0} ** Tier.size,
    neutral: u16 = 0,
    /// Objective placeholders waiting to enter (see SlimeCell.special).
    special: u16 = 0,

    pub fn total(self: SlimeReservoir) u32 {
        var n: u32 = self.neutral;
        n += self.special;
        for (self.tiered) |m| n += m;
        return n;
    }

    pub fn is_empty(self: SlimeReservoir) bool {
        return self.total() == 0;
    }

    /// Units here that are NOT specials.  The win condition asks whether
    /// anything but objectives is left in play, and the reservoir half of that
    /// question is this.
    pub fn non_special(self: SlimeReservoir) u32 {
        return self.total() - self.special;
    }
};


/// Animation to play on an entity, signalled by the server via action_result
/// and forwarded to the browser in the render JSON.  Extend by adding variants.
pub const ActionAnimation = enum(u8) {
    attack = 0,
    hurt = 1,
    die = 2,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "SlimeGrid init is all empty with the requested dimensions" {
    const grid = SlimeGrid.init(3, 4);
    try testing.expectEqual(@as(u8, 3), grid.rows);
    try testing.expectEqual(@as(u8, 4), grid.cols);
    try testing.expectEqual(@as(u16, 12), grid.len());
    try testing.expectEqual(@as(u16, 12), grid.live().len);
    try testing.expectEqual(@as(u16, 0), grid.occupied());
    for (grid.live()) |cell| try testing.expectEqual(SlimeCell.empty, cell);
}

test "SlimeGrid index is row-major with row 0 as the top row" {
    const grid = SlimeGrid.init(3, 4);
    try testing.expectEqual(@as(u16, 0), grid.index(0, 0));
    try testing.expectEqual(@as(u16, 3), grid.index(0, 3));
    try testing.expectEqual(@as(u16, 4), grid.index(1, 0));
    try testing.expectEqual(@as(u16, 11), grid.index(2, 3));
}

test "SlimeGrid set/at and put/get address the same cell" {
    var grid = SlimeGrid.init(2, 2);
    grid.set(1, 0, .{ .tiered = .green });
    try testing.expectEqual(SlimeCell{ .tiered = .green }, grid.at(1, 0));
    try testing.expectEqual(SlimeCell{ .tiered = .green }, grid.get(grid.index(1, 0)));

    grid.put(grid.index(0, 1), .neutral);
    try testing.expectEqual(SlimeCell.neutral, grid.at(0, 1));
}

test "SlimeGrid occupied counts every non-empty cell kind" {
    var grid = SlimeGrid.init(2, 3);
    try testing.expectEqual(@as(u16, 0), grid.occupied());
    grid.set(0, 0, .neutral);
    grid.set(0, 1, .{ .tiered = .red });
    grid.set(0, 2, .neutralized);
    try testing.expectEqual(@as(u16, 3), grid.occupied());
    grid.set(0, 1, .empty);
    try testing.expectEqual(@as(u16, 2), grid.occupied());
}

test "SlimeGrid tier_count is per difficulty and excludes defused cells" {
    var grid = SlimeGrid.init(2, 3);
    grid.set(0, 0, .{ .tiered = .red });
    grid.set(0, 1, .{ .tiered = .red });
    grid.set(0, 2, .{ .tiered = .green });
    // A defused cell has no tier: it is nobody's cohort.
    grid.set(1, 0, .neutralized);
    grid.set(1, 1, .neutral);

    try testing.expectEqual(@as(u16, 2), grid.tier_count(.red));
    try testing.expectEqual(@as(u16, 1), grid.tier_count(.green));
    try testing.expectEqual(@as(u16, 0), grid.tier_count(.yellow));
    // Three hazards on the grid; neutral and neutralized are not hazards.
    try testing.expectEqual(@as(u16, 3), grid.hazard_count());
}

test "SlimeGrid ignores cells beyond the live region" {
    var grid = SlimeGrid.init(1, 2);
    // Write past the live region directly; accessors must not see it.
    grid.cells[50] = .neutral;
    try testing.expectEqual(@as(u16, 2), grid.len());
    try testing.expectEqual(@as(u16, 0), grid.occupied());
    try testing.expectEqual(@as(u16, 0), grid.tier_count(.red));
    try testing.expectEqual(@as(u16, 0), grid.hazard_count());
}

test "SlimeCell.is_slime is false only for empty" {
    const empty: SlimeCell = .empty;
    try testing.expect(!empty.is_slime());
    const neutral: SlimeCell = .neutral;
    const neutralized: SlimeCell = .neutralized;
    const special: SlimeCell = .special;
    try testing.expect(neutral.is_slime());
    try testing.expect((SlimeCell{ .tiered = .red }).is_slime());
    try testing.expect(neutralized.is_slime());
    // A special occupies its cell like any other unit — it falls, and it is
    // never "nothing".
    try testing.expect(special.is_slime());
}

test "SlimeCell.is_hazard is true only for a live tiered cell" {
    // Only hazards are worth casting at.  A special looks immovable in the same
    // way a red does, but no cast can ever touch it, so it is NOT a hazard.
    try testing.expect((SlimeCell{ .tiered = .red }).is_hazard());
    try testing.expect((SlimeCell{ .tiered = .green }).is_hazard());
    const neutralized: SlimeCell = .neutralized;
    const neutral: SlimeCell = .neutral;
    const empty: SlimeCell = .empty;
    const special: SlimeCell = .special;
    try testing.expect(!neutralized.is_hazard());
    try testing.expect(!neutral.is_hazard());
    try testing.expect(!empty.is_hazard());
    try testing.expect(!special.is_hazard());
}

test "edible and blocking are exact opposites over the occupied cells" {
    // The feast's whole rulebook: an occupied cell either feeds it or stops it,
    // never both and never neither.  Empty conducts without feeding.
    const cases = [_]SlimeCell{
        .neutral,                 .neutralized,
        .special,                 .{ .tiered = .red },
        .{ .tiered = .yellow },   .{ .tiered = .green },
    };
    for (cases) |cell| {
        try testing.expect(cell.is_edible() != cell.blocks_feast());
    }
    const empty: SlimeCell = .empty;
    try testing.expect(!empty.is_edible());
    try testing.expect(!empty.blocks_feast());
}

test "SlimeReservoir totals across tiers, neutral and specials" {
    var res = SlimeReservoir{};
    try testing.expect(res.is_empty());
    try testing.expectEqual(@as(u32, 0), res.total());

    res.neutral = 5;
    res.tiered[@intFromEnum(Tier.red)] = 2;
    res.tiered[@intFromEnum(Tier.green)] = 3;
    try testing.expect(!res.is_empty());
    try testing.expectEqual(@as(u32, 10), res.total());
    try testing.expectEqual(@as(u32, 10), res.non_special());

    // Specials count toward the total (they still have to enter the grid) but
    // are excluded from `non_special`, which is what the win check reads.
    res.special = 4;
    try testing.expectEqual(@as(u32, 14), res.total());
    try testing.expectEqual(@as(u32, 10), res.non_special());
}

test "a reservoir of nothing but specials is not empty, but has no real slime" {
    // The win condition: nothing left in play except objectives.
    var res = SlimeReservoir{ .special = 3 };
    try testing.expect(!res.is_empty());
    try testing.expectEqual(@as(u32, 0), res.non_special());
}

test "grid capacity bounds agree" {
    try testing.expectEqual(@as(u16, 256), MAX_GRID_CELLS);
    try testing.expectEqual(@as(usize, MAX_GRID_CELLS), (SlimeGrid{ .rows = 1, .cols = 1 }).cells.len);
}

test "SlimeGrid row_of and col_of invert index" {
    const grid = SlimeGrid.init(4, 7);
    var flat: u16 = 0;
    while (flat < grid.len()) : (flat += 1) {
        try testing.expectEqual(flat, grid.index(grid.row_of(flat), grid.col_of(flat)));
    }
}

test "SlimeGrid.step moves one cell in each direction" {
    const grid = SlimeGrid.init(4, 7);
    const middle = grid.index(2, 3);
    try testing.expectEqual(grid.index(1, 3), grid.step(middle, -1, 0));
    try testing.expectEqual(grid.index(3, 3), grid.step(middle, 1, 0));
    try testing.expectEqual(grid.index(2, 2), grid.step(middle, 0, -1));
    try testing.expectEqual(grid.index(2, 4), grid.step(middle, 0, 1));
}

test "SlimeGrid.step clamps at every edge instead of wrapping" {
    // Wrapping would teleport the cursor across the field on a single press.
    const grid = SlimeGrid.init(4, 7);
    const top_left = grid.index(0, 0);
    try testing.expectEqual(top_left, grid.step(top_left, -1, 0));
    try testing.expectEqual(top_left, grid.step(top_left, 0, -1));

    const bottom_right = grid.index(3, 6);
    try testing.expectEqual(bottom_right, grid.step(bottom_right, 1, 0));
    try testing.expectEqual(bottom_right, grid.step(bottom_right, 0, 1));
}

test "SlimeGrid.step never leaves its row when moving sideways" {
    // A naive flat +/- 1 would spill into the neighbouring row at the edges.
    const grid = SlimeGrid.init(4, 7);
    const row_end = grid.index(1, 6);
    try testing.expectEqual(@as(u8, 1), grid.row_of(grid.step(row_end, 0, 1)));
    const row_start = grid.index(1, 0);
    try testing.expectEqual(@as(u8, 1), grid.row_of(grid.step(row_start, 0, -1)));
}

test "SlimeGrid.step on a 1x1 grid always stays put" {
    const grid = SlimeGrid.init(1, 1);
    for ([_][2]i8{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |d| {
        try testing.expectEqual(@as(u16, 0), grid.step(0, d[0], d[1]));
    }
}
