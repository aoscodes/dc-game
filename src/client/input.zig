const rl = @import("raylib");
const shared = @import("shared");
const c = shared.components;

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

pub const InputState = struct {
    cursor_col: u8 = 0,
    cursor_row: u8 = 0,
    is_our_turn: bool = false,

    pub fn poll(self: *InputState) InputEvent {
        if (!self.is_our_turn) return .none;

        if (rl.isKeyPressed(.one)) return .select_attack;
        if (rl.isKeyPressed(.two)) return .select_defend;

        const dcol: i8 = if (rl.isKeyPressed(.right)) 1 else if (rl.isKeyPressed(.left)) -1 else 0;
        const drow: i8 = if (rl.isKeyPressed(.down)) 1 else if (rl.isKeyPressed(.up)) -1 else 0;
        if (dcol != 0 or drow != 0) {
            return .{ .cursor_move = .{ .dcol = dcol, .drow = drow } };
        }

        if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.z)) return .confirm;
        if (rl.isKeyPressed(.escape) or rl.isKeyPressed(.x)) return .cancel;

        return .none;
    }

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
