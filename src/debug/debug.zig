//! Debug and development tooling module.
//!
//! Sub-modules:
//!   profiler            — comptime-named tick profiler (zero heap)
//!   inspector           — comptime entity/component inspector (any writer)
//!   snapshot            — binary ECS world snapshot (write + read)
//!   replay              — proto.GameState frame recorder and player
//!   tracking_allocator  — wrapping allocator with atomic allocation stats
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

// Re-export the most-used types at module level for convenience.
pub const Profiler = profiler.Profiler;
pub const TrackingAllocator = tracking_allocator.TrackingAllocator;

// Pull every sub-module's tests into `zig build debug-test` so they can't
// rot silently (unreferenced files are never semantically analysed).
test {
    _ = profiler;
    _ = inspector;
    _ = snapshot;
    _ = replay;
    _ = tracking_allocator;
}
