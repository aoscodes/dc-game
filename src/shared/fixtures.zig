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

/// A shape from authored rows, for fixtures only (config.zig does this at load).
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

pub fn shape(comptime rows: []const []const u8) balance.Shape {
    return Shaped(rows).shape;
}

const D = c.ComboSlot{ .action = .dispense };
const M = c.ComboSlot{ .action = .medicine };

pub const player_recipes = [_]balance.PlayerRecipe{
    // The bread-and-butter aim: one cell, one tier.
    .{
        .label = "poke",
        .pattern = mk(&.{D}),
        .shape = shape(&.{"#"}),
    },
    // A horizontal sweep of three.
    .{
        .label = "sweep",
        .pattern = mk(&.{ D, D }),
        .shape = shape(&.{"###"}),
    },
    // The big one: a full 3x3 block.
    .{
        .label = "block",
        .pattern = mk(&.{ D, D, D }),
        .shape = shape(&.{ "###", "###", "###" }),
    },
    // Same five cells as `plus`, rotated: orientation is authored, not derived.
    .{
        .label = "cross",
        .pattern = mk(&.{ D, M, D }),
        .shape = shape(&.{ "#.#", ".#.", "#.#" }),
    },
    // A downward triangle.
    .{
        .label = "wedge",
        .pattern = mk(&.{ D, D, M }),
        .shape = shape(&.{ "###", ".#." }),
    },
    // Pure heal: minimal footprint, real medicine.
    .{
        .label = "tonic",
        .pattern = mk(&.{ M, M }),
        .shape = shape(&.{"#"}),
        .medicine = .{ .medicine = .{ 6, 6, 6 } },
    },
    // Tier-targeted medicine: only heals what red slime did.
    .{
        .label = "red_tonic",
        .pattern = mk(&.{ M, M, M }),
        .shape = shape(&.{"#"}),
        .medicine = .{ .medicine = .{ 10, 0, 0 } },
    },
};

pub const team_recipes = [_]balance.TeamRecipe{
    // Two players each cast [dispense, medicine]; together they clear a plus
    // far bigger than either could alone.
    .{
        .label = "twin_bloom",
        .patterns = &.{
            mk(&.{ D, M }),
            mk(&.{ D, M }),
        },
        .shape = shape(&.{ "..#..", ".###.", "#####", ".###.", "..#.." }),
        .medicine = .{ .medicine = .{ 4, 4, 4 } },
    },
    // Asymmetric: one player brings the line, the other the column.
    .{
        .label = "crossfire",
        .patterns = &.{
            mk(&.{ M, D }),
            mk(&.{ M, D, D }),
        },
        .shape = shape(&.{ "..#..", "..#..", "#####", "..#..", "..#.." }),
    },
};

/// Default fixture encounter.  Totals: 110 units (30 neutral + 80 hazard).
/// Every unit costs 1 normal hunger → 110; the 80 hazards add 2 extra each
/// → 270 if nothing is ever neutralized (a loss against hunger_max 200).
/// Defusing everything keeps it at 110, a comfortable clear.  The 6×10
/// fixture grid holds 60, so 50 units always start in the reservoir.
pub const encounters = [_]enc.Encounter{
    .{
        .label = "slime_feast_01",
        .hunger_max = 200,
        .slime = .{ .tiered = .{ 35, 25, 20 }, .neutral = 30 },
    },
};

pub const test_config = config.Config{
    .balance = .{
        .hunger_cost_normal = 1,
        .hunger_cost_hazard_extra = 2,
        // 6×10 = 60 on-grid cells; the fixture encounter's 110 units mean the
        // reservoir always starts non-empty (exercises refill paths).
        .slime_grid = .{ .rows = 6, .cols = 10 },
        // 3 casts per player per turn: enough for a team recipe plus a solo
        // follow-up, so tests can exercise budget exhaustion in one turn.
        .casts_per_turn = 3,
        .player_recipes = &player_recipes,
        .team_recipes = &team_recipes,
    },
    .encounters = .{
        .encounters = &encounters,
        .default_index = 0,
    },
};
