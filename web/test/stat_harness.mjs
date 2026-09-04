// Harness for the board stat report (bridge/controllers.js: the CTRL:STAT
// parser, Controller.statLines, ControllerSession.onZigSpawned).
//
// This guards a DELIVERY property, and it exists because the delivery broke.
// A board reports its flash stats once per link — appetite, babies, its
// resident critter, its three LED colours and its brood seed — and the client
// folds them into
// the take_slot it sends when it takes a seat. There are two places that can
// forward them and neither is sufficient alone: the CTRL:STAT handler fires
// when the line arrives, which is normally before the player's Zig process
// exists (so the write is dropped), and onZigSpawned replays them once it
// does. When critter and led were added to the handler but not to the replay,
// they never reached a single player, and every Lil Guy on the shared screen
// rendered in its authored greys instead of its owner's colours. Nothing
// failed: an absent appearance is a legal state with a defined look.
//
// It broke a second time for the mirror-image reason: the replay was correct
// but ran too early. A player is built in one synchronous burst — assign ->
// makePlayer -> spawnZig -> onZigSpawned — kicked off by CTRL:HELLO, and
// CTRL:STAT is a separate, later serial line. The burst therefore knew
// nothing, and again nothing failed.
//
// So the assertion that matters is not "the parser understands the line" but
// "everything the parser learned reaches the client, before it takes its
// seat" — contents AND timing. Both are checked here.
//
// A Controller is constructed WITHOUT open()ing a serial port, same as
// link_harness, so this drives the real state machine with no hardware.
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { Controller, ControllerSession, ControllerManager } =
  require(new URL("../../bridge/controllers.js", import.meta.url).pathname);

let failures = 0;
function check(cond, what) {
  if (!cond) { failures++; console.log(`FAIL: ${what}`); }
}
function eq(a, b, what) {
  check(a === b, `${what} (got ${JSON.stringify(a)}, want ${JSON.stringify(b)})`);
}

/** An inert board: real parser and real state, stubbed transport. */
function mkBoard() {
  const manager = { assign() {}, boardsChanged() {}, dropController() {} };
  const ctrl = new Controller("/dev/fake", "uid1", manager);
  ctrl.write = () => {};
  ctrl.linked = true;
  return ctrl;
}

/**
 * A real ControllerManager over a real Controller, with the two things that
 * touch the outside world replaced: the serial port, and the spawn of a Zig
 * process.
 *
 * `makePlayer` is intercepted rather than run, but the interception is not a
 * restatement of it — it records WHEN assign decided to build a player, and
 * what that player's client would have read at that instant, by running the
 * real onZigSpawned. That is the whole property under test: a board becomes a
 * player exactly once, and it knows what it is by then.
 *
 * setTimeout is captured so the link-up deadline can be fired on demand
 * instead of waited out.
 */
function mkLinkedBoard({ withRoom = true } = {}) {
  const timers = [];
  const realSetTimeout = globalThis.setTimeout;
  globalThis.setTimeout = (fn, ms) => {
    const t = { fn, ms, cleared: false };
    timers.push(t);
    return t;
  };
  const realClearTimeout = globalThis.clearTimeout;
  globalThis.clearTimeout = (t) => { if (t) t.cleared = true; };

  /** Every makePlayer, as the stdin the new player's client would read. */
  const built = [];
  const room = { code: "TEST", port: 1 };
  const manager = new ControllerManager({
    clientBin: "/nonexistent",
    pickRoom: () => (withRoom ? room : null),
    roomJoined() {}, roomLeft() {}, isRoomAlive: () => true,
    moveLabels: () => [],
  });
  manager.makePlayer = (ctrl) => {
    ctrl.playerSession = { writeToZig() {} }; // occupied, as the real one does
    built.push(stdinLines(ctrl));
  };

  const ctrl = new Controller("/dev/fake", "uid1", manager);
  ctrl.write = () => {};
  manager.controllers.set(ctrl.path, ctrl);
  ctrl.onLine("CTRL:HELLO");

  return {
    ctrl,
    built,
    restore() {
      // close() before restoring, so the real heartbeat interval that link-up
      // started is cleared — otherwise it outlives the harness, times the
      // link out, and tears down a board nobody is holding any more.
      ctrl.close();
      globalThis.setTimeout = realSetTimeout;
      globalThis.clearTimeout = realClearTimeout;
    },
    /** Run the link-up deadline as if STAT_WAIT_MS had elapsed. */
    fireDeadline() {
      for (const t of timers) if (!t.cleared) t.fn();
    },
    pendingTimers: () => timers.filter((t) => !t.cleared).length,
  };
}

/**
 * The lines a board's player actually writes to its client's stdin, in order.
 *
 * Drives the REAL ControllerSession.onZigSpawned rather than restating what it
 * ought to send — the bug this file exists for was a divergence between two
 * lists of stats, so a third list here would be able to agree with the wrong
 * one and report success.
 */
function stdinLines(ctrl) {
  const sent = [];
  const session = Object.create(ControllerSession.prototype);
  session.controller = ctrl;
  session.writeToZig = (line) => { sent.push(line); };
  session.onZigSpawned();
  return sent;
}

