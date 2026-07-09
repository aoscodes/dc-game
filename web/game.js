"use strict";

const LAYOUT = {
  screen: { w: 1024, h: 768 },
  bg: "#14141e",

  // Slime field: zone columns eaten left-to-right, one per round.
  slimeField: {
    x0: 40, x1: 984, y0: 220, y1: 620,
    labelDy: 24, labelFont: 14,
    activeBorder: "rgba(255,255,100,0.85)",
    border: "rgba(180,200,255,0.25)",
    eatenFill: "rgba(20,20,30,0.75)",
    blobMinR: 10, blobRScale: 4.5,
    blobFont: 12,
  },

  hungerBar: {
    x0: 40, x1: 984, y: 150, h: 18,
    labelFont: 14, labelDy: -8,
    bg: "rgba(30,10,10,0.78)",
    fill: "rgba(255,150,50,0.9)",
    danger: "rgba(255,60,60,0.95)",
    textFont: 13,
  },

  score: { x: 40, y: 90, font: 20 },

  headers: { waveX: 40, waveY: 50, waveFont: 20, labelDy: -30, labelFont: 18 },

  // Per-player pending-combo rows, bottom-left beside the action menu.
  comboPanel: { x: 24, y0: 652, rowH: 18, font: 13, slotW: 14, nameW: 42 },

  // Cosmetic critters: one spawns per player entity (see tickLilGuys).
  lilGuys: { size: 48, speed: 60, chompMin: 0.9, chompMax: 2.2 },

  actionMenu: {
    w: 340, h: 108, marginBottom: 128,
    padX: 10, padTopY: 14,
    actionRowDy: 16, actionFont: 16, actionCols: [0, 150],
    elementRowDy: 34, elementFont: 13, elementCols: [0, 80, 160, 240],
    cancelRowDy: 48, cancelFont: 12,
    castBarDy: 56, castBarH: 6,
    timerBarDy: 66, timerBarH: 6,
    timerTextDy: 86, timerTextFont: 13,
    previewDy: 102, previewFont: 13,
  },

  floater: { font: 16, drift: 40, jitter: 40, stack: 22, lifetime: 1.5, },

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

  lobby: {
    titleX: 40, titleY: 52, titleFont: 32,
    codeX: 40, codeY: 92, codeFont: 22,
    listY: 130, rowGap: 36, rowDy: 20, rowX: 60, rowFont: 20,
    readyDy: 20, readyFont: 18,
  },

  connecting: { x: 40, y: 60, font: 24 },
  full: { x: 40, titleDy: -16, titleFont: 24, subDy: 16, subFont: 18 },
  gameOver: { x: 40, font: 24, scoreDy: 40, scoreFont: 32 },
};

// Derived convenience aliases (read-only mirrors of LAYOUT).
const SW = LAYOUT.screen.w;
const SH = LAYOUT.screen.h;
const FIELD = LAYOUT.slimeField;

const C_BG = LAYOUT.bg ?? "#14141e";
const C_CURSOR = "rgba(255,255,100,0.7)";
const C_TEXT = "rgba(230,230,230,1)";
const C_HEADER = "rgba(180,200,255,1)";
const C_SLIME_HDR = "rgba(160,255,140,1)";
const C_OWN_ROW = "rgba(255,255,60,0.9)";
const C_MENU_BG = "rgba(20,20,40,0.86)";
const C_MENU_BORDER = C_HEADER;

/** Sprite used for the cosmetic Lil Guys roaming the slime field. */
const LIL_GUY_SPRITE = "grunt";

/** Sprite sheets to load; Lil Guys are the only sprites rendered. */
const CLASSES = [LIL_GUY_SPRITE];

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
 * @param {number} id
 * @param {string} cls
 * @param {string|null} lastAction
 * @param {number} dt
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

