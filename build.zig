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
            .name = "client",
            .root_module = client_mod,
        });

        // With emscripten_set_main_loop the browser's rAF governs frame rate.
        // EndDrawing's built-in WaitTime busy-spins on WASM (nanosleep is a
        // no-op without Asyncify) causing ~1700 fps and browser starvation.
        // SUPPORT_CUSTOM_FRAME_CONTROL removes that block; we call
        // swapScreenBuffer + pollInputEvents manually each frame instead.
        //
        // addCMacro on raylib_artifact does not work (dep is pre-cached).
        // Instead re-fetch raylib directly via raylib_zig's sub-dependency
        // with the config flag, giving us a correctly compiled artifact.
        const raylib_wasm_artifact = raylib_dep.builder.dependency("raylib", .{
            .target = target,
            .optimize = optimize,
            .config = @as([]const u8, "-DSUPPORT_CUSTOM_FRAME_CONTROL"),
        }).artifact("raylib");
        wasm.root_module.linkLibrary(raylib_wasm_artifact);

        var emcc_flags = rlz.emsdk.emccDefaultFlags(b.allocator, .{ .optimize = optimize, .asyncify = false });
        var emcc_settings = rlz.emsdk.emccDefaultSettings(b.allocator, .{ .optimize = optimize });

        // ws_connect / ws_send / ws_close are provided via ws_lib.js as a
        // proper Emscripten JS library (--js-library).  This ensures Closure
        // Compiler preserves their names in all optimize modes; without it
        // -Oz renames them to single-letter keys that JS cannot inject into.
        emcc_flags.put(
            b.fmt("--js-library={s}", .{b.pathFromRoot("web/ws_lib.js")}),
            {},
        ) catch @panic("OOM");

        // Export all symbols that index.html calls directly or that ws_glue.js
        // invokes as callbacks.  Without this list emscripten only exports main.
        emcc_settings.put("EXPORTED_FUNCTIONS",
            \\["_main","_start_connect","_save_player_id","_wasm_alloc","_wasm_free","_on_ws_open","_on_ws_message","_on_ws_close","_g_server_url_buf"]
        ) catch @panic("OOM");

        // Export wasmMemory (for ws_glue.js) and ws_impl (so ws_glue.js can
        // populate the ws_connect/ws_send/ws_close dispatch slots at runtime).
        // Also suppresses the spurious requestFullscreen warning from raylib's
        // default emcc settings.
        emcc_settings.put("EXPORTED_RUNTIME_METHODS", "[\"wasmMemory\",\"ws_impl\"]") catch @panic("OOM");

        // Allow the WASM heap to grow beyond the default 16 MB initial size.
        // Without this, page_allocator.alloc fails as soon as the heap is full
        // because memory.grow returns -1 and Emscripten does not resize.
        emcc_settings.put("ALLOW_MEMORY_GROWTH", "1") catch @panic("OOM");

        const emcc_step = rlz.emsdk.emccStep(b, raylib_wasm_artifact, wasm, .{
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
        // Debug tooling module  (raylib always available in native builds)
        // -------------------------------------------------------------------
        const debug_mod = b.addModule("debug_zig", .{
            .root_source_file = b.path("src/debug/debug.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs_zig", .module = ecs_mod },
                .{ .name = "shared", .module = shared_mod },
                .{ .name = "raylib", .module = raylib_mod },
            },
        });

        // -------------------------------------------------------------------
        // ECS demo  (zig build demo / zig build run-demo)
        // src/main.zig — 5 000 falling entities + debug HUD
        // -------------------------------------------------------------------
        const demo_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs_zig", .module = ecs_mod },
                .{ .name = "raylib", .module = raylib_mod },
                .{ .name = "debug_zig", .module = debug_mod },
            },
        });
        const demo_exe = b.addExecutable(.{
            .name = "ecs_demo",
            .root_module = demo_mod,
        });
        demo_exe.root_module.linkLibrary(raylib_artifact);
        const demo_install = b.addInstallArtifact(demo_exe, .{});
        const demo_step = b.step("demo", "Build the ECS gravity demo");
        demo_step.dependOn(&demo_install.step);

        const run_demo = b.addRunArtifact(demo_exe);
        run_demo.step.dependOn(&demo_install.step);
        if (b.args) |args| run_demo.addArgs(args);
        const run_demo_step = b.step("run-demo", "Run the ECS gravity demo");
        run_demo_step.dependOn(&run_demo.step);

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
            .name = "client",
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
                .{ .name = "debug_zig", .module = debug_mod },
            },
        });

        const server_exe = b.addExecutable(.{
            .name = "server",
            .root_module = server_mod,
        });
        // Link raylib for the server so hud.zig compiles (not rendered server-side)
        server_exe.root_module.linkLibrary(raylib_artifact);

        const server_step = b.step("server", "Build and install the game server");
        const server_install = b.addInstallArtifact(server_exe, .{});
        server_step.dependOn(&server_install.step);

        const run_server = b.addRunArtifact(server_exe);
        run_server.step.dependOn(&server_install.step);
        if (b.args) |args| run_server.addArgs(args);
        const run_server_step = b.step("run-server", "Run the game server");
        run_server_step.dependOn(&run_server.step);

        // -------------------------------------------------------------------
        // E2E test  (zig build e2e)
        // Spawns a real server process, runs two bot clients through a
        // full game session, asserts players win.  Separate from `zig build
        // test` to avoid flakiness from process spawning in CI.
        // -------------------------------------------------------------------
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
        // server binary must be installed before the test runs
        run_e2e.step.dependOn(&e2e_server_install.step);
        run_e2e.step.dependOn(&e2e_install.step);

        const e2e_step = b.step("e2e", "Run end-to-end game session test");
        e2e_step.dependOn(&run_e2e.step);

        // -------------------------------------------------------------------
        // Debug module tests  (zig build debug-test)
        // Tests in src/debug/ (profiler, inspector, snapshot, replay, etc.)
        // Excludes hud.zig which requires a live window.
        // -------------------------------------------------------------------
        const debug_test_step = b.step("debug-test", "Run debug module tests");

        const debug_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/debug/debug.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "ecs_zig", .module = ecs_mod },
                    .{ .name = "shared", .module = shared_mod },
                    .{ .name = "raylib", .module = raylib_mod },
                },
            }),
        });
        debug_tests.root_module.linkLibrary(raylib_artifact);
        debug_test_step.dependOn(&b.addRunArtifact(debug_tests).step);

        // snapshot_test.zig has its own test file; add it too
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
    // debug_zig is needed because session.zig imports it.
    // We create a headless debug module (raylib_mod is still available in
    // native builds; for the test runner it must be linked too).
    const session_debug_mod = b.addModule("debug_zig_session_test", .{
        .root_source_file = b.path("src/debug/debug.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs_zig", .module = ecs_mod },
            .{ .name = "shared", .module = shared_mod },
            .{ .name = "raylib", .module = raylib_mod },
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
    session_tests.root_module.linkLibrary(raylib_artifact);
    test_step.dependOn(&b.addRunArtifact(session_tests).step);
}
