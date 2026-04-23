"use strict";

const SW = 1024;
const SH = 768;

const CELL_W = 90;
const CELL_H = 100;
const CELL_PAD = 6;

const PLAYER_GRID_X = 60;
const PLAYER_GRID_Y = 180;

const ENEMY_GRID_X = SW - 60 - (CELL_W + CELL_PAD) * 3;
const ENEMY_GRID_Y = 180;

const C_BG = "#14141e";
const C_CELL_EMPTY = "rgba(40,40,55,0.7)";
const C_ATB_BG = "rgba(30,30,30,0.78)";
const C_ATB_FILL = "rgba(255,220,50,0.9)";
const C_HP_BG = "rgba(30,10,10,0.78)";
const C_HP_FILL = "rgba(60,200,60,0.9)";
const C_CURSOR = "rgba(255,255,100,0.7)";
const C_CHARGING = "rgba(255,255,255,0.24)";
const C_TEXT = "rgba(230,230,230,1)";
const C_HEADER = "rgba(180,200,255,1)";
const C_ENEMY_HDR = "rgba(255,120,80,1)";
const C_OWN_BORDER = "rgba(255,255,60,0.78)";
const C_MENU_BG = "rgba(20,20,40,0.86)";
const C_MENU_BORDER = C_HEADER;
const C_SEL = C_CURSOR;

function classColor(cls) {
  switch (cls) {
    case "fighter": return "rgba(60,120,200,0.86)";
    case "mage": return "rgba(180,60,200,0.86)";
    case "healer": return "rgba(60,200,120,0.86)";
    case "grunt": return "rgba(160,80,40,0.86)";
    case "archer": return "rgba(140,160,40,0.86)";
    case "shaman": return "rgba(200,100,60,0.86)";
    case "boss": return "rgba(200,20,20,1)";
    default: return "rgba(128,128,128,0.86)";
  }
}

function classLabel(cls) {
  switch (cls) {
    case "fighter": return "FTR";
    case "mage": return "MGE";
    case "healer": return "HLR";
    case "grunt": return "GRT";
    case "archer": return "ARC";
    case "shaman": return "SHA";
    case "boss": return "BOSS";
    default: return cls.slice(0, 3).toUpperCase();
  }
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

function drawFull() {
  clear();
  text("Session full (max 6 players).", 40, SH / 2 - 16, 24, C_TEXT);
  text("Close another tab to free a slot.", 40, SH / 2 + 16, 18, C_TEXT);
}

// Draw the 3×2 lobby position-picker grid.
// Columns are visually flipped so col 0 (front rank) is on the right, matching
// the in-game ally grid orientation (closest to enemies = right edge).
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

  for (let col = 0; col < 3; col++) {
    for (let row = 0; row < 4; row++) {
      // Flip columns: col 0 (front) renders at the right edge
      const cx = ox + (2 - col) * (CW + CP);
      const cy = oy + row * (CH + CP);

      const key = `${col},${row}`;
      const occ = occupied[key];
      const isOurs = occ && occ.id === lobby.player_id;
      const isCursor = col === (lobby.chosen_col ?? 0) && row === (lobby.chosen_row ?? 0);

      // Cell background
      let bg = C_CELL_EMPTY;
      if (occ) bg = isOurs ? "rgba(80,160,80,0.86)" : "rgba(120,80,80,0.7)";
      rect(cx, cy, CW, CH, bg);

      // Cursor highlight
      if (isCursor) rectStroke(cx, cy, CW, CH, 3, C_CURSOR);

      // Player name or col label
      if (occ) {
        const nameColor = isOurs ? "rgba(255,255,100,1)" : C_TEXT;
        text(occ.name.slice(0, 6), cx + 4, cy + 20, 13, nameColor);
        text(occ.class.slice(0, 3).toUpperCase(), cx + 4, cy + 38, 12, C_TEXT);
      }
    }
  }

  // Column rank labels below the grid (front = right, back = left, matching flip)
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
    text(`${p.name}  ${p.class}  ${ready}${conn}`, 60, y, 20, color);
  });

  const pickerY = listY + 6 * 36 + 20;
  const readyLabel = lobby.ready ? "Press ENTER to un-ready" : "Press ENTER when ready";
  text(readyLabel, 60, pickerY, 18, C_TEXT);

  // Position picker
  const gridX = SW - 290;
  const gridY = 130;
  text("Position  [Arrow keys]", gridX, gridY - 14, 14, "rgba(180,200,255,0.9)");
  drawLobbyGrid(lobby, gridX, gridY);
}

