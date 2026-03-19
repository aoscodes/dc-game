"use strict";

/**
 * Bridge between the Zig client binary and the browser canvas.
 *
 * Responsibilities:
 *   - Spawn ./zig-out/bin/client and manage its lifecycle
 *   - Connect to the game server WebSocket (owns reconnect loop)
 *   - Relay server frames → Zig stdin as  WIRE:<hex>\n
 *   - Relay Zig stdout send-frames → server WebSocket
 *   - Relay Zig stdout render-frames → all connected browser WS clients
 *   - Relay browser keydown events → Zig stdin as  KEY:<name>\n
 *   - Serve web/ directory as static files on HTTP port 3000
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
const CLIENT_BIN  = path.resolve(__dirname, "../zig-out/bin/client");
const WEB_DIR     = path.resolve(__dirname, "../web");

const RECONNECT_INITIAL_MS = 1_000;
const RECONNECT_MAX_MS     = 16_000;

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
// Browser WebSocket server  (/ws)
// ---------------------------------------------------------------------------

const browserWss = new WebSocketServer({ server: httpServer, path: "/ws" });

/** @type {Set<WebSocket>} */
const browserClients = new Set();

browserWss.on("connection", (ws) => {
  browserClients.add(ws);
  ws.on("close", () => browserClients.delete(ws));
  ws.on("message", (raw) => {
    // Expect { key: "ArrowUp" } etc.
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    if (typeof msg.key === "string") {
      writeToZig(`KEY:${msg.key}\n`);
    }
  });
});

/** Broadcast a string to all connected browser clients. */
function broadcastToBrowser(text) {
  for (const ws of browserClients) {
    if (ws.readyState === WebSocket.OPEN) ws.send(text);
  }
}

// ---------------------------------------------------------------------------
// Zig client process
// ---------------------------------------------------------------------------

let zigProc = null;
let zigStdinWritable = false;

/** Write a line to Zig stdin; logs a warning if the process is not running. */
function writeToZig(line) {
  if (zigProc && zigStdinWritable) {
    zigProc.stdin.write(line);
  } else {
    console.warn("[bridge] writeToZig: dropped (Zig not running):", line.trimEnd().slice(0, 60));
  }
}

function spawnZig() {
  console.log(`[bridge] spawning ${CLIENT_BIN}`);

  zigProc = spawn(CLIENT_BIN, [], {
    stdio: ["pipe", "pipe", "inherit"],
  });

  zigStdinWritable = true;

  zigProc.on("error", (err) => {
    console.error("[bridge] Zig spawn error:", err.message);
    zigStdinWritable = false;
  });

  zigProc.stdin.on("error", (err) => {
    console.error("[bridge] Zig stdin error:", err.message);
    zigStdinWritable = false;
  });

  // Read Zig stdout line by line.
  let lineBuf = "";
  zigProc.stdout.on("data", (chunk) => {
    lineBuf += chunk.toString();
    let nl;
    while ((nl = lineBuf.indexOf("\n")) !== -1) {
      const line = lineBuf.slice(0, nl);
      lineBuf = lineBuf.slice(nl + 1);
      handleZigLine(line.trimEnd());
    }
  });

  zigProc.on("exit", (code) => {
    console.warn(`[bridge] Zig client exited (code=${code}); restarting in 1s`);
    zigStdinWritable = false;
    zigProc = null;
    setTimeout(spawnZig, 1_000);
  });
}

function handleZigLine(line) {
  if (!line) return;
  let msg;
  try { msg = JSON.parse(line); } catch {
    console.error("[bridge] bad Zig stdout line (not JSON):", line.slice(0, 120));
    return;
  }

  if (msg.tag === "render") {
    broadcastToBrowser(line);
  } else if (msg.tag === "send" && typeof msg.bytes === "string") {
    const bytes = hexToBytes(msg.bytes);
    if (bytes !== null) sendToServer(bytes);
  } else {
    console.warn("[bridge] unknown Zig frame tag:", msg.tag);
  }
}

// ---------------------------------------------------------------------------
// Game server WebSocket  (owns reconnect)
// ---------------------------------------------------------------------------

let serverWs = null;
let serverConnected = false;
let reconnectDelay = RECONNECT_INITIAL_MS;
let firstConnect = true;

function connectToServer() {
  console.log(`[bridge] connecting to server ${SERVER_URL}`);
  const ws = new WebSocket(SERVER_URL, { perMessageDeflate: false });
  serverWs = ws;

  ws.on("open", () => {
    console.log("[bridge] server connected");
    serverConnected = true;
    reconnectDelay = RECONNECT_INITIAL_MS;

    if (firstConnect) {
      firstConnect = false;
      // Tell Zig the server is ready so it sends join_lobby / reconnect.
      writeToZig("READY\n");
    } else {
      // Re-open: Zig needs to re-send join/reconnect.
      // Signal it by writing READY again — Zig's reconnect path in send_join
      // will use the stored player_id.
      writeToZig("READY\n");
    }
  });

  ws.on("message", (data) => {
    // data is a Buffer of raw binary bytes.
    const hex = Buffer.from(data).toString("hex");
    writeToZig(`WIRE:${hex}\n`);
  });

  ws.on("close", () => {
    serverConnected = false;
    serverWs = null;
    console.warn(`[bridge] server disconnected; retry in ${reconnectDelay}ms`);
    setTimeout(() => {
      reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
      connectToServer();
    }, reconnectDelay);
  });

  ws.on("error", (err) => {
    console.error("[bridge] server WS error:", err.message);
    // 'close' fires after 'error' so reconnect is handled there.
  });
}

/** Send raw bytes to the game server; logs a warning if not connected. */
function sendToServer(bytes) {
  if (serverWs && serverConnected && serverWs.readyState === WebSocket.OPEN) {
    serverWs.send(bytes);
  } else {
    console.warn(`[bridge] sendToServer: dropped ${bytes.length} bytes (not connected)`);
  }
}

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

spawnZig();
connectToServer();
