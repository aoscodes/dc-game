"use strict";

/**
 * Bridge between the Zig client binary and the browser canvas.
 *
 * Each browser tab gets its own TabSession: a dedicated Zig client process
 * and a dedicated WebSocket connection to the game server.  The server sees
 * each tab as a distinct player.
 *
 * Multiple lobbies are supported.  Each lobby runs its own Zig server process
 * on a dedicated port; a game is ALWAYS running in it (there is no lobby
 * phase).  The LobbyRegistry tracks all active lobbies by their 6-character
 * join code.  Tabs are routed to a lobby via:
 *   { action: "create" }                    — spawn a new server + attach
 *   { action: "join", code: "XXXXXX" }      — attach to an existing lobby
 *
 * A tab attaches as an OBSERVER of the running game.  Taking one of the four
 * player seats is the browser's P key (Shift+P leaves), forwarded like any
 * other key — the Zig client turns it into the take_slot/leave_slot protocol.
 * A round does NOT roll over: the end screen's button sends the tab back to
 * the station directory, which drops this socket and lets the room go.  The
 * next round is a fresh /game.  ({ action: "restart" } → RESTART is still
 * carried for the protocol's sake, but no page sends it.)
 *
 * Responsibilities per TabSession:
 *   - Create or join the room the tab's URL asks for, on its first message
 *   - Spawn ./zig-out/bin/client and manage its lifecycle
 *   - Connect to the chosen lobby's server WebSocket (owns reconnect loop)
 *   - Relay server frames → Zig stdin as  WIRE:<hex>\n
 *   - Relay Zig stdout send-frames → server WebSocket
 *   - Relay Zig stdout render-frames → the tab's browser WebSocket only
 *   - Relay browser keydown events → Zig stdin as  KEY:<name>\n
 *
 * Shared:
 *   - HTTP static file server on port 3000 (serves web/).  The page routes:
 *       /                  the station directory (web/index.html) — what a
 *                          kiosk boots into, and the only page that links the
 *                          others.  /onboard and /powerups link back to it;
 *                          /game does not (see the /game route below).
 *       /game              the game shell (web/game.html)
 *       /config/{hash}     the same shell, playing a saved /tune config
 *       /onboard           the badge colour kiosk
 *       /powerups          the powerup kiosk
 *       /tune              the config editor
 *     and one endpoint that is not a page:
 *       POST /api/kiosk/exit  closes the fullscreen browser to the desktop,
 *                          for the hold-to-exit button on `/`.  Armed only by
 *                          KIOSK_STATE_DIR and only for loopback callers;
 *                          404 everywhere else, including the VPS.
 *   - Hardware controller discovery over USB serial (controllers.js): every
 *     board is its own player with a dedicated Zig client; selected-shape
 *     feedback flows back to the board's e-paper.
 *   - /onboard + /onboard-ws (OnboardSession): the badge colour kiosk.  No Zig
 *     client, no lobby, no session slot — it only needs the bridge because the
 *     bridge is what holds the serial ports.
 *
 * Stdio protocol (Zig ↔ bridge):
 *   Zig stdin  ← WIRE:<hex>\n   raw server message bytes, hex-encoded
 *   Zig stdin  ← KEY:<name>\n   browser KeyboardEvent.key value
 *   Zig stdin  ← READY\n        sent when the server WS opens
 *   Zig stdin  ← JOIN\n         take a player seat (board sessions)
 *   Zig stdin  ← RESTART\n      release the end-screen hold into the next
 *                               encounter (no page sends this any more)
 *   Zig stdout → {"tag":"render",...}\n   full UI state for the browser
 *   Zig stdout → {"tag":"send","bytes":"<hex>"}\n  forward to server
 */

const { spawn }   = require("child_process");
const http        = require("http");
const net         = require("net");
const fs          = require("fs");
const path        = require("path");
const { WebSocketServer, WebSocket } = require("ws");
const { PlayerSession } = require("./session");
const {
  ControllerManager, BABY_TYPE_COUNT, PALETTE_COLOR_COUNT,
  POWERUP_KIND_COUNT, POWERUP_COUNT_MAX, POWERUP_NAMES,
  isPalette, boardStateView,
} = require("./controllers");
const { Ledger } = require("./ledger");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const PORT        = parseInt(process.env.PORT || "3000", 10);
// Opt-in, off by default, and deliberately not a config file: the /api/dev
// routes rewrite what a board claims to be, which is a thing a dev box should
// be able to do and a thing the event machine must not.  An env var is the
// one switch that cannot be reached by anyone holding only the HTTP port.
const DEV_INJECT  = process.env.DEV_INJECT === "1";
// The kiosk kill switch (POST /api/kiosk/exit).  Set to $ROOT/state by
// pi-setup.sh, and UNSET everywhere else — including the VPS, which has no
// browser to close and is reachable from the public internet.  Its presence
// alone arms the route, so there is no way to configure a bridge that thinks
// the switch is enabled but has nowhere to write.
const KIOSK_STATE_DIR = process.env.KIOSK_STATE_DIR || null;
// Where the badge ledger writes (bridge/ledger.js).  Set to an ABSOLUTE path
// outside the repo by pi-setup.sh, because pi-update.sh deploys into a fresh
// worktree each time and a repo-relative default would leave last week's
// records in last week's checkout.  The default here is repo-relative anyway:
// it is for a dev box, where that is exactly what you want.
const BADGE_LOG_DIR = process.env.BADGE_LOG_DIR ||
  path.join(__dirname, "..", "records");
// Both filenames are a contract with scripts/pi-kiosk.sh, which publishes the
// PID and consumes the flag.  Renaming either here alone breaks the switch
// silently, so they are named in exactly these two places.
const KIOSK_PID_FILE  = KIOSK_STATE_DIR && path.join(KIOSK_STATE_DIR, "chromium.pid");
const KIOSK_EXIT_FLAG = KIOSK_STATE_DIR && path.join(KIOSK_STATE_DIR, "kiosk-exit");
// Locally: zig build puts the binaries at zig-out/bin/ (one level up from bridge/).
// On the VPS: deploy installs them flat at /opt/dragoncon/ (same level as bridge/).
const _binDir     = path.resolve(__dirname, "..");

function resolveBin(name) {
  const flat  = path.join(_binDir, name);
  const local = path.join(_binDir, "zig-out", "bin", name);
  return fs.existsSync(flat) ? flat : local;
}

