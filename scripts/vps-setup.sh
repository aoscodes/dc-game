#!/usr/bin/env bash
# vps-setup.sh — one-time provisioning for a fresh Ubuntu 24.04 x86_64 VPS.
#
# Run as root:
#   bash vps-setup.sh
#
# What this does:
#   - Installs nginx, certbot, Node.js 22.x
#   - Creates a locked service user (dragoncon) that runs the server + bridge
#   - Creates a deploy user (deploy) that GitHub Actions SSHes in as
#   - Writes systemd units for the game server and Node bridge
#   - Writes the nginx site config (HTTP only; run certbot separately for TLS)
#   - Enables and starts everything
#
# After this script:
#   1. Add the GitHub Actions public key to /home/deploy/.ssh/authorized_keys
#   2. Once DNS is live: certbot --nginx -d <your-domain>

set -euo pipefail

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
apt-get update -qq
apt-get install -y nginx certbot python3-certbot-nginx

# Node.js 22.x LTS (matches CI)
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# ---------------------------------------------------------------------------
# Service user — locked, no login shell, owns server + bridge
# ---------------------------------------------------------------------------
if ! id dragoncon &>/dev/null; then
    useradd -r -s /bin/false dragoncon
fi

mkdir -p /opt/dragoncon/bridge /opt/dragoncon/data /opt/dragoncon/custom-configs /var/www/dragoncon
chown -R dragoncon:dragoncon /opt/dragoncon

# ---------------------------------------------------------------------------
# Deploy user — used by GitHub Actions (SCP + SSH)
# ---------------------------------------------------------------------------
if ! id deploy &>/dev/null; then
    useradd -m -s /bin/bash deploy
fi

mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chown deploy:deploy /home/deploy/.ssh

# Sudoers: deploy can install binaries, sync bridge files, restart services,
# and run npm as the dragoncon user.
cat > /etc/sudoers.d/deploy <<'EOF'
# Server binary (spawned per-lobby by the bridge; no standalone service)
deploy ALL=(root) NOPASSWD: /usr/bin/install -o dragoncon -g dragoncon -m 755 /tmp/dragoncon-deploy/zig-out/bin/server /opt/dragoncon/server

# Client binary + Node bridge + game data files
deploy ALL=(root) NOPASSWD: /usr/bin/install -o dragoncon -g dragoncon -m 755 /tmp/dragoncon-deploy/zig-out/bin/client /opt/dragoncon/client
deploy ALL=(root) NOPASSWD: /usr/bin/rsync -a --delete /tmp/dragoncon-deploy/bridge/ /opt/dragoncon/bridge/
deploy ALL=(root) NOPASSWD: /usr/bin/rsync -a --delete /tmp/dragoncon-deploy/data/ /opt/dragoncon/data/
deploy ALL=(root) NOPASSWD: /bin/systemctl restart dragoncon-bridge
EOF
chmod 440 /etc/sudoers.d/deploy

echo "ACTION REQUIRED: add the GitHub Actions public key to /home/deploy/.ssh/authorized_keys"

# ---------------------------------------------------------------------------
# systemd units
# ---------------------------------------------------------------------------
# Legacy: the standalone game-server service is gone — the bridge now spawns
# a server process per lobby.  Remove the old unit if this is a re-run.
if systemctl list-unit-files dragoncon-server.service &>/dev/null; then
    systemctl disable --now dragoncon-server 2>/dev/null || true
fi
rm -f /etc/systemd/system/dragoncon-server.service

cat > /etc/systemd/system/dragoncon-bridge.service <<'EOF'
[Unit]
Description=DragonCon Node Bridge
After=network.target

[Service]
User=dragoncon
ExecStart=/usr/bin/node /opt/dragoncon/bridge/index.js
WorkingDirectory=/opt/dragoncon
Environment=PORT=3000
Restart=always
RestartSec=5
TimeoutStartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dragoncon-bridge

