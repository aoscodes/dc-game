"use strict";

/**
 * /tune — designer configuration editor.
 *
 * Loads the shipped data files (or a saved config via ?from=<hash>) into a
 * plain state object, renders bounded inputs for every value, and POSTs to
 * /api/tune/save.  The bridge content-addresses the config and validates it
 * with `server --validate` (the Zig loader is the single source of truth
 * for limits); the UI bounds below are a convenience layer only.
 *
 * Limits mirrored from src/shared/config.zig / protocol caps:
 *   recipes <= 64 per table, group components 2..6 (each an existing move
 *   label), slime grid rows 1..16 × cols 1..16, hunger_base 1..65535 with
 *   hunger_player_cap >= hunger_base (the loader rejects a cap under the
 *   base).
 */

/** Slime difficulty tiers, hardest first — mirrors components.Tier. */
const TIERS = ["red", "yellow", "green"];

const MAX_RECIPES = 64;
/** A group needs 2+ DISTINCT players, so it can never want more components
 *  than there are player slots.  Mirrors config.zig's 2..MAX_PLAYERS check. */
const MIN_GROUP_MOVES = 2;
const MAX_GROUP_MOVES = 6;
/** Mirrors components.MAX_GRID_ROWS / MAX_GRID_COLS. */
const MAX_GRID_ROWS = 16;
const MAX_GRID_COLS = 16;
/** Shapes are bounded by the grid: mirrors balance.MAX_SHAPE_ROWS/COLS. */
const MAX_SHAPE_ROWS = MAX_GRID_ROWS;
const MAX_SHAPE_COLS = MAX_GRID_COLS;
/** Mirrors balance.DEFAULT_SLIME_GRID (used for pre-grid configs). */
const DEFAULT_SLIME_GRID = { rows: 6, cols: 10 };
/** Mirrors the balance.DEFAULT_* realtime pacing knobs. */
const DEFAULT_BITE_INTERVAL_MS = 4000;
const DEFAULT_BITE_SPEEDUP_PER_GUY_PCT = 15;
const DEFAULT_BITE_SPEEDUP_PER_BABY_PCT = 5;
const DEFAULT_CAST_COOLDOWN_MS = 750;
const DEFAULT_TEAM_WINDOW_MS = 3000;
/** Mirrors balance.DEFAULT_RECIPE_COST — an unpriced recipe costs one charge. */
const DEFAULT_RECIPE_COST = 1;
/** Mirrors encounter.DEFAULT_CHARGES. */
const DEFAULT_CHARGES = 30;
/** Mirrors balance.DEFAULT_HUNGER_BASE / _APPETITE_SCALE / _HUNGER_PLAYER_CAP.
 *  The bar's capacity is per PLAYER now: each player contributes
 *  min(hunger_base + appetite * appetite_scale, hunger_player_cap), and the
 *  game's hunger max is the sum over everyone in it. */
const DEFAULT_HUNGER_BASE = 30;
const DEFAULT_APPETITE_SCALE = 5;
const DEFAULT_HUNGER_PLAYER_CAP = 500;
/** Mirrors balance.DEFAULT_MATCH_LEN. */
const DEFAULT_MATCH_LEN = 3;
/** Mirrors balance.DEFAULT_CHARGE_REFILL: charges a swallowed canister
 *  pours back into the team pool. */
const DEFAULT_CHARGE_REFILL = 3;
/** Mirrors balance.BACK_RANKS: the rightmost columns a back_ranks_only
 *  special kind may spawn in — the far side from the feast's door. */
const BACK_RANKS = 2;

/** Mirrors balance.DEFAULT_FEAST_COLUMNS / _FEAST_COLUMNS_PER_GUY: the bite
 *  chews the leftmost `feast_columns + seated * feast_columns_per_guy`
 *  columns at turn end (clamped to the grid). */
const DEFAULT_FEAST_COLUMNS = 1;
const DEFAULT_FEAST_COLUMNS_PER_GUY = 0;

