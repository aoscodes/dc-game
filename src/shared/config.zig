//! Runtime game configuration: parses `data/balance.json` and
//! `data/encounters.json` into the typed Balance / EncounterSet structures.
//!
//! The server loads the files once at process start (`load`); the bridge
//! spawns one server per lobby, so every new lobby picks up fresh data —
//! designers tune the JSON and open a new lobby, no rebuild required.
//! The browser fetches `data/balance.json` directly, so both sides share a
//! single source of truth (wire messages reference recipes by table index,
//! in file order).
//!
//! All inputs are validated here at the boundary; the rest of the game
//! operates on the typed structures and never re-checks.  Unknown JSON
//! fields are rejected so typos fail loudly instead of silently defaulting.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("components.zig");
const balance = @import("balance.zig");
const enc = @import("encounter.zig");
const protocol = @import("protocol.zig");
const game_logic = @import("game_logic.zig");

const log = std.log.scoped(.config);

/// Validation diagnostic: error-level in production so designers see exactly
/// what to fix; warn-level under test (the test runner fails on error logs,
/// and rejection tests intentionally trigger these).
fn fail(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) log.warn(fmt, args) else log.err(fmt, args);
}

pub const BALANCE_FILE = "balance.json";
pub const ENCOUNTERS_FILE = "encounters.json";
/// Sanity cap on data file size.
pub const MAX_FILE_BYTES = 1024 * 1024;

/// The fully-validated game configuration.  Slices point into the arena of
/// the owning `Loaded` (or into static fixture data in tests).
pub const Config = struct {
    balance: balance.Balance,
    encounters: enc.EncounterSet,
};

/// A Config plus the arena that owns all of its slices.
pub const Loaded = struct {
    arena: *std.heap.ArenaAllocator,
    config: Config,

    pub fn deinit(self: *Loaded) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }
};

pub const ConfigError = error{
    InvalidBalanceJson,
    InvalidEncountersJson,
    InvalidBiteInterval,
    InvalidBiteSpeedup,
    InvalidTeamWindow,
    InvalidCharges,
    InvalidSlimeGrid,
    TooManyRecipes,
    InvalidGroupSize,
    UnknownMoveLabel,
    InvalidShapeSize,
    RaggedShape,
    EmptyShape,
    DuplicateLabel,
    EmptyLabel,
    LabelTooLong,
    NoEncounters,
    NoZones,
    TooManyZones,
    NoSlime,
    InvalidHungerFormula,
    InvalidMatchLen,
    InvalidFeastColumns,
    UnsupportedActivation,
    UnknownDefaultEncounter,
};

/// Read and parse both data files from `data_dir` (relative to cwd unless
/// absolute).  Logs a precise reason before returning any error.
pub fn load(gpa: std.mem.Allocator, data_dir: []const u8) !Loaded {
    var dir = std.fs.cwd().openDir(data_dir, .{}) catch |err| {
        fail("cannot open data dir '{s}': {s}", .{ data_dir, @errorName(err) });
        return err;
    };
    defer dir.close();

    const bal_bytes = dir.readFileAlloc(gpa, BALANCE_FILE, MAX_FILE_BYTES) catch |err| {
        fail("cannot read {s}/{s}: {s}", .{ data_dir, BALANCE_FILE, @errorName(err) });
        return err;
    };
    defer gpa.free(bal_bytes);

    const enc_bytes = dir.readFileAlloc(gpa, ENCOUNTERS_FILE, MAX_FILE_BYTES) catch |err| {
        fail("cannot read {s}/{s}: {s}", .{ data_dir, ENCOUNTERS_FILE, @errorName(err) });
        return err;
    };
    defer gpa.free(enc_bytes);

    return parse(gpa, bal_bytes, enc_bytes);
}

/// Parse + validate both JSON documents.  The returned Loaded owns copies of
/// everything; the input slices may be freed afterwards.
pub fn parse(
    gpa: std.mem.Allocator,
    balance_json: []const u8,
    encounters_json: []const u8,
) !Loaded {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_ptr.deinit();
    const a = arena_ptr.allocator();

    const bal = try parse_balance(a, balance_json);
    const encounters = try parse_encounters(a, encounters_json);

    return .{
        .arena = arena_ptr,
        .config = .{ .balance = bal, .encounters = encounters },
    };
}

// ---------------------------------------------------------------------------
// Raw JSON schema (per-color values are sparse named fields; missing = 0)
// ---------------------------------------------------------------------------

// The Colors* structs map named fields onto Element-ordinal arrays; guard
// the assumed ordering at compile time.
// The tier JSON field order must match the Tier ordinals, since the loader
// converts named fields into ordinal-indexed arrays.
comptime {
    std.debug.assert(@intFromEnum(c.Tier.red) == 0);
    std.debug.assert(@intFromEnum(c.Tier.yellow) == 1);
    std.debug.assert(@intFromEnum(c.Tier.green) == 2);
    // The special-kind JSON structs likewise map named fields onto
    // SpecialKind-ordinal arrays.
    std.debug.assert(@intFromEnum(c.SpecialKind.neutralizer) == 0);
    std.debug.assert(@intFromEnum(c.SpecialKind.egg) == 1);
}

const TiersU16Json = struct { red: u16 = 0, yellow: u16 = 0, green: u16 = 0 };

/// Tuning knobs for one special kind (see balance.SpecialTuning).
const SpecialTuningJson = struct {
    match_len: u8 = balance.DEFAULT_MATCH_LEN,
    back_ranks_only: bool = false,
    guaranteed_at_start: bool = false,
    charge_refill: u16 = balance.DEFAULT_CHARGE_REFILL,
    explode_rocks_only: bool = false,
    bite_costs_hunger: bool = false,
    /// Parsed straight into the enum: std.json matches the JSON string to a
    /// tag name, so `"eat"` / `"cast"` / `"eatcast"` validate themselves and
    /// anything else fails the parse with the file named.
    activate_on: balance.Activation = .eat,
};

/// Per-kind tuning table.  Every kind defaults, so `"specials"` and any kind
/// inside it are strictly opt-in.
const SpecialsJson = struct {
    neutralizer: SpecialTuningJson = .{},
    egg: SpecialTuningJson = .{},
    rock: SpecialTuningJson = .{},
    canister: SpecialTuningJson = .{},
    bomb: SpecialTuningJson = .{},
};

/// Per-kind special unit counts for one zone.  An OBJECT, not a scalar: the
/// old `"special": 3` form named no kind and is rejected by the JSON parser,
/// forcing configs to say which specials they mean.
const SpecialCountsJson = struct {
    neutralizer: u16 = 0,
    egg: u16 = 0,
    rock: u16 = 0,
    canister: u16 = 0,
    bomb: u16 = 0,
};

const PlayerRecipeJson = struct {
    label: []const u8,
    /// Footprint rows of `#` (covered) and any other char (not covered),
    /// e.g. ["###","###","###"] for a 3x3 block.
    shape: []const []const u8,
    /// Charges this recipe costs the shared pool.  Absent = DEFAULT_RECIPE_COST;
    /// 0 is legal and means a free move.
    cost: u16 = balance.DEFAULT_RECIPE_COST,
};

const TeamRecipeJson = struct {
    label: []const u8,
    /// The bag of player-move LABELS this group needs, one per contributor,
    /// e.g. ["poke","poke"].  Labels (not indices) so reordering the move table
    /// cannot silently repoint a group at different moves.  Repeats are
    /// meaningful: two "poke" entries mean two different players each poking.
    moves: []const []const u8,
    shape: []const []const u8,
    /// Charges per FIRING of the group, not per contributing player.
    cost: u16 = balance.DEFAULT_RECIPE_COST,
};

const SlimeGridJson = struct {
    rows: u8,
    cols: u8,
};

