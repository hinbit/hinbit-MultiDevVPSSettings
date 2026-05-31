# Server Change Log

This document records only the server-side changes applied on `seach-web` and `seach-db`.

## `seach-web`

Host:
- `82.70.217.246`

Role:
- Hosts the MultiDev manage UI and the project runtime for installed apps.

Changes made:
- Installed and configured the manage UI service.
- Set up nginx for the manage UI and project hosting.
- Restored the visible `Manage SSL` entry in the portal and manage header.
- Added the portal landing page at `/` and kept the main manage dashboard at `/manage/`.
- Added `/manage/tls/` for certificate handling in the UI.
- Added support for per-server certificates, per-project certificates, and a default app-domain certificate fallback.
- Added DB script discovery in the install flow and project UI:
  - scans root `package.json`
  - scans `server/package.json`
  - scans `client/package.json`
  - shows DB-related scripts with Run / Activate buttons
- Updated project install/update logic so the requested app port is written into project env files.
- Updated fresh project installs so missing DB name, user, password, and MySQL variants are generated and written into project env files automatically.
- Added a remote DB bootstrap step so the selected remote machine gets the MySQL root host entries it needs before project DB creation runs through the SSH tunnel.
- Updated project startup detection so dev-style repos with a real `prod` script boot in production mode instead of launching Vite dev mode.
- Configured MySQL access to the remote DB machine through the SSH tunnel endpoint on the web host.
- Cleaned up stale tunnel artifacts after Cloudflare Tunnel was no longer used for the public path.

Current runtime notes:
- `mon2026.seach.co.il` is mapped to the app on port `4311`.
- The app itself serves correctly from the VPS origin.
- Public access still depends on the upstream network / provider path.

## `seach-db`

Host:
- `82.70.221.66`

Role:
- Remote MySQL machine for projects that use a non-local DB.

Changes made:
- Installed MySQL 8.0.
- Configured MySQL access for the web server through the SSH tunnel path.
- Added the DB machine registration path in the manage UI so it can be selected from the project MySQL panel.
- Project DB creation and grants are performed on the selected DB machine instead of only locally.
- Removed stale manage tunnel / Cloudflare tunnel artifacts once the web server became the active manage host.

Current runtime notes:
- The web server reaches MySQL on the DB machine through `127.0.0.1:3307` on the web host side, which is the SSH tunnel endpoint.
- The actual remote DB server remains `82.70.221.66`.

## Notes

- No passwords, private keys, or tunnel tokens are stored in this document.
- The exact credential values remain on the servers and are not committed to the repo.
