//! Client input: raw keys in, wheel turns and cursor steps out.
//!
//! Three independent input axes, which is why draining yields all three at
//! once: `1`/`2` turn the shape wheel, the d-pad aims where a cast will land,
//! and Enter fires.  Nothing blocks anything else, so a player can re-aim
//! between turns of the wheel.
//!
//! There is NO client-side selection state.  The wheel lives on the server (it
//! is authoritative, and every client renders every player's choice), so this
//! layer only reports which way it was turned and how many times.  That is what
//! makes "client and server disagree about what is selected" unrepresentable.

const std = @import("std");
const shared = @import("shared");
const c = shared.components;
const protocol = shared.protocol;

pub fn parse_key_name(name: []const u8) ?RawKey {
    if (std.mem.eql(u8, name, "Enter")) return .enter;
    if (std.mem.eql(u8, name, "Escape")) return .escape;
    if (std.mem.eql(u8, name, "1")) return .one;
    if (std.mem.eql(u8, name, "2")) return .two;
    if (std.mem.eql(u8, name, "ArrowUp")) return .up;
    if (std.mem.eql(u8, name, "ArrowDown")) return .down;
    if (std.mem.eql(u8, name, "ArrowLeft")) return .left;
    if (std.mem.eql(u8, name, "ArrowRight")) return .right;
    // Seat control: p asks for a player slot, Shift+P gives it up.  Case is
    // the whole distinction, exactly as KeyboardEvent.key reports it.
    if (std.mem.eql(u8, name, "p")) return .take_seat;
    if (std.mem.eql(u8, name, "P")) return .leave_seat;

    return null;
}

pub const RawKey = enum { enter, escape, one, two, up, down, left, right, take_seat, leave_seat };

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

/// Cursor steps to forward, in the order they were pressed.  Steps are sent
/// individually rather than collapsed into a net delta: the server clamps at
/// the edge, so "left, left, right" against the wall must end one cell in
/// from the wall, not back where it started.
pub const MAX_CURSOR_STEPS: usize = 16;

/// Wheel turns to forward, in press order, for the same reason cursor steps
/// are: the server wraps, so "forward, forward, backward" is not the same as
/// "forward" whenever the wheel crosses the end of the table.
pub const MAX_CYCLE_TURNS: usize = 16;

pub const Drained = struct {
    step_count: usize = 0,
    steps: [MAX_CURSOR_STEPS]protocol.CursorDir = undefined,
    turn_count: usize = 0,
    turns: [MAX_CYCLE_TURNS]c.CycleDir = undefined,
    /// Enter was pressed: lock in whatever the server has selected.  At most
    /// one per drain, because `drain` returns as soon as it sees one.
    cast: bool = false,
    /// Escape presses: each takes back one of this player's pending casts,
    /// newest first.  Counted rather than flagged, so holding undo walks back
    /// through a plan one step per press instead of collapsing to one.
    cancels: u8 = 0,
    /// p was pressed: ask the server for a player seat (silently ignored when
    /// the game is full, or when this connection already holds one).
    take_seat: bool = false,
    /// Shift+P was pressed: give the seat up and go back to observing.
    leave_seat: bool = false,

    pub fn cursor_steps(self: *const Drained) []const protocol.CursorDir {
        return self.steps[0..self.step_count];
    }

    pub fn cycle_turns(self: *const Drained) []const c.CycleDir {
        return self.turns[0..self.turn_count];
    }
};

/// Drain the key queue into wheel turns, cursor steps, cancels, and at most
/// one cast.
///
/// A cast stops the drain so the caller sees exactly one per call, but any
/// turns, steps and cancels pressed BEFORE it are still returned — they are
/// what chose and aimed the cast being fired.
pub fn drain(queue: *KeyQueue) Drained {
    var out = Drained{};
    while (queue.pop()) |key| {
        switch (key) {
            .enter => {
                out.cast = true;
                return out;
            },
            // Undo: a cast is locked in, not fired, so it can be taken back
            // right up until the last player commits.  Saturates rather than
            // wrapping; nobody has more pending casts than a u8 can count.
            .escape => out.cancels +|= 1,
            // Seat control is a flag, not a count: taking a seat twice in one
            // frame is the same request twice, and the server ignores repeats
            // anyway.
            .take_seat => out.take_seat = true,
            .leave_seat => out.leave_seat = true,
            // 1 = next shape, 2 = previous.
            .one, .two => {
                const dir: c.CycleDir = switch (key) {
                    .one => .forward,
                    .two => .backward,
                    else => unreachable,
                };
                // Overflow drops the excess rather than growing unboundedly;
                // a burst past the cap is beyond human input rates.
                if (out.turn_count < MAX_CYCLE_TURNS) {
                    out.turns[out.turn_count] = dir;
                    out.turn_count += 1;
                }
            },
            // D-pad: aims the cursor, never touches the wheel.
            .up, .down, .left, .right => {
                const dir: protocol.CursorDir = switch (key) {
                    .up => .up,
                    .down => .down,
                    .left => .left,
                    .right => .right,
                    else => unreachable,
                };
                if (out.step_count < MAX_CURSOR_STEPS) {
                    out.steps[out.step_count] = dir;
                    out.step_count += 1;
                }
            },
        }
    }
    return out;
}

test "drain: enter reports a cast" {
    var queue = KeyQueue{};
    queue.push(.one);
    queue.push(.enter);
    const out = drain(&queue);
    try std.testing.expect(out.cast);
    // The turn that chose the shape travels with the cast that fires it.
    try std.testing.expectEqualSlices(c.CycleDir, &.{.forward}, out.cycle_turns());
}

