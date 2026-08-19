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
//! length) naming a SHAPE and a CHARGE COST.  Casting stamps that shape on the
//! grid anchored at the caster's cursor: every covered hazard cell is
//! downgraded one tier.  There is no flat fallback — a combo matching no recipe
//! fizzles, so the recipe tables are the complete move list.
//!
//! ## Charges
//!
//! Charges are the encounter's scarce resource: ONE pool, shared by the whole
//! team, spent across the WHOLE game and never refilled (the starting amount is
//! per-encounter — see encounters.json).  Each recipe prices itself via
//! `cost`, so the recipe table is also the economy: broad shapes can be made
//! expensive and precise ones cheap.  A cast the pool cannot afford fizzles.
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

/// Charges a recipe costs when `cost` is absent from its JSON entry.
pub const DEFAULT_RECIPE_COST: u16 = 1;

pub const PlayerRecipe = struct {
    label: []const u8,
    pattern: c.ActionCombo,
    /// Footprint downgraded at the caster's cursor.  Every recipe names a
    /// shape — the stamp IS the cast's whole effect.
    shape: Shape,
    /// Charges deducted from the team pool when this recipe fires.  May be 0
    /// for a deliberately free move; a cast is refused (and fizzles) when the
    /// pool holds less than this.
    cost: u16 = DEFAULT_RECIPE_COST,
};

/// `patterns` — one exact combo per participating player (distinct players).
///
/// The combined shape lands at the cursor of the LAST JOINER: the player whose
/// submit completed the group. They chose to close the circuit, so they aim it.
pub const TeamRecipe = struct {
    label: []const u8,
    patterns: []const c.ActionCombo,
    shape: Shape,
    /// Charges deducted ONCE per firing of the group, regardless of how many
    /// players contributed.  Charged when the group completes, not when the
    /// individual halves are submitted, so a half that never finds its partner
    /// costs the pool nothing.
    cost: u16 = DEFAULT_RECIPE_COST,
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
    /// Hunger cost per slime unit consumed.  Only EDIBLE units are ever eaten
    /// (neutral and defused), so this is the single hunger rate: hazards are
    /// never swallowed, they are walls.
    hunger_cost_normal: u32,
    /// Dimensions of the slime grid.  Slime beyond `rows * cols` waits in the
    /// off-grid reservoir and refills emptied cells at the start of each turn.
    slime_grid: SlimeGridDims,
    /// Casts each player may commit per turn.  The turn ends once EVERY
    /// connected player has spent their budget, so this is both the team's
    /// per-turn power and the length of a turn.  Must be at least 1: a budget
    /// of 0 could never be spent, so no turn could ever end.
    ///
    /// A fizzled cast (a combo naming no recipe) does NOT spend budget; a
    /// team half held for a partner who never arrives DOES, and so does a cast
    /// the charge pool could not afford — otherwise a bankrupt team could never
    /// end a turn.
    casts_per_turn: u8,
    player_recipes: []const PlayerRecipe,
    team_recipes: []const TeamRecipe,

    /// The cheapest cast in the whole move list.  A team holding fewer charges
    /// than this can never affect the grid again, which is how the session
    /// recognises a dead position (see session.check_end).
    pub fn cheapest_cost(self: *const Balance) u16 {
        var min: u16 = std.math.maxInt(u16);
        for (self.player_recipes) |r| min = @min(min, r.cost);
        for (self.team_recipes) |r| min = @min(min, r.cost);
        return min;
    }
};

/// Default per-player cast budget when `casts_per_turn` is absent.
pub const DEFAULT_CASTS_PER_TURN: u8 = 3;
