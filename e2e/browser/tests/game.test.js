"use strict";
/**
 * game.test.js — verify the browser reaches game phase and renders the
 * Slime Feast board (players + slime field).
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
// Layout constants — must mirror LAYOUT.slimeField in web/game.js.
//
// No player sprites are rendered; slime blobs + cosmetic Lil Guys render
// inside the slime field columns.  Tests assert "something was painted
// somewhere in the region" rather than at fixed positions.
// ---------------------------------------------------------------------------

const SLIME_FIELD = { x0: 40, x1: 984, y0: 220, y1: 620 };

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

test("canvas renders the slime field in game phase", async ({ page }) => {
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

    // Player entities exist; zones carry slime.
    expect(gameFrame.game.entities.length).toBeGreaterThan(0);
    expect(gameFrame.game.zones.length).toBeGreaterThan(0);

    // Regions are painted at runtime, so we scan whole rects for a painted
    // pixel rather than fixed positions.  A "content" pixel is one that is
    // neither the background nor the faint zone backdrop/border.
    const regionHasContent = (region) =>
      page.evaluate(
        ({ x0, y0, x1, y1 }) => {
          const canvas = document.getElementById("canvas");
          const ctx = canvas.getContext("2d");
          const { data } = ctx.getImageData(x0, y0, x1 - x0, y1 - y0);
          for (let i = 0; i < data.length; i += 4) {
            const r = data[i], g = data[i + 1], b = data[i + 2];
            // Background #14141e ≈ (20,20,30); faint backdrop/border stay very
            // close to it.  Real content is meaningfully brighter.
            const nearBackdrop = r <= 45 && g <= 45 && b <= 60;
            if (!nearBackdrop) return true;
          }
          return false;
        },
        region,
      );

    expect(await regionHasContent(SLIME_FIELD)).toBe(true);

    botA.close();
    botB.close();
  } finally {
    collector.close();
    await stopInfra({ server, bridge });
  }
});

test("encounter runs to game_over and browser sees game_over phase", { timeout: 120_000 }, async ({ page }) => {
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

    // The encounter ends on its own: one zone is consumed per round, and the
    // bots dispense fire agents every round (Bot._sendCombo).  Just wait.
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
