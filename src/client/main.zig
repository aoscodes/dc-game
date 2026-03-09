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
    /// Scratch buffer for incoming messages (populated by ws read thread).
    /// Access pattern: read thread writes buf+len then sets recv_ready;
    /// main thread checks recv_ready then reads buf+len.
    /// Must be atomic to guarantee the write is visible across threads.
    recv_buf: [4096]u8 = undefined,
    recv_len: usize = 0,
    recv_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Global client state — one instance per WASM module / process.
var g_state: ClientState = .{};

/// Player display name (set before connect).
var g_name_buf: [16]u8 = [_]u8{0} ** 16;
var g_name_len: u8 = 0;

// ---------------------------------------------------------------------------
// WebSocket callbacks
// ---------------------------------------------------------------------------

fn on_ws_open(_: i32) void {
    std.log.info("ws open", .{});
}

fn on_ws_message(_: i32, data: []const u8) void {
    std.log.info("ws message: {} bytes, tag=0x{x}", .{ data.len, if (data.len > 0) data[0] else 0 });
    // Copy into recv buffer and mark ready for main-loop processing.
    // We process one message per frame (sufficient at 20 Hz server tick).
    if (data.len <= g_state.recv_buf.len) {
        @memcpy(g_state.recv_buf[0..data.len], data);
        g_state.recv_len = data.len;
        // Release store: buf+len writes must be visible before the flag.
        g_state.recv_ready.store(true, .release);
    } else {
        std.log.warn("ws message too large ({} bytes), dropping", .{data.len});
    }
}

fn on_ws_close(_: i32) void {
    std.log.warn("ws closed", .{});
    g_state.transport = null;
    // Show reconnecting message
    const msg = "Connection lost. Reconnecting...";
    const len: u8 = @intCast(@min(msg.len, 63));
    @memcpy(g_state.lobby.error_msg[0..len], msg[0..len]);
    g_state.lobby.error_msg_len = len;
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
    // Acquire load: pairs with the release store in on_ws_message.
    if (!g_state.recv_ready.load(.acquire)) return;
    g_state.recv_ready.store(false, .monotonic);

    const data = g_state.recv_buf[0..g_state.recv_len];
    var fbs = std.io.fixedBufferStream(data);
    const r = fbs.reader();

    const tag = proto.read_tag(r) catch |err| {
        std.log.err("process_recv: bad tag: {}", .{err});
        return;
    };
    std.log.info("process_recv: tag={s}", .{@tagName(tag)});
    switch (tag) {
        .lobby_update => {
            const p = proto.decode_lobby_update(r) catch |err| {
                std.log.err("decode lobby_update failed: {}", .{err});
                return;
            };
            // First lobby_update is the server's ready signal.
            // If we haven't joined yet, send join_lobby now.
            if (g_state.our_player_id == 0xFF) {
                send_join();
            }
            if (p.your_player_id != 0xFF) {
                g_state.our_player_id = p.your_player_id;
            }
            g_state.lobby.update = p;
            g_state.lobby.our_player_id = g_state.our_player_id;
            g_state.phase = .lobby;
        },
        .game_start => {
            const p = proto.decode_game_start(r) catch return;
            g_state.our_player_id = p.your_player_id;
            g_state.game = .{};
            g_state.game.our_player_id = p.your_player_id;
            g_state.game.wave_label_len = p.wave_label_len;
            @memcpy(g_state.game.wave_label[0..p.wave_label_len], p.wave_label[0..p.wave_label_len]);
            g_state.phase = .game;
        },
        .game_state => {
            const p = proto.decode_game_state(r) catch return;
            g_state.game.snapshot = p;
        },
        .your_turn => {
            const p = proto.decode_your_turn(r) catch return;
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
            _ = proto.decode_game_over(r) catch return;
            g_state.phase = .game_over;
        },
        .action_result => {
            // Currently just consumed; future: show damage numbers
            _ = proto.decode_action_result(r) catch return;
        },
        else => {},
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

    // Server URL: env var WS_URL or default localhost.
    const server_url = "ws://127.0.0.1:9001";

    // Wire up WS callbacks
    net.set_callbacks(.{
        .on_open = on_ws_open,
        .on_message = on_ws_message,
        .on_close = on_ws_close,
    });

    // Connect — assign transport BEFORE firing on_open so send_join() works.
    var ws_transport = try net.WsBrowserTransport.connect(server_url);
    g_state.transport = ws_transport.transport();
    ws_transport.notify_open();

    rl.initWindow(@intFromFloat(render.SW), @intFromFloat(render.SH), "JRPG Client");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        // Process any pending incoming message
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

    ws_transport.close();
}
