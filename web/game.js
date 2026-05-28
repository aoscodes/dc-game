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
  text("Connecting to server...", 40, 60, 24, C_TEXT);
}

// ---------------------------------------------------------------------------
// Pre-lobby screen (create / join)
// ---------------------------------------------------------------------------

/**
 * "choose"        — show Create / Join options
 * "entering_code" — user is typing a 6-char lobby code
 */
let preLobbyMode  = "choose";
let preLobbyCode  = "";
let preLobbyError = "";

function drawPreLobby() {
  clear();
  text("Dragoncon Game", 40, 60, 32, C_HEADER);

  if (preLobbyMode === "choose") {
    text("[C]  Create new lobby", 60, 160, 22, C_TEXT);
    text("[J]  Join existing lobby", 60, 200, 22, C_TEXT);
    if (preLobbyError) {
      text(preLobbyError, 60, 260, 18, "rgba(255,100,100,1)");
    }
  } else {
    text("Enter lobby code:", 60, 160, 22, C_TEXT);
    // Show typed code + blinking underscore cursor.
    const display = preLobbyCode.padEnd(6, "_");
    text(display, 60, 210, 36, "rgba(255,255,100,1)");
    text("[ENTER] to join    [ESC] back", 60, 270, 16, "rgba(170,170,170,1)");
    if (preLobbyError) {
      text(preLobbyError, 60, 310, 18, "rgba(255,100,100,1)");
    }
  }
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
    text(`${p.name}  ${p.kind}  ${ready}${conn}`, 60, y, 20, color);
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
  const sp = sprites.get(e.kind);
  if (!sp) return;

  const { img, meta } = sp;
  const { frame_w, frame_h, clips } = meta;
  const { frame } = tickAnimator(e.id, e.kind, lastAction, dt);
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
      const LINE_H = 14;
      const baseY  = cy - 4;
      for (let i = 0; i < lines.length; i++) {
        const lineY = baseY - (lines.length - 1 - i) * LINE_H;
        text(lines[i].str, cx, lineY, 11, lines[i].color);
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
      spawnFloater(label, px + jitter(), py + 22, "rgba(100,220,100,1)");
    }
  }

  // Enemy intent floater: use the snapshotted intent from the round that just resolved.
  const intent = prevEnemyIntent;
  if (intent && intent.damage > 0) {
    const elChar  = intent.element ? (ELEMENT_CHAR[intent.element]  ?? "") : "";
    const elColor = intent.element ? (ELEMENT_COLOR[intent.element] ?? "rgba(255,80,80,1)") : "rgba(255,80,80,1)";
    const label = elChar ? `-${intent.damage} ${elChar}` : `-${intent.damage}`;
    spawnFloater(label, px + jitter(), py - 22, elColor);
  }

  // DoT tick floaters — show elemental ticks on each side.
  // prevDotStacks contains the stack counts at the moment the round fired.
  // A non-zero stack on a side means it ticked damage this round.
  if (prevDotStacks) {
    // DoT on enemy side: stacks in prevDotStacks.enemies dealt damage to enemies.
    let dotEnemyY = ey + 28;
    for (let i = 0; i < 4; i++) {
      const elName = ELEMENT_NAMES[i];
      const stacks = prevDotStacks.enemies[elName];
      if (!stacks || stacks === 0) continue;
      const color  = ELEMENT_COLOR[elName] ?? "rgba(255,100,100,1)";
      spawnFloater(`${ELEMENT_CHAR[elName]} dot -${stacks * ACTION_EFFECT_VALUE}`, ex + jitter(), dotEnemyY, color);
      dotEnemyY += 22;
    }
    // DoT on player side: stacks in prevDotStacks.players dealt damage to players.
    let dotPlayerY = py + 50;
    for (let i = 0; i < 4; i++) {
      const elName = ELEMENT_NAMES[i];
      const stacks = prevDotStacks.players[elName];
      if (!stacks || stacks === 0) continue;
      const color  = ELEMENT_COLOR[elName] ?? "rgba(255,100,100,1)";
      spawnFloater(`${ELEMENT_CHAR[elName]} dot -${stacks * ACTION_EFFECT_VALUE}`, px + jitter(), dotPlayerY, color);
      dotPlayerY += 22;
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
    const y = PLAYER_ZONE.y0 - 42;
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
        text(`${ELEMENT_CHAR[elName]}×${dotP[elName]}`, dx, y + 30, 10, ELEMENT_COLOR[elName]);
        dx += 38;
      }
    }
  }

  // --- Enemy HP bar ---
  const enemySummary = game.enemies;
  if (enemies.length > 0 && enemySummary && enemySummary.hp_max > 0) {
    const { hp_current, hp_max } = enemySummary;
    const scale = hp_max > 0 ? 1 / hp_max : 0;

    // One bar; vertically centred in the same strip.
    const y = ENEMY_ZONE.y0 - 42;
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
        text(`${ELEMENT_CHAR[elName]}×${dotE[elName]}`, dx, y + 16, 10, ELEMENT_COLOR[elName]);
        dx += 38;
      }
    }
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
      // Reset pre-lobby UI state.
      preLobbyMode  = "choose";
      preLobbyCode  = "";
      preLobbyError = "";
      latestMsg = { phase: "pre_lobby" };
    } else if (msg.tag === "joining") {
      // Bridge confirmed the room exists and is connecting us.
      // Switch to connecting screen immediately so the user gets feedback
      // and any stale error text disappears.
      preLobbyMode  = "choose";
      preLobbyCode  = "";
      preLobbyError = "";
      latestMsg = { phase: "connecting" };
    } else if (msg.tag === "error") {
      // Only show an error to the user when they explicitly submitted a code.
      // If the error came from an auto-reconnect (preLobbyMode === "choose" and
      // preLobbyCode is empty), just clear stale localStorage silently.
      const userInitiated = preLobbyMode === "entering_code" || preLobbyCode.length > 0;
      if (msg.reason === "not_found") {
        preLobbyError = userInitiated ? "Lobby not found." : "";
      } else {
        preLobbyError = userInitiated ? `Error: ${msg.reason}` : "";
      }
      preLobbyMode = "choose";
      preLobbyCode = "";
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
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ action: "create" }));
      }
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
        preLobbyError = "";
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ action: "join", code: preLobbyCode }));
        }
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
