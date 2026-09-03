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
 * Starting the next round from the end screen is a CLICK on the report's
 * button ({ action: "restart" } → RESTART stdio line); only tabs have one.
 *
 * Responsibilities per TabSession:
 *   - Show pre_lobby screen until a room is chosen
 *   - Spawn ./zig-out/bin/client and manage its lifecycle
 *   - Connect to the chosen lobby's server WebSocket (owns reconnect loop)
 *   - Relay server frames → Zig stdin as  WIRE:<hex>\n
 *   - Relay Zig stdout send-frames → server WebSocket
 *   - Relay Zig stdout render-frames → the tab's browser WebSocket only
 *   - Relay browser keydown events → Zig stdin as  KEY:<name>\n
 *
 * Shared:
 *   - HTTP static file server on port 3000 (serves web/)
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
 *   Zig stdin  ← RESTART\n      start the next round (tab button click)
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
const { ControllerManager, BABY_TYPE_COUNT, PALETTE_COLOR_COUNT, isPalette } =
  require("./controllers");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const PORT        = parseInt(process.env.PORT || "3000", 10);
// Opt-in, off by default, and deliberately not a config file: the /api/dev
// routes rewrite what a board claims to be, which is a thing a dev box should
// be able to do and a thing the event machine must not.  An env var is the
// one switch that cannot be reached by anyone holding only the HTTP port.
const DEV_INJECT  = process.env.DEV_INJECT === "1";
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

  // /config/{hash}[/...] — play (or fetch data for) a saved custom config.
  const cfgMatch = rawPath.match(/^\/config\/([0-9a-f]{16})(\/.*)?$/);
  if (cfgMatch) {
    const [, hash, rest] = cfgMatch;
    if (!rest || rest === "/") {
      // The game shell; game.js reads the hash from location.pathname.
      serveFile(res, WEB_DIR, "/index.html", { "Cache-Control": "no-cache" });
    } else if (rest.startsWith("/data/")) {
      serveFile(res, path.join(CUSTOM_DIR, hash), rest.slice("/data".length));
    } else {
      res.writeHead(404); res.end("Not found");
    }
    return;
  }

  const urlPath = rawPath === "/" ? "/index.html" : rawPath;

  // /data/* serves the game data files (same ones the servers load).
  if (urlPath.startsWith("/data/")) {
    serveFile(res, DATA_DIR, urlPath.slice("/data".length));
    return;
  }
  serveFile(res, WEB_DIR, urlPath);
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
 *              seed?: <u32> | null, reseat?: boolean }
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
      if (colors !== undefined) ctrl.led = colors === null ? null : [...colors];
      if (seed !== undefined) ctrl.broodSeed = seed;
      // Reseat AFTER the rewrite, and only if the board is actually playing:
      // an unseated board has nothing to tear down and will pick the new
      // stats up whenever the assignment pass next reaches it.
      const wasSeated = ctrl.playerSession !== null;
      if (reseat && wasSeated) ctrl.playerSession.destroy("dev inject");
      applied.push({ ...devBoardView(ctrl), reseated: reseat && wasSeated });
      console.log(`[dev] injected uid=${ctrl.uid} babies=${ctrl.babies.join(",")} ` +
        `seed=${ctrl.broodSeed === null ? "-" : ctrl.broodSeed.toString(16)} ` +
        `reseat=${reseat && wasSeated}`);
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
    // so clean up here and bounce affected tabs back to pre_lobby instead of
    // leaving them stuck on the connecting screen forever.
    console.error(`[lobby] server proc error (${code}):`, err.message);
    usedPorts.delete(port);
    lobbyRegistry.delete(code);
    for (const s of activeSessions) {
      if (s.room && s.room.code === code) s.failToPreLobby("server_error");
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

// Hardware controllers (dc_rp2040 boards on USB serial).  Every linked board
// is its own player (ControllerSession) in the active lobby.
const controllerManager = new ControllerManager({
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
  // The onboarding kiosk, when one is open, re-reads the board list on every
  // link/unlink.  Nothing else cares.
  boardsChanged: () => { if (onboardSession !== null) onboardSession.sendQueue(); },
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
    this.failToPreLobby("server_error");
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
   * Send a pre_lobby error to the browser and reset to pre_lobby state so the
   * user can try again.
   * @param {string} reason
   */
  sendPreLobbyError(reason) {
    if (this.tabWs.readyState === WebSocket.OPEN) {
      this.tabWs.send(JSON.stringify({ tag: "error", reason }));
    }
  }

  /**
   * Handle a browser action message while in the pre_lobby state.
   * @param {{ action: string, code?: string, player_id?: number }} msg
   */
  async handlePreLobbyAction(msg) {
    if (this.started) return; // already in a room

    if (msg.action === "create") {
      // Optional saved /tune config for this lobby.
      let configHash = null;
      if (typeof msg.config === "string" && msg.config.length > 0) {
        if (!HASH_RE.test(msg.config) || !fs.existsSync(dataDirFor(msg.config))) {
          console.warn(`[lobby] create with unknown config '${msg.config}'`);
          this.sendPreLobbyError("config_not_found");
          return;
        }
        configHash = msg.config;
      }
      const code = uniqueCode();
      let port;
      try { port = await findFreePort(); } catch (err) {
        console.error("[lobby] findFreePort failed:", err);
        this.sendPreLobbyError("server_error");
        return;
      }
      const room = spawnLobbyServer(code, port, configHash);
      console.log(`[lobby] created room code=${code} port=${port}`);
      // Acknowledge before the Zig client has connected so the browser
      // transitions away from pre_lobby immediately.  `config` lets the tab
      // load the matching balance tables.
      if (this.tabWs.readyState === WebSocket.OPEN) {
        this.tabWs.send(JSON.stringify({ tag: "joining", config: room.configHash }));
      }
      this.startInRoom(room);
      return;
    }

    if (msg.action === "join") {
      const rawCode = (msg.code || "").toUpperCase().trim();
      if (rawCode.length !== 6) {
        this.sendPreLobbyError("invalid_code");
        return;
      }
      const room = lobbyRegistry.get(rawCode);
      if (!room) {
        console.log(`[lobby] join: code=${rawCode} not found; registry=${[...lobbyRegistry.keys()].join(",") || "(empty)"}`);
        this.sendPreLobbyError("not_found");
        return;
      }
      console.log(`[lobby] join: code=${rawCode} found, routing tab`);
      // Acknowledge immediately so the browser clears the pre_lobby screen
      // before the Zig client finishes connecting to the server.  `config`
      // makes joiners adopt the lobby's balance tables (may differ from the
      // page they joined from).
      if (this.tabWs.readyState === WebSocket.OPEN) {
        this.tabWs.send(JSON.stringify({ tag: "joining", config: room.configHash }));
      }
      this.startInRoom(room);
      return;
    }

    console.warn("[bridge] unknown pre_lobby action:", msg.action);
  }

  // ---- Lifecycle ----------------------------------------------------------

  /** Announce the pre_lobby state to the browser and wait for a room choice. */
  sendPreLobby() {
    if (this.tabWs.readyState === WebSocket.OPEN) {
      this.tabWs.send(JSON.stringify({ tag: "pre_lobby" }));
    }
  }

  /**
   * Abort the current room attempt and return the tab to the pre_lobby
   * screen with an error, so the user can retry without a page refresh.
   * Unlike teardown(), the browser WebSocket stays open.
   * @param {string} reason
   */
  failToPreLobby(reason) {
    if (this.closed) return;
    this.closeShared();
    if (this.room) { roomTabLeft(this.room); this.room = null; }
    this.started = false;
    console.warn(`[bridge] tab bounced to pre_lobby (${reason})`);
    this.sendPreLobbyError(reason);
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
        if (err === null) this.send({ tag: "committed", linkId });
        else this.send({ tag: "commit_failed", linkId, reason: err });
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

    // The report screen's button: only browser tabs can start the next
    // round, and only by this click (never a key), so the action routes
    // here rather than through the KEY: path.
    if (msg.action === "restart") {
      if (session.started) session.writeToZig("RESTART\n");
      return;
    }

    // Room-selection actions are handled before a room is chosen.
    if (typeof msg.action === "string") {
      session.handlePreLobbyAction(msg).catch((err) => {
        console.error("[bridge] handlePreLobbyAction error:", err);
        session.sendPreLobbyError("server_error");
      });
      return;
    }
  });

  // Tell the browser to show the lobby-selection screen.
  session.sendPreLobby();
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

httpServer.listen(PORT, () => {
  console.log(`[bridge] listening on http://localhost:${PORT}`);
});

controllerManager.start();
