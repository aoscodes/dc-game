// Harness for the bridge's side of the badge powerup protocol
// (bridge/controllers.js: sendPowerup / CTRL:POWERUP_ACK / grantPowerup).
//
// Two contracts, and the reason this file exists is that they pull in
// opposite directions.
//
// Liveness, as in link_harness: the /powerups kiosk blocks on a per-grant
// callback, so a callback that is dropped hangs the kiosk and one that fires
// twice miscounts the badges. Settled exactly once, on every path.
//
// Arithmetic, which the palette has no equivalent of: a grant ADDS. This side
// must therefore never invent a count of its own — every number it reports has
// to have come out of a badge — because the badge's flash is the only copy and
// it saturates at 255. The failures that matters look like a kiosk cheerfully
// showing a number that no badge holds.
//
// A Controller is constructed WITHOUT open()ing a serial port and its write()
// is stubbed, so this drives the real state machine with no hardware and no
// timers left running.
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { Controller, ControllerManager, POWERUP_KIND_COUNT, POWERUP_NAMES } =
  require(new URL("../../bridge/controllers.js", import.meta.url).pathname);
const { NULL_LEDGER } =
  require(new URL("../../bridge/ledger.js", import.meta.url).pathname);

let failures = 0;
function check(cond, what) {
  if (!cond) { failures++; console.log(`FAIL: ${what}`); }
}
function eq(a, b, what) {
  check(a === b, `${what} (got ${JSON.stringify(a)}, want ${JSON.stringify(b)})`);
}

/** An inert linked board: real state machine, stubbed transport. */
function mkBoard(linkId = 1) {
  const manager = {
    assign() {}, boardsChanged() {}, dropController() {}, ledger: NULL_LEDGER,
  };
  const ctrl = new Controller(`/dev/fake${linkId}`, `uid${linkId}`, manager);
  const sent = [];
  ctrl.write = (line) => { sent.push(line); };
  ctrl.linked = true;
  ctrl.linkId = linkId;
  ctrl.statSeen = true;
  /** Everything the grant's callback was told, in order. */
  const settled = [];
  return {
    ctrl, sent, settled,
    grant: (kind = 0) => ctrl.sendPowerup(kind, (e) => settled.push(e)),
  };
}

const gidOf = (line) => line.slice(line.indexOf("g=") + 2);
/** A badge's ack for grant `gid`, reporting `n` of kind 0 and zero of the rest. */
const ackLine = (gid, n) =>
  `CTRL:POWERUP_ACK g=${gid} p=${[n, ...Array(POWERUP_KIND_COUNT - 1).fill(0)]
    .join(",")}`;

// --- the name table names every kind ---------------------------------------
{
  // The ordinals are the wire and flash identity and the names are only for
  // the operator console, but a missing one prints as "kind 3" in the log
  // that IS the record of a grant.
  eq(POWERUP_NAMES.length, POWERUP_KIND_COUNT,
    "every powerup ordinal has a display name");
  check(POWERUP_NAMES.every((n) => typeof n === "string" && n.length > 0),
    "and none of them is blank");
}

// --- the happy path --------------------------------------------------------
{
  const b = mkBoard();
  b.grant(0);
  eq(b.sent.length, 1, "the grant is written immediately, not on the first retry tick");
  check(b.sent[0].startsWith("POWERUP:GRANT k=0 g="), `wire form (${b.sent[0]})`);

  b.ctrl.onLine(ackLine(gidOf(b.sent[0]), 3));
  eq(b.settled.length, 1, "the ack settles the grant exactly once");
  eq(b.settled[0], null, "and settles it as banked");
  eq(b.ctrl.powerups[0], 3, "the badge's reported count is mirrored");
  eq(b.ctrl.powerupPending, null, "the ack clears the pending grant");
  eq(b.ctrl.powerupTimer, null, "the ack stops the retry timer");
}

// --- the count comes from the BADGE, never from arithmetic here ------------
{
  // The one property that separates this from the palette. If this side ever
  // starts keeping its own total, the first thing to break is the badge that
  // has been granted powerups by some OTHER bridge run — or that saturated.
  const b = mkBoard();
  eq(b.ctrl.powerups[0], 0, "a badge that has not spoken is assumed to carry nothing");

  b.grant(0);
  eq(b.ctrl.powerups[0], 0,
    "sending a grant does not move the mirror; only the badge's answer does");
  b.ctrl.onLine(ackLine(gidOf(b.sent[0]), 200));
  eq(b.ctrl.powerups[0], 200, "the ack's count is taken verbatim, not incremented");

  // Saturation: the badge stops climbing and says so, and this side must
  // report the badge's number rather than the one it expected.
  b.ctrl.powerups[0] = 255;
  b.grant(0);
  b.ctrl.onLine(ackLine(gidOf(b.sent[1]), 255));
  eq(b.settled.length, 2, "a grant to a full badge still settles");
  eq(b.settled[1], null, "and settles as banked, because the badge banked it");
  eq(b.ctrl.powerups[0], 255, "a full badge stays full rather than wrapping to 0");
}

