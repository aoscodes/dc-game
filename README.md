# Slime Feast

Co-op round-based support game. Up to 6 players help a horde of Lil Guys devour a slime field: dispense color-matched Neutralizing Agents to purify Modified Slime before each zone is eaten, and Medicine to heal the shared Hunger bar. Score = neutral slime consumed.

Authoritative Zig server. Browser canvas renderer. Zig headless client ↔ Node bridge ↔ browser.

## Requirements

- Zig 0.15.2
- Node.js 18+ (for the bridge)

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

| Command                 | Output                                                     |
| ----------------------- | ---------------------------------------------------------- |
| `zig build`             | Headless client binary (`zig-out/bin/client`)              |
| `zig build run`         | Build client + start Node bridge (opens on port 3000)      |
| `zig build server`      | Game server (`zig-out/bin/server`)                         |
| `zig build run-server`  | Build + run server (listens on port 9001)                  |
| `zig build test`        | Unit + integration tests                                   |
| `zig build e2e`         | Zig e2e test: spawn server + 2 bot clients, full game loop |

## Deploy to a VPS

### One-time VPS setup

Provision an Ubuntu 24.04 x86_64 VPS (Hetzner, DigitalOcean, Vultr, etc.).

SSH in as root and run the setup script:

```
bash scripts/vps-setup.sh
```

This installs Nginx and Node.js, creates a `dragoncon` service user, writes the `dragoncon-bridge` systemd unit (the bridge spawns a game-server process per lobby), and configures Nginx to serve `web/` static files and proxy `/ws` to the bridge.

After the script:

1. **Add the deploy SSH key** — generate an ED25519 keypair:

   ```
   ssh-keygen -t ed25519 -f deploy_key
   cat deploy_key.pub >> /home/deploy/.ssh/authorized_keys   # on VPS
   chmod 600 /home/deploy/.ssh/authorized_keys               # on VPS
   ```

2. **Add GitHub Actions secrets** in your repo settings:

   | Secret        | Value                                  |
   | ------------- | -------------------------------------- |
   | `VPS_HOST`    | VPS IPv4 address                       |
   | `VPS_USER`    | `root`                                 |
   | `VPS_SSH_KEY` | Contents of `deploy_key` (private key) |

### CI/CD

`.github/workflows/deploy.yml` runs on every push to `main`:

1. `zig build test` — deploy aborts if it fails
2. Builds `zig-out/bin/server` (`-Doptimize=ReleaseSafe`)
3. Builds `zig-out/bin/client` (`-Doptimize=ReleaseSafe`) and bundles it with `bridge/` + `data/`
4. SCPs server binary → VPS (no restart; new lobbies spawn the new binary)
5. SCPs client binary + bridge + game data → VPS, restarts `dragoncon-bridge.service`
6. SCPs `web/` static files + `data/` → `/var/www/dragoncon/`

Path filters skip jobs when unrelated files change (e.g. only `web/` changed → only `deploy-web` runs).

### TLS (HTTPS / WSS)

The bridge WebSocket is `ws://` by default. After DNS is pointed at the VPS and Nginx is running:

```
certbot --nginx -d <your-domain>
```

Certbot adds `listen 443 ssl` and sets up auto-renew. `game.js` derives the WebSocket URL from `location.host`, so `wss://` is used automatically when the page is served over HTTPS.

Until you have a domain, the game is playable over plain `http://`.

### Balance / encounter tuning (data files — no rebuild)

All designer-tunable data lives in two JSON files:

- `data/balance.json` — conversion rates, hunger costs, casts per turn, and the
  move + group tables (a move has a `shape` and a `cost`; a group names its
  component moves by label, e.g. `"moves": ["poke","sweep"]`).
- `data/encounters.json` — encounters (zones, slime amounts per color,
  hunger budget) plus which encounter is the default.

The server loads both at process start (`--data-dir`, default `data/`) and
the browser fetches `data/balance.json` directly, so there is a single
source of truth — no mirrored tables.  The bridge spawns one server per
lobby, so **editing the JSON takes effect on the next lobby created; no
rebuild or bridge restart needed**.  Invalid files fail loudly at server
start with the exact field and reason; unknown fields are rejected so typos
can't silently default.  Caps enforced by the loader: 64 recipes per table,
16 zones per encounter, group components 2..6 (each an existing move label).
`server --data-dir <dir> --validate` checks a data dir and exits.

### /tune — in-browser config editor

Open **`/tune`** for a form with every knob: rates/costs, casts per round,
round duration, moves and groups (add/remove, paint shapes, pick a group's
component moves) and the encounter (add/remove rounds,
per-color slime, hunger budget).  Saving POSTs to `/api/tune/save`:

- The bridge content-addresses the config (`sha256` prefix) into
  `custom-configs/{hash}/` and validates it with `server --validate` —
  rejections show the loader's exact messages.
- On success you get a **shareable `/config/{hash}` URL**.  Creating a lobby
  from that page runs the game with that config; players joining by room
  code adopt its balance tables automatically.
- Edit an existing config with `/tune?from={hash}`.

Saved configs are never garbage-collected (tiny JSON dirs).

## Gameplay

**Lobby**

| Key     | Action       |
| ------- | ------------ |
| `Enter` | Toggle ready |

**Turns (shape wheel)**

Each player has a fixed budget of casts per turn.  A move is picked off a
**shape wheel** — the move table in file order — and cast at the aimed square:

