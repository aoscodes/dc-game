//! Raylib debug HUD: live stats overlay for the ECS demo window.
//!
//! Renders two panels when `enabled` is true:
//!
//!   Left panel  — World summary
//!     • living_count / max entities
//!     • Per-component array fill (name: count / MAX_ENTITIES)
//!     • Per-system entity-set population (name: count)
//!     • FPS sparkline (last MAX_FPS_SAMPLES frames)
//!
//!   Right panel — Entity detail (rendered only when `highlight != null`)
//!     • Entity ID + signature bitmask
//!     • All present component values via comptime reflection
//!
//! Import and call from the render loop:
//!
//!   const hud = @import("debug_zig").hud;
//!   hud.draw(&world, &state, enabled);
//!
//!   // Update state each frame before drawing:
//!   state.push_fps(rl.getFPS());
//!   state.highlight = nearest_entity;   // or null

const std = @import("std");
const rl = @import("raylib");
const ecs = @import("ecs_zig");

// ---------------------------------------------------------------------------
// HudState  — caller owns this; lives for the duration of the window
// ---------------------------------------------------------------------------

pub const MAX_FPS_SAMPLES: usize = 120;

pub const HudState = struct {
    fps_history: [MAX_FPS_SAMPLES]f32 = [_]f32{0.0} ** MAX_FPS_SAMPLES,
    fps_head: usize = 0,
    /// Entity to show in the right panel.  null = no detail panel.
    highlight: ?ecs.Entity = null,

    pub fn push_fps(self: *HudState, fps: i32) void {
        self.fps_history[self.fps_head] = @floatFromInt(fps);
        self.fps_head = (self.fps_head + 1) % MAX_FPS_SAMPLES;
    }
};

// ---------------------------------------------------------------------------
// Layout constants
// ---------------------------------------------------------------------------

const PAD: i32 = 8;
const LINE: i32 = 16;
const PANEL_W: i32 = 220;
const PANEL_ALPHA: u8 = 200;
const BG_COLOR = rl.Color{ .r = 0, .g = 0, .b = 0, .a = PANEL_ALPHA };
const TEXT_COLOR = rl.Color{ .r = 220, .g = 220, .b = 220, .a = 255 };
const ACCENT_COLOR = rl.Color{ .r = 100, .g = 220, .b = 100, .a = 255 };
const SPARK_COLOR = rl.Color{ .r = 80, .g = 180, .b = 255, .a = 200 };

// ---------------------------------------------------------------------------
// Main draw entry point
// ---------------------------------------------------------------------------

/// Draw the debug HUD overlay.  Call inside a raylib BeginDrawing/EndDrawing
/// block, after the scene has been rendered.
///
/// `world`   — pointer to any World(...) instance
/// `state`   — persistent HudState (caller owns)
/// `enabled` — toggle; returns immediately when false
pub fn draw(world: anytype, state: *HudState, enabled: bool) void {
    if (!enabled) return;

    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();

    // Left panel: world summary
    {
        const panel_h = compute_left_panel_height(world);
        rl.drawRectangle(PAD, PAD, PANEL_W, panel_h, BG_COLOR);
        var y: i32 = PAD + PAD;
        draw_left_panel(world, state, &y, sw, sh);
    }

    // Right panel: entity detail
    if (state.highlight) |entity| {
        const panel_h = compute_right_panel_height(world, entity);
        const rx = sw - PANEL_W - PAD;
        rl.drawRectangle(rx, PAD, PANEL_W, panel_h, BG_COLOR);
        var y: i32 = PAD + PAD;
        draw_right_panel(world, entity, rx, &y);
    }
}

// ---------------------------------------------------------------------------
// Left panel
// ---------------------------------------------------------------------------

fn compute_left_panel_height(world: anytype) i32 {
    const CT = @TypeOf(world.component_arrays);
    const n_comps: i32 = @intCast(@typeInfo(CT).@"struct".fields.len);
    const ST = @TypeOf(world.system_entity_sets);
    const n_sys: i32 = @intCast(@typeInfo(ST).array.len);
    // header + entity line + n_comps + blank + n_sys + blank + sparkline + padding
    return PAD * 2 + LINE * (2 + n_comps + 1 + n_sys + 1) + 40 + PAD;
}

