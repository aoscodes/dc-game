"use strict";

/**
 * Hardware game-controller support: discovers dc_rp2040 boards on USB serial
 * (CDC), links them with a line protocol, and turns each into player input.
 *
 * Line protocol (newline-terminated both ways):
 *   board  -> bridge:  CTRL:HELLO v=1          link accept (reply to GAME:HELLO)
 *                      CTRL:HB                 1s keepalive
 *                      CTRL:BTN <name> <D|U>   button press/release edges
 *   bridge -> board:   GAME:HELLO v=1          link request (repeated until acked)
 *                      GAME:HB                 1s keepalive
 *                      FB:SHAPE <label|->      selected-shape feedback (e-paper)
 *
 * Unknown lines in either direction are ignored (the board emits unrelated
 * sibling-link chatter like "dev cnt=..." until the link is established).
 *
 * Hybrid player model — a linked board is assigned by this ladder:
 *   1. Sticky UID (the board's USB serial number = RP2040 flash unique ID):
 *      return to its previous tab pairing or headless player session.
 *   2. Pair with the oldest started TabSession that has no controller —
 *      the board drives that tab's player.
 *   3. Become its own player: spawn a headless ControllerSession (dedicated
 *      Zig client, named Board-N) in the active lobby (single room, else the
 *      newest; see the pickRoom hook).
 *   4. No room yet: wait; the ladder re-runs on every state change.
 *
 * Unplugging a headless board starts a 30s grace timer on its session —
 * replug inside the window re-attaches to the same player (the Zig process,
 * and thus the player identity, never died). Expiry tears the player down.
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
// Headless player survives this long after its board unplugs.
const PLAYER_GRACE_MS = 30_000;

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
  C: "Enter", // cast (realtime) / ready toggle (lobby)
  D: "Escape", // inert in game; lobby/menu back
};

/**
 * Label of the move this board's player currently has selected, for the
 * e-paper: the wheel is server-authoritative, so the render frame carries an
 * index (`entities[own].selected_shape`) into the balance move table and the
 * caller resolves it against that room's config.  "-" when unknown (lobby,
 * pre-join, or a table that shrank under a stale frame).
 */
function shapeFromRender(msg, labels) {
  const game = msg.game;
  if (!game || !Array.isArray(game.entities)) return "-";
  const mine = game.entities.find((e) => e.owner === game.player_id);
  if (!mine || typeof mine.selected_shape !== "number") return "-";
  return labels[mine.selected_shape] ?? "-";
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
    /** Paired TabSession (board drives that tab's player), or null. */
    this.session = null;
    /** Owned headless ControllerSession (board IS the player), or null. */
    this.playerSession = null;
    this.lastRxMs = 0;
    this.lastShape = null; // last FB:SHAPE payload sent (dedupe)
    this.helloTimer = null;
    this.hbTimer = null;
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
      if (this.session !== null) {
        this.manager.onKey(this.session, key);
      } else if (this.playerSession !== null) {
        this.playerSession.writeToZig(`KEY:${key}\n`);
      }
      return;
    }
    // CTRL:HB and future extensions: keepalive only (lastRxMs above).
  }

  /** Push selected-shape feedback to the board's e-paper (deduped). */
  sendShape(shape) {
    if (!this.linked || shape === this.lastShape) return;
    this.lastShape = shape;
    this.write(`FB:SHAPE ${shape}`);
  }

  close() {
    this.closed = true;
    if (this.helloTimer !== null) clearInterval(this.helloTimer);
    if (this.hbTimer !== null) clearInterval(this.hbTimer);
    this.helloTimer = null;
    this.hbTimer = null;
    if (this.port && this.port.isOpen) {
      this.port.close(() => {});
    }
    this.port = null;
  }
}

/**
 * A headless player owned by a hardware controller: dedicated Zig client in
 * a room, no browser. Render frames drive the board's shape feedback.
 */