const BalanceJson = struct {
    hunger_cost_normal: u32,
    // Deliberately unvalidated beyond its type.  A chain cannot outrun the
    // grid — every link empties a cell — and the largest grid (256 cells)
    // can supply more links than a u8 can count, so every value that fits
    // here is one the board may or may not reach: none of them is out of
    // range, and a bounds check would be one that never fires.  The cap
    // being narrower than the board is exactly why slime.stamp counts depth
    // in a wider integer; see the note on Balance.max_chain_depth.
    max_chain_depth: u8 = balance.DEFAULT_MAX_CHAIN_DEPTH,
    blast_chains: bool = false,
    /// Slime grid dimensions; defaulted so pre-grid configs keep validating.
    slime_grid: SlimeGridJson = .{
        .rows = balance.DEFAULT_SLIME_GRID.rows,
        .cols = balance.DEFAULT_SLIME_GRID.cols,
    },
    /// Realtime pacing knobs (see balance.Balance); defaulted so configs
    /// written before the realtime loop keep validating.
    bite_interval_ms: u32 = balance.DEFAULT_BITE_INTERVAL_MS,
    bite_speedup_per_guy_pct: u16 = balance.DEFAULT_BITE_SPEEDUP_PER_GUY_PCT,
    bite_speedup_per_baby_pct: u16 = balance.DEFAULT_BITE_SPEEDUP_PER_BABY_PCT,
    cast_cooldown_ms: u32 = balance.DEFAULT_CAST_COOLDOWN_MS,
    team_window_ms: u32 = balance.DEFAULT_TEAM_WINDOW_MS,
    /// Appetite → hunger formula knobs (see game_logic.player_hunger).
    /// Defaulted so configs written before appetite keep validating.
    hunger_base: u16 = balance.DEFAULT_HUNGER_BASE,
    appetite_scale: u16 = balance.DEFAULT_APPETITE_SCALE,
    hunger_player_cap: u16 = balance.DEFAULT_HUNGER_PLAYER_CAP,
    /// Hunger capacity per baby Lil Guy; defaulted so configs written before
    /// babies keep validating.
    baby_hunger: u16 = balance.DEFAULT_BABY_HUNGER,
    /// Bite width knobs (see balance.Balance.feast_width); defaulted so
    /// configs written before the column bite keep validating.
    feast_columns: u8 = balance.DEFAULT_FEAST_COLUMNS,
    feast_columns_per_guy: u8 = balance.DEFAULT_FEAST_COLUMNS_PER_GUY,
    /// When true (the default), no special kind ever spawns in column 0 —
    /// the feast's door.  Defaulted so older configs keep validating.
    specials_avoid_door_column: bool = true,
    /// Per-special-kind tuning; defaulted so configs written before special
    /// kinds keep validating.
    specials: SpecialsJson = .{},
    player_recipes: []const PlayerRecipeJson,
    team_recipes: []const TeamRecipeJson,
};

/// One slime bundle.  Historically one per round ("zone"); now purely an
/// additive slice of the encounter's single slime total.
const ZoneJson = struct {
    /// Hazard slime per difficulty tier.
    tiered: TiersU16Json = .{},
    neutral: u16 = 0,
    /// Special units per kind (components.SlimeCell.special).  Absent = none,
    /// so configs without specials stay valid and specials are strictly
    /// opt-in.
    special: SpecialCountsJson = .{},
};

const EncounterJson = struct {
    label: []const u8,
    /// Charges the shared pool starts with; defaulted so configs written before
    /// the charge economy keep validating.
    charges: u32 = enc.DEFAULT_CHARGES,
    /// Slime bundles, SUMMED into the encounter's total slime.  Named `zones`
    /// for back-compatibility with saved designer configs (std.json rejects
    /// unknown fields, so the name cannot simply change).
    zones: []const ZoneJson,
};

const EncountersJson = struct {
    default: []const u8,
    encounters: []const EncounterJson,
};

/// Force string allocation so parsed values never alias the input buffer.
const json_opts = std.json.ParseOptions{ .allocate = .alloc_always };

// ---------------------------------------------------------------------------
// Conversion + validation
// ---------------------------------------------------------------------------

