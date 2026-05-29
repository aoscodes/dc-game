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
const EntityKind = components.EntityKind;
const Statblock = components.Statblock;

pub const SpawnEntry = struct {
    kind: EntityKind,
    grid_col: u2,
    grid_row: u2,
    stats: Statblock,
};

pub const Wave = struct {
    label: []const u8,
    entries: []const SpawnEntry,
    next_wave: ?[]const u8 = null,
};

pub const wave_01_basic = Wave{
    .label = "wave_01_basic",
    .entries = &[_]SpawnEntry{
        .{ .kind = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
    },
    .next_wave = null,
};

pub const wave_02_spread = Wave{
    .label = "wave_02_spread",
    .entries = &[_]SpawnEntry{
        .{ .kind = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .grunt, .grid_col = 2, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .archer, .grid_col = 1, .grid_row = 1, .stats = .{ .hp = 55, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .archer, .grid_col = 0, .grid_row = 2, .stats = .{ .hp = 55, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .archer, .grid_col = 2, .grid_row = 2, .stats = .{ .hp = 55, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
    },
    .next_wave = "wave_03_healer_back",
};

pub const wave_03_healer_back = Wave{
    .label = "wave_03_healer_back",
    .entries = &[_]SpawnEntry{
        .{ .kind = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .grunt, .grid_col = 1, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .grunt, .grid_col = 2, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .shaman, .grid_col = 1, .grid_row = 2, .stats = .{ .hp = 60, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
    },
    .next_wave = "wave_04_all_archers",
};

pub const wave_04_all_archers = Wave{
    .label = "wave_04_all_archers",
    .entries = &[_]SpawnEntry{
        .{ .kind = .archer, .grid_col = 0, .grid_row = 0, .stats = .{ .hp = 55, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .archer, .grid_col = 2, .grid_row = 0, .stats = .{ .hp = 55, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .archer, .grid_col = 0, .grid_row = 2, .stats = .{ .hp = 55, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .archer, .grid_col = 2, .grid_row = 2, .stats = .{ .hp = 55, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
    },
    .next_wave = "wave_05_boss_plus_grunts",
};

pub const wave_05_boss_plus_grunts = Wave{
    .label = "wave_05_boss_plus_grunts",
    .entries = &[_]SpawnEntry{
        .{ .kind = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .grunt, .grid_col = 2, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .boss, .grid_col = 1, .grid_row = 1, .stats = .{ .hp = 220, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
    },
    .next_wave = "wave_06_full_grid",
};

pub const wave_06_full_grid = Wave{
    .label = "wave_06_full_grid",
    .entries = &[_]SpawnEntry{
        .{ .kind = .grunt, .grid_col = 0, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .grunt, .grid_col = 1, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .grunt, .grid_col = 2, .grid_row = 0, .stats = .{ .hp = 80, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .archer, .grid_col = 0, .grid_row = 1, .stats = .{ .hp = 55, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .shaman, .grid_col = 1, .grid_row = 2, .stats = .{ .hp = 60, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
        .{ .kind = .archer, .grid_col = 2, .grid_row = 1, .stats = .{ .hp = 55, .attack = 1, .shield = 1, .heal = 1, .fire = 1, .earth = 1, .wind = 1, .water = 1, .level = 1 } },
    },
};

pub const WaveEntry = struct {
    label: []const u8,
    wave: *const Wave,
};

pub const ALL_WAVES = [_]WaveEntry{
    .{ .label = wave_01_basic.label, .wave = &wave_01_basic },
    .{ .label = wave_02_spread.label, .wave = &wave_02_spread },
    .{ .label = wave_03_healer_back.label, .wave = &wave_03_healer_back },
    .{ .label = wave_04_all_archers.label, .wave = &wave_04_all_archers },
    .{ .label = wave_05_boss_plus_grunts.label, .wave = &wave_05_boss_plus_grunts },
    .{ .label = wave_06_full_grid.label, .wave = &wave_06_full_grid },
};

pub fn find_wave(label: []const u8) ?*const Wave {
    for (&ALL_WAVES) |entry| {
        if (std.mem.eql(u8, entry.label, label)) return entry.wave;
    }
    return null;
}

const std = @import("std");
