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
#   2. Copy waves.json to /opt/dragoncon/waves.json
#   3. Once DNS is live: certbot --nginx -d <your-domain>

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

mkdir -p /opt/dragoncon/bridge /var/www/dragoncon
chown -R dragoncon:dragoncon /opt/dragoncon

# waves.json lives here; managed manually (not deployed by CI)
touch /opt/dragoncon/waves.json
chown dragoncon:dragoncon /opt/dragoncon/waves.json
echo "NOTE: populate /opt/dragoncon/waves.json with your wave definitions"

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
# Server
deploy ALL=(root) NOPASSWD: /usr/bin/install -o dragoncon -g dragoncon -m 755 /tmp/dragoncon-deploy/zig-out/bin/server /opt/dragoncon/server
deploy ALL=(root) NOPASSWD: /bin/systemctl restart dragoncon-server

# Client binary + Node bridge
deploy ALL=(root) NOPASSWD: /usr/bin/install -o dragoncon -g dragoncon -m 755 /tmp/dragoncon-deploy/zig-out/bin/client /opt/dragoncon/client
deploy ALL=(root) NOPASSWD: /usr/bin/rsync -a --delete /tmp/dragoncon-deploy/bridge/ /opt/dragoncon/bridge/
deploy ALL=(root) NOPASSWD: /bin/systemctl restart dragoncon-bridge
deploy ALL=(dragoncon) NOPASSWD: /usr/bin/npm
EOF
chmod 440 /etc/sudoers.d/deploy

echo "ACTION REQUIRED: add the GitHub Actions public key to /home/deploy/.ssh/authorized_keys"

# ---------------------------------------------------------------------------
# systemd units
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/dragoncon-server.service <<'EOF'
[Unit]
Description=DragonCon Game Server
After=network.target

[Service]
User=dragoncon
ExecStart=/opt/dragoncon/server
WorkingDirectory=/opt/dragoncon
Restart=always
RestartSec=5
TimeoutStartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/dragoncon-bridge.service <<'EOF'
[Unit]
Description=DragonCon Node Bridge
After=network.target
Wants=dragoncon-server.service

[Service]
User=dragoncon
ExecStart=/usr/bin/node /opt/dragoncon/bridge/index.js
WorkingDirectory=/opt/dragoncon
Environment=PORT=3000
Environment=SERVER_URL=ws://127.0.0.1:9001
Restart=always
RestartSec=5
TimeoutStartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dragoncon-server dragoncon-bridge

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
echo "  2. cp waves.json /opt/dragoncon/waves.json"
echo "     chown dragoncon:dragoncon /opt/dragoncon/waves.json"
echo ""
echo "  3. Add GitHub secrets: VPS_HOST, VPS_USER=deploy, VPS_SSH_KEY"
echo ""
echo "  4. After DNS propagates: certbot --nginx -d <your-domain>"
