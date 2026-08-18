//! End-to-end test: spawn a real server, connect two bot clients over
//! WebSocket, play through the default Slime Feast encounter, assert the
//! game ends with a positive shared score.
//!
//! This exercises the whole real-time stack: the server-authoritative slime
//! grid and aim cursors, the reservoir refill, one Lil Guy per player biting on
//! its own timer, shape stamping at each caster's captured anchor, and
//! team-recipe grouping across two independent WebSocket clients.
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
/// game_state frames to skip between submits, so each cast lands after the
/// previous one's lock has expired.
const CAST_INTERVAL_TICKS: u32 = 30;
/// Cursor steps sent per cast cycle.  Walking before every cast sweeps the
/// stamp across the field instead of grinding the same cells, and proves the
/// server's cursor is authoritative and clamped (the bots deliberately walk
/// past the edge).
const AIM_STEPS_PER_CAST: u8 = 3;

// ---------------------------------------------------------------------------
// Bot result (written by bot thread, read by main after join)
// ---------------------------------------------------------------------------

const BotResult = struct {
    err: ?anyerror = null,
    got_game_over: bool = false,
    score: u32 = 0,
    hunger_events: u32 = 0,
    /// Grid dimensions announced in game_start — proves the client is told how
    /// to lay the field out.
    grid_cells: u16 = 0,
    /// Lil Guys seen in the last game_state: one per connected player.
    lil_guys: u8 = 0,
    stats_neutralized: u32 = 0,
    casts_total: u16 = 0,
    /// Hazard cells the team's stamps downgraded, summed over all tiers.
    stats_covered: u32 = 0,
    /// Highest cursor column this bot's own entity was ever seen at, proving
    /// the server moved the cursor in response to move_cursor.
    max_cursor_col: u8 = 0,
    /// shape_cast broadcasts seen — the wire proof that stamps landed.
    shape_casts: u32 = 0,
};

// ---------------------------------------------------------------------------
// Bot context (passed to each thread)
// ---------------------------------------------------------------------------

