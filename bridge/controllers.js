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
 *                                seed=<u32 hex> powerups=<a[,b,...]>
 *                                              persistent flash stats, sent
 *                                              once after CTRL:HELLO; appetite
 *                                              feeds the player's hunger
 *                                              capacity, babies (per BabyType,
 *                                              ordinal order) join the game
 *                                              with their owner, and critter +
 *                                              led are what that player's Lil
 *                                              Guy looks like on the shared
 *                                              screen.  seed is the badge's
 *                                              brood seed, which is what its
 *                                              BABIES look like: the renderer
 *                                              rolls one palette per badge
 *                                              from it.  powerups is what the
 *                                              badge CARRIES (one count per
 *                                              powerup kind, ordinal order),
 *                                              handed out at the /powerups
 *                                              kiosk; the badge only counts
 *                                              them, this side decides what
 *                                              holding one means.  Every key
 *                                              but appetite is absent on old
 *                                              firmware; each falls back on
 *                                              its own.
 *                      CTRL:SCORE_ACK g=<u32>  score banked to flash (sent
 *                                              AFTER the save; re-sent on retries)
 *                      CTRL:LED_ACK g=<u32>    palette banked to flash, on
 *                                              exactly the same terms
 *                      CTRL:POWERUP_ACK g=<u32> p=<a[,b,...]>
 *                                              powerup banked to flash, same
 *                                              terms again, and carrying the
 *                                              RESULTING counts — the kiosk
 *                                              shows a number going up, and
 *                                              the badge's own copy is the
 *                                              only one that cannot drift
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
 *                      POWERUP:GRANT k=<0..N-1> g=<u32>
 *                                              add ONE powerup of kind k to
 *                                              the badge's permanent
 *                                              inventory, from the /powerups
 *                                              kiosk.  g = per-grant id;
 *                                              retried every 1s until acked,
 *                                              bounded.  An INCREMENT, not a
 *                                              total: the badge's count is
 *                                              the only copy that matters, so
 *                                              its dedupe on g — not any
 *                                              bookkeeping here — is what
 *                                              stops a retry granting twice.
 *
 * Unknown lines in either direction are ignored (the board emits unrelated
 * sibling-link chatter like "dev cnt=..." until the link is established).
 *
 * Player model: every linked board IS a player — it gets its own headless
 * ControllerSession (dedicated Zig client + server connection) in the active
 * lobby, which takes one of the game's four seats (JOIN after READY).  Not
 * the instant it links, though: it becomes a player once it has reported its
 * flash stats (CTRL:STAT, see Controller.statSeen), because the server
 * freezes a player's stats when they take their seat and a board seated
 * before it has spoken is stuck at defaults for the whole game.  A
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

// Powerup kinds a badge can carry, in the ordinal order that IS their flash
// and wire identity — must match the firmware's powerup_kind_t
// (board/src/game/types.h) and the kiosk's button list (web/powerups.js).
// Three copies with no codegen between them, exactly as BABY_TYPE_COUNT
// already is; appending is safe, reordering is not.
const POWERUP_KIND_COUNT = 1;

// Display names for those ordinals, for the operator console. Used nowhere
// that matters to the protocol — the wire carries the ordinal — so a name may
// be improved freely.
const POWERUP_NAMES = ["neutralizer canister"];

// The badge's per-kind ceiling: firmware stores each count in a u8 and
// SATURATES rather than wrapping (board/src/store/store.h POWERUP_COUNT_MAX),
// so a count above this did not come from a badge and never will.
const POWERUP_COUNT_MAX = 255;

/**
 * Parse a badge's powerup counts, "a,b,c", into POWERUP_KIND_COUNT u8s.
 *
 * Rejects the whole list on a miscount rather than padding or truncating: a
 * badge running firmware that knows a different number of kinds is reporting
 * counts this side cannot align to ordinals, and a silently shifted list
 * would read as the wrong powerup rather than as nothing.
 *
 * @returns {number[] | null} null when malformed or miscounted
 */
function parsePowerupList(text) {
  const parts = text.split(",");
  if (parts.length !== POWERUP_KIND_COUNT) return null;
  const counts = [];
  for (const p of parts) {
    if (!/^\d+$/.test(p.trim())) return null;
    const n = Number(p.trim());
    if (n > POWERUP_COUNT_MAX) return null;
    counts.push(n >>> 0);
  }
  return counts;
}

const { SerialPort } = require("serialport");
const { ReadlineParser } = require("@serialport/parser-readline");
const { PlayerSession } = require("./session");
const { NULL_LEDGER, stamp } = require("./ledger");

// USB identity of the dc_rp2040 firmware (usb_descriptors.c).
const VENDOR_ID = "cafe";
const PRODUCT_ID = "4001";

