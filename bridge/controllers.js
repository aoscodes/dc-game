"use strict";

/**
 * Hardware game-controller support: discovers dc_rp2040 boards on USB serial
 * (CDC), links them with a line protocol, and turns each into a player.
 *
 * Line protocol (newline-terminated both ways):
 *   board  -> bridge:  CTRL:HELLO v=1          link accept (reply to GAME:HELLO)
 *                      CTRL:HB                 1s keepalive
 *                      CTRL:BTN <name> <D|U>   button press/release edges
 *                      CTRL:STAT appetite=<u32> babies=<a,b,c,d,e>
 *                                critter=<0..4> led=<rrggbb>,<rrggbb>,<rrggbb>
 *                                              persistent flash stats, sent
 *                                              once after CTRL:HELLO; appetite
 *                                              feeds the player's hunger
 *                                              capacity, babies (per BabyType,
 *                                              ordinal order) join the game
 *                                              with their owner, and critter +
 *                                              led are what that player's Lil
 *                                              Guy looks like on the shared
 *                                              screen.  Every key but appetite
 *                                              is absent on old firmware; each
 *                                              falls back on its own.
 *                      CTRL:SCORE_ACK g=<u32>  score banked to flash (sent
 *                                              AFTER the save; re-sent on retries)
 *                      CTRL:LED_ACK g=<u32>    palette banked to flash, on
 *                                              exactly the same terms
 *   bridge -> board:   GAME:HELLO v=1          link request (repeated until acked)
 *                      GAME:HB                 1s keepalive
 *                      GAME:PHASE <game|over>  session phase edge: "game" while
 *                                              an encounter is actively running,
 *                                              "over" otherwise (endgame hold,
 *                                              connecting, no room). Deduped;
 *                                              sent whenever it changes so the
 *                                              board only parks on its
 *                                              controller screen mid-game.
 *                      GAME:SCORE s=<u32> g=<u32> b=<a,b,c,d,e>
 *                                              final team score of a finished
 *                                              game plus the babies it hatched
 *                                              (per BabyType, ordinal order;
 *                                              the board banks both).  g =
 *                                              per-game id; retried every 1s
 *                                              until acked, bounded.
 *                      FB:SHAPE <label|->      selected-shape feedback (e-paper)
 *                      LED:LIVE c=<rrggbb>,<rrggbb>,<rrggbb>
 *                                              the /onboard screen's colour
 *                                              spin, streamed ~20Hz. Transient
 *                                              and unacked; the board never
 *                                              saves it and lets it expire on
 *                                              its own after 500ms, so a dead
 *                                              host cannot strand the LEDs.
 *                      LED:SET c=<rrggbb>,<rrggbb>,<rrggbb> g=<u32>
 *                                              the colours the spin landed on,
 *                                              one per colour LED, for the
 *                                              board to bank into its flash.
 *                                              g = per-roll id; retried every
 *                                              1s until acked, bounded.
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

// BabyType ordinal order — must match the Zig components.BabyType enum and
// the board's flash layout. The wire carries counts as a bare comma list in
// exactly this order.
const BABY_TYPE_COUNT = 5;

/** How many LEDs a badge has, and so how many colours it reports. */
const LED_COUNT = 3;

/** Parse "rrggbb,rrggbb,rrggbb" into 3 packed u24s, or null when malformed. */
function parseLedList(text) {
  const parts = text.split(",");
  if (parts.length !== LED_COUNT) return null;
  const leds = [];
  for (const p of parts) {
    if (!/^[0-9a-fA-F]{6}$/.test(p.trim())) return null;
    leds.push(parseInt(p.trim(), 16) >>> 0);
  }
  return leds;
}

/** Parse "a,b,c,d,e" into 5 u32s, or null when malformed/miscounted. */
function parseBabyList(text) {
  const parts = text.split(",");
  if (parts.length !== BABY_TYPE_COUNT) return null;
  const counts = [];
  for (const p of parts) {
    if (!/^\d+$/.test(p.trim())) return null;
    counts.push(Number(p.trim()) >>> 0);
  }
  return counts;
}

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
// LED:SET retry cadence and cap. Same reasoning as the score — the board's
// flash save parks its e-paper renderer around the erase — but the /onboard
// screen is waiting on this ack before it moves to the next badge, so the cap
// doubles as how long a player stares at a stalled kiosk.
const PALETTE_RETRY_MS = 1000;
const PALETTE_RETRY_MAX = 5;

// How many colours a palette carries: one per RGB LED on the badge
// (LED_RGB_COUNT in the firmware's led/rgb.h). The onboarding screen's three
// zones are these three LEDs.
const PALETTE_COLOR_COUNT = 3;

