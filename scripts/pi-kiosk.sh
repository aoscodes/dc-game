#!/usr/bin/env bash
# pi-kiosk.sh — launch the game in a fullscreen Chromium tab.
#
# Runs inside the pi user's Wayland (labwc) session, started from
# ~/.config/labwc/autostart by scripts/pi-setup.sh.  The bridge itself is a
# system service (slimefeast-bridge) and is NOT started here — this script
# only owns the browser.
#
# Three things make this more than a one-line chromium invocation, all of them
# lessons about a machine with no keyboard that gets its power cut nightly:
#
#   1. The session starts long before the bridge is listening, and Chromium
#      caches the failure — land on ERR_CONNECTION_REFUSED once and the kiosk
#      sits on an error page until someone reloads it.  So: wait for a real
#      HTTP 200 before launching.
#   2. That wait cannot be unbounded (a broken bridge would leave a bare
#      desktop with no clue on screen) and cannot be short either, because the
#      bridge waits on the update, which waits on wifi and may then do a cold
#      build.  So: wait BRIDGE_WAIT, launch regardless, and keep watching —
#      when the bridge finally answers, restart the browser onto the game.
#   3. An unclean shutdown leaves a crash flag in the profile, and the next
#      boot renders a "Restore pages?" bubble over the game with no input
#      device able to dismiss it.  So: scrub the flag every launch.

set -uo pipefail

# shellcheck source=/dev/null
[[ -r /etc/default/slimefeast ]] && . /etc/default/slimefeast

ROOT="${ROOT:-/opt/slimefeast}"
PORT="${PORT:-3000}"
KIOSK_URL="${KIOSK_URL:-http://localhost:${PORT}/}"
# How long to wait for the bridge before opening the browser anyway.  Giving
# up and launching beats staring at a blank desktop: a broken bridge then
# shows an error page an operator can actually see and diagnose.
#
# It does NOT need to cover a slow boot.  Launching early is recoverable —
# the loop below keeps polling and restarts the browser onto the game once
# the bridge answers — so this is only the point at which we stop assuming
# things are fine and put something on screen.
BRIDGE_WAIT="${BRIDGE_WAIT:-90}"
# Shell snippet run once before the browser, for display setup that is not
# yet decided (rotation, mode, overscan) — e.g. a panel mounted upside down:
#   DISPLAY_SETUP='wlr-randr --output HDMI-A-1 --transform 180'
# Empty by default: guessing a display config for a kiosk you have not seen
# is worse than leaving it at the compositor's own defaults.
#
# Rotation belongs HERE and not in web/'s CSS.  The compositor transform turns
# the touchscreen's coordinates with the output, so a tap still lands where it
# looks like it landed; a `transform: rotate(180deg)` on the page rotates only
# the pixels, and every hit test on the far side of it — canvasCoords in
# game.js, the browser's own on the kiosk buttons — would need inverting to
# match.  Set it from pi-setup.sh (see DISPLAY_SETUP there), which is what
# writes /etc/default/slimefeast.
DISPLAY_SETUP="${DISPLAY_SETUP:-}"
# Where the browser's PID and the exit request are exchanged with the bridge.
# The bridge derives the same two filenames from KIOSK_STATE_DIR (see the
# /api/kiosk/exit route in bridge/index.js) — if you rename either file, both
# sides have to change or the kill switch silently stops working.
KIOSK_STATE_DIR="${KIOSK_STATE_DIR:-$ROOT/state}"

PROFILE="$ROOT/state/chromium"
PIDFILE="$KIOSK_STATE_DIR/chromium.pid"
EXITFLAG="$KIOSK_STATE_DIR/kiosk-exit"

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

# -s, and no -S: a connection-refused per second while we poll is expected,
# and logging every one of them would bury the real message.
bridge_up() { curl -fs --max-time 2 -o /dev/null "http://localhost:${PORT}/"; }