/** Scalar balance fields: [key, label, min, max, step]. */
const RATE_FIELDS = [
  ["hunger_cost_normal", "hunger per bite (eaten or nibbled)", 0, 1000, 1],
  ["bite_interval_ms", "ms between bites (base rate)", 100, 60000, 50],
  ["bite_speedup_per_guy_pct", "% faster bites per extra lil guy", 0, 1000, 1],
  ["bite_speedup_per_baby_pct", "% faster bites per baby", 0, 1000, 1],
  ["cast_cooldown_ms", "ms between one player's casts", 0, 60000, 50],
  ["team_window_ms", "ms window for team recipes", 1, 60000, 50],
  ["hunger_base", "hunger capacity per player (appetite 0)", 1, 65535, 1],
  ["appetite_scale", "extra capacity per appetite point", 0, 65535, 1],
  ["hunger_player_cap", "per-player capacity ceiling", 1, 65535, 1],
  ["feast_columns", "bite width: columns eaten per turn", 1, 16, 1],
  ["feast_columns_per_guy", "extra bite columns per seated player", 0, 16, 1],
];

/**
 * @type {{
 *   balance: object,
 *   encounter: { charges: number,
 *                slime: { tiered: object, neutral: number,
 *                         special: {neutralizer: number, egg: number} } },
 * }}
 * `encounter.slime` is the ONE slime pool of the encounter: whatever does not
 * fit on the grid waits in the reservoir and refills from the top.
 * `charges` is the team's whole budget for the encounter — one pool, spent
 * across every turn and every player, never refilled.
 */
let state = null;

// ---------------------------------------------------------------------------
// Load
// ---------------------------------------------------------------------------

const FROM_HASH = (new URLSearchParams(location.search).get("from") || "")
  .match(/^[0-9a-f]{16}$/)?.[0] ?? null;

function dataUrl(file) {
  return FROM_HASH ? `/config/${FROM_HASH}/data/${file}` : `/data/${file}`;
}

/** Densify a sparse per-tier map into every tier, so inputs always bind. */
const tiersFrom = (sparse) =>
  Object.fromEntries(TIERS.map((t) => [t, (sparse ?? {})[t] ?? 0]));

/** Drop zero entries: the Zig loader defaults absent tiers to 0, so a sparse
 *  map keeps saved configs readable and diffable. */
const sparseTiers = (dense) =>
  Object.fromEntries(TIERS.filter((t) => (dense?.[t] ?? 0) > 0).map((t) => [t, dense[t]]));

/** Special kinds, mirroring components.SpecialKind (ordinal order).
 *  `neutralizer` fires a 3x3 Agent block when eaten; `egg` is edible and
 *  hatches a baby; `rock` is the permanent wall nothing can touch;
 *  `canister` refills the team's charge pool when eaten; `bomb` destroys
 *  its 3x3 surroundings when eaten (or just the rocks in it). */
const SPECIAL_KINDS = ["neutralizer", "egg", "rock", "canister", "bomb"];

const specialsFrom = (obj) =>
  Object.fromEntries(SPECIAL_KINDS.map((k) => [k, obj?.[k] ?? 0]));

const sparseSpecials = (dense) =>
  Object.fromEntries(SPECIAL_KINDS.filter((k) => (dense?.[k] ?? 0) > 0).map((k) => [k, dense[k]]));

const sumSpecials = (obj) =>
  SPECIAL_KINDS.reduce((n, k) => n + (obj?.[k] ?? 0), 0);

/**
 * Collapse a legacy `zones` array into the one slime pool, mirroring
 * config.zig: per-tier hazard counts and neutral units are summed.
 */
function sumZones(zones) {
  const pool = { tiered: tiersFrom(null), neutral: 0, special: specialsFrom(null) };
  for (const z of zones) {
    for (const t of TIERS) pool.tiered[t] += (z.tiered ?? {})[t] ?? 0;
    pool.neutral += z.neutral ?? 0;
    for (const k of SPECIAL_KINDS) pool.special[k] += (z.special ?? {})[k] ?? 0;
  }
  return pool;
}

