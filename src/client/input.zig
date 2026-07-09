const std = @import("std");
const shared = @import("shared");
const c = shared.components;
const ComboSlot = c.ComboSlot;

pub fn parse_key_name(name: []const u8) ?RawKey {
    if (std.mem.eql(u8, name, "Enter")) return .enter;
    if (std.mem.eql(u8, name, "Escape")) return .escape;
    if (std.mem.eql(u8, name, "1")) return .one;
    if (std.mem.eql(u8, name, "2")) return .two;
    if (std.mem.eql(u8, name, "q")) return .q;
    if (std.mem.eql(u8, name, "w")) return .w;
    if (std.mem.eql(u8, name, "e")) return .e;
    if (std.mem.eql(u8, name, "r")) return .r;

    return null;
}

pub const RawKey = enum { enter, escape, one, two, q, w, e, r };

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

pub const ComboBuffer = struct {
    slots: [c.MAX_COMBO_LEN]ComboSlot = undefined,
    len: u8 = 0,

    pub fn push(self: *ComboBuffer, slot: ComboSlot) bool {
        if (self.len >= c.MAX_COMBO_LEN) return false;
        self.slots[self.len] = slot;
        self.len += 1;
        return true;
    }

    pub fn clear(self: *ComboBuffer) void {
        self.len = 0;
    }

    pub fn to_combo(self: *const ComboBuffer) c.ActionCombo {
        var out = c.ActionCombo{
            .slots = [_]ComboSlot{.{ .action = .dispense }} ** c.MAX_COMBO_LEN,
            .len = self.len,
        };
        @memcpy(out.slots[0..self.len], self.slots[0..self.len]);
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
            // Action keys: 1=dispense  2=medicine
            .one, .two => {
                const action: c.ActionChoice = switch (key) {
                    .one => .dispense,
                    .two => .medicine,
                    else => unreachable,
                };
                if (combo.push(.{ .action = action })) result = .appended;
            },
            // Agent color keys: Q=fire  W=earth  E=wind  R=water
            .q, .w, .e, .r => {
                const element: c.Element = switch (key) {
                    .q => .fire,
                    .w => .earth,
                    .e => .wind,
                    .r => .water,
                    else => unreachable,
                };
                if (combo.push(.{ .element = element })) result = .appended;
            },
            else => {},
        }
    }
    return result;
}