fn parse_balance(a: std.mem.Allocator, bytes: []const u8) !balance.Balance {
    const raw = std.json.parseFromSliceLeaky(BalanceJson, a, bytes, json_opts) catch |err| {
        fail("{s}: JSON parse failed: {s}", .{ BALANCE_FILE, @errorName(err) });
        return ConfigError.InvalidBalanceJson;
    };

    // A bite interval under 100ms would chew faster than the server's tick
    // (and any human) can follow — always a units mistake (seconds vs ms).
    if (raw.bite_interval_ms < 100) {
        fail("{s}: bite_interval_ms {} must be >= 100", .{ BALANCE_FILE, raw.bite_interval_ms });
        return ConfigError.InvalidBiteInterval;
    }
    // 1000% per head is already an 11x speedup from one extra guy; anything
    // past that is a typo, not a tuning.
    if (raw.bite_speedup_per_guy_pct > 1000 or raw.bite_speedup_per_baby_pct > 1000) {
        fail("{s}: bite speedup pcts (guy={}, baby={}) must be 0..1000", .{
            BALANCE_FILE, raw.bite_speedup_per_guy_pct, raw.bite_speedup_per_baby_pct,
        });
        return ConfigError.InvalidBiteSpeedup;
    }
    // A window of 0 could never be met — two casts can't land at the same
    // instant — so every team recipe would be dead data.
    if (raw.team_window_ms < 1) {
        fail("{s}: team_window_ms must be >= 1", .{BALANCE_FILE});
        return ConfigError.InvalidTeamWindow;
    }
    if (raw.slime_grid.rows < 1 or raw.slime_grid.rows > c.MAX_GRID_ROWS or
        raw.slime_grid.cols < 1 or raw.slime_grid.cols > c.MAX_GRID_COLS)
    {
        fail("{s}: slime_grid {}x{} outside 1..{}x1..{}", .{
            BALANCE_FILE,        raw.slime_grid.rows, raw.slime_grid.cols,
            c.MAX_GRID_ROWS, c.MAX_GRID_COLS,
        });
        return ConfigError.InvalidSlimeGrid;
    }
    // A base of 0 would let a lone appetite-0 player contribute nothing, so
    // the bar could start at 0 and hunger could never end the game; a cap
    // under the base would silently pay every player less than the base
    // promises.  Both are always config mistakes.
    if (raw.hunger_base == 0 or raw.hunger_player_cap < raw.hunger_base) {
        fail("{s}: need hunger_base >= 1 and hunger_player_cap >= hunger_base (got base={} cap={})", .{
            BALANCE_FILE, raw.hunger_base, raw.hunger_player_cap,
        });
        return ConfigError.InvalidHungerFormula;
    }
    // A bite of 0 columns would eat nothing every turn (the game could only
    // end by running the hunger clock via downgrades that never happen), and
    // one wider than the grid promises columns that do not exist.
    // `feast_columns_per_guy` is unbounded above: `feast_width` clamps the
    // total at the grid, so a huge per-guy bonus just means "whole board".
    if (raw.feast_columns < 1 or raw.feast_columns > raw.slime_grid.cols) {
        fail("{s}: feast_columns {} outside 1..{} (grid cols)", .{
            BALANCE_FILE, raw.feast_columns, raw.slime_grid.cols,
        });
        return ConfigError.InvalidFeastColumns;
    }
    // A match_len of 0/1 would fire on every lone special, and one longer
    // than the grid's longest line could never fire at all — both are always
    // config mistakes.
    // SpecialsJson's field names mirror the SpecialKind tags exactly, so the
    // table builds itself — a new kind only has to be added to SpecialsJson
    // for the compiler to wire it through.
    var specials: [c.SpecialKind.size]balance.SpecialTuning = undefined;
    inline for (@typeInfo(c.SpecialKind).@"enum".fields) |f| {
        const t = @field(raw.specials, f.name);
        specials[f.value] = .{
            .match_len = t.match_len,
            .back_ranks_only = t.back_ranks_only,
            .guaranteed_at_start = t.guaranteed_at_start,
            .charge_refill = t.charge_refill,
            .explode_rocks_only = t.explode_rocks_only,
            .bite_costs_hunger = t.bite_costs_hunger,
            .activate_on = t.activate_on,
        };
    }
    const longest_line = @max(raw.slime_grid.rows, raw.slime_grid.cols);
    for (specials, 0..) |tuning, k| {
        if (tuning.match_len < 2 or tuning.match_len > longest_line) {
            fail("{s}: specials.{s} match_len {} outside 2..{} (grid's longest line)", .{
                BALANCE_FILE,
                @tagName(@as(c.SpecialKind, @enumFromInt(k))),
                tuning.match_len,
                longest_line,
            });
            return ConfigError.InvalidMatchLen;
        }
        // Cast activation is wired for the two kinds whose effects need
        // nothing from the session: the neutralizer's block and the bomb's
        // blast both resolve entirely inside the field.  The others are
        // refused rather than half-supported -- a cast-hatched egg would
        // need the session PRNG to roll the baby's type and a cast-drunk
        // canister would need the team's charge pool, neither of which the
        // stamp path can reach.  The rock has no effect to fire at all: a
        // cast BREAKS it (see slime.apply_shape).
        if (tuning.activate_on != .eat) {
            const kind: c.SpecialKind = @enumFromInt(k);
            const wired = switch (kind) {
                .neutralizer, .bomb => true,
                .egg, .canister, .rock => false,
            };
            if (!wired) {
                fail("{s}: specials.{s} activate_on \"{s}\" unsupported (only neutralizer and bomb)", .{
                    BALANCE_FILE,
                    @tagName(kind),
                    @tagName(tuning.activate_on),
                });
                return ConfigError.UnsupportedActivation;
            }
        }
    }
    if (raw.player_recipes.len > balance.MAX_PLAYER_RECIPES) {
        fail("{s}: {} player recipes exceeds cap {}", .{ BALANCE_FILE, raw.player_recipes.len, balance.MAX_PLAYER_RECIPES });
        return ConfigError.TooManyRecipes;
    }
    if (raw.team_recipes.len > balance.MAX_TEAM_RECIPES) {
        fail("{s}: {} team recipes exceeds cap {}", .{ BALANCE_FILE, raw.team_recipes.len, balance.MAX_TEAM_RECIPES });
        return ConfigError.TooManyRecipes;
    }

    const players = try a.alloc(balance.PlayerRecipe, raw.player_recipes.len);
    for (raw.player_recipes, players) |pr, *out| {
        try validate_recipe_label(pr.label);
        out.* = .{
            .label = pr.label,
            .shape = try shape_from_rows(a, pr.label, pr.shape),
            .cost = pr.cost,
        };
    }
    // Labels are how groups name their components and how the UI names a
    // selection, so a repeat would make both ambiguous.
    try reject_duplicate_labels(players);

    const teams = try a.alloc(balance.TeamRecipe, raw.team_recipes.len);
    for (raw.team_recipes, teams) |tr, *out| {
        try validate_recipe_label(tr.label);
        // A one-move group is just a move, and a group can never need more
        // contributors than a lobby can hold.  MAX_TEAM_COMPONENTS bounds the
        // fixed-size bag `complete_group` matches against.
        const max_group = @min(protocol.MAX_PLAYERS, balance.MAX_TEAM_COMPONENTS);
        if (tr.moves.len < 2 or tr.moves.len > max_group) {
            fail("{s}: group '{s}' needs {} moves (want 2..{})", .{ BALANCE_FILE, tr.label, tr.moves.len, max_group });
            return ConfigError.InvalidGroupSize;
        }
        const comps = try a.alloc(u8, tr.moves.len);
        for (tr.moves, comps) |name, *comp| {
            comp.* = move_index(players, name) orelse {
                fail("{s}: group '{s}' names unknown move '{s}'", .{ BALANCE_FILE, tr.label, name });
                return ConfigError.UnknownMoveLabel;
            };
        }
        out.* = .{
            .label = tr.label,
            .components = comps,
            .shape = try shape_from_rows(a, tr.label, tr.shape),
            .cost = tr.cost,
        };
    }

    return .{
        .hunger_cost_normal = raw.hunger_cost_normal,
        .max_chain_depth = raw.max_chain_depth,
        .blast_chains = raw.blast_chains,
        .slime_grid = .{ .rows = raw.slime_grid.rows, .cols = raw.slime_grid.cols },
        .bite_interval_ms = raw.bite_interval_ms,
        .bite_speedup_per_guy_pct = raw.bite_speedup_per_guy_pct,
        .bite_speedup_per_baby_pct = raw.bite_speedup_per_baby_pct,
        .cast_cooldown_ms = raw.cast_cooldown_ms,
        .team_window_ms = raw.team_window_ms,
        .hunger_base = raw.hunger_base,
        .appetite_scale = raw.appetite_scale,
        .hunger_player_cap = raw.hunger_player_cap,
        .baby_hunger = raw.baby_hunger,
        .feast_columns = raw.feast_columns,
        .feast_columns_per_guy = raw.feast_columns_per_guy,
        .specials_avoid_door_column = raw.specials_avoid_door_column,
        .specials = specials,
        .player_recipes = players,
        .team_recipes = teams,
    };
}

fn parse_encounters(a: std.mem.Allocator, bytes: []const u8) !enc.EncounterSet {
    const raw = std.json.parseFromSliceLeaky(EncountersJson, a, bytes, json_opts) catch |err| {
        fail("{s}: JSON parse failed: {s}", .{ ENCOUNTERS_FILE, @errorName(err) });
        return ConfigError.InvalidEncountersJson;
    };

    if (raw.encounters.len == 0) {
        fail("{s}: at least one encounter is required", .{ENCOUNTERS_FILE});
        return ConfigError.NoEncounters;
    }

    const list = try a.alloc(enc.Encounter, raw.encounters.len);
    for (raw.encounters, list) |e, *out| {
        if (e.label.len == 0) {
            fail("{s}: encounter label must not be empty", .{ENCOUNTERS_FILE});
            return ConfigError.EmptyLabel;
        }
        if (e.label.len > enc.MAX_LABEL_LEN) {
            fail("{s}: encounter label '{s}' exceeds {} bytes", .{ ENCOUNTERS_FILE, e.label, enc.MAX_LABEL_LEN });
            return ConfigError.LabelTooLong;
        }
        if (e.zones.len == 0) {
            fail("{s}: encounter '{s}' has no zones", .{ ENCOUNTERS_FILE, e.label });
            return ConfigError.NoZones;
        }
        if (e.zones.len > enc.MAX_ZONES) {
            fail("{s}: encounter '{s}' has {} zones (max {})", .{ ENCOUNTERS_FILE, e.label, e.zones.len, enc.MAX_ZONES });
            return ConfigError.TooManyZones;
        }
        // With no charges the team could never open a wall, so any encounter
        // whose field is not already fully edible would be unwinnable from the
        // first frame.  Rejected at load rather than shipped as a trap.
        if (e.charges == 0) {
            fail("{s}: encounter '{s}' charges must be > 0", .{ ENCOUNTERS_FILE, e.label });
            return ConfigError.InvalidCharges;
        }
        // Sum every bundle into the encounter's single slime total; saturating
        // so a designer config cannot overflow the u16 buckets.
        var slime = c.SlimeReservoir{};
        for (e.zones) |z| {
            slime.neutral +|= z.neutral;
            const per_kind = [_]u16{
                z.special.neutralizer, z.special.egg,  z.special.rock,
                z.special.canister,    z.special.bomb,
            };
            for (&slime.special, per_kind) |*acc, add| acc.* +|= add;
            const per_tier = [_]u16{ z.tiered.red, z.tiered.yellow, z.tiered.green };
            for (&slime.tiered, per_tier) |*acc, add| acc.* +|= add;
        }
        if (slime.is_empty()) {
            fail("{s}: encounter '{s}' has no slime", .{ ENCOUNTERS_FILE, e.label });
            return ConfigError.NoSlime;
        }
        out.* = .{
            .label = e.label,
            .charges = e.charges,
            .slime = slime,
        };
    }

    const default_index = for (list, 0..) |e, i| {
        if (std.mem.eql(u8, e.label, raw.default)) break i;
    } else {
        fail("{s}: default '{s}' matches no encounter label", .{ ENCOUNTERS_FILE, raw.default });
        return ConfigError.UnknownDefaultEncounter;
    };

    return .{ .encounters = list, .default_index = default_index };
}

