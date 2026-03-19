"use strict";

/**
 * Shared helpers for browser e2e tests.
 *
 * Each test suite gets its own server + bridge on a unique port pair so suites
 * can run sequentially without port conflicts.
 *
 * Port layout:
 *   SERVER_PORT  — game server WebSocket  (Zig)
 *   BRIDGE_PORT  — Node bridge HTTP + /ws  (browser connects here)
 */

const { spawn } = require("child_process");
const path      = require("path");
const net       = require("net");

const ROOT = path.resolve(__dirname, "../..");

exports.ROOT = ROOT;

// ---------------------------------------------------------------------------
// Process lifecycle
// ---------------------------------------------------------------------------

/**
 * Spawn the game server on the given port.
 * Returns a ChildProcess; caller must kill it in afterAll.
 */
exports.spawnServer = function spawnServer(port) {
  const proc = spawn(
    path.join(ROOT, "zig-out/bin/server"),
    [String(port)],
    { stdio: "ignore" },
  );
  proc.on("error", (e) => console.error("[e2e] server spawn error:", e.message));
  return proc;
};

/**
 * Spawn the Node bridge pointed at the given server port, listening on
 * bridgePort for HTTP/WS connections.
 * Returns a ChildProcess.
 */
exports.spawnBridge = function spawnBridge(serverPort, bridgePort) {
  const proc = spawn(
    "node",
    [path.join(ROOT, "bridge/index.js")],
    {
      env: {
        ...process.env,
        SERVER_URL: `ws://127.0.0.1:${serverPort}`,
        PORT:       String(bridgePort),
      },
      stdio: ["ignore", "pipe", "pipe"],
      cwd: ROOT,
    },
  );
  proc.on("error", (e) => console.error("[e2e] bridge spawn error:", e.message));
  // Pipe both stdout and stderr to the test console for debug visibility.
  proc.stdout.on("data", (d) => {
    const msg = d.toString().trim();
    if (msg) console.log("[bridge]", msg);
  });
  proc.stderr.on("data", (d) => {
    const msg = d.toString().trim();
    if (msg) console.error("[bridge]", msg);
  });
  return proc;
};

/**
 * Kill a child process cleanly; resolves once the process exits.
 */
exports.kill = function kill(proc) {
  return new Promise((resolve) => {
    if (!proc || proc.exitCode !== null) { resolve(); return; }
    proc.once("exit", resolve);
    proc.kill("SIGTERM");
    // Force-kill after 2 s.
    setTimeout(() => { try { proc.kill("SIGKILL"); } catch {} }, 2_000);
  });
};

// ---------------------------------------------------------------------------
// Port waiting
// ---------------------------------------------------------------------------

/**
 * Poll until port accepts a TCP connection, or throw after timeoutMs.
 */
exports.waitForPort = function waitForPort(port, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    function attempt() {
      const sock = new net.Socket();
      sock.setTimeout(200);
      sock.once("connect", () => { sock.destroy(); resolve(); });
      sock.once("error",   () => { sock.destroy(); retry(); });
      sock.once("timeout", () => { sock.destroy(); retry(); });
      sock.connect(port, "127.0.0.1");
    }
    function retry() {
      if (Date.now() > deadline) {
        reject(new Error(`port ${port} not ready after ${timeoutMs}ms`));
      } else {
        setTimeout(attempt, 80);
      }
    }
    attempt();
  });
};

// ---------------------------------------------------------------------------
// Bot WS client  (drives the game server directly, bypassing the bridge)
// ---------------------------------------------------------------------------

const WS = require("ws");

/**
 * Minimal bot that connects directly to the game server, sends join/class/
 * ready, and drives combat automatically (always attacks first enemy).
 *
 * Usage:
 *   const bot = new Bot(serverPort, "BotA");
 *   await bot.connect();
 *   await bot.waitForGameOver(30_000);
 *   bot.close();
 */
class Bot {
  constructor(serverPort, name) {
    this.serverPort = serverPort;
    this.name       = name;
    this._ws        = null;
    this._enemies   = [];
    this._sentJoin  = false;
    this._sentReady = false;
    this._inGame    = false;
    this._gameOverResolve = null;
    this._gameOverReject  = null;
  }

  connect() {
    return new Promise((resolve, reject) => {
      const ws = new WS(`ws://127.0.0.1:${this.serverPort}`);
      this._ws = ws;
      ws.once("open",  resolve);
      ws.once("error", reject);
      ws.on("message", (raw) => this._onMessage(Buffer.from(raw)));
    });
  }

  waitForGameOver(timeoutMs = 25_000) {
    return new Promise((resolve, reject) => {
      this._gameOverResolve = resolve;
      this._gameOverReject  = reject;
      setTimeout(() => reject(new Error(`${this.name}: game_over timeout`)), timeoutMs);
    });
  }