const FULL = "CTRL:STAT appetite=7 babies=1,0,2,0,0 powerups=3 critter=3 " +
  "led=d4506e,7ac0a0,e8c46a seed=1f3c9a04";

// --- the parser ------------------------------------------------------------
{
  const ctrl = mkBoard();
  ctrl.onLine(FULL);
  eq(ctrl.appetite, 7, "appetite parsed");
  eq(ctrl.babies.join(","), "1,0,2,0,0", "babies parsed");
  eq(ctrl.powerups.join(","), "3", "powerups parsed");
  eq(ctrl.critter, 3, "critter parsed");
  eq(JSON.stringify(ctrl.led), JSON.stringify([0xd4506e, 0x7ac0a0, 0xe8c46a]),
    "led parsed as packed u24s");
  eq(ctrl.broodSeed, 0x1f3c9a04, "brood seed parsed as a u32");

  // The top of the range, where a parse that lands in a signed int32 turns
  // negative. The renderer feeds this straight to a PRNG, so a negative is
  // not a smaller number, it is a different family.
  const hi = mkBoard();
  hi.onLine("CTRL:STAT seed=ffffffff");
  eq(hi.broodSeed, 0xffffffff, "a top-of-range brood seed stays unsigned");
}

// --- the delivery that actually lands --------------------------------------
//
// THE regression test. Every stat the board reported has to be in the lines
// the client reads before it takes its seat; a stat that stops at the parser
// is a stat the game never sees.
{
  const ctrl = mkBoard();
  ctrl.onLine(FULL);
  const sent = stdinLines(ctrl);

  check(sent.includes("STAT:appetite=7\n"), "appetite reaches the client");
  check(sent.includes("STAT:babies=1,0,2,0,0\n"), "babies reach the client");
  check(sent.includes("STAT:powerups=3\n"), "powerups reach the client");
  check(sent.includes("STAT:critter=3\n"), "critter reaches the client");
  check(sent.includes("STAT:led=d4506e,7ac0a0,e8c46a\n"),
    "led reaches the client");
  check(sent.includes("STAT:seed=1f3c9a04\n"), "brood seed reaches the client");

  // Stated as a count too, so a stat added to the report and forgotten here
  // shows up as a failure rather than passing by omission.
  eq(sent.length, 6, "every reported stat is forwarded and nothing else");

  // Hex is zero-padded per channel: "0a" must not collapse to "a", which
  // would shift every following digit and recolour the creature.
  const ctrl2 = mkBoard();
  ctrl2.onLine("CTRL:STAT appetite=0 babies=0,0,0,0,0 powerups=0 critter=0 " +
    "led=000a0b,0c0d0e,0f1011");
  check(stdinLines(ctrl2).includes("STAT:led=000a0b,0c0d0e,0f1011\n"),
    "led channels stay zero-padded through the round trip");
}

// --- a board that never onboarded ------------------------------------------
//
// All-zero LEDs are the badge's factory state: no palette, NOT a palette of
// black. It must not reach the client as a colour, or the creature renders
// solid black instead of falling back to something legible.
{
  const ctrl = mkBoard();
  ctrl.onLine("CTRL:STAT appetite=2 babies=0,0,0,0,0 critter=1 " +
    "led=000000,000000,000000");
  eq(ctrl.led, null, "all-zero led is no palette");
  const sent = stdinLines(ctrl);
  check(!sent.some((l) => l.startsWith("STAT:led=")),
    "an un-onboarded board sends no palette at all");
  check(sent.includes("STAT:critter=1\n"),
    "...but its critter still travels — the board knows that regardless");
}

// --- a brood seed of zero --------------------------------------------------
//
// The rule that is NOT the led rule, and the reason the two are parsed
// differently. All-zero LEDs mean "never onboarded" because black is not a
// colour anyone rolls; a zero brood seed means zero, because it is derived
// from the flash uid rather than chosen and no value of it is reserved. Zero
// dropped as "unset" would hand one badge in four billion a grey brood.
{
  const ctrl = mkBoard();
  ctrl.onLine("CTRL:STAT seed=00000000");
  eq(ctrl.broodSeed, 0, "a zero brood seed is a seed");
  check(stdinLines(ctrl).includes("STAT:seed=00000000\n"),
    "...and it is forwarded, zero-padded, like any other");
}

// --- old firmware ----------------------------------------------------------
//
// Boards in the field predate every field but appetite. Unknown keys are
// ignored and missing ones stay absent, so an old badge still plays — with a
// hunger share and a default-looking creature.
{
  const ctrl = mkBoard();
  ctrl.onLine("CTRL:STAT appetite=5");
  eq(ctrl.appetite, 5, "old firmware's appetite is read");
  eq(ctrl.critter, null, "old firmware reports no critter");
  eq(ctrl.led, null, "old firmware reports no palette");
  eq(ctrl.broodSeed, null, "old firmware reports no brood seed");
  eq(ctrl.powerups.join(","), "0", "old firmware carries no powerups");
  const sent = stdinLines(ctrl);
  eq(sent.length, 3, "only the stats it actually has are forwarded");
  check(sent.includes("STAT:babies=0,0,0,0,0\n"),
    "babies default to none rather than going missing");
  check(sent.includes("STAT:powerups=0\n"),
    "...and so do powerups: carrying none is an ANSWER, not a silence");
}

