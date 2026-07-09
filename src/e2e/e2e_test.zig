//! End-to-end test: spawn a real server, connect two bot clients over
//! WebSocket, play through the default Slime Feast encounter, assert the
//! game ends with a positive shared score.
//!
//! Run with:  zig build e2e
//!
//! The test binary and server are both installed into zig-out/bin/.
//! We locate server relative to our own executable path.

const std = @import("std");
const ws = @import("websocket");
const shared = @import("shared");
const proto = shared.protocol;
const c = shared.components;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const PORT: u16 = 19001;
const SERVER_STARTUP_TIMEOUT_MS: u64 = 3000;
const BOT_TIMEOUT_MS: u32 = 30_000;
/// Fast rounds so the encounter completes quickly.
const ROUND_DURATION_S = "0.3";

// ---------------------------------------------------------------------------
// Bot result (written by bot thread, read by main after join)
// ---------------------------------------------------------------------------

const BotResult = struct {
    err: ?anyerror = null,
    got_game_over: bool = false,
    score: u32 = 0,
    hunger_events: u32 = 0,
};

// ---------------------------------------------------------------------------
// Bot context (passed to each thread)
// ---------------------------------------------------------------------------

const BotCtx = struct {
    name: []const u8,
    result: BotResult = .{},
};

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ---- Locate server binary -----------------------------------------------
    const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_dir);
    const server_path = try std.fs.path.join(allocator, &.{ exe_dir, "server" });
    defer allocator.free(server_path);

    std.debug.print("[e2e] server binary: {s}\n", .{server_path});

    // ---- Kill any stale server on the test port ----------------------------
    if (std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "pkill", "-f", "server" },
    })) |res| {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    } else |_| {}
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // ---- Spawn server -------------------------------------------------------
    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{PORT});
    defer allocator.free(port_str);

    var server_child = std.process.Child.init(
        &.{ server_path, port_str, "--round-duration", ROUND_DURATION_S },
        allocator,
    );
    server_child.stdout_behavior = .Ignore;
    server_child.stderr_behavior = .Ignore;
    try server_child.spawn();
    defer {
        _ = server_child.kill() catch {};
        _ = server_child.wait() catch {};
    }

    std.debug.print("[e2e] server spawned (pid {})\n", .{server_child.id});

    // ---- Wait for server to accept connections ------------------------------
    try wait_for_port(allocator, PORT, SERVER_STARTUP_TIMEOUT_MS);
    std.debug.print("[e2e] server ready on port {d}\n", .{PORT});

    // ---- Run two bot threads ------------------------------------------------
    var ctx_a = BotCtx{ .name = "BotA" };
    var ctx_b = BotCtx{ .name = "BotB" };

    const thread_a = try std.Thread.spawn(.{}, run_bot, .{&ctx_a});
    const thread_b = try std.Thread.spawn(.{}, run_bot, .{&ctx_b});
    thread_a.join();
    thread_b.join();

    // ---- Check results -------------------------------------------------------
    var failed = false;

    for ([_]*BotCtx{ &ctx_a, &ctx_b }) |ctx| {
        if (ctx.result.err) |e| {
            std.debug.print("[e2e] FAIL {s}: error {s}\n", .{ ctx.name, @errorName(e) });
            failed = true;
            continue;
        }
        if (!ctx.result.got_game_over) {
            std.debug.print("[e2e] FAIL {s}: no game_over received\n", .{ctx.name});
            failed = true;
            continue;
        }
        if (ctx.result.score == 0) {
            std.debug.print("[e2e] FAIL {s}: final score is 0, want > 0\n", .{ctx.name});
            failed = true;
            continue;
        }
        if (ctx.result.hunger_events == 0) {
            std.debug.print("[e2e] FAIL {s}: no hunger action_results seen\n", .{ctx.name});
            failed = true;
            continue;
        }
        std.debug.print("[e2e] OK   {s}: score={}, {} hunger events\n", .{
            ctx.name, ctx.result.score, ctx.result.hunger_events,
        });
    }

    if (failed) {
        std.debug.print("[e2e] FAIL\n", .{});
        std.process.exit(1);
    }
    std.debug.print("[e2e] PASS\n", .{});
}

// ---------------------------------------------------------------------------
// Bot thread
// ---------------------------------------------------------------------------

