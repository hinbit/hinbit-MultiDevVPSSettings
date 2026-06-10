# Multidev Sample Program Pack

This pack describes four installable skeleton application shapes and their runnable `2run_` smoke-test copies.

## The four sample programs

1. `ui-control` - service-only app with a browser UI, no DB machine required.
2. `light-no-db` - very light app with no DB dependency.
3. `local-db` - app that uses the local MySQL instance on the VPS.
4. `remote-connector` - app that uses a remote DB machine and an outbound connector layer such as 360dialog or Twilio.

## How to read the examples

- `PORT` is the main runtime port Multidev should assign.
- `APP_PORT` is the saved Multidev app port when present.
- `GUI_PORT` is for split UI processes.
- `API_PORT` is for split API processes.
- `DB_HOST` / `DB_PORT` / `MYSQL_HOST` / `MYSQL_PORT` describe database connectivity.
- `CONNECTOR_PORT` is for connector relay services.
- `PUBLIC_URL` / `API_BASE_URL` should point at the installed domain, not localhost.
- `VPS-INSTALL.MD` can hold a JSON route block for extra nginx wiring that should be installed automatically.

## Install goal

The idea is to let another Codex session copy one of these skeletons into a real app repo and have Multidev install it in one run without manual rescue.
Each template already includes a root `package.json` with `start`, `dev`, and `check`, so the Multidev start detector has a real entrypoint to find.

## Samples layout

- `samples/templates/{progname}` = installable skeleton with root runtime files
- `samples/2run_{progname}` = runnable quiz smoke test copy
