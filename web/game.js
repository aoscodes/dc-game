"use strict";

/**
 * Canvas renderer for the DragonCon game.
 *
 * Connects to the Node bridge WebSocket and renders each incoming
 * JSON render-frame onto a <canvas>.  Keyboard events are sent back
 * to the bridge so the Zig client can update its UI state.
 *
 * Layout mirrors the deleted render.zig:
 *   1024 × 768 px canvas
 *   ALLIES grid  — left side, origin (60, 180)
 *   ENEMIES grid — right side, mirrored
 *   3 cols × 4 rows, each cell 90 × 100 px with 6 px padding
 */

// ---------------------------------------------------------------------------
// Layout constants  (mirror render.zig)
// ---------------------------------------------------------------------------

const SW = 1024;
const SH = 768;

const CELL_W   = 90;
const CELL_H   = 100;
const CELL_PAD = 6;

const PLAYER_GRID_X = 60;
const PLAYER_GRID_Y = 180;

const ENEMY_GRID_X = SW - 60 - (CELL_W + CELL_PAD) * 3;
const ENEMY_GRID_Y = 180;

// ---------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------

const C_BG          = "#14141e";
const C_CELL_EMPTY  = "rgba(40,40,55,0.7)";
const C_ATB_BG      = "rgba(30,30,30,0.78)";
const C_ATB_FILL    = "rgba(255,220,50,0.9)";
const C_HP_BG       = "rgba(30,10,10,0.78)";
const C_HP_FILL     = "rgba(60,200,60,0.9)";
const C_CURSOR      = "rgba(255,255,100,0.7)";
const C_CHARGING    = "rgba(255,255,255,0.24)";
const C_TEXT        = "rgba(230,230,230,1)";
const C_HEADER      = "rgba(180,200,255,1)";
const C_ENEMY_HDR   = "rgba(255,120,80,1)";
const C_OWN_BORDER  = "rgba(255,255,60,0.78)";
const C_MENU_BG     = "rgba(20,20,40,0.86)";
const C_MENU_BORDER = C_HEADER;
const C_SEL         = C_CURSOR;

/** @param {string} cls */
function classColor(cls) {
  switch (cls) {
    case "fighter": return "rgba(60,120,200,0.86)";
    case "mage":    return "rgba(180,60,200,0.86)";
    case "healer":  return "rgba(60,200,120,0.86)";
    case "grunt":   return "rgba(160,80,40,0.86)";
    case "archer":  return "rgba(140,160,40,0.86)";
    case "shaman":  return "rgba(200,100,60,0.86)";
    case "boss":    return "rgba(200,20,20,1)";
    default:        return "rgba(128,128,128,0.86)";
  }
}

/** Short class label, mirrors render.zig */
function classLabel(cls) {
  switch (cls) {
    case "fighter": return "FTR";
    case "mage":    return "MGE";
    case "healer":  return "HLR";
    case "grunt":   return "GRT";
    case "archer":  return "ARC";
    case "shaman":  return "SHA";
    case "boss":    return "BOSS";
    default:        return cls.slice(0, 3).toUpperCase();
  }
}

// ---------------------------------------------------------------------------
// Canvas setup
// ---------------------------------------------------------------------------

const canvas = document.getElementById("canvas");
const ctx    = canvas.getContext("2d");

// ---------------------------------------------------------------------------
// Render functions
// ---------------------------------------------------------------------------

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
  ctx.lineWidth   = lineW;
  ctx.strokeRect(x + lineW / 2, y + lineW / 2, w - lineW, h - lineW);
}

// ---------------------------------------------------------------------------

function drawConnecting() {
  clear();
  text("Connecting to server...", 40, 60, 24, C_TEXT);
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
    const color = p.id === lobby.our_player_id ? "rgba(255,255,100,1)" : C_TEXT;
    const ready = p.ready ? "[READY]" : "[     ]";
    const conn  = p.connected ? "" : " (disconnected)";
    text(`${p.name}  ${p.class}  ${ready}${conn}`, 60, y, 20, color);
  });

  const pickerY = listY + 6 * 36 + 20;
  text("Class:  [1] Fighter   [2] Mage   [3] Healer", 60, pickerY, 18, C_TEXT);
  text(`Selected: ${lobby.selected_class || "fighter"}`, 60, pickerY + 28, 18, C_HEADER);
  const readyLabel = lobby.ready ? "Press ENTER to un-ready" : "Press ENTER when ready";
  text(readyLabel, 60, pickerY + 60, 18, C_TEXT);
}