const BAUD_RATE = 115200;
const SCAN_INTERVAL_MS = 2000;
const HELLO_INTERVAL_MS = 1000;
const HB_INTERVAL_MS = 1000;
// How long a freshly linked board is given to send its one-per-link
// CTRL:STAT before it is made a player anyway (Controller.statSeen).  The
// board arms that report at link-up and emits it on its next task tick, so
// this is orders of magnitude more than the happy path needs; it is sized to
// be unmissable for a board that is merely slow, and short enough that a
// board which will never report is not left standing at the door.  Below
// LINK_TIMEOUT_MS, so a board whose link is already dying is dropped rather
// than seated blind.
const STAT_WAIT_MS = 1000;
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
// POWERUP:GRANT retry cadence and cap, on the palette's reasoning again: the
// board parks its renderer around the flash erase, and the /powerups kiosk is
// waiting on the ack to show the new count. Giving up is safe here BECAUSE
// the board dedupes on the grant id — an ack lost after the save still leaves
// the powerup granted, so the worst case of exhausting the cap is a kiosk
// that reports a failure for a badge that in fact got it. Under-granting is
// impossible; over-granting is what the cap and the dedupe together prevent.
const POWERUP_RETRY_MS = 1000;
const POWERUP_RETRY_MAX = 5;

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

// Grant ids for POWERUP:GRANT, on those same terms — and here uniqueness is
// load-bearing rather than merely tidy, because the board's dedupe on this id
// is the ONLY thing standing between a retry and a second powerup. Two boards
// granted in the same millisecond get different ids (the +1 branch), and a
// bridge restarted within the same millisecond as its last grant cannot
// reissue one, because the clock is what seeds it.
let lastPowerupId = 0;
function nextPowerupId() {
  const t = Date.now() >>> 0;
  lastPowerupId = t > lastPowerupId ? t : (lastPowerupId + 1) >>> 0;
  return lastPowerupId;
}

// Identifies one LINK, not one board.  The /onboard screen addresses badges by
// this and nothing else, which is what makes its queue correct: a badge that
// is unplugged and replugged is a new link and so is rolled again, while a
// badge that just sits there keeps its id and is rolled once.  It also means a
// queued command can never land on a board that was swapped underneath it —
// the id simply stops resolving.
let lastLinkId = 0;

// Per-game id for the ledger.  All three parts earn their place:
//
//   the room code — but only that, and it is not an identity: codes are unique
//     among LIVE rooms (uniqueCode in index.js checks the registry, nothing
//     more) and are reissued once a lobby dies, so two games a night apart can
//     share one;
//   the timestamp — which separates those two, and orders the games directory
//     usefully when it is listed;
//   the counter — because the timestamp is only millisecond-resolved, and a
//     RESTART mints the next game the instant the last one closed.  Without it
//     two games can collide, and a collision here does not merely confuse a
//     reader: the second game's file is written over the first's, and a record
//     that silently loses records is worse than no record.
//
// The counter resets on a bridge restart, which is harmless — a restart takes
// far longer than the millisecond the timestamp would have to match.
let lastGameSeq = 0;
function nextGameId(roomCode) {
  return `${stamp()}-${roomCode}-${++lastGameSeq}`;
}

/**
 * A board's REPORTED state as plain JSON.
 *
 * ONE definition, on Controller.statLines's terms and for the same reason: it
 * has three consumers now — /api/dev/boards, the ledger's badge record and the
 * ledger's per-game roster — and three hand-rolled copies of "which fields are
 * a badge's state" is three chances for a field to be added to two of them.
 *
 * `critter`, `colors` and `seed` are null when the board has not reported
 * them, which is a state distinct from any value: see the CTRL:STAT handler.
 *
 * @param {Controller} ctrl
 */
function boardStateView(ctrl) {
  return {
    appetite: ctrl.appetite,
    babies: [...ctrl.babies],
    powerups: [...ctrl.powerups],
    critter: ctrl.critter,
    colors: ctrl.led === null
      ? null
      : ctrl.led.map((c) => c.toString(16).padStart(6, "0")),
    seed: ctrl.broodSeed === null
      ? null
      : ctrl.broodSeed.toString(16).padStart(8, "0"),
  };
}

