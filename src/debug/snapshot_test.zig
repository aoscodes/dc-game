//! Round-trip tests for snapshot.zig

const std = @import("std");
const ecs = @import("ecs_zig");
const snapshot = @import("snapshot.zig");

const Pos = struct { x: f32, y: f32 };
const Hp = struct { current: u16, max: u16 };
const Tag = struct { id: u8 };

const TestWorld = ecs.World(
    .{ .pos = Pos, .hp = Hp, .tag = Tag },
    .{},
);

test "snapshot round-trip: component values preserved" {
    var world = try TestWorld.init(std.testing.allocator);
    defer world.deinit();

    const e0 = world.create_entity();
    world.add_component(e0, Pos{ .x = 1.5, .y = -3.0 });
    world.add_component(e0, Hp{ .current = 80, .max = 100 });

    const e1 = world.create_entity();
    world.add_component(e1, Pos{ .x = 0.0, .y = 5.0 });
    world.add_component(e1, Tag{ .id = 7 });

    const living = [_]ecs.Entity{ e0, e1 };

    // Serialize
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try snapshot.Snapshot(TestWorld).write(&world, fbs.writer(), &living);

    // Deserialize into fresh world
    var world2 = try TestWorld.init(std.testing.allocator);
    defer world2.deinit();

    fbs.reset();
    try snapshot.Snapshot(TestWorld).read(&world2, fbs.reader());

    // Check e0 components
    try std.testing.expect(world2.component_arrays.pos.has(e0));
    try std.testing.expect(world2.component_arrays.hp.has(e0));
    const pos0 = world2.component_arrays.pos.get(e0).*;
    try std.testing.expectApproxEqAbs(pos0.x, 1.5, 0.001);
    try std.testing.expectApproxEqAbs(pos0.y, -3.0, 0.001);
    const hp0 = world2.component_arrays.hp.get(e0).*;
    try std.testing.expectEqual(@as(u16, 80), hp0.current);
    try std.testing.expectEqual(@as(u16, 100), hp0.max);

    // Check e1
    try std.testing.expect(world2.component_arrays.pos.has(e1));
    try std.testing.expect(world2.component_arrays.tag.has(e1));
    try std.testing.expect(!world2.component_arrays.hp.has(e1));
    const tag1 = world2.component_arrays.tag.get(e1).*;
    try std.testing.expectEqual(@as(u8, 7), tag1.id);

    // living_count restored
    try std.testing.expectEqual(@as(u32, 2), world2.entity_manager.living_count);
}

test "snapshot: bad magic returns error" {
    var buf = [_]u8{ 'X', 'X', 'X', 'X', 0, 0, 0, 0 };
    var fbs = std.io.fixedBufferStream(&buf);
    var world = try TestWorld.init(std.testing.allocator);
    defer world.deinit();
    try std.testing.expectError(
        error.BadMagic,
        snapshot.Snapshot(TestWorld).read(&world, fbs.reader()),
    );
}
