"use strict";

const LAYOUT = {
  // DESIGN SPACE.  Every coordinate in this file is authored in these units.
  // The canvas backing store is `renderScale` times larger (index.html) and a
  // single setTransform at boot scales design units up to it, so art and text
  // gain resolution without any coordinate in here changing.
  screen: { w: 1024, h: 768 },
  renderScale: 2,
  bg: "#14141e",

  // Slime field: the server-authoritative grid.  Its rows × cols come from
  // the wire (balance.slime_grid), so cell size is derived, not fixed: the
  // grid is square-celled and letterboxed inside this rect (see gridRect).
  slimeField: {
    x0: 40, x1: 984, y0: 220, y1: 620,
    labelDy: 24,
    border: "rgba(180,200,255,0.25)",
    reservoirFont: 14,

    // Empty cell: a dim recessed socket, so a hole reads as "awaiting the
    // reservoir" rather than as background.
    socketFill: "rgba(0,0,0,0.22)",
    socketBorder: "rgba(255,255,255,0.05)",

    // --- Individual slime unit tiles (see tileSprite) --------------------
    tileMax: 72,        // cap on cell size (design px); small grids letterbox
    tileGap: 0.18,      // inset per side as a fraction of the cell: large, so
    // units read as discrete candies rather than a contiguous mass
    tileRadius: 0.28,   // body corner radius as a fraction of the body size
    symbolAlpha: 0.42,  // element glyph opacity stamped on the body
    // Per-cell animation durations (seconds) and idle wobble.
    dropS: 0.15,        // refill slide-in from above
    popS: 0.22,         // eaten-tile burst
    flashS: 0.25,       // neutralized white bloom
    dissolveS: 0.3,     // agent-destroyed tile: shrink + fade in place
    bobAmp: 0.02,       // idle breathing: ±fraction of tile size
    bobFreq: 1.6,       // idle breathing rate (rad/s)

    // --- Transmute cohort highlight (see cohortHighlight) -----------------
    //
    // Drawn at the SOCKET edge, outside the tile body, so it can never be
    // read as the static inner ring that marks an already-neutralized unit.
    cohortWidth: 2.5,     // outline stroke width (design px)
    cohortPulseHz: 2.4,   // pulse rate
    cohortAlphaMin: 0.35, // pulse trough
    cohortAlphaMax: 0.95, // pulse crest
  },

  hungerBar: {
    x0: 40, x1: 984, y: 150, h: 18,
    labelFont: 14, labelDy: -8,
    bg: "rgba(30,10,10,0.78)",
    // Grey, matching neutral/neutralized slime: this portion is not healable,
    // and element colors are reserved for the healable segments.
    fill: "rgba(150,150,162,0.9)",
    dangerBorder: "rgba(255,60,60,0.95)",
    textFont: 13,
  },

  score: { x: 40, y: 90, font: 20 },

  headers: { waveX: 40, waveY: 50, waveFont: 20, labelDy: -30, labelFont: 18 },

  // Per-player pending-combo rows, bottom-left beside the action menu.
  comboPanel: { x: 24, y0: 652, rowH: 18, font: 13, slotW: 14, nameW: 42 },

  // Lil Guys: one per connected player, walking to the grid cell the SERVER
  // reserved for them (see tickLilGuys).  `speed` is px/s; `snap` is how
  // close counts as arrived.
  lilGuys: { size: 48, speed: 220, snap: 3 },

  actionMenu: {
    w: 340, h: 108, marginBottom: 128,
    padX: 10, padTopY: 14,
    actionRowDy: 16, actionFont: 16, actionCols: [0, 150],
    elementRowDy: 34, elementFont: 13, elementCols: [0, 80, 160, 240],
    cancelRowDy: 48, cancelFont: 12,
    castBarDy: 56, castBarH: 16,
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
    feastY: 150,
    // Match-wide feast tallies (one row per measure, label + colored cells).
    fcols: { label: 40, cells: 260 },
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
/** Warning red: wasted agents, and a projected color with no cohort to hit. */
const C_BAD = "rgba(255,110,110,1)";
/** Muted tint for the "wasted" tail of a dispense floater — present but not
 *  competing with the transmute count that actually accomplished something. */
const C_MUTED = "rgba(190,150,150,0.85)";

/** Sprite used for the cosmetic Lil Guys roaming the slime field. */
const LIL_GUY_SPRITE = "grunt";

/** Sprite sheets to load; Lil Guys are the only sprites rendered. */
const CLASSES = [LIL_GUY_SPRITE];

const sprites = new Map();

async function loadAssets() {
  await Promise.all([
    loadBalanceData(),
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
  lastScoreSeen = 0;
  lastHungerSeen = 0;
  lilGuys.clear();
  lastBitePos = null;
  // Grid animation state is per-match: a new game's first frame must adopt its
  // grid silently rather than diff it against the last game's board.
  prevGrid = [];
  cellAnim.clear();
  bittenThisFrame.clear();
  dispensedColorsThisFrame.clear();
  lastTransientGame = null;
}

const canvas = document.getElementById("canvas");
const ctx = canvas.getContext("2d");

// Map design space onto the larger backing store, once.  Everything below
// draws in design units; nothing else touches the base transform (the few
// ctx.save()/restore() pairs in this file apply only relative transforms, so
// this survives them).
ctx.setTransform(LAYOUT.renderScale, 0, 0, LAYOUT.renderScale, 0, 0);

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
    text("[C]  Create lobby", L.optX, L.optY0, L.optFont, highlight);
    text("[J]  Join existing lobby", L.optX, L.optY0 + L.optGap, L.optFont, C_TEXT);
    if (PAGE_CONFIG_HASH) {
      text(`(custom config ${PAGE_CONFIG_HASH})`,
        L.optX, L.optY0 + 2 * L.optGap, L.errorFont, "rgba(170,170,170,1)");
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

  drawRecipeGuide();
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
 * Lobby study guide: how casting works + every defined recipe with its key
 * sequence AND symbols, all in parity colors (slime = agent = medicine =
 * hunger block).  Recipes appear in data/balance.json order.
 */
function drawRecipeGuide() {
  const L = LAYOUT.lobby;
  let y = L.guideY;

  text("HOW CASTING WORKS", L.guideX, y, L.guideFont + 2, C_HEADER);
  y += L.guideLineH;
  const descColor = "rgba(200,200,210,0.9)";
  // ENTER fires a cast after its own buffer; team-recipe matches merge and
  // fire together.
  const castingLine = [
    { str: `Press ENTER to cast — it fires ${(CAST_BUFFER_MS / 1000).toFixed(1)}s later.`, color: descColor },
    { str: "Casts completing a team recipe in that window merge and fire together!", color: RECIPE_COLOR_TEAM },
    ...(CAST_LOCK_MS > 0
      ? [{ str: `${(CAST_LOCK_MS / 1000).toFixed(1)}s cooldown per cast.`, color: descColor }]
      : []),
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
      { str: "Dispensed agents neutralize matching-color slime ON THE GRID;", color: ACTION_COLOR.dispense },
      { str: "medicine heals matching-color hunger.", color: ACTION_COLOR.medicine },
    ],
    [
      { str: "Agents are split across the cells of that color — extras are wasted, so time your casts.", color: descColor },
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
 * indices agree by construction).  Floaters rise from the field's center,
 * stacked when several fire at once.
 */
function spawnRecipeFloaters(game) {
  const fired = game.recipes_fired ?? [];
  if (fired.length === 0) return;

  const { x: cx, y: cy } = fieldCenter();
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

/**
 * Dispense-outcome floaters (`game.agents_dispensed`, transient): what a cast's
 * agents actually accomplished, one label per color per converted batch.
 *
 * Also records which colors fired, so updateGridAnims can tell a cell that was
 * DESTROYED by the transmutation from one that was merely refilled.  That set
 * is consumed and cleared by updateGridAnims on the same frame.
 */
function spawnDispenseFloaters(game) {
  const events = game.agents_dispensed ?? [];
  if (events.length === 0) return;

  const { x: cx, y: cy } = fieldCenter();
  const STACK = LAYOUT.floater.stack;

  events.forEach((ev, i) => {
    dispensedColorsThisFrame.add(ev.color);
    const wasted = ev.dispensed - ev.transmuted;
    const glyph = ELEMENT_CHAR[ev.color] ?? "";
    const head = `${glyph}${ev.dispensed} → ${ev.transmuted} transmuted`;
    const y = cy + i * STACK;
    spawnFloater(head, cx, y, ELEMENT_COLOR[ev.color] ?? C_TEXT,
      LAYOUT.floater.lifetime, LAYOUT.floater.font);
    // Overshoot gets its own muted label: the count that matters is the one
    // that landed, but a player tuning combo size needs to see the surplus.
    if (wasted > 0) {
      spawnFloater(`(${wasted} wasted)`, cx, y + LAYOUT.floater.stack * 0.7,
        C_MUTED, LAYOUT.floater.lifetime, LAYOUT.floater.font);
    }
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
 * events from the field's center (where recipe floaters appear).
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
  // Group events sit just below the recipe floaters so both stay readable.
  const groupPos = () => {
    const p = fieldCenter();
    return { x: p.x, y: p.y + 28 };
  };

  for (const ev of events) {
    if (ev.type === "grouped") {
      const { x, y } = groupPos();
      spawnFloater("team combo locked!", x, y, RECIPE_COLOR_TEAM,
        LAYOUT.floater.lifetime, LAYOUT.floater.recipeFont);
    } else if (ev.type === "replaced") {
      const p = rowPos(ev.player_id);
      if (p) spawnFloater("spell replaced", p.x, p.y, "rgba(200,180,255,0.9)");
    } else if (ev.type === "fired" && ev.spell_count > 1) {
      const { x, y } = groupPos();
      spawnFloater(`casts fired ×${ev.spell_count}`, x, y, CAST_EVENT_COLOR,
        LAYOUT.floater.lifetime, LAYOUT.floater.recipeFont);
    }
  }
}

/**
 * Compact per-player pending-combo rows (bottom-left UI panel).  No player
 * sprites are rendered — combos are the only per-player element on screen.
 * The local player's row is highlighted and carries its cast countdown.
 */
function drawComboPanel(game) {
  const CP = LAYOUT.comboPanel;
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

    // Pending-cast countdown (the matchable window for team recipes).
    const usedX = CP.x + CP.nameW + 5 * CP.slotW + 8;
    const castS = (e.cast_ms ?? 0) / 1000;
    if (castS > 0) {
      text(`⌛${castS.toFixed(1)}`, usedX, y, CP.font, CAST_EVENT_COLOR);
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
/** Group-cast buffer / per-cast cooldown (ms) from balance.json. */
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
 * CONTRACT: `combos` holds AT MOST ONE COMBO PER PLAYER (see
 * projectedCombos).  The server additionally requires a team recipe's patterns
 * to be filled by DISTINCT players; under this contract two distinct indices
 * are already two distinct players, so matching distinct indices — as the loop
 * below does via `picked` — enforces that rule.  Passing two combos from one
 * player would silently break parity and over-project team recipes.
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

/**
 * The combo to project per player: the COMMITTED one if they have a cast
 * buffering, otherwise whatever they are currently typing.
 *
 * Submitted wins because it is what will actually fire — and the two are
 * independent server-side (submitting clears the typing pool, but the player
 * may immediately start a new combo), so a player mid-cast who has begun
 * typing again would otherwise flip the preview to a combo that is not the
 * one about to land.
 *
 * ONE COMBO PER OWNER, mirroring the server: casts fire out of a pid-indexed
 * pool, so a player can never contribute two casts to a batch, and team
 * recipes require DISTINCT players.  Deduplicating by owner here keeps that
 * rule true of the projection even if a snapshot ever carried two entities for
 * one player — otherwise a lone player typing half of a team recipe would see
 * it falsely projected as complete.
 */
function projectedCombos(game) {
  const byOwner = new Map();
  for (const e of game.entities ?? []) {
    if (byOwner.has(e.owner)) continue;
    const submitted = e.submitted ?? [];
    byOwner.set(e.owner, submitted.length > 0 ? submitted : (e.combo ?? []));
  }
  return [...byOwner.values()];
}

/**
 * Per-color risk readout for the projected agents: how many of the on-grid
 * cohort they can transmute, and how many overshoot into nothing.
 *
 * Reach is the on-grid cohort ONLY — surplus agents are wasted, never banked
 * against the off-grid reservoir — so `wasted` is the tuning signal that tells
 * a player their combo is too big for the board.
 *
 * @returns {Array<{color: string, agents: number, hit: number, cohort: number,
 *   wasted: number}>} one entry per projected color, in ELEMENT_NAMES order.
 */
function cohortRisk(game) {
  const projected = matchRecipes(projectedCombos(game));
  const grid = game.grid ?? [];
  const cohorts = {};
  for (const name of grid) {
    const el = modifiedElement(name);
    if (el !== null) cohorts[el] = (cohorts[el] ?? 0) + 1;
  }

  const out = [];
  for (const color of ELEMENT_NAMES) {
    const agents = projected.units[color] ?? 0;
    if (agents === 0) continue;
    const cohort = cohorts[color] ?? 0;
    const hit = Math.min(agents, cohort);
    out.push({ color, agents, hit, cohort, wasted: agents - hit });
  }
  return out;
}

/**
 * Flat indices of every cell a projected cast could transmute, with the color
 * driving each highlight.
 *
 * Deliberately the WHOLE eligible cohort, never a predicted subset: the server
 * picks its victims with a seeded random shuffle (slime.zig neutralize), so
 * marking specific cells would be a guess the client cannot honour.  The count
 * in the action-menu readout carries the precision instead.
 *
 * @returns {Map<number, string>} flat index → element color
 */
function cohortHighlight(game) {
  const marks = new Map();
  const risk = cohortRisk(game);
  if (risk.length === 0) return marks;

  const colors = new Set(risk.map(r => r.color));
  const grid = game.grid ?? [];
  for (let flat = 0; flat < grid.length; flat++) {
    const el = modifiedElement(grid[flat]);
    if (el !== null && colors.has(el)) marks.set(flat, el);
  }
  return marks;
}

// ---------------------------------------------------------------------------
// Feast tracking (score / hunger deltas → floaters over the bitten cell)
// ---------------------------------------------------------------------------

let lastScoreSeen = 0;
let lastHungerSeen = 0;

/**
 * Call once per drawGame frame, AFTER tickLilGuys so `lastBitePos` already
 * points at the cell bitten on this frame.  Score and hunger only move when a
 * Lil Guy eats or medicine lands, so the deltas are floated over that cell
 * (falling back to the field center for medicine, which has no cell).
 */
function updateFeastTracking(game) {
  const score = game.score ?? 0;
  const hunger = game.hunger?.current ?? 0;
  const scoreGain = score - lastScoreSeen;
  const hungerGain = hunger - lastHungerSeen;
  lastScoreSeen = score;
  lastHungerSeen = hunger;

  if (scoreGain === 0 && hungerGain === 0) return;

  const at = lastBitePos ?? fieldCenter();
  const jitter = () => (Math.random() - 0.5) * LAYOUT.floater.jitter;
  const STACK = LAYOUT.floater.stack;

  if (scoreGain > 0) {
    spawnFloater(`+${scoreGain}`, at.x + jitter(), at.y - STACK, "rgba(100,220,100,1)");
  }
  if (hungerGain > 0) {
    spawnFloater(`+${hungerGain} hunger`, at.x + jitter(), at.y + STACK, "rgba(255,150,50,1)");
  } else if (hungerGain < 0) {
    // Medicine: healing is cast-driven, so anchor it at the field center.
    const p = fieldCenter();
    spawnFloater(`${hungerGain} hunger (medicine)`, p.x + jitter(), p.y + STACK,
      "rgba(255,80,180,1)");
  }
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

/** Neutral slime: needs no agent, so it must not read as any element color.
 *  Grey is the "safe / inert" color — shared by neutral and neutralized
 *  tiles, and by the non-healable portion of the hunger bar. */
const NEUTRAL_COLOR = "rgba(150,150,162,1)";

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
// Slime field (the server-authoritative grid)
// ---------------------------------------------------------------------------
//
// The server owns one grid of individual slime units plus an off-grid
// reservoir that refills emptied cells from the top row.  Render frames carry
// the whole grid (`game.grid`, row-major, row 0 = top) with its dimensions, so
// every client draws exactly the same field.
//
// Each unit is drawn as its own tile — a gel blob stamped with its element
// glyph — so the field reads as a board of discrete pieces rather than a
// blanket of goo.  A cell's flat index is its identity: the server refills
// holes in place and never slides existing units around, so tiles never move
// between cells.  (No cascade: faking one would make tile identity lie about
// server state.)

/** Grid dimensions from a render frame, floored at 1×1 so geometry is safe
 *  even on a frame that arrives before the grid does. */
function gridDims(game) {
  return {
    rows: Math.max(game?.grid_rows ?? 0, 1),
    cols: Math.max(game?.grid_cols ?? 0, 1),
  };
}

/**
 * Placement of a rows×cols grid inside the slime field: square cells, sized
 * to fit and capped at FIELD.tileMax, then centered — small grids letterbox
 * inside the field rather than stretching to fill it.  Square cells keep the
 * tile art circular at any grid shape and make the sprite cache one
 * dimensional (see tileSprite).
 */
function gridRect(rows, cols) {
  const fieldW = FIELD.x1 - FIELD.x0;
  const fieldH = FIELD.y1 - FIELD.y0;
  const cell = Math.min(fieldW / cols, fieldH / rows, FIELD.tileMax);
  const w = cell * cols;
  const h = cell * rows;
  return {
    x0: FIELD.x0 + (fieldW - w) / 2,
    y0: FIELD.y0 + (fieldH - h) / 2,
    w, h, cell,
  };
}

/** Screen rect of the cell at flat index `flat` (row-major, row 0 = top). */
function cellRect(flat, rows, cols) {
  const g = gridRect(rows, cols);
  const x0 = g.x0 + (flat % cols) * g.cell;
  const y0 = g.y0 + Math.floor(flat / cols) * g.cell;
  return { x0, y0, x1: x0 + g.cell, y1: y0 + g.cell, w: g.cell, h: g.cell };
}

/** Screen center of a cell — the anchor for chomp floaters and Lil Guy walks. */
function cellCenter(flat, rows, cols) {
  const r = cellRect(flat, rows, cols);
  return { x: (r.x0 + r.x1) / 2, y: (r.y0 + r.y1) / 2 };
}

/** Center of the whole field: the fallback anchor for cast-wide floaters. */
function fieldCenter() {
  return { x: (FIELD.x0 + FIELD.x1) / 2, y: (FIELD.y0 + FIELD.y1) / 2 };
}

// --- Slime unit tiles --------------------------------------------------------
//
// A tile is pure function of (cell state, cell size), so each distinct tile is
// rendered ONCE into an offscreen canvas and thereafter blitted.  There are
// only 9 states (4 modified + 4 neutralized + neutral), and a 16×16 grid draws
// 256 cells per frame — drawing gel bodies with live gradients at that rate
// would mean thousands of gradient allocations per second, so the cache is
// what makes the look affordable.  Animation varies only the destination rect.

/** Deterministic PRNG (mulberry32); same seed → same value.  Used to give
 *  every cell a stable idle-wobble phase from its flat index. */
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

/** Tile body colors by element name, plus neutral's grey.  Derived from
 *  ELEMENT_COLOR/NEUTRAL_COLOR (single source of color truth). */
const TILE_RGB = {
  ...Object.fromEntries(ELEMENT_NAMES.map((n) => [n, parseRgb(ELEMENT_COLOR[n])])),
  neutral: parseRgb(NEUTRAL_COLOR),
};

/**
 * Decode a wire cell name into what to draw.
 *   "empty"   → null (no tile; the socket shows through)
 *   "neutral" → grey body, no glyph
 *   "red"     → red body + ♦ glyph            (threat: needs a red agent)
 *   "red_n"   → grey body + red ring          (defused, and by which agent)
 * Neutralized slime is safe to eat, so its BODY is grey like neutral; the ring
 * preserves which color was spent neutralizing it.
 */
function cellStyle(name) {
  if (!name || name === "empty") return null;
  if (name === "neutral") return { body: "neutral", glyph: null, ring: null };
  if (name.endsWith("_n")) {
    const el = name.slice(0, -2);
    return ELEMENT_NAMES.includes(el)
      ? { body: "neutral", glyph: null, ring: el }
      : { body: "neutral", glyph: null, ring: null };
  }
  return ELEMENT_NAMES.includes(name)
    ? { body: name, glyph: ELEMENT_CHAR[name], ring: null }
    : { body: "neutral", glyph: null, ring: null };
}

/** True when the cell name denotes slime a Lil Guy could bite. */
function cellIsSlime(name) {
  return cellStyle(name) !== null;
}

/**
 * The element of a cell that is still MODIFIED, or null for anything else
 * (empty, neutral, or already-neutralized `x_n`).
 *
 * This is exactly the set agents can transmute, so it drives both the cohort
 * highlight and the dissolve classification.  Neutralized units keep their
 * element in the name for the ring color, hence the explicit `_n` rejection.
 */
function modifiedElement(name) {
  return ELEMENT_NAMES.includes(name) ? name : null;
}

/** state|size → rendered tile canvas.  Cleared when the cell size changes. */
const tileCache = new Map();
let tileCacheSize = -1;

/** Trace a rounded rect onto `c` (no fill/stroke). */
function roundRectPath(c, x, y, w, h, r) {
  const rr = Math.min(r, w / 2, h / 2);
  c.beginPath();
  c.moveTo(x + rr, y);
  c.lineTo(x + w - rr, y);
  c.quadraticCurveTo(x + w, y, x + w, y + rr);
  c.lineTo(x + w, y + h - rr);
  c.quadraticCurveTo(x + w, y + h, x + w - rr, y + h);
  c.lineTo(x + rr, y + h);
  c.quadraticCurveTo(x, y + h, x, y + h - rr);
  c.lineTo(x, y + rr);
  c.quadraticCurveTo(x, y, x + rr, y);
  c.closePath();
}

/**
 * Render (and cache) the tile for one cell state at one cell size.
 * The blob is inset by FIELD.tileGap per side, giving the large gutter that
 * makes units read as separate pieces.  Returns a canvas the size of a cell,
 * so callers blit it at the cell rect (scaled/offset for animation).
 */
function tileSprite(name, size) {
  if (size !== tileCacheSize) {
    tileCache.clear();
    tileCacheSize = size;
  }
  const key = `${name}|${size}`;
  const hit = tileCache.get(key);
  if (hit) return hit;

  const style = cellStyle(name);
  if (!style) return null;

  const cv = document.createElement("canvas");
  cv.width = size;
  cv.height = size;
  const c = cv.getContext("2d");

  const inset = size * FIELD.tileGap;
  const bw = size - inset * 2;
  const radius = bw * FIELD.tileRadius;
  const [r, g, b] = TILE_RGB[style.body];

  // Body: vertical gradient (lit top, shaded bottom) reads as a gel volume.
  const grad = c.createLinearGradient(0, inset, 0, inset + bw);
  grad.addColorStop(0, `rgba(${Math.min(255, r + 45)},${Math.min(255, g + 45)},${Math.min(255, b + 45)},1)`);
  grad.addColorStop(0.55, `rgba(${r},${g},${b},1)`);
  grad.addColorStop(1, `rgba(${Math.round(r * 0.62)},${Math.round(g * 0.62)},${Math.round(b * 0.62)},1)`);
  roundRectPath(c, inset, inset, bw, bw, radius);
  c.fillStyle = grad;
  c.fill();

  // Rim: darker outline so adjacent tiles stay separate even at small sizes.
  c.strokeStyle = `rgba(${Math.round(r * 0.35)},${Math.round(g * 0.35)},${Math.round(b * 0.35)},0.95)`;
  c.lineWidth = Math.max(1, size * 0.035);
  c.stroke();

  // Specular highlight, upper-left: the "candy" cue.
  c.save();
  roundRectPath(c, inset, inset, bw, bw, radius);
  c.clip();
  c.fillStyle = "rgba(255,255,255,0.34)";
  c.beginPath();
  c.ellipse(inset + bw * 0.34, inset + bw * 0.26, bw * 0.24, bw * 0.15,
    -Math.PI / 5, 0, Math.PI * 2);
  c.fill();
  c.restore();

  // Ring: which agent color neutralized this unit.
  if (style.ring) {
    const [rr_, rg, rb] = TILE_RGB[style.ring];
    c.strokeStyle = `rgba(${rr_},${rg},${rb},0.85)`;
    c.lineWidth = Math.max(1.5, size * 0.055);
    roundRectPath(c, inset + bw * 0.16, inset + bw * 0.16, bw * 0.68, bw * 0.68,
      radius * 0.68);
    c.stroke();
  }

  // Element glyph: colorblind parity with the action menu and combo panel.
  if (style.glyph) {
    c.fillStyle = `rgba(20,16,32,${FIELD.symbolAlpha})`;
    c.font = `bold ${Math.round(bw * 0.5)}px monospace`;
    c.textAlign = "center";
    c.textBaseline = "middle";
    c.fillText(style.glyph, size / 2, size / 2 + bw * 0.02);
  }

  tileCache.set(key, cv);
  return cv;
}

// --- Per-cell animation ------------------------------------------------------
//
// The server sends the whole grid every tick, so the client classifies changes
// by diffing against the previous frame.  Diffing is idempotent: an unchanged
// grid queues nothing, which matters because frames arrive at ~20Hz while we
// render at 60.
//
// Eats are the exception — they are NOT diffed.  The server refills in the same
// tick it bites, so a bitten cell goes straight from one color to another with
// no empty frame in between.  The Lil Guy bite-timer wrap already identifies
// the exact cell (see tickLilGuys), and that is what drives the pop.

/** Previous frame's cell names, for change classification. */
let prevGrid = [];

/** flat → { kind: "drop"|"pop"|"flash", t } with `t` counting down in seconds.
 *  A "pop" also carries `from`: the tile that was eaten, bursting outward
 *  while its replacement drops in behind it. */
const cellAnim = new Map();

/** Cells the Lil Guys resolved a bite on this frame (set by tickLilGuys). */
const bittenThisFrame = new Set();

/** Colors that dispensed agents this frame, from `game.agents_dispensed`.
 *  A cell of one of these colors that changed was transmuted by a cast, so it
 *  DISSOLVES rather than dropping — half of every transmutation is destroyed
 *  outright (balance.neutralize_residue_mult) and refilled in the same tick,
 *  which would otherwise render as "new slime arrived" instead of "your agent
 *  vaporized this". */
const dispensedColorsThisFrame = new Set();

/** flat → idle wobble phase.  Derived from the flat index so a cell always
 *  breathes on the same beat, and memoised because the draw loop would
 *  otherwise build a fresh PRNG closure per cell per frame. */
const bobPhases = [];
function bobPhase(flat) {
  let p = bobPhases[flat];
  if (p === undefined) {
    p = mulberry32(flat + 1)() * Math.PI * 2;
    bobPhases[flat] = p;
  }
  return p;
}

/**
 * Diff `grid` against the previous frame and queue an animation per changed
 * cell.  Must run AFTER tickLilGuys so `bittenThisFrame` is populated.
 */
function updateGridAnims(grid) {
  for (let flat = 0; flat < grid.length; flat++) {
    const now = grid[flat];
    const was = prevGrid[flat];
    if (was === undefined) continue; // first frame: no animation, just adopt
    if (now === was) continue;

    if (cellIsSlime(was) && now === `${was}_n`) {
      // A cast neutralized this unit in place: it survived, so it stays put.
      cellAnim.set(flat, { kind: "flash", t: FIELD.flashS });
    } else if (bittenThisFrame.has(flat)) {
      // A Lil Guy ate it; whatever is here now arrived from the reservoir.
      cellAnim.set(flat, { kind: "pop", t: FIELD.popS, from: was });
    } else if (dispensedColorsThisFrame.has(modifiedElement(was))) {
      // Agents of this color fired this frame and this unit is gone: it was
      // destroyed by the transmutation, not eaten and not merely replaced.
      cellAnim.set(flat, { kind: "dissolve", t: FIELD.dissolveS, from: was });
    } else {
      // Refilled hole, or any other server-side replacement.
      cellAnim.set(flat, { kind: "drop", t: FIELD.dropS });
    }
  }
  prevGrid = grid.slice();
  bittenThisFrame.clear();
  dispensedColorsThisFrame.clear();
}

/** Advance queued cell animations, dropping the finished ones. */
function tickGridAnims(dt) {
  for (const [flat, a] of cellAnim) {
    a.t -= dt;
    if (a.t <= 0) cellAnim.delete(flat);
  }
}

/**
 * Draw the slime field: recessed sockets, one gel tile per slime unit, and the
 * reservoir readout — units still queued off-grid, which refill emptied cells
 * from the top row.
 */
function drawSlimeField(game) {
  const { rows, cols } = gridDims(game);
  const grid = game.grid ?? [];
  const g = gridRect(rows, cols);
  const t = performance.now() / 1000;

  rect(FIELD.x0, FIELD.y0, FIELD.x1 - FIELD.x0, FIELD.y1 - FIELD.y0,
    "rgba(255,255,255,0.03)");

  // Cells a live or pending cast would transmute.  Computed once per frame,
  // and only while something is actually projected.
  const marks = cohortHighlight(game);
  const pulse = marks.size > 0
    ? FIELD.cohortAlphaMin + (FIELD.cohortAlphaMax - FIELD.cohortAlphaMin) *
      (0.5 + 0.5 * Math.sin(t * Math.PI * 2 * FIELD.cohortPulseHz))
    : 0;

  // Walk the grid off `g` directly: cellRect would recompute the same
  // placement (and allocate a rect) for every one of up to 256 cells.
  const inset = g.cell * FIELD.tileGap;
  const body = g.cell - inset * 2;
  const cellCount = rows * cols;
  for (let flat = 0; flat < cellCount; flat++) {
    const x0 = g.x0 + (flat % cols) * g.cell;
    const y0 = g.y0 + Math.floor(flat / cols) * g.cell;

    // Socket: every cell gets one, so holes are visibly waiting to be filled.
    rect(x0 + inset, y0 + inset, body, body, FIELD.socketFill);
    rectStroke(x0 + inset, y0 + inset, body, body, 1, FIELD.socketBorder);

    const anim = cellAnim.get(flat);

    // A popping tile bursts outward over its socket; its replacement (below)
    // drops in behind it.
    if (anim?.kind === "pop") {
      const p = 1 - anim.t / FIELD.popS;      // 0 → 1
      drawTile(anim.from, x0, y0, g.cell, 1 + p * 0.3, 0, 1 - p);
    }

    // A dissolving tile collapses INWARD as it fades — the opposite of a
    // pop's outward burst — reading as "vaporized in place" rather than
    // "bitten off".  Its replacement (below) drops in behind it.
    if (anim?.kind === "dissolve") {
      const p = 1 - anim.t / FIELD.dissolveS; // 0 → 1
      drawTile(anim.from, x0, y0, g.cell, 1 - p * 0.55, 0, 1 - p);
    }

    const name = grid[flat];
    if (!cellIsSlime(name)) continue;

    let scale = 1;
    let dy = 0;
    if (anim?.kind === "drop" || anim?.kind === "pop" || anim?.kind === "dissolve") {
      // Slide in from the cell above, easing out, with a landing squash.
      const dur = anim.kind === "drop" ? FIELD.dropS
        : anim.kind === "pop" ? FIELD.popS
          : FIELD.dissolveS;
      const p = 1 - anim.t / dur;
      const ease = 1 - (1 - p) * (1 - p);
      dy = -(1 - ease) * g.cell;
      scale = 1 + Math.sin(p * Math.PI) * 0.08;
    } else {
      // Idle: every cell breathes on its own stable phase.
      scale = 1 + Math.sin(t * FIELD.bobFreq + bobPhase(flat)) * FIELD.bobAmp;
    }

    drawTile(name, x0, y0, g.cell, scale, dy, 1);

    // Cohort outline: pulsing, in the projected color, at the socket edge —
    // outside the tile body, so it is never confused with the static inner
    // ring that marks an already-neutralized unit.
    const mark = marks.get(flat);
    if (mark !== undefined) {
      ctx.save();
      ctx.globalAlpha = pulse;
      rectStroke(x0 + inset, y0 + inset, body, body, FIELD.cohortWidth,
        ELEMENT_COLOR[mark]);
      ctx.restore();
    }

    // Neutralize flash: a white bloom over the settled tile.
    if (anim?.kind === "flash") {
      const p = 1 - anim.t / FIELD.flashS;
      ctx.save();
      ctx.globalAlpha = (1 - p) * 0.8;
      rect(x0 + inset, y0 + inset, body, body, "rgba(255,255,255,1)");
      ctx.restore();
    }
  }

  rectStroke(FIELD.x0, FIELD.y0, FIELD.x1 - FIELD.x0, FIELD.y1 - FIELD.y0, 1,
    FIELD.border);

  // Reservoir: off-grid slime waiting to drop into the top row.
  const reservoir = game.reservoir ?? 0;
  const label = reservoir > 0
    ? `${reservoir} more slime incoming ↓`
    : "reservoir empty — last of the slime";
  text(label, FIELD.x0, FIELD.y1 + FIELD.labelDy, FIELD.reservoirFont,
    reservoir > 0 ? "rgba(170,180,220,0.8)" : "rgba(255,255,140,0.9)");
}

/**
 * Blit one cached tile into the cell at (x0, y0), scaled about the cell centre
 * and offset vertically by `dy` (animation).  `alpha` < 1 fades it out.
 */
function drawTile(name, x0, y0, cell, scale, dy, alpha) {
  const sprite = tileSprite(name, Math.round(cell));
  if (!sprite) return;
  const size = cell * scale;
  const off = (cell - size) / 2;
  if (alpha < 1) {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.drawImage(sprite, x0 + off, y0 + off + dy, size, size);
    ctx.restore();
  } else {
    ctx.drawImage(sprite, x0 + off, y0 + off + dy, size, size);
  }
}

// ---------------------------------------------------------------------------
// Lil Guys (server-driven: each walks to the grid cell the server reserved)
// ---------------------------------------------------------------------------
//
// The server spawns one Lil Guy ECS entity per connected player, reserves a
// random grid cell for it, and counts down a bite timer.  Frames carry that
// state as `game.lil_guys[] = { id, target, bite_ms }` — `id` is the server
// entity id, and `target` is a flat grid index (null when the grid is empty and
// no cell could be reserved).
//
// The client is purely presentational: it interpolates each guy toward its
// reserved cell and plays the `attack` clip when the server's timer says the
// bite lands.  Because the reservation is not exclusive, two guys may share a
// cell and one will miss — that is the server's outcome, and the client shows
// it faithfully by animating the chomp either way.

/**
 * @typedef {object} LilGuyView
 * @property {number} x        - current screen x (top-left of the sprite)
 * @property {number} y        - current screen y
 * @property {number|null} target - flat grid index it is walking to
 * @property {number} lastBiteMs  - previous frame's server bite timer, used
 *   to detect the wrap that means "the bite just landed"
 * @property {boolean} facingLeft - sprite mirror, set from the walk direction
 * @property {string|null} pendingClip - one-shot clip for the next draw
 *   ("attack" on the frame a bite resolves), consumed by drawLilGuys
 * @property {number} id      - animator id (offset far above entity ids)
 */

/** Server entity id → its view state.  Keyed so late joins / disconnects map
 *  to the right sprite instead of shifting everyone by one. */
const lilGuys = new Map();

/** Animator ids live far above entity ids so they cannot collide. */
const LIL_GUY_ANIM_BASE = 1_000_000;

/** Screen position of the most recent chomp — the anchor for score/hunger
 *  floaters (see updateFeastTracking).  null until the first bite lands. */
let lastBitePos = null;

/**
 * Sync the Lil Guy views with the server's horde and advance them one frame.
 * Spawns/removes views to match `game.lil_guys`, walks each toward its
 * reserved cell, and fires the chomp (attack clip + floater) on the frame the
 * server's bite timer wraps.
 */
function tickLilGuys(game, dt) {
  const G = LAYOUT.lilGuys;
  const { rows, cols } = gridDims(game);
  const horde = game.lil_guys ?? [];

  // Drop views whose server entity is gone (player disconnected).
  const live = new Set(horde.map((lg) => lg.id));
  for (const id of lilGuys.keys()) {
    if (!live.has(id)) lilGuys.delete(id);
  }

  for (const lg of horde) {
    const target = lg.target ?? null;
    let g = lilGuys.get(lg.id);
    if (!g) {
      // Spawn already standing on its cell: a new guy should not sprint in
      // from a stale corner of the field.
      const at = target !== null
        ? cellCenter(target, rows, cols)
        : fieldCenter();
      g = {
        x: at.x - G.size / 2,
        y: at.y - G.size / 2,
        target,
        lastBiteMs: lg.bite_ms ?? 0,
        facingLeft: false,
        pendingClip: null,
        id: LIL_GUY_ANIM_BASE + lg.id,
      };
      lilGuys.set(lg.id, g);
    }

    // A rising bite timer means the server restarted the countdown, i.e. the
    // previous bite resolved (landed or missed) — chomp on the cell we were
    // standing on, then walk to the freshly reserved one.
    const biteMs = lg.bite_ms ?? 0;
    if (biteMs > g.lastBiteMs) {
      const at = g.target !== null
        ? cellCenter(g.target, rows, cols)
        : { x: g.x + G.size / 2, y: g.y + G.size / 2 };
      lastBitePos = at;
      // Tell the tile layer which cell was eaten: the server refills in the
      // same tick it bites, so this is the only signal that distinguishes an
      // eat from a plain refill (see updateGridAnims).
      if (g.target !== null) bittenThisFrame.add(g.target);
      // Hand the attack clip to the animator on this frame's draw.
      g.pendingClip = "attack";
      spawnFloater("chomp", at.x, at.y - LAYOUT.floater.stack,
        "rgba(230,230,240,0.85)", 0.8); // cosmetic: exempt from 3s rule
    }
    g.lastBiteMs = biteMs;
    g.target = target;

    // Walk toward the reserved cell (no target → hold position).
    if (target === null) continue;
    const at = cellCenter(target, rows, cols);
    const tx = at.x - G.size / 2;
    const ty = at.y - G.size / 2;
    const dx = tx - g.x, dy = ty - g.y;
    const dist = Math.hypot(dx, dy);
    if (dist <= G.snap) {
      g.x = tx;
      g.y = ty;
      continue;
    }
    const step = Math.min(G.speed * dt, dist);
    g.x += (dx / dist) * step;
    g.y += (dy / dist) * step;
    g.facingLeft = dx < 0;
  }
}

function drawLilGuys(dt) {
  const G = LAYOUT.lilGuys;
  for (const g of lilGuys.values()) {
    drawSprite(g.id, LIL_GUY_SPRITE, g.x, g.y, G.size, G.size, g.pendingClip,
      dt, g.facingLeft);
    g.pendingClip = null; // one-shot: the animator owns the clip from here
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

  // Every cast fires at the end of its OWN buffer (entity.cast_ms); casts
  // completing a team recipe merge and fire together.  The bar tracks the
  // local player's pending cast, and the cooldown after it fires.
  {
    const bufferS = (game.cast_buffer_ms ?? 0) / 1000;
    const own = (game.entities ?? []).find(e => e.owner === game.player_id);
    const ownCastS = own ? (own.cast_ms ?? 0) / 1000 : 0;
    const lockS = own ? (own.lock_ms ?? 0) / 1000 : 0;

    const castFrac = ownCastS > 0 && bufferS > 0
      ? Math.max(0, Math.min(1, ownCastS / bufferS))
      : 0;
    rect(px, my + M.castBarDy, tbw, M.castBarH, "rgba(30,30,30,0.8)");
    if (ownCastS > 0) {
      rect(px, my + M.castBarDy, tbw * castFrac, M.castBarH, "rgba(120,220,255,0.9)");
    }
    rectStroke(px, my + M.castBarDy, tbw, M.castBarH, 1, "rgba(255,255,255,0.3)");

    let status = "Build a combo, then ENTER to cast";
    if (ownCastS > 0) status = `Dispensing: ${ownCastS.toFixed(1)}s`;
    else if (lockS > 0) status = `Cooldown: ${lockS.toFixed(1)}s`;
    text(status, px, my + M.timerTextDy, M.timerTextFont, C_TEXT);
  }

  // Project from committed combos in preference to typed ones, so the preview
  // survives the cast buffer instead of blanking the instant you press ENTER.
  const projected = matchRecipes(projectedCombos(game));

  // Per-color reach: `n of cohort`, plus the surplus that will be wasted.
  // A projected color with NO cohort on the grid is the worst case — every
  // agent is thrown away — so it is called out in red rather than hidden.
  const risk = new Map(cohortRisk(game).map(r => [r.color, r]));
  const parts = [];
  for (const name of ELEMENT_NAMES) {
    const n = projected.units[name];
    if (!n) continue;
    const r = risk.get(name);
    if (!r) {
      parts.push({ str: `${ELEMENT_CHAR[name]}${n}`, color: ELEMENT_COLOR[name] });
      continue;
    }
    parts.push({
      str: `${ELEMENT_CHAR[name]}${n} → ${r.hit} of ${r.cohort}`,
      color: r.cohort === 0 ? C_BAD : ELEMENT_COLOR[name],
    });
    if (r.wasted > 0) {
      parts.push({ str: `${r.wasted} wasted`, color: C_BAD });
    }
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

/** The `game` object whose transient events have already been consumed.
 *  Identity, not tick number: each server message is parsed into a fresh
 *  object, so identity is exact and needs no monotonicity assumption. */
let lastTransientGame = null;

function drawGame(game, dt) {
  // The render loop redraws `latestMsg` every animation frame (~60Hz) while
  // server frames arrive at ~20Hz, so the same frame is drawn ~3 times.
  // Transient events (dispense outcomes, recipe fires, casts, fizzles) are
  // per-frame facts, NOT per-draw, and must be consumed exactly once or they
  // spawn triplicate floaters.
  const fresh = game !== lastTransientGame;
  lastTransientGame = game;

  tickFloaters(dt);
  // Order matters: tickLilGuys resolves this frame's bite (setting lastBitePos)
  // and updateFeastTracking floats the score/hunger deltas over that cell.
  tickLilGuys(game, dt);
  // Dispense outcomes must be read BEFORE the grid diff: they tell
  // updateGridAnims which colors fired, which is how a cell destroyed by a
  // transmutation is told apart from one that was merely refilled.
  if (fresh) spawnDispenseFloaters(game);
  // Then classify grid changes: updateGridAnims needs both the bite
  // tickLilGuys just resolved and the dispense colors above to tell an eaten
  // cell, a vaporized cell and a plain refill apart.
  tickGridAnims(dt);
  if (fresh) updateGridAnims(game.grid ?? []);
  updateFeastTracking(game);
  if (fresh) {
    spawnCastFloaters(game);
    spawnRecipeFloaters(game);
    spawnCastEventFloaters(game);
  }

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
 * End-of-game tuning report: outcome, match-wide feast tallies, per-player
 * table, recipe fire counts, derived waste/overheal totals.
 *
 * The grid model has no rounds, so the report is a single match-wide summary:
 * what was dispensed vs. what it actually neutralized (the rest was wasted on
 * off-grid or wrong-color slime), and what the Lil Guys ended up eating.
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

  // ---- Match-wide feast tallies -------------------------------------------
  const F = L.fcols;
  const feast = stats.feast ?? {};
  let y = L.feastY;
  text("FEAST", F.label, y, L.sectionFont, C_HEADER);
  y += L.rowH;

  /** One "LABEL  ♦12 ▲5" row. */
  const feastRow = (label, obj) => {
    text(label, F.label, y, L.rowFont, "rgba(200,200,210,0.9)");
    drawColorCells(F.cells, y, L.rowFont, obj);
    y += L.rowH;
  };
  feastRow("agents dispensed", feast.agents);
  feastRow("slime neutralized", feast.neutralized);
  feastRow("modified slime eaten", feast.escaped);
  feastRow("medicine dispensed", feast.medicine);
  feastRow("hunger healed", feast.healed);

  // Derived: agents that found no matching on-grid cell, and medicine poured
  // into hunger that was not there.  Both are the numbers a designer tunes on.
  const wasted = sumColors(feast.agents) - sumColors(feast.neutralized);
  const overheal = sumColors(feast.medicine) - sumColors(feast.healed);
  y += 4;
  text(
    `neutral eaten ${feast.neutral ?? 0}  ·  hunger ${feast.hunger_normal ?? 0} base ` +
    `+ ${feast.hunger_extra ?? 0} from modified  ·  agents wasted ${wasted}  ·  medicine overheal ${overheal}`,
    F.label, y, L.rowFont, "rgba(200,200,210,0.9)",
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
  const eaten = (stats.slime_total ?? 0) - (stats.slime_left ?? 0);
  text(`total spells cast: ${stats.casts_total}  ·  slime eaten: ${eaten}/${stats.slime_total ?? 0}`,
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
    if (e.key === "c" || e.key === "C") {
      // Creating from /config/{hash} keeps that saved config's tables.
      preLobbyError = "";
      sendPreLobbyAction({ action: "create", config: PAGE_CONFIG_HASH ?? undefined });
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
