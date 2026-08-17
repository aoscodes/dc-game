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
//! Players support a horde of "Lil Guys" (one per connected player, each a
//! real server ECS entity — see `LilGuy`) that each pick a random occupied
//! cell, walk to it and bite it empty.  Modified Slime (colored, per-Element)
//! costs extra hunger unless players neutralize it first by dispensing
//! matching-color Neutralizing Agents — which convert a random subset of the
//! matching-color cells CURRENTLY ON THE GRID (agents beyond that cohort are
//! wasted).  Medicine heals the hunger bar, but only the portion
//! attributable to un-neutralized modified-slime consumption.
//!
//! ## Combo slot model
//!
//! A combo is a sequence of up to MAX_COMBO_LEN `ComboSlot` values.
//! Each slot is either an `ActionChoice` (dispense/medicine) or an
//! `Element` modifier (red/green/yellow/blue — the four agent colors).
//! An element token applies to all following action tokens until the next
//! element token or end of combo.  Trailing element tokens with no
//! following action are ignored during resolution.  See
//! `game_logic.parse_combo` for the canonical interpretation.
//!
//! Exact combos may match recipes (player/team tables loaded from
//! data/balance.json — see config.zig) which *replace* the combo's flat
//! per-slot conversion with a tuned AgentOutput.

const std = @import("std");

pub const Health = struct {
    current: u16,
    max: u16,
};

/// Kind of entity on the wire's PLAYER list.  Lil Guys are server entities
/// too, but ride their own `GameState.lil_guys` array (they carry a target
/// cell and bite timer, not a combo), so they are not an EntityKind.
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

/// Player actions:
///   dispense — release Neutralizing Agent units of the current combo element
///              (agent color) onto the current round's zone.
///   medicine — contribute to the round's medicine pool OF THE CURRENT combo
///              element.  Medicine is symmetrical: color-X medicine heals
///              only the hunger caused by eating un-neutralized color-X
///              Modified Slime.  Colorless medicine is wasted.
pub const ActionChoice = enum(u8) {
    dispense = 0,
    medicine = 1,

    pub const size = @typeInfo(ActionChoice).@"enum".fields.len;
};

/// Agent color / Modified Slime type.  Reskinned elements: the color of a
/// slime communicates which Neutralizing Agent it requires.
pub const Element = enum(u8) {
    red = 0,
    green = 1,
    yellow = 2,
    blue = 3,

    pub const size = @typeInfo(Element).@"enum".fields.len;
};

/// One slot in a combo: either an action or an element modifier.
/// Wire encoding: action = raw ActionChoice value (0x00–0x01);
///                element = 0x80 | raw Element value (0x80–0x83).
pub const ComboSlot = union(enum) {
    action: ActionChoice,
    element: Element,
};

pub const MAX_COMBO_LEN: u8 = 5;

/// An ordered sequence of 1–MAX_COMBO_LEN combo slots submitted by a player
/// for one round.  Slots are action tokens (dispense/medicine) optionally
/// preceded by element modifier tokens.  See `game_logic.parse_combo` for
/// the resolution rules.
pub const ActionCombo = struct {
    slots: [MAX_COMBO_LEN]ComboSlot,
    len: u8, // 1..MAX_COMBO_LEN
};

