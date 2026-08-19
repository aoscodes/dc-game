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
    InvalidCastsPerTurn,
    InvalidSlimeGrid,
    TooManyRecipes,
    InvalidTeamPatternCount,
    InvalidComboLength,
    InvalidComboSlot,
    InvalidShapeSize,
    RaggedShape,
    EmptyShape,
    DuplicatePattern,
    EmptyLabel,
    LabelTooLong,
    NoEncounters,
    NoZones,
    TooManyZones,
    NoSlime,
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
// The tier JSON field order must match the Tier ordinals, since the loader
// converts named fields into ordinal-indexed arrays.
comptime {
    std.debug.assert(@intFromEnum(c.Tier.red) == 0);
    std.debug.assert(@intFromEnum(c.Tier.yellow) == 1);
    std.debug.assert(@intFromEnum(c.Tier.green) == 2);
}

const TiersU32Json = struct { red: u32 = 0, yellow: u32 = 0, green: u32 = 0 };
const TiersU16Json = struct { red: u16 = 0, yellow: u16 = 0, green: u16 = 0 };

const PlayerRecipeJson = struct {
    label: []const u8,
    /// Combo slots as strings: "dispense" | "medicine".
    pattern: []const []const u8,
    /// Footprint rows of `#` (covered) and any other char (not covered),
    /// e.g. ["###","###","###"] for a 3x3 block.
    shape: []const []const u8,
    /// Medicine brewed per tier.  Absent = a pure-neutralizing recipe.
    medicine: TiersU32Json = .{},
};

const TeamRecipeJson = struct {
    label: []const u8,
    patterns: []const []const []const u8,
    shape: []const []const u8,
    medicine: TiersU32Json = .{},
};

const SlimeGridJson = struct {
    rows: u8,
    cols: u8,
};

const BalanceJson = struct {
    hunger_cost_normal: u32,
    hunger_cost_hazard_extra: u32,
    /// Slime grid dimensions; defaulted so pre-grid configs keep validating.
    slime_grid: SlimeGridJson = .{
        .rows = balance.DEFAULT_SLIME_GRID.rows,
        .cols = balance.DEFAULT_SLIME_GRID.cols,
    },
    /// Defaulted so a config written before turns keeps validating.
    casts_per_turn: u8 = balance.DEFAULT_CASTS_PER_TURN,
    player_recipes: []const PlayerRecipeJson,
    team_recipes: []const TeamRecipeJson,
};

/// One slime bundle.  Historically one per round ("zone"); now purely an
/// additive slice of the encounter's single slime total.
const ZoneJson = struct {
    /// Hazard slime per difficulty tier.
    tiered: TiersU16Json = .{},
    neutral: u16 = 0,
};