fn draw_left_panel(world: anytype, state: *HudState, y: *i32, _: i32, _: i32) void {
    const x = PAD * 2;

    // Title
    draw_text("[ ECS DEBUG ]", x, y.*, ACCENT_COLOR);
    y.* += LINE + 4;

    // Entity count
    var line_buf: [64]u8 = undefined;
    const living = world.entity_manager.living_count;
    const line = std.fmt.bufPrint(
        &line_buf,
        "entities: {d}/{d}",
        .{ living, ecs.MAX_ENTITIES },
    ) catch "entities: ?";
    draw_text(line, x, y.*, TEXT_COLOR);
    y.* += LINE;

    // Component arrays
    draw_text("-- components --", x, y.*, ACCENT_COLOR);
    y.* += LINE;
    {
        const comp_arrays = &world.component_arrays;
        const CT = @TypeOf(comp_arrays.*);
        inline for (@typeInfo(CT).@"struct".fields) |f| {
            const arr = &@field(comp_arrays, f.name);
            const comp_line = std.fmt.bufPrint(
                &line_buf,
                "  {s}: {d}",
                .{ f.name, arr.size },
            ) catch "  ?: ?";
            draw_text(comp_line, x, y.*, TEXT_COLOR);
            y.* += LINE;
        }
    }

    // System entity sets
    draw_text("-- systems --", x, y.*, ACCENT_COLOR);
    y.* += LINE;
    {
        const ST = @TypeOf(world.system_entity_sets);
        const n_sys = @typeInfo(ST).array.len;
        const sys_storage = &world.systems;
        const SysT = @TypeOf(sys_storage.*);
        inline for (@typeInfo(SysT).@"struct".fields, 0..) |f, i| {
            if (i >= n_sys) break;
            const count = world.system_entity_sets[i].count();
            const sys_line = std.fmt.bufPrint(
                &line_buf,
                "  {s}: {d}",
                .{ f.name, count },
            ) catch "  ?: ?";
            draw_text(sys_line, x, y.*, TEXT_COLOR);
            y.* += LINE;
        }
    }

    // FPS sparkline
    y.* += 4;
    draw_sparkline(state, x, y.*);
    y.* += 44;
}

fn draw_sparkline(state: *HudState, x: i32, y: i32) void {
    const w = PANEL_W - PAD * 2;
    const h: i32 = 36;

    // Find max for scaling
    var max_fps: f32 = 1.0;
    for (state.fps_history) |v| if (v > max_fps) {
        max_fps = v;
    };

    const n = MAX_FPS_SAMPLES;
    var prev_x: i32 = x;
    var prev_y: i32 = y + h;

    for (0..n) |i| {
        const idx = (state.fps_head + i) % n;
        const v = state.fps_history[idx];
        const px = x + @divTrunc(@as(i32, @intCast(i)) * w, @as(i32, n));
        const py = y + h - @as(i32, @intFromFloat(v / max_fps * @as(f32, @floatFromInt(h))));
        if (i > 0) rl.drawLine(prev_x, prev_y, px, py, SPARK_COLOR);
        prev_x = px;
        prev_y = py;
    }
    // Label
    var buf: [16]u8 = undefined;
    const cur_fps = state.fps_history[(state.fps_head + n - 1) % n];
    const label = std.fmt.bufPrint(&buf, "fps:{d:.0}", .{cur_fps}) catch "fps:?";
    draw_text(label, x, y + h + 2, TEXT_COLOR);
}

// ---------------------------------------------------------------------------
// Right panel
// ---------------------------------------------------------------------------

fn compute_right_panel_height(world: anytype, entity: ecs.Entity) i32 {
    const CT = @TypeOf(world.component_arrays);
    var count: i32 = 3; // header + entity line + sig
    inline for (@typeInfo(CT).@"struct".fields) |f| {
        const arr = &@field(world.component_arrays, f.name);
        if (arr.has(entity)) count += 1;
    }
    return PAD * 2 + LINE * count + PAD;
}

fn draw_right_panel(world: anytype, entity: ecs.Entity, rx: i32, y: *i32) void {
    const x = rx + PAD;
    var line_buf: [128]u8 = undefined;

    draw_text("[ ENTITY ]", x, y.*, ACCENT_COLOR);
    y.* += LINE + 4;

    const id_line = std.fmt.bufPrint(&line_buf, "id: {d}", .{entity}) catch "id: ?";
    draw_text(id_line, x, y.*, TEXT_COLOR);
    y.* += LINE;

    const sig = world.entity_manager.get_signature(entity);
    const sig_line = std.fmt.bufPrint(&line_buf, "sig: 0x{x:0>8}", .{sig.mask}) catch "sig: ?";
    draw_text(sig_line, x, y.*, TEXT_COLOR);
    y.* += LINE;

    const comp_arrays = &world.component_arrays;
    const CT = @TypeOf(comp_arrays.*);
    inline for (@typeInfo(CT).@"struct".fields) |f| {
        const arr = &@field(comp_arrays, f.name);
        if (arr.has(entity)) {
            const val = arr.get(entity).*;
            const comp_line = std.fmt.bufPrint(
                &line_buf,
                "{s}: {}",
                .{ f.name, val },
            ) catch f.name;
            draw_text(comp_line, x, y.*, TEXT_COLOR);
            y.* += LINE;
        }
    }
}

// ---------------------------------------------------------------------------
// Helper: draw_text wraps rl.drawText with consistent font size
// ---------------------------------------------------------------------------

fn draw_text(text: []const u8, x: i32, y: i32, color: rl.Color) void {
    // raylib wants a null-terminated string; copy to a small stack buffer.
    var buf: [128:0]u8 = [_:0]u8{0} ** 128;
    const n = @min(text.len, 127);
    @memcpy(buf[0..n], text[0..n]);
    rl.drawText(&buf, x, y, 12, color);
}
