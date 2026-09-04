"use strict";

/**
 * The badge ledger: a local, append-only record of every badge this kiosk has
 * seen and everything that happened to it.
 *
 * WHAT THIS IS NOT
 *
 * It is not a badge database, and nothing in this process may read from it.
 * A badge's powerup counts, its colours and its brood live in ONE place — the
 * badge's own flash — and controllers.js is emphatic about why (see the
 * POWERUP:GRANT and ControllerManager.grantPowerup comments): a count kept on
 * this side is wrong the first time a badge is granted by another bridge run,
 * saturates at 255, or is reflashed.  A ledger IS a second copy of that data,
 * so the only thing keeping it from rotting into a competing authority is that
 * it CANNOT BE READ.  Every verb below writes; there is no getter, no query,
 * no `getBadge(uid)`.  An operator reads badges.json with `jq`, out of band,
 * after the fact.  Code never does.
 *
 * The distinction the records themselves keep is "reported at", not "has": a
 * badge state in here is what some badge SAID at some instant, and it is
 * stamped with when it said so and where the claim came from (`source`).
 *
 * Which is also why two acks are treated differently.  CTRL:POWERUP_ACK
 * carries the badge's RESULTING counts, so a grant refreshes the recorded
 * powerups — the badge said so.  CTRL:LED_ACK carries only the roll id, so an
 * onboarding commit records the EVENT and deliberately leaves the recorded
 * colours alone: the badge acked a flash save, it did not report a palette.
 * The next link's CTRL:STAT is what updates them.  Inferring the new colours
 * here would be this side inventing badge state, which is the whole failure
 * mode this file is trying not to become.
 *
 * ON DISK  (all under BADGE_LOG_DIR, default <repo>/records)
 *
 *   events-<stamp>.jsonl   Every event, one JSON object per line, in order.
 *                          One file per bridge run — "tonight's log" is a
 *                          file.  Append-only, so a power cut mid-write costs
 *                          the last line and nothing else.  This is the
 *                          record; the two below are views of it.
 *
 *   badges.json            Every badge ever seen, keyed by uid, each with its
 *                          last reported state, running totals and its whole
 *                          connection log.  The "big JSON record".  Rewritten
 *                          whole, debounced, tmp+rename so it is never torn,
 *                          with the previous copy kept as badges.json.bak.
 *
 *   games/<gameId>.json    One file per game: when it opened, which badges sat
 *                          in it, the final score and the server's whole match
 *                          report.  `endedBy: null` means the game never
 *                          closed — the bridge died holding it.
 *
 * Nothing is pruned or capped.  The SD card is the limit, deliberately: this
 * feature exists to keep the record, and a retention policy is a policy about
 * which part of it to throw away.  The one cost of that choice is that
 * badges.json is rewritten in full, so its write grows with lifetime
 * connection count (~1.5 MB at 30 badges x 200 connections, which the debounce
 * absorbs).  If it ever matters, archive badges.json between events; the log
 * is untouched by that.
 *
 * ORDERING
 *
 * Every verb enqueues onto one promise chain, and the in-memory document is
 * mutated INSIDE that chain.  So the initial load is simply the first link,
 * callers never await anything, and an event recorded a microsecond after
 * construction still lands after the load rather than being overwritten by it.
 * No verb ever rejects: a ledger that cannot write is a lost record, not a
 * broken kiosk, and taking the game down with it would be a strictly worse
 * trade.
 */

const fsp = require("fs/promises");
const path = require("path");

/** Schema version of badges.json and the game files. */
const LEDGER_VERSION = 1;

/** How long badges.json rewrites coalesce.  A burst of badges linking at once
 *  is one write, and the events file has already durably taken every one. */
const SNAPSHOT_DEBOUNCE_MS = 1_000;

/**
 * Compact ISO 8601, safe in a filename and sorted correctly by name:
 * 2026-09-04T12:00:00.123Z -> 20260904T120000123Z.
 */
