#!/usr/bin/env bash
# pi-setup.sh — one-time provisioning for a Raspberry Pi kiosk.
#
# Run once, as root, from a clone of this repo on the Pi:
#
#   sudo bash scripts/pi-setup.sh
#
# Re-runnable: every step is idempotent, so this is also how you apply a
# change to the boot process (new unit options, a new KIOSK_URL default, an
# updated pi-update.sh).
#
# What you get:
#   - Zig 0.15.2 + Node 22 + Chromium installed
#   - /opt/slimefeast, with a fetch-only clone and shared build caches
#   - slimefeast-update.service   oneshot: fast-forward to origin/main, build
#   - slimefeast-bridge.service   the Node bridge, ordered after the update
#   - a labwc autostart hook that opens the game fullscreen
#   - autologin to the desktop, screen blanking off
#
# Assumes a read-only GitHub deploy key is already installed for the kiosk
# user (default: pi) at ~/.ssh/ — this script verifies it can reach origin and
# refuses to continue if it cannot.  That is the one failure worth stopping
# for: it is the difference between "provisioned" and "provisioned, and will
# silently never update again".

set -euo pipefail

# ---------------------------------------------------------------------------
# Tunables — override on the command line, e.g. KIOSK_USER=kiosk sudo -E ...
# ---------------------------------------------------------------------------

KIOSK_USER="${KIOSK_USER:-pi}"
ROOT="${ROOT:-/opt/slimefeast}"
BRANCH="${BRANCH:-main}"
PORT="${PORT:-3000}"
KIOSK_URL="${KIOSK_URL:-http://localhost:${PORT}/}"

ZIG_VERSION="0.15.2"
ZIG_TARBALL="https://ziglang.org/download/${ZIG_VERSION}/zig-aarch64-linux-${ZIG_VERSION}.tar.xz"
ZIG_SHA256="958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f"
NODE_MAJOR=22

# Copies of the runtime scripts live here, not in the repo checkout: the boot
# path must not depend on a symlink that a failed build could leave dangling,
# and a script must never be rewritten underneath its own running shell.
LIBDIR="/usr/local/lib/slimefeast"

