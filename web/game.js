"use strict";

const LAYOUT = {
  // DESIGN SPACE.  Every coordinate in this file is authored in these units.
  // The canvas backing store is `renderScale` times larger (index.html) and a
  // single setTransform at boot scales design units up to it, so art and text
  // gain resolution without any coordinate in here changing.
  screen: { w: 1024, h: 768 },
  renderScale: 2,
  // The whole screen is the same PAPER as the slime field (see
  // slimeField.paper): one continuous e-paper surface, with everything on it
  // drawn as ink.
  bg: "rgba(238,242,250,1)",

  // Slime field: the server-authoritative grid.  Its rows × cols come from
  // the wire (balance.slime_grid), so cell size is derived, not fixed: the
  // grid is square-celled and letterboxed inside this rect (see gridRect).
  slimeField: {
    x0: 40, x1: 984, y0: 220, y1: 620,
    labelDy: 24,
    border: "rgba(0,0,0,0.22)",
    reservoirFont: 14,

    // The field is PAPER: the same white the slime tile art is drawn on
    // (scripts/gen_slime_tiles.py PAPER), so the tiles' white cards merge
    // into one continuous surface and only the line art shows — the face
    // the e-paper badge wears.  The UI around the field stays dark.
    paper: "rgba(238,242,250,1)",

    // Empty cell: a dim recessed socket, so a hole reads as "awaiting the
    // reservoir" rather than as background.
    socketFill: "rgba(0,0,0,0.10)",
    socketBorder: "rgba(0,0,0,0.08)",

    // --- Individual slime unit tiles (see tileSprite) --------------------
    tileMax: 72,        // cap on cell size (design px); small grids letterbox
    tileGap: 0.18,      // inset per side as a fraction of the cell: large, so
    // units read as discrete candies rather than a contiguous mass
    tileRadius: 0.28,   // body corner radius as a fraction of the body size
    symbolAlpha: 0.55,  // tier glyph opacity stamped on the body
    // Per-cell animation durations (seconds) and idle wobble.
    dropS: 0.15,        // refill slide-in from above
    popS: 0.22,         // eaten-tile burst (driven by the feast cinematic)
    flashS: 0.25,       // downgraded-tile white bloom
    bobAmp: 0.02,       // idle breathing: ±fraction of tile size
    bobFreq: 1.6,       // idle breathing rate (rad/s)

    // --- Aim cursor + projected shape footprint (see shapePreview) --------
    //
    // One owner-keyed language for every selected square, mirroring the
    // badge's tile rings: SOLID outline = the local player, DOTTED = a
    // sibling player.  Cursors bracket the CELL edge; footprint outlines sit
    // at the SOCKET edge, so the two never merge on a shared cell.
    cursorWidth: 3,       // the local player's cursor: thick, unmissable
    cursorMateWidth: 2,   // teammates' cursors: present but subordinate
    previewWidth: 3.5,    // projected-footprint outline stroke width
    previewPulseHz: 2.4,  // pulse rate
    previewAlphaMin: 0.35,// pulse trough
    previewAlphaMax: 0.95,// pulse crest
    // Under-socket tint on a covered cell, in the color the cell will BECOME
    // — visible where the footprint covers EMPTY ground (an occupied cell
    // shows the coverage by swapping to the inverted tile art instead).
    previewFillAlpha: 0.16,

    // --- Locked-in casts --------------------------------------------------
    //
    // A cast that has been committed is a FACT, so it is drawn as solid pips
    // rather than as another pulsing outline: the pulse means "if you press
    // ENTER", and these have already been pressed.
    pendingDotFrac: 0.09,  // pip radius, as a fraction of the cell
    pendingDotGap: 0.06,   // gap between pips on one square, ditto

    // --- The coming bite ---------------------------------------------------
    //
    // Hatch strength for a hazard the next bite will NIBBLE (hunger for no
    // score), and for the brighter version shown where the PENDING cast
    // would defuse it in time to be consumed instead.  The opened mark is
    // loud on purpose: it is the only place the screen shows what a cast is
    // worth beyond the cells it lands on.
    shelteredAlpha: 0.5,
    openedAlpha: 0.95,
    // Wash over the bite-strip columns — the front the feast will chew at
    // turn end — so the team always knows what ground is on the clock.
    biteStripAlpha: 0.08,
  },

  hungerBar: {
    x0: 40, x1: 984, y: 150, h: 18,
    labelFont: 14, labelDy: -8,
    bg: "rgba(0,0,0,0.12)",
    // Grey, matching neutral/defused slime.  The bar is a one-way clock now:
    // there is nothing to segment it by, because nothing takes hunger back.
    fill: "rgba(150,150,162,0.9)",
    dangerBorder: "rgba(255,60,60,0.95)",
    textFont: 13,
  },

  // The shared charge pool, drawn as a DRAINING gauge directly under the
  // hunger bar: the two are read together, since one fills as the other
  // empties and the game ends whichever way round they finish.
  chargeBar: {
    x0: 40, x1: 984, y: 196, h: 10,
    labelFont: 13, labelDy: -6,
    bg: "rgba(0,0,0,0.12)",
    lowBorder: "rgba(200,140,0,0.95)",
    textFont: 13,
  },

  // Score HUD, top-right: a big golden triangle with the collected count to
  // its left.  Every eaten cell launches a small golden triangle (see
  // flyTris) that streaks here; the big one swells once per arrival and the
  // displayed count steps up with it, so the score visibly ACCRUES rather
  // than jumping.  `x/y` is the big triangle's centre and the fliers' target.
  scoreHud: {
    x: 968, y: 58,
    triSize: 15,          // big triangle circumradius (design px)
    font: 26, gap: 14,    // score digits: size, and clearance from the triangle
    pulseS: 0.35, pulseScale: 1.3, // arrival swell: one beat, and back
    // Flying triangles: a brief random pop off the bitten cell, then an
    // accelerating homing run.  `steer` is how hard velocity bends toward the
    // target per second; `snap` is close-enough (plus a per-frame overshoot
    // guard); `maxAgeS` is the failsafe so no flier orbits forever.
    flySize: 7,
    launchSpeed: 160, homeSpeed: 1500, rampS: 0.55, steer: 8,
    snap: 12, maxAgeS: 2.5,
    trailLen: 10,         // positions kept for the streak
    trailAlpha: 0.55, trailWidth: 4, // streak: alpha and width at the head
  },

  headers: { waveX: 40, waveY: 50, waveFont: 20, labelDy: -30, labelFont: 18 },

  // Per-player shape-wheel rows, bottom-left beside the action menu.
  // `labelW` is the widest move label the row reserves; longer labels are
  // clipped by the columns after it rather than reflowing the panel.
  wheelPanel: { x: 24, y0: 652, rowH: 18, font: 13, labelW: 84, nameW: 42 },

  // Lil Guys: one per connected player, cosmetic bodies — they STAND at the
  // LEFT edge of the field (the mouths the conveyor feeds) and chomp in
  // place when the turn-end bite chews the front columns (see tickLilGuys /
  // the cinematic).  `speed` is px/s for filing back to a post; `snap` is
  // how close counts as arrived.
  //
  // `scale` sizes the drawSprite box RELATIVE TO A SLIME BLOCK: the guys are
  // a quarter again as big as the food they eat, whatever cell size the grid
  // letterboxes to (see lilGuySize).  The blit is nearest-neighbour off a
  // 72px frame, so pixel widths alternate slightly at non-integer ratios —
  // traded knowingly for a size that tracks the board.  `doorGap` is the
  // clearance between a parked guy and the grid's left edge, so the corral
  // never overlaps the first column of cells.
  lilGuys: { scale: 1.25, speed: 220, snap: 3, doorGap: 6 },

  // The turn-end bite, played out cell by cell (see the cinematic section).
  // The whole sequence is a deliberate pause in play: input is dead until it
  // finishes, because the board on screen is mid-replay and nothing aimed at it
  // would mean anything.
  cinematic: {
    // Wall clock the EAT stage is fitted BETWEEN, whatever the bite's width,
    // so the pause never scales with the meal: a wide bite hurries and a
    // one-cell nibble lingers instead of finishing before the eye catches
    // it.  A small meal is the common case and the one most worth watching,
    // so it gets the same beat as a feast.
    eatMinS: 2,
    eatCapS: 5,
    chompPauseS: 0.1,   // beat held on each bitten cell, so a bite is legible
    collapseS: 0.4,     // one advance: survivors sliding left, refills sliding in
    effectStepS: 0.15,  // stagger between a swallowed neutralizer's affected cells
    ringS: 0.4,         // one affected cell's border flash, fading out
    // Longest frame the replay will honour.  requestAnimationFrame stops firing
    // in a hidden tab, so returning to one delivers a single frame worth however
    // long it was away — and spending it would eat the whole meal in one step,
    // which is the jump cut the replay exists to avoid.  Time the player was not
    // watching is not time the feast ran.
    maxStepS: 1 / 15,
  },

  // Per-player action menus: one box per SEAT (max `seats`), bottom row,
  // to the right of the wheel panel.  Each shows only the spell shape its
  // player is holding plus their lock-in state; pulse/shake are the physical
  // feedback for valid / refused selections (see the menu FX section).
  playerMenus: {
    seats: 4, w: 160, h: 96, gap: 14, x0: 291, y: 656,
    labelDy: 16, labelFont: 12,
    shapeCellMax: 13, shapeCellGap: 2,
    statusDy: 10, statusFont: 12,      // up from the box's bottom edge
    pulseS: 0.35, pulseScale: 1.10,    // valid lock-in: one swell and back
    shakeS: 0.4, shakeAmp: 5, shakeHz: 26, // refused: decaying sideways rattle
    // Gentle continuous breathing on the menu of the LAST committed action,
    // so "who moved most recently" stays readable after the swell ends.
    lastPulseHz: 1.4, lastPulseScale: 1.03,
  },

  // Default floater lifetime ≥ 3s so feedback is readable; cosmetic chomps
  // are exempt (see tickLilGuys).  Recipe floaters render larger, and the
  // end-of-match verdict larger still — it is the only thing on the board
  // worth reading at that point.
  floater: {
    font: 16, drift: 40, jitter: 40, stack: 22, lifetime: 3.0,
    // The verdict sits ABOVE field centre: the feast tally lands at centre
    // (-30) and the sheltered line just below it (+28), and a 56px headline
    // dropped between them would sit on both.  Everything drifts up together
    // afterwards, so clearing them once clears them for good.
    recipeFont: 24, verdictFont: 56, verdictDy: -70,
  },

  preLobby: {
    titleX: 40, titleY: 60, titleFont: 32,
    optX: 60, optY0: 160, optGap: 40, optFont: 22,
    errorDy: 100, errorFont: 18,
    codePromptY: 160, codeY: 210, codeFont: 36, codeHintY: 270, codeHintFont: 16,
  },

  // The pre-match screen: title + game id up top, the study guide below,
  // and the BEGIN button (gameOver.button geometry) at the bottom.
  guide: {
    titleX: 40, titleY: 52, titleFont: 32,
    codeX: 40, codeY: 92, codeFont: 22,
    guideX: 40, guideY: 140, guideFont: 13, guideLineH: 19,
    recipeHeaderGap: 10, recipeRowH: 25, recipeFont: 14,
    recipeLabelW: 170, recipeSlotGap: 10, recipeArrowGap: 24,
    // Mini-board cell size for the shape demo inside each recipe card, and
    // the grid the card's demo slot is budgeted for: every card reserves a
    // demoGridMax × demoGridMax box (shapes centre inside it), so all cards
    // come out the same size whatever shape they hold.
    demoCell: 20, demoGridMax: 6,
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
    pcols: { name: 40, casts: 190, covered: 250, defused: 420, recipes: 590 },
    hintFont: 14,
    // The clickable "next round" button, bottom-centred under the report.
    button: { w: 320, h: 52, bottomGap: 28, font: 18 },
  },
};

// Derived convenience aliases (read-only mirrors of LAYOUT).
const SW = LAYOUT.screen.w;
const SH = LAYOUT.screen.h;
const FIELD = LAYOUT.slimeField;

// Everything below is INK on the paper background: the palette that used to
// be light-on-dark is restated dark-on-light, same hues, e-paper contrast.
const C_BG = LAYOUT.bg ?? "rgba(238,242,250,1)";
const C_TEXT = "rgba(40,40,55,1)";
const C_HEADER = "rgba(60,90,200,1)";
const C_SLIME_HDR = "rgba(30,140,60,1)";
const C_OWN_ROW = "rgba(190,140,0,1)";
// Score gold: the flying triangles, their streaks, and the HUD triangle.
// Warmer and brighter than the ambers above on purpose — it is a reward, not
// a warning — with a dark rim so it holds an edge on the paper background.
const C_GOLD = "rgba(255,200,60,1)";
const C_GOLD_DARK = "rgba(170,120,15,1)";
/**
 * Per-seat identity colors, indexed by player id (seat 0..3): every mark a
 * player leaves on the shared screen — stamp outlines, cursor box, pending
 * pips, menu frame — wears their color, so four people can read one board.
 * Dark enough to hold contrast on the paper field.
 *
 * Future: controllers will inject custom colors; route any override through
 * `playerColor` so the default palette stays the fallback.
 */
const PLAYER_COLORS = [
  "rgba(190,140,0,1)", // P0 amber
  "rgba(70,110,220,1)", // P1 blue
  "rgba(40,150,80,1)", // P2 green
  "rgba(160,70,190,1)", // P3 purple
];
/** Marks owned by nobody we can name (observer id 0xFF, stale seat). */
const C_UNSEATED = "rgba(110,110,130,0.8)";

/** THE lookup for a player's color — every owner-keyed mark goes through
 *  here, so controller-injected palettes later only touch this. */
function playerColor(owner) {
  return PLAYER_COLORS[owner] ?? C_UNSEATED;
}

const C_MENU_BG = "rgba(0,0,0,0.05)";
/** Warning red: a stamp aimed off the grid or at cells with nothing to hit. */
const C_BAD = "rgba(210,50,50,1)";
/** Muted tint for the wasted tail of a stamp floater — present but not
 *  competing with the count that actually accomplished something. */
const C_MUTED = "rgba(150,110,110,0.9)";

/** The shared charge pool.  Amber, and used NOWHERE else: charges are the one
 *  resource that never comes back, so they get a colour of their own rather
 *  than borrowing a tier's. */
const C_CHARGE = "rgba(200,140,0,1)";
/** A recipe that costs nothing — green, because it is always castable. */
const C_FREE = "rgba(30,150,70,1)";
/** The coming bite's wasted mouthfuls: hazards it will nibble for hunger and
 *  no score (and the bite-strip ground wash).  Deliberately cold and dull:
 *  a nibble is not a threat, it is wasted opportunity. */
const C_SHELTERED = "rgba(60,120,170,1)";

/** Sprite used for the cosmetic Lil Guys roaming the slime field.  Generated
 *  from the board build's authored art by scripts/gen_lilguy.py. */
const LIL_GUY_SPRITE = "lilguy";
/** The slime tile atlas (scripts/gen_slime_tiles.py): authored SlimeBlock art
 *  shared with the e-paper badge.  Frames are picked by NAME from its json
 *  (hard/medium/soft/goo + *_invert for selected cells). */
const SLIME_SPRITE = "slime";
/** The baby atlas (scripts/gen_babies.py): the authored critters, one frame
 *  per BabyType, picked by NAME from its json (rose..plum). */
const BABY_SPRITE = "babies";

