"use strict";
/**
 * canvas.test.js — verify the page loads, canvas is the right size, and
 * the renderer produces non-blank output once the bridge is connected.
 *
 * Ports: server=19100, bridge=19101
 */

const { test, expect } = require("@playwright/test");
const {
  spawnServer, spawnBridge, kill, waitForPort, waitForCanvasContent,
} = require("../helpers");

const SERVER_PORT = 19100;
const BRIDGE_PORT = 19101;

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

test("page loads with a canvas element", async ({ page }) => {
  await page.goto(`http://localhost:${BRIDGE_PORT}/`);
  const canvas = page.locator("#canvas");
  await expect(canvas).toBeVisible();
});

test("canvas dimensions are 1024x768", async ({ page }) => {
  await page.goto(`http://localhost:${BRIDGE_PORT}/`);
  const dims = await page.evaluate(() => {
    const c = document.getElementById("canvas");
    return { w: c.width, h: c.height };
  });
  expect(dims.w).toBe(1024);
  expect(dims.h).toBe(768);
});

test("canvas renders non-blank pixels once connected", async ({ page }) => {
  await page.goto(`http://localhost:${BRIDGE_PORT}/`);
  await waitForCanvasContent(page, 10_000);
});

test("game.js WebSocket connects to bridge /ws and receives render frames", async ({ page }) => {
  const wsFrames = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (frame) => {
      try {
        const msg = JSON.parse(frame.payload);
        if (msg.tag === "render") wsFrames.push(msg);
      } catch {}
    });
  });

  await page.goto(`http://localhost:${BRIDGE_PORT}/`);
  // Wait until we've intercepted at least one render frame.
  await page.waitForFunction(
    () => true, // just a yield; frames collected via event
    { timeout: 1_000 },
  ).catch(() => {});
  await page.waitForTimeout(3_000);

  expect(wsFrames.length).toBeGreaterThan(0);
  expect(wsFrames[0].tag).toBe("render");
  expect(["connecting", "lobby", "game"]).toContain(wsFrames[0].phase);
});