const CLIENT_BIN  = resolveBin("client");
const SERVER_BIN  = resolveBin("server");
const WEB_DIR     = path.resolve(__dirname, "../web");
// Designer-tunable game data (balance.json / encounters.json).  Served to
// the browser at /data/* and passed to every spawned server via --data-dir,
// so both sides read the same files.
const DATA_DIR    = path.resolve(__dirname, "../data");
// Saved /tune configs: custom-configs/{hash}/{balance,encounters}.json.
// Content-addressed (sha256 prefix), validated by `server --validate` at
// save time, never garbage-collected (tiny JSON files).
const CUSTOM_DIR  = path.resolve(__dirname, "../custom-configs");

/** Config hashes are 16 lowercase hex chars (sha256 prefix). */
const HASH_RE = /^[0-9a-f]{16}$/;

/**
 * Is this remote address this machine?
 *
 * Node reports IPv4 loopback as "127.0.0.1" and IPv6 as "::1", and a v4
 * connection to a dual-stack listener as the v4-mapped "::ffff:127.0.0.1".
 * 127.0.0.0/8 is loopback entirely, not just .1.
 */
function isLoopback(addr) {
  if (typeof addr !== "string") return false;
  const bare = addr.startsWith("::ffff:") ? addr.slice("::ffff:".length) : addr;
  return bare === "::1" || /^127\.\d+\.\d+\.\d+$/.test(bare);
}

/** Data dir for a config hash, or the shipped defaults when hash is null. */
function dataDirFor(hash) {
  return hash ? path.join(CUSTOM_DIR, hash) : DATA_DIR;
}

/**
 * Move labels in balance-file order, which is the index space of a render
 * frame's `selected_shape`.  Only hardware e-paper feedback needs this (the
 * browser fetches balance.json itself), so a read failure degrades to "no
 * labels" rather than taking a room down.  Cached per config hash: these
 * files are immutable once written (content-addressed), and DATA_DIR only
 * changes across a bridge restart.
 *
 * @type {Map<string | null, string[]>}
 */
const moveLabelCache = new Map();

/** @param {string | null} hash @returns {string[]} */
function moveLabelsFor(hash) {
  const hit = moveLabelCache.get(hash);
  if (hit !== undefined) return hit;
  let labels = [];
  try {
    const raw = fs.readFileSync(path.join(dataDirFor(hash), "balance.json"), "utf8");
    const recipes = JSON.parse(raw).player_recipes;
    if (Array.isArray(recipes)) {
      labels = recipes.map((r) => (typeof r.label === "string" ? r.label : "?"));
    }
  } catch (err) {
    console.warn(`[bridge] move labels unavailable (config=${hash ?? "default"}):`, err.message);
  }
  moveLabelCache.set(hash, labels);
  return labels;
}

const MAX_SESSIONS          = 6;
// Grace period before an empty lobby's server process is killed.
const LOBBY_IDLE_TIMEOUT_MS = 30_000;
// Port range for spawned server processes.
const SERVER_PORT_BASE      = 9001;

// Join-code charset — must match the one in server/main.zig.
const CODE_CHARSET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

// ---------------------------------------------------------------------------
// Static file server
// ---------------------------------------------------------------------------

const MIME = {
  ".html": "text/html",
  ".js":   "application/javascript",
  ".css":  "text/css",
  ".ico":  "image/x-icon",
  ".json": "application/json",
  ".png":  "image/png",
};

function serveFile(res, baseDir, relPath, extraHeaders = {}) {
  const filePath = path.join(baseDir, path.normalize(relPath));
  if (!filePath.startsWith(baseDir)) {
    res.writeHead(403); res.end("Forbidden"); return;
  }
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end("Not found"); return; }
    const ext = path.extname(filePath);
    res.writeHead(200, {
      "Content-Type": MIME[ext] || "application/octet-stream",
      ...extraHeaders,
    });
    res.end(data);
  });
}

const httpServer = http.createServer((req, res) => {
  // Strip the query string (e.g. game.js?v=<sha> cache buster).
  const rawPath = req.url.split("?")[0];

  if (req.method === "POST" && rawPath === "/api/tune/save") {
    handleTuneSave(req, res);
    return;
  }

  // /api/kiosk/exit — close the fullscreen browser to the desktop.
  // 404 rather than 403 when unarmed, like /api/dev/*: a bridge without
  // KIOSK_STATE_DIR should be indistinguishable from one built without the
  // route.  Loopback-only on top of that, because the only caller that should
  // ever exist is a page in the browser running on this same machine.
  // NOTE the loopback test does NOT survive a reverse proxy — nginx forwards
  // from 127.0.0.1 — which is why the env var, not this check, is what keeps
  // the switch off the public VPS.  vps-setup.sh also refuses the path at the
  // nginx layer so that neither one is load-bearing alone.
  if (rawPath === "/api/kiosk/exit") {
    if (!KIOSK_STATE_DIR) { res.writeHead(404); res.end("Not found"); return; }
    if (req.method !== "POST") { res.writeHead(405); res.end("Method not allowed"); return; }
    if (!isLoopback(req.socket.remoteAddress)) {
      res.writeHead(403); res.end("Forbidden"); return;
    }
    handleKioskExit(res);
    return;
  }

  // /api/dev/* — the board-stat override used by bridge/tools/inject.mjs.
  // 404 rather than 403 when disabled: a bridge without DEV_INJECT should be
  // indistinguishable from one built without these routes at all.
  if (rawPath.startsWith("/api/dev/")) {
    if (!DEV_INJECT) { res.writeHead(404); res.end("Not found"); return; }
    if (req.method === "GET" && rawPath === "/api/dev/boards") {
      handleDevBoards(res);
      return;
    }
    if (req.method === "POST" && rawPath === "/api/dev/inject") {
      handleDevInject(req, res);
      return;
    }
    res.writeHead(404); res.end("Not found");
    return;
  }

  // /tune — the config editor (query string carries ?from=<hash>).
  if (rawPath === "/tune") {
    serveFile(res, WEB_DIR, "/tune.html", { "Cache-Control": "no-cache" });
    return;
  }

  // /onboard — the badge colour kiosk.  Standalone, like /tune: it never
  // touches a lobby or the Zig binaries, it just needs the bridge because the
  // bridge is what holds the serial ports.
  if (rawPath === "/onboard") {
    serveFile(res, WEB_DIR, "/onboard.html", { "Cache-Control": "no-cache" });
    return;
  }

  // /powerups — the powerup kiosk, standalone on /onboard's terms and for the
  // same reason: it hands items to badges over the serial ports the bridge
  // holds, and has nothing to do with a game being in progress.
  if (rawPath === "/powerups") {
    serveFile(res, WEB_DIR, "/powerups.html", { "Cache-Control": "no-cache" });
    return;
  }

  // /game — the game shell.  It lives here rather than at / so that / can be
  // the station directory: the kiosks are touchscreens with no keyboard and no
  // address bar, so without a page that links the stations there is no way to
  // reach one but to edit KIOSK_URL over a shell on the Pi.
  //
  // Opening it IS the room request: bare, it creates a lobby; with `?code=`,
  // it joins that one.  The query string is the whole of the choice, which is
  // what lets the directory's one Play tile reach play in a single tap — a
  // create/join screen behind it could only be worked with a keyboard the
  // kiosks do not have.
  //
  // NOTE: this page alone has no link back to the directory, unlike the two
  // kiosks.  The canvas takes clicks for casting, so a corner control here is
  // a misfire waiting to happen mid-round.  A station that should never show
  // the directory at all wants KIOSK_URL=/game instead.
  if (rawPath === "/game") {
    serveFile(res, WEB_DIR, "/game.html", { "Cache-Control": "no-cache" });
    return;
  }

  // /config/{hash}[/...] — play (or fetch data for) a saved custom config.
  const cfgMatch = rawPath.match(/^\/config\/([0-9a-f]{16})(\/.*)?$/);
  if (cfgMatch) {
    const [, hash, rest] = cfgMatch;
    if (!rest || rest === "/") {
      // The game shell; game.js reads the hash from location.pathname.
      serveFile(res, WEB_DIR, "/game.html", { "Cache-Control": "no-cache" });
    } else if (rest.startsWith("/data/")) {
      serveFile(res, path.join(CUSTOM_DIR, hash), rest.slice("/data".length));
    } else {
      res.writeHead(404); res.end("Not found");
    }
    return;
  }

  // / — the station directory.  no-cache like every other page route: this is
  // the one page a kiosk holds open indefinitely, so a stale copy is the one
  // that survives longest.
  if (rawPath === "/") {
    serveFile(res, WEB_DIR, "/index.html", { "Cache-Control": "no-cache" });
    return;
  }

  // /data/* serves the game data files (same ones the servers load).
  if (rawPath.startsWith("/data/")) {
    serveFile(res, DATA_DIR, rawPath.slice("/data".length));
    return;
  }
  serveFile(res, WEB_DIR, rawPath);
});

