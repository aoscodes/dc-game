// Badge onboarding kiosk (/onboard).
//
// Three equal full-height zones, one per RGB LED on the badge, spin
// independently through the colour spectrum and land on a harmonic triad.  The
// colours stream to the badge's LEDs live while they spin, and are written to
// its flash when they land.
//
// Deliberately standalone: this file shares nothing with game.js and game.js
// knows nothing about it.  The kiosk has no lobby, no server, no player — it
// is a colour picker that happens to be spring-loaded.
//
// THE QUEUE RULE.  The bridge addresses badges by LINK id, never by badge
// identity, and this page keeps a set of link ids it has finished with.  That
// one decision is what makes the whole flow behave:
//
//   - a badge left plugged in keeps its link id, so it is rolled exactly once;
//   - unplug and replug it and it arrives as a NEW link id, so it is rolled
//     again — which is how you deliberately reroll a badge you dislike;
//   - a badge unplugged mid-spin simply stops resolving, so it is skipped;
//   - a badge plugged in while the kiosk is idle starts a roll on arrival.
//
// Nothing here tracks which physical badge is which, and nothing needs to.
//
// Extracted by name in web/test/palette_harness.mjs, which is why the colour
// maths lives in plain top-level functions with no DOM in sight.

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

// Design space, mirroring game.js: all drawing below is in these coordinates
// and the 2x backing store is applied once as a transform.
const LAYOUT = {
  screen: { w: 1024, h: 768 },
  renderScale: 2,
  zones: 3,
  status: { h: 96, font: "600 30px system-ui, -apple-system, sans-serif" },
  hint: { font: "400 20px system-ui, -apple-system, sans-serif" },
};

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

/**
 * HSL -> 8-bit RGB.  Hue in degrees (any range, wrapped), s/l in 0..1.
 * @returns {number[]} [r, g, b], each 0..255
 */
function hslToRgb(h, s, l) {
  const hp = ((((h % 360) + 360) % 360)) / 60;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs((hp % 2) - 1));
  const m = l - c / 2;
  let r = 0, g = 0, b = 0;
  if (hp < 1) { r = c; g = x; }
  else if (hp < 2) { r = x; g = c; }
  else if (hp < 3) { g = c; b = x; }
  else if (hp < 4) { g = x; b = c; }
  else if (hp < 5) { r = x; b = c; }
  else { r = c; b = x; }
  return [
    Math.round((r + m) * 255),
    Math.round((g + m) * 255),
    Math.round((b + m) * 255),
  ];
}

/** [r,g,b] -> "rrggbb", the wire form the firmware parses. */
function rgbToHex(rgb) {
  return rgb.map((v) => Math.max(0, Math.min(255, v)).toString(16).padStart(2, "0")).join("");
}

/** [r,g,b] -> a canvas fill string. */
function rgbToCss(rgb) {
  return `rgb(${rgb[0]}, ${rgb[1]}, ${rgb[2]})`;
}

/** Fold any hue onto 0..360. */
function wrapHue(h) {
  return ((h % 360) + 360) % 360;
}

/**
 * Signed shortest way round the colour wheel from `a` to `b`, in -180..180.
 * Used so a zone's final approach drifts the short way into its target
 * instead of doubling back across the wheel.
 */
function hueDelta(a, b) {
  return ((wrapHue(b - a) + 540) % 360) - 180;
}

/** Distance between two hues ignoring direction, 0..180. */
function hueSeparation(a, b) {
  return Math.abs(hueDelta(a, b));
}

// ---------------------------------------------------------------------------
// Randomness
// ---------------------------------------------------------------------------

/**
 * Small seedable PRNG.  Seeded rather than Math.random so the harness can
 * assert the harmony invariants over thousands of reproducible rolls — a
 * palette rule that holds "usually" is a palette rule that will eventually
 * hand a player three muddy browns.
 * @param {number} seed
 * @returns {() => number} uniform in [0, 1)
 */