function stamp(date = new Date()) {
  return date.toISOString().replace(/[-:]/g, "").replace(".", "");
}

/**
 * The ledger's verbs, in one list because two things are built from it: the
 * real Ledger and the NULL_LEDGER below.  The assertion at the bottom of this
 * file checks they have not drifted, so adding a verb cannot leave the
 * hardware-free harnesses calling a hole.
 */
const LEDGER_VERBS = [
  "badgeLinked",
  "badgeStat",
  "badgeUnlinked",
  "onboardCommitted",
  "onboardFailed",
  "powerupGrantPass",
  "powerupGranted",
  "gameOpened",
  "badgeSeated",
  "badgeObserving",
  "scoreDelivered",
  "scoreBanked",
  "scoreFailed",
  "gameClosed",
  "flush",
  "stop",
];

/**
 * A ledger that records nothing, for the test harnesses that drive a real
 * Controller with no filesystem behind it (web/test/stat_harness.mjs and
 * friends), and for any future caller that wants the machinery off.
 *
 * Frozen so a caller cannot quietly turn it into a spy and start depending on
 * ledger reads by the back door.
 */
const NULL_LEDGER = Object.freeze(Object.fromEntries(
  LEDGER_VERBS.map((verb) => [verb, () => Promise.resolve()]),
));

/**
 * Write `text` to `file` such that a reader always sees either the previous
 * contents or the new ones, never a mixture.
 *
 * With `backup`, the previous contents also survive as `<file>.bak`, and the
 * copy happens BEFORE the rename so that `file` is never absent: a crash
 * between the two leaves a stale-but-whole file and a matching .bak, which is
 * the mildest failure available here.
 *
 * That is worth it for badges.json — every badge's history is in one file,
 * rewritten constantly — and is actively wrong for a game file, which is
 * written twice in its life and lives in a directory whose file COUNT is
 * meaningful.  A .bak beside each game would double the apparent number of
 * games played, in the one place someone would go to count them.
 */
async function writeAtomic(file, text, fsync, backup = false) {
  const tmp = `${file}.tmp`;
  const handle = await fsp.open(tmp, "w");
  try {
    await handle.writeFile(text, "utf8");
    if (fsync) await handle.sync();
  } finally {
    await handle.close();
  }
  if (backup) {
    try {
      await fsp.copyFile(file, `${file}.bak`);
    } catch (err) {
      if (err.code !== "ENOENT") throw err; // no previous copy on the first write
    }
  }
  await fsp.rename(tmp, file);
}

/**
 * Read a badges.json, or null when it is absent, unparseable, or not shaped
 * like one.
 *
 * The shape check is part of "readable" on purpose: a file that parses but has
 * no `badges` map cannot be loaded, and treating that as success would leave
 * the ledger running on an empty document and overwrite the real record with
 * it on the next snapshot.
 */
async function readSnapshot(file) {
  let raw;
  try {
    raw = await fsp.readFile(file, "utf8");
  } catch {
    return null;
  }
  let doc;
  try {
    doc = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof doc !== "object" || doc === null) return null;
  if (typeof doc.badges !== "object" || doc.badges === null) return null;
  return doc;
}

