#!/usr/bin/env bash
# pi-update.sh — bring the kiosk up to the latest origin/$BRANCH, atomically.
#
# Run by slimefeast-update.service at boot, ordered BEFORE the bridge starts.
# Provisioned by scripts/pi-setup.sh.
#
# The contract, and the reason this is not `git pull && zig build`:
#
#   This script ALWAYS EXITS 0.
#
# It is the first thing that runs on an event machine with no keyboard.  A
# dead network, a force-pushed branch, a broken commit on main, a full disk —
# none of those may stop the Pi booting into a playable game.  Every failure
# path logs loudly and leaves the previous deployment running.
#
# That guarantee needs more than a trap.  Building in place is unsafe: the
# bridge serves web/ straight off the working tree while the binaries come
# from zig-out/, so a pull that lands new web/game.js and then fails to build
# leaves a new renderer talking to an old client over a changed wire protocol
# — a kiosk that looks fine and cannot play.  So a commit is built in its own
# git worktree and the `current` symlink is moved only once that build is
# green.  `current` always points at a commit that compiled.
#
# Layout (see pi-setup.sh):
#   $ROOT/src                 fetch-only clone
#   $ROOT/builds/<sha>        worktree per commit, built in place
#   $ROOT/current -> builds/<sha>
#   $ROOT/custom-configs      persistent /tune output, symlinked into builds
#   $ROOT/node_modules        shared, symlinked into builds
#   $ROOT/state               build stamps + npm lock hash

set -uo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# shellcheck source=/dev/null
[[ -r /etc/default/slimefeast ]] && . /etc/default/slimefeast

ROOT="${ROOT:-/opt/slimefeast}"
BRANCH="${BRANCH:-main}"
# How long a `git fetch` may hang before we give up and boot what we have.
# A captive-portal wifi that accepts the TCP connection and then never
# answers is the case this exists for.
FETCH_TIMEOUT="${FETCH_TIMEOUT:-60}"
# How long to wait for wifi to actually carry traffic before giving up and
# booting the last known good build.
#
# systemd's network-online.target is NOT sufficient here and was the original
# bug: on Raspberry Pi OS it is satisfied once NetworkManager has finished
# *managing* its devices, which on wifi happens well before association, DHCP
# and DNS are usable — so the unit ordered "after network is online" still
# raced the wifi and lost, every boot, silently (fetch failed, fail-soft
# kicked in, the Pi quietly ran forever on whatever it first built).
#
# So the target is kept as a cheap first approximation and the real
# precondition is established here, by probing the thing we actually need.
NETWORK_WAIT="${NETWORK_WAIT:-180}"
# Completed builds kept for rollback.  Each is a full worktree (~tens of MB
# plus zig-out); three is enough to walk back from a bad deploy by hand.
KEEP_BUILDS="${KEEP_BUILDS:-3}"

# Non-interactive by construction.  Without BatchMode a missing or rejected
# key makes ssh sit waiting for a passphrase on a unit with no terminal,
# turning a clear failure into a hang until TimeoutStartSec.
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=10}"
export GIT_TERMINAL_PROMPT=0

SRC="$ROOT/src"
BUILDS="$ROOT/builds"
STATE="$ROOT/state"
CURRENT="$ROOT/current"

log()  { printf '[pi-update] %s\n' "$*"; }
warn() { printf '[pi-update] WARN: %s\n' "$*" >&2; }

