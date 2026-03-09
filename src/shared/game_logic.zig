//! Pure game logic: combat math, grid queries, ATB rules.
//!
//! All functions are stateless and take component values by value or pointer.
//! No ECS World import here — callers pass in the data they need.  This keeps
//! the logic testable without a full World instance.

const std = @import("std");
const c = @import("components.zig");

// ---------------------------------------------------------------------------
// Grid helpers
// ---------------------------------------------------------------------------

pub const GRID_COLS: u8 = 3;
pub const GRID_ROWS: u8 = 4;

/// Returns true if (col, row) is a valid grid position.
pub fn grid_valid(col: u8, row: u8) bool {
    return col < GRID_COLS and row < GRID_ROWS;
}

/// Collect all grid cells in a 2×2 region whose top-left corner is (col, row).
/// Out-of-bounds cells are omitted.  Returns the number of valid cells written
/// into `out` (max 4).
pub fn aoe_cells_2x2(
    col: u8,
    row: u8,
    out: *[4]c.GridPos,
) u8 {
    var n: u8 = 0;
    var dc: u8 = 0;
    while (dc < c.AOE_SIZE) : (dc += 1) {
        var dr: u8 = 0;
        while (dr < c.AOE_SIZE) : (dr += 1) {
            const gc = col + dc;
            const gr = row + dr;
            if (grid_valid(gc, gr)) {
                out[n] = .{ .col = @intCast(gc), .row = @intCast(gr) };
                n += 1;
            }
        }
    }
    return n;
}

/// Collect the 1×3 column projection directly behind a fighter at (col, row):
/// cells (col, row+1), (col, row+2), (col, row+3).
/// Out-of-bounds cells are omitted.  Returns count written into `out` (max 3).
pub fn fighter_defend_cells(
    col: u8,
    row: u8,
    out: *[3]c.GridPos,
) u8 {
    var n: u8 = 0;
    var d: u8 = 1;
    while (d <= c.FIGHTER_DEFEND_DEPTH) : (d += 1) {
        const gr = row + d;
        if (grid_valid(col, gr)) {
            out[n] = .{ .col = @intCast(col), .row = @intCast(gr) };
            n += 1;
        }
    }
    return n;
}

// ---------------------------------------------------------------------------
// Combat math
// ---------------------------------------------------------------------------

/// Compute raw damage before mitigation.
/// Minimum 1 — attacks never completely fizzle.
pub fn raw_damage(attack: u16, defense: u16) u16 {
    return if (attack > defense) attack - defense else 1;
}

/// Apply stacked mitigation effects to a raw damage value.
/// `total_mitigation` is the sum of all active mitigation magnitudes on the
/// target, clamped to MAX_MITIGATION before application.
pub fn mitigated_damage(raw: u16, total_mitigation: f32) u16 {
    const clamped = std.math.clamp(total_mitigation, 0.0, c.MAX_MITIGATION);
    const reduced = @as(f32, @floatFromInt(raw)) * (1.0 - clamped);
    // Round down; minimum 1 after mitigation too.
    const result: u16 = @intFromFloat(@floor(reduced));
    return if (result == 0) 1 else result;
}

/// Apply `damage` to a Health component.  HP floor is 0.
pub fn apply_damage(health: *c.Health, damage: u16) void {
    health.current = if (health.current > damage) health.current - damage else 0;
}

/// Apply `amount` healing to a Health component.  HP ceiling is max.
pub fn apply_heal(health: *c.Health, amount: u16) void {
    const restored = @as(u32, health.current) + @as(u32, amount);
    health.current = @intCast(@min(restored, @as(u32, health.max)));
}

/// Returns true if the entity is dead (HP == 0).
pub fn is_dead(health: c.Health) bool {
    return health.current == 0;
}

// ---------------------------------------------------------------------------
// ATB helpers
// ---------------------------------------------------------------------------

/// Advance the ATB gauge by `dt` seconds.
/// Returns true if the gauge crossed 1.0 (entity is now ready to act).
pub fn tick_atb(speed: *c.Speed, dt: f32) bool {
    if (speed.gauge >= 1.0) return false; // already full; don't double-fire
    speed.gauge = @min(speed.gauge + speed.rate * dt, 1.0);
    return speed.gauge >= 1.0;
}

