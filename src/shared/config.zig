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
    InvalidCastsPerRound,
    InvalidRoundDuration,
    InvalidEatRate,
    InvalidCastWindow,
    TooManyRecipes,
    InvalidTeamPatternCount,
    InvalidComboLength,
    InvalidComboSlot,
    EmptyLabel,
    LabelTooLong,
    NoEncounters,
    NoZones,
    TooManyZones,
    InvalidHungerMax,
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
comptime {
    std.debug.assert(@intFromEnum(c.Element.red) == 0);
    std.debug.assert(@intFromEnum(c.Element.green) == 1);
    std.debug.assert(@intFromEnum(c.Element.yellow) == 2);
    std.debug.assert(@intFromEnum(c.Element.blue) == 3);
}

const ColorsU32Json = struct { red: u32 = 0, green: u32 = 0, yellow: u32 = 0, blue: u32 = 0 };
const ColorsU16Json = struct { red: u16 = 0, green: u16 = 0, yellow: u16 = 0, blue: u16 = 0 };

const OutputJson = struct {
    units: ColorsU32Json = .{},
    medicine: ColorsU32Json = .{},
};

const PlayerRecipeJson = struct {
    label: []const u8,
    /// Combo slots as strings: "dispense" | "medicine" | element name.
    pattern: []const []const u8,
    output: OutputJson,
};

const TeamRecipeJson = struct {
    label: []const u8,
    patterns: []const []const []const u8,
    output: OutputJson,
};

const BalanceJson = struct {
    casts_per_round: u8,
    units_per_slot: u32,
    medicine_per_slot: u32,
    hunger_cost_normal: u32,
    hunger_cost_modified_extra: u32,
    round_duration_default_s: f32,
    /// Realtime mode fields; defaulted so pre-realtime configs (including
    /// saved /tune configs) keep validating unchanged.
    eat_rate_units_per_s: f32 = 2.0,
    cast_window_ms: u32 = 3000,
    player_recipes: []const PlayerRecipeJson,
    team_recipes: []const TeamRecipeJson,
};

const ZoneJson = struct {
    modified: ColorsU16Json = .{},
    neutral: u16 = 0,
};

