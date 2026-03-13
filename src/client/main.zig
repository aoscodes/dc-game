const std = @import("std");
const rl = @import("raylib");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;

const render = @import("render.zig");
const inp = @import("input.zig");

const net = if (@import("builtin").target.os.tag == .emscripten)
    @import("net/ws_browser.zig")
else
    @import("net/ws_native.zig");

const ClientPhase = enum { connecting, lobby, game, game_over };

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
            std.log.warn("msg queue full, dropping {} byte message", .{data.len});
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
    phase: ClientPhase = .connecting,
    lobby: render.LobbyState = .{},
    game: render.GameState = .{},
    transport: ?shared.Transport = null,
    our_player_id: u8 = 0xFF,
    send_buf: [512]u8 = undefined,
    recv_queue: MsgQueue = .{},
    recv_scratch: [4096]u8 = undefined,
};

var g_state: ClientState = .{};

// Storage for the server URL written by JS via g_server_url_buf before
// start_connect is called.  The buffer is large enough for any reasonable URL.
// Exported directly so JS can write into it without pointer indirection.
export var g_server_url_buf: [256]u8 = [_]u8{0} ** 256;
var g_server_url: []const u8 = "ws://127.0.0.1:9001";

var g_need_reconnect: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

var g_ws_transport: net.WsBrowserTransport = undefined;
var g_ws_transport_valid: bool = false;

fn connect_loop(_: void) void {
    while (true) {
        const result = net.WsBrowserTransport.connect(g_server_url);
        if (result) |t| {
            g_ws_transport = t;
            g_ws_transport_valid = true;
            g_state.transport = g_ws_transport.transport();
            g_need_reconnect.store(false, .monotonic);
            g_ws_transport.notify_open();
            while (!g_need_reconnect.load(.acquire)) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
            g_ws_transport.close();
            g_ws_transport_valid = false;
            g_state.transport = null;
            g_state.phase = .connecting;
        } else |_| {
            std.Thread.sleep(std.time.ns_per_s);
        }
    }
}

var g_name_buf: [16]u8 = [_]u8{0} ** 16;
var g_name_len: u8 = 0;

fn on_ws_open(_: i32) void {
    std.log.info("ws open", .{});
    send_join();
}

fn on_ws_message(_: i32, data: []const u8) void {
    std.log.info("ws message: {} bytes, tag=0x{x}", .{ data.len, if (data.len > 0) data[0] else 0 });
    g_state.recv_queue.push(data);
}

fn on_ws_close(_: i32) void {
    std.log.warn("ws closed", .{});
    g_need_reconnect.store(true, .release);
}

fn send_join() void {
    const t = g_state.transport orelse {
        std.log.err("send_join: no transport", .{});
        return;
    };
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    const w = fbs.writer();

    if (g_state.our_player_id != 0xFF) {
        std.log.info("send_join: reconnect pid={}", .{g_state.our_player_id});
        proto.encode(w, .reconnect, proto.Reconnect{ .player_id = g_state.our_player_id }) catch return;
    } else {
        std.log.info("send_join: join_lobby name={s}", .{g_name_buf[0..g_name_len]});
        var p = proto.JoinLobby{
            .name = [_]u8{0} ** 16,
            .name_len = g_name_len,
        };
        @memcpy(p.name[0..g_name_len], g_name_buf[0..g_name_len]);
        proto.encode(w, .join_lobby, p) catch return;
    }
    t.send(fbs.getWritten()) catch |err| {
        std.log.err("send_join: send failed: {}", .{err});
        return;
    };
}

fn send_choose_class(class: c.ClassTag) void {
    const t = g_state.transport orelse return;
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .choose_class, proto.ChooseClass{ .class = class }) catch return;
    t.send(fbs.getWritten()) catch return;
}

fn send_ready_up() void {
    const t = g_state.transport orelse return;
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .ready_up, {}) catch return;
    t.send(fbs.getWritten()) catch return;
}

fn send_action(action: proto.ActionTag, target: u32) void {
    const t = g_state.transport orelse return;
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    proto.encode(fbs.writer(), .choose_action, proto.ChooseAction{
        .action = action,
        .target_entity = target,
    }) catch return;
    t.send(fbs.getWritten()) catch return;
}

