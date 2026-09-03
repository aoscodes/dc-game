const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // Dependencies
    // -----------------------------------------------------------------------

    const ws_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });
    const ws_mod = ws_dep.module("websocket");

    // -----------------------------------------------------------------------
    // Shared module
    // -----------------------------------------------------------------------

    const shared_mod = b.addModule("shared", .{
        .root_source_file = b.path("src/shared/shared.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Shipped data files, embedded so config tests can validate them.
    shared_mod.addAnonymousImport("balance_data", .{ .root_source_file = b.path("data/balance.json") });
    shared_mod.addAnonymousImport("encounters_data", .{ .root_source_file = b.path("data/encounters.json") });

    // -----------------------------------------------------------------------
    // ECS core module
    // -----------------------------------------------------------------------

    const ecs_mod = b.addModule("ecs_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // -----------------------------------------------------------------------
    // Debug tooling module  (no Raylib dependency)
    // -----------------------------------------------------------------------

    const debug_mod = b.addModule("debug_zig", .{
        .root_source_file = b.path("src/debug/debug.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs_zig", .module = ecs_mod },
            .{ .name = "shared", .module = shared_mod },
        },
    });

    // -----------------------------------------------------------------------
    // Native client  (zig build  /  zig build run)
    //
    // The client is a headless binary.  Rendering is done in the browser via
    // the Node.js bridge (bridge/index.js).  Run with:
    //   node bridge/index.js
    // which will spawn this binary and relay its stdio to the browser.
    // -----------------------------------------------------------------------

    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs_zig", .module = ecs_mod },
            .{ .name = "shared", .module = shared_mod },
        },
    });

    const client_exe = b.addExecutable(.{
        .name = "client",
        .root_module = client_mod,
    });
    b.installArtifact(client_exe);

    // `zig build run` — build client then launch bridge (which spawns client).
    // We just run the bridge; it handles spawning the binary.
    const run_bridge = b.addSystemCommand(&.{ "node", "bridge/index.js" });
    run_bridge.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_bridge.addArgs(args);
    const run_step = b.step("run", "Build client and start the Node.js bridge");
    run_step.dependOn(&run_bridge.step);

    // -----------------------------------------------------------------------
    // Server  (zig build server)
    // -----------------------------------------------------------------------

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs_zig", .module = ecs_mod },
            .{ .name = "shared", .module = shared_mod },
            .{ .name = "websocket", .module = ws_mod },
            .{ .name = "debug_zig", .module = debug_mod },
        },
    });

    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_module = server_mod,
    });
    // Install server alongside client so `zig build` (and `zig build run`) always
    // produce both binaries.  The bridge needs both at zig-out/bin/.
    b.installArtifact(server_exe);

    const server_step = b.step("server", "Build and install the game server");
    const server_install = b.addInstallArtifact(server_exe, .{});
    server_step.dependOn(&server_install.step);

    const run_server = b.addRunArtifact(server_exe);
    run_server.step.dependOn(&server_install.step);
    if (b.args) |args| run_server.addArgs(args);
    const run_server_step = b.step("run-server", "Run the game server");
    run_server_step.dependOn(&run_server.step);

    // -----------------------------------------------------------------------
    // E2E test  (zig build e2e)
    // -----------------------------------------------------------------------

    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/e2e/e2e_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "shared", .module = shared_mod },
            .{ .name = "websocket", .module = ws_mod },
        },
    });
    const e2e_exe = b.addExecutable(.{
        .name = "e2e",
        .root_module = e2e_mod,
    });

    const e2e_server_install = b.addInstallArtifact(server_exe, .{});
    const e2e_install = b.addInstallArtifact(e2e_exe, .{});
    const run_e2e = b.addRunArtifact(e2e_exe);
    run_e2e.step.dependOn(&e2e_server_install.step);
    run_e2e.step.dependOn(&e2e_install.step);

    const e2e_step = b.step("e2e", "Run end-to-end game session test");
    e2e_step.dependOn(&run_e2e.step);

    // -----------------------------------------------------------------------
    // Debug module tests  (zig build debug-test)
    // -----------------------------------------------------------------------

    const debug_test_step = b.step("debug-test", "Run debug module tests");

    const debug_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/debug/debug.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs_zig", .module = ecs_mod },
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    debug_test_step.dependOn(&b.addRunArtifact(debug_tests).step);

    const snapshot_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/debug/snapshot_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs_zig", .module = ecs_mod },
            },
        }),
    });
    debug_test_step.dependOn(&b.addRunArtifact(snapshot_tests).step);

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    const test_step = b.step("test", "Run all tests");

    const ecs_tests = b.addTest(.{ .root_module = ecs_mod });
    test_step.dependOn(&b.addRunArtifact(ecs_tests).step);

    const shared_test_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/shared.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared_test_mod.addAnonymousImport("balance_data", .{ .root_source_file = b.path("data/balance.json") });
    shared_test_mod.addAnonymousImport("encounters_data", .{ .root_source_file = b.path("data/encounters.json") });
    const shared_tests = b.addTest(.{ .root_module = shared_test_mod });
    test_step.dependOn(&b.addRunArtifact(shared_tests).step);

    // Session integration tests — debug_zig no longer requires raylib.
    const session_debug_mod = b.addModule("debug_zig_session_test", .{
        .root_source_file = b.path("src/debug/debug.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs_zig", .module = ecs_mod },
            .{ .name = "shared", .module = shared_mod },
        },
    });
    const session_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/session_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs_zig", .module = ecs_mod },
                .{ .name = "shared", .module = shared_mod },
                .{ .name = "websocket", .module = ws_mod },
                .{ .name = "debug_zig", .module = session_debug_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(session_tests).step);

    // Bot harness tests — inject bots into player slots, configurable profiles.
    const bot_debug_mod = b.addModule("debug_zig_bot_test", .{
        .root_source_file = b.path("src/debug/debug.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs_zig", .module = ecs_mod },
            .{ .name = "shared", .module = shared_mod },
        },
    });
    const bot_harness_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/bot_harness_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs_zig", .module = ecs_mod },
                .{ .name = "shared", .module = shared_mod },
                .{ .name = "debug_zig", .module = bot_debug_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(bot_harness_tests).step);

    // Client input tests (key → combo-slot mapping, submit/cancel results).
    const client_input_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/input.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(client_input_tests).step);

    // Render-frame contract tests: the JSON the browser renderer actually
    // reads.  The binary protocol is not the contract with web/game.js —
    // this hand-written mirror is, and it can drift from proto silently.
    const stdout_writer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/stdout_writer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(stdout_writer_tests).step);

    // -----------------------------------------------------------------------
    // JS mirror harnesses  (zig build web-test)
    // -----------------------------------------------------------------------
    //
    // web/game.js re-implements server rules so the replay can show the same
    // meal the server served; web/test asserts the two still agree.  Wired
    // into `test` on purpose — these ran as loose scratch files for months and
    // one of them silently rotted against a deleted API, which is precisely
    // what an unrun test does.
    const web_test = b.addSystemCommand(&.{ "node", "web/test/run.mjs" });
    web_test.setCwd(b.path("."));
    // Node is already a hard dependency of `zig build run` (the bridge), so
    // requiring it here adds nothing new to the toolchain.
    const web_test_step = b.step("web-test", "Run the JS mirror harnesses");
    web_test_step.dependOn(&web_test.step);
    test_step.dependOn(&web_test.step);

    // -----------------------------------------------------------------------
    // Sprite atlases  (zig build assets)
    // -----------------------------------------------------------------------
    //
    // The critter art lives in the BOARD repo, in the same 5-tone masters the
    // e-paper badge draws from, and scripts/gen_lilguys.py converts it into
    // the atlases web/game.js loads.  Generated output is COMMITTED, because
    // the browser fetches web/assets straight off disk and a clone that has
    // not run a build step must still be able to serve a playable game.
    //
    // Committed output rots, so `assets-check` regenerates into memory and
    // compares — wired into `test` so that editing the art on the board side
    // and forgetting to re-run this is a failing build rather than a game
    // quietly drawing last month's creature.
    const gen_assets = b.addSystemCommand(&.{ "python3", "scripts/gen_lilguys.py" });
    gen_assets.setCwd(b.path("."));
    const assets_step = b.step("assets", "Regenerate the sprite atlases from the board's art");
    assets_step.dependOn(&gen_assets.step);

    const check_assets = b.addSystemCommand(&.{ "python3", "scripts/gen_lilguys.py", "--check" });
    check_assets.setCwd(b.path("."));
    const assets_check_step = b.step("assets-check", "Verify the committed atlases match the board's art");
    assets_check_step.dependOn(&check_assets.step);
    test_step.dependOn(&check_assets.step);

    // -----------------------------------------------------------------------
    // Render-gate probe  (zig build gate-probe)
    // -----------------------------------------------------------------------
    //
    // The only test that runs the CLIENT BINARY.  `zig build e2e` drives the
    // server with protocol-level bots and never spawns a client, so the whole
    // client emit path — stdin reader, render gate, JSON writer — was untested
    // end to end.  A stdin reader that livelocked and emitted zero frames once
    // passed every other step in this file; that is the gap this closes.
    //
    // Wired into `test` despite taking ~14s of wall clock, because the failure
    // it catches is invisible to every cheaper check and fatal to the game.
    // Override the window with PROBE_SECONDS when iterating.
    const probe_client_install = b.addInstallArtifact(client_exe, .{});
    const probe_server_install = b.addInstallArtifact(server_exe, .{});
    const gate_probe = b.addSystemCommand(&.{ "node", "bridge/test/gate_probe.mjs" });
    gate_probe.setCwd(b.path("."));
    gate_probe.step.dependOn(&probe_client_install.step);
    gate_probe.step.dependOn(&probe_server_install.step);
    // It spawns a real server on a real port and measures real elapsed time, so
    // it is never up to date and must not be cached.
    gate_probe.has_side_effects = true;
    const gate_probe_step = b.step("gate-probe", "Measure the client's render frames end to end");
    gate_probe_step.dependOn(&gate_probe.step);
    test_step.dependOn(&gate_probe.step);
}