/** One physical board on a serial port. */
class Controller {
  /**
   * @param {string} path
   * @param {string} uid  USB serial number (flash unique ID)
   * @param {ControllerManager} manager
   * @param {"serial" | "path"} [uidSource]  where `uid` came from.  A serial
   *   number is the board's flash unique id and so identifies a BADGE; the
   *   port-path fallback identifies a PORT, which the next badge plugged into
   *   it inherits.  Only the ledger cares, and only so that its records can
   *   say which kind of claim they rest on.  Defaults to the weaker of the
   *   two, so a caller that does not know cannot accidentally assert identity.
   */
  constructor(path, uid, manager, uidSource = "path") {
    this.path = path;
    this.uid = uid;
    this.uidSource = uidSource;
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
    /** The badge's brood seed (CTRL:STAT) as a u32, or null until it says.
     *  The one number that names the colours this badge's BABY Lil Guys wear;
     *  the renderer rolls the actual palette from it (web/palette.js
     *  rollBroodPalette).  Not a colour, and deliberately so: the badge's own
     *  panel is 1bpp, so it has no reason to own an opinion about the shade,
     *  and a seed is the whole brood in four bytes with nothing in flash. */
    this.broodSeed = null;
    /** Powerups this badge CARRIES (CTRL:STAT, then every CTRL:POWERUP_ACK),
     *  per powerup kind ordinal; zeros until it says.
     *
     *  Mirrored from the badge rather than counted here, and re-read from
     *  every ack: the badge's flash is the only copy, it saturates at 255,
     *  and it survives a bridge restart the way nothing on this side does. */
    this.powerups = new Array(POWERUP_KIND_COUNT).fill(0);
    /** Whether this board's one-per-link CTRL:STAT has been accounted for.
     *
     *  This board does not become a player until it has (see
     *  ControllerManager.assign), because a player is built in one
     *  synchronous burst — assign -> makePlayer -> spawnZig -> onZigSpawned —
     *  and everything that burst knows about the board is whatever arrived
     *  BEFORE it.  CTRL:HELLO and CTRL:STAT are two separate serial lines and
     *  the stats are always the later one, so building the player on HELLO
     *  built it blind: appetite 0, no babies, no critter, no palette.
     *
     *  Set by the CTRL:STAT handler, or by statTimer giving up on a board
     *  that is never going to send one. */
    this.statSeen = false;
    /** Deadline for the above, armed at link-up; null when not waiting. */
    this.statTimer = null;
    this.lastShape = null; // last FB:SHAPE payload sent (dedupe)
    /** Last GAME:PHASE activity sent (boolean), or null before the first. */
    this.lastActive = null;
    this.helloTimer = null;
    this.hbTimer = null;
    /** In-flight GAME:SCORE ({ line, gid, attempts, gameId }), or null. */
    this.scorePending = null;
    this.scoreTimer = null;
    /** In-flight LED:SET ({ line, gid, attempts, done }), or null. */
    this.palettePending = null;
    this.paletteTimer = null;
    /** In-flight POWERUP:GRANT ({ line, gid, attempts, done }), or null. */
    this.powerupPending = null;
    this.powerupTimer = null;
    this.closed = false;
  }