// ---------------------------------------------------------------------------
// /api/tune/save — persist a designer config and hand back a play URL
// ---------------------------------------------------------------------------

const MAX_TUNE_BODY = 256 * 1024;

/** JSON.stringify with recursively sorted object keys (stable hashing). */
function stableStringify(value) {
  if (Array.isArray(value)) {
    return "[" + value.map(stableStringify).join(",") + "]";
  }
  if (value !== null && typeof value === "object") {
    return "{" + Object.keys(value).sort()
      .map((k) => JSON.stringify(k) + ":" + stableStringify(value[k]))
      .join(",") + "}";
  }
  return JSON.stringify(value);
}

/**
 * Run `server --validate` against a data dir; resolves with
 * { ok, errors: string[] }.  The Zig config loader is the single source of
 * truth for limits — the bridge never re-implements validation rules.
 */
function validateDataDir(dir) {
  return new Promise((resolve) => {
    // Positional port arg first ("0", unused in validate mode) — the server
    // treats its first argument as the port.
    const proc = spawn(SERVER_BIN, ["0", "--data-dir", dir, "--validate"], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    proc.stderr.on("data", (d) => { stderr += d.toString(); });
    proc.on("error", (err) => {
      resolve({ ok: false, errors: [`validator spawn failed: ${err.message}`] });
    });
    proc.on("exit", (code) => {
      if (code === 0) { resolve({ ok: true, errors: [] }); return; }
      // Keep only the config loader's precise diagnostics; the trailing
      // generic "failed to load game data" line adds nothing.
      const errors = stderr.split("\n")
        .filter((l) => l.includes("error(config):"))
        .map((l) => l.replace(/^error\(config\):\s*/, "").trim())
        .filter((l) => l.length > 0);
      resolve({ ok: false, errors: errors.length ? errors : ["config validation failed"] });
    });
  });
}

/**
 * POST body: { balance: <balance.json object>,
 *              encounter: { charges, zones: [...] } }
 * The encounter is saved as the single default encounter labelled "custom".
 * `zones` is a legacy wire name: the Zig loader sums the entries into the one
 * slime pool this game has, so old saved configs keep working.
 * Responds 200 { url, hash } or 400 { errors: [...] }.
 */
function handleTuneSave(req, res) {
  const reply = (status, obj) => {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(obj));
  };

  let body = "";
  let overflow = false;
  req.on("data", (chunk) => {
    body += chunk;
    if (body.length > MAX_TUNE_BODY) { overflow = true; req.destroy(); }
  });
  req.on("close", () => { if (overflow) reply(413, { errors: ["config too large"] }); });
  req.on("end", async () => {
    if (overflow) return;
    let msg;
    try { msg = JSON.parse(body); } catch {
      reply(400, { errors: ["body is not valid JSON"] });
      return;
    }
    if (typeof msg !== "object" || msg === null ||
        typeof msg.balance !== "object" || msg.balance === null ||
        typeof msg.encounter !== "object" || msg.encounter === null) {
      reply(400, { errors: ["expected { balance, encounter }"] });
      return;
    }

    const balanceDoc = msg.balance;
    const encountersDoc = {
      default: "custom",
      encounters: [{
        label: "custom",
        charges: msg.encounter.charges,
        zones: msg.encounter.zones,
      }],
    };
    // Content hash over the tables alone.  Historic hashes also folded in a
    // game mode; those directories still exist and still validate, they simply
    // are not reproducible from this endpoint any more.
    const hash = require("crypto").createHash("sha256")
      .update(stableStringify({ balance: balanceDoc, encounters: encountersDoc }))
      .digest("hex").slice(0, 16);
    const dir = path.join(CUSTOM_DIR, hash);
    const url = `/config/${hash}`;

    // Content-addressed: an existing dir already passed validation.
    if (fs.existsSync(dir)) { reply(200, { url, hash }); return; }

    try {
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, "balance.json"), JSON.stringify(balanceDoc, null, 2) + "\n");
      fs.writeFileSync(path.join(dir, "encounters.json"), JSON.stringify(encountersDoc, null, 2) + "\n");
    } catch (err) {
      console.error("[tune] save write failed:", err.message);
      fs.rmSync(dir, { recursive: true, force: true });
      reply(500, { errors: ["failed to write config"] });
      return;
    }

    const result = await validateDataDir(dir);
    if (!result.ok) {
      fs.rmSync(dir, { recursive: true, force: true });
      reply(400, { errors: result.errors });
      return;
    }
    console.log(`[tune] saved config ${hash}`);
    reply(200, { url, hash });
  });
}

