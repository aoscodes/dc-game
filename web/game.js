"use strict";

const LAYOUT = {
  screen: { w: 2048, h: 1536 },
  bg: "#14141e",

  // Slime field: zone columns eaten left-to-right, one per round.
  slimeField: {
    x0: 40, x1: 984, y0: 220, y1: 620,
    labelDy: 24, labelFont: 14,
    activeBorder: "rgba(255,255,100,0.85)",
    border: "rgba(180,200,255,0.25)",
    eatenFill: "rgba(20,20,30,0.75)",

    // Organic ooze layer (see drawOoze): slime renders as one contiguous
    // carpet of goo; colors interdigitate instead of sitting in uniform blobs.
    oozeScale: 20,                 // screen px per ooze px (low-res goo canvas)
    oozeParticleCap: 20,          // max metaball particles per color per zone
    oozeFillFactor: 1.5,          // footprint overfill: 1.0 = exactly zone
    // area at full coverage; >1 closes gaps
    oozeShrinkGamma: 1.8,         // coverage exponent: counteracts overfill
    // so a half-eaten zone reads half-covered
    oozeMinR: 1.7,                // min particle core radius (ooze px)
    oozeAlphaCutoff: 20,          // 0-255 silhouette threshold (goo fusing)
    oozeOutline: [58, 34, 96],    // rim color [r,g,b] — deep violet, distinct
    // from all element colors / neutral / bg
    oozeWobbleAmp: 1.4,           // idle wobble amplitude (ooze px)
    oozeWobbleFreq: 0.7,          // idle wobble base frequency (rad/s)
    oozeBleed: 0.0,               // horiz. bleed past column edge (col-w frac)
  },

  hungerBar: {
    x0: 40, x1: 984, y: 150, h: 18,
    labelFont: 14, labelDy: -8,
    bg: "rgba(30,10,10,0.78)",
    // Dim purple: normal (neutral) consumption must not read as any slime
    // color — element colors are reserved for the healable segments.
    fill: "rgba(140,100,185,0.9)",
    dangerBorder: "rgba(255,60,60,0.95)",
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

  // Default floater lifetime ≥ 3s so feedback is readable; cosmetic chomps
  // are exempt (see tickLilGuys).  Recipe floaters render larger.
  floater: { font: 16, drift: 40, jitter: 40, stack: 22, lifetime: 3.0, recipeFont: 24 },

  preLobby: {
    titleX: 40, titleY: 60, titleFont: 32,
    optX: 60, optY0: 160, optGap: 40, optFont: 22,
    errorDy: 100, errorFont: 18,
    codePromptY: 160, codeY: 210, codeFont: 36, codeHintY: 270, codeHintFont: 16,
  },

  lobby: {
    titleX: 40, titleY: 52, titleFont: 32,
    codeX: 40, codeY: 92, codeFont: 22,
    listY: 130, rowGap: 36, rowDy: 20, rowX: 60, rowFont: 20,
    readyDy: 20, readyFont: 18,
    guideX: 40, guideY: 408, guideFont: 13, guideLineH: 19,
    recipeHeaderGap: 10, recipeRowH: 25, recipeFont: 14,
    recipeLabelW: 170, recipeSlotGap: 10, recipeArrowGap: 24,
  },

  connecting: { x: 40, y: 60, font: 24 },
  full: { x: 40, titleDy: -16, titleFont: 24, subDy: 16, subFont: 18 },
  gameOver: {
    x: 40, titleY: 56, titleFont: 26,
    scoreY: 92, scoreFont: 20,
    sectionFont: 15, rowFont: 13, rowH: 20,
    roundsY: 150,
    cols: { round: 40, casts: 92, agents: 150, neutralized: 330, escaped: 500, healed: 650, hunger: 830 },
    pcols: { name: 40, casts: 200, dispense: 260, medicine: 460, recipes: 660, fizzles: 790 },
    hintFont: 14,
  },
};

// Derived convenience aliases (read-only mirrors of LAYOUT).
const SW = LAYOUT.screen.w;
const SH = LAYOUT.screen.h;
const FIELD = LAYOUT.slimeField;

const C_BG = LAYOUT.bg ?? "#14141e";
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
  await Promise.all([
    loadBalanceData(),
    loadConfigMeta(),
    ...CLASSES.map(async cls => {
      // Absolute paths: the page may be served at /config/{hash}.
      const [meta, img] = await Promise.all([
        fetch(`/assets/${cls}.json`).then(r => r.json()),
        new Promise((res, rej) => {
          const i = new Image();
          i.onload = () => res(i);
          i.onerror = rej;
          i.src = `/assets/${cls}.png`;
        }),
      ]);
      sprites.set(cls, { img, meta });
    }),
  ]);
}

/** Combo slot from its data-file name: actions vs element modifiers. */
function slotFromName(name) {
  return (name === "dispense" || name === "medicine")
    ? { action: name }
    : { element: name };
}

/**
 * Saved /tune config hash from the URL when playing at /config/{hash};
 * null on the plain game page (shipped defaults).
 */
const PAGE_CONFIG_HASH =
  (location.pathname.match(/^\/config\/([0-9a-f]{16})/) || [])[1] ?? null;

/**
 * Lobby creation defaults to realtime mode when served at /realtime or when
 * the URL carries ?mode=realtime (composable with /config/{hash}).
 */
const PAGE_REALTIME = location.pathname === "/realtime" ||
  new URLSearchParams(location.search).get("mode") === "realtime";

/**
 * Game type a saved config is LOCKED to (custom-configs meta.json, written
 * at /tune save time).  Lobbies created from a locked config only offer
 * that mode — game types are only reachable through configs of their type.
 * null = no config on this page, or a legacy config saved before modes
 * were recorded (those still offer both modes).
 */
let configLockedMode = null;

/** Fetch the page config's meta.json (missing = legacy config → null). */
async function loadConfigMeta() {
  if (!PAGE_CONFIG_HASH) return;
  try {
    const res = await fetch(`/config/${PAGE_CONFIG_HASH}/data/meta.json`);
    if (!res.ok) return;
    const meta = await res.json();
    if (meta.mode === "realtime" || meta.mode === "classic") {
      configLockedMode = meta.mode;
    }
  } catch { /* legacy config — both modes stay available */ }
}

