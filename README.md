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
- a `/manage/tls/` page for pasting server-default and per-project certificate + key PEMs

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
- [docs/multidev-sample-programs.md](docs/multidev-sample-programs.md)
- [samples/README.md](samples/README.md)

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

If the repo is private under a separate GitHub account, configure the SSH key in `/manage/ssh-keys/` with its GitHub user. The manage panel writes root's SSH config for you and `projectctl` will clone through the matching host alias (`github.com` for `shaykid`, `github-hinbit` for `hinbit`). `projectctl` clones as root, so uploading a key into the VPS is not enough by itself.

If you install a project before DNS/TLS is ready, `projectctl` will now finish the install and leave the site on HTTP for the moment. Re-run `sudo app-sync.sh` after the domain resolves to the VPS to activate the SSL vhost.

Pull updates and restart PM2 for an existing project:

```bash
projectctl update owner/repo
projectctl restart owner/repo
projectctl uninstall owner/repo
```

`projectctl update` now prompts with two choices when local changes exist:
- `Merge .env (default)` keeps the current VPS env values after the pull and appends any new upstream env keys
- `Stash all` stashes every local change before pulling
After every install or pull, `projectctl` runs dependency installs in the root plus `server/` and `client/` when those folders exist. The subfolder installs use `npm --prefix ...` so each component is installed in its own directory before build and restart.
After every install or pull, `projectctl` runs `build all` automatically:
- `build all` runs the root build script plus `server/` and `client/` build scripts when they exist
- the project list shows the last build mode, status, and timestamp
`projectctl` now rewrites project `.env` files in a shell-safe form, so values with spaces are quoted automatically and remain safe for scripts that source the file.
`projectctl` also skips common reserved ports when auto-picking a new app port, and it preserves split-app internal ports such as CherryWrapper's `PORT=8787` instead of overwriting them with the public UI port.

Run an ad-hoc package script from an existing project:

```bash
projectctl script owner/repo db:fill
projectctl script --pm2 owner/repo dev
projectctl script --dir server owner/repo db:seed
```

When you install a project from `/manage/`, the UI now scans the repo for DB-related scripts across the root, `server/`, and `client/` package manifests and shows the runnable ones after install.
If the project repo does not already define DB name, user, and password values, the installer now generates them automatically and writes them into the project env files so the DB and MySQL panels are populated on first install.
`projectctl install` also stamps the requested port into the project env files so the runtime uses the selected app port consistently.
`projectctl install` and `projectctl update` also normalize common deployment env keys from local/dev values to server/web values when the repo ships them in `.env` or `.env.example`-style templates, so installed projects boot in production mode instead of local browser/dev mode.
The env seeding/merge step covers the repo root plus `server/` and `client/` env files when they exist.
In the Manage UI, the merged env list is read-only and source-aware; duplicates are highlighted in red, while edits happen in the selected file only.
Projects can now keep additional domain aliases from the `Domains` panel. Each alias can point at its own env file for management, and `app-sync` will map all configured domains back to the same project.
After install or update, `projectctl` now verifies that PM2 is actually online, retries the restart once if it is not, and fails loudly if the project still does not come up.
After install or update, `projectctl` also verifies that the domain maps to the installed port in `/etc/app-map.csv` and in the generated nginx vhost, then resyncs once if the mapping is stale.
After PM2 is online, `projectctl` also runs a host-header HTTP smoke test against the installed domain, compares it against the local app response, and fails loudly if the domain serves different content.
If the repo defines root-level `db:init` and `db:seed` scripts, a fresh install runs them automatically so the new database starts with schema and seed data.

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
Use `/manage/tls/` to paste a server-default certificate for the manage host domain and a per-project certificate for any app domain. Custom certs are stored under `/etc/vps-custom-certs/` and override Let’s Encrypt on sync.
You can also save a default app-domain certificate such as `seach.co.il`; new subdomains like `mon2026.seach.co.il` will use it unless a project-specific certificate is set.

## Runtime layout

- `/etc/app-map.csv` maps domain to port
- `/etc/app-watch.csv` lists PM2 apps to monitor
- `/etc/vps-projects/*.env` stores project metadata for `projectctl`
- the Manage UI env editor can switch between individual env files and saves back to the selected file
- `/usr/local/bin/app-sync.sh` generates nginx and TLS config
- `/usr/local/bin/pm2-smart-restart.sh` restarts PM2 apps when watched files change
- `/usr/local/bin/projectctl` manages GitHub project installs and updates
- `/usr/local/bin/manage-server.mjs` powers the web UI at `/manage/`
- `/etc/vps-system.env` stores manage-panel credentials if configured
- `/etc/systemd/system/pm2-root.service` resurrects PM2 at boot
