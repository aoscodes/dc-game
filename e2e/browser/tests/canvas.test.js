"use strict";
/**
 * canvas.test.js — verify the page loads, canvas is the right size, the
 * renderer produces correctly-phased output once the bridge is connected,
 * and the connecting screen is drawn even before the game server is up.
 *
 * Port layout:
 *   19100 / 19101 — server + bridge (normal connected tests)
 *   19102         — bridge only, no server (connecting-screen test)
 */

const { test, expect } = require("@playwright/test");
const {
  spawnServer, spawnBridge, kill, waitForPort,
  waitForCanvasContent, canvasRegionHasColor,
  openFrameCollector, waitForFramePhase,
} = require("../helpers");

const SERVER_PORT = 19100;
const BRIDGE_PORT = 19101;

// Bridge-only port — points at a port where no server will ever listen.
const NO_SERVER_PORT  = 19199; // nothing listens here
const BRIDGE_ONLY_PORT = 19102;

let server, bridge;
let bridgeOnly;

test.beforeAll(async () => {
  server = spawnServer(SERVER_PORT);
  await waitForPort(SERVER_PORT, 8_000);
  bridge = spawnBridge(SERVER_PORT, BRIDGE_PORT);
  await waitForPort(BRIDGE_PORT, 8_000);

  // Bridge that cannot reach a server — used for the connecting-screen test.
  bridgeOnly = spawnBridge(NO_SERVER_PORT, BRIDGE_ONLY_PORT);
  await waitForPort(BRIDGE_ONLY_PORT, 8_000);
});

test.afterAll(async () => {
  await kill(bridge);
  await kill(server);
  await kill(bridgeOnly);
});

// ---------------------------------------------------------------------------

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
  // Collect frames from a Node WS client before navigating so we don't miss
  // early frames.
  const collector = openFrameCollector(BRIDGE_PORT);
  await collector.ready;
  try {
    await page.goto(`http://localhost:${BRIDGE_PORT}/`);

    // Wait for at least a connecting or lobby frame — proves Zig is running
    // and emitting, not just the HTML body colour satisfying the pixel check.
    const frame = await waitForFramePhase(collector, "connecting", 5_000)
      .catch(() => waitForFramePhase(collector, "lobby", 8_000));
    expect(["connecting", "lobby", "game"]).toContain(frame.phase);

    await waitForCanvasContent(page, 8_000);
  } finally {
    collector.close();
  }
});

test("game.js WebSocket connects to bridge /ws and receives render frames", async ({ page }) => {
  const collector = openFrameCollector(BRIDGE_PORT);
  await collector.ready;
  try {
    await page.goto(`http://localhost:${BRIDGE_PORT}/`);

    // After 3 s at 60 fps we expect ~180 frames; 10 is a conservative floor
    // that would fail if Zig is dead or frames are being silently swallowed.
    await page.waitForTimeout(3_000);

    expect(collector.frames.length).toBeGreaterThanOrEqual(10);
    // Every frame must have a known phase string.
    for (const f of collector.frames) {
      expect(["connecting", "lobby", "game", "game_over"]).toContain(f.phase);
    }
  } finally {
    collector.close();
  }
});

test("connecting screen is drawn before server is available", async ({ page }) => {
  // The bridge-only instance points at a non-existent server, so the Zig
  // client stays in the 'connecting' phase indefinitely.  Verify:
  //   1. A 'connecting' render frame reaches the browser.
  //   2. The canvas is non-blank (drawConnecting drew something).
  // This test would have caught the old spin-wait bug where no frames were
  // emitted until READY arrived.
  const collector = openFrameCollector(BRIDGE_ONLY_PORT);
  await collector.ready;
  try {
    await page.goto(`http://localhost:${BRIDGE_ONLY_PORT}/`);

    await waitForFramePhase(collector, "connecting", 5_000);

    await waitForCanvasContent(page, 5_000);

    // The connecting text is drawn in C_TEXT = rgba(230,230,230,1).
    // Check the text region (x=40,y=40 roughly where "Connecting..." starts).
    const hasConnectingText = await canvasRegionHasColor(
      page, 40, 40, 500, 30,
      180, 255, 180, 255, 180, 255, // near-white range covers C_TEXT
    );
    expect(hasConnectingText).toBe(true);
  } finally {
    collector.close();
  }
});