// ---------------------------------------------------------------------------
// Kiosk kill switch  (/api/kiosk/exit, KIOSK_STATE_DIR only)
// ---------------------------------------------------------------------------
//
// The Pi has no keyboard, and Chromium runs with --kiosk, so there is no tab
// bar, no address bar and no window chrome to close.  Getting to the desktop
// meant SSH-ing in.  This route is the hidden hold-button on the station
// directory reaching the one process that can do something about it.
//
// Closing the browser is only half of it: pi-kiosk.sh RELAUNCHES Chromium 3
// seconds after any exit, on purpose, so that a crash at an unattended event
// heals itself.  So the flag is written first and the signal sent second —
// the flag is what tells that loop this exit was asked for.  Written first
// because the ordering is the whole guarantee: a browser reaped before the
// flag landed would be restarted, and the operator would be left holding a
// button that appears to do nothing.
//
// Not a `pkill`: the bridge must never guess which process is the kiosk.
// pi-kiosk.sh publishes the PID it actually launched, and the cmdline check
// below refuses to signal anything that is not still that browser — a pidfile
// outliving its process is otherwise a licence to kill a recycled PID.

/**
 * Verify a PID is still the kiosk browser before signalling it.
 *
 * Linux only, which is where kiosks run; on anything without /proc this
 * cannot be checked and the PID is taken on trust (a dev box that set
 * KIOSK_STATE_DIR asked for this).
 */
function pidIsKioskBrowser(pid) {
  let cmdline;
  try {
    cmdline = fs.readFileSync(`/proc/${pid}/cmdline`, "utf8");
  } catch {
    // ENOENT on Linux means the process is gone; on macOS it means /proc
    // does not exist.  Distinguished by whether /proc itself is there.
    return !fs.existsSync("/proc");
  }
  // Argv is NUL-separated.  --kiosk is the flag that makes this the fullscreen
  // browser rather than some other Chromium the operator opened.
  return cmdline.split("\0").includes("--kiosk");
}

function handleKioskExit(res) {
  const fail = (code, error) => {
    console.error(`[bridge] kiosk exit refused: ${error}`);
    res.writeHead(code, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: false, error }));
  };

  let pid;
  try {
    pid = parseInt(fs.readFileSync(KIOSK_PID_FILE, "utf8").trim(), 10);
  } catch {
    return fail(409, "no browser is running (pi-kiosk.sh publishes no PID)");
  }
  if (!Number.isInteger(pid) || pid <= 1) {
    return fail(409, "kiosk pidfile is not a usable PID");
  }
  if (!pidIsKioskBrowser(pid)) {
    return fail(409, `PID ${pid} is not the kiosk browser (stale pidfile)`);
  }

  // Flag before signal — see the note above; this ordering is load-bearing.
  try {
    fs.writeFileSync(KIOSK_EXIT_FLAG, `${new Date().toISOString()}\n`);
  } catch (e) {
    return fail(500, `could not write the exit flag: ${e.message}`);
  }

  try {
    process.kill(pid, "SIGTERM");
  } catch (e) {
    // The flag would otherwise sit there and quit the NEXT browser to exit.
    try { fs.unlinkSync(KIOSK_EXIT_FLAG); } catch { /* nothing to undo */ }
    return fail(500, `could not signal PID ${pid}: ${e.message}`);
  }

  console.log(`[bridge] kiosk exit requested — SIGTERM to PID ${pid}`);
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ ok: true, pid }));
}

// ---------------------------------------------------------------------------
// Dev board-stat override  (/api/dev/*, DEV_INJECT=1 only)
// ---------------------------------------------------------------------------
//
// A board's stats reach the game exactly once, at one instant: the server
// freezes a player's Appearance when they take their seat, and the board
// reports CTRL:STAT once per link.  That is the right shape for the event and
// a miserable one to develop a RENDERER against — eyeballing a brood palette
// meant reflashing a badge and replugging it, per palette.
//
// So these routes rewrite the bridge's in-memory picture of a board and then
// reseat it.  Nothing is written to the badge: no GAME:SCORE, no LED:SET, no
// flash erase.  An override lives exactly as long as the link does, because
// the next CTRL:STAT (i.e. the next replug) overwrites these same fields with
// what the flash actually holds.  Unplug the badge and the lie is gone.
//
// The reseat is not a detail, it IS the mechanism: destroy() drops the board's
// player, and the assignment pass immediately rebuilds one, whose fresh Zig
// client is handed the rewritten statLines() before its JOIN.

/** Serialise one board for /api/dev/boards. */
function devBoardView(ctrl) {
  return {
    linkId: ctrl.linkId,
    uid: ctrl.uid,
    appetite: ctrl.appetite,
    babies: ctrl.babies,
    powerups: ctrl.powerups,
    critter: ctrl.critter,
    colors: ctrl.led === null
      ? null
      : ctrl.led.map((c) => c.toString(16).padStart(6, "0")),
    seed: ctrl.broodSeed === null
      ? null
      : ctrl.broodSeed.toString(16).padStart(8, "0"),
    seated: ctrl.playerSession !== null,
  };
}

function handleDevBoards(res) {
  const boards = controllerManager.listLinked()
    .map((b) => controllerManager.linkedById(b.linkId))
    .filter((c) => c !== null)
    .map(devBoardView);
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ boards }));
}

/**
 * POST body: { target?: "all" | <linkId number> | <uid string>,
 *              babies?: [a,b,c,d,e], colors?: ["rrggbb" x3] | null,
 *              seed?: <u32> | null, powerups?: [n], reseat?: boolean }
 *
 * An ABSENT key leaves that stat alone; an explicit null clears it.  The two
 * have to be distinguishable because "no palette" is a state a real board can
 * be in (never onboarded) and therefore a state worth being able to test.
 *
 * Responds 200 { applied: [<board view>] } or 400 { errors: [...] }.
 */
