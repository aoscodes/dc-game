// Harness for the board stat report (bridge/controllers.js: the CTRL:STAT
// parser, Controller.statLines, ControllerSession.onZigSpawned).
//
// This guards a DELIVERY property, and it exists because the delivery broke.
// A board reports its flash stats once per link — appetite, babies, its
// resident critter and its three LED colours — and the client folds them into
// the take_slot it sends when it takes a seat. There are two places that can
// forward them and neither is sufficient alone: the CTRL:STAT handler fires
// when the line arrives, which is normally before the player's Zig process
// exists (so the write is dropped), and onZigSpawned replays them once it
// does. When critter and led were added to the handler but not to the replay,
// they never reached a single player, and every Lil Guy on the shared screen
// rendered in its authored greys instead of its owner's colours. Nothing
// failed: an absent appearance is a legal state with a defined look.
//
// So the assertion that matters is not "the parser understands the line" but
// "everything the parser learned reaches the client, before it takes its
// seat". That is what is checked here.
//
// A Controller is constructed WITHOUT open()ing a serial port, same as
// link_harness, so this drives the real state machine with no hardware.
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { Controller, ControllerSession } =
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

const FULL = "CTRL:STAT appetite=7 babies=1,0,2,0,0 critter=3 " +
  "led=d4506e,7ac0a0,e8c46a";

// --- the parser ------------------------------------------------------------
{
  const ctrl = mkBoard();
  ctrl.onLine(FULL);
  eq(ctrl.appetite, 7, "appetite parsed");
  eq(ctrl.babies.join(","), "1,0,2,0,0", "babies parsed");
  eq(ctrl.critter, 3, "critter parsed");
  eq(JSON.stringify(ctrl.led), JSON.stringify([0xd4506e, 0x7ac0a0, 0xe8c46a]),
    "led parsed as packed u24s");
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
  check(sent.includes("STAT:critter=3\n"), "critter reaches the client");
  check(sent.includes("STAT:led=d4506e,7ac0a0,e8c46a\n"),
    "led reaches the client");

  // Stated as a count too, so a stat added to the report and forgotten here
  // shows up as a failure rather than passing by omission.
  eq(sent.length, 4, "every reported stat is forwarded and nothing else");

  // Hex is zero-padded per channel: "0a" must not collapse to "a", which
  // would shift every following digit and recolour the creature.
  const ctrl2 = mkBoard();
  ctrl2.onLine("CTRL:STAT appetite=0 babies=0,0,0,0,0 critter=0 " +
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
  const sent = stdinLines(ctrl);
  eq(sent.length, 2, "only the stats it actually has are forwarded");
  check(sent.includes("STAT:babies=0,0,0,0,0\n"),
    "babies default to none rather than going missing");
}

// --- a board with no stats yet ---------------------------------------------
//
// onZigSpawned runs whether or not CTRL:STAT has arrived. It must still send
// the two stats that have real defaults, so the client is never left waiting
// on a line that is not coming.
{
  const sent = stdinLines(mkBoard());
  eq(sent.length, 2, "a silent board still forwards its defaults");
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

if (failures > 0) {
  console.log(`stat: ${failures} failure(s)`);
  process.exit(1);
}
console.log("OK  stat: every reported board stat reaches the client before JOIN");
