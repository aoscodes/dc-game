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
/// Both are written by the Node bridge to our stdin.
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
    our_player_id: u8 = 0xFF,
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
//
// Reads newline-delimited lines from stdin forever.  Each line is either:
//   WIRE:<hex>   — server message bytes, hex-encoded, no spaces
//   KEY:<name>   — browser keydown event name

fn stdin_reader(_: void) void {
    var stdin_file = std.fs.File.stdin();
    const stdin = stdin_file.deprecatedReader();
    var line_buf: [4096]u8 = undefined;
    var hex_buf: [2048]u8 = undefined;

    while (true) {
        const line = stdin.readUntilDelimiter(&line_buf, '\n') catch |err| {
            if (err == error.EndOfStream) return; // bridge closed stdin
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
    if (g_state.our_player_id != 0xFF) {
        proto.encode(w, .reconnect, proto.Reconnect{ .player_id = g_state.our_player_id }) catch return;
    } else {
        const name = "Player";
        var p = proto.JoinLobby{ .name = [_]u8{0} ** 16, .name_len = @intCast(name.len) };
        @memcpy(p.name[0..name.len], name);
        proto.encode(w, .join_lobby, p) catch return;
    }
    emit_send(fbs.getWritten());
}

fn send_choose_class(class: c.ClassTag) void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .choose_class, proto.ChooseClass{ .class = class }) catch return;
    emit_send(fbs.getWritten());
}

fn send_ready_up() void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .ready_up, {}) catch return;
    emit_send(fbs.getWritten());
}

fn send_action(action: proto.ActionTag, target: u32) void {
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .choose_action, proto.ChooseAction{
        .action = action,
        .target_entity = target,
    }) catch return;
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
                if (p.your_player_id != 0xFF) {
                    g_state.our_player_id = p.your_player_id;
                }
                g_state.lobby.update = p;
                g_state.lobby.our_player_id = g_state.our_player_id;
                g_state.phase = .lobby;
            },
            .game_start => {
                const p = proto.decode_game_start(r) catch continue;
                g_state.our_player_id = p.your_player_id;
                g_state.game = .{};
                g_state.game.our_player_id = p.your_player_id;
                g_state.game.wave_label_len = p.wave_label_len;
                @memcpy(g_state.game.wave_label[0..p.wave_label_len], p.wave_label[0..p.wave_label_len]);
                g_state.phase = .game;
            },
            .game_state => {
                const p = proto.decode_game_state(r) catch continue;
                g_state.game.snapshot = p;
            },
            .your_turn => {
                const p = proto.decode_your_turn(r) catch continue;
                for (g_state.game.snapshot.entities[0..g_state.game.snapshot.entity_count]) |e| {
                    if (e.entity == p.entity and e.owner == g_state.game.our_player_id) {
                        g_state.game.cursor.is_our_turn = true;
                        g_state.game.cursor.cursor_col = 0;
                        g_state.game.cursor.cursor_row = 0;
                        g_state.game.action_selected = null;
                        g_state.game.our_entity = p.entity;
                        break;
                    }
                }
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

fn is_our_class(gs: *const GameState, class: c.ClassTag) bool {
    for (gs.snapshot.entities[0..gs.snapshot.entity_count]) |e| {
        if (e.owner == gs.our_player_id) return e.class == class;
    }
    return false;
}

fn update_lobby() void {
    const key = g_key_queue.pop() orelse return;
    switch (key) {
        .one => {
            g_state.lobby.selected_class = .fighter;
            send_choose_class(.fighter);
        },
        .two => {
            g_state.lobby.selected_class = .mage;
            send_choose_class(.mage);
        },
        .three => {
            g_state.lobby.selected_class = .healer;
            send_choose_class(.healer);
        },
        .enter => {
            g_state.lobby.ready = !g_state.lobby.ready;
            send_ready_up();
        },
        else => {},
    }
}

fn update_game() void {
    const gs = &g_state.game;
    const ev = gs.cursor.poll(&g_key_queue);

    switch (ev) {
        .none => {},
        .cursor_move => |delta| {
            gs.cursor.apply_cursor_move(delta, 3, 4);
        },
        .select_attack => {
            gs.action_selected = .attack;
            gs.targeting_enemy = !is_our_class(gs, .healer);
        },
        .select_defend => {
            gs.action_selected = .defend;
        },
        .confirm => {
            if (gs.action_selected) |action| {
                var target: u32 = 0;
                if (action == .attack) {
                    const target_team: c.TeamId = if (gs.targeting_enemy) .enemies else .players;
                    const cur = gs.cursor.grid_pos();
                    for (gs.snapshot.entities[0..gs.snapshot.entity_count]) |e| {
                        if (e.team == target_team and
                            e.grid_col == cur.col and
                            e.grid_row == cur.row)
                        {
                            target = e.entity;
                            break;
                        }
                    }
                }
                send_action(action, target);
                gs.cursor.is_our_turn = false;
                gs.action_selected = null;
            }
        },
        .cancel => {
            gs.action_selected = null;
        },
    }
}

// ---------------------------------------------------------------------------
// Bridge handshake
// ---------------------------------------------------------------------------
//
// The bridge writes "READY\n" once the game server WebSocket opens.
// stdin_reader handles this line and sets g_ready; main blocks until then
// so the first render frame doesn't race with send_join.

var g_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    // stdin_reader owns all stdin I/O, including the initial READY handshake.
    const stdin_thread = try std.Thread.spawn(.{}, stdin_reader, .{{}});
    stdin_thread.detach();

    // Do NOT spin-wait for READY here.  The render loop runs from the moment
    // the binary starts, emitting "connecting" phase frames so the browser
    // shows the connecting screen immediately.  stdin_reader will set g_ready
    // and call send_join() asynchronously once the server handshake arrives.

    const out = stdout_writer();
    var next_tick = std.time.nanoTimestamp();

    while (true) {
        // Drain any inbound messages only once we're past the handshake; before
        // that the queue is always empty, but calling it is harmless.
        process_recv();

        switch (g_state.phase) {
            // Emit "connecting" frames immediately so the browser shows the
            // connecting screen rather than a blank canvas while waiting for
            // the server.  (g_ready being false just means we haven't sent
            // join yet; it is safe to render the phase we're in.)
            .connecting => {},
            .lobby => update_lobby(),
            .game => update_game(),
            .game_over => {
                // Any key returns to lobby; bridge will reconnect.
                if (g_key_queue.pop() != null) {
                    g_state.phase = .lobby;
                }
            },
        }

        out.write_render(g_state.phase, &g_state.lobby, &g_state.game);

        // Fixed-rate sleep: accumulate timing debt rather than drifting.
        next_tick += TICK_NS;
        const now = std.time.nanoTimestamp();
        if (next_tick > now) {
            std.Thread.sleep(@intCast(next_tick - now));
        } else {
            // We're behind; reset rather than spinning.
            next_tick = std.time.nanoTimestamp();
        }
    }
}