# 0 = bridge answered, 1 = gave up waiting.
wait_for_bridge() {
  local deadline=$(( SECONDS + BRIDGE_WAIT ))
  until bridge_up; do
    (( SECONDS >= deadline )) && return 1
    sleep 1
  done
  return 0
}

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

# ---------------------------------------------------------------------------
# Which PID is the browser
# ---------------------------------------------------------------------------
#
# NOT `$!`.  On Raspberry Pi OS `chromium-browser` is a shell script — it is
# the wrapper that reads /etc/chromium.d/* for the Pi's hardware flags, which
# is the whole reason we prefer it — and it runs the real binary as a CHILD
# rather than exec-ing it.  So `$!` is the wrapper's PID.
#
# That is not a PID that merely fails to work; it is one that fails while
# looking like it worked.  The wrapper's own cmdline still carries --kiosk, so
# it passes the bridge's pidIsKioskBrowser check, the kill switch answers 200,
# and SIGTERM reaps the script and ORPHANS a fullscreen browser that now has
# no launcher, no pidfile and no way to be closed.  The operator sees a held
# button, no error, and a screen that did not change.
#
# So walk down from the launcher and publish the process that IS the browser.
#
# The discriminator: Chromium's helpers (zygote, GPU, every renderer) all carry
# --type=, and the browser process is the one that does not.  That leaves the
# wrapper and the browser as the only two candidates in the tree, and the
# browser is the deeper — hence breadth-first, keeping the LAST match, which
# is the deepest one.  Matching on --kiosk as well as the tree walk because
# this must agree with the bridge's check exactly: a PID that satisfies one
# and not the other is the failure above with the roles swapped.
kiosk_browser_pid() {
  local queue=("$1") best="" pid cmdline kids
  while (( ${#queue[@]} > 0 )); do
    pid="${queue[0]}"
    queue=("${queue[@]:1}")
    # Argv is NUL-separated; the bounding spaces make " --kiosk " an exact
    # word match rather than a prefix one.
    cmdline=" $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    if [[ "$cmdline" == *" --kiosk "* && "$cmdline" != *" --type="* ]]; then
      best="$pid"
    fi
    if kids="$(pgrep -P "$pid" 2>/dev/null)"; then
      # shellcheck disable=SC2206  # word splitting is the point: one PID per line
      queue+=($kids)
    fi
  done
  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}

# Poll, because the wrapper has not spawned the browser yet at the instant we
# are handed its PID.  Bounded: a launcher that never produces a browser is a
# broken install, and blocking here forever would cost the kiosk its restart
# loop as well as its kill switch.
KIOSK_PID_WAIT="${KIOSK_PID_WAIT:-15}"
publish_browser_pid() {
  local launcher=$1 waited=0 pid
  # No /proc means no process tree to walk (a dev box, macOS).  There is also
  # no wrapper to see through there, and the bridge's own check degrades the
  # same way, so the launcher PID is the honest answer rather than a failure.
  if [[ ! -d /proc ]]; then
    printf '%s\n' "$launcher" > "$PIDFILE"
    return 0
  fi
  while (( waited < KIOSK_PID_WAIT )); do
    if pid="$(kiosk_browser_pid "$launcher")"; then
      printf '%s\n' "$pid" > "$PIDFILE"
      if [[ "$pid" == "$launcher" ]]; then
        log "browser pid $pid (launcher exec'd into it; kill switch armed)"
      else
        log "browser pid $pid under launcher $launcher (kill switch armed)"
      fi
      return 0
    fi
    kill -0 "$launcher" 2>/dev/null || { warn "launcher $launcher died before a browser appeared"; return 1; }
    sleep 1
    (( waited++ ))
  done
  # Publishing the launcher anyway would re-arm the exact failure this
  # function exists to prevent, so publish nothing: the kill switch reports
  # "no browser is running", which is a message an operator can act on.
  warn "no browser process found under $launcher in ${KIOSK_PID_WAIT}s — kill switch disarmed"
  return 1
}

mkdir -p "$KIOSK_STATE_DIR"

# A leftover flag would quit the kiosk the instant it came up, which on a
# machine whose power is cut nightly is a brick.  The flag means "the exit
# button was held SINCE THIS SCRIPT STARTED" and nothing else.
rm -f "$EXITFLAG"

log "launching $CHROMIUM at $KIOSK_URL"

trap 'rm -f "$PIDFILE"' EXIT

while :; do
  # The bridge can legitimately be minutes late, not seconds: it is ordered
  # after the update unit, which waits for wifi to actually carry traffic and
  # may then do a cold Zig build.
  if wait_for_bridge; then
    bridge_ready=1
  else
    bridge_ready=0
    warn "bridge did not answer in ${BRIDGE_WAIT}s — opening the browser anyway"
    warn "check: systemctl status slimefeast-update slimefeast-bridge"
  fi

  clear_crash_flags

  # Backgrounded so the loop can go on to publish a PID for the bridge, then
  # waited on so it still blocks for the browser's whole lifetime.
  # A pidfile rather than the bridge pattern-matching `pkill`: the bridge must
  # never guess which process is the kiosk.
  #
  # LAUNCHER, not browser: on Pi OS this name is a wrapper script and the two
  # are different processes.  `wait` wants this one (it is our child); the
  # pidfile and every kill below want the one publish_browser_pid finds.
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
    --check-for-update-interval=31536000 &
  launcher_pid=$!
  # A failure here disarms the kill switch and nothing else: a kiosk that
  # cannot be closed from the screen is still a kiosk, so it is logged and
  # played on rather than fatal.
  publish_browser_pid "$launcher_pid" || true

  # We launched onto Chromium's connection-error page, which has no
  # auto-refresh.  On a machine with no keyboard that is a dead end, so watch
  # for the bridge and reload onto the game the moment it answers.  This is
  # what makes a slow boot — long wifi wait, then a cold build — safe to sit
  # through unattended: the kiosk heals itself instead of needing someone to
  # notice it is parked on an error.
  reloading=0
  if (( bridge_ready == 0 )); then
    while kill -0 "$launcher_pid" 2>/dev/null; do
      if bridge_up; then
        log "bridge came up — reloading the kiosk onto the game"
        reloading=1
        # The browser, not the launcher, for the same reason the pidfile holds
        # the browser: killing a wrapper leaves its child on screen, and here
        # that would be a stale error page nothing ever replaces.  Falls back
        # to the launcher only when no browser PID was ever published.
        kill "$(cat "$PIDFILE" 2>/dev/null || printf '%s' "$launcher_pid")" 2>/dev/null
        break
      fi
      sleep 2
    done
  fi

  wait "$launcher_pid"
  chromium_status=$?
  # A non-zero status is expected and uninteresting when we did the killing.
  if (( reloading == 0 && chromium_status != 0 )); then
    warn "chromium exited non-zero (status $chromium_status)"
  fi
  rm -f "$PIDFILE"

  # The exit flag is the ONLY thing that distinguishes an operator holding the
  # hidden button from a crash.  The bridge writes it before it signals, so by
  # the time the browser is reaped it is already on disk — a crash can never
  # be mistaken for a request, and a request can never be restarted over.
  if [[ -e "$EXITFLAG" ]]; then
    rm -f "$EXITFLAG"
    log "exit requested from the kiosk page — leaving the desktop up"
    log "to bring the kiosk back, run: $0"
    exit 0
  fi

  # A planned reload, so skip the cooldown: the bridge is up and the game
  # should be on screen now, not in three seconds.
  if (( reloading == 1 )); then
    continue
  fi

  # A crash on an unattended kiosk should come back, not leave a bare desktop.
  # The pause keeps a hard-failing browser from spinning the CPU; the game is
  # a fresh page load either way, so nothing is lost by restarting.
  warn "chromium exited — restarting in 3s"
  sleep 3
done
