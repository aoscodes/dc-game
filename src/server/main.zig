//! game server entry point.
//!
//! Listens on a configurable port (default 9001).  Each incoming WebSocket
//! connection is handled by the websocket.zig server with our `Handler` type.
//!
//! A single global `Session` is kept for simplicity (one room at a time).
//! The game loop runs on a dedicated tick thread paced at --tick-ms
//! (default 50ms), passing measured wall-clock dt to the session.

const std = @import("std");
const ws = @import("websocket");
const shared = @import("shared");
const cfg_mod = shared.config;
const dbg = @import("debug_zig");

const session_mod = @import("session.zig");
const Session = session_mod.Session;
const ws_server = @import("net/ws_server.zig");

/// Default tick period in milliseconds; override with --tick-ms.
const DEFAULT_TICK_MS: u32 = 50;
/// Upper bound on a single tick's dt: a stalled thread (debugger, laptop
/// sleep) must not simulate a huge time jump in one step.
const MAX_DT_S: f32 = 0.25;
const DEFAULT_PORT: u16 = 9001;
/// Default directory holding balance.json / encounters.json (relative to
/// cwd); override with --data-dir.
const DEFAULT_DATA_DIR = "data";

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var ta: dbg.TrackingAllocator = undefined;
/// Loaded once at startup; referenced by the session for its lifetime.
var g_loaded: cfg_mod.Loaded = undefined;
var session: ?Session = null;
var session_lock: std.Thread.Mutex = .{};

/// Sentinel for a handler that never registered with the session (the
/// connection registry was full).
const NO_CONN: usize = std.math.maxInt(usize);

const Handler = struct {
    conn: *ws.Conn,
    conn_id: usize = NO_CONN,

    pub fn init(hs: *ws.Handshake, conn: *ws.Conn, _: void) !Handler {
        _ = hs;
        return Handler{ .conn = conn };
    }

    pub fn afterInit(self: *Handler) !void {
        session_lock.lock();
        defer session_lock.unlock();

        const sess = &(session orelse return error.NoSession);
        const t = ws_server.conn_transport(self.conn);

        // Every connection starts as an OBSERVER of the running game; the
        // session answers with a game_start (player_id = NO_PLAYER).  A seat
        // is only taken by an explicit take_slot.
        if (sess.connect(t)) |conn_id| {
            self.conn_id = conn_id;
            std.log.info("connection {} attached (observer)", .{conn_id});
        } else {
            std.log.warn("connection registry full, rejecting connection", .{});
            self.conn.close(.{}) catch {};
        }
    }

    pub fn clientMessage(self: *Handler, data: []u8) !void {
        if (data.len == 0 or self.conn_id == NO_CONN) return;
        session_lock.lock();
        const sess_ptr = if (session) |*s| s else {
            session_lock.unlock();
            return;
        };
        sess_ptr.enqueue_message(self.conn_id, data);
        session_lock.unlock();
    }

    pub fn close(self: *Handler) void {
        if (self.conn_id == NO_CONN) return;
        session_lock.lock();
        defer session_lock.unlock();
        const sess = &(session orelse return);
        // Releases the connection's seat (if any): shares go back to the
        // group and play continues — the remaining players learn of the
        // shrunken bar/pool from the ordinary game_state tick.
        sess.disconnect(self.conn_id);
        std.log.info("connection {} closed", .{self.conn_id});
    }
};

fn tick_loop(tick_ns: u64) void {
    var timer = std.time.Timer.start() catch |err| {
        std.log.err("tick_loop: failed to start timer: {}", .{err});
        return;
    };
    // Measures REAL elapsed time between iterations so the simulation stays
    // wall-clock accurate regardless of tick pacing jitter.
    var dt_timer = std.time.Timer.start() catch |err| {
        std.log.err("tick_loop: failed to start dt timer: {}", .{err});
        return;
    };
    while (true) {
        const start = timer.read();

        {
            session_lock.lock();
            if (session) |*sess| {
                const dt_raw: f32 = @as(f32, @floatFromInt(dt_timer.lap())) /
                    @as(f32, @floatFromInt(std.time.ns_per_s));
                const dt = @min(dt_raw, MAX_DT_S);
                sess.tick(dt) catch |err| {
                    std.log.err("tick error: {}", .{err});
                };
            }
            session_lock.unlock();
        }

        const elapsed = timer.read() - start;
        if (elapsed < tick_ns) {
            std.Thread.sleep(tick_ns - elapsed);
        }
    }
}