function clearEntityState() {
  animState.clear();
  floaters.length = 0;
  lastRoundSeen = -1;
  lastScoreSeen = 0;
  lastHungerSeen = 0;
  lastZoneIndexSeen = 0;
  lilGuys.length = 0;
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
let preLobbyMode = "choose";
let preLobbyCode = "";
let preLobbyError = "";

/** Ordered list of stat keys shown in the editor (display order). */
const STAT_KEYS = ["hp", "attack", "shield", "heal", "fire", "earth", "wind", "water", "level"];

/** Default statblock values (applied on each pre_lobby entry). */
const DEFAULT_STATS = { hp: 120, attack: 1, shield: 1, heal: 1, fire: 1, earth: 1, wind: 1, water: 1, level: 1 };

/** Reset all pre-lobby state (called on server pre_lobby / joining / error messages). */
function resetPreLobby() {
  _krStop();
  preLobbyMode = "choose";
  preLobbyCode = "";
  preLobbyError = "";
  preLobbyStats = { ...DEFAULT_STATS };
  preLobbyPendingAction = null;
  preLobbyStatCursor = 0;
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
let _krKey = null;   // "ArrowLeft" | "ArrowRight" | null
let _krTimer = null;
let _krStart = 0;
let _krDelta = 0;      // +1 or -1

function _krStop() {
  _krKey = null;
  if (_krTimer !== null) { clearTimeout(_krTimer); _krTimer = null; }
}

function _krSchedule() {
  const elapsed = Date.now() - _krStart;
  const delay = Math.max(30, 400 - elapsed * 0.6);
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
  text("Slime Feast", L.titleX, L.titleY, L.titleFont, C_HEADER);

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
      const y = L.statStartY + i * L.statRowH;
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
  text("Slime Feast", L.titleX, L.titleY, L.titleFont, C_HEADER);

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
 * Draw one sprite into a cell box, scaled preserving aspect ratio.
 *
 * @param {number} id  - animator id
 * @param {string} kind - sprite class name
 * @param {number} cx  - cell top-left x
 * @param {number} cy  - cell top-left y
 * @param {number} cw  - cell width
 * @param {number} ch  - cell height
 * @param {string|null} lastAction - "attack"|"die"|null
 * @param {number} dt  - seconds since last frame
 * @param {boolean} flip - mirror horizontally
 */
function drawSprite(id, kind, cx, cy, cw, ch, lastAction, dt, flip) {
  const sp = sprites.get(kind);
  if (!sp) return;

  const { img, meta } = sp;
  const { frame_w, frame_h, clips } = meta;
  const { frame } = tickAnimator(id, kind, lastAction, dt);
  const clip = clips[animState.get(id)?.clip ?? "idle"] ?? clips["idle"];

  const srcX = frame * frame_w;
  const srcY = clip.row * frame_h;

  const scale = Math.min(cw / frame_w, ch / frame_h);
  const dw = frame_w * scale;
  const dh = frame_h * scale;
  const dx = cx + (cw - dw) / 2;
  const dy = cy + (ch - dh) / 2;

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

/**
 * Server marks casters via action_result .cast → entity.last_action for one
 * render frame.  With no player sprites, visualise the cast as a floater
 * rising from the caster's combo-panel row.
 */
function spawnCastFloaters(game) {
  const CP = LAYOUT.comboPanel;
  (game.entities || []).forEach((e, i) => {
    if (!e.last_action) return;
    const y = CP.y0 + i * CP.rowH;
    const x = CP.x + CP.nameW + 5 * CP.slotW + 24;
    spawnFloater("✦ cast", x, y, C_OWN_ROW, 1.0);
  });
}

/**
 * Compact per-player pending-combo rows (bottom-left UI panel).  No player
 * sprites are rendered — combos are the only per-player element on screen.
 * The local player's row is highlighted.
 */
function drawComboPanel(game) {
  const CP = LAYOUT.comboPanel;
  const castsPerRound = game.casts_per_round ?? 3;
  const entities = game.entities || [];
  entities.forEach((e, i) => {
    const y = CP.y0 + i * CP.rowH;
    const own = e.owner === game.player_id;
    text(`P${e.owner}`, CP.x, y, CP.font, own ? C_OWN_ROW : "rgba(180,200,255,0.75)");

    const combo = e.combo ?? [];
    for (let s = 0; s < 5; s++) {
      const slotX = CP.x + CP.nameW + s * CP.slotW;
      const slot = combo[s];
      if (slot && slot.action !== undefined) {
        text(ACTION_CHAR[slot.action] ?? "?", slotX, y, CP.font,
          ACTION_COLOR[slot.action] ?? C_TEXT);
      } else if (slot && slot.element !== undefined) {
        text(ELEMENT_CHAR[slot.element] ?? "?", slotX, y, CP.font,
          ELEMENT_COLOR[slot.element] ?? C_TEXT);
      } else {
        text("·", slotX, y, CP.font, "rgba(120,120,140,0.5)");
      }
    }

    // Spells committed this round.
    const usedX = CP.x + CP.nameW + 5 * CP.slotW + 8;
    text(`${e.casts_used ?? 0}/${castsPerRound}`, usedX, y, CP.font, "rgba(160,170,200,0.8)");
  });
}

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
    const frac = f.age / f.lifetime;
    const alpha = frac > 0.6 ? 1 - (frac - 0.6) / 0.4 : 1.0;
    const yOffset = -LAYOUT.floater.drift * frac; // drift upward over lifetime

    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = `bold ${LAYOUT.floater.font}px monospace`;
    ctx.fillStyle = f.color;
    ctx.textAlign = "center";
    ctx.fillText(f.text, f.x, f.y + yOffset);
    ctx.restore();
  }
}

// ---------------------------------------------------------------------------
// Combo parsing + recipe preview (mirrors game_logic.zig / balance.zig)
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

// Must match balance.zig flat conversion rates.
const UNITS_PER_SLOT = 5;
const MEDICINE_PER_SLOT = 3;

const el = (e) => ({ element: e });
const ac = (a) => ({ action: a });

/** Mirrors balance.player_recipes (exact patterns → outputs).
 *  `medicine` is per color: color-X medicine heals only color-X healable
 *  hunger (symmetrical healing). */
const PLAYER_RECIPES = [
  { label: "crimson_flood", pattern: [el("fire"), ac("dispense"), ac("dispense"), ac("dispense")], output: { units: { fire: 20 }, medicine: {} } },
  { label: "verdant_flood", pattern: [el("earth"), ac("dispense"), ac("dispense"), ac("dispense")], output: { units: { earth: 20 }, medicine: {} } },
  { label: "gale_flood", pattern: [el("wind"), ac("dispense"), ac("dispense"), ac("dispense")], output: { units: { wind: 20 }, medicine: {} } },
  { label: "tide_flood", pattern: [el("water"), ac("dispense"), ac("dispense"), ac("dispense")], output: { units: { water: 20 }, medicine: {} } },
  { label: "prism_mist", pattern: [el("fire"), ac("dispense"), el("water"), ac("dispense")], output: { units: { fire: 6, earth: 6, wind: 6, water: 6 }, medicine: {} } },
  { label: "panacea", pattern: [el("water"), ac("medicine"), ac("medicine")], output: { units: {}, medicine: { water: 10 } } },
];

/** Mirrors balance.team_recipes. */
const TEAM_RECIPES = [
  {
    label: "twin_flames",
    patterns: [
      [el("fire"), ac("dispense"), ac("dispense")],
      [el("fire"), ac("dispense"), ac("dispense")],
    ],
    output: { units: { fire: 30 }, medicine: { fire: 2 } },
  },
  {
    label: "mudslide",
    patterns: [
      [el("water"), ac("dispense"), ac("dispense")],
      [el("earth"), ac("dispense"), ac("dispense")],
    ],
    output: { units: { earth: 18, water: 18 }, medicine: {} },
  },
];

function slotsEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i].action !== b[i].action || a[i].element !== b[i].element) return false;
  }
  return true;
}

