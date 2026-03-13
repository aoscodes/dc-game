# Deploy — Implementation Spec

**Status:** Ready for task breakdown
**Effort:** M total (all deliverables combined ~3-5 hours)
**Date:** 2026-03-13

---

## Problem Statement

DragonCon RPG runs locally only. There is no way for players to access it from a
browser without building from source. The goal is a publicly reachable URL where
anyone can open a browser and play.

---

## Target Architecture

```
Internet
  └─ :443 HTTPS/WSS ──► Nginx (VPS, Ubuntu 24.04 x86_64)
                              ├─ GET /        → /var/www/dragoncon/  (static WASM assets)
                              └─ GET /ws      → ws://127.0.0.1:9001  (game server)

VPS
  ├── Nginx          TLS termination, static files, WebSocket proxy
  ├── dragoncon-server   systemd service, binds 127.0.0.1:9001
  └── Certbot        Let's Encrypt cert, auto-renew cron
```

Game server binds localhost only; Nginx is the sole public-facing process.
WS shares port 443 via Nginx `proxy_pass` on path `/ws`.

---

## Deliverables (Ordered)

### [D1] Fix WebSocket URL — `web/index.html` (S)
- **Depends on:** —
- **Files:** `web/index.html`

`index.html:109` currently builds `${protocol}//${location.hostname}:9001`.
Change to `${protocol}//${location.hostname}/ws`.

Nginx proxies `GET /ws` → `ws://127.0.0.1:9001`. Server still binds `:9001`
unchanged. Browser WS connection shares the HTTPS port (443); no cross-port
mixed-content issue.

```diff
-  const serverUrl = `${protocol}//${location.hostname}:9001`;
+  const serverUrl = `${protocol}//${location.hostname}/ws`;
```

---

### [D2] VPS provisioning (S — manual, one-time)
- **Depends on:** —
- **Files:** none (external action)

Provision Ubuntu 24.04 x86_64 VPS. Recommended providers:

| Provider | Plan | Cost |
|---|---|---|
| Hetzner | CX22 (2 vCPU, 4 GB) | ~€4/mo |
| DigitalOcean | Basic Droplet (1 GB) | ~$6/mo |
| Vultr | Cloud Compute (1 GB) | ~$6/mo |

Steps:
1. Create instance with Ubuntu 24.04 x86_64
2. Add SSH public key during creation
3. Note the IPv4 address

---

### [D3] VPS setup script — `scripts/vps-setup.sh` (M)
- **Depends on:** D2
- **Files:** `scripts/vps-setup.sh`

One-time manual run as root on the freshly provisioned VPS. Creates all
persistent server-side infrastructure: packages, users, directories, systemd
unit, and Nginx config.

**Packages:**
```
apt-get update && apt-get install -y nginx certbot python3-certbot-nginx
```

**Service user:**
```
useradd -r -s /bin/false dragoncon
mkdir -p /opt/dragoncon /var/www/dragoncon
chown dragoncon:dragoncon /opt/dragoncon
```

**Deploy user** (used by GitHub Actions SSH):
```
useradd -m -s /bin/bash deploy
mkdir -p /home/deploy/.ssh
# (paste GitHub Actions public key into /home/deploy/.ssh/authorized_keys)
# Grant deploy user rights to copy files and restart the service:
echo "deploy ALL=(root) NOPASSWD: /bin/systemctl restart dragoncon-server" \
  >> /etc/sudoers.d/deploy
echo "deploy ALL=(root) NOPASSWD: /usr/bin/install -o dragoncon -g dragoncon -m 755 * /opt/dragoncon/server" \
  >> /etc/sudoers.d/deploy
```

**systemd unit** (`/etc/systemd/system/dragoncon-server.service`):
```ini
[Unit]
Description=DragonCon Game Server
After=network.target

[Service]
User=dragoncon
ExecStart=/opt/dragoncon/server
WorkingDirectory=/opt/dragoncon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**Nginx config** (`/etc/nginx/sites-available/dragoncon`):
```nginx
server {
    listen 80;
    server_name _;          # replaced by certbot once domain is ready

    root /var/www/dragoncon;
    index index.html;

    # WebSocket proxy → game server
    location /ws {
        proxy_pass         http://127.0.0.1:9001;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "Upgrade";
        proxy_set_header   Host       $host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # Static WASM assets
    location / {
        try_files $uri $uri/ =404;
        # WASM MIME type (nginx may not have it on Ubuntu 24.04)
        types {
            application/wasm wasm;
        }
    }
}
```

```
ln -s /etc/nginx/sites-available/dragoncon /etc/nginx/sites-enabled/dragoncon
rm -f /etc/nginx/sites-enabled/default
systemctl enable --now dragoncon-server
systemctl reload nginx
```

**Note on Raylib:** The server binary links Raylib statically (required because
`session.zig` imports `debug_zig` which imports `hud.zig`). Raylib draw
functions are never called at runtime — `rl.initWindow()` is never invoked by
the server. No X11/display server is needed on the VPS.

---

### [D4] GitHub Actions workflow — `.github/workflows/deploy.yml` (M)
- **Depends on:** D1, D3
- **Files:** `.github/workflows/deploy.yml`

Triggers: `push` to `main` only.

#### Job 1: `build`

Runs on `ubuntu-24.04`.