const EncounterJson = struct {
    label: []const u8,
    hunger_max: u16,
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

    // A budget of 0 could never be spent, so the turn could never end and the
    // encounter would hang.  Rejected at load rather than deadlocking at play.
    if (raw.casts_per_turn < 1) {
        fail("{s}: casts_per_turn must be >= 1", .{BALANCE_FILE});
        return ConfigError.InvalidCastsPerTurn;
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
            .shape = try shape_from_rows(a, pr.label, pr.shape),
            .medicine = medicine_from_json(pr.medicine),
        };
    }
    // Two recipes sharing a combo would make the move ambiguous: the first
    // would always win and the second would be dead data.
    try reject_duplicate_patterns(players);

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
            .shape = try shape_from_rows(a, tr.label, tr.shape),
            .medicine = medicine_from_json(tr.medicine),
        };
    }

    return .{
        .hunger_cost_normal = raw.hunger_cost_normal,
        .hunger_cost_hazard_extra = raw.hunger_cost_hazard_extra,
        .slime_grid = .{ .rows = raw.slime_grid.rows, .cols = raw.slime_grid.cols },
        .casts_per_turn = raw.casts_per_turn,
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
        // Sum every bundle into the encounter's single slime total; saturating
        // so a designer config cannot overflow the u16 buckets.
        var slime = c.SlimeReservoir{};
        for (e.zones) |z| {
            slime.neutral +|= z.neutral;
            const per_tier = [_]u16{ z.tiered.red, z.tiered.yellow, z.tiered.green };
            for (&slime.tiered, per_tier) |*acc, add| acc.* +|= add;
        }
        if (slime.is_empty()) {
            fail("{s}: encounter '{s}' has no slime", .{ ENCOUNTERS_FILE, e.label });
            return ConfigError.NoSlime;
        }
        out.* = .{ .label = e.label, .hunger_max = e.hunger_max, .slime = slime };
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

fn medicine_from_json(m: TiersU32Json) c.MedicineOutput {
    return .{ .medicine = .{ m.red, m.yellow, m.green } };
}

fn slot_from_name(name: []const u8) ?c.ComboSlot {
    if (std.meta.stringToEnum(c.ActionChoice, name)) |action| return .{ .action = action };
    return null;
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

/// Player combos are matched first-hit, so a repeated pattern silently
/// shadows the later recipe.  Reject it at load rather than ship dead data.
fn reject_duplicate_patterns(recipes: []const balance.PlayerRecipe) !void {
    for (recipes, 0..) |a_rec, i| {
        for (recipes[i + 1 ..]) |b_rec| {
            if (game_logic.combos_equal(a_rec.pattern, b_rec.pattern)) {
                fail("{s}: recipes '{s}' and '{s}' share the same pattern", .{ BALANCE_FILE, a_rec.label, b_rec.label });
                return ConfigError.DuplicatePattern;
            }
        }
    }
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
            fail("{s}: recipe '{s}' has unknown slot '{s}' (want dispense|medicine)", .{ BALANCE_FILE, recipe_label, name });
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
    \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
    \\ "player_recipes":[],"team_recipes":[]}
;

/// Minimal valid encounters document for rejection tests.
const minimal_encounters =
    \\{"default":"e1","encounters":[
    \\ {"label":"e1","hunger_max":100,"zones":[{"neutral":5}]}]}
;

/// A one-recipe balance document, `{...}`-interpolated at the recipe body so
/// each rejection test states only the field it is exercising.
fn one_recipe(comptime body: []const u8) []const u8 {
    return "{\"hunger_cost_normal\":1,\"hunger_cost_hazard_extra\":2," ++
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

test "every shipped recipe has a legal combo and a real footprint" {
    var loaded = try parse(
        std.testing.allocator,
        @embedFile("balance_data"),
        @embedFile("encounters_data"),
    );
    defer loaded.deinit();
    const bal = &loaded.config.balance;
    for (bal.player_recipes) |pr| {
        try std.testing.expect(pr.pattern.len >= 1);
        try std.testing.expect(pr.pattern.len <= c.MAX_COMBO_LEN);
        try std.testing.expect(pr.shape.size() >= 1);
    }
    for (bal.team_recipes) |tr| {
        try std.testing.expect(tr.patterns.len >= 1);
        try std.testing.expect(tr.shape.size() >= 1);
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
            \\{"label":"x","pattern":["dispense"],"shape":["###","###","###"]}
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
            \\{"label":"x","pattern":["dispense"],"shape":["#.#",".#.","#.#"]}
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
            \\{"label":"x","pattern":["dispense"],"shape":["#"]}
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
            \\{"label":"x","pattern":["dispense"],"shape":["...","..."]}
        ),
        minimal_encounters,
    ));
}

test "a shape with no rows is rejected" {
    try std.testing.expectError(ConfigError.InvalidShapeSize, parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"x","pattern":["dispense"],"shape":[]}
        ),
        minimal_encounters,
    ));
}

test "a ragged shape is rejected" {
    try std.testing.expectError(ConfigError.RaggedShape, parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"x","pattern":["dispense"],"shape":["###","#"]}
        ),
        minimal_encounters,
    ));
}

