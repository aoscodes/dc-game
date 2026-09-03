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
// The colour maths and the palette roll live in palette.js, shared with the
// game (which rolls baby palettes under the same rules).  This file owns the
// SPIN: how the zones travel to the colours palette.js picked.
//
// Extracted by name in web/test/palette_harness.mjs, which is why the spin
// maths lives in plain top-level functions with no DOM in sight.

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

// Design space, mirroring game.js: all drawing below is in these coordinates
// and the backing store scale is applied once as a transform.  Same cabinet
// panel as the game, so the same 1024x600 at 1:1 — see the note on
// LAYOUT.screen in game.js for why this is not supersampled.
const LAYOUT = {
  screen: { w: 1024, h: 600 },
  renderScale: 1,
  // One zone per colour in the palette, which is one per LED on the badge.
  // Taken from palette.js rather than restated so the screen cannot end up
  // showing a different number of colours than the roll produces.
  zones: PALETTE_SIZE,
  status: { h: 96, font: "600 30px system-ui, -apple-system, sans-serif" },
  hint: { font: "400 20px system-ui, -apple-system, sans-serif" },
};

// The colour maths this page spins through — hslToRgb, luminance, rgbToHex,
// the hue helpers, the PRNG, HARMONY and rollPalette — lives in palette.js,
// loaded before this file.  It moved there when the game started rolling baby
// palettes from the same rules: the roll became a contract between two pages
// rather than this page's private business.  Only rgbToCss stayed, because
// only this page paints with a canvas fill string.

/** [r,g,b] -> a canvas fill string. */
function rgbToCss(rgb) {
  return `rgb(${rgb[0]}, ${rgb[1]}, ${rgb[2]})`;
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
