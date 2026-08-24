"use strict";

/**
 * Hardware game-controller support: discovers dc_rp2040 boards on USB serial
 * (CDC), links them with a line protocol, and turns each into a player.
 *
 * Line protocol (newline-terminated both ways):
 *   board  -> bridge:  CTRL:HELLO v=1          link accept (reply to GAME:HELLO)
 *                      CTRL:HB                 1s keepalive
 *                      CTRL:BTN <name> <D|U>   button press/release edges
 *                      CTRL:STAT appetite=<u32> persistent flash stat, sent
 *                                              once after CTRL:HELLO; feeds
 *                                              the player's hunger capacity
 *                      CTRL:SCORE_ACK g=<u32>  score banked to flash (sent
 *                                              AFTER the save; re-sent on retries)
 *   bridge -> board:   GAME:HELLO v=1          link request (repeated until acked)
 *                      GAME:HB                 1s keepalive
 *                      GAME:PHASE <game|over>  session phase edge: "game" while
 *                                              an encounter is actively running,
 *                                              "over" otherwise (endgame hold,
 *                                              connecting, no room). Deduped;
 *                                              sent whenever it changes so the
 *                                              board only parks on its
 *                                              controller screen mid-game.
 *                      GAME:SCORE s=<u32> g=<u32>  final team score of a finished
 *                                              game (g = per-game id; retried
 *                                              every 1s until acked, bounded)
 *                      FB:SHAPE <label|->      selected-shape feedback (e-paper)
 *
 * Unknown lines in either direction are ignored (the board emits unrelated
 * sibling-link chatter like "dev cnt=..." until the link is established).
 *
 * Player model: every linked board IS a player — it gets its own headless
 * ControllerSession (dedicated Zig client + server connection) in the active
 * lobby, which takes one of the game's four seats (JOIN after READY).  A
 * full game means the board connects as a mere observer: its buttons do
 * nothing until a seat frees up and it relinks.
 *
 * Unplugging a board makes its player leave IMMEDIATELY — the server gives
 * the leaver's hunger/charge shares back to the group and play continues for
 * everyone else.  A replugged board is a NEW player: the same controller can
 * never rejoin a game it left.
 */

const { SerialPort } = require("serialport");
const { ReadlineParser } = require("@serialport/parser-readline");
const { PlayerSession } = require("./session");

// USB identity of the dc_rp2040 firmware (usb_descriptors.c).
const VENDOR_ID = "cafe";
const PRODUCT_ID = "4001";

const BAUD_RATE = 115200;
const SCAN_INTERVAL_MS = 2000;
const HELLO_INTERVAL_MS = 1000;
const HB_INTERVAL_MS = 1000;
// Link drops after this much CTRL: silence (board sends CTRL:HB every 1s).
const LINK_TIMEOUT_MS = 3000;
// GAME:SCORE retry cadence and cap. The board's flash save takes ~100ms+
// (it parks its renderer around the erase), so the ack is never instant;
// five attempts comfortably outlives any transient CDC hiccup while still
// giving up long before the next game could end.
const SCORE_RETRY_MS = 1000;
const SCORE_RETRY_MAX = 5;

// Board button -> browser KeyboardEvent.key (the Zig client's KEY: protocol).
// D-pad = aim, face buttons = shape wheel + cast (see src/client/input.zig).
// Every value here must be one of input.zig's parse_key_name names, or the
// Zig client silently drops the press.
const KEY_MAP = {
  UP: "ArrowUp",
  LEFT: "ArrowLeft",
  DOWN: "ArrowDown",
  RIGHT: "ArrowRight",
  A: "1", // shape wheel forward
  B: "2", // shape wheel backward
  C: "Enter", // cast (realtime) / dismiss (game over)
  D: "Escape", // take back the newest lock-in
};

/**
 * Label of the move this board's player currently has selected, for the
 * e-paper: the wheel is server-authoritative, so the render frame carries an
 * index (`entities[own].selected_shape`) into the balance move table and the
 * caller resolves it against that room's config.  "-" when unknown (observer,
 * pre-connect, or a table that shrank under a stale frame).
 */
