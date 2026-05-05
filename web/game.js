"use strict";

const SW = 1024;
const SH = 768;

const CELL_W = 90;
const CELL_H = 100;

// Team placement zones (soft boundaries — no hard grid).
const PLAYER_ZONE = { x0: 20,  x1: 330, y0: 180, y1: 660 };
const ENEMY_ZONE  = { x0: 694, x1: 1004, y0: 180, y1: 660 };

const C_BG = "#14141e";
const C_HP_BG = "rgba(30,10,10,0.78)";
const C_HP_FILL = "rgba(60,200,60,0.9)";
const C_CURSOR = "rgba(255,255,100,0.7)";
const C_TEXT = "rgba(230,230,230,1)";
const C_HEADER = "rgba(180,200,255,1)";
const C_ENEMY_HDR = "rgba(255,120,80,1)";
const C_OWN_BORDER = "rgba(255,255,60,0.78)";
const C_MENU_BG = "rgba(20,20,40,0.86)";
const C_MENU_BORDER = C_HEADER;
const C_SEL = C_CURSOR;

// ---------------------------------------------------------------------------
// Asset loading
// ---------------------------------------------------------------------------

const CLASSES = ["fighter", "mage", "healer", "grunt", "archer", "shaman", "boss"];

/** @type {Map<string, { img: HTMLImageElement, meta: { frame_w: number, frame_h: number, clips: Record<string,{row:number,frames:number,fps:number,loop:boolean}> } }>} */
const sprites = new Map();

async function loadAssets() {
  await Promise.all(CLASSES.map(async cls => {
    const [meta, img] = await Promise.all([
      fetch(`assets/${cls}.json`).then(r => r.json()),
      new Promise((res, rej) => {
        const i = new Image();
        i.onload = () => res(i);
        i.onerror = rej;
        i.src = `assets/${cls}.png`;
      }),
    ]);
    sprites.set(cls, { img, meta });
  }));
}

// ---------------------------------------------------------------------------
// Per-entity animator state
// ---------------------------------------------------------------------------

/**
 * @typedef {{ clip: string, frame: number, elapsed: number, locked: boolean }} AnimState
 * locked = true while a non-looping clip is playing; cleared when it finishes.
 */

/** @type {Map<number, AnimState>} */
const animState = new Map();

/**
 * Advance the animator for one entity and return its current {clip, frame}.
 * Call once per entity per rendered frame.
 *
 * @param {number} id          - entity id
 * @param {string} cls         - class name (key into sprites map)
 * @param {string|null} lastAction - "attack"|"die"|null from server this tick
 * @param {number} dt          - seconds since last frame
 */
function tickAnimator(id, cls, lastAction, dt) {
  const sp = sprites.get(cls);
  if (!sp) return { clip: "idle", frame: 0 };
  const { clips } = sp.meta;

  let s = animState.get(id);
  if (!s) {
    s = { clip: "idle", frame: 0, elapsed: 0, locked: false };
    animState.set(id, s);
  }

  // Transition: a new last_action from the server overrides the current clip
  // (unless we're mid-die, which must never be interrupted).
  if (lastAction && lastAction !== s.clip && s.clip !== "die") {
    s.clip = lastAction;
    s.frame = 0;
    s.elapsed = 0;
    s.locked = !clips[lastAction]?.loop;
  }

  const clip = clips[s.clip] ?? clips["idle"];
  const spf = 1 / clip.fps; // seconds per frame

  s.elapsed += dt;
  while (s.elapsed >= spf) {
    s.elapsed -= spf;
    s.frame++;
    if (s.frame >= clip.frames) {
      if (clip.loop) {
        s.frame = 0;
      } else {
        // Hold last frame; unlock so idle can resume next tick.
        s.frame = clip.frames - 1;
        s.locked = false;
        // Revert to idle unless this is die (stay dead).
        if (s.clip !== "die") {
          s.clip = "idle";
          s.frame = 0;
          s.elapsed = 0;
        }
        break;
      }
    }
  }

  return { clip: s.clip, frame: s.frame };
}

// ---------------------------------------------------------------------------
// Entity positions — assigned once on first sight, persist until cleared.
// ---------------------------------------------------------------------------

/** @type {Map<number, {x: number, y: number}>} */
const entityPositions = new Map();