function handleDevInject(req, res) {
  const reply = (status, obj) => {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(obj));
  };

  let body = "";
  let overflow = false;
  req.on("data", (chunk) => {
    body += chunk;
    if (body.length > 8192) { overflow = true; req.destroy(); }
  });
  req.on("close", () => { if (overflow) reply(413, { errors: ["body too large"] }); });
  req.on("end", () => {
    if (overflow) return;
    let msg;
    try { msg = JSON.parse(body); } catch {
      reply(400, { errors: ["body is not valid JSON"] });
      return;
    }
    if (typeof msg !== "object" || msg === null) {
      reply(400, { errors: ["expected an object"] });
      return;
    }

    // Validate everything BEFORE touching a single board: a half-applied
    // injection across several badges is not a state worth being able to
    // reach, and reporting it would be worse than refusing it.
    const errors = [];

    let babies;
    if ("babies" in msg) {
      if (!Array.isArray(msg.babies) || msg.babies.length !== BABY_TYPE_COUNT ||
          !msg.babies.every((n) => Number.isInteger(n) && n >= 0)) {
        errors.push(`babies must be ${BABY_TYPE_COUNT} non-negative integers`);
      } else {
        babies = msg.babies.map((n) => n >>> 0);
      }
    }

    let powerups;
    if ("powerups" in msg) {
      // Held to the same ceiling the badge itself saturates at, so an
      // injected board is one a badge could actually be — a dev tool that can
      // reach states the hardware cannot is a dev tool that tests fiction.
      if (!Array.isArray(msg.powerups) || msg.powerups.length !== POWERUP_KIND_COUNT ||
          !msg.powerups.every((n) => Number.isInteger(n) && n >= 0 && n <= POWERUP_COUNT_MAX)) {
        errors.push(
          `powerups must be ${POWERUP_KIND_COUNT} integers in 0..${POWERUP_COUNT_MAX}`);
      } else {
        powerups = msg.powerups.map((n) => n >>> 0);
      }
    }

    let colors;
    if ("colors" in msg) {
      if (msg.colors === null) colors = null;
      else if (isPalette(msg.colors)) colors = msg.colors.map((c) => parseInt(c, 16));
      else errors.push(`colors must be null or ${PALETTE_COLOR_COUNT} six-digit hex strings`);
    }

    let seed;
    if ("seed" in msg) {
      if (msg.seed === null) seed = null;
      else if (Number.isInteger(msg.seed) && msg.seed >= 0 && msg.seed <= 0xffffffff) {
        seed = msg.seed >>> 0;
      } else errors.push("seed must be null or a u32");
    }

    const target = "target" in msg ? msg.target : "all";
    if (target !== "all" && typeof target !== "number" && typeof target !== "string") {
      errors.push("target must be \"all\", a linkId number, or a uid string");
    }

    if (errors.length > 0) { reply(400, { errors }); return; }

    const linked = controllerManager.listLinked()
      .map((b) => controllerManager.linkedById(b.linkId))
      .filter((c) => c !== null);
    const targeted = target === "all"
      ? linked
      : linked.filter((c) => (typeof target === "number" ? c.linkId === target : c.uid === target));

    if (targeted.length === 0) {
      reply(404, { errors: [linked.length === 0
        ? "no boards are linked"
        : `no linked board matches ${JSON.stringify(target)}`] });
      return;
    }

    const reseat = msg.reseat !== false;
    const applied = [];
    for (const ctrl of targeted) {
      if (babies !== undefined) ctrl.babies = [...babies];
      if (powerups !== undefined) ctrl.powerups = [...powerups];
      if (colors !== undefined) ctrl.led = colors === null ? null : [...colors];
      if (seed !== undefined) ctrl.broodSeed = seed;
      // Reseat AFTER the rewrite, and only if the board is actually playing:
      // an unseated board has nothing to tear down and will pick the new
      // stats up whenever the assignment pass next reaches it.
      const wasSeated = ctrl.playerSession !== null;
      if (reseat && wasSeated) ctrl.playerSession.destroy("dev inject");
      applied.push({ ...devBoardView(ctrl), reseated: reseat && wasSeated });
      console.log(`[dev] injected uid=${ctrl.uid} babies=${ctrl.babies.join(",")} ` +
        `powerups=${ctrl.powerups.join(",")} ` +
        `seed=${ctrl.broodSeed === null ? "-" : ctrl.broodSeed.toString(16)} ` +
        `reseat=${reseat && wasSeated}`);
      // Recorded, and recorded as an INJECTION.  These stats did not come from
      // the badge and the badge does not know about them, so a record that
      // filed them alongside real CTRL:STAT reports would be a record of games
      // that were never really played with these creatures.
      ledger.badgeStat({
        uid: ctrl.uid,
        link: ctrl.linkId,
        state: boardStateView(ctrl),
        statReported: true,
        source: "dev_inject",
      });
    }
    reply(200, { applied });
  });
}

// ---------------------------------------------------------------------------
// Port allocation
// ---------------------------------------------------------------------------

/** Ports currently claimed by a live server process. */
const usedPorts = new Set();

/**
 * Find a TCP port that is both not in `usedPorts` and not already bound
 * by another process.  Scans upward from SERVER_PORT_BASE.
 * Returns a Promise<number>.
 */
function findFreePort() {
  return new Promise((resolve, reject) => {
    let candidate = SERVER_PORT_BASE;
    const tryNext = () => {
      if (usedPorts.has(candidate)) { candidate++; tryNext(); return; }
      const srv = net.createServer();
      srv.once("error", () => { candidate++; tryNext(); });
      srv.once("listening", () => {
        srv.close(() => resolve(candidate));
      });
      srv.listen(candidate, "0.0.0.0");
    };
    tryNext();
  });
}

// ---------------------------------------------------------------------------
// Lobby registry
// ---------------------------------------------------------------------------

/**
 * @typedef {{
 *   code:        string,
 *   port:        number,
 *   proc:        import("child_process").ChildProcess,
 *   tabCount:    number,
 *   idleTimer:   ReturnType<typeof setTimeout> | null,
 *   configHash:  string | null,
 * }} LobbyRoom
 */

/** @type {Map<string, LobbyRoom>} */
const lobbyRegistry = new Map();

/** Generate a random 6-char join code (same charset as Zig server). */
function generateCode() {
  let code = "";
  for (let i = 0; i < 6; i++)
    code += CODE_CHARSET[Math.floor(Math.random() * CODE_CHARSET.length)];
  return code;
}

/** Generate a unique code not already in the registry. */
function uniqueCode() {
  let code;
  do { code = generateCode(); } while (lobbyRegistry.has(code));
  return code;
}

/**
 * Spawn a new game server process for a lobby with the given code and port.
 * Returns a LobbyRoom immediately (process may not be ready yet).
 *
 * @param {string} code
 * @param {number} port
 * @param {string | null} configHash - saved /tune config, or null for defaults
 * @returns {LobbyRoom}
 */
function spawnLobbyServer(code, port, configHash) {
  const dataDir = dataDirFor(configHash);
  console.log(`[lobby] spawning server for code=${code} port=${port} config=${configHash ?? "default"}`);
  usedPorts.add(port);

  const args = [String(port), "--join-code", code, "--data-dir", dataDir];
  const proc = spawn(SERVER_BIN, args, {
    stdio: ["ignore", "pipe", "pipe"],
  });

  proc.stdout.on("data", (d) => {
    process.stdout.write(`[server:${code}] ${d}`);
  });
  proc.stderr.on("data", (d) => {
    process.stderr.write(`[server:${code}] ${d}`);
  });

  proc.on("error", (err) => {
    // Spawn failure (e.g. ENOENT: binary missing) emits 'error' without 'exit',
    // so clean up here and show affected tabs the reason instead of leaving
    // them stuck on the connecting screen forever.
    console.error(`[lobby] server proc error (${code}):`, err.message);
    usedPorts.delete(port);
    lobbyRegistry.delete(code);
    for (const s of activeSessions) {
      if (s.room && s.room.code === code) s.failWithError("server_error");
    }
  });

  proc.on("exit", (code_) => {
    console.log(`[lobby] server proc exited (${code}) code=${code_}`);
    usedPorts.delete(port);
    lobbyRegistry.delete(code);
  });

  /** @type {LobbyRoom} */
  const room = { code, port, proc, tabCount: 0, idleTimer: null, configHash };
  lobbyRegistry.set(code, room);
  return room;
}

