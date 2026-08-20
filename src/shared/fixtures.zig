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

/// Fixture move indices, by label.  A move's index is its wire identity and the
/// way group components are named, so tests refer to these instead of counting
/// table rows by hand.
pub const POKE: u8 = 0;
pub const SWEEP: u8 = 1;
pub const BLOCK: u8 = 2;
pub const CROSS: u8 = 3;
pub const WEDGE: u8 = 4;
pub const TRICKLE: u8 = 5;
pub const DELUGE: u8 = 6;

pub const player_recipes = [_]balance.PlayerRecipe{
    // The bread-and-butter aim: one cell, one tier.
    .{
        .label = "poke",
        .shape = shape(&.{"#"}),
    },
    // A horizontal sweep of three.
    .{
        .label = "sweep",
        .shape = shape(&.{"###"}),
    },
    // The big one: a full 3x3 block.
    .{
        .label = "block",
        .shape = shape(&.{ "###", "###", "###" }),
    },
    // Same five cells as `plus`, rotated: orientation is authored, not derived.
    .{
        .label = "cross",
        .shape = shape(&.{ "#.#", ".#.", "#.#" }),
    },
    // A downward triangle.
    .{
        .label = "wedge",
        .shape = shape(&.{ "###", ".#." }),
    },
    // The free move: no charges at all, so tests can act with a bankrupt pool
    // and the economy has a floor a team can never fall through.
    .{
        .label = "trickle",
        .shape = shape(&.{"#"}),
        .cost = 0,
    },
    // Deliberately expensive: exercises "the pool cannot afford this".
    .{
        .label = "deluge",
        .shape = shape(&.{ "###", "###", "###" }),
        .cost = 9,
    },
};

/// Fixture group indices, by label.
pub const TWIN_BLOOM: u8 = 0;
pub const CROSSFIRE: u8 = 1;
pub const TRIAD: u8 = 2;

pub const team_recipes = [_]balance.TeamRecipe{
    // Two players poke the same cell; together they clear a plus far bigger
    // than either could alone.
    .{
        .label = "twin_bloom",
        .components = &.{ POKE, POKE },
        .shape = shape(&.{ "..#..", ".###.", "#####", ".###.", "..#.." }),
        .cost = 4,
    },
    // Asymmetric: one player brings the line, the other the block.
    .{
        .label = "crossfire",
        .components = &.{ SWEEP, BLOCK },
        .shape = shape(&.{ "..#..", "..#..", "#####", "..#..", "..#.." }),
    },
    // A three-player group whose bag CONTAINS twin_bloom's, listed after it: the
    // fixture for "an earlier group shadows a later one" (see complete_group).
    // Deliberately unaffordable on a near-empty pool, so the solo-fallback path
    // has something to fall back from.
    .{
        .label = "triad",
        .components = &.{ POKE, POKE, POKE },
        .shape = shape(&.{ "#####", "#####", "#####" }),
        .cost = 12,
    },
};

/// Default fixture encounter.  Totals: 112 units — 30 neutral, 80 hazard and 2
/// specials.  Every unit eaten costs 1 hunger against a 200 bar, so hunger is
/// deliberately NOT the binding constraint here: the fixture exists to exercise
/// the path and the charge economy.  The 6×10 fixture grid holds 60, so 52
/// units always start in the reservoir, and the 2 specials guarantee tests meet
/// a cell nothing can remove.
pub const encounters = [_]enc.Encounter{
    .{
        .label = "slime_feast_01",
        .hunger_max = 200,
        // Enough charges to matter but not enough to ignore: 40 charges against
        // 80 hazards means the team cannot simply defuse everything.
        .charges = 40,
        .slime = .{ .tiered = .{ 35, 25, 20 }, .neutral = 30, .special = 2 },
    },
};

/// The priced move table: `player_recipes` without the free `trickle` (and
/// without `deluge`, which follows it).
///
/// `trickle` costs 0, so under `test_config` the cheapest move is free and the
/// team can ALWAYS act — which is exactly why the fixture has it, and exactly
/// why `out_of_charges` can never fire there.  Tests about running the pool dry
/// need a table with a floor above zero, and this is it.
///
/// The indices POKE..WEDGE are unchanged, so the group table (which names
/// components by index) is shared verbatim.
pub const priced_recipes = player_recipes[0 .. WEDGE + 1];

pub const test_config = config.Config{
    .balance = .{
        .hunger_cost_normal = 1,
        // 6×10 = 60 on-grid cells; the fixture encounter's 112 units mean the
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

/// `test_config` with a floor under the move table: identical in every other
/// respect, so a test can swap it in and change exactly one thing about the
/// world — whether the team can act on an empty pool.
pub const priced_config = config.Config{
    .balance = .{
        .hunger_cost_normal = test_config.balance.hunger_cost_normal,
        .slime_grid = test_config.balance.slime_grid,
        .casts_per_turn = test_config.balance.casts_per_turn,
        .player_recipes = priced_recipes,
        .team_recipes = &team_recipes,
    },
    .encounters = .{
        .encounters = &encounters,
        .default_index = 0,
    },
};