const BotCtx = struct {
    name: []const u8,
    /// Which direction this bot sweeps.  The two bots aim differently so the
    /// team stamp lands somewhere neither would reach alone, and so the test
    /// covers a cursor walking into BOTH a clamped edge and open field.
    sweep: proto.CursorDir,
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
        &.{ server_path, port_str },
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
    var ctx_a = BotCtx{ .name = "BotA", .sweep = .right };
    var ctx_b = BotCtx{ .name = "BotB", .sweep = .down };

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
        if (ctx.result.grid_cells == 0) {
            std.debug.print("[e2e] FAIL {s}: game_start carried no grid dimensions\n", .{ctx.name});
            failed = true;
            continue;
        }
        if (ctx.result.lil_guys < 2) {
            std.debug.print("[e2e] FAIL {s}: saw {} Lil Guys, want one per player\n", .{
                ctx.name, ctx.result.lil_guys,
            });
            failed = true;
            continue;
        }
        if (ctx.result.casts_total == 0 or ctx.result.stats_neutralized == 0) {
            std.debug.print("[e2e] FAIL {s}: empty match stats (casts={}, neutralized={})\n", .{
                ctx.name, ctx.result.casts_total, ctx.result.stats_neutralized,
            });
            failed = true;
            continue;
        }
        // Coverage is the shape mechanic's headline stat: casts firing without
        // it would mean stamps landed nowhere.
        if (ctx.result.stats_covered == 0) {
            std.debug.print("[e2e] FAIL {s}: stamps covered no hazard cells\n", .{ctx.name});
            failed = true;
            continue;
        }
        if (ctx.result.shape_casts == 0) {
            std.debug.print("[e2e] FAIL {s}: no shape_cast broadcasts seen\n", .{ctx.name});
            failed = true;
            continue;
        }
        // The bots start at the grid centre and only ever aim outward, so a
        // cursor that never left column 0 means move_cursor did nothing.
        if (ctx.result.max_cursor_col == 0) {
            std.debug.print("[e2e] FAIL {s}: cursor never moved\n", .{ctx.name});
            failed = true;
            continue;
        }
        std.debug.print("[e2e] OK   {s}: score={}, {} hunger events, {}-cell grid, {} lil guys, {} casts, {} covered, {} defused, {} stamps, cursor col {}\n", .{
            ctx.name,                  ctx.result.score,
            ctx.result.hunger_events,  ctx.result.grid_cells,
            ctx.result.lil_guys,       ctx.result.casts_total,
            ctx.result.stats_covered,  ctx.result.stats_neutralized,
            ctx.result.shape_casts,    ctx.result.max_cursor_col,
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
    // Our player id, from game_start — needed to pick our own entity (and so
    // our own cursor) out of each snapshot.
    var my_player_id: u8 = 0xFF;
    // Ticks to wait between casts.  The server rejects submits while a
    // player's cast lock is cooling, so we pace ourselves rather than
    // spamming every frame.
    var ticks_until_cast: u32 = 0;

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
                var fbs = std.io.fixedBufferStream(payload);
                const start = proto.decode_game_start(fbs.reader()) catch continue;
                in_game = true;
                my_player_id = start.player_id;
                ctx.result.grid_cells =
                    @as(u16, start.grid_rows) * @as(u16, start.grid_cols);
                std.debug.print("[e2e] {s} game_start: {}x{} grid, player {}\n", .{
                    ctx.name, start.grid_rows, start.grid_cols, start.player_id,
                });
            },

            .game_state => {
                var fbs = std.io.fixedBufferStream(payload);
                const gs = proto.decode_game_state(fbs.reader()) catch continue;
                if (!in_game) continue;

                ctx.result.lil_guys = @max(ctx.result.lil_guys, gs.lil_guy_count);

                // Track our own cursor as the server reports it.  While a cast
                // buffers the server sends the captured ANCHOR here, so this
                // also proves anchors are snapshotted.
                for (gs.entities[0..gs.entity_count]) |e| {
                    if (e.owner != my_player_id) continue;
                    ctx.result.max_cursor_col =
                        @max(ctx.result.max_cursor_col, e.cursor_col);
                }

                if (ticks_until_cast > 0) {
                    ticks_until_cast -= 1;
                    continue;
                }
                ticks_until_cast = CAST_INTERVAL_TICKS;

                // Aim first, then cast: the server captures the cursor at
                // SUBMIT time, so the walk must land before the submit.
                // Clamping makes the sweep safe to run forever — a bot that
                // reaches the edge simply stops advancing.
                for (0..AIM_STEPS_PER_CAST) |_| {
                    try send_move_cursor(&client, ctx.sweep);
                }
                // Both bots submit the twin_bloom half, so the team recipe
                // fires and stamps its big diamond; unpaired casts still land
                // as the solo `sweep` recipe.
                try send_submit(&client, c.make_combo(&.{
                    .{ .action = .dispense },
                    .{ .action = .medicine },
                }));
            },

            .action_result => {
                var fbs = std.io.fixedBufferStream(payload);
                const ar = proto.decode_action_result(fbs.reader()) catch continue;
                if (ar.tag == .damage) {
                    ctx.result.hunger_events += 1;
                }
            },

            .shape_cast => {
                var fbs = std.io.fixedBufferStream(payload);
                _ = proto.decode_shape_cast(fbs.reader()) catch continue;
                ctx.result.shape_casts += 1;
            },

            .game_over => {
                var fbs = std.io.fixedBufferStream(payload);
                const go = proto.decode_game_over(fbs.reader()) catch continue;
                ctx.result.got_game_over = true;
                ctx.result.score = go.score;
                ctx.result.casts_total = go.stats.casts_total;
                for (go.stats.feast.neutralized) |n| ctx.result.stats_neutralized += n;
                for (go.stats.feast.cells_covered) |n| ctx.result.stats_covered += n;
                std.debug.print("[e2e] {s} game_over: score={} reason={s} slime={}/{} casts={} covered={} defused={}\n", .{
                    ctx.name,                 go.score,
                    @tagName(go.stats.reason), go.stats.slime_left,
                    go.stats.slime_total,     go.stats.casts_total,
                    ctx.result.stats_covered, ctx.result.stats_neutralized,
                });
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

/// Walk this player's server-authoritative aim cursor one cell.  Clamped
/// server-side, so stepping into an edge is a no-op rather than an error.
fn send_move_cursor(client: *ws.Client, dir: proto.CursorDir) !void {
    var buf: [2]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), .move_cursor, proto.MoveCursor{ .dir = dir });
    try client.writeBin(fbs.getWritten());
}

fn send_ready_up(client: *ws.Client) !void {
    var buf: [2]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), .ready_up, {});
    try client.writeBin(fbs.getWritten());
}

/// Submit a spell for real (choose_combo is only the live preview).
fn send_submit(client: *ws.Client, combo: c.ActionCombo) !void {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), .submit_spell, proto.SubmitSpell{ .combo = combo });
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