pub fn main() !void {
    defer _ = gpa.deinit();
    ta = dbg.TrackingAllocator.init(gpa.allocator());
    const allocator = ta.allocator();
    defer ta.report_stderr("server");

    var port: u16 = DEFAULT_PORT;
    var join_code_override: ?[6]u8 = null;
    var data_dir: []const u8 = DEFAULT_DATA_DIR;
    var validate_only = false;
    var tick_ms: u32 = DEFAULT_TICK_MS;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip argv[0]
    if (args.next()) |arg| {
        port = std.fmt.parseInt(u16, arg, 10) catch DEFAULT_PORT;
    }
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--join-code")) {
            if (args.next()) |val| {
                if (val.len == 6) {
                    var code: [6]u8 = undefined;
                    @memcpy(&code, val[0..6]);
                    join_code_override = code;
                } else {
                    std.log.warn("--join-code must be exactly 6 characters, ignoring '{s}'", .{val});
                }
            }
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            if (args.next()) |val| data_dir = val;
        } else if (std.mem.eql(u8, arg, "--tick-ms")) {
            if (args.next()) |val| {
                tick_ms = std.fmt.parseInt(u32, val, 10) catch blk: {
                    std.log.warn("invalid --tick-ms value '{s}', using default {d}", .{ val, DEFAULT_TICK_MS });
                    break :blk DEFAULT_TICK_MS;
                };
                if (tick_ms == 0) {
                    std.log.warn("--tick-ms must be >= 1, using default {d}", .{DEFAULT_TICK_MS});
                    tick_ms = DEFAULT_TICK_MS;
                }
            }
        } else if (std.mem.eql(u8, arg, "--validate")) {
            // Load + validate the data files, then exit — used by the bridge's
            // /api/tune/save endpoint to vet designer configs with the exact
            // same loader the game uses.
            validate_only = true;
        }
    }

    // Load all balance/encounter data from the data files.  Every new lobby
    // gets a fresh server process (see bridge/index.js), so editing the JSON
    // takes effect on the next lobby without a rebuild.
    g_loaded = cfg_mod.load(allocator, data_dir) catch {
        std.log.err("failed to load game data from '{s}' — fix the data files and restart", .{data_dir});
        std.process.exit(1);
    };
    defer g_loaded.deinit();

    if (validate_only) {
        std.log.info("game data in '{s}' is valid", .{data_dir});
        return;
    }

    var join_code: [6]u8 = undefined;
    if (join_code_override) |override| {
        join_code = override;
    } else {
        const charset = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        for (&join_code) |*ch| {
            ch.* = charset[rng.random().int(u8) % charset.len];
        }
    }

    session = try Session.init(allocator, join_code, &g_loaded.config);
    defer if (session) |*s| s.deinit();

    // A game is ALWAYS live: launch the default encounter immediately, already
    // playing.  There is no screen in front of it — a tab that connects is in
    // the game.  Nothing is lost by starting empty: `tick` disarms the bite
    // timer while no seat is taken, so the encounter idles on a still board
    // until the first player arrives, and the timer then arms from THAT moment.
    if (session) |*s| {
        try s.start_game(g_loaded.config.encounters.default().label);
    }

    std.log.info("Room code: {s}", .{join_code});
    std.log.info("Listening on port {d}", .{port});

    const tick_ns: u64 = @as(u64, tick_ms) * std.time.ns_per_ms;
    const tick_thread = try std.Thread.spawn(.{}, tick_loop, .{tick_ns});
    tick_thread.detach();

    var server = try ws.Server(Handler).init(allocator, .{
        .port = port,
        .address = "0.0.0.0",
    });
    try server.listen({});
}