function drawGrid(game, team, ox, oy) {
  // Flip player columns so col 0 (front rank) renders on the right edge, facing enemies
  const colX = (col) => team === "players"
    ? ox + (2 - col) * (CELL_W + CELL_PAD)
    : ox + col * (CELL_W + CELL_PAD);

  // Draw empty cells
  for (let col = 0; col < 3; col++) {
    for (let row = 0; row < 4; row++) {
      rect(colX(col), oy + row * (CELL_H + CELL_PAD), CELL_W, CELL_H, C_CELL_EMPTY);
    }
  }

  const entities = (game.entities || []).filter(e => e.team === team);
  for (const e of entities) {
    // Derive grid position from slot (spawn order): col = slot % 3, row = slot / 3
    const col = e.slot % 3;
    const row = Math.floor(e.slot / 3);
    const cx = colX(col);
    const cy = oy + row * (CELL_H + CELL_PAD);

    // Class background
    rect(cx, cy, CELL_W, CELL_H, classColor(e.class));

    // HP bar
    const BAR_H = 8;
    const hpFrac = e.hp_max > 0 ? e.hp / e.hp_max : 0;
    rect(cx, cy, CELL_W, BAR_H, C_HP_BG);
    rect(cx, cy, CELL_W * hpFrac, BAR_H, C_HP_FILL);

    // Shield bar (below HP bar, blue)
    if (e.shield_hp > 0) {
      const shieldFrac = Math.min(1, e.shield_hp / e.hp_max);
      rect(cx, cy + BAR_H, CELL_W, BAR_H, "rgba(30,30,120,0.6)");
      rect(cx, cy + BAR_H, CELL_W * shieldFrac, BAR_H, "rgba(80,160,255,0.9)");
    }

    // Class abbreviation
    text(classLabel(e.class), cx + 4, cy + 20 + 16, 16, C_TEXT);

    // HP number
    text(String(e.hp), cx + 4, cy + 44 + 14, 14, C_TEXT);

    // Player-owned entity border
    if (e.owner === game.player_id && team === "players") {
      rectStroke(cx, cy, CELL_W, CELL_H, 2, C_OWN_BORDER);
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

  const pending = game.pending_action;
  const dColor = pending === "damage" ? C_SEL : C_TEXT;
  const sColor = pending === "shield" ? C_SEL : C_TEXT;
  const hColor = pending === "heal"   ? C_SEL : C_TEXT;
  text("[1] Damage", mx + 10,        my + 14 + 16, 16, dColor);
  text("[2] Shield", mx + 10 + 106,  my + 14 + 16, 16, sColor);
  text("[3] Heal",   mx + 10 + 212,  my + 14 + 16, 16, hColor);

  // Round timer bar
  const timerFrac = game.round_duration > 0
    ? Math.max(0, Math.min(1, game.round_timer / game.round_duration))
    : 0;
  rect(mx + 10, my + 50, mw - 20, 10, "rgba(30,30,30,0.8)");
  rect(mx + 10, my + 50, (mw - 20) * timerFrac, 10, "rgba(255,200,50,0.9)");
  text(`Round: ${game.round_timer !== undefined ? game.round_timer.toFixed(1) : "?"}s`, mx + 10, my + 78, 13, C_TEXT);
}

function drawGame(game) {
  clear();

  const wave = game.wave || "";
  text(`Wave: ${wave}`, 40, 30 + 20, 20, C_HEADER);

  text("ALLIES", PLAYER_GRID_X, 155 + 18, 18, C_HEADER);
  text("ENEMIES", ENEMY_GRID_X, 155 + 18, 18, C_ENEMY_HDR);

  drawGrid(game, "players", PLAYER_GRID_X, PLAYER_GRID_Y);
  drawGrid(game, "enemies", ENEMY_GRID_X, ENEMY_GRID_Y);

  drawActionMenu(game);
}

function drawGameOver() {
  clear();
  text("Game Over!  Press any key to return to lobby.", 40, SH / 2, 24, C_TEXT);
}

function renderFrame(msg) {
  switch (msg.phase) {
    case "connecting": drawConnecting(); break;
    case "lobby": drawLobby(msg.lobby); break;
    case "game": drawGame(msg.game); break;
    case "game_over": drawGameOver(); break;
    default: drawConnecting();
  }
}

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
    if (msg.tag === "render") renderFrame(msg);
    else if (msg.tag === "full") drawFull();
  });
}

connect();

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
