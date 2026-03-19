"use strict";
/**
 * connecting.test.js — verify the browser shows the connecting screen while
 * the game server is unreachable, and transitions to lobby once it comes up.
 *
 * Port layout:
 *   test 1 — bridge=19130, no server (unreachable port 19139)
 *   test 2 — server=19131, bridge=19132 (server starts after browser opens)
 */

const { test, expect } = require("@playwright/test");
const {
  spawnServer, spawnBridge, kill, waitForPort,
  waitForCanvasContent, canvasRegionHasColor,
  openFrameCollector, waitForFramePhase,
  assertLobbyFrame,
} = require("../helpers");

// ---------------------------------------------------------------------------

test("connecting screen is drawn when server is unreachable", async ({ page }) => {
  // Nothing listens on 19139 — bridge will keep retrying forever.
  const bridge = spawnBridge(19139, 19130);
  await waitForPort(19130, 8_000);
  const collector = openFrameCollector(19130);
  await collector.ready;
  try {
    await page.goto("http://localhost:19130/");

    // Must receive connecting-phase frames (Zig runs immediately, no spin-wait).
    await waitForFramePhase(collector, "connecting", 5_000);

    // Canvas must be non-blank — drawConnecting() must have painted.
    await waitForCanvasContent(page, 5_000);

    // The "Connecting to server..." text is drawn in C_TEXT = rgba(230,230,230).
    // Check a wide strip at y≈40–80 where the text appears (baseline y=60).
    const hasText = await canvasRegionHasColor(
      page, 40, 35, 500, 40,
      180, 255, 180, 255, 180, 255,
    );
    expect(hasText).toBe(true);
  } finally {
    collector.close();
    await kill(bridge);
  }
});

test("transitions from connecting to lobby when server comes up", async ({ page }) => {
  const SERVER_PORT = 19131;
  const BRIDGE_PORT = 19132;

  // Start bridge BEFORE the server so the browser sees connecting frames first.
  const bridge = spawnBridge(SERVER_PORT, BRIDGE_PORT);
  await waitForPort(BRIDGE_PORT, 8_000);
  const collector = openFrameCollector(BRIDGE_PORT);
  await collector.ready;
  try {
    await page.goto(`http://localhost:${BRIDGE_PORT}/`);

    // Should see connecting frames while server is not yet up.
    await waitForFramePhase(collector, "connecting", 5_000);

    // Now start the server — bridge will connect and Zig will send join.
    const realServer = spawnServer(SERVER_PORT);
    await waitForPort(SERVER_PORT, 8_000);

    try {
      // Bridge connects to server; Zig receives READY and sends join.
      // Should transition to lobby within 10 s.
      const lobbyFrame = await waitForFramePhase(collector, "lobby", 12_000);

      // Verify the lobby frame has real content — not just a phase string.
      assertLobbyFrame(lobbyFrame);

      // Canvas must show lobby content.
      await waitForCanvasContent(page, 5_000);
    } finally {
      await kill(realServer);
    }
  } finally {
    collector.close();
    await kill(bridge);
  }
});
