const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;

const inp = @import("input.zig");
const sw = @import("stdout_writer.zig");

const ClientPhaseTag = sw.ClientPhaseTag;
const LobbyState = sw.LobbyState;
const GameState = sw.GameState;

const WIRE_PREFIX = "WIRE:";
const KEY_PREFIX  = "KEY:";

const RENDER_HZ: u64 = 60;
const TICK_NS: u64 = std.time.ns_per_s / RENDER_HZ;

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
    lobby: LobbyState = .{},
    game: GameState = .{},
    player_id: u8 = 0xFF,
    send_buf: [512]u8 = undefined,
    recv_queue: MsgQueue = .{},
    recv_scratch: [4096]u8 = undefined,
};

var g_state: ClientState = .{};
var g_key_queue: inp.KeyQueue = .{};

var g_stdout_mu: std.Thread.Mutex = .{};

fn stdout_writer() sw.Writer {
    return .{ .mu = &g_stdout_mu };
}

fn stdin_reader(_: void) void {
    var stdin_file = std.fs.File.stdin();
    const stdin = stdin_file.deprecatedReader();
    var line_buf: [4096]u8 = undefined;
    var hex_buf: [2048]u8 = undefined;

    while (true) {
        const line = stdin.readUntilDelimiter(&line_buf, '\n') catch |err| {
            if (err == error.EndOfStream) return;
            std.log.err("stdin read error: {}", .{err});
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        const trimmed = std.mem.trimRight(u8, line, "\r");

        if (std.mem.eql(u8, trimmed, "READY")) {
            g_ready.store(true, .release);
            send_join();
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
        }
    }
}

fn emit_send(bytes: []const u8) void {
    stdout_writer().write_send(bytes);
}

fn send_join() void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    const w = fbs.writer();
    if (g_state.player_id != 0xFF) {
        proto.encode(w, .reconnect, proto.Reconnect{ .player_id = g_state.player_id }) catch return;
    } else {
        const name = "Player";
        var p = proto.JoinLobby{ .name = [_]u8{0} ** 16, .name_len = @intCast(name.len) };
        @memcpy(p.name[0..name.len], name);
        proto.encode(w, .join_lobby, p) catch return;
    }
    emit_send(fbs.getWritten());
}

fn send_ready_up() void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .ready_up, {}) catch return;
    emit_send(fbs.getWritten());
}

fn send_combo(combo: *const inp.ComboBuffer) void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .choose_combo, proto.ChooseCombo{ .combo = combo.to_combo() }) catch return;
    emit_send(fbs.getWritten());
}

fn send_cancel_combo() void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .cancel_combo, {}) catch return;
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
            .lobby_update => {
                const p = proto.decode_lobby_update(r) catch |err| {
                    std.log.err("decode lobby_update: {}", .{err});
                    continue;
                };
                if (p.player_id != 0xFF) {
                    g_state.player_id = p.player_id;
                }
                g_state.lobby.update = p;
                g_state.lobby.player_id = g_state.player_id;
                // The server broadcasts a lobby_update right after game_over
                // (ready flags reset).  Keep showing the outcome screen; the
                // stored lobby state is used once the player presses a key.
                if (g_state.phase != .game_over) {
                    g_state.phase = .lobby;
                }
            },
            .game_start => {
                const p = proto.decode_game_start(r) catch continue;
                g_state.player_id = p.player_id;
                g_state.game = .{};
                g_state.game.player_id = p.player_id;
                g_state.game.round_timer = p.round_duration;
                g_state.game.round_duration = p.round_duration;
                g_state.game.casts_per_round = p.casts_per_round;
                g_state.game.encounter_label_len = p.encounter_label_len;
                @memcpy(g_state.game.encounter_label[0..p.encounter_label_len], p.encounter_label[0..p.encounter_label_len]);
                g_state.phase = .game;
            },
            .game_state => {
                const p = proto.decode_game_state(r) catch continue;
                g_state.game.snapshot = p;
                g_state.game.round_timer = p.round_timer;
            },
            .game_over => {
                const p = proto.decode_game_over(r) catch continue;
                g_state.game.final_score = p.score;
                g_state.game.final_stats = p.stats;
                // Server resets ready flags at game end; mirror locally so the
                // lobby prompt is correct when the player returns.
                g_state.lobby.ready = false;
                g_state.phase = .game_over;
            },
            .action_result => {
                const p = proto.decode_action_result(r) catch continue;
                const anim: c.ActionAnimation = switch (p.tag) {
                    .damage, .heal, .cast => .attack,
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
            .round_reset => {
                g_state.game.round += 1;
                g_state.game.pending_combo.clear();
            },
            .cast_committed => {
                const p = proto.decode_cast_committed(r) catch continue;
                // Our pending combo was committed server-side; clear the
                // local buffer so the next spell starts fresh, and cancel
                // any stale in-flight combo the server may have stored after
                // the commit (keys racing the cast_committed message).
                if (p.player_id == g_state.player_id) {
                    g_state.game.pending_combo.clear();
                    send_cancel_combo();
                }
            },
            .cast_fizzled => {
                const p = proto.decode_cast_fizzled(r) catch continue;
                if (p.player_id == g_state.player_id) {
                    g_state.game.pending_combo.clear();
                    send_cancel_combo();
                }
                // Record for the renderer (transient, drained per frame).
                if (g_state.game.fizzle_count < g_state.game.fizzles.len) {
                    g_state.game.fizzles[g_state.game.fizzle_count] = p.player_id;
                    g_state.game.fizzle_count += 1;
                }
            },
            .recipe_fired => {
                const p = proto.decode_recipe_fired(r) catch continue;
                // Record for the renderer (transient, drained per frame).
                if (g_state.game.recipe_count < g_state.game.recipes_fired.len) {
                    g_state.game.recipes_fired[g_state.game.recipe_count] = p;
                    g_state.game.recipe_count += 1;
                }
            },
            else => {},
        }
    }
}

fn update_lobby() void {
    const key = g_key_queue.pop() orelse return;
    switch (key) {
        .enter => {
            g_state.lobby.ready = !g_state.lobby.ready;
            send_ready_up();
        },
        else => {},
    }
}

fn update_game() void {
    const gs = &g_state.game;
    const result = inp.drain_into_combo(&g_key_queue, &gs.pending_combo);
    switch (result) {
        .unchanged => {},
        .appended => send_combo(&gs.pending_combo),
        .cancelled => {
            gs.pending_combo.clear();
            send_cancel_combo();
        },
    }
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
            .lobby => update_lobby(),
            .game => update_game(),
            .game_over => {
                if (g_key_queue.pop() != null) {
                    g_state.phase = .lobby;
                }
            },
        }

        out.write_render(g_state.phase, &g_state.lobby, &g_state.game);

        next_tick += TICK_NS;
        const now = std.time.nanoTimestamp();
        if (next_tick > now) {
            std.Thread.sleep(@intCast(next_tick - now));
        } else {
            next_tick = std.time.nanoTimestamp();
        }
    }
}
