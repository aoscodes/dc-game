//! End-to-end test: spawn a real server, connect two bot clients over
//! WebSocket, play through a Slime Feast encounter in real time, assert the
//! game ends with a positive shared score.
//!
//! This exercises the whole realtime stack: the server-authoritative slime
//! grid and aim cursors, the per-player cast cooldown, the bite clock (the
//! feast settling on wall time, sped up by the two seats) and the reservoir
//! refill that follows it, shape stamping at each caster's captured anchor,
//! and the recent-cast window across two independent WebSocket clients.
//!
//! The server is launched on a TEST DATA DIR written by this binary: the
//! shipped 4s bite interval would stretch the run past half a minute, so the
//! e2e plays the same game at a 500ms bite and a 100ms cooldown — which also
//! exercises --data-dir end to end.
//!
//! Run with:  zig build e2e
//!
//! The test binary and server are both installed into zig-out/bin/.
//! We locate server relative to our own executable path.

const std = @import("std");
const ws = @import("websocket");
const shared = @import("shared");
const proto = shared.protocol;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const PORT: u16 = 19001;
const SERVER_STARTUP_TIMEOUT_MS: u64 = 3000;
const BOT_TIMEOUT_MS: u32 = 30_000;

/// Where the fast-clock test data is written before the server spawns.
const E2E_DATA_DIR = "zig-out/e2e-data";

/// The shipped balance at e2e speed: a 500ms bite and a 100ms cooldown, so a
/// whole encounter settles in seconds.  The tables are minimal — one cheap
/// poke, one line, and a poke+poke group so team recipes are reachable.
///
/// The settle window is scaled to match: 60ms against a 434ms two-bot bite
/// interval leaves most of each meal playable, so the bots still land the
/// hundreds of casts the assertions below count — while a bot casting every
/// frame is guaranteed to walk into the window and be refused, which is the
/// only way this path gets exercised end to end.
const E2E_BALANCE_JSON =
    \\{
    \\  "hunger_cost_normal": 1,
    \\  "hunger_base": 30,
    \\  "appetite_scale": 5,
    \\  "hunger_player_cap": 500,
    \\  "slime_grid": { "rows": 6, "cols": 10 },
    \\  "bite_interval_ms": 500,
    \\  "bite_speedup_per_guy_pct": 15,
    \\  "bite_speedup_per_baby_pct": 5,
    \\  "cast_cooldown_ms": 100,
    \\  "team_window_ms": 1500,
    \\  "settle_lockout_ms": 60,
    \\  "baby_hunger": 10,
    \\  "feast_columns": 1,
    \\  "feast_columns_per_guy": 0,
    \\  "specials_avoid_door_column": true,
    \\  "player_recipes": [
    \\    { "label": "poke", "shape": ["#"], "cost": 1 },
    \\    { "label": "sweep", "shape": ["###"], "cost": 3 }
    \\  ],
    \\  "team_recipes": [
    \\    { "label": "bloom", "moves": ["poke", "poke"],
    \\      "shape": ["..#..", ".###.", "#####", ".###.", "..#.."], "cost": 4 }
    \\  ]
    \\}
;

/// 60 units against the two bots' 60-point bar: roughly ten bites of game,
/// a couple of realtime seconds at the 500ms interval.
const E2E_ENCOUNTERS_JSON =
    \\{
    \\  "default": "e2e_feast",
    \\  "encounters": [
    \\    { "label": "e2e_feast", "charges": 60,
    \\      "zones": [ { "tiered": { "green": 30 }, "neutral": 30 } ] }
    \\  ]
    \\}
;
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
    /// Highest bite number seen in a game_state — proves the bite clock
    /// advanced rather than the match resolving inside the first meal.
    max_bite: u16 = 0,
    /// `bite_settled` broadcasts seen: the wire proof that feasts happened.
    bite_settles: u32 = 0,
    /// Cast cooldown announced in game_start.
    cast_cooldown_ms: u32 = 0,
    /// Highest `cooldown_ms` this bot ever saw on ITSELF — proof that casting
    /// actually started the cooldown the server broadcasts.
    max_cooldown_seen: u32 = 0,
    stats_neutralized: u32 = 0,
    casts_total: u16 = 0,
    /// Hazard cells the team's stamps downgraded, summed over all tiers.
    stats_covered: u32 = 0,
    /// Highest cursor column this bot's own entity was ever seen at, proving
    /// the server moved the cursor in response to move_cursor.
    max_cursor_col: u8 = 0,
    /// shape_cast broadcasts seen — the wire proof that stamps landed.
    shape_casts: u32 = 0,
    /// `cast_refused` messages this bot earned — the wire proof that the
    /// post-bite settle window actually turned casts away.
    casts_refused: u32 = 0,
    /// Highest `cast_locked_ms` seen in a snapshot, proving the window both
    /// appeared on the wire and was drawable.
    max_cast_locked_ms: u32 = 0,
};

