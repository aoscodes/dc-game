"use strict";

// ---------------------------------------------------------------------------
// LAYOUT — single source of truth for every on-screen position, size, and font.
//
// Want to move something?  Edit it here.  No draw function hard-codes pixels;
// they all read from this object.  Grouped by screen / region.
// ---------------------------------------------------------------------------
const LAYOUT = {
  screen: { w: 1024, h: 768 },
  bg: "#14141e",

  // Entity cell box (sprite drawn aspect-correct & centred inside it).
  cell: { w: 90, h: 100, sep: 12 },

  // Team play areas.  Widened from the original 310px-wide zones and the
  // 364px centre gap shrunk, so entities have room and rarely overlap.
  zones: {
    players: { x0: 30, x1: 470, y0: 200, y1: 620 },
    enemies: { x0: 554, x1: 994, y0: 200, y1: 620 },
    visible: true, // draw a faint backdrop + border so play areas are obvious
    bgFill: "rgba(255,255,255,0.03)",
    border: "rgba(180,200,255,0.18)",
    borderW: 2,
  },

  // Game-screen headers.
  headers: { waveX: 40, waveY: 50, waveFont: 20, labelDy: -62, labelFont: 18 },

  // Aggregate team HP/heal bars (drawn above each zone).
  teamBars: { dy: -42, barH: 10, gap: 4, labelW: 40, font: 10, dotGap: 38, dotDyPlayers: 30, dotDyEnemies: 16 },

  // Combo glyph row under each player entity.
  comboRow: { slotW: 18, maxSlots: 4, dy: 4, font: 14, textDy: 13 },

  // Enemy intent / combo lines stacked above each enemy sprite.
  intentLine: { lineH: 14, baseDy: -4, font: 11 },

  // Bottom action menu + round timer.
  actionMenu: {
    w: 320, h: 90, marginBottom: 110,
    padX: 10, padTopY: 14,
    actionRowDy: 16, actionFont: 16, actionCols: [0, 106, 212],
    elementRowDy: 34, elementFont: 13, elementCols: [0, 80, 160, 240],
    cancelRowDy: 50, cancelFont: 12,
    timerBarDy: 58, timerBarH: 10, timerTextDy: 82, timerTextFont: 13,
  },

  // Floating combat text.
  floater: { font: 16, drift: 40, jitter: 40, stack: 22, lifetime: 1.5 },

  // Pre-lobby / stat editor.
  preLobby: {
    titleX: 40, titleY: 60, titleFont: 32,
    optX: 60, optY0: 160, optGap: 40, optFont: 22,
    errorDy: 100, errorFont: 18,
    codePromptY: 160, codeY: 210, codeFont: 36, codeHintY: 270, codeHintFont: 16,
    statTitleY: 100, statTitleFont: 24, statHintY: 130, statHintFont: 14,
    statRowH: 38, statStartY: 168, statLabelX: 70, statLabelFont: 20,
    statHiX: 50, statHiW: 480,
    statBarX: 220, statBarW: 300, statBarH: 14, statValX: 534,
  },

  // Lobby list.
  lobby: {
    titleX: 40, titleY: 52, titleFont: 32,
    codeX: 40, codeY: 92, codeFont: 22,
    listY: 130, rowGap: 36, rowDy: 20, rowX: 60, rowFont: 20,
    readyDy: 20, readyFont: 18,
  },

  connecting: { x: 40, y: 60, font: 24 },
  full: { x: 40, titleDy: -16, titleFont: 24, subDy: 16, subFont: 18 },
  gameOver: { x: 40, font: 24 },
};

// Derived convenience aliases (read-only mirrors of LAYOUT).
const SW = LAYOUT.screen.w;
const SH = LAYOUT.screen.h;
const CELL_W = LAYOUT.cell.w;
const CELL_H = LAYOUT.cell.h;
const PLAYER_ZONE = LAYOUT.zones.players;
const ENEMY_ZONE = LAYOUT.zones.enemies;

const C_BG = LAYOUT.bg ?? "#14141e";
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

const CLASSES = ["player", "grunt", "archer", "shaman", "boss"];

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
 *
 * Uses rejection sampling with a *radial* separation test (so diagonal
 * near-overlaps are also rejected, unlike the old axis-OR test).  If no
 * fully-separated spot is found within MAX_TRIES, returns the best candidate
 * seen (the one maximising distance to its nearest neighbour) rather than an
 * unvalidated random point — so crowded zones degrade gracefully instead of
 * piling sprites on top of each other.
 *
 * @param {{ x0:number, x1:number, y0:number, y1:number }} zone
 * @returns {{ x: number, y: number }}
 */