/** Flat per-slot conversion (mirrors game_logic.flat_convert).
 *  Both actions are color-bound; colorless slots are wasted. */
function flatConvert(slots) {
  const out = { units: {}, medicine: {}, labels: [] };
  for (const { action, element } of parseComboSlots(slots)) {
    if (element === null) continue; // colorless actions wasted
    if (action === "dispense") {
      out.units[element] = (out.units[element] ?? 0) + UNITS_PER_SLOT;
    } else if (action === "medicine") {
      out.medicine[element] = (out.medicine[element] ?? 0) + MEDICINE_PER_SLOT;
    }
  }
  return out;
}

function addOutput(sum, output, label) {
  for (const [e, n] of Object.entries(output.units ?? {})) {
    sum.units[e] = (sum.units[e] ?? 0) + n;
  }
  for (const [e, n] of Object.entries(output.medicine ?? {})) {
    sum.medicine[e] = (sum.medicine[e] ?? 0) + n;
  }
  if (label) sum.labels.push(label);
}

/**
 * Convert all players' pending combos into the projected team AgentOutput.
 * Mirrors game_logic.match_recipes: team recipes (greedy, repeatable, table
 * order) → player recipes → flat fallback.
 *
 * @param {Array<Array<{action?:string, element?:string}>>} combos
 * @returns {{units: Object<string,number>, medicine: number, labels: string[]}}
 */