/**
 * Pick a random non-overlapping position within a zone for a new entity.
 * Uses rejection sampling; falls back to an unvalidated position after
 * MAX_TRIES attempts so crowded zones never deadlock.
 *
 * @param {{ x0:number, x1:number, y0:number, y1:number }} zone
 * @returns {{ x: number, y: number }}
 */
function assignPosition(zone) {
  const MAX_TRIES = 50;
  const SEP = CELL_W + 8; // minimum centre-to-centre distance
  const existing = [...entityPositions.values()];

  for (let i = 0; i < MAX_TRIES; i++) {
    const x = zone.x0 + Math.random() * (zone.x1 - zone.x0 - CELL_W);
    const y = zone.y0 + Math.random() * (zone.y1 - zone.y0 - CELL_H);
    const ok = existing.every(p => Math.abs(p.x - x) >= SEP || Math.abs(p.y - y) >= SEP);
    if (ok) return { x, y };
  }
  // Fallback: place without collision check.
  return {
    x: zone.x0 + Math.random() * (zone.x1 - zone.x0 - CELL_W),
    y: zone.y0 + Math.random() * (zone.y1 - zone.y0 - CELL_H),
  };
}

function clearEntityState() {
  entityPositions.clear();
  animState.clear();
}

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------

const canvas = document.getElementById("canvas");
const ctx = canvas.getContext("2d");

function clear() {
  ctx.fillStyle = C_BG;
  ctx.fillRect(0, 0, SW, SH);
}

function text(str, x, y, size, color, font = "monospace") {
  ctx.fillStyle = color;
  ctx.font = `${size}px ${font}`;
  ctx.fillText(str, x, y);
}

function rect(x, y, w, h, color) {
  ctx.fillStyle = color;
  ctx.fillRect(x, y, w, h);
}

function rectStroke(x, y, w, h, lineW, color) {
  ctx.strokeStyle = color;
  ctx.lineWidth = lineW;
  ctx.strokeRect(x + lineW / 2, y + lineW / 2, w - lineW, h - lineW);
}

// ---------------------------------------------------------------------------
// Screen helpers
// ---------------------------------------------------------------------------

function drawConnecting() {
  clear();
  text("Connecting to server...", 40, 60, 24, C_TEXT);
}

function drawFull() {
  clear();
  text("Session full (max 6 players).", 40, SH / 2 - 16, 24, C_TEXT);
  text("Close another tab to free a slot.", 40, SH / 2 + 16, 18, C_TEXT);
}

// Draw the 3×2 lobby position-picker grid.
// Columns are visually flipped so col 0 (front rank) is on the right, matching
// the in-game ally grid orientation (closest to enemies = right edge).
function drawLobbyGrid(lobby, ox, oy) {
  const CW = 70, CH = 56, CP = 5;
  const players = lobby.players || [];

  // Build a lookup: "col,row" -> player info for occupied cells
  const occupied = {};
  for (const p of players) {
    if (p.grid_col !== undefined && p.grid_row !== undefined) {
      occupied[`${p.grid_col},${p.grid_row}`] = p;
    }
  }

  for (let col = 0; col < 3; col++) {
    for (let row = 0; row < 4; row++) {
      // Flip columns: col 0 (front) renders at the right edge
      const cx = ox + (2 - col) * (CW + CP);
      const cy = oy + row * (CH + CP);

      const key = `${col},${row}`;
      const occ = occupied[key];
      const isOurs = occ && occ.id === lobby.player_id;
      const isCursor = col === (lobby.chosen_col ?? 0) && row === (lobby.chosen_row ?? 0);

      // Cell background
      let bg = "rgba(40,40,55,0.7)";
      if (occ) bg = isOurs ? "rgba(80,160,80,0.86)" : "rgba(120,80,80,0.7)";
      rect(cx, cy, CW, CH, bg);

      // Cursor highlight
      if (isCursor) rectStroke(cx, cy, CW, CH, 3, C_CURSOR);

      // Player name or col label
      if (occ) {
        const nameColor = isOurs ? "rgba(255,255,100,1)" : C_TEXT;
        text(occ.name.slice(0, 6), cx + 4, cy + 20, 13, nameColor);
        text(occ.class.slice(0, 3).toUpperCase(), cx + 4, cy + 38, 12, C_TEXT);
      }
    }
  }

  // Column rank labels below the grid (front = right, back = left, matching flip)
  const labelY = oy + 4 * (CH + CP) + 14;
  for (let col = 0; col < 3; col++) {
    const lx = ox + (2 - col) * (CW + CP) + CW / 2 - 14;
    const label = col === 0 ? "FRONT" : col === 2 ? "BACK" : "";
    if (label) text(label, lx, labelY, 11, "rgba(140,160,200,0.8)");
  }
}