# Every early return is a successful exit: see the header.  `bail` names the
# reason in the journal so `journalctl -u slimefeast-update` explains why the
# kiosk is running the version it is running.
bail() {
  warn "$*"
  warn "keeping current deployment: $(readlink "$CURRENT" 2>/dev/null || echo '<none>')"
  exit 0
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

for tool in git zig node npm; do
  command -v "$tool" >/dev/null || bail "$tool not on PATH — run scripts/pi-setup.sh"
done

[[ -d "$SRC/.git" ]] || bail "no clone at $SRC — run scripts/pi-setup.sh"

mkdir -p "$BUILDS" "$STATE" "$ROOT/custom-configs" || bail "cannot write under $ROOT"

# ---------------------------------------------------------------------------
# 1. Wait for the network to actually work
# ---------------------------------------------------------------------------

# Probes with the real operation — an authenticated ls-remote of the branch we
# want — rather than a ping or a DNS lookup.  Anything cheaper passes while
# the thing we need still fails: DNS resolves before the wifi can route, the
# route exists before the deploy key is readable, and a captive portal answers
# everything.  If this succeeds, the fetch below will succeed.
wait_for_origin() {
  local deadline=$(( SECONDS + NETWORK_WAIT )) attempt=0
  while :; do
    attempt=$(( attempt + 1 ))
    if timeout 25 git -C "$SRC" ls-remote --exit-code --quiet origin \
         "refs/heads/$BRANCH" >/dev/null 2>&1; then
      (( attempt > 1 )) && log "origin reachable after ${SECONDS}s (attempt $attempt)"
      return 0
    fi
    (( SECONDS >= deadline )) && return 1
    # Every 5th attempt, so a slow-joining wifi leaves a readable trail in the
    # journal instead of a wall of identical lines.
    (( attempt % 5 == 1 )) && log "origin unreachable, waiting for network (${SECONDS}s/${NETWORK_WAIT}s)"
    sleep 5
  done
}

log "waiting for origin to become reachable (up to ${NETWORK_WAIT}s)"
if ! wait_for_origin; then
  # Show the real error once, now that we have stopped polling: a bad deploy
  # key and a dead access point both look like "unreachable" above, and the
  # difference is the whole diagnosis.
  warn "last error from git:"
  timeout 25 git -C "$SRC" ls-remote --exit-code origin "refs/heads/$BRANCH" 2>&1 \
    | sed 's/^/[pi-update]   /' >&2
  bail "origin unreachable after ${NETWORK_WAIT}s (wifi down? deploy key?)"
fi

# ---------------------------------------------------------------------------
# 2. What does origin say?
# ---------------------------------------------------------------------------

log "fetching origin/$BRANCH"
if ! timeout "$FETCH_TIMEOUT" git -C "$SRC" fetch --prune --quiet origin "$BRANCH"; then
  bail "git fetch failed or timed out"
fi

SHA="$(git -C "$SRC" rev-parse --verify --quiet "refs/remotes/origin/$BRANCH")" \
  || bail "origin/$BRANCH does not resolve"

SHORT="${SHA:0:12}"
BUILD_DIR="$BUILDS/$SHA"
STAMP="$STATE/built-$SHA"

# Up to date means: this commit built green AND is the one being served.  Both
# halves matter — a stamp alone would skip re-pointing a symlink that someone
# moved by hand to pin an older version, and a symlink alone would re-serve a
# tree whose build we never confirmed.
if [[ -f "$STAMP" && "$(readlink -f "$CURRENT" 2>/dev/null)" == "$(readlink -f "$BUILD_DIR" 2>/dev/null)" ]]; then
  log "already on origin/$BRANCH ($SHORT) — nothing to do"
  exit 0
fi

log "target origin/$BRANCH = $SHORT"

# ---------------------------------------------------------------------------
# 3. Materialise the commit in its own worktree
# ---------------------------------------------------------------------------

# A previous run may have died mid-build and left a partial tree.  It has no
# stamp, so it is garbage by definition: drop it and start clean.
if [[ -e "$BUILD_DIR" && ! -f "$STAMP" ]]; then
  log "discarding incomplete build dir for $SHORT"
  git -C "$SRC" worktree remove --force "$BUILD_DIR" 2>/dev/null || rm -rf "$BUILD_DIR"
fi

if [[ ! -d "$BUILD_DIR" ]]; then
  # Detached: this worktree tracks a commit, not a branch, so a later fetch
  # that moves origin/$BRANCH cannot mutate a tree we already built.
  git -C "$SRC" worktree add --detach --quiet "$BUILD_DIR" "$SHA" \
    || bail "git worktree add failed for $SHORT"
fi

# Roll back the worktree and its stamp, then exit 0.  Used for every failure
# after the tree exists, so a broken commit leaves nothing behind to be
# mistaken for a good build by the next boot.
abort_build() {
  warn "$*"
  rm -f "$STAMP"
  git -C "$SRC" worktree remove --force "$BUILD_DIR" 2>/dev/null || rm -rf "$BUILD_DIR"
  git -C "$SRC" worktree prune 2>/dev/null
  bail "build of $SHORT abandoned"
}

# ---------------------------------------------------------------------------
# 4. Wire in the state that must outlive a deploy
# ---------------------------------------------------------------------------

# bridge/index.js resolves ../custom-configs and ../zig-out relative to
# bridge/, and CI installs binaries flat next to bridge/ on the VPS.  Here the
# worktree IS the deployment root, so custom-configs must be a symlink to the
# shared dir or every update would orphan the saved /tune configs (which are
# content-addressed and never garbage collected — losing them breaks live
# /config/{hash} URLs people are holding).
ln -sfn "$ROOT/custom-configs" "$BUILD_DIR/custom-configs"

# node_modules is shared for time, not space: serialport is a native module
# and building it per commit would dominate the update.
mkdir -p "$ROOT/node_modules"
ln -sfn "$ROOT/node_modules" "$BUILD_DIR/bridge/node_modules"

# ---------------------------------------------------------------------------
# 5. npm deps — only when the lockfile actually moved
# ---------------------------------------------------------------------------

LOCK="$BUILD_DIR/bridge/package-lock.json"
LOCK_HASH_FILE="$STATE/package-lock.sha256"
lock_hash="$(sha256sum "$LOCK" 2>/dev/null | cut -d' ' -f1)"

if [[ -z "$lock_hash" ]]; then
  abort_build "bridge/package-lock.json missing at $SHORT"
fi

if [[ "$lock_hash" != "$(cat "$LOCK_HASH_FILE" 2>/dev/null)" ]] || [[ ! -d "$ROOT/node_modules/ws" ]]; then
  log "installing bridge dependencies (lockfile changed)"
  # --omit=dev: the bridge has no devDependencies today, and this keeps it that
  # way on the kiosk if any are added.  npm ci is run with cwd=bridge/ so it
  # writes through the node_modules symlink into the shared dir.
  if ( cd "$BUILD_DIR/bridge" && npm ci --omit=dev --no-audit --no-fund ); then
    printf '%s\n' "$lock_hash" > "$LOCK_HASH_FILE"
  else
    # Deliberately not fatal on its own: if a usable node_modules is already
    # there, a transient npm registry outage should not block a Zig-only
    # change.  If it is genuinely missing, the bridge fails to start and
    # systemd's Restart=always surfaces it in the journal.
    warn "npm ci failed"
    [[ -d "$ROOT/node_modules/ws" ]] || abort_build "no usable node_modules and npm ci failed"
    warn "continuing with existing node_modules"
  fi
else
  log "bridge dependencies unchanged"
fi

# ---------------------------------------------------------------------------
# 6. Build
# ---------------------------------------------------------------------------

# The default step installs BOTH binaries (build.zig installs client and
# server), which is what the bridge needs: it spawns one server per lobby.
#
# Caches are shared across builds and live outside the worktrees, so a rebuild
# after a one-file change is seconds rather than minutes.
#
# No `zig build test` here on purpose: the test step shells out to python3 +
# PIL for the sprite-atlas check and spends ~14s on the render-gate probe.
# main is already gated by CI; re-litigating it on a Pi only makes boots slow.
log "building $SHORT (ReleaseSafe, native cpu)"
if ! ( cd "$BUILD_DIR" && zig build \
        -Doptimize=ReleaseSafe \
        --cache-dir "$ROOT/zig-cache" \
        --global-cache-dir "$ROOT/zig-global-cache" \
        --prefix "$BUILD_DIR/zig-out" ); then
  abort_build "zig build failed at $SHORT"
fi

for bin in client server; do
  [[ -x "$BUILD_DIR/zig-out/bin/$bin" ]] || abort_build "zig build produced no $bin at $SHORT"
done

# ---------------------------------------------------------------------------
# 7. Smoke check the shipped data files
# ---------------------------------------------------------------------------

# The server loads data/*.json at process start and dies on an invalid file.
# The bridge spawns servers lazily, per lobby, so without this a bad data
# commit boots a healthy-looking kiosk that cannot create a single lobby.
# `--validate` is the loader's own dry run, so this is exactly the check the
# real thing will do.
log "validating data files"
if ! "$BUILD_DIR/zig-out/bin/server" 0 --data-dir "$BUILD_DIR/data" --validate; then
  abort_build "data/ failed validation at $SHORT"
fi

# ---------------------------------------------------------------------------
# 8. Publish, atomically
# ---------------------------------------------------------------------------

printf '%s\n' "$SHA" > "$STAMP"

# ln -sfn on an existing symlink-to-directory drops the new link INSIDE the
# old target instead of replacing it.  Create-then-rename avoids that and is
# atomic, so there is no instant where `current` is missing or dangling.
tmp_link="$ROOT/.current.$$"
ln -sfn "$BUILD_DIR" "$tmp_link" || bail "cannot stage new current symlink"
if ! mv -T "$tmp_link" "$CURRENT"; then
  rm -f "$tmp_link"
  bail "cannot publish new current symlink"
fi

log "now serving $SHORT"

# ---------------------------------------------------------------------------
# 9. Flag provisioning drift
# ---------------------------------------------------------------------------

# The boot path (these scripts, the systemd units, the autostart hook) is
# installed by pi-setup.sh and deliberately NOT self-updating: rewriting a
# shell script while its own interpreter is reading it is a real hazard, and a
# change to how the kiosk boots deserves a deliberate re-provision rather than
# arriving silently overnight.  So just say so in the journal.
LIBDIR="${LIBDIR:-/usr/local/lib/slimefeast}"
for script in pi-update.sh pi-kiosk.sh; do
  new="$BUILD_DIR/scripts/$script"
  [[ -f "$new" && -f "$LIBDIR/$script" ]] || continue
  if ! cmp -s "$new" "$LIBDIR/$script"; then
    warn "scripts/$script changed in $SHORT but the installed copy is older"
    warn "  re-provision to pick it up: sudo bash $BUILD_DIR/scripts/pi-setup.sh"
  fi
done
if [[ -f "$LIBDIR/pi-setup.sha256" && -f "$BUILD_DIR/scripts/pi-setup.sh" ]]; then
  if [[ "$(sha256sum "$BUILD_DIR/scripts/pi-setup.sh" | cut -d' ' -f1)" != "$(cat "$LIBDIR/pi-setup.sha256")" ]]; then
    warn "scripts/pi-setup.sh changed in $SHORT — re-provision when convenient:"
    warn "  sudo bash $BUILD_DIR/scripts/pi-setup.sh"
  fi
fi

# ---------------------------------------------------------------------------
# 10. Prune
# ---------------------------------------------------------------------------

# Keep the newest few stamped builds so an operator can roll back by moving
# the symlink.  Never touch the live one, whatever its age.
live="$(readlink -f "$CURRENT")"
mapfile -t stale < <(
  find "$BUILDS" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | tail -n "+$((KEEP_BUILDS + 1))" | cut -d' ' -f2-
)
for dir in "${stale[@]:-}"; do
  [[ -n "$dir" ]] || continue
  [[ "$(readlink -f "$dir")" == "$live" ]] && continue
  log "pruning old build $(basename "$dir" | cut -c1-12)"
  rm -f "$STATE/built-$(basename "$dir")"
  git -C "$SRC" worktree remove --force "$dir" 2>/dev/null || rm -rf "$dir"
done
git -C "$SRC" worktree prune 2>/dev/null

exit 0
