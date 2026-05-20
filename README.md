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

## What it does not install

- app source code
- app-specific databases
- DNS records
- Cloudflare configuration

## Files

- [bootstrap/install.sh](bootstrap/install.sh)
- [bootstrap/projectctl.sh](bootstrap/projectctl.sh)
- [bootstrap/structure.md](bootstrap/structure.md)

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

Pull updates and restart PM2 for an existing project:

```bash
projectctl update owner/repo
projectctl restart owner/repo
projectctl uninstall owner/repo
```

Optional environment variables:

- `ACME_EMAIL` for Let's Encrypt notifications
- `ADMIN_USER` to create a non-root sudo user
- `ADMIN_SSH_PUBKEY` to install an SSH public key for that user
- `PROJECT_PORT_START` / `PROJECT_PORT_END` to change the auto-assigned port range
- `--branch` and `--pm2-name` on `projectctl install` to override repo branch and PM2 process name
- `--env-file` to inject a repo `.env` before build/start
- `--entrypoint` to force the PM2-managed runtime file or command when auto-detection is not enough
- when a domain is set, `VITE_ALLOWED_HOSTS` and `CORS_ORIGIN` are exported into the PM2 runtime

## Runtime layout

- `/etc/app-map.csv` maps domain to port
- `/etc/app-watch.csv` lists PM2 apps to monitor
- `/etc/vps-projects/*.env` stores project metadata for `projectctl`
- `/usr/local/bin/app-sync.sh` generates nginx and TLS config
- `/usr/local/bin/pm2-smart-restart.sh` restarts PM2 apps when watched files change
- `/usr/local/bin/projectctl` manages GitHub project installs and updates
- `/etc/systemd/system/pm2-root.service` resurrects PM2 at boot
