# ecs-zig JRPG

Co-op browser JRPG with ATB (Active Time Battle) combat. Up to 6 players vs scripted enemy waves. Authoritative Zig server; browser client compiled to WASM via Emscripten + Raylib.

## Requirements

- Zig 0.15.2
- For WASM: Emscripten SDK (pulled in as a Zig package dep — no system install needed)

## Quick start

Terminal 1 — server:

```
zig build run-server
```

Terminal 2 — native desktop client (dev/test):

```
zig build run
```

The client connects to `ws://127.0.0.1:9001`. **Start the server first** — the client will crash with `ConnectionFailed` if the server isn't up.

## Build targets

| Command | Output |
|---|---|
| `zig build` | Native desktop client (`zig-out/bin/jrpg_client`) |
| `zig build run` | Build + run native client |
| `zig build server` | Game server (`zig-out/bin/jrpg_server`) |
| `zig build run-server` | Build + run server |
| `zig build -Dtarget=wasm32-emscripten` | WASM bundle → `zig-out/web/` |
| `zig build test` | Unit + integration tests (protocol, game logic, ECS, session) |
| `zig build e2e` | E2E test: spawn real server, 2 bot clients, assert players win |

## WASM / browser

After `zig build -Dtarget=wasm32-emscripten`, serve `zig-out/web/` with any static HTTP server alongside `web/index.html` and `web/ws_glue.js`:

```
cd zig-out/web && python3 -m http.server 8080
```

Open `http://localhost:8080`. Enter a player name; the page connects to the server via WebSocket. `sessionStorage` persists your `player_id` across reloads for reconnect support.

## Gameplay

**Lobby**

| Key | Action |
|---|---|
| `1` / `2` / `3` | Pick class: Fighter / Mage / Healer |
| `Enter` | Toggle ready |

**Combat (ATB)**

When your ATB bar fills the server sends `YourTurn`. Then:

| Key | Action |
|---|---|
| Arrow keys | Move cursor |
| `A` | Select Attack |
| `D` | Select Defend |
| `Enter` | Confirm |
| `Escape` | Cancel |

- **Fighter** — single-target melee attack; Defend shields allies in the row behind.
- **Mage** — 2×2 AoE on the enemy grid.
- **Healer** — 2×2 AoE heal on the player grid.

Six scripted enemy waves (`wave_01_basic` through `wave_05_boss_plus_grunts`); clearing all waves wins. `wave_01_basic` is a standalone warm-up (3 grunts, no chaining); the full campaign starts at `wave_02_spread`.

## Architecture

```
shared/          pure Zig: ECS components, ATB/combat math, wire protocol, wave scripts
client/          Zig + Raylib → native binary or WASM via Emscripten
  net/ws_native.zig   desktop WebSocket client (dev)
  net/ws_browser.zig  extern JS bindings (WASM)
server/          Zig + websocket.zig (karlseguin) — authoritative game loop
  session.zig    lobby state machine, ATB tick, AI, action resolution
web/
  index.html     WASM shell + name entry form
  ws_glue.js     JS WebSocket ↔ WASM linear memory bridge
```

All game logic runs on the server. Clients send inputs only (`JoinLobby`, `ChooseClass`, `ReadyUp`, `ChooseAction`, `Reconnect`). The server broadcasts `LobbyUpdate`, `GameState` snapshots, `YourTurn`, `ActionResult`, and `GameOver`.

Wire protocol is binary, little-endian, no allocations on the hot path. See `src/shared/protocol.zig`.

## Project layout

```
src/
  root.zig               ECS core (Austin Morlan-style, comptime)
  shared/
    shared.zig           module root
    components.zig       all ECS component types
    game_logic.zig       ATB, combat math, grid helpers
    protocol.zig         binary wire protocol + round-trip tests
    transport.zig        abstract Transport interface
    waves.zig            6 scripted enemy wave definitions
  client/
    main.zig             entry point, ClientState, message dispatch
    render.zig           lobby + game scene (colored rects, HP/ATB bars)
    input.zig            keyboard → InputEvent
    net/
      ws_browser.zig     WASM extern JS WS bindings
      ws_native.zig      native desktop WS client
  server/
    main.zig             server entry point
    session.zig          Session struct: lobby, tick, AI, broadcasts
    session_test.zig     13 in-process integration tests (no network)
    net/
      ws_server.zig      websocket.zig → Transport adapter
  e2e/
    e2e_test.zig         end-to-end test (spawns server, 2 bots, full game loop)
specs/
  game-plan.md           original milestone plan
  next-steps.md          bug fix log
web/
  index.html
  ws_glue.js
