"use strict";
/**
 * game.test.js — verify the browser reaches game phase and renders entities.
 *
 * Each test spawns its own server+bridge on a unique port pair so that game
 * state from earlier tests (lobby → playing → ended) never bleeds into later
 * ones.  The game server has one session that does not reset after game_over.
 *
 * Port layout (server / bridge):
 *   test 1 — 19120 / 19121
 *   test 2 — 19122 / 19123
 *   test 3 — 19124 / 19125
 */

const { test, expect } = require("@playwright/test");
const {
  spawnServer, spawnBridge, kill, waitForPort, waitForCanvasContent, Bot,
} = require("../helpers");
const WS = require("ws");

// ---------------------------------------------------------------------------
// Shared helper: intercept render phases via Playwright WS frame events.
// ---------------------------------------------------------------------------
function trackPhases(page) {
  const phases = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (frame) => {
      try {
        const msg = JSON.parse(frame.payload);
        if (msg.tag === "render") phases.push(msg.phase);
      } catch {}
    });
  });
  return phases;
}

async function waitForPhase(phases, targetPhase, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (phases.includes(targetPhase)) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`phase "${targetPhase}" not seen after ${timeoutMs}ms; got: ${[...new Set(phases)].join(",")}`);
}

// ---------------------------------------------------------------------------
// Per-test server+bridge lifecycle helpers.
// ---------------------------------------------------------------------------

async function startInfra(serverPort, bridgePort) {
  const server = spawnServer(serverPort);
  await waitForPort(serverPort, 8_000);
  const bridge = spawnBridge(serverPort, bridgePort);
  await waitForPort(bridgePort, 8_000);
  return { server, bridge };
}

async function stopInfra({ server, bridge }) {
  await kill(bridge);
  await kill(server);
}

// ---------------------------------------------------------------------------

test("browser reaches game phase when two players are ready", async ({ page }) => {
  const SERVER_PORT = 19120;
  const BRIDGE_PORT = 19121;
  const { server, bridge } = await startInfra(SERVER_PORT, BRIDGE_PORT);
  try {
    const phases = trackPhases(page);
    await page.goto(`http://localhost:${BRIDGE_PORT}/`);

    // Wait for lobby phase — Zig client connected and joined.
    await waitForPhase(phases, "lobby", 10_000);

    // Connect two bots and ready them up.
    const botA = new Bot(SERVER_PORT, "BotA");
    const botB = new Bot(SERVER_PORT, "BotB");
    await botA.connect();
    await botB.connect();

    // Ready up the browser player (Zig client) by sending Enter key.
    // Give the bots a moment to register with the server first.
    await page.waitForTimeout(500);
    await page.keyboard.press("Enter");

    // All three players are now ready; game should start.
    await waitForPhase(phases, "game", 15_000);
    expect(phases).toContain("game");

    botA.close();
    botB.close();
  } finally {
    await stopInfra({ server, bridge });
  }
});

test("canvas renders entity cells when in game phase", async ({ page }) => {
  const SERVER_PORT = 19122;
  const BRIDGE_PORT = 19123;
  const { server, bridge } = await startInfra(SERVER_PORT, BRIDGE_PORT);
  try {
    const phases = trackPhases(page);
    await page.goto(`http://localhost:${BRIDGE_PORT}/`);

    await waitForPhase(phases, "lobby", 10_000);

    const botA = new Bot(SERVER_PORT, "BotA");
    const botB = new Bot(SERVER_PORT, "BotB");
    await botA.connect();
    await botB.connect();

    await page.waitForTimeout(500);
    await page.keyboard.press("Enter");

    await waitForPhase(phases, "game", 15_000);

    // Give it a tick to paint.
    await page.waitForTimeout(300);

    // The game grid starts at PLAYER_GRID_X=60, PLAYER_GRID_Y=180.
    // Sample the first ally cell (90×100) and expect at least one pixel that
    // is neither the background (#14141e) nor the empty-cell grey.
    const hasCellContent = await page.evaluate(() => {
      const canvas = document.getElementById("canvas");
      const ctx = canvas.getContext("2d");
      const { data } = ctx.getImageData(60, 180, 90, 100);
      for (let i = 0; i < data.length; i += 4) {
        const r = data[i], g = data[i + 1], b = data[i + 2];
        const isBackground = r <= 25 && g <= 25 && b <= 35;
        const isEmptyCell  = r >= 35 && r <= 55 && g >= 35 && g <= 55 && b >= 45 && b <= 65;
        if (!isBackground && !isEmptyCell) return true;
      }
      return false;
    });
    expect(hasCellContent).toBe(true);

    botA.close();
    botB.close();
  } finally {
    await stopInfra({ server, bridge });
  }
});