fn validate_recipe_label(label: []const u8) !void {
    if (label.len == 0) {
        fail("{s}: recipe label must not be empty", .{BALANCE_FILE});
        return ConfigError.EmptyLabel;
    }
}


/// Turn authored rows of `#` into a Shape.  The anchor — the cell the caster
/// is aiming at — is the bounding box centre rounded down, so odd-sized
/// shapes centre exactly on the cursor.  Orientation is taken literally:
/// rotations and reflections are separate authored recipes.
fn shape_from_rows(
    a: std.mem.Allocator,
    recipe_label: []const u8,
    rows: []const []const u8,
) !balance.Shape {
    if (rows.len < 1 or rows.len > balance.MAX_SHAPE_ROWS) {
        fail("{s}: recipe '{s}' shape has {} rows (want 1..{})", .{ BALANCE_FILE, recipe_label, rows.len, balance.MAX_SHAPE_ROWS });
        return ConfigError.InvalidShapeSize;
    }
    const cols = rows[0].len;
    if (cols < 1 or cols > balance.MAX_SHAPE_COLS) {
        fail("{s}: recipe '{s}' shape has {} cols (want 1..{})", .{ BALANCE_FILE, recipe_label, cols, balance.MAX_SHAPE_COLS });
        return ConfigError.InvalidShapeSize;
    }
    // A ragged grid has no well-defined anchor, so demand a rectangle.
    for (rows) |line| {
        if (line.len != cols) {
            fail("{s}: recipe '{s}' shape rows are ragged ({} vs {})", .{ BALANCE_FILE, recipe_label, line.len, cols });
            return ConfigError.RaggedShape;
        }
    }

    var offsets: [balance.MAX_SHAPE_CELLS]balance.ShapeOffset = undefined;
    var n: usize = 0;
    const anchor_r: i8 = @intCast(rows.len / 2);
    const anchor_c: i8 = @intCast(cols / 2);
    for (rows, 0..) |line, r| {
        for (line, 0..) |ch, cl| {
            if (ch != '#') continue;
            offsets[n] = .{
                .d_row = @as(i8, @intCast(r)) - anchor_r,
                .d_col = @as(i8, @intCast(cl)) - anchor_c,
            };
            n += 1;
        }
    }
    // An empty shape is a recipe that does nothing — always a typo.
    if (n == 0) {
        fail("{s}: recipe '{s}' shape covers no cells (need at least one '#')", .{ BALANCE_FILE, recipe_label });
        return ConfigError.EmptyShape;
    }

    const owned = try a.alloc(balance.ShapeOffset, n);
    @memcpy(owned, offsets[0..n]);
    return .{ .offsets = owned, .rows = @intCast(rows.len), .cols = @intCast(cols) };
}

/// Labels identify a move to groups (`moves: [...]`) and to players (the UI
/// shows the selected label), so a repeat would make both ambiguous — the
/// first would always win and the second would be unreachable.
fn reject_duplicate_labels(recipes: []const balance.PlayerRecipe) !void {
    for (recipes, 0..) |a_rec, i| {
        for (recipes[i + 1 ..]) |b_rec| {
            if (std.mem.eql(u8, a_rec.label, b_rec.label)) {
                fail("{s}: two moves share the label '{s}'", .{ BALANCE_FILE, a_rec.label });
                return ConfigError.DuplicateLabel;
            }
        }
    }
}

/// Resolve a group component's authored label to its move-table index, which is
/// the form the runtime matches against.  Null when no move owns the label.
fn move_index(recipes: []const balance.PlayerRecipe, label: []const u8) ?u8 {
    for (recipes, 0..) |r, i| {
        if (std.mem.eql(u8, r.label, label)) return @intCast(i);
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Minimal valid balance document for rejection tests.
const minimal_balance =
    \\{"hunger_cost_normal":1,
    \\ "player_recipes":[],"team_recipes":[]}
;

/// Minimal valid encounters document for rejection tests.
const minimal_encounters =
    \\{"default":"e1","encounters":[
    \\ {"label":"e1","zones":[{"neutral":5}]}]}
;

/// A one-recipe balance document, `{...}`-interpolated at the recipe body so
/// each rejection test states only the field it is exercising.
fn one_recipe(comptime body: []const u8) []const u8 {
    return "{\"hunger_cost_normal\":1," ++
        "\"player_recipes\":[" ++ body ++ "],\"team_recipes\":[]}";
}

test "shipped data files parse and validate" {
    var loaded = try parse(
        std.testing.allocator,
        @embedFile("balance_data"),
        @embedFile("encounters_data"),
    );
    defer loaded.deinit();

    const cfg = &loaded.config;
    try std.testing.expect(cfg.balance.slime_grid.cells() >= 1);
    try std.testing.expect(cfg.balance.player_recipes.len >= 1);
    try std.testing.expect(cfg.encounters.encounters.len >= 1);
    // Default encounter resolves and every encounter holds slime to eat
    // (guaranteed by validation; assert anyway as a regression tripwire).
    _ = cfg.encounters.default();
    for (cfg.encounters.encounters) |e| {
        try std.testing.expect(e.total_units() >= 1);
    }
}

test "every shipped move has a real footprint and every group real components" {
    var loaded = try parse(
        std.testing.allocator,
        @embedFile("balance_data"),
        @embedFile("encounters_data"),
    );
    defer loaded.deinit();
    const bal = &loaded.config.balance;
    for (bal.player_recipes) |pr| {
        try std.testing.expect(pr.shape.size() >= 1);
    }
    for (bal.team_recipes) |tr| {
        // A group needs at least two contributors to be a group at all, and
        // every component must index a move that actually exists.
        try std.testing.expect(tr.components.len >= 2);
        try std.testing.expect(tr.shape.size() >= 1);
        for (tr.components) |comp| {
            try std.testing.expect(comp < bal.player_recipes.len);
        }
    }
}

test "every shipped shape fits inside the grid it is cast on" {
    // A shape wider than the field could never be fully placed.
    var loaded = try parse(
        std.testing.allocator,
        @embedFile("balance_data"),
        @embedFile("encounters_data"),
    );
    defer loaded.deinit();
    const bal = &loaded.config.balance;
    for (bal.player_recipes) |pr| {
        try std.testing.expect(pr.shape.rows <= bal.slime_grid.rows);
        try std.testing.expect(pr.shape.cols <= bal.slime_grid.cols);
    }
    for (bal.team_recipes) |tr| {
        try std.testing.expect(tr.shape.rows <= bal.slime_grid.rows);
        try std.testing.expect(tr.shape.cols <= bal.slime_grid.cols);
    }
}

test "minimal documents parse" {
    var loaded = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.config.balance.player_recipes.len);
    try std.testing.expectEqualStrings("e1", loaded.config.encounters.default().label);
}

test "a shape's anchor centres an odd footprint on the aimed cell" {
    var loaded = try parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"x","shape":["###","###","###"]}
        ),
        minimal_encounters,
    );
    defer loaded.deinit();
    const shape = loaded.config.balance.player_recipes[0].shape;
    try std.testing.expectEqual(@as(usize, 9), shape.size());
    // Offsets span -1..+1 on both axes, so the centre cell is (0,0).
    var has_centre = false;
    for (shape.offsets) |o| {
        try std.testing.expect(o.d_row >= -1 and o.d_row <= 1);
        try std.testing.expect(o.d_col >= -1 and o.d_col <= 1);
        if (o.d_row == 0 and o.d_col == 0) has_centre = true;
    }
    try std.testing.expect(has_centre);
}

