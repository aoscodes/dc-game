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
  spawnServer, spawnBridge, kill, waitForPort,
  canvasRegionHasColor,
  openFrameCollector, waitForFramePhase,
  assertGameFrame, Bot,
} = require("../helpers");
const WS = require("ws");

// ---------------------------------------------------------------------------
// Layout constants — must mirror LAYOUT.zones in web/game.js.
//
// Entities are placed at runtime within these team zones (random, collision-
// avoided), so tests assert "a sprite was painted somewhere in the zone"
// rather than at a fixed grid cell.
// ---------------------------------------------------------------------------

const PLAYER_ZONE = { x0: 30, x1: 470, y0: 200, y1: 620 };
const ENEMY_ZONE  = { x0: 554, x1: 994, y0: 200, y1: 620 };

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
  const collector = openFrameCollector(BRIDGE_PORT);
  await collector.ready;
  try {
    await page.goto(`http://localhost:${BRIDGE_PORT}/`);

    // Wait for lobby — Zig client connected and joined.
    await waitForFramePhase(collector, "lobby", 10_000);

    // Connect two bots and ready them up.
    const botA = new Bot(SERVER_PORT, "BotA");
    const botB = new Bot(SERVER_PORT, "BotB");
    await botA.connect();
    await botB.connect();

    // Ready up the browser player (Zig client) by sending Enter key.
    await page.waitForTimeout(500);
    await page.keyboard.press("Enter");

    // All three players are now ready; game should start.
    const gameFrame = await waitForFramePhase(collector, "game", 15_000);

    // Assert the frame carries real game data — not just a phase string.
    assertGameFrame(gameFrame);

    botA.close();
    botB.close();
  } finally {
    collector.close();
    await stopInfra({ server, bridge });
  }
});

test("canvas renders entity cells when in game phase", async ({ page }) => {
  const SERVER_PORT = 19122;
  const BRIDGE_PORT = 19123;
  const { server, bridge } = await startInfra(SERVER_PORT, BRIDGE_PORT);
  const collector = openFrameCollector(BRIDGE_PORT);
  await collector.ready;
  try {
    await page.goto(`http://localhost:${BRIDGE_PORT}/`);

    await waitForFramePhase(collector, "lobby", 10_000);

    const botA = new Bot(SERVER_PORT, "BotA");
    const botB = new Bot(SERVER_PORT, "BotB");
    await botA.connect();
    await botB.connect();

    await page.waitForTimeout(500);
    await page.keyboard.press("Enter");

    const gameFrame = await waitForFramePhase(collector, "game", 15_000);
    assertGameFrame(gameFrame);

    // Give it a tick to paint.
    await page.waitForTimeout(300);

    // Both teams have at least one entity in the frame.
    expect(gameFrame.game.entities.some((e) => e.team === "players")).toBe(true);
    expect(gameFrame.game.entities.some((e) => e.team === "enemies")).toBe(true);

    // Entities are placed at runtime somewhere within their team zone, so we
    // scan the whole zone rect for a painted sprite pixel rather than a fixed
    // grid cell.  A "sprite" pixel is one that is neither the background nor
    // the faint zone backdrop/border (both extremely close to background).
    const zoneHasSprite = (zone) =>
      page.evaluate(
        ({ x0, y0, x1, y1 }) => {
          const canvas = document.getElementById("canvas");
          const ctx = canvas.getContext("2d");
          const { data } = ctx.getImageData(x0, y0, x1 - x0, y1 - y0);
          for (let i = 0; i < data.length; i += 4) {
            const r = data[i], g = data[i + 1], b = data[i + 2];
            // Background #14141e ≈ (20,20,30); faint backdrop/border stay very
            // close to it.  A real sprite pixel is meaningfully brighter.
            const nearBackdrop = r <= 45 && g <= 45 && b <= 60;
            if (!nearBackdrop) return true;
          }
          return false;
        },
        zone,
      );

    expect(await zoneHasSprite(PLAYER_ZONE)).toBe(true);
    expect(await zoneHasSprite(ENEMY_ZONE)).toBe(true);

    botA.close();
    botB.close();
  } finally {
    collector.close();
    await stopInfra({ server, bridge });
  }
});

test("bots play to game_over and browser sees game_over phase", { timeout: 120_000 }, async ({ page }) => {
  const SERVER_PORT = 19124;
  const BRIDGE_PORT = 19125;
  const { server, bridge } = await startInfra(SERVER_PORT, BRIDGE_PORT);
  const collector = openFrameCollector(BRIDGE_PORT);
  await collector.ready;
  try {
    await page.goto(`http://localhost:${BRIDGE_PORT}/`);
    await waitForFramePhase(collector, "lobby", 10_000);

    const botA = new Bot(SERVER_PORT, "BotA");
    const botB = new Bot(SERVER_PORT, "BotB");
    await botA.connect();
    await botB.connect();

    // Ready up the browser player.
    await page.waitForTimeout(500);
    await page.keyboard.press("Enter");

    await waitForFramePhase(collector, "game", 15_000);

    // Inject an auto-player into the page: open a second /ws connection and
    // watch render frames.  On each turn:
    //   1. Send key "1" to select attack.
    //   2. Once action_selected="attack", navigate the cursor to the first
    //      living enemy using ArrowRight/ArrowDown as needed.
    //   3. Send Enter to confirm.
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
            if (!enemy) return;
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

    // Connect a Node.js WS client to directly observe render frames.
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

    await Promise.all([
      botA.waitForGameOver(90_000),
      botB.waitForGameOver(90_000),
      nodeGameOverPromise,
    ]);
    botA.close();
    botB.close();

    expect(nodePhases).toContain("game_over");

    // Give renderer a tick to paint the game_over screen.
    await page.waitForTimeout(200);

    // drawGameOver draws text at (40, SH/2) = (40, 384).
    // C_TEXT = rgba(230,230,230,1) — near-white.  Check the center strip.
    const hasGameOverText = await canvasRegionHasColor(
      page, 40, 354, 700, 60,
      180, 255, 180, 255, 180, 255,
    );
    expect(hasGameOverText).toBe(true);
  } finally {
    collector.close();
    await stopInfra({ server, bridge });
  }
});