class Ledger {
  /**
   * @param {object} opts
   * @param {string} opts.dir    BADGE_LOG_DIR
   * @param {boolean} [opts.fsync]  fsync every write.  Off by default: it buys
   *   survival of the very last event across a hard power cut, at the price of
   *   SD-card write amplification on every one of them.
   */
  constructor({ dir, fsync = false }) {
    this.dir = dir;
    this.gamesDir = path.join(dir, "games");
    this.snapshotFile = path.join(dir, "badges.json");
    this.fsync = fsync;

    /** badges.json, in memory.  Mutated only inside the queue. */
    this.doc = { version: LEDGER_VERSION, updatedAt: null, badges: {} };
    /** Game files currently open, by gameId.  @type {Map<string, object>} */
    this.openGames = new Map();

    this.eventsFile = path.join(dir, `events-${stamp()}.jsonl`);
    /** Append handle for eventsFile, opened on first use. */
    this.eventsHandle = null;

    this.seq = 0;
    this.snapshotTimer = null;
    this.snapshotDirty = false;
    this.stopped = false;

    /** Tail of the one write chain.  Never rejects; see enqueue. */
    this.queue = Promise.resolve();
    // Queued, not awaited: construction stays synchronous so a caller cannot
    // hold a half-built ledger, and every verb queues behind this anyway.
    // Anyone needing to know it has finished awaits flush().
    this.enqueue(() => this.#init());
  }

  // ---- Plumbing -------------------------------------------------------------

  /**
   * Run `fn` after everything already queued.  Failures are logged and
   * swallowed: one unwritable event must not poison every later one, and must
   * never surface as a rejection in the middle of a game.
   */
  enqueue(fn) {
    this.queue = this.queue.then(fn).catch((err) => {
      console.error("[ledger] write failed:", err.message);
    });
    return this.queue;
  }

  /**
   * Load the previous run's snapshot and open this run's events file.
   *
   * PRIVATE, and private the enforced way rather than the polite way: running
   * it twice moves the same unreadable badges.json aside twice, the second
   * failing on a file that is no longer there.  There is no legitimate second
   * caller, so there should be no way to be one.
   */
  async #init() {
    await fsp.mkdir(this.gamesDir, { recursive: true }); // makes this.dir too

    // The .bak is tried second because writeAtomic guarantees it is the
    // PREVIOUS whole copy: at worst one debounce interval stale, and the
    // events file covers that gap.
    const loaded = await readSnapshot(this.snapshotFile) ??
      await readSnapshot(`${this.snapshotFile}.bak`);

    if (loaded !== null) {
      this.doc = {
        version: LEDGER_VERSION,
        updatedAt: loaded.updatedAt ?? null,
        badges: loaded.badges,
      };
    } else {
      // Neither copy is loadable.  Distinguish "first run" from "there is a
      // file there and it is unreadable": the second must be moved aside
      // rather than silently overwritten, because it is a record, and an
      // unreadable record may still be recoverable by hand.
      let present = true;
      try {
        await fsp.access(this.snapshotFile);
      } catch {
        present = false;
      }
      if (present) {
        const aside = `${this.snapshotFile}.corrupt-${stamp()}`;
        await fsp.rename(this.snapshotFile, aside);
        console.error(`[ledger] badges.json unreadable; moved to ${path.basename(aside)}`);
      }
    }

    const repaired = this.repairOpenConnections();
    await this.append({ type: "bridge_started", events: path.basename(this.eventsFile), repaired });
    this.markDirty();
  }

  /**
   * Close connections the last run left open.  A bridge that is killed never
   * writes a disconnectedAt, so on load anything still open is a remnant of
   * that death — during normal running, repair does not run at all.
   *
   * `disconnectedAt` stays null rather than being set to now: we know the
   * connection ended, we do not know when, and a plausible-looking timestamp
   * would be a fabrication in a file whose whole job is to be trustworthy.
   *
   * @returns {number} connections repaired
   */
  repairOpenConnections() {
    let repaired = 0;
    for (const badge of Object.values(this.doc.badges)) {
      for (const conn of badge.connections ?? []) {
        if (conn.endedBy === null || conn.endedBy === undefined) {
          conn.endedBy = "bridge_exit";
          repaired++;
        }
      }
    }
    return repaired;
  }

  /** Append one event line.  Called only from inside the queue. */
  async append(event) {
    const line = JSON.stringify({
      at: new Date().toISOString(),
      seq: ++this.seq,
      ...event,
    });
    if (this.eventsHandle === null) {
      this.eventsHandle = await fsp.open(this.eventsFile, "a");
    }
    await this.eventsHandle.appendFile(`${line}\n`, "utf8");
    if (this.fsync) await this.eventsHandle.sync();
  }