// --- CTRL:STAT seeds the mirror -------------------------------------------
{
  const b = mkBoard();
  b.ctrl.onLine("CTRL:STAT appetite=5 powerups=" +
    [7, ...Array(POWERUP_KIND_COUNT - 1).fill(0)].join(","));
  eq(b.ctrl.powerups[0], 7, "the one-per-link stat report seeds the counts");

  // A miscounted list is rejected WHOLE: a badge whose firmware knows a
  // different number of kinds is reporting counts this side cannot align to
  // ordinals, and a shifted list reads as the wrong powerup.
  b.ctrl.onLine("CTRL:STAT appetite=5 powerups=" +
    Array(POWERUP_KIND_COUNT + 1).fill(9).join(","));
  eq(b.ctrl.powerups[0], 7, "a miscounted list leaves the last good counts alone");
  b.ctrl.onLine("CTRL:STAT appetite=5 powerups=1x");
  b.ctrl.onLine("CTRL:STAT appetite=5 powerups=" +
    [256, ...Array(POWERUP_KIND_COUNT - 1).fill(0)].join(","));
  eq(b.ctrl.powerups[0], 7,
    "and so do a non-numeric list and one that overflows the badge's u8");

  // Old firmware sends no powerups key at all; that is zero, not a mystery.
  const old = mkBoard(2);
  old.ctrl.onLine("CTRL:STAT appetite=5 babies=1,2,3,4,5");
  eq(old.ctrl.powerups.join(","), Array(POWERUP_KIND_COUNT).fill(0).join(","),
    "a stat line without powerups leaves a badge carrying none");
}

// --- acks that are not for this grant --------------------------------------
{
  const b = mkBoard();
  b.grant(0);
  // The board dedupes on the id and re-acks retries, so an EARLIER grant's
  // ack can arrive while a newer one is in flight. Settling on it would tell
  // the kiosk a grant landed that is still in the air.
  b.ctrl.onLine(ackLine(1, 4));
  eq(b.settled.length, 0, "a stale ack does not settle the current grant");
  check(b.ctrl.powerupPending !== null, "a stale ack leaves the grant in flight");
  // ... but its COUNTS are still the badge's own, and so still news.
  eq(b.ctrl.powerups[0], 4, "a stale ack's counts are believed anyway");

  b.ctrl.onLine("CTRL:POWERUP_ACK");            // no arguments
  b.ctrl.onLine("CTRL:POWERUP_ACK g=1");        // no counts
  b.ctrl.onLine(`CTRL:POWERUP_ACK g=${gidOf(b.sent[0])} p=`);     // empty counts
  b.ctrl.onLine(`CTRL:POWERUP_ACK g=${gidOf(b.sent[0])} p=1,2,3,4`); // miscounted
  b.ctrl.onLine("CTRL:LED_ACK g=1");            // another protocol's ack
  eq(b.settled.length, 0, "malformed and foreign acks do not settle the grant");
  eq(b.ctrl.powerups[0], 4, "and do not disturb the counts");
  b.ctrl.clearPowerupRetry("cleanup");
}

// --- retries run out -------------------------------------------------------
{
  const b = mkBoard();
  b.grant(0);
  const gid = gidOf(b.sent[0]);
  // Drive the retry timer by hand rather than waiting out five real seconds.
  const tick = b.ctrl.powerupTimer._onTimeout;
  check(typeof tick === "function", "the retry timer is drivable");
  for (let i = 0; i < 20; i++) tick();

  check(b.sent.length >= 2, `the grant is retried (${b.sent.length} writes)`);
  check(b.sent.every((l) => gidOf(l) === gid),
    "every retry carries the SAME id — the board's dedupe on it is the only " +
    "thing stopping a retry granting a second powerup");
  eq(b.settled.length, 1, "running out of retries settles the grant exactly once");
  eq(b.settled[0], "no_ack", "and settles it as a failure the kiosk can report");
  eq(b.ctrl.powerupTimer, null, "giving up stops the retry timer");

  // The kiosk has moved on; a late ack must not settle a second time — but
  // its counts are still the badge's, and are how the operator finds out the
  // grant landed after all.
  b.ctrl.onLine(ackLine(gid, 6));
  eq(b.settled.length, 1, "an ack arriving after we gave up settles nothing");
  eq(b.ctrl.powerups[0], 6, "but still corrects the counts");
}

// --- unplugged mid-save ----------------------------------------------------
{
  const b = mkBoard();
  b.grant(0);
  b.ctrl.close();
  eq(b.settled.length, 1, "closing the port settles the in-flight grant exactly once");
  eq(b.settled[0], "unlinked", "and settles it as unlinked");
  eq(b.ctrl.powerupTimer, null, "closing stops the retry timer");

  b.ctrl.close();
  eq(b.settled.length, 1, "closing twice does not settle twice");
}

// --- superseded ------------------------------------------------------------
{
  const b = mkBoard();
  b.grant(0);
  b.grant(0);
  eq(b.settled.length, 1, "a second grant settles the first exactly once");
  eq(b.settled[0], "superseded", "and says why");
  check(gidOf(b.sent[0]) !== gidOf(b.sent[1]),
    "the second grant carries a NEW id, so the badge banks it rather than " +
    "mistaking it for a retry of the first");
  b.ctrl.clearPowerupRetry("cleanup");
  eq(b.settled.length, 2, "the second grant is still settleable");
}