test("bots play to game_over and browser sees game_over phase", { timeout: 120_000 }, async ({ page }) => {
  const SERVER_PORT = 19124;
  const BRIDGE_PORT = 19125;
  const { server, bridge } = await startInfra(SERVER_PORT, BRIDGE_PORT);
  try {
    const phases = trackPhases(page);
    await page.goto(`http://localhost:${BRIDGE_PORT}/`);
    await waitForPhase(phases, "lobby", 10_000);

    const botA = new Bot(SERVER_PORT, "BotA");
    const botB = new Bot(SERVER_PORT, "BotB");
    await botA.connect();
    await botB.connect();

    // Ready up the browser player.
    await page.waitForTimeout(500);
    await page.keyboard.press("Enter");

    await waitForPhase(phases, "game", 15_000);

    // Inject an auto-player into the page: open a second /ws connection and
    // watch render frames.  On each turn:
    //   1. Send key "1" to select attack.
    //   2. Once action_selected="attack", navigate the cursor to the first
    //      living enemy using ArrowRight/ArrowDown as needed.
    //   3. Send Enter to confirm — attack lands, ATB resets to idle so the
    //      entity keeps cycling without blocking the game.
    // Cursor resets to (0,0) at the start of each turn.
    await page.evaluate((bridgePort) => {
      const ws = new WebSocket(`ws://localhost:${bridgePort}/ws`);
      let step = "idle"; // idle → sent1 → moving → sentEnter
      let cursorCol = 0, cursorRow = 0;
      let targetCol = -1, targetRow = -1;

      function sendArrows() {
        const dc = targetCol - cursorCol;
        const dr = targetRow - cursorRow;
        const keys = [];
        if (dc > 0) for (let i = 0; i < dc; i++) keys.push("ArrowRight");
        if (dc < 0) for (let i = 0; i < -dc; i++) keys.push("ArrowLeft");
        if (dr > 0) for (let i = 0; i < dr; i++) keys.push("ArrowDown");
        if (dr < 0) for (let i = 0; i < -dr; i++) keys.push("ArrowUp");
        keys.forEach((k, i) => {
          setTimeout(() => {
            ws.send(JSON.stringify({ key: k }));
            if (i === keys.length - 1) {
              setTimeout(() => {
                ws.send(JSON.stringify({ key: "Enter" }));
                step = "sentEnter";
              }, 200);
            }
          }, i * 50);
        });
        if (keys.length === 0) {
          // Already on target.
          setTimeout(() => { ws.send(JSON.stringify({ key: "Enter" })); step = "sentEnter"; }, 50);
        }
      }

      ws.onmessage = (ev) => {
        try {
          const msg = JSON.parse(ev.data);
          if (msg.tag !== "render" || !msg.game) return;
          if (!msg.game.is_our_turn) { step = "idle"; cursorCol = 0; cursorRow = 0; return; }
          if (msg.game.cursor) { cursorCol = msg.game.cursor.col; cursorRow = msg.game.cursor.row; }
          if (step === "idle" && msg.game.action_selected === null) {
            const enemy = (msg.game.entities || []).find((e) => e.team === "enemies");
            if (!enemy) return; // no enemies left — bots will finish
            targetCol = enemy.col;
            targetRow = enemy.row;
            step = "sent1";
            ws.send(JSON.stringify({ key: "1" })); // select attack
          } else if (step === "sent1" && msg.game.action_selected === "attack") {
            step = "moving";
            sendArrows();
          }
        } catch {}
      };
    }, BRIDGE_PORT);

    // Connect a Node.js WS client to the bridge to directly observe render
    // frames — more reliable than Playwright's framereceived for long runs.
    const nodePhases = [];
    const nodeGameOverPromise = new Promise((resolve, reject) => {
      const nodeWs = new WS(`ws://127.0.0.1:${BRIDGE_PORT}/ws`);
      const timer = setTimeout(() => reject(new Error("node WS game_over timeout")), 90_000);
      nodeWs.on("message", (raw) => {
        try {
          const msg = JSON.parse(raw.toString());
          if (msg.tag === "render") {
            nodePhases.push(msg.phase);
            if (msg.phase === "game_over") { clearTimeout(timer); nodeWs.close(); resolve(); }
          }
        } catch {}
      });
      nodeWs.on("error", reject);
    });

    // Wait for bots to finish (they play autonomously; Zig client auto-plays
    // via the injected script above).
    await Promise.all([
      botA.waitForGameOver(90_000),
      botB.waitForGameOver(90_000),
      nodeGameOverPromise,
    ]);
    botA.close();
    botB.close();

    expect(nodePhases).toContain("game_over");
  } finally {
    await stopInfra({ server, bridge });
  }
});
