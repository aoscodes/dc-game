#!/usr/bin/env bash
# pi-kiosk.sh — launch the game in a fullscreen Chromium tab.
#
# Runs inside the pi user's Wayland (labwc) session, started from
# ~/.config/labwc/autostart by scripts/pi-setup.sh.  The bridge itself is a
# system service (slimefeast-bridge) and is NOT started here — this script
# only owns the browser.
#
# Two things make this more than a one-line chromium invocation, both of them
# lessons about a machine with no keyboard that gets its power cut nightly:
#
#   1. The session starts long before the bridge is listening, and Chromium
#      caches the failure — land on ERR_CONNECTION_REFUSED once and the kiosk
#      sits on an error page until someone reloads it.  So: wait for a real
#      HTTP 200 before launching.
#   2. An unclean shutdown leaves a crash flag in the profile, and the next
#      boot renders a "Restore pages?" bubble over the game with no input
#      device able to dismiss it.  So: scrub the flag every launch.

set -uo pipefail

# shellcheck source=/dev/null
[[ -r /etc/default/slimefeast ]] && . /etc/default/slimefeast

ROOT="${ROOT:-/opt/slimefeast}"
PORT="${PORT:-3000}"
KIOSK_URL="${KIOSK_URL:-http://localhost:${PORT}/}"
# How long to wait for the bridge before opening the browser anyway.  Giving
# up and launching beats staring at a blank desktop: a bridge that is merely
# slow will be picked up by Chromium's own retry, and one that is broken shows
# an error page an operator can actually see.
BRIDGE_WAIT="${BRIDGE_WAIT:-90}"
# Shell snippet run once before the browser, for display setup that is not
# yet decided (rotation, mode, overscan) — e.g.
#   DISPLAY_SETUP='wlr-randr --output HDMI-A-1 --transform 90'
# Empty by default: guessing a display config for a kiosk you have not seen
# is worse than leaving it at the compositor's own defaults.
DISPLAY_SETUP="${DISPLAY_SETUP:-}"

PROFILE="$ROOT/state/chromium"

log()  { printf '[pi-kiosk] %s\n' "$*"; }
warn() { printf '[pi-kiosk] WARN: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Resolve the browser
# ---------------------------------------------------------------------------

# Raspberry Pi OS ships the `chromium-browser` package (and its wrapper, which
# already applies the Pi's own hardware flags, so prefer it); plain Debian
# calls the binary `chromium`.
CHROMIUM=""
for candidate in chromium-browser chromium; do
  if command -v "$candidate" >/dev/null; then CHROMIUM="$candidate"; break; fi
done
[[ -n "$CHROMIUM" ]] || { warn "no chromium binary found — run scripts/pi-setup.sh"; exit 1; }

# ---------------------------------------------------------------------------
# Display setup hook
# ---------------------------------------------------------------------------

if [[ -n "$DISPLAY_SETUP" ]]; then
  log "applying DISPLAY_SETUP"
  # Operator-supplied and intentionally evaluated: it is a shell snippet in a
  # root-owned file on a single-purpose device, and the alternative is a
  # bespoke mini-language for wlr-randr arguments.
  eval "$DISPLAY_SETUP" || warn "DISPLAY_SETUP failed (continuing)"
fi

# ---------------------------------------------------------------------------
# Wait for the bridge
# ---------------------------------------------------------------------------

log "waiting for bridge on port $PORT (up to ${BRIDGE_WAIT}s)"
deadline=$(( SECONDS + BRIDGE_WAIT ))
# -s, and no -S: a connection-refused per second for up to BRIDGE_WAIT is
# expected here, and logging every one of them would bury the real message.
until curl -fs --max-time 2 -o /dev/null "http://localhost:${PORT}/"; do
  if (( SECONDS >= deadline )); then
    warn "bridge did not answer in ${BRIDGE_WAIT}s — launching anyway"
    warn "check: systemctl status slimefeast-bridge"
    break
  fi
  sleep 1
done

# ---------------------------------------------------------------------------
# Launch, and keep it up
# ---------------------------------------------------------------------------

mkdir -p "$PROFILE"

# Clear the crash/restore state an unclean exit leaves in the profile.
# Rewriting Chromium's own state file is crude, but it is the only interface
# Chromium offers for this.
#
# Done as a parsed-and-reserialised JSON edit rather than a sed on the raw
# text: a regex that silently matches nothing leaves the kiosk showing a
# "Restore pages?" bubble that nobody on the floor can dismiss, and that
# failure is invisible until it is in front of players.  The write is
# create-then-rename so a power cut mid-scrub cannot leave a truncated
# profile behind either.
clear_crash_flags() {
  local prefs="$PROFILE/Default/Preferences"
  [[ -f "$prefs" ]] || return 0   # first boot: nothing to scrub
  command -v python3 >/dev/null || { warn "python3 missing — cannot scrub crash flags"; return 0; }
  python3 - "$prefs" <<'PY' || warn "could not scrub crash flags"
import json, os, sys, tempfile

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        prefs = json.load(f)
except (OSError, ValueError):
    # An unreadable or corrupt profile is not worth failing over: Chromium
    # rebuilds it from defaults, which is exactly the clean state we want.
    sys.exit(0)

profile = prefs.get("profile")
if not isinstance(profile, dict):
    sys.exit(0)

profile["exit_type"] = "Normal"
profile["exited_cleanly"] = True

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(prefs, f, separators=(",", ":"))
    os.replace(tmp, path)
except BaseException:
    os.unlink(tmp)
    raise
PY
}

log "launching $CHROMIUM at $KIOSK_URL"

while :; do
  clear_crash_flags

  "$CHROMIUM" \
    --kiosk "$KIOSK_URL" \
    --user-data-dir="$PROFILE" \
    --noerrdialogs \
    --disable-infobars \
    --no-first-run \
    --no-default-browser-check \
    --disable-session-crashed-bubble \
    --disable-features=Translate \
    --disable-pinch \
    --autoplay-policy=no-user-gesture-required \
    --check-for-update-interval=31536000 \
    || warn "chromium exited non-zero"

  # A deliberate quit (or a crash) on an unattended kiosk should come back,
  # not leave a bare desktop.  The pause keeps a hard-failing browser from
  # spinning the CPU; the game is a fresh page load either way, so nothing
  # is lost by restarting.
  warn "chromium exited — restarting in 3s"
  sleep 3
done
