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
    symbolAlpha: 0.55,  // tier glyph opacity stamped on the body
    // Per-cell animation durations (seconds) and idle wobble.
    dropS: 0.15,        // refill slide-in from above
    popS: 0.22,         // eaten-tile burst
    flashS: 0.25,       // downgraded-tile white bloom
    bobAmp: 0.02,       // idle breathing: ±fraction of tile size
    bobFreq: 1.6,       // idle breathing rate (rad/s)

    // --- Aim cursor + projected shape footprint (see shapePreview) --------
    //
    // Both are drawn at the SOCKET edge, outside the tile body, so neither can
    // be read as part of a tile's own art.
    cursorWidth: 3,       // the local player's cursor: thick, unmissable
    cursorMateWidth: 2,   // teammates' cursors: present but subordinate
    cursorCornerFrac: 0.3, // crosshair arm length, as a fraction of the cell
    previewWidth: 3.5,    // projected-footprint outline stroke width
    previewPulseHz: 2.4,  // pulse rate
    previewAlphaMin: 0.35,// pulse trough
    previewAlphaMax: 0.95,// pulse crest
    // Under-socket tint on a covered cell, and the wash laid OVER its tile.
    // Both are drawn in the color the cell will BECOME, so a committed cast
    // reads as an outcome rather than as a generic highlight.
    previewFillAlpha: 0.16,
    previewWashAlpha: 0.3, // scaled by the pulse, so the wash breathes too

    // --- Candidate ghosts (see candidateShapes) ---------------------------
    //
    // Deliberately quieter than the committed preview and drawn UNDER it:
    // ghosts are "this is where it would land IF you keep typing", and must
    // never be mistaken for the cast that is actually about to fire.  Neutral
    // (not outcome-colored) for the same reason.
    ghostWidth: 1,
    ghostAlpha: 0.22,      // per covering candidate — overlap is ADDITIVE, so
    ghostAlphaCap: 0.66,   // cells several candidates share read strongest
    ghostFillAlpha: 0.05,  // ditto, also scaled by the overlap count
  },

  hungerBar: {
    x0: 40, x1: 984, y: 150, h: 18,
    labelFont: 14, labelDy: -8,
    bg: "rgba(30,10,10,0.78)",
    // Grey, matching neutral/defused slime: this portion is not healable,
    // and tier colors are reserved for the healable segments.
    fill: "rgba(150,150,162,0.9)",
    dangerBorder: "rgba(255,60,60,0.95)",
    textFont: 13,
  },

  score: { x: 40, y: 90, font: 20 },

  headers: { waveX: 40, waveY: 50, waveFont: 20, labelDy: -30, labelFont: 18 },

  // Per-player pending-combo rows, bottom-left beside the action menu.
  comboPanel: { x: 24, y0: 652, rowH: 18, font: 13, slotW: 14, nameW: 42 },

  // Lil Guys: one per connected player, purely cosmetic — they mill about the
  // field and pounce at the turn-end feast (see tickLilGuys).  `speed` is px/s;
  // `snap` is how close counts as arrived.
  lilGuys: { size: 48, speed: 220, snap: 3 },

  actionMenu: {
    w: 340, h: 126, marginBottom: 128,
    padX: 10, padTopY: 14,
    actionRowDy: 16, actionFont: 16, actionCols: [0, 150],
    aimRowDy: 34, aimFont: 13,
    cancelRowDy: 48, cancelFont: 12,
    castBarDy: 56, castBarH: 16,
    timerTextDy: 86, timerTextFont: 13,
    previewDy: 102, previewFont: 13,
    candidateDy: 120, candidateFont: 12,
    // Cap the candidate hint: the panel is a fixed width, and a config may
    // author far more recipes than share a prefix legibly.  Overflow is
    // summarised as "+N more" rather than clipped.
    candidateMax: 3,
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
    pcols: { name: 40, casts: 190, covered: 250, defused: 420, recipes: 590, fizzles: 760 },
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
/** Warning red: a stamp aimed off the grid or at cells with nothing to hit. */
const C_BAD = "rgba(255,110,110,1)";
/** Muted tint for the wasted tail of a stamp floater — present but not
 *  competing with the count that actually accomplished something. */
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

/**
 * Combo slot from its data-file name.  Combos are ACTION KEYS ONLY — a recipe
 * is identified by the sequence of keys pressed, and what it does is carried by
 * its shape, not by any color token in the pattern.
 */
function slotFromName(name) {
  return { action: name };
}

/**
 * Parse an authored shape (rows of "#" / ".") into anchor-relative offsets.
 * MIRRORS config.shape_from_rows: the anchor is the bounding box centre
 * (`len / 2`, floored), so offsets reach up and left of it.  Both sides derive
 * offsets from the same data file with the same rule, so a preview covers
 * exactly the cells the server will stamp.
 *
 * @param {string[]} rows
 * @returns {Array<{dRow: number, dCol: number}>}
 */
function shapeOffsets(rows) {
  const anchorR = Math.floor(rows.length / 2);
  const anchorC = Math.floor((rows[0]?.length ?? 0) / 2);
  const offsets = [];
  rows.forEach((line, r) => {
    for (let cl = 0; cl < line.length; cl++) {
      if (line[cl] !== "#") continue;
      offsets.push({ dRow: r - anchorR, dCol: cl - anchorC });
    }
  });
  return offsets;
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
  CASTS_PER_TURN = bal.casts_per_turn ?? 3;
  PLAYER_RECIPES = bal.player_recipes.map((r) => ({
    label: r.label,
    pattern: r.pattern.map(slotFromName),
    rows: r.shape,
    offsets: shapeOffsets(r.shape),
    medicine: r.medicine ?? {},
  }));
  TEAM_RECIPES = bal.team_recipes.map((r) => ({
    label: r.label,
    patterns: r.patterns.map((p) => p.map(slotFromName)),
    rows: r.shape,
    offsets: shapeOffsets(r.shape),
    medicine: r.medicine ?? {},
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
  feastThisFrame = false;
  stampedThisFrame.clear();
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

/** Key binding per action — mirrors src/client/input.zig. */
const ACTION_KEY = { dispense: "1", medicine: "2" };

/** Render one combo slot as key+symbol (e.g. "1d") in its action color. */
function slotKeySymbol(slot) {
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

/** Colored parts for a recipe's medicine output (per healable tier). */
function medicineParts(medicine) {
  const parts = [];
  for (const name of TIER_NAMES) {
    const n = medicine?.[name];
    if (n) parts.push({ str: `med${TIER_CHAR[name]}${n}`, color: TIER_COLOR[name] });
  }
  return parts;
}

/**
 * Draw a recipe's shape as a small glyph grid ("###" / ".#."), with the anchor
 * cell marked — that is the cell you aim at, and every other cell is placed
 * relative to it.
 *
 * @returns {number} x after the drawn glyph.
 */
function drawShapeGlyph(x, y, font, rows) {
  const G = LAYOUT.lobby;
  const anchorR = Math.floor(rows.length / 2);
  const anchorC = Math.floor((rows[0]?.length ?? 0) / 2);
  ctx.font = `${font}px monospace`;
  const cw = ctx.measureText("#").width;
  const ch = font * 0.82;
  // Top-align the block on the row baseline so tall shapes grow downward and
  // never collide with the row above.
  const y0 = y - ch * anchorR;
  rows.forEach((line, r) => {
    for (let cl = 0; cl < line.length; cl++) {
      const on = line[cl] === "#";
      const isAnchor = r === anchorR && cl === anchorC;
      const glyph = on ? (isAnchor ? "◉" : "■") : "·";
      const color = on
        ? (isAnchor ? C_OWN_ROW : SHAPE_COLOR)
        : "rgba(110,110,130,0.5)";
      text(glyph, x + cl * cw, y0 + r * ch, font, color);
    }
  });
  return x + (rows[0]?.length ?? 0) * cw;
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
  // The turn loop: a fixed budget of casts each, then the whole field is eaten.
  const castingLine = [
    { str: `Press ENTER to cast — ${CASTS_PER_TURN} casts each per turn.`, color: descColor },
    { str: "A team recipe needs BOTH halves — the first one waits until a partner casts theirs!", color: RECIPE_COLOR_TEAM },
  ];
  const descLines = [
    [
      { str: "AIM with the arrow keys, then type a combo:", color: descColor },
      { str: "1d dispense", color: ACTION_COLOR.dispense },
      { str: "2m medicine", color: ACTION_COLOR.medicine },
    ],
    [
      { str: "Each combo below stamps its SHAPE on the grid, centred on your cursor.", color: descColor },
    ],
    [
      { str: "Every covered cell steps down one tier:", color: descColor },
      { str: `${TIER_CHAR.red}red`, color: TIER_COLOR.red },
      { str: "→", color: descColor },
      { str: `${TIER_CHAR.yellow}yellow`, color: TIER_COLOR.yellow },
      { str: "→", color: descColor },
      { str: `${TIER_CHAR.green}green`, color: TIER_COLOR.green },
      { str: "→ defused (harmless to eat).", color: descColor },
    ],
    [
      { str: "Aim is captured when you press ENTER — re-aiming will not move a cast already made.", color: descColor },
    ],
    [
      { str: "The turn ends once EVERYONE is out of casts: the Lil Guys then devour the whole field.", color: descColor },
    ],
    [
      { str: "Live hazard slime is what hurts to eat — defuse it first, and a fresh field arrives.", color: descColor },
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

  const drawRecipeRow = (r, labelColor, patterns, suffix) => {
    text(r.label, L.guideX, y, L.recipeFont, labelColor);
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
    x = drawShapeGlyph(x, y, L.recipeFont, r.rows ?? ["#"]) + L.recipeSlotGap;
    x = drawParts(x, y, L.recipeFont, medicineParts(r.medicine), L.recipeSlotGap);
    if (suffix) text(suffix, x + 4, y, L.guideFont, RECIPE_COLOR_TEAM);
    // Tall shapes render below the baseline, so advance past the whole block.
    const shapeH = (r.rows?.length ?? 1) * L.recipeFont * 0.82;
    y += Math.max(L.recipeRowH, shapeH + 4);
  };

  for (const r of PLAYER_RECIPES) {
    drawRecipeRow(r, RECIPE_COLOR_PLAYER, [r.pattern], null);
  }
  for (const r of TEAM_RECIPES) {
    drawRecipeRow(r, RECIPE_COLOR_TEAM, r.patterns, `(team ×${r.patterns.length})`);
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
  // A combo that matched nothing, or a team half nobody completed: show the
  // fizzle on the caster's row (grey — nothing happened).
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
 * Big celebratory floaters when recipes fire (the server broadcasts one event
 * per fire, as the cast resolves).  Labels are resolved by table index into
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
 * Stamp-outcome floaters (`game.shape_casts`, transient): what each landed
 * shape actually accomplished, floated over the cells it covered.
 *
 * Also records every covered cell, so updateGridAnims can tell a cell a stamp
 * DOWNGRADED from one that was merely refilled.  That set is consumed and
 * cleared by updateGridAnims on the same frame.
 */
function spawnStampFloaters(game) {
  const events = game.shape_casts ?? [];
  if (events.length === 0) return;

  const { rows, cols } = gridDims(game);
  const STACK = LAYOUT.floater.stack;

  events.forEach((ev, i) => {
    for (const flat of ev.cells ?? []) stampedThisFrame.add(flat);

    // Anchor the readout on the footprint itself — the whole point of aiming
    // is that the outcome is local, so a field-centre label would hide it.
    const at = (ev.cells ?? []).length > 0
      ? cellCenter(ev.cells[0], rows, cols)
      : fieldCenter();
    const y = at.y + i * STACK;

    const hits = sumTiers(ev.downgraded);
    const head = hits > 0
      ? `${hits} downgraded${ev.neutralized > 0 ? `, ${ev.neutralized} defused` : ""}`
      : "no effect";
    spawnFloater(head, at.x, y, hits > 0 ? C_SLIME_HDR : C_BAD,
      LAYOUT.floater.lifetime, LAYOUT.floater.font);

    // Nothing is destroyed by a stamp, so the only waste is coverage thrown
    // away: cells clipped off the grid edge, or in-bounds cells with nothing
    // left to downgrade.  Both are aiming feedback.
    const wasted = (ev.off_grid ?? 0) + (ev.inert ?? 0);
    if (wasted > 0) {
      spawnFloater(`(${wasted} wasted)`, at.x, y + STACK * 0.7,
        C_MUTED, LAYOUT.floater.lifetime, LAYOUT.floater.font);
    }
  });
}

/** Turn-loop floater color (matches the cast-budget gauge). */
const CAST_EVENT_COLOR = "rgba(120,220,255,1)";

/**
 * Turn-end floaters (`game.turn_ended`, transient): the feast, announced.
 *
 * The per-cell score/hunger deltas are floated separately by
 * updateFeastTracking; this is the headline — how much was eaten, and how much
 * of the hunger it cost is still healable with medicine.
 */
function spawnTurnEndedFloaters(game) {
  const te = game.turn_ended;
  if (!te) return;

  const { x, y } = fieldCenter();
  const STACK = LAYOUT.floater.stack + 8;
  spawnFloater(`FEAST! ${te.cells_eaten ?? 0} units devoured`, x, y - STACK,
    CAST_EVENT_COLOR, LAYOUT.floater.lifetime, LAYOUT.floater.recipeFont);

  // Healable hunger is the actionable part: it is what medicine can still undo.
  const healable = sumTiers(te.healable);
  if (healable > 0) {
    spawnFloater(`${healable} hunger still healable`, x, y + 28,
      C_BAD, LAYOUT.floater.lifetime, LAYOUT.floater.font);
  }
}

/**
 * Compact per-player pending-combo rows (bottom-left UI panel).  No player
 * sprites are rendered — combos are the only per-player element on screen.
 * The local player's row is highlighted, and every row shows how many casts
 * that player has left this turn: the turn cannot end until they are all spent,
 * so a row with casts left is a row the team is waiting on.
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
      } else {
        text("·", slotX, y, CP.font, "rgba(120,120,140,0.5)");
      }
    }

    // Casts left this turn: a filled pip per remaining cast, so "who are we
    // waiting on" is readable at a glance.
    const usedX = CP.x + CP.nameW + 5 * CP.slotW + 8;
    const left = e.casts_left ?? 0;
    if (left > 0) {
      text("◆".repeat(left), usedX, y, CP.font, CAST_EVENT_COLOR);
    } else {
      text("done", usedX, y, CP.font, "rgba(120,120,140,0.7)");
    }
    // A held team half is aimed at its captured ANCHOR, so the row shows where
    // a completed shape will actually land rather than where the player has
    // since wandered.
    text(`@${e.cursor_row ?? 0},${e.cursor_col ?? 0}`, usedX + 44, y, CP.font,
      own ? C_OWN_ROW : "rgba(180,200,255,0.6)");
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

// Recipe tables are loaded from data/balance.json (loadBalanceData) — the same
// file the Zig server reads, so there is no hand-mirrored copy to drift.  A
// recipe's `medicine` output is per TIER: tier-X medicine heals only the
// tier-X healable bucket (symmetrical healing).
//
// There is NO flat fallback: an unmatched combo fizzles.  These tables are the
// complete move list, both here and on the server.

/** Casts each player gets per turn, from balance.json.  The server announces
 *  the same number in game_start; this copy is what the LOBBY reads, before
 *  any game_start has arrived. */
let CASTS_PER_TURN = 3;
/** @typedef {{dRow: number, dCol: number}} ShapeOffset */
/** @type {Array<{label: string, pattern: Array<object>, rows: string[],
 *   offsets: ShapeOffset[], medicine: Object<string,number>}>} */
let PLAYER_RECIPES = [];
/** @type {Array<{label: string, patterns: Array<Array<object>>, rows: string[],
 *   offsets: ShapeOffset[], medicine: Object<string,number>}>} */
let TEAM_RECIPES = [];

/** Two combos are the same move iff they are the same action-key sequence. */
function slotsEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i].action !== b[i].action) return false;
  }
  return true;
}

/**
 * Accumulate one matched recipe into the projected batch: its shape (as a
 * separate stamp, since each stamp lands at its own anchor) and its medicine.
 *
 * @param {{stamps: Array<object>, medicine: Object<string,number>,
 *   labels: string[]}} sum
 * @param {object} recipe   - the matched recipe (carries offsets + medicine)
 * @param {number} anchorIndex - index into `combos` of the player whose cursor
 *   anchors this stamp; -1 when unknown.
 */
function addOutput(sum, recipe, anchorIndex) {
  sum.stamps.push({
    offsets: recipe.offsets ?? [],
    label: recipe.label,
    anchorIndex,
  });
  for (const [t, n] of Object.entries(recipe.medicine ?? {})) {
    sum.medicine[t] = (sum.medicine[t] ?? 0) + n;
  }
  sum.labels.push(recipe.label);
}

/**
 * Match all players' pending combos into the projected batch of stamps.
 * Mirrors game_logic.match_recipes: team recipes (greedy, repeatable, table
 * order) → player recipes → unmatched combos fizzle.
 *
 * CONTRACT: `combos` holds AT MOST ONE COMBO PER PLAYER (see
 * projectedCombos).  The server additionally requires a team recipe's patterns
 * to be filled by DISTINCT players; under this contract two distinct indices
 * are already two distinct players, so matching distinct indices — as the loop
 * below does via `picked` — enforces that rule.  Passing two combos from one
 * player would silently break parity and over-project team recipes.
 *
 * A team stamp is anchored at the LAST JOINER's cursor (the player whose combo
 * completed the group), falling back to the first contributor.  `lastJoiner`
 * is the server's `session.last_joiner`, which the client cannot observe, so
 * the projection uses the first contributor — the preview may therefore move
 * to the true anchor once the group actually fires.
 *
 * @param {Array<Array<{action?:string}>>} combos
 * @returns {{stamps: Array<{offsets: ShapeOffset[], label: string,
 *   anchorIndex: number}>, medicine: Object<string,number>, labels: string[]}}
 */
function matchRecipes(combos) {
  const sum = { stamps: [], medicine: {}, labels: [] };
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
      addOutput(sum, tr, picks[0] ?? -1);
    }
  }

  for (let ci = 0; ci < combos.length; ci++) {
    if (consumed[ci] || combos[ci].length === 0) continue;
    for (const pr of PLAYER_RECIPES) {
      if (slotsEqual(combos[ci], pr.pattern)) {
        addOutput(sum, pr, ci);
        consumed[ci] = true;
        break;
      }
    }
  }

  return sum;
}

/**
 * The combo to project per player: their HELD team half if they have one,
 * otherwise whatever they are currently typing.
 *
 * The held half wins because it is what will actually fire once a partner
 * completes it — and the two are independent server-side (submitting clears the
 * typing pool, but the player may immediately start a new combo), so a player
 * holding a half who has begun
 * typing again would otherwise flip the preview to a combo that is not the
 * one about to land.
 *
 * ONE COMBO PER OWNER, mirroring the server: casts fire out of a pid-indexed
 * pool, so a player can never contribute two casts to a batch, and team
 * recipes require DISTINCT players.  Deduplicating by owner here keeps that
 * rule true of the projection even if a snapshot ever carried two entities for
 * one player — otherwise a lone player typing half of a team recipe would see
 * it falsely projected as complete.
 *
 * Each entry carries its owner's aim, because a stamp lands at the anchoring
 * player's cursor, not the local player's.
 *
 * @returns {{combos: Array<Array<object>>, aims: Array<{row: number,
 *   col: number}>}}
 */
function projectedCombos(game) {
  const byOwner = new Map();
  for (const e of game.entities ?? []) {
    if (byOwner.has(e.owner)) continue;
    const submitted = e.submitted ?? [];
    byOwner.set(e.owner, {
      combo: submitted.length > 0 ? submitted : (e.combo ?? []),
      aim: { row: e.cursor_row ?? 0, col: e.cursor_col ?? 0 },
    });
  }
  const entries = [...byOwner.values()];
  return {
    combos: entries.map((v) => v.combo),
    aims: entries.map((v) => v.aim),
  };
}

/**
 * Resolve a projected batch into the cells it would cover, with each cell's
 * projected outcome.
 *
 * Placement is EXACT, not a guess: a stamp's footprint is a pure function of
 * (shape offsets, anchor cursor), all of which the client already has, so the
 * preview is exactly the set of cells the server will hit.  Off-grid offsets
 * are clipped away, matching slime.apply_shape.
 *
 * @returns {{cells: Map<number, string>, offGrid: number, inert: number,
 *   hits: number, defused: number}} `cells` maps flat index → the tier name it
 *   will become ("defused" when it bottoms out).
 */
function shapePreview(game) {
  const { rows, cols } = gridDims(game);
  const grid = game.grid ?? [];
  const { combos, aims } = projectedCombos(game);
  const projected = matchRecipes(combos);

  const cells = new Map();
  let offGrid = 0;
  let inert = 0;
  let hits = 0;
  let defused = 0;

  for (const stamp of projected.stamps) {
    const aim = aims[stamp.anchorIndex];
    if (aim === undefined) continue;
    for (const { dRow, dCol } of stamp.offsets) {
      const r = aim.row + dRow;
      const cl = aim.col + dCol;
      if (r < 0 || r >= rows || cl < 0 || cl >= cols) { offGrid++; continue; }
      const flat = r * cols + cl;
      // Chain multiple stamps over the same cell: each one steps it down
      // again, exactly as the server applies them in sequence.
      const current = cells.get(flat) ?? grid[flat];
      const next = downgradeName(current);
      if (next === null) { inert++; continue; }
      cells.set(flat, next);
      hits++;
      if (next === "defused") defused++;
    }
  }
  return { cells, offGrid, inert, hits, defused, projected };
}

/**
 * Resolve the shapes the local player is currently typing TOWARD, so the field
 * projects the intended footprint before the combo is complete.
 *
 * A candidate is any player recipe whose pattern STARTS WITH the typed buffer.
 * That includes recipes longer than an already-exact match (typing `1` both
 * casts `poke` and is en route to `sweep`), so the ghosts answer "what else is
 * still reachable from here" rather than "what is complete".  The exact match
 * itself is excluded: it is drawn as the committed preview, and drawing it
 * twice would make a complete combo look identical to an incomplete one.
 *
 * Uses the TYPED buffer (`entity.combo`), never the submitted one: this is a
 * projection of keys not yet pressed, and a held half has no keys left to
 * press.  An empty buffer yields nothing — every recipe would be a candidate,
 * which is noise, not aim.
 *
 * Team recipes are excluded: a team stamp lands at the server's `last_joiner`
 * cursor, which the client cannot observe, so ghosting a team half at the LOCAL
 * cursor would confidently point at the wrong cells.
 *
 * Overlap is ADDITIVE, mirroring the mechanic: cells that several candidates
 * cover are the cells that pay off across the most continuations, so `cells`
 * counts coverage rather than merely flagging it.
 *
 * @returns {{cells: Map<number, number>, labels: Array<{label: string,
 *   remaining: number}>}} `cells` maps flat index → how many candidates cover
 *   it; `labels` is ordered by fewest keys remaining, then recipe-table order.
 */
function candidateShapes(game) {
  const own = (game.entities ?? []).find((e) => e.owner === game.player_id);
  const typed = own?.combo ?? [];
  const cells = new Map();
  const labels = [];
  if (typed.length === 0) return { cells, labels };

  const { rows, cols } = gridDims(game);
  const aimRow = own?.cursor_row ?? 0;
  const aimCol = own?.cursor_col ?? 0;

  for (const pr of PLAYER_RECIPES) {
    // Strictly longer, so the exact match is excluded by construction.
    if (pr.pattern.length <= typed.length) continue;
    if (!slotsEqual(typed, pr.pattern.slice(0, typed.length))) continue;

    labels.push({ label: pr.label, remaining: pr.pattern.length - typed.length });
    for (const { dRow, dCol } of pr.offsets) {
      const r = aimRow + dRow;
      const cl = aimCol + dCol;
      // Clipped exactly as slime.apply_shape would: a ghost must not imply
      // coverage the server could never deliver.
      if (r < 0 || r >= rows || cl < 0 || cl >= cols) continue;
      const flat = r * cols + cl;
      cells.set(flat, (cells.get(flat) ?? 0) + 1);
    }
  }
  // Nearest continuations first: those are the ones one keypress away.
  labels.sort((a, b) => a.remaining - b.remaining);
  return { cells, labels };
}

// ---------------------------------------------------------------------------
// Feast tracking (score / hunger deltas → floaters over the bitten cell)
// ---------------------------------------------------------------------------

let lastScoreSeen = 0;
let lastHungerSeen = 0;

/**
 * Call once per drawGame frame, AFTER tickLilGuys so `lastBitePos` already
 * points at a cell the feast just ate.  Score and hunger only move at the
 * turn-end feast or when medicine lands, so the deltas are floated over that
 * cell (falling back to the field center for medicine, which has no cell).
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

/** Tier ordinal → name string; matches protocol Tier ordinal order, hardest
 *  first.  A cell's color is its DIFFICULTY, not its type: red needs three
 *  stamps to defuse, yellow two, green one. */
const TIER_NAMES = ["red", "yellow", "green"];

/** Map Tier → display character.  Pip count = stamps still needed, so the
 *  glyph carries the difficulty without relying on color. */
const TIER_CHAR = { red: "≡", yellow: "=", green: "-" };

/** Map Tier → colour: a hot-to-cool ramp, so difficulty reads at a glance.
 *
 *  SINGLE SOURCE OF COLOR TRUTH: slime blobs, combo/recipe readouts,
 *  hunger-bar healable segments, and the game-over stats tables all read from
 *  this map, so a tier always looks the same wherever it appears. */
const TIER_COLOR = {
  red: "rgba(255,90,90,1)",
  yellow: "rgba(250,210,80,1)",
  green: "rgba(130,230,130,1)",
};

/** Shape footprints in the recipe guide and the on-grid preview: deliberately
 *  NOT a tier color, since a shape is tier-agnostic. */
const SHAPE_COLOR = "rgba(160,220,255,1)";

/** Neutral and defused slime: harmless, so it must not read as any tier color.
 *  Grey is the "safe / inert" color — shared by both tiles and by the
 *  non-healable portion of the hunger bar. */
const NEUTRAL_COLOR = "rgba(150,150,162,1)";

/**
 * Restate an `rgba(r,g,b,a)` color at a new alpha.
 *
 * Every palette constant in this file is written in that one form, so a literal
 * rewrite is exact and avoids a canvas globalAlpha save/restore per cell (the
 * field draws up to 256 of them per frame).  Alpha is clamped, since callers
 * scale it by pulse and overlap counts.  Anything not in `rgba(...)` form is
 * returned untouched rather than silently mangled.
 */
function withAlpha(color, alpha) {
  const a = Math.max(0, Math.min(1, alpha));
  const m = /^rgba?\(([^,]+),([^,]+),([^,)]+)/.exec(color);
  if (m === null) return color;
  return `rgba(${m[1].trim()},${m[2].trim()},${m[3].trim()},${a})`;
}

/** Sum a per-tier {red, yellow, green} object. */
function sumTiers(obj) {
  return TIER_NAMES.reduce((t, name) => t + (obj?.[name] ?? 0), 0);
}

/**
 * One stamp applied to a cell: the name it becomes, or null when there is
 * nothing to downgrade (empty / neutral / already defused).
 *
 * MIRRORS components.Tier.downgrade + slime.apply_shape: red → yellow → green
 * → defused.  Nothing is ever destroyed, so a stamp only ever changes what a
 * cell COSTS to eat, never whether it is eaten.
 */
function downgradeName(name) {
  if (name === "red") return "yellow";
  if (name === "yellow") return "green";
  if (name === "green") return "defused";
  return null;
}

// ---------------------------------------------------------------------------
// Hunger bar + score
// ---------------------------------------------------------------------------

/**
 * Draw the Total Hunger bar.  Fills left→right as slime is consumed; the
 * healable (hazard-slime) portion sits at the right end of the fill as
 * color-coded segments — one per TIER — since only same-tier medicine can heal
 * each segment.
 */
function drawHungerBar(game) {
  const H = LAYOUT.hungerBar;
  const hunger = game.hunger ?? { current: 0, max: 0, healable: {} };
  const healable = hunger.healable ?? {};
  const w = H.x1 - H.x0;
  const frac = hunger.max > 0 ? Math.min(1, hunger.current / hunger.max) : 0;

  const healableTotal = sumTiers(healable);
  const healFracTotal = hunger.max > 0 ? Math.min(frac, healableTotal / hunger.max) : 0;

  text("TOTAL HUNGER", H.x0, H.y + H.labelDy, H.labelFont, C_HEADER);

  rect(H.x0, H.y, w, H.h, H.bg);
  if (frac > 0) rect(H.x0, H.y, w * frac, H.h, H.fill);

  // Healable segments: right end of the current fill, one per tier (only these
  // use tier colors — grey fill = unhealable hunger).  Scale segments
  // proportionally if the fill clamped at the bar edge.
  if (healFracTotal > 0 && healableTotal > 0) {
    const scale = (w * healFracTotal) / healableTotal;
    let x = H.x0 + w * (frac - healFracTotal);
    for (const name of TIER_NAMES) {
      const units = healable[name] ?? 0;
      if (units === 0) continue;
      const segW = units * scale;
      rect(x, H.y, segW, H.h, TIER_COLOR[name]);
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
// Each unit is drawn as its own tile — a gel blob stamped with its tier
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
// only 5 states (3 tiers + defused + neutral), and a 16×16 grid draws
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

/** Tile body colors by tier name, plus neutral's grey.  Derived from
 *  TIER_COLOR/NEUTRAL_COLOR (single source of color truth). */
const TILE_RGB = {
  ...Object.fromEntries(TIER_NAMES.map((n) => [n, parseRgb(TIER_COLOR[n])])),
  neutral: parseRgb(NEUTRAL_COLOR),
};

/**
 * Decode a wire cell name into what to draw.
 *   "empty"    → null (no tile; the socket shows through)
 *   "neutral"  → grey body, no glyph        (harmless filler)
 *   "red"      → red body + ≡ glyph         (hazard, 3 stamps from harmless)
 *   "defused"  → grey body + a dim ring     (was a hazard, now harmless)
 * A defused cell is safe to eat, so its BODY is grey like neutral; the ring
 * distinguishes "someone defused this" from "this was never a threat".
 */
function cellStyle(name) {
  if (!name || name === "empty") return null;
  if (name === "neutral") return { body: "neutral", glyph: null, ring: false };
  if (name === "defused") return { body: "neutral", glyph: null, ring: true };
  return TIER_NAMES.includes(name)
    ? { body: name, glyph: TIER_CHAR[name], ring: false }
    : { body: "neutral", glyph: null, ring: false };
}

/** True when the cell name denotes slime — anything the feast will eat. */
function cellIsSlime(name) {
  return cellStyle(name) !== null;
}

/** The tier of a cell that is still a HAZARD, or null for anything else
 *  (empty, neutral, or already defused).  Exactly the set a stamp can
 *  downgrade. */
function hazardTier(name) {
  return TIER_NAMES.includes(name) ? name : null;
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

  // Ring: this unit was a hazard that somebody defused, as opposed to neutral
  // filler that never threatened anything.
  if (style.ring) {
    c.strokeStyle = "rgba(255,255,255,0.55)";
    c.lineWidth = Math.max(1.5, size * 0.055);
    roundRectPath(c, inset + bw * 0.16, inset + bw * 0.16, bw * 0.68, bw * 0.68,
      radius * 0.68);
    c.stroke();
  }

  // Tier glyph: pip count = stamps still needed, so difficulty survives
  // colorblindness.
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
// The turn-end feast is the exception — it is NOT diffed.  The server eats the
// whole field and refills it in the same tick, so a cell goes straight from one
// color to another with no empty frame in between.  The `turn_ended` event is
// what identifies that frame, and that is what drives the pop.

/** Previous frame's cell names, for change classification. */
let prevGrid = [];

/** flat → { kind: "drop"|"pop"|"flash", t } with `t` counting down in seconds.
 *  A "pop" also carries `from`: the tile that was eaten, bursting outward
 *  while its replacement drops in behind it. */
const cellAnim = new Map();

/** True on the frame a `turn_ended` arrived: EVERY cell was devoured, so every
 *  change on this frame is an eat followed by a refill rather than a plain
 *  server-side replacement.  Set by tickLilGuys, consumed by updateGridAnims. */
let feastThisFrame = false;

/** Cells a stamp covered this frame, from `game.shape_casts`.  A covered cell
 *  that changed was DOWNGRADED by a cast, so it flashes in place rather than
 *  dropping in as new slime — a downgrade rewrites the cell, it never destroys
 *  it, and the two must not look the same. */
const stampedThisFrame = new Set();

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
 * cell.  Must run AFTER tickLilGuys so `feastThisFrame` is populated.
 */
function updateGridAnims(grid) {
  for (let flat = 0; flat < grid.length; flat++) {
    const now = grid[flat];
    const was = prevGrid[flat];
    if (was === undefined) continue; // first frame: no animation, just adopt
    if (now === was) continue;

    if (stampedThisFrame.has(flat) && now === downgradeName(was)) {
      // A stamp stepped this unit down a tier in place: it survived, so it
      // stays put and blooms.
      cellAnim.set(flat, { kind: "flash", t: FIELD.flashS });
    } else if (feastThisFrame && was !== "empty") {
      // The feast ate it; whatever is here now arrived from the reservoir.
      cellAnim.set(flat, { kind: "pop", t: FIELD.popS, from: was });
    } else {
      // Refilled hole, or any other server-side replacement.
      cellAnim.set(flat, { kind: "drop", t: FIELD.dropS });
    }
  }
  prevGrid = grid.slice();
  feastThisFrame = false;
  stampedThisFrame.clear();
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

  // Cells a live or pending cast would cover, and what each becomes.  Exact,
  // not a guess: placement is a pure function of (shape, cursor).  Computed
  // once per frame, and only while something is actually projected.
  const preview = shapePreview(game).cells;
  const pulse = preview.size > 0
    ? FIELD.previewAlphaMin + (FIELD.previewAlphaMax - FIELD.previewAlphaMin) *
      (0.5 + 0.5 * Math.sin(t * Math.PI * 2 * FIELD.previewPulseHz))
    : 0;

  // Cells the combo being TYPED is heading toward.  Static (no pulse) and
  // neutral, so the eye separates "would land" from the pulsing "will land".
  const ghosts = candidateShapes(game).cells;

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

    // Candidate ghost, UNDER everything else: a committed cast covering the
    // same cell must visually win, so this only ever shows through where
    // nothing firmer is drawn.
    const ghostCount = ghosts.get(flat);
    if (ghostCount !== undefined) drawGhostMark(x0, y0, inset, body, ghostCount);

    // Projected footprint: a socket tinted in the OUTCOME color plus a pulsing
    // outline, on every cell a pending cast will cover.  Drawn UNDER the tile
    // so it reads as ground being targeted, and covering an empty cell still
    // shows (that is exactly the aiming mistake worth seeing).
    const becomes = preview.get(flat);
    if (becomes !== undefined) {
      rect(x0 + inset, y0 + inset, body, body,
        withAlpha(becomesColor(becomes), FIELD.previewFillAlpha));
    }

    const name = grid[flat];
    if (!cellIsSlime(name)) {
      // Empty cell: the footprint outline is all there is to draw.
      if (becomes !== undefined) drawPreviewMark(x0, y0, inset, body, becomes, pulse);
      continue;
    }

    let scale = 1;
    let dy = 0;
    if (anim?.kind === "drop" || anim?.kind === "pop") {
      // Slide in from the cell above, easing out, with a landing squash.
      const dur = anim.kind === "drop" ? FIELD.dropS : FIELD.popS;
      const p = 1 - anim.t / dur;
      const ease = 1 - (1 - p) * (1 - p);
      dy = -(1 - ease) * g.cell;
      scale = 1 + Math.sin(p * Math.PI) * 0.08;
    } else {
      // Idle: every cell breathes on its own stable phase.
      scale = 1 + Math.sin(t * FIELD.bobFreq + bobPhase(flat)) * FIELD.bobAmp;
    }

    drawTile(name, x0, y0, g.cell, scale, dy, 1);

    // Outcome wash OVER the tile.  The socket tint above is hidden behind an
    // occupied tile, which is precisely where the preview matters most, so the
    // covered tile is also washed in the color it will become.
    if (becomes !== undefined) {
      rect(x0 + inset, y0 + inset, body, body,
        withAlpha(becomesColor(becomes), FIELD.previewWashAlpha * pulse));
    }

    // Footprint outline: pulsing, in the color the cell will BECOME, at the
    // socket edge — outside the tile body, so it is never confused with the
    // static inner ring that marks an already-defused unit.
    if (becomes !== undefined) drawPreviewMark(x0, y0, inset, body, becomes, pulse);

    // Downgrade flash: a white bloom over the settled tile.
    if (anim?.kind === "flash") {
      const p = 1 - anim.t / FIELD.flashS;
      ctx.save();
      ctx.globalAlpha = (1 - p) * 0.8;
      rect(x0 + inset, y0 + inset, body, body, "rgba(255,255,255,1)");
      ctx.restore();
    }
  }

  // Cursors last, so aim is never buried under a tile.
  drawCursors(game, g, cols);

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

/** The color standing for a projected outcome tier ("defused" has no tier). */
function becomesColor(becomes) {
  return becomes === "defused" ? SHAPE_COLOR : (TIER_COLOR[becomes] ?? SHAPE_COLOR);
}

/**
 * Outline one previewed cell in the color it will BECOME after the stamp —
 * so the preview shows the outcome, not merely "this will be hit".
 */
function drawPreviewMark(x0, y0, inset, body, becomes, pulse) {
  ctx.save();
  ctx.globalAlpha = pulse;
  rectStroke(x0 + inset, y0 + inset, body, body, FIELD.previewWidth,
    becomesColor(becomes));
  ctx.restore();
}

/**
 * Mark one cell a still-being-typed combo could reach.  `count` is how many
 * candidate recipes cover it, and brightness scales with it (capped) so the
 * cells that pay off across the most continuations stand out.
 */
function drawGhostMark(x0, y0, inset, body, count) {
  const strength = Math.min(count, FIELD.ghostAlphaCap / FIELD.ghostAlpha);
  ctx.save();
  rect(x0 + inset, y0 + inset, body, body,
    withAlpha(SHAPE_COLOR, FIELD.ghostFillAlpha * strength));
  ctx.globalAlpha = FIELD.ghostAlpha * strength;
  rectStroke(x0 + inset, y0 + inset, body, body, FIELD.ghostWidth, SHAPE_COLOR);
  ctx.restore();
}

/**
 * Draw every player's aim cursor as a corner crosshair on their cell.
 *
 * The server sends a cursor for EVERY player (and, while a team half is held,
 * the captured anchor instead of the live cursor), so teammates can see where
 * each other are aiming and coordinate a team shape.  The local player's is thicker
 * and yellow; teammates' are thinner and blue.
 *
 * A crosshair rather than a full box: a box at the socket edge would compete
 * with the footprint outline drawn there, and the corner arms stay legible even
 * when both land on the same cell.
 */
function drawCursors(game, g, cols) {
  const own = [];
  for (const e of game.entities ?? []) {
    const r = e.cursor_row ?? 0;
    const cl = e.cursor_col ?? 0;
    const x0 = g.x0 + cl * g.cell;
    const y0 = g.y0 + r * g.cell;
    const isOwn = e.owner === game.player_id;
    // Own cursor drawn last, on top of any teammate sharing the cell.
    if (isOwn) { own.push({ x0, y0 }); continue; }
    drawCrosshair(x0, y0, g.cell, FIELD.cursorMateWidth, C_HEADER);
  }
  for (const o of own) {
    drawCrosshair(o.x0, o.y0, g.cell, FIELD.cursorWidth, C_OWN_ROW);
  }
}

/** Four corner arms bracketing one cell. */
function drawCrosshair(x0, y0, cell, lineW, color) {
  const arm = cell * FIELD.cursorCornerFrac;
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = lineW;
  ctx.beginPath();
  // Top-left, top-right, bottom-left, bottom-right.
  ctx.moveTo(x0, y0 + arm); ctx.lineTo(x0, y0); ctx.lineTo(x0 + arm, y0);
  ctx.moveTo(x0 + cell - arm, y0); ctx.lineTo(x0 + cell, y0); ctx.lineTo(x0 + cell, y0 + arm);
  ctx.moveTo(x0, y0 + cell - arm); ctx.lineTo(x0, y0 + cell); ctx.lineTo(x0 + arm, y0 + cell);
  ctx.moveTo(x0 + cell - arm, y0 + cell); ctx.lineTo(x0 + cell, y0 + cell); ctx.lineTo(x0 + cell, y0 + cell - arm);
  ctx.stroke();
  ctx.restore();
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
// Lil Guys (purely cosmetic: the turn-end feast, dramatised)
// ---------------------------------------------------------------------------
//
// The Lil Guys are NOT simulated.  The server has no Lil Guy entities: at turn
// end it eats the whole field in one operation and tells us so with a
// `turn_ended` event.  Everything here is animation over that single fact.
//
// One guy is shown per connected player (read off `game.entities`, which the
// server already sends for the combo panel).  Between turns they mill about the
// field; on the frame a `turn_ended` arrives they pounce on a cell that was
// occupied, chomp, and the tile layer pops every eaten cell.
//
// Because they are cosmetic, a guy's chosen cell is a display choice and can be
// picked freely — no server state depends on it.

/**
 * @typedef {object} LilGuyView
 * @property {number} x        - current screen x (top-left of the sprite)
 * @property {number} y        - current screen y
 * @property {number|null} target - flat grid index it is walking to
 * @property {boolean} facingLeft - sprite mirror, set from the walk direction
 * @property {string|null} pendingClip - one-shot clip for the next draw
 *   ("attack" on the frame a feast lands), consumed by drawLilGuys
 * @property {number} id      - animator id (offset far above entity ids)
 */

/** Player id → its view state.  Keyed so late joins / disconnects map to the
 *  right sprite instead of shifting everyone by one. */
const lilGuys = new Map();

/** Animator ids live far above entity ids so they cannot collide. */
const LIL_GUY_ANIM_BASE = 1_000_000;

/** Screen position of the most recent chomp — the anchor for score/hunger
 *  floaters (see updateFeastTracking).  null until the first feast. */
let lastBitePos = null;

/** Pick a flat index of an occupied cell for a guy to stand on, or null when
 *  the field is bare.  `nth` spreads the horde out instead of stacking it. */
function feastCell(grid, nth) {
  const occupied = [];
  for (let flat = 0; flat < grid.length; flat++) {
    if (cellIsSlime(grid[flat])) occupied.push(flat);
  }
  if (occupied.length === 0) return null;
  return occupied[(nth * 7) % occupied.length];
}

/**
 * Sync the Lil Guy views with the connected players and advance them one frame.
 *
 * On a `turn_ended` frame every guy chomps: the tile layer is told the whole
 * field was eaten (`feastThisFrame`) so each cell pops, and the floater layer
 * gets an anchor for the hunger/score deltas.
 *
 * `fresh` distinguishes a NEW server frame from a redraw of the one already
 * shown: we redraw at ~60Hz over ~20Hz of frames, so the chomp and its floater
 * must fire only on the first sight of a `turn_ended` or they arrive in triples.
 * Walking is unaffected and advances on every redraw.
 */
function tickLilGuys(game, dt, fresh) {
  const G = LAYOUT.lilGuys;
  const { rows, cols } = gridDims(game);
  const grid = game.grid ?? [];
  const players = (game.entities ?? []).filter((e) => e.owner !== undefined);
  const feast = fresh ? (game.turn_ended ?? null) : null;

  // Drop views whose player is gone (disconnected).
  const live = new Set(players.map((e) => e.owner));
  for (const pid of lilGuys.keys()) {
    if (!live.has(pid)) lilGuys.delete(pid);
  }

  players.forEach((e, i) => {
    const target = feastCell(grid, i);
    let g = lilGuys.get(e.owner);
    if (!g) {
      // Spawn already standing on its cell: a new guy should not sprint in
      // from a stale corner of the field.
      const at = target !== null ? cellCenter(target, rows, cols) : fieldCenter();
      g = {
        x: at.x - G.size / 2,
        y: at.y - G.size / 2,
        target,
        facingLeft: false,
        pendingClip: null,
        id: LIL_GUY_ANIM_BASE + e.owner,
      };
      lilGuys.set(e.owner, g);
    }

    if (feast) {
      const at = g.target !== null
        ? cellCenter(g.target, rows, cols)
        : { x: g.x + G.size / 2, y: g.y + G.size / 2 };
      lastBitePos = at;
      g.pendingClip = "attack";
      spawnFloater("chomp", at.x, at.y - LAYOUT.floater.stack,
        "rgba(230,230,240,0.85)", 0.8); // cosmetic: exempt from 3s rule
    }
    g.target = target;

    // Walk toward the chosen cell (bare field → hold position).
    if (target === null) return;
    const at = cellCenter(target, rows, cols);
    const tx = at.x - G.size / 2;
    const ty = at.y - G.size / 2;
    const dx = tx - g.x, dy = ty - g.y;
    const dist = Math.hypot(dx, dy);
    if (dist <= G.snap) {
      g.x = tx;
      g.y = ty;
      return;
    }
    const step = Math.min(G.speed * dt, dist);
    g.x += (dx / dist) * step;
    g.y += (dy / dist) * step;
    g.facingLeft = dx < 0;
  });

  // The feast emptied every cell, so the tile layer must treat this frame's
  // changes as eats rather than refills.  Set even with no guys on screen: the
  // field was still devoured.
  if (feast) feastThisFrame = true;
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
// Action menu + projected stamp preview
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

  // Aim row: the arrow keys move the cursor the shape is stamped on.
  const own0 = (game.entities ?? []).find(e => e.owner === game.player_id);
  const aimY = my + M.padTopY + M.aimRowDy;
  text(`[← ↑ ↓ →] Aim  @${own0?.cursor_row ?? 0},${own0?.cursor_col ?? 0}`,
    px, aimY, M.aimFont, C_OWN_ROW);

  text("[Esc] Cancel", px, my + M.padTopY + M.cancelRowDy, M.cancelFont, "rgba(180,180,180,0.8)");

  const tbw = mw - M.padX * 2;

  // The local player's cast budget for this turn.  Casts resolve the instant
  // they are submitted, so there is no countdown to show — what matters is how
  // many are left, because the turn (and the feast) waits on the last one.
  {
    const total = game.casts_per_turn ?? 0;
    const own = (game.entities ?? []).find(e => e.owner === game.player_id);
    const left = own ? (own.casts_left ?? 0) : 0;
    const frac = total > 0 ? Math.max(0, Math.min(1, left / total)) : 0;

    rect(px, my + M.castBarDy, tbw, M.castBarH, "rgba(30,30,30,0.8)");
    if (left > 0) {
      rect(px, my + M.castBarDy, tbw * frac, M.castBarH, "rgba(120,220,255,0.9)");
    }
    rectStroke(px, my + M.castBarDy, tbw, M.castBarH, 1, "rgba(255,255,255,0.3)");

    const status = left > 0
      ? `Turn ${game.turn ?? 1} — ${left}/${total} casts left`
      : `Turn ${game.turn ?? 1} — out of casts, waiting on the team`;
    text(status, px, my + M.timerTextDy, M.timerTextFont,
      left > 0 ? C_TEXT : "rgba(180,180,190,0.75)");
  }

  // Project from a HELD team half in preference to a typed combo, so the
  // preview shows what a partner would complete rather than blanking the
  // instant you press ENTER.  The same resolution the field preview draws, so
  // the numbers and the highlighted cells can never disagree.
  const pv = shapePreview(game);
  const projected = pv.projected;

  const parts = [];
  if (pv.hits > 0) {
    parts.push({ str: `${pv.hits} cells`, color: C_SLIME_HDR });
    if (pv.defused > 0) {
      parts.push({ str: `${pv.defused} defused`, color: SHAPE_COLOR });
    }
  }
  // Coverage thrown away: clipped off the grid edge, or landing on cells with
  // nothing left to downgrade.  This is the aiming signal, so it is called out
  // in red rather than hidden.
  const wasted = pv.offGrid + pv.inert;
  if (wasted > 0) parts.push({ str: `${wasted} wasted`, color: C_BAD });
  // Medicine is per tier: shown in the color of the healable bucket it heals.
  for (const name of TIER_NAMES) {
    const n = projected.medicine[name];
    if (n) parts.push({ str: `med${TIER_CHAR[name]}${n}`, color: TIER_COLOR[name] });
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

  // Where the typed combo could still go: the names behind the ghost cells on
  // the field, each with the number of keys still to press.  Dim, because this
  // is an invitation rather than a commitment.
  const cand = candidateShapes(game);
  if (cand.labels.length > 0) {
    // Already sorted nearest-first, so a truncated list keeps the most
    // actionable continuations.
    const shown = cand.labels.slice(0, M.candidateMax);
    const parts = shown.map((c) => `${c.label} +${c.remaining}`);
    const hidden = cand.labels.length - shown.length;
    if (hidden > 0) parts.push(`+${hidden} more`);
    text(`\u2192 ${parts.join(" \u00b7 ")}`, px, my + M.candidateDy,
      M.candidateFont, withAlpha(SHAPE_COLOR, 0.65));
  }
}

/** The `game` object whose transient events have already been consumed.
 *  Identity, not tick number: each server message is parsed into a fresh
 *  object, so identity is exact and needs no monotonicity assumption. */
let lastTransientGame = null;

function drawGame(game, dt) {
  // The render loop redraws `latestMsg` every animation frame (~60Hz) while
  // server frames arrive at ~20Hz, so the same frame is drawn ~3 times.
  // Transient events (dispense outcomes, recipe fires, turn ends, fizzles) are
  // per-frame facts, NOT per-draw, and must be consumed exactly once or they
  // spawn triplicate floaters.
  const fresh = game !== lastTransientGame;
  lastTransientGame = game;

  tickFloaters(dt);
  // Order matters: tickLilGuys reacts to this frame's feast (setting
  // lastBitePos and feastThisFrame) and updateFeastTracking floats the
  // score/hunger deltas over that cell.
  tickLilGuys(game, dt, fresh);
  // Stamp outcomes must be read BEFORE the grid diff: they tell updateGridAnims
  // which cells were covered, which is how a downgraded cell is told apart from
  // one that was merely refilled.
  if (fresh) spawnStampFloaters(game);
  // Then classify grid changes: updateGridAnims needs both the feast
  // tickLilGuys just registered and the covered cells above to tell an eaten
  // cell, a downgraded cell and a plain refill apart.
  tickGridAnims(dt);
  if (fresh) updateGridAnims(game.grid ?? []);
  updateFeastTracking(game);
  if (fresh) {
    spawnCastFloaters(game);
    spawnRecipeFloaters(game);
    spawnTurnEndedFloaters(game);
  }

  clear();

  const H = LAYOUT.headers;
  const encounter = game.encounter || "";
  text(`Encounter: ${encounter}   ·   Turn ${game.turn ?? 1}`,
    H.waveX, H.waveY, H.waveFont, C_HEADER);

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

/**
 * Draw non-zero per-tier values as colored "≡12 -5" cells starting at x.
 * Draws a grey dash when everything is zero.
 */
function drawTierCells(x, y, font, obj) {
  let dx = x;
  let any = false;
  for (const name of TIER_NAMES) {
    const v = obj?.[name] ?? 0;
    if (!v) continue;
    any = true;
    const str = `${TIER_CHAR[name]}${v}`;
    text(str, dx, y, font, TIER_COLOR[name]);
    ctx.font = `${font}px monospace`;
    dx += ctx.measureText(str).width + 8;
  }
  if (!any) text("—", dx, y, font, "rgba(120,120,140,0.6)");
}

/**
 * End-of-game tuning report: outcome, match-wide feast tallies, per-player
 * table, recipe fire counts, derived waste/overheal totals.
 *
 * The report is a single match-wide summary across every turn: how much of the
 * field the team's stamps covered and defused, and how much of it was still a
 * live hazard when the feast came for it.
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

  /** One "LABEL  ≡12 -5" row, bucketed by tier. */
  const feastRow = (label, obj) => {
    text(label, F.label, y, L.rowFont, "rgba(200,200,210,0.9)");
    drawTierCells(F.cells, y, L.rowFont, obj);
    y += L.rowH;
  };
  // `covered` and `neutralized` are bucketed by the tier each cell was BEFORE
  // the stamp, so the rows read as "what did we hit", not "what is left".
  feastRow("cells downgraded", feast.covered);
  feastRow("cells defused", feast.neutralized);
  feastRow("hazard slime eaten", feast.escaped);
  feastRow("medicine dispensed", feast.medicine);
  feastRow("hunger healed", feast.healed);

  // Derived: medicine poured into hunger that was not there — the number a
  // designer tunes medicine pools on.
  const overheal = sumTiers(feast.medicine) - sumTiers(feast.healed);
  y += 4;
  text(
    `neutral eaten ${feast.neutral ?? 0}  ·  hunger ${feast.hunger_normal ?? 0} base ` +
    `+ ${feast.hunger_extra ?? 0} from hazards  ·  medicine overheal ${overheal}`,
    F.label, y, L.rowFont, "rgba(200,200,210,0.9)",
  );
  y += L.rowH + 14;

  // ---- Per-player table ----------------------------------------------------
  const P = L.pcols;
  text("PLAYER", P.name, y, L.sectionFont, C_HEADER);
  text("CASTS", P.casts, y, L.sectionFont, C_HEADER);
  text("CELLS HIT", P.covered, y, L.sectionFont, C_HEADER);
  text("DEFUSED", P.defused, y, L.sectionFont, C_HEADER);
  text("RECIPES", P.recipes, y, L.sectionFont, C_HEADER);
  text("FIZZLES", P.fizzles, y, L.sectionFont, C_HEADER);
  y += L.rowH;
  for (const p of stats.players ?? []) {
    text(p.name || "(anon)", P.name, y, L.rowFont, C_TEXT);
    text(String(p.casts), P.casts, y, L.rowFont, C_TEXT);
    text(String(p.cells_covered ?? 0), P.covered, y, L.rowFont, C_SLIME_HDR);
    text(String(p.cells_neutralized ?? 0), P.defused, y, L.rowFont, SHAPE_COLOR);
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
  // Aim: the arrow keys walk the server-authoritative cursor the shape is
  // stamped on.  Clamped server-side, so holding a direction at an edge is
  // harmless.
  "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
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
