// Empirical check on the render gate: spawn a real server, drive a real Zig
// client through the real bridge session, and measure the frames that come out.
//
// This exists because `zig build e2e` never spawns the CLIENT — it talks to the
// server with protocol-level bots — so the client's whole emit path (the stdin
// reader, the render gate, the JSON writer) had no end-to-end coverage at all.
// That gap was not theoretical: a stdin reader that livelocked on empty lines
// and emitted zero frames passed every other test in the repo.
//
// The claim being measured is one frame per server tick, each carrying the board
// that its events describe:
//
//   - frames == distinct ticks == tick span   (no drops, no duplicate emits)
//   - every frame carrying an event also carries a grid
//
// The second is the straddle bug: the browser keeps only the newest frame per
// paint, so an event delivered in a frame whose grid predates it is an event the
// renderer animates against the wrong board — or drops entirely.
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import path from "node:path";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..", "..");
const require = createRequire(path.join(ROOT, "bridge/"));
const { PlayerSession } = require(path.join(ROOT, "bridge/session.js"));

// A high port, to avoid colliding with a dev server on the usual one.
const PORT = Number(process.env.PROBE_PORT ?? 19077);
// A CEILING, not a duration: the run stops as soon as it has its sample, which
// is ~2s on an idle box.  Generous because under `zig build test` this competes
// with parallel compilation, and a tight ceiling would make load look like a
// client bug.
const SECONDS = Number(process.env.PROBE_SECONDS ?? 60);
// The nominal server tick.  Overridable because the invariant must hold at any
// pacing, and a mismatch between nominal and actual is itself worth seeing.
const TICK_MS = process.env.TICK_MS ?? "50";

// The probe writes its own data rather than borrowing `zig build e2e`'s, for
// two reasons: an ordering dependency on another build step is a trap on a
// clean checkout, and the e2e encounter is deliberately short (60 charges) so
// the game would END inside the window — resetting the tick counter and making
// the tick-span assertions nonsense.
//
// Fast bites so several land in the window (the shipped interval is 10s, which
// would yield a sample of zero), and charges far beyond what one player can eat
// in SECONDS so the encounter is still running when measurement stops.
const DATA_DIR = path.join(ROOT, "zig-out/probe-data");
fs.mkdirSync(DATA_DIR, { recursive: true });
fs.writeFileSync(path.join(DATA_DIR, "balance.json"), JSON.stringify({
  hunger_cost_normal: 1,
  hunger_base: 30,
  appetite_scale: 5,
  hunger_player_cap: 500,
  slime_grid: { rows: 6, cols: 10 },
  bite_interval_ms: 500,
  bite_speedup_per_guy_pct: 15,
  bite_speedup_per_baby_pct: 5,
  cast_cooldown_ms: 100,
  team_window_ms: 1500,
  settle_lockout_ms: 60,
  baby_hunger: 10,
  feast_columns: 1,
  feast_columns_per_guy: 0,
  specials_avoid_door_column: true,
  player_recipes: [
    { label: "poke", shape: ["#"], cost: 1 },
    { label: "sweep", shape: ["###"], cost: 3 },
  ],
  team_recipes: [],
}, null, 2));
fs.writeFileSync(path.join(DATA_DIR, "encounters.json"), JSON.stringify({
  default: "probe_feast",
  encounters: [
    { label: "probe_feast", charges: 100000,
      zones: [{ tiered: { green: 50000 }, neutral: 50000 }] },
  ],
}, null, 2));

const server = spawn(
  path.join(ROOT, "zig-out/bin/server"),
  [String(PORT), "--data-dir", DATA_DIR, "--tick-ms", TICK_MS],
  { stdio: ["ignore", "ignore", "pipe"] },
);
// Kept, not discarded: a server that dies on a bad data file or an occupied
// port would otherwise present as "the client emitted nothing", sending the
// reader hunting for a bug in the client.  Printed only on failure.
let serverErr = "";
server.stderr.setEncoding("utf8");
server.stderr.on("data", (d) => { serverErr += d; });
server.on("error", (err) => {
  console.log(`FAIL: could not spawn the server: ${err.message}`);
  process.exit(1);
});
let serverExit = null;
server.on("exit", (code, sig) => { serverExit = sig ?? code; });