function shapeFromRender(msg, labels) {
  const game = msg.game;
  if (!game || !Array.isArray(game.entities)) return "-";
  const mine = game.entities.find((e) => e.owner === game.player_id);
  if (!mine || typeof mine.selected_shape !== "number") return "-";
  return labels[mine.selected_shape] ?? "-";
}

/**
 * Final team score on the frame that ENTERS game_over, else null. Callers
 * track prevPhase per session so repeated game_over frames (the Zig client
 * re-renders the board while it holds) fire the score exactly once per game.
 * @param {object} msg  a "render" frame from the Zig client
 * @param {string | null} prevPhase  msg.phase of the previous frame
 * @returns {number | null}
 */
function finalScoreFromRender(msg, prevPhase) {
  if (msg.phase !== "game_over" || prevPhase === "game_over") return null;
  if (typeof msg.score !== "number") return null;
  return msg.score >>> 0;
}

// Per-report id for the board's dedupe (it remembers the last BANKED id per
// power cycle). Wall-clock seeded and monotonically bumped, so neither a
// bridge restart nor several boards reported in the same millisecond can
// reissue an id a board already banked.
let lastScoreId = 0;
function nextScoreId() {
  const t = Date.now() >>> 0;
  lastScoreId = t > lastScoreId ? t : (lastScoreId + 1) >>> 0;
  return lastScoreId;
}

/** One physical board on a serial port. */
class Controller {
  /**
   * @param {string} path
   * @param {string} uid  USB serial number (flash unique ID)
   * @param {ControllerManager} manager
   */
  constructor(path, uid, manager) {
    this.path = path;
    this.uid = uid;
    this.manager = manager;
    this.port = null;
    this.linked = false;
    /** Owned headless ControllerSession (the board IS the player), or null. */
    this.playerSession = null;
    this.lastRxMs = 0;
    /** Appetite stat reported by the board (CTRL:STAT), 0 until it arrives.
     *  Forwarded to the board's player — it scales that player's share of
     *  the game's hunger bar (see the Zig server's game_logic.player_hunger). */
    this.appetite = 0;
    this.lastShape = null; // last FB:SHAPE payload sent (dedupe)
    /** Last GAME:PHASE activity sent (boolean), or null before the first. */
    this.lastActive = null;
    this.helloTimer = null;
    this.hbTimer = null;
    /** In-flight GAME:SCORE ({ line, gid, attempts }), or null. */
    this.scorePending = null;
    this.scoreTimer = null;
    this.closed = false;
  }

  open() {
    const port = new SerialPort(
      { path: this.path, baudRate: BAUD_RATE },
      (err) => {
        if (err) {
          console.error(`[ctrl] open failed (${this.path}):`, err.message);
          this.manager.dropController(this);
        }
      },
    );
    this.port = port;

    port.on("open", () => {
      // TinyUSB gates CDC TX on DTR; assert it explicitly.
      port.set({ dtr: true, rts: true }, () => {});
      console.log(`[ctrl] opened ${this.path} (uid=${this.uid})`);
      this.helloTimer = setInterval(() => {
        if (!this.linked) this.write("GAME:HELLO v=1");
      }, HELLO_INTERVAL_MS);
      this.write("GAME:HELLO v=1");
    });

    const parser = port.pipe(new ReadlineParser({ delimiter: "\n" }));
    parser.on("data", (raw) => this.onLine(raw.toString().trim()));

    port.on("close", () => {
      console.log(`[ctrl] port closed ${this.path}`);
      this.manager.dropController(this);
    });
    port.on("error", (err) => {
      console.error(`[ctrl] port error (${this.path}):`, err.message);
      this.manager.dropController(this);
    });
  }

  write(line) {
    if (this.port && this.port.isOpen) {
      this.port.write(line + "\n");
    }
  }

