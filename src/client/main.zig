//! JRPG client entry point.
//!
//! Runs on native desktop (dev/test) and WASM (browser via Emscripten).
//! In both cases the game loop is driven by raylib's `WindowShouldClose`
//! / Emscripten main-loop callback.
//!
//! Responsibilities:
//!   1. Open the raylib window.
//!   2. Connect to the game server via WebSocket (native: ws_native stub;
//!      WASM: ws_browser extern bindings).
//!   3. Maintain `ClientState` — the locally-mirrored game state received
//!      from the server.
//!   4. Drive the input system and produce `ChooseAction` messages.
//!   5. Call the render module each frame.

const std = @import("std");
const rl = @import("raylib");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;

const render = @import("render.zig");
const inp = @import("input.zig");

// On WASM the ws_browser module provides extern bindings.
// On native we use a thin blocking WS client (ws_native.zig).
const net = if (@import("builtin").target.os.tag == .emscripten)
    @import("net/ws_browser.zig")
else
    @import("net/ws_native.zig");

// ---------------------------------------------------------------------------
// Client state machine
// ---------------------------------------------------------------------------

const ClientPhase = enum { connecting, lobby, game, game_over };

/// Simple mutex-protected message queue.
/// The WS read thread pushes; the main loop pops one message at a time.
const MsgQueue = struct {
    /// Flat byte buffer storing length-prefixed messages (2-byte LE header).
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

    /// Pop one message into `out`. Returns slice or null if empty.
    fn pop(self: *MsgQueue, out: []u8) ?[]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.len < 2) return null;
        const msg_len: usize = @as(usize, self.buf[0]) | (@as(usize, self.buf[1]) << 8);
        if (self.len < 2 + msg_len) return null;
        if (msg_len > out.len) {
            // Skip oversized message.
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
    /// Our assigned player_id — set from lobby_update and game_start.
    /// 0xFF = not yet assigned.
    our_player_id: u8 = 0xFF,

    /// Scratch buffer for outgoing messages.
    send_buf: [512]u8 = undefined,
    /// Message queue: WS read thread pushes, main loop pops.
    recv_queue: MsgQueue = .{},
    /// Scratch buffer used by process_recv to pop one message at a time.
    recv_scratch: [4096]u8 = undefined,
};

/// Global client state — one instance per WASM module / process.
var g_state: ClientState = .{};

/// Server URL used by the connection loop.
var g_server_url: []const u8 = "ws://127.0.0.1:9001";

/// Set by on_ws_close (from the read thread) to signal that the connection
/// dropped and the connect loop should retry.  Cleared by the connect loop.
var g_need_reconnect: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Persistent storage for the WsBrowserTransport.  Lives at a stable address
/// so the read thread can hold a pointer to it for its full lifetime.
/// Only ever written by the connect loop thread.
var g_ws_transport: net.WsBrowserTransport = undefined;
var g_ws_transport_valid: bool = false;

/// Long-lived thread that owns all connect/reconnect logic.
/// Runs for the lifetime of the process.  Never touches g_state.phase directly
/// from a racing context; instead it drives open/close in strict sequence.
fn connect_loop(_: void) void {
    while (true) {
        // Attempt TCP connect + WS handshake.
        const result = net.WsBrowserTransport.connect(g_server_url);
        if (result) |t| {
            // Install fresh transport at stable address.
            g_ws_transport = t;
            g_ws_transport_valid = true;
            g_state.transport = g_ws_transport.transport();
            g_need_reconnect.store(false, .monotonic);

            // notify_open fires on_ws_open → send_join, spawns read thread.
            g_ws_transport.notify_open();

            // Block until the read thread exits (connection dropped or closed).
            // notify_open spawned the thread; close() joins it.
            // We spin-wait on g_need_reconnect which on_ws_close sets just
            // before the read thread exits.
            while (!g_need_reconnect.load(.acquire)) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }

            // Join the read thread and clean up.
            g_ws_transport.close();
            g_ws_transport_valid = false;
            g_state.transport = null;
            g_state.phase = .connecting;
        } else |_| {
            // Connection failed — wait before retrying.
            std.Thread.sleep(std.time.ns_per_s);
        }
    }
}

/// Player display name (set before connect).
var g_name_buf: [16]u8 = [_]u8{0} ** 16;
var g_name_len: u8 = 0;

// ---------------------------------------------------------------------------
// WebSocket callbacks
// ---------------------------------------------------------------------------

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
    // Signal connect_loop to wake up and reconnect.  Do not touch phase or
    // transport here — connect_loop owns those after the read thread exits.
    g_need_reconnect.store(true, .release);
}

// ---------------------------------------------------------------------------
// Message senders
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Message processing
// ---------------------------------------------------------------------------

fn process_recv() void {
    // Drain all queued messages each frame.
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
                // Check if the entity belongs to us
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
                // Currently just consumed; future: show damage numbers
                _ = proto.decode_action_result(r) catch continue;
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Game update (lobby input, game input)
// ---------------------------------------------------------------------------

fn update_lobby() void {
    // Class picker: 1/2/3
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
    // Ready up
    if (rl.isKeyPressed(.enter)) {
        g_state.lobby.ready = !g_state.lobby.ready;
        send_ready_up();
    }
}

/// Returns true if the local player's entity has `class` in the current snapshot.
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
            // Healers target allies; everyone else targets enemies.
            gs.targeting_enemy = !is_our_class(gs, .healer);
        },
        .select_defend => {
            gs.action_selected = .defend;
        },
        .confirm => {
            if (gs.action_selected) |action| {
                // Find target entity at cursor position
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
// WASM memory helpers (called by ws_glue.js)
// ---------------------------------------------------------------------------

/// Called by JS (index.html) to persist player_id across page reloads.
/// The WASM host reads it back from sessionStorage on reconnect.
export fn save_player_id(pid: u8) void {
    g_state.our_player_id = pid;
}

export fn wasm_alloc(len: usize) ?[*]u8 {
    const mem = std.heap.page_allocator.alloc(u8, len) catch return null;
    return mem.ptr;
}

export fn wasm_free(ptr: [*]u8, len: usize) void {
    std.heap.page_allocator.free(ptr[0..len]);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    // Default player name; in a real build the UI would prompt for it.
    const default_name = "Player";
    g_name_len = @intCast(default_name.len);
    @memcpy(g_name_buf[0..g_name_len], default_name);

    // Wire up WS callbacks
    net.set_callbacks(.{
        .on_open = on_ws_open,
        .on_message = on_ws_message,
        .on_close = on_ws_close,
    });

    // Spawn the persistent connect loop — it handles all reconnect logic.
    const loop_thread = try std.Thread.spawn(.{}, connect_loop, .{{}});
    loop_thread.detach();

    rl.initWindow(@intFromFloat(render.SW), @intFromFloat(render.SH), "JRPG Client");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        // Process any pending incoming messages
        process_recv();

        // Update
        switch (g_state.phase) {
            .connecting => {},
            .lobby => update_lobby(),
            .game => update_game(),
            .game_over => {
                if (rl.isKeyPressed(.enter)) g_state.phase = .lobby;
            },
        }

        // Draw
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