function mulberry32(seed) {
  let a = seed >>> 0;
  return function next() {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Uniform in [lo, hi). */
function randRange(rand, lo, hi) {
  return lo + rand() * (hi - lo);
}

/** Uniform integer in [lo, hi]. */
function randInt(rand, lo, hi) {
  return lo + Math.floor(rand() * (hi - lo + 1));
}

/** Fisher-Yates, in place, returning the same array. */
function shuffle(rand, arr) {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    const t = arr[i]; arr[i] = arr[j]; arr[j] = t;
  }
  return arr;
}

// ---------------------------------------------------------------------------
// Harmony
// ---------------------------------------------------------------------------

/**
 * The rules a landed palette must satisfy.  These are not decoration: three
 * colours picked independently at random are, more often than not, ugly and —
 * worse on a badge with three small LEDs a few millimetres apart —
 * indistinguishable.  Every bound here is defending one of those two failures.
 */
const HARMONY = {
  // Hue offsets from a random base.  Classical schemes; the tightest pair in
  // the table is split-complementary's 150/210, 60 degrees apart.
  schemes: [
    [0, 120, 240], // triadic
    [0, 150, 210], // split-complementary
    [0, 90, 180],  // tetradic, three of four
  ],
  // Enough wobble that repeat rolls of one scheme do not look identical, small
  // enough that the scheme is still recognisable.
  hueJitterDeg: 8,
  // The floor the harness asserts, and it is TIGHT: the worst case is that
  // 60-degree pair jittered apart in opposite directions, 60 - 2*8 = 44, which
  // is what the harness actually observes. Widening the jitter or adding a
  // closer scheme breaks this immediately — which is the point of asserting it
  // rather than trusting the arithmetic to survive the next edit.
  minSeparationDeg: 44,
  // Saturated enough to read as a colour on a diffused LED, short of the
  // full-blast primaries that all look like "on".
  sat: [0.62, 0.88],
  // Kept off both ends: near-black loses the hue, near-white washes it out.
  lum: [0.42, 0.62],
  // Three colours of equal lightness read as one smear at a glance, so the
  // three are forced onto distinct steps.  2 * 0.08 fits inside the 0.20 band
  // above with room to spare, so this is always satisfiable.
  minLumGap: 0.08,
};

/**
 * Roll one harmonic triad.
 *
 * The lightness step deserves a note: rather than resampling until three
 * independent draws happen to be far enough apart (unbounded, and biased
 * towards the extremes), it draws three sorted offsets from the SLACK left
 * over after reserving the gaps, then adds the gaps back. That is exactly
 * uniform over the valid orderings and cannot fail.
 *
 * @param {() => number} rand
 * @returns {{h: number, s: number, l: number}[]} one entry per zone
 */
function rollPalette(rand) {
  const base = rand() * 360;
  const scheme = HARMONY.schemes[Math.floor(rand() * HARMONY.schemes.length)];
  const j = HARMONY.hueJitterDeg;
  const hues = scheme.map((off) => wrapHue(base + off + randRange(rand, -j, j)));

  const sats = hues.map(() => randRange(rand, HARMONY.sat[0], HARMONY.sat[1]));

  const [lo, hi] = HARMONY.lum;
  const gap = HARMONY.minLumGap;
  const slack = (hi - lo) - gap * (LAYOUT.zones - 1);
  const offsets = [];
  for (let i = 0; i < LAYOUT.zones; i++) offsets.push(rand());
  offsets.sort((a, b) => a - b);
  // Ascending by construction; shuffled so zone order carries no bias.
  const lums = shuffle(rand, offsets.map((u, i) => lo + u * slack + i * gap));

  const triad = hues.map((h, i) => ({ h, s: sats[i], l: lums[i] }));
  return shuffle(rand, triad);
}

// ---------------------------------------------------------------------------
// Spin
// ---------------------------------------------------------------------------

const SPIN = {
  duration: [1.8, 3.2], // seconds; per zone, so they never land together
  spins: [2, 4],        // whole trips round the wheel before the approach
  // Brownian wobble on top of the sweep, damped to nothing by the landing so
  // the final colour is exactly the one that gets banked.
  noiseDeg: 40,
  // The zone starts somewhere unrelated, so the sweep is visible from frame
  // one rather than easing out of the previous badge's colour.
  startSat: [0.55, 0.9],
  startLum: [0.4, 0.65],
};

/** Deceleration curve: fast, then a long slow settle onto the target. */
function easeOutQuint(p) {
  return 1 - Math.pow(1 - p, 5);
}

/**
 * A few detuned sines summed into a cheap smooth 1-D noise in about -1..1.
 * Enough to keep the wobble from looking like a sine, and deterministic per
 * zone so a redraw at the same timestamp gives the same colour.
 */
function makeNoise(rand) {
  const parts = [];
  for (let i = 0; i < 3; i++) {
    parts.push({ f: randRange(rand, 0.7, 3.0), p: rand() * Math.PI * 2, w: 1 / (i + 1) });
  }
  const norm = parts.reduce((s, o) => s + o.w, 0);
  return function noise(t) {
    let v = 0;
    for (const o of parts) v += o.w * Math.sin(t * o.f * Math.PI * 2 + o.p);
    return v / norm;
  };
}

/**
 * Build the per-zone spin that lands on `target`.
 * @param {() => number} rand
 * @param {{h: number, s: number, l: number}[]} target  from rollPalette
 */
function makeSpin(rand, target) {
  return target.map((to) => ({
    to,
    from: {
      h: rand() * 360,
      s: randRange(rand, SPIN.startSat[0], SPIN.startSat[1]),
      l: randRange(rand, SPIN.startLum[0], SPIN.startLum[1]),
    },
    spins: randInt(rand, SPIN.spins[0], SPIN.spins[1]),
    duration: randRange(rand, SPIN.duration[0], SPIN.duration[1]),
    noise: makeNoise(rand),
  }));
}

/**
 * Where one zone is at `t` seconds into the spin.
 * @returns {{h: number, s: number, l: number}}
 */
function spinSample(zone, t) {
  const p = Math.max(0, Math.min(1, t / zone.duration));
  const e = easeOutQuint(p);
  // spins * 360 dominates the shortest-way delta, so the sweep is always
  // forward through the spectrum rather than reversing near the end.
  const travel = zone.spins * 360 + hueDelta(zone.from.h, zone.to.h);
  const wobble = zone.noise(t) * Math.pow(1 - p, 2) * SPIN.noiseDeg;
  return {
    h: wrapHue(zone.from.h + travel * e + wobble),
    s: zone.from.s + (zone.to.s - zone.from.s) * e,
    l: zone.from.l + (zone.to.l - zone.from.l) * e,
  };
}

/** Every zone's colour at `t`. */
function spinColors(spin, t) {
  return spin.map((z) => spinSample(z, t));
}

/** True once the slowest zone has landed. */
function spinDone(spin, t) {
  return spin.every((z) => t >= z.duration);
}

/** HSL triple -> the "rrggbb" strings the wire carries. */
function paletteHex(hsls) {
  return hsls.map((c) => rgbToHex(hslToRgb(c.h, c.s, c.l)));
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/** How long a landed palette is held on screen before the next badge. */
const HOLD_SAVED_MS = 1400;
/** Longer on failure: the reason is worth reading. */
const HOLD_FAILED_MS = 2200;
/** Live frame cadence. Matches nothing on the board; it just has to beat the
 *  firmware's 500ms live-frame timeout with room for a few dropped writes. */
const LIVE_INTERVAL_MS = 50;

const S = {
  /** @type {"waiting"|"spinning"|"saving"|"saved"|"failed"|"busy"} */
  phase: "waiting",
  /** Link id being rolled right now, or null. */
  linkId: null,
  /** Link ids the bridge says are plugged in, in link order. */
  queue: [],
  /** Link ids this kiosk is finished with — banked, failed, or vanished. */
  done: new Set(),
  spin: null,
  /** The landed HSL triple, once the spin finishes. */
  palette: null,
  spinStartMs: 0,
  lastLiveMs: 0,
  holdUntil: 0,
  failReason: "",
  connected: false,
};

/** Link ids still owed a roll. */
function pendingLinks() {
  return S.queue.filter((id) => !S.done.has(id) && id !== S.linkId);
}

/** Begin rolling `linkId`. */
function startRoll(linkId, nowMs) {
  // Seeded off the clock and the link so each badge gets its own palette even
  // when two are onboarded in the same second.
  const rand = mulberry32((nowMs ^ (linkId * 0x9e3779b1)) >>> 0);
  S.linkId = linkId;
  S.spin = makeSpin(rand, rollPalette(rand));
  S.palette = null;
  S.spinStartMs = nowMs;
  S.lastLiveMs = 0;
  S.phase = "spinning";
}

/** Finish with the current badge, whatever the outcome, and go idle. */
function finishRoll(holdMs, nowMs) {
  if (S.linkId !== null) S.done.add(S.linkId);
  S.linkId = null;
  S.holdUntil = nowMs + holdMs;
}

/**
 * Drive the state machine one frame.  Split out from the render loop and free
 * of DOM so the harness can step it.
 * @param {number} nowMs
 */
function step(nowMs) {
  if (S.phase === "busy") return;

  // The badge went away mid-roll: skip it. Its replacement, or its own replug,
  // arrives as a different link id and gets its own roll.
  if (S.linkId !== null && !S.queue.includes(S.linkId)
      && (S.phase === "spinning" || S.phase === "saving")) {
    S.phase = "failed";
    S.failReason = "unplugged";
    finishRoll(HOLD_FAILED_MS, nowMs);
    return;
  }

  if (S.phase === "spinning") {
    const t = (nowMs - S.spinStartMs) / 1000;
    if (spinDone(S.spin, t)) {
      S.palette = spinColors(S.spin, t);
      S.phase = "saving";
      send({ action: "commit", linkId: S.linkId, colors: paletteHex(S.palette) });
      return;
    }
    if (nowMs - S.lastLiveMs >= LIVE_INTERVAL_MS) {
      S.lastLiveMs = nowMs;
      send({ action: "live", linkId: S.linkId, colors: paletteHex(spinColors(S.spin, t)) });
    }
    return;
  }

  // saving: waiting on the board's post-save ack, routed in by the bridge.
  if (S.phase === "saving") return;

  // waiting / saved / failed: idle. Take the next badge once the hold is up.
  if (nowMs < S.holdUntil) return;
  const next = pendingLinks();
  if (next.length > 0) startRoll(next[0], nowMs);
  else if (S.phase !== "waiting") S.phase = "waiting";
}

/** @param {{tag: string, [k: string]: unknown}} msg */
function onMessage(msg, nowMs) {
  if (msg.tag === "busy") {
    S.phase = "busy";
    return;
  }
  if (msg.tag === "queue") {
    // Filtered to numbers, not just checked for being an array: every use of
    // the queue is an identity comparison against S.linkId, and a "3" that
    // slipped in would silently never match a 3 — the badge would look
    // unplugged forever rather than failing loudly.
    S.queue = Array.isArray(msg.links)
      ? msg.links.filter((id) => typeof id === "number")
      : [];
    // Link ids are monotonic and never reused, so ids that have left the queue
    // can be forgotten; without this the set grows for the life of the page.
    for (const id of [...S.done]) if (!S.queue.includes(id)) S.done.delete(id);
    return;
  }
  // Acks are matched by link id: a late ack for a badge we already gave up on
  // must not overwrite the state of the one we moved on to.
  if (msg.tag === "committed") {
    if (msg.linkId !== S.linkId || S.phase !== "saving") return;
    S.phase = "saved";
    finishRoll(HOLD_SAVED_MS, nowMs);
    return;
  }
  if (msg.tag === "commit_failed") {
    if (msg.linkId !== S.linkId || S.phase !== "saving") return;
    S.phase = "failed";
    S.failReason = typeof msg.reason === "string" ? msg.reason : "unknown";
    finishRoll(HOLD_FAILED_MS, nowMs);
    return;
  }
}

// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

let ws = null;

function send(obj) {
  if (ws !== null && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function connect() {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(`${proto}//${location.host}/onboard-ws`);

  ws.addEventListener("open", () => {
    S.connected = true;
    console.log("[onboard] connected to bridge");
  });
  ws.addEventListener("close", () => {
    S.connected = false;
    S.queue = [];
    // A refused kiosk stays refused: reconnecting would just spin on the
    // rejection, and the fix is to close the other tab, not to retry.
    if (S.phase !== "busy") setTimeout(connect, 1000);
  });
  ws.addEventListener("error", (e) => console.error("[onboard] ws error", e));
  ws.addEventListener("message", (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    if (typeof msg !== "object" || msg === null) return;
    onMessage(msg, performance.now());
  });
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

const canvas = document.getElementById("canvas");
const ctx = canvas.getContext("2d");

/**
 * Zone `i`'s slab, in design space.  Boundaries are rounded rather than the
 * widths, so the three always tile the screen exactly with no seam and no
 * overhang, whatever the rounding does.
 */
function zoneRect(i) {
  const sw = LAYOUT.screen.w;
  const x0 = Math.round((i * sw) / LAYOUT.zones);
  const x1 = Math.round(((i + 1) * sw) / LAYOUT.zones);
  return { x: x0, w: x1 - x0 };
}

/** The status line for the current phase. */
function statusText() {
  switch (S.phase) {
    case "busy": return "Another onboarding screen is already open";
    case "waiting": return S.connected
      ? (S.queue.length > 0 ? "All badges done — unplug to finish" : "Plug in a badge")
      : "Connecting to the bridge...";
    case "spinning": return "Choosing colours...";
    case "saving": return "Saving to badge...";
    case "saved": return "Saved";
    case "failed": return S.failReason === "unplugged"
      ? "Badge unplugged — skipped"
      : `Could not save (${S.failReason})`;
    default: return "";
  }
}

/** True when the three slabs should be on screen at all. */
function showingColors() {
  return S.phase === "spinning" || S.phase === "saving"
    || S.phase === "saved" || S.phase === "failed";
}

function draw(nowMs) {
  const { w, h } = LAYOUT.screen;
  ctx.setTransform(LAYOUT.renderScale, 0, 0, LAYOUT.renderScale, 0, 0);
  ctx.fillStyle = "rgb(8, 8, 10)";
  ctx.fillRect(0, 0, w, h);

  let colors = null;
  if (S.phase === "spinning" && S.spin !== null) {
    colors = spinColors(S.spin, (nowMs - S.spinStartMs) / 1000);
  } else if (S.palette !== null && showingColors()) {
    colors = S.palette;
  }

  if (colors !== null) {
    for (let i = 0; i < LAYOUT.zones; i++) {
      const { x, w: zw } = zoneRect(i);
      ctx.fillStyle = rgbToCss(hslToRgb(colors[i].h, colors[i].s, colors[i].l));
      ctx.fillRect(x, 0, zw, h);
    }
    // A failed badge keeps its colours on screen but greys them back, so the
    // status line reads as the subject rather than a footnote on a wall of
    // colour that never made it onto the badge.
    if (S.phase === "failed") {
      ctx.fillStyle = "rgba(8, 8, 10, 0.72)";
      ctx.fillRect(0, 0, w, h);
    }
  }

  // Status strip, always legible regardless of what is behind it.
  const sh = LAYOUT.status.h;
  ctx.fillStyle = "rgba(8, 8, 10, 0.82)";
  ctx.fillRect(0, h - sh, w, sh);
  ctx.fillStyle = "rgb(242, 244, 250)";
  ctx.font = LAYOUT.status.font;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(statusText(), w / 2, h - sh / 2);

  // The reroll affordance is not obvious, so say it out loud — but only when
  // there is nothing else happening.
  if (S.phase === "waiting" && S.connected && S.queue.length > 0) {
    ctx.fillStyle = "rgba(242, 244, 250, 0.55)";
    ctx.font = LAYOUT.hint.font;
    ctx.fillText("Replug a badge to roll it again", w / 2, h - sh - 34);
  }
}

function frame() {
  const now = performance.now();
  step(now);
  draw(now);
  requestAnimationFrame(frame);
}

connect();
requestAnimationFrame(frame);