/**
 * Normalise an authored shape into a rectangular rows-of-"#/."  array.
 *
 * config.shape_from_rows REJECTS a ragged shape (there is no well-defined
 * anchor), so the editor pads to the widest row rather than letting the user
 * save something the loader will refuse.
 */
function shapeFrom(rows) {
  const src = (rows ?? []).length > 0 ? rows : ["#"];
  const cols = Math.max(...src.map((r) => r.length), 1);
  return src.map((r) => r.padEnd(cols, "."));
}

async function load() {
  const [balRes, encRes] = await Promise.all([
    fetch(dataUrl("balance.json")),
    fetch(dataUrl("encounters.json")),
  ]);
  if (!balRes.ok || !encRes.ok) throw new Error("failed to fetch config data");
  const bal = await balRes.json();
  const encs = await encRes.json();
  const def = encs.encounters.find((e) => e.label === encs.default) ?? encs.encounters[0];

  state = {
    balance: {
      hunger_cost_normal: bal.hunger_cost_normal,
      // Grid dimensions; default like the server does for pre-grid configs.
      slime_grid: {
        rows: bal.slime_grid?.rows ?? DEFAULT_SLIME_GRID.rows,
        cols: bal.slime_grid?.cols ?? DEFAULT_SLIME_GRID.cols,
      },
      // Default like the server does for older configs.
      bite_interval_ms: bal.bite_interval_ms ?? DEFAULT_BITE_INTERVAL_MS,
      bite_speedup_per_guy_pct: bal.bite_speedup_per_guy_pct ?? DEFAULT_BITE_SPEEDUP_PER_GUY_PCT,
      bite_speedup_per_baby_pct: bal.bite_speedup_per_baby_pct ?? DEFAULT_BITE_SPEEDUP_PER_BABY_PCT,
      cast_cooldown_ms: bal.cast_cooldown_ms ?? DEFAULT_CAST_COOLDOWN_MS,
      team_window_ms: bal.team_window_ms ?? DEFAULT_TEAM_WINDOW_MS,
      hunger_base: bal.hunger_base ?? DEFAULT_HUNGER_BASE,
      appetite_scale: bal.appetite_scale ?? DEFAULT_APPETITE_SCALE,
      hunger_player_cap: bal.hunger_player_cap ?? DEFAULT_HUNGER_PLAYER_CAP,
      feast_columns: bal.feast_columns ?? DEFAULT_FEAST_COLUMNS,
      feast_columns_per_guy: bal.feast_columns_per_guy ?? DEFAULT_FEAST_COLUMNS_PER_GUY,
      // Default like the server does: specials stay out of the door column.
      specials_avoid_door_column: bal.specials_avoid_door_column ?? true,
      // Per-kind special tuning, densified so inputs always bind (and so a
      // round-trip PRESERVES it — older editors silently dropped the table).
      specials: Object.fromEntries(SPECIAL_KINDS.map((k) => [k, {
        match_len: bal.specials?.[k]?.match_len ?? DEFAULT_MATCH_LEN,
        back_ranks_only: bal.specials?.[k]?.back_ranks_only ?? false,
        guaranteed_at_start: bal.specials?.[k]?.guaranteed_at_start ?? false,
        charge_refill: bal.specials?.[k]?.charge_refill ?? DEFAULT_CHARGE_REFILL,
        explode_rocks_only: bal.specials?.[k]?.explode_rocks_only ?? false,
      }])),
      player_recipes: bal.player_recipes.map((r) => ({
        label: r.label,
        shape: shapeFrom(r.shape),
        cost: r.cost ?? DEFAULT_RECIPE_COST,
      })),
      team_recipes: bal.team_recipes.map((r) => ({
        label: r.label,
        moves: [...r.moves],
        shape: shapeFrom(r.shape),
        cost: r.cost ?? DEFAULT_RECIPE_COST,
      })),
    },
    encounter: {
      charges: def.charges ?? DEFAULT_CHARGES,
      // Multi-zone configs collapse into the single pool, exactly as the Zig
      // loader does, so an old config round-trips to the same game.
      slime: sumZones(def.zones ?? []),
    },
  };
  renderAll();
}

