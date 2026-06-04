# Multidev App Install Guide

This guide is for future Codex sessions that need to adjust an app so it installs cleanly on MultidevVPS in one run.

The goal is simple:
- `projectctl install` should finish without manual fixes
- the app should boot on the VPS immediately after install
- the project should already have correct env values, DB wiring, ports, and build/start commands
- the manage UI should not need a follow-up rescue step

## 1. Put the canonical scripts in the repo root

Multidev works best when the root `package.json` exposes the real install/runtime entry points.

Preferred root scripts:
- `start` for the production runtime
- `prod` when production runtime is separate from `start`
- `build` for the production build
- `install:all` for a full dependency install
- `db:init` for schema creation / initial support tables
- `db:seed` for demo data and required users
- `db:migrate` for schema evolution

If the real implementation lives in `server/` or `client/`, add root aliases that proxy to those folders.

Do not rely on a manual command that only exists in a subfolder.
If Multidev cannot detect it from the root, installs become fragile.

Good patterns:
- `npm start`
- `npm run prod`
- `npm run build`
- `npm run db:init`
- `npm run db:seed`
- `npm run install:all`

Avoid:
- commands that only work after `cd server`
- commands that only work after `cd client`
- developer-only commands that ignore the Multidev port/env contract

## 2. Keep the scripts in predictable locations

Recommended repo layout:

```text
package.json
README.md
CODEX.md
PREINSTALL_REQUIREMENTS.md
EMBEDDING_GUIDE.md   # only if the app actually needs it
scripts/
  env.mjs
  init-db.mjs
  seed-db.mjs
  wait-for-db.mjs
server/
  index.js
  db.js
  routes/
  middleware/
  scripts/
    support.sql or app-specific support SQL
client/
  src/
  vite.config.js
```

If the app is split into server and client parts:
- the root `start` or `prod` script must still be the one Multidev can call
- the root `build` script must build the real production bundle
- the root DB scripts must still be visible and runnable

## 3. Ship complete env templates

The repo should include env templates with all keys the app expects.

Important rules:
- include keys even when the value is empty
- do not hide required keys behind local-only machine state
- use `.env.example` and `.env.production.example` as the source of truth when possible
- if the app has more than one runtime component, each component must have the keys it needs

Why this matters:
- Multidev merges env files during install and pull
- shell-sourced scripts need safe values
- missing keys are harder to recover than extra keys

Use quoted values when a value contains spaces or special characters.
Example:

```env
GUI_TITLE='My App Admin'
```

Do not leave a value unquoted if your installer or seed scripts will source the file as shell.

## 4. Make the app production-aware

The app must clearly distinguish between:
- local dev
- production on the VPS

Common keys that should be normalized for the VPS install:
- `NODE_ENV`
- `APP_ENV`
- `ENVIRONMENT`
- `MODE`
- `DEPLOYMENT`
- `SERVER_LOCATION`
- `APP_LOCATION`
- `DEPLOY_TARGET`
- `LOCATION`
- `RUNTIME_TARGET`
- `SERVER_MODE`

For Multidev installs, these should resolve to the production/web value unless the app has a special reason not to.

Do not hardcode localhost into the app bundle if the app is meant to be public.
Prefer:
- relative URLs like `/api`
- deploy-time public base URLs
- runtime env values that point at the installed domain

## 5. Make ports install-safe

Do not hardcode ports that can collide with other apps.

Rules:
- the app should respect the port Multidev writes into the env
- split-runtime apps should keep internal service ports separate from the public project port
- if a port is already occupied, choose a different one
- avoid common ports when possible

Examples:
- public project port
- internal API port
- UI port
- connector relay port

If the app has multiple runtime pieces, keep their responsibilities explicit in env:
- public port for the project entrypoint
- internal API port if the app needs one
- GUI port if the UI is separate
- connector or relay port if a messaging component exists

## 6. Make DB setup one-run friendly

If the app needs MySQL:
- `db:init` should create schema and support tables idempotently
- `db:seed` should be safe to rerun
- the app should be able to boot immediately after install with the correct DB user/password

Use this order:
1. install dependencies
2. create or sync DB user and grants
3. run `db:init`
4. run `db:seed`
5. build if needed
6. start the app

The app should not require a human to manually create the DB user after install.

If the app has a demo login or required admin user:
- seed it in `db:seed`
- document the credentials in `README.md`
- make the seed idempotent

If the app needs support tables that are not part of the main schema:
- put them in a separate support SQL file
- make `db:init` apply them every time

## 7. Use the correct start kind

Multidev can only manage what it can infer.

Make sure the app exposes one of these clean start paths:
- `start`
- `prod`
- `ecosystem.config.cjs` only if the root install flow can resolve it reliably

If you use PM2 ecosystem files:
- the ecosystem should live at a known location
- the root scripts should still point to the real runtime
- the installed env values must reach the process

Avoid:
- starting with a laptop-only command
- starting without loading the project env
- starting on the wrong port because the app ignored the installed env

## 8. Database machine handling

Multidev supports:
- local current DB
- remote DB machine
- custom manual DB connection

The app should support these cases without code changes:
- local DB on the same VPS
- remote DB selected from the DB machine list
- custom DB host saved per project

For custom DB machines:
- saving connection details should not require root creds
- moving data should be a separate action
- the app should use the saved custom DB values after reconnect

## 9. Post-install verification checklist

After changing the app repo for Multidev, the installing Codex session should verify:

1. `projectctl install` or `projectctl update` completes
2. the project appears in the Multidev project list
3. the PM2 process is online
4. the app responds on localhost
5. the public domain loads
6. login works if the app has auth
7. DB init/seed ran successfully
8. QR / webhook / connector features work if the app provides them
9. the manage UI shows the correct repo, port, domain, and DB status

If any step fails, fix it before handing the app back.

## 10. Common failure modes to check first

When an install is not smooth, inspect these first:
- wrong GitHub repo slug
- missing SSH key access to the repo
- wrong root `package.json` scripts
- env values not quoted correctly
- `DB_USER` / `DB_PASSWORD` mismatch
- support tables not created
- app listening on the wrong port
- app ignoring the installed env
- domain mapped to the wrong process
- public URL pointing to the wrong host or port

Typical symptoms:
- `Repository not found` => GitHub access or wrong slug
- `Access denied for user ...` => DB user/grants/env mismatch
- `EADDRINUSE` => wrong port chosen or port not preserved
- `Table ... doesn't exist` => `db:init` did not run the support SQL
- public domain opens the wrong app => app-map / nginx mapping mismatch

## 11. What future Codex sessions should change in the repo

Before handing the app over to Multidev, make sure the repo itself documents:
- where the production start command lives
- which env values are required
- whether the app uses MySQL and what `db:init` / `db:seed` do
- whether the app has multiple runtime ports
- whether the app needs any support tables or demo users

The repo should be self-describing enough that Multidev can install it once, verify it, and keep it running without manual rescue steps.

