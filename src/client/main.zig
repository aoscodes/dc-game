const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;

const inp = @import("input.zig");
const sw = @import("stdout_writer.zig");

const ClientPhaseTag = sw.ClientPhaseTag;
const GameState = sw.GameState;

const WIRE_PREFIX = "WIRE:";
const KEY_PREFIX  = "KEY:";
/// Player stats fed in from hardware, e.g. "STAT:appetite=7" — the board's
/// persistent appetite counter, forwarded by the bridge (controllers.js).
const STAT_APPETITE_PREFIX = "STAT:appetite=";
/// The board's banked babies as a comma list per BabyType ordinal, e.g.
/// "STAT:babies=1,0,2,0,0".  Same lifecycle as the appetite line: sent by the
/// bridge before JOIN.
const STAT_BABIES_PREFIX = "STAT:babies=";
/// The board's resident critter as a BabyType ordinal, e.g. "STAT:critter=2",
/// and its three LED colours as hex, e.g. "STAT:led=d4506e,7ac0a0,e8c46a".
/// Both are purely cosmetic (what this player's Lil Guy looks like) and both
/// are sent only once the board has actually reported them - the bridge
/// withholds the line rather than sending a placeholder, so absent stays
/// distinguishable from chosen.
const STAT_CRITTER_PREFIX = "STAT:critter=";
const STAT_LED_PREFIX = "STAT:led=";

/// How often the loop WAKES.  Not how often it emits: input is forwarded at
/// this rate to keep presses responsive, while render frames go out only when
/// the server gives us something new to draw (see sw.RenderGate).  Emitting at
/// this rate was the animation-loss bug — it split a tick's events from the
/// board they described, and sent each board three times over.
const POLL_HZ: u64 = 60;
const TICK_NS: u64 = std.time.ns_per_s / POLL_HZ;

const MsgQueue = struct {
    buf: [16384]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    mu: std.Thread.Mutex = .{},

    fn used(self: *const MsgQueue) usize {
        return (self.tail + self.buf.len - self.head) % self.buf.len;
    }

    fn free(self: *const MsgQueue) usize {
        return self.buf.len - 1 - self.used();
    }

    fn push(self: *MsgQueue, data: []const u8) void {
        if (data.len > 0xFFFF) return;
        self.mu.lock();
        defer self.mu.unlock();
        const needed = 2 + data.len;
        if (needed > self.free()) {
            std.log.warn("msg queue full, dropping {} bytes", .{data.len});
            return;
        }
        self.write_byte(@intCast(data.len & 0xFF));
        self.write_byte(@intCast(data.len >> 8));
        for (data) |b| self.write_byte(b);
    }

    fn pop(self: *MsgQueue, out: []u8) ?[]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.used() < 2) return null;
        const lo = self.peek_byte(0);
        const hi = self.peek_byte(1);
        const msg_len: usize = @as(usize, lo) | (@as(usize, hi) << 8);
        if (self.used() < 2 + msg_len) return null;
        self.head = (self.head + 2) % self.buf.len;
        if (msg_len > out.len) {
            std.log.warn("msg queue: message {} bytes too large for scratch, discarding", .{msg_len});
            self.head = (self.head + msg_len) % self.buf.len;
            return null;
        }
        for (out[0..msg_len]) |*b| {
            b.* = self.read_byte();
        }
        return out[0..msg_len];
    }

    inline fn write_byte(self: *MsgQueue, b: u8) void {
        self.buf[self.tail] = b;
        self.tail = (self.tail + 1) % self.buf.len;
    }

    inline fn read_byte(self: *MsgQueue) u8 {
        const b = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        return b;
    }

    inline fn peek_byte(self: *const MsgQueue, offset: usize) u8 {
        return self.buf[(self.head + offset) % self.buf.len];
    }
};

const ClientState = struct {
    phase: ClientPhaseTag = .connecting,
    game: GameState = .{},
    /// The seat this connection holds, or NO_PLAYER while observing.
    player_id: u8 = proto.NO_PLAYER,
    send_buf: [512]u8 = undefined,
    recv_queue: MsgQueue = .{},
    recv_scratch: [4096]u8 = undefined,
    /// Whether this frame has anything new to draw.  Armed by the messages
    /// that complete a tick or change our standing, never by the clock.
    render_gate: sw.RenderGate = .{},
};