# ---------------------------------------------------------------------------
# Nginx site config
# ---------------------------------------------------------------------------
cat > /etc/nginx/sites-available/dragoncon <<'EOF'
server {
    # default_server: the VPS also hosts name-based vhosts for the GRG sites
    # (provisioned from the monorepo's scripts/sites-setup.sh).  Without an
    # explicit default, nginx picks whichever `listen 80` it parses first,
    # which is decided by alphabetical ordering of sites-enabled filenames.
    # Pin it so bare-IP and unknown-Host requests keep reaching the game.
    listen 80 default_server;
    server_name _;

    root /var/www/dragoncon;
    index index.html;

    # WebSocket proxy -> Node bridge (which relays to the Zig server)
    location = /ws {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "Upgrade";
        proxy_set_header   Host       $host;
        # Keep long-lived WS connections alive through the proxy
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # The kiosk WebSockets.  Same stanza as /ws and for the same reasons.
    # Exact matches, like /ws: an exact location is settled before any regex or
    # prefix block, so these can never be reordered into a static file handler
    # by something added later.
    location = /onboard-ws {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "Upgrade";
        proxy_set_header   Host       $host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location = /powerups-ws {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "Upgrade";
        proxy_set_header   Host       $host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # Tuning API (save configs) -> Node bridge
    location /api/ {
        proxy_pass       http://127.0.0.1:3000;
        proxy_set_header Host $host;
    }

    # Saved custom-config data files live with the bridge (content-addressed
    # under /opt/dragoncon/custom-configs), not in the static web root.
    # Regexes with {n} repetition must be quoted or nginx parses { as a block.
    location ~ "^/config/[0-9a-f]{16}/data/" {
        proxy_pass       http://127.0.0.1:3000;
        proxy_set_header Host $host;
    }

    # /config/{hash} serves the regular game shell; game.js reads the hash
    # from location.pathname (all asset/script URLs are absolute).
    # The optional trailing slash matches the bridge, which accepts it too
    # (see the cfgMatch branch in bridge/index.js) — the two configs are
    # independent, so every route has to agree in both or the Pi and the VPS
    # disagree about what a URL means.
    location ~ "^/config/[0-9a-f]{16}/?$" {
        add_header Cache-Control "no-cache";
        try_files /game.html =404;
    }

    # The extensionless page routes.  Each must be spelled out: the catch-all
    # `location /` below is try_files-only, so anything without a file
    # extension 404s unless it is named here.  This is what /onboard and
    # /powerups were missing — they worked against the bridge directly on the
    # Pi and had never worked on the VPS at all.
    location = /game {
        add_header Cache-Control "no-cache";
        try_files /game.html =404;
    }
    location = /onboard {
        add_header Cache-Control "no-cache";
        try_files /onboard.html =404;
    }
    location = /powerups {
        add_header Cache-Control "no-cache";
        try_files /powerups.html =404;
    }

    # The tuning editor (static, ships with web/).
    location = /tune {
        add_header Cache-Control "no-cache";
        try_files /tune.html =404;
    }

    # The shells must revalidate so the ?v=<sha> cache buster inside them is
    # seen on every deploy.  The versioned scripts themselves can be cached
    # forever.  index.html is the station directory, game.html the game.
    location = /game.html {
        add_header Cache-Control "no-cache";
    }
    location = /index.html {
        add_header Cache-Control "no-cache";
    }
    location = / {
        add_header Cache-Control "no-cache";
        try_files /index.html =404;
    }

    # Static assets served directly from /var/www/dragoncon (deployed by CI)
    location / {
        try_files $uri $uri/ =404;
    }

    include /etc/nginx/mime.types;
}
EOF

ln -sf /etc/nginx/sites-available/dragoncon /etc/nginx/sites-enabled/dragoncon
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx
systemctl restart nginx

echo ""
echo "=== vps-setup.sh complete ==="
echo ""
echo "Next steps:"
echo "  1. echo '<your-pubkey>' >> /home/deploy/.ssh/authorized_keys"
echo "     chown deploy:deploy /home/deploy/.ssh/authorized_keys"
echo "     chmod 600 /home/deploy/.ssh/authorized_keys"
echo ""
echo "  2. Add GitHub secrets: VPS_HOST, VPS_USER=deploy, VPS_SSH_KEY"
echo ""
echo "  4. After DNS propagates: certbot --nginx -d <your-domain>"
