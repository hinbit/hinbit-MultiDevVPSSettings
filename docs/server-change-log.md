# Server Change Log

This document records the server-side changes applied during the MultiDev / VPS setup work.

## `seach-web` server

Host:
- `82.70.217.246`

Role:
- Hosts the MultiDev manage UI and the project runtime for installed apps.

Changes made:
- Installed and configured the manage UI service.
- Added SSH alias support in `~/.ssh/config` for access as `seach-web`.
- Deployed `projectctl` to manage GitHub clones, installs, restarts, and DB wiring.
- Added `/manage/` portal routing and kept the project dashboard on `/manage/`.
- Added `/manage/tls/` for certificate handling in the UI.
- Added a portal page on `/` for quick access to Projects, SSH Keys, DB Vault, DB Machines, and TLS.
- Added Cloudflare Tunnel support for the manage UI.
- Added support for custom TLS certificates stored under `/etc/vps-custom-certs/`.
- Added default app-domain TLS fallback so a cert for `seach.co.il` can be used by subdomains like `mon2026.seach.co.il` unless a project-specific cert exists.
- Added DB script discovery in the install flow and project UI:
  - scans root `package.json`
  - scans `server/package.json`
  - scans `client/package.json`
  - shows DB-related scripts with Run / Activate buttons
- Updated project install/update logic to stamp the requested app port into project env files.
- Updated project startup detection so dev-style repos with a `prod` script boot in production mode instead of launching Vite dev mode.
- Updated port/env writing so the selected app port is persisted to `.env` and `server/.env`.

Current runtime notes:
- `mon2026.seach.co.il` is mapped to the app on port `4311`.
- The app itself serves correctly from the VPS origin.
- Public access still depends on the upstream network / provider path.

## `seach-db` server

Host:
- `82.70.221.66`

Role:
- Remote MySQL machine for projects that use a non-local DB.

Changes made:
- Installed MySQL 8.0.
- Configured MySQL access for the web server through the SSH tunnel path.
- Added SSH alias support in `~/.ssh/config` for access as `seach-db`.
- Added reverse-proxy handling for the manage UI at one point, then removed stale manage tunnel / cloudflared artifacts after the web server became the active manage host.
- Kept the DB machine registration path in the manage UI so it can be selected from the project MySQL panel.
- Project DB creation / grants are now performed on the selected DB machine, not just locally.

Current runtime notes:
- The web server reaches MySQL on the DB machine through `127.0.0.1:3307` on the web host side, which is the SSH tunnel endpoint.
- The actual remote DB server remains `82.70.221.66`.

## Install-definition changes

The following install behavior changes were added to `projectctl` and the manage UI:

- `projectctl install` now writes the requested app port into project env files.
- `projectctl update` now re-detects startup mode so production repos with a real `prod` script are started with `npm run prod` instead of `npm run dev`.
- `projectctl script` now supports `--dir` so scripts in `server/` or `client/` can be run directly.
- The manage UI now shows DB-related scripts discovered during install and lets you run or activate them from the UI.
- TLS handling now supports:
  - server default certs
  - per-project certs
  - default app-domain certs for shared base domains like `seach.co.il`
- When a project-specific certificate is not present, the app sync now prefers the default app-domain certificate if one exists.

## Notes

- No passwords, private keys, or tunnel tokens are stored in this document.
- The exact values for credentials remain on the servers and are not committed to the repo.
