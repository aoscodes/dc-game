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

/// All designer-tunable balance numbers.  Loaded from `data/balance.json`
/// (see config.zig); tests use the frozen fixture in fixtures.zig.
pub const Balance = struct {
    /// Spells (combos) each player may commit per round.  The cast window is
    /// round_duration / casts_per_round; the pending combo commits when the
    /// window closes.
    casts_per_round: u8,
    /// Agent units released per elemental dispense slot in a non-recipe combo.
    units_per_slot: u32,
    /// Medicine contributed per elemental medicine slot in a non-recipe combo.
    /// Medicine carries the combo's current element; colorless slots are wasted.
    medicine_per_slot: u32,
    /// Hunger cost per slime unit consumed (any unit — never healable).
    hunger_cost_normal: u32,
    /// EXTRA hunger per un-neutralized modified unit consumed (healable portion).
    hunger_cost_modified_extra: u32,
    /// Round length in seconds unless overridden with --round-duration.
    /// Classic mode only.
    round_duration_default_s: f32,
    /// Realtime mode: slime units eaten per second PER LIL GUY (one Lil Guy
    /// per connected player) — the team eats at rate × players.
    eat_rate_units_per_s: f32,
    /// Realtime mode: length of the repeating cast window in milliseconds.
    /// Submitted spells batch-convert (recipes → medicine → transmute) when
    /// the window closes; team recipes require distinct players submitting
    /// in the SAME window.
    cast_window_ms: u32,
    player_recipes: []const PlayerRecipe,
    team_recipes: []const TeamRecipe,
};
