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

## Install rule

Future Codex sessions should copy this template into a real repo, keep the root `package.json` start script visible to Multidev, and make sure env values are complete before install.
If the app needs special nginx/path wiring, put it in `VPS-INSTALL.MD` as a JSON block so Multidev can wire it automatically during install/update.
