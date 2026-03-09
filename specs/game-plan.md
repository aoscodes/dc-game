# Co-op JRPG Browser Game — Spec

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  shared/        ← Zig library (game logic, ECS components)  │
├─────────────────┬───────────────────────────────────────────┤
│  client/        │  server/                                  │
│  Zig + raylib   │  Zig + websocket.zig                      │
│  → WASM via     │  → native binary                          │
│    Emscripten   │                                           │
│  WS via extern  │  Authoritative game loop                  │
│  JS bindings    │  Broadcasts state snapshots               │
└─────────────────┴───────────────────────────────────────────┘
```

## Repository Layout

```
ecs-zig/
├── build.zig                  ← updated for 3 targets
├── build.zig.zon              ← add emsdk + websocket.zig deps
├── src/
│   ├── root.zig               ← ECS core (unchanged)
│   ├── shared/
│   │   ├── components.zig     ← all component types
│   │   ├── game_logic.zig     ← ATB, combat math, grid rules
│   │   ├── waves.zig          ← scripted enemy wave definitions
│   │   └── protocol.zig       ← message types (client↔server)
│   ├── client/
│   │   ├── main.zig           ← client entry point
│   │   ├── render.zig         ← raylib draw systems
│   │   ├── input.zig          ← keyboard input system
│   │   └── net/
│   │       ├── transport.zig  ← abstract Transport interface
│   │       └── ws_browser.zig ← extern JS WebSocket impl
│   └── server/
│       ├── main.zig           ← server entry point
│       ├── session.zig        ← lobby + room management
│       └── net/
│           ├── transport.zig  ← same abstract interface
│           └── ws_server.zig  ← websocket.zig impl
└── web/
    ├── index.html
    └── ws_glue.js             ← JS WebSocket bridge for WASM
```

## Constraints

- ECS architecture: all game state lives in components; all behavior in systems
- No `anytype` escape hatches in game logic; all component types registered at comptime
- Binary wire protocol; no allocations on the hot path
- Raylib for rendering; Emscripten as WASM toolchain
- websocket.zig (karlseguin) for server-side WS; thin extern bindings on client
- Transport is an abstract interface — never import a concrete WS type from game logic

---

## M1 — Shared: Components, Waves, Protocol `(L)`

### Components (`src/shared/components.zig`)

```zig
GridPos     { col: u2, row: u2 }            // 3 cols (0-2), 4 rows (0-3)
Health      { current: u16, max: u16 }
Speed       { gauge: f32, rate: f32 }       // ATB; gauge ticks 0→1 at rate/sec
Class       { tag: enum { fighter, mage, healer, grunt, archer, shaman, boss } }
Team        { id: u8 }                      // 0=players, 1=enemies
ActionState { tag: enum { idle, charging, acting, defending } }
Owner       { player_id: u8 }              // which client controls this char
Stats       { attack: u16, defense: u16, speed_base: f32, max_hp: u16 }
ActiveEffect{ tag: enum { mitigation }, duration: f32, magnitude: f32 }
```

### Wave Scripts (`src/shared/waves.zig`)

```zig
const SpawnEntry = struct {
    class: ClassTag,
    grid_col: u2,
    grid_row: u2,
    stats: StatOverride,  // optional per-entry stat tuning
};
const Wave = struct {
    label: []const u8,
    entries: []const SpawnEntry,
    next_wave: ?[]const u8,  // null = final wave
};
```

Shipped wave scripts (all comptime constants):

| Label | Description |
|---|---|
| `wave_01_basic` | 3 grunts, front rank only |
| `wave_02_spread` | grunts + archers across all 3 rows |
| `wave_03_healer_back` | shaman (healer) in back, grunts shielding |
| `wave_04_all_mages` | 4 archers, AoE-heavy stress test |
| `wave_05_boss_plus_grunts` | 1 boss (high HP/def) + 2 grunts flanking |
| `wave_06_full_grid` | 6 enemies, full 3×4 spread |

### Protocol (`src/shared/protocol.zig`)

1-byte tag prefix + packed fields. No heap on hot path.

```zig
pub const MsgTag = enum(u8) {
    // Client → Server
    join_lobby      = 0x01,
    choose_class    = 0x02,
    ready_up        = 0x03,
    choose_action   = 0x04,
    reconnect       = 0x05,

    // Server → Client
    lobby_update    = 0x10,
    game_start      = 0x11,
    game_state      = 0x12,  // full snapshot each tick or on change
    action_result   = 0x13,
    your_turn       = 0x14,  // notifies owning client when ATB gauge fills
    game_over       = 0x15,
};
```

`game_state` snapshot: per living entity, pack
`(entity_id u32, grid_col u2, grid_row u2, hp_current u16, hp_max u16,
  atb_gauge f32, action_state u8, class u8, team u8)` — fixed-size record.

### Reconnect Protocol

- First connect: server assigns `player_id: u8`, echoes in `lobby_update`
- Client persists `player_id` in JS `sessionStorage`
- Reconnect: client sends `reconnect { player_id }` first
- Server: matching slot → restore connection + send current `game_state` snapshot
- Session ended → send `game_over`

---

## M2 — Transport Abstraction `(S)`

`src/client/net/transport.zig` and `src/server/net/transport.zig` (identical interface).

```zig
pub const Transport = struct {
    send_fn: *const fn (ctx: *anyopaque, msg: []const u8) anyerror!void,
    ctx: *anyopaque,

    pub fn send(self: Transport, msg: []const u8) !void {
        return self.send_fn(self.ctx, msg);
    }
};
```

Game logic receives a `Transport`; never imports `ws_browser` or `ws_server` directly.

---

## M3 — Server: Lobby + Class Selection + Session `(M)`

`src/server/main.zig` + `src/server/session.zig`

- Listen on configurable port (env var or CLI flag)
- On connect: assign `player_id`, add to lobby, broadcast `lobby_update`
- 6-char alphanumeric join code per session
- Lobby phase: clients send `choose_class` → server records, re-broadcasts `lobby_update`
- `ready_up` from all connected players → `game_start` → instantiate game world + spawn first wave
- Session state machine: `lobby → playing → ended`
- Up to 6 players; session persists on disconnect (slot held open for reconnect)

---

## M4 — Server: Game Loop `(L)`

`src/server/session.zig`

### ATB System (server tick: 20 Hz)

- Each tick: for every character, `gauge += rate * dt`
- `gauge >= 1.0` → set `ActionState.charging`, send `your_turn` to owning client
- `choose_action` received: validate (correct player? valid target?), resolve, broadcast `game_state`

### Combat Rules

| Class | Attack | Defend |
|---|---|---|
| Fighter | Single target; `dmg = max(1, atk - def)` | Apply `mitigation` to 1×3 projection: same col, rows `row+1..row+3` |
| Mage | AoE 2×2 on enemy grid (clamped), each target takes full damage | Self-mitigation |
| Healer | AoE 2×2 on player grid, restore `heal = atk` HP each | Self-mitigation |

Mitigation: reduce incoming damage by 30% (const, tunable).

### Enemy AI (server-side system)

- When ATB full: attack front-rank player preferentially (random among front rank; fallback to any living player)
- Shaman: heal lowest-HP ally instead if any ally below 50% HP

### Win Condition

- All enemies dead → `game_over { winner: .players }`, load `next_wave` or end
- All players dead → `game_over { winner: .enemies }`

---

## M5 — Build System `(M)`

### New deps (`build.zig.zon`)

```
zig fetch --save=emsdk      git+https://github.com/emscripten-core/emsdk#4.0.9
zig fetch --save=websocket  git+https://github.com/karlseguin/websocket.zig#master
```

### Three build targets (`build.zig`)

1. `zig build` → native desktop client (dev/testing, raylib window)
2. `zig build -Dtarget=wasm32-emscripten` → `zig-out/web/` (browser client)
3. `zig build server` → native server binary

Branch on `target.query.os_tag == .emscripten`: use `addLibrary` + `emccStep` for WASM; `addExecutable` for desktop/server.

---

## M6 — Client: WebSocket Bridge `(S)`

`src/client/net/ws_browser.zig` + `web/ws_glue.js`

Zig extern declarations (~30 lines):
```zig
extern "env" fn ws_connect(url_ptr: [*]const u8, url_len: usize) i32;
extern "env" fn ws_send(handle: i32, data_ptr: [*]const u8, data_len: usize) void;
extern "env" fn ws_close(handle: i32) void;

