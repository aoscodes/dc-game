"use strict";

const { defineConfig, devices } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./tests",
  timeout: 120_000,
  // Each test file gets its own port so they can run in parallel without
  // tripping over each other's server/bridge processes.
  fullyParallel: false, // sequential: ports are deterministic per-file
  retries: 0,
  reporter: [["list"], ["html", { open: "never", outputFolder: "playwright-report" }]],
  use: {
    // Set HEADED=1 to open a real browser window (e.g. for watching bot tests).
    headless: !process.env.HEADED,
    // Set SLOW_MO=<ms> to slow down Playwright actions (useful when watching).
    slowMo: Number(process.env.SLOW_MO ?? 0),
    // Capture screenshots on failure for debugging CI.
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