fn process_recv() void {
    while (g_state.recv_queue.pop(&g_state.recv_scratch)) |data| {
        var fbs = std.io.fixedBufferStream(data);
        const r = fbs.reader();

        const tag = proto.read_tag(r) catch |err| {
            std.log.err("process_recv: bad tag: {}", .{err});
            continue;
        };
        std.log.info("process_recv: tag={s}", .{@tagName(tag)});
        switch (tag) {
            .lobby_update => {
                const p = proto.decode_lobby_update(r) catch |err| {
                    std.log.err("decode lobby_update failed: {}", .{err});
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

fn update_lobby() void {
    if (rl.isKeyPressed(.one)) {
        g_state.lobby.selected_class = .fighter;
        send_choose_class(.fighter);
    }
    if (rl.isKeyPressed(.two)) {
        g_state.lobby.selected_class = .mage;
        send_choose_class(.mage);
    }
    if (rl.isKeyPressed(.three)) {
        g_state.lobby.selected_class = .healer;
        send_choose_class(.healer);
    }
    if (rl.isKeyPressed(.enter)) {
        g_state.lobby.ready = !g_state.lobby.ready;
        send_ready_up();
    }
}

fn is_our_class(gs: *render.GameState, class: c.ClassTag) bool {
    for (gs.snapshot.entities[0..gs.snapshot.entity_count]) |e| {
        if (e.owner == gs.our_player_id) return e.class == class;
    }
    return false;
}

fn update_game() void {
    const gs = &g_state.game;
    const ev = gs.cursor.poll();

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

export fn save_player_id(pid: u8) void {
    g_state.our_player_id = pid;
}

/// Called by JS after it has written the server URL into g_server_url_buf.
/// Reads the null-terminated string from the buffer and opens the WebSocket.
export fn start_connect() void {
    // Find null terminator to determine URL length.
    const len = std.mem.indexOfScalar(u8, &g_server_url_buf, 0) orelse g_server_url_buf.len;
    if (len > 0) g_server_url = g_server_url_buf[0..len];
    _ = net.WsBrowserTransport.connect(g_server_url) catch {};
}

export fn wasm_alloc(len: usize) ?[*]u8 {
    const mem = std.heap.page_allocator.alloc(u8, len) catch return null;
    return mem.ptr;
}

export fn wasm_free(ptr: [*]u8, len: usize) void {
    std.heap.page_allocator.free(ptr[0..len]);
}

pub fn main() !void {
    const default_name = "Player";
    g_name_len = @intCast(default_name.len);
    @memcpy(g_name_buf[0..g_name_len], default_name);

    net.set_callbacks(.{
        .on_open = on_ws_open,
        .on_message = on_ws_message,
        .on_close = on_ws_close,
    });

    // WASM is single-threaded: the browser WebSocket is purely event-driven
    // via JS callbacks (on_ws_open / on_ws_message / on_ws_close).  No
    // background thread is needed; JS calls start_connect() explicitly after
    // writing the server URL into g_server_url_buf via g_server_url_ptr.
    // On native, the connect loop runs in a dedicated thread so it can block
    // on send/recv and still let the Raylib render loop run.
    if (comptime @import("builtin").target.os.tag == .emscripten) {
        // connect deferred — JS calls start_connect() after setting URL
    } else {
        const loop_thread = try std.Thread.spawn(.{}, connect_loop, .{{}});
        loop_thread.detach();
    }

    rl.initWindow(@intFromFloat(render.SW), @intFromFloat(render.SH), "Client");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        process_recv();

        switch (g_state.phase) {
            .connecting => {},
            .lobby => update_lobby(),
            .game => update_game(),
            .game_over => {
                if (rl.isKeyPressed(.enter)) g_state.phase = .lobby;
            },
        }

        rl.beginDrawing();
        defer rl.endDrawing();

        switch (g_state.phase) {
            .connecting => {
                rl.clearBackground(.black);
                rl.drawText("Connecting to server...", 40, 40, 24, .ray_white);
            },
            .lobby => render.draw_lobby(&g_state.lobby),
            .game => render.draw_game(&g_state.game),
            .game_over => {
                rl.clearBackground(.black);
                rl.drawText("Game Over!  Press ENTER to return to lobby.", 40, 300, 24, .ray_white);
            },
        }

        rl.drawFPS(4, 4);
    }
}