// ---------------------------------------------------------------------------
// Small DOM helpers
// ---------------------------------------------------------------------------

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  for (const c of children) {
    node.append(typeof c === "string" ? document.createTextNode(c) : c);
  }
  return node;
}

const clamp = (v, min, max) => Math.min(max, Math.max(min, v));

/**
 * Bounded number input bound to obj[key].  Clamps on change; steps of 1
 * force integers (the data files use integer fields except round duration).
 */
/** A checkbox bound to obj[key] (a boolean). */
function boolInput(obj, key, onChange = null) {
  const input = el("input", { type: "checkbox" });
  input.checked = !!obj[key];
  input.addEventListener("change", () => {
    obj[key] = input.checked;
    if (onChange) onChange();
  });
  return input;
}

function numInput(obj, key, min, max, step = 1, cls = "", onChange = null) {
  const input = el("input", { type: "number", min, max, step, class: cls });
  input.value = obj[key];
  input.addEventListener("change", () => {
    let v = parseFloat(input.value);
    if (Number.isNaN(v)) v = min;
    v = clamp(v, min, max);
    if (step === 1) v = Math.round(v);
    obj[key] = v;
    input.value = v;
    if (onChange) onChange();
  });
  return input;
}

/**
 * Row of one input per tier, bound to a {red, yellow, green} object.
 * `onChange` (optional) fires after any of them is edited.
 */
function tierRow(prefix, tiers, max = 1000, onChange = null) {
  const row = el("span", { class: "colors" });
  if (prefix) row.append(el("span", { class: "muted" }, `${prefix} `));
  for (const t of TIERS) {
    row.append(el("span", { class: t }, `${t[0].toUpperCase()} `));
    row.append(numInput(tiers, t, 0, max, 1, "", onChange));
  }
  return row;
}

/**
 * A recipe's charge cost.  0 is legal and meaningful — a free move — so the
 * input is always shown rather than being treated as an absent value.
 */
function costRow(recipe) {
  return el("span", { class: "colors" },
    el("span", { class: "muted" }, "charge cost "),
    numInput(recipe, "cost", 0, 65535, 1),
    el("span", { class: "muted" }, " (0 = free)"));
}

/**
 * Paint grid for a recipe's shape: click any cell to toggle it, and grow or
 * shrink the bounding box with the row/col buttons.
 *
 * The ANCHOR — the cell the caster aims at — is outlined rather than chosen: it
 * is always the bounding box centre (`len / 2`, floored), because that is what
 * config.shape_from_rows computes.  Making it editable here would let a saved
 * config disagree with the loader.
 *
 * `recipe.shape` is mutated in place and re-rendered via `onChange`, so the
 * outlined anchor tracks a resize immediately.
 */
function shapeEditor(recipe, onChange) {
  const rows = recipe.shape;
  const nRows = rows.length;
  const nCols = rows[0].length;
  const anchorR = Math.floor(nRows / 2);
  const anchorC = Math.floor(nCols / 2);

  const grid = el("div", { class: "grid" });
  grid.style.gridTemplateColumns = `repeat(${nCols}, 22px)`;
  rows.forEach((line, r) => {
    for (let cl = 0; cl < nCols; cl++) {
      const on = line[cl] === "#";
      const isAnchor = r === anchorR && cl === anchorC;
      const cls = ["cell", on ? "on" : "", isAnchor ? "anchor" : ""]
        .filter(Boolean).join(" ");
      grid.append(el("button", {
        class: cls,
        title: isAnchor ? `anchor (row ${r}, col ${cl})` : `row ${r}, col ${cl}`,
        onclick: () => {
          const ch = rows[r][cl] === "#" ? "." : "#";
          rows[r] = rows[r].slice(0, cl) + ch + rows[r].slice(cl + 1);
          onChange();
        },
      }));
    }
  });

  // Resizing preserves what is already painted: added rows/cols start empty,
  // and removed ones are simply dropped.
  const resize = (dRows, dCols) => {
    if (dRows > 0) rows.push(".".repeat(nCols));
    if (dRows < 0) rows.pop();
    if (dCols > 0) for (let r = 0; r < rows.length; r++) rows[r] += ".";
    if (dCols < 0) for (let r = 0; r < rows.length; r++) rows[r] = rows[r].slice(0, -1);
    onChange();
  };
  const btn = (label, enabled, dRows, dCols) => {
    const b = el("button", { onclick: () => resize(dRows, dCols) }, label);
    if (!enabled) b.disabled = true;
    return b;
  };

  return el("div", { class: "shape" },
    el("div", { class: "row" }, el("span", { class: "muted" }, "shape (click to paint) ")),
    grid,
    el("div", { class: "row" },
      btn("+ row", nRows < MAX_SHAPE_ROWS, 1, 0),
      btn("− row", nRows > 1, -1, 0),
      btn("+ col", nCols < MAX_SHAPE_COLS, 0, 1),
      btn("− col", nCols > 1, 0, -1),
      el("span", { class: "muted dims" },
        `${nRows}×${nCols}, ${cellsOn(rows)} cells, anchor @${anchorR},${anchorC}`)),
  );
}

