# Multidev Install Spec

This is the canonical guide for making an app install cleanly on MultidevVPS in one run and for how future Codex sessions should verify it.

It merges two goals:
- the app should expose a shape that `projectctl` can install without manual rescue
- the install session should validate the live VPS state and fix anything that is not mapped correctly

## 1. Canonical repo layout

Keep the main install/runtime entry points at the repo root.

Recommended root files:
- `package.json`
- `README.md`
- `CODEX.md`
- `PREINSTALL_REQUIREMENTS.md`
- `EMBEDDING_GUIDE.md` if the app actually needs embedding/model setup

Recommended folders:
- `scripts/` for env loading, DB init, seed, wait helpers
- `server/` for the backend
- `client/` for the frontend

If `server/` or `client/` contain the real runtime logic, the root scripts must proxy to them so Multidev can still detect and run the app from the root.

## 2. Required script names

Prefer these canonical script names in the root `package.json`:
- `start` for the production runtime entry
- `prod` for an explicit production runtime if needed
- `build` for the production build
- `install:all` for dependency installation across root, `server/`, and `client/`
- `db:init` for schema + support tables
- `db:seed` for demo data and required users
- `db:migrate` for schema evolution

If the real runtime or DB command lives in a subfolder, expose a root alias for it.

Avoid:
- commands that only work after `cd server`
- commands that only work after `cd client`
- hidden install steps that only exist on the developer laptop

## 3. Env file contract

Ship env templates with all keys the app expects.

Rules:
- include keys even when their value is empty
- use `.env.example` and `.env.production.example` as the source of truth when possible
- if the app has more than one runtime component, each component must have the keys it needs
- quote values with spaces or special characters

Examples:

```env
GUI_TITLE='My App Admin'
DB_PASSWORD='secret value'
```

The app should remain safe when env files are sourced by shell-based scripts.

## 4. Production normalization

Multidev installs should normalize deployment-facing env values from local/dev to production/web.

Common keys to normalize:
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

Public URLs should resolve to the installed domain or a relative `/api` style path, not to localhost in a production bundle.

## 5. Port safety

Do not hardcode ports that can collide with other apps.

Rules:
- respect the port Multidev writes into the env
- preserve split-runtime apps correctly
- choose a new port if the requested one is already occupied
- avoid common ports when possible

Split-runtime apps should keep their responsibilities explicit, for example:
- public project port
- internal API port
- UI port
- connector relay port

## 6. DB flow

If the app needs MySQL:
- `db:init` must be idempotent
- `db:seed` must be safe to rerun
- install must create or sync DB user/grants before the DB init step

Recommended order:
1. install dependencies
2. create or sync DB user and grants
3. run `db:init`
4. run `db:seed`
5. build if needed
6. start the app

The app should not require a human to create the DB user manually after install.

If the app has a demo login or required admin user:
- seed it in `db:seed`
- document the credentials in `README.md`
- make the seed idempotent

If the app needs support tables outside the main schema:
- put them in a separate support SQL file
- make `db:init` apply them every time

## 7. Start kind

Multidev needs a clear start path it can infer.

Prefer one of:
- `start`
- `prod`
- a root-level `ecosystem.config.cjs` that the install flow can resolve reliably

If PM2 ecosystem files are used:
- the ecosystem should live at a known location
- prefer CommonJS (`ecosystem.config.cjs`, or `module.exports` in `.js`) so PM2 can load it reliably
- avoid `export default` in `ecosystem.config.js` unless there is also a reliable `package.json start` fallback
- root scripts should still point to the real runtime
- the installed env values must reach the process

Do not start with commands that ignore the installed env or the assigned port.

## 8. DB machine handling

Multidev supports:
- local current DB
- remote DB machine
- custom manual DB connection

The app should support all of these without code changes.

For custom DB machines:
- saving connection details should not require root creds
- moving data should be a separate action
- the app should use the saved custom DB values after reconnect
- DB host, user, password, name, and port should all be savable per project

## 9. Install-time verification

After install or pull, verify these in order:

1. Git pull or install completed
2. project appears in the Multidev project list
3. PM2 process is online
4. localhost response is healthy
5. public domain loads
6. login works if the app has auth
7. DB init/seed ran successfully
8. QR / webhook / connector features work if the app provides them
9. project DB wiring matches the saved env
10. the manage UI shows the correct repo, port, domain, and DB state

If anything is wrong, fix it before handoff.

## 10. Common failure modes

Check these first when an install is not smooth:
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

## 11. What the repo should document

Before handing the app over to Multidev, the repo itself should explain:
- where the production start command lives
- which env values are required
- whether the app uses MySQL and what `db:init` / `db:seed` do
- whether the app has multiple runtime ports
- whether the app needs any support tables or demo users
- whether any connector or webhook settings are required for live mode

## 12. Notes for future Codex sessions

When a future Codex session adapts an app for Multidev:
- treat the repo as the source of truth
- add or fix root scripts first
- make env templates complete before changing runtime code
- keep install-time DB setup idempotent
- verify the live project after install instead of assuming it worked
- if a step fails, fix it before reporting success

The intended result is a one-run install that ends with:
- correct env values
- correct DB wiring
- correct port mapping
- correct domain mapping
- correct runtime state
- no manual rescue steps

## 13. GitHub SSH mapping

Multidev can keep multiple GitHub SSH identities on the VPS.

Rules:
- each saved SSH key should record the GitHub user it belongs to
- `shaykid` should use the default `git@github.com` host alias
- `hinbit` should use `git@github-hinbit`
- `projectctl` should pull using the host alias that matches the repo owner
- the manage panel should write the SSH config for those aliases automatically

This is required so a future Codex session can install or update repos from different GitHub accounts without manual SSH config edits on the server.
