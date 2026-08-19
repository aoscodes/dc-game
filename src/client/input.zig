//! Client input: raw keys in, combo edits and cursor steps out.
//!
//! Two independent input axes, which is why draining yields BOTH a combo
//! result and any cursor steps: the action keys build the combo (the recipe
//! NAME) while the d-pad aims where it will land.  Neither blocks the other,
//! so a player can re-aim mid-combo.

const std = @import("std");
const shared = @import("shared");
const c = shared.components;
const protocol = shared.protocol;
const ComboSlot = c.ComboSlot;

pub fn parse_key_name(name: []const u8) ?RawKey {
    if (std.mem.eql(u8, name, "Enter")) return .enter;
    if (std.mem.eql(u8, name, "Escape")) return .escape;
    if (std.mem.eql(u8, name, "1")) return .one;
    if (std.mem.eql(u8, name, "2")) return .two;
    if (std.mem.eql(u8, name, "ArrowUp")) return .up;
    if (std.mem.eql(u8, name, "ArrowDown")) return .down;
    if (std.mem.eql(u8, name, "ArrowLeft")) return .left;
    if (std.mem.eql(u8, name, "ArrowRight")) return .right;

    return null;
}

pub const RawKey = enum { enter, escape, one, two, up, down, left, right };

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

/// What a drain did to the combo buffer.
///
/// The two TERMINAL results — `cancelled` and `submitted` — leave the buffer
/// EMPTY, because `drain` clears it as it reports them.  `submitted` therefore
/// carries the combo by value: it is the only surviving copy, which is what
/// makes "committed a spell but left it in the buffer" unrepresentable rather
/// than merely discouraged.  (It used to be a bare tag, and the caller cleared
/// on a server reply — but a cast that resolves immediately never sends one,
/// so the spent recipe leaked into the next cast.)
pub const DrainResult = union(enum) {
    unchanged,
    appended,
    cancelled,
    submitted: c.ActionCombo,
};

/// Cursor steps to forward, in the order they were pressed.  Steps are sent
/// individually rather than collapsed into a net delta: the server clamps at
/// the edge, so "left, left, right" against the wall must end one cell in
/// from the wall, not back where it started.
pub const MAX_CURSOR_STEPS: usize = 16;

pub const Drained = struct {
    combo: DrainResult = .unchanged,
    step_count: usize = 0,
    steps: [MAX_CURSOR_STEPS]protocol.CursorDir = undefined,

    pub fn cursor_steps(self: *const Drained) []const protocol.CursorDir {
        return self.steps[0..self.step_count];
    }
};

/// Drain the key queue, applying action keys to `combo` and collecting d-pad
/// presses as cursor steps.
///
/// A terminal combo result (escape/enter) stops the drain so the caller sees
/// exactly one commit per call, but any cursor steps pressed BEFORE it are
/// still returned — they are what aimed the cast being committed.
pub fn drain(queue: *KeyQueue, combo: *ComboBuffer) Drained {
    var out = Drained{};
    while (queue.pop()) |key| {
        switch (key) {
            // Both terminal keys hand the buffer back empty: the recipe either
            // went out on the wire or was thrown away, and either way the next
            // key starts a new spell.
            .escape => {
                combo.clear();
                out.combo = .cancelled;
                return out;
            },
            .enter => {
                out.combo = .{ .submitted = combo.to_combo() };
                combo.clear();
                return out;
            },
            // Action keys: 1=dispense  2=catalyst.  These NAME the recipe.
            .one, .two => {
                const action: c.ActionChoice = switch (key) {
                    .one => .dispense,
                    .two => .catalyst,
                    else => unreachable,
                };
                if (combo.push(.{ .action = action })) out.combo = .appended;
            },
            // D-pad: aims the cursor, never touches the combo.
            .up, .down, .left, .right => {
                const dir: protocol.CursorDir = switch (key) {
                    .up => .up,
                    .down => .down,
                    .left => .left,
                    .right => .right,
                    else => unreachable,
                };
                // Overflow drops the excess rather than growing unboundedly;
                // a burst past the cap is beyond human input rates.
                if (out.step_count < MAX_CURSOR_STEPS) {
                    out.steps[out.step_count] = dir;
                    out.step_count += 1;
                }
            },
        }
    }
    return out;
}

test "drain: enter hands the combo over and empties the buffer" {
    var queue = KeyQueue{};
    var combo = ComboBuffer{};
    queue.push(.one);
    queue.push(.enter);
    const out = drain(&queue, &combo);
    // The committed recipe travels in the RESULT...
    const submitted = out.combo.submitted;
    try std.testing.expectEqual(@as(u8, 1), submitted.len);
    try std.testing.expectEqual(c.ActionChoice.dispense, submitted.slots[0].action);
    // ...and no longer in the buffer.
    try std.testing.expectEqual(@as(u8, 0), combo.len);
}

test "drain: a spent recipe never leaks into the next cast" {
    // Regression.  The buffer used to survive a submit and be cleared only by
    // a server reply, but a cast that RESOLVES IMMEDIATELY (every solo recipe)
    // answers with recipe_fired and never with cast_committed/cast_fizzled.
    // So typing "1" after firing poke sent [dispense, dispense] — a sweep the
    // player never asked for.
    var queue = KeyQueue{};
    var combo = ComboBuffer{};
    queue.push(.one);
    queue.push(.enter);
    try std.testing.expectEqual(@as(u8, 1), drain(&queue, &combo).combo.submitted.len);

    queue.push(.one);
    queue.push(.enter);
    const second = drain(&queue, &combo).combo.submitted;
    try std.testing.expectEqual(@as(u8, 1), second.len);
}

