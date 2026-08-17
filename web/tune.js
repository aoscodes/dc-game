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
 *   recipes <= 64 per table, pattern 1..5 slots, team patterns 1..6,
 *   encounter hunger_max 1..65535, slime grid rows 1..16 × cols 1..16.
 */

const ELEMENTS = ["red", "green", "yellow", "blue"];
const SLOT_OPTIONS = ["dispense", "medicine", "red", "green", "yellow", "blue"];

const MAX_RECIPES = 64;
const MAX_PATTERN_SLOTS = 5;
const MAX_TEAM_PATTERNS = 6;
/** Mirrors components.MAX_GRID_ROWS / MAX_GRID_COLS. */
const MAX_GRID_ROWS = 16;
const MAX_GRID_COLS = 16;
/** Mirrors balance.DEFAULT_SLIME_GRID (used for pre-grid configs). */
const DEFAULT_SLIME_GRID = { rows: 6, cols: 10 };

/** Scalar balance fields: [key, label, min, max, step]. */
const RATE_FIELDS = [
  ["units_per_slot", "neutralization agent units per dispense", 0, 1000, 1],
  ["medicine_per_slot", "medicine per dispense", 0, 1000, 1],
  ["hunger_cost_normal", "hunger per unit eaten", 0, 1000, 1],
  ["hunger_cost_modified_extra", "extra hunger from modified slime", 0, 1000, 1],
  ["neutralize_residue_mult", "neutralized slime residue (0–1)", 0, 1, 0.05],
  ["eat_rate_units_per_s", "units eaten /s per lil guy", 0.1, 100, 0.1],
  ["cast_buffer_ms", "team recipe window (ms)", 0, 60000, 50],
  ["cast_lock_ms", "cooldown (ms)", 0, 60000, 50],
];

/**
 * @type {{
 *   balance: object,
 *   encounter: { hunger_max: number,
 *                slime: { modified: object, neutral: number } },
 * }}
 * `encounter.slime` is the ONE slime pool of the encounter: whatever does not
 * fit on the grid waits in the reservoir and refills from the top.
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

const colorsFrom = (sparse) =>
  Object.fromEntries(ELEMENTS.map((e) => [e, (sparse ?? {})[e] ?? 0]));

/**
 * Collapse a legacy `zones` array into the one slime pool, mirroring
 * config.zig: per-color modified counts and neutral units are summed.
 */