/// Reset the ATB gauge to 0 after an action is resolved.
pub fn reset_atb(speed: *c.Speed) void {
    speed.gauge = 0.0;
}

// ---------------------------------------------------------------------------
// ActiveEffect helpers
// ---------------------------------------------------------------------------

/// Tick all active effects on an entity by `dt` seconds.
/// Removes expired effects by swap-removing from `effects` slice.
/// Returns the new length of the effects slice.
pub fn tick_effects(effects: []c.ActiveEffect, dt: f32) usize {
    var i: usize = 0;
    var len: usize = effects.len;
    while (i < len) {
        effects[i].duration -= dt;
        if (effects[i].duration <= 0.0) {
            // Swap-remove
            effects[i] = effects[len - 1];
            len -= 1;
        } else {
            i += 1;
        }
    }
    return len;
}

/// Sum all mitigation magnitudes in `effects`.
pub fn sum_mitigation(effects: []const c.ActiveEffect) f32 {
    var total: f32 = 0.0;
    for (effects) |eff| {
        if (eff.tag == .mitigation) total += eff.magnitude;
    }
    return total;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "raw_damage: normal" {
    try std.testing.expectEqual(@as(u16, 5), raw_damage(15, 10));
}

test "raw_damage: floored at 1" {
    try std.testing.expectEqual(@as(u16, 1), raw_damage(5, 20));
    try std.testing.expectEqual(@as(u16, 1), raw_damage(10, 10));
}

test "mitigated_damage: 30% reduction" {
    // 20 raw * (1 - 0.3) = 14
    try std.testing.expectEqual(@as(u16, 14), mitigated_damage(20, 0.30));
}

test "mitigated_damage: capped at MAX_MITIGATION" {
    // Even with 99% mitigation, MAX_MITIGATION caps at 0.75
    const dmg = mitigated_damage(100, 0.99);
    // 100 * (1 - 0.75) = 25
    try std.testing.expectEqual(@as(u16, 25), dmg);
}

test "mitigated_damage: floor at 1" {
    try std.testing.expectEqual(@as(u16, 1), mitigated_damage(1, 0.30));
}

test "apply_damage: no underflow" {
    var h = c.Health{ .current = 5, .max = 100 };
    apply_damage(&h, 999);
    try std.testing.expectEqual(@as(u16, 0), h.current);
}

test "apply_heal: no overflow" {
    var h = c.Health{ .current = 95, .max = 100 };
    apply_heal(&h, 999);
    try std.testing.expectEqual(@as(u16, 100), h.current);
}

test "tick_atb: fires exactly once" {
    var s = c.Speed{ .gauge = 0.0, .rate = 1.0 };
    try std.testing.expect(tick_atb(&s, 1.0)); // gauge → 1.0, fires
    try std.testing.expect(!tick_atb(&s, 1.0)); // already full, no re-fire
}

test "aoe_cells_2x2: centre of grid" {
    var out: [4]c.GridPos = undefined;
    const n = aoe_cells_2x2(1, 1, &out);
    try std.testing.expectEqual(@as(u8, 4), n);
}

test "aoe_cells_2x2: corner clips" {
    var out: [4]c.GridPos = undefined;
    const n = aoe_cells_2x2(2, 3, &out); // col 2+1 and row 3+1 both OOB
    try std.testing.expectEqual(@as(u8, 1), n);
}

test "fighter_defend_cells: front rank" {
    var out: [3]c.GridPos = undefined;
    const n = fighter_defend_cells(1, 0, &out);
    try std.testing.expectEqual(@as(u8, 3), n);
    try std.testing.expectEqual(c.GridPos{ .col = 1, .row = 1 }, out[0]);
    try std.testing.expectEqual(c.GridPos{ .col = 1, .row = 2 }, out[1]);
    try std.testing.expectEqual(c.GridPos{ .col = 1, .row = 3 }, out[2]);
}

test "fighter_defend_cells: back rank clips" {
    var out: [3]c.GridPos = undefined;
    const n = fighter_defend_cells(0, 3, &out); // row 3 is last; no rows behind
    try std.testing.expectEqual(@as(u8, 0), n);
}