test "drain: escape returns cancelled and empties the buffer" {
    var queue = KeyQueue{};
    var combo = ComboBuffer{};
    queue.push(.one);
    queue.push(.two);
    queue.push(.escape);
    queue.push(.enter);
    const out = drain(&queue, &combo);
    try std.testing.expectEqual(DrainResult.cancelled, out.combo);
    try std.testing.expectEqual(@as(u8, 0), combo.len);
}

test "drain: action keys append in press order" {
    var queue = KeyQueue{};
    var combo = ComboBuffer{};
    queue.push(.two);
    queue.push(.one);
    const out = drain(&queue, &combo);
    try std.testing.expectEqual(DrainResult.appended, out.combo);
    try std.testing.expectEqual(@as(u8, 2), combo.len);
    try std.testing.expectEqual(c.ActionChoice.catalyst, combo.slots[0].action);
    try std.testing.expectEqual(c.ActionChoice.dispense, combo.slots[1].action);
}

test "drain: d-pad keys yield cursor steps and leave the combo alone" {
    var queue = KeyQueue{};
    var combo = ComboBuffer{};
    queue.push(.up);
    queue.push(.right);
    const out = drain(&queue, &combo);
    try std.testing.expectEqual(DrainResult.unchanged, out.combo);
    try std.testing.expectEqual(@as(u8, 0), combo.len);
    try std.testing.expectEqualSlices(
        protocol.CursorDir,
        &.{ .up, .right },
        out.cursor_steps(),
    );
}

test "drain: aiming and typing interleave freely" {
    // Re-aiming mid-combo is the core of the mechanic; neither input blocks.
    var queue = KeyQueue{};
    var combo = ComboBuffer{};
    queue.push(.one);
    queue.push(.left);
    queue.push(.two);
    queue.push(.left);
    const out = drain(&queue, &combo);
    try std.testing.expectEqual(DrainResult.appended, out.combo);
    try std.testing.expectEqual(@as(u8, 2), combo.len);
    try std.testing.expectEqual(@as(usize, 2), out.step_count);
}

test "drain: opposing steps are kept, not cancelled out" {
    // The server clamps, so collapsing these into a net zero would be wrong
    // whenever the cursor starts against an edge.
    var queue = KeyQueue{};
    var combo = ComboBuffer{};
    queue.push(.left);
    queue.push(.left);
    queue.push(.right);
    const out = drain(&queue, &combo);
    try std.testing.expectEqualSlices(
        protocol.CursorDir,
        &.{ .left, .left, .right },
        out.cursor_steps(),
    );
}

test "drain: steps pressed before a submit still travel with it" {
    var queue = KeyQueue{};
    var combo = ComboBuffer{};
    queue.push(.one);
    queue.push(.down);
    queue.push(.enter);
    const out = drain(&queue, &combo);
    try std.testing.expectEqual(@as(u8, 1), out.combo.submitted.len);
    // The step that aimed this cast must not be swallowed by the commit.
    try std.testing.expectEqualSlices(protocol.CursorDir, &.{.down}, out.cursor_steps());
}

test "drain: a step burst past the cap is dropped, not overflowed" {
    var queue = KeyQueue{};
    var combo = ComboBuffer{};
    var i: usize = 0;
    while (i < MAX_CURSOR_STEPS + 5) : (i += 1) queue.push(.up);
    const out = drain(&queue, &combo);
    try std.testing.expectEqual(MAX_CURSOR_STEPS, out.step_count);
}

test "drain: an empty queue changes nothing" {
    var queue = KeyQueue{};
    var combo = ComboBuffer{};
    const out = drain(&queue, &combo);
    try std.testing.expectEqual(DrainResult.unchanged, out.combo);
    try std.testing.expectEqual(@as(usize, 0), out.step_count);
}

test "parse_key_name maps the d-pad and rejects the old color keys" {
    try std.testing.expectEqual(RawKey.up, parse_key_name("ArrowUp").?);
    try std.testing.expectEqual(RawKey.down, parse_key_name("ArrowDown").?);
    try std.testing.expectEqual(RawKey.left, parse_key_name("ArrowLeft").?);
    try std.testing.expectEqual(RawKey.right, parse_key_name("ArrowRight").?);
    try std.testing.expectEqual(RawKey.one, parse_key_name("1").?);
    try std.testing.expectEqual(RawKey.two, parse_key_name("2").?);
    // Colors are difficulty tiers now, not input.
    try std.testing.expectEqual(@as(?RawKey, null), parse_key_name("q"));
    try std.testing.expectEqual(@as(?RawKey, null), parse_key_name("r"));
}

test "ComboBuffer refuses to grow past MAX_COMBO_LEN" {
    var combo = ComboBuffer{};
    var i: usize = 0;
    while (i < c.MAX_COMBO_LEN) : (i += 1)
        try std.testing.expect(combo.push(.{ .action = .dispense }));
    try std.testing.expect(!combo.push(.{ .action = .catalyst }));
    try std.testing.expectEqual(c.MAX_COMBO_LEN, combo.len);
}