/**
 * The current room's game mode: "classic" | "realtime".
 * Set from the bridge's `joining` ack; render frames win when they carry
 * `game.mode` / `lobby.mode` (see roomModeFrom).
 */
let roomMode = "classic";

/** Resolve the effective mode for a render frame (frame value wins). */
function roomModeFrom(obj) {
  if (obj && (obj.mode === "realtime" || obj.mode === "classic")) {
    roomMode = obj.mode;
  }
  return roomMode;
}

/** Config hash whose balance tables are currently loaded. */
let loadedConfigHash = null;

/** Balance data URL for a config hash (null = shipped defaults). */
function balanceUrl(hash) {
  return hash ? `/config/${hash}/data/balance.json` : "/data/balance.json";
}

/**
 * Fetch balance data — the same file the Zig server loads — and populate
 * the rates and recipe tables.  Single source of truth:
 * wire recipe indices refer to these tables in file order.  Re-invoked with
 * a different hash when joining a lobby that runs a custom config.
 */
async function loadBalanceData(hash = PAGE_CONFIG_HASH) {
  const res = await fetch(balanceUrl(hash));
  if (!res.ok) throw new Error(`fetch ${balanceUrl(hash)}: HTTP ${res.status}`);
  const bal = await res.json();
  const output = (o) => ({ units: o.units ?? {}, medicine: o.medicine ?? {} });
  UNITS_PER_SLOT = bal.units_per_slot;
  MEDICINE_PER_SLOT = bal.medicine_per_slot;
  CASTS_PER_ROUND = bal.casts_per_round;
  CAST_BUFFER_MS = bal.cast_buffer_ms ?? 500;
  CAST_LOCK_MS = bal.cast_lock_ms ?? 500;
  PLAYER_RECIPES = bal.player_recipes.map((r) => ({
    label: r.label,
    pattern: r.pattern.map(slotFromName),
    output: output(r.output),
  }));
  TEAM_RECIPES = bal.team_recipes.map((r) => ({
    label: r.label,
    patterns: r.patterns.map((p) => p.map(slotFromName)),
    output: output(r.output),
  }));
  loadedConfigHash = hash;
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
  zoneOozeInitTotals.clear();
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
 */
let preLobbyMode = "choose";
let preLobbyCode = "";
let preLobbyError = "";

/** Reset all pre-lobby state (called on server pre_lobby / joining / error messages). */
function resetPreLobby() {
  preLobbyMode = "choose";
  preLobbyCode = "";
  preLobbyError = "";
}

function drawPreLobby() {
  clear();
  const L = LAYOUT.preLobby;
  text("Slime Feast", L.titleX, L.titleY, L.titleFont, C_HEADER);

  if (preLobbyMode === "choose") {
    const highlight = "rgba(255,255,100,1)";
    if (configLockedMode !== null) {
      // Saved config locked to one game type: a single create option.
      const modeLabel = configLockedMode === "realtime" ? "REAL-TIME" : "CLASSIC";
      text(`[C]  Create ${modeLabel} lobby (this config's game type)`,
        L.optX, L.optY0, L.optFont, highlight);
      text("[J]  Join existing lobby", L.optX, L.optY0 + L.optGap, L.optFont, C_TEXT);
    } else {
      // Fixed key → mode mapping ([C] = classic, [R] = realtime, always);
      // the page's default mode only picks which line is emphasized.
      text("[C]  Create CLASSIC lobby", L.optX, L.optY0, L.optFont,
        PAGE_REALTIME ? C_TEXT : highlight);
      text("[R]  Create REAL-TIME lobby", L.optX, L.optY0 + L.optGap, L.optFont,
        PAGE_REALTIME ? highlight : C_TEXT);
      text("[J]  Join existing lobby", L.optX, L.optY0 + 2 * L.optGap, L.optFont, C_TEXT);
    }
    if (preLobbyError) {
      text(preLobbyError, L.optX, L.optY0 + 2 * L.optGap + L.errorDy, L.errorFont, "rgba(255,100,100,1)");
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

  // Game-type badge beside the title — always shown so a classic room is
  // never mistaken for a realtime one (or vice versa).
  {
    ctx.font = `${L.titleFont}px monospace`;
    const badgeX = L.titleX + ctx.measureText("Slime Feast").width + 24;
    const realtime = roomModeFrom(lobby) === "realtime";
    text(realtime ? "REAL-TIME" : "CLASSIC", badgeX, L.titleY, L.codeFont,
      realtime ? "rgba(255,150,50,1)" : "rgba(140,180,255,1)");
  }

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

  drawRecipeGuide(roomModeFrom(lobby));
}

/** Key bindings per element / action — mirrors src/client/input.zig. */
const ELEMENT_KEY = { red: "Q", green: "W", yellow: "E", blue: "R" };
const ACTION_KEY = { dispense: "1", medicine: "2" };

/** Render one combo slot as key+symbol (e.g. "Q♦", "1d") in its parity color. */
function slotKeySymbol(slot) {
  if (slot.element !== undefined) {
    return {
      str: `${ELEMENT_KEY[slot.element] ?? "?"}${ELEMENT_CHAR[slot.element] ?? "?"}`,
      color: ELEMENT_COLOR[slot.element] ?? C_TEXT,
    };
  }
  return {
    str: `${ACTION_KEY[slot.action] ?? "?"}${ACTION_CHAR[slot.action] ?? "?"}`,
    color: ACTION_COLOR[slot.action] ?? C_TEXT,
  };
}

/** Draw colored text parts left-to-right; returns the x after the last part. */
function drawParts(x, y, font, parts, gap) {
  let dx = x;
  ctx.font = `${font}px monospace`;
  for (const p of parts) {
    text(p.str, dx, y, font, p.color);
    ctx.font = `${font}px monospace`;
    dx += ctx.measureText(p.str).width + gap;
  }
  return dx;
}

/** Colored output parts for a recipe's AgentOutput ({units, medicine} maps). */
function outputParts(output) {
  const parts = [];
  for (const name of ELEMENT_NAMES) {
    const n = output.units?.[name];
    if (n) parts.push({ str: `${ELEMENT_CHAR[name]}${n}`, color: ELEMENT_COLOR[name] });
  }
  for (const name of ELEMENT_NAMES) {
    const n = output.medicine?.[name];
    if (n) parts.push({ str: `med${ELEMENT_CHAR[name]}${n}`, color: ELEMENT_COLOR[name] });
  }
  return parts;
}

/**
 * Lobby study guide: how casting works (mode-aware) + every defined recipe
 * with its key sequence AND symbols, all in parity colors (slime = agent =
 * medicine = hunger block).  Recipes appear in data/balance.json order.
 * @param {"classic" | "realtime"} mode - the room's play mode
 */
function drawRecipeGuide(mode) {
  const L = LAYOUT.lobby;
  let y = L.guideY;

  text("HOW CASTING WORKS", L.guideX, y, L.guideFont + 2, C_HEADER);
  y += L.guideLineH;
  const descColor = "rgba(200,200,210,0.9)";
  // Classic: spells auto-commit on a timer.  Realtime: ENTER fires a cast
  // after its own buffer; team-recipe matches merge and fire together.
  const castingLine = mode === "realtime"
    ? [
      { str: `Press ENTER to cast — it fires ${(CAST_BUFFER_MS / 1000).toFixed(1)}s later.`, color: descColor },
      { str: "Casts completing a team recipe in that window merge and fire together!", color: RECIPE_COLOR_TEAM },
      ...(CAST_LOCK_MS > 0
        ? [{ str: `${(CAST_LOCK_MS / 1000).toFixed(1)}s cooldown per cast.`, color: descColor }]
        : []),
    ]
    : [
      { str: `Spells auto-cast when the cast bar empties — ${CASTS_PER_ROUND} per round. Exact combos below are RECIPES (stronger).`, color: descColor },
    ];
  const descLines = [
    [
      { str: "Pick an agent color —", color: descColor },
      { str: "Q♦", color: ELEMENT_COLOR.red },
      { str: "W▲", color: ELEMENT_COLOR.green },
      { str: "E≋", color: ELEMENT_COLOR.yellow },
      { str: "R~", color: ELEMENT_COLOR.blue },
      { str: "— then actions:", color: descColor },
      { str: "1d dispense", color: ACTION_COLOR.dispense },
      { str: "2m medicine", color: ACTION_COLOR.medicine },
    ],
    [
      { str: "Dispensed agents transmute matching-color slime to neutral;", color: ACTION_COLOR.dispense },
      { str: "medicine heals matching-color hunger.", color: ACTION_COLOR.medicine },
    ],
    castingLine,
  ];
  for (const line of descLines) {
    drawParts(L.guideX, y, L.guideFont, line, 8);
    y += L.guideLineH;
  }
  y += L.recipeHeaderGap;

  text("RECIPES", L.guideX, y, L.guideFont + 2, C_HEADER);
  y += L.guideLineH;

  const drawRecipeRow = (label, labelColor, patterns, output, suffix) => {
    text(label, L.guideX, y, L.recipeFont, labelColor);
    let x = L.guideX + L.recipeLabelW;
    patterns.forEach((pattern, pi) => {
      if (pi > 0) {
        text("+", x, y, L.recipeFont, descColor);
        ctx.font = `${L.recipeFont}px monospace`;
        x += ctx.measureText("+").width + L.recipeSlotGap;
      }
      x = drawParts(x, y, L.recipeFont, pattern.map(slotKeySymbol), L.recipeSlotGap);
    });
    text("→", x, y, L.recipeFont, descColor);
    x += L.recipeArrowGap;
    x = drawParts(x, y, L.recipeFont, outputParts(output), L.recipeSlotGap);
    if (suffix) text(suffix, x + 4, y, L.guideFont, RECIPE_COLOR_TEAM);
    y += L.recipeRowH;
  };

  for (const r of PLAYER_RECIPES) {
    drawRecipeRow(r.label, RECIPE_COLOR_PLAYER, [r.pattern], r.output, null);
  }
  for (const r of TEAM_RECIPES) {
    drawRecipeRow(r.label, RECIPE_COLOR_TEAM, r.patterns, r.output, `(team ×${r.patterns.length})`);
  }
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
  const rowPos = (i) => ({
    x: CP.x + CP.nameW + 5 * CP.slotW + 24,
    y: CP.y0 + i * CP.rowH,
  });
  (game.entities || []).forEach((e, i) => {
    if (!e.last_action) return;
    const { x, y } = rowPos(i);
    spawnFloater("✦ cast", x, y, C_OWN_ROW);
  });
  // Zero-output spells discarded at window close: show the fizzle on the
  // caster's row (grey — nothing happened, no cast consumed).
  for (const pid of game.fizzles ?? []) {
    const i = (game.entities || []).findIndex((e) => e.owner === pid);
    if (i === -1) continue;
    const { x, y } = rowPos(i);
    spawnFloater("fizzle…", x, y, "rgba(150,150,160,0.9)");
  }
}

/** Player-recipe floater color (matches the recipe label color elsewhere). */
const RECIPE_COLOR_PLAYER = "rgba(255,255,140,1)";
/** Team-recipe floater color — distinct so co-op combos pop. */
const RECIPE_COLOR_TEAM = "rgba(140,240,255,1)";

/**
 * Big celebratory floaters when recipes fire (server broadcasts one event
 * per fire at cast-window close).  Labels are resolved by table index into
 * the tables loaded from data/balance.json (same file the server reads, so
 * indices agree by construction).  Floaters rise from the active zone's
 * center, stacked when several fire at once.
 */
function spawnRecipeFloaters(game) {
  const fired = game.recipes_fired ?? [];
  if (fired.length === 0) return;

  const count = Math.max(game.zones?.length ?? 1, 1);
  const zoneIndex = Math.min(game.zone_index ?? 0, count - 1);
  const rectZ = zoneColumnRect(zoneIndex, count);
  const cx = (rectZ.x0 + rectZ.x1) / 2;
  const cy = (rectZ.y0 + rectZ.y1) / 2;
  const STACK = LAYOUT.floater.stack + 8;

  fired.forEach((rf, i) => {
    const isTeam = rf.kind === "team";
    const table = isTeam ? TEAM_RECIPES : PLAYER_RECIPES;
    const label = table[rf.index]?.label ?? "recipe";
    const textStr = isTeam ? `${label}! (team)` : `${label}!`;
    spawnFloater(textStr, cx, cy - i * STACK,
      isTeam ? RECIPE_COLOR_TEAM : RECIPE_COLOR_PLAYER,
      LAYOUT.floater.lifetime, LAYOUT.floater.recipeFont);
  });
}

/** Cast lifecycle floater color (matches the realtime cast bar). */
const CAST_EVENT_COLOR = "rgba(120,220,255,1)";

/**
 * Realtime cast-loop event floaters (`game.cast_events`, transient):
 *   grouped  — a new cast completed a team recipe; members now fire together
 *   replaced — Px swapped their pending cast (its buffer restarted)
 *   fired    — expired casts converted (spell_count spells; solo fires are
 *              silent — the ✦ cast action floater already covers those)
 * Player-scoped events rise from that player's combo-panel row; group-level
 * events from the active zone's center (where recipe floaters appear).
 */
function spawnCastEventFloaters(game) {
  const events = game.cast_events ?? [];
  if (events.length === 0) return;

  const CP = LAYOUT.comboPanel;
  const rowPos = (pid) => {
    const i = (game.entities || []).findIndex((e) => e.owner === pid);
    if (i === -1) return null;
    return { x: CP.x + CP.nameW + 5 * CP.slotW + 24, y: CP.y0 + i * CP.rowH };
  };
  const zoneCenter = () => {
    const count = Math.max(game.zones?.length ?? 1, 1);
    const zoneIndex = Math.min(game.zone_index ?? 0, count - 1);
    const rectZ = zoneColumnRect(zoneIndex, count);
    return { x: (rectZ.x0 + rectZ.x1) / 2, y: (rectZ.y0 + rectZ.y1) / 2 + 28 };
  };

  for (const ev of events) {
    if (ev.type === "grouped") {
      const { x, y } = zoneCenter();
      spawnFloater("team combo locked!", x, y, RECIPE_COLOR_TEAM,
        LAYOUT.floater.lifetime, LAYOUT.floater.recipeFont);
    } else if (ev.type === "replaced") {
      const p = rowPos(ev.player_id);
      if (p) spawnFloater("spell replaced", p.x, p.y, "rgba(200,180,255,0.9)");
    } else if (ev.type === "fired" && ev.spell_count > 1) {
      const { x, y } = zoneCenter();
      spawnFloater(`casts fired ×${ev.spell_count}`, x, y, CAST_EVENT_COLOR,
        LAYOUT.floater.lifetime, LAYOUT.floater.recipeFont);
    }
  }
}

/**
 * Compact per-player pending-combo rows (bottom-left UI panel).  No player
 * sprites are rendered — combos are the only per-player element on screen.
 * The local player's row is highlighted.  In realtime mode a per-player
 * cast countdown replaces the classic casts-used counter.
 */
function drawComboPanel(game) {
  const CP = LAYOUT.comboPanel;
  const realtime = roomModeFrom(game) === "realtime";
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

    const usedX = CP.x + CP.nameW + 5 * CP.slotW + 8;
    if (realtime) {
      // Pending-cast countdown (matchable window for team recipes).
      const castS = (e.cast_ms ?? 0) / 1000;
      if (castS > 0) {
        text(`⌛${castS.toFixed(1)}`, usedX, y, CP.font, CAST_EVENT_COLOR);
      }
    } else {
      // Spells committed this round.
      text(`${e.casts_used ?? 0}/${castsPerRound}`, usedX, y, CP.font, "rgba(160,170,200,0.8)");
    }
  });
}

/** @type {Floater[]} */
const floaters = [];

/**
 * Spawn a floating text label that drifts upward and fades out.
 * @param {string} text
 * @param {number} x       - canvas x (centre of text)
 * @param {number} y       - canvas y (baseline at spawn)
 * @param {string} color   - CSS color string (alpha overridden by fade)
 * @param {number} lifetime - seconds until fully faded (default 3.0)
 * @param {number} size     - font px (default LAYOUT.floater.font)
 */
function spawnFloater(text, x, y, color, lifetime = LAYOUT.floater.lifetime, size = LAYOUT.floater.font) {
  floaters.push({ text, x, y, color, age: 0, lifetime, size });
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
    ctx.font = `bold ${f.size ?? LAYOUT.floater.font}px monospace`;
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

// Flat conversion rates + recipe tables are loaded from data/balance.json
// (loadBalanceData) — the same file the Zig server reads, so there is no
// hand-mirrored copy to drift.  `medicine` outputs are per color: color-X
// medicine heals only color-X healable hunger (symmetrical healing).
let UNITS_PER_SLOT = 0;
let MEDICINE_PER_SLOT = 0;
let CASTS_PER_ROUND = 0;
/** Realtime: group-cast buffer / per-cast cooldown (ms) from balance.json. */
let CAST_BUFFER_MS = 500;
let CAST_LOCK_MS = 500;
/** @type {Array<{label: string, pattern: Array<object>, output: object}>} */
let PLAYER_RECIPES = [];
/** @type {Array<{label: string, patterns: Array<Array<object>>, output: object}>} */
let TEAM_RECIPES = [];

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
    for (; ;) {
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
      spawnFloater("chomp!", cx + jitter() * 2, cy + jitter() * 2, "rgba(255,255,255,0.9)", 1.0); // cosmetic: exempt from 3s rule
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
const ELEMENT_NAMES = ["red", "green", "yellow", "blue"];

/** Map Element (agent color) enum string → display character. */
const ELEMENT_CHAR = { red: "♦", green: "▲", yellow: "≋", blue: "~" };

/** Map Element (agent color / slime type) → colour.  Matches the whiteboard:
 *  red / yellow / green / blue scribbles.
 *
 *  SINGLE SOURCE OF COLOR TRUTH: slime blobs, agent key labels (QWER),
 *  combo slot chars, team output preview, hunger-bar healable segments, and
 *  the game-over stats tables all read from this map so a slime color always
 *  matches its agent, its medicine, and its hunger block. */
const ELEMENT_COLOR = {
  red: "rgba(255,90,90,1)",
  green: "rgba(130,230,130,1)",
  yellow: "rgba(250,210,80,1)",
  blue: "rgba(110,160,255,1)",
};

/** Neutral / transmuted slime (matches nothing — needs no agent). */
const NEUTRAL_COLOR = "rgba(138,43,226,1)";

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
  if (frac > 0) rect(H.x0, H.y, w * frac, H.h, H.fill);

  // Healable segments: right end of the current fill, one per slime color
  // (only these use element colors — dim-purple fill = unhealable hunger).
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
  // Danger is signalled by the border, never the fill.
  const nearFull = frac > 0.85;
  rectStroke(H.x0 - 2, H.y - 2, w + 4, H.h + 4, nearFull ? 3 : 1,
    nearFull ? H.dangerBorder : "rgba(255,255,255,0.25)");

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

// --- Organic ooze layer ------------------------------------------------------
//
// Slime is drawn as one contiguous carpet of goo built from seeded "metaball"
// particles:
//   1. Per live zone, per color, scatter soft radial-gradient particles on a
//      low-res offscreen canvas (count ∝ units, deterministic seed → stable
//      shapes, slow sine wobble → living ooze).
//   2. Threshold the offscreen alpha so overlapping halos fuse into a single
//      silhouette; overlapping colors have already blended → organic mixing.
//   3. Paint a 1-ooze-px rim (FIELD.oozeOutline) around the silhouette.
//   4. Blit to the slime field unsmoothed (chunky pixels match the art style).

/** Deterministic PRNG (mulberry32); same seed → same particle layout. */
function mulberry32(seed) {
  let s = seed | 0;
  return function () {
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Parse "rgb(a)(r,g,b…)" → [r,g,b]; white fallback for malformed input. */
function parseRgb(str) {
  const m = /rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/.exec(str);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : [255, 255, 255];
}

/** Ooze fill colors, index-aligned with zoneOozeUnits(): 4 elements + neutral.
 *  Derived from ELEMENT_COLOR/NEUTRAL_COLOR (single source of color truth). */
const OOZE_RGB = [
  ...ELEMENT_NAMES.map((name) => parseRgb(ELEMENT_COLOR[name])),
  parseRgb(NEUTRAL_COLOR),
];

/** Low-res goo canvas covering the slime field. */
const oozeCanvas = document.createElement("canvas");
oozeCanvas.width = Math.ceil((FIELD.x1 - FIELD.x0) / FIELD.oozeScale);
oozeCanvas.height = Math.ceil((FIELD.y1 - FIELD.y0) / FIELD.oozeScale);
const octx = oozeCanvas.getContext("2d", { willReadFrequently: true });

/** Per-zone ooze unit counts, index-aligned with OOZE_RGB.  Transmuted
 *  (neutralized) slime folds into neutral, as the old blobs did. */
function zoneOozeUnits(z) {
  return [
    z.red ?? 0, z.green ?? 0, z.yellow ?? 0, z.blue ?? 0,
    (z.neutral ?? 0) + sumColors(z.neutralized),
  ];
}

/** Zone idx → total units when the zone was first seen this game.  Coverage
 *  = totalNow / totalInit: a fresh zone is fully carpeted, then the ooze
 *  recedes as slime is eaten/transmuted.  Cleared in clearEntityState(). */
const zoneOozeInitTotals = new Map();

/** Coverage ratio (0..1) for zone `i` with current total `totalNow`.
 *  First sighting records the initial total; `max` guards against counts
 *  growing later (a fuller zone re-becomes the 100% baseline). */
function zoneOozeCoverage(i, totalNow) {
  const init = Math.max(zoneOozeInitTotals.get(i) ?? 0, totalNow);
  zoneOozeInitTotals.set(i, init);
  return init > 0 ? totalNow / init : 0;
}

/**
 * Build wobbled particles for one (zone, color) at time `t` (seconds).
 * Particles gather around 1-3 seeded cluster centers so each color forms
 * organic pools that interdigitate with its neighbours; positions/phases are
 * pure functions of (seed, t) so nothing flickers frame-to-frame.
 * `x0..x1` is the zone's column span (ooze px); only scatter particles and
 * cluster fringes may stray up to `bleed` px outside it, so a zone's mass
 * stays in its own column while edges still fuse with neighbours.
 * `footprint` is this color's total solid area budget (ooze px²) — the
 * zone's area × its unit share × coverage, so a fresh zone is carpeted and
 * the ooze recedes as slime is eaten / transmuted.
 */
function oozeParticles(zoneIdx, colorIdx, units, footprint, x0, x1, bleed, t) {
  if (units <= 0 || footprint <= 0) return [];
  const rng = mulberry32(((zoneIdx + 1) * 131071) ^ ((colorIdx + 1) * 8191));
  const h = oozeCanvas.height;
  const count = Math.min(units, FIELD.oozeParticleCap);
  const r = Math.max(FIELD.oozeMinR, Math.sqrt(footprint / count / Math.PI));

  const nClusters = Math.min(3, 1 + Math.floor(count / 12));
  const inset = (x1 - x0) * 0.08;
  const clusters = [];
  for (let c = 0; c < nClusters; c++) {
    // Centers stay inside the column proper (and on-canvas) so the zone's
    // mass reads in its own round; fringes/halos provide the mixing.
    const cx = Math.min(oozeCanvas.width - 4,
      Math.max(4, x0 + inset + rng() * (x1 - x0 - 2 * inset)));
    clusters.push({ cx, cy: h * (0.15 + 0.7 * rng()) });
  }
  const spreadX = (x1 - x0) * 0.3;
  const spreadY = h * 0.32;

  const ps = [];
  for (let i = 0; i < count; i++) {
    // Every 3rd particle scatters uniformly across the bled span (fills
    // corners the clusters miss); the rest gather on cluster centers with a
    // triangular distribution: dense cores, ragged fringes.
    const scatter = i % 3 === 2;
    const cl = clusters[i % nClusters];
    const bx = scatter ? x0 - bleed + rng() * (x1 - x0 + 2 * bleed)
      : cl.cx + (rng() + rng() - 1) * spreadX;
    const by = scatter ? h * (0.04 + 0.92 * rng())
      : cl.cy + (rng() + rng() - 1) * spreadY;
    const phase = rng() * Math.PI * 2;
    const freq = FIELD.oozeWobbleFreq * (0.5 + rng());
    const amp = FIELD.oozeWobbleAmp * (0.5 + rng());
    // No clamping: particles past the field edge clip naturally (clamping
    // piles cores on the border pixel → dense bar artifact).
    ps.push({
      x: bx + Math.sin(t * freq + phase) * amp,
      y: by + Math.cos(t * freq * 1.37 + phase * 1.7) * amp,
      r,
      colorIdx,
    });
  }
  return ps;
}

/** Paint one soft particle: solid-ish core, wide faint halo.  Halos of nearby
 *  particles sum past the alpha cutoff, fusing them into contiguous goo. */
function paintOozeParticle(p) {
  const [r, g, b] = OOZE_RGB[p.colorIdx];
  const R = p.r * 2.2;
  const grad = octx.createRadialGradient(p.x, p.y, 0, p.x, p.y, R);
  grad.addColorStop(0, `rgba(${r},${g},${b},0.95)`);
  grad.addColorStop(0.45, `rgba(${r},${g},${b},0.5)`);
  grad.addColorStop(1, `rgba(${r},${g},${b},0)`);
  octx.fillStyle = grad;
  octx.beginPath();
  octx.arc(p.x, p.y, R, 0, Math.PI * 2);
  octx.fill();
}

/** Threshold the goo alpha into a solid silhouette, then paint the rim. */
function oozeThresholdAndOutline() {
  const w = oozeCanvas.width, h = oozeCanvas.height;
  const img = octx.getImageData(0, 0, w, h);
  const d = img.data;
  const cutoff = FIELD.oozeAlphaCutoff;
  for (let i = 3; i < d.length; i += 4) d[i] = d[i] < cutoff ? 0 : 255;

  const [or_, og, ob] = FIELD.oozeOutline;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      if (d[i + 3] === 0) continue;
      // Rim = opaque pixel touching the field edge or a transparent 4-neighbour.
      // (Alpha offsets: left i-1, right i+7, up i-w*4+3, down i+w*4+3.)
      const rim = x === 0 || x === w - 1 || y === 0 || y === h - 1 ||
        d[i - 1] === 0 || d[i + 7] === 0 ||
        d[i - w * 4 + 3] === 0 || d[i + w * 4 + 3] === 0;
      if (rim) { d[i] = or_; d[i + 1] = og; d[i + 2] = ob; }
    }
  }
  octx.putImageData(img, 0, 0);
}

/**
 * Draw the full ooze carpet for all live zones at time `t` (seconds).
 * Zones bleed into each other horizontally so the carpet reads as one
 * continuous organic layer; per-color particle lists are painted round-robin
 * so no color systematically sits on top where they mix.
 */
function drawOoze(zones, zoneIndex, t) {
  const w = oozeCanvas.width, h = oozeCanvas.height;
  octx.clearRect(0, 0, w, h);

  const colW = w / Math.max(zones.length, 1);
  const bleed = colW * FIELD.oozeBleed;
  const zoneArea = colW * h;
  const lists = [];
  for (let i = zoneIndex; i < zones.length; i++) {
    const units = zoneOozeUnits(zones[i]);
    const total = units.reduce((a, u) => a + u, 0);
    const coverage = zoneOozeCoverage(i, total);
    // Footprint budget: full coverage tiles the zone (× overfill so random
    // gaps close); shrinks with coverage as the zone is eaten down.  The
    // gamma counteracts the overfill headroom, which would otherwise keep a
    // half-eaten zone looking fully carpeted.
    const budget = zoneArea * Math.pow(coverage, FIELD.oozeShrinkGamma) *
      FIELD.oozeFillFactor;
    const x0 = i * colW;
    const x1 = (i + 1) * colW;
    for (let c = 0; c < units.length; c++) {
      const footprint = total > 0 ? budget * (units[c] / total) : 0;
      lists.push(oozeParticles(i, c, units[c], footprint, x0, x1, bleed, t));
    }
  }
  const maxLen = lists.reduce((m, l) => Math.max(m, l.length), 0);
  for (let k = 0; k < maxLen; k++) {
    for (const l of lists) if (k < l.length) paintOozeParticle(l[k]);
  }

  oozeThresholdAndOutline();

  ctx.save();
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(oozeCanvas, FIELD.x0, FIELD.y0, FIELD.x1 - FIELD.x0, FIELD.y1 - FIELD.y0);
  ctx.restore();
}

/**
 * Draw the slime field: a continuous organic ooze carpet across the live
 * zones (color = slime type = required agent, grey = neutral/transmuted),
 * with zone columns overlaid.  Consumed zones are dimmed; the active zone is
 * highlighted.
 */
function drawSlimeField(game) {
  const zones = game.zones ?? [];
  const count = zones.length;
  if (count === 0) return;
  const zoneIndex = game.zone_index ?? 0;

  // Backdrop under the ooze carpet.
  rect(FIELD.x0, FIELD.y0, FIELD.x1 - FIELD.x0, FIELD.y1 - FIELD.y0,
    "rgba(255,255,255,0.03)");

  drawOoze(zones, zoneIndex, performance.now() / 1000);

  // Zone overlays: eaten dimming, borders, and round labels sit on top of
  // the goo so the round structure stays legible.
  for (let i = 0; i < count; i++) {
    const rectZ = zoneColumnRect(i, count);
    const zw = rectZ.x1 - rectZ.x0;
    const zh = rectZ.y1 - rectZ.y0;

    if (i < zoneIndex) {
      // Consumed zone.
      rect(rectZ.x0, rectZ.y0, zw, zh, FIELD.eatenFill);
      ctx.save();
      ctx.fillStyle = "rgba(150,150,160,0.7)";
      ctx.font = `bold 16px monospace`;
      ctx.textAlign = "center";
      ctx.fillText("EATEN", (rectZ.x0 + rectZ.x1) / 2, (rectZ.y0 + rectZ.y1) / 2);
      ctx.restore();
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
      spawnFloater("chomp", g.x + G.size / 2, g.y, "rgba(230,230,240,0.85)", 0.8); // cosmetic: exempt from 3s rule
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
  text("[Q]♦", px + M.elementCols[0], eRowY, M.elementFont, ELEMENT_COLOR.red);
  text("[W]▲", px + M.elementCols[1], eRowY, M.elementFont, ELEMENT_COLOR.green);
  text("[E]≋", px + M.elementCols[2], eRowY, M.elementFont, ELEMENT_COLOR.yellow);
  text("[R]~", px + M.elementCols[3], eRowY, M.elementFont, ELEMENT_COLOR.blue);

  text("[Esc] Cancel", px, my + M.padTopY + M.cancelRowDy, M.cancelFont, "rgba(180,180,180,0.8)");

  const tbw = mw - M.padX * 2;

  if (roomModeFrom(game) === "realtime") {
    // Realtime: no round countdown, no shared cast timer.  Every cast fires
    // at the end of its OWN buffer (entity.cast_ms); casts completing a team
    // recipe merge and fire together.  The bar tracks the local player's
    // pending cast.
    const bufferS = (game.cast_buffer_ms ?? 0) / 1000;
    const own = (game.entities ?? []).find(e => e.owner === game.player_id);
    const ownCastS = own ? (own.cast_ms ?? 0) / 1000 : 0;
    const lockS = own ? (own.lock_ms ?? 0) / 1000 : 0;
    const othersPending = (game.entities ?? [])
      .some(e => e.owner !== game.player_id && (e.cast_ms ?? 0) > 0);

    const castFrac = ownCastS > 0 && bufferS > 0
      ? Math.max(0, Math.min(1, ownCastS / bufferS))
      : 0;
    const barH = M.timerBarDy + M.timerBarH - M.castBarDy; // span both classic bars
    rect(px, my + M.castBarDy, tbw, barH, "rgba(30,30,30,0.8)");
    if (ownCastS > 0) {
      rect(px, my + M.castBarDy, tbw * castFrac, barH, "rgba(120,220,255,0.9)");
    }
    rectStroke(px, my + M.castBarDy, tbw, barH, 1, "rgba(255,255,255,0.3)");

    let status;
    if (ownCastS > 0) {
      status = `Dispensing: ${ownCastS.toFixed(1)}s`;
    }
    if (lockS > 0 && ownCastS <= 0) status = `Cooldown: ${lockS.toFixed(1)}s`;
    text(status, px, my + M.timerTextDy, M.timerTextFont, C_TEXT);
  } else {
    const castsPerRound = game.casts_per_round ?? 1;
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
    // "Auto-cast" spells it out: classic commits the pending combo when the
    // cast bar empties — Enter does nothing in this mode.
    text(`Auto-cast in: ${castText}s (${castsUsed}/${castsPerRound})  ·  Round: ${roundText}s`,
      px, my + M.timerTextDy, M.timerTextFont, C_TEXT);
  }

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
  spawnRecipeFloaters(game);
  spawnCastEventFloaters(game);

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

/** Sum a per-color {red, green, yellow, blue} object. */
function sumColors(obj) {
  return ELEMENT_NAMES.reduce((t, name) => t + (obj?.[name] ?? 0), 0);
}

/** Add per-color object `add` into accumulator object `acc`. */
function addColors(acc, add) {
  for (const name of ELEMENT_NAMES) acc[name] = (acc[name] ?? 0) + (add?.[name] ?? 0);
}

/**
 * Draw non-zero per-color values as colored "♦12 ▲5" cells starting at x.
 * Draws a grey dash when everything is zero.
 */
function drawColorCells(x, y, font, obj) {
  let dx = x;
  let any = false;
  for (const name of ELEMENT_NAMES) {
    const v = obj?.[name] ?? 0;
    if (!v) continue;
    any = true;
    const str = `${ELEMENT_CHAR[name]}${v}`;
    text(str, dx, y, font, ELEMENT_COLOR[name]);
    ctx.font = `${font}px monospace`;
    dx += ctx.measureText(str).width + 8;
  }
  if (!any) text("—", dx, y, font, "rgba(120,120,140,0.6)");
}

/**
 * End-of-game tuning report: outcome, round-by-round table, per-player
 * table, recipe fire counts, derived waste/overheal totals.
 */
function drawGameOver(msg) {
  clear();
  const L = LAYOUT.gameOver;
  const score = msg && msg.score !== undefined && msg.score !== null ? msg.score : "?";
  const stats = msg ? msg.stats : null;

  const reasonText = stats
    ? (stats.reason === "hunger_full" ? "The Lil Guys got full!" : "Slime field cleared!")
    : "";
  text(`Encounter over — ${reasonText}`, L.x, L.titleY, L.titleFont, C_HEADER);
  const hungerText = stats ? `   ·   Hunger ${stats.hunger_final}/${stats.hunger_max}` : "";
  text(`Neutral slime consumed: ${score}${hungerText}`, L.x, L.scoreY, L.scoreFont, C_SLIME_HDR);

  if (!stats) {
    text("Press any key to return to lobby.", L.x, SH - 40, L.hintFont, C_TEXT);
    return;
  }

  // ---- Round-by-round table ------------------------------------------------
  const C = L.cols;
  let y = L.roundsY;
  text("ROUND", C.round, y, L.sectionFont, C_HEADER);
  text("CASTS", C.casts, y, L.sectionFont, C_HEADER);
  text("AGENTS", C.agents, y, L.sectionFont, C_HEADER);
  text("NEUTRALIZED", C.neutralized, y, L.sectionFont, C_HEADER);
  text("ESCAPED", C.escaped, y, L.sectionFont, C_HEADER);
  text("MED (HEALED)", C.healed, y, L.sectionFont, C_HEADER);
  text("HUNGER", C.hunger, y, L.sectionFont, C_HEADER);
  y += L.rowH;

  const totals = { agents: {}, medicine: {}, healed: {}, neutralized: {}, escaped: {} };
  let neutralTotal = 0;
  for (const [i, r] of (stats.rounds ?? []).entries()) {
    text(String(i + 1), C.round, y, L.rowFont, C_TEXT);
    text(String(r.casts), C.casts, y, L.rowFont, C_TEXT);
    drawColorCells(C.agents, y, L.rowFont, r.agents);
    drawColorCells(C.neutralized, y, L.rowFont, r.neutralized);
    drawColorCells(C.escaped, y, L.rowFont, r.escaped);
    // Medicine: dispensed with healed total in parens.
    drawColorCells(C.healed, y, L.rowFont, r.medicine);
    text(`(+${sumColors(r.healed)})`, C.hunger - 60, y, L.rowFont, "rgba(255,80,180,0.9)");
    text(`${r.hunger_after}`, C.hunger, y, L.rowFont,
      r.hunger_extra > 0 ? "rgba(255,150,50,0.95)" : "rgba(160,220,160,0.9)");
    y += L.rowH;

    addColors(totals.agents, r.agents);
    addColors(totals.medicine, r.medicine);
    addColors(totals.healed, r.healed);
    addColors(totals.neutralized, r.neutralized);
    addColors(totals.escaped, r.escaped);
    neutralTotal += r.neutral ?? 0;
  }

  // Derived totals: agent waste + medicine overheal.
  const wasted = sumColors(totals.agents) - sumColors(totals.neutralized);
  const overheal = sumColors(totals.medicine) - sumColors(totals.healed);
  y += 4;
  text(
    `totals: neutralized ${sumColors(totals.neutralized)}  ·  natural ${neutralTotal}  ·  escaped ${sumColors(totals.escaped)}` +
    `  ·  agents wasted ${wasted}  ·  medicine overheal ${overheal}`,
    C.round, y, L.rowFont, "rgba(200,200,210,0.9)",
  );
  y += L.rowH + 14;

  // ---- Per-player table ----------------------------------------------------
  const P = L.pcols;
  text("PLAYER", P.name, y, L.sectionFont, C_HEADER);
  text("CASTS", P.casts, y, L.sectionFont, C_HEADER);
  text("DISPENSE SLOTS", P.dispense, y, L.sectionFont, C_HEADER);
  text("MEDICINE SLOTS", P.medicine, y, L.sectionFont, C_HEADER);
  text("RECIPES", P.recipes, y, L.sectionFont, C_HEADER);
  text("FIZZLES", P.fizzles, y, L.sectionFont, C_HEADER);
  y += L.rowH;
  for (const p of stats.players ?? []) {
    text(p.name || "(anon)", P.name, y, L.rowFont, C_TEXT);
    text(String(p.casts), P.casts, y, L.rowFont, C_TEXT);
    drawColorCells(P.dispense, y, L.rowFont, p.dispense);
    drawColorCells(P.medicine, y, L.rowFont, p.medicine);
    text(`${p.recipe_casts}/${p.casts}`, P.recipes, y, L.rowFont, "rgba(255,255,140,0.9)");
    text(String(p.fizzles ?? 0), P.fizzles, y, L.rowFont,
      (p.fizzles ?? 0) > 0 ? "rgba(255,120,120,0.9)" : "rgba(120,120,140,0.7)");
    y += L.rowH;
  }
  y += 14;

  // ---- Recipe fire counts (labels resolved by table index; order must
  // match balance.zig) --------------------------------------------------------
  const recipeParts = [];
  (stats.player_recipe_hits ?? []).forEach((n, i) => {
    if (n > 0 && PLAYER_RECIPES[i]) recipeParts.push(`${PLAYER_RECIPES[i].label} ×${n}`);
  });
  (stats.team_recipe_hits ?? []).forEach((n, i) => {
    if (n > 0 && TEAM_RECIPES[i]) recipeParts.push(`${TEAM_RECIPES[i].label} ×${n} (team)`);
  });
  text("RECIPES", P.name, y, L.sectionFont, C_HEADER);
  y += L.rowH;
  text(recipeParts.length > 0 ? recipeParts.join("  ·  ") : "none fired",
    P.name, y, L.rowFont, recipeParts.length > 0 ? "rgba(255,255,140,0.9)" : "rgba(120,120,140,0.7)");
  y += L.rowH;
  text(`total spells cast: ${stats.casts_total}  ·  zones eaten: ${(stats.rounds ?? []).length}/${stats.zone_count}`,
    P.name, y, L.rowFont, "rgba(200,200,210,0.9)");

  text("Press any key to return to lobby.", L.x, SH - 40, L.hintFont, C_TEXT);
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
      // Adopt the room's mode (render frames overwrite this later).
      roomMode = msg.mode === "realtime" ? "realtime" : "classic";
      // Adopt the lobby's config: a room created from /config/{hash} uses
      // that hash's balance tables; joiners from any page must match.
      const roomConfig = typeof msg.config === "string" ? msg.config : null;
      if (roomConfig !== loadedConfigHash) {
        loadBalanceData(roomConfig).catch((err) =>
          console.error("[game] failed to load lobby config", err));
      }
    } else if (msg.tag === "error") {
      // Every pre-lobby action is user-initiated (C/J keys), so always show
      // the reason.
      const errMsg =
        msg.reason === "not_found" ? "Lobby not found." :
          msg.reason === "config_not_found" ? "Saved config not found — re-save it at /tune." :
            `Error: ${msg.reason}`;
      resetPreLobby();
      preLobbyError = errMsg;
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

/** Forward one key to the Zig client via the tab WebSocket. */
function sendKey(key) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ key }));
  }
}

document.addEventListener("keydown", (e) => {
  // During pre_lobby, handle input locally — do not forward to Zig.
  if (latestMsg && latestMsg.phase === "pre_lobby") {
    handlePreLobbyKey(e);
    return;
  }

  if (!FORWARDED_KEYS.has(e.key)) return;
  e.preventDefault();
  sendKey(e.key);
});

/** Send a pre-lobby room action to the bridge. */
function sendPreLobbyAction(action) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(action));
  }
}

/**
 * Handle a keydown event while the pre_lobby screen is shown.
 * Input is handled entirely in the browser — nothing is forwarded to Zig.
 * @param {KeyboardEvent} e
 */
function handlePreLobbyKey(e) {
  e.preventDefault();

  if (preLobbyMode === "choose") {
    const isC = e.key === "c" || e.key === "C";
    const isR = e.key === "r" || e.key === "R";
    if (isC || isR) {
      // Locked config: [C] creates its game type, [R] does nothing.
      // Otherwise fixed mapping: [C] = classic, [R] = realtime, always.
      // Creating from /config/{hash} keeps that saved config.
      if (configLockedMode !== null && isR) return;
      preLobbyError = "";
      const mode = configLockedMode ?? (isR ? "realtime" : "classic");
      sendPreLobbyAction({ action: "create", mode, config: PAGE_CONFIG_HASH ?? undefined });
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
        sendPreLobbyAction({ action: "join", code: preLobbyCode });
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