var g_state: ClientState = .{};
var g_key_queue: inp.KeyQueue = .{};

// Appetite stat for take_slot, set via the STAT:appetite= stdio line BEFORE
// the JOIN line (hardware controller sessions send it right after spawn).
// Written and read only on the stdin thread, so no synchronisation needed.
var g_appetite: u32 = 0;
// Babies for take_slot, set via the STAT:babies= stdio line; same lifecycle
// and threading story as g_appetite.
var g_babies: c.BabyCounts = [_]u32{0} ** c.BabyType.size;
// Cosmetic appearance for take_slot, set via the STAT:critter= and STAT:led=
// stdio lines; same lifecycle and threading story as g_appetite.
var g_appearance: proto.Appearance = .{};

var g_stdout_mu: std.Thread.Mutex = .{};

fn stdout_writer() sw.Writer {
    return .{ .mu = &g_stdout_mu };
}

fn stdin_reader(_: void) void {
    const stdin_file = std.fs.File.stdin();
    // BUFFERED, and that matters for more than syscall count.  Unbuffered, a
    // line cost one read() per byte, which stretched the delivery of a single
    // wire message over milliseconds — wide enough for the render loop to run
    // between a tick's events and the board that described them, and split
    // them into two frames.  The gate (sw.RenderGate) is what makes that
    // harmless; this is what makes it rare.  Streaming mode because stdin is a
    // pipe: positional reads would just fail a syscall first.
    var read_buf: [8192]u8 = undefined;
    var stdin_reader_state = stdin_file.readerStreaming(&read_buf);
    const stdin = &stdin_reader_state.interface;
    var hex_buf: [2048]u8 = undefined;

    while (true) {
        const trimmed = inp.next_line(stdin) catch |err| switch (err) {
            // The line outran the buffer, and NOTHING was consumed — returning
            // to the top would spin on the same line forever.  Discard it up to
            // its newline and carry on with the next.
            error.StreamTooLong => {
                std.log.err("stdin line longer than {} bytes; discarding it", .{read_buf.len});
                _ = stdin.discardDelimiterInclusive('\n') catch return;
                continue;
            },
            error.ReadFailed => {
                std.log.err("stdin read error: {?}", .{stdin_reader_state.err});
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            },
            // The bridge closed our stdin: it is done with us, so stop reading.
        } orelse return;

        if (std.mem.eql(u8, trimmed, "READY")) {
            // The bridge's server socket is open.  Nothing to send: every
            // connection starts as an observer and the server has already
            // answered with a game_start.
            g_ready.store(true, .release);
        } else if (std.mem.eql(u8, trimmed, "JOIN")) {
            // The bridge asks this client to take a player seat (hardware
            // controller sessions send it right after READY).  Silently
            // ignored by the server when the game is full.
            send_take_slot();
        } else if (std.mem.eql(u8, trimmed, "RESTART")) {
            // The browser tab's report-screen button was clicked: the ONLY
            // way a next round starts.  It arrives as its own stdio line —
            // never a KEY: — so no keyboard mash can trigger it, and board
            // sessions (which have no button) can never send it.
            send_restart();
        } else if (std.mem.startsWith(u8, trimmed, WIRE_PREFIX)) {
            const hex = trimmed[WIRE_PREFIX.len..];
            const decoded = std.fmt.hexToBytes(&hex_buf, hex) catch |err| {
                std.log.err("hex decode error: {}", .{err});
                continue;
            };
            g_state.recv_queue.push(decoded);
        } else if (std.mem.startsWith(u8, trimmed, KEY_PREFIX)) {
            const key_name = trimmed[KEY_PREFIX.len..];
            if (inp.parse_key_name(key_name)) |key| {
                g_key_queue.push(key);
            }
        } else if (std.mem.startsWith(u8, trimmed, STAT_APPETITE_PREFIX)) {
            const value = trimmed[STAT_APPETITE_PREFIX.len..];
            g_appetite = std.fmt.parseInt(u32, value, 10) catch {
                std.log.warn("bad appetite stat line: {s}", .{trimmed});
                continue;
            };
        } else if (std.mem.startsWith(u8, trimmed, STAT_BABIES_PREFIX)) {
            g_babies = parse_baby_counts(trimmed[STAT_BABIES_PREFIX.len..]) orelse {
                std.log.warn("bad babies stat line: {s}", .{trimmed});
                continue;
            };
        } else if (std.mem.startsWith(u8, trimmed, STAT_CRITTER_PREFIX)) {
            const value = trimmed[STAT_CRITTER_PREFIX.len..];
            const ordinal = std.fmt.parseInt(u8, value, 10) catch {
                std.log.warn("bad critter stat line: {s}", .{trimmed});
                continue;
            };
            g_appearance.critter = std.meta.intToEnum(c.BabyType, ordinal) catch {
                std.log.warn("bad critter stat line: {s}", .{trimmed});
                continue;
            };
        } else if (std.mem.startsWith(u8, trimmed, STAT_LED_PREFIX)) {
            g_appearance.led = parse_led_colours(trimmed[STAT_LED_PREFIX.len..]) orelse {
                std.log.warn("bad led stat line: {s}", .{trimmed});
                continue;
            };
        }
    }
}

