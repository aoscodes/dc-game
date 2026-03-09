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

    /// Scratch buffer for outgoing messages.
    send_buf: [512]u8 = undefined,
    /// Scratch buffer for incoming messages (populated by ws callback).
    recv_buf: [4096]u8 = undefined,
    recv_len: usize = 0,
    recv_ready: bool = false,
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
    // Send JoinLobby or Reconnect
    send_join();
}

fn on_ws_message(_: i32, data: []const u8) void {
    // Copy into recv buffer and mark ready for main-loop processing.
    // We process one message per frame (sufficient at 20 Hz server tick).
    if (data.len <= g_state.recv_buf.len) {
        @memcpy(g_state.recv_buf[0..data.len], data);
        g_state.recv_len = data.len;
        g_state.recv_ready = true;
    }
}

fn on_ws_close(_: i32) void {
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
    const t = g_state.transport orelse return;
    var fbs = std.io.fixedBufferStream(&g_state.send_buf);
    const w = fbs.writer();

    // TODO: check sessionStorage for saved player_id (WASM) and send
    // Reconnect instead when applicable.  For now always send JoinLobby.
    var p = proto.JoinLobby{
        .name = [_]u8{0} ** 16,
        .name_len = g_name_len,
    };
    @memcpy(p.name[0..g_name_len], g_name_buf[0..g_name_len]);
    proto.encode(w, .join_lobby, p) catch return;
    t.send(fbs.getWritten()) catch return;
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
    if (!g_state.recv_ready) return;
    g_state.recv_ready = false;

    const data = g_state.recv_buf[0..g_state.recv_len];
    var fbs = std.io.fixedBufferStream(data);
    const r = fbs.reader();

    const tag = proto.read_tag(r) catch return;
    switch (tag) {
        .lobby_update => {
            const p = proto.decode_lobby_update(r) catch return;
            g_state.lobby.update = p;
            g_state.phase = .lobby;
        },
        .game_start => {
            const p = proto.decode_game_start(r) catch return;
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
            gs.targeting_enemy = true;
        },
        .select_defend => {
            gs.action_selected = .defend;
        },
        .confirm => {
            if (gs.action_selected) |action| {
                // Find target entity at cursor position
                var target: u32 = 0;
                if (action == .attack or (!gs.targeting_enemy)) {
                    const target_team: c.TeamId = if (action == .attack or gs.targeting_enemy)
                        .enemies
                    else
                        .players;
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

    // Connect
    var ws_transport = try net.WsBrowserTransport.connect(server_url);
    g_state.transport = ws_transport.transport();

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