function drawLobby(lobby) {
  clear();
  text("Dragoncon Game", 40, 52, 32, C_HEADER);

  const joinCode = lobby.join_code || "??????";
  text(`Room: ${joinCode}`, 40, 92, 22, C_TEXT);

  const listY = 130;
  const players = lobby.players || [];
  players.forEach((p, i) => {
    const y = listY + i * 36 + 20;
    const color = p.id === lobby.player_id ? "rgba(255,255,100,1)" : C_TEXT;
    const ready = p.ready ? "[READY]" : "[     ]";
    const conn = p.connected ? "" : " (disconnected)";
    text(`${p.name}  ${p.class}  ${ready}${conn}`, 60, y, 20, color);
  });

  const pickerY = listY + 6 * 36 + 20;
  const readyLabel = lobby.ready ? "Press ENTER to un-ready" : "Press ENTER when ready";
  text(readyLabel, 60, pickerY, 18, C_TEXT);

  // Position picker
  const gridX = SW - 290;
  const gridY = 130;
  text("Position  [Arrow keys]", gridX, gridY - 14, 14, "rgba(180,200,255,0.9)");
  drawLobbyGrid(lobby, gridX, gridY);
}

/**
 * Draw one entity's sprite into its cell, scaled to CELL_W × CELL_H.
 * Enemies are flipped horizontally so they face the player team.
 *
 * @param {object} e   - entity from game.entities
 * @param {number} cx  - cell top-left x
 * @param {number} cy  - cell top-left y
 * @param {string} lastAction - "attack"|"die"|null
 * @param {number} dt  - seconds since last frame
 * @param {boolean} flip - mirror horizontally (enemies)
 */
function drawEntitySprite(e, cx, cy, lastAction, dt, flip) {
  const sp = sprites.get(e.class);
  if (!sp) return;

  const { img, meta } = sp;
  const { frame_w, frame_h, clips } = meta;
  const { frame } = tickAnimator(e.id, e.class, lastAction, dt);
  const clip = clips[animState.get(e.id)?.clip ?? "idle"] ?? clips["idle"];

  const srcX = frame * frame_w;
  const srcY = clip.row * frame_h;

  ctx.save();
  ctx.imageSmoothingEnabled = false;

  if (flip) {
    // Flip around the cell's horizontal centre.
    ctx.translate(cx + CELL_W, cy);
    ctx.scale(-1, 1);
    ctx.drawImage(img, srcX, srcY, frame_w, frame_h, 0, 0, CELL_W, CELL_H);
  } else {
    ctx.drawImage(img, srcX, srcY, frame_w, frame_h, cx, cy, CELL_W, CELL_H);
  }

  ctx.restore();
}

function drawTeam(game, team, dt) {
  const zone = team === "players" ? PLAYER_ZONE : ENEMY_ZONE;
  const flip = team === "enemies";

  const entities = (game.entities || []).filter(e => e.team === team);
  for (const e of entities) {
    if (e.hp <= 0) continue;

    // Assign position on first sight; never move it.
    if (!entityPositions.has(e.id)) {
      entityPositions.set(e.id, assignPosition(zone));
    }
    const { x: cx, y: cy } = entityPositions.get(e.id);

    // Sprite
    drawEntitySprite(e, cx, cy, e.last_action ?? null, dt, flip);

    // Player-owned entity border
    if (e.owner === game.player_id && team === "players") {
      rectStroke(cx, cy, CELL_W, CELL_H, 2, C_OWN_BORDER);
    }

    // Combo slot row under every player entity, sourced from per-entity
    // snapshot so all players' combos are visible, not just the local one.
    if (team === "players") {
      const entityCombo = e.combo ?? [];
      const SLOT_W = 18;
      const MAX_SLOTS = 4;
      const rowW = MAX_SLOTS * SLOT_W;
      const rowX = cx + (CELL_W - rowW) / 2;
      const rowY = cy + CELL_H + 4;

      for (let i = 0; i < MAX_SLOTS; i++) {
        const slotX = rowX + i * SLOT_W;
        const action = entityCombo[i];
        if (action) {
          text(ACTION_CHAR[action] ?? "?", slotX, rowY + 13, 14,
               ACTION_COLOR[action] ?? C_TEXT);
        } else {
          text("·", slotX, rowY + 13, 14, "rgba(120,120,140,0.5)");
        }
      }
    }
  }
}

