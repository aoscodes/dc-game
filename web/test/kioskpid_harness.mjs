// Harness for the kiosk kill switch's PID resolution.
//
// Two halves of one contract, tested together because neither means anything
// alone: pi-kiosk.sh must PUBLISH the browser's PID, and bridge/index.js must
// REFUSE any PID that is not one.
//
// The bug this exists to prevent already shipped.  On Raspberry Pi OS
// `chromium-browser` is a shell script that runs the real binary as a child,
// so `$!` in pi-kiosk.sh was the launcher, not the browser.  Every check
// passed — the launcher's own cmdline carries --kiosk too — and the kill
// switch answered 200 while SIGTERM reaped the script and orphaned a
// fullscreen browser that nothing could now close.  An operator holding the
// hidden button got no error and no change on screen.
//
// So what is asserted is the DISCRIMINATION, not the plumbing: given the Pi's
// process-tree shape, both sides must land on the same browser PID and reject
// both the launcher above it and the helpers beside it.
//
// Linux only.  The whole mechanism is /proc, and both sides deliberately
// degrade to "take the PID on trust" without one, so there is nothing to
// assert on a dev machine — it skips rather than passing vacuously.
import { readFileSync, existsSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import fs from "node:fs";
import path from "node:path";

let failures = 0;
function check(cond, what) {
  if (!cond) { failures++; console.log(`FAIL: ${what}`); }
}

if (process.platform !== "linux" || !existsSync("/proc")) {
  console.log(`ok (skipped: no /proc on ${process.platform})`);
  process.exit(0);
}

// ---------------------------------------------------------------------------
// A fake Chromium tree
// ---------------------------------------------------------------------------
//
// Real Chromium is not spawned: it wants a display, it costs seconds, and the
// subject here is a tree SHAPE with particular argv and exe on each node —
// which a shell and two `sleep`s reproduce exactly:
//
//   launcher  bash   "chromium-browser --kiosk URL <script>"   <- wrong answer
//    ├─ browser  sleep  "chromium --kiosk URL"                 <- right answer
//    └─ renderer sleep  "chromium --type=renderer --kiosk URL"
//
// Details that are load-bearing, not incidental:
//   - the leaves are `sleep`, not shells, so /proc/PID/exe distinguishes them
//     from the launcher — which is the bridge's half of the check;
//   - the renderer carries --kiosk even though a real one may not, so --type=
//     is the only thing that can be excluding it and the test cannot pass for
//     the wrong reason;
//   - `exec -a` is how a process wears another's argv, and it is a BASHISM,
//     so bash throughout and never `sh` (dash on Debian and Pi OS);
//   - each leaf writes $BASHPID *before* exec-ing, so the PID the harness
//     asserts on is read from the process itself rather than inferred.
const URL_ = "http://localhost:3000/";
const dir = mkdtempSync(join(tmpdir(), "kioskpid-"));

const ARGV = {
  launcher: `chromium-browser --kiosk ${URL_}`,
  browser:  `chromium --kiosk ${URL_}`,
  renderer: `chromium --type=renderer --kiosk ${URL_}`,
};

/** A child that records its own PID and then wears `argv`. */
const leaf = (name) =>
  `( echo $BASHPID > "${dir}/${name}.pid"; exec -a ${JSON.stringify(ARGV[name])} sleep 30 ) &`;

writeFileSync(`${dir}/launcher.sh`, [
  `echo $$ > "${dir}/launcher.pid"`,
  leaf("browser"),
  leaf("renderer"),
  "wait",
].join("\n") + "\n");

// The outer bash execs, so this child's PID *is* the launcher's — exactly as
// pi-kiosk.sh's `$!` is.
const child = spawn("bash", ["-c",
  `exec -a ${JSON.stringify(ARGV.launcher)} bash "${dir}/launcher.sh"`,
], { stdio: "ignore", detached: true });
// Unreffed so a cleanup that somehow misses cannot hold the harness open:
// a kill-switch test that hangs CI is its own kind of broken.
child.unref();

/** Wait for every level to have published its PID. */
async function treePids() {
  for (let i = 0; i < 100; i++) {
    try {
      const pids = {};
      for (const n of ["launcher", "browser", "renderer"]) {
        pids[n] = Number(readFileSync(`${dir}/${n}.pid`, "utf8").trim());
      }
      if (Object.values(pids).every((p) => Number.isInteger(p) && p > 1)) return pids;
    } catch { /* not all up yet */ }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error("fake chromium tree never reported its PIDs");
}

// ---------------------------------------------------------------------------
// The two implementations, lifted out of the files that ship them
// ---------------------------------------------------------------------------

/** Extract a named function's source out of a JS file. */
function extractFn(src, name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`missing ${name}`);
  let i = src.indexOf("{", start), depth = 0;
  for (; i < src.length; i++) { if (src[i] === "{") depth++; else if (src[i] === "}" && --depth === 0) break; }
  return src.slice(start, i + 1);
}

const bridgeSrc = readFileSync(new URL("../../bridge/index.js", import.meta.url), "utf8");
const shellSet = bridgeSrc.match(/const SHELL_EXES = new Set\(\[[^\]]*\]\);/);
if (!shellSet) throw new Error("missing SHELL_EXES in bridge/index.js");
const pidIsKioskBrowser = new Function("fs", "path",
  `${shellSet[0]}\n${extractFn(bridgeSrc, "pidIsKioskBrowser")}\nreturn pidIsKioskBrowser;`,
)(fs, path);

