//! Scripted enemy wave definitions.
//!
//! A Wave is a comptime constant slice of SpawnEntry values describing the
//! initial enemy composition for one battle encounter.  The server loads a
//! wave by label at game-start and again whenever `next_wave` is non-null and
//! all enemies from the previous wave are dead.
//!
//! Adding a new wave: append a new `pub const wave_XX` below, then add it to
//! `ALL_WAVES`.  No other file needs to change.

const components = @import("components.zig");
const ClassTag = components.ClassTag;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Per-stat overrides for a single spawn entry.
/// A field value of 0 means "use the class default" (see default_stats below).
pub const StatOverride = struct {
    attack: u16 = 0,
    defense: u16 = 0,
    speed_base: f32 = 0.0,
    max_hp: u16 = 0,
};

pub const SpawnEntry = struct {
    class: ClassTag,
    grid_col: u2,
    grid_row: u2,
    /// Zero fields fall back to class defaults (see `resolve_stats`).
    stats: StatOverride = .{},
};

pub const Wave = struct {
    /// Human-readable identifier; also used as the key in ALL_WAVES.
    label: []const u8,
    entries: []const SpawnEntry,
    /// Label of the wave to load after this one is cleared.
    /// null = this is the final wave; game ends on clear.
    next_wave: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Class default stats
// ---------------------------------------------------------------------------

pub const DefaultStats = struct {
    attack: u16,
    defense: u16,
    speed_base: f32,
    max_hp: u16,
};

pub fn class_defaults(tag: ClassTag) DefaultStats {
    return switch (tag) {
        .grunt => .{ .attack = 12, .defense = 8, .speed_base = 0.18, .max_hp = 80 },
        .archer => .{ .attack = 18, .defense = 4, .speed_base = 0.22, .max_hp = 55 },
        .shaman => .{ .attack = 8, .defense = 6, .speed_base = 0.15, .max_hp = 60 },
        .boss => .{ .attack = 25, .defense = 16, .speed_base = 0.10, .max_hp = 220 },
        // Player classes: defaults used during playtesting when no human stat
        // sheet is provided.
        .fighter => .{ .attack = 20, .defense = 14, .speed_base = 0.20, .max_hp = 120 },
        .mage => .{ .attack = 28, .defense = 5, .speed_base = 0.17, .max_hp = 70 },
        .healer => .{ .attack = 10, .defense = 8, .speed_base = 0.16, .max_hp = 80 },
    };
}

/// Apply a StatOverride on top of class defaults; zero fields keep the default.
pub fn resolve_stats(class: ClassTag, override: StatOverride) DefaultStats {
    const d = class_defaults(class);
    return .{
        .attack = if (override.attack != 0) override.attack else d.attack,
        .defense = if (override.defense != 0) override.defense else d.defense,
        .speed_base = if (override.speed_base != 0.0) override.speed_base else d.speed_base,
        .max_hp = if (override.max_hp != 0) override.max_hp else d.max_hp,
    };
}

// ---------------------------------------------------------------------------
// Wave scripts
// ---------------------------------------------------------------------------

/// wave_01_basic — three grunts in the front rank; easiest encounter.
pub const wave_01_basic = Wave{
    .label = "wave_01_basic",
    .entries = &[_]SpawnEntry{
        .{ .class = .grunt, .grid_col = 0, .grid_row = 0 },
        .{ .class = .grunt, .grid_col = 1, .grid_row = 0 },
        .{ .class = .grunt, .grid_col = 2, .grid_row = 0 },
    },
    .next_wave = "wave_02_spread",
};

/// wave_02_spread — grunts and archers spread across all three rows.
pub const wave_02_spread = Wave{
    .label = "wave_02_spread",
    .entries = &[_]SpawnEntry{
        .{ .class = .grunt, .grid_col = 0, .grid_row = 0 },
        .{ .class = .grunt, .grid_col = 2, .grid_row = 0 },
        .{ .class = .archer, .grid_col = 1, .grid_row = 1 },
        .{ .class = .archer, .grid_col = 0, .grid_row = 2 },
        .{ .class = .archer, .grid_col = 2, .grid_row = 2 },
    },
    .next_wave = "wave_03_healer_back",
};

/// wave_03_healer_back — shaman healing from back rank while grunts shield it.
pub const wave_03_healer_back = Wave{
    .label = "wave_03_healer_back",
    .entries = &[_]SpawnEntry{
        .{ .class = .grunt, .grid_col = 0, .grid_row = 0 },
        .{ .class = .grunt, .grid_col = 1, .grid_row = 0 },
        .{ .class = .grunt, .grid_col = 2, .grid_row = 0 },
        .{ .class = .shaman, .grid_col = 1, .grid_row = 2 },
    },
    .next_wave = "wave_04_all_archers",
};

/// wave_04_all_archers — four archers; AoE-heavy stress test for healers.
pub const wave_04_all_archers = Wave{
    .label = "wave_04_all_archers",
    .entries = &[_]SpawnEntry{
        .{ .class = .archer, .grid_col = 0, .grid_row = 0 },
        .{ .class = .archer, .grid_col = 2, .grid_row = 0 },
        .{ .class = .archer, .grid_col = 0, .grid_row = 2 },
        .{ .class = .archer, .grid_col = 2, .grid_row = 2 },
    },
    .next_wave = "wave_05_boss_plus_grunts",
};

/// wave_05_boss_plus_grunts — high-HP boss flanked by two grunts.
pub const wave_05_boss_plus_grunts = Wave{
    .label = "wave_05_boss_plus_grunts",
    .entries = &[_]SpawnEntry{
        .{ .class = .grunt, .grid_col = 0, .grid_row = 0 },
        .{ .class = .grunt, .grid_col = 2, .grid_row = 0 },
        .{ .class = .boss, .grid_col = 1, .grid_row = 1 },
    },
    .next_wave = "wave_06_full_grid",
};

/// wave_06_full_grid — six enemies filling a dense 3×2 front; maximum pressure.
pub const wave_06_full_grid = Wave{
    .label = "wave_06_full_grid",
    .entries = &[_]SpawnEntry{
        .{ .class = .grunt, .grid_col = 0, .grid_row = 0 },
        .{ .class = .grunt, .grid_col = 1, .grid_row = 0 },
        .{ .class = .grunt, .grid_col = 2, .grid_row = 0 },
        .{ .class = .archer, .grid_col = 0, .grid_row = 1 },
        .{ .class = .shaman, .grid_col = 1, .grid_row = 2 },
        .{ .class = .archer, .grid_col = 2, .grid_row = 1 },
    },
    // Final wave; next_wave = null.
};

// ---------------------------------------------------------------------------
// Registry — all waves indexed by label
// ---------------------------------------------------------------------------

pub const WaveEntry = struct {
    label: []const u8,
    wave: *const Wave,
};

/// Flat list of all available waves.  Used by the server to look up a wave by
/// label string at runtime.
pub const ALL_WAVES = [_]WaveEntry{
    .{ .label = wave_01_basic.label, .wave = &wave_01_basic },
    .{ .label = wave_02_spread.label, .wave = &wave_02_spread },
    .{ .label = wave_03_healer_back.label, .wave = &wave_03_healer_back },
    .{ .label = wave_04_all_archers.label, .wave = &wave_04_all_archers },
    .{ .label = wave_05_boss_plus_grunts.label, .wave = &wave_05_boss_plus_grunts },
    .{ .label = wave_06_full_grid.label, .wave = &wave_06_full_grid },
};

/// Look up a wave by label.  Returns null if not found.
pub fn find_wave(label: []const u8) ?*const Wave {
    for (&ALL_WAVES) |entry| {
        if (std.mem.eql(u8, entry.label, label)) return entry.wave;
    }
    return null;
}

const std = @import("std");