/** Painted cell count — 0 is invalid (config.zig rejects an empty shape). */
function cellsOn(rows) {
  return rows.reduce((n, line) => n + [...line].filter((ch) => ch === "#").length, 0);
}

/** Every move label currently authored — the only legal group components. */
function moveLabels() {
  return state.balance.player_recipes.map((r) => r.label);
}

/**
 * Dropdown sequence editing a group's component moves (array of move labels).
 * Constraining each slot to an existing label by construction is what keeps
 * the editor from producing a config the Zig loader rejects for an unknown
 * component.  Repeats are legal and meaningful: two `poke` components means
 * two DIFFERENT players each casting poke.
 */
function movesEditor(moves, onStructureChange) {
  const labels = moveLabels();
  const wrap = el("span", { class: "moveseq" });
  if (labels.length === 0) {
    wrap.append(el("span", { class: "error-note" },
      "⚠ define a move first — a group is built out of moves"));
    return wrap;
  }
  moves.forEach((move, i) => {
    const sel = el("select");
    for (const opt of labels) {
      sel.append(el("option", move === opt ? { value: opt, selected: "" } : { value: opt }, opt));
    }
    // A label the move table no longer has (renamed or removed under this
    // group): surfaced rather than silently snapped to another move, since
    // silently rebalancing someone's group is worse than an explicit warning.
    if (!labels.includes(move)) {
      sel.prepend(el("option", { value: move, selected: "" }, `${move} (missing!)`));
    }
    sel.addEventListener("change", () => { moves[i] = sel.value; });
    wrap.append(sel);
  });
  const add = el("button", {
    onclick: () => { moves.push(labels[0]); onStructureChange(); },
  }, "+ move");
  if (moves.length >= MAX_GROUP_MOVES) add.disabled = true;
  const del = el("button", {
    class: "danger",
    onclick: () => { moves.pop(); onStructureChange(); },
  }, "− move");
  if (moves.length <= MIN_GROUP_MOVES) del.disabled = true;
  wrap.append(add, del);
  return wrap;
}

function labelInput(recipe) {
  const input = el("input", { type: "text", maxlength: "32", placeholder: "label" });
  input.value = recipe.label;
  input.addEventListener("change", () => { recipe.label = input.value.trim(); });
  return input;
}

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

function renderConfigNote() {
  const note = FROM_HASH
    ? `Editing saved config ${FROM_HASH} — saving forks it into a new one.`
    : "Editing the shipped defaults — saving creates a new config.";
  document.getElementById("config-note").replaceChildren(el("span", {}, note));
}

function renderRates() {
  const box = document.getElementById("rates");
  box.replaceChildren(el("legend", {}, "Rates & costs"));
  for (const [key, text, min, max, step] of RATE_FIELDS) {
    box.append(
      el("label", {}, el("span", {}, text), numInput(state.balance, key, min, max, step)),
      el("br"),
    );
  }
  box.append(slimeGridRow(), el("br"), ...specialsRows());
}