  open() {
    const port = new SerialPort(
      { path: this.path, baudRate: BAUD_RATE },
      (err) => {
        if (err) {
          console.error(`[ctrl] open failed (${this.path}):`, err.message);
          this.manager.dropController(this, "open_failed");
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
      this.manager.dropController(this, "unplugged");
    });
    port.on("error", (err) => {
      console.error(`[ctrl] port error (${this.path}):`, err.message);
      this.manager.dropController(this, "port_error");
    });
  }

  write(line) {
    if (this.port && this.port.isOpen) {
      this.port.write(line + "\n");
    }
  }

  /**
   * This board's flash stats as stdio lines for its player's Zig client.
   *
   * ONE definition, used by both delivery points: `onLine`'s CTRL:STAT
   * handler and ControllerSession.onZigSpawned.  They exist because neither
   * alone is sufficient - the board reports once per link, typically before
   * the player's Zig process is spawned (so the write would be dropped), and
   * onZigSpawned replays whatever is known by the time it is running.  When
   * the two disagreed about which stats to send, the ones only listed in the
   * handler silently never arrived, and every Lil Guy on the field rendered
   * in its authored greys.
   *
   * Critter, led and seed are OMITTED when the board has not reported them,
   * rather than sent as a default.  The client's "unreported" is a distinct
   * state from any value that could stand in for it.
   *
   * Powerups are NOT omitted: they ride with appetite and babies, always
   * sent.  There is no "unreported" state for them - a board that has never
   * been granted anything genuinely carries none, and the server needs the
   * count either way to size the charge grant it makes on the player's
   * behalf.  `this.powerups` starts at all zeros and is only ever replaced by
   * a full list the badge itself reported, so this line is never a guess.
   *
   * @returns {string[]} newline-terminated lines, in read order
   */
  statLines() {
    const lines = [
      `STAT:appetite=${this.appetite}\n`,
      `STAT:babies=${this.babies.join(",")}\n`,
      `STAT:powerups=${this.powerups.join(",")}\n`,
    ];
    if (this.critter !== null) lines.push(`STAT:critter=${this.critter}\n`);
    if (this.led !== null) {
      const hex = this.led.map((c) => c.toString(16).padStart(6, "0"));
      lines.push(`STAT:led=${hex.join(",")}\n`);
    }
    if (this.broodSeed !== null) {
      lines.push(`STAT:seed=${this.broodSeed.toString(16).padStart(8, "0")}\n`);
    }
    return lines;
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
        // Opens the ledger's connection record.  Deliberately BEFORE any stats
        // exist: CTRL:STAT is a separate, later serial line, so the record is
        // a lifecycle (opened here, stat-stamped below, closed in
        // dropController) rather than one write that would have to either be
        // empty or wait on a report that may never come.
        this.manager.ledger.badgeLinked({
          uid: this.uid,
          uidSource: this.uidSource,
          port: this.path,
          link: this.linkId,
        });
        this.hbTimer = setInterval(() => {
          this.write("GAME:HB");
          if (Date.now() - this.lastRxMs > LINK_TIMEOUT_MS) {
            console.warn(`[ctrl] heartbeat timeout ${this.path}`);
            this.manager.dropController(this, "heartbeat_timeout");
          }
        }, HB_INTERVAL_MS);
        // Held back until CTRL:STAT lands (statSeen); this call covers the
        // rest of the assignment pass, not this board.
        this.manager.assign();
        // Old firmware predates CTRL:STAT entirely, and any single line is
        // best-effort over serial, so waiting for one cannot be unconditional
        // or such a board would never play at all.  It joins blind instead,
        // which is the degradation controller.c already documents.
        this.statTimer = setTimeout(() => {
          this.statTimer = null;
          if (this.closed || this.statSeen) return;
          console.warn(
            `[ctrl] no CTRL:STAT from ${this.path} in ${STAT_WAIT_MS}ms; ` +
            `joining at defaults (no appetite, babies, critter or palette)`);
          this.statSeen = true;
          // Recorded, flagged as NOT a badge report: the state below is this
          // side's defaults, and a record that did not distinguish them from a
          // badge that genuinely carries nothing would be a record of a
          // fiction.
          this.manager.ledger.badgeStat({
            uid: this.uid,
            link: this.linkId,
            state: boardStateView(this),
            statReported: false,
            // NOT "badge".  Nothing here came from one — the badge stayed
            // silent and these are this side's defaults.  `statReported` says
            // so too, but a `source` of "badge" sitting next to it is the
            // exact kind of small lie this file exists to not tell.
            source: "timeout",
          });
          this.manager.assign();
        }, STAT_WAIT_MS);
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
        const seed = arg.match(/^seed=([0-9a-fA-F]{1,8})$/);
        if (seed !== null) {
          // No zero-is-absent rule here, unlike led: the seed is derived from
          // the flash uid rather than stored, so a badge that has one always
          // has one, and 0 is as good a seed as any other.
          this.broodSeed = parseInt(seed[1], 16) >>> 0;
          known = true;
          continue;
        }
        const powerups = arg.match(/^powerups=([\d,]+)$/);
        if (powerups !== null) {
          const counts = parsePowerupList(powerups[1]);
          if (counts !== null) {
            this.powerups = counts;
            known = true;
          }
          continue;
        }
      }
      if (!known) {
        console.warn(`[ctrl] unknown stat line '${line}' from ${this.path}`);
        return;
      }
      // Logged rather than left to inference: this report is sent once per
      // link and nothing downstream ever asks again, so when it goes missing
      // the only symptom is a player who quietly looks and eats like the
      // defaults.  A board that firmware once dropped whole (its line did not
      // fit the cdc fifo) looked exactly like a board with nothing to say.
      console.log(
        `[ctrl] stat ${this.path} (appetite=${this.appetite}, ` +
        `babies=${this.babies.join(",")}, ` +
        `critter=${this.critter === null ? "unreported" : this.critter}, ` +
        `led=${this.led === null ? "unset" : this.led
          .map((c) => c.toString(16).padStart(6, "0")).join(",")}, ` +
        `seed=${this.broodSeed === null ? "unreported"
          : this.broodSeed.toString(16).padStart(8, "0")}, ` +
        `powerups=${this.powerups.join(",")})`);
      // Forward to the player; the stats only count if they land before the
      // seat is taken (the server freezes the share at count time).  Usually
      // a no-op: the board reports once per link, which is normally before
      // its player process exists, and onZigSpawned is what actually delivers
      // them.  This covers the board that re-reports while already seated.
      if (this.playerSession !== null) {
        for (const l of this.statLines()) this.playerSession.writeToZig(l);
      }
      // Stamps the ledger's open connection record with what the badge said.
      this.manager.ledger.badgeStat({
        uid: this.uid,
        link: this.linkId,
        state: boardStateView(this),
        statReported: true,
        source: "badge",
      });
      // Release the assignment gate: this board can now be made a player
      // that knows what it is.  Idempotent — a board that re-reports while
      // already seated has a playerSession, so assign passes over it.
      if (this.statTimer !== null) {
        clearTimeout(this.statTimer);
        this.statTimer = null;
      }
      this.statSeen = true;
      this.manager.assign();
      return;
    }

