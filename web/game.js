"use strict";

const SW = 1024;
const SH = 768;

const CELL_W = 90;
const CELL_H = 100;

// Team placement zones (soft boundaries — no hard grid).
const PLAYER_ZONE = { x0: 20, x1: 330, y0: 180, y1: 660 };
const ENEMY_ZONE = { x0: 694, x1: 1004, y0: 180, y1: 660 };

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

const CLASSES = ["fighter", "mage", "healer", "grunt", "archer", "shaman", "boss"];

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

  if (lastAction && lastAction !== s.clip && s.clip !== "die") {
    s.clip = lastAction;
    s.frame = 0;
    s.elapsed = 0;
    s.locked = !clips[lastAction]?.loop;
  }

  const clip = clips[s.clip] ?? clips["idle"];
  const spf = 1 / clip.fps;

  s.elapsed += dt;
  while (s.elapsed >= spf) {
    s.elapsed -= spf;
    s.frame++;
    if (s.frame >= clip.frames) {
      if (clip.loop) {
        s.frame = 0;
      } else {
        s.frame = clip.frames - 1;
        s.locked = false;
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
  const SEP = CELL_W + 8; // minimum center-to-center distance
  const existing = [...entityPositions.values()];

  for (let i = 0; i < MAX_TRIES; i++) {
    const x = zone.x0 + Math.random() * (zone.x1 - zone.x0 - CELL_W);
    const y = zone.y0 + Math.random() * (zone.y1 - zone.y0 - CELL_H);
    const ok = existing.every(p => Math.abs(p.x - x) >= SEP || Math.abs(p.y - y) >= SEP);
    if (ok) return { x, y };
  }
  return {
    x: zone.x0 + Math.random() * (zone.x1 - zone.x0 - CELL_W),
    y: zone.y0 + Math.random() * (zone.y1 - zone.y0 - CELL_H),
  };
}

function clearEntityState() {
  entityPositions.clear();
  animState.clear();
  floaters.length = 0;
  lastRoundSeen = -1;
  lastEntitiesSnapshot = [];
}

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

function drawConnecting() {
  clear();
  text("Connecting to server...", 40, 60, 24, C_TEXT);
}

function drawFull() {
  clear();
  text("Session full (max 6 players).", 40, SH / 2 - 16, 24, C_TEXT);
  text("Close another tab to free a slot.", 40, SH / 2 + 16, 18, C_TEXT);
}

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
  const summary = team === "enemies" ? game.enemies : game.players;
  const teamAlive = summary && summary.hp_current > 0;

  const entities = (game.entities || []).filter(e => e.team === team);
  for (const e of entities) {
    if (!teamAlive) continue;

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
        const slot = entityCombo[i];
        if (slot && slot.action !== undefined) {
          text(ACTION_CHAR[slot.action] ?? "?", slotX, rowY + 13, 14,
            ACTION_COLOR[slot.action] ?? C_TEXT);
        } else if (slot && slot.element !== undefined) {
          text(ELEMENT_CHAR[slot.element] ?? "?", slotX, rowY + 13, 14,
            ELEMENT_COLOR[slot.element] ?? C_TEXT);
        } else {
          text("·", slotX, rowY + 13, 14, "rgba(120,120,140,0.5)");
        }
      }
    }
  }
}

// Must match game_logic.zig ACTION_EFFECT_VALUE.
const ACTION_EFFECT_VALUE = 1;

// ---------------------------------------------------------------------------
// Floater system
// ---------------------------------------------------------------------------

/**
 * @typedef {{ text: string, x: number, y: number, color: string, age: number, lifetime: number }} Floater
 */

/** @type {Floater[]} */
const floaters = [];

/**
 * Spawn a floating text label that drifts upward and fades out.
 * @param {string} text
 * @param {number} x       - canvas x (centre of text)
 * @param {number} y       - canvas y (baseline at spawn)
 * @param {string} color   - CSS color string (alpha overridden by fade)
 * @param {number} lifetime - seconds until fully faded (default 1.5)
 */
function spawnFloater(text, x, y, color, lifetime = 1.5) {
  floaters.push({ text, x, y, color, age: 0, lifetime });
}

