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
//! length).  When a submitted combo matches a recipe, the recipe's
//! AgentOutput REPLACES the combo's flat conversion.
//!
//! Team recipes match sets of combos cast by distinct players in the same
//! round.  They are checked first, greedily, in table order; each player's
//! combo can be consumed by at most one recipe per round.  A team recipe may
//! fire multiple times per round if several disjoint player groups match.
//! Player recipes are checked next, then any unmatched combo falls back to
//! flat conversion (see game_logic.flat_convert).

const c = @import("components.zig");

/// Wire cap on the player recipe table (MatchStats hit-array sizing).
/// The config loader rejects data files exceeding it.
pub const MAX_PLAYER_RECIPES: u8 = 64;
/// Wire cap on the team recipe table.
pub const MAX_TEAM_RECIPES: u8 = 64;

pub const PlayerRecipe = struct {
    label: []const u8,
    pattern: c.ActionCombo,
    output: c.AgentOutput,
};

/// `patterns` — one exact combo per participating player (distinct players).
pub const TeamRecipe = struct {
    label: []const u8,
    patterns: []const c.ActionCombo,
    output: c.AgentOutput,
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

/// Default grid used when `slime_grid` is absent from balance.json, so
/// pre-grid configs (including the saved /tune configs) keep validating.
pub const DEFAULT_SLIME_GRID = SlimeGridDims{ .rows = 6, .cols = 10 };

/// All designer-tunable balance numbers.  Loaded from `data/balance.json`
/// (see config.zig); tests use the frozen fixture in fixtures.zig.
pub const Balance = struct {
    /// Agent units released per elemental dispense slot in a non-recipe combo.
    units_per_slot: u32,
    /// Medicine contributed per elemental medicine slot in a non-recipe combo.
    /// Medicine carries the combo's current element; colorless slots are wasted.
    medicine_per_slot: u32,
    /// Hunger cost per slime unit consumed (any unit — never healable).
    hunger_cost_normal: u32,
    /// EXTRA hunger per un-neutralized modified unit consumed (healable portion).
    hunger_cost_modified_extra: u32,
    /// Portion (0.0–1.0) of transmuted modified slime that SURVIVES as
    /// neutralized slime; the rest is destroyed outright (less to eat, less
    /// hunger, less score).  Rounded down per transmute call per color, so
    /// e.g. 0.5 on a single unit leaves nothing.  1.0 = everything survives.
    neutralize_residue_mult: f32,
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
