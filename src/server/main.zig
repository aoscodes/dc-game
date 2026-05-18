//! game server entry point.
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
const logic = shared.game_logic;
const dbg = @import("debug_zig");

const session_mod = @import("session.zig");
const Session = session_mod.Session;
const ws_server = @import("net/ws_server.zig");

const TICK_HZ: u64 = 20;
const TICK_NS: u64 = std.time.ns_per_s / TICK_HZ;
const DEFAULT_PORT: u16 = 9001;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var ta: dbg.TrackingAllocator = undefined;
var session: ?Session = null;
var session_lock: std.Thread.Mutex = .{};

const Handler = struct {
    conn: *ws.Conn,
    player_id: u8 = 0xFF,

    pub fn init(hs: *ws.Handshake, conn: *ws.Conn, _: void) !Handler {
        _ = hs;
        return Handler{ .conn = conn };
    }

    pub fn afterInit(self: *Handler) !void {
        session_lock.lock();
        defer session_lock.unlock();

        const sess = &(session orelse return error.NoSession);
        const t = ws_server.conn_transport(self.conn);

        if (sess.join(t, "")) |pid| {
            self.player_id = pid;
            std.log.info("player {} connected (slot reserved)", .{pid});
            sess.broadcast_lobby_update() catch {};
        } else {
            std.log.warn("session full, rejecting connection", .{});
            self.conn.close(.{}) catch {};
        }
    }

    pub fn clientMessage(self: *Handler, data: []u8) !void {
        if (data.len == 0) return;

        var fbs_peek = std.io.fixedBufferStream(data);
        const tag = proto.read_tag(fbs_peek.reader()) catch return;

        if (tag == .reconnect) {
            const p = proto.decode_reconnect(fbs_peek.reader()) catch return;
            session_lock.lock();
            defer session_lock.unlock();
            const sess = &(session orelse return);
            const t = ws_server.conn_transport(self.conn);
            if (sess.reconnect(p.player_id, t)) {
                if (self.player_id != p.player_id) {
                    sess.disconnect(self.player_id);
                }
                self.player_id = p.player_id;
                std.log.info("player {} reconnected", .{p.player_id});
                sess.broadcast_lobby_update() catch {};
            }
            return;
        }

        session_lock.lock();
        const sess_ptr = if (session) |*s| s else {
            session_lock.unlock();
            return;
        };
        sess_ptr.enqueue_message(self.player_id, data);
        session_lock.unlock();
    }

    pub fn close(self: *Handler) void {
        session_lock.lock();
        defer session_lock.unlock();
        const sess = &(session orelse return);
        const joined = self.player_id < session_mod.MAX_PLAYERS and
            sess.players[self.player_id].name_len > 0;
        sess.disconnect(self.player_id);
        std.log.info("player {} disconnected", .{self.player_id});
        if (joined) sess.broadcast_lobby_update() catch {};
    }
};

fn tick_loop(_: void) void {
    var timer = std.time.Timer.start() catch |err| {
        std.log.err("tick_loop: failed to start timer: {}", .{err});
        return;
    };
    while (true) {
        const start = timer.read();

        {
            session_lock.lock();
            if (session) |*sess| {
                const dt: f32 = @as(f32, @floatFromInt(TICK_NS)) / @as(f32, @floatFromInt(std.time.ns_per_s));
                sess.tick(dt) catch |err| {
                    std.log.err("tick error: {}", .{err});
                };
            }
            session_lock.unlock();
        }

        const elapsed = timer.read() - start;
        if (elapsed < TICK_NS) {
            std.Thread.sleep(TICK_NS - elapsed);
        }
    }
}

pub fn main() !void {
    defer _ = gpa.deinit();
    ta = dbg.TrackingAllocator.init(gpa.allocator());
    const allocator = ta.allocator();
    defer ta.report_stderr("server");

    var port: u16 = DEFAULT_PORT;
    var round_duration: f32 = logic.ROUND_DURATION_DEFAULT_S;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip argv[0]
    if (args.next()) |arg| {
        port = std.fmt.parseInt(u16, arg, 10) catch DEFAULT_PORT;
    }
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--round-duration")) {
            if (args.next()) |val| {
                round_duration = std.fmt.parseFloat(f32, val) catch blk: {
                    std.log.warn("invalid --round-duration value '{s}', using default {d:.1}s", .{ val, logic.ROUND_DURATION_DEFAULT_S });
                    break :blk logic.ROUND_DURATION_DEFAULT_S;
                };
            }
        }
    }

    var join_code: [6]u8 = undefined;
    const charset = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    for (&join_code) |*ch| {
        ch.* = charset[rng.random().int(u8) % charset.len];
    }

    session = try Session.init(allocator, join_code);
    defer if (session) |*s| s.deinit();
    session.?.round_duration = round_duration;
    session.?.round_timer = round_duration;

    std.log.info("Room code: {s}", .{join_code});
    std.log.info("Listening on port {d}", .{port});

    const tick_thread = try std.Thread.spawn(.{}, tick_loop, .{{}});
    tick_thread.detach();

    var server = try ws.Server(Handler).init(allocator, .{
        .port = port,
        .address = "0.0.0.0",
    });
    try server.listen({});
}
