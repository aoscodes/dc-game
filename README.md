# Slime Feast

Co-op realtime support game. Up to 6 players feed a crew of Lil Guys parked at the left edge of a slime conveyor: on a tuneable clock — sped up by every extra Lil Guy and every baby at the table — the field drifts into their mouths and they bite the front columns whole. Cast shapes (throttled by a per-player cooldown) to defuse the hazards before they reach the front — a defused cell is consumed for a point, a live one is only nibbled, filling the shared Hunger bar (the game's clock) for nothing. Score = slime consumed; clear the field before the bar fills.

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

Open `http://localhost:3000` for the station directory, or
`http://localhost:3000/game` to go straight to the game.

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

## Raspberry Pi kiosk (self-hosted)

A Pi that boots straight into the station directory: fast-forwards to the
latest `main`, builds it, starts the bridge, and opens a fullscreen Chromium
tab on `http://localhost:3000`.  Point `KIOSK_URL` at `/game` instead for a
station that should come up playing without a tap.  No nginx and no network dependency at play time —
the bridge serves `web/` and `data/` itself and spawns a game server per
lobby, so the whole stack is local.

Requires **64-bit** Raspberry Pi OS (Bookworm or later, labwc/Wayland) and a
read-only GitHub deploy key already installed for the kiosk user.

```
git clone git@github.com:aoscodes/dc-game.git
sudo bash dc-game/scripts/pi-setup.sh
sudo reboot
```

`pi-setup.sh` is re-runnable and is also how you apply a change to the boot
path.  It installs Zig 0.15.2 (pinned + checksummed), Node 22 and Chromium,
adds the kiosk user to `dialout` for the USB controllers, lays out
`/opt/slimefeast`, writes the two systemd units, hooks the browser into the
labwc session, and turns on desktop autologin with screen blanking off.

### What runs at boot

| Unit / hook                 | Does                                                     |
| --------------------------- | -------------------------------------------------------- |
| `slimefeast-update.service` | oneshot: fetch `origin/main`, build it, publish it        |
| `slimefeast-bridge.service` | the Node bridge on port 3000 (spawns a server per lobby)  |
| `~/.config/labwc/autostart` | `pi-kiosk.sh` — waits for the bridge, opens Chromium      |

The version check runs **once per boot**, never on a timer, so a deploy can
never change the game under a table of players mid-session.

### Atomic deploys

`pi-update.sh` builds each commit in its own git worktree and moves a
`current` symlink only once that build has compiled *and* its `data/*.json`
have passed `server --validate`:

```
/opt/slimefeast/
  src/                fetch-only clone
  builds/<sha>/       worktree per commit, built here
  current -> builds/<sha>     last commit that actually worked
  custom-configs/     saved /tune configs, symlinked into every build
  node_modules/       shared (serialport is native), rebuilt only on lockfile change
  zig-cache/          shared, so an update is not a cold build
```

This matters because building in place is not safe: the bridge serves
`web/game.js` off the working tree while the client/server binaries come from
`zig-out/`, so a pull that lands a new renderer and then fails to build gives
you a kiosk that looks fine and cannot play.

**`pi-update.sh` always exits 0.** No network, a force-pushed branch, a broken
commit, a full disk — every failure is logged and leaves the previous
deployment serving.  The Pi always boots into a working directory one tap
from a playable game; the journal explains why it is on the version it is on.

The boot scripts themselves are *not* self-updating (rewriting a shell script
under its own running interpreter is a hazard, and changing how the kiosk
boots deserves to be deliberate).  When a deployed commit changes
`scripts/pi-*.sh`, the update logs a nudge to re-run `pi-setup.sh`.

### Operating it

```
# what happened at boot
journalctl -u slimefeast-update -u slimefeast-bridge -f
tail -f ~/.local/state/slimefeast-kiosk.log        # the browser side

# force an update now
sudo systemctl restart slimefeast-update slimefeast-bridge

# pin to a known-good build and stop updating
sudo ln -sfn /opt/slimefeast/builds/<sha> /opt/slimefeast/current.new
sudo mv -T /opt/slimefeast/current.new /opt/slimefeast/current
sudo systemctl mask slimefeast-update
sudo systemctl restart slimefeast-bridge
```

Knobs live in `/etc/default/slimefeast` (`BRANCH`, `PORT`, `KIOSK_URL`,
`FETCH_TIMEOUT`, `KEEP_BUILDS`, `BRIDGE_WAIT`, `DISPLAY_SETUP`,
`KIOSK_STATE_DIR`).  Edit, then
restart the two units.  `DISPLAY_SETUP` is an empty shell hook for display
config once the kiosk hardware is settled, e.g.
`DISPLAY_SETUP='wlr-randr --output HDMI-A-1 --transform 90'`.
`KIOSK_STATE_DIR` is the handshake directory that arms the hold-to-exit button
(see [Closing the kiosk to the desktop](#closing-the-kiosk-to-the-desktop));
comment it out to disable the button entirely.

Tests are not run on the Pi — the `test` step needs python3 + PIL for the
sprite-atlas check and spends ~14s on the render-gate probe, and CI already
gates `main`.

## Deploy to a VPS

### One-time VPS setup

Provision an Ubuntu 24.04 x86_64 VPS (Hetzner, DigitalOcean, Vultr, etc.).

SSH in as root and run the setup script:

```
bash scripts/vps-setup.sh
```

This installs Nginx and Node.js, creates a `dragoncon` service user, writes the `dragoncon-bridge` systemd unit (the bridge spawns a game-server process per lobby), and configures Nginx to serve `web/` static files and proxy `/ws`, `/onboard-ws` and `/powerups-ws` to the bridge.

Nginx re-declares the page routes independently of the bridge, so **a new
extensionless route has to be added in both places** — the catch-all
`location /` is `try_files`-only and 404s anything without a file extension.

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

- `data/balance.json` — grid size, hunger cost per unit eaten, the realtime
  pacing (`bite_interval_ms`, `bite_speedup_per_guy_pct`,
  `bite_speedup_per_baby_pct`, `cast_cooldown_ms`, `team_window_ms`), and the
  move + group tables (a move has a `shape` and a `cost`; a group names its
  component moves by label, e.g. `"moves": ["poke","sweep"]`).
- `data/encounters.json` — encounters (the reservoir's zones and what slime
  each holds, charge pool, hunger budget) plus which encounter is the default.

The server loads both at process start (`--data-dir`, default `data/`) and
the browser fetches `data/balance.json` directly, so there is a single
source of truth — no mirrored tables.  The bridge spawns one server per
lobby, so **editing the JSON takes effect on the next lobby created; no
rebuild or bridge restart needed**.  Invalid files fail loudly at server
start with the exact field and reason; unknown fields are rejected so typos
can't silently default.  Caps enforced by the loader: 64 recipes per table,
16 zones per encounter, group components 2..6 (each an existing move label).
`server --data-dir <dir> --validate` checks a data dir and exits.

### Pages

The kiosks are touchscreens with no keyboard and no address bar, so `/` is a
**station directory**: three big buttons, one per page below.  It is what a
kiosk boots into (`KIOSK_URL` defaults to `/`) and the only way to get from
one station to another without a shell on the Pi.

| Route             | Page                                                     | Back to `/` |
| ----------------- | -------------------------------------------------------- | ----------- |
| `/`               | Station directory (`web/index.html`)                      | —           |
| `/game`           | The game (`web/game.html`)                                | no          |
| `/config/{hash}`  | The game, running a saved `/tune` config                  | no          |
| `/onboard`        | Badge colour kiosk — needs the bridge for the serial ports | yes        |
| `/powerups`       | Powerup kiosk — same                                      | yes         |
| `/tune`           | Config editor (operator tool; deliberately not on `/`)    | no          |

The game has no back control on purpose: its canvas takes clicks for casting,
so a corner button is a misfire waiting to happen mid-round.  Set
`KIOSK_URL=/game` on a Pi that should come up playing and never show the
directory; leave it at `/` on a station an operator retasks between sessions.

#### Closing the kiosk to the desktop

Chromium runs with `--kiosk`: no address bar, no tab bar, no window chrome,
and the Pi has no keyboard.  The directory page carries an **invisible button
in its top-left corner — hold it for five seconds** and the browser closes to
the desktop.  A progress ring appears once the hold starts, so it is
discoverable to whoever knows it is there and invisible to everyone else; a
visible "Quit" on a screen attendees are prodding gets pressed.

It is only on `/`, because that is the one page reachable from every station
and the one page with no gameplay to misfire into.

The switch is **armed by the `KIOSK_STATE_DIR` env var** (`pi-setup.sh` sets it
in `/etc/default/slimefeast`).  Unset — which is every non-Pi machine — and
`POST /api/kiosk/exit` 404s and the button reports that it is not enabled.
It is also refused for non-loopback callers, and nginx returns 404 for it
outright, so it does not exist on the VPS.

To get back to the kiosk, either log out and back in (labwc autostart runs
`pi-kiosk.sh`) or run it from a terminal:

```bash
~/slimefeast/scripts/pi-kiosk.sh &
```

How it stays distinguishable from a crash: the bridge writes a
`$KIOSK_STATE_DIR/kiosk-exit` flag *before* signalling the browser, and
`pi-kiosk.sh` — which otherwise relaunches a dead browser after 3s — checks for
that flag and stops instead.  A browser that dies without the flag is still a
crash, and is still healed automatically.

### /tune — in-browser config editor

Open **`/tune`** for a form with every knob: grid and costs, the bite clock
and cast cooldown,
moves and groups (add/remove, paint shapes, pick a group's component moves)
and the encounter (add/remove reservoir zones, the slime each holds, charge
pool, hunger budget).  Saving POSTs to `/api/tune/save`:

- The bridge content-addresses the config (`sha256` prefix) into
  `custom-configs/{hash}/` and validates it with `server --validate` —
  rejections show the loader's exact messages.
- On success you get a **shareable `/config/{hash}` URL**.  Opening that page
  starts a lobby running that config; players joining by room code adopt its
  balance tables automatically.
- Edit an existing config with `/tune?from={hash}`.

Saved configs are never garbage-collected (tiny JSON dirs).

## Gameplay

**Getting into a game**

Room choice lives entirely in the URL — there is no create/join screen.

| URL                 | Effect                                       |
| ------------------- | -------------------------------------------- |
| `/game`             | Start a lobby on the shipped balance tables  |
| `/config/{hash}`    | Start a lobby on that saved `/tune` config   |
| `/game?code=XXXXXX` | Join that lobby (its config wins)            |

A tab that creates a lobby rewrites its own address to include the code, so a
reload or a dropped connection rejoins the same room instead of spawning
another.  The code is shown in the top-right of the board while playing.
Hardware badges never need it — they join the newest lobby on their own.

Asking for a room that has closed is a dead end with one button, which starts
a fresh game on the same page (keeping the `/config/{hash}` setup, if any).

There is **no screen in front of the game**: the tile press lands on a live
board.  An encounter launches with the server and simply waits — the bite
timer stays disarmed until the first player takes a seat, then arms from that
moment, so nothing is lost by starting an empty room.  The same holds between
rounds: the report's one button starts the next encounter playing.

**Play (shape wheel, realtime)**

Casting is throttled by a per-player cooldown (`cast_cooldown_ms`).  A move
is picked off a **shape wheel** — the move table in file order — and cast at
the aimed square:

| Key                   | Action                                       |
| --------------------- | -------------------------------------------- |
| `1`                   | Shape wheel: next move                       |
| `2`                   | Shape wheel: previous move                   |
| `Enter`               | Cast the selected move at the cursor         |
| `← ↑ ↓ →`             | Aim the cursor                               |

Selection is **server-authoritative** and persists across casts (there is no
client-side selection state to disagree with the server), so every player's
current pick is visible to the whole team.

A cast resolves the **moment it is pressed**: it **stamps** its shape onto
the field, downgrading every covered hazard cell one tier (red → yellow →
green → defused).  Coverage off the grid edge, or on a cell with nothing left
to downgrade, is wasted; a stamp never empties a cell outright.  A press
inside the cooldown is silently dropped; a cast the pool cannot pay is
refused and costs nothing — not even the cooldown.

The Lil Guys bite on their own **clock**: every `bite_interval_ms` — sped up
by `bite_speedup_per_guy_pct` per seated Lil Guy past the first and
`bite_speedup_per_baby_pct` per baby at the table (board-brought and hatched
alike) — the field settles in three ordered steps, and the order is the
whole mechanic:

1. **Bite** — the Lil Guys stand at the **left** edge and chew the front
   `feast_columns` columns (plus `feast_columns_per_guy` per seated player)
   cell by cell.  Edible units (neutral, defused, consumable specials) are
   **consumed**; a live hazard is **nibbled** — downgraded one tier in place,
   filling hunger for no score; rocks are skipped.  Defusing the front before
   the bite lands is the point of a cast.
2. **Shift** — every row's survivors pack **left** into the space the bite
   opened: the field is a conveyor drifting into the Lil Guys' mouths.
3. **Fill** — the reservoir tops the field up from the **right** edge.

Every bite fills hunger (`hunger_cost_normal`) whether it consumed or only
nibbled, so the Hunger bar is the game's **clock**: a full bar simply calls
time on the encounter.  Nibbles are the loss that hurts — clock spent on a
cell that scored nothing.  Clearing the field before the bar fills is the win.

Casting also composes: every landed cast stays **ripe** for
`team_window_ms`, and when a **distinct** player's cast completes a
**group**'s component bag on the **same square** within that window, the
group's shape fires too, at the completing player's square.  The completer
pays the **group's** cost instead of their own — the contributors already
paid their way as they landed — and the consumed contributions leave the
window, so a cast feeds at most one group.

The encounter ends **when a bite settles**, on the first of:

| Reason | Condition |
| --- | --- |
| `field_cleared` | the field and the reservoir hold nothing playable — a win, and it beats the clock on a tie |
| `hunger_full` | the Hunger bar — the game's clock — filled |

Running the charge pool dry does **not** end the game: a broke team's casts
are refused while the bite's nibbles keep chewing the field down until the
clock or the cleared field calls it.

The final shared score and a match report are broadcast either way.

The board is **held** after the server calls it: the closing feast plays out in
full, the verdict floats over it for three seconds, and only then does the
report replace it.

## Architecture

```
shared/      pure Zig: ECS components, slime-field + recipe math, wire protocol, data-file loader
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
to the newest lobby, or waiting until one exists. Assignment is sticky by the
board's USB serial number: replugging returns it to its tab pairing, or (within
a 30s grace window) to its headless player.

### The badge ledger

Every badge plug-in, powerup grant, onboarding roll and game is recorded to
disk by `bridge/ledger.js`, under `BADGE_LOG_DIR` (default: `records/` beside
the repo; `$ROOT/records` on the Pi). Three things live there:

| file | what it is |
| --- | --- |
| `events-<stamp>.jsonl` | append-only event stream, one file per bridge run |
| `badges.json` | latest state and full connection history, per badge uid |
| `games/<gameId>.json` | one file per game: roster, final score, hatched babies |

It only ever grows — no retention, no caps — because the records *are* the
event's history. Back it up by copying the directory.

**It is deliberately write-only.** There is no read API and no query, and this
is enforced by a test. A badge's own flash is the only authority on what that
badge contains; a queryable record of what the bridge last saw would become a
second one, and the two would disagree the first time a badge was plugged into
a different machine. So the ledger observes and never answers.

Consequences of that stance, visible in the files:

- Stats the bridge assumed rather than received are flagged `statReported:
  false`; stats written by the `/api/dev` inject routes carry `source:
  "dev_inject"`. Neither is presented as something a badge said.
- Powerup counts are only ever recorded as the *badge* reported them back in
  its ack — never as this side's arithmetic.
- A uid is recorded with `uidSource`. `"serial"` is the board's flash unique
  id and identifies a badge; `"path"` is a port that a board without a serial
  number was plugged into, and the next board there inherits the name.
- A connection left open by a bridge that was killed is closed on the next run
  as `endedBy: "bridge_exit"` with `disconnectedAt: null` — the end is not
  known, so no time is invented for it. A clean shutdown records
  `"bridge_stopped"` *with* a timestamp, because that one happened at a known
  moment.

## Project layout

```
src/
  root.zig               ECS core (Austin Morlan-style, comptime)
  shared/
    shared.zig           module root
    components.zig       component types + slime tier/wheel model
    game_logic.zig       wheel cycling, group matching, hunger/score helpers
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
    session.zig          Session: lobby, turn/cast handling, feast resolution, broadcasts
    session_test.zig     in-process integration tests (no network)
    bot_harness_test.zig bot-driven session tests
  e2e/
    e2e_test.zig         Zig e2e: spawns server + 2 bots, full game loop
  debug/
    debug.zig            debug/snapshot utilities (no Raylib dependency)
bridge/
  index.js               Node bridge: spawns client, WebSocket relay, static files, /api/tune/save
  session.js             PlayerSession: one headless Zig client, its stdio protocol
  controllers.js         dc_rp2040 badges over USB serial: link, stats, palette, powerups, scores
  ledger.js              write-only record of every badge, grant and game (see above)
web/
  index.html             / station directory: big touch buttons to the pages below
  kiosk.js               the directory's hidden hold-5s exit to the desktop
  game.html              /game canvas shell (also served at /config/{hash})
  game.js                canvas renderer: connecting / game / game_over / error / full phases
  onboard.html, onboard.js    /onboard badge colour kiosk
  powerups.html, powerups.js  /powerups powerup kiosk
  tune.html, tune.js     /tune config editor
data/
  balance.json           grid, costs, recipes
  encounters.json        encounters (reservoir zones, charges, hunger budget)
custom-configs/          saved /tune configs (gitignored, content-addressed)
scripts/
  vps-setup.sh           one-time VPS provisioning (Nginx, Node.js, systemd, deploy user)
  pi-setup.sh            one-time Pi kiosk provisioning (Zig, Node, Chromium, units, autostart)
  pi-update.sh           boot-time: fast-forward to main, build, publish atomically
  pi-kiosk.sh            session: wait for the bridge, open the fullscreen tab,
                         relaunch it if it dies — unless the exit was asked for
.github/workflows/
  deploy.yml             CI: test → build → deploy on push to main
```