/** Decrement tab count for a room; schedule shutdown if it reaches 0. */
function roomTabLeft(room) {
  room.tabCount = Math.max(0, room.tabCount - 1);
  if (room.tabCount === 0) {
    room.idleTimer = setTimeout(() => {
      if (room.tabCount === 0) {
        console.log(`[lobby] idle timeout — killing server for code=${room.code}`);
        if (room.proc.pid !== undefined) room.proc.kill();
        usedPorts.delete(room.port);
        lobbyRegistry.delete(room.code);
      }
    }, LOBBY_IDLE_TIMEOUT_MS);
  }
}

/** Cancel idle shutdown when a new tab joins a room. */
function roomTabJoined(room) {
  if (room.idleTimer !== null) {
    clearTimeout(room.idleTimer);
    room.idleTimer = null;
  }
  room.tabCount++;
}

// ---------------------------------------------------------------------------
// Per-tab session
// ---------------------------------------------------------------------------

/** @type {Set<TabSession>} */
const activeSessions = new Set();

/** The single open onboarding kiosk (/onboard), or null.  @type {OnboardSession | null} */
let onboardSession = null;

/** Every open powerup kiosk (/powerups).  Unlike the onboarding kiosk this is
 *  a SET: those pages only press buttons and read back counts, and the grants
 *  themselves are serialised by the controller manager, so several open tabs
 *  cannot race the way two colour rolls on one badge would.
 *  @type {Set<PowerupSession>} */
const powerupSessions = new Set();

/**
 * The badge ledger: a durable, append-only OBSERVATION of what the badges did.
 *
 * Write-only by construction, and it matters that it stays that way — a badge's
 * flash is the only authority on its own contents, and a queryable record of
 * what the bridge last saw would become a second one.  See bridge/ledger.js.
 */
const ledger = new Ledger({ dir: BADGE_LOG_DIR });

// Hardware controllers (dc_rp2040 boards on USB serial).  Every linked board
// is its own player (ControllerSession) in the active lobby.
const controllerManager = new ControllerManager({
  ledger,
  clientBin: CLIENT_BIN,
  // Boards join the single active lobby, or the newest when several exist
  // (Map preserves insertion order), or wait when there is none.
  pickRoom: () => {
    const rooms = [...lobbyRegistry.values()];
    return rooms.length > 0 ? rooms[rooms.length - 1] : null;
  },
  // Controller players count as room occupants so a lobby that is all boards
  // doesn't get idle-killed under the players' feet.
  roomJoined: (room) => roomTabJoined(room),
  roomLeft: (room) => roomTabLeft(room),
  isRoomAlive: (room) => lobbyRegistry.get(room.code) === room,
  moveLabels: (configHash) => moveLabelsFor(configHash ?? null),
  // The kiosks re-read the board list on every link/unlink: the onboarding
  // one to know what is left to roll, the powerup ones to show how many
  // badges the next press will reach.  Nothing else cares.
  boardsChanged: () => {
    if (onboardSession !== null) onboardSession.sendQueue();
    for (const s of powerupSessions) s.sendBoards();
  },
});

class TabSession extends PlayerSession {
  /** @param {WebSocket} tabWs */
  constructor(tabWs) {
    super({ clientBin: CLIENT_BIN, label: "tab" });
    this.tabWs          = tabWs;
  }

  // ---- PlayerSession hooks --------------------------------------------------

  onZigFrame(msg, line) {
    if (msg.tag === "render") {
      if (this.tabWs.readyState === WebSocket.OPEN) this.tabWs.send(line);
    } else {
      console.warn("[bridge] unknown Zig frame tag:", msg.tag);
    }
  }

  onZigSpawnError(_err) {
    // Without handling, the tab hangs on "Connecting..." forever.
    this.failWithError("server_error");
  }

  // ---- Room routing -------------------------------------------------------

  /**
   * Called once a room has been chosen.  Starts the Zig client and connects
   * it to the room's server port.
   * @param {LobbyRoom} room
   */
  startInRoom(room) {
    if (this.started) return;
    this.started = true;
    this.room    = room;
    roomTabJoined(room);
    this.spawnZig();
    // A waiting board may now get a player in this (possibly new) room.
    controllerManager.sessionStarted();
    // Small delay: give the server process a moment to bind its port if just spawned.
    setTimeout(() => {
      if (!this.closed) this.connectToServer(room.port);
    }, 200);
  }

  /**
   * Tell the browser this tab has no room.  Terminal from the tab's point of
   * view: room choice is made by its URL, so there is nothing it can amend in
   * place and it shows a dead end offering the station directory.
   * @param {string} reason
   */
  sendRoomError(reason) {
    if (this.tabWs.readyState === WebSocket.OPEN) {
      this.tabWs.send(JSON.stringify({ tag: "error", reason }));
    }
  }

