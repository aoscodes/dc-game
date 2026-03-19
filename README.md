# DragonCon RPG

Co-op RPG with ATB (Active Time Battle) combat. Up to 6 players vs scripted enemy waves.

Authoritative Zig server. Browser canvas renderer. Zig headless client ↔ Node bridge ↔ browser.

## Requirements

- Zig 0.15.2
- Node.js 18+ (for the bridge and browser e2e tests)

## Quick start (local)

Terminal 1 — server:

```
zig build run-server
```

Terminal 2 — bridge (builds client binary, then starts it + serves the browser UI):

```
zig build run
```

Open `http://localhost:3000`.

### How it works

```
browser (canvas)
   ↕  WebSocket /ws
Node bridge  (bridge/index.js)
   ↕  stdin/stdout JSON frames
Zig client binary  (zig-out/bin/client)
   ↕  stdin/stdout WIRE: hex frames
Node bridge
   ↕  WebSocket
Zig server  (zig-out/bin/server)
```

The Zig client is headless — no window, no GPU. It reads server messages and key events from stdin, writes render frames and outbound server messages to stdout as newline-delimited JSON. The Node bridge owns the WebSocket connections to both the server and the browser.

## Build targets

| Command | Output |
| --- | --- |
| `zig build` | Headless client binary (`zig-out/bin/client`) |
| `zig build run` | Build client + start Node bridge (opens on port 3000) |
| `zig build server` | Game server (`zig-out/bin/server`) |
| `zig build run-server` | Build + run server (listens on port 9001) |
| `zig build test` | Unit + integration tests |
| `zig build e2e` | Zig e2e test: spawn server + 2 bot clients, full game loop |
| `zig build browser-e2e` | Playwright browser e2e (14 tests, requires Node.js) |

## Deploy to a VPS

### One-time VPS setup

Provision an Ubuntu 24.04 x86_64 VPS (Hetzner, DigitalOcean, Vultr, etc.).

SSH in as root and run the setup script:

```
bash scripts/vps-setup.sh
```

This installs Nginx and Node.js, creates a `dragoncon` service user, writes two systemd units (`dragoncon-server` and `dragoncon-bridge`), and configures Nginx to serve `web/` static files and proxy `/ws` to the bridge.

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

1. `zig build test` + `zig build e2e` — deploy aborts if either fails
2. Builds `zig-out/bin/server` (`-Doptimize=ReleaseSafe`)
3. Builds `zig-out/bin/client` (`-Doptimize=ReleaseSafe`) and bundles it with `bridge/`
4. Browser e2e (Playwright, 14 tests) — deploy aborts if any fail
5. SCPs server binary → VPS, restarts `dragoncon-server.service`
6. SCPs client binary + bridge → VPS, runs `npm ci`, restarts `dragoncon-bridge.service`
7. SCPs `web/` static files → `/var/www/dragoncon/`

Path filters skip jobs when unrelated files change (e.g. only `web/` changed → only `deploy-web` runs).

### TLS (HTTPS / WSS)

The bridge WebSocket is `ws://` by default. After DNS is pointed at the VPS and Nginx is running:

```
certbot --nginx -d <your-domain>
```

Certbot adds `listen 443 ssl` and sets up auto-renew. `game.js` derives the WebSocket URL from `location.host`, so `wss://` is used automatically when the page is served over HTTPS.

Until you have a domain, the game is playable over plain `http://`.

### `waves.json`

The server hot-reloads `/opt/dragoncon/waves.json` at runtime (mtime polling). Edit it on the VPS directly — changes take effect within 5 seconds without a restart. Intentionally excluded from CI deploys so wave tuning doesn't trigger a full rebuild.

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
| `1` | Select Attack |
| `2` | Select Defend |
| `Enter` or `Z` | Confirm |
| `Escape` or `X` | Cancel |

- **Fighter** — single-target melee attack; Defend shields allies in the row behind.
- **Mage** — 2×2 AoE on the enemy grid.
- **Healer** — 2×2 AoE heal on the player grid.

Six scripted enemy waves (`wave_01_basic` through `wave_05_boss_plus_grunts`); clearing all waves wins.

## Architecture

```
shared/      pure Zig: ECS components, ATB/combat math, wire protocol, wave scripts
client/      headless Zig stdio binary — game logic + UI state, no window/GPU
server/      authoritative game loop, lobby state machine, AI, broadcasts
bridge/      Node.js: spawns client, owns both WebSocket connections, serves web/
web/         static HTML + JS canvas renderer (no build step)
e2e/         Zig bot e2e (src/e2e/) + Playwright browser e2e (e2e/browser/)
```

All game logic runs on the server. Clients send inputs only (`JoinLobby`, `ChooseClass`, `ReadyUp`, `ChooseAction`, `Reconnect`). The server broadcasts `LobbyUpdate`, `GameState` snapshots, `YourTurn`, `ActionResult`, `GameOver`.

Wire protocol is binary, little-endian, no allocations on the hot path. See `src/shared/protocol.zig`.

Stdio protocol between client and bridge:

| Direction | Format | Meaning |
| --- | --- | --- |
| bridge → client stdin | `WIRE:<hex>\n` | Raw server message bytes, hex-encoded |
| bridge → client stdin | `KEY:<name>\n` | Browser `KeyboardEvent.key` value |
| bridge → client stdin | `READY\n` | Server WebSocket connected; send join |
| client stdout → bridge | `{"tag":"render",...}\n` | Full UI snapshot for the browser |
| client stdout → bridge | `{"tag":"send","bytes":"<hex>"}\n` | Forward bytes to server |

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
    main.zig             entry point, ClientState, stdin reader, game loop
    stdout_writer.zig    JSON render/send frame serialiser
    input.zig            key name → InputEvent
  server/
    main.zig             server entry point
    session.zig          Session: lobby, ATB tick, AI, action resolution, broadcasts
    session_test.zig     13 in-process integration tests (no network)
  e2e/
    e2e_test.zig         Zig e2e: spawns server + 2 bots, full game loop
  debug/
    debug.zig            debug/snapshot utilities (no Raylib dependency)
bridge/
  index.js               Node bridge: spawns client, WebSocket relay, static file server
web/
  index.html             canvas shell
  game.js                canvas renderer: connecting / lobby / game / game_over phases
e2e/browser/
  helpers.js             spawn helpers, Bot, frame collectors, pixel/frame assertions
  playwright.config.js   Playwright config (headless Chromium)
  tests/
    canvas.test.js       canvas element, dimensions, frame rate, connecting screen
    connecting.test.js   connecting phase before/after server comes up
    lobby.test.js        lobby frame content, C_HEADER title colour, key round-trips
    game.test.js         game phase entities, grid pixel checks, game_over
scripts/
  vps-setup.sh           one-time VPS provisioning (Nginx, Node.js, systemd, deploy user)
.github/workflows/
  deploy.yml             CI: test → build → browser-e2e → deploy on push to main
```