// POLL for the port, never a fixed sleep.  A freshly linked binary's first run
// can take seconds, and a sleep that is usually long enough is a flake that
// blames the client for the machine being busy.
async function waitForListening(timeoutMs) {
  const net = await import("node:net");
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (serverExit !== null) return `server exited early (${serverExit})`;
    const ok = await new Promise((resolve) => {
      const s = net.connect(PORT, "127.0.0.1");
      const done = (v) => { s.destroy(); resolve(v); };
      s.once("connect", () => done(true));
      s.once("error", () => done(false));
      setTimeout(() => done(false), 250);
    });
    if (ok) return null;
    await new Promise((r) => setTimeout(r, 100));
  }
  return `port ${PORT} never accepted a connection within ${timeoutMs}ms`;
}

const notListening = await waitForListening(20000);
if (notListening) {
  console.log(`FAIL: ${notListening}`);
  if (serverErr) console.log(`--- server stderr ---\n${serverErr}`);
  server.kill("SIGKILL");
  process.exit(1);
}

let frames = 0;
const ticksSeen = new Set();
let tickMin = null, tickMax = null;
let withBite = 0, biteWithBoard = 0;
let withCasts = 0, castsWithBoard = 0;
let dupTicks = 0, lastTick = null;
let sawGrid = 0;
let clickedPast = false;
let preFrames = 0;
const t0 = Date.now();
// Wall-clock of the first and last in-game frame, for the observed tick period.
let tFirst = null, tLast = null;

class Probe extends PlayerSession {
  onServerReady() { this.writeToZig("JOIN\n"); }
  onZigFrame(msg) {
    if (msg?.tag !== "render") return;

    // The pre-match guide holds play, and the server returns before it
    // broadcasts a board — so without this click there is no board to observe
    // and every assertion below would vacuously pass on an empty sample.  The
    // browser tab clicks past it; so do we, once.  Counted apart: there is no
    // live tick behind these.
    if (msg.phase === "pre_match" || msg.phase === "connecting") {
      preFrames++;
      if (msg.phase === "pre_match" && !clickedPast) {
        clickedPast = true;
        this.writeToZig("RESTART\n");
      }
      return;
    }

    frames++;
    if (tFirst === null) tFirst = Date.now();
    tLast = Date.now();
    const g = msg.game;
    if (!g) return;
    const hasBoard = Array.isArray(g.grid) && g.grid.length > 0;
    if (hasBoard) sawGrid++;

    // A repeated tick number is a duplicate emit — the amplification that came
    // from rendering on a wall-clock timer instead of on arriving state.
    if (g.tick === lastTick) dupTicks++;
    lastTick = g.tick;
    ticksSeen.add(g.tick);
    if (typeof g.tick === "number") {
      if (tickMin === null || g.tick < tickMin) tickMin = g.tick;
      if (tickMax === null || g.tick > tickMax) tickMax = g.tick;
    }

    if (g.bite_settled) { withBite++; if (hasBoard) biteWithBoard++; }
    if (g.shape_casts?.length > 0) { withCasts++; if (hasBoard) castsWithBoard++; }
  }
}

const probe = new Probe({
  clientBin: path.join(ROOT, "zig-out/bin/client"),
  label: "probe",
});
probe.spawnZig();
probe.connectToServer(PORT);

// Keep casting, so there are shape_casts to co-locate with boards.  These names
// must be ones parse_key_name knows: it returns null for anything else, and a
// dropped key is a silently empty sample (" " cost an hour once).
const keys = ["ArrowRight", "1", "Enter", "ArrowLeft", "2", "Enter"];
let k = 0;
const caster = setInterval(
  () => probe.writeToZig(`KEY:${keys[k++ % keys.length]}\n`), 120);