class ControllerSession extends PlayerSession {
  /**
   * @param {object} opts
   * @param {string} opts.clientBin
   * @param {string} opts.name         player name ("Board-1", ...)
   * @param {object} opts.room         LobbyRoom to join
   * @param {Controller} opts.controller
   * @param {ControllerManager} opts.manager
   */
  constructor({ clientBin, name, room, controller, manager }) {
    super({ clientBin, label: name });
    this.name = name;
    this.manager = manager;
    this.controller = controller;
    this.graceTimer = null;
    this.room = room;
    this.started = true;
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
    // Before READY (sent on server WS open) so JoinLobby carries the name.
    this.writeToZig(`NAME:${this.name}\n`);
  }

  onZigFrame(msg, _line) {
    if (msg.tag === "render") {
      if (this.controller !== null) {
        this.controller.sendShape(
          shapeFromRender(msg, this.manager.moveLabels(this.room.configHash)),
        );
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

  // ---- Board attachment -----------------------------------------------------

  /** Board re-linked within the grace window: same player carries on. */
  attach(controller) {
    if (this.graceTimer !== null) {
      clearTimeout(this.graceTimer);
      this.graceTimer = null;
    }
    this.controller = controller;
    console.log(`[ctrl] ${this.name} re-attached (uid=${controller.uid})`);
  }

  /** Board unplugged: keep the player alive for PLAYER_GRACE_MS. */
  detach() {
    this.controller = null;
    if (this.closed || this.graceTimer !== null) return;
    console.log(`[ctrl] ${this.name} board unplugged; dropping player in ${PLAYER_GRACE_MS / 1000}s unless it returns`);
    this.graceTimer = setTimeout(() => {
      this.graceTimer = null;
      this.destroy("grace expired");
    }, PLAYER_GRACE_MS);
  }

  destroy(reason) {
    if (this.closed) return;
    this.closed = true;
    if (this.graceTimer !== null) {
      clearTimeout(this.graceTimer);
      this.graceTimer = null;
    }
    this.closeShared();
    if (this.controller !== null) {
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
   * @param {() => Iterable<object>} hooks.getSessions  active TabSessions in
   *   creation order (each gets a `.controller` property managed here)
   * @param {(session: object, key: string) => void} hooks.onKey  deliver one
   *   key press to a tab session
   * @param {() => object | null} hooks.pickRoom  room for a new headless
   *   player (null = none available)
   * @param {(room: object) => void} hooks.roomJoined  occupancy up
   * @param {(room: object) => void} hooks.roomLeft    occupancy down
   * @param {(room: object) => boolean} hooks.isRoomAlive
   * @param {(configHash: string | null) => string[]} hooks.moveLabels  move
   *   labels in balance-file order for a room's config (index space of
   *   `selected_shape`)
   */
  constructor({ clientBin, getSessions, onKey, pickRoom, roomJoined, roomLeft, isRoomAlive, moveLabels }) {
    this.clientBin = clientBin;
    this.getSessions = getSessions;
    this.onKey = onKey;
    this.pickRoom = pickRoom;
    this.roomJoined = roomJoined;
    this.roomLeft = roomLeft;
    this.isRoomAlive = isRoomAlive;
    this.moveLabels = moveLabels;
    /** @type {Map<string, Controller>} port path -> controller */
    this.controllers = new Map();
    /** @type {Map<string, object>} uid -> TabSession (sticky tab pairing) */
    this.uidToSession = new Map();
    /** @type {Map<string, ControllerSession>} uid -> headless player */
    this.uidToPlayer = new Map();
    /** @type {Map<string, number>} uid -> Board-N number (bridge lifetime) */
    this.uidToNumber = new Map();
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

  /** Stable per-UID player name for the bridge's lifetime. */
  nameFor(uid) {
    let n = this.uidToNumber.get(uid);
    if (n === undefined) {
      const used = new Set(this.uidToNumber.values());
      n = 1;
      while (used.has(n)) n++;
      this.uidToNumber.set(uid, n);
    }
    return `Board-${n}`;
  }

  /**
   * Assignment ladder for every linked, unassigned controller (see module
   * doc). Safe to call on any state change; no-ops when nothing applies.
   */
  assign() {
    for (const ctrl of this.controllers.values()) {
      if (!ctrl.linked || ctrl.session !== null || ctrl.playerSession !== null) continue;

      // 1a. Sticky tab pairing: while the previous tab is alive the claim
      //     holds — the board waits for it rather than serving another tab.
      const prevTab = this.uidToSession.get(ctrl.uid);
      if (prevTab !== undefined && !prevTab.closed) {
        if (prevTab.started && prevTab.controller === null) this.pair(ctrl, prevTab);
        continue;
      }

      // 1b. Sticky headless player: replug within the grace window.
      const prevPlayer = this.uidToPlayer.get(ctrl.uid);
      if (prevPlayer !== undefined && !prevPlayer.closed) {
        prevPlayer.attach(ctrl);
        ctrl.playerSession = prevPlayer;
        continue;
      }

      // 2. Pair with the oldest started tab session lacking a controller.
      let paired = false;
      for (const session of this.getSessions()) {
        if (session.started && session.controller === null) {
          this.pair(ctrl, session);
          paired = true;
          break;
        }
      }
      if (paired) continue;

      // 3. Become an independent player in the active lobby.
      const room = this.pickRoom();
      if (room !== null) {
        this.makePlayer(ctrl, room);
        continue;
      }

      // 4. No room yet: wait for the next state change.
    }
  }

  pair(ctrl, session) {
    ctrl.session = session;
    session.controller = ctrl;
    this.uidToSession.set(ctrl.uid, session);
    this.uidToPlayer.delete(ctrl.uid); // pairing modes are exclusive per uid
    // Force a fresh shape push for the new pairing.
    ctrl.lastShape = null;
    ctrl.sendShape("-");
    console.log(`[ctrl] paired uid=${ctrl.uid} to a tab session`);
  }

  makePlayer(ctrl, room) {
    const name = this.nameFor(ctrl.uid);
    const player = new ControllerSession({
      clientBin: this.clientBin,
      name,
      room,
      controller: ctrl,
      manager: this,
    });
    ctrl.playerSession = player;
    this.uidToPlayer.set(ctrl.uid, player);
    this.uidToSession.delete(ctrl.uid); // pairing modes are exclusive per uid
    ctrl.lastShape = null;
    player.start();
    console.log(`[ctrl] uid=${ctrl.uid} joined room ${room.code} as ${name}`);
  }

  /** A tab session started in a room: boards may pair or join its lobby. */
  sessionStarted() {
    this.assign();
  }

  /**
   * A tab session left its room or closed: detach its controller. Sticky UID
   * mapping is kept only while the session can come back (still open).
   * @param {object} session
   * @param {{ forget?: boolean }} [opts]  forget: drop the sticky mapping too
   */
  releaseSession(session, { forget = false } = {}) {
    const ctrl = session.controller;
    if (ctrl) {
      ctrl.session = null;
      session.controller = null;
    }
    if (forget) {
      for (const [uid, s] of this.uidToSession) {
        if (s === session) this.uidToSession.delete(uid);
      }
    }
    this.assign();
  }

  /** A headless player died (grace expiry, dead room, spawn failure). */
  playerDestroyed(player, reason) {
    for (const [uid, p] of this.uidToPlayer) {
      if (p === player) this.uidToPlayer.delete(uid);
    }
    console.log(`[ctrl] player ${player.name} destroyed (${reason})`);
    // Its board may still be linked (e.g. room died) — reassign it.
    this.assign();
  }

  /** Serial port gone or link dead: tear down and allow re-discovery. */
  dropController(ctrl) {
    if (ctrl.closed) return;
    if (ctrl.session) {
      ctrl.session.controller = null;
      ctrl.session = null;
    }
    if (ctrl.playerSession) {
      ctrl.playerSession.detach(); // grace window starts
      ctrl.playerSession = null;
    }
    ctrl.close();
    this.controllers.delete(ctrl.path);
    console.log(`[ctrl] dropped ${ctrl.path} (uid=${ctrl.uid})`);
  }
}

module.exports = { ControllerManager, ControllerSession, shapeFromRender };
