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
/// neutralizer specials.  Every unit eaten costs 1 hunger against a 200 bar
/// for the usual two-player test session (2 × the fixture `hunger_base` of
/// 100), so hunger is deliberately NOT the binding constraint here: the
/// fixture exists to exercise the path and the charge economy.  The 6×10
/// fixture grid holds 60, so 52 units always start in the reservoir, and the
/// 2 neutralizers guarantee tests meet a cell nothing can remove.  No eggs:
/// hatch-path tests seed their own so the baseline totals stay hatch-free.
pub const encounters = [_]enc.Encounter{
    .{
        .label = "slime_feast_01",
        // Enough charges to matter but not enough to ignore: 40 charges against
        // 80 hazards means the team cannot simply defuse everything.
        .charges = 40,
        .slime = .{ .tiered = .{ 35, 25, 20 }, .neutral = 30, .special = .{ 2, 0, 0, 0, 0 } },
    },
};

/// The priced move table: `player_recipes` without the free `trickle` (and
/// without `deluge`, which follows it).
///
/// `trickle` costs 0, so under `test_config` the cheapest move is free and the
/// team can NEVER be broke — which is exactly why the fixture has it.  Tests
/// about running the pool dry (cast presses becoming passes) need a table
/// with a floor above zero, and this is it.
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
        // Realtime pacing, pinned small and round so tests advance time in
        // tidy steps: a bite each simulated second, a 100ms cast cooldown,
        // and a 500ms team-recipe window.
        .bite_interval_ms = 1000,
        .bite_speedup_per_guy_pct = 15,
        .bite_speedup_per_baby_pct = 5,
        .cast_cooldown_ms = 100,
        .team_window_ms = 500,
        // Appetite → hunger formula, pinned: an appetite-0 player contributes
        // 100, so the usual two-player test session gets the historical 200
        // bar and hunger stays a non-binding 112-units-vs-200 affair.
        .hunger_base = 100,
        .appetite_scale = 5,
        .hunger_player_cap = 500,
        .player_recipes = &player_recipes,
        .team_recipes = &team_recipes,
    },
    .encounters = .{
        .encounters = &encounters,
        .default_index = 0,
    },
};

/// `test_config` with the post-bite settle window switched ON, and identical
/// in every other respect — so a test can change exactly one thing about the
/// world: whether casting is refused while the Lil Guys chew.
///
/// 200ms is deliberately DOUBLE the fixture's 100ms cast cooldown, so a test
/// can tell the two refusals apart by walking the clock between them: past
/// the cooldown but still inside the window.  It also sits well under the
/// 869ms two-player bite interval, leaving playable time between meals.
///
/// `test_config` itself leaves the window at 0 (the shipped default), so
/// every test that is not about this feature casts through a settle exactly
/// as it always did.
pub const settling_config = blk: {
    var cfg = test_config;
    cfg.balance.settle_lockout_ms = SETTLE_LOCKOUT_MS;
    break :blk cfg;
};

/// The settle window `settling_config` pins, named so tests can walk the
/// clock relative to it instead of against a magic number.
pub const SETTLE_LOCKOUT_MS: u32 = 200;

/// `test_config` with a floor under the move table: identical in every other
/// respect, so a test can swap it in and change exactly one thing about the
/// world — whether the team can act on an empty pool.
pub const priced_config = config.Config{
    .balance = .{
        .hunger_cost_normal = test_config.balance.hunger_cost_normal,
        .slime_grid = test_config.balance.slime_grid,
        .bite_interval_ms = test_config.balance.bite_interval_ms,
        .bite_speedup_per_guy_pct = test_config.balance.bite_speedup_per_guy_pct,
        .bite_speedup_per_baby_pct = test_config.balance.bite_speedup_per_baby_pct,
        .cast_cooldown_ms = test_config.balance.cast_cooldown_ms,
        .team_window_ms = test_config.balance.team_window_ms,
        .hunger_base = test_config.balance.hunger_base,
        .appetite_scale = test_config.balance.appetite_scale,
        .hunger_player_cap = test_config.balance.hunger_player_cap,
        .player_recipes = priced_recipes,
        .team_recipes = &team_recipes,
    },
    .encounters = .{
        .encounters = &encounters,
        .default_index = 0,
    },
};
