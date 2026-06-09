# VPS Install Notes - Local DB App 2run

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
  "proxy_routes": []
}
```

## Notes

- main runtime port example: 8002
- keep `PORT`, `APP_PORT`, `GUI_PORT`, `API_PORT`, `DB_*`, `MYSQL_*`, `CONNECTOR_*`, `PUBLIC_URL`, and `API_BASE_URL` in the env template when relevant
- use `server/.env`, `client/.env`, or `dashboard/.env` if the repo has split runtime files
- do not hardcode localhost ports into the browser bundle
