// Harness for the kiosk exit (web/kiosk.js).
//
// This is a KILL SWITCH on a machine standing in a hall, and both of its
// failure directions are bad in a way no other button on the kiosk is:
//
//   - fires when it should not — an attendee leaning on the corner of the
//     screen closes the game mid-round;
//   - fails to fire and says nothing — the operator holds it, gets no arc and
//     no message, and cannot tell the switch from a dead screen.
//
// So what is asserted here is the STATE MACHINE, not the drawing: that a hold
// released early never posts, that a completed hold posts exactly once, and
// that every non-2xx answer turns into a sentence an operator can act on.
//
// kioskExitController takes its timers, its transport and its callbacks as
// dependencies precisely so this file can drive it with none of them real —
// there is no DOM here, no fetch and no clock, so nothing is timing-dependent
// and nothing is left running.
import { readFileSync } from "node:fs";

// Resolved from THIS file, not the cwd: run by `zig build web-test` from the
// repo root and by hand from anywhere.
const src = readFileSync(new URL("../kiosk.js", import.meta.url), "utf8");

function extract(name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`missing ${name}`);
  let i = src.indexOf("{", start), depth = 0;
  for (; i < src.length; i++) { if (src[i] === "{") depth++; else if (src[i] === "}" && --depth === 0) break; }
  return src.slice(start, i + 1);
}

const load = (...names) =>
  new Function(`${names.map(extract).join("\n")}\nreturn {${names.join(",")}};`)();

const { kioskExitController, kioskExitMessage } = load(
  "kioskExitController", "kioskExitMessage");

let failures = 0;
function check(cond, what) {
  if (!cond) { failures++; console.log(`FAIL: ${what}`); }
}
function eq(a, b, what) {
  check(a === b, `${what} (got ${JSON.stringify(a)}, want ${JSON.stringify(b)})`);
}

const HOLD = 5000;

/**
 * A controller with a hand-cranked clock and a scripted transport.
 *
 * Timers are a list and `tick()` runs the ones that are due, so a "hold" is
 * an explicit press/advance/release rather than a real wait — the harness
 * cannot be flaky and the five seconds cost nothing.
 */
function mk({ post } = {}) {
  let now = 0;
  let nextHandle = 1;
  const timers = new Map();
  const events = [];
  const posts = [];

  const ctl = kioskExitController({
    holdMs: HOLD,
    setTimer: (fn, ms) => {
      const h = nextHandle++;
      timers.set(h, { fn, at: now + ms });
      return h;
    },
    clearTimer: (h) => { timers.delete(h); },
    onHoldStart: () => events.push("start"),
    onHoldEnd: () => events.push("end"),
    onError: (m) => events.push(`error:${m}`),
    post: () => {
      posts.push(now);
      return post ? post() : Promise.resolve(null);
    },
  });

  /** Advance the clock and run whatever came due. */
  function advance(ms) {
    now += ms;
    for (const [h, t] of [...timers]) {
      if (t.at <= now) { timers.delete(h); t.fn(); }
    }
  }
  // The controller's post() path is promise-chained, so settling it takes a
  // few microtask turns; awaiting a resolved promise a few times drains them
  // without any real time passing.
  const drain = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };

  return { ctl, advance, drain, events, posts, pending: () => timers.size };
}

// --- a hold released early must never post ---------------------------------
{
  const h = mk();
  h.ctl.press();
  h.advance(HOLD - 1);          // one millisecond short
  h.ctl.release();
  h.advance(HOLD * 10);         // and then all the time in the world
  eq(h.posts.length, 0, "released one ms early does not post");
  eq(h.events.join(","), "start,end", "an abandoned hold starts and ends");
  eq(h.pending(), 0, "an abandoned hold leaves no timer behind");
}

// --- a completed hold posts exactly once -----------------------------------
{
  const h = mk();
  h.ctl.press();
  h.advance(HOLD);
  await h.drain();
  eq(h.posts.length, 1, "a completed hold posts once");
  eq(h.events.join(","), "start,end", "a completed hold reports no error");
  eq(h.pending(), 0, "a completed hold leaves no timer behind");
}