    if (line.startsWith("CTRL:SCORE_ACK ")) {
      // Banked on the board (the ack is sent after its flash save): stop
      // retrying. Stale acks (an earlier report's retries) are ignored.
      const arg = line.slice("CTRL:SCORE_ACK ".length).trim();
      if (this.scorePending !== null && arg === `g=${this.scorePending.gid}`) {
        console.log(`[ctrl] score banked (uid=${this.uid}, ${arg})`);
        this.manager.ledger.scoreBanked({
          gameId: this.scorePending.gameId,
          uid: this.uid,
          link: this.linkId,
          gid: this.scorePending.gid,
        });
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

    if (line.startsWith("CTRL:POWERUP_ACK ")) {
      // Granted and banked on the board. The ack carries the badge's
      // RESULTING counts, so this is also where the mirror is refreshed —
      // including for the saturated badge, whose numbers do not move.
      const arg = line.slice("CTRL:POWERUP_ACK ".length).trim();
      const m = arg.match(/^g=(\d+) p=([\d,]+)$/);
      if (m === null) {
        console.warn(`[ctrl] malformed powerup ack '${line}' from ${this.path}`);
        return;
      }
      const counts = parsePowerupList(m[2]);
      if (counts === null) {
        // A count list this side cannot align to its own ordinals is worse
        // than no list: the mirror keeps the last good one and the grant is
        // left to time out, so the kiosk reports a failure rather than a
        // confident wrong number.
        console.warn(
          `[ctrl] powerup ack with unreadable counts '${line}' from ${this.path}`);
        return;
      }
      // Recorded even for a stale ack (an earlier grant's retries): the
      // counts are the badge's own and are news whichever grant produced
      // them. Only the settling below is gated on the id.
      this.powerups = counts;
      if (this.powerupPending !== null &&
          Number(m[1]) === this.powerupPending.gid) {
        console.log(
          `[ctrl] powerup banked (uid=${this.uid}, g=${m[1]}, ` +
          `powerups=${counts.join(",")})`);
        this.clearPowerupRetry(null); // null is the success reason
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
   * @param {string | null} [gameId]  the ledger's id for the game this score
   *   ends, carried on the pending report so the ack — which lands seconds
   *   later, on the serial line, long after the render frame that knew which
   *   game it was — can still be filed against it.  Null when unknown; the
   *   hardware path does not depend on it.
   */
  sendScore(score, hatched, gameId = null) {
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
      gameId,
    };
    this.manager.ledger.scoreDelivered({
      gameId,
      uid: this.uid,
      link: this.linkId,
      gid,
      score: score >>> 0,
      hatched: counts,
    });
    const attempt = () => {
      const p = this.scorePending;
      if (p === null) return;
      if (p.attempts >= SCORE_RETRY_MAX) {
        console.warn(
          `[ctrl] score never acked (uid=${this.uid}, g=${p.gid}); giving up`,
        );
        // Not proof the badge lacks the score: the ack may have been lost
        // after the save, exactly as the powerup cap's comment describes.
        // Recorded as an unanswered delivery, which is all this side knows.
        this.manager.ledger.scoreFailed({
          gameId: p.gameId,
          uid: this.uid,
          link: this.linkId,
          gid: p.gid,
          reason: "no_ack",
        });
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

  /**
   * Hand this badge ONE powerup of `kind` to keep: POWERUP:GRANT retried
   * until CTRL:POWERUP_ACK (or the bounded attempts run out).
   *
   * The grant id is what makes the retries safe. This side deliberately does
   * NOT keep its own running total to add to — the badge's flash is the only
   * copy, and an increment the badge dedupes is the one shape that survives
   * a retry, a relink and a bridge restart without either end having to know
   * what the other thinks the count is.
   *
   * One in flight per board: a second grant to a badge still waiting on the
   * first supersedes it, on the palette's terms. That is a kiosk mash rather
   * than a lost powerup — the superseded one may well already be in flash,
   * which is exactly why its callback settles as an error rather than a
   * silent success. The counts in the next ack are the truth either way.
   *
   * @param {number} kind  powerup ordinal, 0..POWERUP_KIND_COUNT-1
   * @param {(err: string | null) => void} done  called exactly once: null on
   *   ack, else a reason.
   */
  sendPowerup(kind, done) {
    if (!Number.isInteger(kind) || kind < 0 || kind >= POWERUP_KIND_COUNT) {
      done("bad_kind");
      return;
    }
    if (!this.linked) { done("not_linked"); return; }
    const gid = nextPowerupId();
    this.clearPowerupRetry("superseded");
    this.powerupPending = {
      line: `POWERUP:GRANT k=${kind} g=${gid}`,
      gid,
      attempts: 0,
      done,
    };
    const attempt = () => {
      const p = this.powerupPending;
      if (p === null) return;
      if (p.attempts >= POWERUP_RETRY_MAX) {
        console.warn(
          `[ctrl] powerup never acked (uid=${this.uid}, g=${p.gid}); giving up`,
        );
        this.clearPowerupRetry("no_ack");
        return;
      }
      p.attempts++;
      this.write(p.line);
    };
    this.powerupTimer = setInterval(attempt, POWERUP_RETRY_MS);
    attempt();
  }

  /**
   * Drop any in-flight POWERUP:GRANT, settling its callback exactly once —
   * the single place a grant ends, on clearPaletteRetry's terms.
   *
   * @param {string | null} [reason]  null = acked, string = why it failed,
   *   absent = there was no grant to settle
   */
  clearPowerupRetry(reason) {
    if (this.powerupTimer !== null) clearInterval(this.powerupTimer);
    this.powerupTimer = null;
    const pending = this.powerupPending;
    this.powerupPending = null;
    if (pending !== null && reason !== undefined) pending.done(reason);
  }

  close() {
    this.closed = true;
    if (this.helloTimer !== null) clearInterval(this.helloTimer);
    if (this.hbTimer !== null) clearInterval(this.hbTimer);
    if (this.statTimer !== null) clearTimeout(this.statTimer);
    this.statTimer = null;
    this.clearScoreRetry();
    // Unplugged mid-roll: settle the waiting onboarding screen so it can skip
    // this badge instead of hanging on an ack that can never arrive.
    this.clearPaletteRetry("unlinked");
    // Same for a grant in flight. Note this does NOT mean the powerup was not
    // granted — the badge may have banked it and been unplugged before the
    // ack — so the kiosk reports it as unknown-for-this-badge, and the next
    // link's CTRL:STAT settles the question with the badge's own count.
    this.clearPowerupRetry("unlinked");
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
    /** Ledger game id this board has already been recorded as SEATED in, or
     *  null.  Keyed by game rather than a boolean so that the next game in the
     *  same room — a RESTART — records the seat again. */
    this.seatedIn = null;
    /** Same, for having been recorded as an observer (the game was full). */
    this.observingIn = null;
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
    // Before READY/JOIN so the take_slot carries the board's stats — the
    // server freezes them at seat time, and this is the delivery that
    // actually lands (see Controller.statLines).
    if (this.controller !== null) {
      for (const line of this.controller.statLines()) this.writeToZig(line);
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
        this.noteGame(msg);
        // Game just ended: bank the final team score — and the encounter's
        // hatched babies — on the board.  The game id is read BEFORE closing,
        // because every board in the room reaches this edge and only the first
        // closes the record — but all of them still have a score to deliver
        // against it.
        if (score !== null) {
          const hatched = hatchedFromRender(msg);
          const gameId = this.manager.gameIdFor(this.room);
          this.manager.closeGame(this.room, score, msg.stats ?? null, hatched);
          this.controller.sendScore(score, hatched, gameId);
        }
      }
    } else {
      console.warn(`[bridge] unknown Zig frame tag (${this.label}):`, msg.tag);
    }
  }

  /**
   * Keep the ledger's picture of the room's current game up to date from this
   * board's own render frames.
   *
   * Each board is its own headless client with its own frame stream, so four
   * boards in one game see the same events four times.  The de-duplication
   * lives one level up (ControllerManager.openGame is per ROOM), and what is
   * per-board here is only this board's standing in that game.
   *
   * Seat detection reads `game.observer` — the flag the client computes for
   * exactly this question — rather than comparing player_id against a copy of
   * the protocol's NO_PLAYER sentinel kept on this side.  A frame that carries
   * neither is left alone rather than guessed at.
   */
  noteGame(msg) {
    const game = msg.game;
    if (msg.phase !== "game" || !game) return;
    const gameId = this.manager.openGame(this.room, game.encounter ?? "");
    if (gameId === null) return;

    if (game.observer === false) {
      if (this.seatedIn === gameId) return;
      this.seatedIn = gameId;
      this.manager.ledger.badgeSeated({
        gameId,
        uid: this.controller.uid,
        link: this.controller.linkId,
        playerId: game.player_id ?? null,
        state: boardStateView(this.controller),
      });
    } else if (game.observer === true) {
      if (this.observingIn === gameId) return;
      this.observingIn = gameId;
      this.manager.ledger.badgeObserving({
        gameId,
        uid: this.controller.uid,
        link: this.controller.linkId,
      });
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
   * @param {object} [hooks.ledger]  the badge ledger (bridge/ledger.js).
   *   WRITE-ONLY by construction — nothing here reads from it, and nothing here
   *   may start to; see that file's header.  Defaults to NULL_LEDGER, which is
   *   what the hardware-free test harnesses run against.
   */
  constructor({ clientBin, pickRoom, roomJoined, roomLeft, isRoomAlive, moveLabels,
    boardsChanged, ledger }) {
    this.clientBin = clientBin;
    this.pickRoom = pickRoom;
    this.roomJoined = roomJoined;
    this.roomLeft = roomLeft;
    this.isRoomAlive = isRoomAlive;
    this.moveLabels = moveLabels;
    this.onBoardsChanged = boardsChanged ?? (() => {});
    this.ledger = ledger ?? NULL_LEDGER;
    /** @type {Map<string, Controller>} port path -> controller */
    this.controllers = new Map();
    this.scanTimer = null;
    /** Tail of the serialised powerup-grant queue (see grantPowerup). */
    this.grantQueue = Promise.resolve();
    /**
     * The game each room is currently playing, for the ledger.
     *
     * Keyed by the room OBJECT, not its code: a code only identifies a room
     * among the live ones (index.js's isRoomAlive compares object identity for
     * exactly this reason), and it is reissued once a lobby dies.  A WeakMap
     * because a room that has been garbage collected can have no more games,
     * so there is nothing to clean up and no way to leak.
     *
     * @type {WeakMap<object, { gameId: string, closed: boolean }>}
     */
    this.games = new WeakMap();
  }

  /**
   * The ledger id of the room's current game, minting one if the room has no
   * open game.  Idempotent per room, which is the point: every board in the
   * room reports the same game from its own frame stream.
   *
   * A CLOSED entry is left in place rather than deleted, so the boards that
   * reach the game-over edge after the first one can still name the game their
   * score belongs to.  The next game in that room (a RESTART) mints afresh
   * because the entry it finds is closed.
   *
   * @param {object} room  LobbyRoom
   * @param {string} encounter  the encounter label from the render frame
   * @returns {string | null} null when the room is no longer alive
   */
  openGame(room, encounter) {
    const open = this.games.get(room);
    if (open !== undefined && !open.closed) return open.gameId;
    if (!this.isRoomAlive(room)) return null;
    const gameId = nextGameId(room.code);
    this.games.set(room, { gameId, closed: false });
    this.ledger.gameOpened({ gameId, roomCode: room.code, encounter });
    return gameId;
  }

  /**
   * The room's current game id — open or just closed — or null if it has
   * never had one.  Read, never minted: callers on the game-over path want to
   * name the game that just ended, not start one.
   */
  gameIdFor(room) {
    return this.games.get(room)?.gameId ?? null;
  }

  /**
   * Close the room's game with its final score and the server's match report.
   * Idempotent: the first board to reach the game-over edge closes it and the
   * rest pass through, which is what turns four identical per-board edges into
   * one game record.
   */
  closeGame(room, score, stats, hatched) {
    const open = this.games.get(room);
    if (open === undefined || open.closed) return;
    open.closed = true;
    this.ledger.gameClosed({ gameId: open.gameId, score, stats, hatched });
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

  /**
   * Hand ONE powerup of `kind` to every linked badge, then report what each
   * of them now carries on this process's stdout.
   *
   * This is the /powerups kiosk's whole job. Two things about the targeting
   * are deliberate:
   *
   * Every LINKED board, not every open port. A board that is plugged in but
   * has not completed the CTRL:HELLO handshake has no link id, cannot be
   * addressed, and would silently drop the line; it is counted in the report
   * as skipped rather than pretended at. It is not waited for either — the
   * operator pressed a button and wants an answer, and a badge that links a
   * second later simply did not get this grant.
   *
   * Fan-out with no all-or-nothing: each badge settles on its own, and one
   * that never acks does not hold up or roll back the others. There is no
   * transaction to be had here anyway — the powerups are already in other
   * badges' flash by then.
   *
   * The stdout report is the point of the feature, not a debug aid, and it
   * prints each badge's counts as the BADGE reports them (from the ack), never
   * as this side's arithmetic.  It is no longer the ONLY record — the ledger
   * files the same pass durably (bridge/ledger.js) — but it remains the one an
   * operator standing at the kiosk actually reads, and it stays for that.
   *
   * Note that neither record is an inventory.  The badge's flash is still the
   * only place a count lives; both of these say "a grant happened, and here is
   * what the badge said it then held", which is a different claim.
   *
   * @param {number} kind  powerup ordinal, 0..POWERUP_KIND_COUNT-1
   * Grants are SERIALISED across callers: a second one waits for the first to
   * settle rather than superseding it board-by-board. A badge can only have
   * one grant in flight, and superseding one is genuinely ambiguous — the
   * superseded grant may already be in the badge's flash — so the one case
   * where that could happen (a double-pressed button, or two kiosk tabs) is
   * removed rather than reported. The wait is bounded by the retry cap.
   *
   * @param {number} kind  powerup ordinal, 0..POWERUP_KIND_COUNT-1
   * @returns {Promise<{kind: number, results: Array<{
   *   uid: string, linkId: number | null, ok: boolean,
   *   reason: string | null, powerups: number[]}>}>}
   *   Resolves once every targeted badge has settled. Never rejects: a badge
   *   that failed is a result with ok:false, because the kiosk has to show
   *   the other badges' new counts regardless.
   */
  grantPowerup(kind) {
    // Tail of the queue, never rejected (grantOne does not throw), so one
    // grant cannot poison every later one.
    this.grantQueue = this.grantQueue.then(() => this.grantOne(kind));
    return this.grantQueue;
  }

  /** One serialised grant pass. Call through grantPowerup, not directly. */
  async grantOne(kind) {
    if (!Number.isInteger(kind) || kind < 0 || kind >= POWERUP_KIND_COUNT) {
      console.warn(`[ctrl] powerup grant refused: no such kind ${kind}`);
      return { kind, results: [] };
    }
    const name = POWERUP_NAMES[kind] ?? `kind ${kind}`;
    const targets = [...this.controllers.values()]
      .filter((c) => c.linked)
      .sort((a, b) => a.linkId - b.linkId);
    const skipped = this.controllers.size - targets.length;

    console.log(
      `[ctrl] granting 1 ${name} to ${targets.length} badge(s)` +
      (skipped > 0 ? `; ${skipped} plugged but unlinked, skipped` : ""));

    const results = await Promise.all(targets.map((ctrl) =>
      new Promise((resolve) => {
        ctrl.sendPowerup(kind, (err) => resolve({
          uid: ctrl.uid,
          linkId: ctrl.linkId,
          ok: err === null,
          reason: err,
          // Read after settling, so a success carries the counts the ack
          // just delivered. A failure carries the last ones known, which
          // may predate the grant — the badge is the authority and it did
          // not answer.
          powerups: [...ctrl.powerups],
        }));
      })));

    const granted = results.filter((r) => r.ok).length;
    console.log(
      `[ctrl] powerups: ${granted}/${results.length} badge(s) banked 1 ${name}`);
    this.ledger.powerupGrantPass({
      kind, name, targets: results.length, granted, skipped,
    });
    for (const r of results) {
      const counts = r.powerups
        .map((n, i) => `${POWERUP_NAMES[i] ?? `kind ${i}`}=${n}`)
        .join(" ");
      console.log(
        `[ctrl]   uid=${r.uid} link=${r.linkId} ` +
        `${r.ok ? "ok" : `FAILED (${r.reason})`}  ${counts}`);
      this.ledger.powerupGranted({
        uid: r.uid,
        link: r.linkId,
        kind,
        name,
        ok: r.ok,
        reason: r.reason,
        powerups: r.powerups,
      });
    }
    return { kind, results };
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
      // A serial number is the board's flash unique id, so it identifies a
      // BADGE.  The path fallback identifies a PORT, and the next badge
      // plugged into it inherits the name — which the ledger has to be able to
      // say, or a shared port reads as one badge with a long history.
      const uid = p.serialNumber || p.path;
      const ctrl = new Controller(p.path, uid, this, p.serialNumber ? "serial" : "path");
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
      // Not until the board has said what it is (Controller.statSeen): the
      // player is built synchronously from here and carries whatever is known
      // at that instant, permanently — the server freezes a player's stats
      // when they take their seat.
      if (!ctrl.statSeen) continue;
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
   *
   * @param {Controller} ctrl
   * @param {string} [reason]  why, for the ledger's connection record: which
   *   of unplugged / port_error / heartbeat_timeout / open_failed happened is
   *   the difference between a player walking off with their badge and a badge
   *   whose link is failing while it sits in the port.
   */
  dropController(ctrl, reason = "dropped") {
    if (ctrl.closed) return;
    const player = ctrl.playerSession;
    const wasLinked = ctrl.linked;
    ctrl.playerSession = null;
    ctrl.close();
    this.controllers.delete(ctrl.path);
    console.log(`[ctrl] dropped ${ctrl.path} (uid=${ctrl.uid})`);
    // Closes the ledger's connection record, and only for a board that had one
    // — a port that never completed CTRL:HELLO opened nothing.  Same gate
    // boardsChanged uses below, for the same reason.
    if (wasLinked) {
      this.ledger.badgeUnlinked({ uid: ctrl.uid, link: ctrl.linkId, reason });
    }
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
  // One definition of "a board's reported state as JSON", shared by
  // /api/dev/boards and the ledger's badge and per-game records.
  boardStateView,
  // Shapes of a board's stats, for validating anything that rewrites them
  // (index.js's /api/dev routes) against the same constants the parser uses.
  BABY_TYPE_COUNT,
  PALETTE_COLOR_COUNT,
  POWERUP_KIND_COUNT,
  POWERUP_COUNT_MAX,
  POWERUP_NAMES,
  isPalette,
};
