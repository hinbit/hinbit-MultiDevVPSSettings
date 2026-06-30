# VPS Install Notes - UI Control Service

This file is the Multidev install contract for the app.

## What Multidev should look for

- root scripts in `package.json`
- complete env templates, including empty keys
- optional extra nginx route hints
- optional DB / connector wiring

## Route hints

If the app exposes extra HTTP routes that need to be served by nginx on a different upstream port, keep them in the JSON block below.
Multidev will look for this file during install and update, and will wire the routes automatically when the block is present.

```vps-install
{
  "proxy_routes": [
    {
      "path": "/api",
      "port": 3000,
      "type": "prefix"
    }
  ]
}
```

## Notes

- main runtime port example: 3000
- keep `PORT`, `APP_PORT`, `GUI_PORT`, `API_PORT`, `DB_*`, `MYSQL_*`, `CONNECTOR_*`, `PUBLIC_URL`, and `API_BASE_URL` in the env template when relevant
- use `server/.env`, `client/.env`, or `dashboard/.env` if the repo has split runtime files
- use `PREINSTALL_REQUIREMENTS.md` for OS packages or browser binaries such as Chromium
- make sure the root runtime process stays alive under PM2; a successful build does not create a service by itself
- add a `/health` or `/api/health` route so Multidev smoke tests can confirm the domain serves the same app as the local port
- do not hardcode localhost ports into the browser bundle