fn run_bot(ctx: *BotCtx) void {
    run_bot_inner(ctx) catch |e| {
        ctx.result.err = e;
        std.debug.print("[e2e] {s} error: {s}\n", .{ ctx.name, @errorName(e) });
    };
}

fn run_bot_inner(ctx: *BotCtx) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ---- Connect ------------------------------------------------------------
    var client = try ws.Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = PORT,
    });
    defer client.deinit();

    try client.handshake("/", .{ .timeout_ms = 5000 });
    std.debug.print("[e2e] {s} connected\n", .{ctx.name});

    // Set a per-read timeout so we don't hang forever.
    try client.readTimeout(BOT_TIMEOUT_MS);

    // ---- Message loop -------------------------------------------------------
    var sent_join: bool = false;
    var sent_ready: bool = false;
    var in_game: bool = false;
    var last_zone: u8 = 0xFF;

    while (true) {
        const msg = try client.read() orelse continue;
        defer client.done(msg);

        if (msg.data.len == 0) continue;

        const tag_byte = msg.data[0];
        const tag = std.meta.intToEnum(proto.MsgTag, tag_byte) catch continue;
        const payload = msg.data[1..];

        switch (tag) {
            .lobby_update => {
                var fbs = std.io.fixedBufferStream(payload);
                const lu = proto.decode_lobby_update(fbs.reader()) catch continue;

                if (in_game) break; // shouldn't happen, but be safe

                // Send join_lobby exactly once.
                if (!sent_join) {
                    try send_join_lobby(&client, ctx.name);
                    sent_join = true;
                }

                // Send ready_up exactly once, after both players are present.
                if (!sent_ready and lu.player_count >= 2) {
                    std.debug.print("[e2e] {s} sees {} players, sending ready_up\n", .{
                        ctx.name, lu.player_count,
                    });
                    try send_ready_up(&client);
                    sent_ready = true;
                }
            },

            .game_start => {
                in_game = true;
                std.debug.print("[e2e] {s} game_start\n", .{ctx.name});
            },

            .game_state => {
                var fbs = std.io.fixedBufferStream(payload);
                const gs = proto.decode_game_state(fbs.reader()) catch continue;
                // Once per zone: both bots cast the twin_flames half so the
                // team recipe fires and fire slime gets neutralized.
                if (in_game and gs.zone_index != last_zone and gs.zone_index < gs.zone_count) {
                    last_zone = gs.zone_index;
                    std.debug.print("[e2e] {s} dispensing for zone {}\n", .{ ctx.name, gs.zone_index });
                    try send_combo(&client, c.make_combo(&.{
                        .{ .element = .fire },
                        .{ .action = .dispense },
                        .{ .action = .dispense },
                    }));
                }
            },

            .action_result => {
                var fbs = std.io.fixedBufferStream(payload);
                const ar = proto.decode_action_result(fbs.reader()) catch continue;
                if (ar.tag == .damage) {
                    ctx.result.hunger_events += 1;
                }
            },

            .game_over => {
                var fbs = std.io.fixedBufferStream(payload);
                const go = proto.decode_game_over(fbs.reader()) catch continue;
                ctx.result.got_game_over = true;
                ctx.result.score = go.score;
                std.debug.print("[e2e] {s} game_over: score={}\n", .{ ctx.name, go.score });
                break;
            },

            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Send helpers  (each allocates a local stack buf, passes mutable slice)
// ---------------------------------------------------------------------------

fn send_join_lobby(client: *ws.Client, name: []const u8) !void {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const name_len: u8 = @intCast(@min(name.len, 16));
    var p = proto.JoinLobby{ .name = [_]u8{0} ** 16, .name_len = name_len };
    @memcpy(p.name[0..name_len], name[0..name_len]);
    try proto.encode(fbs.writer(), .join_lobby, p);
    try client.writeBin(fbs.getWritten());
}

fn send_ready_up(client: *ws.Client) !void {
    var buf: [2]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), .ready_up, {});
    try client.writeBin(fbs.getWritten());
}

fn send_combo(client: *ws.Client, combo: c.ActionCombo) !void {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), .choose_combo, proto.ChooseCombo{ .combo = combo });
    try client.writeBin(fbs.getWritten());
}

// ---------------------------------------------------------------------------
// Port-ready polling
// ---------------------------------------------------------------------------

fn wait_for_port(allocator: std.mem.Allocator, port: u16, timeout_ms: u64) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        const stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        stream.close();
        return;
    }
    return error.ServerDidNotStart;
}