// ---------------------------------------------------------------------------
// Bot context (passed to each thread)
// ---------------------------------------------------------------------------

const BotCtx = struct {
    name: []const u8,
    /// Which direction this bot sweeps.  The two bots aim differently so the
    /// team stamp lands somewhere neither would reach alone, and so the test
    /// covers a cursor walking into BOTH a clamped edge and open field.
    /// BotA heads LEFT because column 0 is where the Lil Guys come in: work
    /// done there is the only work the feast can immediately collect.
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

    // ---- Write the fast-clock data dir --------------------------------------
    try std.fs.cwd().makePath(E2E_DATA_DIR);
    try std.fs.cwd().writeFile(.{
        .sub_path = E2E_DATA_DIR ++ "/balance.json",
        .data = E2E_BALANCE_JSON,
    });
    try std.fs.cwd().writeFile(.{
        .sub_path = E2E_DATA_DIR ++ "/encounters.json",
        .data = E2E_ENCOUNTERS_JSON,
    });
    std.debug.print("[e2e] wrote fast-clock data to {s}\n", .{E2E_DATA_DIR});

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
        &.{ server_path, port_str, "--data-dir", E2E_DATA_DIR },
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
    var ctx_a = BotCtx{ .name = "BotA", .sweep = .left };
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
        if (ctx.result.max_bite < 2) {
            std.debug.print("[e2e] FAIL {s}: reached bite {}, want the clock to advance\n", .{
                ctx.name, ctx.result.max_bite,
            });
            failed = true;
            continue;
        }
        if (ctx.result.bite_settles == 0) {
            std.debug.print("[e2e] FAIL {s}: no bite_settled broadcasts seen\n", .{ctx.name});
            failed = true;
            continue;
        }
        if (ctx.result.cast_cooldown_ms == 0) {
            std.debug.print("[e2e] FAIL {s}: game_start carried no cast cooldown\n", .{ctx.name});
            failed = true;
            continue;
        }
        // A cooldown that never appears on the wire would mean casts were
        // throttle-free (or the snapshot lies).  The bots cast constantly and
        // the state broadcasts every 50ms against a 100ms cooldown, so a
        // running cooldown cannot stay invisible.
        if (ctx.result.max_cooldown_seen == 0) {
            std.debug.print("[e2e] FAIL {s}: own cooldown never seen running\n", .{ctx.name});
            failed = true;
            continue;
        }
        // The settle window, both halves of it: the countdown clients draw
        // and the refusal a cast inside it earns.  A bot casting every frame
        // against a 60ms window on a 434ms bite cannot avoid walking into it,
        // so silence here means the rule is not reaching the wire at all.
        if (ctx.result.max_cast_locked_ms == 0) {
            std.debug.print("[e2e] FAIL {s}: settle window never seen on the wire\n", .{ctx.name});
            failed = true;
            continue;
        }
        if (ctx.result.casts_refused == 0) {
            std.debug.print("[e2e] FAIL {s}: no cast was ever refused mid-settle\n", .{ctx.name});
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
        std.debug.print("[e2e] OK   {s}: score={}, {} hunger events, {}-cell grid, {} bites, {} feasts, {} casts, {} covered, {} defused, {} stamps, cursor col {}\n", .{
            ctx.name,                  ctx.result.score,
            ctx.result.hunger_events,  ctx.result.grid_cells,
            ctx.result.max_bite,       ctx.result.bite_settles,
            ctx.result.casts_total,    ctx.result.stats_covered,
            ctx.result.stats_neutralized, ctx.result.shape_casts,
            ctx.result.max_cursor_col,
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
    // Every connection is an OBSERVER of the already-running game until its
    // take_slot is granted (confirmed by a game_start whose player_id is a
    // real seat).  The boot encounter holds at the PRE-MATCH screen; this
    // test plays the browser tab's part and clicks past it with `restart`.
    var sent_take: bool = false;
    var in_game: bool = false;
    // Our player id, from game_start — needed to pick our own entity (and so
    // our own cursor) out of each snapshot.
    var my_player_id: u8 = proto.NO_PLAYER;

    while (true) {
        const msg = try client.read() orelse continue;
        defer client.done(msg);

        if (msg.data.len == 0) continue;

        const tag_byte = msg.data[0];
        const tag = std.meta.intToEnum(proto.MsgTag, tag_byte) catch continue;
        const payload = msg.data[1..];

        switch (tag) {
            .game_start => {
                var fbs = std.io.fixedBufferStream(payload);
                const start = proto.decode_game_start(fbs.reader()) catch continue;
                if (start.player_id == proto.NO_PLAYER) {
                    // Observing.  Ask for a seat exactly once.
                    if (!sent_take) {
                        std.debug.print("[e2e] {s} observing game {s}; taking a seat\n", .{
                            ctx.name, start.join_code,
                        });
                        try send_take_slot(&client);
                        sent_take = true;
                    }
                    continue;
                }
                if (start.prematch) {
                    // The pre-match guide is holding play: click past it, as
                    // the browser tab would.  Both bots may send this; the
                    // second is a stray click the server ignores.
                    std.debug.print("[e2e] {s} at pre-match; beginning play\n", .{ctx.name});
                    try send_restart(&client);
                    continue;
                }
                in_game = true;
                my_player_id = start.player_id;
                ctx.result.grid_cells =
                    @as(u16, start.grid_rows) * @as(u16, start.grid_cols);
                ctx.result.cast_cooldown_ms = start.cast_cooldown_ms;
                std.debug.print("[e2e] {s} game_start: {}x{} grid, player {}, {}ms cooldown, {}ms window\n", .{
                    ctx.name,          start.grid_rows, start.grid_cols,
                    start.player_id,   start.cast_cooldown_ms,
                    start.team_window_ms,
                });
            },

            .game_state => {
                var fbs = std.io.fixedBufferStream(payload);
                const gs = proto.decode_game_state(fbs.reader()) catch continue;
                if (!in_game) continue;

                ctx.result.max_bite = @max(ctx.result.max_bite, gs.bite);
                ctx.result.max_cast_locked_ms =
                    @max(ctx.result.max_cast_locked_ms, gs.cast_locked_ms);

                // Track our own cursor and cooldown as the server reports them.
                for (gs.entities[0..gs.entity_count]) |e| {
                    if (e.owner != my_player_id) continue;
                    ctx.result.max_cursor_col =
                        @max(ctx.result.max_cursor_col, e.cursor_col);
                    ctx.result.max_cooldown_seen =
                        @max(ctx.result.max_cooldown_seen, e.cooldown_ms);
                }

                // Cast every frame: casts resolve immediately, and presses
                // inside the cooldown are harmlessly dropped, so the bots
                // simply cast as fast as the server will take it.  Aim first,
                // then cast: the server captures the cursor when the cast is
                // accepted, so the walk must land before the trigger.
                // Clamping makes the sweep safe to run forever — a bot that
                // reaches the edge simply stops advancing.
                for (0..AIM_STEPS_PER_CAST) |_| {
                    try send_move_cursor(&client, ctx.sweep);
                }
                // Both bots leave the wheel on move 0 (`poke`), so wherever
                // their casts land on one square inside the window they
                // complete the bloom; everywhere else the poke lands alone.
                try send_cast(&client);
            },

            .action_result => {
                var fbs = std.io.fixedBufferStream(payload);
                const ar = proto.decode_action_result(fbs.reader()) catch continue;
                if (ar.tag == .damage) {
                    ctx.result.hunger_events += 1;
                }
            },

            .bite_settled => {
                var fbs = std.io.fixedBufferStream(payload);
                _ = proto.decode_bite_settled(fbs.reader()) catch continue;
                ctx.result.bite_settles += 1;
            },

            .shape_cast => {
                var fbs = std.io.fixedBufferStream(payload);
                _ = proto.decode_shape_cast(fbs.reader()) catch continue;
                ctx.result.shape_casts += 1;
            },

            .cast_refused => {
                var fbs = std.io.fixedBufferStream(payload);
                _ = proto.decode_cast_refused(fbs.reader()) catch continue;
                ctx.result.casts_refused += 1;
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

/// Ask for a player seat in the running game (appetite 0, like a browser).
fn send_take_slot(client: *ws.Client) !void {
    // tag + appetite (u32) + five per-type baby counts (u32 each) = 25 bytes.
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), .take_slot, proto.TakeSlot{});
    try client.writeBin(fbs.getWritten());
}

/// Advance a hold (the pre-match guide here) — the browser tab's click.
fn send_restart(client: *ws.Client) !void {
    var buf: [2]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), .restart, {});
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

/// Fire whatever the server has selected, wherever the server has us aiming.
fn send_cast(client: *ws.Client) !void {
    var buf: [2]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try proto.encode(fbs.writer(), .cast, {});
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
