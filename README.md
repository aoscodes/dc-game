# DragonCon RPG

Co-op RPG with ATB (Active Time Battle) combat. Up to 6 players vs scripted enemy waves. Authoritative Zig server; browser client compiled to WASM via Emscripten + Raylib.

## Requirements

- Zig 0.15.2
- For WASM: Emscripten SDK (pulled in as a Zig package dep — no system install needed)

## Quick start (local)

Terminal 1 — server:

```
zig build run-server
```

Terminal 2 — native desktop client:

```
zig build run
```

The client connects to `ws://127.0.0.1:9001`. Start the server first.

### Browser client locally

```
zig build -Dtarget=wasm32-emscripten
cp web/index.html web/ws_glue.js zig-out/web/
cd zig-out/web && python3 -m http.server 8080
```

Open `http://localhost:8080`. The page connects to `ws://localhost/ws` — to test locally you need Nginx (or a proxy) forwarding `/ws` to port 9001, or temporarily revert the server URL in `web/index.html` to `ws://localhost:9001` for local-only testing.

## Build targets

| Command | Output |
| --- | --- |
| `zig build` | Native desktop client (`zig-out/bin/client`) |
| `zig build run` | Build + run native client |
| `zig build server` | Game server (`zig-out/bin/server`) |
| `zig build run-server` | Build + run server |
| `zig build -Dtarget=wasm32-emscripten` | WASM bundle → `zig-out/web/` |
| `zig build test` | Unit + integration tests |
| `zig build e2e` | E2E test: spawn real server + 2 bot clients |

## Deploy to a VPS

### One-time VPS setup

Provision an Ubuntu 24.04 x86_64 VPS (Hetzner, DigitalOcean, Vultr, etc.).

SSH in as root and run the setup script:

```
bash scripts/vps-setup.sh
```

This installs Nginx, creates a `dragoncon` service user, writes the systemd unit, and configures Nginx to serve static files and proxy `/ws` to the game server.

After the script:

1. **Add the deploy SSH key** — generate an ED25519 keypair:
   ```
   ssh-keygen -t ed25519 -f deploy_key
   cat deploy_key.pub >> /home/deploy/.ssh/authorized_keys   # on VPS
   chmod 600 /home/deploy/.ssh/authorized_keys               # on VPS
   ```

2. **Copy `waves.json`** to the VPS (managed separately, not deployed by CI):
   ```
   scp waves.json deploy@<vps-ip>:/opt/dragoncon/waves.json
   ```

3. **Add GitHub Actions secrets** in your repo settings:

   | Secret | Value |
   | --- | --- |
   | `VPS_HOST` | VPS IPv4 address |
   | `VPS_USER` | `deploy` |
   | `VPS_SSH_KEY` | Contents of `deploy_key` (private key) |

### CI/CD

`.github/workflows/deploy.yml` runs on every push to `main`:

1. Runs `zig build test` and `zig build e2e` — deploy aborts if either fails
2. Builds `zig-out/bin/server` (`-Doptimize=ReleaseSafe`)
3. Builds `zig-out/web/` (`-Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall`)
4. SCPs artifacts to the VPS and restarts `dragoncon-server.service`

First push after secrets are set will trigger a full deploy.

### TLS (HTTPS / WSS)

The browser requires `wss://` when the page is served over HTTPS. After DNS is pointed at the VPS:

```
certbot --nginx -d <your-domain>
```

Certbot edits the Nginx config to add `listen 443 ssl` and sets up auto-renew. The page then serves over HTTPS and the client automatically uses `wss://` (see `web/index.html`).

Until you have a domain, the game is playable over plain `http://` with `ws://`.

### `waves.json`

The server hot-reloads `/opt/dragoncon/waves.json` at runtime (mtime polling). Edit it on the VPS directly — changes take effect within 5 seconds without a restart. It is intentionally excluded from CI deploys so you can tune waves without triggering a full rebuild.

## Gameplay

**Lobby**

| Key | Action |
| --- | --- |
| `1` / `2` / `3` | Pick class: Fighter / Mage / Healer |
| `Enter` | Toggle ready |

**Combat (ATB)**

When your ATB bar fills the server sends `YourTurn`. Then:

| Key | Action |
| --- | --- |
| Arrow keys | Move cursor |
| `A` | Select Attack |
| `D` | Select Defend |
| `Enter` | Confirm |
| `Escape` | Cancel |

- **Fighter** — single-target melee attack; Defend shields allies in the row behind.
- **Mage** — 2×2 AoE on the enemy grid.
- **Healer** — 2×2 AoE heal on the player grid.

Six scripted enemy waves (`wave_01_basic` through `wave_05_boss_plus_grunts`); clearing all waves wins.

## Architecture

```
shared/          pure Zig: ECS components, ATB/combat math, wire protocol, wave scripts
client/          Zig + Raylib → native binary or WASM via Emscripten
  net/ws_native.zig   desktop WebSocket client
  net/ws_browser.zig  extern JS bindings (WASM); Thread.spawn guarded for single-threaded target
server/          Zig + websocket.zig (karlseguin) — authoritative game loop
  session.zig    lobby state machine, ATB tick, AI, action resolution
web/
  index.html     WASM shell + name entry form; derives ws/wss URL from page origin
  ws_glue.js     JS WebSocket ↔ WASM linear memory bridge (injected at instantiation time)
```

All game logic runs on the server. Clients send inputs only (`JoinLobby`, `ChooseClass`, `ReadyUp`, `ChooseAction`, `Reconnect`). The server broadcasts `LobbyUpdate`, `GameState` snapshots, `YourTurn`, `ActionResult`, and `GameOver`.

Wire protocol is binary, little-endian, no allocations on the hot path. See `src/shared/protocol.zig`.

WebSocket URL (`web/index.html`) is derived from the page origin at runtime — `wss://` when served over HTTPS, `ws://` otherwise. Path is always `/ws`, which Nginx proxies to `127.0.0.1:9001`.

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
scripts/
  vps-setup.sh           one-time VPS provisioning (Nginx, systemd, deploy user)
specs/
  game-plan.md           original milestone plan
  next-steps.md          known gaps
  deploy.md              deployment spec
web/
  index.html             WASM shell
  ws_glue.js             JS WebSocket bridge
.github/workflows/
  deploy.yml             CI: test → build → deploy on push to main