/// Parse "rrggbb,rrggbb,rrggbb" into the badge's three LED colours.  Null on
/// any malformed or miscounted list, so a garbled line leaves the previous
/// palette (or none) standing rather than half-applying a new one.
fn parse_led_colours(list: []const u8) ?[proto.LED_COUNT][3]u8 {
    var leds: [proto.LED_COUNT][3]u8 = undefined;
    var it = std.mem.splitScalar(u8, list, ',');
    for (&leds) |*rgb| {
        const field = std.mem.trim(u8, it.next() orelse return null, " ");
        if (field.len != 6) return null;
        for (rgb, 0..) |*channel, i| {
            channel.* = std.fmt.parseInt(u8, field[i * 2 ..][0..2], 16) catch return null;
        }
    }
    if (it.next() != null) return null;
    return leds;
}

fn emit_send(bytes: []const u8) void {
    stdout_writer().write_send(bytes);
}

/// Parse a "n,n,n,n,n" comma list into per-type baby counts.  Null on any
/// malformed or miscounted list, so a garbled stat line is ignored whole
/// rather than half-applied.
fn parse_baby_counts(list: []const u8) ?c.BabyCounts {
    var counts: c.BabyCounts = [_]u32{0} ** c.BabyType.size;
    var it = std.mem.splitScalar(u8, list, ',');
    for (&counts) |*count| {
        const field = it.next() orelse return null;
        count.* = std.fmt.parseInt(u32, std.mem.trim(u8, field, " "), 10) catch return null;
    }
    if (it.next() != null) return null;
    return counts;
}

/// Ask for a player seat, carrying the board's stats (all zero for browsers).
/// The server grants it with a personalized game_start, or silently ignores
/// the request when all seats are taken — either way this connection keeps
/// receiving the game.
fn send_take_slot() void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .take_slot, proto.TakeSlot{
        .appetite = g_appetite,
        .babies = g_babies,
        .appearance = g_appearance,
    }) catch return;
    emit_send(fbs.getWritten());
}

/// Give the seat up and observe.  The server confirms with a game_start
/// carrying NO_PLAYER.
fn send_leave_slot() void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .leave_slot, {}) catch return;
    emit_send(fbs.getWritten());
}

/// Ask the server to start the next encounter from the end screen.  Ignored
/// server-side while a game is running.
fn send_restart() void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .restart, {}) catch return;
    emit_send(fbs.getWritten());
}

/// One turn of the shape wheel.  Sent per press, not as a net offset: the
/// server wraps, so the number of turns is not recoverable from the difference
/// between where the wheel was and where it should end up.
fn send_cycle_shape(dir: c.CycleDir) void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .cycle_shape, proto.CycleShape{ .dir = dir }) catch return;
    emit_send(fbs.getWritten());
}

/// Fire the server's current selection at the server's current cursor.
/// There is nothing to send BUT the trigger: both are server state.
fn send_cast() void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .cast, {}) catch return;
    emit_send(fbs.getWritten());
}

fn send_move_cursor(dir: proto.CursorDir) void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .move_cursor, proto.MoveCursor{ .dir = dir }) catch return;
    emit_send(fbs.getWritten());
}

