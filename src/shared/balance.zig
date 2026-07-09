//! Tuning tables for the Slime Feast encounter.
//!
//! Everything gameplay-numeric lives here so designers can tune without
//! touching resolution logic:
//!   - flat per-slot conversion rates (non-recipe combos)
//!   - hunger costs for neutral vs modified slime
//!   - hard-coded recipe tables (player + team)
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

// ---------------------------------------------------------------------------
// Flat conversion + hunger costs — TODO tune (arbitrary starting values)
// ---------------------------------------------------------------------------

/// Spells (combos) each player may commit per round.  The cast window is
/// round_duration / CASTS_PER_ROUND; the pending combo commits when the
/// window closes.
pub const CASTS_PER_ROUND: u8 = 3;

/// Agent units released per elemental dispense slot in a non-recipe combo.
pub const UNITS_PER_SLOT: u32 = 5;
/// Medicine contributed per elemental medicine slot in a non-recipe combo.
/// Medicine carries the combo's current element; colorless slots are wasted.
pub const MEDICINE_PER_SLOT: u32 = 3;
/// Hunger cost per slime unit consumed (any unit — never healable).
pub const HUNGER_COST_NORMAL: u32 = 1;
/// EXTRA hunger per un-neutralized modified unit consumed (healable portion).
pub const HUNGER_COST_MODIFIED_EXTRA: u32 = 2;

// ---------------------------------------------------------------------------
// Recipes
// ---------------------------------------------------------------------------

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

const mk = c.make_combo;

// Starter recipe set — TODO tune with playtesting.
pub const player_recipes = [_]PlayerRecipe{
    // Mono-color burst: beats flat conversion (3 slots × 5 = 15 → 20).
    .{
        .label = "crimson_flood",
        .pattern = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }),
        .output = .{ .units = .{ 20, 0, 0, 0 } },
    },
    .{
        .label = "verdant_flood",
        .pattern = mk(&.{ .{ .element = .earth }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }),
        .output = .{ .units = .{ 0, 20, 0, 0 } },
    },
    .{
        .label = "gale_flood",
        .pattern = mk(&.{ .{ .element = .wind }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }),
        .output = .{ .units = .{ 0, 0, 20, 0 } },
    },
    .{
        .label = "tide_flood",
        .pattern = mk(&.{ .{ .element = .water }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }),
        .output = .{ .units = .{ 0, 0, 0, 20 } },
    },
    // Multi-color mist: covers every color at once.
    .{
        .label = "prism_mist",
        .pattern = mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .element = .water }, .{ .action = .dispense } }),
        .output = .{ .units = .{ 6, 6, 6, 6 } },
    },
    // Concentrated water medicine: beats flat conversion (2 slots × 3 = 6 → 10).
    .{
        .label = "panacea",
        .pattern = mk(&.{ .{ .element = .water }, .{ .action = .medicine }, .{ .action = .medicine } }),
        .output = .{ .medicine = .{ 0, 0, 0, 10 } },
    },
};

pub const team_recipes = [_]TeamRecipe{
    // Two players each cast [fire, dispense, dispense] in the same round.
    .{
        .label = "twin_flames",
        .patterns = &.{
            mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } }),
            mk(&.{ .{ .element = .fire }, .{ .action = .dispense }, .{ .action = .dispense } }),
        },
        .output = .{ .units = .{ 30, 0, 0, 0 }, .medicine = .{ 20, 0, 0, 0 } },
    },
    // One dispenses water, one dispenses earth — combined downpour.
    .{
        .label = "mudslide",
        .patterns = &.{
            mk(&.{ .{ .element = .water }, .{ .action = .dispense }, .{ .action = .dispense } }),
            mk(&.{ .{ .element = .earth }, .{ .action = .dispense }, .{ .action = .dispense } }),
        },
        .output = .{ .units = .{ 0, 40, 0, 40 } },
    },
};