  /** badges.json has changed; schedule the coalesced rewrite. */
  markDirty() {
    this.snapshotDirty = true;
    if (this.snapshotTimer !== null || this.stopped) return;
    this.snapshotTimer = setTimeout(() => {
      this.snapshotTimer = null;
      this.enqueue(() => this.writeSnapshot());
    }, SNAPSHOT_DEBOUNCE_MS);
    // Never hold the process open for a debounce: the shutdown path flushes.
    if (typeof this.snapshotTimer.unref === "function") this.snapshotTimer.unref();
  }

  async writeSnapshot() {
    if (!this.snapshotDirty) return;
    this.snapshotDirty = false;
    this.doc.updatedAt = new Date().toISOString();
    await writeAtomic(
      this.snapshotFile, `${JSON.stringify(this.doc, null, 2)}\n`, this.fsync, true);
  }

  async writeGame(game) {
    await writeAtomic(
      path.join(this.gamesDir, `${game.gameId}.json`),
      `${JSON.stringify(game, null, 2)}\n`,
      this.fsync,
    );
  }

  // ---- Badge record helpers (queue-internal) --------------------------------

  /**
   * The badge's record, created on first sight.
   *
   * `uidSource` rides along because a uid is only an identity when it is the
   * board's USB serial number (the RP2040 flash unique id).  When serialport
   * reports no serial number the uid falls back to the port PATH, which a
   * different badge inherits the next time one is plugged into that port — so
   * a path-sourced record is a record of a PORT, and saying so in the file is
   * the only thing that stops a later reader reading it as a badge.
   */
  badgeRecord(uid, uidSource) {
    let badge = this.doc.badges[uid];
    if (badge === undefined) {
      badge = {
        uid,
        uidSource,
        firstSeenAt: new Date().toISOString(),
        lastSeenAt: null,
        connectionCount: 0,
        state: null,
        totals: { games: 0, onboarded: 0, powerupsGranted: {}, scoresBanked: 0 },
        games: [],
        connections: [],
      };
      this.doc.badges[uid] = badge;
    } else if (uidSource !== undefined && badge.uidSource !== uidSource) {
      // A badge whose serial number appeared or vanished between plugs is two
      // different identity claims about one record.  Recorded rather than
      // resolved: the file should show that it happened.
      badge.uidSourceChangedTo = uidSource;
      badge.uidSource = uidSource;
    }
    badge.lastSeenAt = new Date().toISOString();
    return badge;
  }

  /** The badge's currently open connection for `link`, or null. */
  openConnection(badge, link) {
    for (let i = badge.connections.length - 1; i >= 0; i--) {
      const conn = badge.connections[i];
      if (conn.link === link && conn.endedBy === null) return conn;
    }
    return null;
  }

  // ---- Badge lifecycle -----------------------------------------------------

  /**
   * A board completed the CTRL:HELLO handshake.  OPENS a connection record.
   *
   * The record is opened here and stat-stamped later, rather than written once
   * when everything is known, because at this instant nothing IS known:
   * CTRL:STAT is a separate, later serial line (up to STAT_WAIT_MS behind, and
   * absent forever on old firmware).  A single point-in-time record would
   * therefore either be empty or would have to wait on a report that may never
   * come.
   */
  badgeLinked({ uid, uidSource, port, link }) {
    return this.enqueue(async () => {
      const badge = this.badgeRecord(uid, uidSource);
      // Defensive: a drop always precedes a relink, so an already-open
      // connection here means one was never closed.  Say so rather than
      // leaving two open records for one board.
      for (const conn of badge.connections) {
        if (conn.endedBy === null) conn.endedBy = "superseded";
      }
      badge.connectionCount++;
      badge.connections.push({
        link,
        port,
        connectedAt: new Date().toISOString(),
        disconnectedAt: null,
        endedBy: null,
        durationMs: null,
        state: null,
      });
      await this.append({ type: "badge_linked", badge: uid, uidSource, port, link });
      this.markDirty();
    });
  }