test "drain: only one cast per call, and the rest of the queue survives" {
    // Two Enters in one burst must be two casts, not one: each is a charge.
    var queue = KeyQueue{};
    queue.push(.enter);
    queue.push(.enter);
    try std.testing.expect(drain(&queue).cast);
    try std.testing.expect(drain(&queue).cast);
    try std.testing.expect(!drain(&queue).cast);
}

test "drain: nothing is carried between calls" {
    // Regression in spirit: the old ComboBuffer survived a submit and leaked a
    // spent recipe into the next cast.  There is no client-side state left to
    // leak — a drain reports only keys pressed since the last one.
    var queue = KeyQueue{};
    queue.push(.one);
    queue.push(.enter);
    _ = drain(&queue);

    const second = drain(&queue);
    try std.testing.expect(!second.cast);
    try std.testing.expectEqual(@as(usize, 0), second.turn_count);
}

test "drain: escape is inert in game" {
    // It used to cancel a half-typed combo.  There is no half-typed anything
    // now, and the key is left to the lobby.
    var queue = KeyQueue{};
    queue.push(.one);
    queue.push(.escape);
    queue.push(.two);
    const out = drain(&queue);
    try std.testing.expect(!out.cast);
    try std.testing.expectEqualSlices(
        c.CycleDir,
        &.{ .forward, .backward },
        out.cycle_turns(),
    );
}

test "drain: 1 goes forward and 2 goes back, in press order" {
    var queue = KeyQueue{};
    queue.push(.two);
    queue.push(.one);
    queue.push(.one);
    const out = drain(&queue);
    try std.testing.expectEqualSlices(
        c.CycleDir,
        &.{ .backward, .forward, .forward },
        out.cycle_turns(),
    );
}

test "drain: opposing turns are kept, not cancelled out" {
    // The server WRAPS, so collapsing these into a net zero would be wrong
    // whenever the wheel crosses the end of the table.
    var queue = KeyQueue{};
    queue.push(.one);
    queue.push(.two);
    const out = drain(&queue);
    try std.testing.expectEqual(@as(usize, 2), out.turn_count);
}

test "drain: d-pad keys yield cursor steps and leave the wheel alone" {
    var queue = KeyQueue{};
    queue.push(.up);
    queue.push(.right);
    const out = drain(&queue);
    try std.testing.expectEqual(@as(usize, 0), out.turn_count);
    try std.testing.expect(!out.cast);
    try std.testing.expectEqualSlices(
        protocol.CursorDir,
        &.{ .up, .right },
        out.cursor_steps(),
    );
}

test "drain: aiming and cycling interleave freely" {
    // Re-aiming while choosing a shape is the core of the mechanic; neither
    // input blocks the other.
    var queue = KeyQueue{};
    queue.push(.one);
    queue.push(.left);
    queue.push(.two);
    queue.push(.left);
    const out = drain(&queue);
    try std.testing.expectEqual(@as(usize, 2), out.turn_count);
    try std.testing.expectEqual(@as(usize, 2), out.step_count);
}

test "drain: opposing steps are kept, not cancelled out" {
    // The server clamps, so collapsing these into a net zero would be wrong
    // whenever the cursor starts against an edge.
    var queue = KeyQueue{};
    queue.push(.left);
    queue.push(.left);
    queue.push(.right);
    const out = drain(&queue);
    try std.testing.expectEqualSlices(
        protocol.CursorDir,
        &.{ .left, .left, .right },
        out.cursor_steps(),
    );
}

test "drain: steps pressed before a cast still travel with it" {
    var queue = KeyQueue{};
    queue.push(.down);
    queue.push(.enter);
    const out = drain(&queue);
    try std.testing.expect(out.cast);
    // The step that aimed this cast must not be swallowed by the trigger.
    try std.testing.expectEqualSlices(protocol.CursorDir, &.{.down}, out.cursor_steps());
}

test "drain: a step burst past the cap is dropped, not overflowed" {
    var queue = KeyQueue{};
    var i: usize = 0;
    while (i < MAX_CURSOR_STEPS + 5) : (i += 1) queue.push(.up);
    try std.testing.expectEqual(MAX_CURSOR_STEPS, drain(&queue).step_count);
}

test "drain: a turn burst past the cap is dropped, not overflowed" {
    var queue = KeyQueue{};
    var i: usize = 0;
    while (i < MAX_CYCLE_TURNS + 5) : (i += 1) queue.push(.one);
    try std.testing.expectEqual(MAX_CYCLE_TURNS, drain(&queue).turn_count);
}

test "drain: an empty queue changes nothing" {
    var queue = KeyQueue{};
    const out = drain(&queue);
    try std.testing.expect(!out.cast);
    try std.testing.expectEqual(@as(usize, 0), out.turn_count);
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

test "parse_key_name: seat control is case-sensitive p vs P" {
    try std.testing.expectEqual(RawKey.take_seat, parse_key_name("p").?);
    try std.testing.expectEqual(RawKey.leave_seat, parse_key_name("P").?);
}

test "drain: seat keys surface as flags and block nothing" {
    var queue = KeyQueue{};
    queue.push(.take_seat);
    queue.push(.left);
    queue.push(.leave_seat);
    const out = drain(&queue);
    try std.testing.expect(out.take_seat);
    try std.testing.expect(out.leave_seat);
    try std.testing.expectEqualSlices(protocol.CursorDir, &.{.left}, out.cursor_steps());
}
