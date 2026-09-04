"use strict";

// The kiosk exit: hold the invisible top-left button on the station directory
// for HOLD_MS and the bridge closes the fullscreen browser to the desktop.
//
// The Pi has no keyboard and Chromium runs with --kiosk, so there is no tab
// bar, no address bar and no window chrome — getting to the desktop otherwise
// means SSH.  It is hidden rather than labelled because it lives on a screen
// an attendee is prodding, and a visible "Quit" on a kiosk gets pressed; the
// long hold is the affordance in place of a label, and it is also what keeps
// a resting palm from completing it.
//
// SPLIT IN TWO on purpose.  kioskExitController is the state machine and knows
// nothing about the DOM, fetch or timers — they arrive as dependencies — and
// kioskExitMessage is a pure mapping from an HTTP result to what an operator
// should read.  Both are extracted by name and driven directly by
// web/test/kiosk_harness.mjs; the wiring at the bottom of this file is the
// only part a browser is needed for.  The bugs worth catching here (a hold
// that fires after being released, a failure that queues a request per press)
// all live in the state machine, so the state machine is the part with no
// browser in it.

// ---------------------------------------------------------------------------
// Pure: what an operator should read
// ---------------------------------------------------------------------------

/**
 * Map a POST /api/kiosk/exit result to an operator-facing message.
 *
 * Returns null when there is nothing to say — the browser is about to be
 * killed, so success has no UI.
 *
 * @param {number} status HTTP status.
 * @param {{error?: string}} body Parsed JSON body, or {} if it did not parse.
 */
function kioskExitMessage(status, body) {
  if (status >= 200 && status < 300) return null;
  // 404 is the bridge saying the switch is not armed on this machine, which
  // is the one failure an operator can actually fix (and the expected answer
  // on the VPS, where there is no browser to close).  It is reported as its
  // own sentence rather than a bare 404 because "not found" reads as a bug.
  if (status === 404) {
    return "Kiosk exit is not enabled on this machine (KIOSK_STATE_DIR unset).";
  }
  const detail = (body && body.error) || `HTTP ${status}`;
  return `Could not close the kiosk: ${detail}`;
}

// ---------------------------------------------------------------------------
// The hold state machine
// ---------------------------------------------------------------------------

/**
 * Hold-to-confirm, with the browser injected.
 *
 * @param {object} deps
 * @param {number}   deps.holdMs      How long the button must be held.
 * @param {Function} deps.setTimer    setTimeout(fn, ms) -> handle.
 * @param {Function} deps.clearTimer  clearTimeout(handle).
 * @param {Function} deps.post        () -> Promise<string|null>; the message
 *                                    to show, or null on success.
 * @param {Function} deps.onHoldStart Called when a hold begins (show the arc).
 * @param {Function} deps.onHoldEnd   Called when it ends, completed or not.
 * @param {Function} deps.onError     Called with a message to show.
 * @returns {{press: Function, release: Function, isHolding: Function}}
 */
function kioskExitController(deps) {
  const {
    holdMs, setTimer, clearTimer, post, onHoldStart, onHoldEnd, onError,
  } = deps;

  let timer = null;
  // Guards the case the whole thing exists for failing gracefully in: on
  // success the browser dies and nothing can press again, but an unarmed or
  // broken switch is held repeatedly by an operator who cannot tell whether
  // it registered, and each of those must not stack another request.
  let inFlight = false;

  /** Give up on the current hold, if any.  Idempotent. */
  function release() {
    if (timer === null) return;
    clearTimer(timer);
    timer = null;
    onHoldEnd();
  }

  /** Begin a hold.  A second press while already holding is ignored, not
   *  treated as a restart: two pointers on the button would otherwise reset
   *  the timer and the hold could never finish. */
  function press() {
    if (timer !== null) return;
    timer = setTimer(complete, holdMs);
    onHoldStart();
  }

  function complete() {
    // Cleared BEFORE the request so release() during the flight is a no-op
    // rather than a clearTimer on a handle that already fired.
    timer = null;
    onHoldEnd();
    if (inFlight) return;
    inFlight = true;
    let settled = false;
    const done = () => { if (!settled) { settled = true; inFlight = false; } };
    Promise.resolve()
      .then(post)
      .then((message) => { done(); if (message) onError(message); })
      .catch((e) => { done(); onError(`Could not reach the bridge: ${e && e.message ? e.message : e}`); });
  }

  return { press, release, isHolding: () => timer !== null };
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

// Guarded so this file can be read by the harness (and by anything else
// without a document) without trying to bind to elements that are not there.
if (typeof document !== "undefined") {
  (() => {
    const HOLD_MS = 5000;

    const btn = document.getElementById("exit");
    const msg = document.getElementById("exit-msg");
    if (!btn || !msg) return;
    const arc = btn.querySelector(".arc");

    // The arc is a CSS transition; its duration comes from HOLD_MS so the
    // ring can never disagree with the timer that fires.
    if (arc) arc.style.transitionDuration = `${HOLD_MS}ms`;

    let hideMsg = null;
    function showError(text) {
      msg.textContent = text;
      msg.hidden = false;
      // Long enough to read, short enough that an operator's failed attempt
      // is not still on screen when players walk up.
      if (hideMsg !== null) clearTimeout(hideMsg);
      hideMsg = setTimeout(() => { msg.hidden = true; hideMsg = null; }, 8000);
    }

    const ctl = kioskExitController({
      holdMs: HOLD_MS,
      setTimer: (fn, ms) => setTimeout(fn, ms),
      clearTimer: (h) => clearTimeout(h),
      onHoldStart: () => { msg.hidden = true; btn.classList.add("holding"); },
      onHoldEnd: () => { btn.classList.remove("holding"); },
      onError: showError,
      post: async () => {
        const res = await fetch("/api/kiosk/exit", { method: "POST" });
        const body = res.ok ? {} : await res.json().catch(() => ({}));
        return kioskExitMessage(res.status, body);
      },
    });

    btn.addEventListener("pointerdown", (e) => {
      // isPrimary drops extra fingers; button 0 drops right/middle click.
      if (!e.isPrimary || e.button !== 0) return;
      e.preventDefault();
      // Capture so a finger drifting off a 96px target part-way through does
      // not silently throw away five seconds of holding.
      try { btn.setPointerCapture(e.pointerId); } catch { /* not captureable */ }
      ctl.press();
    });

    // pointerup: released early.  pointercancel: the browser took the gesture
    // (a scroll, a system edge swipe).  Neither completed the hold.
    btn.addEventListener("pointerup", () => ctl.release());
    btn.addEventListener("pointercancel", () => ctl.release());

    // A long press IS the interaction, so the menu it would otherwise raise is
    // never wanted.  In JS as well as CSS: Firefox ignores
    // -webkit-touch-callout.
    btn.addEventListener("contextmenu", (e) => e.preventDefault());
  })();
}