  /** @param {string} line */
  onLine(line) {
    if (!line.startsWith("CTRL:")) return; // sibling-link chatter etc.
    this.lastRxMs = Date.now();

    if (line.startsWith("CTRL:HELLO")) {
      if (!this.linked) {
        this.linked = true;
        console.log(`[ctrl] linked ${this.path} (uid=${this.uid})`);
        this.hbTimer = setInterval(() => {
          this.write("GAME:HB");
          if (Date.now() - this.lastRxMs > LINK_TIMEOUT_MS) {
            console.warn(`[ctrl] heartbeat timeout ${this.path}`);
            this.manager.dropController(this);
          }
        }, HB_INTERVAL_MS);
        this.manager.assign();
      }
      return;
    }

    if (line.startsWith("CTRL:BTN ")) {
      const [name, edge] = line.slice("CTRL:BTN ".length).split(" ");
      if (edge !== "D") return; // down-edges only
      const key = KEY_MAP[name];
      if (key === undefined) {
        console.warn(`[ctrl] unknown button '${name}' from ${this.path}`);
        return;
      }
      if (this.playerSession !== null) {
        this.playerSession.writeToZig(`KEY:${key}\n`);
      }
      return;
    }

    if (line.startsWith("CTRL:STAT ")) {
      // Persistent flash stats, reported once after the link comes up.
      const arg = line.slice("CTRL:STAT ".length).trim();
      const m = arg.match(/^appetite=(\d+)$/);
      if (m === null) {
        console.warn(`[ctrl] unknown stat '${arg}' from ${this.path}`);
        return;
      }
      this.appetite = Number(m[1]) >>> 0;
      // Forward to the player; the stat only counts if it lands before the
      // seat is taken (the server freezes the share at count time).
      if (this.playerSession !== null) {
        this.playerSession.writeToZig(`STAT:appetite=${this.appetite}\n`);
      }
      return;
    }

    if (line.startsWith("CTRL:SCORE_ACK ")) {
      // Banked on the board (the ack is sent after its flash save): stop
      // retrying. Stale acks (an earlier report's retries) are ignored.
      const arg = line.slice("CTRL:SCORE_ACK ".length).trim();
      if (this.scorePending !== null && arg === `g=${this.scorePending.gid}`) {
        console.log(`[ctrl] score banked (uid=${this.uid}, ${arg})`);
        this.clearScoreRetry();
      }
      return;
    }
    // CTRL:HB and future extensions: keepalive only (lastRxMs above).
  }

  /**
   * Push the session phase to the board (deduped): true while an encounter
   * is actively running, false for endgame hold / connecting / no room. The
   * board uses this to decide whether to park on its controller screen.
   * @param {boolean} active
   */
  sendPhase(active) {
    if (!this.linked || active === this.lastActive) return;
    this.lastActive = active;
    this.write(`GAME:PHASE ${active ? "game" : "over"}`);
  }

  /** Push selected-shape feedback to the board's e-paper (deduped). */
  sendShape(shape) {
    if (!this.linked || shape === this.lastShape) return;
    this.lastShape = shape;
    this.write(`FB:SHAPE ${shape}`);
  }

  /**
   * Report a finished game's final team score for the board to bank into
   * its flash lifetime total: GAME:SCORE retried until CTRL:SCORE_ACK (or
   * the bounded attempts run out). The board dedupes by the id, so retries
   * - and a replay across a relink - can never double-bank.
   * @param {number} score  final team score (u32)
   */
  sendScore(score) {
    if (!this.linked) return;
    const gid = nextScoreId();
    this.clearScoreRetry(); // a newer game's report supersedes any in flight
    this.scorePending = {
      line: `GAME:SCORE s=${score >>> 0} g=${gid}`,
      gid,
      attempts: 0,
    };
    const attempt = () => {
      const p = this.scorePending;
      if (p === null) return;
      if (p.attempts >= SCORE_RETRY_MAX) {
        console.warn(
          `[ctrl] score never acked (uid=${this.uid}, g=${p.gid}); giving up`,
        );
        this.clearScoreRetry();
        return;
      }
      p.attempts++;
      this.write(p.line);
    };
    this.scoreTimer = setInterval(attempt, SCORE_RETRY_MS);
    attempt();
  }