// --- refusals settle too ---------------------------------------------------
{
  const b = mkBoard();
  b.grant(POWERUP_KIND_COUNT); // one past the last kind
  b.grant(-1);
  b.grant(1.5);
  b.grant("0");
  eq(b.settled.length, 4, "every rejected kind still settles its grant");
  check(b.settled.every((r) => r === "bad_kind"), `all rejected as bad_kind (${b.settled})`);
  // An out-of-range ordinal reaching the badge would index past its counts
  // array, and the badge rejects it — but the line should not be written at
  // all, so the two ends never disagree about which kinds exist.
  eq(b.sent.length, 0, "nothing out of range reaches the board");

  const gone = mkBoard(3);
  gone.ctrl.linked = false;
  gone.grant(0);
  eq(gone.settled.length, 1, "a grant at an unlinked board settles rather than hanging");
  eq(gone.settled[0], "not_linked", "and says so");
  eq(gone.sent.length, 0, "and writes nothing");
}

// --- fan-out over every linked badge ---------------------------------------
{
  const mgr = new ControllerManager({
    clientBin: "", pickRoom: () => null, roomJoined() {}, roomLeft() {},
    isRoomAlive: () => false, moveLabels: () => [],
  });
  const boards = [];
  for (const [path, uid, linkId, linked] of [
    ["/dev/a", "uid-a", 2, true],
    ["/dev/b", "uid-b", 1, true],
    ["/dev/c", "uid-c", null, false], // plugged, never completed the handshake
  ]) {
    const c = new Controller(path, uid, mgr);
    c.sent = [];
    c.write = (l) => c.sent.push(l);
    c.linked = linked;
    c.linkId = linkId;
    mgr.controllers.set(path, c);
    boards.push(c);
  }
  const [a, bb, unlinked] = boards;

  const pending = mgr.grantPowerup(0);
  // Grants are queued rather than fired synchronously (grantPowerup
  // serialises them), so give the queue a turn before reading the wire.
  await new Promise((r) => setImmediate(r));
  eq(a.sent.length, 1, "a linked badge is granted");
  eq(bb.sent.length, 1, "every linked badge is granted, not just the first");
  eq(unlinked.sent.length, 0,
    "a plugged-but-unlinked badge is skipped: it has no link to address and " +
    "would silently drop the line");

  a.onLine(ackLine(gidOf(a.sent[0]), 1));
  bb.clearPowerupRetry("no_ack"); // this one never answers
  const summary = await pending;

  eq(summary.results.length, 2, "the report covers exactly the badges targeted");
  eq(summary.results[0].uid, "uid-b", "and is ordered by link id, not by port");
  const byUid = Object.fromEntries(summary.results.map((r) => [r.uid, r]));
  eq(byUid["uid-a"].ok, true, "the badge that acked is reported as granted");
  eq(byUid["uid-a"].powerups[0], 1, "with the count the badge itself reported");
  eq(byUid["uid-b"].ok, false, "the badge that never answered is reported failed");
  eq(byUid["uid-b"].reason, "no_ack", "with the reason, so the operator can retry");
  // One badge failing must not roll back or hide the others: their powerups
  // are already in flash and there is no transaction to be had.
  eq(byUid["uid-a"].ok, true, "one badge's failure does not undo another's grant");

  const none = await mgr.grantPowerup(POWERUP_KIND_COUNT);
  eq(none.results.length, 0, "an unknown kind grants to nobody");
  eq(a.sent.length, 1, "and writes nothing to any badge");

  // Serialisation: a second grant must not supersede a first that is still in
  // flight. Superseding is the one outcome with no honest answer — the
  // superseded grant may already be in the badge's flash — so a double press
  // has to queue rather than race.
  a.sent.length = 0;
  const first = mgr.grantPowerup(0);
  const second = mgr.grantPowerup(0);
  await new Promise((r) => setImmediate(r));
  eq(a.sent.length, 1, "a queued second grant does not reach the badge yet");
  const firstGid = gidOf(a.sent[0]);
  a.onLine(ackLine(firstGid, 2));
  bb.clearPowerupRetry("no_ack");
  await first;
  await new Promise((r) => setImmediate(r));
  eq(a.sent.length, 2, "the second grant goes out once the first has settled");
  check(gidOf(a.sent[1]) !== firstGid, "with its own id");
  a.onLine(ackLine(gidOf(a.sent[1]), 3));
  bb.clearPowerupRetry("no_ack");
  const s2 = await second;
  eq(s2.results.find((r) => r.uid === "uid-a").ok, true,
    "and settles on its own merits, not the first grant's");
}

if (failures === 0) {
  console.log("OK  powerup: grants settle once, counts only ever come from the badge");
} else {
  console.log(`FAIL: ${failures} powerup checks failed`);
}
process.exit(failures === 0 ? 0 : 1);
