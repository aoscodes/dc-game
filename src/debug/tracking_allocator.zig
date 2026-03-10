//! Wrapping allocator that counts allocations, frees, and peak bytes.
//!
//! All stat updates use atomic operations so the allocator is safe to use
//! from multiple threads (e.g. tick thread + WS handler threads).
//!
//! Usage:
//!
//!   var ta = TrackingAllocator.init(gpa.allocator());
//!   defer ta.report("server", std.io.getStdErr().writer());
//!   const allocator = ta.allocator();
//!   // ... pass allocator to Session.init, etc.
//!
//!   // Inspect live stats at any time:
//!   const s = ta.stats();
//!   std.log.debug("heap: {} bytes current, {} peak", .{s.current_bytes, s.peak_bytes});

const std = @import("std");

pub const Stats = struct {
    alloc_count: u64,
    free_count: u64,
    /// Bytes currently allocated (alloc - freed).
    current_bytes: u64,
    /// Maximum value `current_bytes` has ever reached.
    peak_bytes: u64,
    /// Total bytes ever allocated (monotonic).
    total_bytes: u64,
};

pub const TrackingAllocator = struct {
    backing: std.mem.Allocator,

    alloc_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    free_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    current_bytes: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    peak_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(backing: std.mem.Allocator) TrackingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn stats(self: *const TrackingAllocator) Stats {
        const cur = self.current_bytes.load(.monotonic);
        return .{
            .alloc_count = self.alloc_count.load(.monotonic),
            .free_count = self.free_count.load(.monotonic),
            .current_bytes = if (cur > 0) @intCast(cur) else 0,
            .peak_bytes = self.peak_bytes.load(.monotonic),
            .total_bytes = self.total_bytes.load(.monotonic),
        };
    }

    pub fn reset_peak(self: *TrackingAllocator) void {
        const cur: u64 = @intCast(@max(0, self.current_bytes.load(.monotonic)));
        self.peak_bytes.store(cur, .monotonic);
    }

    pub fn report(self: *const TrackingAllocator, label: []const u8, writer: anytype) void {
        const s = self.stats();
        writer.print(
            "--- alloc tracker: {s} ---\n" ++
                "  allocs:  {d}\n" ++
                "  frees:   {d}\n" ++
                "  current: {d} bytes\n" ++
                "  peak:    {d} bytes\n" ++
                "  total:   {d} bytes\n",
            .{ label, s.alloc_count, s.free_count, s.current_bytes, s.peak_bytes, s.total_bytes },
        ) catch {};
    }

    /// Convenience: dump stats to stderr using std.debug.print.
    pub fn report_stderr(self: *const TrackingAllocator, label: []const u8) void {
        const s = self.stats();
        std.debug.print(
            "--- alloc tracker: {s} ---\n" ++
                "  allocs:  {d}\n" ++
                "  frees:   {d}\n" ++
                "  current: {d} bytes\n" ++
                "  peak:    {d} bytes\n" ++
                "  total:   {d} bytes\n",
            .{ label, s.alloc_count, s.free_count, s.current_bytes, s.peak_bytes, s.total_bytes },
        );
    }

    // ------------------------------------------------------------------
    // Internal vtable callbacks
    // ------------------------------------------------------------------

    fn alloc_fn(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, ptr_align, ret_addr);
        if (result != null) {
            _ = self.alloc_count.fetchAdd(1, .monotonic);
            const new_cur = self.current_bytes.fetchAdd(@intCast(len), .monotonic) + @as(i64, @intCast(len));
            _ = self.total_bytes.fetchAdd(len, .monotonic);
            // Update peak
            var peak = self.peak_bytes.load(.monotonic);
            while (@as(u64, @intCast(new_cur)) > peak) {
                peak = self.peak_bytes.cmpxchgWeak(
                    peak,
                    @intCast(new_cur),
                    .monotonic,
                    .monotonic,
                ) orelse break;
            }
        }
        return result;
    }

    fn resize_fn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(buf, buf_align, new_len, ret_addr);
        if (ok) {
            const delta: i64 = @as(i64, @intCast(new_len)) - @as(i64, @intCast(buf.len));
            const new_cur = self.current_bytes.fetchAdd(delta, .monotonic) + delta;
            if (delta > 0) {
                _ = self.total_bytes.fetchAdd(@intCast(delta), .monotonic);
                var peak = self.peak_bytes.load(.monotonic);
                while (@as(u64, @intCast(@max(0, new_cur))) > peak) {
                    peak = self.peak_bytes.cmpxchgWeak(
                        peak,
                        @intCast(@max(0, new_cur)),
                        .monotonic,
                        .monotonic,
                    ) orelse break;
                }
            }
        }
        return ok;
    }

    fn remap_fn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(buf, buf_align, new_len, ret_addr);
        if (result != null) {
            const delta: i64 = @as(i64, @intCast(new_len)) - @as(i64, @intCast(buf.len));
            const new_cur = self.current_bytes.fetchAdd(delta, .monotonic) + delta;
            if (delta > 0) {
                _ = self.total_bytes.fetchAdd(@intCast(delta), .monotonic);
                var peak = self.peak_bytes.load(.monotonic);
                while (@as(u64, @intCast(@max(0, new_cur))) > peak) {
                    peak = self.peak_bytes.cmpxchgWeak(
                        peak,
                        @intCast(@max(0, new_cur)),
                        .monotonic,
                        .monotonic,
                    ) orelse break;
                }
            }
        }
        return result;
    }

    fn free_fn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, buf_align, ret_addr);
        _ = self.free_count.fetchAdd(1, .monotonic);
        _ = self.current_bytes.fetchSub(@intCast(buf.len), .monotonic);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc_fn,
        .resize = resize_fn,
        .remap = remap_fn,
        .free = free_fn,
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "tracking allocator: counts allocs and frees" {
    var ta = TrackingAllocator.init(std.testing.allocator);
    const ally = ta.allocator();

    const s0 = ta.stats();
    try std.testing.expectEqual(@as(u64, 0), s0.alloc_count);

    const mem = try ally.alloc(u8, 64);
    try std.testing.expectEqual(@as(u64, 1), ta.stats().alloc_count);
    try std.testing.expectEqual(@as(u64, 64), ta.stats().current_bytes);
    try std.testing.expectEqual(@as(u64, 64), ta.stats().peak_bytes);

    ally.free(mem);
    try std.testing.expectEqual(@as(u64, 1), ta.stats().free_count);
    try std.testing.expectEqual(@as(u64, 0), ta.stats().current_bytes);
    // peak stays at 64 after free
    try std.testing.expectEqual(@as(u64, 64), ta.stats().peak_bytes);
}

test "tracking allocator: peak tracks high watermark" {
    var ta = TrackingAllocator.init(std.testing.allocator);
    const ally = ta.allocator();

    const a = try ally.alloc(u8, 100);
    const b = try ally.alloc(u8, 200);
    try std.testing.expectEqual(@as(u64, 300), ta.stats().peak_bytes);
    ally.free(b);
    try std.testing.expectEqual(@as(u64, 300), ta.stats().peak_bytes); // doesn't drop
    ally.free(a);
}
