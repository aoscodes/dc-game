const std = @import("std");
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

/// Map a browser key name (as sent by JS KeyboardEvent.key) to a raw key token
/// understood by InputState.poll.  Returns null for unrecognised keys.
pub fn parse_key_name(name: []const u8) ?RawKey {
    if (std.mem.eql(u8, name, "ArrowUp")) return .up;
    if (std.mem.eql(u8, name, "ArrowDown")) return .down;
    if (std.mem.eql(u8, name, "ArrowLeft")) return .left;
    if (std.mem.eql(u8, name, "ArrowRight")) return .right;
    if (std.mem.eql(u8, name, "Enter")) return .enter;
    if (std.mem.eql(u8, name, "Escape")) return .escape;
    if (std.mem.eql(u8, name, "z") or
        std.mem.eql(u8, name, "Z")) return .z;
    if (std.mem.eql(u8, name, "x") or
        std.mem.eql(u8, name, "X")) return .x;
    if (std.mem.eql(u8, name, "1")) return .one;
    if (std.mem.eql(u8, name, "2")) return .two;
    if (std.mem.eql(u8, name, "3")) return .three;
    return null;
}

pub const RawKey = enum { up, down, left, right, enter, escape, z, x, one, two, three };

/// Thread-safe single-slot key queue.  The stdin reader thread pushes raw keys;
/// the game loop thread pops them one per tick.  Capacity is intentionally
/// small — we only need to buffer a handful of keystrokes between ticks.
pub const KeyQueue = struct {
    buf: [64]RawKey = undefined,
    head: usize = 0,
    tail: usize = 0,
    mu: std.Thread.Mutex = .{},

    pub fn push(self: *KeyQueue, key: RawKey) void {
        self.mu.lock();
        defer self.mu.unlock();
        const next = (self.tail + 1) % self.buf.len;
        if (next == self.head) return; // full, drop
        self.buf[self.tail] = key;
        self.tail = next;
    }

    pub fn pop(self: *KeyQueue) ?RawKey {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.head == self.tail) return null;
        const key = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        return key;
    }
};

pub const InputState = struct {
    cursor_col: u8 = 0,
    cursor_row: u8 = 0,
    is_our_turn: bool = false,

    /// Drain one key from the queue and convert to an InputEvent.
    /// Only processes game-relevant keys when it is the player's turn.
    pub fn poll(self: *InputState, queue: *KeyQueue) InputEvent {
        const key = queue.pop() orelse return .none;

        // Class selection and lobby keys are handled regardless of turn state
        // by the caller (main.zig update_lobby / update_game).  Here we expose
        // the raw key as an event only when it is our turn.
        if (!self.is_our_turn) return .none;

        return switch (key) {
            .one => .select_attack,
            .two => .select_defend,
            .right => .{ .cursor_move = .{ .dcol = 1, .drow = 0 } },
            .left => .{ .cursor_move = .{ .dcol = -1, .drow = 0 } },
            .down => .{ .cursor_move = .{ .dcol = 0, .drow = 1 } },
            .up => .{ .cursor_move = .{ .dcol = 0, .drow = -1 } },
            .enter, .z => .confirm,
            .escape, .x => .cancel,
            else => .none,
        };
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