/// Build an ActionCombo from a slice of slots (must be 1..MAX_COMBO_LEN).
/// Unused trailing slots are padded with a harmless dispense action.
pub fn make_combo(slots: []const ComboSlot) ActionCombo {
    std.debug.assert(slots.len >= 1 and slots.len <= MAX_COMBO_LEN);
    var combo = ActionCombo{
        .slots = [_]ComboSlot{.{ .action = .dispense }} ** MAX_COMBO_LEN,
        .len = @intCast(slots.len),
    };
    @memcpy(combo.slots[0..slots.len], slots);
    return combo;
}

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
///   neutral     — naturally-neutral slime, costs hunger_cost_normal
///   modified    — colored slime; costs the normal + modified-extra hunger,
///                 and that extra is healable by matching-color medicine
///   neutralized — was `modified` of this color, transmuted by a matching
///                 Neutralizing Agent; costs only hunger_cost_normal.  The
///                 original color is retained for rendering and stats.
///
/// Wire encoding (one byte, see protocol.zig):
///   0x00 = empty, 0x01 = neutral, 0x10|e = modified, 0x20|e = neutralized.
pub const SlimeCell = union(enum) {
    empty,
    neutral,
    modified: Element,
    neutralized: Element,

    /// True if this cell holds a slime unit a Lil Guy can bite.
    pub fn is_slime(self: SlimeCell) bool {
        return self != .empty;
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

    /// Count of `modified` cells of one color — the cohort a dispensed
    /// Neutralizing Agent of that color may transmute.
    pub fn modified_count(self: *const SlimeGrid, element: Element) u16 {
        var n: u16 = 0;
        for (self.live()) |cell| {
            if (cell == .modified and cell.modified == element) n += 1;
        }
        return n;
    }
};

/// Off-grid slime waiting to enter the grid from the top.
///
/// The reservoir only ever holds slime in its ORIGINAL state — neutralizing
/// happens on the grid, so no `neutralized` bucket exists here.  `modified[e]`
/// is indexed by Element ordinal.
pub const SlimeReservoir = struct {
    modified: [Element.size]u16 = [_]u16{0} ** Element.size,
    neutral: u16 = 0,

    pub fn total(self: SlimeReservoir) u32 {
        var n: u32 = self.neutral;
        for (self.modified) |m| n += m;
        return n;
    }

    pub fn is_empty(self: SlimeReservoir) bool {
        return self.total() == 0;
    }
};

/// A Lil Guy's reserved bite: the grid cell it is walking to, plus the
/// countdown until the bite lands.
///
/// One Lil Guy exists per connected player as a real server ECS entity.  The
/// target is RESERVED, not exclusive — another Lil Guy may reach the same cell
/// first, or a neutralizing agent may destroy it, in which case the bite finds
/// an empty cell and the Lil Guy simply re-targets (see session.bite_tick).
///
/// `target` is a flat `SlimeGrid` index; `NO_TARGET` means "none reserved yet"
/// (the grid was empty when this Lil Guy last looked).
pub const LilGuy = struct {
    /// Flat grid index being approached, or NO_TARGET.
    target: u16 = NO_TARGET,
    /// Seconds until the bite lands.  Reset on every re-target.
    bite_timer: f32 = 0,

    /// Sentinel `target` value: no cell reserved.  Out of range for any grid
    /// since MAX_GRID_CELLS is far below it.
    pub const NO_TARGET: u16 = std.math.maxInt(u16);

    pub fn has_target(self: LilGuy) bool {
        return self.target != NO_TARGET;
    }
};

/// Result of converting one round's combos: Neutralizing Agent units and
/// medicine pools, both per color.  Color-X medicine heals only the healable
/// hunger caused by color-X modified slime (symmetrical healing).  Produced
/// per-combo (flat conversion or recipe output) and summed across the team.
pub const AgentOutput = struct {
    units: [Element.size]u32 = [_]u32{0} ** Element.size,
    medicine: [Element.size]u32 = [_]u32{0} ** Element.size,

    pub fn add(self: *AgentOutput, other: AgentOutput) void {
        for (&self.units, other.units) |*u, o| u.* +|= o;
        for (&self.medicine, other.medicine) |*m, o| m.* +|= o;
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
    grid.set(1, 0, .{ .modified = .green });
    try testing.expectEqual(SlimeCell{ .modified = .green }, grid.at(1, 0));
    try testing.expectEqual(SlimeCell{ .modified = .green }, grid.get(grid.index(1, 0)));

    grid.put(grid.index(0, 1), .neutral);
    try testing.expectEqual(SlimeCell.neutral, grid.at(0, 1));
}

test "SlimeGrid occupied counts every non-empty cell kind" {
    var grid = SlimeGrid.init(2, 3);
    try testing.expectEqual(@as(u16, 0), grid.occupied());
    grid.set(0, 0, .neutral);
    grid.set(0, 1, .{ .modified = .red });
    grid.set(0, 2, .{ .neutralized = .red });
    try testing.expectEqual(@as(u16, 3), grid.occupied());
    grid.set(0, 1, .empty);
    try testing.expectEqual(@as(u16, 2), grid.occupied());
}

test "SlimeGrid modified_count is per color and excludes neutralized" {
    var grid = SlimeGrid.init(2, 3);
    grid.set(0, 0, .{ .modified = .red });
    grid.set(0, 1, .{ .modified = .red });
    grid.set(0, 2, .{ .modified = .blue });
    // Already-neutralized red is NOT part of the red cohort.
    grid.set(1, 0, .{ .neutralized = .red });
    grid.set(1, 1, .neutral);

    try testing.expectEqual(@as(u16, 2), grid.modified_count(.red));
    try testing.expectEqual(@as(u16, 1), grid.modified_count(.blue));
    try testing.expectEqual(@as(u16, 0), grid.modified_count(.green));
    try testing.expectEqual(@as(u16, 0), grid.modified_count(.yellow));
}

test "SlimeGrid ignores cells beyond the live region" {
    var grid = SlimeGrid.init(1, 2);
    // Write past the live region directly; accessors must not see it.
    grid.cells[50] = .neutral;
    try testing.expectEqual(@as(u16, 2), grid.len());
    try testing.expectEqual(@as(u16, 0), grid.occupied());
    try testing.expectEqual(@as(u16, 0), grid.modified_count(.red));
}

test "SlimeCell.is_slime is false only for empty" {
    const empty: SlimeCell = .empty;
    const neutral: SlimeCell = .neutral;
    try testing.expect(!empty.is_slime());
    try testing.expect(neutral.is_slime());
    try testing.expect((SlimeCell{ .modified = .red }).is_slime());
    try testing.expect((SlimeCell{ .neutralized = .red }).is_slime());
}

test "SlimeReservoir totals across colors and neutral" {
    var res = SlimeReservoir{};
    try testing.expect(res.is_empty());
    try testing.expectEqual(@as(u32, 0), res.total());

    res.neutral = 5;
    res.modified[@intFromEnum(Element.red)] = 2;
    res.modified[@intFromEnum(Element.blue)] = 3;
    try testing.expect(!res.is_empty());
    try testing.expectEqual(@as(u32, 10), res.total());
}

test "grid capacity bounds agree" {
    try testing.expectEqual(@as(u16, 256), MAX_GRID_CELLS);
    try testing.expectEqual(@as(usize, MAX_GRID_CELLS), (SlimeGrid{ .rows = 1, .cols = 1 }).cells.len);
}