/**
 * Per-kind special tuning: the (dormant) match length, the back-ranks
 * spawn restriction, and the start-of-play guarantee.  The back-ranks
 * checkbox pins the kind's spawns to the grid's rightmost BACK_RANKS
 * columns — the far side from the feast's door, where (since slime never
 * falls sideways) a unit stays for its whole life.  The guarantee checkbox
 * seats one unit of the kind on the grid before the initial fill whenever
 * the encounter's supply holds any (mid-game refills are untouched).
 * Leads with the global door-column rule: no special ever spawns in
 * column 0 while it is set.
 */
function specialsRows() {
  const rows = [
    el("label", {},
      el("span", {}, "specials never spawn in the door column (column 0)"),
      boolInput(state.balance, "specials_avoid_door_column")),
    el("br"),
  ];
  for (const k of SPECIAL_KINDS) {
    const tuning = state.balance.specials[k];
    rows.push(
      el("label", {},
        el("span", {}, `${k} match length (match machinery is dormant)`),
        numInput(tuning, "match_len", 2, Math.max(MAX_GRID_ROWS, MAX_GRID_COLS))),
      el("br"),
      el("label", {},
        el("span", {}, `${k} spawns only on the back ${BACK_RANKS} columns (far from the feast's door)`),
        boolInput(tuning, "back_ranks_only")),
      el("br"),
      el("label", {},
        el("span", {}, `${k} guaranteed on the starting grid (one seated at the start of play while the supply holds any)`),
        boolInput(tuning, "guaranteed_at_start")),
      el("br"),
    );
    if (k === "canister") {
      rows.push(
        el("label", {},
          el("span", {}, "canister charge refill (charges back per canister eaten)"),
          numInput(tuning, "charge_refill", 0, 65535)),
        el("br"),
      );
    }
    if (k === "bomb") {
      rows.push(
        el("label", {},
          el("span", {}, "bomb blast destroys ONLY rocks (everything else survives)"),
          boolInput(tuning, "explode_rocks_only")),
        el("br"),
      );
    }
  }
  return rows;
}

/**
 * Slime grid dimensions — nested under balance.slime_grid, with a live
 * readout of the resulting on-grid cell count (slime beyond it waits in the
 * reservoir and refills from the top).
 */
function slimeGridRow() {
  const grid = state.balance.slime_grid;
  const cells = el("span", { class: "muted" });
  const refresh = () => {
    cells.textContent = ` = ${grid.rows * grid.cols} cells on grid`;
    // Resizing the grid changes how much slime starts in the reservoir.
    if (document.getElementById("slime-total").textContent) renderSlimeTotal();
  };
  refresh();
  return el("label", {},
    el("span", {}, "slime grid (rows × cols)"),
    numInput(grid, "rows", 1, MAX_GRID_ROWS, 1, "", refresh),
    el("span", { class: "muted" }, " × "),
    numInput(grid, "cols", 1, MAX_GRID_COLS, 1, "", refresh),
    cells,
  );
}

function renderPlayerRecipes() {
  const box = document.getElementById("player-recipes");
  box.replaceChildren();
  state.balance.player_recipes.forEach((r, i) => {
    box.append(el("div", { class: "card" },
      el("div", { class: "row" },
        labelInput(r), " ",
        el("button", {
          class: "danger",
          onclick: () => { state.balance.player_recipes.splice(i, 1); renderPlayerRecipes(); },
        }, "remove recipe")),
      el("div", { class: "row" }, shapeEditor(r, renderPlayerRecipes)),
      el("div", { class: "row" }, costRow(r)),
      ...(cellsOn(r.shape) === 0
        ? [el("div", { class: "row" }, el("span", { class: "error-note" },
          "⚠ shape covers no cells — the server will reject this"))]
        : []),
    ));
  });
  document.getElementById("pr-count").textContent = `(${state.balance.player_recipes.length}/${MAX_RECIPES})`;
  document.getElementById("add-player-recipe").disabled =
    state.balance.player_recipes.length >= MAX_RECIPES;
}