function sumZones(zones) {
  const pool = { modified: colorsFrom(null), neutral: 0 };
  for (const z of zones) {
    for (const e of ELEMENTS) pool.modified[e] += (z.modified ?? {})[e] ?? 0;
    pool.neutral += z.neutral ?? 0;
  }
  return pool;
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
      units_per_slot: bal.units_per_slot,
      medicine_per_slot: bal.medicine_per_slot,
      hunger_cost_normal: bal.hunger_cost_normal,
      hunger_cost_modified_extra: bal.hunger_cost_modified_extra,
      neutralize_residue_mult: bal.neutralize_residue_mult ?? 1.0,
      // Grid dimensions; default like the server does for pre-grid configs.
      slime_grid: {
        rows: bal.slime_grid?.rows ?? DEFAULT_SLIME_GRID.rows,
        cols: bal.slime_grid?.cols ?? DEFAULT_SLIME_GRID.cols,
      },
      // Default like the server does for older configs.
      eat_rate_units_per_s: bal.eat_rate_units_per_s ?? 2.0,
      cast_buffer_ms: bal.cast_buffer_ms ?? 500,
      cast_lock_ms: bal.cast_lock_ms ?? 500,
      player_recipes: bal.player_recipes.map((r) => ({
        label: r.label,
        pattern: [...r.pattern],
        output: { units: colorsFrom(r.output.units), medicine: colorsFrom(r.output.medicine) },
      })),
      team_recipes: bal.team_recipes.map((r) => ({
        label: r.label,
        patterns: r.patterns.map((p) => [...p]),
        output: { units: colorsFrom(r.output.units), medicine: colorsFrom(r.output.medicine) },
      })),
    },
    encounter: {
      hunger_max: def.hunger_max,
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
 * Row of 4 per-color inputs bound to a {red, green, yellow, blue} object.
 * `onChange` (optional) fires after any of them is edited.
 */
function colorRow(prefix, colors, max = 1000, onChange = null) {
  const row = el("span", { class: "colors" });
  if (prefix) row.append(el("span", { class: "muted" }, `${prefix} `));
  for (const e of ELEMENTS) {
    row.append(el("span", { class: e }, `${e[0].toUpperCase()} `));
    row.append(numInput(colors, e, 0, max, 1, "", onChange));
  }
  return row;
}

/** Dropdown sequence editing a pattern (array of slot-name strings). */
function patternEditor(pattern, onStructureChange) {
  const wrap = el("span", { class: "slotseq" });
  pattern.forEach((slot, i) => {
    const sel = el("select");
    for (const opt of SLOT_OPTIONS) {
      sel.append(el("option", slot === opt ? { value: opt, selected: "" } : { value: opt }, opt));
    }
    sel.addEventListener("change", () => { pattern[i] = sel.value; });
    wrap.append(sel);
  });
  const add = el("button", { onclick: () => { pattern.push("dispense"); onStructureChange(); } }, "+ slot");
  if (pattern.length >= MAX_PATTERN_SLOTS) add.disabled = true;
  const del = el("button", {
    class: "danger",
    onclick: () => { pattern.pop(); onStructureChange(); },
  }, "− slot");
  if (pattern.length <= 1) del.disabled = true;
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
  box.append(slimeGridRow());
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
      el("div", { class: "row" }, el("span", { class: "muted" }, "pattern "), patternEditor(r.pattern, renderPlayerRecipes)),
      el("div", { class: "row" }, colorRow("units", r.output.units)),
      el("div", { class: "row" }, colorRow("medicine", r.output.medicine)),
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
    r.patterns.forEach((p, pi) => {
      const delPattern = el("button", {
        class: "danger",
        onclick: () => { r.patterns.splice(pi, 1); renderTeamRecipes(); },
      }, "− pattern");
      if (r.patterns.length <= 1) delPattern.disabled = true;
      card.append(el("div", { class: "row" },
        el("span", { class: "muted" }, `player ${pi + 1} `),
        patternEditor(p, renderTeamRecipes), delPattern));
    });
    const addPattern = el("button", {
      onclick: () => { r.patterns.push(["red", "dispense"]); renderTeamRecipes(); },
    }, "+ pattern");
    if (r.patterns.length >= MAX_TEAM_PATTERNS) addPattern.disabled = true;
    card.append(
      el("div", { class: "row" }, addPattern),
      el("div", { class: "row" }, colorRow("units", r.output.units)),
      el("div", { class: "row" }, colorRow("medicine", r.output.medicine)),
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
  scalars.replaceChildren(el("label", {},
    el("span", {}, "hunger budget (bar capacity)"),
    numInput(state.encounter, "hunger_max", 1, 65535)));

  const pool = state.encounter.slime;
  const box = document.getElementById("slime-pool");
  box.replaceChildren(el("div", { class: "card" },
    el("div", { class: "row" }, el("span", { class: "muted" }, "modified slime units")),
    el("div", { class: "row" }, colorRow("", pool.modified, 65535, renderSlimeTotal)),
    el("div", { class: "row" },
      el("span", { class: "muted" }, "neutral slime units "),
      numInput(pool, "neutral", 0, 65535, 1, "", renderSlimeTotal)),
  ));
  renderSlimeTotal();
}

/** Live "N units — M on grid, K waiting in the reservoir" readout. */
function renderSlimeTotal() {
  const pool = state.encounter.slime;
  const grid = state.balance.slime_grid;
  const total = ELEMENTS.reduce((n, e) => n + pool.modified[e], 0) + pool.neutral;
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
    label: "new_recipe",
    pattern: ["red", "dispense", "dispense"],
    output: { units: colorsFrom(null), medicine: colorsFrom(null) },
  });
  renderPlayerRecipes();
});

document.getElementById("add-team-recipe").addEventListener("click", () => {
  state.balance.team_recipes.push({
    label: "new_team_recipe",
    patterns: [["red", "dispense"], ["red", "dispense"]],
    output: { units: colorsFrom(null), medicine: colorsFrom(null) },
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
        balance: state.balance,
        encounter: {
          hunger_max: state.encounter.hunger_max,
          zones: [state.encounter.slime],
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
