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

/// One line of bridge text, delimiter consumed and stripped; null at clean EOF.
///
/// This exists to name a trap.  The obvious-looking `takeDelimiterExclusive`
/// tosses only the line's own bytes and LEAVES the '\n' in the buffer, so the
/// next call finds the delimiter at offset 0, returns an empty slice, tosses
/// nothing, and spins on empty lines forever — a silent livelock that starves
/// the whole client of input while looking, from the outside, like a stall.
/// `takeDelimiter` consumes the delimiter and reports clean EOF as null.
///
/// `error.StreamTooLong` means the line outran the reader's buffer and NOTHING
/// was consumed; the caller must discard to the next newline or it will spin on
/// the same line.  `error.ReadFailed` leaves the cause in the reader's `err`.
pub fn next_line(reader: *std.io.Reader) error{ ReadFailed, StreamTooLong }!?[]const u8 {
    const line = try reader.takeDelimiter('\n') orelse return null;
    // The bridge is line-oriented; a CRLF pipe must not smuggle a '\r' into a
    // key name or a hex payload.
    return std.mem.trimRight(u8, line, "\r");
}

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
    /// Enter was pressed: fire whatever the server has selected.  At most
    /// one per drain, because `drain` returns as soon as it sees one.
    cast: bool = false,
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

/// Drain the key queue into wheel turns, cursor steps, and at most one cast.
///
/// A cast stops the drain so the caller sees exactly one per call, but any
/// turns and steps pressed BEFORE it are still returned — they are what chose
/// and aimed the cast being fired.
pub fn drain(queue: *KeyQueue) Drained {
    var out = Drained{};
    while (queue.pop()) |key| {
        switch (key) {
            .enter => {
                out.cast = true;
                return out;
            },
            // Inert: a realtime cast resolves the instant it fires, so there
            // is nothing pending for undo to take back.  The key stays
            // parsed so a board's D button is a clean no-op, not a typo.
            .escape => {},
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
    // It used to take back a pending lock-in.  A realtime cast resolves the
    // instant it fires, so there is nothing left for the key to undo.
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

test "next_line: consumes the delimiter instead of spinning on it" {
    // The regression this function is named for. With takeDelimiterExclusive
    // this loop never terminates: line 2 onward come back as empty slices
    // forever, because the '\n' is never consumed.
    var r = std.io.Reader.fixed("READY\nJOIN\nWIRE:abcd\n");
    var seen: [8][]const u8 = undefined;
    var n: usize = 0;
    while (try next_line(&r)) |line| {
        // A spin shows up here as an unbounded run of empty lines, so cap it
        // rather than hanging the test runner.
        try std.testing.expect(n < seen.len);
        seen[n] = line;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("READY", seen[0]);
    try std.testing.expectEqualStrings("JOIN", seen[1]);
    try std.testing.expectEqualStrings("WIRE:abcd", seen[2]);
}

test "next_line: a blank line is a line, not end of stream" {
    // Distinct from the spin: one genuine empty line must be reported once and
    // must not be mistaken for EOF, or a stray newline would kill the reader.
    var r = std.io.Reader.fixed("\nJOIN\n");
    const first = try next_line(&r);
    try std.testing.expectEqualStrings("", first.?);
    const second = try next_line(&r);
    try std.testing.expectEqualStrings("JOIN", second.?);
    try std.testing.expectEqual(@as(?[]const u8, null), try next_line(&r));
}

test "next_line: an unterminated final line still arrives" {
    // The bridge can die mid-write; whatever it managed to send is still a
    // line, and the EOF after it is clean.
    var r = std.io.Reader.fixed("READY\nJOI");
    _ = try next_line(&r);
    try std.testing.expectEqualStrings("JOI", (try next_line(&r)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try next_line(&r));
}

test "next_line: strips a CRLF carriage return" {
    var r = std.io.Reader.fixed("KEY:Enter\r\n");
    try std.testing.expectEqualStrings("KEY:Enter", (try next_line(&r)).?);
}