test "an over-tall shape is rejected" {
    // MAX_SHAPE_ROWS + 1 rows of a single cell.
    const rows = "[" ++ "\"#\"," ** balance.MAX_SHAPE_ROWS ++ "\"#\"]";
    try std.testing.expectError(ConfigError.InvalidShapeSize, parse(
        std.testing.allocator,
        one_recipe("{\"label\":\"x\",\"pattern\":[\"dispense\"],\"shape\":" ++ rows ++ "}"),
        minimal_encounters,
    ));
}

test "an over-wide shape is rejected" {
    const wide = "\"" ++ "#" ** (balance.MAX_SHAPE_COLS + 1) ++ "\"";
    try std.testing.expectError(ConfigError.InvalidShapeSize, parse(
        std.testing.allocator,
        one_recipe("{\"label\":\"x\",\"pattern\":[\"dispense\"],\"shape\":[" ++ wide ++ "]}"),
        minimal_encounters,
    ));
}

test "two recipes sharing a pattern are rejected" {
    // The second would be unreachable: first-hit matching shadows it.
    try std.testing.expectError(ConfigError.DuplicatePattern, parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"a","pattern":["dispense","medicine"],"shape":["#"]},
            \\{"label":"b","pattern":["dispense","medicine"],"shape":["##"]}
        ),
        minimal_encounters,
    ));
}

test "recipes differing only in order are distinct patterns" {
    var loaded = try parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"a","pattern":["dispense","medicine"],"shape":["#"]},
            \\{"label":"b","pattern":["medicine","dispense"],"shape":["##"]}
        ),
        minimal_encounters,
    );
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.config.balance.player_recipes.len);
}

test "medicine is keyed by tier and defaults to none" {
    var loaded = try parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"plain","pattern":["dispense"],"shape":["#"]},
            \\{"label":"tonic","pattern":["medicine"],"shape":["#"],
            \\ "medicine":{"red":7,"green":2}}
        ),
        minimal_encounters,
    );
    defer loaded.deinit();
    const recipes = loaded.config.balance.player_recipes;
    try std.testing.expectEqual(@as(u32, 0), recipes[0].medicine.total());
    try std.testing.expectEqual(@as(u32, 7), recipes[1].medicine.medicine[@intFromEnum(c.Tier.red)]);
    try std.testing.expectEqual(@as(u32, 0), recipes[1].medicine.medicine[@intFromEnum(c.Tier.yellow)]);
    try std.testing.expectEqual(@as(u32, 2), recipes[1].medicine.medicine[@intFromEnum(c.Tier.green)]);
}

test "an element name is no longer a valid combo slot" {
    // Colors are difficulty tiers now; they were never castable input.
    try std.testing.expectError(ConfigError.InvalidComboSlot, parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"x","pattern":["red","dispense"],"shape":["#"]}
        ),
        minimal_encounters,
    ));
}

test "unknown combo slot name is rejected" {
    try std.testing.expectError(ConfigError.InvalidComboSlot, parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"x","pattern":["lava","dispense"],"shape":["#"]}
        ),
        minimal_encounters,
    ));
}

test "over-long combo pattern is rejected" {
    try std.testing.expectError(ConfigError.InvalidComboLength, parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"x","shape":["#"],
            \\ "pattern":["dispense","dispense","dispense","dispense","dispense","dispense"]}
        ),
        minimal_encounters,
    ));
}

test "empty combo pattern is rejected" {
    try std.testing.expectError(ConfigError.InvalidComboLength, parse(
        std.testing.allocator,
        one_recipe(
            \\{"label":"x","pattern":[],"shape":["#"]}
        ),
        minimal_encounters,
    ));
}

test "casts_per_turn defaults when absent" {
    var loaded = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(
        balance.DEFAULT_CASTS_PER_TURN,
        loaded.config.balance.casts_per_turn,
    );
}

