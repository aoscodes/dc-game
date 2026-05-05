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

/// Client-side accumulator for the player's current round combo.
/// Mirrors `components.ActionCombo` but also tracks whether it has been
/// modified since last sent so callers can avoid redundant network sends.
pub const ComboBuffer = struct {
    actions: [c.MAX_COMBO_LEN]c.ActionChoice = undefined,
    len: u8 = 0,

    /// Append one action.  Returns true if the action was appended; false if
    /// the buffer is already full (len == MAX_COMBO_LEN), in which case the
    /// buffer is unchanged.
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

    /// Return an `ActionCombo` view of the filled prefix.
    /// Caller must ensure `len >= 1`.
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
    /// No action keys were in the queue; combo unchanged.
    unchanged,
    /// One or more actions were appended to the combo.
    appended,
    /// Escape was pressed; caller should clear the combo and send cancel.
    cancelled,
};

/// Drain all pending keys from `queue`, classifying them:
///   - 1/2/3 → attempt to append to `combo` (ignored if full)
///   - Escape → return `.cancelled` immediately (combo is NOT cleared here;
///               caller decides)
///   - Other  → ignored
///
/// Returns `.cancelled` if Escape was found, `.appended` if at least one
/// action key was processed and space was available, otherwise `.unchanged`.
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
                // if full, push returns false and we leave result as-is
            },
            else => {},
        }
    }
    return result;
}