function renderTeamRecipes() {
  const box = document.getElementById("team-recipes");
  box.replaceChildren();
  state.balance.team_recipes.forEach((r, i) => {
    const card = el("div", { class: "card" },
      el("div", { class: "row" },
        labelInput(r), " ",
        el("button", {
          class: "danger",
          onclick: () => { state.balance.team_recipes.splice(i, 1); renderTeamRecipes(); },
        }, "remove recipe")));
    card.append(
      el("div", { class: "row" },
        el("span", { class: "muted" }, `needs ${r.moves.length} players: `),
        movesEditor(r.moves, renderTeamRecipes)),
      el("div", { class: "row" }, shapeEditor(r, renderTeamRecipes)),
      el("div", { class: "row" }, costRow(r)),
      ...(cellsOn(r.shape) === 0
        ? [el("div", { class: "row" }, el("span", { class: "error-note" },
          "⚠ shape covers no cells — the server will reject this"))]
        : []),
    );
    box.append(card);
  });
  document.getElementById("tr-count").textContent = `(${state.balance.team_recipes.length}/${MAX_RECIPES})`;
  document.getElementById("add-team-recipe").disabled =
    state.balance.team_recipes.length >= MAX_RECIPES;
}

/**
 * The encounter's single slime pool.  The readout compares the total against
 * the grid capacity so a designer can see how much starts in the reservoir.
 */
function renderEncounter() {
  const scalars = document.getElementById("encounter-scalars");
  // The hunger budget is no longer an encounter knob: the bar's capacity is
  // the sum of the players' appetite contributions (see the hunger_base /
  // appetite_scale / hunger_player_cap rate fields above).
  scalars.replaceChildren(
    el("label", {},
      el("span", {}, "team charges (whole encounter, never refills)"),
      numInput(state.encounter, "charges", 1, 4294967295)));

  const pool = state.encounter.slime;
  const box = document.getElementById("slime-pool");
  box.replaceChildren(el("div", { class: "card" },
    // Tier = how many stamps a unit needs before it is harmless: red 3,
    // yellow 2, green 1.
    el("div", { class: "row" }, el("span", { class: "muted" },
      "hazard slime units, by difficulty tier (red = 3 stamps, yellow = 2, green = 1)")),
    el("div", { class: "row" }, tierRow("", pool.tiered, 65535, renderSlimeTotal)),
    el("div", { class: "row" },
      el("span", { class: "muted" }, "neutral slime units "),
      numInput(pool, "neutral", 0, 65535, 1, "", renderSlimeTotal)),
    // Special kinds: the neutralizer is inert to every cast; the feast
    // swallows it for free and it fires a 3x3 Neutralizing Agent block as it
    // goes down.  The egg is ordinary food and hatches a baby when eaten.
    // The rock is a permanent wall nothing can touch; the canister is a free
    // pickup that refills the team's charge pool.
    el("div", { class: "row" },
      el("span", { class: "muted" }, "neutralizer specials (free pickup; fires a 3x3 Agent block when eaten) "),
      numInput(pool.special, "neutralizer", 0, 65535, 1, "", renderSlimeTotal)),
    el("div", { class: "row" },
      el("span", { class: "muted" }, "egg specials (edible; hatches a baby when eaten) "),
      numInput(pool.special, "egg", 0, 65535, 1, "", renderSlimeTotal)),
    el("div", { class: "row" },
      el("span", { class: "muted" }, "rock specials (permanent wall: impassable, cast-proof, never eaten) "),
      numInput(pool.special, "rock", 0, 65535, 1, "", renderSlimeTotal)),
    el("div", { class: "row" },
      el("span", { class: "muted" }, "canister specials (free pickup; refills team charges when eaten) "),
      numInput(pool.special, "canister", 0, 65535, 1, "", renderSlimeTotal)),
    el("div", { class: "row" },
      el("span", { class: "muted" }, "bomb specials (free pickup; destroys its 3x3 surroundings when eaten) "),
      numInput(pool.special, "bomb", 0, 65535, 1, "", renderSlimeTotal)),
  ));
  renderSlimeTotal();
}