function assignPosition(zone) {
  const MAX_TRIES = 200;
  const SEP = CELL_W + LAYOUT.cell.sep; // minimum centre-to-centre distance
  const SEP2 = SEP * SEP;
  const existing = [...entityPositions.values()];

  const spanX = zone.x1 - zone.x0 - CELL_W;
  const spanY = zone.y1 - zone.y0 - CELL_H;

  // Nearest-neighbour squared distance for a candidate (Infinity if none).
  const nearest2 = (x, y) => {
    let best = Infinity;
    for (const p of existing) {
      const dx = p.x - x, dy = p.y - y;
      const d2 = dx * dx + dy * dy;
      if (d2 < best) best = d2;
    }
    return best;
  };

  let bestPos = null;
  let bestDist2 = -1;

  for (let i = 0; i < MAX_TRIES; i++) {
    const x = zone.x0 + Math.random() * Math.max(0, spanX);
    const y = zone.y0 + Math.random() * Math.max(0, spanY);
    const d2 = nearest2(x, y);
    if (d2 >= SEP2) return { x, y };
    if (d2 > bestDist2) { bestDist2 = d2; bestPos = { x, y }; }
  }

  return bestPos ?? { x: zone.x0, y: zone.y0 };
}

function clearEntityState() {
  entityPositions.clear();
  animState.clear();
  floaters.length = 0;
  lastRoundSeen = -1;
  lastEntitiesSnapshot    = [];
  lastEnemyIntentSnapshot = null;
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
  const L = LAYOUT.connecting;
  text("Connecting to server...", L.x, L.y, L.font, C_TEXT);
}

// ---------------------------------------------------------------------------
// Pre-lobby screen (create / join)
// ---------------------------------------------------------------------------

/**
 * "choose"        — show Create / Join options
 * "entering_code" — user is typing a 6-char lobby code
 * "editing_stats" — player is adjusting their statblock before creating/joining
 */
let preLobbyMode  = "choose";
let preLobbyCode  = "";
let preLobbyError = "";

/** Ordered list of stat keys shown in the editor (display order). */
const STAT_KEYS = ["hp", "attack", "shield", "heal", "fire", "earth", "wind", "water", "level"];

/** Default statblock values (applied on each pre_lobby entry). */
const DEFAULT_STATS = { hp: 120, attack: 1, shield: 1, heal: 1, fire: 1, earth: 1, wind: 1, water: 1, level: 1 };

/** Reset all pre-lobby state (called on server pre_lobby / joining / error messages). */
function resetPreLobby() {
  _krStop();
  preLobbyMode          = "choose";
  preLobbyCode          = "";
  preLobbyError         = "";
  preLobbyStats         = { ...DEFAULT_STATS };
  preLobbyPendingAction = null;
  preLobbyStatCursor    = 0;
}

/** Mutable statblock for the current session (reset on pre_lobby entry). */
let preLobbyStats = { hp: 120, attack: 1, shield: 1, heal: 1, fire: 1, earth: 1, wind: 1, water: 1, level: 1 };

/** Index into STAT_KEYS indicating the currently selected row. */
let preLobbyStatCursor = 0;

/**
 * Pending create-or-join action; stored while player edits stats.
 * @type {{ action: string, code?: string } | null}
 */
let preLobbyPendingAction = null;

// Key-repeat state for stat value adjustment (ArrowLeft / ArrowRight).
let _krKey      = null;   // "ArrowLeft" | "ArrowRight" | null
let _krTimer    = null;
let _krStart    = 0;
let _krDelta    = 0;      // +1 or -1

function _krStop() {
  _krKey = null;
  if (_krTimer !== null) { clearTimeout(_krTimer); _krTimer = null; }
}

function _krSchedule() {
  const elapsed = Date.now() - _krStart;
  const delay   = Math.max(30, 400 - elapsed * 0.6);
  _krTimer = setTimeout(_krTick, delay);
}

function _krTick() {
  if (_krKey === null) return;
  _adjustStat(_krDelta);
  _krSchedule();
}

function _adjustStat(delta) {
  const key = STAT_KEYS[preLobbyStatCursor];
  preLobbyStats[key] = Math.max(1, Math.min(100, (preLobbyStats[key] || 1) + delta));
}