function matchRecipes(combos) {
  const sum = { units: {}, medicine: {}, labels: [] };
  const consumed = combos.map(() => false);

  for (const tr of TEAM_RECIPES) {
    for (;;) {
      const picked = combos.map(() => false);
      const picks = [];
      let ok = true;
      for (const pattern of tr.patterns) {
        let found = -1;
        for (let ci = 0; ci < combos.length; ci++) {
          if (consumed[ci] || picked[ci]) continue;
          if (combos[ci].length > 0 && slotsEqual(combos[ci], pattern)) { found = ci; break; }
        }
        if (found === -1) { ok = false; break; }
        picks.push(found);
        picked[found] = true;
      }
      if (!ok) break;
      for (const ci of picks) consumed[ci] = true;
      addOutput(sum, tr.output, tr.label);
    }
  }

  for (let ci = 0; ci < combos.length; ci++) {
    if (consumed[ci] || combos[ci].length === 0) continue;
    for (const pr of PLAYER_RECIPES) {
      if (slotsEqual(combos[ci], pr.pattern)) {
        addOutput(sum, pr.output, pr.label);
        consumed[ci] = true;
        break;
      }
    }
  }

  for (let ci = 0; ci < combos.length; ci++) {
    if (consumed[ci] || combos[ci].length === 0) continue;
    addOutput(sum, flatConvert(combos[ci]), null);
  }

  return sum;
}

// ---------------------------------------------------------------------------
// Round tracking (score / hunger deltas → floaters over the eaten zone)
// ---------------------------------------------------------------------------

let lastRoundSeen = -1;
let lastScoreSeen = 0;
let lastHungerSeen = 0;
let lastZoneIndexSeen = 0;

/**
 * Call at the start of every drawGame frame.
 * Detects round boundary and spawns summary floaters over the zone that was
 * just consumed, using score/hunger deltas from the previous frame.
 */
function updateRoundTracking(game) {
  if (game.round !== lastRoundSeen && lastRoundSeen !== -1) {
    const zoneRect = zoneColumnRect(lastZoneIndexSeen, Math.max(game.zones?.length ?? 1, 1));
    const cx = (zoneRect.x0 + zoneRect.x1) / 2;
    const cy = (zoneRect.y0 + zoneRect.y1) / 2;
    const jitter = () => (Math.random() - 0.5) * LAYOUT.floater.jitter;
    const STACK = LAYOUT.floater.stack;

    const scoreGain = (game.score ?? 0) - lastScoreSeen;
    const hungerGain = (game.hunger?.current ?? 0) - lastHungerSeen;

    // Chomp burst over the consumed zone.
    for (let i = 0; i < 4; i++) {
      spawnFloater("chomp!", cx + jitter() * 2, cy + jitter() * 2, "rgba(255,255,255,0.9)", 1.0);
    }
    if (scoreGain > 0) {
      spawnFloater(`+${scoreGain} score`, cx + jitter(), cy - STACK, "rgba(100,220,100,1)");
    }
    if (hungerGain > 0) {
      spawnFloater(`+${hungerGain} hunger`, cx + jitter(), cy + STACK, "rgba(255,150,50,1)");
    } else if (hungerGain < 0) {
      spawnFloater(`${hungerGain} hunger (medicine)`, cx + jitter(), cy + STACK, "rgba(255,80,180,1)");
    }
  }
  lastRoundSeen = game.round;
  lastScoreSeen = game.score ?? 0;
  lastHungerSeen = game.hunger?.current ?? 0;
  lastZoneIndexSeen = Math.min(game.zone_index ?? 0, Math.max((game.zones?.length ?? 1) - 1, 0));
}

/** Map ActionChoice enum string → display character. */
const ACTION_CHAR = { dispense: "d", medicine: "m" };

/** Map ActionChoice enum string → highlight colour. */
const ACTION_COLOR = {
  dispense: "rgba(160,220,255,1)",
  medicine: "rgba(255,80,180,1)",
};

