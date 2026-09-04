"use strict";

/**
 * PlayerSession: the shared core of one game player as seen by the bridge —
 * a dedicated Zig client process plus a WebSocket connection to a lobby's
 * server (with reconnect backoff).  The server sees each PlayerSession as a
 * distinct player.
 *
 * Every connection starts as an OBSERVER of the room's always-running game;
 * taking one of the four player seats is an explicit protocol step (the
 * browser's P key, or the JOIN stdio line for boards).
 *
 * Two kinds extend it:
 *   - TabSession        (index.js)       browser tab: renders frames to the
 *                                        tab WebSocket, keys come from the
 *                                        browser
 *   - ControllerSession (controllers.js) headless hardware-controller player:
 *                                        no browser, render frames feed the
 *                                        board's e-paper shape feedback
 *
 * Stdio protocol with the Zig client (see README):
 *   stdin  <- WIRE:<hex>\n  raw server bytes    stdin <- KEY:<name>\n
 *   stdin  <- READY\n       server WS is open   stdin <- JOIN\n  take a seat
 *   stdin  <- STAT:appetite=<n>\n board flash stat
 *   stdin  <- STAT:babies=<a,b,c,d,e>\n board flash babies (BabyType order)
 *   stdin  <- STAT:powerups=<a>\n     board flash powerups (PowerupKind order)
 *   stdin  <- STAT:critter=<0..4>\n   the badge's resident Lil Guy
 *   stdin  <- STAT:led=<hex,hex,hex>\n its three onboarded colours
 *   stdin  <- STAT:seed=<u32 hex>\n    its brood seed: what its BABIES wear
 *     The last three are OMITTED, not defaulted, when the board has not said —
 *     see Controller.statLines.  Appetite, babies and powerups are always
 *     sent: for those, "none" is an answer rather than a silence.  All of
 *     them must land before JOIN; the server freezes a player's stats when
 *     they take their seat.
 *   stdin  <- RESTART\n     start the next round (tab button click)
 *   stdout -> {"tag":"render",...}\n            stdout -> {"tag":"send","bytes":"<hex>"}\n
 */

const { spawn } = require("child_process");
const { WebSocket } = require("ws");

const RECONNECT_INITIAL_MS = 1_000;
const RECONNECT_MAX_MS = 16_000;

class PlayerSession {
  /**
   * @param {object} opts
   * @param {string} opts.clientBin  path to the Zig client binary
   * @param {string} opts.label      log prefix ("tab", "Board-1", ...)
   */
  constructor({ clientBin, label }) {
    this.clientBin       = clientBin;
    this.label           = label;
    this.zigProc         = null;
    this.zigWritable     = false;
    this.serverWs        = null;
    this.serverConnected = false;
    this.lineBuf         = "";
    this.closed          = false;
    this.reconnectTimer  = null;
    this.reconnectDelay  = RECONNECT_INITIAL_MS;
    /** @type {object | null} LobbyRoom */
    this.room            = null;
    this.started         = false;
  }

  // ---- Subclass hooks -------------------------------------------------------

  /** A parsed non-"send" stdout frame from the Zig client. */
  onZigFrame(_msg, _line) {}

  /** Zig process is up and writable (initial spawn and every restart). */
  onZigSpawned() {}

  /** Zig binary failed to spawn (e.g. ENOENT). */
  onZigSpawnError(_err) {}

  /**
   * The server WS just opened (READY was sent to the Zig client).  Fires on
   * every (re)connect — a reconnected socket is a brand-new observer to the
   * server, so anything standing-related must be re-asked here.
   */
  onServerReady() {}

  /**
   * Server WS dropped (not by teardown). Return true to run the reconnect
   * backoff loop; false if the subclass took over (e.g. dead room teardown).
   */
  shouldReconnect() { return true; }

  // ---- Zig stdin ------------------------------------------------------------

  writeToZig(line) {
    if (this.zigProc && this.zigWritable) {
      this.zigProc.stdin.write(line);
    } else {
      console.warn(`[bridge] writeToZig(${this.label}): dropped (Zig not running):`,
        line.trimEnd().slice(0, 60));
    }
  }

  // ---- Server WebSocket -----------------------------------------------------

  sendToServer(bytes) {
    if (this.serverWs && this.serverConnected &&
        this.serverWs.readyState === WebSocket.OPEN) {
      this.serverWs.send(bytes);
    } else {
      console.warn(`[bridge] sendToServer(${this.label}): dropped ${bytes.length} bytes (not connected)`);
    }
  }

  connectToServer(port) {
    const url = `ws://127.0.0.1:${port}`;
    console.log(`[bridge] ${this.label} connecting to server ${url}`);
    const ws = new WebSocket(url, { perMessageDeflate: false });
    this.serverWs = ws;

    ws.on("open", () => {
      if (this.closed) { ws.close(); return; }
      console.log(`[bridge] ${this.label} server connected`);
      this.serverConnected = true;
      this.reconnectDelay  = RECONNECT_INITIAL_MS;
      this.writeToZig("READY\n");
      this.onServerReady();
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
      if (!this.shouldReconnect()) return;
      console.warn(`[bridge] ${this.label} server disconnected; retry in ${this.reconnectDelay}ms`);
      this.reconnectTimer = setTimeout(() => {
        this.reconnectTimer = null;
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, RECONNECT_MAX_MS);
        if (!this.closed && this.room) this.connectToServer(this.room.port);
      }, this.reconnectDelay);
    });

    ws.on("error", (err) => {
      console.error(`[bridge] ${this.label} server WS error:`, err.message);
    });
  }

  // ---- Zig process ----------------------------------------------------------

  spawnZig() {
    console.log(`[bridge] spawning ${this.clientBin} for ${this.label}`);
    const proc = spawn(this.clientBin, [], { stdio: ["pipe", "pipe", "inherit"] });
    this.zigProc     = proc;
    this.zigWritable = true;

    proc.on("error", (err) => {
      // Spawn failure (e.g. ENOENT: binary missing) emits 'error' without
      // 'exit' — without handling, the session hangs forever.
      console.error(`[bridge] Zig spawn error (${this.label}):`, err.message);
      this.zigWritable = false;
      this.onZigSpawnError(err);
    });

    proc.stdin.on("error", (err) => {
      console.error(`[bridge] Zig stdin error (${this.label}):`, err.message);
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
      console.warn(`[bridge] Zig client exited (${this.label}, code=${code}); restarting in 1s`);
      this.reconnectDelay = RECONNECT_INITIAL_MS;
      setTimeout(() => { if (!this.closed) this.spawnZig(); }, 1_000);
    });

    this.onZigSpawned();
  }

  handleZigLine(line) {
    if (!line) return;
    let msg;
    try { msg = JSON.parse(line); } catch {
      console.error(`[bridge] bad Zig stdout line (${this.label}, not JSON):`, line.slice(0, 120));
      return;
    }

    if (msg.tag === "send" && typeof msg.bytes === "string") {
      const bytes = hexToBytes(msg.bytes);
      if (bytes !== null) this.sendToServer(bytes);
    } else {
      this.onZigFrame(msg, line);
    }
  }

  // ---- Shared cleanup -------------------------------------------------------

  /**
   * Stop the Zig process, server WS, and pending reconnects without firing
   * their restart/reconnect handlers.  Does NOT set `closed` or touch room
   * membership — callers layer their own lifecycle on top.
   */
  closeShared() {
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
  }
}

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

module.exports = { PlayerSession, hexToBytes };