// --- carrying nothing is not the same as saying nothing --------------------
//
// The rule that separates powerups from critter/led/seed. The cosmetic three
// are withheld when unreported, because the client draws something different
// for "unknown" than for any value. A powerup count has no such state: the
// server turns it into charges, and a missing line would leave the player
// holding whatever the previous STAT set — so zero must be SENT.
{
  const ctrl = mkBoard();
  ctrl.onLine("CTRL:STAT appetite=1 powerups=4");
  check(stdinLines(ctrl).includes("STAT:powerups=4\n"), "a full badge reports 4");

  ctrl.onLine("CTRL:STAT appetite=1 powerups=0");
  check(stdinLines(ctrl).includes("STAT:powerups=0\n"),
    "a badge that spent them down to zero says so, rather than going quiet");

  // A miscounted list is refused whole, same as a short led list: a partial
  // tally would silently zero the kinds it omitted.
  ctrl.onLine("CTRL:STAT powerups=1,2");
  eq(ctrl.powerups.join(","), "0", "a miscounted powerup list is refused");
}

// --- a board with no stats yet ---------------------------------------------
//
// onZigSpawned runs whether or not CTRL:STAT has arrived. It must still send
// the two stats that have real defaults, so the client is never left waiting
// on a line that is not coming.
{
  const sent = stdinLines(mkBoard());
  eq(sent.length, 3, "a silent board still forwards its defaults");
  check(sent.includes("STAT:appetite=0\n"), "default appetite forwarded");
}

// --- malformed input -------------------------------------------------------
//
// A garbled line must not half-apply. Nothing here should be able to leave a
// board wearing two of its three colours.
{
  const ctrl = mkBoard();
  ctrl.onLine(FULL);
  ctrl.onLine("CTRL:STAT led=d4506e,7ac0a0"); // two colours, not three
  eq(JSON.stringify(ctrl.led), JSON.stringify([0xd4506e, 0x7ac0a0, 0xe8c46a]),
    "a short led list leaves the previous palette standing");

  ctrl.onLine("CTRL:STAT critter=9"); // past the last BabyType
  eq(ctrl.critter, 3, "an out-of-range critter is refused, not clamped");
}

// --- the ORDER, not just the contents --------------------------------------
//
// THE regression test, part two. Everything above feeds the stat line first
// and then asks what the client reads, which is the one order a real board
// never uses. CTRL:HELLO and CTRL:STAT are two serial lines and the stats are
// always the later one, so a player built on HELLO is built blind — and it
// stays blind, because the server freezes a player's stats when they take
// their seat. Waiting is not an optimisation here, it is the only chance.
{
  const b = mkLinkedBoard();
  try {
    eq(b.built.length, 0,
      "a board that has not reported yet is NOT made a player");

    b.ctrl.onLine(FULL);
    eq(b.built.length, 1, "reporting makes it a player");
    const sent = b.built[0];
    check(sent.includes("STAT:critter=3\n") &&
      sent.includes("STAT:led=d4506e,7ac0a0,e8c46a\n") &&
      sent.includes("STAT:seed=1f3c9a04\n") &&
      sent.includes("STAT:appetite=7\n"),
      "the player is built knowing its stats, not after the fact");
    eq(b.pendingTimers(), 0, "the deadline is cancelled once the board reports");

    // Boards re-report; that must not seat them twice.
    b.ctrl.onLine(FULL);
    eq(b.built.length, 1, "a re-report does not build a second player");
  } finally { b.restore(); }
}

// --- a board that never reports --------------------------------------------
//
// Old firmware predates CTRL:STAT, and any one serial line can be lost.
// Waiting forever would mean such a board never plays at all, so the deadline
// seats it blind — worse stats, still a game.
{
  const b = mkLinkedBoard();
  try {
    eq(b.built.length, 0, "still waiting before the deadline");
    b.fireDeadline();
    eq(b.built.length, 1, "the deadline seats a silent board anyway");
    eq(b.built[0].length, 3, "...at defaults, with no invented appearance");

    // The deadline fired and gave up; a stat line arriving later must not
    // produce a second player for the same board.
    b.ctrl.onLine(FULL);
    eq(b.built.length, 1, "a late report does not build a second player");
  } finally { b.restore(); }
}

// --- no room yet -----------------------------------------------------------
//
// A board can link before any game exists. It waits for a room, and by then
// its stats have long arrived — the path that happened to work before, and
// must keep working.
{
  const b = mkLinkedBoard({ withRoom: false });
  try {
    b.ctrl.onLine(FULL);
    eq(b.built.length, 0, "no room, no player");
  } finally { b.restore(); }
}

if (failures > 0) {
  console.log(`stat: ${failures} failure(s)`);
  process.exit(1);
}
console.log("OK  stat: every reported board stat reaches the client before JOIN");