  close() { try { this._ws.close(); } catch {} }

  _send(bytes) {
    if (this._ws.readyState === WS.OPEN) this._ws.send(bytes);
  }

  _onMessage(raw) {
    const tag = raw[0];
    const payload = raw.slice(1);

    switch (tag) {
      case 0x10: // lobby_update
        this._onLobbyUpdate(payload);
        break;
      case 0x11: // game_start
        this._inGame = true;
        break;
      case 0x12: // game_state
        this._onGameState(payload);
        break;
      case 0x14: // your_turn
        this._onYourTurn();
        break;
      case 0x15: // game_over
        if (this._gameOverResolve) this._gameOverResolve();
        break;
    }
  }

  _onLobbyUpdate(payload) {
    if (this._inGame) return;
    let off = 0;
    // join_code(6), player_count(1), your_player_id(1)
    const playerCount = payload[6];
    if (!this._sentJoin) {
      this._sendJoin();
      this._sendClass(0); // fighter
      this._sentJoin = true;
    }
    if (!this._sentReady && playerCount >= 2) {
      this._sendReady();
      this._sentReady = true;
    }
    void off; // suppress unused warning
  }

  _onGameState(payload) {
    this._enemies = [];
    let off = 5; // tick(4) + entity_count(1)
    const count = payload[4];
    for (let i = 0; i < count; i++) {
      const entityId = payload.readUInt32LE(off); off += 4;
      off += 2; // col, row
      off += 4; // hp_current, hp_max
      off += 4; // atb_gauge (f32)
      off += 1; // action_state
      off += 1; // class
      const team = payload[off]; off += 1;
      off += 1; // owner
      if (team === 1) this._enemies.push(entityId); // enemies team = 1
    }
  }

  _onYourTurn() {
    const target = this._enemies[0] ?? 0;
    this._sendAction(0, target); // attack
  }

  _sendJoin() {
    const name = Buffer.from(this.name.slice(0, 16));
    const buf = Buffer.allocUnsafe(2 + name.length);
    buf[0] = 0x01; // join_lobby
    buf[1] = name.length;
    name.copy(buf, 2);
    this._send(buf);
  }

  _sendClass(classIdx) {
    this._send(Buffer.from([0x02, classIdx]));
  }

  _sendReady() {
    this._send(Buffer.from([0x03]));
  }

  _sendAction(action, targetEntity) {
    const buf = Buffer.allocUnsafe(6);
    buf[0] = 0x04; // choose_action
    buf[1] = action;
    buf.writeUInt32LE(targetEntity, 2);
    this._send(buf);
  }
}

exports.Bot = Bot;

// ---------------------------------------------------------------------------
// Canvas pixel helpers
// ---------------------------------------------------------------------------

/**
 * Return true if the canvas has at least one non-background-coloured pixel.
 * Background is #14141e (r=20,g=20,b=30).
 */
exports.canvasHasContent = async function canvasHasContent(page) {
  return page.evaluate(() => {
    const canvas = document.getElementById("canvas");
    if (!canvas) return false;
    const ctx = canvas.getContext("2d");
    const { data } = ctx.getImageData(0, 0, canvas.width, canvas.height);
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i + 1], b = data[i + 2];
      // Any pixel that isn't the background colour counts as content.
      if (!(r <= 25 && g <= 25 && b <= 35)) return true;
    }
    return false;
  });
};

/**
 * Wait until the page's canvas shows at least one non-background pixel.
 */
exports.waitForCanvasContent = async function waitForCanvasContent(page, timeoutMs = 8_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await exports.canvasHasContent(page)) return;
    await page.waitForTimeout(100);
  }
  throw new Error("canvas remained blank after " + timeoutMs + "ms");
};

/**
 * Return true if the canvas region (x,y,w,h) contains at least one pixel
 * whose r/g/b channels all fall within the given inclusive ranges.
 *
 * Use this to assert that a specific colour (e.g. C_HEADER, classColor) is
 * present in a known screen area rather than just "some non-background pixel".
 */
exports.canvasRegionHasColor = async function canvasRegionHasColor(
  page, x, y, w, h,
  rMin, rMax, gMin, gMax, bMin, bMax,
) {
  return page.evaluate(
    ({ x, y, w, h, rMin, rMax, gMin, gMax, bMin, bMax }) => {
      const canvas = document.getElementById("canvas");
      if (!canvas) return false;
      const ctx = canvas.getContext("2d");
      const { data } = ctx.getImageData(x, y, w, h);
      for (let i = 0; i < data.length; i += 4) {
        const r = data[i], g = data[i + 1], b = data[i + 2];
        if (r >= rMin && r <= rMax && g >= gMin && g <= gMax && b >= bMin && b <= bMax)
          return true;
      }
      return false;
    },
    { x, y, w, h, rMin, rMax, gMin, gMax, bMin, bMax },
  );
};