const kioskSrc = readFileSync(new URL("../../scripts/pi-kiosk.sh", import.meta.url), "utf8");
const fnStart = kioskSrc.indexOf("kiosk_browser_pid() {");
if (fnStart < 0) throw new Error("missing kiosk_browser_pid in scripts/pi-kiosk.sh");
const fnEnd = kioskSrc.indexOf("\n}\n", fnStart);
if (fnEnd < 0) throw new Error("kiosk_browser_pid is not closed at column 0");
const resolverSrc = kioskSrc.slice(fnStart, fnEnd + 2);

/** Run pi-kiosk.sh's own resolver against a real PID; "" when it finds none. */
function shellResolve(rootPid) {
  return new Promise((resolve) => {
    const sh = spawn("bash", ["-c", `${resolverSrc}\nkiosk_browser_pid ${rootPid} || true`],
      { stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    sh.stdout.on("data", (d) => { out += d; });
    sh.on("close", () => resolve(out.trim()));
  });
}

// ---------------------------------------------------------------------------

let pids;
try {
  pids = await treePids();
  // The launcher is our spawned child; if that stops holding, the fixture is
  // testing something other than what it claims to.
  check(pids.launcher === child.pid,
    `fixture: the spawned PID is the launcher (got ${pids.launcher}, spawned ${child.pid})`);

  // --- pi-kiosk.sh publishes the browser, not the launcher it was handed ---
  const picked = await shellResolve(child.pid);
  check(picked === String(pids.browser),
    `resolver picks the browser (got ${picked}, want ${pids.browser})`);
  check(picked !== String(pids.launcher),
    "resolver must never publish the launcher — that is the orphaned-browser bug");
  // A --type= helper is never a candidate: a real browser has dozens, and
  // signalling one closes a tab while the kiosk stays up.
  check(picked !== String(pids.renderer), "resolver must skip --type= helpers");

  // --- the bridge agrees, on the same PID -----------------------------------
  check(pidIsKioskBrowser(pids.browser) === true,
    "bridge accepts the PID the resolver publishes");
  // The launcher is a shell wearing the browser's own flags. This is the
  // check that was missing when the switch shipped broken.
  check(pidIsKioskBrowser(pids.launcher) === false,
    "bridge rejects the launcher even though its argv carries --kiosk");
  check(pidIsKioskBrowser(process.pid) === false,
    "bridge rejects a process with no --kiosk in its argv");
} finally {
  // A detached group, so one kill takes the whole tree.  A failure here is
  // cleanup, not a test result.
  try { process.kill(-child.pid, "SIGKILL"); } catch { /* already gone */ }
  for (const p of Object.values(pids ?? {})) {
    try { process.kill(p, "SIGKILL"); } catch { /* already gone */ }
  }
  rmSync(dir, { recursive: true, force: true });
}

if (failures > 0) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("ok (launcher rejected, browser published, helpers skipped)");
