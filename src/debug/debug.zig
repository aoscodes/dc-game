//! Debug and development tooling module.
//!
//! Sub-modules:
//!   profiler            — comptime-named tick profiler (zero heap)
//!   inspector           — comptime entity/component inspector (any writer)
//!   snapshot            — binary ECS world snapshot (write + read)
//!   replay              — proto.GameState frame recorder and player
//!   tracking_allocator  — wrapping allocator with atomic allocation stats
//!   hot_reload          — JSON wave file watcher with mtime polling
//!
//! Import the whole module:
//!
//!   const dbg = @import("debug_zig");
//!   var prof = dbg.profiler.Profiler(MyZones).init();
//!   dbg.inspector.inspect(&world, entity, writer);

pub const profiler = @import("profiler.zig");
pub const inspector = @import("inspector.zig");
pub const snapshot = @import("snapshot.zig");
pub const replay = @import("replay.zig");
pub const tracking_allocator = @import("tracking_allocator.zig");
pub const hot_reload = @import("hot_reload.zig");

// Re-export the most-used types at module level for convenience.
pub const Profiler = profiler.Profiler;
pub const TrackingAllocator = tracking_allocator.TrackingAllocator;
pub const WaveWatcher = hot_reload.WaveWatcher;