function tickFloaters(dt) {
  for (const f of floaters) f.age += dt;
  // Remove expired in-place.
  let w = 0;
  for (const f of floaters) {
    if (f.age < f.lifetime) floaters[w++] = f;
  }
  floaters.length = w;
}

function drawFloaters() {
  for (const f of floaters) {
    const frac     = f.age / f.lifetime;
    const alpha    = frac > 0.6 ? 1 - (frac - 0.6) / 0.4 : 1.0;
    const yOffset  = -40 * frac; // drift 40px upward over lifetime

    // Strip any existing alpha from the color string and reapply via globalAlpha.
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font        = "bold 16px monospace";
    ctx.fillStyle   = f.color;
    ctx.textAlign   = "center";
    ctx.fillText(f.text, f.x, f.y + yOffset);
    ctx.restore();
  }
}

// ---------------------------------------------------------------------------
// Round resolution floaters
// ---------------------------------------------------------------------------

/**
 * Parse a combo's slots into elemented actions using the same rules as
 * game_logic.parse_combo on the server:
 *   - element token sets the current element (persists until next element)
 *   - action token emits { action, element } and keeps the current element
 *   - trailing element tokens are dropped
 *
 * @param {Array<{action?:string, element?:string}>} slots
 * @returns {Array<{action:string, element:string|null}>}
 */
function parseComboSlots(slots) {
  let currentElement = null;
  const out = [];
  for (const slot of slots) {
    if (slot.element !== undefined) {
      currentElement = slot.element;
    } else if (slot.action !== undefined) {
      out.push({ action: slot.action, element: currentElement });
      // Element persists — do NOT reset here.
    }
  }
  return out;
}

/**
 * Given a list of entity snapshots (from the prior frame), tally all
 * elemented actions across every player entity's combo.
 *
 * Returns a Map<element|"none", {damage:n, shield:n, heal:n}>.
 */
function tallyPlayerActions(entities) {
  const tally = new Map();

  const get = (key) => {
    if (!tally.has(key)) tally.set(key, { damage: 0, shield: 0, heal: 0 });
    return tally.get(key);
  };

  for (const e of entities) {
    if (e.team !== "players") continue;
    const acts = parseComboSlots(e.combo ?? []);
    for (const { action, element } of acts) {
      const key = element ?? "none";
      get(key)[action] = (get(key)[action] ?? 0) + 1;
    }
  }
  return tally;
}

/**
 * Called once per round resolution (when game.round increases).
 * Reads lastEntitiesSnapshot to derive what the resolved round contained,
 * then spawns floaters accordingly.
 *
 * @param {object} game   - current game frame (used for enemy count/intent)
 * @param {Array}  prevEntities - entity snapshot from the frame before round_reset
 */
function spawnRoundSummaryFloaters(game, prevEntities) {
  const tally = tallyPlayerActions(prevEntities);

  // Centre points for spawn zones.
  const ex = (ENEMY_ZONE.x0 + ENEMY_ZONE.x1) / 2;
  const ey = (ENEMY_ZONE.y0 + ENEMY_ZONE.y1) / 2;
  const px = (PLAYER_ZONE.x0 + PLAYER_ZONE.x1) / 2;
  const py = (PLAYER_ZONE.y0 + PLAYER_ZONE.y1) / 2;

  // Small random X jitter so stacked floaters spread slightly.
  const jitter = () => (Math.random() - 0.5) * 40;

  let floaterY = ey; // stack floaters vertically in the enemy zone

  for (const [element, counts] of tally) {
    const elChar  = element === "none" ? ""   : (ELEMENT_CHAR[element]  ?? "");
    const elColor = element === "none" ? "rgba(255,100,100,1)" : (ELEMENT_COLOR[element] ?? "rgba(255,100,100,1)");

    if (counts.damage > 0) {
      const label = element === "none"
        ? `-${counts.damage}`
        : `-${counts.damage} ${elChar}`;
      spawnFloater(label, ex + jitter(), floaterY, elColor);
      floaterY += 22;
    }

    const shieldColor = element === "none"
      ? "rgba(80,160,255,1)"
      : (ELEMENT_COLOR[element] ?? "rgba(80,160,255,1)");
    if (counts.shield > 0) {
      const label = element === "none"
        ? `+${counts.shield} shld`
        : `+${counts.shield} shld ${elChar}`;
      spawnFloater(label, px + jitter(), py, shieldColor);
    }

    if (counts.heal > 0) {
      const label = element === "none"
        ? `+${counts.heal} heal`
        : `+${counts.heal} heal ${elChar}`;
      spawnFloater(label, px + jitter(), py + 22, "rgba(100,220,100,1)");
    }
  }

  // Enemy intent: 1 damage per living enemy entity.
  const enemyCount = (game.entities ?? []).filter(e => e.team === "enemies").length;
  if (enemyCount > 0) {
    spawnFloater(`-${enemyCount}`, px + jitter(), py - 22, "rgba(255,80,80,1)");
  }
}

