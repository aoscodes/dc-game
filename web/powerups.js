// Powerup kiosk (/powerups).
//
// One rectangular button per powerup. Pressing one hands that powerup to every
// badge currently plugged into this bridge, and the badge banks it in flash.
//
// Deliberately standalone, on /onboard's terms: no lobby, no game, no Zig
// process. Handing out an item is a thing done to BADGES, and a badge carries
// what it carries whether or not a game is running.
//
// THIS PAGE OWNS NO COUNTS. Every number it shows arrived from the bridge,
// which got it from a badge's own post-save ack. Nothing here adds one to
// anything. That is not fastidiousness — the badge's flash is the only copy of
// a powerup count, it survives this page, this bridge process and every game
// played on it, and it saturates at 255. A tally kept here would be a second
// copy that is wrong the first time a badge is granted by another bridge run,
// reflashed, or filled up.
//
// The button list is not hardcoded either: the bridge publishes {ordinal,
// name} pairs and the page sends the ORDINAL back. The ordinal is the wire and
// flash identity all the way down to the firmware's powerup_kind_t, so a page
// with its own idea of the list could hand out the wrong item; a page with no
// idea at all cannot.
//
// Plain browser script, no modules — the same house rule as onboard.js and
// game.js.

const boardsEl = document.getElementById("boards");
const buttonsEl = document.getElementById("buttons");
const logEl = document.getElementById("log");

/** Page state. Everything here is told to us; nothing is derived. */
const S = {
  connected: false,
  /** [{ordinal, name}], from the bridge. Empty until it says. */
  kinds: [],
  /** Badges linked to the bridge right now, from the bridge. */
  boards: 0,
  /** True while a grant is in flight: buttons are locked for the duration. */
  granting: false,
};

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/**
 * Whether a press can do anything right now.
 *
 * Locking during a grant is the page's half of not double-granting; the
 * bridge serialises grants as well, so a press that slips through queues
 * rather than racing. Two defences because the failure is not recoverable:
 * a powerup handed out twice cannot be taken back off a badge.
 */
function canGrant() {
  return S.connected && !S.granting && S.boards > 0;
}

function renderBoards() {
  if (!S.connected) {
    boardsEl.textContent = "connecting to the bridge…";
    boardsEl.className = "";
    return;
  }
  if (S.boards === 0) {
    boardsEl.textContent = "no badges plugged in — plug one in to grant";
    boardsEl.className = "none";
    return;
  }
  boardsEl.textContent =
    `${S.boards} badge${S.boards === 1 ? "" : "s"} linked; a press grants to all of them`;
  boardsEl.className = "";
}

function renderButtons() {
  buttonsEl.textContent = "";
  for (const k of S.kinds) {
    const btn = document.createElement("button");
    btn.className = "powerup";
    btn.textContent = `+1  ${k.name}`;
    btn.disabled = !canGrant();
    btn.addEventListener("click", () => grant(k));
    buttonsEl.appendChild(btn);
  }
  if (S.kinds.length === 0) {
    const p = document.createElement("p");
    p.textContent = "this bridge published no powerups";
    buttonsEl.appendChild(p);
  }
}

/** Refresh only the disabled state, so a press does not rebuild the list. */
function syncButtons() {
  const enable = canGrant();
  for (const btn of buttonsEl.querySelectorAll("button.powerup")) {
    btn.disabled = !enable;
  }
}

/**
 * Append a line to the grant log.
 *
 * Never cleared and never rewritten: this is the page's copy of the record the
 * bridge is printing to its stdout, and the operator's only way to answer "did
 * that badge get it?" after the fact.
 */
function log(text, cls) {
  const line = document.createElement("div");
  if (cls !== undefined) line.className = cls;
  line.textContent = text;
  logEl.appendChild(line);
  logEl.scrollTop = logEl.scrollHeight;
}

/** "neutralizer canister=3 shield=0" for one badge's reported counts. */
function countsText(counts) {
  return counts
    .map((n, i) => `${S.kinds[i]?.name ?? `kind ${i}`}=${n}`)
    .join("  ");
}

// ---------------------------------------------------------------------------
// Granting
// ---------------------------------------------------------------------------

function grant(kind) {
  if (!canGrant()) return;
  S.granting = true;
  syncButtons();
  log(`granting 1 ${kind.name} to ${S.boards} badge(s)…`, "head");
  send({ action: "grant", kind: kind.ordinal });
}

/**
 * A grant finished. `results` is one entry per badge the bridge targeted,
 * carrying that badge's own counts.
 *
 * A badge that failed is reported as a failure and NOT retried automatically.
 * A grant that ran out of retries may well have reached flash — the ack is
 * what went missing, not necessarily the save — so retrying on the operator's
 * behalf risks the one outcome that cannot be undone. The operator can press
 * again, having read the counts.
 */
function onGranted(msg) {
  S.granting = false;
  const name = S.kinds[msg.kind]?.name ?? `kind ${msg.kind}`;
  const results = Array.isArray(msg.results) ? msg.results : [];
  const ok = results.filter((r) => r.ok).length;
  log(`${ok}/${results.length} badge(s) banked 1 ${name}`, "head");
  for (const r of results) {
    const counts = Array.isArray(r.powerups) ? countsText(r.powerups) : "";
    log(
      `  uid=${r.uid} link=${r.linkId} ` +
      `${r.ok ? "ok" : `FAILED (${r.reason})`}  ${counts}`,
      r.ok ? "ok" : "fail",
    );
  }
  if (results.length === 0) log("  nothing to grant to", "fail");
  syncButtons();
}

// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

let ws = null;

function send(obj) {
  if (ws !== null && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function onMessage(msg) {
  switch (msg.tag) {
    case "kinds":
      S.kinds = Array.isArray(msg.kinds) ? msg.kinds : [];
      renderButtons();
      return;
    case "boards":
      S.boards = typeof msg.count === "number" ? msg.count : 0;
      renderBoards();
      syncButtons();
      return;
    case "granted":
      onGranted(msg);
      return;
    default:
      console.warn("[powerups] unknown message", msg);
  }
}

function connect() {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(`${proto}//${location.host}/powerups-ws`);

  ws.addEventListener("open", () => {
    S.connected = true;
    renderBoards();
    syncButtons();
    console.log("[powerups] connected to bridge");
  });
  ws.addEventListener("close", () => {
    S.connected = false;
    S.boards = 0;
    // A grant in flight when the socket dropped has no answer coming. It is
    // NOT reported as failed, because it was very likely banked — the bridge
    // kept running and its stdout has the truth. The lock is released so the
    // page is usable again once reconnected.
    if (S.granting) {
      S.granting = false;
      log("lost the bridge mid-grant; see the bridge log for what landed", "fail");
    }
    renderBoards();
    syncButtons();
    setTimeout(connect, 1000);
  });
  ws.addEventListener("error", (e) => console.error("[powerups] ws error", e));
  ws.addEventListener("message", (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    if (typeof msg !== "object" || msg === null) return;
    onMessage(msg);
  });
}

renderBoards();
renderButtons();
connect();
