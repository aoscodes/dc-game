"use strict";
/**
 * lobby.test.js — verify the browser reaches lobby phase with correct content.
 *
 * Ports: server=19110, bridge=19111
 *
 * Flow:
 *   1. Spawn server + bridge.
 *   2. Open browser page — bridge connects, Zig client sends join_lobby,
 *      server replies with lobby_update, client emits lobby render frame.
 *   3. Assert canvas shows lobby content (non-blank, correct colours, phase=lobby).
 *   4. Assert lobby frame fields are well-formed (join_code, selected_class, etc.).
 *   5. Send key events via the bridge WS and confirm internal state updates.
 */

const { test, expect } = require("@playwright/test");
const {
  spawnServer, spawnBridge, kill, waitForPort,
  waitForCanvasContent, canvasRegionHasColor,
  openFrameCollector, waitForFramePhase,
  assertLobbyFrame,
} = require("../helpers");
const WS = require("ws");

const SERVER_PORT = 19110;
const BRIDGE_PORT = 19111;

let server, bridge;

test.beforeAll(async () => {
  server = spawnServer(SERVER_PORT);
  await waitForPort(SERVER_PORT, 8_000);
  bridge = spawnBridge(SERVER_PORT, BRIDGE_PORT);
  await waitForPort(BRIDGE_PORT, 8_000);
});

test.afterAll(async () => {
  await kill(bridge);
  await kill(server);
});

test("canvas renders lobby phase after server connection", async ({ page }) => {
  const collector = openFrameCollector(BRIDGE_PORT);
  await collector.ready;
  try {
    await page.goto(`http://localhost:${BRIDGE_PORT}/`);

    // Wait for lobby phase and grab the frame.
    const frame = await waitForFramePhase(collector, "lobby", 10_000);

    // Verify the frame has well-formed lobby fields — not just a phase string.
    assertLobbyFrame(frame);

    // Canvas must have non-blank pixels.
    await waitForCanvasContent(page, 5_000);
  } finally {
    collector.close();
  }
});

test("canvas shows 'Dragoncon Game' title in C_HEADER colour", async ({ page }) => {
  // C_HEADER = rgba(180,200,255,1) — the title text colour.
  // drawLobby: text("Dragoncon Game", 40, 52, 32, C_HEADER)
  // The text baseline is at y=52; with a 32px font glyphs extend up to ~y=20.
  // Sample the region x=40..400, y=20..60.
  const collector = openFrameCollector(BRIDGE_PORT);
  await collector.ready;
  try {
    await page.goto(`http://localhost:${BRIDGE_PORT}/`);
    await waitForFramePhase(collector, "lobby", 10_000);
    await waitForCanvasContent(page, 5_000);

    // Check for C_HEADER-coloured pixels (near-blue-white).
    // C_HEADER = rgb(180,200,255) — allow ±20 per channel for antialiasing.
    const hasTitleColor = await canvasRegionHasColor(
      page, 40, 20, 360, 40,
      155, 210,  // r: 180 ± 25
      175, 225,  // g: 200 ± 25
      225, 255,  // b: 255 ± 30
    );
    expect(hasTitleColor).toBe(true);
  } finally {
    collector.close();
  }
});

test("key event forwarding: KEY:2 reaches Zig and updates render frame", async ({ page }) => {
  await page.goto(`http://localhost:${BRIDGE_PORT}/`);
  await waitForCanvasContent(page, 10_000);

  // Connect a second browser WS client to capture render frames directly.
  await page.evaluate((bridgePort) => {
    window.__testWs = new WebSocket(`ws://localhost:${bridgePort}/ws`);
    window.__testWs.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data);
        if (msg.tag === "render" && msg.lobby) {
          window.__lastClass = msg.lobby.selected_class;
        }
      } catch {}
    };
  }, BRIDGE_PORT);

  // Wait for at least one lobby frame so we have a baseline.
  await page.waitForFunction(() => !!window.__lastClass, { timeout: 8_000 });

  // Press '2' in the browser — game.js forwards KEY:2 → bridge → Zig stdin.
  await page.keyboard.press("2");

  // Wait for selected_class to change to 'mage'.
  await page.waitForFunction(
    () => window.__lastClass === "mage",
    { timeout: 5_000 },
  );
  expect(await page.evaluate(() => window.__lastClass)).toBe("mage");
});

test("Enter key toggles ready state", async ({ page }) => {
  await page.goto(`http://localhost:${BRIDGE_PORT}/`);
  await waitForCanvasContent(page, 10_000);

  await page.evaluate((bridgePort) => {
    window.__ready = false;
    window.__testWs2 = new WebSocket(`ws://localhost:${bridgePort}/ws`);
    window.__testWs2.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data);
        if (msg.tag === "render" && msg.lobby) {
          window.__ready = msg.lobby.ready;
        }
      } catch {}
    };
  }, BRIDGE_PORT);

  // Wait for a lobby frame.
  await page.waitForFunction(() => window.__ready !== undefined, { timeout: 8_000 });
  expect(await page.evaluate(() => window.__ready)).toBe(false);

  // Press Enter — should toggle ready.
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => window.__ready === true, { timeout: 5_000 });
  expect(await page.evaluate(() => window.__ready)).toBe(true);
});
