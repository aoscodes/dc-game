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

/// Drain one key from the queue and convert it to a game InputEvent.
/// Keys 1/2/3 map to damage/shield/heal.  Always active during the game phase.
pub fn poll(queue: *KeyQueue) InputEvent {
    const key = queue.pop() orelse return .none;
    return switch (key) {
        .one => .damage,
        .two => .shield,
        .three => .heal,
        else => .none,
    };
}