  /**
   * A board reported its flash stats — or was given up on waiting for.
   *
   * @param {object} a
   * @param {string} a.uid
   * @param {number} a.link
   * @param {object} a.state  boardStateView(ctrl): what the badge SAID
   * @param {boolean} a.statReported  false when the CTRL:STAT wait expired and
   *   `state` is therefore this side's defaults rather than a badge's report
   * @param {"badge" | "dev_inject"} a.source  where the claim came from, so a
   *   developer's /api/dev/inject override is never mistaken for a real report
   */
  badgeStat({ uid, link, state, statReported, source }) {
    return this.enqueue(async () => {
      const badge = this.badgeRecord(uid);
      const reportedAt = new Date().toISOString();
      const stamped = { ...state, reportedAt, statReported, source };
      badge.state = stamped;
      const conn = this.openConnection(badge, link);
      if (conn !== null) conn.state = stamped;
      await this.append({
        type: "badge_stat", badge: uid, link, statReported, source, state,
      });
      this.markDirty();
    });
  }

  /** The port went away or the link died.  CLOSES the connection record. */
  badgeUnlinked({ uid, link, reason }) {
    return this.enqueue(async () => {
      const badge = this.badgeRecord(uid);
      const conn = this.openConnection(badge, link);
      let durationMs = null;
      if (conn !== null) {
        const at = new Date();
        conn.disconnectedAt = at.toISOString();
        conn.endedBy = reason;
        durationMs = at.getTime() - new Date(conn.connectedAt).getTime();
        conn.durationMs = durationMs;
      }
      await this.append({ type: "badge_unlinked", badge: uid, link, reason, durationMs });
      this.markDirty();
    });
  }

  // ---- Onboarding kiosk ----------------------------------------------------

  /**
   * A palette reached a badge's flash (CTRL:LED_ACK).
   *
   * Note what is NOT done: `badge.state.colors` is left alone.  The ack
   * carries only the roll id, so the badge has confirmed a save, not reported
   * a palette — and the recorded state is only ever what a badge said.  The
   * next link's CTRL:STAT updates the colours, from the flash, for real.
   */
  onboardCommitted({ uid, link, colors }) {
    return this.enqueue(async () => {
      const badge = this.badgeRecord(uid);
      badge.totals.onboarded++;
      await this.append({ type: "onboard_committed", badge: uid, link, colors });
      this.markDirty();
    });
  }

  onboardFailed({ uid, link, colors, reason }) {
    return this.enqueue(async () => {
      await this.append({ type: "onboard_failed", badge: uid, link, colors, reason });
    });
  }

  // ---- Powerup kiosk -------------------------------------------------------

  /** One press of a kiosk button: the fan-out as a whole. */
  powerupGrantPass({ kind, name, targets, granted, skipped }) {
    return this.enqueue(async () => {
      await this.append({ type: "powerup_grant_pass", kind, name, targets, granted, skipped });
    });
  }

  /**
   * One badge's outcome within that pass.
   *
   * `powerups` is refreshed onto the badge's recorded state on success, which
   * is legitimate where onboardCommitted's colours are not: CTRL:POWERUP_ACK
   * carries the badge's own RESULTING counts, so this is still a badge report
   * being mirrored rather than arithmetic done on this side.  A failure
   * carries whatever counts were last known and does not touch the record —
   * the badge is the authority and it did not answer.
   */
  powerupGranted({ uid, link, kind, name, ok, reason, powerups }) {
    return this.enqueue(async () => {
      const badge = this.badgeRecord(uid);
      if (ok) {
        badge.totals.powerupsGranted[name] = (badge.totals.powerupsGranted[name] ?? 0) + 1;
        if (badge.state !== null) {
          badge.state = {
            ...badge.state,
            powerups: [...powerups],
            reportedAt: new Date().toISOString(),
            source: "badge",
          };
        }
      }
      await this.append({
        type: "powerup_granted", badge: uid, link, kind, name, ok, reason, powerups,
      });
      this.markDirty();
    });
  }