/** Live "N units — M on grid, K waiting in the reservoir" readout. */
function renderSlimeTotal() {
  const pool = state.encounter.slime;
  const grid = state.balance.slime_grid;
  const total = TIERS.reduce((n, t) => n + pool.tiered[t], 0) + pool.neutral + sumSpecials(pool.special);
  const cells = grid.rows * grid.cols;
  const reserved = Math.max(0, total - cells);
  document.getElementById("slime-total").textContent = reserved > 0
    ? `(${total} units — ${cells} on grid, ${reserved} in the reservoir)`
    : `(${total} units — all on grid, ${cells - total} cells spare)`;
}

function renderAll() {
  renderConfigNote();
  renderRates();
  renderPlayerRecipes();
  renderTeamRecipes();
  renderEncounter();
}

// ---------------------------------------------------------------------------
// Add buttons + save
// ---------------------------------------------------------------------------

document.getElementById("add-player-recipe").addEventListener("click", () => {
  state.balance.player_recipes.push({
    label: "new_move",
    // A single anchor cell: the smallest VALID shape, so a fresh recipe never
    // starts in a state the loader would reject.
    shape: ["#"],
    cost: DEFAULT_RECIPE_COST,
  });
  renderPlayerRecipes();
});

document.getElementById("add-team-recipe").addEventListener("click", () => {
  // Seeded from the first two moves (or the first twice, which is legal — two
  // DIFFERENT players each casting it), so a fresh group is already valid.
  const labels = moveLabels();
  state.balance.team_recipes.push({
    label: "new_group",
    moves: [labels[0] ?? "", labels[1] ?? labels[0] ?? ""],
    shape: ["#"],
    cost: DEFAULT_RECIPE_COST,
  });
  renderTeamRecipes();
});

function showResult(ok, children) {
  const box = document.getElementById("save-result");
  box.className = ok ? "ok" : "error";
  box.replaceChildren(...children);
}

document.getElementById("save").addEventListener("click", async () => {
  showResult(true, [el("span", { class: "muted" }, "saving…")]);
  let res, data;
  try {
    res = await fetch("/api/tune/save", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      // `zones` is the loader's legacy field name for the slime pool; the
      // Zig side sums the array, so a single entry is the whole encounter.
      body: JSON.stringify({
        balance: {
          ...state.balance,
          // `cost` is always emitted, including 0: a free recipe is a design
          // decision, and omitting it would silently reload as the default 1.
          player_recipes: state.balance.player_recipes.map((r) => ({
            label: r.label,
            shape: r.shape,
            cost: r.cost,
          })),
          team_recipes: state.balance.team_recipes.map((r) => ({
            label: r.label,
            moves: r.moves,
            shape: r.shape,
            cost: r.cost,
          })),
        },
        encounter: {
          charges: state.encounter.charges,
          zones: [{
            tiered: sparseTiers(state.encounter.slime.tiered),
            neutral: state.encounter.slime.neutral,
            ...(sumSpecials(state.encounter.slime.special) > 0
              ? { special: sparseSpecials(state.encounter.slime.special) } : {}),
          }],
        },
      }),
    });
    data = await res.json();
  } catch (err) {
    showResult(false, [el("div", {}, `save failed: ${err.message}`)]);
    return;
  }
  if (!res.ok) {
    showResult(false, [
      el("div", {}, "Configuration rejected:"),
      el("ul", {}, ...(data.errors ?? ["unknown error"]).map((e) => el("li", {}, e))),
    ]);
    return;
  }
  const playPath = data.url;
  const playUrl = `${location.origin}${playPath}`;
  const editPath = `/tune?from=${data.hash}`;
  showResult(true, [
    el("div", {}, "Saved! Play this configuration at: "),
    el("a", { id: "play-link", href: playPath }, playUrl),
    el("span", {}, " "),
    el("button", { onclick: () => navigator.clipboard.writeText(playUrl) }, "copy"),
    el("div", { class: "muted" }, `Edit it later at ${editPath}.`),
  ]);
});

load().catch((err) => {
  document.body.prepend(el("div", { style: "color:#f88" },
    `failed to load config data: ${err.message}`));
});
