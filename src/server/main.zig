//! JRPG game server entry point.
//!
//! Listens on a configurable port (default 9001).  Each incoming WebSocket
//! connection is handled by the websocket.zig server with our `Handler` type.
//!
//! A single global `Session` is kept for simplicity (one room at a time).
//! The game loop runs on a dedicated tick thread at TICK_HZ.

const std = @import("std");
const ws = @import("websocket");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;

const session_mod = @import("session.zig");
const Session = session_mod.Session;
const ws_server = @import("net/ws_server.zig");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const TICK_HZ: u64 = 20;
const TICK_NS: u64 = std.time.ns_per_s / TICK_HZ;
const DEFAULT_PORT: u16 = 9001;

// ---------------------------------------------------------------------------
// Global session (single room)
// ---------------------------------------------------------------------------

var g_gpa = std.heap.GeneralPurposeAllocator(.{}){};
var g_session: ?Session = null;
var g_session_lock: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// WebSocket handler
// ---------------------------------------------------------------------------

const App = struct {
    allocator: std.mem.Allocator,
};

const Handler = struct {
    conn: *ws.Conn,
    player_id: u8 = 0xFF,
    app: *App,

    pub fn init(hs: *ws.Handshake, conn: *ws.Conn, app: *App) !Handler {
        _ = hs;
        return Handler{ .conn = conn, .app = app };
    }

    pub fn afterInit(self: *Handler) !void {
        // Register with the session
        g_session_lock.lock();
        defer g_session_lock.unlock();

        const sess = &(g_session orelse return error.NoSession);
        const t = ws_server.conn_transport(self.conn);

        // Check if this is a reconnect attempt — we'll handle after receiving
        // the first message.  For now, assign a new slot.
        if (sess.join(t, "connecting...")) |pid| {
            self.player_id = pid;
            std.log.info("player {} connected", .{pid});
            sess.broadcast_lobby_update() catch {};
        } else {
            std.log.warn("session full, rejecting connection", .{});
            self.conn.close(.{}) catch {};
        }
    }

    pub fn clientMessage(self: *Handler, data: []u8) !void {
        if (data.len == 0) return;

        // Special case: handle reconnect before handing off to session queue.
        var fbs_peek = std.io.fixedBufferStream(data);
        const tag = proto.read_tag(fbs_peek.reader()) catch return;

        if (tag == .reconnect) {
            const p = proto.decode_reconnect(fbs_peek.reader()) catch return;
            g_session_lock.lock();
            defer g_session_lock.unlock();
            const sess = &(g_session orelse return);
            const t = ws_server.conn_transport(self.conn);
            if (sess.reconnect(p.player_id, t)) {
                // Release the slot we grabbed in afterInit
                if (self.player_id != p.player_id) {
                    sess.disconnect(self.player_id);
                }
                self.player_id = p.player_id;
                std.log.info("player {} reconnected", .{p.player_id});
                // Send current state
                sess.broadcast_lobby_update() catch {};
            }
            return;
        }

        // All other messages go to the session's per-player queue.
        g_session_lock.lock();
        const sess_ptr = if (g_session) |*s| s else {
            g_session_lock.unlock();
            return;
        };
        sess_ptr.enqueue_message(self.player_id, data);
        g_session_lock.unlock();
    }

    pub fn close(self: *Handler) void {
        g_session_lock.lock();
        defer g_session_lock.unlock();
        const sess = &(g_session orelse return);
        sess.disconnect(self.player_id);
        std.log.info("player {} disconnected", .{self.player_id});
        sess.broadcast_lobby_update() catch {};
    }
};

// ---------------------------------------------------------------------------
// Tick thread
// ---------------------------------------------------------------------------

fn tick_loop(_: void) void {
    var timer = std.time.Timer.start() catch unreachable;
    while (true) {
        const start = timer.read();

        {
            g_session_lock.lock();
            if (g_session) |*sess| {
                const dt: f32 = @as(f32, @floatFromInt(TICK_NS)) / @as(f32, @floatFromInt(std.time.ns_per_s));
                sess.tick(dt) catch |err| {
                    std.log.err("tick error: {}", .{err});
                };
                sess.tick_effects(dt);
                sess.run_ai() catch |err| {
                    std.log.err("AI error: {}", .{err});
                };
            }
            g_session_lock.unlock();
        }

        const elapsed = timer.read() - start;
        if (elapsed < TICK_NS) {
            std.Thread.sleep(TICK_NS - elapsed);
        }
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    const allocator = g_gpa.allocator();
    defer _ = g_gpa.deinit();

    // Parse port from args
    var port: u16 = DEFAULT_PORT;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip argv[0]
    if (args.next()) |arg| {
        port = std.fmt.parseInt(u16, arg, 10) catch DEFAULT_PORT;
    }

    // Generate a join code
    var join_code: [6]u8 = undefined;
    const charset = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    for (&join_code) |*ch| {
        ch.* = charset[rng.random().int(u8) % charset.len];
    }

    // Create session
    g_session = try Session.init(allocator, join_code);
    defer if (g_session) |*s| s.deinit();

    std.log.info("Room code: {s}", .{join_code});
    std.log.info("Listening on port {d}", .{port});

    // Spawn tick thread
    const tick_thread = try std.Thread.spawn(.{}, tick_loop, .{{}});
    tick_thread.detach();

    // Start WebSocket server (blocks)
    var app = App{ .allocator = allocator };
    var server = try ws.Server(Handler).init(allocator, .{
        .port = port,
        .address = "0.0.0.0",
    });
    try server.listen(&app);
}
