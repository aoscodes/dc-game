# Sprite Animation Implementation Guide

Step-by-step guide for adding 2D sprite animation with multi-cell enemy support.
No server changes. No protocol changes. Three files touched.

---

## Overview

```
Files changed:
  src/client/stdout_writer.zig   — forward action_result events in render JSON
  src/client/main.zig            — buffer action_result messages for the writer
  web/game.js                    — RAF loop, anim state machine, multi-cell draw
```

Constraints:

- Player entities: always 1×1 cell
- Enemy entities: size per class, client-side lookup, top-left anchor
- Placeholder colored frames only (no PNG assets)
- 4 clips: idle, attack, hurt, die
- Die clip: clean vanish on completion, non-blocking
- Animation state: client-inferred from `action_result` events

### How the pieces fit together

The game has two separate tick rates: the **server** runs at 20 Hz and is the
authoritative source of game state. The **browser** will soon run at 60 Hz
(or whatever the monitor's refresh rate is) and is purely cosmetic. These two
rates are deliberately decoupled — the browser renders as smoothly as the
hardware allows, interpolating and animating between server state updates.

The server already broadcasts `action_result` messages (e.g. "entity 7 dealt 45
damage to entity 12", "entity 12 died") but the Zig client currently decodes and
discards them. This guide plumbs those events through to the browser, then builds
an animation state machine in JavaScript that reacts to them.

```
Server (20 Hz)
  └─ broadcasts game_state + action_result messages over WebSocket
       └─ Zig client stdin_reader thread decodes them
            ├─ game_state  → updates g_state.game.snapshot (already done)
            └─ action_result → NEW: buffered in g_state.game.pending_results
                 └─ render loop (60 Hz):
                      └─ write_render() emits JSON including "action_results":[...]
                           └─ bridge → browser
                                └─ game.js processActionResults() → triggerClip()
                                     └─ advanceAnimations(dt) → drawEntity()
```

---

## Step 1 — Add result buffer to `GameState` in `stdout_writer.zig`

### Why

`GameState` in `stdout_writer.zig` is the struct that holds everything the Zig
client needs to emit one render frame. It currently holds the latest server
snapshot (entities, HP, ATB, etc.) plus some client-side UI state (cursor,
targeting, wave label).

We need to add a place to accumulate `action_result` events between render ticks.
The render loop runs at 60 Hz; the server sends events at 20 Hz. Multiple events
can arrive between renders, so we need a small buffer — not a single slot.

We use a fixed-size array of 8 rather than a dynamic list for two reasons:

1. No allocation needed — `GameState` is stack-allocated.
2. If more than 8 events arrive in one render window (extremely unlikely at 20 Hz
   server rate), dropping the excess is acceptable because these are cosmetic.

The buffer is a simple append-only array drained atomically once per render tick
— not a ring buffer. This means if it fills, new events are dropped rather than
overwriting old ones. Old events are preferable to new ones here because the
oldest event in the window is the one that causally explains the state change the
player is about to see.

### What

**File:** `src/client/stdout_writer.zig`

Locate `GameState` (line 68). Add two fields:

```zig
pub const GameState = struct {
    // ... existing fields ...
    pending_results: [8]proto.ActionResult = [_]proto.ActionResult{
        .{ .tag = .damage, .actor_entity = 0, .target_entity = 0, .value = 0 }
    } ** 8,
    pending_result_count: u8 = 0,
};
```

---

## Step 2 — Emit `action_results` in `stdout_writer.zig`

### Why

The serialisation in `stdout_writer.zig` uses typed structs and
`std.json.Stringify` — there is no manual JSON string building. The pattern for
adding a new field to the output is always the same three-part move:

1. Define a `Json*` struct that represents the shape you want in the output.
2. Add a field of that type to the appropriate parent `Json*` struct.
3. Populate the field from `GameState` in `write_render_inner` alongside the
   existing population of `entities_buf`.

`std.json.Stringify` then handles all quoting, commas, and escaping
automatically when it serialises the top-level `JsonRenderFrame`.

After emitting, the buffer must be cleared so the same events aren't re-emitted
next frame. Because `write_render_inner` takes `*const GameState`, the clear
cannot happen inside it. Instead, clear `pending_result_count` in `main.zig`
immediately after `out.write_render(...)` returns — this keeps `stdout_writer`
const-correct and the clear is still guaranteed to happen exactly once per
render tick.

### What

**File:** `src/client/stdout_writer.zig`

**1.** Add a `JsonActionResult` struct near the other `Json*` types at the
bottom of the file (after `JsonEntity`):

```zig
const JsonActionResult = struct {
    tag: proto.ActionResultTag,
    actor: u32,
    target: u32,
    value: u16,
};
```

**2.** Add an `action_results` field to `JsonGame` (line 197):

```zig
const JsonGame = struct {
    // ... existing fields ...
    action_results: []const JsonActionResult,
};
```

**3.** In `write_render_inner` (line 79), add a results buffer alongside the
existing `entities_buf` declaration and populate it:

```zig
var results_buf: [8]JsonActionResult = undefined;
for (0..game.pending_result_count) |i| {
    const res = game.pending_results[i];
    results_buf[i] = .{
        .tag = res.tag,
        .actor = res.actor_entity,
        .target = res.target_entity,
        .value = res.value,
    };
}
```

**4.** Wire `results_buf` into the `JsonGame` initialiser alongside `entities`:

```zig
.action_results = results_buf[0..game.pending_result_count],
```

**File:** `src/client/main.zig`

**5.** Clear the buffer after `out.write_render` returns (line 407):

```zig
out.write_render(g_state.phase, &g_state.lobby, &g_state.game);
g_state.game.pending_result_count = 0;  // consume events once per render tick
```

No signature changes needed anywhere.

---

## Step 3 — Buffer `action_result` messages in `main.zig`

### Why

`process_recv` in `main.zig` is the central dispatch point for all inbound
server messages. It runs every render tick, draining the `recv_queue` that the
`stdin_reader` thread fills.

The `action_result` branch currently decodes and throws away the result:

```zig
.action_result => {
    _ = proto.decode_action_result(r) catch continue;
},
```

This is where the Zig client knew about damage/death events but had nowhere to
put them. We now have a buffer (Step 1), so we push each decoded result into it.

The saturation-drop on overflow (rather than ring-buffer overwrite) is
intentional: if somehow 9+ events arrive between renders, the first 8 are the
most historically relevant. In practice at 20 Hz server / 60 Hz render, you'd
need 9 actions to resolve in a single 50ms server tick, which is impossible given
that each action consumes a full ATB charge.

### What

**File:** `src/client/main.zig`

Locate the `action_result` branch in `process_recv` (line 247):

```zig
.action_result => {
    _ = proto.decode_action_result(r) catch continue;
},
```

Replace with:

```zig
.action_result => {
    const res = proto.decode_action_result(r) catch continue;
    const gs = &g_state.game;
    if (gs.pending_result_count < gs.pending_results.len) {
        gs.pending_results[gs.pending_result_count] = res;
        gs.pending_result_count += 1;
    }
    // If full, drop — these are cosmetic events.
},
```

---

## Step 4 — Switch to a `requestAnimationFrame` loop in `game.js`

### Why

Currently `game.js` renders exactly once per WebSocket message:

```js
ws.addEventListener("message", ...) → renderFrame(msg)
```

This has two problems for animation:

1. **No delta time.** The animation clock needs to know how much wall-clock time
   has passed since the last frame so it can advance frames at the correct rate
   (e.g. "advance one frame every 83ms for 12fps"). Without a real timer, all
   animation would be frame-count based and speed up or slow down with network
   jitter.

2. **Wrong cadence.** Server messages arrive at 20 Hz. Animations need to draw
   at 60 Hz (or whatever the monitor supports) to look smooth. If we only render
   on messages, dying entities freeze between server ticks.

`requestAnimationFrame` (RAF) is the browser's mechanism for running a callback
at the display's refresh rate, synchronized to the vsync signal. It's the
correct tool for any continuous animation loop. The callback receives a
high-resolution timestamp (`now`, in milliseconds), which lets us compute
`dt = now - lastFrameTime` — the exact elapsed time since the previous draw.

The pattern is:

- WS message handler stores the latest game state but doesn't render.
- RAF loop runs at ~60 Hz, reads the latest stored state, advances animations
  by `dt`, then draws.

This decouples the render rate from the network rate cleanly. When no new
server message has arrived since the last frame, the browser re-renders the same
game state with animations advanced — this is what makes dying entities continue
their clip even between server ticks.

### What

**File:** `web/game.js`

At the bottom of the file, find the WebSocket `message` listener:

```js
ws.addEventListener("message", (ev) => {
  let msg;
  try {
    msg = JSON.parse(ev.data);
  } catch {
    return;
  }
  if (msg.tag === "render") renderFrame(msg);
  else if (msg.tag === "full") drawFull();
});
```

Change to store the latest message instead of rendering immediately:

```js
let latestMsg = null;

ws.addEventListener("message", (ev) => {
  let msg;
  try {
    msg = JSON.parse(ev.data);
  } catch {
    return;
  }
  if (msg.tag === "render") latestMsg = msg;
  else if (msg.tag === "full") drawFull();
});
```

Replace the `connect()` call at the bottom with a RAF loop that wraps it:

```js
let lastFrameTime = performance.now();

function gameLoop(now) {
  const dt = now - lastFrameTime;
  lastFrameTime = now;
  if (latestMsg) renderFrame(latestMsg, dt);
  requestAnimationFrame(gameLoop);
}

connect();
requestAnimationFrame(gameLoop);
```

Update `renderFrame` to accept and thread `dt` through:

```js
function renderFrame(msg, dt = 0) {
  switch (msg.phase) {
    case "connecting":
      drawConnecting();
      break;
    case "lobby":
      drawLobby(msg.lobby);
      break;
    case "game":
      drawGame(msg.game, dt);
      break;
    case "game_over":
      drawGameOver();
      break;
    default:
      drawConnecting();
  }
}
```

---

## Step 5 — Add constants and class size table

### Why

Three groups of constants are needed:

**`CLASS_SIZE`** maps a class name to `[cols_wide, rows_tall]`. This is the
single source of truth for visual entity size. It lives client-side because the
server has no concept of sprite size — it tracks only a single `(col, row)`
anchor per entity. A boss at `(col=0, row=0)` with size `[2,2]` visually covers
cells `(0,0)`, `(1,0)`, `(0,1)`, `(1,1)`, but the server only knows `(0,0)`.
The client infers the rest from this table.

**`CLIPS`** defines the animation parameters for each clip: how many frames it
has, what FPS it runs at, and whether it loops. These numbers govern the timing
logic in `advanceAnim`. With placeholder frames there are no actual images, so
`frames` just determines how many distinct "states" the color indicator cycles
through.

**`CLIP_TINT`** maps each clip to an RGBA color that gets overlaid on the base
class-colored rect when that clip is active. `null` for idle means no overlay —
the entity just shows its class color normally. This is the entire placeholder
"animation" effect: a tinted flash on top of the existing rect. When real sprites
arrive, this overlay approach gets replaced by `drawImage` entirely.

### What

**File:** `web/game.js`

Add near the top, after the existing constants:

```js
// Size in grid cells [cols_wide, rows_tall].
// Players are always 1x1; only enemies may be multi-cell.
const CLASS_SIZE = {
  fighter: [1, 1],
  mage: [1, 1],
  healer: [1, 1],
  grunt: [1, 1],
  archer: [1, 1],
  shaman: [1, 1],
  boss: [2, 2],
};

// Clip definitions. Placeholder rendering uses tinted rect overlays.
const CLIPS = {
  idle: { frames: 4, fps: 6, loop: true },
  attack: { frames: 4, fps: 12, loop: false },
  hurt: { frames: 3, fps: 10, loop: false },
  die: { frames: 6, fps: 8, loop: false },
};

// Tint overlaid on the base classColor rect for non-idle clips.
// null means no overlay (idle shows the base rect only).
const CLIP_TINT = {
  idle: null,
  attack: "rgba(255,200,50,0.45)",
  hurt: "rgba(255,40,40,0.55)",
  die: "rgba(80,80,80,0.70)",
};
```

---

## Step 6 — Add animation state maps

### Why

Two `Map` objects serve as the runtime state of the animation system:

**`animStates`** is the primary store: `entityId → AnimState` for every entity
currently in the server snapshot. An `AnimState` tracks which clip is playing,
which frame we're on, how many milliseconds have elapsed on the current frame,
and whether a non-looping clip has finished. Entities are added to this map on
first appearance and removed when they leave the snapshot — with one exception.

**`dyingEntities`** is the exception. When an entity dies, it immediately
disappears from the server snapshot (the server calls `destroy_entity` and stops
broadcasting it). But the die clip needs to keep playing for ~750ms after the
entity is gone. We can't keep the entity in `animStates` because the cleanup
logic removes entries not present in the current snapshot. Instead, when we
trigger a die clip we move the entity's state — and a copy of its last known
pixel rect and class — into `dyingEntities`. The draw loop reads both maps:
`animStates` for live entities, `dyingEntities` for finishing-die entities.
When the die clip finishes, the entry is deleted from `dyingEntities` and the
entity is gone for good.

Storing the pixel rect in `dyingEntities` is necessary because once an entity
leaves the snapshot, there's no longer an `(e.col, e.row, e.class)` to recompute
it from. The rect must be captured at the moment of death.

### What

**File:** `web/game.js`

Add after the constants from Step 5:

```js
// entityId (number) -> AnimState for live entities.
// AnimState: { clip: string, frame: number, elapsed: number, done: boolean }
const animStates = new Map();

// entityId -> { anim: AnimState, r: Rect, cls: string }
// Entities removed from snapshot but still playing their die clip.
// Rect: { x, y, w, h }
const dyingEntities = new Map();
```

---

## Step 7 — Add helper functions

### Why (per function)

**`entityPixelRect`** converts an entity's logical grid position `(col, row)`
and class (for size) into a pixel rectangle on the canvas. This computation
appears in multiple places (drawing, hit-testing for death), so centralising it
avoids drift. The multi-cell width formula is:
`cw * CELL_W + (cw-1) * CELL_PAD` — this accounts for the padding between cells
that would have separated them if they were individual cells.

**`coveredCells`** builds a `Set<"col,row">` of every grid cell occupied by any
entity, expanding multi-cell entities across their full footprint. This is used
in the grid background draw pass to skip drawing the empty-cell rect under a
multi-cell entity — without this, the grey empty-cell background would show
through the top-left cell while the entity's visual extends into adjacent cells
that were "skipped" from the background pass.

**`advanceAnim`** is the core timer. It accumulates `dt` on `anim.elapsed` and
advances `anim.frame` each time a full frame duration (`1000 / fps` ms) has
elapsed. Subtracting `frameDur` rather than resetting to zero is important: it
preserves any "overshoot" into the next frame, keeping the animation correctly
timed even when `dt` is irregular (e.g. the browser was briefly throttled). For
non-looping clips, it clamps at the last frame and sets `done = true`. Returns
`true` when a non-looping clip just completed — callers use this as a signal.

**`advanceAnimations`** orchestrates the per-frame advance for all entities.
It also handles two bookkeeping concerns:

- **Lazy init**: if a live entity has no `AnimState` yet (first time we've seen
  it), create one with `clip: "idle"`.
- **Garbage collection**: entities that have left the snapshot (no longer in
  `liveIds`) are removed from `animStates`. This prevents unbounded map growth
  across waves.
- **Die clip handoff**: die clips are in `dyingEntities`, not `animStates`, so
  the loop does not try to advance them here — they're advanced in the second
  loop that iterates `dyingEntities`.

**`triggerClip`** is the only way to start a new clip on an entity. It always
resets `frame`, `elapsed`, and `done` to zero/false so the clip starts cleanly
regardless of what was playing before. The die clip is special: it calls
`dyingEntities.set` and `animStates.delete` atomically so the entity transitions
to dying state in a single call. All other clips just mutate the existing
`AnimState` in place via `Object.assign`.

**`processActionResults`** maps server combat events to clip triggers. The
mapping is:

- Any actor in a result → `"attack"` clip. (The actor did something.)
- `"damage"` on target → `"hurt"` clip. (The target took a hit.)
- `"death"` on target → `"die"` clip. (The target is being removed.)

The function takes two callback arguments (`pixelRectForId`, `classForId`) rather
than direct access to the entity array because it needs to look up data for
entities that may be about to disappear — passing callbacks keeps it decoupled
from the draw loop's local variables.

**`drawEntity`** is a unified draw function for both live and dying entities.
It takes either a full entity object or just a class string (for dying entities
which only have their class left) via the `e_or_cls` parameter — the
`typeof` checks at the top destructure appropriately. Drawing order matters:
base rect → tint overlay → frame indicator → charging overlay → HP bar →
ATB bar → labels → owner border. Each layer paints on top of the previous, so
the order is back-to-front.

### What

**File:** `web/game.js`

Add these functions before `drawGrid`:

```js
// Returns the pixel rect for an entity given a colX mapper and grid origin y.
function entityPixelRect(e, colX, oy) {
  const [cw, ch] = CLASS_SIZE[e.class] ?? [1, 1];
  return {
    x: colX(e.col),
    y: oy + e.row * (CELL_H + CELL_PAD),
    w: cw * CELL_W + (cw - 1) * CELL_PAD,
    h: ch * CELL_H + (ch - 1) * CELL_PAD,
  };
}

// Returns a Set of "col,row" strings for every cell covered by multi-cell
// entities. Used to skip drawing the empty cell background under them.
function coveredCells(entities) {
  const covered = new Set();
  for (const e of entities) {
    const [cw, ch] = CLASS_SIZE[e.class] ?? [1, 1];
    for (let dc = 0; dc < cw; dc++) {
      for (let dr = 0; dr < ch; dr++) {
        covered.add(`${e.col + dc},${e.row + dr}`);
      }
    }
  }
  return covered;
}

// Advance a single AnimState by dt milliseconds.
// Returns true if the clip just finished (non-looping, last frame elapsed).
function advanceAnim(anim, dt) {
  if (anim.done) return false;
  const clip = CLIPS[anim.clip];
  anim.elapsed += dt;
  const frameDur = 1000 / clip.fps;
  if (anim.elapsed >= frameDur) {
    anim.elapsed -= frameDur; // subtract, don't reset — preserves overshoot
    anim.frame++;
    if (anim.frame >= clip.frames) {
      if (clip.loop) {
        anim.frame = 0;
      } else {
        anim.frame = clip.frames - 1;
        anim.done = true;
        return true;
      }
    }
  }
  return false;
}

// Advance all live and dying animations. Call once per game frame.
function advanceAnimations(dt, liveIds) {
  for (const id of liveIds) {
    if (!animStates.has(id)) {
      animStates.set(id, { clip: "idle", frame: 0, elapsed: 0, done: false });
    }
    const anim = animStates.get(id);
    const finished = advanceAnim(anim, dt);
    // Non-looping clip finished: return to idle.
    if (finished && anim.clip !== "die") {
      anim.clip = "idle";
      anim.frame = 0;
      anim.elapsed = 0;
      anim.done = false;
    }
    // die clips are handled separately in dyingEntities — see triggerClip.
  }

  for (const [id, dying] of dyingEntities) {
    const finished = advanceAnim(dying.anim, dt);
    if (finished) {
      dyingEntities.delete(id);
    }
  }

  // Clean up animStates for entities that have left the snapshot entirely
  // (and aren't in dyingEntities — those were moved there by triggerClip).
  for (const id of animStates.keys()) {
    if (!liveIds.has(id)) {
      animStates.delete(id);
    }
  }
}

// Trigger a clip on an entity. For "die", moves the entity's state to
// dyingEntities so it keeps rendering after leaving the snapshot.
// r is the pixel rect (only needed for "die").
function triggerClip(id, clip, r, cls) {
  const newAnim = { clip, frame: 0, elapsed: 0, done: false };
  if (clip === "die") {
    dyingEntities.set(id, { anim: newAnim, r, cls });
    animStates.delete(id);
  } else {
    if (animStates.has(id)) {
      Object.assign(animStates.get(id), newAnim);
    }
  }
}

// Process action_results from the server, triggering appropriate clips.
// Call this once per drawGame invocation before advancing animations.
// pixelRectForId is a function (id) => rect|null for looking up rects of
// entities that may be dying (need the rect to keep drawing them).
function processActionResults(results, pixelRectForId, classForId) {
  if (!results) return;
  for (const res of results) {
    const actor = res.actor;
    const target = res.target;
    if (animStates.has(actor)) {
      triggerClip(actor, "attack");
    }
    switch (res.tag) {
      case "damage":
        if (animStates.has(target)) {
          triggerClip(target, "hurt");
        }
        break;
      case "death": {
        // hurt first, then die on same frame is fine — die overwrites.
        const r = pixelRectForId(target);
        const cls = classForId(target);
        if (r && cls) {
          triggerClip(target, "die", r, cls);
        }
        break;
      }
      // heal, defend, miss: no clip for now
    }
  }
}

// Draw a single entity (live or dying) given its pixel rect and AnimState.
function drawEntity(e_or_cls, r, anim, ownerId, ourPlayerId, isPlayer) {
  const cls = typeof e_or_cls === "string" ? e_or_cls : e_or_cls.class;
  const hp = typeof e_or_cls === "string" ? null : e_or_cls;
  const owner = typeof e_or_cls === "string" ? null : e_or_cls.owner;
  const state = typeof e_or_cls === "string" ? null : e_or_cls.state;
  const atb = typeof e_or_cls === "string" ? null : e_or_cls.atb;
  const hpCur = typeof e_or_cls === "string" ? null : e_or_cls.hp;
  const hpMax = typeof e_or_cls === "string" ? null : e_or_cls.hp_max;

  // 1. Base class-colored rect.
  rect(r.x, r.y, r.w, r.h, classColor(cls));

  // 2. Animation tint overlay.
  const tint = CLIP_TINT[anim.clip];
  if (tint) {
    // Pulse opacity slightly per frame for visual interest.
    ctx.save();
    ctx.globalAlpha = 0.7 + 0.3 * (anim.frame % 2 === 0 ? 1 : 0);
    rect(r.x, r.y, r.w, r.h, tint);
    ctx.restore();
  }

  // 3. Placeholder frame indicator: small square top-right corner cycles hue.
  //    This makes the animation clock visible without any real sprite assets.
  //    Remove this once real sprites are in place.
  const frameColors = ["#f00", "#f80", "#ff0", "#0f0", "#08f", "#80f"];
  const fc = frameColors[anim.frame % frameColors.length];
  rect(r.x + r.w - 14, r.y + 2, 12, 12, fc);

  if (hp === null) return; // dying entity — skip bars/labels

  // 4. Charging overlay.
  if (state === "charging") {
    rect(r.x, r.y, r.w, r.h, C_CHARGING);
  }

  // 5. HP bar (scaled to entity width).
  const BAR_H_HP = 8;
  const hpFrac = hpMax > 0 ? hpCur / hpMax : 0;
  rect(r.x, r.y, r.w, BAR_H_HP, C_HP_BG);
  rect(r.x, r.y, r.w * hpFrac, BAR_H_HP, C_HP_FILL);

  // 6. ATB bar (scaled to entity width).
  const BAR_H_ATB = 6;
  const atbY = r.y + r.h - BAR_H_ATB;
  const atbFrac = Math.max(0, Math.min(1, atb));
  rect(r.x, atbY, r.w, BAR_H_ATB, C_ATB_BG);
  rect(r.x, atbY, r.w * atbFrac, BAR_H_ATB, C_ATB_FILL);

  // 7. Class label and HP number.
  text(classLabel(cls), r.x + 4, r.y + 14 + 16, 16, C_TEXT);
  text(String(hpCur), r.x + 4, r.y + 36 + 14, 14, C_TEXT);

  // 8. Player-owned border.
  if (isPlayer && owner === ourPlayerId) {
    rectStroke(r.x, r.y, r.w, r.h, 2, C_OWN_BORDER);
  }
}
```

---

## Step 8 — Rewrite `drawGrid`

### Why

The existing `drawGrid` does a simple flat loop: draw empty cells, then draw
entities inline. It needs to change in four ways:

1. **Multi-cell background skip.** The empty cell grid must not draw a grey rect
   under cells that are covered by a multi-cell entity. The `coveredCells` set
   built in Step 7 drives this check.

2. **Event processing.** `processActionResults` must be called exactly once per
   frame, not twice (once per team). We call it on the `"enemies"` pass
   arbitrarily — it processes results for all entity IDs regardless of team, so
   calling it once is sufficient. Player entities don't have animation clips
   triggered from a different team's pass because `triggerClip` guards on
   `animStates.has(id)` — the actor's ID will be in `animStates` regardless of
   which pass processes it.

3. **Dying entity draw pass.** After live entities, we draw `dyingEntities` with
   reduced opacity (`globalAlpha = 0.7`). This is drawn only on the `"enemies"`
   pass for the same once-per-frame reason — enemies are the only multi-cell
   entities, and dying entities are most likely enemies. (If a player could die
   with a visible clip, you'd move this to a separate post-pass in `drawGame`.)

4. **`dt` threading.** The function now takes `dt` and passes it to
   `advanceAnimations`. `drawGrid` is called twice per frame (once per team), and
   `advanceAnimations` is called once per pass on each team's entity set. This is
   correct — each team's animations are independent.

### What

**File:** `web/game.js`

Replace the existing `drawGrid` function entirely:

```js
function drawGrid(game, team, ox, oy, dt) {
  const isTargeting =
    (team === "enemies" && game.is_our_turn && game.targeting_enemy) ||
    (team === "players" && game.is_our_turn && !game.targeting_enemy);

  const colX = (col) =>
    team === "players"
      ? ox + (2 - col) * (CELL_W + CELL_PAD)
      : ox + col * (CELL_W + CELL_PAD);

  const entities = (game.entities || []).filter((e) => e.team === team);

  // Build covered-cell set for multi-cell entities so we can skip
  // drawing the empty background behind them.
  const covered = coveredCells(entities);

  // 1. Empty cell backgrounds (skip cells covered by multi-cell entities).
  for (let col = 0; col < 3; col++) {
    for (let row = 0; row < 4; row++) {
      if (covered.has(`${col},${row}`)) continue;
      const cx = colX(col);
      const cy = oy + row * (CELL_H + CELL_PAD);
      rect(cx, cy, CELL_W, CELL_H, C_CELL_EMPTY);
    }
  }

  // 2. Build lookup helpers for processActionResults.
  const rectById = new Map(
    entities.map((e) => [e.id, entityPixelRect(e, colX, oy)]),
  );
  const clsById = new Map(entities.map((e) => [e.id, e.class]));

  // Process events only once (on the enemies pass to avoid double-trigger).
  // Player entities don't need death rects since they're always 1x1 and
  // the same logic applies; processing once is sufficient.
  if (team === "enemies") {
    processActionResults(
      game.action_results,
      (id) => rectById.get(id) ?? null,
      (id) => clsById.get(id) ?? null,
    );
  }

  // 3. Advance animations for this team's live entities.
  const liveIds = new Set(entities.map((e) => e.id));
  advanceAnimations(dt, liveIds);

  // 4. Draw live entities.
  for (const e of entities) {
    const r = entityPixelRect(e, colX, oy);
    // Ensure AnimState exists (advanceAnimations creates it but guard here).
    if (!animStates.has(e.id)) {
      animStates.set(e.id, { clip: "idle", frame: 0, elapsed: 0, done: false });
    }
    const anim = animStates.get(e.id);
    drawEntity(e, r, anim, e.owner, game.player_id, team === "players");
  }

  // 5. Draw dying entities that belong to this team.
  // We don't track team on dyingEntities so we draw all of them on both
  // passes — they only exist briefly and the overdraw is harmless.
  // Alternatively, store team in the dying entry if you want precision.
  if (team === "enemies") {
    ctx.save();
    ctx.globalAlpha = 0.7;
    for (const [, dying] of dyingEntities) {
      drawEntity(dying.cls, dying.r, dying.anim, null, null, false);
    }
    ctx.restore();
  }

  // 6. Cursor overlay.
  if (isTargeting && game.cursor) {
    const cc = game.cursor.col;
    const cr = game.cursor.row;
    const cx = colX(cc);
    const cy = oy + cr * (CELL_H + CELL_PAD);
    rectStroke(cx, cy, CELL_W, CELL_H, 3, C_CURSOR);
  }
}
```

---

## Step 9 — Update `drawGame` to pass `dt`

### Why

This is purely mechanical — `drawGame` is the function that calls `drawGrid`,
and now that `drawGrid` needs `dt`, `drawGame` needs to receive it from
`renderFrame` and forward it down. There's no new logic here; it's just
completing the parameter chain started in Step 4.

### What

**File:** `web/game.js`

Update the signature and calls:

```js
function drawGame(game, dt) {
  clear();

  const wave = game.wave || "";
  text(`Wave: ${wave}`, 40, 30 + 20, 20, C_HEADER);

  text("ALLIES", PLAYER_GRID_X, 155 + 18, 18, C_HEADER);
  text("ENEMIES", ENEMY_GRID_X, 155 + 18, 18, C_ENEMY_HDR);

  drawGrid(game, "players", PLAYER_GRID_X, PLAYER_GRID_Y, dt);
  drawGrid(game, "enemies", ENEMY_GRID_X, ENEMY_GRID_Y, dt);

  if (game.is_our_turn) {
    drawActionMenu(game);
  }
}
```

---

## Step 10 — Build and verify

```bash
zig build
zig build run-server   # terminal 1
zig build run          # terminal 2
```

Open the browser. You should see:

- [ ] Entities render with their class-colored base rect (same as before)
- [ ] A small colored square in the top-right corner of each entity cycles through
      frame colors at the clip's fps — this confirms the animation clock is running
- [ ] When an entity takes damage, a red tint flashes over it briefly
- [ ] When an entity attacks, a gold tint flashes over the actor
- [ ] When an entity dies, it stays on screen with a grey tint for the duration
      of the die clip, then vanishes cleanly
- [ ] A boss-class enemy (if present in the wave) spans two cells both wide and
      tall, HP and ATB bars scaled to the full width

---

## Notes for future real-sprite work

When you have actual PNG spritesheets, the only thing that changes is inside
`drawEntity`. Replace steps 1–3 (rect + tint + frame indicator) with a single
`drawImage` call:

```js
const srcX = anim.frame * SPRITE_W;
const srcY = CLIP_ROW[anim.clip] * SPRITE_H;
ctx.drawImage(spriteImg, srcX, srcY, SPRITE_W, SPRITE_H, r.x, r.y, r.w, r.h);
```

where `CLIP_ROW` maps clip names to row indices in the spritesheet, and
`SPRITE_W`/`SPRITE_H` are the dimensions of a single frame.

Everything else — the state machine, event processing, multi-cell layout,
`dyingEntities` — stays identical. The placeholder frame-color square can be
removed once real sprites are in place.

For enemies that face left, wrap the `drawImage` call with a canvas transform
that mirrors horizontally about the entity's centre:

```js
ctx.save();
ctx.translate(r.x + r.w, r.y);
ctx.scale(-1, 1);
ctx.drawImage(spriteImg, srcX, srcY, SPRITE_W, SPRITE_H, 0, 0, r.w, r.h);
ctx.restore();
```

`ctx.save()` / `ctx.restore()` bracket the transform so it doesn't affect
anything drawn after the entity.
