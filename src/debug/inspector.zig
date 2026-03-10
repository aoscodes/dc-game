//! Comptime entity inspector.
//!
//! Walks every component registered in a World and pretty-prints the ones
//! present on a given entity.  Works with any World(...) instantiation via
//! comptime reflection; no specialisation required.
//!
//! Usage (server / tests — any std.io.Writer):
//!
//!   const dbg = @import("debug_zig");
//!   dbg.inspector.inspect(world, entity, std.io.getStdErr().writer());
//!
//! The `inspect` function is generic over the world type and writer type.

const std = @import("std");
const ecs = @import("ecs_zig");

/// Print a structured dump of all components on `entity` within `world`.
///
/// Output format (example):
///
///   entity 3  sig=0b00001101
///     [grid_pos]  GridPos{ .col = 1, .row = 0 }
///     [health]    Health{ .current = 80, .max = 120 }
///     [speed]     Speed{ .gauge = 0.42, .rate = 0.20 }
///
pub fn inspect(world: anytype, entity: ecs.Entity, writer: anytype) void {
    const sig = world.entity_manager.get_signature(entity);
    writer.print("entity {}  sig=0b{b:0>32}\n", .{ entity, sig.mask }) catch {};

    const comp_arrays = &world.component_arrays;
    const CT = @TypeOf(comp_arrays.*);
    const fields = @typeInfo(CT).@"struct".fields;

    inline for (fields) |f| {
        const arr = &@field(comp_arrays, f.name);
        if (!arr.has(entity)) continue;
        const val = arr.get(entity).*;
        writer.print("  [{s}]  {}\n", .{ f.name, val }) catch {};
    }
}

/// Print a one-line summary of every living entity in `living_slice`.
///
///   entity 0  [grid_pos health speed class team owner stats action_state]
///
pub fn inspect_all(world: anytype, living: []const ecs.Entity, writer: anytype) void {
    for (living) |entity| {
        inspect_one_line(world, entity, writer);
    }
}

fn inspect_one_line(world: anytype, entity: ecs.Entity, writer: anytype) void {
    writer.print("entity {}  [", .{entity}) catch {};
    const comp_arrays = &world.component_arrays;
    const CT = @TypeOf(comp_arrays.*);
    const fields = @typeInfo(CT).@"struct".fields;
    var first = true;
    inline for (fields) |f| {
        const arr = &@field(comp_arrays, f.name);
        if (!arr.has(entity)) continue;
        if (!first) writer.writeByte(' ') catch {};
        writer.writeAll(f.name) catch {};
        first = false;
    }
    writer.writeAll("]\n") catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "inspector: prints components for entity" {
    const std_ = @import("std");
    const ecs_ = @import("ecs_zig");

    const Pos = struct { x: f32, y: f32 };
    const Vel = struct { dx: f32 };

    const W = ecs_.World(.{ .pos = Pos, .vel = Vel }, .{});
    var world = try W.init(std_.testing.allocator);
    defer world.deinit();

    const e = world.create_entity();
    world.add_component(e, Pos{ .x = 1.0, .y = 2.0 });
    world.add_component(e, Vel{ .dx = 0.5 });

    var buf: [512]u8 = undefined;
    var fbs = std_.io.fixedBufferStream(&buf);
    inspect(&world, e, fbs.writer());
    const out = fbs.getWritten();

    try std_.testing.expect(std_.mem.indexOf(u8, out, "pos") != null);
    try std_.testing.expect(std_.mem.indexOf(u8, out, "vel") != null);
    try std_.testing.expect(std_.mem.indexOf(u8, out, "1.0") != null or
        std_.mem.indexOf(u8, out, "1e0") != null or
        std_.mem.indexOf(u8, out, "x = 1") != null);
}

test "inspector: missing component not printed" {
    const std_ = @import("std");
    const ecs_ = @import("ecs_zig");

    const Pos = struct { x: f32 };
    const Hp = struct { v: u16 };

    const W = ecs_.World(.{ .pos = Pos, .hp = Hp }, .{});
    var world = try W.init(std_.testing.allocator);
    defer world.deinit();

    const e = world.create_entity();
    world.add_component(e, Pos{ .x = 3.0 });
    // Hp intentionally omitted

    var buf: [256]u8 = undefined;
    var fbs = std_.io.fixedBufferStream(&buf);
    inspect(&world, e, fbs.writer());
    const out = fbs.getWritten();

    try std_.testing.expect(std_.mem.indexOf(u8, out, "pos") != null);
    try std_.testing.expect(std_.mem.indexOf(u8, out, "hp") == null);
}