// ---------------------------------------------------------------------------
// WS frame helpers
// ---------------------------------------------------------------------------

/**
 * Open a Node.js WS connection to the bridge and collect render frames.
 * Returns { frames, close } — call close() in afterAll/finally.
 *
 * Useful when you need to inspect frame *content* rather than just counting
 * frames, since Playwright's framereceived can be unreliable for long tests.
 */
exports.openFrameCollector = function openFrameCollector(bridgePort) {
  const WS = require("ws");
  const frames = [];
  const ws = new WS(`ws://127.0.0.1:${bridgePort}/ws`);
  ws.on("message", (raw) => {
    try {
      const msg = JSON.parse(raw.toString());
      if (msg.tag === "render") frames.push(msg);
    } catch {}
  });
  ws.on("error", (e) => console.error("[e2e] frame collector WS error:", e.message));
  const ready = new Promise((resolve, reject) => {
    ws.once("open", resolve);
    ws.once("error", reject);
  });
  return {
    frames,
    ready,
    close: () => { try { ws.close(); } catch {} },
  };
};

/**
 * Wait until `collector.frames` contains a frame with the given phase.
 * Returns the first matching frame.
 */
exports.waitForFramePhase = async function waitForFramePhase(collector, phase, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const f = collector.frames.find((m) => m.phase === phase);
    if (f) return f;
    await new Promise((r) => setTimeout(r, 80));
  }
  const seen = [...new Set(collector.frames.map((m) => m.phase))].join(",");
  throw new Error(`phase "${phase}" not seen after ${timeoutMs}ms; got: ${seen || "(none)"}`);
};

// ---------------------------------------------------------------------------
// Frame content assertions
// ---------------------------------------------------------------------------

const KNOWN_CLASSES = new Set(["fighter", "mage", "healer", "grunt", "archer", "shaman", "boss"]);
const KNOWN_TEAMS   = new Set(["players", "enemies"]);

/**
 * Assert that a render frame in lobby phase has well-formed lobby fields.
 * Throws with a descriptive message if anything is missing or wrong-typed.
 */
exports.assertLobbyFrame = function assertLobbyFrame(frame) {
  if (!frame || frame.tag !== "render" || frame.phase !== "lobby")
    throw new Error(`assertLobbyFrame: not a lobby frame: ${JSON.stringify(frame)}`);
  const L = frame.lobby;
  if (!L) throw new Error("assertLobbyFrame: frame.lobby is null/undefined");
  if (typeof L.join_code !== "string")
    throw new Error(`assertLobbyFrame: join_code not a string: ${JSON.stringify(L.join_code)}`);
  if (!Array.isArray(L.players))
    throw new Error("assertLobbyFrame: players is not an array");
  if (!KNOWN_CLASSES.has(L.selected_class))
    throw new Error(`assertLobbyFrame: unknown selected_class: ${L.selected_class}`);
  if (typeof L.ready !== "boolean")
    throw new Error(`assertLobbyFrame: ready not boolean: ${L.ready}`);
};

/**
 * Assert that a render frame in game phase has well-formed game fields,
 * including at least one entity with valid team/class/position fields.
 * Throws with a descriptive message if anything is wrong.
 */
exports.assertGameFrame = function assertGameFrame(frame) {
  if (!frame || frame.tag !== "render" || frame.phase !== "game")
    throw new Error(`assertGameFrame: not a game frame: ${JSON.stringify(frame)}`);
  const G = frame.game;
  if (!G) throw new Error("assertGameFrame: frame.game is null/undefined");
  if (!Array.isArray(G.entities) || G.entities.length === 0)
    throw new Error("assertGameFrame: entities is empty or not an array");
  for (const e of G.entities) {
    if (typeof e.id !== "number")
      throw new Error(`assertGameFrame: entity.id not a number: ${JSON.stringify(e)}`);
    if (typeof e.col !== "number" || typeof e.row !== "number")
      throw new Error(`assertGameFrame: entity col/row not numbers: ${JSON.stringify(e)}`);
    if (typeof e.hp !== "number" || typeof e.hp_max !== "number")
      throw new Error(`assertGameFrame: entity hp/hp_max not numbers: ${JSON.stringify(e)}`);
    if (!KNOWN_TEAMS.has(e.team))
      throw new Error(`assertGameFrame: unknown team: ${e.team}`);
    if (!KNOWN_CLASSES.has(e.class))
      throw new Error(`assertGameFrame: unknown class: ${e.class}`);
  }
  const hasPlayers = G.entities.some((e) => e.team === "players");
  const hasEnemies = G.entities.some((e) => e.team === "enemies");
  if (!hasPlayers) throw new Error("assertGameFrame: no player-team entities");
  if (!hasEnemies) throw new Error("assertGameFrame: no enemy-team entities");
};
