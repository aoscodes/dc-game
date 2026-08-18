//! Balance *types* for the Slime Feast encounter.
//!
//! The actual numbers live in `data/balance.json` and are loaded at server
//! start by `config.zig` — designers tune the JSON, no rebuild required.
//! The browser fetches the same file, so there is a single source of truth
//! for rates and recipe tables (wire messages reference recipes by table
//! index, in file order).
//!
//! ## Recipes
//!
//! A recipe is an *exact* combo pattern (same slots, same order, same
//! length) naming a SHAPE.  Casting stamps that shape on the grid anchored at
//! the caster's cursor: every covered hazard cell is downgraded one tier.
//! There is no flat fallback — a combo matching no recipe fizzles, so the
//! recipe tables are the complete move list.
//!
//! Team recipes match sets of combos cast by distinct players in the same
//! round.  They are checked first, greedily, in table order; each player's
//! combo can be consumed by at most one recipe per round.  A team recipe may
//! fire multiple times per round if several disjoint player groups match.
//! Player recipes are checked next.

const std = @import("std");
const c = @import("components.zig");

/// Wire cap on the player recipe table (MatchStats hit-array sizing).
/// The config loader rejects data files exceeding it.
pub const MAX_PLAYER_RECIPES: u8 = 64;
/// Wire cap on the team recipe table.
pub const MAX_TEAM_RECIPES: u8 = 64;

/// Bounding-box cap on a single shape.  A shape must fit the grid caps, since
/// a shape larger than the playfield could never land fully.
pub const MAX_SHAPE_ROWS: u8 = c.MAX_GRID_ROWS;
pub const MAX_SHAPE_COLS: u8 = c.MAX_GRID_COLS;
pub const MAX_SHAPE_CELLS: u16 = @as(u16, MAX_SHAPE_ROWS) * @as(u16, MAX_SHAPE_COLS);

/// One cell of a shape, as a SIGNED offset from the shape's anchor.  Signed
/// because the anchor is the bounding box's centre, so cells reach up/left of
/// it; the grid clips whatever falls outside (see slime.apply_shape).
pub const ShapeOffset = struct {
    d_row: i8,
    d_col: i8,
};

/// The footprint a cast stamps on the grid: the set of cells it covers,
/// relative to the anchor cell the player aims at.
///
/// Orientation is FIXED — rotations and reflections are authored as separate
/// recipes, so every distinct footprint has its own combo and the move list
/// stays explicit.
///
/// Built by `config.zig` from JSON rows of `#`/`.` characters, e.g.
/// `[".#.", "###", ".#."]` is a plus.  The anchor is the bounding box centre
/// (rounded down), so odd-sized shapes centre on the aimed cell.
pub const Shape = struct {
    /// Covered cells, in row-major order of the authored rows.  Never empty:
    /// the loader rejects a shape with no `#`.
    offsets: []const ShapeOffset,
    /// Bounding box of the authored rows, for previews and validation.
    rows: u8,
    cols: u8,

    /// Number of cells this shape covers when it lands fully on the grid.
    pub fn size(self: Shape) usize {
        return self.offsets.len;
    }
};

pub const PlayerRecipe = struct {
    label: []const u8,
    pattern: c.ActionCombo,
    /// Footprint downgraded at the caster's cursor.  Every recipe names a
    /// shape; a pure-heal recipe carries a minimal (1×1) shape and non-zero
    /// `medicine`.
    shape: Shape,
    medicine: c.MedicineOutput = .{},
};

/// `patterns` — one exact combo per participating player (distinct players).
///
/// The combined shape lands at the cursor of the LAST JOINER: the player whose
/// submit completed the group. They chose to close the circuit, so they aim it.
pub const TeamRecipe = struct {
    label: []const u8,
    patterns: []const c.ActionCombo,
    shape: Shape,
    medicine: c.MedicineOutput = .{},
};

/// Slime grid dimensions — a GLOBAL knob (not per-encounter), so every game
/// presents the same playfield shape and the renderer's layout is stable.
/// Validated by config.zig against components.MAX_GRID_ROWS/COLS.
pub const SlimeGridDims = struct {
    rows: u8,
    cols: u8,

    /// Live cell count of a grid with these dimensions.
    pub fn cells(self: SlimeGridDims) u16 {
        return @as(u16, self.rows) * @as(u16, self.cols);
    }
};

/// Default grid used when `slime_grid` is absent from balance.json.
pub const DEFAULT_SLIME_GRID = SlimeGridDims{ .rows = 6, .cols = 10 };

/// All designer-tunable balance numbers.  Loaded from `data/balance.json`
/// (see config.zig); tests use the frozen fixture in fixtures.zig.
pub const Balance = struct {
    /// Hunger cost per slime unit consumed (any unit — never healable).
    hunger_cost_normal: u32,
    /// EXTRA hunger per un-neutralized hazard unit consumed (healable portion,
    /// healed by medicine matching the tier that was eaten).
    hunger_cost_hazard_extra: u32,
    /// Dimensions of the slime grid.  Slime beyond `rows * cols` waits in the
    /// off-grid reservoir and refills emptied cells from the top row.
    slime_grid: SlimeGridDims,
    /// Slime units eaten per second PER LIL GUY (one Lil Guy per connected
    /// player) — the team eats at rate × players.  Its inverse is one Lil
    /// Guy's per-bite interval.
    eat_rate_units_per_s: f32,
    /// PER-CAST buffer in milliseconds.  Each accepted
    /// submit_spell fires solo when its own buffer expires — unless a newly
    /// accepted cast COMPLETES a team recipe with pending casts, in which
    /// case that recipe instance's members fire together at the newest
    /// joiner's expiry.  0 = fire immediately (no grouping window).
    cast_buffer_ms: u32,
    /// Per-player cast cooldown in milliseconds, started on
    /// each accepted submit.  While locked further submits are ignored; once
    /// unlocked a resubmit REPLACES the player's pending cast (restarting
    /// its buffer).  Values above cast_buffer_ms throttle overall cast
    /// rate.  0 = no lock.
    cast_lock_ms: u32,
    player_recipes: []const PlayerRecipe,
    team_recipes: []const TeamRecipe,
};
