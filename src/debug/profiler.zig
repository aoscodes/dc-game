//! Tick profiler: comptime-named timing zones, zero heap allocation.
//!
//! Usage:
//!
//!   var prof = Profiler(zones).init();
//!   prof.begin(.drain);
//!   // ... work ...
//!   prof.end(.drain);
//!   if (prof.should_report()) prof.report(std.io.getStdErr().writer(), 0);
//!
//! `zones` is a comptime enum whose fields name each measurement zone.
//! All storage is inline in the Profiler struct; no heap is touched.

const std = @import("std");

pub const Zone = struct {
    total_ns: u64 = 0,
    count: u64 = 0,
    last_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    /// Wall-clock start of the current open `begin` call (0 = not open).
    start_ns: u64 = 0,
};

/// Returns a Profiler type parameterised by a comptime enum of zone names.
///
///   const Zones = enum { drain, atb, ai, effects, broadcast };
///   var p = Profiler(Zones).init();
///
pub fn Profiler(comptime ZoneEnum: type) type {
    const n = @typeInfo(ZoneEnum).@"enum".fields.len;
    return struct {
        const Self = @This();

        zones: [n]Zone = [_]Zone{.{}} ** n,
        /// How many `end` calls since the last `report`.
        calls_since_report: u32 = 0,

        pub fn init() Self {
            return .{};
        }

        /// Open a zone.  Calling `begin` twice on the same zone without an
        /// intervening `end` overwrites the start time (last-call wins).
        pub fn begin(self: *Self, comptime zone: ZoneEnum) void {
            const i = @intFromEnum(zone);
            self.zones[i].start_ns = @intCast(std.time.nanoTimestamp());
        }

        /// Close a zone and record the elapsed time.
        pub fn end(self: *Self, comptime zone: ZoneEnum) void {
            const now: u64 = @intCast(std.time.nanoTimestamp());
            const i = @intFromEnum(zone);
            const z = &self.zones[i];
            if (z.start_ns == 0) return; // begin was never called
            const elapsed = now - z.start_ns;
            z.last_ns = elapsed;
            z.total_ns += elapsed;
            z.count += 1;
            if (elapsed < z.min_ns) z.min_ns = elapsed;
            if (elapsed > z.max_ns) z.max_ns = elapsed;
            z.start_ns = 0;
            self.calls_since_report += 1;
        }

        /// True every `interval` total end-calls; use to throttle report output.
        pub fn should_report(self: *const Self, interval: u32) bool {
            return self.calls_since_report >= interval;
        }

        /// Write a table of zone stats to `writer`.  `label` is a prefix line.
        /// Resets `calls_since_report` to 0.
        pub fn report(self: *Self, writer: anytype, label: []const u8) void {
            if (label.len > 0) writer.print("--- profiler: {s} ---\n", .{label}) catch {};
            const fields = @typeInfo(ZoneEnum).@"enum".fields;
            inline for (fields, 0..) |f, i| {
                const z = &self.zones[i];
                if (z.count != 0) {
                    const avg = z.total_ns / z.count;
                    writer.print(
                        "  {s:<16} cnt={d:>6}  last={d:>7}us  avg={d:>7}us  min={d:>7}us  max={d:>7}us\n",
                        .{
                            f.name,
                            z.count,
                            z.last_ns / 1000,
                            avg / 1000,
                            z.min_ns / 1000,
                            z.max_ns / 1000,
                        },
                    ) catch {};
                }
            }
            self.calls_since_report = 0;
        }

        /// Convenience: dump stats to stderr using std.debug.print.
        /// Safe to call from any thread; does not require a writer.
        pub fn report_stderr(self: *Self, label: []const u8) void {
            if (label.len > 0) std.debug.print("--- profiler: {s} ---\n", .{label});
            const fields = @typeInfo(ZoneEnum).@"enum".fields;
            inline for (fields, 0..) |f, i| {
                const z = &self.zones[i];
                if (z.count != 0) {
                    const avg = z.total_ns / z.count;
                    std.debug.print(
                        "  {s:<16} cnt={d:>6}  last={d:>7}us  avg={d:>7}us  min={d:>7}us  max={d:>7}us\n",
                        .{
                            f.name,
                            z.count,
                            z.last_ns / 1000,
                            avg / 1000,
                            z.min_ns / 1000,
                            z.max_ns / 1000,
                        },
                    );
                }
            }
            self.calls_since_report = 0;
        }

        /// Zero all accumulated stats (keeps the struct alive).
        pub fn reset(self: *Self) void {
            self.zones = [_]Zone{.{}} ** n;
            self.calls_since_report = 0;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "profiler: zones record and report" {
    const Zones = enum { alpha, beta };
    var p = Profiler(Zones).init();

    p.begin(.alpha);
    std.time.sleep(1_000); // 1 µs
    p.end(.alpha);

    p.begin(.beta);
    p.end(.beta);

    try std.testing.expect(p.zones[@intFromEnum(Zones.alpha)].count == 1);
    try std.testing.expect(p.zones[@intFromEnum(Zones.beta)].count == 1);
    try std.testing.expect(p.zones[@intFromEnum(Zones.alpha)].total_ns >= 1_000);
}

test "profiler: should_report throttle" {
    const Zones = enum { x };
    var p = Profiler(Zones).init();
    try std.testing.expect(!p.should_report(3));
    p.begin(.x);
    p.end(.x);
    p.begin(.x);
    p.end(.x);
    try std.testing.expect(!p.should_report(3));
    p.begin(.x);
    p.end(.x);
    try std.testing.expect(p.should_report(3));
    // report resets counter
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    p.report(fbs.writer(), "test");
    try std.testing.expect(!p.should_report(3));
}

test "profiler: reset clears state" {
    const Zones = enum { z };
    var p = Profiler(Zones).init();
    p.begin(.z);
    p.end(.z);
    p.reset();
    try std.testing.expect(p.zones[0].count == 0);
}
