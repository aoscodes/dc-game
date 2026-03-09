//! Client input system.
//!
//! Translates raw raylib key events into high-level `InputEvent` values.
//! Input is only meaningful when the server has signalled it is this client's
//! turn (ActionState.charging for the player's own character).
//!
//! The targeting cursor is a grid position on either the enemy grid (for
//! attacks) or the player grid (for healer heals).  Arrow keys move it;
//! Enter/Z confirms; Escape/X cancels.

const rl = @import("raylib");
const shared = @import("shared");
const c = shared.components;

// ---------------------------------------------------------------------------
// Input events
// ---------------------------------------------------------------------------

pub const InputEventTag = enum {
    none,
    cursor_move,
    confirm,
    cancel,
    select_attack,
    select_defend,
};

pub const CursorDelta = struct { dcol: i8, drow: i8 };

pub const InputEvent = union(InputEventTag) {
    none: void,
    cursor_move: CursorDelta,
    confirm: void,
    cancel: void,
    select_attack: void,
    select_defend: void,
};

// ---------------------------------------------------------------------------
// InputState — owns the cursor position and pending event
// ---------------------------------------------------------------------------

pub const InputState = struct {
    /// Current cursor position on the active target grid.
    cursor_col: u8 = 0,
    cursor_row: u8 = 0,

    /// Whether it is currently this client's turn to act.
    /// Set by the client main loop when a `your_turn` message arrives.
    /// Cleared after `confirm` is consumed.
    is_our_turn: bool = false,

    pub fn poll(self: *InputState) InputEvent {
        if (!self.is_our_turn) return .none;

        // Action selection
        if (rl.isKeyPressed(.one)) return .select_attack;
        if (rl.isKeyPressed(.two)) return .select_defend;

        // Cursor navigation
        const dcol: i8 = if (rl.isKeyPressed(.right)) 1 else if (rl.isKeyPressed(.left)) -1 else 0;
        const drow: i8 = if (rl.isKeyPressed(.down)) 1 else if (rl.isKeyPressed(.up)) -1 else 0;
        if (dcol != 0 or drow != 0) {
            return .{ .cursor_move = .{ .dcol = dcol, .drow = drow } };
        }

        // Confirm / cancel
        if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.z)) return .confirm;
        if (rl.isKeyPressed(.escape) or rl.isKeyPressed(.x)) return .cancel;

        return .none;
    }

    /// Move the cursor, clamping to valid grid bounds.
    pub fn apply_cursor_move(self: *InputState, delta: CursorDelta, cols: u8, rows: u8) void {
        const new_col = @as(i16, self.cursor_col) + delta.dcol;
        const new_row = @as(i16, self.cursor_row) + delta.drow;
        self.cursor_col = @intCast(std.math.clamp(new_col, 0, @as(i16, cols) - 1));
        self.cursor_row = @intCast(std.math.clamp(new_row, 0, @as(i16, rows) - 1));
    }

    pub fn grid_pos(self: InputState) c.GridPos {
        return .{ .col = @intCast(self.cursor_col), .row = @intCast(self.cursor_row) };
    }
};

const std = @import("std");