| Key                   | Action                                       |
| --------------------- | -------------------------------------------- |
| `1`                   | Shape wheel: next move                       |
| `2`                   | Shape wheel: previous move                   |
| `Enter`               | Cast the selected move at the cursor         |
| `← ↑ ↓ →`             | Aim the cursor                               |

Selection is **server-authoritative** and persists across casts and turns
(there is no client-side selection state to disagree with the server), so
every player's current pick is visible to the whole team.

At round end the current zone is consumed in its entirety:

- Matching-color agent units neutralize Modified Slime (`min(agents, slime)`;
  excess and wrong-color agents are wasted).
- Every unit costs normal hunger; un-neutralized modified units cost extra
  hunger, and only that extra portion is healable by Medicine.
- Score += neutralized + naturally-neutral units.

Casting also composes: when 2+ **distinct** players cast a **group**'s
component moves on the **same square** within one turn, the group fires at the
completing player's square, for the group's cost, and consumes its whole bag —
contributors included, so a grouped cast is not also billed as a solo move.

The encounter ends when all zones are consumed or the Hunger bar fills; the
final shared score is broadcast either way.

## Architecture

```
shared/      pure Zig: ECS components, recipe/zone resolution math, wire protocol, data-file loader
client/      headless Zig stdio binary — game logic + UI state, no window/GPU
server/      authoritative game loop, lobby state machine, round resolution, broadcasts
bridge/      Node.js: spawns client, owns both WebSocket connections, serves web/ + data/
web/         static HTML + JS canvas renderer (no build step)
data/        designer-tunable JSON: balance + recipes + encounters
e2e/         Zig bot e2e (src/e2e/)
```

All game logic runs on the server. Clients send inputs only (`JoinLobby`, `ReadyUp`, `MoveCursor`, `CycleShape`, `Cast`, `Reconnect`). The server broadcasts `LobbyUpdate`, `GameState` snapshots (each entity carries its `selected_shape`), `RoundReset`, `ActionResult`, `GameOver` (final score).

Wire protocol is binary, little-endian, no allocations on the hot path. See `src/shared/protocol.zig`.

Stdio protocol between client and bridge:

| Direction              | Format                             | Meaning                               |
| ---------------------- | ---------------------------------- | ------------------------------------- |
| bridge → client stdin  | `WIRE:<hex>\n`                     | Raw server message bytes, hex-encoded |
| bridge → client stdin  | `KEY:<name>\n`                     | Browser `KeyboardEvent.key` value     |
| bridge → client stdin  | `NAME:<name>\n`                    | Display name for JoinLobby (default "Player") |
| bridge → client stdin  | `READY\n`                          | Server WebSocket connected; send join |
| client stdout → bridge | `{"tag":"render",...}\n`           | Full UI snapshot for the browser      |
| client stdout → bridge | `{"tag":"send","bytes":"<hex>"}\n` | Forward bytes to server               |

### Hardware controllers

The bridge also discovers dc_rp2040 boards over USB serial
(`bridge/controllers.js`). Buttons map to the same `KEY:` path (d-pad = aim
arrows, A=`1` wheel forward, B=`2` wheel back, C=`Enter` cast/ready,
D=`Escape`) and the selected move's label is mirrored back to the board's
e-paper via `FB:SHAPE`.

Hybrid player model: a linked board first pairs with the oldest started tab
session lacking a controller (it drives that tab's player); when no tab is
free it becomes its own player — a headless Zig client named `Board-N` joined
to the active lobby (C toggles ready). Assignment is sticky by the board's
USB serial number: replugging returns it to its tab pairing, or (within a 30s
grace window) to its headless player.

## Project layout

```
src/
  root.zig               ECS core (Austin Morlan-style, comptime)
  shared/
    shared.zig           module root
    components.zig       component types + wheel/zone/agent model
    game_logic.zig       wheel cycling, group matching, zone/hunger resolution
    balance.zig          balance/recipe types (values in data/balance.json)
    config.zig           data-file loader: JSON parse + validation
    fixtures.zig         frozen fixture config for tests
    protocol.zig         binary wire protocol + round-trip tests
    transport.zig        abstract Transport interface
    encounter.zig        encounter types (values in data/encounters.json)
    bots.zig             bot profiles/teams for the test harness
  client/
    main.zig             entry point, ClientState, stdin reader, game loop
    stdout_writer.zig    JSON render/send frame serialiser
    input.zig            key name → cursor step / wheel turn / cast
  server/
    main.zig             server entry point
    session.zig          Session: lobby, round timer, zone resolution, broadcasts
    session_test.zig     in-process integration tests (no network)
    bot_harness_test.zig bot-driven session tests
  e2e/
    e2e_test.zig         Zig e2e: spawns server + 2 bots, full game loop
  debug/
    debug.zig            debug/snapshot utilities (no Raylib dependency)
bridge/
  index.js               Node bridge: spawns client, WebSocket relay, static files, /api/tune/save
web/
  index.html             canvas shell (also served at /config/{hash})
  game.js                canvas renderer: connecting / lobby / game / game_over phases
  tune.html, tune.js     /tune config editor
data/
  balance.json           rates, costs, recipes
  encounters.json        encounters (zones per round, hunger budget)
custom-configs/          saved /tune configs (gitignored, content-addressed)
scripts/
  vps-setup.sh           one-time VPS provisioning (Nginx, Node.js, systemd, deploy user)
.github/workflows/
  deploy.yml             CI: test → build → deploy on push to main
```
