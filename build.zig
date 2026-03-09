const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // Dependencies
    // -----------------------------------------------------------------------

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib_mod = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    const ws_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });
    const ws_mod = ws_dep.module("websocket");

    // -----------------------------------------------------------------------
    // Shared module
    // -----------------------------------------------------------------------

    // A single module that both client and server import.  Contains all
    // component definitions, the wire protocol, transport interface, wave
    // scripts, and pure game logic.  Registered as "shared" in every
    // downstream module's import list.
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
    // Build path: WASM client vs native client vs server
    // -----------------------------------------------------------------------

    const is_wasm = target.query.os_tag == .emscripten;

    if (is_wasm) {
        // -------------------------------------------------------------------
        // WASM client  (zig build -Dtarget=wasm32-emscripten)
        // -------------------------------------------------------------------
        const rlz = @import("raylib_zig");
        const emsdk_dep = b.dependency("emsdk", .{});

        const client_mod = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs_zig", .module = ecs_mod },
                .{ .name = "raylib", .module = raylib_mod },
                .{ .name = "shared", .module = shared_mod },
            },
        });

        const wasm = b.addLibrary(.{
            .name = "jrpg_client",
            .root_module = client_mod,
        });
        wasm.root_module.linkLibrary(raylib_artifact);

        const emcc_flags = rlz.emsdk.emccDefaultFlags(b.allocator, .{ .optimize = optimize });
        const emcc_settings = rlz.emsdk.emccDefaultSettings(b.allocator, .{ .optimize = optimize });

        const emcc_step = rlz.emsdk.emccStep(b, raylib_artifact, wasm, .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .shell_file_path = rlz.emsdk.shell(raylib_dep.builder),
            .install_dir = .{ .custom = "web" },
            .embed_paths = &.{},
        });
        _ = emsdk_dep; // emsdk is pulled in transitively by raylib_zig
        b.getInstallStep().dependOn(emcc_step);
    } else {
        // -------------------------------------------------------------------
        // Native desktop client  (zig build  /  zig build run)
        // -------------------------------------------------------------------
        const client_mod = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs_zig", .module = ecs_mod },
                .{ .name = "raylib", .module = raylib_mod },
                .{ .name = "shared", .module = shared_mod },
            },
        });

        const client_exe = b.addExecutable(.{
            .name = "jrpg_client",
            .root_module = client_mod,
        });
        client_exe.root_module.linkLibrary(raylib_artifact);
        b.installArtifact(client_exe);

        const run_client = b.addRunArtifact(client_exe);
        run_client.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_client.addArgs(args);
        const run_step = b.step("run", "Run the desktop client");
        run_step.dependOn(&run_client.step);

        // -------------------------------------------------------------------
        // Server  (zig build server)
        // -------------------------------------------------------------------
        const server_mod = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs_zig", .module = ecs_mod },
                .{ .name = "shared", .module = shared_mod },
                .{ .name = "websocket", .module = ws_mod },
            },
        });

        const server_exe = b.addExecutable(.{
            .name = "jrpg_server",
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
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    const test_step = b.step("test", "Run all tests");

    // ECS core tests
    const ecs_tests = b.addTest(.{ .root_module = ecs_mod });
    test_step.dependOn(&b.addRunArtifact(ecs_tests).step);

    // Shared module tests (protocol round-trips, game logic, transport)
    const shared_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shared/shared.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(shared_tests).step);

    // Session integration tests (server game loop, no network, no raylib)
    const session_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/session_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs_zig", .module = ecs_mod },
                .{ .name = "shared", .module = shared_mod },
                .{ .name = "websocket", .module = ws_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(session_tests).step);
}