test "a shape reads only '#' as covered" {
    var loaded = try parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"x","shape":["#.#",".#.","#.#"]}
        ),
        minimal_encounters,
    );
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 5), loaded.config.balance.player_recipes[0].shape.size());
}

test "a 1x1 shape sits exactly on the cursor" {
    var loaded = try parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"x","shape":["#"]}
        ),
        minimal_encounters,
    );
    defer loaded.deinit();
    const shape = loaded.config.balance.player_recipes[0].shape;
    try std.testing.expectEqual(@as(usize, 1), shape.size());
    try std.testing.expectEqual(@as(i8, 0), shape.offsets[0].d_row);
    try std.testing.expectEqual(@as(i8, 0), shape.offsets[0].d_col);
}

test "a shape covering no cells is rejected" {
    try std.testing.expectError(ConfigError.EmptyShape, parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"x","shape":["...","..."]}
        ),
        minimal_encounters,
    ));
}

test "a shape with no rows is rejected" {
    try std.testing.expectError(ConfigError.InvalidShapeSize, parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"x","shape":[]}
        ),
        minimal_encounters,
    ));
}

test "a ragged shape is rejected" {
    try std.testing.expectError(ConfigError.RaggedShape, parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"x","shape":["###","#"]}
        ),
        minimal_encounters,
    ));
}

test "an over-tall shape is rejected" {
    // MAX_SHAPE_ROWS + 1 rows of a single cell.
    const rows = "[" ++ "\"#\"," ** balance.MAX_SHAPE_ROWS ++ "\"#\"]";
    try std.testing.expectError(ConfigError.InvalidShapeSize, parse(
        std.testing.allocator,
        one_recipe("{\"label\":\"x\",\"shape\":" ++ rows ++ "}"),
        minimal_encounters,
    ));
}

test "an over-wide shape is rejected" {
    const wide = "\"" ++ "#" ** (balance.MAX_SHAPE_COLS + 1) ++ "\"";
    try std.testing.expectError(ConfigError.InvalidShapeSize, parse(
        std.testing.allocator,
        one_recipe("{\"label\":\"x\",\"shape\":[" ++ wide ++ "]}"),
        minimal_encounters,
    ));
}

test "two moves sharing a label are rejected" {
    // Groups name components by label, so a repeat makes a group ambiguous and
    // leaves the second move unreachable from the group table.
    try std.testing.expectError(ConfigError.DuplicateLabel, parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"a","shape":["#"]},
            \\{"label":"a","shape":["##"]}
        ),
        minimal_encounters,
    ));
}

test "moves sharing a shape but not a label are both kept" {
    // Two ways to spend on the same footprint is a pricing decision, not an
    // error: only the label has to be unique.
    var loaded = try parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"cheap","shape":["#"],"cost":1},
            \\{"label":"dear","shape":["#"],"cost":5}
        ),
        minimal_encounters,
    );
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.config.balance.player_recipes.len);
}

test "recipe cost defaults to one and 0 is a legal free move" {
    var loaded = try parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"plain","shape":["#"]},
            \\{"label":"free","shape":["#"],"cost":0},
            \\{"label":"heavy","shape":["###"],"cost":12}
        ),
        minimal_encounters,
    );
    defer loaded.deinit();
    const recipes = loaded.config.balance.player_recipes;
    try std.testing.expectEqual(balance.DEFAULT_RECIPE_COST, recipes[0].cost);
    try std.testing.expectEqual(@as(u16, 0), recipes[1].cost);
    try std.testing.expectEqual(@as(u16, 12), recipes[2].cost);
    // The free move sets the floor the dead-position check compares against.
    try std.testing.expectEqual(@as(u16, 0), loaded.config.balance.cheapest_cost());
}