log()  { printf '\n[pi-setup] %s\n' "$*"; }
warn() { printf '[pi-setup] WARN: %s\n' "$*" >&2; }
die()  { printf '[pi-setup] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "run as root: sudo bash scripts/pi-setup.sh"

# Zig publishes no 32-bit ARM build for 0.15.2, so a 32-bit Pi OS cannot build
# on device at all.  Say so here rather than failing obscurely in a tarball
# extraction.
arch="$(uname -m)"
[[ "$arch" == "aarch64" ]] || die "need 64-bit Raspberry Pi OS (uname -m = $arch, want aarch64)"

id "$KIOSK_USER" &>/dev/null || die "user '$KIOSK_USER' does not exist (set KIOSK_USER=)"
USER_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
[[ -d "$USER_HOME" ]] || die "no home directory for $KIOSK_USER"

# The repo this script was run from — the source of truth for the copies we
# install below, and for the origin URL of the clone we are about to make.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SRC="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null)" \
  || die "run this from a clone of the repo (scripts/pi-setup.sh)"
REPO_URL="${REPO_URL:-$(git -C "$REPO_SRC" remote get-url origin)}"

log "provisioning kiosk: user=$KIOSK_USER root=$ROOT branch=$BRANCH port=$PORT"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

log "installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  git curl ca-certificates xz-utils rsync

# Chromium: Raspberry Pi OS packages it as chromium-browser (with a wrapper
# that applies the Pi's hardware flags); plain Debian calls it chromium.
if ! command -v chromium-browser >/dev/null && ! command -v chromium >/dev/null; then
  log "installing chromium"
  apt-get install -y chromium-browser || apt-get install -y chromium \
    || die "could not install chromium"
fi

# Node: match CI (22.x).  Pi OS ships an older major, so add NodeSource unless
# what is already there is new enough.
node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if (( node_major < NODE_MAJOR )); then
  log "installing Node.js ${NODE_MAJOR}.x (found major: $node_major)"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
else
  log "Node.js major $node_major already satisfies >= $NODE_MAJOR"
fi

# ---------------------------------------------------------------------------
# Zig
# ---------------------------------------------------------------------------

# Pinned, checksummed, and installed outside apt: build.zig.zon sets
# minimum_zig_version and Zig makes no source-compatibility promise between
# minors, so "whatever the distro has" is not a usable answer.
if [[ "$(zig version 2>/dev/null)" == "$ZIG_VERSION" ]]; then
  log "Zig $ZIG_VERSION already installed"
else
  log "installing Zig $ZIG_VERSION"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$ZIG_TARBALL" -o "$tmp/zig.tar.xz"
  printf '%s  %s\n' "$ZIG_SHA256" "$tmp/zig.tar.xz" | sha256sum -c - \
    || die "Zig tarball checksum mismatch"
  rm -rf "/opt/zig-$ZIG_VERSION"
  mkdir -p "/opt/zig-$ZIG_VERSION"
  tar -xJf "$tmp/zig.tar.xz" -C "/opt/zig-$ZIG_VERSION" --strip-components=1
  # -n so an existing /opt/zig symlink is replaced rather than followed (which
  # would drop the new link inside the old version's directory).
  ln -sfn "/opt/zig-$ZIG_VERSION" /opt/zig
  ln -sfn /opt/zig/zig /usr/local/bin/zig
  rm -rf "$tmp"; trap - EXIT
  [[ "$(zig version)" == "$ZIG_VERSION" ]] || die "Zig install did not take"
fi

# ---------------------------------------------------------------------------
# Serial access for the hardware controllers
# ---------------------------------------------------------------------------

# bridge/controllers.js enumerates dc_rp2040 boards over USB serial; without
# dialout the bridge runs fine and silently sees no controllers.
if id -nG "$KIOSK_USER" | tr ' ' '\n' | grep -qx dialout; then
  log "$KIOSK_USER already in dialout"
else
  log "adding $KIOSK_USER to dialout (USB serial controllers)"
  usermod -aG dialout "$KIOSK_USER"
fi

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------

log "creating $ROOT"
mkdir -p "$ROOT"/{builds,state,custom-configs,node_modules,zig-cache,zig-global-cache}
chown -R "$KIOSK_USER:$KIOSK_USER" "$ROOT"

# Everything under $ROOT is owned and written by the kiosk user, so the clone
# is made as that user too — which is also what picks up its deploy key.
as_user() { sudo -u "$KIOSK_USER" -H "$@"; }

log "trusting github.com host key for $KIOSK_USER"
as_user mkdir -p "$USER_HOME/.ssh"
as_user touch "$USER_HOME/.ssh/known_hosts"
chmod 700 "$USER_HOME/.ssh"
if ! as_user ssh-keygen -F github.com -f "$USER_HOME/.ssh/known_hosts" >/dev/null; then
  ssh-keyscan -t ed25519 github.com 2>/dev/null >> "$USER_HOME/.ssh/known_hosts"
  chown "$KIOSK_USER:$KIOSK_USER" "$USER_HOME/.ssh/known_hosts"
fi

log "checking deploy key can reach $REPO_URL"
as_user git ls-remote --exit-code "$REPO_URL" "refs/heads/$BRANCH" >/dev/null \
  || die "cannot reach $REPO_URL branch $BRANCH as $KIOSK_USER — install the read-only deploy key at $USER_HOME/.ssh/ first"

if [[ -d "$ROOT/src/.git" ]]; then
  log "clone already present at $ROOT/src"
  as_user git -C "$ROOT/src" remote set-url origin "$REPO_URL"
else
  log "cloning into $ROOT/src"
  as_user git clone --quiet --branch "$BRANCH" "$REPO_URL" "$ROOT/src"
fi

# ---------------------------------------------------------------------------
# Runtime scripts + config
# ---------------------------------------------------------------------------

log "installing runtime scripts to $LIBDIR"
mkdir -p "$LIBDIR"
for s in pi-update.sh pi-kiosk.sh; do
  [[ -f "$REPO_SRC/scripts/$s" ]] || die "missing $REPO_SRC/scripts/$s"
  install -m 755 "$REPO_SRC/scripts/$s" "$LIBDIR/$s"
done
# Recorded so pi-update.sh can tell the journal when a newly deployed commit
# changes provisioning and this script needs re-running.
sha256sum "$REPO_SRC/scripts/pi-setup.sh" | cut -d' ' -f1 > "$LIBDIR/pi-setup.sha256"

log "writing /etc/default/slimefeast"
cat > /etc/default/slimefeast <<EOF
# Slime Feast kiosk configuration.  Read by slimefeast-update.service,
# slimefeast-bridge.service and pi-kiosk.sh.  Edit, then:
#   sudo systemctl restart slimefeast-update slimefeast-bridge
ROOT=$ROOT
BRANCH=$BRANCH
PORT=$PORT
KIOSK_URL=$KIOSK_URL
KIOSK_USER=$KIOSK_USER

# Seconds to wait for git fetch before booting the last known good build.
FETCH_TIMEOUT=60
# Completed builds kept for manual rollback.
KEEP_BUILDS=3
# Seconds pi-kiosk.sh waits for the bridge before opening the browser anyway.
BRIDGE_WAIT=90

# Shell snippet run before Chromium, for display setup (rotation, mode).
# Left empty deliberately — set it once the kiosk display is decided, e.g.
#   DISPLAY_SETUP='wlr-randr --output HDMI-A-1 --transform 90'
DISPLAY_SETUP=
EOF
chmod 644 /etc/default/slimefeast

# ---------------------------------------------------------------------------
# systemd units
# ---------------------------------------------------------------------------

log "writing systemd units"

# Oneshot, not a timer: main is checked exactly once per boot, so the version
# can never change under a table of players mid-session.  RemainAfterExit
# keeps it "active" so the bridge's ordering dependency is satisfied.
#
# It exits 0 even when it fails on purpose (see pi-update.sh) — a Requires=
# on a unit that can legitimately fail would stop the kiosk booting offline,
# which is the opposite of what an event machine needs.
cat > /etc/systemd/system/slimefeast-update.service <<EOF
[Unit]
Description=Slime Feast kiosk: update to latest $BRANCH and build
Wants=network-online.target
After=network-online.target
Before=slimefeast-bridge.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$KIOSK_USER
Group=$KIOSK_USER
EnvironmentFile=/etc/default/slimefeast
ExecStart=$LIBDIR/pi-update.sh
# A cold Zig build on a Pi is minutes, not seconds.
TimeoutStartSec=1800
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# The bridge is the only long-lived process: it serves web/ + data/ + /ws and
# spawns one game-server process per lobby itself (bridge/index.js), so there
# is no separate server unit.
#
# WorkingDirectory is the `current` symlink, which pi-update.sh only ever
# points at a commit that built and whose data files validated.  Ordering
# after the update means the symlink is already correct at start — the bridge
# is never restarted out from under players.
cat > /etc/systemd/system/slimefeast-bridge.service <<EOF
[Unit]
Description=Slime Feast bridge (serves the game, spawns a server per lobby)
After=network.target slimefeast-update.service
Wants=slimefeast-update.service

[Service]
User=$KIOSK_USER
Group=$KIOSK_USER
SupplementaryGroups=dialout
EnvironmentFile=/etc/default/slimefeast
WorkingDirectory=$ROOT/current
ExecStart=/usr/bin/node $ROOT/current/bridge/index.js
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable slimefeast-update.service slimefeast-bridge.service >/dev/null

# ---------------------------------------------------------------------------
# labwc autostart — the browser
# ---------------------------------------------------------------------------

log "hooking pi-kiosk.sh into the labwc session"

LABWC_DIR="$USER_HOME/.config/labwc"
AUTOSTART="$LABWC_DIR/autostart"
as_user mkdir -p "$LABWC_DIR"

# A user autostart REPLACES the system one rather than adding to it, so seed
# from /etc/xdg/labwc/autostart on first run — otherwise the Pi's own session
# startup (panel, desktop, notifications) silently disappears.
if [[ ! -f "$AUTOSTART" ]]; then
  if [[ -f /etc/xdg/labwc/autostart ]]; then
    log "seeding $AUTOSTART from the system default"
    install -o "$KIOSK_USER" -g "$KIOSK_USER" -m 755 /etc/xdg/labwc/autostart "$AUTOSTART"
  else
    warn "no /etc/xdg/labwc/autostart found — is this labwc? creating a bare one"
    as_user touch "$AUTOSTART"
    chmod 755 "$AUTOSTART"
  fi
fi

# Marker-delimited block so re-running this script updates in place instead of
# appending a second launcher.
MARKER_BEGIN="# >>> slimefeast kiosk >>>"
MARKER_END="# <<< slimefeast kiosk <<<"
if grep -qF "$MARKER_BEGIN" "$AUTOSTART"; then
  log "replacing existing kiosk block in $AUTOSTART"
  sed -i "/${MARKER_BEGIN}/,/${MARKER_END}/d" "$AUTOSTART"
fi
cat >> "$AUTOSTART" <<EOF
$MARKER_BEGIN
# Managed by scripts/pi-setup.sh — edits here are overwritten on re-run.
# Backgrounded so it cannot stall the rest of the session while it waits for
# the bridge; it logs to ~/.local/state/slimefeast-kiosk.log.
mkdir -p "\$HOME/.local/state"
$LIBDIR/pi-kiosk.sh >> "\$HOME/.local/state/slimefeast-kiosk.log" 2>&1 &
$MARKER_END
EOF
chown "$KIOSK_USER:$KIOSK_USER" "$AUTOSTART"

# ---------------------------------------------------------------------------
# Pi behaviour: autologin, no blanking
# ---------------------------------------------------------------------------

if command -v raspi-config >/dev/null; then
  log "enabling desktop autologin for $KIOSK_USER and disabling screen blanking"
  # B4 = boot to desktop, autologin.  Without it there is no Wayland session
  # for the browser to appear in, and nobody to type a password at an event.
  raspi-config nonint do_boot_behaviour B4 || warn "could not set boot behaviour"
  # 1 = blanking off.  raspi-config knows where this lives for the current
  # display stack, which is why this is not a hand-written config edit.
  raspi-config nonint do_blanking 1 || warn "could not disable screen blanking"
  if [[ "$KIOSK_USER" != "pi" ]]; then
    warn "raspi-config autologin targets the default user; verify autologin is for $KIOSK_USER"
  fi
else
  warn "raspi-config not found — set desktop autologin and disable screen blanking manually"
fi

# ---------------------------------------------------------------------------
# First build
# ---------------------------------------------------------------------------

log "running the first update + build (this takes a while on a Pi)"
systemctl start slimefeast-update.service || warn "update unit reported failure"

if [[ -L "$ROOT/current" ]]; then
  systemctl restart slimefeast-bridge.service
  log "bridge started on http://localhost:$PORT/"
else
  warn "no build was published — the bridge cannot start yet"
  warn "check: journalctl -u slimefeast-update -n 50"
fi

cat <<EOF

=== pi-setup.sh complete ===

  serving      $KIOSK_URL
  deployment   $ROOT/current -> $(readlink "$ROOT/current" 2>/dev/null || echo '<none yet>')

  logs         journalctl -u slimefeast-update -u slimefeast-bridge -f
               tail -f $USER_HOME/.local/state/slimefeast-kiosk.log
  force update sudo systemctl restart slimefeast-update slimefeast-bridge
  pin version  sudo ln -sfn $ROOT/builds/<sha> $ROOT/current.new \\
                 && sudo mv -T $ROOT/current.new $ROOT/current \\
                 && sudo systemctl mask slimefeast-update

Reboot to verify the whole path (autologin -> bridge -> kiosk tab):

  sudo reboot
EOF
