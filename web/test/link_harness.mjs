// Harness for the bridge's side of the badge palette protocol
// (bridge/controllers.js: sendPalette / sendLive / CTRL:LED_ACK).
//
// This one guards a liveness property rather than a rules mirror: the
// onboarding kiosk blocks on a per-roll callback, so if that callback is ever
// dropped the kiosk hangs on a badge forever, and if it is ever called twice
// the kiosk skips the next badge without rolling it. "Settled exactly once,
// on every path" is therefore the whole contract, and the paths that settle it
// are the boring ones nobody exercises by hand: retries running out, a board
// unplugged mid-save, a second roll superseding the first.
//
// A Controller is constructed WITHOUT open()ing a serial port and its write()
// is stubbed, so this drives the real state machine with no hardware and no
// timers left running.
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { Controller, ControllerManager } =
  require(new URL("../../bridge/controllers.js", import.meta.url).pathname);

let failures = 0;
function check(cond, what) {
  if (!cond) { failures++; console.log(`FAIL: ${what}`); }
}
function eq(a, b, what) {
  check(a === b, `${what} (got ${JSON.stringify(a)}, want ${JSON.stringify(b)})`);
}

/** An inert linked board: real state machine, stubbed transport. */
function mkBoard(linkId = 1) {
  const manager = { assign() {}, boardsChanged() {}, dropController() {} };
  const ctrl = new Controller(`/dev/fake${linkId}`, `uid${linkId}`, manager);
  const sent = [];
  ctrl.write = (line) => { sent.push(line); };
  ctrl.linked = true;
  ctrl.linkId = linkId;
  /** Everything the roll's callback was told, in order. */
  const settled = [];
  return { ctrl, sent, settled, roll: (colors) => ctrl.sendPalette(colors, (e) => settled.push(e)) };
}

const RGB = ["ff0000", "00ff00", "0000ff"];
const gidOf = (line) => line.slice(line.indexOf("g=") + 2);

// --- the happy path --------------------------------------------------------
{
  const b = mkBoard();
  b.roll(RGB);
  eq(b.sent.length, 1, "the roll is written immediately, not on the first retry tick");
  check(b.sent[0].startsWith("LED:SET c=ff0000,00ff00,0000ff g="), `LED:SET wire form (${b.sent[0]})`);

  b.ctrl.onLine(`CTRL:LED_ACK ${"g=" + gidOf(b.sent[0])}`);
  eq(b.settled.length, 1, "the ack settles the roll exactly once");
  eq(b.settled[0], null, "and settles it as banked");
  eq(b.ctrl.palettePending, null, "the ack clears the pending roll");
  eq(b.ctrl.paletteTimer, null, "the ack stops the retry timer");
}

// --- acks that are not for this roll ---------------------------------------
{
  const b = mkBoard();
  b.roll(RGB);
  // The board dedupes on the id, so a retry of an EARLIER roll can still be
  // acked while a newer one is in flight. Acting on it would settle the wrong
  // roll and hand the kiosk a colour it never showed.
  b.ctrl.onLine("CTRL:LED_ACK g=1");
  eq(b.settled.length, 0, "a stale ack does not settle the current roll");
  check(b.ctrl.palettePending !== null, "a stale ack leaves the roll in flight");

  b.ctrl.onLine("CTRL:LED_ACK");        // no argument
  b.ctrl.onLine("CTRL:LED_ACK g=");     // empty argument
  b.ctrl.onLine("CTRL:SCORE_ACK g=1");  // the other protocol's ack
  eq(b.settled.length, 0, "malformed and foreign acks do not settle the roll");
  b.ctrl.clearPaletteRetry("cleanup");
}

// --- retries run out -------------------------------------------------------
{
  const b = mkBoard();
  b.roll(RGB);
  const gid = gidOf(b.sent[0]);
  // Drive the retry timer by hand rather than waiting out five real seconds.
  const tick = b.ctrl.paletteTimer._onTimeout;
  check(typeof tick === "function", "the retry timer is drivable");
  for (let i = 0; i < 20; i++) tick();

  check(b.sent.length >= 2, `the roll is retried (${b.sent.length} writes)`);
  check(b.sent.every((l) => gidOf(l) === gid),
    "every retry carries the SAME id, so the board dedupes instead of re-erasing");
  eq(b.settled.length, 1, "running out of retries settles the roll exactly once");
  eq(b.settled[0], "no_ack", "and settles it as a failure the kiosk can report");
  eq(b.ctrl.paletteTimer, null, "giving up stops the retry timer");

  // The kiosk has moved on; a late ack must not settle a second time.
  b.ctrl.onLine(`CTRL:LED_ACK g=${gid}`);
  eq(b.settled.length, 1, "an ack arriving after we gave up settles nothing");
}

// --- unplugged mid-save ----------------------------------------------------
{
  const b = mkBoard();
  b.roll(RGB);
  b.ctrl.close();
  eq(b.settled.length, 1, "closing the port settles the in-flight roll exactly once");
  eq(b.settled[0], "unlinked", "and settles it as unlinked, so the kiosk skips the badge");
  eq(b.ctrl.paletteTimer, null, "closing stops the retry timer");

  // close() is called from more than one place; it must stay idempotent.
  b.ctrl.close();
  eq(b.settled.length, 1, "closing twice does not settle twice");
}