test "cheapest_cost spans both recipe tables" {
    const doc =
        \\{"hunger_cost_normal":1,
        \\ "player_recipes":[{"label":"p","shape":["#"],"cost":5}],
        \\ "team_recipes":[{"label":"t","moves":["p","p"],
        \\   "shape":["#"],"cost":2}]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    // The group is the cheapest move, so it decides when a team is broke.
    try std.testing.expectEqual(@as(u16, 2), loaded.config.balance.cheapest_cost());
}

test "a group naming an unknown move is rejected" {
    // Typo protection: a group whose bag can never be filled is dead data.
    const bad =
        \\{"hunger_cost_normal":1,
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[{"label":"t","moves":["poke","pokke"],"shape":["#"]}]}
    ;
    try std.testing.expectError(
        ConfigError.UnknownMoveLabel,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "a group's components resolve to move-table indices in authored order" {
    const doc =
        \\{"hunger_cost_normal":1,
        \\ "player_recipes":[{"label":"a","shape":["#"]},
        \\   {"label":"b","shape":["##"]},{"label":"c","shape":["###"]}],
        \\ "team_recipes":[{"label":"t","moves":["c","a"],"shape":["#"]}]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    // Indices, not labels, are what the runtime matches — and file order is the
    // index, which is also the order players cycle through.
    try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, loaded.config.balance.team_recipes[0].components);
}

test "a group may name the same move twice" {
    // Two players each poking is the canonical group; the repeat is the point.
    const doc =
        \\{"hunger_cost_normal":1,
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[{"label":"t","moves":["poke","poke"],"shape":["###"]}]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, loaded.config.balance.team_recipes[0].components);
}

test "realtime pacing knobs default when absent" {
    var loaded = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer loaded.deinit();
    const bal = &loaded.config.balance;
    try std.testing.expectEqual(balance.DEFAULT_BITE_INTERVAL_MS, bal.bite_interval_ms);
    try std.testing.expectEqual(balance.DEFAULT_BITE_SPEEDUP_PER_GUY_PCT, bal.bite_speedup_per_guy_pct);
    try std.testing.expectEqual(balance.DEFAULT_BITE_SPEEDUP_PER_BABY_PCT, bal.bite_speedup_per_baby_pct);
    try std.testing.expectEqual(balance.DEFAULT_CAST_COOLDOWN_MS, bal.cast_cooldown_ms);
    try std.testing.expectEqual(balance.DEFAULT_TEAM_WINDOW_MS, bal.team_window_ms);
}

test "slime_grid defaults when absent" {
    var loaded = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(balance.DEFAULT_SLIME_GRID.rows, loaded.config.balance.slime_grid.rows);
    try std.testing.expectEqual(balance.DEFAULT_SLIME_GRID.cols, loaded.config.balance.slime_grid.cols);
}

test "slime_grid is read from the document" {
    const doc =
        \\{"hunger_cost_normal":1,
        \\ "slime_grid":{"rows":4,"cols":12},
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u8, 4), loaded.config.balance.slime_grid.rows);
    try std.testing.expectEqual(@as(u8, 12), loaded.config.balance.slime_grid.cols);
    try std.testing.expectEqual(@as(usize, 48), loaded.config.balance.slime_grid.cells());
}

test "out-of-range slime_grid dimensions are rejected" {
    const zero =
        \\{"hunger_cost_normal":1,
        \\ "slime_grid":{"rows":0,"cols":8},
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidSlimeGrid,
        parse(std.testing.allocator, zero, minimal_encounters),
    );
    const too_big =
        \\{"hunger_cost_normal":1,
        \\ "slime_grid":{"rows":8,"cols":99},
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidSlimeGrid,
        parse(std.testing.allocator, too_big, minimal_encounters),
    );
}

test "realtime pacing knobs are read from the document" {
    const doc =
        \\{"hunger_cost_normal":1,
        \\ "bite_interval_ms":2500,"bite_speedup_per_guy_pct":20,
        \\ "bite_speedup_per_baby_pct":10,"cast_cooldown_ms":300,
        \\ "team_window_ms":1500,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    const bal = &loaded.config.balance;
    try std.testing.expectEqual(@as(u32, 2500), bal.bite_interval_ms);
    try std.testing.expectEqual(@as(u16, 20), bal.bite_speedup_per_guy_pct);
    try std.testing.expectEqual(@as(u16, 10), bal.bite_speedup_per_baby_pct);
    try std.testing.expectEqual(@as(u32, 300), bal.cast_cooldown_ms);
    try std.testing.expectEqual(@as(u32, 1500), bal.team_window_ms);
    // The additive interval formula: 1 guy = base; extra guys and babies
    // speed the same base, no compounding.
    try std.testing.expectEqual(@as(u32, 2500), bal.bite_interval_effective(1, 0));
    // 3 guys, 2 babies: 100 + 2*20 + 2*10 = 160 -> 2500*100/160 = 1562.
    try std.testing.expectEqual(@as(u32, 1562), bal.bite_interval_effective(3, 2));
    // A zero-seat table still yields the base interval (never divides oddly).
    try std.testing.expectEqual(@as(u32, 2500), bal.bite_interval_effective(0, 0));
}

test "a sub-100ms bite interval is rejected" {
    // Faster than the server tick can pace — always a seconds-vs-ms mistake.
    const bad =
        \\{"hunger_cost_normal":1,
        \\ "bite_interval_ms":99,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidBiteInterval,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "an absurd bite speedup percent is rejected" {
    const bad_guy =
        \\{"hunger_cost_normal":1,
        \\ "bite_speedup_per_guy_pct":1001,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidBiteSpeedup,
        parse(std.testing.allocator, bad_guy, minimal_encounters),
    );
    const bad_baby =
        \\{"hunger_cost_normal":1,
        \\ "bite_speedup_per_baby_pct":1001,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidBiteSpeedup,
        parse(std.testing.allocator, bad_baby, minimal_encounters),
    );
}

test "a zero team window is rejected" {
    // Two casts can never land at the same instant, so every group would be
    // dead data.
    const bad =
        \\{"hunger_cost_normal":1,
        \\ "team_window_ms":0,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidTeamWindow,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "appetite formula knobs default when absent" {
    var loaded = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(balance.DEFAULT_HUNGER_BASE, loaded.config.balance.hunger_base);
    try std.testing.expectEqual(balance.DEFAULT_APPETITE_SCALE, loaded.config.balance.appetite_scale);
    try std.testing.expectEqual(balance.DEFAULT_HUNGER_PLAYER_CAP, loaded.config.balance.hunger_player_cap);
}

test "appetite formula knobs are read from the document" {
    const doc =
        \\{"hunger_cost_normal":1,
        \\ "hunger_base":12,"appetite_scale":3,"hunger_player_cap":40,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u16, 12), loaded.config.balance.hunger_base);
    try std.testing.expectEqual(@as(u16, 3), loaded.config.balance.appetite_scale);
    try std.testing.expectEqual(@as(u16, 40), loaded.config.balance.hunger_player_cap);
}

test "a zero hunger_base or a cap under the base is rejected" {
    // base 0: a lone appetite-0 player would contribute nothing and hunger
    // could never end the game.
    const zero_base =
        \\{"hunger_cost_normal":1,
        \\ "hunger_base":0,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidHungerFormula,
        parse(std.testing.allocator, zero_base, minimal_encounters),
    );
    // cap < base: every player would be paid less than the base promises.
    const low_cap =
        \\{"hunger_cost_normal":1,
        \\ "hunger_base":30,"hunger_player_cap":10,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidHungerFormula,
        parse(std.testing.allocator, low_cap, minimal_encounters),
    );
}

test "retired encounter hunger_max is rejected, not ignored" {
    // The bar's capacity is the sum of the players' appetite contributions
    // now (balance.hunger_base et al), so a leftover per-encounter budget
    // would silently do nothing.
    const stale =
        \\{"default":"e1","encounters":[
        \\ {"label":"e1","hunger_max":60,"zones":[{"neutral":5}]}]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidEncountersJson,
        parse(std.testing.allocator, minimal_balance, stale),
    );
}

test "retired turn, old-realtime and medicine fields are rejected" {
    // The realtime loop has no cast budgets, buffers, locks or per-second eat
    // rate, and medicine is gone entirely.  Leaving a stale tunable in a
    // config would silently do nothing, so std.json's unknown-field
    // strictness is the intended behaviour.
    for ([_][]const u8{
        // The turn loop's per-player cast budget: casts pace themselves on
        // cast_cooldown_ms now.
        \\{"hunger_cost_normal":1,
        \\ "casts_per_turn":3,
        \\ "player_recipes":[],"team_recipes":[]}
        ,
        \\{"hunger_cost_normal":1,
        \\ "eat_rate_units_per_s":2.0,
        \\ "player_recipes":[],"team_recipes":[]}
        ,
        \\{"hunger_cost_normal":1,
        \\ "cast_buffer_ms":500,
        \\ "player_recipes":[],"team_recipes":[]}
        ,
        \\{"hunger_cost_normal":1,
        \\ "cast_lock_ms":500,
        \\ "player_recipes":[],"team_recipes":[]}
        ,
        // Hazards are never eaten now, so there is no extra to charge for.
        \\{"hunger_cost_normal":1,
        \\ "hunger_cost_hazard_extra":2,
        \\ "player_recipes":[],"team_recipes":[]}
        ,
        // A recipe's medicine output has no meaning any more.
        \\{"hunger_cost_normal":1,
        \\ "player_recipes":[{"label":"x","shape":["#"],
        \\   "medicine":{"red":3}}],
        \\ "team_recipes":[]}
        ,
        // Button patterns are gone: a move is selected by cycling the wheel, not
        // spelled out, so a leftover `pattern` would silently do nothing.
        \\{"hunger_cost_normal":1,
        \\ "player_recipes":[{"label":"x","pattern":["dispense"],"shape":["#"]}],
        \\ "team_recipes":[]}
        ,
        // Groups name component MOVES now, not per-player button patterns.
        \\{"hunger_cost_normal":1,
        \\ "player_recipes":[{"label":"x","shape":["#"]}],
        \\ "team_recipes":[{"label":"t","patterns":[["dispense"],["catalyst"]],
        \\   "shape":["#"]}]}
        ,
    }) |bad| {
        try std.testing.expectError(
            ConfigError.InvalidBalanceJson,
            parse(std.testing.allocator, bad, minimal_encounters),
        );
    }
}

test "unknown top-level field is rejected (typo protection)" {
    const bad =
        \\{"hunger_cost_normal":1,
        \\ "unnits_per_slot":5,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidBalanceJson,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "a removed pre-shape balance field is rejected, not ignored" {
    // Old configs are incompatible on purpose: their recipes have no shapes.
    const stale =
        \\{"units_per_slot":5,"reagent_per_slot":3,
        \\ "hunger_cost_normal":1,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidBalanceJson,
        parse(std.testing.allocator, stale, minimal_encounters),
    );
}

test "a recipe without a shape is rejected" {
    const bad =
        \\{"hunger_cost_normal":1,
        \\ "player_recipes":[{"label":"x"}],
        \\ "team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidBalanceJson,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "groups carry one shared shape and one shared cost" {
    const doc =
        \\{"hunger_cost_normal":1,
        \\ "player_recipes":[{"label":"a","shape":["#"]},{"label":"b","shape":["##"]}],
        \\ "team_recipes":[{"label":"t","moves":["a","b"],
        \\   "shape":["#####"],"cost":3}]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    const tr = loaded.config.balance.team_recipes[0];
    try std.testing.expectEqual(@as(usize, 2), tr.components.len);
    try std.testing.expectEqual(@as(usize, 5), tr.shape.size());
    // One cost for the group, not one per contributing player.
    try std.testing.expectEqual(@as(u16, 3), tr.cost);
}

test "a group of fewer than two moves is rejected" {
    // One contributor is just a move; calling it a group would let a solo
    // player fire group shapes at group prices.
    for ([_][]const u8{
        \\{"hunger_cost_normal":1,
        \\ "player_recipes":[{"label":"a","shape":["#"]}],
        \\ "team_recipes":[{"label":"t","moves":[],"shape":["#"]}]}
        ,
        \\{"hunger_cost_normal":1,
        \\ "player_recipes":[{"label":"a","shape":["#"]}],
        \\ "team_recipes":[{"label":"t","moves":["a"],"shape":["#"]}]}
        ,
    }) |bad| {
        try std.testing.expectError(
            ConfigError.InvalidGroupSize,
            parse(std.testing.allocator, bad, minimal_encounters),
        );
    }
}

test "a group needing more contributors than a lobby holds is rejected" {
    // Such a group could never fire, so it is dead data rather than hard mode.
    const over = @min(protocol.MAX_PLAYERS, balance.MAX_TEAM_COMPONENTS) + 1;
    const moves = "[" ++ "\"a\"," ** (over - 1) ++ "\"a\"]";
    const bad = "{\"hunger_cost_normal\":1," ++
        "\"player_recipes\":[{\"label\":\"a\",\"shape\":[\"#\"]}]," ++
        "\"team_recipes\":[{\"label\":\"t\",\"moves\":" ++ moves ++ ",\"shape\":[\"#\"]}]}";
    try std.testing.expectError(
        ConfigError.InvalidGroupSize,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "legacy multi-zone encounters are summed into one slime total" {
    const doc =
        \\{"default":"e1","encounters":[
        \\ {"label":"e1","zones":[
        \\   {"tiered":{"red":3},"neutral":1},
        \\   {"tiered":{"red":2,"green":4},"neutral":5}]}]}
    ;
    var loaded = try parse(std.testing.allocator, minimal_balance, doc);
    defer loaded.deinit();
    const e = loaded.config.encounters.default();
    try std.testing.expectEqual(@as(u16, 5), e.slime.tiered[@intFromEnum(c.Tier.red)]);
    try std.testing.expectEqual(@as(u16, 4), e.slime.tiered[@intFromEnum(c.Tier.green)]);
    try std.testing.expectEqual(@as(u16, 6), e.slime.neutral);
    try std.testing.expectEqual(@as(u32, 15), e.total_units());
}

test "specials are summed per kind from the zones and default to none" {
    const doc =
        \\{"default":"e1","encounters":[
        \\ {"label":"e1","zones":[
        \\   {"neutral":4,"special":{"neutralizer":1,"egg":1}},
        \\   {"tiered":{"red":2},"special":{"neutralizer":2}}]}]}
    ;
    var loaded = try parse(std.testing.allocator, minimal_balance, doc);
    defer loaded.deinit();
    const e = loaded.config.encounters.default();
    try std.testing.expectEqual(@as(u16, 3), e.slime.special[@intFromEnum(c.SpecialKind.neutralizer)]);
    try std.testing.expectEqual(@as(u16, 1), e.slime.special[@intFromEnum(c.SpecialKind.egg)]);
    // Every special counts as supply — they occupy grid cells — and every
    // unit is clearable (even a rock breaks under the Agent), so the total
    // is exactly what the win condition measures down to zero.
    try std.testing.expectEqual(@as(u32, 10), e.total_units());
    try std.testing.expectEqual(@as(u32, 10), e.slime.total());
}

test "an encounter of nothing but specials is still 'slime' for validation" {
    // Degenerate but legal: an all-neutralizer field.  Nothing to eat, so the
    // team wins the moment it starts — the loader's job is not to judge design.
    const doc =
        \\{"default":"e1","encounters":[
        \\ {"label":"e1","zones":[{"special":{"neutralizer":3}}]}]}
    ;
    var loaded = try parse(std.testing.allocator, minimal_balance, doc);
    defer loaded.deinit();
    const slime = loaded.config.encounters.default().slime;
    try std.testing.expectEqual(@as(u16, 3), slime.special[@intFromEnum(c.SpecialKind.neutralizer)]);
}

test "the old scalar special count is rejected: configs must name a kind" {
    const bad =
        \\{"default":"e1","encounters":[
        \\ {"label":"e1","zones":[{"special":3}]}]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidEncountersJson,
        parse(std.testing.allocator, minimal_balance, bad),
    );
}

test "special tuning defaults, is read, and bad match_len is rejected" {
    // Absent entirely: every kind gets DEFAULT_MATCH_LEN.
    var defaulted = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer defaulted.deinit();
    for (defaulted.config.balance.specials) |tuning| {
        try std.testing.expectEqual(balance.DEFAULT_MATCH_LEN, tuning.match_len);
    }

    const doc =
        \\{"hunger_cost_normal":1,
        \\ "specials":{"neutralizer":{"match_len":4}},
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u8, 4), loaded.config.balance.special_tuning(.neutralizer).match_len);
    try std.testing.expectEqual(balance.DEFAULT_MATCH_LEN, loaded.config.balance.special_tuning(.egg).match_len);

    // 1 would fire on every lone special; longer than the grid's longest line
    // could never fire at all.
    const too_short =
        \\{"hunger_cost_normal":1,
        \\ "specials":{"egg":{"match_len":1}},
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidMatchLen,
        parse(std.testing.allocator, too_short, minimal_encounters),
    );
    const too_long =
        \\{"hunger_cost_normal":1,
        \\ "slime_grid":{"rows":3,"cols":4},
        \\ "specials":{"neutralizer":{"match_len":5}},
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidMatchLen,
        parse(std.testing.allocator, too_long, minimal_encounters),
    );
}

test "back_ranks_only defaults off and is read per kind" {
    var defaulted = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer defaulted.deinit();
    for (defaulted.config.balance.specials) |tuning| {
        try std.testing.expect(!tuning.back_ranks_only);
    }

    const doc =
        \\{"hunger_cost_normal":1,
        \\ "specials":{"egg":{"back_ranks_only":true}},
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expect(loaded.config.balance.special_tuning(.egg).back_ranks_only);
    try std.testing.expect(!loaded.config.balance.special_tuning(.neutralizer).back_ranks_only);
}

test "guaranteed_at_start defaults off and is read per kind" {
    var defaulted = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer defaulted.deinit();
    for (defaulted.config.balance.specials) |tuning| {
        try std.testing.expect(!tuning.guaranteed_at_start);
    }

    const doc =
        \\{"hunger_cost_normal":1,
        \\ "specials":{"egg":{"guaranteed_at_start":true}},
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expect(loaded.config.balance.special_tuning(.egg).guaranteed_at_start);
    try std.testing.expect(!loaded.config.balance.special_tuning(.neutralizer).guaranteed_at_start);
}

test "specials_avoid_door_column defaults on and is read" {
    var defaulted = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer defaulted.deinit();
    try std.testing.expect(defaulted.config.balance.specials_avoid_door_column);

    const doc =
        \\{"hunger_cost_normal":1,
        \\ "specials_avoid_door_column":false,
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expect(!loaded.config.balance.specials_avoid_door_column);
}

test "baby_hunger defaults and is read" {
    var defaulted = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer defaulted.deinit();
    try std.testing.expectEqual(balance.DEFAULT_BABY_HUNGER, defaulted.config.balance.baby_hunger);

    const doc =
        \\{"hunger_cost_normal":1,
        \\ "baby_hunger":25,
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u16, 25), loaded.config.balance.baby_hunger);
}

test "feast column knobs default and are read" {
    var defaulted = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer defaulted.deinit();
    try std.testing.expectEqual(balance.DEFAULT_FEAST_COLUMNS, defaulted.config.balance.feast_columns);
    try std.testing.expectEqual(
        balance.DEFAULT_FEAST_COLUMNS_PER_GUY,
        defaulted.config.balance.feast_columns_per_guy,
    );

    const doc =
        \\{"hunger_cost_normal":1,
        \\ "feast_columns":2,"feast_columns_per_guy":1,
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u8, 2), loaded.config.balance.feast_columns);
    try std.testing.expectEqual(@as(u8, 1), loaded.config.balance.feast_columns_per_guy);
    // The width formula: base + per-guy, clamped at the grid's columns.
    try std.testing.expectEqual(@as(u8, 2), loaded.config.balance.feast_width(0));
    try std.testing.expectEqual(@as(u8, 4), loaded.config.balance.feast_width(2));
    try std.testing.expectEqual(@as(u8, 10), loaded.config.balance.feast_width(99));
}

test "a zero or over-wide feast_columns is rejected" {
    // 0 columns would bite nothing forever; wider than the grid promises
    // columns that do not exist.
    const zero =
        \\{"hunger_cost_normal":1,
        \\ "feast_columns":0,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidFeastColumns,
        parse(std.testing.allocator, zero, minimal_encounters),
    );
    const wide =
        \\{"hunger_cost_normal":1,
        \\ "slime_grid":{"rows":6,"cols":10},
        \\ "feast_columns":11,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidFeastColumns,
        parse(std.testing.allocator, wide, minimal_encounters),
    );
}

test "encounter charges default, are read, and 0 is rejected" {
    var defaulted = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer defaulted.deinit();
    try std.testing.expectEqual(enc.DEFAULT_CHARGES, defaulted.config.encounters.default().charges);

    const doc =
        \\{"default":"e1","encounters":[
        \\ {"label":"e1","charges":7,"zones":[{"neutral":5}]}]}
    ;
    var loaded = try parse(std.testing.allocator, minimal_balance, doc);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 7), loaded.config.encounters.default().charges);

    // A team with no charges can never open a wall, so the encounter would be a
    // trap rather than a challenge.
    const bad =
        \\{"default":"e1","encounters":[
        \\ {"label":"e1","charges":0,"zones":[{"neutral":5}]}]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidCharges,
        parse(std.testing.allocator, minimal_balance, bad),
    );
}

test "encounter with no slime at all is rejected" {
    const bad =
        \\{"default":"e1","encounters":[
        \\ {"label":"e1","zones":[{"neutral":0}]}]}
    ;
    try std.testing.expectError(
        ConfigError.NoSlime,
        parse(std.testing.allocator, minimal_balance, bad),
    );
}

test "unknown default encounter is rejected" {
    const bad =
        \\{"default":"nope","encounters":[
        \\ {"label":"e1","zones":[{"neutral":5}]}]}
    ;
    try std.testing.expectError(
        ConfigError.UnknownDefaultEncounter,
        parse(std.testing.allocator, minimal_balance, bad),
    );
}

test "too many zones is rejected" {
    const zone = "{\"neutral\":1},";
    const bad = "{\"default\":\"e1\",\"encounters\":[{\"label\":\"e1\"," ++
        "\"zones\":[" ++
        zone ** (enc.MAX_ZONES) ++ "{\"neutral\":1}]}]}";
    try std.testing.expectError(
        ConfigError.TooManyZones,
        parse(std.testing.allocator, minimal_balance, bad),
    );
}

test "activate_on defaults to eat, reads per kind, and refuses unwired kinds" {
    var defaulted = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer defaulted.deinit();
    for (defaulted.config.balance.specials) |tuning| {
        try std.testing.expectEqual(balance.Activation.eat, tuning.activate_on);
    }

    const doc =
        \\{"hunger_cost_normal":1,
        \\ "specials":{"bomb":{"activate_on":"cast"},
        \\             "neutralizer":{"activate_on":"eatcast"}},
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    const bal = loaded.config.balance;
    try std.testing.expectEqual(balance.Activation.cast, bal.special_tuning(.bomb).activate_on);
    try std.testing.expectEqual(balance.Activation.eatcast, bal.special_tuning(.neutralizer).activate_on);
    try std.testing.expectEqual(balance.Activation.eat, bal.special_tuning(.egg).activate_on);

    // The three kinds whose cast path is not wired are refused OUTRIGHT
    // rather than silently ignored — a knob that reads as set but does
    // nothing is worse than one that will not load.
    for ([_][]const u8{ "egg", "canister", "rock" }) |kind| {
        var buf: [256]u8 = undefined;
        const bad = try std.fmt.bufPrint(&buf,
            \\{{"hunger_cost_normal":1,
            \\ "specials":{{"{s}":{{"activate_on":"cast"}}}},
            \\ "player_recipes":[{{"label":"poke","shape":["#"]}}],
            \\ "team_recipes":[]}}
        , .{kind});
        try std.testing.expectError(
            ConfigError.UnsupportedActivation,
            parse(std.testing.allocator, bad, minimal_encounters),
        );
    }

    // ...but leaving one of them explicitly on `eat` is fine: the check is
    // on the VALUE, not on mentioning the kind.
    const explicit_eat =
        \\{"hunger_cost_normal":1,
        \\ "specials":{"rock":{"activate_on":"eat"}},
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    var ok = try parse(std.testing.allocator, explicit_eat, minimal_encounters);
    defer ok.deinit();

    // A tag that is not one of the three fails the PARSE, naming the file.
    const nonsense =
        \\{"hunger_cost_normal":1,
        \\ "specials":{"bomb":{"activate_on":"whenever"}},
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidBalanceJson,
        parse(std.testing.allocator, nonsense, minimal_encounters),
    );
}

test "chain knobs default and are read" {
    var defaulted = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer defaulted.deinit();
    try std.testing.expectEqual(
        balance.DEFAULT_MAX_CHAIN_DEPTH,
        defaulted.config.balance.max_chain_depth,
    );
    try std.testing.expect(!defaulted.config.balance.blast_chains);

    const doc =
        \\{"hunger_cost_normal":1,
        \\ "max_chain_depth":7, "blast_chains":true,
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u8, 7), loaded.config.balance.max_chain_depth);
    try std.testing.expect(loaded.config.balance.blast_chains);

    // The cap needs no range check: see the note on BalanceJson.  The
    // largest value the type can hold loads fine — slime.zig pins that a
    // full board chained at this cap counts without overflowing.
    const maxed =
        \\{"hunger_cost_normal":1,
        \\ "max_chain_depth":255,
        \\ "player_recipes":[{"label":"poke","shape":["#"]}],
        \\ "team_recipes":[]}
    ;
    var wide = try parse(std.testing.allocator, maxed, minimal_encounters);
    defer wide.deinit();
    try std.testing.expectEqual(@as(u8, 255), wide.config.balance.max_chain_depth);
}