function drawPreLobby() {
  clear();
  const L = LAYOUT.preLobby;
  text("Dragoncon Game", L.titleX, L.titleY, L.titleFont, C_HEADER);

  if (preLobbyMode === "choose") {
    text("[C]  Create new lobby", L.optX, L.optY0, L.optFont, C_TEXT);
    text("[J]  Join existing lobby", L.optX, L.optY0 + L.optGap, L.optFont, C_TEXT);
    if (preLobbyError) {
      text(preLobbyError, L.optX, L.optY0 + L.optGap + L.errorDy, L.errorFont, "rgba(255,100,100,1)");
    }
  } else if (preLobbyMode === "entering_code") {
    text("Enter lobby code:", L.optX, L.codePromptY, L.optFont, C_TEXT);
    // Show typed code + blinking underscore cursor.
    const display = preLobbyCode.padEnd(6, "_");
    text(display, L.optX, L.codeY, L.codeFont, "rgba(255,255,100,1)");
    text("[ENTER] to confirm    [ESC] back", L.optX, L.codeHintY, L.codeHintFont, "rgba(170,170,170,1)");
    if (preLobbyError) {
      text(preLobbyError, L.optX, L.codeHintY + 40, L.errorFont, "rgba(255,100,100,1)");
    }
  } else if (preLobbyMode === "editing_stats") {
    text("Customise stats", L.optX, L.statTitleY, L.statTitleFont, C_HEADER);
    text("[UP/DOWN] change value    [ENTER] confirm    [ESC] back", L.optX, L.statHintY, L.statHintFont, "rgba(170,170,170,1)");

    for (let i = 0; i < STAT_KEYS.length; i++) {
      const key = STAT_KEYS[i];
      const val = preLobbyStats[key] || 1;
      const y   = L.statStartY + i * L.statRowH;
      const sel = i === preLobbyStatCursor;

      if (sel) {
        // Highlight row background.
        ctx.save();
        ctx.fillStyle = "rgba(255,255,100,0.12)";
        ctx.fillRect(L.statHiX, y - 14, L.statHiW, L.statRowH - 4);
        ctx.restore();
      }

      const label = key.charAt(0).toUpperCase() + key.slice(1);
      text(label, L.statLabelX, y, L.statLabelFont, sel ? C_CURSOR : C_TEXT);

      // Value bar (0-100 mapped to statBarW px wide).
      const barY = y - L.statBarH / 2 + 2;
      ctx.save();
      ctx.fillStyle = "rgba(60,60,80,0.7)";
      ctx.fillRect(L.statBarX, barY, L.statBarW, L.statBarH);
      ctx.fillStyle = sel ? "rgba(255,255,80,0.85)" : "rgba(80,180,255,0.75)";
      ctx.fillRect(L.statBarX, barY, L.statBarW * (val / 100), L.statBarH);
      ctx.restore();

      text(String(val).padStart(3, " "), L.statValX, y, L.statLabelFont, sel ? C_CURSOR : C_TEXT);
    }
  }
}

function drawFull() {
  clear();
  const L = LAYOUT.full;
  text("Session full (max 6 players).", L.x, SH / 2 + L.titleDy, L.titleFont, C_TEXT);
  text("Close another tab to free a slot.", L.x, SH / 2 + L.subDy, L.subFont, C_TEXT);
}

function drawLobby(lobby) {
  clear();
  const L = LAYOUT.lobby;
  text("Dragoncon Game", L.titleX, L.titleY, L.titleFont, C_HEADER);

  const joinCode = lobby.join_code || "??????";
  text(`Room: ${joinCode}`, L.codeX, L.codeY, L.codeFont, C_TEXT);

  const players = lobby.players || [];
  players.forEach((p, i) => {
    const y = L.listY + i * L.rowGap + L.rowDy;
    const color = p.id === lobby.player_id ? "rgba(255,255,100,1)" : C_TEXT;
    const ready = p.ready ? "[READY]" : "[     ]";
    const conn = p.connected ? "" : " (disconnected)";
    text(`${p.name}  ${p.kind}  ${ready}${conn}`, L.rowX, y, L.rowFont, color);
  });

  const pickerY = L.listY + 6 * L.rowGap + L.readyDy;
  const readyLabel = lobby.ready ? "Press ENTER to un-ready" : "Press ENTER when ready";
  text(readyLabel, L.rowX, pickerY, L.readyFont, C_TEXT);
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
  const sp = sprites.get(e.kind);
  if (!sp) return;

  const { img, meta } = sp;
  const { frame_w, frame_h, clips } = meta;
  const { frame } = tickAnimator(e.id, e.kind, lastAction, dt);
  const clip = clips[animState.get(e.id)?.clip ?? "idle"] ?? clips["idle"];

  const srcX = frame * frame_w;
  const srcY = clip.row * frame_h;

  // Fit the native sprite into the cell preserving aspect ratio (no stretch),
  // then centre it within the cell box.
  const scale = Math.min(CELL_W / frame_w, CELL_H / frame_h);
  const dw = frame_w * scale;
  const dh = frame_h * scale;
  const dx = cx + (CELL_W - dw) / 2;
  const dy = cy + (CELL_H - dh) / 2;

  ctx.save();
  ctx.imageSmoothingEnabled = false;

  if (flip) {
    // Flip around the destination rect's horizontal centre.
    ctx.translate(dx + dw, dy);
    ctx.scale(-1, 1);
    ctx.drawImage(img, srcX, srcY, frame_w, frame_h, 0, 0, dw, dh);
  } else {
    ctx.drawImage(img, srcX, srcY, frame_w, frame_h, dx, dy, dw, dh);
  }

  ctx.restore();
}