  /**
   * Handle the room request a tab sends the moment its socket opens.  The tab
   * reads it off its own URL — `/game` and `/config/{hash}` create, `?code=`
   * joins — so this runs once per session, before any key can be forwarded.
   * @param {{ action: string, code?: string, config?: string }} msg
   */
  async handleRoomAction(msg) {
    if (this.started) return; // already in a room

    if (msg.action === "create") {
      // Optional saved /tune config for this lobby.
      let configHash = null;
      if (typeof msg.config === "string" && msg.config.length > 0) {
        if (!HASH_RE.test(msg.config) || !fs.existsSync(dataDirFor(msg.config))) {
          console.warn(`[lobby] create with unknown config '${msg.config}'`);
          this.sendRoomError("config_not_found");
          return;
        }
        configHash = msg.config;
      }
      const code = uniqueCode();
      let port;
      try { port = await findFreePort(); } catch (err) {
        console.error("[lobby] findFreePort failed:", err);
        this.sendRoomError("server_error");
        return;
      }
      const room = spawnLobbyServer(code, port, configHash);
      console.log(`[lobby] created room code=${code} port=${port}`);
      // Acknowledge before the Zig client has connected so the browser shows
      // the connecting screen immediately.  `config` lets the tab load the
      // matching balance tables; `code` is what it pins into its own URL, so
      // a reconnect rejoins THIS room instead of asking for another one.
      if (this.tabWs.readyState === WebSocket.OPEN) {
        this.tabWs.send(JSON.stringify({ tag: "joining", code: room.code, config: room.configHash }));
      }
      this.startInRoom(room);
      return;
    }

    if (msg.action === "join") {
      const rawCode = (msg.code || "").toUpperCase().trim();
      if (rawCode.length !== 6) {
        this.sendRoomError("invalid_code");
        return;
      }
      const room = lobbyRegistry.get(rawCode);
      if (!room) {
        console.log(`[lobby] join: code=${rawCode} not found; registry=${[...lobbyRegistry.keys()].join(",") || "(empty)"}`);
        this.sendRoomError("not_found");
        return;
      }
      console.log(`[lobby] join: code=${rawCode} found, routing tab`);
      // Acknowledge immediately so the browser leaves the connecting screen
      // before the Zig client finishes connecting to the server.  `config`
      // makes joiners adopt the lobby's balance tables (may differ from the
      // page they joined from).
      if (this.tabWs.readyState === WebSocket.OPEN) {
        this.tabWs.send(JSON.stringify({ tag: "joining", code: room.code, config: room.configHash }));
      }
      this.startInRoom(room);
      return;
    }

    console.warn("[bridge] unknown room action:", msg.action);
  }

  // ---- Lifecycle ----------------------------------------------------------

  /**
   * Abort the current room attempt and show the tab a dead end.  Unlike
   * teardown(), the browser WebSocket stays open — closing it would start the
   * tab's reconnect loop, which would re-state the same doomed request every
   * second and bury the reason under a flickering connecting screen.
   *
   * `started` is cleared so a tab that does come back around (a reload, a
   * hand-edited URL) is treated as a fresh request rather than one already in
   * a room.
   * @param {string} reason
   */
  failWithError(reason) {
    if (this.closed) return;
    this.closeShared();
    if (this.room) { roomTabLeft(this.room); this.room = null; }
    this.started = false;
    console.warn(`[bridge] tab left without a room (${reason})`);
    this.sendRoomError(reason);
  }

  teardown() {
    if (this.closed) return;
    this.closed = true;
    this.closeShared();
    if (this.room)     { roomTabLeft(this.room); this.room = null; }
    activeSessions.delete(this);
    console.log(`[bridge] tab session torn down (${activeSessions.size} active)`);
  }
}

// ---------------------------------------------------------------------------
// Onboarding kiosk session  (/onboard-ws)
// ---------------------------------------------------------------------------

/**
 * The /onboard page's link to the serial ports.  Deliberately NOT a
 * PlayerSession: onboarding spawns no Zig client, joins no lobby, and consumes
 * no session slot — it colours badges, which has nothing to do with a game
 * being in progress.
 *
 * The bridge holds no queue.  It publishes the set of currently linked boards
 * and routes two verbs at them; the page decides which board it is rolling and
 * remembers which link ids it has finished.  That split is what makes the
 * "roll each badge once, but roll a replugged one again" rule fall out for
 * free: ids identify a LINK, so a badge left plugged in keeps its id and stays
 * done, while a replugged one arrives with a new id and is rolled afresh.
 */
class OnboardSession {
  /** @param {WebSocket} ws */
  constructor(ws) {
    this.ws = ws;
    this.closed = false;
  }

  send(obj) {
    if (!this.closed && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(obj));
    }
  }

  /** Publish the currently linked boards, newest last. */
  sendQueue() {
    this.send({ tag: "queue", links: controllerManager.listLinked().map((b) => b.linkId) });
  }

  /**
   * @param {{ action?: string, linkId?: unknown, colors?: unknown }} msg
   */
  handle(msg) {
    // An unresolvable link id is the unplugged case, not an error: the board
    // went away mid-roll and the page skips it on the next queue message.
    if (msg.action === "live") {
      if (typeof msg.linkId !== "number") return;
      const ctrl = controllerManager.linkedById(msg.linkId);
      if (ctrl !== null) ctrl.sendLive(msg.colors);
      return;
    }

    if (msg.action === "commit") {
      if (typeof msg.linkId !== "number") return;
      const linkId = msg.linkId;
      const ctrl = controllerManager.linkedById(linkId);
      if (ctrl === null) {
        this.send({ tag: "commit_failed", linkId, reason: "unlinked" });
        return;
      }
      // sendPalette calls back exactly once — on the board's post-save ack, on
      // running out of retries, or on the board going away mid-roll — so the
      // page can never be left waiting on a badge that will never answer.
      ctrl.sendPalette(msg.colors, (err) => {
        // The ledger is told on BOTH edges.  A failed roll is the interesting
        // one: it is the case where the operator saw a badge refuse, and the
        // colours it is actually wearing are whatever it had before.
        if (err === null) {
          this.send({ tag: "committed", linkId });
          ledger.onboardCommitted({
            uid: ctrl.uid, link: linkId, colors: msg.colors,
          });
        } else {
          this.send({ tag: "commit_failed", linkId, reason: err });
          ledger.onboardFailed({
            uid: ctrl.uid, link: linkId, colors: msg.colors, reason: err,
          });
        }
      });
      return;
    }

    console.warn("[onboard] unknown action:", msg.action);
  }

  teardown() {
    if (this.closed) return;
    this.closed = true;
    if (onboardSession === this) onboardSession = null;
    console.log("[onboard] kiosk closed");
  }
}

// noServer, not { server, path }: see the upgrade router below.
const onboardWss = new WebSocketServer({ noServer: true });

onboardWss.on("connection", (ws) => {
  // One kiosk at a time.  Two pages rolling the same badge would race on its
  // LEDs and on its flash, and there is no sensible way to arbitrate that.
  if (onboardSession !== null) {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ tag: "busy" }));
    ws.close();
    console.warn("[onboard] rejected kiosk: one already open");
    return;
  }

  const session = new OnboardSession(ws);
  onboardSession = session;
  console.log("[onboard] kiosk opened");

  ws.on("close", () => session.teardown());
  ws.on("error", () => session.teardown());
  ws.on("message", (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    if (typeof msg !== "object" || msg === null) return;
    session.handle(msg);
  });

  // Whatever is already plugged in is already waiting to be rolled.
  session.sendQueue();
});

// ---------------------------------------------------------------------------
// Powerup kiosk  (/powerups-ws)
// ---------------------------------------------------------------------------