/** Sprite sheets to load: the Lil Guys, the slime tile atlas and the brood. */
const CLASSES = [LIL_GUY_SPRITE, SLIME_SPRITE, BABY_SPRITE];

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
  BOMB_ROCKS_ONLY = bal.specials?.bomb?.explode_rocks_only ?? false;
  FEAST_COLUMNS = bal.feast_columns ?? 1;
  FEAST_COLUMNS_PER_GUY = bal.feast_columns_per_guy ?? 0;
  PLAYER_RECIPES = bal.player_recipes.map((r) => ({
    label: r.label,
    rows: r.shape,
    offsets: shapeOffsets(r.shape),
    cost: r.cost ?? 1,
  }));
  // Group components are authored as move LABELS; resolve to move-table
  // indices once here so the guide and the preview both index the same space
  // the server does.  An unknown label cannot occur (the Zig loader rejects
  // the config), but a -1 would poison lookups, so it is dropped.
  const moveIndex = new Map(PLAYER_RECIPES.map((r, i) => [r.label, i]));
  TEAM_RECIPES = bal.team_recipes.map((r) => ({
    label: r.label,
    components: r.moves.map((m) => moveIndex.get(m)).filter((i) => i !== undefined),
    rows: r.shape,
    offsets: shapeOffsets(r.shape),
    cost: r.cost ?? 1,
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
  flyTris.length = 0;
  scoreHud.displayed = 0;
  scoreHud.pulseT = 0;
  lastScoreSeen = 0;
  lastHungerSeen = 0;
  lilGuys.clear();
  babyViews.length = 0; // re-derived from the next frame's counts
  lastBitePos = null;
  // Grid animation state is per-match: a new game's first frame must adopt its
  // grid silently rather than diff it against the last game's board.  A replay
  // in flight is abandoned outright — it is animating a board this session has
  // left, and there is nothing left on screen to land it on.  Its held score and
  // hunger floaters go with it, deliberately: the deltas are already banked
  // server-side, and floating them here would mean numbers rising over the
  // game-over screen from a board that is no longer being shown.
  cinematic = null;
  prevGrid = [];
  cellAnim.clear();
  stampedThisFrame.clear();
  lastTransientGame = null;
  chargesSeenMax = 0;
  menuFx.clear();
  prevMenuPending = new Map();
  lastCommitPid = null;
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

  if (preLobbyMode === "choose") {
    const highlight = "rgba(170,120,0,1)";
    text("[C]  Create lobby", L.optX, L.optY0, L.optFont, highlight);
    text("[J]  Join existing lobby", L.optX, L.optY0 + L.optGap, L.optFont, C_TEXT);
    if (PAGE_CONFIG_HASH) {
      text(`(custom config ${PAGE_CONFIG_HASH})`,
        L.optX, L.optY0 + 2 * L.optGap, L.errorFont, "rgba(110,110,120,1)");
    }
    if (preLobbyError) {
      text(preLobbyError, L.optX, L.optY0 + 2 * L.optGap + L.errorDy, L.errorFont, "rgba(200,50,50,1)");
    }
  } else if (preLobbyMode === "entering_code") {
    text("Enter lobby code:", L.optX, L.codePromptY, L.optFont, C_TEXT);
    // Show typed code + blinking underscore cursor.
    const display = preLobbyCode.padEnd(6, "_");
    text(display, L.optX, L.codeY, L.codeFont, "rgba(170,120,0,1)");
    text("[ENTER] to confirm    [ESC] back", L.optX, L.codeHintY, L.codeHintFont, "rgba(110,110,120,1)");
    if (preLobbyError) {
      text(preLobbyError, L.optX, L.codeHintY + 40, L.errorFont, "rgba(200,50,50,1)");
    }
  }
}

function drawFull() {
  clear();
  const L = LAYOUT.full;
  text("Session full (max 6 players).", L.x, SH / 2 + L.titleDy, L.titleFont, C_TEXT);
  text("Close another tab to free a slot.", L.x, SH / 2 + L.subDy, L.subFont, C_TEXT);
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

/** Width a drawParts run occupies (no trailing gap), so callers can center
 *  it before drawing. */
function partsWidth(font, parts, gap) {
  if (parts.length === 0) return 0;
  ctx.font = `${font}px monospace`;
  let w = -gap;
  for (const p of parts) w += ctx.measureText(p.str).width + gap;
  return w;
}

/**
 * Colored parts for a recipe's charge cost.  Every recipe shows one, including
 * the free ones: "0" is a real tactical option and hiding it would make a free
 * recipe look like an unpriced oversight.
 */
function costParts(cost) {
  const n = cost ?? 0;
  return [{ str: `${n}\u26a1`, color: n === 0 ? C_FREE : C_CHARGE }];
}

/**
 * Draw a recipe's shape as a MINI BOARD, rendered with the same pieces the
 * field uses: every cell gets the recessed socket rect, and each covered ("#")
 * cell wears the INVERTED slime tile art — the game's own mark for "a cast
 * covers this cell" — over a SHAPE_COLOR footprint outline at the socket edge.
 * The anchor cell (the one you aim at; every other cell lands relative to it)
 * is bracketed at the cell edge in C_OWN_ROW, the same aim-cell convention as
 * the action menu's shape (drawSpellShape).
 *
 * @param {number} cx   - horizontal centre of the demo grid
 * @param {number} top  - top edge of the demo grid
 * @param {string[]} rows - authored shape rows ("###" / ".#.")
 * @param {number} cell - cell size in design px (LAYOUT.guide.demoCell)
 */
function drawShapeDemo(cx, top, rows, cell) {
  const nR = rows.length;
  const nC = rows[0]?.length ?? 0;
  if (nR === 0 || nC === 0) return;
  const anchorR = Math.floor(nR / 2);
  const anchorC = Math.floor(nC / 2);
  const x0 = cx - (nC * cell) / 2;

  const inset = cell * FIELD.tileGap;
  const body = cell - inset * 2;
  for (let r = 0; r < nR; r++) {
    for (let cl = 0; cl < nC; cl++) {
      const cxp = x0 + cl * cell;
      const cyp = top + r * cell;
      // Socket: the same ground every field cell stands on.
      rect(cxp + inset, cyp + inset, body, body, FIELD.socketFill);
      rectStroke(cxp + inset, cyp + inset, body, body, 1, FIELD.socketBorder);
      if (rows[r][cl] === "#") {
        // Covered cell: inverted hazard tile + footprint outline, exactly the
        // pair the live cast preview paints on the field.
        drawTile("red", cxp, cyp, cell, 1, 0, 1, true);
        ctx.save();
        ctx.strokeStyle = SHAPE_COLOR;
        ctx.lineWidth = 1.5;
        ctx.strokeRect(cxp + inset, cyp + inset, body, body);
        ctx.restore();
      }
      if (r === anchorR && cl === anchorC) {
        rectStroke(cxp, cyp, cell, cell, 1.5, C_OWN_ROW);
      }
    }
  }
}

/**
 * Lobby study guide: how casting works + every move on the shape wheel and
 * every group, all in parity colors (slime = agent = hunger block).
 * Moves appear in data/balance.json order, which IS the wheel order.
 */
function drawRecipeGuide() {
  const L = LAYOUT.guide;
  let y = L.guideY;

  y += L.guideLineH;
  const descColor = "rgba(70,70,85,0.95)";
  // The turn loop: a fixed budget of casts each, all of them resolving
  // together once the last player has chosen, then the whole field is eaten.
  const castingLine = [
    { str: `Press A to LOCK IN`, color: descColor },
    { str: "Once all Researchers have LOCKED IN their selection the SD2 will disperse", color: RECIPE_COLOR_TEAM },
    { str: "Neutralizing Agent over the Substance field", color: RECIPE_COLOR_TEAM },
  ];
  const descLines = [
    [
      { str: "GAMEPLAY INSTRUCTIONS TO COME", color: descColor },
      //  { str: "AIM with the arrow keys. Turn the SHAPE WHEEL to pick your move:", color: descColor },
      //  { str: "1 next", color: WHEEL_COLOR.forward },
      //  { str: "2 back", color: WHEEL_COLOR.backward },
      //],
      //[
      //  { str: "Your pick STAYS until you turn the wheel again — it survives casting and the turn end.", color: descColor },
      //],
      //[
      //  { str: "Each move below stamps its SHAPE on the grid, centred on your cursor.", color: descColor },
      //],
      //[
      //  { str: "Every covered cell steps down one tier:", color: descColor },
      //  { str: `${TIER_CHAR.red}red`, color: TIER_COLOR.red },
      //  { str: "→", color: descColor },
      //  { str: `${TIER_CHAR.yellow}yellow`, color: TIER_COLOR.yellow },
      //  { str: "→", color: descColor },
      //  { str: `${TIER_CHAR.green}green`, color: TIER_COLOR.green },
      //  { str: "→ defused (harmless to eat).", color: descColor },
      //],
      //[
      //  { str: "Aim is captured when you press ENTER — re-aiming will not move a cast already locked in.", color: descColor },
      //],
      //[
      //  { str: "Nothing lands until the turn resolves, so you can see the whole plan first.", color: descColor },
      //  { str: "ESC takes back your last lock-in.", color: C_BAD },
      //],
      //[
      //  { str: "The turn ends once EVERYONE has locked in: every cast lands at once, then the Lil Guys pour in from the LEFT.", color: descColor },
      //],
      //[
      //  { str: "They only eat what they can WALK to. Live hazard slime is a wall — everything behind it survives.", color: descColor },
      //],
      //[
      //  { str: "Defuse a wall and you open a road. Survivors fall to the bottom, then fresh slime drops in on top.", color: descColor },
      //],
      //[
      //  { str: "Every cast spends from ONE shared pool", color: descColor },
      //  { str: "\u26a1", color: C_CHARGE },
      //  { str: "that lasts the WHOLE encounter and never refills. A cast the turn cannot afford is REFUSED, costing nothing.", color: descColor },
    ],
    //  castingLine,

  ];
  for (const line of descLines) {
    drawParts(L.guideX, y, L.guideFont, line, 8);
    y += L.guideLineH;
  }
  y += L.recipeHeaderGap;

  text("MOVES", L.guideX, y, L.guideFont + 2, C_HEADER);
  y += L.guideLineH;

  // Each recipe is a bordered CARD with its parts stacked vertically (label,
  // components, shape, cost).  Every card is the SAME fixed size, budgeted
  // for the largest shape the demo may hold (demoGridMax × demoGridMax), so
  // the grid of cards stays regular whatever each recipe contains: each part
  // lives in a fixed slot, and slots a card has no content for stay blank.
  // Cards flow LEFT-TO-RIGHT, wrapping to a new row when the next card would
  // run past the canvas edge.
  const maxX = SW - L.guideX; // right margin mirrors the left one
  const cardGap = L.recipeSlotGap;
  const cardPad = 8;
  const cardBorder = "rgba(0,0,0,0.25)";
  const lineH = L.guideLineH;
  const demoGapY = 4; // breathing room above and below the mini board
  const demoBox = L.demoGridMax * L.demoCell; // demo slot: fits a 6×6 shape
  const cardW = cardPad * 2 + demoBox;
  const cardH = cardPad + L.recipeFont // label baseline
    + lineH                            // component slot (blank for moves)
    + demoGapY + demoBox + demoGapY    // mini-board demo slot
    + lineH                            // cost line
    + lineH                            // suffix slot (blank for moves)
    + cardPad;
  let x = L.guideX;

  /** Close out the current flow row (no-op if nothing is on it). */
  const flushRow = () => {
    if (x > L.guideX) {
      y += cardH + cardGap;
      x = L.guideX;
    }
  };

  /**
   * One guide card: label, what it is made of, its shape (a mini board drawn
   * with the game's own tiles — see drawShapeDemo), its cost — stacked top to
   * bottom inside a border box, every line centred on the card and the shape
   * centred in its slot.  `made` is the components line — empty for a move
   * (the wheel is how you pick it), the component move labels for a group.
   */
  const drawRecipeRow = (r, labelColor, made, suffix) => {
    if (x > L.guideX && x + cardW > maxX) flushRow();
    rectStroke(x, y, cardW, cardH, 1, cardBorder);
    const cx = x + cardW / 2;
    ctx.font = `${L.recipeFont}px monospace`;
    let by = y + cardPad + L.recipeFont; // label baseline
    text(r.label, cx - ctx.measureText(r.label).width / 2, by,
      L.recipeFont, labelColor);
    by += lineH; // component slot, blank when there are none
    if (made.length > 0) {
      drawParts(cx - partsWidth(L.recipeFont, made, L.recipeSlotGap) / 2, by,
        L.recipeFont, made, L.recipeSlotGap);
    }
    const rows = r.rows ?? ["#"];
    // Centre the shape inside the fixed demo slot, both axes.
    by += demoGapY;
    drawShapeDemo(cx, by + (demoBox - rows.length * L.demoCell) / 2,
      rows, L.demoCell);
    by += demoBox + demoGapY;
    by += lineH;
    const cost = costParts(r.cost);
    drawParts(cx - partsWidth(L.recipeFont, cost, L.recipeSlotGap) / 2, by,
      L.recipeFont, cost, L.recipeSlotGap);
    if (suffix) {
      by += lineH;
      ctx.font = `${L.guideFont}px monospace`;
      text(suffix, cx - ctx.measureText(suffix).width / 2, by,
        L.guideFont, RECIPE_COLOR_TEAM);
    }
    x += cardW + cardGap;
  };

  for (const r of PLAYER_RECIPES) {
    drawRecipeRow(r, RECIPE_COLOR_PLAYER, [], null);
  }
  flushRow();

  if (TEAM_RECIPES.length > 0) {
    y += L.recipeHeaderGap;
    text("GROUPS", L.guideX, y, L.guideFont + 2, C_HEADER);
    y += L.guideLineH;
    for (const r of TEAM_RECIPES) {
      // Components are move labels joined by "+": each must come from a
      // DIFFERENT player, so the count doubles as "how many of you it takes".
      const made = [];
      r.components.forEach((ci, i) => {
        if (i > 0) made.push({ str: "+", color: descColor });
        made.push({ str: PLAYER_RECIPES[ci]?.label ?? "?", color: RECIPE_COLOR_PLAYER });
      });
      drawRecipeRow(r, RECIPE_COLOR_TEAM, made, `(needs ${r.components.length} players)`);
    }
    flushRow();
  }
}

/**
 * The pre-match screen: shown before EVERY encounter (server holds play on
 * its `prematch` flag).  The study guide, the game id so others can join,
 * and the BEGIN button that starts play — a browser click, like the end
 * screen's, so a round never begins by accident.
 */
function drawPreMatch(game) {
  clear();
  const L = LAYOUT.guide;
  text(`Game ${game?.join_code ?? "------"}`, L.codeX, L.codeY, L.codeFont, C_TEXT);
  const standing = game?.observer
    ? "Press P to play once game starts"
    : `You are seated as P${game?.player_id ?? "?"}.`;
  ctx.save();
  ctx.font = `${L.codeFont - 6}px monospace`;
  text(standing, L.codeX + 260, L.codeY, L.codeFont - 6,
    game?.observer ? C_TEXT : playerColor(game?.player_id));
  ctx.restore();

  drawRecipeGuide();
  drawRestartButton("SCAN FOR NEARBY SLIME");
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
 * The one thing a cast can do other than land: be refused for price.
 *
 * Sent only to the player who tried, and only on the frame they tried, so it
 * is a floater rather than anything persistent — nothing changed, and the
 * numbers it quotes are already on screen in the turn readout.  Loud and
 * central because it explains a key press that otherwise did nothing at all.
 */
function spawnRefusalFloater(game) {
  const ob = game.over_budget;
  if (!ob) return;
  const { x, y } = fieldCenter();
  spawnFloater(`Too expensive! \u26a1${ob.needed} needed, \u26a1${ob.have} left`,
    x, y, C_BAD, LAYOUT.floater.lifetime, LAYOUT.floater.recipeFont);
}

/** Player-recipe floater color (matches the recipe label color elsewhere). */
const RECIPE_COLOR_PLAYER = "rgba(170,120,0,1)";
/** Group floater color — distinct so co-op fires pop. */
const RECIPE_COLOR_TEAM = "rgba(0,140,180,1)";

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

  for (const ev of events) {
    for (const flat of ev.cells ?? []) stampedThisFrame.add(flat);
  }

  // A cast that lands while the feast is replaying is held until the replay
  // ends.  The board on screen is the pre-feast one, so floating "3 downgraded"
  // now would point at cells that visibly have not changed — and the cells it
  // names may not even exist after the collapse.  The stamped-cell record above
  // is NOT deferred: the diff after the replay needs it to tell a downgrade from
  // a refill, and it is bookkeeping rather than something on screen.
  const sink = cinematic ? cinematic.deferred.stamps : null;
  if (sink) {
    sink.push(...events);
    return;
  }

  const { rows, cols } = gridDims(game);
  events.forEach((ev, i) => floatStampOutcome(ev, i, rows, cols));
}

/** One landed shape's readout, stacked at `slot` to keep simultaneous casts apart. */
function floatStampOutcome(ev, slot, rows, cols) {
  const STACK = LAYOUT.floater.stack;

  // Anchor the readout on the footprint itself — the whole point of aiming
  // is that the outcome is local, so a field-centre label would hide it.
  const at = (ev.cells ?? []).length > 0
    ? cellCenter(ev.cells[0], rows, cols)
    : fieldCenter();
  const y = at.y + slot * STACK;

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
}

/** Turn-loop floater color (matches the cast-budget gauge). */
const CAST_EVENT_COLOR = "rgba(0,130,200,1)";

// The turn-end headline ("Lil Guys Eating!", then the tally) is spawned by the
// feast cinematic, which is the only thing that knows when the meal starts and
// when it is over — see spawnFeastTallyFloaters.

/**
 * Compact per-player shape-wheel rows (bottom-left UI panel).  No player
 * sprites are rendered — the wheel selection is the only per-player element on
 * screen.  The local player's row is highlighted, and every row shows how many
 * casts that player has left this turn: the turn cannot end until they are all
 * spent, so a row with casts left is a row the team is waiting on.
 *
 * Showing EVERY player's selection (not just the local one) is what makes
 * groups playable: you can see a teammate is holding the move your group needs
 * before you spend a cast on the square.
 */
function drawWheelPanel(game) {
  const CP = LAYOUT.wheelPanel;
  const entities = game.entities || [];
  entities.forEach((e, i) => {
    const y = CP.y0 + i * CP.rowH;
    text(`P${e.owner}`, CP.x, y, CP.font, playerColor(e.owner));

    // Selection is server-authoritative, so this is what that player WILL
    // cast.  A stale frame against a freshly reloaded (shorter) move table
    // falls back to the first move, matching the server's own clamp.
    const move = PLAYER_RECIPES[e.selected_shape ?? 0] ?? PLAYER_RECIPES[0];
    text(move?.label ?? "-", CP.x + CP.nameW, y, CP.font, RECIPE_COLOR_PLAYER);

    // Casts left this turn: a filled pip per remaining cast, so "who are we
    // waiting on" is readable at a glance.  A player with none left has LOCKED
    // IN — the turn resolves the moment the last of them does.
    const usedX = CP.x + CP.nameW + CP.labelW;
    const left = e.casts_left ?? 0;
    if (left > 0) {
      text("◆".repeat(left), usedX, y, CP.font, CAST_EVENT_COLOR);
    } else {
      text("locked in", usedX, y, CP.font, SHAPE_COLOR);
    }
    // Where that player is aimed.  Once they have locked in, their cursor is
    // just a cursor: show the square their last commitment is actually ON,
    // because that is the one a group has to be aimed at.
    const mine = (game.pending ?? []).filter((pc) => pc.player_id === e.owner);
    const last = mine.length > 0 ? mine[mine.length - 1] : null;
    const cols = gridDims(game).cols;
    const at = last !== null && left === 0
      ? `!${Math.floor(last.square / cols)},${last.square % cols}`
      : `@${e.cursor_row ?? 0},${e.cursor_col ?? 0}`;
    text(at, usedX + 60, y, CP.font, playerColor(e.owner));
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
// Score fly-off (golden triangles: eaten cell → score HUD, top right)
// ---------------------------------------------------------------------------
//
// Every cell the feast eats launches one small golden triangle from where it
// stood: a short random pop, then an accelerating homing streak to the HUD
// triangle beside the score.  On arrival it disappears, the HUD triangle
// swells once, and the DISPLAYED score steps up by one — so the count on
// screen accrues bite by bite instead of jumping to the server's total.
//
// The server's score is still the only truth: whenever nothing is in flight
// and no replay is running, the displayed count snaps to `game.score`, which
// covers hidden tabs, mid-game joins, and any cell whose scoring the client
// mis-guessed.  The triangles are receipts, not a ledger.

/** @typedef {{x:number, y:number, vx:number, vy:number, age:number,
 *             trail: {x:number, y:number}[]}} FlyTri */
/** @type {FlyTri[]} */
const flyTris = [];

/** What the HUD currently shows: the count (stepped up per arrival, synced to
 *  the server when idle) and the seconds left in the arrival swell. */
const scoreHud = { displayed: 0, pulseT: 0 };

/** Trace an equilateral triangle path, point-up at rot=0, circumradius r. */
function trianglePath(x, y, r, rot = 0) {
  ctx.beginPath();
  for (let i = 0; i < 3; i++) {
    const a = rot - Math.PI / 2 + i * (2 * Math.PI / 3);
    const px = x + r * Math.cos(a);
    const py = y + r * Math.sin(a);
    if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
  }
  ctx.closePath();
}

/** Launch one golden triangle from (x, y) — a bitten cell's centre. */
function spawnFlyTri(x, y) {
  const S = LAYOUT.scoreHud;
  // Random outward pop, biased upward so the launch reads as a burst off the
  // board before the homing pull takes over.
  const a = Math.random() * Math.PI * 2;
  flyTris.push({
    x, y,
    vx: Math.cos(a) * S.launchSpeed,
    vy: Math.sin(a) * S.launchSpeed - 60,
    age: 0,
    trail: [],
  });
}

/** One flier landed on the HUD: count it and start the swell. */
function flyTriArrive() {
  scoreHud.displayed += 1;
  scoreHud.pulseT = LAYOUT.scoreHud.pulseS;
}

/**
 * Advance every flier one frame and drop the arrived ones.
 *
 * Motion is velocity steering: each frame the velocity bends toward "straight
 * at the HUD at the current target speed", and the target speed ramps from
 * launch to homing over `rampS` — so the random pop reads first, then the
 * flier commits.  Arrival is "close enough OR would overshoot this frame"
 * (the homing run ends fast enough to clear the snap radius in one step),
 * with `maxAgeS` as the failsafe.
 */
function tickFlyTris(dt) {
  const S = LAYOUT.scoreHud;
  scoreHud.pulseT = Math.max(0, scoreHud.pulseT - dt);
  let w = 0;
  for (const tri of flyTris) {
    tri.age += dt;
    const dx = S.x - tri.x;
    const dy = S.y - tri.y;
    const dist = Math.hypot(dx, dy) || 1;
    const speed = S.launchSpeed +
      (S.homeSpeed - S.launchSpeed) * Math.min(1, tri.age / S.rampS);
    if (dist <= Math.max(S.snap, speed * dt) || tri.age > S.maxAgeS) {
      flyTriArrive();
      continue;
    }
    const k = Math.min(1, S.steer * dt);
    tri.vx += (dx / dist * speed - tri.vx) * k;
    tri.vy += (dy / dist * speed - tri.vy) * k;
    tri.trail.push({ x: tri.x, y: tri.y });
    if (tri.trail.length > S.trailLen) tri.trail.shift();
    tri.x += tri.vx * dt;
    tri.y += tri.vy * dt;
    flyTris[w++] = tri;
  }
  flyTris.length = w;
}

/** Draw every flier: fading tapered streak first, gold triangle on top,
 *  nose rotated along its velocity. */
function drawFlyTris() {
  const S = LAYOUT.scoreHud;
  ctx.save();
  ctx.lineCap = "round";
  for (const tri of flyTris) {
    const pts = tri.trail.concat([{ x: tri.x, y: tri.y }]);
    for (let i = 1; i < pts.length; i++) {
      const f = i / pts.length; // 0 tail → 1 head
      ctx.strokeStyle = `rgba(255,200,60,${(S.trailAlpha * f).toFixed(3)})`;
      ctx.lineWidth = Math.max(0.5, S.trailWidth * f);
      ctx.beginPath();
      ctx.moveTo(pts[i - 1].x, pts[i - 1].y);
      ctx.lineTo(pts[i].x, pts[i].y);
      ctx.stroke();
    }
    const rot = Math.atan2(tri.vy, tri.vx) + Math.PI / 2;
    trianglePath(tri.x, tri.y, S.flySize, rot);
    ctx.fillStyle = C_GOLD;
    ctx.fill();
    ctx.lineWidth = 1;
    ctx.strokeStyle = C_GOLD_DARK;
    ctx.stroke();
  }
  ctx.restore();
}

/**
 * The score HUD, top right: big gold triangle, count to its left.  Both wear
 * the arrival swell — a sine ease up and back over `pulseS`.  Drawn LAST so
 * incoming fliers vanish INTO the triangle rather than over it.
 */
function drawScoreHud(game) {
  const S = LAYOUT.scoreHud;
  // Idle catch-up: with nothing in flight and no replay running, the server's
  // total is the only number worth showing.
  if (flyTris.length === 0 && !cinematicActive()) {
    scoreHud.displayed = game.score ?? 0;
  }
  const frac = S.pulseS > 0 ? scoreHud.pulseT / S.pulseS : 0;
  const scale = 1 + (S.pulseScale - 1) * Math.sin(frac * Math.PI);

  trianglePath(S.x, S.y, S.triSize * scale);
  ctx.fillStyle = C_GOLD;
  ctx.fill();
  ctx.lineWidth = 2;
  ctx.strokeStyle = C_GOLD_DARK;
  ctx.stroke();

  ctx.save();
  ctx.font = `bold ${Math.round(S.font * scale)}px monospace`;
  ctx.fillStyle = C_GOLD_DARK;
  ctx.textAlign = "right";
  ctx.fillText(`${scoreHud.displayed}`, S.x - S.triSize - S.gap, S.y + S.font * 0.35);
  ctx.restore();
}

// ---------------------------------------------------------------------------
// Shape-wheel + group preview (mirrors game_logic.zig / balance.zig)
// ---------------------------------------------------------------------------

// Move tables are loaded from data/balance.json (loadBalanceData) — the same
// file the Zig server reads, so there is no hand-mirrored copy to drift.  A
// move's `cost` is what it takes out of the team's shared charge pool; a group
// is charged ONCE for the whole group, not once per contributor.
//
// These tables are the complete move list, both here and on the server: the
// wheel can only ever be pointing at one of them.

/** Casts each player gets per turn, from balance.json.  The server announces
 *  the same number in game_start; this copy is what the LOBBY reads, before
 *  any game_start has arrived. */
let CASTS_PER_TURN = 3;
/** @typedef {{dRow: number, dCol: number}} ShapeOffset */
/** @type {Array<{label: string, rows: string[],
 *   offsets: ShapeOffset[], cost: number}>} */
let PLAYER_RECIPES = [];
/** `components` are indices into PLAYER_RECIPES (resolved from the authored
 *  move labels at load time).
 *  @type {Array<{label: string, components: number[], rows: string[],
 *   offsets: ShapeOffset[], cost: number}>} */
let TEAM_RECIPES = [];

/**
 * Accumulate one projected recipe into the batch: its shape as a stamp at an
 * absolute anchor, plus its cost.
 *
 * @param {{stamps: Array<object>, cost: number, labels: string[]}} sum
 * @param {object} recipe - the move or group (carries offsets + cost)
 * @param {{row: number, col: number}} anchor - square the stamp centres on
 * @param {number} owner - player_id credited with the stamp (a group goes to
 *   the completing cast's owner, mirroring the server); picks the outline's
 *   color
 * @param {boolean} pending - every cast in this stamp is LOCKED IN: the
 *   outline draws dotted (a fact), where live aim draws solid
 */
function addOutput(sum, recipe, anchor, owner, pending) {
  sum.stamps.push({
    offsets: recipe.offsets ?? [],
    label: recipe.label,
    anchor,
    owner,
    pending,
  });
  sum.cost += recipe.cost ?? 0;
  sum.labels.push(recipe.label);
}

/**
 * The turn as the viewer can best guess it: every cast already LOCKED IN,
 * plus EVERY seated player's live aim while they still have a cast to spend.
 *
 * Locked-in casts are facts — the server froze their square and move — so
 * they are taken verbatim and in order, and they render DOTTED.  Live aim is
 * a live wheel + cursor the server broadcasts for every seat, rendered SOLID
 * in that player's color: the whole table (and any observer screen) sees
 * where everyone is pointing before anything is committed.
 *
 * @returns {Array<{owner: number, move: number, row: number, col: number,
 *   pending: boolean}>} lock-ins first in order, then live aim in seat
 *   order with the viewer's own last (it wins overlap precedence).
 */
function projectedCasts(game) {
  const { cols } = gridDims(game);
  const casts = (game.pending ?? []).map((pc) => ({
    owner: pc.player_id,
    move: pc.move,
    row: Math.floor(pc.square / cols),
    col: pc.square % cols,
    pending: true,
  }));

  const live = [];
  let ownAim = null;
  for (const e of game.entities ?? []) {
    if ((e.casts_left ?? 0) === 0) continue;
    const aim = {
      owner: e.owner,
      move: e.selected_shape ?? 0,
      row: e.cursor_row ?? 0,
      col: e.cursor_col ?? 0,
      pending: false,
    };
    if (e.owner === game.player_id) ownAim = aim; else live.push(aim);
  }
  if (ownAim !== null) live.push(ownAim);
  return casts.concat(live);
}

/**
 * Resolve a list of casts into the stamps and the price the turn would buy.
 *
 * MIRROR OF game_logic.resolve_batch — keep the two in step.  Per square, in
 * first-appearance order, each group in table order fires as many times as its
 * component bag can be filled from the casts still unconsumed on that square,
 * each component from a DISTINCT player.  A group consumes its whole bag, so a
 * contributor does not also stamp their own move.  Whatever is left over
 * stamps itself, in lock-in order.  The total is what the pool is charged: a
 * group is priced at the group, never at its parts.
 *
 * The last entry may be the viewer's own uncommitted aim (see projectedCasts),
 * which is what makes this a preview rather than a readout.
 *
 * @returns {{stamps: Array<{offsets: ShapeOffset[], label: string,
 *   anchor: {row: number, col: number}}>, cost: number, labels: string[]}}
 */
function projectBatch(game) {
  const sum = { stamps: [], cost: 0, labels: [] };
  const casts = projectedCasts(game);
  const consumed = new Array(casts.length).fill(false);

  casts.forEach((head, hi) => {
    // One hunt per square: a later cast on a square already searched would
    // only re-run the same search over the same remaining casts.
    const seen = casts.slice(0, hi)
      .some((e) => e.row === head.row && e.col === head.col);
    if (seen) return;

    for (const tr of TEAM_RECIPES) {
      if ((tr.components ?? []).length === 0) continue;
      for (; ;) {
        const picks = [];
        for (const comp of tr.components) {
          const found = casts.findIndex((cand, ci) =>
            !consumed[ci] &&
            cand.row === head.row && cand.col === head.col &&
            cand.move === comp &&
            !picks.some((pi) => casts[pi].owner === cand.owner));
          if (found === -1) break;
          picks.push(found);
        }
        if (picks.length < tr.components.length) break;
        for (const pi of picks) consumed[pi] = true;
        // Credited to the contributor who locked in LAST, exactly as the
        // server resolves it (game_logic.resolve_batch).  The group is a
        // FACT (dotted) only once every contribution is locked in; one live
        // aim in the bag keeps it a solid could-be.
        const last = Math.max(...picks);
        addOutput(sum, tr, { row: head.row, col: head.col }, casts[last].owner,
          picks.every((pi) => casts[pi].pending));
      }
    }
  });

  casts.forEach((c, ci) => {
    if (consumed[ci]) return;
    const move = PLAYER_RECIPES[c.move];
    if (move === undefined) return;
    addOutput(sum, move, { row: c.row, col: c.col }, c.owner, c.pending);
  });

  return sum;
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
  const projected = projectBatch(game);

  const cells = new Map();
  // flat → { owner, pending } for EVERY on-grid covered cell — inert ones
  // included (already-defused slime, empty ground).  This is the map the
  // renderer draws the stamp's SHAPE from, so it must be the whole
  // footprint: a coverage map that skipped the do-nothing cells would show
  // a stamp with holes in it.  The outline wears the owner's color; pending
  // (locked-in) draws dotted, live aim solid.  Where stamps overlap the
  // VIEWER's own wins: your own aim is what your cast resolves against —
  // same precedence as the badge's overlay map.
  const owners = new Map();
  let offGrid = 0;
  let inert = 0;
  let hits = 0;
  let defused = 0;

  for (const stamp of projected.stamps) {
    for (const { dRow, dCol } of stamp.offsets) {
      const r = stamp.anchor.row + dRow;
      const cl = stamp.anchor.col + dCol;
      if (r < 0 || r >= rows || cl < 0 || cl >= cols) { offGrid++; continue; }
      const flat = r * cols + cl;
      if (!owners.has(flat) || stamp.owner === game.player_id) {
        owners.set(flat, { owner: stamp.owner, pending: stamp.pending });
      }
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
  // Nibbles this batch would turn into MEALS.  A cast's real value is what
  // it defuses before the bite lands on it — hunger-clock that would have
  // been spent for nothing becomes a point instead — so the preview has to
  // price that explicitly or the whole mechanic stays invisible.
  let opened = 0;
  if (cells.size > 0) {
    const before = reachability(game);
    if (before.nibbled.size > 0) {
      const after = reachability(game, cells);
      for (const flat of before.nibbled) {
        if (after.eaten.has(flat)) opened++;
      }
    }
  }

  return { cells, owners, offGrid, inert, hits, defused, opened, projected };
}

// ---------------------------------------------------------------------------
// Feast tracking (score / hunger deltas → floaters over the bitten cell)
// ---------------------------------------------------------------------------

let lastScoreSeen = 0;
let lastHungerSeen = 0;

/**
 * Call once per drawGame frame, right after any feast replay has been started.
 * Score and hunger ONLY move at the turn-end feast — nothing gives either of
 * them back — so the deltas always belong over the cell that was just bitten.
 *
 * While the feast is being replayed the deltas are HELD: they are the payout of
 * a meal the player has not watched yet, and the replay releases them over the
 * final bite (see finishEat).
 */
function updateFeastTracking(game) {
  const score = game.score ?? 0;
  const hunger = game.hunger?.current ?? 0;
  const scoreGain = score - lastScoreSeen;
  const hungerGain = hunger - lastHungerSeen;
  lastScoreSeen = score;
  lastHungerSeen = hunger;

  if (scoreGain === 0 && hungerGain === 0) return;

  if (cinematic) {
    cinematic.deferred.score += scoreGain;
    cinematic.deferred.hunger += hungerGain;
    return;
  }
}

/** Highlight colour per shape-wheel direction key (1 = next, 2 = back). */
const WHEEL_COLOR = {
  forward: "rgba(30,120,200,1)",
  backward: "rgba(200,30,140,1)",
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
 *  SINGLE SOURCE OF COLOR TRUTH: slime blobs, move/group readouts and the
 *  game-over stats tables all read from this map, so a tier always looks the
 *  same wherever it appears. */
const TIER_COLOR = {
  red: "rgba(215,60,60,1)",
  yellow: "rgba(200,150,0,1)",
  green: "rgba(50,160,70,1)",
};

/** Shape footprints in the recipe guide and the on-grid preview: deliberately
 *  NOT a tier color, since a shape is tier-agnostic. */
const SHAPE_COLOR = "rgba(40,120,200,1)";

/** Neutral and defused slime: harmless, so it must not read as any tier color.
 *  Grey is the "safe / inert" color — shared by both tiles and by the hunger
 *  bar's fill. */
const NEUTRAL_COLOR = "rgba(150,150,162,1)";

/** Neutralizer special: inert to casts, swallowed for free by the feast,
 *  firing a 3x3 Agent block as it goes down.  Violet, shared with nothing,
 *  because it is neither ordinary food nor hazard. */
const SPECIAL_COLOR = "rgba(140,70,210,1)";

/** Egg special: edible, hatches a baby when eaten.  Warm cream so it reads
 *  as a prize rather than a threat. */
const EGG_COLOR = "rgba(235,200,120,1)";

/** Rock special: the permanent wall — inedible, impassable, cast-proof.
 *  Cold slate, deliberately duller than any hazard: nothing to do here. */
const ROCK_COLOR = "rgba(96,94,108,1)";

/** Canister special: free pickup that refills the team's charge pool
 *  ("Neutralizing Agent energy").  Teal, energetic but not a hazard hue. */
const CANISTER_COLOR = "rgba(60,180,190,1)";

/** Bomb special: free pickup that DESTROYS its 3x3 surroundings when eaten
 *  (or just the rocks in it, per balance).  Hot orange: handle with care. */
const BOMB_COLOR = "rgba(225,110,40,1)";

/** Whether the bomb's blast destroys ONLY rocks (balance
 *  specials.bomb.explode_rocks_only) — read with the balance tables so the
 *  replay and the reachability preview mutate boards exactly as the server
 *  did. */
let BOMB_ROCKS_ONLY = false;

/** Bite width knobs (balance feast_columns / feast_columns_per_guy) — read
 *  with the balance tables so the replay bites exactly the columns the
 *  server bit.  MIRRORS balance.Balance.feast_width. */
let FEAST_COLUMNS = 1;
let FEAST_COLUMNS_PER_GUY = 0;

/** The bite's width in columns for this frame's seated crowd, clamped to the
 *  grid — MIRRORS balance.feast_width(seated_players). */
function feastWidth(game, cols) {
  const seated = (game?.entities ?? []).filter((e) => e.owner !== undefined).length;
  return Math.min(FEAST_COLUMNS + seated * FEAST_COLUMNS_PER_GUY, cols);
}

/** BabyType ordinal → type name; matches components.BabyType.  Each has
 *  authored art in the baby atlas (BABY_SPRITE), keyed by these names. */
const BABY_TYPES = ["rose", "mint", "sky", "gold", "plum"];

/** Colour per baby type.  The critters draw as black-and-white sprites for
 *  now; this table is the fallback dot when the atlas has not loaded, and
 *  the palette for the per-type colour identity that is coming later. */
const BABY_COLOR = {
  rose: "rgba(230,110,140,1)",
  mint: "rgba(110,210,160,1)",
  sky: "rgba(110,170,230,1)",
  gold: "rgba(220,180,70,1)",
  plum: "rgba(160,110,200,1)",
};

/** Sum a per-baby-type {rose,...,plum} object. */
function sumBabies(obj) {
  return BABY_TYPES.reduce((t, name) => t + (obj?.[name] ?? 0), 0);
}

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
 * Draw the Total Hunger bar: a one-way clock.  It only ever fills, so there is
 * nothing to segment it by and no reason for tier colour here — the single
 * grey fill IS the message.
 */
function drawHungerBar(game) {
  const H = LAYOUT.hungerBar;
  const hunger = game.hunger ?? { current: 0, max: 0 };
  const w = H.x1 - H.x0;
  const frac = hunger.max > 0 ? Math.min(1, hunger.current / hunger.max) : 0;

  text("L. Genus Specimen apitite level", H.x0, H.y + H.labelDy, H.labelFont, C_HEADER);

  rect(H.x0, H.y, w, H.h, H.bg);
  if (frac > 0) rect(H.x0, H.y, w * frac, H.h, H.fill);

  // Danger is signalled by the border, never the fill.
  const nearFull = frac > 0.85;
  rectStroke(H.x0 - 2, H.y - 2, w + 4, H.h + 4, nearFull ? 3 : 1,
    nearFull ? H.dangerBorder : "rgba(0,0,0,0.25)");

  text(`${hunger.current}/${hunger.max}`,
    H.x0 + w - 90, H.y + H.h + 14, H.textFont, "rgba(70,70,85,0.95)");
}

/**
 * Highest charges seen this game — the denominator for the pool gauge.
 *
 * The server sends only what is LEFT, and the starting figure comes from the
 * encounter, which the client never reads.  Since the pool is monotonically
 * non-increasing within a game, the first value observed is the maximum, and
 * clearEntityState() resets it between games.
 */
let chargesSeenMax = 0;

/**
 * Draw the shared charge pool.  Drains right→left, opposite to hunger, so the
 * two gauges visibly close on each other as the encounter runs out of road.
 */
function drawChargeBar(game) {
  const B = LAYOUT.chargeBar;
  const charges = game.charges ?? 0;
  if (charges > chargesSeenMax) chargesSeenMax = charges;
  const w = B.x1 - B.x0;
  const frac = chargesSeenMax > 0 ? Math.min(1, charges / chargesSeenMax) : 0;

  text("Neutralizer Units Remaining",
    B.x0, B.y + B.labelDy, B.labelFont, C_CHARGE);

  rect(B.x0, B.y, w, B.h, B.bg);
  if (frac > 0) rect(B.x0, B.y, w * frac, B.h, C_CHARGE);

  const low = frac <= 0.15;
  rectStroke(B.x0 - 2, B.y - 2, w + 4, B.h + 4, low ? 3 : 1,
    low ? B.lowBorder : "rgba(0,0,0,0.25)");

  text(`\u26a1 ${charges}`, B.x0 + w - 90, B.y + B.h + 14, B.textFont, C_CHARGE);
}

// ---------------------------------------------------------------------------
// Slime field (the server-authoritative grid)
// ---------------------------------------------------------------------------
//
// The server owns one grid of individual slime units plus an off-grid
// reservoir that refills emptied cells from the right edge.  Render frames carry
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

// --- The turn-end bite -------------------------------------------------------
//
// MIRRORS slime.feast.  The Lil Guys stand at the LEFT edge and bite the
// front `feastWidth` columns cell by cell, column-major top-down: edible
// units (neutral / defused / consumable specials) are CONSUMED, live hazards
// are NIBBLED one tier softer in place, rocks are skipped.  Nothing shelters
// anything — every cell in the bitten columns is visited exactly once.
//
// The client recomputes this rather than being told, because it needs the
// answer for a HYPOTHETICAL board — the one the player's pending cast would
// create — and no server message can describe a turn that has not happened.

/** Memo for reachability(), keyed on the frame object.  drawGame calls this
 *  from several places per frame; one entry is enough, since frames are
 *  processed strictly in order. */
let reachCacheKey = null;
let reachCacheVal = null;

/**
 * Bite the front `width` columns of an arbitrary board and report what the
 * feast takes.
 *
 * Takes a plain board rather than a render frame so the same bite serves both
 * the live grid and the PRE-feast board the cinematic replays (which is no
 * longer any frame the server sent).
 *
 * @param {string[]} board - flat cell names, row-major, row 0 = top
 * @param {number} rows
 * @param {number} cols
 * @param {number} width - bite width in columns (see feastWidth)
 * @param {Map<number,string>} [overrides] - flat → replacement cell name,
 *   used to ask "what would this cast convert?" without mutating the board.
 * @returns {{eaten: Set<number>, nibbled: Set<number>, order: number[],
 *            settles: Map<number, number[]>}}
 *   `order` is every bitten cell (consumed AND nibbled) in the server's
 *   column-major walk order; `eaten` is the consumed subset, `nibbled` the
 *   hazards that only stepped a tier; `settles` maps a bite index to the
 *   neutralizer blocks fired after it (each entry the swallowed
 *   neutralizer's cell — its 3x3 fires there, on the STANDING board).
 */
function biteFeast(board, rows, cols, width, overrides) {
  // A full SIMULATION of the meal.  MIRRORS slime.feast cell for cell: the
  // walk is column 0 top-down, then column 1, and so on.  A swallowed
  // neutralizer's 3x3 fires on the STANDING board mid-bite (so a hazard
  // later in the walk can be defused in time to be consumed); a bomb's
  // blast levels its 3x3 the same way (a cell it empties ahead of the walk
  // is skipped when reached).
  const work = board.slice(0, rows * cols);
  if (overrides) for (const [flat, name] of overrides) work[flat] = name;

  /** Bite positions in the order they were taken. */
  const order = [];
  const eaten = new Set();
  const nibbled = new Set();
  /** Neutralizer blocks after order[i]: each the 3x3's center cell. */
  const settles = new Map();

  const w = Math.min(width, cols);
  for (let col = 0; col < w; col++) {
    for (let r = 0; r < rows; r++) {
      const flat = r * cols + col;
      const name = work[flat];
      const tier = hazardTier(name);
      if (tier !== null) {
        // The NIBBLE: one downgrade in place, never removed.
        work[flat] = downgradeName(name);
        order.push(flat);
        nibbled.add(flat);
        continue;
      }
      if (!cellIsEdible(name)) continue; // empty, or an inert rock
      work[flat] = "empty";
      order.push(flat);
      eaten.add(flat);
      if (name === "special_neutralizer") {
        // The block fires where it was eaten, on the board AS IT STANDS.
        for (const cell of agentBlockCells(flat, rows, cols)) {
          const next = downgradeName(work[cell]);
          if (next !== null) work[cell] = next;
        }
        const at = order.length - 1;
        if (!settles.has(at)) settles.set(at, []);
        settles.get(at).push(flat);
      } else if (name === "special_bomb") {
        // The blast levels its 3x3 where it was eaten, on the board AS IT
        // STANDS — a cell it empties ahead of the walk is skipped there.
        detonateOn(work, flat, rows, cols, null);
      }
    }
  }

  return { eaten, nibbled, order, settles };
}

/**
 * Pack every row of `board` against the LEFT edge — MIRRORS slime.shift_left:
 * the conveyor's advance.  When `onMove` is given it is called
 * (destFlat, slidCols) per moved unit, which is how the replay turns slides
 * into animations.
 */
function shiftBoard(board, rows, cols, onMove) {
  for (let r = 0; r < rows; r++) {
    let write = 0;
    for (let read = 0; read < cols; read++) {
      const flat = r * cols + read;
      if (!cellIsSlime(board[flat])) continue;
      if (read !== write) {
        const dest = r * cols + write;
        board[dest] = board[flat];
        board[flat] = "empty";
        if (onMove) onMove(dest, read - write);
      }
      write++;
    }
  }
}

/** The 3x3 Agent block around `center`, clipped, in row-major offset order —
 *  MIRRORS slime.AGENT_BLOCK, so effects apply in the server's order. */
function agentBlockCells(center, rows, cols) {
  const cr = Math.floor(center / cols), cc = center % cols;
  const cells = [];
  for (let dr = -1; dr <= 1; dr++) {
    for (let dc = -1; dc <= 1; dc++) {
      const r = cr + dr, cl = cc + dc;
      if (r < 0 || r >= rows || cl < 0 || cl >= cols) continue;
      cells.push(r * cols + cl);
    }
  }
  return cells;
}

/**
 * The bomb's blast — MIRRORS slime.detonate: destroy every occupied cell in
 * the 3x3 around `center` (or, with BOMB_ROCKS_ONLY, just the rocks in it).
 * Walked in the server's row-major order; `onDestroy(flat, name)` is called
 * per destroyed cell so the replay can burst them where they stood.
 */
function detonateOn(board, center, rows, cols, onDestroy) {
  for (const cell of agentBlockCells(center, rows, cols)) {
    const name = board[cell];
    if (!cellIsSlime(name)) continue;
    if (BOMB_ROCKS_ONLY && name !== "special_rock") continue;
    board[cell] = "empty";
    if (onDestroy) onDestroy(cell, name);
  }
}

/**
 * `biteFeast` over a render frame's own grid at this frame's bite width,
 * memoised per frame — "what will the NEXT bite consume, and what will it
 * only nibble?".
 *
 * @param {object} game    - render frame (grid + dims + seated crowd)
 * @param {Map<number,string>} [overrides] - see biteFeast
 */
function reachability(game, overrides) {
  if (!overrides && reachCacheKey === game && reachCacheVal) return reachCacheVal;

  const { rows, cols } = gridDims(game);
  const out = biteFeast(game.grid ?? [], rows, cols, feastWidth(game, cols), overrides);
  if (!overrides) {
    reachCacheKey = game;
    reachCacheVal = out;
  }
  return out;
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
  special_neutralizer: parseRgb(SPECIAL_COLOR),
  special_egg: parseRgb(EGG_COLOR),
  special_rock: parseRgb(ROCK_COLOR),
  special_canister: parseRgb(CANISTER_COLOR),
  special_bomb: parseRgb(BOMB_COLOR),
};

/**
 * Decode a wire cell name into what to draw.
 *   "empty"               → null (no tile; the socket shows through)
 *   "neutral"             → grey body, no glyph  (harmless filler)
 *   "red"                 → red body + ≡ glyph   (hazard, 3 stamps from harmless)
 *   "defused"             → grey body + a dim ring (was a hazard, now harmless)
 *   "special_neutralizer" → violet body + ★ glyph (free pickup: eaten for no
 *                            score, fires a 3x3 Agent block)
 *   "special_egg"         → cream body + ○ glyph  (food with a baby inside)
 *   "special_rock"        → slate body + ■ glyph  (permanent wall: inedible,
 *                            impassable, cast-proof)
 *   "special_canister"    → teal body + ⚡ glyph  (free pickup: refills the
 *                            team's charge pool)
 *   "special_bomb"        → orange body + ✱ glyph (free pickup: destroys its
 *                            3x3 surroundings — or just the rocks in it)
 * A defused cell is safe to eat, so its BODY is grey like neutral; the ring
 * distinguishes "someone defused this" from "this was never a threat".
 */
function cellStyle(name) {
  if (!name || name === "empty") return null;
  if (name === "neutral") return { body: "neutral", glyph: null, ring: false };
  if (name === "defused") return { body: "neutral", glyph: null, ring: false };
  if (name === "special_neutralizer") return { body: "special_neutralizer", glyph: "\u2605", ring: false };
  if (name === "special_egg") return { body: "special_egg", glyph: "\u25cb", ring: false };
  if (name === "special_rock") return { body: "special_rock", glyph: "\u25a0", ring: false };
  if (name === "special_canister") return { body: "special_canister", glyph: "\u26a1", ring: false };
  if (name === "special_bomb") return { body: "special_bomb", glyph: "\u2731", ring: false };
  return TIER_NAMES.includes(name)
    ? { body: name, glyph: TIER_CHAR[name], ring: false }
    : { body: "neutral", glyph: null, ring: false };
}

/** True when the cell name denotes an occupied cell — anything with a tile. */
function cellIsSlime(name) {
  return cellStyle(name) !== null;
}

/** True when the bite CONSUMES this cell (as opposed to nibbling or skipping
 *  it).  Live hazards are nibbled instead; the rock is inert; empty is
 *  nothing.  Consumable specials are eaten whole: an egg is food with a baby
 *  inside, a neutralizer is free equipment that fires a 3x3 Agent block as
 *  it is swallowed, a canister is free equipment that refills the team's
 *  charge pool, a bomb levels its 3x3 as it goes down. */
function cellIsEdible(name) {
  return name === "neutral" || name === "defused" ||
    name === "special_egg" || name === "special_neutralizer" ||
    name === "special_canister" || name === "special_bomb";
}

/** The tier of a cell that is still a HAZARD, or null for anything else
 *  (empty, neutral, or already defused).  Exactly the set a stamp can
 *  downgrade. */
function hazardTier(name) {
  return TIER_NAMES.includes(name) ? name : null;
}

/** state|selected|size → rendered tile canvas.  Cleared on cell-size change. */
const tileCache = new Map();
let tileCacheSize = -1;

/** Tile body → slime atlas frame stem (see scripts/gen_slime_tiles.py).
 *  Hard/Medium/Soft/Goo are the authored red/yellow/green/grey; neutral and
 *  defused both map to goo, matching the badge.  The special kinds have no
 *  authored art and keep the procedural drawing. */
const SLIME_FRAME = {
  red: "hard",
  yellow: "medium",
  green: "soft",
  neutral: "goo",
};

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
 *
 * Slime bodies blit the authored SlimeBlock atlas (black-and-white, shared
 * with the e-paper badge); `selected` swaps in the *_invert frame — the mark
 * for a cell covered by the cast preview or a cursor.  The special kinds (and the
 * unlikely case of the atlas not having loaded) falls back to the original
 * procedural gel tile.
 */
function tileSprite(name, size, selected = false) {
  if (size !== tileCacheSize) {
    tileCache.clear();
    tileCacheSize = size;
  }
  const key = `${name}|${selected ? 1 : 0}|${size}`;
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

  const atlas = sprites.get(SLIME_SPRITE);
  const stem = SLIME_FRAME[style.body];
  if (atlas !== undefined && stem !== undefined) {
    const meta = atlas.meta;
    const idx = meta.frames[selected ? `${stem}_invert` : stem];
    // Pixel art: nearest-neighbour upscale, same as drawSprite.
    c.imageSmoothingEnabled = false;
    c.drawImage(atlas.img, idx * meta.frame_w, 0, meta.frame_w, meta.frame_h,
      inset, inset, bw, bw);
    tileCache.set(key, cv);
    return cv;
  }

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
// The turn-end feast is NOT diffed at all: the server bites, slides and refills
// the whole field in one tick, so every cell changes at once and a diff can say
// nothing useful about which of the three happened.  That frame is replayed
// instead, and the replay queues these same animations itself — see the feast
// cinematic section.

/** Previous frame's cell names, for change classification. */
let prevGrid = [];

/**
 * flat → queued animation, `t` counting down from `dur` in seconds:
 *   { kind: "drop",  dur, t, cells? }        a tile arriving from above
 *   { kind: "slide", dur, t, cells? }        a tile arriving from the RIGHT
 *     (the conveyor: the shift packing left, or the refill entering)
 *   { kind: "pop",   dur, t, from, cells? }  a bitten tile bursting outward,
 *     with any replacement arriving behind it
 *   { kind: "flash", dur, t }                a downgraded tile blooming
 * `cells` is the travel distance in cells, defaulting to one: the feast
 * cinematic sets a real distance, since its survivors and refills travel
 * arbitrarily far.
 */
const cellAnim = new Map();

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
 * cell.
 *
 * Turn-end frames never reach here: drawGame hands those to the cinematic,
 * which owns the eat/fall/refill animations and adopts the grid when it is done.
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
      cellAnim.set(flat, { kind: "flash", dur: FIELD.flashS, t: FIELD.flashS });
    } else {
      // A refilled hole, or any other replacement, sliding in from above.
      cellAnim.set(flat, { kind: "drop", dur: FIELD.dropS, t: FIELD.dropS });
    }
  }
  prevGrid = grid.slice();
  stampedThisFrame.clear();
}

/** Advance queued cell animations, dropping the finished ones. */
function tickGridAnims(dt) {
  for (const [flat, a] of cellAnim) {
    a.t -= dt;
    if (a.t <= 0) cellAnim.delete(flat);
  }
}

/** How far a queued cell animation has run, 0 → 1. */
function animProgress(anim) {
  return 1 - anim.t / anim.dur;
}

/**
 * Draw the slime field: recessed sockets, one gel tile per slime unit, and the
 * reservoir readout — units still queued off-grid, which refill emptied cells
 * from the right edge.
 *
 * While the feast cinematic runs, the BOARD DRAWN IS THE CINEMATIC'S, not the
 * frame's: the replay is mid-way between two server boards, so the frame's grid
 * is the future.  Every aiming overlay (cast preview, nibble hatching,
 * cursors) is suppressed for the same reason — they answer
 * questions about a board that is not on screen, and input is dead anyway.
 */
function drawSlimeField(game) {
  const { rows, cols } = gridDims(game);
  const replay = cinematicBoard();
  const grid = replay ?? game.grid ?? [];
  const g = gridRect(rows, cols);
  const t = performance.now() / 1000;

  // Paper first: the tiles' own white cards dissolve into it (see
  // FIELD.paper), leaving just the line art — the badge's e-paper face.
  rect(FIELD.x0, FIELD.y0, FIELD.x1 - FIELD.x0, FIELD.y1 - FIELD.y0,
    FIELD.paper);

  // Cells the wheel selections would cover if everyone cast now, what each
  // becomes, and WHOSE stamp covers it (outline in the owner's seat color:
  // solid = live aim, dotted = locked in).  `owners` is the WHOLE footprint
  // — covered-but-inert cells (already-defused slime, empty ground) included
  // — so the stamp's shape renders unbroken; `cells` holds only the
  // outcomes, for the tint.  Exact, not a guess: placement is a pure
  // function of (shape, cursor).  Computed once per frame.
  const pv = replay || playSuspended()
    ? { cells: new Map(), owners: new Map() }
    : shapePreview(game);
  const preview = pv.cells;
  const previewOwners = pv.owners;
  // Only LIVE aim pulses ("not yet resolved"); locked-in outlines hold
  // steady — a commitment is a fact, not a question.
  let anyLive = false;
  for (const o of previewOwners.values()) {
    if (!o.pending) { anyLive = true; break; }
  }
  const pulse = anyLive
    ? FIELD.previewAlphaMin + (FIELD.previewAlphaMax - FIELD.previewAlphaMin) *
    (0.5 + 0.5 * Math.sin(t * Math.PI * 2 * FIELD.previewPulseHz))
    : 0;

  // Cells drawn with the INVERTED tile art: covered by the cast preview, or
  // under any player's cursor (the crosshair still says whose).  Suppressed
  // with the rest of the aiming overlays during the replay.
  const cursorCells = new Set();
  if (!replay && !playSuspended()) {
    for (const e of game.entities ?? []) {
      cursorCells.add((e.cursor_row ?? 0) * cols + (e.cursor_col ?? 0));
    }
  }

  // What the NEXT bite will do, on THIS board and on the board the pending
  // cast would create.  A cell that would be nibbled now but consumed after
  // — `opened` — is the payoff of the cast, and it is almost never the cell
  // being aimed at, so nothing else on screen can show it.
  const reach = replay
    ? { eaten: new Set(), nibbled: new Set() }
    : reachability(game);
  const after = preview.size > 0
    ? reachability(game, new Map([...preview].map(([f, b]) => [f, b])))
    : reach;
  const opened = new Set();
  for (const flat of reach.nibbled) {
    if (after.eaten.has(flat)) opened.add(flat);
  }
  // The bite strip: the columns the turn-end feast will chew, marked so the
  // team always knows what front they are defending.
  const biteCols = replay ? 0 : feastWidth(game, cols);

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

    // The bite strip: a faint wash over the columns the turn-end feast will
    // chew.  Drawn under the tile, so it reads as marked GROUND.
    if (flat % cols < biteCols) {
      rect(x0 + inset, y0 + inset, body, body,
        withAlpha(C_SHELTERED, FIELD.biteStripAlpha));
    }

    // A hazard the coming bite will NIBBLE — hunger spent for no score: a
    // cold hatch across the socket, brightened to green where the pending
    // cast would defuse it in time to be consumed instead.
    if (reach.nibbled.has(flat)) {
      drawNibbleMark(x0, y0, inset, body,
        opened.has(flat) ? FIELD.openedAlpha : FIELD.shelteredAlpha,
        opened.has(flat) ? C_SLIME_HDR : C_SHELTERED);
    }

    const anim = cellAnim.get(flat);

    // A popping tile bursts outward over its socket; its replacement (below)
    // drops in behind it.
    if (anim?.kind === "pop") {
      const p = animProgress(anim);           // 0 → 1
      drawTile(anim.from, x0, y0, g.cell, 1 + p * 0.3, 0, 1 - p);
    }

    // Projected footprint.  `coveredBy` marks EVERY covered cell — inert
    // ones (already-defused slime, empty ground) included — so the stamp's
    // whole shape reads; `becomes` exists only where the stamp changes
    // something and drives the outcome-colored socket tint.
    const becomes = preview.get(flat);
    const coveredBy = previewOwners.get(flat);
    if (becomes !== undefined) {
      rect(x0 + inset, y0 + inset, body, body,
        withAlpha(becomesColor(becomes), FIELD.previewFillAlpha));
    }

    const name = grid[flat];
    if (!cellIsSlime(name)) {
      // Empty cell: the footprint outline is all there is to draw — and
      // covering empty ground still shows, which is exactly the aiming
      // mistake worth seeing.
      if (coveredBy !== undefined) {
        drawPreviewMark(x0, y0, inset, body, coveredBy, pulse);
      }
      continue;
    }

    let scale = 1;
    let dy = 0;
    let dx = 0;
    if (anim?.kind === "drop" || anim?.kind === "pop") {
      // Fall in from `cells` rows above (one, unless the cinematic set a real
      // fall distance), easing out, with a landing squash.
      const p = animProgress(anim);
      const ease = 1 - (1 - p) * (1 - p);
      dy = -(1 - ease) * g.cell * (anim.cells ?? 1);
      scale = 1 + Math.sin(p * Math.PI) * 0.08;
    } else if (anim?.kind === "slide") {
      // The conveyor: slide in from `cells` columns to the RIGHT (the shift
      // packing left, or the refill entering at the right edge), easing out.
      const p = animProgress(anim);
      const ease = 1 - (1 - p) * (1 - p);
      dx = (1 - ease) * g.cell * (anim.cells ?? 1);
      scale = 1 + Math.sin(p * Math.PI) * 0.06;
    } else {
      // Idle: every cell breathes on its own stable phase.
      scale = 1 + Math.sin(t * FIELD.bobFreq + bobPhase(flat)) * FIELD.bobAmp;
    }

    // Selected cells (covered by a stamp or under a cursor) swap to the
    // inverted tile art — already-defused slime inverts too, so the stamp's
    // shape stays unbroken over cells it would not change.
    drawTile(name, x0 + dx, y0, g.cell, scale, dy, 1,
      coveredBy !== undefined || cursorCells.has(flat));

    // Footprint outline in the owner's seat color (solid = live aim, dotted
    // = locked in), at the socket edge — outside the tile body, so it is
    // never confused with the tile's own art.  The OUTCOME survives in the
    // socket tint and the inverted tile.
    if (coveredBy !== undefined) {
      drawPreviewMark(x0, y0, inset, body, coveredBy, pulse);
    }

    // Downgrade flash: a white bloom over the settled tile.
    if (anim?.kind === "flash") {
      const p = animProgress(anim);
      ctx.save();
      ctx.globalAlpha = (1 - p) * 0.8;
      rect(x0 + inset, y0 + inset, body, body, "rgba(255,255,255,1)");
      ctx.restore();
    }

    // Agent-block ring: a violet border flashed on a cell the swallowed
    // neutralizer's 3x3 just downgraded, fading as the next cell lands —
    // the block sweeping its footprint one square at a time.
    if (anim?.kind === "ring") {
      const p = animProgress(anim);
      ctx.save();
      ctx.globalAlpha = 1 - p;
      ctx.strokeStyle = SPECIAL_COLOR;
      ctx.lineWidth = 3;
      ctx.strokeRect(x0 + inset, y0 + inset, body, body);
      ctx.restore();
    }
  }

  // Locked-in casts, then cursors, so aim is never buried under a tile.
  // Both hidden during the replay: nobody can aim while the feast plays out,
  // and the pending list is already empty by then.
  if (!replay) {
    drawPendingMarks(game, g, cols);
    drawCursors(game, g, cols);
  }

  rectStroke(FIELD.x0, FIELD.y0, FIELD.x1 - FIELD.x0, FIELD.y1 - FIELD.y0, 1,
    FIELD.border);

}

/** The color standing for a projected outcome tier ("defused" has no tier). */
function becomesColor(becomes) {
  return becomes === "defused" ? SHAPE_COLOR : (TIER_COLOR[becomes] ?? SHAPE_COLOR);
}

/**
 * Outline one previewed cell in its owner's seat color.  SOLID = live aim
 * (still moving, so it pulses); DOTTED = locked in (a fact, drawn steady at
 * full preview alpha).  The cell's OUTCOME shows in the socket tint and the
 * inverted tile art, not here.
 *
 * @param {{owner: number, pending: boolean}} mark  the cell's covering stamp
 */
function drawPreviewMark(x0, y0, inset, body, mark, pulse) {
  ctx.save();
  ctx.globalAlpha = mark.pending ? FIELD.previewAlphaMax : pulse;
  ctx.strokeStyle = playerColor(mark.owner);
  ctx.lineWidth = FIELD.previewWidth;
  if (mark.pending) ctx.setLineDash([FIELD.previewWidth, FIELD.previewWidth]);
  ctx.strokeRect(x0 + inset, y0 + inset, body, body);
  ctx.restore();
}

/**
 * Hatch one cell the coming bite will only NIBBLE.
 *
 * Diagonal strokes, not a tint: a tint would read as another outcome colour
 * and compete with the cast preview, whereas hatching reads as "crossed out"
 * at any density.  Callers brighten it to green for cells the pending cast
 * would convert into a meal, which is the same mark saying the opposite
 * thing — deliberately, since it is the same fact either way.
 */
function drawNibbleMark(x0, y0, inset, body, alpha, color) {
  ctx.save();
  // Clip first: the strokes are drawn as full-length diagonals and trimmed to
  // the socket, which keeps the hatch spacing identical in every cell.
  ctx.beginPath();
  ctx.rect(x0 + inset, y0 + inset, body, body);
  ctx.clip();
  ctx.strokeStyle = withAlpha(color, alpha);
  ctx.lineWidth = 1;
  ctx.beginPath();
  const step = body / 4;
  for (let d = -body; d < body; d += step) {
    ctx.moveTo(x0 + inset + d, y0 + inset);
    ctx.lineTo(x0 + inset + d + body, y0 + inset + body);
  }
  ctx.stroke();
  ctx.restore();
}

/**
 * Draw every player's aim cursor as a square outline bracketing their cell,
 * SOLID in that player's seat color — dotted is reserved for locked-in
 * stamps, and a cursor is always live.  The viewer's own is thicker and
 * drawn last, on top of anyone sharing the cell.
 *
 * The server sends a live cursor for EVERY player, so teammates can see where
 * each other are aiming and coordinate a team shape.  Drawn at the CELL edge,
 * outside the socket, so it never merges with the footprint outline at the
 * socket edge when both land on the same cell.
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
    if (isOwn) { own.push({ x0, y0, owner: e.owner }); continue; }
    drawCursorBox(x0, y0, g.cell, FIELD.cursorMateWidth, playerColor(e.owner));
  }
  for (const o of own) {
    drawCursorBox(o.x0, o.y0, g.cell, FIELD.cursorWidth, playerColor(o.owner));
  }
}

/**
 * Mark every square with a cast LOCKED IN on it: one solid pip per cast, in a
 * row along the bottom of the cell.
 *
 * This is the turn's only public record before it resolves — the whole reason
 * a teammate can plan a group at all — so it is drawn for every player's
 * casts, not just the viewer's, and it is deliberately unlike the cursor: a
 * cursor is where somebody is looking, a pip is what they have already done.
 */
function drawPendingMarks(game, g, cols) {
  const bySquare = new Map();
  for (const pc of game.pending ?? []) {
    const list = bySquare.get(pc.square);
    if (list === undefined) bySquare.set(pc.square, [pc]); else list.push(pc);
  }

  const r = g.cell * FIELD.pendingDotFrac;
  const gap = g.cell * FIELD.pendingDotGap;
  for (const [square, list] of bySquare) {
    const cx = g.x0 + (square % cols) * g.cell + g.cell / 2;
    const cy = g.y0 + Math.floor(square / cols) * g.cell + g.cell - r * 2;
    const span = list.length * r * 2 + (list.length - 1) * gap;
    let x = cx - span / 2 + r;
    for (const pc of list) {
      ctx.save();
      ctx.fillStyle = playerColor(pc.player_id);
      ctx.beginPath();
      ctx.arc(x, cy, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
      x += r * 2 + gap;
    }
  }
}

/** A square outline bracketing one cell, solid in the owner's seat color
 *  (dotted means "locked in" and a cursor never is).  Inset by half the
 *  stroke so the line stays inside the cell instead of bleeding into its
 *  neighbours. */
function drawCursorBox(x0, y0, cell, lineW, color) {
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = lineW;
  ctx.strokeRect(x0 + lineW / 2, y0 + lineW / 2, cell - lineW, cell - lineW);
  ctx.restore();
}

/**
 * Blit one cached tile into the cell at (x0, y0), scaled about the cell centre
 * and offset vertically by `dy` (animation).  `alpha` < 1 fades it out.
 * `selected` draws the inverted tile art (cast preview / cursor coverage).
 */
function drawTile(name, x0, y0, cell, scale, dy, alpha, selected = false) {
  const sprite = tileSprite(name, Math.round(cell), selected);
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
// Lil Guys (cosmetic bodies: the turn-end bite, dramatised)
// ---------------------------------------------------------------------------
//
// The Lil Guys are NOT simulated.  The server has no Lil Guy entities: their
// one mechanical trace is the HEADCOUNT, which widens the bite (see
// feastWidth).  Everything here is animation over the `turn_ended` fact.
//
// One guy is shown per connected player (read off `game.entities`, which the
// server already sends for the wheel panel).  They STAND at the left edge of
// the field — the mouths the conveyor feeds into, so where they stand is a
// true statement about where every meal happens.  They never walk the board:
// when a `turn_ended` arrives the feast cinematic (below) chews the front
// columns while the guys chomp in place at their posts (the babies do the
// running — see tickBabies).
//
// Because they are cosmetic, a guy's position is a display choice and can be
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

/**
 * The sprite box for a Lil Guy: 1.5 slime blocks, whatever cell size the
 * grid currently letterboxes to — the guys stay proportioned to the food
 * they eat instead of towering over a dense board or drowning on a sparse
 * one.
 */
function lilGuySize(rows, cols) {
  return gridRect(rows, cols).cell * LAYOUT.lilGuys.scale;
}

/**
 * The door post for roster position `i` of `count`: a sprite top-left pixel
 * position fully LEFT of the grid — the mouths the conveyor feeds into, with
 * `doorGap` of clearance so the corral never overlaps the first column of
 * cells — spread evenly down the grid's height so the crew reads as a queue
 * at the door rather than a stack.  Clamped on-screen for the degenerate
 * grid that fills the field wall to wall.
 */
function lilGuyPost(i, count, rows, cols) {
  const size = lilGuySize(rows, cols);
  const g = gridRect(rows, cols);
  const cy = g.y0 + ((i + 0.5) * rows * g.cell) / Math.max(1, count);
  return {
    x: Math.max(4, g.x0 - size - LAYOUT.lilGuys.doorGap),
    y: cy - size / 2,
  };
}

/**
 * Ensure a view exists for every connected player, drop the departed, and hand
 * the surviving views back in `game.entities` order.
 *
 * Shared by the idle milling below and the cinematic, which needs the same
 * roster to hand out the bite script.
 *
 * @param {number[]} spawnAt - flat index each new guy should appear standing on,
 *   by roster position.  A guy is born on its cell rather than sprinting in from
 *   a stale corner of the field.
 */
function syncLilGuys(game, spawnAt) {
  const { rows, cols } = gridDims(game);
  const size = lilGuySize(rows, cols);
  const players = (game.entities ?? []).filter((e) => e.owner !== undefined);

  const live = new Set(players.map((e) => e.owner));
  for (const pid of lilGuys.keys()) {
    if (!live.has(pid)) lilGuys.delete(pid);
  }

  return players.map((e, i) => {
    const existing = lilGuys.get(e.owner);
    if (existing) return existing;
    const seat = spawnAt[i];
    let at;
    if (seat !== undefined && seat !== null) {
      const c = cellCenter(seat, rows, cols);
      at = { x: c.x - size / 2, y: c.y - size / 2 };
    } else {
      // No seat (idle): born at the door, which is where an idle guy stands.
      at = lilGuyPost(i, players.length, rows, cols);
    }
    const g = {
      x: at.x,
      y: at.y,
      target: seat ?? null,
      facingLeft: false,
      pendingClip: null,
      id: LIL_GUY_ANIM_BASE + e.owner,
    };
    lilGuys.set(e.owner, g);
    return g;
  });
}

/**
 * Step one guy toward the pixel position (tx, ty) for at most `dt` seconds.
 *
 * Arrival is resolved WITHIN the slice that reaches the target rather than on
 * the frame after: the cinematic walks a queue of cells against a wall-clock
 * budget, and a frame spent standing still at each one is a frame the budget
 * did not account for — over a full board that is most of a second.
 *
 * @returns {{arrived: boolean, left: number}} `left` is the unused remainder of
 *   `dt` once it arrived, for the caller to spend on what comes next.
 */
function walkLilGuyTo(g, tx, ty, speed, dt) {
  const G = LAYOUT.lilGuys;
  const dx = tx - g.x, dy = ty - g.y;
  const dist = Math.hypot(dx, dy);
  const reach = speed * dt;
  if (dist <= G.snap || dist <= reach) {
    g.x = tx;
    g.y = ty;
    if (dist > 0) g.facingLeft = dx < 0;
    return { arrived: true, left: dt - Math.min(dt, dist / speed) };
  }
  g.x += (dx / dist) * reach;
  g.y += (dy / dist) * reach;
  g.facingLeft = dx < 0;
  return { arrived: false, left: 0 };
}

/** Walk one guy back to their door post; face the field once parked. */
function walkLilGuyHome(g, i, count, rows, cols, dt) {
  const post = lilGuyPost(i, count, rows, cols);
  g.target = null;
  const walk = walkLilGuyTo(g, post.x, post.y, LAYOUT.lilGuys.speed, dt);
  // Parked at the door: face the field the conveyor feeds them from, not
  // the wall it happened to approach from.
  if (walk.arrived) g.facingLeft = false;
  return walk;
}

/**
 * Advance the Lil Guys one frame: everyone stands (or files back to) their
 * door post on the field's left edge.  They never leave it — the bite comes
 * to THEM — so this runs during the cinematic too; the eat stage just makes
 * them chomp in place (see biteAt).
 */
function tickLilGuys(game, dt) {
  const { rows, cols } = gridDims(game);
  syncLilGuys(game, []).forEach((g, i, all) => {
    void walkLilGuyHome(g, i, all.length, rows, cols, dt);
  });
}

function drawLilGuys(game, dt) {
  const { rows, cols } = gridDims(game);
  const size = lilGuySize(rows, cols);
  for (const g of lilGuys.values()) {
    drawSprite(g.id, LIL_GUY_SPRITE, g.x, g.y, size, size, g.pendingClip,
      dt, g.facingLeft);
    g.pendingClip = null; // one-shot: the animator owns the clip from here
  }
}

// ---------------------------------------------------------------------------
// The feast cinematic: the turn-end bite, played out
// ---------------------------------------------------------------------------
//
// The server does the whole turn end in ONE tick — bite the front columns,
// slide the survivors left, refill from the right — and sends only the
// finished board plus a `turn_ended` event.  Shown as sent it is a jump cut:
// the board the player aimed at is simply replaced.
//
// So the client replays it.  It has both boards (`prevGrid` before, the frame's
// grid after), the rules (the bite mirrored in biteFeast, the shift and the
// match effects mirrored below), and the per-pass refill events — the one step
// only the server's PRNG knows.  A synthetic `board` is drawn instead of the
// frame's grid until the replay lands exactly on it.  Each settle PASS plays:
//
//   eat      — the front columns are chewed cell by cell in the server's
//              walk order (the Lil Guys chomp at their posts, the babies
//              sprint the strip); consumed cells pop, nibbled hazards flash
//              a tier softer in place; the board changes mid-meal only
//              where the server's did (a swallowed neutralizer's block, a
//              bomb's blast)
//   collapse — survivors pack LEFT along their rows: the conveyor advances
//   fill     — the pass's refill event slides in from the RIGHT edge
//   matchFx  — the pass's special matches pop and fire their effects
//
// A pass that matched RE-OPENED the feast, so the next pass's eat begins; the
// pass that matched nothing is the last, and the replay lands.
//
// The replay is authoritative about NOTHING: it starts from a server board and
// ends on a server board, and every intermediate step is derived from the same
// rules the server used.  A survivor that does not match the server's board at
// the end means a rule drifted, and the replay snaps to the server instead of
// arguing (see finishFill).
//
// It is also a deliberate pause in play: input is dead for its duration
// (see the keydown handler), because the board on screen is mid-replay and
// aiming at it would mean nothing.

/**
 * @typedef {object} Cinematic
 * @property {"eat"|"midEffect"|"collapse"|"fill"|"matchFx"} stage
 *   — `midEffect` is a swallowed neutralizer's block landing one cell at a
 *   time on the STANDING board; it pauses the meal, which resumes after
 * @property {number} rows
 * @property {number} cols
 * @property {string[]} board  - what is DRAWN: the replay's current board
 * @property {string[]} target - the server's post-settle board, adopted at the end
 * @property {number} pass     - the settle pass now playing (0-based)
 * @property {number} passes   - passes the server's settle took (turn_ended)
 * @property {Map<number, object>} refillsByPass - pass → its refill event
 * @property {Map<number, object[]>} matchesByPass - pass → its match events
 * @property {object} frame    - the freshest render frame (entity roster for
 *   the chompers)
 * @property {number[]} script - bite POSITIONS (consumed AND nibbled) in the
 *   server's column-major walk order.  Bites are strictly sequential, so the
 *   meal is a single global script.
 * @property {Map<number, number[]>} settles - neutralizer blocks owed after
 *   each script index (see biteFeast); each pauses the meal and plays as
 *   midEffect
 * @property {number[]} settleQueue - the current bite's blocks still to
 *   play (each the swallowed neutralizer's cell)
 * @property {number|null} pendingEffect - the 3x3 center midEffect is
 *   landing cell by cell
 * @property {number[]} effectCells - the pending block's covered cells, in
 *   the server's row-major application order
 * @property {number} effectIdx - the next effectCells entry to apply
 * @property {number} biteIdx - the next script entry to take
 * @property {number} holdT   - chomp pause remaining after the last bite
 * @property {number} chompS   - per-bite pause, fitted so the whole meal
 *   lands between eatMinS and eatCapS
 * @property {number} t        - seconds left in a timed stage (collapse, fill)
 * @property {{score: number, hunger: number, stamps: object[]}} deferred - things
 *   the server already applied, held back until the screen catches up: the feast's
 *   score and hunger (paid when the eating finishes) and any casts that landed
 *   mid-replay (floated when it ends, over the board they actually apply to)
 * @property {{eaten: number, bitten: number}} tally - the headline numbers,
 *   floated when the replay ends
 */

/** The replay in progress, or null.  At most one runs at a time. */
let cinematic = null;

/** The board to DRAW instead of the frame's grid, or null when not replaying. */
function cinematicBoard() {
  return cinematic ? cinematic.board : null;
}

/** True while the feast is being replayed — the window in which input is dead. */
function cinematicActive() {
  return cinematic !== null;
}

/**
 * True while the board is on screen but not playable: the feast replay, or the
 * end-of-match outro behind it (see `outroActive`).
 *
 * Every affordance the board offers — the cast preview, the cells it would
 * cover, the casts-left line — is a promise that pressing a key will do
 * something.  In both of these windows nothing will, so the promise has to come
 * off the screen rather than be quietly broken.  The keydown handler drops the
 * same two cases, and that is not a coincidence: this predicate is the visible
 * half of that one.
 */
function playSuspended() {
  return cinematicActive() || outroActive();
}

/**
 * Begin replaying the feast announced by `game.turn_ended`.
 *
 * @param {object} game - the render frame carrying the event (and the board the
 *   feast produced)
 * @returns {boolean} true when a replay started; false when the frame cannot be
 *   replayed (no previous board to replay FROM, e.g. the first frame of a match,
 *   or a board whose dimensions just changed), in which case the caller shows
 *   the server's board as sent.
 */
function startFeastCinematic(game) {
  const te = game.turn_ended;
  const { rows, cols } = gridDims(game);
  const target = (game.grid ?? []).slice();
  const tally = {
    eaten: te?.cells_eaten ?? 0,
    bitten: te?.hazards_bitten ?? 0,
  };

  // A replay in flight when another turn ends: possible, since a player out of
  // casts is not waiting on their own input.  Land the old one on its board
  // first — half a meal is not a state to start a second one from.
  if (cinematic) snapFinishCinematic();

  // Any cast on this frame is folded into the board the replay starts from
  // (below) and bloomed there, so the covered set has been spent: leaving it for
  // the next diff would have those cells read as downgrades a second time.
  stampedThisFrame.clear();

  const before = prevGrid;
  if (before.length !== target.length || target.length !== rows * cols) {
    //spawnFeastTallyFloaters(tally);
    return false;
  }

  const board = before.slice();
  // The cast that ENDED the turn resolved in the same server tick as the feast,
  // so `prevGrid` predates it: the meal has to start from the board that cast
  // produced or the bite chews a front the server never saw.  Replayed the way
  // the server applied them — in event order, each stamp stepping a cell down
  // again — and clipped identically, since the cell lists arrive pre-clipped.
  for (const ev of game.shape_casts ?? []) {
    for (const flat of ev.cells ?? []) {
      const next = downgradeName(board[flat]);
      if (next === null) continue;
      board[flat] = next;
      // Bloom it, as any downgrade does: the last cast of a turn is the one most
      // worth seeing land, and the replay starts on the board it made.
      cellAnim.set(flat, { kind: "flash", dur: FIELD.flashS, t: FIELD.flashS });
    }
  }

  // The turn settled in PASSES: matches re-open the feast, so the server ran
  // eat/collapse/fill/match until no match fired, and sent the per-pass data
  // the replay cannot derive — each pass's refill (PRNG) — plus each match.
  // Everything else (bites, slides, the 5x5s) is mirrored rules, so the
  // replay walks the whole cascade exactly.
  const refillsByPass = new Map();
  for (const fr of game.refills ?? []) refillsByPass.set(fr.pass, fr);
  const matchesByPass = new Map();
  for (const sm of game.special_matches ?? []) {
    const list = matchesByPass.get(sm.pass ?? 0);
    if (list === undefined) matchesByPass.set(sm.pass ?? 0, [sm]);
    else list.push(sm);
  }
  const passes = Math.max(1, te?.passes ?? 1);

  cinematic = {
    stage: "eat",
    rows, cols,
    board,
    target,
    pass: 0,
    passes,
    refillsByPass,
    matchesByPass,
    frame: game,
    script: [],
    settles: new Map(),
    settleQueue: [],
    pendingEffect: null,
    effectCells: [],
    effectIdx: 0,
    biteIdx: 0,
    holdT: 0,
    chompS: LAYOUT.cinematic.chompPauseS,
    t: 0,
    deferred: { score: 0, hunger: 0, stamps: [] },
    tally,
  };

  const ate = armEatPass(game);
  if (ate) {
    const { x, y } = fieldCenter();
    // Ink, not the light cast-event cyan: this headline floats over the paper
    // field, where light colors vanish.
    spawnFloater("Lil Guys Eating!", x, y - LAYOUT.floater.stack - 8,
      "rgba(40,36,60,0.95)", LAYOUT.floater.lifetime, LAYOUT.floater.recipeFont);
  }
  return true;
}

/**
 * Arm the current pass's eat stage: bite the replay board with the mirrored
 * rules and fit the per-bite hold so the whole meal lands between eatMinS
 * and eatCapS.
 *
 * Nobody walks: the Lil Guys chomp in place at their posts and the babies
 * sprint the bite strip (see tickBabies), so the pacing is purely the holds.
 *
 * Returns true when an eat stage was armed; false when there was nothing to
 * chew, in which case the replay goes straight to the slide.  No headline in
 * that case: announcing an eat stage that is never played is the one thing
 * worse than showing nothing.
 */
function armEatPass(game) {
  const c = cinematic;
  const { rows, cols } = c;
  const C = LAYOUT.cinematic;
  const feast = biteFeast(c.board, rows, cols, feastWidth(game, cols));

  c.script = feast.order;
  c.settles = feast.settles;
  c.biteIdx = 0;
  c.holdT = 0;
  syncLilGuys(game, []);

  const bites = feast.order.length;
  if (bites === 0) {
    beginShift();
    return false;
  }
  // Every bite is one hold, so the meal's wall clock is bites × chompS:
  // stretched on a small meal (the bites ARE the animation) and shortened on
  // a wide one so the pause never scales past the cap.
  c.chompS = Math.min(Math.max(C.chompPauseS, C.eatMinS / bites), C.eatCapS / bites);
  c.stage = "eat";
  return true;
}

/**
 * The frame step the BOARD advances by: clamped while the feast is replaying.
 *
 * requestAnimationFrame stops firing in a hidden tab, so returning to one
 * delivers a single frame carrying the whole absence.  Spending it would eat the
 * meal in one step — the jump cut the replay exists to avoid — so time the player
 * was not watching is not time the feast ran.  The replay takes longer in
 * wall-clock terms, which is right: it is a cutscene, not a simulation chasing a
 * clock.
 *
 * The clamp covers the queued cell animations too, since the replay's stage
 * timers and its falling tiles have to stay in lockstep or tiles land before (or
 * after) the stage that owns them.
 */
function boardStep(dt) {
  return cinematic ? Math.min(dt, LAYOUT.cinematic.maxStepS) : dt;
}

/** Advance the replay one frame.  Drives the Lil Guys for its duration. */
function tickCinematic(game, dt) {
  if (!cinematic) return;
  // The freshest frame, for the entity roster the next pass's queues need.
  cinematic.frame = game;
  switch (cinematic.stage) {
    case "eat": tickEat(game, dt); break;
    case "midEffect":
      tickLilGuys(game, dt);
      tickMidEffect(dt);
      break;
    case "collapse":
      // This pass's meal is over: the conveyor advances (survivors pack
      // left) while the crew holds its posts.
      tickLilGuys(game, dt);
      cinematic.t -= dt;
      if (cinematic.t <= 0) beginFillPass();
      break;
    case "fill":
      tickLilGuys(game, dt);
      cinematic.t -= dt;
      if (cinematic.t <= 0) beginMatchFx();
      break;
    case "matchFx":
      tickLilGuys(game, dt);
      cinematic.t -= dt;
      if (cinematic.t <= 0) nextPassOrFinish();
      break;
  }
}

/**
 * One frame of the eat stage.
 *
 * Bites are strictly SEQUENTIAL, paced by the fitted per-bite hold; each one
 * lands on the next scripted cell — consumed or nibbled — while the Lil Guys
 * chomp in place at their posts and the babies sprint the strip.
 */
function tickEat(game, dt) {
  const c = cinematic;

  // The crew never leaves the door: keep them filed at their posts.
  tickLilGuys(game, dt);

  let left = dt;
  while (left > 0 && c.biteIdx < c.script.length) {
    if (c.holdT > 0) {
      const used = Math.min(left, c.holdT);
      c.holdT -= used;
      left -= used;
      continue;
    }
    const flat = c.script[c.biteIdx];
    biteAt(game, flat);
    c.holdT = c.chompS;
    c.biteIdx++;
    // A block owed on this bite PAUSES the meal: it lands cell by cell on
    // the standing board, and only then does the next bite get looked for.
    // The rest of the frame's slice is forfeit — a pause is a pause.
    if (pauseForSettles(c.biteIdx - 1)) return;
  }

  // The last bite's hold is still owed once the script is spent: drain it —
  // without waiting it out the final cell would pop and the board slide in
  // the same frame, and a one-cell meal would be over before it was seen.
  if (c.biteIdx >= c.script.length && c.holdT > 0) {
    c.holdT = Math.max(0, c.holdT - dt);
  }

  if (c.biteIdx >= c.script.length && c.holdT <= 0) {
    finishEat();
  }
}

/**
 * One bite lands on `flat`: a hazard is NIBBLED (one tier softer, in place),
 * anything edible is consumed via `bite`.  Either way the nearest mouths
 * react — the Lil Guy whose post row is closest chomps in place, and the
 * baby sprinting nearest puffs.
 */
function biteAt(game, flat) {
  const c = cinematic;
  const name = c.board[flat];
  const at = cellCenter(flat, c.rows, c.cols);

  if (hazardTier(name) !== null) {
    // The NIBBLE: the survivor steps one tier in place and blooms.  No
    // score triangle — a nibble feeds nobody.
    c.board[flat] = downgradeName(name);
    cellAnim.set(flat, { kind: "flash", dur: FIELD.flashS, t: FIELD.flashS });
    lastBitePos = at;
    chompNearestMouths(game, flat);
    return;
  }

  bite(flat);
  chompNearestMouths(game, flat);
}

/** Play the chomp on the mouths nearest the bitten cell: the Lil Guy whose
 *  post row is closest snaps its attack clip, and the nearest sprinting baby
 *  puffs.  Purely visual — the bite itself already landed. */
function chompNearestMouths(game, flat) {
  const c = cinematic;
  const at = cellCenter(flat, c.rows, c.cols);

  let bestGuy = null;
  let bestD = Infinity;
  for (const g of lilGuys.values()) {
    const d = Math.abs(g.y - at.y);
    if (d < bestD) { bestD = d; bestGuy = g; }
  }
  if (bestGuy !== null) bestGuy.pendingClip = "attack";

  let bestBaby = null;
  bestD = Infinity;
  for (const b of babyViews) {
    const d = Math.abs(b.y - at.y);
    if (d < bestD) { bestD = d; bestBaby = b; }
  }
  if (bestBaby !== null) bestBaby.chompT = BABY_CHOMP_S;

  spawnFloater("chomp", at.x, at.y - LAYOUT.floater.stack,
    "rgba(40,36,60,0.85)", 0.8); // ink, not white: it floats over the paper field
}

/**
 * Consume one cell: it leaves the replay's board and bursts where it stood.
 */
function bite(flat) {
  const c = cinematic;
  const was = c.board[flat];
  c.board[flat] = "empty";
  cellAnim.set(flat, { kind: "pop", dur: FIELD.popS, t: FIELD.popS, from: was });

  // Every eaten cell is a score unit: send its golden triangle to the HUD.
  // (Bomb-levelled neighbours below are DESTROYED, not eaten — no triangle.)
  if (was && was !== "empty") {
    const sp = cellCenter(flat, c.rows, c.cols);
    spawnFlyTri(sp.x, sp.y);
    lastBitePos = sp;
  }

  // A swallowed canister pours its agent energy back into the team pool —
  // the server already credited it; this is the on-board receipt.
  if (was === "special_canister") {
    const fx = cellCenter(flat, c.rows, c.cols);
    spawnFloater("agent refilled!", fx.x, fx.y - LAYOUT.floater.stack,
      CANISTER_COLOR, 0.9);
  }

  // A swallowed bomb levels its 3x3 the moment it goes down — MIRRORS the
  // server's inline blast, so the replay board opens exactly where the
  // walk continues.  Destroyed tiles burst where they stood.
  if (was === "special_bomb") {
    detonateOn(c.board, flat, c.rows, c.cols, (cell, name) => {
      cellAnim.set(cell, { kind: "pop", dur: FIELD.popS, t: FIELD.popS, from: name });
    });
    const fx = cellCenter(flat, c.rows, c.cols);
    spawnFloater("BOOM!", fx.x, fx.y - LAYOUT.floater.stack, BOMB_COLOR, 0.9);
  }
}

/**
 * Pause the meal on the neutralizer blocks owed after bite `idx`, if any.
 * Queues them and enters the midEffect stage; returns true when the meal
 * paused (the caller's eat frame is over).
 */
function pauseForSettles(idx) {
  const c = cinematic;
  const list = c.settles?.get(idx);
  if (!list || list.length === 0) return false;
  c.settleQueue = list.slice();
  nextMidSettleOrResume();
  return true;
}

/**
 * The standing board takes the pending block.  Its cells are queued in the
 * server's row-major application order and land ONE AT A TIME (see
 * tickMidEffect), each flashing a border as its downgrade lands.
 */
function beginMidEffect() {
  const c = cinematic;
  const effect = c.pendingEffect;
  c.pendingEffect = null;
  if (effect === null) {
    nextMidSettleOrResume();
    return;
  }
  c.effectCells = agentBlockCells(effect, c.rows, c.cols);
  c.effectIdx = 0;
  c.stage = "midEffect";
  c.t = 0; // the first cell lands on the next tick
  const fx = cellCenter(effect, c.rows, c.cols);
  spawnFloater("neutralized!", fx.x, fx.y - LAYOUT.floater.stack,
    SPECIAL_COLOR, 0.9);
}

/**
 * One frame of the effect stage: every `effectStepS`, the block's next cell
 * WITH SOMETHING TO DOWNGRADE takes its step — board updated, border flashed
 * — so the result of each cell is on screen before the next one lands.
 * Cells the block covers but cannot change are skipped silently.
 */
function tickMidEffect(dt) {
  const c = cinematic;
  c.t -= dt;
  if (c.t > 0) return;
  while (c.effectIdx < c.effectCells.length) {
    const cell = c.effectCells[c.effectIdx++];
    const next = downgradeName(c.board[cell]);
    if (next === null) continue;
    c.board[cell] = next;
    cellAnim.set(cell, {
      kind: "ring", dur: LAYOUT.cinematic.ringS, t: LAYOUT.cinematic.ringS,
    });
    c.t = LAYOUT.cinematic.effectStepS;
    return;
  }
  nextMidSettleOrResume();
}

/** The block in flight is done: play the next one owed on this bite, or
 *  hand the board back to the meal. */
function nextMidSettleOrResume() {
  const c = cinematic;
  if (c.settleQueue.length > 0) {
    c.pendingEffect = c.settleQueue.shift();
    beginMidEffect();
    return;
  }
  c.stage = "eat";
}

/** The strip is picked clean: pay out the deltas the meal earned, then slide. */
function finishEat() {
  beginShift();
}

/**
 * Enter the shift stage: survivors pack LEFT along their rows — the
 * conveyor's advance.
 *
 * MIRRORS slime.shift_left — per row, left-to-right, packing every occupied
 * cell against the left edge in the order it already stood in.  Slime never
 * changes lane, so a row is the whole story.  The board is updated at once
 * and the slide is a per-tile display offset over it.
 */
function beginShift() {
  const c = cinematic;
  const { rows, cols } = c;
  let longest = 0;

  shiftBoard(c.board, rows, cols, (dest, slid) => {
    cellAnim.set(dest, {
      kind: "slide", dur: LAYOUT.cinematic.collapseS,
      t: LAYOUT.cinematic.collapseS, cells: slid,
    });
    longest = Math.max(longest, slid);
  });

  c.stage = "collapse";
  c.t = longest > 0 ? LAYOUT.cinematic.collapseS : 0;
  if (c.t === 0) beginFillPass(); // nothing moved: no slide to watch
}

/**
 * Enter the fill stage: the reservoir units the server drew slide in from
 * the RIGHT edge — the far end of the conveyor.
 *
 * Which units, and where, comes from the server's own refill event — the
 * draw is the one thing in the turn end the client cannot derive, since it
 * comes out of the session's PRNG.
 *
 * The shift leaves every hole at the RIGHT end of its row, and the server
 * fills column-major from the right, so a row's refill is a contiguous run
 * of new units hanging off the field's right edge.  They slide in as ONE
 * RIGID ROW: every unit in the run travels the same distance, which is what
 * keeps them exactly one cell apart on the way in, queued in the order they
 * land.
 */
function beginFillPass() {
  const c = cinematic;
  const { rows, cols } = c;
  const S = LAYOUT.cinematic;
  let any = false;

  const fr = c.refillsByPass.get(c.pass);
  if (fr !== undefined) {
    // The server told us exactly which cells this pass filled and with what
    // — the one step of a settle the client cannot derive.  A row's new
    // units slide in as one rigid run, exactly one cell apart.
    const byRow = new Map();
    (fr.cells ?? []).forEach((flat, i) => {
      const row = Math.floor(flat / cols);
      const entry = { flat, name: fr.contents?.[i] ?? "neutral" };
      const list = byRow.get(row);
      if (list === undefined) byRow.set(row, [entry]);
      else list.push(entry);
    });
    for (const [, list] of byRow) {
      for (const { flat, name } of list) {
        c.board[flat] = name;
        cellAnim.set(flat, {
          kind: "slide", dur: S.collapseS, t: S.collapseS,
          cells: list.length,
        });
      }
      any = true;
    }
  } else {
    // No refill event (an older server): derive the pour from the target
    // board, which is only sound on a single-pass settle.  The shift leaves
    // every hole at the RIGHT end of its row and the server fills from the
    // right, so a row's refill is a contiguous run of new units.
    for (let row = 0; row < rows; row++) {
      const run = [];
      for (let col = cols - 1; col >= 0; col--) {
        const flat = row * cols + col;
        if (cellIsSlime(c.board[flat])) continue;
        // The reservoir ran dry partway across the board: this hole stays
        // open, and so does everything left of it.
        if (!cellIsSlime(c.target[flat])) break;
        run.push(flat);
      }
      if (run.length === 0) continue;

      for (const flat of run) {
        c.board[flat] = c.target[flat];
        cellAnim.set(flat, {
          kind: "slide", dur: S.collapseS, t: S.collapseS,
          cells: run.length,
        });
      }
      any = true;
    }
  }

  c.stage = "fill";
  c.t = any ? S.collapseS : 0;
  if (c.t === 0) beginMatchFx(); // nothing left to pour
}

/**
 * Enter the match stage: this pass's special matches pop and fire.
 *
 * MIRRORS field_resolve_matches: every matched cell pops first (the union —
 * a cell shared by a row and a column run pops once), then the effects land
 * in message order — the neutralizer's 5x5 downgrading exactly like a cast.
 * The server resolved the runs; the client just performs them.
 *
 * A pass with matches is exactly a pass that RE-OPENS the feast, so the
 * stage after this one is the next pass's eat.
 */
function beginMatchFx() {
  const c = cinematic;
  const events = c.matchesByPass.get(c.pass) ?? [];
  if (events.length === 0) {
    nextPassOrFinish();
    return;
  }

  for (const ev of events) {
    for (const flat of ev.cells ?? []) {
      if (c.board[flat] === "empty") continue;
      cellAnim.set(flat, {
        kind: "pop", dur: FIELD.popS, t: FIELD.popS, from: c.board[flat],
      });
      c.board[flat] = "empty";
    }
  }
  events.forEach((ev, i) => {
    for (const flat of matchBlockCells(ev.center, c.rows, c.cols)) {
      const next = downgradeName(c.board[flat]);
      if (next === null) continue;
      c.board[flat] = next;
      cellAnim.set(flat, { kind: "flash", dur: FIELD.flashS, t: FIELD.flashS });
    }
    const at = cellCenter(ev.center, c.rows, c.cols);
    const hits = sumTiers(ev.downgraded);
    const head = hits > 0
      ? `${ev.kind} match! ${hits} downgraded${(ev.neutralized ?? 0) > 0 ? `, ${ev.neutralized} defused` : ""}`
      : `${ev.kind} match!`;
    spawnFloater(head, at.x, at.y - i * LAYOUT.floater.stack, SPECIAL_COLOR,
      LAYOUT.floater.lifetime, LAYOUT.floater.recipeFont);
  });

  c.stage = "matchFx";
  // A beat to read the reaction before the feast re-opens.
  c.t = LAYOUT.cinematic.collapseS;
}

/**
 * A pass just finished settling.  A pass that MATCHED re-opened the feast, so
 * the next pass's meal begins; the pass that matched nothing was the last —
 * verify the replay landed on the server's board and stand down.
 */
function nextPassOrFinish() {
  const c = cinematic;
  const matched = (c.matchesByPass.get(c.pass) ?? []).length > 0;
  c.pass++;
  if (matched && c.pass < c.passes) {
    if (armEatPass(c.frame)) {
      const { x, y } = fieldCenter();
      spawnFloater("The feast continues!", x, y - LAYOUT.floater.stack - 8,
        "rgba(40,36,60,0.95)", LAYOUT.floater.lifetime, LAYOUT.floater.recipeFont);
    }
    return;
  }
  finishSettle();
}

/**
 * The replay has landed.  Adopt the server's board and hand the field back.
 *
 * The replay's board should now BE the server's; where it is not, a mirrored
 * rule has drifted from the server's, and the server wins without argument —
 * the whole point of replaying is that it is derivable, so a mismatch is a bug
 * to see in the console, not a board to keep.
 */
function finishSettle() {
  const c = cinematic;
  for (let flat = 0; flat < c.target.length; flat++) {
    if (c.board[flat] === c.target[flat]) continue;
    console.warn("[game] feast replay diverged from the server board at", flat,
      c.board[flat], "!=", c.target[flat]);
    break;
  }
  endCinematic();
}

/** Cut the replay short and land it on the server's board immediately. */
function snapFinishCinematic() {
  if (!cinematic) return;
  cellAnim.clear();
  // Fliers belong to the meal being cut: land them all as one arrival — a
  // single swell stands in for the flock, and drawScoreHud's idle sync snaps
  // the displayed count to the server's total on the next frame.
  if (flyTris.length > 0) {
    flyTris.length = 0;
    scoreHud.pulseT = LAYOUT.scoreHud.pulseS;
  }
  endCinematic();
}

/** Adopt the replay's target board as the new diff baseline and stand down. */
function endCinematic() {
  const c = cinematic;
  cinematic = null;
  // The baseline is the board the replay reproduced, NOT whatever the latest
  // frame holds: teammates can cast while the replay runs, and those changes
  // must still be diffed and animated on the next frame rather than adopted
  // silently here.
  prevGrid = c.target.slice();
  //spawnFeastTallyFloaters(c.tally);
  // Casts held during the replay, released now that the board they describe is
  // the one on screen.  Stacked after the tally so the headline reads first.
  c.deferred.stamps.forEach((ev, i) => floatStampOutcome(ev, i + 1, c.rows, c.cols));
  c.deferred.stamps.length = 0;
}

/**
 * The feast's headline numbers, floated once the meal is over.
 *
 * The nibbles get equal billing with the tally: every one was hunger-clock
 * spent on a cell no cast defused in time, which is the number that should
 * change how the next turn is played.
 */
function spawnFeastTallyFloaters(tally) {
  const { x, y } = fieldCenter();
  spawnFloater(`${tally.eaten} units devoured`, x, y - LAYOUT.floater.stack - 8,
    CAST_EVENT_COLOR, LAYOUT.floater.lifetime, LAYOUT.floater.recipeFont);
  if (tally.bitten > 0) {
    spawnFloater(`${tally.bitten} hazard${tally.bitten === 1 ? "" : "s"} nibbled — hunger for nothing`,
      x, y + 28, C_SHELTERED, LAYOUT.floater.lifetime, LAYOUT.floater.font);
  }
}

// ---------------------------------------------------------------------------
// Per-player action menus
// ---------------------------------------------------------------------------
//
// One menu box per SEAT — always LAYOUT.playerMenus.seats of them, with
// unfilled seats drawn as dim placeholders, so the row never reflows as
// players come and go.  Each menu shows exactly one thing: the SHAPE of the
// spell its player's wheel is currently holding, plus that player's lock-in
// state for the round.  Feedback is physical rather than textual:
//
//   pulse — the box swells once when its player locks in a VALID cast on the
//           board (a new pending cast of theirs appears on the wire)
//   shake — the box rattles when its player's attempt is REFUSED: the turn
//           cannot afford it (`over_budget`), or they are already fully
//           locked in and pressing ENTER anyway (detected locally, since the
//           server has nothing to say about a key that does nothing)

/** @typedef {{kind: "pulse"|"shake", t: number, dur: number}} MenuFx */

/** player id → running feedback animation on their menu.  @type {Map<number, MenuFx>} */
const menuFx = new Map();

/** player id → pending-cast count last frame, for lock-in detection.
 *  @type {Map<number, number>} */
let prevMenuPending = new Map();

/** The player whose committed cast is the round's most recent — their menu
 *  keeps a gentle pulse after the lock-in swell ends.  Cleared when their
 *  commitment goes away (undo, or the turn resolving).
 *  @type {number|null} */
let lastCommitPid = null;

/** Start (restarting if mid-flight) one player's menu feedback. */
function triggerMenuFx(playerId, kind) {
  const P = LAYOUT.playerMenus;
  const dur = kind === "pulse" ? P.pulseS : P.shakeS;
  menuFx.set(playerId, { kind, t: dur, dur });
}

/** Advance menu feedback animations, dropping the finished ones. */
function tickMenuFx(dt) {
  for (const [pid, fx] of menuFx) {
    fx.t -= dt;
    if (fx.t <= 0) menuFx.delete(pid);
  }
}

/**
 * Diff this frame's pending casts against the last frame's, per player.
 * A count that GREW is a lock-in the server accepted — the valid-selection
 * pulse, for whichever player's menu it was.  A count that shrank is an undo
 * or the turn resolving, neither of which is feedback-worthy: the baseline
 * just moves.  `over_budget` is sent only to the player who tried, so it
 * always shakes the viewer's own menu.
 *
 * Call once per FRESH frame (transient events must be consumed exactly once).
 */
function updateMenuFx(game) {
  const counts = new Map();
  for (const pc of game.pending ?? []) {
    counts.set(pc.player_id, (counts.get(pc.player_id) ?? 0) + 1);
  }
  // The holder's commitment went away (undo, or the turn resolved): the
  // "most recent action" marker has nothing to point at any more.
  if (lastCommitPid !== null &&
    (counts.get(lastCommitPid) ?? 0) < (prevMenuPending.get(lastCommitPid) ?? 0)) {
    lastCommitPid = null;
  }
  for (const [pid, n] of counts) {
    if (n > (prevMenuPending.get(pid) ?? 0)) {
      triggerMenuFx(pid, "pulse");
      lastCommitPid = pid;
    }
  }
  prevMenuPending = counts;

  if (game.over_budget) triggerMenuFx(game.player_id, "shake");
}

/** Draw the whole seat row: one menu per player, placeholders for the rest. */
function drawPlayerMenus(game) {
  const P = LAYOUT.playerMenus;
  const players = (game.entities ?? []).slice(0, P.seats);
  for (let seat = 0; seat < P.seats; seat++) {
    const x = P.x0 + seat * (P.w + P.gap);
    const e = players[seat];
    if (e === undefined) {
      drawEmptySeat(x, P.y, P.w, P.h);
    } else {
      drawPlayerMenu(game, e, x, P.y);
    }
  }
}

/** A seat nobody is sitting in: present (so the row reads as four chairs),
 *  but visibly hollow. */
function drawEmptySeat(x, y, w, h) {
  ctx.save();
  ctx.strokeStyle = "rgba(110,110,130,0.35)";
  ctx.lineWidth = 1;
  ctx.setLineDash([4, 4]);
  ctx.strokeRect(x + 0.5, y + 0.5, w - 1, h - 1);
  ctx.restore();
  ctx.save();
  ctx.font = `${LAYOUT.playerMenus.labelFont}px monospace`;
  ctx.fillStyle = "rgba(110,110,130,0.4)";
  ctx.textAlign = "center";
  ctx.fillText("empty", x + w / 2, y + h / 2 + 4);
  ctx.restore();
}

/** One player's menu: their held spell's shape, and their lock-in state. */
function drawPlayerMenu(game, e, x, y) {
  const P = LAYOUT.playerMenus;
  const own = e.owner === game.player_id;
  const locked = (e.casts_left ?? 0) === 0;
  const fx = menuFx.get(e.owner);

  ctx.save();
  const cx = x + P.w / 2;
  const cy = y + P.h / 2;
  if (fx) {
    if (fx.kind === "pulse") {
      // One swell and back: sin over the animation's life, peaking mid-way.
      const p = 1 - fx.t / fx.dur;
      const s = 1 + (P.pulseScale - 1) * Math.sin(p * Math.PI);
      ctx.translate(cx, cy);
      ctx.scale(s, s);
      ctx.translate(-cx, -cy);
    } else {
      // Sideways rattle, decaying to rest so it ends where it started.
      const decay = fx.t / fx.dur;
      const dx = Math.sin(fx.t * P.shakeHz * Math.PI * 2) * P.shakeAmp * decay;
      ctx.translate(dx, 0);
    }
  } else if (e.owner === lastCommitPid) {
    // The round's most recent committed action: keep breathing after the
    // lock-in swell, so the marker survives until someone else moves.
    const t = performance.now() / 1000;
    const s = 1 + (P.lastPulseScale - 1) *
      (0.5 + 0.5 * Math.sin(t * Math.PI * 2 * P.lastPulseHz));
    ctx.translate(cx, cy);
    ctx.scale(s, s);
    ctx.translate(-cx, -cy);
  }

  rect(x, y, P.w, P.h, C_MENU_BG);
  // Locked in: a solid bright frame plus a tint wash — the box itself is the
  // state, readable across the room, with the label below as confirmation.
  if (locked) rect(x, y, P.w, P.h, withAlpha(SHAPE_COLOR, 0.10));
  rectStroke(x, y, P.w, P.h, locked ? 4 : 2,
    locked ? SHAPE_COLOR : playerColor(e.owner));

  // Seat label: whose menu this is, in their color.
  ctx.font = `${P.labelFont}px monospace`;
  ctx.textAlign = "center";
  ctx.fillStyle = playerColor(e.owner);
  ctx.fillText(own ? `P${e.owner} (you)` : `P${e.owner}`, x + P.w / 2, y + P.labelDy);

  // The held spell, drawn as its shape — the same rows the field preview
  // stamps, so what the menu shows IS what ENTER lands.
  const move = PLAYER_RECIPES[e.selected_shape ?? 0] ?? PLAYER_RECIPES[0];
  const shapeTop = y + P.labelDy + 6;
  const shapeBottom = y + P.h - P.statusDy - P.statusFont - 2;
  drawSpellShape(x + P.w / 2, (shapeTop + shapeBottom) / 2,
    P.w - 20, shapeBottom - shapeTop, move?.rows ?? ["#"], locked);

  // Lock-in state for the round: pips while casts remain (the same ◆
  // language as the wheel panel), the banner once they are spent.
  const statusY = y + P.h - P.statusDy;
  if (locked) {
    ctx.fillStyle = SHAPE_COLOR;
    ctx.font = `bold ${P.statusFont}px monospace`;
    ctx.fillText("LOCKED IN", x + P.w / 2, statusY);
  } else {
    ctx.fillStyle = CAST_EVENT_COLOR;
    ctx.font = `${P.statusFont}px monospace`;
    ctx.fillText("◆".repeat(e.casts_left ?? 0), x + P.w / 2, statusY);
  }
  ctx.restore();
}

/**
 * Draw a spell's shape as a small grid of filled cells, centred on (cx, cy)
 * and fitted inside maxW×maxH.  The anchor cell — the one the cursor aims —
 * is outlined, matching the anchor bracket of the lobby guide's shape demos
 * (drawShapeDemo).  `dim` mutes the
 * fill for a menu whose player is locked in: the spell is still held, but no
 * cast of it is available this round.
 */
function drawSpellShape(cx, cy, maxW, maxH, rows, dim) {
  const P = LAYOUT.playerMenus;
  const nR = rows.length;
  const nC = rows[0]?.length ?? 0;
  if (nR === 0 || nC === 0) return;

  const gap = P.shapeCellGap;
  const cell = Math.min(
    P.shapeCellMax,
    (maxW - (nC - 1) * gap) / nC,
    (maxH - (nR - 1) * gap) / nR,
  );
  const w = nC * cell + (nC - 1) * gap;
  const h = nR * cell + (nR - 1) * gap;
  const x0 = cx - w / 2;
  const y0 = cy - h / 2;
  const anchorR = Math.floor(nR / 2);
  const anchorC = Math.floor(nC / 2);

  const fill = withAlpha(SHAPE_COLOR, dim ? 0.45 : 1);
  for (let r = 0; r < nR; r++) {
    for (let cl = 0; cl < nC; cl++) {
      const cxp = x0 + cl * (cell + gap);
      const cyp = y0 + r * (cell + gap);
      if (rows[r][cl] === "#") {
        rect(cxp, cyp, cell, cell, fill);
      } else {
        rect(cxp, cyp, cell, cell, "rgba(110,110,130,0.15)");
      }
      if (r === anchorR && cl === anchorC) {
        rectStroke(cxp, cyp, cell, cell, 1.5, withAlpha(C_OWN_ROW, dim ? 0.45 : 1));
      }
    }
  }
}

/** The `game` object whose transient events have already been consumed.
 *  Identity, not tick number: each server message is parsed into a fresh
 *  object, so identity is exact and needs no monotonicity assumption. */
let lastTransientGame = null;

// --- Special matches ---------------------------------------------------------
//
// `game.special_matches` (transient): the server popped a lined-up run of
// specials and fired its effect.  The popped cells vanish from the grid on
// this same frame (the diff shows them), so the client's job is the reaction
// shot: a floater at the run's centre, and marking the effect's footprint so
// the downgraded cells bloom in place instead of reading as refills.

/** The neutralize_block footprint around `center` — MIRRORS the hard-coded
 *  5x5 in slime.NEUTRALIZE_BLOCK, clipped at the grid edge. */
function matchBlockCells(center, rows, cols) {
  const cr = Math.floor(center / cols), cc = center % cols;
  const cells = [];
  for (let dr = -2; dr <= 2; dr++) {
    for (let dc = -2; dc <= 2; dc++) {
      const r = cr + dr, cl = cc + dc;
      if (r < 0 || r >= rows || cl < 0 || cl >= cols) continue;
      cells.push(r * cols + cl);
    }
  }
  return cells;
}

/** One floater per resolved match, anchored at the run's centre. */
function spawnMatchFloaters(game) {
  const events = game.special_matches ?? [];
  if (events.length === 0) return;
  const { rows, cols } = gridDims(game);
  events.forEach((ev, i) => {
    for (const flat of matchBlockCells(ev.center, rows, cols)) {
      stampedThisFrame.add(flat);
    }
    const at = cellCenter(ev.center, rows, cols);
    const hits = sumTiers(ev.downgraded);
    const head = hits > 0
      ? `${ev.kind} match! ${hits} downgraded${ev.neutralized > 0 ? `, ${ev.neutralized} defused` : ""}`
      : `${ev.kind} match!`;
    spawnFloater(head, at.x, at.y - i * LAYOUT.floater.stack, SPECIAL_COLOR,
      LAYOUT.floater.lifetime, LAYOUT.floater.recipeFont);
  });
}

// --- Babies -------------------------------------------------------------------
//
// Hatched from eaten eggs, and brought along by boards that banked them.
// PURELY VISUAL for now (their one mechanical effect — hunger capacity — is
// server-side): small circles in the 5 placeholder type colours, idling in
// the Lil Guys' corral on the field's left edge.  The TARGET brood is
// re-derived from every frame —
// each seated player's board babies plus the session's hatched tally — so
// joins, leaves, hatches, restarts and reconnects all reconcile to the same
// picture.  A hatch additionally animates: the new baby spawns at the eaten
// egg's cell and wanders down to its post.

/** @type {{type: string, x: number, y: number, phase: number}[]} */
const babyViews = [];

/** Wall clock for the babies' idle bob. */
let babyClock = 0;

/** Per-type target counts for the current frame. */
function babyTargets(game) {
  const counts = Object.fromEntries(BABY_TYPES.map((n) => [n, 0]));
  for (const e of game.entities ?? []) {
    for (const n of BABY_TYPES) counts[n] += e.babies?.[n] ?? 0;
  }
  for (const n of BABY_TYPES) counts[n] += game.hatched?.[n] ?? 0;
  return counts;
}

function babyRadius(rows, cols) {
  return Math.max(4, gridRect(rows, cols).cell * 0.16);
}

/**
 * Resting spot for the i-th baby: the same corral the Lil Guys queue in.
 * The first column sits inside the guys' door column — the brood mills among
 * the crew — and overflow columns march LEFT, behind their backs, staggered a
 * half pitch so it reads as a scatter rather than a parade grid.  Clamped
 * on-screen like the guys' own posts.
 */
function babyPost(i, rows, cols) {
  const g = gridRect(rows, cols);
  const size = lilGuySize(rows, cols);
  const r = babyRadius(rows, cols);
  const pitch = r * 2.6;
  const perCol = Math.max(1, Math.floor(g.h / pitch));
  const col = Math.floor(i / perCol);
  const row = i % perCol;
  const doorX = Math.max(4, g.x0 - size - LAYOUT.lilGuys.doorGap);
  const jog = (col % 2) * pitch * 0.5;
  return {
    x: Math.max(4, doorX + size * 0.5 - col * pitch),
    y: g.y0 + r * 1.5 + row * pitch + jog,
  };
}

/** How fast the brood patrols the bite strip during the eat stage, in grid
 *  heights per second — quick enough to read as a frenzy. */
const BABY_PATROL_HZ = 0.6;

/** True while the babies should be SPRINTING the front column: the feast
 *  replay's eat stage.  Everywhere else they idle at their posts. */
function babiesOnPatrol() {
  return cinematic !== null && cinematic.stage === "eat";
}

/**
 * Baby i's patrol position this instant: running up and down the FIRST
 * column, each on its own phase so the brood reads as a scatter of workers
 * rather than a conga line.  A triangle wave, so they turn around at the
 * edges instead of teleporting.
 */
function babyPatrolAt(i, rows, cols) {
  const g = gridRect(rows, cols);
  const x = g.x0 + g.cell / 2; // the first column: where the bite lands
  const phase = (babyClock * BABY_PATROL_HZ + i / Math.max(1, babyViews.length)) % 1;
  const tri = phase < 0.5 ? phase * 2 : 2 - phase * 2; // 0→1→0
  return { x, y: g.y0 + tri * (g.h - g.cell) + g.cell / 2 };
}

/**
 * Reconcile the on-screen brood with the frame, then idle it.
 * `fresh` gates the transient hatch event, exactly like the floaters.
 */
function tickBabies(game, dt, fresh) {
  babyClock += dt;
  const { rows, cols } = gridDims(game);

  // Where this frame's hatches burst out, per type, consumed as spawns.
  const hatchAt = new Map();
  if (fresh && game.eggs_hatched) {
    const eh = game.eggs_hatched;
    (eh.cells ?? []).forEach((flat, i) => {
      const type = eh.types?.[i];
      if (!type) return;
      const at = cellCenter(flat, rows, cols);
      const list = hatchAt.get(type);
      if (list === undefined) hatchAt.set(type, [at]); else list.push(at);
    });
  }

  const counts = babyTargets(game);
  for (const n of BABY_TYPES) {
    let have = 0;
    for (const b of babyViews) if (b.type === n) have++;
    // Surplus leaves with its owner (or the old encounter): newest first.
    for (let i = babyViews.length - 1; i >= 0 && have > counts[n]; i--) {
      if (babyViews[i].type === n) {
        babyViews.splice(i, 1);
        have--;
      }
    }
    // Deficit spawns: at the eaten egg when this frame hatched one, else
    // straight onto a post (board babies arriving with a joiner).
    while (have < counts[n]) {
      const burst = hatchAt.get(n)?.shift();
      const post = babyPost(babyViews.length, rows, cols);
      babyViews.push({
        type: n,
        x: burst?.x ?? post.x,
        y: burst?.y ?? post.y,
        phase: Math.random() * Math.PI * 2,
      });
      have++;
    }
  }

  // During the eat stage the whole brood SPRINTS the first column, biting
  // (see babyPatrolAt); everywhere else everyone drifts toward their post —
  // new hatches visibly wander down the same way.
  const patrol = babiesOnPatrol();
  babyViews.forEach((b, i) => {
    if (b.chompT !== undefined && b.chompT > 0) {
      b.chompT = Math.max(0, b.chompT - dt);
    }
    const at = patrol ? babyPatrolAt(i, rows, cols) : babyPost(i, rows, cols);
    // A quicker ease on patrol, so the turnarounds read as running rather
    // than drifting.
    const ease = Math.min(1, dt * (patrol ? 10 : 3));
    b.x += (at.x - b.x) * ease;
    b.y += (at.y - b.y) * ease;
  });
}

function drawBabies(game) {
  if (babyViews.length === 0) return;
  const { rows, cols } = gridDims(game);
  const r = babyRadius(rows, cols);
  const atlas = sprites.get(BABY_SPRITE);
  for (const b of babyViews) {
    const bob = Math.sin(babyClock * 2.2 + b.phase) * r * 0.18;
    // A bite puffs the baby up for a beat — the sprite's stand-in for the
    // Lil Guys' attack clip (the babies' sheet has no action frames).
    const puff = (b.chompT ?? 0) > 0 ? 1 + 0.45 * (b.chompT / BABY_CHOMP_S) : 1;
    const idx = atlas?.meta.frames[b.type];
    if (atlas !== undefined && idx !== undefined) {
      // The authored critter, centred where the dot used to sit.  4r reads
      // as half a Lil Guy: recognisably the same species, clearly a baby.
      const s = r * 4 * puff;
      const { frame_w, frame_h } = atlas.meta;
      ctx.save();
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(atlas.img, idx * frame_w, 0, frame_w, frame_h,
        b.x - s / 2, b.y + bob - s / 2, s, s);
      ctx.restore();
      continue;
    }
    // Atlas not loaded: the old placeholder dot, so the brood never vanishes.
    ctx.save();
    ctx.fillStyle = BABY_COLOR[b.type] ?? NEUTRAL_COLOR;
    ctx.beginPath();
    ctx.arc(b.x, b.y + bob, r * puff, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = "rgba(20,20,28,0.8)";
    ctx.lineWidth = Math.max(1, r * 0.18);
    ctx.stroke();
    ctx.restore();
  }
}

/** How long a baby's bite puff lasts (seconds). */
const BABY_CHOMP_S = 0.25;

function drawGame(game, dt) {
  // The render loop redraws `latestMsg` every animation frame (~60Hz) while
  // server frames arrive at ~20Hz, so the same frame is drawn ~3 times.
  // Transient events (dispense outcomes, recipe fires, turn ends, refusals) are
  // per-frame facts, NOT per-draw, and must be consumed exactly once or they
  // spawn triplicate floaters.
  const fresh = game !== lastTransientGame;
  lastTransientGame = game;

  tickFloaters(dt);

  // Stamp outcomes are read first: they tell the grid diff which cells were
  // covered (a downgrade blooms in place; a replacement drops in), and the feast
  // replay below starts from the board those same stamps produced.
  //if (fresh) spawnStampFloaters(game);

  // A turn end starts the feast replay, which then owns the board and the Lil
  // Guys until it lands.  It must start BEFORE anything reads the board, and its
  // own board must not be diffed against the frame it is replaying toward — the
  // replay produces that board itself, cell by cell.  A turn that ends while one
  // is still running lands it early and replays from there, which is why this is
  // not gated on there being no replay in flight.
  const startedReplay = fresh && game.turn_ended
    ? startFeastCinematic(game)
    : false;
  updateFeastTracking(game);

  // The replay and the cells it drops share one clamped step, or tiles land out
  // of step with the stage that owns them.  Idle Lil Guys keep real time: they
  // are ambient, and nobody minds them teleporting a little after a hidden tab.
  const step = boardStep(dt);
  if (cinematicActive()) {
    tickCinematic(game, step);
  } else {
    tickLilGuys(game, dt);
  }

  tickGridAnims(step);
  // Diffing is the replay's job while it runs: it queues the eats, falls and
  // refills itself, and adopts the board it landed on when it ends.  Cells
  // stamped meanwhile are kept, not dropped: the team keeps casting while the
  // replay plays, and the first diff after it lands is what has to tell those
  // downgrades from refills.
  if (fresh && !cinematicActive() && !startedReplay) updateGridAnims(game.grid ?? []);
  if (fresh) {
    spawnRefusalFloater(game);
    //spawnRecipeFloaters(game);
    // Match reactions belong to the replay's pass structure — it pops and
    // flashes them at the moment they fired.  Only when a frame could not be
    // replayed (no prior board) do they float here, over the board as sent.
    if (!startedReplay && !cinematicActive()) spawnMatchFloaters(game);
    updateMenuFx(game);
  }
  tickBabies(game, dt, fresh);
  tickMenuFx(dt);
  // Fliers wear the same hidden-tab clamp as the replay that spawns them:
  // a single huge frame must not teleport every streak onto the HUD at once.
  tickFlyTris(Math.min(dt, LAYOUT.cinematic.maxStepS));

  clear();

  const H = LAYOUT.headers;
  text(`Turn ${game.turn ?? 1}`,
    H.waveX, H.waveY, H.waveFont, C_HEADER);

  // The game id (join code), tucked under the score HUD top right, so anyone
  // watching can tell others what to join.
  const gameId = `Game ${game.join_code ?? "------"}`;
  const idFont = 14;
  ctx.font = `${idFont}px monospace`;
  text(gameId, SW - ctx.measureText(gameId).width - 24,
    LAYOUT.scoreHud.y + 34, idFont, C_HEADER);

  // Observers watch the same board; the only key that means anything to them
  // is the one that puts them in it.
  if (game.observer) {
    const hint = "OBSERVING — press P to take a seat";
    ctx.font = `${H.labelFont - 4}px monospace`;
    text(hint, SW - ctx.measureText(hint).width - 24,
      LAYOUT.scoreHud.y + 54, H.labelFont - 4, C_TEXT);
  }

  drawHungerBar(game);
  drawChargeBar(game);
  drawSlimeField(game);
  drawLilGuys(game, dt);
  drawBabies(game);
  drawPlayerMenus(game);

  // Floaters drawn last so they appear on top of everything; the score
  // fliers over those, and the HUD last of all so fliers vanish INTO it.
  drawFloaters();
  drawFlyTris();
  drawScoreHud(game);
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
 * table, recipe fire counts, and the charge pool's final ledger.
 *
 * The report is a single match-wide summary across every turn: how much of the
 * field the team's stamps covered and defused, how much food they never opened
 * a road to, and what the whole effort cost from the shared pool.
 */
function drawGameOver(msg) {
  clear();
  const L = LAYOUT.gameOver;
  const score = msg && msg.score !== undefined && msg.score !== null ? msg.score : "?";
  const stats = msg ? msg.stats : null;

  const REASON_TEXT = {
    hunger_full: "The Lil Guys got full!",
    field_cleared: "Slime field cleared!",
  };
  const reasonText = stats ? (REASON_TEXT[stats.reason] ?? stats.reason) : "";
  text(`Encounter over — ${reasonText}`, L.x, L.titleY, L.titleFont, C_HEADER);
  const hungerText = stats ? `   ·   Hunger ${stats.hunger_final}/${stats.hunger_max}` : "";
  text(`Neutral slime consumed: ${score}${hungerText}`, L.x, L.scoreY, L.scoreFont, C_SLIME_HDR);

  if (!stats) {
    drawRestartButton("START NEXT ROUND");
    return;
  }

  // ---- Match-wide feast tallies -------------------------------------------
  const F = L.fcols;
  const feast = stats.feast ?? {};
  let y = L.feastY;
  y += L.rowH;

  const feastRow = (label, obj) => {
    text(label, F.label, y, L.rowFont, "rgba(70,70,85,0.95)");
    drawTierCells(F.cells, y, L.rowFont, obj);
    y += L.rowH;
  };

  y += 4;
  const spent = feast.charges_spent ?? 0;
  const left = feast.charges_left ?? 0;
  const consumed = (feast.neutral ?? 0) + (feast.defused ?? 0);
  y += L.rowH;
  // The headline tuning number: food that existed, was edible, and was never
  // reached.  A high figure means the charges went somewhere that did not open
  // a road, which is the only way this game is really lost.
  y += L.rowH;
  // Charges per unit of food: the single ratio that says whether the encounter
  // was priced right.  Guarded, because a team can finish having spent nothing.
  const perUnit = consumed > 0 ? (spent / consumed).toFixed(2) : "—";
  y += L.rowH + 14;

  // ---- Per-player table ----------------------------------------------------
  const P = L.pcols;
  text("PLAYER", P.name, y, L.sectionFont, C_HEADER);
  text("CASTS", P.casts, y, L.sectionFont, C_HEADER);
  text("CELLS HIT", P.covered, y, L.sectionFont, C_HEADER);
  text("DEFUSED", P.defused, y, L.sectionFont, C_HEADER);
  text("RECIPES", P.recipes, y, L.sectionFont, C_HEADER);
  y += L.rowH;
  (stats.players ?? []).forEach((p, i) => {
    text(`P${i + 1}`, P.name, y, L.rowFont, C_TEXT);
    text(String(p.casts), P.casts, y, L.rowFont, C_TEXT);
    text(String(p.cells_covered ?? 0), P.covered, y, L.rowFont, C_SLIME_HDR);
    text(String(p.cells_neutralized ?? 0), P.defused, y, L.rowFont, SHAPE_COLOR);
    text(`${p.recipe_casts}/${p.casts}`, P.recipes, y, L.rowFont, "rgba(170,120,0,0.95)");
    y += L.rowH;
  });
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
    P.name, y, L.rowFont, recipeParts.length > 0 ? "rgba(170,120,0,0.95)" : "rgba(120,120,140,0.7)");
  y += L.rowH;
  const eaten = (stats.slime_total ?? 0) - (stats.slime_left ?? 0);
  text(`total spells cast: ${stats.casts_total}  ·  slime eaten: ${eaten}/${stats.slime_total ?? 0}`,
    P.name, y, L.rowFont, "rgba(70,70,85,0.95)");

  drawRestartButton("START NEXT ROUND");
}

/** Design-space bounds of the next-round button.  Fixed geometry, so click
 *  hit-testing needs no per-frame state. */
const RESTART_BUTTON = (() => {
  const B = LAYOUT.gameOver.button;
  return { x: (SW - B.w) / 2, y: SH - B.h - B.bottomGap, w: B.w, h: B.h };
})();
let restartHover = false;

/** True while a HOLD screen is up and the button should exist: the report
 *  (once its outro replay lands) or the pre-match guide.  Clicks anywhere
 *  else must not advance the match. */
function restartButtonActive() {
  return (latestMsg?.phase === "game_over" && !outroActive()) ||
    latestMsg?.phase === "pre_match";
}

/** The one way the match advances past a hold: a CLICK, from a browser tab.
 *  Drawn as a real button so the trigger is unmistakably deliberate. */
function drawRestartButton(label) {
  const B = LAYOUT.gameOver.button;
  const r = RESTART_BUTTON;
  rect(r.x, r.y, r.w, r.h,
    restartHover ? "rgba(60,90,200,0.18)" : "rgba(60,90,200,0.08)");
  rectStroke(r.x, r.y, r.w, r.h, restartHover ? 3 : 2, C_HEADER);
  ctx.save();
  ctx.font = `bold ${B.font}px monospace`;
  ctx.fillStyle = C_HEADER;
  ctx.textAlign = "center";
  ctx.fillText(label, r.x + r.w / 2, r.y + r.h / 2 + B.font * 0.35);
  ctx.restore();
}

// ---------------------------------------------------------------------------
// End-of-match outro
// ---------------------------------------------------------------------------
//
// The server ends the match on the turn that fills the hunger bar (the
// game's clock) or clears the field — both of which happen at the END of a
// turn, after the closing feast has already been eaten.  Cutting to the
// report there would throw away the best moment in the game: the bite that
// ended it.
//
// So the board is HELD.  The game_over frame carries the same payload a turn
// end does (post-feast grid + turn_ended), the feast replays exactly as any
// other turn's does, and only once it has landed does the verdict float up.
// The report waits behind it.  Input is dead for the duration — see the keydown
// handler — because there is nothing to decide and a stray keypress would
// otherwise skip straight past the payoff.

/** Seconds the verdict floater holds the board before the report replaces it. */
const OUTRO_HOLD_S = 3.0;

/** Reason → what the players are told, and in what colour. */
const VERDICT = {
  field_cleared: { text: "FIELD CLEARED!", color: C_SLIME_HDR },
  hunger_full: { text: "GAME OVER", color: C_BAD },
};
const VERDICT_DEFAULT = { text: "GAME OVER", color: C_BAD };

/**
 * @typedef {object} Outro
 * @property {object} msg        - the game_over frame the outro plays from, held
 *                                 by identity so later frames cannot restart it
 * @property {number|null} age   - seconds since the verdict floated; null while
 *                                 the closing feast is still being eaten
 * @property {boolean} done      - outro finished; the report owns the screen
 */

/** @type {Outro|null} */
let outro = null;

/** True while the outro still owns the screen. */
function outroActive() {
  return outro !== null && !outro.done;
}

/**
 * Advance the outro one frame.  Called AFTER the board is drawn, so the feast
 * replay has already been ticked and `cinematicActive()` is the answer for this
 * frame rather than the last one.
 */
function tickOutro(dt) {
  if (!outroActive()) return;
  // Eat first, talk after.  A verdict over a board still mid-chew reads as a
  // bug, and the tally floaters the replay lands with need the room.
  if (outro.age === null) {
    if (cinematicActive()) return;
    const { x, y } = fieldCenter();
    const v = VERDICT[outro.msg.stats?.reason] ?? VERDICT_DEFAULT;
    spawnFloater(v.text, x, y + LAYOUT.floater.verdictDy, v.color,
      OUTRO_HOLD_S, LAYOUT.floater.verdictFont);
    outro.age = 0;
    return;
  }
  outro.age += dt;
  // Held for the floater's whole life, so the verdict fades out rather than
  // being cut off by the report.
  if (outro.age < OUTRO_HOLD_S) return;
  outro.done = true;
  // The board is finished with.  Nothing downstream clears it for us: the
  // report is drawn from the game_over phase this outro has been standing in
  // since it started, so the usual leaving-the-game-phase hook already fired
  // (and did nothing) frames ago.
  clearEntityState();
}

// ---------------------------------------------------------------------------
// Render loop
// ---------------------------------------------------------------------------

let latestMsg = null;
let lastTs = null;
let lastPhase = null;

function renderFrame(msg, dt) {
  // A game_over frame without a board is nothing to replay: the outro is
  // skipped and the report drawn immediately, exactly as before.
  //
  // `outro === null` is the whole guard, and it is enough for both jobs: a
  // finished outro is kept (as `done`) rather than cleared, so the frames still
  // arriving behind it cannot start a second one, and the record is only torn
  // down when the phase changes below.  Gating on `lastPhase` instead would
  // wedge the fallback case — one boardless frame would mark the phase as seen
  // and no later frame, board or not, could ever open the outro.
  if (msg.phase === "game_over" && msg.game && outro === null) {
    outro = { msg, age: null, done: false };
  }
  if (msg.phase !== "game_over" && outro !== null) {
    // Left game_over — either the outro finished and the player dismissed the
    // report, or the room moved on under us (a paired board can dismiss for
    // everyone).  An outro cut short still has a board and floaters on screen;
    // a finished one already cleared them.
    if (!outro.done) clearEntityState();
    outro = null;
  }

  if (outroActive()) {
    lastPhase = msg.phase;
    // Drawn from the held frame, not the live one: the outro must not be
    // restarted, re-diffed or re-floated by the frames still arriving behind
    // it, and drawGame keys all of that off frame identity.
    drawGame(outro.msg.game, dt);
    tickOutro(dt);
    return;
  }

  // Clear per-entity state whenever we leave the game phase.  An outro leaves
  // it by way of game_over instead, and clears on its own way out.
  if (lastPhase === "game" && msg.phase !== "game") clearEntityState();
  lastPhase = msg.phase;

  switch (msg.phase) {
    case "pre_lobby": drawPreLobby(); break;
    case "connecting": drawConnecting(); break;
    case "pre_match": drawPreMatch(msg.game); break;
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
  // Enter = lock in a cast (game) / dismiss (game over).
  // Escape = take back your newest lock-in, one per press.
  "Enter", "Escape",
  // Shape wheel: 1 turns forward, 2 turns back.  Selection lives on the
  // server, so these are the whole of the client's part in it.
  "1", "2",
  // Aim: the arrow keys walk the server-authoritative cursor the shape is
  // stamped on.  Clamped server-side, so holding a direction at an edge is
  // harmless.
  "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
  // Seats: p takes a player slot (silently ignored when all four are taken),
  // Shift+P gives it up and goes back to observing.  Case matters — it is
  // exactly what KeyboardEvent.key reports.
  "p", "P",
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
  // The feast replay is a pause in play: the board on screen is mid-meal, so
  // neither aiming at it nor casting into it would mean anything.  Keys are
  // dropped rather than queued — a cast the player cannot see land is worse
  // than one they have to press again.
  //
  // The outro is the same pause with nothing behind it: the match is already
  // decided, and the only key the Zig client still answers to is the one that
  // dismisses the report — which must not be spent before the report is up.
  if (cinematicActive() || outroActive()) return;
  if (latestMsg?.phase === "game" && latestMsg.game) {
    const g = latestMsg.game;
    // A lock-in FREEZES its player: while any cast of theirs is pending, the
    // cursor and the wheel are committed — aiming or re-rolling now would
    // silently desync what they see from what they promised the round.  The
    // keys are dropped HERE, not sent and refused: the server would happily
    // move the cursor, and the lock is a client-honoured contract.  ESC is
    // the one exception — cancelling is exactly how the player frees
    // themselves back up.
    const frozen = (g.pending ?? []).some((pc) => pc.player_id === g.player_id);
    const steering = e.key === "1" || e.key === "2" || e.key.startsWith("Arrow");
    if (frozen && steering) {
      triggerMenuFx(g.player_id, "shake");
      return;
    }
    // ENTER with every cast already spent is a refusal the server never
    // answers (the key does nothing), so the invalid-selection shake is
    // raised locally: the player asked, the answer is no, their menu says so.
    if (e.key === "Enter") {
      const own = (g.entities ?? []).find((en) => en.owner === g.player_id);
      if (own !== undefined && (own.casts_left ?? 0) === 0) {
        triggerMenuFx(g.player_id, "shake");
      }
    }
  }
  sendKey(e.key);
});

/** A mouse event's position in DESIGN units: the canvas is CSS-scaled, so
 *  client coordinates must be mapped back through its on-screen rect. */
function canvasCoords(e) {
  const r = canvas.getBoundingClientRect();
  return {
    x: (e.clientX - r.left) * (SW / r.width),
    y: (e.clientY - r.top) * (SH / r.height),
  };
}

function overRestartButton(e) {
  if (!restartButtonActive()) return false;
  const { x, y } = canvasCoords(e);
  const r = RESTART_BUTTON;
  return x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h;
}

canvas.addEventListener("mousemove", (e) => {
  restartHover = overRestartButton(e);
  canvas.style.cursor = restartHover ? "pointer" : "default";
});

// Starting the next round is a CLICK on the report's button — deliberately
// not a key, so nobody mashing casts at the buzzer relaunches the game by
// accident.  Computed from the event (not the hover flag) so touch works.
canvas.addEventListener("click", (e) => {
  if (!overRestartButton(e)) return;
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ action: "restart" }));
  }
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