/** Element ordinal → name string; matches protocol Element ordinal order. */
const ELEMENT_NAMES = ["fire", "earth", "wind", "water"];

/** Map Element (agent color) enum string → display character. */
const ELEMENT_CHAR = { fire: "♦", earth: "▲", wind: "≋", water: "~" };

/** Map Element (agent color / slime type) → colour.  Matches the whiteboard:
 *  red / yellow / green / blue scribbles. */
const ELEMENT_COLOR = {
  fire: "rgba(255,90,90,1)",
  earth: "rgba(250,210,80,1)",
  wind: "rgba(130,230,130,1)",
  water: "rgba(110,160,255,1)",
};

const NEUTRAL_COLOR = "rgba(190,190,200,1)";

// ---------------------------------------------------------------------------
// Hunger bar + score
// ---------------------------------------------------------------------------

/**
 * Draw the Total Hunger bar.  Fills left→right as slime is consumed; the
 * healable (modified-slime) portion sits at the right end of the fill as
 * color-coded segments — one per slime color — since only matching-color
 * medicine can heal each segment.
 */
function drawHungerBar(game) {
  const H = LAYOUT.hungerBar;
  const hunger = game.hunger ?? { current: 0, max: 0, healable: {} };
  const healable = hunger.healable ?? {};
  const w = H.x1 - H.x0;
  const frac = hunger.max > 0 ? Math.min(1, hunger.current / hunger.max) : 0;

  const healableTotal = ELEMENT_NAMES.reduce((t, name) => t + (healable[name] ?? 0), 0);
  const healFracTotal = hunger.max > 0 ? Math.min(frac, healableTotal / hunger.max) : 0;

  text("TOTAL HUNGER", H.x0, H.y + H.labelDy, H.labelFont, C_HEADER);

  rect(H.x0, H.y, w, H.h, H.bg);
  const fillColor = frac > 0.85 ? H.danger : H.fill;
  if (frac > 0) rect(H.x0, H.y, w * frac, H.h, fillColor);

  // Healable segments: right end of the current fill, one per slime color.
  // Scale segments proportionally if the fill clamped at the bar edge.
  if (healFracTotal > 0 && healableTotal > 0) {
    const scale = (w * healFracTotal) / healableTotal;
    let x = H.x0 + w * (frac - healFracTotal);
    for (const name of ELEMENT_NAMES) {
      const units = healable[name] ?? 0;
      if (units === 0) continue;
      const segW = units * scale;
      rect(x, H.y, segW, H.h, ELEMENT_COLOR[name]);
      x += segW;
    }
  }
  rectStroke(H.x0, H.y, w, H.h, 1, "rgba(255,255,255,0.25)");

  text(`${hunger.current}/${hunger.max}  (healable ${healableTotal})`,
    H.x0 + w + 6 - 230, H.y + H.h + 14, H.textFont, "rgba(200,200,210,0.9)");
}

function drawScore(game) {
  const S = LAYOUT.score;
  text(`Score: ${game.score ?? 0}`, S.x, S.y, S.font, C_SLIME_HDR);
}

// ---------------------------------------------------------------------------
// Slime field (zone columns)
// ---------------------------------------------------------------------------

/** Rect for zone column `i` of `count` within the slime field. */
function zoneColumnRect(i, count) {
  const w = (FIELD.x1 - FIELD.x0) / Math.max(count, 1);
  return { x0: FIELD.x0 + i * w, x1: FIELD.x0 + (i + 1) * w, y0: FIELD.y0, y1: FIELD.y1 };
}

/**
 * Draw one slime blob (filled circle + unit count).
 */
function drawBlob(x, y, units, color) {
  const r = FIELD.blobMinR + Math.sqrt(units) * FIELD.blobRScale;
  ctx.save();
  ctx.fillStyle = color;
  ctx.globalAlpha = 0.85;
  ctx.beginPath();
  ctx.arc(x, y, r, 0, Math.PI * 2);
  ctx.fill();
  ctx.globalAlpha = 1.0;
  ctx.fillStyle = "rgba(10,10,20,0.95)";
  ctx.font = `bold ${FIELD.blobFont}px monospace`;
  ctx.textAlign = "center";
  ctx.fillText(String(units), x, y + 4);
  ctx.restore();
}