/** Draw a faint backdrop + border for a team zone so play areas are obvious. */
function drawZone(zone) {
  const Z = LAYOUT.zones;
  if (!Z.visible) return;
  rect(zone.x0, zone.y0, zone.x1 - zone.x0, zone.y1 - zone.y0, Z.bgFill);
  rectStroke(zone.x0, zone.y0, zone.x1 - zone.x0, zone.y1 - zone.y0, Z.borderW, Z.border);
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
      const CR = LAYOUT.comboRow;
      const rowW = CR.maxSlots * CR.slotW;
      const rowX = cx + (CELL_W - rowW) / 2;
      const rowY = cy + CELL_H + CR.dy;

      for (let i = 0; i < CR.maxSlots; i++) {
        const slotX = rowX + i * CR.slotW;
        const slot = entityCombo[i];
        if (slot && slot.action !== undefined) {
          text(ACTION_CHAR[slot.action] ?? "?", slotX, rowY + CR.textDy, CR.font,
            ACTION_COLOR[slot.action] ?? C_TEXT);
        } else if (slot && slot.element !== undefined) {
          text(ELEMENT_CHAR[slot.element] ?? "?", slotX, rowY + CR.textDy, CR.font,
            ELEMENT_COLOR[slot.element] ?? C_TEXT);
        } else {
          text("·", slotX, rowY + CR.textDy, CR.font, "rgba(120,120,140,0.5)");
        }
      }
    } else {
      // Enemy: show per-action lines above the sprite.
      // Format per line: "[element_char] action_label [±value]"
      // Intent contributes 1 damage action of intent.element per entity.
      // Combo contributes its parsed elemented actions.
      // Colour: element colour if elemental, else action colour.
      const lines = [];

      // Intent: 1 damage of intent.element (shared across all enemies).
      const intent = game.enemy_intent;
      if (intent && intent.damage > 0) {
        const el     = intent.element ?? null;
        const elChar = el ? (ELEMENT_CHAR[el] ?? "") : "";
        const color  = el ? (ELEMENT_COLOR[el] ?? ACTION_COLOR.damage) : ACTION_COLOR.damage;
        const prefix = elChar ? `${elChar} ` : "";
        lines.push({ str: `${prefix}dmg -1`, color });
      }

      // Combo: detect special groups first, then render remaining actions individually.
      const combo           = e.combo ?? [];
      const dotTriggers     = detectDotTriggers(combo);
      const cleanseTriggers = detectCleanseTriggers(combo);
      const consumed        = new Set([...dotTriggers, ...cleanseTriggers]);

      for (const el of dotTriggers) {
        lines.push({ str: `${ELEMENT_CHAR[el] ?? el} DoT +1`, color: ELEMENT_COLOR[el] ?? ACTION_COLOR.damage });
      }
      for (const el of cleanseTriggers) {
        lines.push({ str: `${ELEMENT_CHAR[el] ?? el} Clr 1`, color: ELEMENT_COLOR[el] ?? ACTION_COLOR.heal });
      }

      for (const { action, element } of parseComboSlots(combo)) {
        if (element && consumed.has(element)) continue; // already shown as special label
        const elChar = element ? (ELEMENT_CHAR[element] ?? "") : "";
        const color  = element ? (ELEMENT_COLOR[element] ?? ACTION_COLOR[action] ?? C_TEXT)
                               : (ACTION_COLOR[action] ?? C_TEXT);
        const prefix = elChar ? `${elChar} ` : "";
        const label  = action === "damage" ? "dmg"
                     : action === "shield" ? "shld"
                     : "heal";
        const sign   = action === "damage" ? `-${ACTION_EFFECT_VALUE}` : `+${ACTION_EFFECT_VALUE}`;
        lines.push({ str: `${prefix}${label} ${sign}`, color });
      }

      // Render bottom-to-top above the sprite: last line sits just above cy.
      const IL = LAYOUT.intentLine;
      const baseY  = cy + IL.baseDy;
      for (let i = 0; i < lines.length; i++) {
        const lineY = baseY - (lines.length - 1 - i) * IL.lineH;
        text(lines[i].str, cx, lineY, IL.font, lines[i].color);
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
function spawnFloater(text, x, y, color, lifetime = LAYOUT.floater.lifetime) {
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
    const yOffset  = -LAYOUT.floater.drift * frac; // drift upward over lifetime

    // Strip any existing alpha from the color string and reapply via globalAlpha.
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font        = `bold ${LAYOUT.floater.font}px monospace`;
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
 * Group combo slots by element token and return element names that satisfy
 * `predicate(dmgCount, healCount, shieldCount)`.  Mirrors the Zig
 * detect_dot_triggers / detect_cleanse_triggers group semantics exactly.
 *
 * @param {Array<{action?:string, element?:string}>} slots
 * @param {(dc:number, hc:number, sc:number) => boolean} predicate
 * @returns {Set<string>}
 */
function detectSpecialGroups(slots, predicate) {
  const result = new Set();
  let el = null, dc = 0, hc = 0, sc = 0;
  const flush = () => { if (el && predicate(dc, hc, sc)) result.add(el); };
  for (const slot of slots) {
    if (slot.element !== undefined) {
      flush();
      el = slot.element; dc = 0; hc = 0; sc = 0;
    } else if (slot.action !== undefined && el !== null) {
      if      (slot.action === "damage") dc++;
      else if (slot.action === "heal")   hc++;
      else if (slot.action === "shield") sc++;
    }
  }
  flush();
  return result;
}

/** Returns Set of element names whose group is exactly {dmg, heal} → DoT trigger. */
const detectDotTriggers     = s => detectSpecialGroups(s, (dc, hc, sc) => dc === 1 && hc === 1 && sc === 0);

/** Returns Set of element names whose group is exactly {heal, shield} → cleanse trigger. */
const detectCleanseTriggers = s => detectSpecialGroups(s, (dc, hc, sc) => hc === 1 && sc === 1 && dc === 0);

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
function spawnRoundSummaryFloaters(game, prevEntities, prevEnemyIntent, prevDotStacks) {
  const tally = tallyPlayerActions(prevEntities);

  // Centre points for spawn zones.
  const ex = (ENEMY_ZONE.x0 + ENEMY_ZONE.x1) / 2;
  const ey = (ENEMY_ZONE.y0 + ENEMY_ZONE.y1) / 2;
  const px = (PLAYER_ZONE.x0 + PLAYER_ZONE.x1) / 2;
  const py = (PLAYER_ZONE.y0 + PLAYER_ZONE.y1) / 2;

  // Small random X jitter so stacked floaters spread slightly.
  const jitter = () => (Math.random() - 0.5) * LAYOUT.floater.jitter;
  const STACK = LAYOUT.floater.stack;

  let floaterY = ey; // stack floaters vertically in the enemy zone

  for (const [element, counts] of tally) {
    const elChar  = element === "none" ? ""   : (ELEMENT_CHAR[element]  ?? "");
    const elColor = element === "none" ? "rgba(255,100,100,1)" : (ELEMENT_COLOR[element] ?? "rgba(255,100,100,1)");

    if (counts.damage > 0) {
      const label = element === "none"
        ? `-${counts.damage}`
        : `-${counts.damage} ${elChar}`;
      spawnFloater(label, ex + jitter(), floaterY, elColor);
      floaterY += STACK;
    }

    // Show "blocked N" for the amount of enemy damage actually cancelled this round.
    // blocked = min(player shield count, enemy damage of same element).
    // Enemy damage for this element = intent damage (if intent.element matches) + 0 (no enemy combos shown client-side).
    // We approximate using prevEnemyIntent element match for the "none" bucket only;
    // for other elements the intent element may differ, so we use Math.min conservatively.
    const intentMatchesElement = prevEnemyIntent
      ? ((prevEnemyIntent.element ?? null) === (element === "none" ? null : element))
      : false;
    const intentDmgForElement = (intentMatchesElement && prevEnemyIntent) ? prevEnemyIntent.damage : 0;
    const blocked = Math.min(counts.shield, intentDmgForElement);
    if (blocked > 0) {
      const shieldColor = element === "none"
        ? "rgba(80,160,255,1)"
        : (ELEMENT_COLOR[element] ?? "rgba(80,160,255,1)");
      const label = element === "none"
        ? `blocked ${blocked * ACTION_EFFECT_VALUE}`
        : `blocked ${blocked * ACTION_EFFECT_VALUE} ${elChar}`;
      spawnFloater(label, px + jitter(), py, shieldColor);
    }

    if (counts.heal > 0) {
      const label = element === "none"
        ? `+${counts.heal} heal`
        : `+${counts.heal} heal ${elChar}`;
      spawnFloater(label, px + jitter(), py + STACK, "rgba(100,220,100,1)");
    }
  }

  // Enemy intent floater: use the snapshotted intent from the round that just resolved.
  const intent = prevEnemyIntent;
  if (intent && intent.damage > 0) {
    const elChar  = intent.element ? (ELEMENT_CHAR[intent.element]  ?? "") : "";
    const elColor = intent.element ? (ELEMENT_COLOR[intent.element] ?? "rgba(255,80,80,1)") : "rgba(255,80,80,1)";
    const label = elChar ? `-${intent.damage} ${elChar}` : `-${intent.damage}`;
    spawnFloater(label, px + jitter(), py - STACK, elColor);
  }

  // DoT tick floaters — show elemental ticks on each side.
  // prevDotStacks contains the stack counts at the moment the round fired.
  // A non-zero stack on a side means it ticked damage this round.
  if (prevDotStacks) {
    // DoT on enemy side: stacks in prevDotStacks.enemies dealt damage to enemies.
    let dotEnemyY = ey + STACK + 6;
    for (let i = 0; i < 4; i++) {
      const elName = ELEMENT_NAMES[i];
      const stacks = prevDotStacks.enemies[elName];
      if (!stacks || stacks === 0) continue;
      const color  = ELEMENT_COLOR[elName] ?? "rgba(255,100,100,1)";
      spawnFloater(`${ELEMENT_CHAR[elName]} dot -${stacks * ACTION_EFFECT_VALUE}`, ex + jitter(), dotEnemyY, color);
      dotEnemyY += STACK;
    }
    // DoT on player side: stacks in prevDotStacks.players dealt damage to players.
    let dotPlayerY = py + STACK * 2 + 6;
    for (let i = 0; i < 4; i++) {
      const elName = ELEMENT_NAMES[i];
      const stacks = prevDotStacks.players[elName];
      if (!stacks || stacks === 0) continue;
      const color  = ELEMENT_COLOR[elName] ?? "rgba(255,100,100,1)";
      spawnFloater(`${ELEMENT_CHAR[elName]} dot -${stacks * ACTION_EFFECT_VALUE}`, px + jitter(), dotPlayerY, color);
      dotPlayerY += STACK;
    }
  }
}

// ---------------------------------------------------------------------------
// Round tracking state
// ---------------------------------------------------------------------------

let lastRoundSeen    = -1;
/** Shallow copy of game.entities from the previous frame. */
let lastEntitiesSnapshot = [];
/** Copy of game.enemy_intent from the previous frame (used in round-boundary floaters). */
let lastEnemyIntentSnapshot = null;
/** Copy of game.dot_stacks from the previous frame (used in round-boundary floaters). */
let lastDotStacksSnapshot = null;

/**
 * Call at the start of every drawGame frame.
 * Detects round boundary, spawns floaters from the previous frame's entities,
 * then updates the snapshot for the next round.
 */
function updateRoundTracking(game) {
  if (game.round !== lastRoundSeen && lastRoundSeen !== -1) {
    spawnRoundSummaryFloaters(game, lastEntitiesSnapshot, lastEnemyIntentSnapshot, lastDotStacksSnapshot);
  }
  lastRoundSeen = game.round;
  // Snapshot current entities, intent and dot_stacks so they're available next frame if a round fires.
  lastEntitiesSnapshot     = (game.entities ?? []).slice();
  lastEnemyIntentSnapshot  = game.enemy_intent ?? null;
  lastDotStacksSnapshot    = game.dot_stacks ?? null;
}

/** Map ActionChoice enum string → display character. */
const ACTION_CHAR = { damage: "a", shield: "s", heal: "h" };

/** Map ActionChoice enum string → highlight colour. */
const ACTION_COLOR = {
  damage: "rgba(255,100,100,1)",
  shield: "rgba(80,160,255,1)",
  heal:   "rgba(100,220,100,1)",
};

/** Element ordinal → name string; matches protocol Element ordinal order. */
const ELEMENT_NAMES = ["fire", "earth", "wind", "water"];

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
  const TB = LAYOUT.teamBars;
  const ROW_H = TB.barH + TB.gap;
  const bx = x0 + TB.labelW;
  const bw = (x1 - x0) - TB.labelW;

  for (let i = 0; i < bars.length; i++) {
    const { label, value, frac, color, bg } = bars[i];
    const by = y + i * ROW_H;
    const f = Math.max(0, Math.min(1, frac));

    text(label, x0, by + TB.barH - 2, TB.font, "rgba(180,200,255,0.85)");
    rect(bx, by, bw, TB.barH, bg);
    if (f > 0) rect(bx, by, bw * f, TB.barH, color);
    text(String(Math.round(value)), bx + bw + 4, by + TB.barH - 2, TB.font, "rgba(180,200,255,0.7)");
  }
}

/**
 * Draw aggregate player-team bars (HP, projected heal) above the player zone.
 * Draw aggregate enemy-team HP bar above the enemy zone.
 * Shield pools are removed — shields cancel damage within the round, no bar needed.
 */
function drawTeamBars(game) {
  const entities = game.entities || [];
  const players = entities.filter(e => e.team === "players");
  const enemies = entities.filter(e => e.team === "enemies");

  // --- Player bars ---
  const playerSummary = game.players;
  if (players.length > 0 && playerSummary && playerSummary.hp_max > 0) {
    let healCount = 0;
    for (const e of players) {
      for (const slot of (e.combo ?? [])) {
        if (slot.action === "heal") healCount++;
      }
    }
    const { hp_current, hp_max } = playerSummary;
    const scale = hp_max > 0 ? 1 / hp_max : 0;
    const projHeal = healCount * ACTION_EFFECT_VALUE;

    // Two bars stacked; top sits just below the "ALLIES" label.
    const y = PLAYER_ZONE.y0 + LAYOUT.teamBars.dy;
    drawBars([
      { label: "HP",   value: hp_current, frac: hp_current * scale, color: "rgba(60,200,60,0.9)",   bg: C_HP_BG },
      { label: "Heal", value: projHeal,   frac: projHeal   * scale, color: "rgba(140,230,100,0.9)", bg: "rgba(20,50,20,0.6)" },
    ], PLAYER_ZONE.x0, PLAYER_ZONE.x1, y);

    // DoT stacks on the player party (applied by enemies).
    const dotP = game.dot_stacks?.players;
    if (dotP) {
      let dx = PLAYER_ZONE.x0;
      for (let i = 0; i < 4; i++) {
        const elName = ELEMENT_NAMES[i];
        if (!dotP[elName]) continue;
        text(`${ELEMENT_CHAR[elName]}×${dotP[elName]}`, dx, y + LAYOUT.teamBars.dotDyPlayers, LAYOUT.teamBars.font, ELEMENT_COLOR[elName]);
        dx += LAYOUT.teamBars.dotGap;
      }
    }
  }

  // --- Enemy HP bar ---
  const enemySummary = game.enemies;
  if (enemies.length > 0 && enemySummary && enemySummary.hp_max > 0) {
    const { hp_current, hp_max } = enemySummary;
    const scale = hp_max > 0 ? 1 / hp_max : 0;

    // One bar; vertically centred in the same strip.
    const y = ENEMY_ZONE.y0 + LAYOUT.teamBars.dy;
    drawBars([
      { label: "HP", value: hp_current, frac: hp_current * scale, color: "rgba(255,100,60,0.9)", bg: C_HP_BG },
    ], ENEMY_ZONE.x0, ENEMY_ZONE.x1, y);

    // DoT stacks on the enemy side (applied by players).
    const dotE = game.dot_stacks?.enemies;
    if (dotE) {
      let dx = ENEMY_ZONE.x0;
      for (let i = 0; i < 4; i++) {
        const elName = ELEMENT_NAMES[i];
        if (!dotE[elName]) continue;
        text(`${ELEMENT_CHAR[elName]}×${dotE[elName]}`, dx, y + LAYOUT.teamBars.dotDyEnemies, LAYOUT.teamBars.font, ELEMENT_COLOR[elName]);
        dx += LAYOUT.teamBars.dotGap;
      }
    }
  }
}

function drawActionMenu(game) {
  const M = LAYOUT.actionMenu;
  const mx = SW / 2 - M.w / 2;
  const my = SH - M.marginBottom;
  const mw = M.w;
  const mh = M.h;

  rect(mx, my, mw, mh, C_MENU_BG);
  rectStroke(mx, my, mw, mh, 2, C_MENU_BORDER);

  const px = mx + M.padX;
  const aRowY = my + M.padTopY + M.actionRowDy;
  text("[1] Atk",  px + M.actionCols[0], aRowY, M.actionFont, C_TEXT);
  text("[2] Shld", px + M.actionCols[1], aRowY, M.actionFont, C_TEXT);
  text("[3] Heal", px + M.actionCols[2], aRowY, M.actionFont, C_TEXT);

  const eRowY = my + M.padTopY + M.elementRowDy;
  text("[Q]♦", px + M.elementCols[0], eRowY, M.elementFont, ELEMENT_COLOR.fire);
  text("[W]▲", px + M.elementCols[1], eRowY, M.elementFont, ELEMENT_COLOR.earth);
  text("[E]≋", px + M.elementCols[2], eRowY, M.elementFont, ELEMENT_COLOR.wind);
  text("[R]~", px + M.elementCols[3], eRowY, M.elementFont, ELEMENT_COLOR.water);

  text("[Esc] Cancel", px, my + M.padTopY + M.cancelRowDy, M.cancelFont, "rgba(180,180,180,0.8)");

  // Round timer bar
  const timerFrac = game.round_duration > 0
    ? Math.max(0, Math.min(1, game.round_timer / game.round_duration))
    : 0;
  const tbw = mw - M.padX * 2;
  rect(px, my + M.timerBarDy, tbw, M.timerBarH, "rgba(30,30,30,0.8)");
  rect(px, my + M.timerBarDy, tbw * timerFrac, M.timerBarH, "rgba(255,200,50,0.9)");
  text(`Round: ${game.round_timer !== undefined ? game.round_timer.toFixed(1) : "?"}s`, px, my + M.timerTextDy, M.timerTextFont, C_TEXT);
}

function drawGame(game, dt) {
  // Must come first: detects round boundary using previous frame's data.
  updateRoundTracking(game);
  tickFloaters(dt);

  clear();

  // Faint backdrops so the play areas are obvious.
  drawZone(PLAYER_ZONE);
  drawZone(ENEMY_ZONE);

  const H = LAYOUT.headers;
  const wave = game.wave || "";
  text(`Wave: ${wave}`, H.waveX, H.waveY, H.waveFont, C_HEADER);

  text("ALLIES", PLAYER_ZONE.x0, PLAYER_ZONE.y0 + H.labelDy, H.labelFont, C_HEADER);
  text("ENEMIES", ENEMY_ZONE.x0, ENEMY_ZONE.y0 + H.labelDy, H.labelFont, C_ENEMY_HDR);

  drawTeamBars(game);

  drawTeam(game, "players", dt);
  drawTeam(game, "enemies", dt);

  drawActionMenu(game);

  // Floaters drawn last so they appear on top of everything.
  drawFloaters();
}

function drawGameOver() {
  clear();
  const L = LAYOUT.gameOver;
  text("Game Over!  Press any key to return to lobby.", L.x, SH / 2, L.font, C_TEXT);
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
    case "pre_lobby":  drawPreLobby(); break;
    case "connecting": drawConnecting(); break;
    case "lobby":      drawLobby(msg.lobby); break;
    case "game":       drawGame(msg.game, dt); break;
    case "game_over":  drawGameOver(); break;
    default:           drawConnecting();
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

    if (msg.tag === "render") {
      latestMsg = msg;
    } else if (msg.tag === "pre_lobby") {
      // Bridge is asking us to pick a room.
      resetPreLobby();
      latestMsg = { phase: "pre_lobby" };
    } else if (msg.tag === "joining") {
      // Bridge confirmed the room exists and is connecting us.
      // Switch to connecting screen immediately so the user gets feedback
      // and any stale error text disappears.
      resetPreLobby();
      latestMsg = { phase: "connecting" };
    } else if (msg.tag === "error") {
      // Only show an error to the user when they explicitly submitted a code.
      // If the error came from an auto-reconnect (preLobbyMode === "choose" and
      // preLobbyCode is empty), just clear stale localStorage silently.
      const userInitiated = preLobbyMode === "entering_code" ||
                            preLobbyMode === "editing_stats"  ||
                            preLobbyCode.length > 0;
      const errMsg = msg.reason === "not_found" ? "Lobby not found." : `Error: ${msg.reason}`;
      resetPreLobby();
      preLobbyError = userInitiated ? errMsg : "";
      latestMsg = { phase: "pre_lobby" };
    } else if (msg.tag === "full") {
      drawFull();
    }
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
  // During pre_lobby, handle input locally — do not forward to Zig.
  if (latestMsg && latestMsg.phase === "pre_lobby") {
    handlePreLobbyKey(e);
    return;
  }

  if (!FORWARDED_KEYS.has(e.key)) return;
  e.preventDefault();
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ key: e.key }));
  }
});