const EncounterJson = struct {
    label: []const u8,
    hunger_max: u16,
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

    if (raw.casts_per_round == 0) {
        fail("{s}: casts_per_round must be >= 1", .{BALANCE_FILE});
        return ConfigError.InvalidCastsPerRound;
    }
    if (!(raw.round_duration_default_s > 0)) {
        fail("{s}: round_duration_default_s must be > 0", .{BALANCE_FILE});
        return ConfigError.InvalidRoundDuration;
    }
    if (!(raw.eat_rate_units_per_s > 0)) {
        fail("{s}: eat_rate_units_per_s must be > 0", .{BALANCE_FILE});
        return ConfigError.InvalidEatRate;
    }
    if (raw.cast_window_ms == 0) {
        fail("{s}: cast_window_ms must be >= 1", .{BALANCE_FILE});
        return ConfigError.InvalidCastWindow;
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
            .pattern = try combo_from_names(pr.label, pr.pattern),
            .output = output_from_json(pr.output),
        };
    }

    const teams = try a.alloc(balance.TeamRecipe, raw.team_recipes.len);
    for (raw.team_recipes, teams) |tr, *out| {
        try validate_recipe_label(tr.label);
        if (tr.patterns.len < 1 or tr.patterns.len > protocol.MAX_PLAYERS) {
            fail("{s}: team recipe '{s}' has {} patterns (want 1..{})", .{ BALANCE_FILE, tr.label, tr.patterns.len, protocol.MAX_PLAYERS });
            return ConfigError.InvalidTeamPatternCount;
        }
        const pats = try a.alloc(c.ActionCombo, tr.patterns.len);
        for (tr.patterns, pats) |names, *pat| {
            pat.* = try combo_from_names(tr.label, names);
        }
        out.* = .{
            .label = tr.label,
            .patterns = pats,
            .output = output_from_json(tr.output),
        };
    }

    return .{
        .casts_per_round = raw.casts_per_round,
        .units_per_slot = raw.units_per_slot,
        .medicine_per_slot = raw.medicine_per_slot,
        .hunger_cost_normal = raw.hunger_cost_normal,
        .hunger_cost_modified_extra = raw.hunger_cost_modified_extra,
        .round_duration_default_s = raw.round_duration_default_s,
        .eat_rate_units_per_s = raw.eat_rate_units_per_s,
        .cast_window_ms = raw.cast_window_ms,
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
        if (e.hunger_max == 0) {
            fail("{s}: encounter '{s}' hunger_max must be > 0", .{ ENCOUNTERS_FILE, e.label });
            return ConfigError.InvalidHungerMax;
        }
        const zones = try a.alloc(c.ZoneDef, e.zones.len);
        for (e.zones, zones) |z, *zd| {
            zd.* = .{
                .modified = .{ z.modified.red, z.modified.green, z.modified.yellow, z.modified.blue },
                .neutral = z.neutral,
            };
        }
        out.* = .{ .label = e.label, .hunger_max = e.hunger_max, .zones = zones };
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

fn output_from_json(o: OutputJson) c.AgentOutput {
    return .{
        .units = .{ o.units.red, o.units.green, o.units.yellow, o.units.blue },
        .medicine = .{ o.medicine.red, o.medicine.green, o.medicine.yellow, o.medicine.blue },
    };
}

fn slot_from_name(name: []const u8) ?c.ComboSlot {
    if (std.meta.stringToEnum(c.ActionChoice, name)) |action| return .{ .action = action };
    if (std.meta.stringToEnum(c.Element, name)) |element| return .{ .element = element };
    return null;
}

fn combo_from_names(recipe_label: []const u8, names: []const []const u8) !c.ActionCombo {
    if (names.len < 1 or names.len > c.MAX_COMBO_LEN) {
        fail("{s}: recipe '{s}' pattern length {} outside 1..{}", .{ BALANCE_FILE, recipe_label, names.len, c.MAX_COMBO_LEN });
        return ConfigError.InvalidComboLength;
    }
    var combo = c.ActionCombo{
        .slots = [_]c.ComboSlot{.{ .action = .dispense }} ** c.MAX_COMBO_LEN,
        .len = @intCast(names.len),
    };
    for (names, 0..) |name, i| {
        combo.slots[i] = slot_from_name(name) orelse {
            fail("{s}: recipe '{s}' has unknown slot '{s}' (want dispense|medicine|red|green|yellow|blue)", .{ BALANCE_FILE, recipe_label, name });
            return ConfigError.InvalidComboSlot;
        };
    }
    return combo;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Minimal valid balance document for rejection tests.
const minimal_balance =
    \\{"casts_per_round":3,"units_per_slot":5,"medicine_per_slot":3,
    \\ "hunger_cost_normal":1,"hunger_cost_modified_extra":2,
    \\ "round_duration_default_s":15,
    \\ "player_recipes":[],"team_recipes":[]}
;

/// Minimal valid encounters document for rejection tests.
const minimal_encounters =
    \\{"default":"e1","encounters":[
    \\ {"label":"e1","hunger_max":100,"zones":[{"neutral":5}]}]}
;

test "shipped data files parse and validate" {
    var loaded = try parse(
        std.testing.allocator,
        @embedFile("balance_data"),
        @embedFile("encounters_data"),
    );
    defer loaded.deinit();

    const cfg = &loaded.config;
    try std.testing.expect(cfg.balance.casts_per_round >= 1);
    try std.testing.expect(cfg.balance.player_recipes.len >= 1);
    try std.testing.expect(cfg.encounters.encounters.len >= 1);
    // Default encounter resolves and every zone count fits the wire bound
    // (guaranteed by validation; assert anyway as a regression tripwire).
    _ = cfg.encounters.default();
    for (cfg.encounters.encounters) |e| {
        try std.testing.expect(e.zones.len >= 1);
        try std.testing.expect(e.zones.len <= enc.MAX_ZONES);
    }
}

test "shipped balance parses to the expected shapes" {
    var loaded = try parse(
        std.testing.allocator,
        @embedFile("balance_data"),
        @embedFile("encounters_data"),
    );
    defer loaded.deinit();
    for (loaded.config.balance.player_recipes) |pr| {
        try std.testing.expect(pr.pattern.len >= 1);
        try std.testing.expect(pr.pattern.len <= c.MAX_COMBO_LEN);
    }
    for (loaded.config.balance.team_recipes) |tr| {
        try std.testing.expect(tr.patterns.len >= 1);
    }
}

test "minimal documents parse" {
    var loaded = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.config.balance.player_recipes.len);
    try std.testing.expectEqualStrings("e1", loaded.config.encounters.default().label);
}

test "unknown combo slot name is rejected" {
    const bad =
        \\{"casts_per_round":3,"units_per_slot":5,"medicine_per_slot":3,
        \\ "hunger_cost_normal":1,"hunger_cost_modified_extra":2,
        \\ "round_duration_default_s":15,
        \\ "player_recipes":[{"label":"x","pattern":["lava","dispense"],
        \\   "output":{"units":{"red":1}}}],
        \\ "team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidComboSlot,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "over-long combo pattern is rejected" {
    const bad =
        \\{"casts_per_round":3,"units_per_slot":5,"medicine_per_slot":3,
        \\ "hunger_cost_normal":1,"hunger_cost_modified_extra":2,
        \\ "round_duration_default_s":15,
        \\ "player_recipes":[{"label":"x",
        \\   "pattern":["red","dispense","dispense","dispense","dispense","dispense"],
        \\   "output":{"units":{"red":1}}}],
        \\ "team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidComboLength,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "realtime fields default when absent (pre-realtime configs stay valid)" {
    var loaded = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), loaded.config.balance.eat_rate_units_per_s, 0.001);
    try std.testing.expectEqual(@as(u32, 3000), loaded.config.balance.cast_window_ms);
}

test "zero eat_rate_units_per_s is rejected" {
    const bad =
        \\{"casts_per_round":3,"units_per_slot":5,"medicine_per_slot":3,
        \\ "hunger_cost_normal":1,"hunger_cost_modified_extra":2,
        \\ "round_duration_default_s":15,"eat_rate_units_per_s":0,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidEatRate,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "zero cast_window_ms is rejected" {
    const bad =
        \\{"casts_per_round":3,"units_per_slot":5,"medicine_per_slot":3,
        \\ "hunger_cost_normal":1,"hunger_cost_modified_extra":2,
        \\ "round_duration_default_s":15,"cast_window_ms":0,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidCastWindow,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "zero casts_per_round is rejected" {
    const bad =
        \\{"casts_per_round":0,"units_per_slot":5,"medicine_per_slot":3,
        \\ "hunger_cost_normal":1,"hunger_cost_modified_extra":2,
        \\ "round_duration_default_s":15,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidCastsPerRound,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "unknown top-level field is rejected (typo protection)" {
    const bad =
        \\{"casts_per_round":3,"units_per_slot":5,"medicine_per_slot":3,
        \\ "hunger_cost_normal":1,"hunger_cost_modified_extra":2,
        \\ "round_duration_default_s":15,"units_per_sloot":9,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidBalanceJson,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "unknown default encounter is rejected" {
    const bad =
        \\{"default":"nope","encounters":[
        \\ {"label":"e1","hunger_max":100,"zones":[{"neutral":5}]}]}
    ;
    try std.testing.expectError(
        ConfigError.UnknownDefaultEncounter,
        parse(std.testing.allocator, minimal_balance, bad),
    );
}

test "too many zones is rejected" {
    var buf: [4096]u8 = undefined;
    var w = std.io.fixedBufferStream(&buf);
    try w.writer().writeAll(
        \\{"default":"e1","encounters":[{"label":"e1","hunger_max":100,"zones":[
    );
    for (0..enc.MAX_ZONES + 1) |i| {
        if (i > 0) try w.writer().writeAll(",");
        try w.writer().writeAll(
            \\{"neutral":1}
        );
    }
    try w.writer().writeAll("]}]}");
    try std.testing.expectError(
        ConfigError.TooManyZones,
        parse(std.testing.allocator, minimal_balance, w.getWritten()),
    );
}

test "team recipe with zero patterns is rejected" {
    const bad =
        \\{"casts_per_round":3,"units_per_slot":5,"medicine_per_slot":3,
        \\ "hunger_cost_normal":1,"hunger_cost_modified_extra":2,
        \\ "round_duration_default_s":15,
        \\ "player_recipes":[],
        \\ "team_recipes":[{"label":"t","patterns":[],"output":{}}]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidTeamPatternCount,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}
