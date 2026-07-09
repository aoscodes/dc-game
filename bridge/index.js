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

const RECONNECT_INITIAL_MS  = 1_000;
const RECONNECT_MAX_MS      = 16_000;
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
};

const httpServer = http.createServer((req, res) => {
  // Strip the query string (e.g. game.js?v=<sha> cache buster).
  const rawPath  = req.url.split("?")[0];
  const urlPath  = rawPath === "/" ? "/index.html" : rawPath;
  const filePath = path.join(WEB_DIR, path.normalize(urlPath));

  if (!filePath.startsWith(WEB_DIR)) {
    res.writeHead(403); res.end("Forbidden"); return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end("Not found"); return; }
    const ext = path.extname(filePath);
    res.writeHead(200, { "Content-Type": MIME[ext] || "application/octet-stream" });
    res.end(data);
  });
});

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
 * @returns {LobbyRoom}
 */
function spawnLobbyServer(code, port) {
  console.log(`[lobby] spawning server for code=${code} port=${port}`);
  usedPorts.add(port);

  const proc = spawn(SERVER_BIN, [String(port), "--join-code", code], {
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
  const room = { code, port, proc, tabCount: 0, idleTimer: null };
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

class TabSession {
  /** @param {WebSocket} tabWs */
  constructor(tabWs) {
    this.tabWs          = tabWs;
    this.zigProc        = null;
    this.zigWritable    = false;
    this.serverWs       = null;
    this.serverConnected = false;
    this.lineBuf        = "";
    this.closed         = false;
    this.reconnectTimer = null;
    this.reconnectDelay = RECONNECT_INITIAL_MS;
    /** @type {LobbyRoom | null} */
    this.room           = null;
    this.started        = false;
    /** @type {object | null} Statblock from browser, sent to Zig before READY. */
    this.pendingStats   = null;
  }

  // ---- Zig stdin ----------------------------------------------------------

  writeToZig(line) {
    if (this.zigProc && this.zigWritable) {
      this.zigProc.stdin.write(line);
    } else {
      console.warn("[bridge] writeToZig: dropped (Zig not running):", line.trimEnd().slice(0, 60));
    }
  }

  // ---- Server WebSocket ---------------------------------------------------

  sendToServer(bytes) {
    if (this.serverWs && this.serverConnected &&
        this.serverWs.readyState === WebSocket.OPEN) {
      this.serverWs.send(bytes);
    } else {
      console.warn(`[bridge] sendToServer: dropped ${bytes.length} bytes (not connected)`);
    }
  }

  connectToServer(port) {
    const url = `ws://127.0.0.1:${port}`;
    console.log(`[bridge] tab connecting to server ${url}`);
    const ws = new WebSocket(url, { perMessageDeflate: false });
    this.serverWs = ws;

    ws.on("open", () => {
      if (this.closed) { ws.close(); return; }
      console.log("[bridge] tab server connected");
      this.serverConnected = true;
      this.reconnectDelay  = RECONNECT_INITIAL_MS;
      if (this.pendingStats) {
        this.writeToZig(`STATBLOCK:${JSON.stringify(this.pendingStats)}\n`);
      }
      this.writeToZig("READY\n");
    });

    ws.on("message", (data) => {
      if (this.closed) return;
      const hex = Buffer.from(data).toString("hex");
      this.writeToZig(`WIRE:${hex}\n`);
    });

    ws.on("close", () => {
      this.serverConnected = false;
      this.serverWs = null;
      if (this.closed) return;
      console.warn(`[bridge] tab server disconnected; retry in ${this.reconnectDelay}ms`);
      this.reconnectTimer = setTimeout(() => {
        this.reconnectTimer = null;
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, RECONNECT_MAX_MS);
        if (!this.closed && this.room) this.connectToServer(this.room.port);
      }, this.reconnectDelay);
    });

    ws.on("error", (err) => {
      console.error("[bridge] tab server WS error:", err.message);
    });
  }

  // ---- Zig process --------------------------------------------------------

  spawnZig() {
    console.log(`[bridge] spawning ${CLIENT_BIN} for tab`);
    const proc = spawn(CLIENT_BIN, [], { stdio: ["pipe", "pipe", "inherit"] });
    this.zigProc     = proc;
    this.zigWritable = true;

    proc.on("error", (err) => {
      // Spawn failure (e.g. ENOENT: binary missing) emits 'error' without
      // 'exit' — without handling, the tab hangs on "Connecting..." forever.
      console.error("[bridge] Zig spawn error:", err.message);
      this.zigWritable = false;
      this.failToPreLobby("server_error");
    });

    proc.stdin.on("error", (err) => {
      console.error("[bridge] Zig stdin error:", err.message);
      this.zigWritable = false;
    });

    proc.stdout.on("data", (chunk) => {
      this.lineBuf += chunk.toString();
      let nl;
      while ((nl = this.lineBuf.indexOf("\n")) !== -1) {
        const line = this.lineBuf.slice(0, nl);
        this.lineBuf = this.lineBuf.slice(nl + 1);
        this.handleZigLine(line.trimEnd());
      }
    });

    proc.on("exit", (code) => {
      this.zigProc     = null;
      this.zigWritable = false;
      if (this.closed) return;
      console.warn(`[bridge] Zig client exited (code=${code}); restarting in 1s`);
      this.reconnectDelay = RECONNECT_INITIAL_MS;
      setTimeout(() => { if (!this.closed) this.spawnZig(); }, 1_000);
    });
  }

  handleZigLine(line) {
    if (!line) return;
    let msg;
    try { msg = JSON.parse(line); } catch {
      console.error("[bridge] bad Zig stdout line (not JSON):", line.slice(0, 120));
      return;
    }

    if (msg.tag === "render") {
      if (this.tabWs.readyState === WebSocket.OPEN) this.tabWs.send(line);
    } else if (msg.tag === "send" && typeof msg.bytes === "string") {
      const bytes = hexToBytes(msg.bytes);
      if (bytes !== null) this.sendToServer(bytes);
    } else {
      console.warn("[bridge] unknown Zig frame tag:", msg.tag);
    }
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
      if (msg.stats && typeof msg.stats === "object") this.pendingStats = msg.stats;
      const code = uniqueCode();
      let port;
      try { port = await findFreePort(); } catch (err) {
        console.error("[lobby] findFreePort failed:", err);
        this.sendPreLobbyError("server_error");
        return;
      }
      const room = spawnLobbyServer(code, port);
      console.log(`[lobby] created room code=${code} port=${port}`);
      // Acknowledge before the Zig client has connected so the browser
      // transitions away from pre_lobby immediately.
      if (this.tabWs.readyState === WebSocket.OPEN) {
        this.tabWs.send(JSON.stringify({ tag: "joining" }));
      }
      this.startInRoom(room);
      return;
    }

    if (msg.action === "join" || msg.action === "reconnect") {
      if (msg.stats && typeof msg.stats === "object") this.pendingStats = msg.stats;
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
      // before the Zig client finishes connecting to the server.
      if (this.tabWs.readyState === WebSocket.OPEN) {
        this.tabWs.send(JSON.stringify({ tag: "joining" }));
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
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.zigProc) {
      // Drop the 'exit' listener so killing it doesn't trigger a restart.
      this.zigProc.removeAllListeners("exit");
      // Only signal procs that actually spawned: pid is undefined when spawn
      // failed (e.g. ENOENT), and calling kill() before the pending 'error'
      // event fires wedges the node process.
      if (this.zigProc.pid !== undefined) this.zigProc.kill();
      this.zigProc = null;
    }
    this.zigWritable = false;
    if (this.serverWs) {
      // Drop the 'close' listener so closing doesn't trigger a reconnect.
      this.serverWs.removeAllListeners("close");
      this.serverWs.close();
      this.serverWs = null;
    }
    this.serverConnected = false;
    if (this.room) { roomTabLeft(this.room); this.room = null; }
    this.started      = false;
    this.pendingStats = null;
    console.warn(`[bridge] tab bounced to pre_lobby (${reason})`);
    this.sendPreLobbyError(reason);
  }

  teardown() {
    if (this.closed) return;
    this.closed = true;
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.zigProc)  {
      // pid is undefined when spawn failed; kill() before the pending
      // 'error' event fires wedges the node process.
      if (this.zigProc.pid !== undefined) this.zigProc.kill();
      this.zigProc = null;
    }
    if (this.serverWs) { this.serverWs.close(); this.serverWs = null; }
    if (this.room)     { roomTabLeft(this.room); this.room = null; }
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
// Utilities
// ---------------------------------------------------------------------------

function hexToBytes(hex) {
  if (hex.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(hex)) {
    console.error("[bridge] hexToBytes: invalid hex string:", hex.slice(0, 40));
    return null;
  }
  const len = hex.length >> 1;
  const buf = Buffer.allocUnsafe(len);
  for (let i = 0; i < len; i++) {
    buf[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return buf;
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

httpServer.listen(PORT, () => {
  console.log(`[bridge] listening on http://localhost:${PORT}`);
});