export fn on_ws_message(handle: i32, ptr: [*]const u8, len: usize) void { ... }
export fn on_ws_open(handle: i32) void { ... }
export fn on_ws_close(handle: i32) void { ... }
```

JS glue (~50 lines): manages handle→WebSocket map, copies messages into WASM linear memory, calls exported callbacks. Wraps into a `Transport` (M2).

---

## M7 — Client: Rendering `(L)`

`src/client/render.zig` — raylib draw systems.

### Scenes

**LobbyScene:**
- List of connected players (name, class choice, ready state)
- Join code display
- Class picker (fighter / mage / healer)
- Ready button

**GameScene:**
- Two 3×4 grids side by side (player left, enemy right)
- Each cell: colored rect (class color), HP bar, ATB gauge bar
- Action menu: appears when `ActionState.charging` for this client's character
  - Select attack or defend
  - Targeting cursor (keyboard nav) on enemy grid (attack) or player grid (healer)
- Mitigation indicator on defended cells

All visuals: colored rectangles + text. No sprites in initial build.

---

## M8 — Client: Input `(M)`

`src/client/input.zig`

- Arrow keys: move targeting cursor
- Z / Enter: confirm action
- X / Escape: cancel / back
- 1/2: select attack vs defend in action menu
- Input only processed when server signals `your_turn` for this client's character
- Produces `ChooseAction` message → sent via Transport

---

## M9 — Integration + Web Shell `(M)`

`web/index.html`

- Loads Emscripten `.js` + `.wasm`
- Injects `ws_glue.js` into WASM import object
- Client connects to server on load → enters lobby
- Full loop: lobby → class select → ready → game → game over → lobby

---

## Deliverables (ordered)

| # | Milestone | Effort | Depends on |
|---|---|---|---|
| M1 | Shared: components + waves + protocol | L | — |
| M2 | Transport abstraction | S | M1 |
| M5 | Build system (WASM + server targets) | M | M1 |
| M3 | Server: lobby + class select + session | M | M2 |
| M4 | Server: game loop (ATB, combat, AI, waves) | L | M3 |
| M6 | Client: WS bridge | S | M2 |
| M7 | Client: rendering | L | M6 |
| M8 | Client: input | M | M6 |
| M9 | Integration + web shell | M | M4, M7, M8 |

**Total estimate**: XL (2–4 weeks solo; parallelizable across 3 agents)

## Agent Split

| Agent | Owns |
|---|---|
| Agent A (shared + build) | M1, M2, M5 |
| Agent B (server) | M3, M4 — after M1/M2 |
| Agent C (client) | M6, M7, M8 — after M1/M2/M5 |
| Sequential | M9 — integrates all three |