/**
 * Draw the slime field: one column per zone, colored blobs sized by remaining
 * units (color = slime type = required agent), grey blob = naturally-neutral.
 * Consumed zones are dimmed; the active zone is highlighted.
 */
function drawSlimeField(game) {
  const zones = game.zones ?? [];
  const count = zones.length;
  if (count === 0) return;
  const zoneIndex = game.zone_index ?? 0;

  for (let i = 0; i < count; i++) {
    const rectZ = zoneColumnRect(i, count);
    const zw = rectZ.x1 - rectZ.x0;
    const zh = rectZ.y1 - rectZ.y0;

    rect(rectZ.x0, rectZ.y0, zw, zh, "rgba(255,255,255,0.03)");

    if (i < zoneIndex) {
      // Consumed zone.
      rect(rectZ.x0, rectZ.y0, zw, zh, FIELD.eatenFill);
      ctx.save();
      ctx.fillStyle = "rgba(150,150,160,0.7)";
      ctx.font = `bold 16px monospace`;
      ctx.textAlign = "center";
      ctx.fillText("EATEN", (rectZ.x0 + rectZ.x1) / 2, (rectZ.y0 + rectZ.y1) / 2);
      ctx.restore();
    } else {
      // Blobs: fire, earth, wind, water, neutral stacked vertically.
      const z = zones[i];
      const entries = [
        { units: z.fire, color: ELEMENT_COLOR.fire },
        { units: z.earth, color: ELEMENT_COLOR.earth },
        { units: z.wind, color: ELEMENT_COLOR.wind },
        { units: z.water, color: ELEMENT_COLOR.water },
        { units: z.neutral, color: NEUTRAL_COLOR },
      ].filter(b => b.units > 0);

      const cx = (rectZ.x0 + rectZ.x1) / 2;
      for (let b = 0; b < entries.length; b++) {
        const by = rectZ.y0 + zh * (b + 1) / (entries.length + 1);
        // Slight horizontal wobble so columns don't look like bar charts.
        const bx = cx + ((b % 2 === 0) ? -1 : 1) * zw * 0.12;
        drawBlob(bx, by, entries[b].units, entries[b].color);
      }
    }

    const isActive = i === zoneIndex;
    rectStroke(rectZ.x0, rectZ.y0, zw, zh, isActive ? 3 : 1,
      isActive ? FIELD.activeBorder : FIELD.border);

    // Round label under the column.
    ctx.save();
    ctx.fillStyle = isActive ? "rgba(255,255,120,0.95)" : "rgba(170,180,220,0.7)";
    ctx.font = `${FIELD.labelFont}px monospace`;
    ctx.textAlign = "center";
    ctx.fillText(`round ${i + 1}`, (rectZ.x0 + rectZ.x1) / 2, rectZ.y1 + FIELD.labelDy);
    ctx.restore();
  }
}

// ---------------------------------------------------------------------------
// Cosmetic Lil Guys (roam the active zone; purely client-side)
// ---------------------------------------------------------------------------

/**
 * @typedef {{ x:number, y:number, tx:number, ty:number, chomp:number, id:number }} LilGuy
 */

/** @type {LilGuy[]} */
const lilGuys = [];

function randIn(lo, hi) { return lo + Math.random() * (hi - lo); }

function lilGuyTarget(rectZ) {
  const G = LAYOUT.lilGuys;
  return {
    tx: randIn(rectZ.x0, rectZ.x1 - G.size),
    ty: randIn(rectZ.y0, rectZ.y1 - G.size),
  };
}

