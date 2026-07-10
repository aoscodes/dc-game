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
    listen 80;
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
    location ~ "^/config/[0-9a-f]{16}$" {
        add_header Cache-Control "no-cache";
        try_files /index.html =404;
    }

    # The tuning editor (static, ships with web/).
    location = /tune {
        add_header Cache-Control "no-cache";
        try_files /tune.html =404;
    }

    # index.html must revalidate so the game.js?v=<sha> cache buster is seen
    # on every deploy.  The versioned game.js itself can be cached forever.
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