  // ---- Games ---------------------------------------------------------------

  gameOpened({ gameId, roomCode, encounter }) {
    return this.enqueue(async () => {
      const game = {
        version: LEDGER_VERSION,
        gameId,
        roomCode,
        encounter,
        openedAt: new Date().toISOString(),
        endedAt: null,
        // null while the game is open.  A file left this way was never closed
        // — the bridge died holding it — which is why there is no startup
        // repair pass over the games directory: the file already says so.
        endedBy: null,
        badges: [],
        score: null,
        hatched: null,
        stats: null,
      };
      this.openGames.set(gameId, game);
      await this.append({ type: "game_opened", gameId, roomCode, encounter });
      await this.writeGame(game);
    });
  }

  /** This badge's entry in an open game, created on first mention. */
  gameBadge(game, uid, link) {
    let entry = game.badges.find((b) => b.uid === uid && b.link === link);
    if (entry === undefined) {
      entry = { uid, link, playerId: null, seated: false, seatedAt: null, state: null, scoreBanked: false };
      game.badges.push(entry);
    }
    return entry;
  }

  badgeSeated({ gameId, uid, link, playerId, state }) {
    return this.enqueue(async () => {
      const badge = this.badgeRecord(uid);
      badge.totals.games++;
      if (!badge.games.includes(gameId)) badge.games.push(gameId);
      const game = this.openGames.get(gameId);
      if (game !== undefined) {
        const entry = this.gameBadge(game, uid, link);
        entry.playerId = playerId;
        entry.seated = true;
        entry.seatedAt = new Date().toISOString();
        entry.state = state;
        await this.writeGame(game);
      }
      await this.append({ type: "badge_seated", gameId, badge: uid, link, playerId });
      this.markDirty();
    });
  }

  /** Linked, in the room, but the game was full: its buttons do nothing. */
  badgeObserving({ gameId, uid, link }) {
    return this.enqueue(async () => {
      const game = this.openGames.get(gameId);
      if (game !== undefined) {
        this.gameBadge(game, uid, link);
        await this.writeGame(game);
      }
      await this.append({ type: "badge_observing", gameId, badge: uid, link });
    });
  }

  /** GAME:SCORE put on the wire for a badge to bank. */
  scoreDelivered({ gameId, uid, link, gid, score, hatched }) {
    return this.enqueue(async () => {
      await this.append({
        type: "score_delivered", gameId, badge: uid, link, gid, score, hatched,
      });
    });
  }

  /** CTRL:SCORE_ACK: the badge saved it to flash. */
  scoreBanked({ gameId, uid, link, gid }) {
    return this.enqueue(async () => {
      const badge = this.badgeRecord(uid);
      badge.totals.scoresBanked++;
      const game = gameId === null ? undefined : this.openGames.get(gameId);
      if (game !== undefined) {
        this.gameBadge(game, uid, link).scoreBanked = true;
        await this.writeGame(game);
      }
      await this.append({ type: "score_banked", gameId, badge: uid, link, gid });
      this.markDirty();
    });
  }

  /**
   * The retries ran out.  NOT proof the badge lacks the score: the ack may
   * have been lost after the save, exactly as controllers.js documents for
   * powerups.  Recorded as an unanswered delivery, which is what it is.
   */
  scoreFailed({ gameId, uid, link, gid, reason }) {
    return this.enqueue(async () => {
      await this.append({ type: "score_failed", gameId, badge: uid, link, gid, reason });
    });
  }