fn process_recv() void {
    while (g_state.recv_queue.pop(&g_state.recv_scratch)) |data| {
        var fbs = std.io.fixedBufferStream(data);
        const r = fbs.reader();

        const tag = proto.read_tag(r) catch |err| {
            std.log.err("process_recv: bad tag: {}", .{err});
            continue;
        };
        switch (tag) {
            .game_start => {
                // Arrives on connect, on every fresh encounter, and whenever
                // this connection's standing changes (seat granted or given
                // up).  The snapshot is deliberately KEPT: the next game_state
                // tick replaces it, and blanking here would flash an empty
                // board on a mere standing change.
                const p = proto.decode_game_start(r) catch continue;
                g_state.player_id = p.player_id;
                g_state.game.player_id = p.player_id;
                g_state.game.join_code = p.join_code;
                g_state.game.cast_cooldown_ms = p.cast_cooldown_ms;
                g_state.game.team_window_ms = p.team_window_ms;
                g_state.game.encounter_label_len = p.encounter_label_len;
                @memcpy(g_state.game.encounter_label[0..p.encounter_label_len], p.encounter_label[0..p.encounter_label_len]);
                // A fresh outro must not survive into the next encounter.
                g_state.game.final_score = null;
                g_state.game.final_stats = null;
                // A holding encounter shows the pre-match guide until a
                // browser tab clicks past it (another game_start follows).
                g_state.phase = if (p.prematch) .pre_match else .game;
                // ALWAYS, not just on a phase change: a re-issued game_start
                // is how a seat grant reaches us, and player_id is on screen.
                // The pre-match guide also depends on this — a holding session
                // broadcasts no game_state at all, so nothing else would ever
                // get the guide drawn.
                g_state.render_gate.note_standing();
            },
            .game_state => {
                const p = proto.decode_game_state(r) catch continue;
                g_state.game.snapshot = p;
                // The tick's board: its events are all in hand now, so this
                // is the moment the frame is complete.
                g_state.render_gate.note_state();
            },
            .game_over => {
                const p = proto.decode_game_over(r) catch continue;
                g_state.game.final_score = p.score;
                g_state.game.final_stats = p.stats;
                g_state.phase = .game_over;
                // The closing board came first (end_game broadcasts it before
                // the report), so this coalesces with it into one frame.
                g_state.render_gate.note_standing();
            },
            .action_result => {
                const p = proto.decode_action_result(r) catch continue;
                const anim: c.ActionAnimation = switch (p.tag) {
                    .damage, .cast => .attack,
                    .death => .die,
                };
                // Record actor animation (pool actions have no specific actor).
                if (p.actor_entity != 0xFFFFFFFF) {
                    const idx = g_state.game.last_action_count;
                    if (idx < proto.MAX_ENTITIES_WIRE) {
                        g_state.game.last_actions[idx] = .{ .entity = p.actor_entity, .anim = anim };
                        g_state.game.last_action_count += 1;
                    }
                }
                // Record die on target for death events.
                if (p.tag == .death) {
                    const idx = g_state.game.last_action_count;
                    if (idx < proto.MAX_ENTITIES_WIRE) {
                        g_state.game.last_actions[idx] = .{ .entity = p.target_entity, .anim = .die };
                        g_state.game.last_action_count += 1;
                    }
                }
            },
            .over_budget => {
                const p = proto.decode_over_budget(r) catch continue;
                // Record for the renderer (transient, drained per frame).
                g_state.game.over_budget = p;
            },
            .cast_refused => {
                const p = proto.decode_cast_refused(r) catch continue;
                // Record for the renderer (transient, drained per frame).
                g_state.game.cast_refused = p;
            },
            .recipe_fired => {
                const p = proto.decode_recipe_fired(r) catch continue;
                // Record for the renderer (transient, drained per frame).
                if (g_state.game.recipe_count < g_state.game.recipes_fired.len) {
                    g_state.game.recipes_fired[g_state.game.recipe_count] = p;
                    g_state.game.recipe_count += 1;
                }
            },
            .shape_cast => {
                const p = proto.decode_shape_cast(r) catch continue;
                // Record for the renderer (transient, drained per frame).
                const gs = &g_state.game;
                if (gs.shape_cast_count < gs.shape_casts.len) {
                    gs.shape_casts[gs.shape_cast_count] = p;
                    gs.shape_cast_count += 1;
                }
            },
            .bite_settled => {
                const p = proto.decode_bite_settled(r) catch continue;
                // Transient, drained per frame: the renderer plays the devour
                // animation off this.  A later bite in the same frame wins —
                // it describes the field the next snapshot will show.
                //
                // A frame is one server tick now (see sw.RenderGate), so this
                // only collapses when the server settles two bites in a single
                // tick: the catch-up path that needs a tick to overrun a whole
                // bite interval (seconds).  Rare, but it must not CORRUPT.
                // The per-pass events carry only a pass index, numbered from 0
                // by each bite, so keeping both bites' passes would let the
                // second bite's pass 0 masquerade as the first's and the
                // renderer would replay a cascade that never happened.  Drop
                // the superseded bite's passes with it: replaying only the
                // later feast is wrong by an animation, not by a board — the
                // snapshot we land on is the truth either way.
                const gs = &g_state.game;
                if (gs.bite_settled != null) {
                    std.log.warn(
                        "two bites settled in one tick (bite {} superseded {}); " ++
                            "dropping the earlier feast's {} refills and {} matches",
                        .{ p.bite, gs.bite_settled.?.bite, gs.refill_count, gs.special_match_count },
                    );
                    gs.refill_count = 0;
                    gs.special_match_count = 0;
                }
                gs.bite_settled = p;
            },
            .special_matched => {
                const p = proto.decode_special_matched(r) catch continue;
                // Record for the renderer (transient, drained per frame).
                const gs = &g_state.game;
                if (gs.special_match_count < gs.special_matches.len) {
                    gs.special_matches[gs.special_match_count] = p;
                    gs.special_match_count += 1;
                }
            },
            .eggs_hatched => {
                const p = proto.decode_eggs_hatched(r) catch continue;
                // Transient, drained per frame — at most one per turn end.
                g_state.game.eggs_hatched = p;
            },
            .field_refilled => {
                const p = proto.decode_field_refilled(r) catch continue;
                // Record for the renderer (transient, drained per frame): one
                // per settle pass, and the renderer replays the cascade from
                // exactly these.
                const gs = &g_state.game;
                if (gs.refill_count < gs.refills.len) {
                    gs.refills[gs.refill_count] = p;
                    gs.refill_count += 1;
                }
            },
            else => {},
        }
    }
}