function tickLilGuys(game, dt) {
  const G = LAYOUT.lilGuys;
  const zones = game.zones ?? [];
  const count = Math.max(zones.length, 1);
  const zoneIndex = Math.min(game.zone_index ?? 0, count - 1);
  const rectZ = zoneColumnRect(zoneIndex, count);

  // One Lil Guy per player entity (late joiners get one too).
  const wanted = (game.entities ?? []).length;
  while (lilGuys.length < wanted) {
    const t = lilGuyTarget(rectZ);
    lilGuys.push({
      x: randIn(rectZ.x0, rectZ.x1 - G.size),
      y: randIn(rectZ.y0, rectZ.y1 - G.size),
      ...t,
      chomp: randIn(G.chompMin, G.chompMax),
      id: 1_000_000 + lilGuys.length, // animator ids far above entity ids
    });
  }
  if (lilGuys.length > wanted) lilGuys.length = wanted;

  for (const g of lilGuys) {
    // Retarget if the active zone moved or we arrived.
    const outside = g.tx < rectZ.x0 || g.tx > rectZ.x1 || g.ty < rectZ.y0 || g.ty > rectZ.y1;
    const dx = g.tx - g.x, dy = g.ty - g.y;
    const dist = Math.hypot(dx, dy);
    if (outside || dist < 4) {
      const t = lilGuyTarget(rectZ);
      g.tx = t.tx;
      g.ty = t.ty;
      continue;
    }
    const step = Math.min(G.speed * dt, dist);
    g.x += (dx / dist) * step;
    g.y += (dy / dist) * step;

    // Cosmetic chomping while the round is live.
    g.chomp -= dt;
    if (g.chomp <= 0) {
      g.chomp = randIn(G.chompMin, G.chompMax);
      spawnFloater("chomp", g.x + G.size / 2, g.y, "rgba(230,230,240,0.85)", 0.8);
    }
  }
}

function drawLilGuys(dt) {
  const G = LAYOUT.lilGuys;
  for (const g of lilGuys) {
    const flip = g.tx < g.x;
    drawSprite(g.id, LIL_GUY_SPRITE, g.x, g.y, G.size, G.size, null, dt, flip);
  }
}

// ---------------------------------------------------------------------------
// Action menu + projected agent preview
// ---------------------------------------------------------------------------

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
  text("[1] Dispense", px + M.actionCols[0], aRowY, M.actionFont, ACTION_COLOR.dispense);
  text("[2] Medicine", px + M.actionCols[1], aRowY, M.actionFont, ACTION_COLOR.medicine);

  const eRowY = my + M.padTopY + M.elementRowDy;
  text("[Q]♦", px + M.elementCols[0], eRowY, M.elementFont, ELEMENT_COLOR.fire);
  text("[W]▲", px + M.elementCols[1], eRowY, M.elementFont, ELEMENT_COLOR.earth);
  text("[E]≋", px + M.elementCols[2], eRowY, M.elementFont, ELEMENT_COLOR.wind);
  text("[R]~", px + M.elementCols[3], eRowY, M.elementFont, ELEMENT_COLOR.water);

  text("[Esc] Cancel", px, my + M.padTopY + M.cancelRowDy, M.cancelFont, "rgba(180,180,180,0.8)");

  const tbw = mw - M.padX * 2;

  // Cast-window timer bar (round_duration / casts_per_round per window).
  // Pending combo commits as a spell when it empties.
  const castsPerRound = game.casts_per_round ?? 3;
  const castDuration = game.round_duration > 0 ? game.round_duration / castsPerRound : 0;
  const castFrac = castDuration > 0
    ? Math.max(0, Math.min(1, (game.cast_timer ?? 0) / castDuration))
    : 0;
  rect(px, my + M.castBarDy, tbw, M.castBarH, "rgba(30,30,30,0.8)");
  rect(px, my + M.castBarDy, tbw * castFrac, M.castBarH, "rgba(120,220,255,0.9)");

  // Round timer bar
  const timerFrac = game.round_duration > 0
    ? Math.max(0, Math.min(1, game.round_timer / game.round_duration))
    : 0;
  rect(px, my + M.timerBarDy, tbw, M.timerBarH, "rgba(30,30,30,0.8)");
  rect(px, my + M.timerBarDy, tbw * timerFrac, M.timerBarH, "rgba(255,200,50,0.9)");

  const own = (game.entities ?? []).find(e => e.owner === game.player_id);
  const castsUsed = own ? (own.casts_used ?? 0) : 0;
  const castText = game.cast_timer !== undefined ? game.cast_timer.toFixed(1) : "?";
  const roundText = game.round_timer !== undefined ? game.round_timer.toFixed(1) : "?";
  text(`Cast: ${castText}s (${castsUsed}/${castsPerRound})  ·  Round: ${roundText}s`,
    px, my + M.timerTextDy, M.timerTextFont, C_TEXT);

  // Projected team output from everyone's PENDING combos (recipe-aware).
  // Already-committed casts this round are not in the snapshot, so this
  // previews only the current cast window.
  const combos = (game.entities ?? []).map(e => e.combo ?? []);
  const projected = matchRecipes(combos);

  const parts = [];
  for (const name of ELEMENT_NAMES) {
    const n = projected.units[name];
    if (n) parts.push({ str: `${ELEMENT_CHAR[name]}${n}`, color: ELEMENT_COLOR[name] });
  }
  // Medicine is per color: shown in the color of the healable bucket it heals.
  for (const name of ELEMENT_NAMES) {
    const n = projected.medicine[name];
    if (n) parts.push({ str: `med${ELEMENT_CHAR[name]}${n}`, color: ELEMENT_COLOR[name] });
  }

  let dx = px;
  const pvY = my + M.previewDy;
  text("Team:", dx, pvY, M.previewFont, "rgba(180,200,255,0.85)");
  dx += 52;
  if (parts.length === 0) {
    text("—", dx, pvY, M.previewFont, "rgba(120,120,140,0.7)");
  } else {
    for (const p of parts) {
      text(p.str, dx, pvY, M.previewFont, p.color);
      dx += ctx.measureText(p.str).width + 12;
    }
  }
  if (projected.labels.length > 0) {
    text(projected.labels.join(", "), dx + 8, pvY, M.previewFont, "rgba(255,255,140,0.9)");
  }
}