/** True for exactly PALETTE_COLOR_COUNT six-digit hex colours. */
function isPalette(colors) {
  return Array.isArray(colors) &&
    colors.length === PALETTE_COLOR_COUNT &&
    colors.every((c) => typeof c === "string" && /^[0-9a-fA-F]{6}$/.test(c));
}

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
  D: "Escape", // no-op in play (cancel is retired: casts resolve instantly)
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

/**
 * Babies hatched over the finished encounter, per BabyType ordinal, from a
 * game_over render frame's stats. Zeros when absent (old client / no stats).
 * @param {object} msg  a "render" frame from the Zig client
 * @returns {number[]}
 */
function hatchedFromRender(msg) {
  const names = ["rose", "mint", "sky", "gold", "plum"]; // BabyType ordinals
  const hatched = msg.stats?.eggs_hatched ?? {};
  return names.map((n) => (hatched[n] ?? 0) >>> 0);
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

// Roll ids for LED:SET, on the same monotonic-per-process terms as score ids
// (the board dedupes on them in RAM, so they only have to be unique for as
// long as a board stays powered).
let lastPaletteId = 0;
function nextPaletteId() {
  const t = Date.now() >>> 0;
  lastPaletteId = t > lastPaletteId ? t : (lastPaletteId + 1) >>> 0;
  return lastPaletteId;
}

// Identifies one LINK, not one board.  The /onboard screen addresses badges by
// this and nothing else, which is what makes its queue correct: a badge that
// is unplugged and replugged is a new link and so is rolled again, while a
// badge that just sits there keeps its id and is rolled once.  It also means a
// queued command can never land on a board that was swapped underneath it —
// the id simply stops resolving.
let lastLinkId = 0;

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
    /** Identity of this link once established, else null (see lastLinkId). */
    this.linkId = null;
    /** Owned headless ControllerSession (the board IS the player), or null. */
    this.playerSession = null;
    this.lastRxMs = 0;
    /** Appetite stat reported by the board (CTRL:STAT), 0 until it arrives.
     *  Forwarded to the board's player — it scales that player's share of
     *  the game's hunger bar (see the Zig server's game_logic.player_hunger). */
    this.appetite = 0;
    /** Babies banked on the board (CTRL:STAT), per BabyType; zeros until the
     *  stat arrives (and forever, for old firmware that never sends it). */
    this.babies = new Array(BABY_TYPE_COUNT).fill(0);
    /** Which critter this badge keeps (CTRL:STAT), as a BabyType ordinal, or
     *  null until it says. The board picks one and keeps it, so this is the
     *  creature drawn for its player all game. */
    this.critter = null;
    /** The badge's three LED colours (CTRL:STAT) as packed u24s, or null
     *  until it says. The client repaints its Lil Guy in these. */
    this.led = null;
    this.lastShape = null; // last FB:SHAPE payload sent (dedupe)
    /** Last GAME:PHASE activity sent (boolean), or null before the first. */
    this.lastActive = null;
    this.helloTimer = null;
    this.hbTimer = null;
    /** In-flight GAME:SCORE ({ line, gid, attempts }), or null. */
    this.scorePending = null;
    this.scoreTimer = null;
    /** In-flight LED:SET ({ line, gid, attempts, done }), or null. */
    this.palettePending = null;
    this.paletteTimer = null;
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
        this.linkId = ++lastLinkId;
        console.log(
          `[ctrl] linked ${this.path} (uid=${this.uid}, link=${this.linkId})`);
        this.hbTimer = setInterval(() => {
          this.write("GAME:HB");
          if (Date.now() - this.lastRxMs > LINK_TIMEOUT_MS) {
            console.warn(`[ctrl] heartbeat timeout ${this.path}`);
            this.manager.dropController(this);
          }
        }, HB_INTERVAL_MS);
        this.manager.assign();
        // A new link is a new badge for the onboarding queue to roll.
        this.manager.boardsChanged();
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
      // Persistent flash stats, reported once after the link comes up, as
      // space-separated key=value pairs. Unknown keys are ignored and a
      // missing `babies` (old firmware) means all zero.
      const args = line.slice("CTRL:STAT ".length).trim().split(/\s+/);
      let known = false;
      for (const arg of args) {
        const appetite = arg.match(/^appetite=(\d+)$/);
        if (appetite !== null) {
          this.appetite = Number(appetite[1]) >>> 0;
          known = true;
          continue;
        }
        const babies = arg.match(/^babies=([\d,]+)$/);
        if (babies !== null) {
          const counts = parseBabyList(babies[1]);
          if (counts !== null) {
            this.babies = counts;
            known = true;
          }
          continue;
        }
        const critter = arg.match(/^critter=(\d+)$/);
        if (critter !== null) {
          const n = Number(critter[1]);
          if (n < BABY_TYPE_COUNT) {
            this.critter = n;
            known = true;
          }
          continue;
        }
        const led = arg.match(/^led=([0-9a-fA-F,]+)$/);
        if (led !== null) {
          const colours = parseLedList(led[1]);
          if (colours !== null) {
            // A badge reports 000000 x3 until someone runs the /onboard flow
            // (store.h led_rgb). That is not a palette of black, it is NO
            // palette, and it stays null so the renderer draws the authored
            // art rather than a solid black creature. The key was still
            // understood, so the line is not a mystery.
            this.led = colours.every((c) => c === 0) ? null : colours;
            known = true;
          }
          continue;
        }
      }
      if (!known) {
        console.warn(`[ctrl] unknown stat line '${line}' from ${this.path}`);
        return;
      }
      // Forward to the player; the stats only count if they land before the
      // seat is taken (the server freezes the share at count time).
      if (this.playerSession !== null) {
        this.playerSession.writeToZig(`STAT:appetite=${this.appetite}\n`);
        this.playerSession.writeToZig(`STAT:babies=${this.babies.join(",")}\n`);
        // Appearance is sent only once the board has said - the server's
        // default is "unreported", which the client draws as plain art, and
        // an invented value here would be indistinguishable from a real one.
        if (this.critter !== null) {
          this.playerSession.writeToZig(`STAT:critter=${this.critter}\n`);
        }
        if (this.led !== null) {
          const hex = this.led.map((c) => c.toString(16).padStart(6, "0"));
          this.playerSession.writeToZig(`STAT:led=${hex.join(",")}\n`);
        }
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

    if (line.startsWith("CTRL:LED_ACK ")) {
      // Palette banked on the board (again, the ack follows its flash save):
      // stop retrying and let the onboarding screen move on.  Stale acks (an
      // earlier roll's retries) are ignored.
      const arg = line.slice("CTRL:LED_ACK ".length).trim();
      if (this.palettePending !== null && arg === `g=${this.palettePending.gid}`) {
        console.log(`[ctrl] palette banked (uid=${this.uid}, ${arg})`);
        this.clearPaletteRetry(null); // null is the success reason; see below
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
   * Report a finished game's final team score — and the babies it hatched —
   * for the board to bank into its flash: GAME:SCORE retried until
   * CTRL:SCORE_ACK (or the bounded attempts run out). The board dedupes by
   * the id, so retries - and a replay across a relink - can never
   * double-bank. Every board that completes the encounter banks the SAME
   * hatch counts: each hatched baby is saved to every connected board.
   * @param {number} score  final team score (u32)
   * @param {number[]} hatched  babies hatched, per BabyType ordinal
   */
  sendScore(score, hatched) {
    if (!this.linked) return;
    const gid = nextScoreId();
    const counts = Array.from(
      { length: BABY_TYPE_COUNT },
      (_, i) => (hatched?.[i] ?? 0) >>> 0,
    );
    this.clearScoreRetry(); // a newer game's report supersedes any in flight
    this.scorePending = {
      line: `GAME:SCORE s=${score >>> 0} g=${gid} b=${counts.join(",")}`,
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

  /**
   * Stream one frame of the onboarding colour spin to the board's LEDs.
   *
   * Fire-and-forget by design: this runs ~20 times a second, so it carries no
   * id, expects no ack, keeps no state, and is never written to flash.  A
   * dropped frame is invisible, and if these simply stop arriving the board's
   * own 500ms timeout hands the LEDs back to the saved palette — there is no
   * "stop" message to lose.
   *
   * @param {string[]} colors  PALETTE_COLOR_COUNT six-digit hex colours
   */
  sendLive(colors) {
    if (!this.linked || !isPalette(colors)) return;
    this.write(`LED:LIVE c=${colors.join(",")}`);
  }

  /**
   * Commit the colours the spin landed on for the board to bank into flash:
   * LED:SET retried until CTRL:LED_ACK (or the bounded attempts run out).  The
   * board dedupes by the id, so retries — and a replay across a relink — can
   * never double-erase the sector.
   *
   * @param {string[]} colors  PALETTE_COLOR_COUNT six-digit hex colours
   * @param {(err: string | null) => void} done  called exactly once: null on
   *   ack, else a reason.  A superseding roll, or the board going away,
   *   settles the outstanding one as an error rather than leaving the
   *   onboarding screen waiting forever.
   */
  sendPalette(colors, done) {
    if (!isPalette(colors)) { done("bad_palette"); return; }
    if (!this.linked) { done("not_linked"); return; }
    const gid = nextPaletteId();
    this.clearPaletteRetry("superseded"); // a newer roll supersedes any in flight
    this.palettePending = {
      line: `LED:SET c=${colors.join(",")} g=${gid}`,
      gid,
      attempts: 0,
      done,
    };
    const attempt = () => {
      const p = this.palettePending;
      if (p === null) return;
      if (p.attempts >= PALETTE_RETRY_MAX) {
        console.warn(
          `[ctrl] palette never acked (uid=${this.uid}, g=${p.gid}); giving up`,
        );
        // Settled through clearPaletteRetry, not by calling p.done here: one
        // place decides that a roll is over, so there is no way to grow a
        // second path that settles it twice or not at all.
        this.clearPaletteRetry("no_ack");
        return;
      }
      p.attempts++;
      this.write(p.line);
    };
    this.paletteTimer = setInterval(attempt, PALETTE_RETRY_MS);
    attempt();
  }

  /**
   * Drop any in-flight LED:SET, settling its callback exactly once.
   *
   * This is the ONLY place a roll ends, which is what makes "settled exactly
   * once" checkable by reading one function: `null` banks it, a string fails
   * it, and omitting the argument means there was no roll to settle (the
   * pre-emptive clear in sendPalette, and close() on a board that was idle).
   *
   * @param {string | null} [reason]  null = acked, string = why it failed
   */
  clearPaletteRetry(reason) {
    if (this.paletteTimer !== null) clearInterval(this.paletteTimer);
    this.paletteTimer = null;
    const pending = this.palettePending;
    this.palettePending = null;
    if (pending !== null && reason !== undefined) pending.done(reason);
  }

  close() {
    this.closed = true;
    if (this.helloTimer !== null) clearInterval(this.helloTimer);
    if (this.hbTimer !== null) clearInterval(this.hbTimer);
    this.clearScoreRetry();
    // Unplugged mid-roll: settle the waiting onboarding screen so it can skip
    // this badge instead of hanging on an ack that can never arrive.
    this.clearPaletteRetry("unlinked");
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
    // Before READY/JOIN so the take_slot carries the board's stats.
    if (this.controller !== null) {
      this.writeToZig(`STAT:appetite=${this.controller.appetite}\n`);
      this.writeToZig(`STAT:babies=${this.controller.babies.join(",")}\n`);
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
        // Game just ended: bank the final team score — and the encounter's
        // hatched babies — on the board.
        if (score !== null) this.controller.sendScore(score, hatchedFromRender(msg));
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
   * @param {(() => void)} [hooks.boardsChanged]  the set of linked boards grew
   *   or shrank; the onboarding screen re-reads listLinked().  Optional: board
   *   players work fine without anyone watching.
   */
  constructor({ clientBin, pickRoom, roomJoined, roomLeft, isRoomAlive, moveLabels,
    boardsChanged }) {
    this.clientBin = clientBin;
    this.pickRoom = pickRoom;
    this.roomJoined = roomJoined;
    this.roomLeft = roomLeft;
    this.isRoomAlive = isRoomAlive;
    this.moveLabels = moveLabels;
    this.onBoardsChanged = boardsChanged ?? (() => {});
    /** @type {Map<string, Controller>} port path -> controller */
    this.controllers = new Map();
    this.scanTimer = null;
  }

  /** A board linked or went away. */
  boardsChanged() {
    this.onBoardsChanged();
  }

  /**
   * Every board currently linked, in link order — which is the order the
   * onboarding screen rolls them in.
   * @returns {{ linkId: number, uid: string }[]}
   */
  listLinked() {
    return [...this.controllers.values()]
      .filter((c) => c.linked)
      .sort((a, b) => a.linkId - b.linkId)
      .map((c) => ({ linkId: c.linkId, uid: c.uid }));
  }

  /**
   * Resolve a link id to its board, or null if that link is gone.  Returning
   * null IS the unplugged case — callers skip it and move on.
   * @param {number} linkId
   * @returns {Controller | null}
   */
  linkedById(linkId) {
    for (const c of this.controllers.values()) {
      if (c.linked && c.linkId === linkId) return c;
    }
    return null;
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
    const wasLinked = ctrl.linked;
    ctrl.playerSession = null;
    ctrl.close();
    this.controllers.delete(ctrl.path);
    console.log(`[ctrl] dropped ${ctrl.path} (uid=${ctrl.uid})`);
    if (player) {
      player.controller = null;
      player.destroy("controller disconnected");
    }
    // After the teardown, so a watcher re-reading listLinked() sees the
    // settled world rather than a half-dismantled one.
    if (wasLinked) this.boardsChanged();
  }
}

module.exports = {
  Controller,
  ControllerManager,
  ControllerSession,
  shapeFromRender,
  finalScoreFromRender,
};