fn update_game() void {
    const drained = inp.drain(&g_key_queue);
    // Seat control first: everything else this frame only matters if the
    // server considers us seated, and the server processes in order.
    if (drained.take_seat) send_take_slot();
    if (drained.leave_seat) send_leave_slot();
    // Aim and choose FIRST: a step or a turn pressed before the trigger must
    // reach the server before the cast it was setting up, or the shape lands
    // at the stale cursor — or is the stale shape.
    for (drained.cursor_steps()) |dir| send_move_cursor(dir);
    for (drained.cycle_turns()) |dir| send_cycle_shape(dir);
    if (drained.cast) send_cast();
}

var g_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn main() !void {
    const stdin_thread = try std.Thread.spawn(.{}, stdin_reader, .{{}});
    stdin_thread.detach();

    const out = stdout_writer();
    var next_tick = std.time.nanoTimestamp();

    while (true) {
        process_recv();

        switch (g_state.phase) {
            .connecting => {},
            // Same input handling as play: seat keys (p / Shift+P) must work
            // while the guide holds; gameplay sends are ignored server-side.
            .pre_match => update_game(),
            .game => update_game(),
            .game_over => {
                // The end screen holds until a browser tab CLICKS the
                // report's button (the RESTART stdio line); keys do nothing
                // here, they are only drained so presses made at the buzzer
                // cannot leak into the next round.  The phase flips when the
                // server answers with a fresh game_start.
                _ = g_key_queue.pop();
            },
        }

        // Only when there is something new to say.  Checked here, after the
        // whole queue is drained, so every message a tick sent rides out in
        // ONE frame together with the board that reflects it.
        if (g_state.render_gate.take()) {
            out.write_render(g_state.phase, &g_state.game);
        }

        next_tick += TICK_NS;
        const now = std.time.nanoTimestamp();
        if (next_tick > now) {
            std.Thread.sleep(@intCast(next_tick - now));
        } else {
            next_tick = std.time.nanoTimestamp();
        }
    }
}
