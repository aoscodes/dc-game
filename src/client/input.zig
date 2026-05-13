const std = @import("std");
const shared = @import("shared");
const c = shared.components;

pub const InputEventTag = enum {
    none,
    damage,
    shield,
    heal,
};

pub const InputEvent = union(InputEventTag) {
    none: void,
    damage: void,
    shield: void,
    heal: void,
};

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

pub fn poll(queue: *KeyQueue) InputEvent {
    const key = queue.pop() orelse return .none;
    return switch (key) {
        .one => .damage,
        .two => .shield,
        .three => .heal,
        else => .none,
    };
}

pub const ComboBuffer = struct {
    actions: [c.MAX_COMBO_LEN]c.ActionChoice = undefined,
    len: u8 = 0,

    pub fn push(self: *ComboBuffer, action: c.ActionChoice) bool {
        if (self.len >= c.MAX_COMBO_LEN) return false;
        self.actions[self.len] = action;
        self.len += 1;
        return true;
    }

    pub fn clear(self: *ComboBuffer) void {
        self.len = 0;
    }

    pub fn is_full(self: *const ComboBuffer) bool {
        return self.len >= c.MAX_COMBO_LEN;
    }

    pub fn is_empty(self: *const ComboBuffer) bool {
        return self.len == 0;
    }

    pub fn to_combo(self: *const ComboBuffer) c.ActionCombo {
        var out = c.ActionCombo{
            .actions = [_]c.ActionChoice{.damage} ** c.MAX_COMBO_LEN,
            .len = self.len,
        };
        @memcpy(out.actions[0..self.len], self.actions[0..self.len]);
        return out;
    }
};

pub const DrainResult = enum {
    unchanged,
    appended,
    cancelled,
};

pub fn drain_into_combo(queue: *KeyQueue, combo: *ComboBuffer) DrainResult {
    var result: DrainResult = .unchanged;
    while (queue.pop()) |key| {
        switch (key) {
            .escape => return .cancelled,
            .one, .two, .three => {
                const action: c.ActionChoice = switch (key) {
                    .one => .damage,
                    .two => .shield,
                    .three => .heal,
                    else => unreachable,
                };
                if (combo.push(action)) result = .appended;
            },
            else => {},
        }
    }
    return result;
}