  gameClosed({ gameId, score, stats, hatched, endedBy = "game_over" }) {
    return this.enqueue(async () => {
      const game = this.openGames.get(gameId);
      await this.append({ type: "game_closed", gameId, endedBy, score, hatched });
      if (game === undefined) return;
      this.openGames.delete(gameId);
      game.endedAt = new Date().toISOString();
      game.endedBy = endedBy;
      game.score = score;
      // Kept alongside `stats` rather than left to be re-derived from it: this
      // is the exact array that was written to the badges, per BabyType
      // ordinal, and the mapping from the server's named stats to those
      // ordinals lives in controllers.js.  A reader of this file should not
      // have to reimplement it to find out what each badge was given.
      game.hatched = hatched ?? null;
      game.stats = stats;
      await this.writeGame(game);
    });
  }

  // ---- Shutdown ------------------------------------------------------------

  /** Settle every queued write, including any debounced snapshot. */
  flush() {
    if (this.snapshotTimer !== null) {
      clearTimeout(this.snapshotTimer);
      this.snapshotTimer = null;
    }
    return this.enqueue(() => this.writeSnapshot());
  }

  /**
   * Wait until the queue is EMPTY, not merely until the work outstanding right
   * now has settled.
   *
   * The difference is the whole reason this exists.  Awaiting `this.queue`
   * once resolves when the writes queued at that instant are done — but a
   * badge acking a score as the kiosk goes down enqueues its event a tick
   * later, behind that point, and a shutdown that only awaited the first
   * promise would walk away while the most interesting event of the run was
   * still in the chain.
   *
   * Terminates when writes stop arriving.  Nothing in a shutdown generates
   * them indefinitely, and the SIGTERM handler in index.js carries a timeout
   * for the case where something does.
   */
  async drain() {
    let tail;
    do {
      tail = this.queue;
      await tail;
    } while (tail !== this.queue);
  }

  /**
   * Close the ledger for a deliberate exit: every open connection and game is
   * closed as such, so the file distinguishes a clean shutdown from a kill.
   */
  stop(reason) {
    if (this.stopped) return this.queue;
    this.stopped = true;
    this.enqueue(async () => {
      const at = new Date();
      for (const badge of Object.values(this.doc.badges)) {
        for (const conn of badge.connections) {
          // Closed with a REAL timestamp, unlike repairOpenConnections: a
          // deliberate stop happens at a known moment, and the badge was still
          // plugged in at it.  Only the crash path has to leave the end blank.
          if (conn.endedBy !== null) continue;
          conn.disconnectedAt = at.toISOString();
          conn.endedBy = "bridge_stopped";
          conn.durationMs = at.getTime() - new Date(conn.connectedAt).getTime();
        }
      }
      for (const game of this.openGames.values()) {
        game.endedAt = at.toISOString();
        game.endedBy = "bridge_stopped";
        await this.writeGame(game);
      }
      this.openGames.clear();
      await this.append({ type: "bridge_stopped", reason });
    });
    return (async () => {
      // Drain BEFORE the final snapshot, so that anything which arrived during
      // shutdown is in `doc` when it is written; then drain again, because
      // writing the snapshot is itself queued work.
      await this.drain();
      await this.flush();
      await this.drain();
      // Closed last, and only once nothing is left to write.  A handle closed
      // while an append was still queued behind it would lose exactly the
      // late-arriving event this drain exists to catch.
      if (this.eventsHandle !== null) {
        await this.eventsHandle.close().catch(() => {});
        this.eventsHandle = null;
      }
    })();
  }
}

// One list, two implementations: prove they agree at load rather than at the
// first call from a code path nobody ran.
for (const verb of LEDGER_VERBS) {
  if (typeof Ledger.prototype[verb] !== "function") {
    throw new Error(`ledger.js: LEDGER_VERBS lists '${verb}' but Ledger has no such method`);
  }
}

module.exports = { Ledger, NULL_LEDGER, LEDGER_VERBS, LEDGER_VERSION, stamp };