  clearScoreRetry() {
    if (this.scoreTimer !== null) clearInterval(this.scoreTimer);
    this.scoreTimer = null;
    this.scorePending = null;
  }

  close() {
    this.closed = true;
    if (this.helloTimer !== null) clearInterval(this.helloTimer);
    if (this.hbTimer !== null) clearInterval(this.hbTimer);
    this.clearScoreRetry();
    this.helloTimer = null;
    this.hbTimer = null;
    if (this.port && this.port.isOpen) {
      this.port.close(() => {});
    }
    this.port = null;
  }
}

/**
 * A player owned by a hardware controller: dedicated Zig client in a room,
 * no browser. Render frames drive the board's shape feedback.
 */
class ControllerSession extends PlayerSession {
  /**
   * @param {object} opts
   * @param {string} opts.clientBin
   * @param {object} opts.room         LobbyRoom to join
   * @param {Controller} opts.controller
   * @param {ControllerManager} opts.manager
   */
  constructor({ clientBin, room, controller, manager }) {
    super({ clientBin, label: `board-${controller.uid}` });
    this.manager = manager;
    this.controller = controller;
    this.room = room;
    this.started = true;
    /** msg.phase of the last render frame (game-over edge detection). */
    this.lastPhase = null;
  }

  start() {
    this.manager.roomJoined(this.room);
    this.spawnZig();
    // Small delay: give the server process a moment to bind its port if just
    // spawned (same as TabSession.startInRoom).
    setTimeout(() => {
      if (!this.closed) this.connectToServer(this.room.port);
    }, 200);
  }

  // ---- PlayerSession hooks --------------------------------------------------

  onZigSpawned() {
    // Before READY/JOIN so the take_slot carries the board's appetite.
    if (this.controller !== null) {
      this.writeToZig(`STAT:appetite=${this.controller.appetite}\n`);
    }
  }

  onServerReady() {
    // A board IS a player: ask for a seat the moment the connection stands.
    // Silently ignored by the server when the game is full — the board then
    // just observes (its buttons do nothing).
    this.writeToZig("JOIN\n");
  }

  onZigFrame(msg, _line) {
    if (msg.tag === "render") {
      const score = finalScoreFromRender(msg, this.lastPhase);
      this.lastPhase = msg.phase;
      if (this.controller !== null) {
        this.controller.sendPhase(msg.phase === "game");
        this.controller.sendShape(
          shapeFromRender(msg, this.manager.moveLabels(this.room.configHash)),
        );
        // Game just ended: bank the final team score on the board.
        if (score !== null) this.controller.sendScore(score);
      }
    } else {
      console.warn(`[bridge] unknown Zig frame tag (${this.label}):`, msg.tag);
    }
  }

  onZigSpawnError(_err) {
    this.destroy("zig spawn failed");
  }

  shouldReconnect() {
    // The lobby's server process died: this player has nowhere to go.
    if (!this.manager.isRoomAlive(this.room)) {
      this.destroy("room dead");
      return false;
    }
    return true;
  }

  destroy(reason) {
    if (this.closed) return;
    this.closed = true;
    this.closeShared();
    if (this.controller !== null) {
      // No player, no frames: whatever game the board was in is over for it.
      this.controller.sendPhase(false);
      this.controller.playerSession = null;
      this.controller = null;
    }
    this.manager.roomLeft(this.room);
    this.manager.playerDestroyed(this, reason);
  }
}