// ---------------------------------------------------------------------------
// Round tracking state
// ---------------------------------------------------------------------------

let lastRoundSeen    = -1;
/** Shallow copy of game.entities from the previous frame. */
let lastEntitiesSnapshot = [];

/**
 * Call at the start of every drawGame frame.
 * Detects round boundary, spawns floaters from the previous frame's entities,
 * then updates the snapshot for the next round.
 */
function updateRoundTracking(game) {
  if (game.round !== lastRoundSeen && lastRoundSeen !== -1) {
    spawnRoundSummaryFloaters(game, lastEntitiesSnapshot);
  }
  lastRoundSeen = game.round;
  // Snapshot current entities so they're available next frame if a round fires.
  lastEntitiesSnapshot = (game.entities ?? []).slice();
}

/** Map ActionChoice enum string → display character. */
const ACTION_CHAR = { damage: "a", shield: "s", heal: "h" };

/** Map ActionChoice enum string → highlight colour. */
const ACTION_COLOR = {
  damage: "rgba(255,100,100,1)",
  shield: "rgba(80,160,255,1)",
  heal:   "rgba(100,220,100,1)",
};

/** Map Element enum string → display character (Unicode symbols). */
const ELEMENT_CHAR = { fire: "♦", earth: "▲", wind: "≋", water: "~" };

