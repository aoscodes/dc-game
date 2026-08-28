//! Balance *types* for the Slime Feast encounter.
//!
//! The actual numbers live in `data/balance.json` and are loaded at server
//! start by `config.zig` — designers tune the JSON, no rebuild required.
//! The browser fetches the same file, so there is a single source of truth
//! for rates and recipe tables (wire messages reference recipes by table
//! index, in file order).
//!
//! ## Moves
//!
//! A move names a SHAPE and a CHARGE COST.  Casting stamps that shape on the
//! grid anchored at the caster's cursor: every covered hazard cell is
//! downgraded one tier.
//!
//! `player_recipes` is an ordered CYCLE: each player has one move selected and
//! steps the selection forward/backward a slot at a time (see
//! session.cycle_selection).  Table order is therefore player-facing — it is the
//! order the wheel turns in — and a move's index is its identity on the wire.
//! There is no way to name a move that is not in the table, so the table is the
//! complete move list and a cast can only fail on price.
//!
//! ## Charges
//!
//! Charges are the encounter's scarce resource: ONE pool, shared by the whole
//! team, spent across the WHOLE game and never refilled (the starting amount is
//! per-encounter — see encounters.json).  Each move prices itself via `cost`,
//! so the move table is also the economy: broad shapes can be made expensive
//! and precise ones cheap.  A cast that would take the TURN over the pool is
//! refused outright — nothing is spent and nothing lands.
//!
//! ## Group moves
//!
//! A group move (`team_recipes`) is a bigger shape that no single player can
//! cast: it names a bag of ordinary moves (`moves`) which DISTINCT players must
//! cast on the SAME square within one turn.  Every cast still stamps its own
//! shape as it lands; the cast that completes the bag stamps the group shape
//! *instead of* its own, and pays the group's cost rather than its own (see
//! game_logic.complete_group).  So a group is discovered by playing normally
//! into the same cell, not by holding a cast back — nothing is ever escrowed,
//! and there is no state to lose at turn end.

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

/// Array cap on a group move's component bag.  A group cannot need more
/// contributors than there are players, and config.zig rejects a bag exceeding
/// protocol.MAX_PLAYERS; this is the looser static bound (protocol imports
/// balance, so balance cannot import protocol to reuse it).
pub const MAX_TEAM_COMPONENTS: u8 = 8;

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
/// recipes, so every distinct footprint is its own entry on the shape wheel and
/// the move list stays explicit.
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

/// One selectable move.  Its INDEX in `Balance.player_recipes` is its identity:
/// the wire sends a selection as an index, and group moves name their components
/// by index too.
pub const PlayerRecipe = struct {
    label: []const u8,
    /// Footprint downgraded at the caster's cursor.  Every move names a
    /// shape — the stamp IS the cast's whole effect.
    shape: Shape,
    /// Charges deducted from the team pool when this move fires.  May be 0
    /// for a deliberately free move.  A lock-in is refused when the whole
    /// turn's quote, this move included, exceeds what the pool holds.
    cost: u16 = DEFAULT_RECIPE_COST,
};

/// A shape too big for one player: it fires when DISTINCT players have cast the
/// moves in `components` on one square during a single turn.
pub const TeamRecipe = struct {
    label: []const u8,
    /// Indices into `Balance.player_recipes` — the moves that must land on the
    /// square, as a BAG (order is irrelevant, repeats are allowed and each
    /// repeat needs another player).  Resolved from JSON move labels by
    /// config.zig, so the data file names components the way designers do.
    components: []const u8,
    shape: Shape,
    /// Charges deducted ONCE when the group fires, INSTEAD of the completing
    /// cast's own cost.  The earlier component casts already paid their own way
    /// as they landed, so this is the price of the upgrade, not of the whole
    /// group.
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

/// Defaults for the appetite → hunger formula, used when the fields are
/// absent from balance.json.  See `game_logic.player_hunger` for the formula
/// itself; the board firmware mirrors it (board/src/game/balance.c
/// balance_player_hunger), so a change here should be made there too.
pub const DEFAULT_HUNGER_BASE: u16 = 30;
pub const DEFAULT_APPETITE_SCALE: u16 = 5;
pub const DEFAULT_HUNGER_PLAYER_CAP: u16 = 500;

/// Default run length a matchable special kind needs, used when a kind is
/// absent from balance.json's `specials` table.
pub const DEFAULT_MATCH_LEN: u8 = 3;

/// Default hunger capacity each baby Lil Guy adds to the pool, used when
/// `baby_hunger` is absent from balance.json.  Mirrored by the board firmware
/// (board/src/game/balance.c), so a change here should be made there too.
pub const DEFAULT_BABY_HUNGER: u16 = 10;

/// Designer knobs for one SpecialKind.  What a kind DOES is hard-coded
/// (components.SpecialKind); this tunes only its numbers.
pub const SpecialTuning = struct {
    /// Same-kind cells that must sit contiguously in one row or column
    /// (after the turn-end refill) to fire the kind's match effect.  Ignored
    /// for kinds with no match behaviour — which today is EVERY kind: the
    /// match machinery is dormant, and this knob waits with it.  The loader
    /// keeps it within 2..max(grid rows, cols) so a match is always
    /// physically possible.
    match_len: u8 = DEFAULT_MATCH_LEN,
};

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
    /// Selection cannot be wrong, so the only way a cast fails is price — and
    /// a refused cast costs nothing, budget included.  A team too poor to add
    /// anything has its remaining budgets stranded instead (see
    /// session.strand_budgets_if_broke), so a turn always ends.
    casts_per_turn: u8,
    /// Hunger capacity ONE player contributes with an appetite of 0.  The
    /// game's hunger bar capacity is the SUM of every player's contribution
    /// (see game_logic.player_hunger), so this replaces the old per-encounter
    /// `hunger_max`: a bigger team simply has more room to eat.
    hunger_base: u16 = DEFAULT_HUNGER_BASE,
    /// Extra hunger capacity per point of a player's appetite stat (the
    /// board's persistent flash stat, sent when a controller joins).  Linear:
    /// contribution = hunger_base + appetite * appetite_scale.
    appetite_scale: u16 = DEFAULT_APPETITE_SCALE,
    /// Ceiling on ONE player's hunger contribution, however large their
    /// appetite has grown — keeps a veteran board from trivialising the bar.
    hunger_player_cap: u16 = DEFAULT_HUNGER_PLAYER_CAP,
    /// Hunger capacity each baby Lil Guy in the encounter adds to the pool —
    /// babies a board brought AND babies hatched mid-game alike.
    baby_hunger: u16 = DEFAULT_BABY_HUNGER,
    /// Per-SpecialKind tuning, indexed by SpecialKind ordinal.
    specials: [c.SpecialKind.size]SpecialTuning =
        [_]SpecialTuning{.{}} ** c.SpecialKind.size,
    player_recipes: []const PlayerRecipe,
    team_recipes: []const TeamRecipe,

    /// Tuning for one special kind.
    pub fn special_tuning(self: *const Balance, kind: c.SpecialKind) SpecialTuning {
        return self.specials[@intFromEnum(kind)];
    }

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