function drawGame(game, dt) {
  // Must come first: detects round boundary using previous frame's data.
  updateRoundTracking(game);
  tickFloaters(dt);
  tickLilGuys(game, dt);
  spawnCastFloaters(game);

  clear();

  const H = LAYOUT.headers;
  const encounter = game.encounter || "";
  text(`Encounter: ${encounter}`, H.waveX, H.waveY, H.waveFont, C_HEADER);

  text("SLIME FIELD", FIELD.x0, FIELD.y0 + H.labelDy, H.labelFont, C_SLIME_HDR);

  drawScore(game);
  drawHungerBar(game);
  drawSlimeField(game);
  drawLilGuys(dt);
  drawComboPanel(game);
  drawActionMenu(game);

  // Floaters drawn last so they appear on top of everything.
  drawFloaters();
}

function drawGameOver(msg) {
  clear();
  const L = LAYOUT.gameOver;
  text("Encounter over!  Press any key to return to lobby.", L.x, SH / 2, L.font, C_TEXT);
  const score = msg && msg.score !== undefined && msg.score !== null ? msg.score : "?";
  text(`Neutral slime consumed: ${score}`, L.x, SH / 2 + L.scoreDy, L.scoreFont, C_SLIME_HDR);
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
    case "pre_lobby": drawPreLobby(); break;
    case "connecting": drawConnecting(); break;
    case "lobby": drawLobby(msg.lobby); break;
    case "game": drawGame(msg.game, dt); break;
    case "game_over": drawGameOver(msg); break;
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
        preLobbyMode === "editing_stats" ||
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
  "Enter", "Escape",
  "1", "2",
  "q", "w", "e", "r",
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
      preLobbyError = "";
      preLobbyPendingAction = { action: "create" };
      preLobbyMode = "editing_stats";
      preLobbyStatCursor = 0;
    } else if (e.key === "j" || e.key === "J") {
      preLobbyMode = "entering_code";
      preLobbyCode = "";
      preLobbyError = "";
    }
    return;
  }

  if (preLobbyMode === "entering_code") {
    if (e.key === "Escape") {
      preLobbyMode = "choose";
      preLobbyCode = "";
      preLobbyError = "";
      return;
    }
    if (e.key === "Backspace") {
      preLobbyCode = preLobbyCode.slice(0, -1);
      preLobbyError = "";
      return;
    }
    if (e.key === "Enter") {
      if (preLobbyCode.length === 6) {
        preLobbyError = "";
        preLobbyPendingAction = { action: "join", code: preLobbyCode };
        preLobbyMode = "editing_stats";
        preLobbyStatCursor = 0;
      } else {
        preLobbyError = "Code must be 6 characters.";
      }
      return;
    }
    // Accept alphanumeric characters (auto-uppercase, max 6).
    if (preLobbyCode.length < 6 && /^[a-zA-Z0-9]$/.test(e.key)) {
      preLobbyCode += e.key.toUpperCase();
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
        _krKey = e.key;
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
