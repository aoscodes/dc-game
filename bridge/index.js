"use strict";

/**
 * Bridge between the Zig client binary and the browser canvas.
 *
 * Each browser tab gets its own TabSession: a dedicated Zig client process
 * and a dedicated WebSocket connection to the game server.  The server sees
 * each tab as a distinct player.
 *
 * Multiple lobbies are supported.  Each lobby runs its own Zig server process
 * on a dedicated port.  The LobbyRegistry tracks all active lobbies by their
 * 6-character join code.  Tabs are routed to a lobby via:
 *   { action: "create" }                          — spawn a new server + join it
 *   { action: "join",      code: "XXXXXX" }       — join an existing lobby by code
 *   { action: "reconnect", code: "XXXXXX",
 *              player_id: N }                      — rejoin after page refresh
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
 *   - Hardware controller discovery/pairing over USB serial (controllers.js):
 *     board buttons feed the same KEY: path; pending-combo feedback flows
 *     back to the board's e-paper.
 *
 * Stdio protocol (Zig ↔ bridge):
 *   Zig stdin  ← WIRE:<hex>\n   raw server message bytes, hex-encoded
 *   Zig stdin  ← KEY:<name>\n   browser KeyboardEvent.key value
 *   Zig stdin  ← READY\n        sent once when server WS first opens
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
const { ControllerManager, comboFromRender } = require("./controllers");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const PORT        = parseInt(process.env.PORT || "3000", 10);
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

  // /tune — the config editor (query string carries ?from=<hash>).
  if (rawPath === "/tune") {
    serveFile(res, WEB_DIR, "/tune.html", { "Cache-Control": "no-cache" });
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
 *              encounter: { hunger_max, zones: [...] } }
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
        hunger_max: msg.encounter.hunger_max,
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

// Hardware controllers (dc_rp2040 boards on USB serial). Hybrid player model:
// a linked board first tries to pair with a started tab session (drives that
// tab's player); with no tab free it becomes its own headless player
// (ControllerSession) in the active lobby. Sessions iterate in Set insertion
// order = tab-connection order, so pairing picks the oldest started tab first.
const controllerManager = new ControllerManager({
  clientBin: CLIENT_BIN,
  getSessions: () => activeSessions,
  onKey: (session, key) => {
    if (session.started) session.writeToZig(`KEY:${key}\n`);
  },
  // Headless boards join the single active lobby, or the newest when several
  // exist (Map preserves insertion order), or wait when there is none.
  pickRoom: () => {
    const rooms = [...lobbyRegistry.values()];
    return rooms.length > 0 ? rooms[rooms.length - 1] : null;
  },
  // Controller players count as room occupants so a lobby that is all boards
  // doesn't get idle-killed under the players' feet.
  roomJoined: (room) => roomTabJoined(room),
  roomLeft: (room) => roomTabLeft(room),
  isRoomAlive: (room) => lobbyRegistry.get(room.code) === room,
});

class TabSession extends PlayerSession {
  /** @param {WebSocket} tabWs */
  constructor(tabWs) {
    super({ clientBin: CLIENT_BIN, label: "tab" });
    this.tabWs          = tabWs;
    /** Paired hardware controller (managed by ControllerManager). */
    this.controller     = null;
  }

  // ---- PlayerSession hooks --------------------------------------------------

  onZigFrame(msg, line) {
    if (msg.tag === "render") {
      if (this.tabWs.readyState === WebSocket.OPEN) this.tabWs.send(line);
      // Mirror the pending combo to a paired hardware controller's e-paper.
      if (this.controller !== null) this.controller.sendCombo(comboFromRender(msg));
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
    // A waiting hardware controller may now pair with this session.
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

    if (msg.action === "join" || msg.action === "reconnect") {
      const rawCode = (msg.code || "").toUpperCase().trim();
      if (rawCode.length !== 6) {
        this.sendPreLobbyError("invalid_code");
        return;
      }
      const room = lobbyRegistry.get(rawCode);
      if (!room) {
        console.log(`[lobby] join/reconnect: code=${rawCode} not found; registry=${[...lobbyRegistry.keys()].join(",") || "(empty)"}`);
        this.sendPreLobbyError("not_found");
        return;
      }
      console.log(`[lobby] join/reconnect: code=${rawCode} found, routing tab`);
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
    // Detach the controller but keep its sticky mapping: if this tab starts
    // again, the same board re-pairs to it.
    controllerManager.releaseSession(this);
    console.warn(`[bridge] tab bounced to pre_lobby (${reason})`);
    this.sendPreLobbyError(reason);
  }

  teardown() {
    if (this.closed) return;
    this.closed = true;
    this.closeShared();
    if (this.room)     { roomTabLeft(this.room); this.room = null; }
    controllerManager.releaseSession(this, { forget: true });
    activeSessions.delete(this);
    console.log(`[bridge] tab session torn down (${activeSessions.size} active)`);
  }
}

// ---------------------------------------------------------------------------
// Browser WebSocket server  (/ws)
// ---------------------------------------------------------------------------

const browserWss = new WebSocketServer({ server: httpServer, path: "/ws" });

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
