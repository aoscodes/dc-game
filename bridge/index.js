"use strict";

/**
 * Bridge between the Zig client binary and the browser canvas.
 *
 * Each browser tab gets its own TabSession: a dedicated Zig client process
 * and a dedicated WebSocket connection to the game server.  The server sees
 * each tab as a distinct player.
 *
 * Responsibilities per TabSession:
 *   - Spawn ./zig-out/bin/client and manage its lifecycle
 *   - Connect to the game server WebSocket (owns reconnect loop)
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
const fs          = require("fs");
const path        = require("path");
const { WebSocketServer, WebSocket } = require("ws");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const PORT        = parseInt(process.env.PORT || "3000", 10);
const SERVER_URL  = process.env.SERVER_URL || "ws://127.0.0.1:9001";
// Locally: zig build puts the binary at zig-out/bin/client (one level up from bridge/).
// On the VPS: deploy installs it flat at /opt/dragoncon/client (same level as bridge/).
// Try the flat path first; fall back to the local dev path.
const _binFlat  = path.resolve(__dirname, "../client");
const _binLocal = path.resolve(__dirname, "../zig-out/bin/client");
const CLIENT_BIN = require("fs").existsSync(_binFlat) ? _binFlat : _binLocal;
const WEB_DIR     = path.resolve(__dirname, "../web");

const RECONNECT_INITIAL_MS = 1_000;
const RECONNECT_MAX_MS     = 16_000;
const MAX_SESSIONS         = 6;

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
  // Default to index.html
  const urlPath = req.url === "/" ? "/index.html" : req.url;
  const filePath = path.join(WEB_DIR, path.normalize(urlPath));

  // Prevent path traversal outside WEB_DIR
  if (!filePath.startsWith(WEB_DIR)) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end("Not found");
      return;
    }
    const ext = path.extname(filePath);
    res.writeHead(200, { "Content-Type": MIME[ext] || "application/octet-stream" });
    res.end(data);
  });
});

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
  }

  // ---- Zig stdin ----------------------------------------------------------

  /** Write a line to this session's Zig stdin. */
  writeToZig(line) {
    if (this.zigProc && this.zigWritable) {
      this.zigProc.stdin.write(line);
    } else {
      console.warn("[bridge] writeToZig: dropped (Zig not running):", line.trimEnd().slice(0, 60));
    }
  }

  // ---- Server WebSocket ---------------------------------------------------

  /** Send raw bytes to this session's game server connection. */
  sendToServer(bytes) {
    if (this.serverWs && this.serverConnected &&
        this.serverWs.readyState === WebSocket.OPEN) {
      this.serverWs.send(bytes);
    } else {
      console.warn(`[bridge] sendToServer: dropped ${bytes.length} bytes (not connected)`);
    }
  }

  connectToServer() {
    console.log(`[bridge] tab connecting to server ${SERVER_URL}`);
    const ws = new WebSocket(SERVER_URL, { perMessageDeflate: false });
    this.serverWs = ws;

    ws.on("open", () => {
      if (this.closed) { ws.close(); return; }
      console.log("[bridge] tab server connected");
      this.serverConnected = true;
      this.reconnectDelay  = RECONNECT_INITIAL_MS;
      // Tell Zig the server is ready so it sends join_lobby / reconnect.
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
        if (!this.closed) this.connectToServer();
      }, this.reconnectDelay);
    });

    ws.on("error", (err) => {
      console.error("[bridge] tab server WS error:", err.message);
      // 'close' fires after 'error' so reconnect is handled there.
    });
  }

  // ---- Zig process --------------------------------------------------------

  spawnZig() {
    console.log(`[bridge] spawning ${CLIENT_BIN} for tab`);

    const proc = spawn(CLIENT_BIN, [], { stdio: ["pipe", "pipe", "inherit"] });
    this.zigProc     = proc;
    this.zigWritable = true;

    proc.on("error", (err) => {
      console.error("[bridge] Zig spawn error:", err.message);
      this.zigWritable = false;
    });

    proc.stdin.on("error", (err) => {
      console.error("[bridge] Zig stdin error:", err.message);
      this.zigWritable = false;
    });

    // Read Zig stdout line by line.
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
      // Reset reconnect backoff so the next server attempt starts fresh.
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
      // Send render frame only to this tab's browser WebSocket.
      if (this.tabWs.readyState === WebSocket.OPEN) this.tabWs.send(line);
    } else if (msg.tag === "send" && typeof msg.bytes === "string") {
      const bytes = hexToBytes(msg.bytes);
      if (bytes !== null) this.sendToServer(bytes);
    } else {
      console.warn("[bridge] unknown Zig frame tag:", msg.tag);
    }
  }

  // ---- Lifecycle ----------------------------------------------------------

  start() {
    this.spawnZig();
    this.connectToServer();
  }

  teardown() {
    if (this.closed) return;
    this.closed = true;
    // Cancel any pending reconnect timer immediately.
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.zigProc)  { this.zigProc.kill();   this.zigProc  = null; }
    if (this.serverWs) { this.serverWs.close(); this.serverWs = null; }
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
    // Session is full — tell the browser before closing so it can render a
    // "session full" screen instead of an empty reconnect loop.
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
    if (typeof msg.key === "string") session.writeToZig(`KEY:${msg.key}\n`);
  });

  session.start();
});

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

/**
 * Decode a hex string to a Buffer.
 * Returns null (and logs) if the input is odd-length or contains non-hex chars.
 */
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
