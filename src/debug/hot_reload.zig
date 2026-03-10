//! Wave hot-reload: watches a JSON file for mtime changes and re-parses it.
//!
//! The watcher polls `std.fs.File.stat().mtime` each tick (cheap; no inotify
//! dependency — works on macOS, Linux, Windows).  On change the file is
//! re-read and parsed into a heap-allocated WaveConfig that replaces the
//! previous one.  If no file exists the static waves.zig data is used.
//!
//! JSON schema (mirrors waves.zig structures):
//!
//!   {
//!     "waves": [
//!       {
//!         "label": "wave_01_basic",
//!         "next_wave": null,          // or "wave_02_spread"
//!         "entries": [
//!           { "class": "grunt", "grid_col": 0, "grid_row": 0 },
//!           { "class": "grunt", "grid_col": 1, "grid_row": 0,
//!             "attack": 15, "defense": 0, "speed_base": 0.0, "max_hp": 0 }
//!         ]
//!       }
//!     ]
//!   }
//!
//! Stat overrides are optional; zero values mean "use class default".
//!
//! Usage:
//!
//!   var watcher = try WaveWatcher.init("waves.json", allocator);
//!   defer watcher.deinit();
//!
//!   // in tick loop:
//!   if (watcher.poll()) {
//!     // watcher.config() now returns updated data
//!   }
//!   const wave = watcher.find_wave("wave_01_basic") orelse fallback;

const std = @import("std");
const waves_static = @import("shared").waves;
const components = @import("shared").components;

// ---------------------------------------------------------------------------
// Runtime wave data (heap-allocated parallel to waves.zig static types)
// ---------------------------------------------------------------------------

pub const RuntimeEntry = struct {
    class: components.ClassTag,
    grid_col: u2,
    grid_row: u2,
    attack: u16,
    defense: u16,
    speed_base: f32,
    max_hp: u16,
};

pub const RuntimeWave = struct {
    label: []const u8,
    entries: []RuntimeEntry,
    next_wave: ?[]const u8,
};

pub const WaveConfig = struct {
    waves: []RuntimeWave,
};

// ---------------------------------------------------------------------------
// WaveWatcher
// ---------------------------------------------------------------------------

pub const WaveWatcher = struct {
    path: []const u8,
    allocator: std.mem.Allocator,
    last_mtime: i128 = 0,
    /// Null when no valid config has been loaded yet.
    current: ?WaveConfig = null,
    /// Arena for the current WaveConfig; reset on each reload.
    arena: std.heap.ArenaAllocator,

    pub fn init(path: []const u8, allocator: std.mem.Allocator) !WaveWatcher {
        var w = WaveWatcher{
            .path = path,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        // Attempt an initial load; failure is non-fatal.
        _ = w.try_reload();
        return w;
    }

    pub fn deinit(self: *WaveWatcher) void {
        self.arena.deinit();
    }

    /// Returns true if the file changed and was successfully reloaded.
    pub fn poll(self: *WaveWatcher) bool {
        const file = std.fs.cwd().openFile(self.path, .{}) catch return false;
        defer file.close();
        const stat = file.stat() catch return false;
        if (stat.mtime == self.last_mtime) return false;
        self.last_mtime = stat.mtime;
        return self.try_reload();
    }

    /// Find a runtime wave by label.  Returns null when not found in the loaded
    /// config; callers should fall back to waves_static.find_wave.
    pub fn find_runtime_wave(self: *const WaveWatcher, label: []const u8) ?*const RuntimeWave {
        const cfg = self.current orelse return null;
        for (cfg.waves) |*rw| {
            if (std.mem.eql(u8, rw.label, label)) return rw;
        }
        return null;
    }

    /// Find a wave by label: checks loaded config first, falls back to static.
    /// Returns a static Wave shell (label + next_wave only) for loaded waves;
    /// use `find_runtime_wave` to get the full entry list for spawning.
    pub fn find_wave(self: *const WaveWatcher, label: []const u8) ?waves_static.Wave {
        if (self.find_runtime_wave(label)) |rw| {
            return waves_static.Wave{
                .label = rw.label,
                .entries = &.{}, // entries accessed via find_runtime_wave
                .next_wave = rw.next_wave,
            };
        }
        return if (waves_static.find_wave(label)) |w| w.* else null;
    }

    // ------------------------------------------------------------------
    // Private
    // ------------------------------------------------------------------

    fn try_reload(self: *WaveWatcher) bool {
        const data = std.fs.cwd().readFileAlloc(
            self.arena.allocator(),
            self.path,
            1024 * 256,
        ) catch return false;

        const parsed = std.json.parseFromSlice(
            JsonRoot,
            self.arena.allocator(),
            data,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.log.warn("hot_reload: parse error: {}", .{err});
            return false;
        };
        defer parsed.deinit();

        // Reset and rebuild into arena
        _ = self.arena.reset(.retain_capacity);
        const arena_alloc = self.arena.allocator();

        const n_waves = parsed.value.waves.len;
        const runtime_waves = arena_alloc.alloc(RuntimeWave, n_waves) catch return false;

        for (parsed.value.waves, 0..) |jw, i| {
            const n_entries = jw.entries.len;
            const entries = arena_alloc.alloc(RuntimeEntry, n_entries) catch return false;
            for (jw.entries, 0..) |je, j| {
                const class = std.meta.stringToEnum(components.ClassTag, je.class) orelse {
                    std.log.warn("hot_reload: unknown class '{s}'", .{je.class});
                    return false;
                };
                entries[j] = .{
                    .class = class,
                    .grid_col = @intCast(@min(je.grid_col, 3)),
                    .grid_row = @intCast(@min(je.grid_row, 3)),
                    .attack = je.attack,
                    .defense = je.defense,
                    .speed_base = je.speed_base,
                    .max_hp = je.max_hp,
                };
            }
            const label = arena_alloc.dupe(u8, jw.label) catch return false;
            const next = if (jw.next_wave) |nw|
                arena_alloc.dupe(u8, nw) catch return false
            else
                null;
            runtime_waves[i] = .{ .label = label, .entries = entries, .next_wave = next };
        }

        self.current = WaveConfig{ .waves = runtime_waves };
        std.log.info("hot_reload: loaded {} waves from '{s}'", .{ n_waves, self.path });
        return true;
    }
};

// ---------------------------------------------------------------------------
// JSON schema types (only fields we need)
// ---------------------------------------------------------------------------

const JsonEntry = struct {
    class: []const u8,
    grid_col: u8,
    grid_row: u8,
    attack: u16 = 0,
    defense: u16 = 0,
    speed_base: f32 = 0.0,
    max_hp: u16 = 0,
};

const JsonWave = struct {
    label: []const u8,
    entries: []JsonEntry,
    next_wave: ?[]const u8 = null,
};

const JsonRoot = struct {
    waves: []JsonWave,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "hot_reload: init with missing file is non-fatal" {
    var w = try WaveWatcher.init("nonexistent_waves_file.json", std.testing.allocator);
    defer w.deinit();
    try std.testing.expect(w.current == null);
    // poll returns false (file missing)
    try std.testing.expect(!w.poll());
}

test "hot_reload: find_wave falls back to static data" {
    var w = try WaveWatcher.init("nonexistent_waves_file.json", std.testing.allocator);
    defer w.deinit();
    const wave = w.find_wave("wave_01_basic");
    try std.testing.expect(wave != null);
    try std.testing.expectEqualStrings("wave_01_basic", wave.?.label);
}
