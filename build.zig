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

    const shared_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shared/shared.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
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
}
