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
 *   zones 1..16, encounter hunger_max 1..65535.
 */

const ELEMENTS = ["red", "green", "yellow", "blue"];
const SLOT_OPTIONS = ["dispense", "medicine", "red", "green", "yellow", "blue"];

const MAX_RECIPES = 64;
const MAX_PATTERN_SLOTS = 5;
const MAX_TEAM_PATTERNS = 6;
const MAX_ZONES = 16;

/** Scalar balance fields: [key, label, min, max, step]. */
const RATE_FIELDS = [
  ["casts_per_round", "casts per round", 1, 10, 1],
  ["units_per_slot", "neutralization agent units per dispense", 0, 1000, 1],
  ["medicine_per_slot", "medicine per dispense", 0, 1000, 1],
  ["hunger_cost_normal", "hunger per unit eaten", 0, 1000, 1],
  ["hunger_cost_modified_extra", "extra hunger from modified slime", 0, 1000, 1],
  ["round_duration_default_s", "round duration (seconds)", 0.5, 300, 0.5],
];

/** @type {{balance: object, encounter: {hunger_max: number, zones: object[]}}} */
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
      casts_per_round: bal.casts_per_round,
      units_per_slot: bal.units_per_slot,
      medicine_per_slot: bal.medicine_per_slot,
      hunger_cost_normal: bal.hunger_cost_normal,
      hunger_cost_modified_extra: bal.hunger_cost_modified_extra,
      round_duration_default_s: bal.round_duration_default_s,
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
      zones: def.zones.map((z) => ({ modified: colorsFrom(z.modified), neutral: z.neutral ?? 0 })),
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
function numInput(obj, key, min, max, step = 1, cls = "") {
  const input = el("input", { type: "number", min, max, step, class: cls });
  input.value = obj[key];
  input.addEventListener("change", () => {
    let v = parseFloat(input.value);
    if (Number.isNaN(v)) v = min;
    v = clamp(v, min, max);
    if (step === 1) v = Math.round(v);
    obj[key] = v;
    input.value = v;
  });
  return input;
}

/** Row of 4 per-color inputs bound to a {red, green,yellow,blue} object. */
function colorRow(prefix, colors, max = 1000) {
  const row = el("span", { class: "colors" });
  if (prefix) row.append(el("span", { class: "muted" }, `${prefix} `));
  for (const e of ELEMENTS) {
    row.append(el("span", { class: e }, `${e[0].toUpperCase()} `));
    row.append(numInput(colors, e, 0, max));
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

function renderRates() {
  const box = document.getElementById("rates");
  box.replaceChildren(el("legend", {}, "Rates & costs"));
  for (const [key, text, min, max, step] of RATE_FIELDS) {
    box.append(
      el("label", {}, el("span", {}, text), numInput(state.balance, key, min, max, step)),
      el("br"),
    );
  }
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

function renderEncounter() {
  const scalars = document.getElementById("encounter-scalars");
  scalars.replaceChildren(el("label", {},
    el("span", {}, "hunger budget (bar capacity)"),
    numInput(state.encounter, "hunger_max", 1, 65535)));

  const box = document.getElementById("zones");
  box.replaceChildren();
  state.encounter.zones.forEach((z, i) => {
    const del = el("button", {
      class: "danger",
      onclick: () => { state.encounter.zones.splice(i, 1); renderEncounter(); },
    }, "remove round");
    if (state.encounter.zones.length <= 1) del.disabled = true;
    box.append(el("div", { class: "card" },
      el("div", { class: "row" },
        el("span", { class: "muted" }, `round ${i + 1} — modified slime `),
        del),
      el("div", { class: "row" },
        colorRow("", z.modified),
        el("span", { class: "muted" }, " neutral "),
        numInput(z, "neutral", 0, 1000)),
    ));
  });
  document.getElementById("zone-count").textContent =
    `(${state.encounter.zones.length}/${MAX_ZONES} rounds — one zone eaten per round)`;
  document.getElementById("add-zone").disabled = state.encounter.zones.length >= MAX_ZONES;
}

function renderAll() {
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

document.getElementById("add-zone").addEventListener("click", () => {
  state.encounter.zones.push({ modified: colorsFrom(null), neutral: 0 });
  renderEncounter();
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
      body: JSON.stringify(state),
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
  const playUrl = `${location.origin}${data.url}`;
  showResult(true, [
    el("div", {}, "Saved! Play this configuration at: "),
    el("a", { id: "play-link", href: data.url }, playUrl),
    el("span", {}, " "),
    el("button", { onclick: () => navigator.clipboard.writeText(playUrl) }, "copy"),
    el("div", { class: "muted" },
      `Edit it later at /tune?from=${data.hash}.`),
  ]);
});

load().catch((err) => {
  document.body.prepend(el("div", { style: "color:#f88" },
    `failed to load config data: ${err.message}`));
});