test "slime_grid defaults when absent" {
    var loaded = try parse(std.testing.allocator, minimal_balance, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(balance.DEFAULT_SLIME_GRID.rows, loaded.config.balance.slime_grid.rows);
    try std.testing.expectEqual(balance.DEFAULT_SLIME_GRID.cols, loaded.config.balance.slime_grid.cols);
}

test "slime_grid is read from the document" {
    const doc =
        \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
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
        \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
        \\ "slime_grid":{"rows":0,"cols":8},
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidSlimeGrid,
        parse(std.testing.allocator, zero, minimal_encounters),
    );
    const too_big =
        \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
        \\ "slime_grid":{"rows":8,"cols":99},
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidSlimeGrid,
        parse(std.testing.allocator, too_big, minimal_encounters),
    );
}

test "zero casts_per_turn is rejected" {
    // A budget that can never be spent is a turn that can never end.
    const bad =
        \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
        \\ "casts_per_turn":0,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidCastsPerTurn,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "casts_per_turn is read from the document" {
    const doc =
        \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
        \\ "casts_per_turn":7,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u8, 7), loaded.config.balance.casts_per_turn);
}

test "retired realtime fields are rejected" {
    // The turn loop has no buffers, locks or per-second eat rate.  Leaving a
    // stale tunable in a config would silently do nothing, so std.json's
    // unknown-field strictness is the intended behaviour here.
    for ([_][]const u8{
        \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
        \\ "eat_rate_units_per_s":2.0,
        \\ "player_recipes":[],"team_recipes":[]}
        ,
        \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
        \\ "cast_buffer_ms":500,
        \\ "player_recipes":[],"team_recipes":[]}
        ,
        \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
        \\ "cast_lock_ms":500,
        \\ "player_recipes":[],"team_recipes":[]}
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
        \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
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
        \\{"units_per_slot":5,"medicine_per_slot":3,
        \\ "hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
        \\ "player_recipes":[],"team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidBalanceJson,
        parse(std.testing.allocator, stale, minimal_encounters),
    );
}

test "a recipe without a shape is rejected" {
    const bad =
        \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
        \\ "player_recipes":[{"label":"x","pattern":["dispense"]}],
        \\ "team_recipes":[]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidBalanceJson,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "team recipes carry one shared shape" {
    const doc =
        \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
        \\ "player_recipes":[],
        \\ "team_recipes":[{"label":"t","patterns":[["dispense"],["medicine"]],
        \\   "shape":["#####"],"medicine":{"yellow":3}}]}
    ;
    var loaded = try parse(std.testing.allocator, doc, minimal_encounters);
    defer loaded.deinit();
    const tr = loaded.config.balance.team_recipes[0];
    try std.testing.expectEqual(@as(usize, 2), tr.patterns.len);
    try std.testing.expectEqual(@as(usize, 5), tr.shape.size());
    try std.testing.expectEqual(@as(u32, 3), tr.medicine.medicine[@intFromEnum(c.Tier.yellow)]);
}

test "team recipe with zero patterns is rejected" {
    const bad =
        \\{"hunger_cost_normal":1,"hunger_cost_hazard_extra":2,
        \\ "player_recipes":[],
        \\ "team_recipes":[{"label":"t","patterns":[],"shape":["#"]}]}
    ;
    try std.testing.expectError(
        ConfigError.InvalidTeamPatternCount,
        parse(std.testing.allocator, bad, minimal_encounters),
    );
}

test "legacy multi-zone encounters are summed into one slime total" {
    const doc =
        \\{"default":"e1","encounters":[
        \\ {"label":"e1","hunger_max":100,"zones":[
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

test "encounter with no slime at all is rejected" {
    const bad =
        \\{"default":"e1","encounters":[
        \\ {"label":"e1","hunger_max":100,"zones":[{"neutral":0}]}]}
    ;
    try std.testing.expectError(
        ConfigError.NoSlime,
        parse(std.testing.allocator, minimal_balance, bad),
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
    const zone = "{\"neutral\":1},";
    const bad = "{\"default\":\"e1\",\"encounters\":[{\"label\":\"e1\"," ++
        "\"hunger_max\":100,\"zones\":[" ++
        zone ** (enc.MAX_ZONES) ++ "{\"neutral\":1}]}]}";
    try std.testing.expectError(
        ConfigError.TooManyZones,
        parse(std.testing.allocator, minimal_balance, bad),
    );
}
