const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;

const inp = @import("input.zig");
const sw = @import("stdout_writer.zig");

// Re-export state types so the rest of the file doesn't need sw. prefix.
const ClientPhaseTag = sw.ClientPhaseTag;
const LobbyState = sw.LobbyState;
const GameState = sw.GameState;

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

/// Inbound server messages are hex-encoded lines prefixed with "WIRE:".
/// Key events arrive as lines prefixed with "KEY:".
const WIRE_PREFIX = "WIRE:";
const KEY_PREFIX = "KEY:";

/// Tick rate for the render/logic loop (does not affect server tick rate).
const RENDER_HZ: u64 = 60;
const TICK_NS: u64 = std.time.ns_per_s / RENDER_HZ;

const MsgQueue = struct {
    buf: [16384]u8 = undefined,
    len: usize = 0,
    mu: std.Thread.Mutex = .{},

    fn push(self: *MsgQueue, data: []const u8) void {
        if (data.len > 0xFFFF) return;
        self.mu.lock();
        defer self.mu.unlock();
        const needed = 2 + data.len;
        if (self.len + needed > self.buf.len) {
            std.log.warn("msg queue full, dropping {} bytes", .{data.len});
            return;
        }
        self.buf[self.len] = @intCast(data.len & 0xFF);
        self.buf[self.len + 1] = @intCast(data.len >> 8);
        @memcpy(self.buf[self.len + 2 .. self.len + 2 + data.len], data);
        self.len += needed;
    }

    fn pop(self: *MsgQueue, out: []u8) ?[]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.len < 2) return null;
        const msg_len: usize = @as(usize, self.buf[0]) | (@as(usize, self.buf[1]) << 8);
        if (self.len < 2 + msg_len) return null;
        if (msg_len > out.len) {
            std.mem.copyForwards(u8, self.buf[0..], self.buf[2 + msg_len .. self.len]);
            self.len -= 2 + msg_len;
            return null;
        }
        @memcpy(out[0..msg_len], self.buf[2 .. 2 + msg_len]);
        std.mem.copyForwards(u8, self.buf[0..], self.buf[2 + msg_len .. self.len]);
        self.len -= 2 + msg_len;
        return out[0..msg_len];
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

/// Mutex protecting stdout so stdin-reader and game loop don't interleave.
var g_stdout_mu: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// Stdout writer accessor
// ---------------------------------------------------------------------------

fn stdout_writer() sw.Writer {
    return .{ .mu = &g_stdout_mu };
}

// ---------------------------------------------------------------------------
// Stdin reader thread
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Protocol helpers — send to server via bridge
// ---------------------------------------------------------------------------

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

fn send_choose_position(col: u8, row: u8) void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .choose_position, proto.ChoosePosition{ .col = col, .row = row }) catch return;
    emit_send(fbs.getWritten());
}

fn send_ready_up() void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .ready_up, {}) catch return;
    emit_send(fbs.getWritten());
}

fn send_action(action: c.ActionChoice) void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .choose_action, proto.ChooseAction{ .action = action }) catch return;
    emit_send(fbs.getWritten());
}

// ---------------------------------------------------------------------------
// Message processing
// ---------------------------------------------------------------------------

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
                // Sync local cursor to the server-authoritative position.
                for (p.players[0..p.player_count]) |pi| {
                    if (pi.player_id == g_state.player_id) {
                        g_state.lobby.chosen_pos = .{
                            .col = pi.grid_col,
                            .row = pi.grid_row,
                        };
                        break;
                    }
                }
                g_state.phase = .lobby;
            },
            .game_start => {
                const p = proto.decode_game_start(r) catch continue;
                g_state.player_id = p.player_id;
                g_state.game = .{};
                g_state.game.player_id = p.player_id;
                g_state.game.round_timer = p.round_duration;
                g_state.game.round_duration = p.round_duration;
                g_state.game.wave_label_len = p.wave_label_len;
                @memcpy(g_state.game.wave_label[0..p.wave_label_len], p.wave_label[0..p.wave_label_len]);
                g_state.phase = .game;
            },
            .game_state => {
                const p = proto.decode_game_state(r) catch continue;
                g_state.game.snapshot = p;
                g_state.game.round_timer = p.round_timer;
            },
            .game_over => {
                _ = proto.decode_game_over(r) catch continue;
                g_state.phase = .game_over;
            },
            .action_result => {
                _ = proto.decode_action_result(r) catch continue;
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Update logic
// ---------------------------------------------------------------------------

fn update_lobby() void {
    const key = g_key_queue.pop() orelse return;
    switch (key) {
        .enter => {
            g_state.lobby.ready = !g_state.lobby.ready;
            send_ready_up();
        },
        // Arrow keys move the cosmetic position cursor in the lobby.
        .up => {
            if (g_state.lobby.chosen_pos.row > 0) {
                g_state.lobby.chosen_pos.row -= 1;
                send_choose_position(g_state.lobby.chosen_pos.col, g_state.lobby.chosen_pos.row);
            }
        },
        .down => {
            if (g_state.lobby.chosen_pos.row < 3) {
                g_state.lobby.chosen_pos.row += 1;
                send_choose_position(g_state.lobby.chosen_pos.col, g_state.lobby.chosen_pos.row);
            }
        },
        .left => {
            if (g_state.lobby.chosen_pos.col < 2) {
                g_state.lobby.chosen_pos.col += 1;
                send_choose_position(g_state.lobby.chosen_pos.col, g_state.lobby.chosen_pos.row);
            }
        },
        .right => {
            if (g_state.lobby.chosen_pos.col > 0) {
                g_state.lobby.chosen_pos.col -= 1;
                send_choose_position(g_state.lobby.chosen_pos.col, g_state.lobby.chosen_pos.row);
            }
        },
        else => {},
    }
}

fn update_game() void {
    const gs = &g_state.game;
    const ev = inp.poll(&g_key_queue);
    switch (ev) {
        .none => {},
        .damage => {
            gs.pending_action = .damage;
            send_action(.damage);
        },
        .shield => {
            gs.pending_action = .shield;
            send_action(.shield);
        },
        .heal => {
            gs.pending_action = .heal;
            send_action(.heal);
        },
    }
}

// ---------------------------------------------------------------------------
// Bridge handshake
// ---------------------------------------------------------------------------

var g_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

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
