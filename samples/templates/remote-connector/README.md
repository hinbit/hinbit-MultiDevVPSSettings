# Remote DB + Connector App Template

This is the installable skeleton version.

## Purpose

An app that uses a remote DB machine and an outbound connector such as 360dialog or Twilio.

## Port glossary

- `PORT`: primary runtime port for the app process.
- `APP_PORT`: Multidev-assigned app port, if the installer writes one.
- `GUI_PORT`: separate browser UI port when the UI is split from the API.
- `API_PORT`: backend API port when the UI and API are separate processes.
- `DB_HOST` / `DB_PORT`: database host and TCP port.
- `MYSQL_HOST` / `MYSQL_PORT`: MySQL-specific host and port.
- `DB_MACHINE_ID`: Multidev DB machine selection such as `local-current` or `seach-db`.
- `CONNECTOR_PORT`: relay port for external API connectors.
- `ACTIVE_CONNECTOR`: connector selector such as 360dialog or Twilio.
- `WEBHOOK_TOKEN`: auth token for webhook or callback endpoints.
- `PUBLIC_URL` / `API_BASE_URL`: public domain or API base used by the client.
- `PREINSTALL_REQUIREMENTS.md`: OS packages or browser binaries the app needs before startup.
- `start` must launch the long-lived runtime on `PORT`; a build artifact alone is not enough for Multidev.
- ship a health endpoint and make sure the process stays online under PM2 after install/update.

## Install rule

Future Codex sessions should copy this template into a real repo, keep the root `package.json` start script visible to Multidev, and make sure env values are complete before install.
Multidev will retry the PM2 restart and the smoke test once, but the app still has to boot successfully under `npm start` or the equivalent root start script.
If the app needs special nginx/path wiring, put it in `VPS-INSTALL.MD` as a JSON block so Multidev can wire it automatically during install/update.
If the app needs OS packages or browser binaries before startup, add them to `PREINSTALL_REQUIREMENTS.md` so Multidev installs them before dependency setup.