/**
 * The powerup kiosk: one button per powerup kind, and pressing one hands that
 * powerup to every badge currently linked.
 *
 * Standalone on OnboardSession's terms — no lobby, no session slot, no Zig
 * process — because handing out an item is a thing done to BADGES, and a badge
 * carries what it carries whether or not a game is running.
 *
 * The bridge keeps no inventory of its own here, and that is the whole design.
 * A powerup lives in one place, the badge's flash, which survives this process
 * and every game played on it; this page is a remote control for a fan-out,
 * and every count it displays came back off a badge in that badge's own ack.
 * The alternative — a tally on this side — would be a second copy that is
 * wrong the first time a badge is granted by another bridge run, saturates, or
 * is reflashed.
 *
 * Several of these may be open at once (unlike the colour kiosk): they only
 * press buttons, and the manager serialises the grants themselves.
 */
class PowerupSession {
  /** @param {WebSocket} ws */
  constructor(ws) {
    this.ws = ws;
    this.closed = false;
  }

  send(obj) {
    if (!this.closed && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(obj));
    }
  }

  /**
   * Publish the powerups this bridge knows how to grant, as {ordinal, name}.
   * The page renders one button per entry and sends back the ORDINAL, so the
   * button list cannot drift out of step with the firmware's enum the way a
   * list hardcoded in the page would.
   */
  sendKinds() {
    this.send({
      tag: "kinds",
      kinds: POWERUP_NAMES.map((name, ordinal) => ({ ordinal, name })),
    });
  }

  /** Publish how many badges the next press would reach. */
  sendBoards() {
    this.send({ tag: "boards", count: controllerManager.listLinked().length });
  }

  /** @param {{ action?: string, kind?: unknown }} msg */
  handle(msg) {
    if (msg.action === "grant") {
      if (typeof msg.kind !== "number") return;
      // grantPowerup settles for every targeted badge — on its post-save ack,
      // on running out of retries, or on it being unplugged mid-grant — so the
      // page can never be left waiting.  It also queues behind any grant
      // already running, which is what makes a mashed button safe.
      controllerManager.grantPowerup(msg.kind).then((summary) => {
        this.send({ tag: "granted", kind: summary.kind, results: summary.results });
        // The counts moved on every badge, not just this page's: a second
        // kiosk tab showing stale numbers would invite granting twice.
        for (const s of powerupSessions) {
          if (s !== this) s.sendBoards();
        }
      });
      return;
    }

    console.warn("[powerups] unknown action:", msg.action);
  }

  teardown() {
    if (this.closed) return;
    this.closed = true;
    powerupSessions.delete(this);
    console.log(`[powerups] kiosk closed (${powerupSessions.size} open)`);
  }
}

// noServer, not { server, path }: see the upgrade router below.
const powerupWss = new WebSocketServer({ noServer: true });

powerupWss.on("connection", (ws) => {
  const session = new PowerupSession(ws);
  powerupSessions.add(session);
  console.log(`[powerups] kiosk opened (${powerupSessions.size} open)`);

  ws.on("close", () => session.teardown());
  ws.on("error", () => session.teardown());
  ws.on("message", (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    if (typeof msg !== "object" || msg === null) return;
    session.handle(msg);
  });

  session.sendKinds();
  session.sendBoards();
});

// ---------------------------------------------------------------------------
// Browser WebSocket server  (/ws)
// ---------------------------------------------------------------------------

const browserWss = new WebSocketServer({ noServer: true });

// Upgrade router.
//
// Both socket servers are `noServer` and dispatched here by hand.  They have
// to be: a WebSocketServer constructed with { server, path } installs its own
// upgrade listener that ABORTS every request whose path it does not recognise
// (ws/lib/websocket-server.js: !shouldHandle -> abortHandshake 400).  With two
// of them on one HTTP server, each one kills the other's connections depending
// on listener order — which presented as the onboarding kiosk being silently
// dropped a moment after connecting, and the next tab being let in as if the
// first had never opened.
httpServer.on("upgrade", (req, socket, head) => {
  const pathname = new URL(req.url, "http://localhost").pathname;
  const wss = pathname === "/ws" ? browserWss
    : pathname === "/onboard-ws" ? onboardWss
    : pathname === "/powerups-ws" ? powerupWss
    : null;
  if (wss === null) {
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
});

browserWss.on("connection", (tabWs) => {
  if (activeSessions.size >= MAX_SESSIONS) {
    if (tabWs.readyState === WebSocket.OPEN) {
      tabWs.send(JSON.stringify({ tag: "full" }));
    }
    tabWs.close();
    console.warn("[bridge] rejected tab: session full");
    return;
  }

  const session = new TabSession(tabWs);
  activeSessions.add(session);
  console.log(`[bridge] tab connected (${activeSessions.size} active)`);

  tabWs.on("close", () => session.teardown());

  tabWs.on("message", (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }

    // Key events are only forwarded once inside a room.
    if (typeof msg.key === "string") {
      if (session.started) session.writeToZig(`KEY:${msg.key}\n`);
      return;
    }

    // Releases a server's end-screen hold into the next encounter.  Kept as
    // an action rather than a KEY: so it can never be reached by mashing the
    // keyboard — but nothing sends it now: the report's button returns the tab
    // to the station instead, and the room is left to be reaped.
    if (msg.action === "restart") {
      if (session.started) session.writeToZig("RESTART\n");
      return;
    }

    // create / join, sent unprompted the moment the tab's socket opens.
    if (typeof msg.action === "string") {
      session.handleRoomAction(msg).catch((err) => {
        console.error("[bridge] handleRoomAction error:", err);
        session.sendRoomError("server_error");
      });
      return;
    }
  });

  // Nothing is sent to open with: the tab already knows which room it wants
  // (its URL says so) and states it without being asked.
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

httpServer.listen(PORT, () => {
  console.log(`[bridge] listening on http://localhost:${PORT}`);
});

controllerManager.start();

/**
 * Settle the ledger on the way out.
 *
 * Only the ledger: everything else here is either already durable or has no
 * business surviving the process.  The badges keep their own contents in
 * flash, so a bridge that dies mid-game costs nothing but the record of it —
 * which is precisely what this recovers.
 *
 * Exit is guaranteed three ways, because a handler that can hang is a kiosk
 * that cannot be stopped without pulling the plug: a timeout, a second signal,
 * and a swallowed rejection that still exits.
 */
let stopping = false;
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    if (stopping) {
      console.warn(`[bridge] ${sig} again — exiting now`);
      process.exit(130);
    }
    stopping = true;
    console.log(`[bridge] ${sig} — settling the ledger`);
    const bail = setTimeout(() => {
      console.warn("[bridge] ledger did not settle in 3s — exiting anyway");
      process.exit(130);
    }, 3000);
    bail.unref();
    ledger.stop(sig)
      .catch((err) => console.error("[bridge] ledger stop failed:", err.message))
      .then(() => process.exit(0));
  });
}