// Must match game_logic.zig ACTION_EFFECT_VALUE.
const ACTION_EFFECT_VALUE = 1;

/** Map ActionChoice enum string → display character. */
const ACTION_CHAR = { damage: "a", shield: "s", heal: "h" };

/** Map ActionChoice enum string → highlight colour. */
const ACTION_COLOR = {
  damage: "rgba(255,100,100,1)",
  shield: "rgba(80,160,255,1)",
  heal:   "rgba(100,220,100,1)",
};

/**
 * Draw stacked status bars confined to a horizontal span [x0, x1].
 * Each bar has a short left label and a numeric value on the right.
 *
 * @param {{ label:string, value:number, frac:number, color:string, bg:string }[]} bars
 * @param {number} x0  - left edge
 * @param {number} x1  - right edge
 * @param {number} y   - top of first bar
 */
function drawBars(bars, x0, x1, y) {
  const BAR_H   = 10;
  const GAP     = 4;
  const LABEL_W = 40;
  const ROW_H   = BAR_H + GAP;
  const bx = x0 + LABEL_W;
  const bw = (x1 - x0) - LABEL_W;

  for (let i = 0; i < bars.length; i++) {
    const { label, value, frac, color, bg } = bars[i];
    const by = y + i * ROW_H;
    const f  = Math.max(0, Math.min(1, frac));

    text(label, x0, by + BAR_H - 2, 10, "rgba(180,200,255,0.85)");
    rect(bx, by, bw, BAR_H, bg);
    if (f > 0) rect(bx, by, bw * f, BAR_H, color);
    text(String(Math.round(value)), bx + bw + 4, by + BAR_H - 2, 10, "rgba(180,200,255,0.7)");
  }
}

/**
 * Draw aggregate player-team bars (HP, projected shield, projected heal)
 * in the header strip above the player zone.
 * Draw aggregate enemy-team HP bar above the enemy zone.
 */
function drawTeamBars(game) {
  const entities = game.entities || [];
  const players  = entities.filter(e => e.team === "players" && e.hp > 0);
  const enemies  = entities.filter(e => e.team === "enemies"  && e.hp > 0);

  // --- Player bars ---
  if (players.length > 0) {
    let totalHp = 0, totalMaxHp = 0, shieldCount = 0, healCount = 0;
    for (const e of players) {
      totalHp    += e.hp;
      totalMaxHp += e.hp_max;
      for (const action of (e.combo ?? [])) {
        if (action === "shield") shieldCount++;
        else if (action === "heal")   healCount++;
      }
    }
    const scale      = totalMaxHp > 0 ? 1 / totalMaxHp : 0;
    const projShield = shieldCount * ACTION_EFFECT_VALUE;
    const projHeal   = healCount   * ACTION_EFFECT_VALUE;

    // Three bars stacked; top of first bar sits just below the "ALLIES" label.
    const y = PLAYER_ZONE.y0 - 56; // leaves room for 3 × (10+4) = 42px + gap
    drawBars([
      { label: "HP",   value: totalHp,    frac: totalHp    * scale, color: "rgba(60,200,60,0.9)",   bg: C_HP_BG },
      { label: "Shld", value: projShield, frac: projShield * scale, color: "rgba(80,160,255,0.9)",  bg: "rgba(20,20,80,0.6)" },
      { label: "Heal", value: projHeal,   frac: projHeal   * scale, color: "rgba(140,230,100,0.9)", bg: "rgba(20,50,20,0.6)" },
    ], PLAYER_ZONE.x0, PLAYER_ZONE.x1, y);
  }

  // --- Enemy bar ---
  if (enemies.length > 0) {
    let totalHp = 0, totalMaxHp = 0;
    for (const e of enemies) { totalHp += e.hp; totalMaxHp += e.hp_max; }
    const scale = totalMaxHp > 0 ? 1 / totalMaxHp : 0;

    // One bar; align bottom with player bars bottom.
    const y = ENEMY_ZONE.y0 - 56 + 28; // vertically centred in the same strip
    drawBars([
      { label: "HP", value: totalHp, frac: totalHp * scale, color: "rgba(255,100,60,0.9)", bg: C_HP_BG },
    ], ENEMY_ZONE.x0, ENEMY_ZONE.x1, y);
  }
}