// --- superseded ------------------------------------------------------------
{
  const b = mkBoard();
  b.roll(RGB);
  b.roll(["111111", "222222", "333333"]);
  eq(b.settled.length, 1, "a second roll settles the first exactly once");
  eq(b.settled[0], "superseded", "and says why");
  check(b.sent[1].includes("111111"), "the second roll is written");
  check(gidOf(b.sent[0]) !== gidOf(b.sent[1]), "the second roll carries a new id");
  b.ctrl.clearPaletteRetry("cleanup");
  eq(b.settled.length, 2, "the second roll is still settleable");
}

// --- refusals settle too ---------------------------------------------------
{
  const b = mkBoard();
  b.roll(["ff0000", "00ff00"]);            // too few
  b.roll(["ff0000", "00ff00", "xyzxyz"]);  // not hex
  b.roll(["ff0000", "00ff00", "0000"]);    // too short
  b.roll("ff0000,00ff00,0000ff");          // not an array
  eq(b.settled.length, 4, "every rejected palette still settles its roll");
  check(b.settled.every((r) => r === "bad_palette"), `all rejected as bad_palette (${b.settled})`);
  eq(b.sent.length, 0, "nothing malformed reaches the board");

  const gone = mkBoard();
  gone.ctrl.linked = false;
  gone.roll(RGB);
  eq(gone.settled.length, 1, "a roll at an unlinked board settles rather than hanging");
  eq(gone.settled[0], "not_linked", "and says so");
  eq(gone.sent.length, 0, "and writes nothing");
}

// --- live frames -----------------------------------------------------------
{
  const b = mkBoard();
  b.ctrl.sendLive(RGB);
  eq(b.sent.length, 1, "a live frame is written");
  eq(b.sent[0], "LED:LIVE c=ff0000,00ff00,0000ff", "live wire form carries no id");
  eq(b.ctrl.palettePending, null, "a live frame creates no pending roll");
  eq(b.ctrl.paletteTimer, null, "a live frame arms no retry timer");

  b.ctrl.sendLive(["ff0000"]);
  b.ctrl.sendLive(["ff0000", "00ff00", "nothex"]);
  eq(b.sent.length, 1, "malformed live frames are dropped, not written");

  b.ctrl.linked = false;
  b.ctrl.sendLive(RGB);
  eq(b.sent.length, 1, "live frames stop at an unlinked board");
}

// --- live frames never disturb a save --------------------------------------
{
  const b = mkBoard();
  b.roll(RGB);
  const gid = gidOf(b.sent[0]);
  // The kiosk stops streaming at the landing, but a frame already in flight
  // must not cancel or re-id the roll it is racing.
  b.ctrl.sendLive(["aaaaaa", "bbbbbb", "cccccc"]);
  check(b.ctrl.palettePending !== null, "a live frame does not cancel an in-flight roll");
  eq(b.ctrl.palettePending.gid, Number(gid), "and does not change its id");
  b.ctrl.onLine(`CTRL:LED_ACK g=${gid}`);
  eq(b.settled.length, 1, "the roll still acks normally");
  eq(b.settled[0], null, "as banked");
}

// --- link identity ---------------------------------------------------------
{
  const mgr = new ControllerManager({
    clientBin: "", pickRoom: () => null, roomJoined() {}, roomLeft() {},
    isRoomAlive: () => false, moveLabels: () => [],
  });
  const a = new Controller("/dev/a", "uid-a", mgr);
  const c = new Controller("/dev/c", "uid-c", mgr);
  a.write = () => {}; c.write = () => {};
  mgr.controllers.set(a.path, a);
  mgr.controllers.set(c.path, c);

  eq(mgr.listLinked().length, 0, "an unlinked board is not offered to the kiosk");
  eq(mgr.linkedById(1), null, "and cannot be addressed");

  a.linked = true; a.linkId = 7;
  c.linked = true; c.linkId = 4;
  eq(mgr.listLinked().map((b) => b.linkId).join(","), "4,7", "boards are listed in link order");
  eq(mgr.linkedById(7), a, "a link id resolves to its board");
  // This is the unplug case the kiosk relies on: a vanished link resolves to
  // null so the roll is skipped, rather than landing on whatever took its slot.
  eq(mgr.linkedById(99), null, "an unknown link id resolves to null");
  a.linked = false;
  eq(mgr.linkedById(7), null, "a board that dropped its link stops resolving");

  // Ids identify a LINK, so a replug is a different badge as far as the kiosk
  // is concerned — which is exactly what makes replug-to-reroll work.
  check(a.linkId !== c.linkId, "two boards never share a link id");
}

if (failures === 0) console.log("OK  link: palette rolls settle exactly once on every path");
else console.log(`FAIL: ${failures} link checks failed`);
process.exit(failures === 0 ? 0 : 1);
