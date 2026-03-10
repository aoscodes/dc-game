//! ECS demo – 5 000 entities falling under gravity, rendered with raylib.
//!
//! Side-on 2D view: x = horizontal, y = vertical (y-up in world space).
//! Entities that fall below the world floor (y < -100) are destroyed and
//! respawned at the top with a fresh random x position.
//!
//! Systems:
//!   PhysicsSystem – stores dt so world.each() can read it per-frame
//!   RenderSystem  – stores a pointer to the raylib draw context (none needed;
//!                   each() closure captures world which has component access)

const std = @import("std");
const rl = @import("raylib");
const ecs = @import("ecs_zig");
const dbg = @import("debug_zig");

// ---------------------------------------------------------------------------
// Vec3
// ---------------------------------------------------------------------------

const Vec3 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }
};

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

const Gravity = struct {
    force: Vec3,
};

const RigidBody = struct {
    velocity: Vec3 = .{},
};

/// x/y are world-space; z unused in this demo.
const Transform = struct {
    position: Vec3 = .{},
};

// ---------------------------------------------------------------------------
// Systems
// ---------------------------------------------------------------------------

/// dt is written here each frame before world.each() is called.
const PhysicsSystem = struct {
    dt: f32 = 0,
};

/// No per-system state; draw calls happen inside the each() callback.
const RenderSystem = struct {};

// ---------------------------------------------------------------------------
// World
// ---------------------------------------------------------------------------

const MyWorld = ecs.World(
    .{
        .gravity = Gravity,
        .rigid_body = RigidBody,
        .transform = Transform,
    },
    .{
        .physics = PhysicsSystem,
        .render = RenderSystem,
    },
);

// ---------------------------------------------------------------------------
// Screen / world constants
// ---------------------------------------------------------------------------

const SW: f32 = 900;
const SH: f32 = 600;
/// World coordinate range: x ∈ [-HALF_W, HALF_W], y ∈ [-HALF_H, HALF_H]
const HALF_W: f32 = 100;
const HALF_H: f32 = 100;
const DOT_R: i32 = 2;

/// World → screen (side-on: x→horizontal, y→vertical, y-up flipped).
inline fn world_to_screen(wx: f32, wy: f32) struct { x: i32, y: i32 } {
    return .{
        .x = @intFromFloat((wx + HALF_W) / (HALF_W * 2) * SW),
        // y=+100 → screen top (y=0), y=-100 → screen bottom (y=SH)
        .y = @intFromFloat((1.0 - (wy + HALF_H) / (HALF_H * 2)) * SH),
    };
}

/// Gravity magnitude → RGBA colour (fast=red, slow=blue).
fn gravity_color(force_y: f32) rl.Color {
    // force_y is negative; magnitude in [1, 10]
    const t = std.math.clamp((-force_y - 1.0) / 9.0, 0.0, 1.0);
    return .{
        .r = @intFromFloat(t * 255),
        .g = @intFromFloat((1.0 - t) * 80),
        .b = @intFromFloat((1.0 - t) * 255),
        .a = 200,
    };
}

// ---------------------------------------------------------------------------
// System callbacks
// ---------------------------------------------------------------------------

fn physics_step(world: *MyWorld, entity: ecs.Entity, sys: *PhysicsSystem) void {
    const rb = world.get_component(entity, RigidBody);
    const tf = world.get_component(entity, Transform);
    const grav = world.get_component(entity, Gravity);

    tf.position = Vec3.add(tf.position, Vec3.scale(rb.velocity, sys.dt));
    rb.velocity = Vec3.add(rb.velocity, Vec3.scale(grav.force, sys.dt));
}

fn render_step(world: *MyWorld, entity: ecs.Entity, _: *RenderSystem) void {
    const tf = world.get_component(entity, Transform);
    const grav = world.get_component(entity, Gravity);
    const sc = world_to_screen(tf.position.x, tf.position.y);
    rl.drawCircle(sc.x, sc.y, DOT_R, gravity_color(grav.force.y));
}

// ---------------------------------------------------------------------------
// Spawn helpers
// ---------------------------------------------------------------------------

fn spawn(world: *MyWorld, rng: std.Random, x: f32, y: f32) ecs.Entity {
    const e = world.create_entity();
    world.add_component(e, Gravity{
        .force = .{
            .y = rng.float(f32) * -9.0 - 1.0, // [-1, -10]
        },
    });
    world.add_component(e, RigidBody{});
    world.add_component(e, Transform{ .position = .{ .x = x, .y = y } });
    return e;
}

fn spawn_top(world: *MyWorld, rng: std.Random) ecs.Entity {
    return spawn(
        world,
        rng,
        rng.float(f32) * (HALF_W * 2) - HALF_W, // x ∈ [-100, 100]
        HALF_H - rng.float(f32) * 20, // y ∈ [80, 100]
    );
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    var ta = dbg.TrackingAllocator.init(gpa.allocator());
    const allocator = ta.allocator();

    var world = try MyWorld.init(allocator);
    defer world.deinit();

    // ---- Register signatures ----
    {
        var sig = ecs.Signature.initEmpty();
        sig.set(MyWorld.component_type(Gravity));
        sig.set(MyWorld.component_type(RigidBody));
        sig.set(MyWorld.component_type(Transform));
        world.set_system_signature(PhysicsSystem, sig);
        world.set_system_signature(RenderSystem, sig);
    }

    // ---- Spawn entities ----
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rng = prng.random();

    // Keep a flat array so we can iterate for respawn checks.
    var entities: [ecs.MAX_ENTITIES]ecs.Entity = undefined;
    for (&entities) |*slot| {
        slot.* = spawn_top(&world, rng);
    }
    // Stagger initial y so they don't all arrive at the bottom at once.
    for (&entities) |e| {
        const tf = world.get_component(e, Transform);
        tf.position.y = rng.float(f32) * (HALF_H * 2) - HALF_H;
    }

    // ---- Debug HUD state ----
    var hud_state = dbg.HudState{};
    var hud_enabled = false;

    // ---- Raylib window ----
    rl.initWindow(@intFromFloat(SW), @intFromFloat(SH), "ECS — 5 000 falling entities");
    defer rl.closeWindow();
    rl.setTargetFPS(120);

    const floor_y: f32 = -HALF_H - 5; // a little below the visible area

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();

        // Toggle debug HUD with D key.
        if (rl.isKeyPressed(.d)) hud_enabled = !hud_enabled;

        // Write dt into the physics system before stepping.
        world.get_system(PhysicsSystem).dt = dt;

        // Step physics.
        world.each(PhysicsSystem, physics_step);

        // Respawn any entity that fell through the floor.
        for (&entities) |*slot| {
            const tf = world.get_component(slot.*, Transform);
            if (tf.position.y < floor_y) {
                world.destroy_entity(slot.*);
                slot.* = spawn_top(&world, rng);
            }
        }

        // Update HUD FPS history.
        hud_state.push_fps(rl.getFPS());

        // Draw.
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.black);

        // Draw floor line.
        rl.drawLine(0, @intFromFloat(SH - 1), @intFromFloat(SW), @intFromFloat(SH - 1), .dark_gray);

        world.each(RenderSystem, render_step);

        rl.drawFPS(10, 10);
        // Entity count (always MAX_ENTITIES while alive).
        rl.drawText(
            std.fmt.comptimePrint("{d} entities", .{ecs.MAX_ENTITIES}),
            10,
            34,
            16,
            .ray_white,
        );

        // Debug HUD overlay (toggle with D).
        dbg.hud.draw(&world, &hud_state, hud_enabled);
    }
}