// --- releasing AFTER completion is harmless --------------------------------
// The finger is still down when the timer fires: the real sequence is
// complete-then-pointerup, and the second must not undo or re-run anything.
{
  const h = mk();
  h.ctl.press();
  h.advance(HOLD);
  await h.drain();
  h.ctl.release();
  h.ctl.release();
  eq(h.posts.length, 1, "release after completion does not post again");
  eq(h.events.join(","), "start,end", "release after completion is a no-op");
}

// --- a second pointer must not restart the hold ----------------------------
// Two fingers on the button would otherwise keep resetting the timer, and the
// hold could never finish.
{
  const h = mk();
  h.ctl.press();
  h.advance(HOLD - 100);
  h.ctl.press();                // a second finger lands late
  h.advance(100);
  await h.drain();
  eq(h.posts.length, 1, "a second press does not restart the timer");
  eq(h.events.filter((e) => e === "start").length, 1, "only one hold began");
}

// --- repeated failures do not queue a request each -------------------------
// The case this guard exists for: an unarmed switch, held again and again by
// an operator who cannot tell whether it registered.
{
  let resolve;
  const h = mk({ post: () => new Promise((r) => { resolve = r; }) });

  h.ctl.press(); h.advance(HOLD); await h.drain();
  eq(h.posts.length, 1, "first hold posts");

  // A second hold completes while the first request is still in flight.
  h.ctl.press(); h.advance(HOLD); await h.drain();
  eq(h.posts.length, 1, "a hold during an in-flight request does not post again");

  // Once it settles, the switch is usable again — a failure must not be
  // permanent, or one 404 disables the exit until the page is reloaded.
  resolve("nope");
  await h.drain();
  check(h.events.includes("error:nope"), "the failure is reported");
  h.ctl.press(); h.advance(HOLD); await h.drain();
  eq(h.posts.length, 2, "the switch works again after a failure settles");
}

// --- a rejected request is reported, not swallowed -------------------------
{
  const h = mk({ post: () => Promise.reject(new Error("boom")) });
  h.ctl.press();
  h.advance(HOLD);
  await h.drain();
  check(h.events.some((e) => e.startsWith("error:") && e.includes("boom")),
    "a thrown request is reported to the operator");
  // Still usable afterwards.
  h.ctl.press(); h.advance(HOLD); await h.drain();
  eq(h.posts.length, 2, "the switch survives a thrown request");
}

// --- success says nothing --------------------------------------------------
// There is deliberately no "closing…" message: on success the browser is
// killed, and a message that only ever appears when it did NOT work is what
// makes the failure legible.
{
  const h = mk({ post: () => Promise.resolve(null) });
  h.ctl.press();
  h.advance(HOLD);
  await h.drain();
  check(!h.events.some((e) => e.startsWith("error:")), "success shows nothing");
}

// --- every answer maps to something an operator can act on -----------------
{
  eq(kioskExitMessage(200, {}), null, "200 has nothing to say");
  eq(kioskExitMessage(204, {}), null, "2xx has nothing to say");

  // The unarmed case must name the switch, not the HTTP status: "404" on a
  // button with no label tells an operator nothing.
  const unarmed = kioskExitMessage(404, {});
  check(unarmed !== null && unarmed.includes("KIOSK_STATE_DIR"),
    "404 names the setting that arms the switch");

  // The bridge's own diagnosis is passed through verbatim — it is the only
  // thing that distinguishes "no browser running" from "stale pidfile".
  check(kioskExitMessage(409, { error: "stale pidfile" }).includes("stale pidfile"),
    "the bridge's reason reaches the operator");

  // A body that did not parse must still produce a sentence, not "undefined".
  const bare = kioskExitMessage(500, {});
  check(bare.includes("500") && !bare.includes("undefined"),
    `a bodyless failure still reads as a sentence (got ${JSON.stringify(bare)})`);
  const nullBody = kioskExitMessage(502, null);
  check(nullBody.includes("502") && !nullBody.includes("undefined"),
    `a null body still reads as a sentence (got ${JSON.stringify(nullBody)})`);
}

if (failures > 0) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log("OK  kiosk: hold cancels clean, posts once, and every failure is legible");
