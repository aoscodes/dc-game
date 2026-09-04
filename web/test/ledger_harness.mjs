// Harness for the badge ledger (bridge/ledger.js) and the bridge's wiring
// into it (bridge/controllers.js).
//
// The ledger's whole value is that it is TRUSTWORTHY, and the ways a record
// can be untrustworthy are not the ways code is usually wrong — it can be
// perfectly consistent and still be a lie. So the checks here are mostly about
// what the ledger must NOT claim:
//
//   - that a badge reported stats when the bridge gave up waiting for them,
//   - that one badge's history is another's, because they shared a port,
//   - that four boards in one room played four games,
//   - that a connection ended at the moment the bridge happened to restart.
//
// Plus the one structural property the file's header promises: it is
// write-only. A read API is how a record becomes a second authority on what a
// badge contains, and the badge's flash is the only one. That is asserted here
// so it fails at test time rather than at design-review time two years from now.
//
// Everything runs against a REAL Ledger in a temp dir, driven through the REAL
// Controller state machine with a stubbed transport — the bugs worth catching
// live in the wiring, and a harness that called the ledger directly would
// agree with a controllers.js that never called it at all.
import { createRequire } from "node:module";
import { mkdtempSync, rmSync, readFileSync, readdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const require = createRequire(import.meta.url);
const { Controller, ControllerManager, ControllerSession } =
  require(new URL("../../bridge/controllers.js", import.meta.url).pathname);
const ledgerMod = require(new URL("../../bridge/ledger.js", import.meta.url).pathname);
const { Ledger, NULL_LEDGER, LEDGER_VERBS } = ledgerMod;

let failures = 0;
function check(cond, what) {
  if (!cond) { failures++; console.log(`FAIL: ${what}`); }
}
function eq(a, b, what) {
  check(a === b, `${what} (got ${JSON.stringify(a)}, want ${JSON.stringify(b)})`);
}

const tmpDirs = [];
function mkDir() {
  const d = mkdtempSync(join(tmpdir(), "ledger-harness-"));
  tmpDirs.push(d);
  return d;
}

const readSnapshot = (dir) => JSON.parse(readFileSync(join(dir, "badges.json"), "utf8"));
const readEvents = (dir) => {
  const f = readdirSync(dir).filter((n) => n.startsWith("events-"));
  return f.flatMap((n) => readFileSync(join(dir, n), "utf8")
    .split("\n").filter(Boolean).map((l) => JSON.parse(l)));
};
const readGames = (dir) => {
  const gdir = join(dir, "games");
  if (!existsSync(gdir)) return [];
  // Every entry, deliberately: `games/` holding anything but game files —
  // strays, .bak copies, half-written .tmp — is itself the bug, because the
  // file count in there is how anyone counts the games played.
  return readdirSync(gdir).map((n) => JSON.parse(readFileSync(join(gdir, n), "utf8")));
};

/**
 * A manager with a real ledger, real controllers and no hardware.
 *
 * makePlayer is stubbed the way stat_harness stubs it: seating a board is what
 * we are recording, not what we are testing, and the real one spawns a client.
 */
function mkRig({ withRoom = true } = {}) {
  const dir = mkDir();
  const ledger = new Ledger({ dir });
  const room = { code: "TEST", port: 1, configHash: null };
  const manager = new ControllerManager({
    clientBin: "/nonexistent",
    pickRoom: () => (withRoom ? room : null),
    roomJoined() {}, roomLeft() {}, isRoomAlive: () => true,
    moveLabels: () => [],
    ledger,
  });
  manager.makePlayer = (ctrl) => {
    ctrl.playerSession = { writeToZig() {}, destroy() { ctrl.playerSession = null; } };
  };
  return { dir, ledger, manager, room };
}

/** Link a board through the REAL CTRL:HELLO path, so the ledger sees it. */
function link(manager, path, uid, uidSource = "serial") {
  const ctrl = new Controller(path, uid, manager, uidSource);
  ctrl.write = () => {};
  manager.controllers.set(path, ctrl);
  ctrl.onLine("CTRL:HELLO v=1");
  return ctrl;
}

const FULL = "CTRL:STAT appetite=7 babies=1,0,2,0,0 powerups=3 critter=3 " +
  "led=d4506e,7ac0a0,e8c46a seed=1f3c9a04";

// --- write-only, structurally ----------------------------------------------
{
  // Not a style check. A getter here is the seam through which the kiosk
  // starts trusting the ledger over the badge in front of it.
  // Anchored to a whole verb — `badgeStat` is a write and must not trip this.
  const banned = /^(get|find|query|lookup|read|load|list|fetch|history)([A-Z]|$)/;
  const offenders = Object.getOwnPropertyNames(Ledger.prototype)
    .filter((n) => banned.test(n));
  eq(offenders.join(","), "", "Ledger exposes no read/query API");

  const exported = Object.keys(ledgerMod).sort().join(",");
  eq(exported, "LEDGER_VERBS,LEDGER_VERSION,Ledger,NULL_LEDGER,stamp",
    "ledger.js exports only the writer, the null writer and its vocabulary");

  // NULL_LEDGER has to answer every verb, or the harnesses that run against it
  // crash on whichever call site is added next rather than on this line.
  check(LEDGER_VERBS.every((v) => typeof NULL_LEDGER[v] === "function"),
    "NULL_LEDGER implements every ledger verb");
  check(Object.isFrozen(NULL_LEDGER), "NULL_LEDGER is frozen");
}

// --- one plug-in, start to finish ------------------------------------------
{
  const { dir, ledger, manager } = mkRig();
  const ctrl = link(manager, "/dev/a", "BADGE-A");
  ctrl.onLine(FULL);
  manager.dropController(ctrl, "unplugged");
  await ledger.stop("test");

  const snap = readSnapshot(dir);
  const badge = snap.badges["BADGE-A"];
  check(badge !== undefined, "the badge has a record");
  eq(badge.uidSource, "serial", "uid is recorded as a serial number");
  eq(badge.connectionCount, 1, "one connection");
  eq(badge.connections.length, 1, "one connection record");

  const conn = badge.connections[0];
  eq(conn.port, "/dev/a", "the connection knows its port");
  eq(conn.endedBy, "unplugged", "and how it ended");
  check(typeof conn.connectedAt === "string", "with a connect timestamp");
  check(typeof conn.disconnectedAt === "string", "and a disconnect timestamp");
  check(conn.durationMs >= 0, "and a duration");

  // The state is snapshotted ON the connection, not only at top level: the
  // point of the file is what a badge was carrying THAT TIME it was plugged in.
  eq(conn.state.appetite, 7, "the connection carries the reported appetite");
  eq(conn.state.babies.join(","), "1,0,2,0,0", "and the babies");
  eq(conn.state.critter, 3, "and the critter");
  eq(conn.state.colors.join(","), "d4506e,7ac0a0,e8c46a", "and the palette");
  eq(conn.state.seed, "1f3c9a04", "and the brood seed");
  eq(conn.state.statReported, true, "flagged as a genuine badge report");
  eq(badge.state.appetite, 7, "and the badge's latest state agrees");

  const events = readEvents(dir);
  eq(events.filter((e) => e.type === "badge_linked").length, 1, "one link event");
  eq(events.filter((e) => e.type === "badge_unlinked").length, 1, "one unlink event");
  check(events.every((e, i) => e.seq === i + 1), "events are sequenced without gaps");
}

// --- a badge that never reports --------------------------------------------
{
  // The bridge gives up after STAT_WAIT_MS and joins the board at defaults.
  // Those defaults are the BRIDGE's, and a record that filed them as the
  // badge's contents would be inventing a creature.
  const { dir, ledger, manager } = mkRig();
  const ctrl = link(manager, "/dev/b", "BADGE-B");
  ctrl.statTimer._onTimeout(); // as if STAT_WAIT_MS elapsed
  manager.dropController(ctrl, "unplugged");
  await ledger.stop("test");

  const conn = readSnapshot(dir).badges["BADGE-B"].connections[0];
  eq(conn.state.statReported, false, "a board that never STATed is marked as such");
  eq(conn.state.critter, null, "and its critter is unknown, not a default");
  eq(conn.state.colors, null, "and its palette is unknown, not black");
}

// --- replug is a second connection, not a second badge ---------------------
{
  const { dir, ledger, manager } = mkRig();
  const first = link(manager, "/dev/c", "BADGE-C");
  first.onLine("CTRL:STAT appetite=2 babies=0,0,0,0,0 powerups=0");
  manager.dropController(first, "unplugged");

  const second = link(manager, "/dev/c", "BADGE-C");
  second.onLine("CTRL:STAT appetite=9 babies=1,1,0,0,0 powerups=0");
  manager.dropController(second, "unplugged");
  await ledger.stop("test");

  const badge = readSnapshot(dir).badges["BADGE-C"];
  eq(Object.keys(readSnapshot(dir).badges).length, 1, "one badge, not two");
  eq(badge.connectionCount, 2, "two connections");
  eq(badge.connections.length, 2, "both are kept");
  eq(badge.connections[0].state.appetite, 2, "the first keeps ITS state");
  eq(badge.connections[1].state.appetite, 9, "the second keeps its own");
  eq(badge.state.appetite, 9, "and the latest state is the latest");
  check(badge.connections[0].link !== badge.connections[1].link,
    "the two connections have distinct link ids");
}

// --- a port-derived uid says so --------------------------------------------
{
  // A board with no USB serial number is named by its port, and the next board
  // in that port inherits the name. The record cannot prevent that; it can
  // refuse to present it as one badge's continuous history.
  const { dir, ledger, manager } = mkRig();
  const ctrl = link(manager, "/dev/ttyACM0", "/dev/ttyACM0", "path");
  ctrl.onLine(FULL);
  manager.dropController(ctrl, "unplugged");
  await ledger.stop("test");

  eq(readSnapshot(dir).badges["/dev/ttyACM0"].uidSource, "path",
    "a port-derived uid is recorded as the weaker claim it is");
}

// --- four boards, one room, one game ---------------------------------------
{
  const { dir, ledger, manager, room } = mkRig();
  const boards = ["A", "B", "C", "D"].map((n, i) => {
    const c = link(manager, `/dev/g${i}`, `GAME-${n}`);
    c.onLine(FULL);
    return c;
  });

  // One inert ControllerSession per board, each with its own frame stream —
  // which is the real shape: every board is its own headless client, so the
  // same game arrives four times and must be recorded once.
  const sessions = boards.map((c) => {
    const s = Object.create(ControllerSession.prototype);
    s.controller = c; s.manager = manager; s.room = room;
    s.lastPhase = null; s.seatedIn = null; s.observingIn = null;
    return s;
  });

  // Three seats, one spectator: exactly the case where a naive record would
  // count four players.
  const seatOf = (i) => ({
    tag: "render", phase: "game",
    game: { encounter: "gnaw", player_id: i, observer: i === 3, join_code: "TEST" },
  });
  const over = {
    tag: "render", phase: "game_over", score: 4200,
    stats: { eggs_hatched: { rose: 2, mint: 1 } },
  };

  for (const [i, s] of sessions.entries()) s.onZigFrame(seatOf(i), "");
  for (const [i, s] of sessions.entries()) s.onZigFrame(seatOf(i), ""); // repeats
  for (const s of sessions) s.onZigFrame(over, "");
  await ledger.stop("test");

  const games = readGames(dir);
  eq(games.length, 1, "four boards in one room played ONE game");
  const g = games[0];
  eq(g.roomCode, "TEST", "the game knows its room");
  eq(g.encounter, "gnaw", "and its encounter");
  eq(g.score, 4200, "and its final score");
  eq(g.endedBy, "game_over", "and that it ended by being played out");
  eq(g.hatched.join(","), "2,1,0,0,0", "and what hatched");
  eq(g.badges.length, 4, "all four badges are on the roster");
  eq(g.badges.filter((b) => b.seated).length, 3, "three of them were seated");
  eq(g.badges.filter((b) => !b.seated).length, 1, "and one was watching");
  check(g.badges.every((b) => b.uid.startsWith("GAME-")), "by uid");

  const events = readEvents(dir);
  eq(events.filter((e) => e.type === "game_opened").length, 1, "one game_opened");
  eq(events.filter((e) => e.type === "game_closed").length, 1, "one game_closed");
  eq(events.filter((e) => e.type === "badge_seated").length, 3,
    "seats are recorded once each, not once per frame");

  // Every board still delivers its own score, all against the same game.
  const delivered = events.filter((e) => e.type === "score_delivered");
  eq(delivered.length, 4, "every board is sent the score");
  check(delivered.every((e) => e.gameId === g.gameId),
    "and every delivery names the game that just ended");

  const snap = readSnapshot(dir);
  eq(snap.badges["GAME-A"].games.length, 1, "the badge's record lists the game");
  eq(snap.badges["GAME-A"].totals.games, 1, "and counts it");
  eq(snap.badges["GAME-A"].games[0], g.gameId, "by the same id the game file uses");
}

// --- a restart in the same room is a new game ------------------------------
{
  const { dir, ledger, manager, room } = mkRig();
  const ctrl = link(manager, "/dev/r", "BADGE-R");
  ctrl.onLine(FULL);
  const s = Object.create(ControllerSession.prototype);
  s.controller = ctrl; s.manager = manager; s.room = room;
  s.lastPhase = null; s.seatedIn = null; s.observingIn = null;

  const playing = { tag: "render", phase: "game", game: { encounter: "gnaw", player_id: 0, observer: false } };
  const over = { tag: "render", phase: "game_over", score: 10 };
  s.onZigFrame(playing, "");
  s.onZigFrame(over, "");
  s.onZigFrame(playing, ""); // RESTART: same room, same code, new game
  s.onZigFrame(over, "");
  await ledger.stop("test");

  const games = readGames(dir);
  eq(games.length, 2, "a restart in the same room is a second game");
  check(games[0].gameId !== games[1].gameId, "with a distinct id");
  eq(readSnapshot(dir).badges["BADGE-R"].totals.games, 2, "and the badge counts both");
}

// --- a score the badge never acked -----------------------------------------
{
  const { dir, ledger, manager } = mkRig();
  const ctrl = link(manager, "/dev/s", "BADGE-S");
  ctrl.onLine(FULL);
  ctrl.sendScore(999, [0, 0, 0, 0, 0], "game-xyz");
  const gid = ctrl.scorePending.gid;
  ctrl.onLine(`CTRL:SCORE_ACK g=${gid}`);
  manager.dropController(ctrl, "unplugged");
  await ledger.stop("test");

  const events = readEvents(dir);
  const banked = events.filter((e) => e.type === "score_banked");
  eq(banked.length, 1, "an acked score is recorded as banked");
  eq(banked[0].gameId, "game-xyz", "against the game it belongs to");
  eq(readSnapshot(dir).badges["BADGE-S"].totals.scoresBanked, 1, "and counted");
}

// --- a bridge that dies mid-connection -------------------------------------
{
  // The next run must not fabricate an end time it cannot know, and must not
  // leave the connection looking open forever either.
  const dir = mkDir();
  const first = new Ledger({ dir });
  first.badgeLinked({ uid: "BADGE-X", uidSource: "serial", port: "/dev/x", link: 1 });
  first.badgeStat({
    uid: "BADGE-X", link: 1, statReported: true, source: "badge",
    state: { appetite: 4, babies: [0, 0, 0, 0, 0], powerups: [1], critter: 1, colors: null, seed: null },
  });
  await first.flush(); // durable, but never stopped: the bridge was killed

  const openConn = readSnapshot(dir).badges["BADGE-X"].connections[0];
  eq(openConn.endedBy, null, "before the crash the connection is open");

  const second = new Ledger({ dir }); // loads and repairs on construction
  await second.flush();

  const conn = readSnapshot(dir).badges["BADGE-X"].connections[0];
  eq(conn.endedBy, "bridge_exit", "the next run closes it as an unclean exit");
  eq(conn.disconnectedAt, null,
    "without inventing a time it has no way of knowing");
  eq(conn.state.appetite, 4, "and the state it did capture survives intact");
  await second.stop("test");
}

// --- a clean stop DOES know the time ---------------------------------------
{
  const dir = mkDir();
  const l = new Ledger({ dir });
  l.badgeLinked({ uid: "BADGE-Y", uidSource: "serial", port: "/dev/y", link: 1 });
  await l.stop("SIGTERM");

  const conn = readSnapshot(dir).badges["BADGE-Y"].connections[0];
  eq(conn.endedBy, "bridge_stopped", "a deliberate stop closes open connections");
  check(typeof conn.disconnectedAt === "string",
    "and does stamp them, because it happens at a known moment");
  check(conn.durationMs >= 0, "with a duration");
}

// --- an event that arrives DURING shutdown still lands --------------------
{
  // A badge acking a score as the kiosk goes down is an ordinary thing to
  // happen, and shutdown closing the events file out from under it would lose
  // the one event the operator is most likely to go looking for.
  const dir = mkDir();
  const l = new Ledger({ dir });
  l.badgeLinked({ uid: "BADGE-L", uidSource: "serial", port: "/dev/l", link: 1 });

  const stopping = l.stop("SIGTERM");
  l.scoreBanked({ gameId: "late-game", uid: "BADGE-L", link: 1, gid: 7 });
  await stopping;

  const banked = readEvents(dir).filter((e) => e.type === "score_banked");
  eq(banked.length, 1, "an event queued during shutdown is still written");
  eq(banked[0].gid, 7, "intact");
}

// --- a corrupt snapshot is moved aside, not overwritten --------------------
{
  const dir = mkDir();
  const l0 = new Ledger({ dir });
  l0.badgeLinked({ uid: "BADGE-Z", uidSource: "serial", port: "/dev/z", link: 1 });
  await l0.stop("test");

  const { writeFileSync } = await import("node:fs");
  writeFileSync(join(dir, "badges.json"), "{ this is not json");
  writeFileSync(join(dir, "badges.json.bak"), "also not json");

  const l1 = new Ledger({ dir });
  await l1.stop("test");

  const aside = readdirSync(dir).filter((n) => n.includes(".corrupt-"));
  eq(aside.length, 1, "an unreadable badges.json is preserved, not clobbered");
  check(readSnapshot(dir).badges !== undefined, "and a fresh one starts clean");
}

for (const d of tmpDirs) rmSync(d, { recursive: true, force: true });

if (failures === 0) {
  console.log("OK  ledger: write-only, one record per plug-in, one record per game");
} else {
  console.log(`FAIL: ${failures} ledger checks failed`);
}
process.exit(failures === 0 ? 0 : 1);