function drawActionMenu(game) {
  const mx = SW / 2 - 160;
  const my = SH - 110;
  const mw = 320;
  const mh = 90;

  rect(mx, my, mw, mh, C_MENU_BG);
  rectStroke(mx, my, mw, mh, 2, C_MENU_BORDER);

  text("[1] Atk", mx + 10,        my + 14 + 16, 16, C_TEXT);
  text("[2] Shld", mx + 10 + 106, my + 14 + 16, 16, C_TEXT);
  text("[3] Heal", mx + 10 + 212, my + 14 + 16, 16, C_TEXT);
  text("[Esc] Cancel", mx + 10,   my + 14 + 34, 12, "rgba(180,180,180,0.8)");

  // Round timer bar
  const timerFrac = game.round_duration > 0
    ? Math.max(0, Math.min(1, game.round_timer / game.round_duration))
    : 0;
  rect(mx + 10, my + 58, mw - 20, 10, "rgba(30,30,30,0.8)");
  rect(mx + 10, my + 58, (mw - 20) * timerFrac, 10, "rgba(255,200,50,0.9)");
  text(`Round: ${game.round_timer !== undefined ? game.round_timer.toFixed(1) : "?"}s`, mx + 10, my + 82, 13, C_TEXT);
}

function drawGame(game, dt) {
  clear();

  const wave = game.wave || "";
  text(`Wave: ${wave}`, 40, 30 + 20, 20, C_HEADER);

  text("ALLIES",  PLAYER_ZONE.x0, PLAYER_ZONE.y0 - 62, 18, C_HEADER);
  text("ENEMIES", ENEMY_ZONE.x0,  ENEMY_ZONE.y0  - 62, 18, C_ENEMY_HDR);

  drawTeamBars(game);

  drawTeam(game, "players", dt);
  drawTeam(game, "enemies", dt);

  drawActionMenu(game);
}

function drawGameOver() {
  clear();
  text("Game Over!  Press any key to return to lobby.", 40, SH / 2, 24, C_TEXT);
}

// ---------------------------------------------------------------------------
// Render loop
// ---------------------------------------------------------------------------

let latestMsg = null;
let lastTs = null;
let lastPhase = null;

function renderFrame(msg, dt) {
  // Clear per-entity state whenever we leave the game phase.
  if (lastPhase === "game" && msg.phase !== "game") clearEntityState();
  lastPhase = msg.phase;

  switch (msg.phase) {
    case "connecting": drawConnecting(); break;
    case "lobby":     drawLobby(msg.lobby); break;
    case "game":      drawGame(msg.game, dt); break;
    case "game_over": drawGameOver(); break;
    default:          drawConnecting();
  }
}

function gameLoop(ts) {
  const dt = lastTs !== null ? (ts - lastTs) / 1000 : 0;
  lastTs = ts;
  if (latestMsg) renderFrame(latestMsg, dt);
  requestAnimationFrame(gameLoop);
}

// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

let ws = null;

function connect() {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  const url = `${proto}//${location.host}/ws`;
  ws = new WebSocket(url);

  ws.addEventListener("open", () => console.log("[game] connected to bridge"));
  ws.addEventListener("close", () => setTimeout(connect, 1_000));
  ws.addEventListener("error", (e) => console.error("[game] ws error", e));
  ws.addEventListener("message", (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    if (msg.tag === "render") latestMsg = msg;
    else if (msg.tag === "full") drawFull();
  });
}

// ---------------------------------------------------------------------------
// Input forwarding
// ---------------------------------------------------------------------------

const FORWARDED_KEYS = new Set([
  "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
  "Enter", "Escape",
  "1", "2", "3",
  "z", "Z", "x", "X",
]);

document.addEventListener("keydown", (e) => {
  if (!FORWARDED_KEYS.has(e.key)) return;
  e.preventDefault();
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ key: e.key }));
  }
});

// ---------------------------------------------------------------------------
// Boot: load assets, then start loop and connect
// ---------------------------------------------------------------------------

loadAssets().then(() => {
  requestAnimationFrame(gameLoop);
  connect();
}).catch(err => {
  console.error("[game] asset load failed", err);
  // Start anyway so the connecting screen shows.
  requestAnimationFrame(gameLoop);
  connect();
});
