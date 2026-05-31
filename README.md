# MultiDevVPSSettings

Bootstrap for a clean Ubuntu VPS that hosts multiple Node/React apps behind nginx and Let's Encrypt.

## What this project installs

- nginx reverse proxy with per-domain vhosts
- Node.js 20 and PM2
- MySQL
- certbot for TLS
- php8.3-fpm and phpMyAdmin
- UFW, fail2ban, and unattended upgrades
- the app routing files used by `app-sync.sh`
- `projectctl` for GitHub clone/pull/restart workflows
- a `/manage/` control panel on the system portal for installs, restarts, updates, logs, stop/kill, project passwords, DB details, environment files, package scripts, and machine stats

## What it does not install

- app source code
- app-specific databases
- DNS records
- Cloudflare configuration
- Cloudflare Tunnel

## Files

- [bootstrap/install.sh](bootstrap/install.sh)
- [bootstrap/projectctl.sh](bootstrap/projectctl.sh)
- [bootstrap/structure.md](bootstrap/structure.md)
- [docs/new-server-runbook.md](docs/new-server-runbook.md)

## Usage

Run the installer as root on a clean Ubuntu VPS:

```bash
bash bootstrap/install.sh
```

Install a new GitHub project and map it to a domain:

```bash
projectctl install --domain example.com --branch main --pm2-name example-app owner/repo
projectctl install --domain example.com --branch main --pm2-name example-app --env-file /root/app.env --entrypoint server/index.js owner/repo
```

If the repo is private under a separate GitHub account, configure root's `~/.ssh/config` on the app VPS so `Host github.com` uses the matching key. `projectctl` clones as root, so uploading a key into the VPS is not enough by itself.

If you install a project before DNS/TLS is ready, `projectctl` will now finish the install and leave the site on HTTP for the moment. Re-run `sudo app-sync.sh` after the domain resolves to the VPS to activate the SSL vhost.

Pull updates and restart PM2 for an existing project:

```bash
projectctl update owner/repo
projectctl restart owner/repo
projectctl uninstall owner/repo
```

Run an ad-hoc package script from an existing project:

```bash
projectctl script owner/repo db:fill
projectctl script --pm2 owner/repo dev
```

Optional environment variables:

- `ACME_EMAIL` for Let's Encrypt notifications
- `ADMIN_USER` to create a non-root sudo user
- `ADMIN_SSH_PUBKEY` to install an SSH public key for that user
- `MANAGE_PASSWORD` to protect `https://multidev.hinbit.com/manage/`
- `PROJECT_PORT_START` / `PROJECT_PORT_END` to change the auto-assigned port range
- `--branch` and `--pm2-name` on `projectctl install` to override repo branch and PM2 process name
- `--env-file` to inject a repo `.env` before build/start
- `--entrypoint` to force the PM2-managed runtime file or command when auto-detection is not enough
- when a domain is set, `VITE_ALLOWED_HOSTS` and `CORS_ORIGIN` are exported into the PM2 runtime

Manage access can be exposed either directly on public `80/443` with nginx and Let's Encrypt, or through Cloudflare Tunnel.
If you use a tunnel, run `cloudflared` on the server that hosts the manage UI and route the hostname to the local manage port:

```text
multidev.seach.co.il -> http://127.0.0.1:8090
```

The tunnel should point to the machine serving `/manage/`, not the separate DB host unless you intentionally want that host to proxy the UI.
The root path `/` now serves the portal landing page, and `/manage/` serves the project dashboard.

## Runtime layout

- `/etc/app-map.csv` maps domain to port
- `/etc/app-watch.csv` lists PM2 apps to monitor
- `/etc/vps-projects/*.env` stores project metadata for `projectctl`
- `/usr/local/bin/app-sync.sh` generates nginx and TLS config
- `/usr/local/bin/pm2-smart-restart.sh` restarts PM2 apps when watched files change
- `/usr/local/bin/projectctl` manages GitHub project installs and updates
- `/usr/local/bin/manage-server.mjs` powers the web UI at `/manage/`
- `/etc/vps-system.env` stores manage-panel credentials if configured
- `/etc/systemd/system/pm2-root.service` resurrects PM2 at boot
