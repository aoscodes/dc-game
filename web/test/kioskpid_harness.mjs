// Harness for the kiosk kill switch's PID resolution.
//
// Two halves of one contract: pi-kiosk.sh should PUBLISH the browser's PID,
// and bridge/index.js must land on the browser whatever the pidfile holds.
//
// The bug this exists to prevent already shipped twice.  On Raspberry Pi OS
// `chromium-browser` is a shell script that runs the real binary as a child,
// so `$!` in pi-kiosk.sh was the launcher, not the browser.  Every check
// passed — the launcher's own cmdline carries --kiosk too — and the switch
// answered 200 while SIGTERM reaped the script and orphaned a fullscreen
// browser nothing could close.  The first fix taught pi-kiosk.sh to publish
// the browser, and shipped a SECOND failure: pi-update.sh refreshes the
// bridge with every commit but deliberately never rewrites pi-kiosk.sh, so on
// a Pi that had not been re-provisioned the new bridge simply rejected the
// old launcher PID.  A half-deployed kiosk is the normal state, not an edge
// case, so the bridge now descends the process tree itself.
//
// Structured in two sections, because the second one cannot run everywhere:
//
//   1. /proc as a FIXTURE.  The bridge's two functions take their filesystem
//      as an argument here, so the whole discrimination — launcher vs browser
//      vs helper — is asserted on every platform, including the Mac this was
//      written on.  This is the section that catches logic errors.
//   2. /proc for REAL, against a tree of live processes.  Linux only; it is
//      what catches a fixture that has drifted from what Linux actually puts
//      in /proc.  It skips elsewhere rather than passing vacuously.
import { readFileSync, existsSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";
import fs from "node:fs";
import path from "node:path";

let failures = 0;
function check(cond, what) {
  if (!cond) { failures++; console.log(`FAIL: ${what}`); }
}

// ---------------------------------------------------------------------------
// The bridge's implementation, lifted out of the file that ships it
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

/** Bind the bridge's PID functions to a given filesystem. */
const bindBridge = (fsImpl, pathImpl) => new Function("fs", "path", `
  ${shellSet[0]}
  ${extractFn(bridgeSrc, "pidIsKioskBrowser")}
  ${extractFn(bridgeSrc, "procChildren")}
  ${extractFn(bridgeSrc, "resolveKioskBrowser")}
  return { pidIsKioskBrowser, resolveKioskBrowser };
`)(fsImpl, pathImpl);

// ---------------------------------------------------------------------------
// 1. /proc as a fixture — runs everywhere
// ---------------------------------------------------------------------------
//
// The Pi's tree, as Linux would present it.  cmdline is NUL-separated and
// NUL-terminated, which is the detail a naive fixture gets wrong.
const URL_ = "http://localhost:3000/";
const argv = (...a) => a.join("\0") + "\0";

const FAKE_PROC = {
  // the wrapper script: carries every flag the browser does, runs under bash
  10: { ppid: 1,  exe: "/usr/bin/bash",             cmdline: argv("/bin/sh", "/usr/bin/chromium-browser", "--kiosk", URL_) },
  // the browser itself — the only correct answer
  11: { ppid: 10, exe: "/usr/lib/chromium/chromium", cmdline: argv("/usr/lib/chromium/chromium", "--kiosk", URL_) },
  // helpers: a real renderer inherits plenty, so it is given --kiosk here to
  // prove that --type= is what excludes it
  12: { ppid: 11, exe: "/usr/lib/chromium/chromium", cmdline: argv("/usr/lib/chromium/chromium", "--type=renderer", "--kiosk", URL_) },
  13: { ppid: 11, exe: "/usr/lib/chromium/chromium", cmdline: argv("/usr/lib/chromium/chromium", "--type=zygote") },
  // something else entirely, with a child, so a walk that ignores its
  // predicate would still find something
  20: { ppid: 1,  exe: "/usr/bin/node",             cmdline: argv("node", "bridge/index.js") },
  21: { ppid: 20, exe: "/usr/bin/node",             cmdline: argv("node", "worker.js") },
};

const fakeFs = {
  existsSync: (p) => p === "/proc" || /^\/proc\/\d+/.test(p),
  readdirSync: (p) => {
    if (p !== "/proc") throw new Error(`ENOENT: ${p}`);
    // Non-numeric entries are real (/proc/self, /proc/cpuinfo) and must be
    // skipped by the code under test, not by the fixture.
    return [...Object.keys(FAKE_PROC), "self", "cpuinfo", "net"];
  },
  readFileSync: (p) => {
    const m = p.match(/^\/proc\/(\d+)\/(cmdline|status)$/);
    if (!m || !FAKE_PROC[m[1]]) throw new Error(`ENOENT: ${p}`);
    return m[2] === "cmdline"
      ? FAKE_PROC[m[1]].cmdline
      : `Name:\tx\nState:\tS\nTgid:\t${m[1]}\nPid:\t${m[1]}\nPPid:\t${FAKE_PROC[m[1]].ppid}\n`;
  },
  readlinkSync: (p) => {
    const m = p.match(/^\/proc\/(\d+)\/exe$/);
    if (!m || !FAKE_PROC[m[1]]) throw new Error(`ENOENT: ${p}`);
    return FAKE_PROC[m[1]].exe;
  },
};

{
  const { pidIsKioskBrowser, resolveKioskBrowser } = bindBridge(fakeFs, { basename });

  check(pidIsKioskBrowser(11) === true,  "fixture: the browser is the browser");
  check(pidIsKioskBrowser(10) === false, "fixture: the launcher is a shell, so not the browser");
  check(pidIsKioskBrowser(12) === false, "fixture: a --type= renderer is not the browser");
  check(pidIsKioskBrowser(13) === false, "fixture: a --type= zygote is not the browser");
  check(pidIsKioskBrowser(20) === false, "fixture: a process with no --kiosk is not the browser");

  // The property the field depends on: an old pi-kiosk.sh publishes 10, and
  // the switch must still reach 11.
  check(resolveKioskBrowser(10) === 11, "fixture: descends from a launcher pidfile to the browser");
  check(resolveKioskBrowser(11) === 11, "fixture: passes a correct pidfile straight through");
  // The recovery path: a pidfile pointing at something with no browser under
  // it at all must still find the one browser on the machine, because the
  // alternative is a kiosk nobody can open without pulling its SD card.
  check(resolveKioskBrowser(20) === 11,
    "fixture: falls back to the one browser on the machine when the pidfile leads nowhere");
  check(resolveKioskBrowser(12) === 11,
    "fixture: the fallback applies to a childless wrong PID too");
}

// The fallback must not GUESS.  Two browsers is an ambiguous machine, and a
// wrong SIGTERM there kills a session someone is using.
{
  const twoBrowsers = { ...FAKE_PROC, 30: { ppid: 1, exe: "/usr/lib/chromium/chromium", cmdline: argv("chromium", "--kiosk", URL_) } };
  const saved = { ...FAKE_PROC };
  Object.assign(FAKE_PROC, twoBrowsers);
  const { resolveKioskBrowser } = bindBridge(fakeFs, { basename });
  check(resolveKioskBrowser(20) === null, "fixture: refuses to choose between two browsers");
  check(resolveKioskBrowser(11) === 11, "fixture: an exact pidfile still wins with two browsers present");
  for (const k of Object.keys(FAKE_PROC)) delete FAKE_PROC[k];
  Object.assign(FAKE_PROC, saved);
}

// ---------------------------------------------------------------------------
// 2. /proc for real — Linux only
// ---------------------------------------------------------------------------

if (process.platform !== "linux" || !existsSync("/proc")) {
  if (failures > 0) { console.log(`\n${failures} check(s) failed`); process.exit(1); }
  console.log(`ok (fixture checks passed; live tree skipped: no /proc on ${process.platform})`);
  process.exit(0);
}

// A real tree of the same shape.  Chromium itself is not spawned: it wants a
// display, it costs seconds, and the subject is a tree shape with particular
// argv and exe per node — which a shell and two `sleep`s reproduce exactly:
//
//   launcher  bash   "chromium-browser --kiosk URL <script>"
//    ├─ browser  sleep  "chromium --kiosk URL"
//    └─ renderer sleep  "chromium --type=renderer --kiosk URL"
//
// The leaves are `sleep` so /proc/PID/exe tells them from the launcher, and
// `exec -a` is how a process wears another's argv — a BASHISM, so bash
// throughout and never `sh`, which is dash on Debian and Pi OS.  Each leaf
// writes $BASHPID before exec-ing, so its PID is read from the process rather
// than inferred.
const dir = mkdtempSync(join(tmpdir(), "kioskpid-"));
const ARGV = {
  launcher: `chromium-browser --kiosk ${URL_}`,
  browser:  `chromium --kiosk ${URL_}`,
  renderer: `chromium --type=renderer --kiosk ${URL_}`,
};
const leaf = (name) =>
  `( echo $BASHPID > "${dir}/${name}.pid"; exec -a ${JSON.stringify(ARGV[name])} sleep 30 ) &`;

writeFileSync(`${dir}/launcher.sh`, [
  `echo $$ > "${dir}/launcher.pid"`, leaf("browser"), leaf("renderer"), "wait",
].join("\n") + "\n");

// The outer bash execs, so this child's PID *is* the launcher's — exactly as
// pi-kiosk.sh's `$!` is.
const child = spawn("bash", ["-c",
  `exec -a ${JSON.stringify(ARGV.launcher)} bash "${dir}/launcher.sh"`,
], { stdio: "ignore", detached: true });
child.unref();

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

// pi-kiosk.sh's own resolver, run as the shell function it actually is.
const kioskSrc = readFileSync(new URL("../../scripts/pi-kiosk.sh", import.meta.url), "utf8");
const fnStart = kioskSrc.indexOf("kiosk_browser_pid() {");
if (fnStart < 0) throw new Error("missing kiosk_browser_pid in scripts/pi-kiosk.sh");
const fnEnd = kioskSrc.indexOf("\n}\n", fnStart);
if (fnEnd < 0) throw new Error("kiosk_browser_pid is not closed at column 0");
const resolverSrc = kioskSrc.slice(fnStart, fnEnd + 2);

const shellResolve = (rootPid) => new Promise((resolve) => {
  const sh = spawn("bash", ["-c", `${resolverSrc}\nkiosk_browser_pid ${rootPid} || true`],
    { stdio: ["ignore", "pipe", "ignore"] });
  let out = "";
  sh.stdout.on("data", (d) => { out += d; });
  sh.on("close", () => resolve(out.trim()));
});

let pids;
try {
  pids = await treePids();
  const { pidIsKioskBrowser, resolveKioskBrowser } = bindBridge(fs, path);

  check(pids.launcher === child.pid,
    `live: the spawned PID is the launcher (got ${pids.launcher}, spawned ${child.pid})`);

  // pi-kiosk.sh publishes the browser, not the launcher it was handed.
  const picked = await shellResolve(child.pid);
  check(picked === String(pids.browser),
    `live: resolver picks the browser (got ${picked}, want ${pids.browser})`);
  check(picked !== String(pids.renderer), "live: resolver skips --type= helpers");

  // And the bridge gets to the same place from either PID.
  check(pidIsKioskBrowser(pids.browser) === true, "live: bridge accepts the browser");
  check(pidIsKioskBrowser(pids.launcher) === false, "live: bridge rejects the launcher");
  check(pidIsKioskBrowser(pids.renderer) === false, "live: bridge rejects a --type= helper");
  const descended = resolveKioskBrowser(pids.launcher);
  check(descended === pids.browser,
    `live: bridge descends launcher -> browser (got ${descended}, want ${pids.browser})`);
  check(resolveKioskBrowser(pids.browser) === pids.browser,
    "live: bridge passes a correct pidfile straight through");
} finally {
  // A detached group, so one kill takes the whole tree.  Cleanup failure is
  // not a test result.
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
console.log("ok (launcher rejected, browser found from either PID, helpers skipped)");
