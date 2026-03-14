"use strict";
/**
 * lobby.test.js — verify the browser reaches lobby phase.
 *
 * Ports: server=19110, bridge=19111
 *
 * Flow:
 *   1. Spawn server + bridge.
 *   2. Open browser page — bridge connects, Zig client sends join_lobby,
 *      server replies with lobby_update, client emits lobby render frame.
 *   3. Assert canvas shows lobby content (non-blank, phase=lobby).
 *   4. Send key events via the bridge WS and confirm internal state updates.
 */

const { test, expect } = require("@playwright/test");
const {
  spawnServer, spawnBridge, kill, waitForPort,
  waitForCanvasContent, ROOT,
} = require("../helpers");
const WS = require(require("path").join(ROOT, "bridge/node_modules/ws"));

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
  // Track render phases via WS frame interception before navigating.
  const phases = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (frame) => {
      try {
        const msg = JSON.parse(frame.payload);
        if (msg.tag === "render") phases.push(msg.phase);
      } catch {}
    });
  });

  await page.goto(`http://localhost:${BRIDGE_PORT}/`);

  // Wait until we see a lobby-phase render frame.
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (phases.includes("lobby")) break;
    await page.waitForTimeout(100);
  }
  expect(phases).toContain("lobby");

  // Canvas must have non-blank pixels.
  await waitForCanvasContent(page, 5_000);
});

test("canvas shows 'Dragoncon Game' text region is painted", async ({ page }) => {
  await page.goto(`http://localhost:${BRIDGE_PORT}/`);
  await waitForCanvasContent(page, 10_000);

  // The title is drawn at y≈20, large font.  Sample a horizontal strip
  // at y=40 (below the title text baseline) and expect non-background pixels.
  const hasTextPixels = await page.evaluate(() => {
    const canvas = document.getElementById("canvas");
    const ctx = canvas.getContext("2d");
    // Sample the top region where the title is rendered (x: 40-400, y: 20-60)
    const { data } = ctx.getImageData(40, 20, 360, 40);
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i + 1], b = data[i + 2];
      if (!(r <= 25 && g <= 25 && b <= 35)) return true;
    }
    return false;
  });
  expect(hasTextPixels).toBe(true);
});

test("key event forwarding: KEY:2 reaches Zig and updates render frame", async ({ page }) => {
  await page.goto(`http://localhost:${BRIDGE_PORT}/`);
  await waitForCanvasContent(page, 10_000);

  // Connect a second browser WS client to capture render frames directly.
  const receivedPhases = [];
  const receivedClasses = [];

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
  const before = await page.evaluate(() => window.__lastClass);

  // Press '2' in the browser — game.js forwards KEY:2 → bridge → Zig stdin.
  await page.keyboard.press("2");

  // Wait for selected_class to change to 'mage'.
  await page.waitForFunction(
    () => window.__lastClass === "mage",
    { timeout: 5_000 },
  );
  const after = await page.evaluate(() => window.__lastClass);
  expect(after).toBe("mage");
  void before; // before may be 'fighter' initially — just assert final state
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
  const before = await page.evaluate(() => window.__ready);
  expect(before).toBe(false);

  // Press Enter — should toggle ready.
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => window.__ready === true, { timeout: 5_000 });
  expect(await page.evaluate(() => window.__ready)).toBe(true);
});