document.addEventListener("keyup", (e) => {
  // Stop key-repeat when ArrowLeft/Right released in stat editor.
  if (preLobbyMode === "editing_stats" && e.key === _krKey) {
    _krStop();
  }
});

/**
 * Handle a keydown event while the pre_lobby screen is shown.
 * Input is handled entirely in the browser — nothing is forwarded to Zig.
 * @param {KeyboardEvent} e
 */
function handlePreLobbyKey(e) {
  e.preventDefault();

  if (preLobbyMode === "choose") {
    if (e.key === "c" || e.key === "C") {
      preLobbyError         = "";
      preLobbyPendingAction = { action: "create" };
      preLobbyMode          = "editing_stats";
      preLobbyStatCursor    = 0;
    } else if (e.key === "j" || e.key === "J") {
      preLobbyMode  = "entering_code";
      preLobbyCode  = "";
      preLobbyError = "";
    }
    return;
  }

  if (preLobbyMode === "entering_code") {
    if (e.key === "Escape") {
      preLobbyMode  = "choose";
      preLobbyCode  = "";
      preLobbyError = "";
      return;
    }
    if (e.key === "Backspace") {
      preLobbyCode  = preLobbyCode.slice(0, -1);
      preLobbyError = "";
      return;
    }
    if (e.key === "Enter") {
      if (preLobbyCode.length === 6) {
        preLobbyError         = "";
        preLobbyPendingAction = { action: "join", code: preLobbyCode };
        preLobbyMode          = "editing_stats";
        preLobbyStatCursor    = 0;
      } else {
        preLobbyError = "Code must be 6 characters.";
      }
      return;
    }
    // Accept alphanumeric characters (auto-uppercase, max 6).
    if (preLobbyCode.length < 6 && /^[a-zA-Z0-9]$/.test(e.key)) {
      preLobbyCode  += e.key.toUpperCase();
      preLobbyError = "";
    }
    return;
  }

  if (preLobbyMode === "editing_stats") {
    if (e.key === "Escape") {
      _krStop();
      // Go back: to entering_code if joining, to choose if creating.
      if (preLobbyPendingAction && preLobbyPendingAction.action === "join") {
        preLobbyMode = "entering_code";
      } else {
        preLobbyMode = "choose";
      }
      return;
    }
    if (e.key === "Enter") {
      _krStop();
      if (preLobbyPendingAction && ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ ...preLobbyPendingAction, stats: { ...preLobbyStats } }));
      }
      return;
    }
    if (e.key === "ArrowUp") {
      preLobbyStatCursor = (preLobbyStatCursor - 1 + STAT_KEYS.length) % STAT_KEYS.length;
      _krStop();
      return;
    }
    if (e.key === "ArrowDown") {
      preLobbyStatCursor = (preLobbyStatCursor + 1) % STAT_KEYS.length;
      _krStop();
      return;
    }
    // Key-repeat for value adjustment.
    if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
      if (_krKey !== e.key) {
        _krStop();
        _krKey   = e.key;
        _krDelta = e.key === "ArrowRight" ? 1 : -1;
        _krStart = Date.now();
        _adjustStat(_krDelta);
        _krSchedule();
      }
      return;
    }
  }
}

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