// Stop on EVIDENCE, not on the clock.  Under `zig build test` this runs beside
// parallel compilation, and a fixed window measured 45 frames in 78 wall-clock
// seconds — the invariants still held, but the sample size was hostage to
// machine load.  Waiting for a target sample instead keeps the run short when
// the box is idle and correct when it is not; SECONDS becomes a ceiling.
const TARGET_TICKS = Number(process.env.PROBE_TICKS ?? 40);
const TARGET_BITES = 3;
const TARGET_CASTS = 3;
const enough = () =>
  ticksSeen.size >= TARGET_TICKS && withBite >= TARGET_BITES && withCasts >= TARGET_CASTS;

const deadline = Date.now() + SECONDS * 1000;
let timedOut = false;
while (!enough()) {
  if (Date.now() > deadline) { timedOut = true; break; }
  if (serverExit !== null) break;
  await new Promise((r) => setTimeout(r, 50));
}
clearInterval(caster);

const elapsed = (Date.now() - t0) / 1000;
const ticksElapsed = tickMin === null ? 0 : tickMax - tickMin + 1;
const msSpan = (tFirst === null || tLast === null) ? 0 : tLast - tFirst;
console.log(`\n--- ${elapsed.toFixed(1)}s at --tick-ms ${TICK_MS} ---`);
console.log(`pre-match frames:     ${preFrames}`);
console.log(`frames emitted:       ${frames}  (${(frames / elapsed).toFixed(1)}/s)`);
console.log(`frames with a board:  ${sawGrid}`);
console.log(`server tick span:     ${tickMin}..${tickMax} (${ticksElapsed} ticks elapsed)`);
console.log(`distinct ticks:       ${ticksSeen.size}`);
console.log(`duplicate-tick emits: ${dupTicks}`);
console.log(`observed tick period: ${ticksElapsed > 1 ? (msSpan / (ticksElapsed - 1)).toFixed(1) : "n/a"}ms  (nominal ${TICK_MS}ms)`);
console.log(`frames w/ bite:       ${withBite}  (with a board: ${biteWithBoard})`);
console.log(`frames w/ casts:      ${withCasts}  (with a board: ${castsWithBoard})`);

let bad = 0;
const fail = (m) => { console.log(`FAIL: ${m}`); bad++; };

if (serverExit !== null) fail(`the server exited mid-run (${serverExit})`);

// Liveness first: every assertion below is vacuous on an empty sample, which is
// exactly how the livelock hid.  A timeout is a failure, not a short sample.
if (frames === 0) fail("the client emitted nothing at all");
if (timedOut) {
  fail(`only ${ticksSeen.size}/${TARGET_TICKS} ticks, ${withBite}/${TARGET_BITES} bites, ` +
       `${withCasts}/${TARGET_CASTS} casts in ${SECONDS}s`);
}
if (sawGrid !== frames) fail(`${frames - sawGrid} in-game frames carried no board`);

// The straddle.
if (withBite !== biteWithBoard) fail("a bite arrived in a frame with no board");
if (withCasts !== castsWithBoard) fail("a cast arrived in a frame with no board");

// The gate: exactly one frame per tick the client actually observed.
if (dupTicks > 0) fail(`${dupTicks} frames repeated a tick already sent`);
if (frames > 0 && ticksSeen.size !== frames) {
  fail(`${frames} frames covered only ${ticksSeen.size} distinct ticks`);
}
if (ticksElapsed !== ticksSeen.size) {
  fail(`${ticksElapsed - ticksSeen.size} of ${ticksElapsed} server ticks never reached a frame`);
}

if (bad > 0 && serverErr) console.log(`--- server stderr ---\n${serverErr}`);
console.log(bad === 0 ? "PROBE PASS" : `PROBE FAIL (${bad})`);

server.kill("SIGKILL");
probe.zigProc?.kill("SIGKILL");
process.exit(bad === 0 ? 0 : 1);