/** Map Element enum string → highlight colour. */
const ELEMENT_COLOR = {
  fire:  "rgba(255,120,40,1)",
  earth: "rgba(160,120,60,1)",
  wind:  "rgba(180,255,180,1)",
  water: "rgba(80,160,255,1)",
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
  const BAR_H = 10;
  const GAP = 4;
  const LABEL_W = 40;
  const ROW_H = BAR_H + GAP;
  const bx = x0 + LABEL_W;
  const bw = (x1 - x0) - LABEL_W;

  for (let i = 0; i < bars.length; i++) {
    const { label, value, frac, color, bg } = bars[i];
    const by = y + i * ROW_H;
    const f = Math.max(0, Math.min(1, frac));

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
  const players = entities.filter(e => e.team === "players");
  const enemies = entities.filter(e => e.team === "enemies");

  // --- Player bars ---
  const playerSummary = game.players;
  if (players.length > 0 && playerSummary && playerSummary.hp_max > 0) {
    let shieldCount = 0, healCount = 0;
    for (const e of players) {
      for (const slot of (e.combo ?? [])) {
        if (slot.action === "shield") shieldCount++;
        else if (slot.action === "heal") healCount++;
      }
    }
    const { hp_current, hp_max, shield_hp } = playerSummary;
    const scale = hp_max > 0 ? 1 / hp_max : 0;
    const projShield = shieldCount * ACTION_EFFECT_VALUE;
    const projHeal = healCount * ACTION_EFFECT_VALUE;

    // Three bars stacked; top of first bar sits just below the "ALLIES" label.
    const y = PLAYER_ZONE.y0 - 56; // leaves room for 3 × (10+4) = 42px + gap
    drawBars([
      { label: "HP", value: hp_current, frac: hp_current * scale, color: "rgba(60,200,60,0.9)", bg: C_HP_BG },
      { label: "Shld", value: shield_hp + projShield, frac: (shield_hp + projShield) * scale, color: "rgba(80,160,255,0.9)", bg: "rgba(20,20,80,0.6)" },
      { label: "Heal", value: projHeal, frac: projHeal * scale, color: "rgba(140,230,100,0.9)", bg: "rgba(20,50,20,0.6)" },
    ], PLAYER_ZONE.x0, PLAYER_ZONE.x1, y);
  }

  // --- Enemy bar + intent label ---
  const enemySummary = game.enemies;
  if (enemies.length > 0 && enemySummary && enemySummary.hp_max > 0) {
    const { hp_current, hp_max } = enemySummary;
    const scale = hp_max > 0 ? 1 / hp_max : 0;

    // One bar; align bottom with player bars bottom.
    const y = ENEMY_ZONE.y0 - 56 + 28; // vertically centred in the same strip
    drawBars([
      { label: "HP", value: hp_current, frac: hp_current * scale, color: "rgba(255,100,60,0.9)", bg: C_HP_BG },
    ], ENEMY_ZONE.x0, ENEMY_ZONE.x1, y);

    // Intent label: 1 damage per living enemy entity this round.
    const intentDmg = enemies.length;
    text(`Intent: -${intentDmg} dmg`, ENEMY_ZONE.x0, y + 24, 11, "rgba(255,160,100,0.85)");
  }
}

function drawActionMenu(game) {
  const mx = SW / 2 - 160;
  const my = SH - 110;
  const mw = 320;
  const mh = 90;

  rect(mx, my, mw, mh, C_MENU_BG);
  rectStroke(mx, my, mw, mh, 2, C_MENU_BORDER);

  text("[1] Atk",  mx + 10,       my + 14 + 16, 16, C_TEXT);
  text("[2] Shld", mx + 10 + 106, my + 14 + 16, 16, C_TEXT);
  text("[3] Heal", mx + 10 + 212, my + 14 + 16, 16, C_TEXT);
  text("[Q]♦", mx + 10,        my + 14 + 34, 13, ELEMENT_COLOR.fire);
  text("[W]▲", mx + 10 + 80,  my + 14 + 34, 13, ELEMENT_COLOR.earth);
  text("[E]≋", mx + 10 + 160, my + 14 + 34, 13, ELEMENT_COLOR.wind);
  text("[R]~", mx + 10 + 240, my + 14 + 34, 13, ELEMENT_COLOR.water);
  text("[Esc] Cancel", mx + 10, my + 14 + 50, 12, "rgba(180,180,180,0.8)");

  // Round timer bar
  const timerFrac = game.round_duration > 0
    ? Math.max(0, Math.min(1, game.round_timer / game.round_duration))
    : 0;
  rect(mx + 10, my + 58, mw - 20, 10, "rgba(30,30,30,0.8)");
  rect(mx + 10, my + 58, (mw - 20) * timerFrac, 10, "rgba(255,200,50,0.9)");
  text(`Round: ${game.round_timer !== undefined ? game.round_timer.toFixed(1) : "?"}s`, mx + 10, my + 82, 13, C_TEXT);
}

function drawGame(game, dt) {
  // Must come first: detects round boundary using previous frame's data.
  updateRoundTracking(game);
  tickFloaters(dt);

  clear();

  const wave = game.wave || "";
  text(`Wave: ${wave}`, 40, 30 + 20, 20, C_HEADER);

  text("ALLIES", PLAYER_ZONE.x0, PLAYER_ZONE.y0 - 62, 18, C_HEADER);
  text("ENEMIES", ENEMY_ZONE.x0, ENEMY_ZONE.y0 - 62, 18, C_ENEMY_HDR);

  drawTeamBars(game);

  drawTeam(game, "players", dt);
  drawTeam(game, "enemies", dt);

  drawActionMenu(game);

  // Floaters drawn last so they appear on top of everything.
  drawFloaters();
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
    case "lobby": drawLobby(msg.lobby); break;
    case "game": drawGame(msg.game, dt); break;
    case "game_over": drawGameOver(); break;
    default: drawConnecting();
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
  "q", "w", "e", "r",
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