```yaml
steps:
  - uses: actions/checkout@v4

  - uses: mlugg/setup-zig@v2
    with:
      version: "0.15.2"

  # Cache Zig package fetches between runs
  - uses: actions/cache@v4
    with:
      path: ~/.cache/zig
      key: zig-${{ hashFiles('build.zig.zon') }}

  # Emscripten SDK — pin to the commit in build.zig.zon
  - uses: mymindstorm/setup-emsdk@v14
    with:
      version: d6b88f4ffd8d6163aadb6ff48ca4b32ceec890dd

  # Unit tests (zig build test covers ECS, shared, session)
  - run: zig build test

  # E2E test (spawns real server + 2 bot clients)
  - run: zig build e2e

  # Server binary (ReleaseSafe: keeps safety checks, good for production)
  - run: zig build server -Doptimize=ReleaseSafe

  # WASM client
  - run: zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall

  # Copy hand-written web assets into the WASM output dir
  - run: cp web/index.html web/ws_glue.js zig-out/web/

  - uses: actions/upload-artifact@v4
    with:
      name: dragoncon-artifacts
      path: |
        zig-out/bin/server
        zig-out/web/
```

#### Job 2: `deploy`

Runs after `build` completes, only on `main`.

```yaml
needs: build
if: github.ref == 'refs/heads/main'
steps:
  - uses: actions/download-artifact@v4
    with:
      name: dragoncon-artifacts

  # Copy server binary
  - uses: appleboy/scp-action@v0.1.7
    with:
      host: ${{ secrets.VPS_HOST }}
      username: ${{ secrets.VPS_USER }}
      key: ${{ secrets.VPS_SSH_KEY }}
      source: "zig-out/bin/server"
      target: "/tmp/dragoncon-deploy/"

  # Copy WASM/web assets
  - uses: appleboy/scp-action@v0.1.7
    with:
      host: ${{ secrets.VPS_HOST }}
      username: ${{ secrets.VPS_USER }}
      key: ${{ secrets.VPS_SSH_KEY }}
      source: "zig-out/web/"
      target: "/var/www/dragoncon/"
      strip_components: 2   # removes zig-out/web/ prefix

  # Install binary + restart service
  - uses: appleboy/ssh-action@v1.0.3
    with:
      host: ${{ secrets.VPS_HOST }}
      username: ${{ secrets.VPS_USER }}
      key: ${{ secrets.VPS_SSH_KEY }}
      script: |
        sudo install -o dragoncon -g dragoncon -m 755 \
          /tmp/dragoncon-deploy/zig-out/bin/server \
          /opt/dragoncon/server
        sudo systemctl restart dragoncon-server
```

**GitHub repo secrets required:**

| Secret | Value |
|---|---|
| `VPS_HOST` | VPS IPv4 address |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | ED25519 private key matching key in `/home/deploy/.ssh/authorized_keys` |

---

### [D5] Domain + TLS (S — after D4 verified over HTTP)
- **Depends on:** D2, D4
- **Files:** none (external action + one VPS command)

`waves.json` is managed separately on the VPS (not deployed from CI — see
non-goals). TLS is the last step; the game is playable over plain HTTP first.

1. Register domain (or free subdomain via `duckdns.org`, `nip.io`, etc.)
2. Set DNS A record → VPS IP; wait for propagation
3. On VPS: `certbot --nginx -d <your-domain>`
   - Certbot edits the Nginx config to add `listen 443 ssl` and redirects HTTP → HTTPS
   - Installs auto-renew cron/timer
4. Nginx now serves HTTPS; browser sends `wss://` automatically
   (`location.protocol === "https:"` → `wss:` in `index.html`)

---

## Non-Goals

- `waves.json` is **not** deployed by CI — it lives at `/opt/dragoncon/waves.json`
  on the VPS and is edited there directly. Hot-reload picks up changes at
  runtime without a redeploy.
- No Docker / containerization — binary deploy via SCP is sufficient for a
  single-binary Zig server.
- No staging environment — deploy goes straight to production on `main`.
- No horizontal scaling — one server instance, one game room. The current
  `g_session` global is not multi-tenant.
- No CDN for WASM assets — Nginx serves them directly. Add Cloudflare in front
  later if needed.

---

## Acceptance Criteria

- [ ] `zig build test && zig build e2e` pass in CI on every push to `main`
- [ ] Push to `main` triggers a deploy without manual intervention
- [ ] `https://<domain>/` loads the name-entry form in a browser
- [ ] Entering a name and clicking Join connects over `wss://` (DevTools Network tab shows 101 Switching Protocols)
- [ ] Two browser tabs can join the same lobby and play a game to completion
- [ ] `waves.json` edits on the VPS take effect within 5 seconds without restart

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Raylib static link pulls in X11/GL symbols — linker fails on headless CI | Low | High | `ubuntu-24.04` runners have `libGL`/`libX11` dev headers; raylib-zig links statically so no runtime dep. If link fails, add `apt-get install -y libgl1-mesa-dev libx11-dev` to CI. |
| Emscripten version mismatch with `raylib_zig` | Medium | High | Pin emsdk setup action to exact commit `d6b88f4f` from `build.zig.zon` |
| Zig dep fetch slow in CI | Low | Low | Cache `~/.cache/zig` keyed on `build.zig.zon` hash |
| Long-lived WS connections dropped by Nginx | Medium | High | `proxy_read_timeout 3600s` in Nginx `/ws` block |
| Server crashes with no restart | Low | High | `Restart=always` + `RestartSec=5` in systemd unit |
| `waves.json` missing at server startup | Medium | Medium | Add startup check or default fallback in `hot_reload.zig`; document path in vps-setup.sh |

---

## Open Items (Non-Blocking)

- [ ] Decide domain registrar / DNS provider → Owner: you
- [ ] Generate ED25519 deploy keypair; add public key to VPS, private key to GitHub secrets → Owner: you
- [ ] Verify `zig build e2e` passes consistently (noted as "not tested E2E" in `specs/next-steps.md`) → Owner: you, before merging D4
