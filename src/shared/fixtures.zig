//! Frozen test-fixture configuration.
//!
//! A comptime copy of a known-good balance/encounter set for unit and
//! integration tests.  Tests use this instead of the shipped JSON so that
//! designers tuning `data/*.json` cannot break logic tests; the shipped
//! files themselves are parse/validation-tested in config.zig.
//!
//! Do NOT reference from production code paths.

const c = @import("components.zig");
const balance = @import("balance.zig");
const enc = @import("encounter.zig");
const config = @import("config.zig");

const mk = c.make_combo;

pub const player_recipes = [_]balance.PlayerRecipe{
    // Mono-color burst: beats flat conversion (3 slots × 5 = 15 → 20).
    .{
        .label = "crimson_flood",
        .pattern = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }),
        .output = .{ .units = .{ 20, 0, 0, 0 } },
    },
    .{
        .label = "verdant_flood",
        .pattern = mk(&.{ .{ .element = .green }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }),
        .output = .{ .units = .{ 0, 20, 0, 0 } },
    },
    .{
        .label = "gale_flood",
        .pattern = mk(&.{ .{ .element = .yellow }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }),
        .output = .{ .units = .{ 0, 0, 20, 0 } },
    },
    .{
        .label = "tide_flood",
        .pattern = mk(&.{ .{ .element = .blue }, .{ .action = .dispense }, .{ .action = .dispense }, .{ .action = .dispense } }),
        .output = .{ .units = .{ 0, 0, 0, 20 } },
    },
    // Multi-color mist: covers every color at once.
    .{
        .label = "prism_mist",
        .pattern = mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .element = .blue }, .{ .action = .dispense } }),
        .output = .{ .units = .{ 6, 6, 6, 6 } },
    },
    // Concentrated blue medicine: beats flat conversion (2 slots × 3 = 6 → 10).
    .{
        .label = "panacea",
        .pattern = mk(&.{ .{ .element = .blue }, .{ .action = .medicine }, .{ .action = .medicine } }),
        .output = .{ .medicine = .{ 0, 0, 0, 10 } },
    },
};

pub const team_recipes = [_]balance.TeamRecipe{
    // Two players each cast [red, dispense, dispense] in the same round.
    .{
        .label = "twin_flames",
        .patterns = &.{
            mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } }),
            mk(&.{ .{ .element = .red }, .{ .action = .dispense }, .{ .action = .dispense } }),
        },
        .output = .{ .units = .{ 30, 0, 0, 0 }, .medicine = .{ 20, 0, 0, 0 } },
    },
    // One dispenses blue, one dispenses green — combined downpour.
    .{
        .label = "mudslide",
        .patterns = &.{
            mk(&.{ .{ .element = .blue }, .{ .action = .dispense }, .{ .action = .dispense } }),
            mk(&.{ .{ .element = .green }, .{ .action = .dispense }, .{ .action = .dispense } }),
        },
        .output = .{ .units = .{ 0, 40, 0, 40 } },
    },
};

/// 3-zone default fixture encounter.  Totals: 110 units → 110 normal hunger;
/// fully un-neutralized modified slime adds 160 extra → 270 (fail without
/// play); full neutralization keeps it at 110 (comfortable clear).
pub const encounters = [_]enc.Encounter{
    .{
        .label = "slime_feast_01",
        .hunger_max = 200,
        .zones = &[_]c.ZoneDef{
            .{ .modified = .{ 10, 5, 0, 0 }, .neutral = 15 },
            .{ .modified = .{ 10, 10, 5, 0 }, .neutral = 10 },
            .{ .modified = .{ 15, 10, 10, 5 }, .neutral = 5 },
        },
    },
};

pub const test_config = config.Config{
    .balance = .{
        .casts_per_round = 3,
        .units_per_slot = 5,
        .medicine_per_slot = 3,
        .hunger_cost_normal = 1,
        .hunger_cost_modified_extra = 2,
        .neutralize_residue_mult = 1.0,
        .round_duration_default_s = 15.0,
        .eat_rate_units_per_s = 2.0,
        .cast_buffer_ms = 500,
        .cast_lock_ms = 500,
        .player_recipes = &player_recipes,
        .team_recipes = &team_recipes,
    },
    .encounters = .{
        .encounters = &encounters,
        .default_index = 0,
    },
};