function drawGrid(game, team, ox, oy) {
  const isTargeting =
    (team === "enemies" && game.is_our_turn && game.targeting_enemy) ||
    (team === "players" && game.is_our_turn && !game.targeting_enemy);

  // Empty cell backgrounds
  for (let col = 0; col < 3; col++) {
    for (let row = 0; row < 4; row++) {
      const cx = ox + col * (CELL_W + CELL_PAD);
      const cy = oy + row * (CELL_H + CELL_PAD);
      rect(cx, cy, CELL_W, CELL_H, C_CELL_EMPTY);
    }
  }

  const entities = (game.entities || []).filter(e => e.team === team);
  for (const e of entities) {
    const cx = ox + e.col * (CELL_W + CELL_PAD);
    const cy = oy + e.row * (CELL_H + CELL_PAD);

    // Class background
    rect(cx, cy, CELL_W, CELL_H, classColor(e.class));

    // Charging overlay
    if (e.state === "charging") {
      rect(cx, cy, CELL_W, CELL_H, C_CHARGING);
    }

    // HP bar
    const BAR_H_HP = 8;
    const hpFrac = e.hp_max > 0 ? e.hp / e.hp_max : 0;
    rect(cx, cy, CELL_W, BAR_H_HP, C_HP_BG);
    rect(cx, cy, CELL_W * hpFrac, BAR_H_HP, C_HP_FILL);

    // ATB bar
    const BAR_H_ATB = 6;
    const atbY = cy + CELL_H - BAR_H_ATB;
    const atbFrac = Math.max(0, Math.min(1, e.atb));
    rect(cx, atbY, CELL_W, BAR_H_ATB, C_ATB_BG);
    rect(cx, atbY, CELL_W * atbFrac, BAR_H_ATB, C_ATB_FILL);

    // Class abbreviation
    text(classLabel(e.class), cx + 4, cy + 14 + 16, 16, C_TEXT);

    // HP number
    text(String(e.hp), cx + 4, cy + 36 + 14, 14, C_TEXT);

    // Player-owned entity border
    if (e.owner === game.our_player_id && team === "players") {
      rectStroke(cx, cy, CELL_W, CELL_H, 2, C_OWN_BORDER);
    }
  }

  // Cursor overlay
  if (isTargeting && game.cursor) {
    const cc = game.cursor.col;
    const cr = game.cursor.row;
    const cx = ox + cc * (CELL_W + CELL_PAD);
    const cy = oy + cr * (CELL_H + CELL_PAD);
    rectStroke(cx, cy, CELL_W, CELL_H, 3, C_CURSOR);
  }
}

function drawActionMenu(game) {
  const mx = SW / 2 - 120;
  const my = SH - 130;
  const mw = 240;
  const mh = 110;

  rect(mx, my, mw, mh, C_MENU_BG);
  rectStroke(mx, my, mw, mh, 2, C_MENU_BORDER);

  text("Your Turn!", mx + 10, my + 8 + 18, 18, C_HEADER);

  const atkColor = game.action_selected === "attack" ? C_SEL : C_TEXT;
  const defColor = game.action_selected === "defend" ? C_SEL : C_TEXT;
  text("[1] Attack", mx + 10, my + 36 + 16, 16, atkColor);
  text("[2] Defend", mx + 10, my + 60 + 16, 16, defColor);
  text("[Enter] Confirm  [X] Cancel", mx + 10, my + 86 + 13, 13, C_TEXT);
}

function drawGame(game) {
  clear();

  const wave = game.wave || "";
  text(`Wave: ${wave}`, 40, 30 + 20, 20, C_HEADER);

  text("ALLIES",  PLAYER_GRID_X, 155 + 18, 18, C_HEADER);
  text("ENEMIES", ENEMY_GRID_X,  155 + 18, 18, C_ENEMY_HDR);

  drawGrid(game, "players", PLAYER_GRID_X, PLAYER_GRID_Y);
  drawGrid(game, "enemies", ENEMY_GRID_X,  ENEMY_GRID_Y);

  if (game.is_our_turn) {
    drawActionMenu(game);
  }
}

function drawGameOver() {
  clear();
  text("Game Over!  Press any key to return to lobby.", 40, SH / 2, 24, C_TEXT);
}

// ---------------------------------------------------------------------------
// Frame dispatch
// ---------------------------------------------------------------------------

function renderFrame(msg) {
  switch (msg.phase) {
    case "connecting": drawConnecting();      break;
    case "lobby":      drawLobby(msg.lobby);  break;
    case "game":       drawGame(msg.game);    break;
    case "game_over":  drawGameOver();        break;
    default:           drawConnecting();
  }
}

// ---------------------------------------------------------------------------
// WebSocket connection to bridge
// ---------------------------------------------------------------------------

let ws = null;

function connect() {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  const url = `${proto}//${location.host}/ws`;
  ws = new WebSocket(url);

  ws.addEventListener("open",    ()    => console.log("[game] connected to bridge"));
  ws.addEventListener("close",   ()    => setTimeout(connect, 1_000));
  ws.addEventListener("error",   (e)   => console.error("[game] ws error", e));
  ws.addEventListener("message", (ev)  => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    if (msg.tag === "render") renderFrame(msg);
  });
}

connect();

// ---------------------------------------------------------------------------
// Keyboard input → bridge
// ---------------------------------------------------------------------------

const FORWARDED_KEYS = new Set([
  "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
  "Enter", "Escape",
  "1", "2", "3",
  "z", "Z", "x", "X",
]);

document.addEventListener("keydown", (e) => {
  if (!FORWARDED_KEYS.has(e.key)) return;
  e.preventDefault();
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ key: e.key }));
  }
});