class ControllerManager {
  /**
   * @param {object} hooks
   * @param {string} hooks.clientBin  path to the Zig client binary
   * @param {() => object | null} hooks.pickRoom  room for a new board player
   *   (null = none available)
   * @param {(room: object) => void} hooks.roomJoined  occupancy up
   * @param {(room: object) => void} hooks.roomLeft    occupancy down
   * @param {(room: object) => boolean} hooks.isRoomAlive
   * @param {(configHash: string | null) => string[]} hooks.moveLabels  move
   *   labels in balance-file order for a room's config (index space of
   *   `selected_shape`)
   */
  constructor({ clientBin, pickRoom, roomJoined, roomLeft, isRoomAlive, moveLabels }) {
    this.clientBin = clientBin;
    this.pickRoom = pickRoom;
    this.roomJoined = roomJoined;
    this.roomLeft = roomLeft;
    this.isRoomAlive = isRoomAlive;
    this.moveLabels = moveLabels;
    /** @type {Map<string, Controller>} port path -> controller */
    this.controllers = new Map();
    this.scanTimer = null;
  }

  start() {
    this.scanTimer = setInterval(() => {
      this.scan().catch((err) => console.error("[ctrl] scan error:", err));
    }, SCAN_INTERVAL_MS);
    this.scan().catch((err) => console.error("[ctrl] scan error:", err));
    console.log("[ctrl] watching for controllers (vid:pid " +
      `${VENDOR_ID}:${PRODUCT_ID})`);
  }

  async scan() {
    const ports = await SerialPort.list();
    for (const p of ports) {
      const vid = (p.vendorId || "").toLowerCase();
      const pid = (p.productId || "").toLowerCase();
      if (vid !== VENDOR_ID || pid !== PRODUCT_ID) continue;
      if (this.controllers.has(p.path)) continue;
      const uid = p.serialNumber || p.path;
      const ctrl = new Controller(p.path, uid, this);
      this.controllers.set(p.path, ctrl);
      ctrl.open();
    }
    this.assign();
  }

  /**
   * Give every linked, unassigned board its own player session in the active
   * lobby (single room, else the newest; see the pickRoom hook).  With no
   * room yet the board waits; this re-runs on every state change.
   */
  assign() {
    for (const ctrl of this.controllers.values()) {
      if (!ctrl.linked || ctrl.playerSession !== null) continue;
      const room = this.pickRoom();
      if (room === null) continue;
      this.makePlayer(ctrl, room);
    }
  }

  makePlayer(ctrl, room) {
    const player = new ControllerSession({
      clientBin: this.clientBin,
      room,
      controller: ctrl,
      manager: this,
    });
    ctrl.playerSession = player;
    ctrl.lastShape = null;
    player.start();
    console.log(`[ctrl] uid=${ctrl.uid} joined room ${room.code}`);
  }

  /** A room appeared or changed: waiting boards may now get a player. */
  sessionStarted() {
    this.assign();
  }

  /** A board player died (board unplug, dead room, spawn failure). */
  playerDestroyed(player, reason) {
    console.log(`[ctrl] player ${player.label} destroyed (${reason})`);
    // Its board may still be linked (e.g. room died) — reassign it.
    this.assign();
  }

  /**
   * Serial port gone or link dead: the board's player leaves IMMEDIATELY.
   * Closing the player's server WS is what tells the game server (its
   * Handler.close → Session.disconnect gives the leaver's hunger/charge
   * shares back to the group); a replugged board is a brand-new player.
   *
   * The controller is closed and deregistered BEFORE the session teardown:
   * teardown re-runs the assignment pass, which must not see this board.
   */
  dropController(ctrl) {
    if (ctrl.closed) return;
    const player = ctrl.playerSession;
    ctrl.playerSession = null;
    ctrl.close();
    this.controllers.delete(ctrl.path);
    console.log(`[ctrl] dropped ${ctrl.path} (uid=${ctrl.uid})`);
    if (player) {
      player.controller = null;
      player.destroy("controller disconnected");
    }
  }
}

module.exports = {
  Controller,
  ControllerManager,
  ControllerSession,
  shapeFromRender,
  finalScoreFromRender,
};
