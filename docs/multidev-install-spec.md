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
- `PREINSTALL_REQUIREMENTS.md` for any OS packages or runtime binaries the app needs before install/build
- `EMBEDDING_GUIDE.md` if the app actually needs embedding/model setup

Recommended folders:
- `scripts/` for env loading, DB init, seed, wait helpers
- `server/` for the backend
- `client/` for the frontend

Also include a root `VPS-INSTALL.MD` when the app needs extra runtime wiring. Multidev looks for it during install/update and can use a machine-readable JSON route block inside it to generate extra nginx locations.

If `server/`, `client/`, or `dashboard/` contain the real runtime logic, the root scripts must proxy to them so Multidev can still detect and run the app from the root.

## 2. Required script names

Prefer these canonical script names in the root `package.json`:
- `start` for the production runtime entry
- `prod` for an explicit production runtime if needed
- `build` for the production build
- `install:all` for dependency installation across root, `server/`, `client/`, and `dashboard/`
- `db:init` for schema + support tables
- `db:seed` for demo data and required users
- `db:migrate` for schema evolution

If the app is intended to run in Docker on Multidev, it should still keep the same root contract and scripts. Multidev can launch it with `projectctl install --runtime docker`, which runs the app inside a host-network container so local MySQL on `127.0.0.1` and remote DB machines both continue to work through the same env files.

If the real runtime or DB command lives in a subfolder, expose a root alias for it.
Sample-derived repos must still ship a root `package.json` with `start`, even if the real implementation lives under `server/`, `client/`, or `dashboard/`.

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
- seed and merge env templates in the repo root, `server/`, `client/`, and `dashboard/` when those folders exist
- the Multidev env editor shows a read-only merged summary, grouped by key source, and it can switch between individual files such as `.env`, `.env.local`, `.env.production`, `.env.machine`, `server/.env`, `client/.env`, and `dashboard/.env`
- duplicate keys inside a file or across files must be marked clearly in red in the merged summary
- save actions write back to the selected file, not the merged view
- if one project should answer to more than one domain, store a primary domain plus alias bindings, and let each alias carry its own env-file path for management and editing
- when the install or pull flow resolves dependencies, root plus `server/`, `client/`, and `dashboard/` should be installed separately, and the subfolder installs should use `npm --prefix <folder>` so each component is refreshed in place before build

Examples:

```env
GUI_TITLE='My App Admin'
DB_PASSWORD='secret value'
```

The app should remain safe when env files are sourced by shell-based scripts.

## 3.5 Preinstall requirements

If an app needs extra OS packages or runtime binaries before Multidev runs `npm install` and builds the repo, declare them in `PREINSTALL_REQUIREMENTS.md`.
Multidev reads the root file and any `server/`, `client/`, or `dashboard/` copy, merges the declared package list, and installs it with `apt-get install -y` before dependency installation.

Use a fenced `vps-requirements` JSON block:

```md
```vps-requirements
{
  "apt": ["chromium", "fonts-liberation"]
}
```
```

Keep the list empty when no extra system packages are required. Use package names that `apt-get install` can resolve on the target Ubuntu image.

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
- choose a new port if the requested one is already occupied or already assigned to another Multidev project in `/etc/vps-projects`
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

After a pull, Multidev should first re-run the domain mapping and HTTPS vhost checks, then run `build all` so any missing app-map or vhost wiring is repaired before the build is considered done.
`build all` runs the root build script plus `server/`, `client/`, and `dashboard/` build scripts when present.

The app should not require a human to create the DB user manually after install.

If the app has extra HTTP routes that must land on a non-default upstream port, document them in `VPS-INSTALL.MD` so Multidev can wire them automatically during install/update.

## 6.5 Project duplication behavior

Multidev supports duplicating an installed project into a new domain-bound copy.

Rules for duplicate-ready repos and installs:
- the duplicate is a copy of the source project, not a new Git remote pull target
- duplicate projects may keep their own env files or share the source env mode chosen at creation time
- duplicate projects may keep the same DB or get a separate DB depending on the creation choice
- duplicate projects can keep a custom PM2 process name, but the name should not collide with the original project
- when the original project is pulled, Multidev should recopies and restart all duplicates that point back to it
- when a duplicate is pulled, Multidev should ignore Git pull and recopy from the original source project instead
- duplicate metadata should keep the original source repo reference so refreshes remain tied to the parent project

The install UI should expose:
- new domain name
- env mode: copy or share
- DB mode: same or separate
- PM2 config / PM2 name choice

The duplicate flow must still preserve the standard install checks: mapping, nginx, PM2, build, DB bootstrap, and smoke tests.

If the app has a demo login or required admin user:
- seed it in `db:seed`
- document the credentials in `README.md`
- make the seed idempotent

If the app needs support tables outside the main schema:
- put them in a separate support SQL file
- make `db:init` apply them every time

## 6.1 Exact repo shape for reliable first install

The safest structure for Multidev is:

```text
repo-root/
  package.json
  README.md
  CODEX.md
  PREINSTALL_REQUIREMENTS.md
  VPS-INSTALL.MD
  .env.example
  .env.production.example
  server/
    package.json
    .env.example
    .env.production.example
    index.js
  client/
    package.json
    .env.example
    .env.production.example
  dashboard/
    package.json
    .env.example
    .env.production.example
```

Minimum root contract:
- root `package.json` exists
- root `package.json` has `start`
- root `package.json` has `build`
- root `package.json` has `install:all`, `db:init`, and `db:seed` when the app needs them
- root scripts proxy into `server/`, `client/`, or `dashboard/` when that is where the real code lives
- env templates exist before the first install
- route special cases are documented in root `VPS-INSTALL.MD`
- hostnames should be treated case-insensitively, but Multidev normalizes them to lowercase before writing cert paths, nginx filenames, and app-map entries

Good pattern:
- Multidev installs the root app first
- subfolders are optional, but if they exist, they also have package.json files
- root scripts are the stable install surface
- `projectctl` can install root deps, then `npm --prefix server install`, `npm --prefix client install`, and `npm --prefix dashboard install`
- `build all` can then verify every runtime piece before handoff

Bad pattern:
- `cd server && npm start` as the only real entrypoint
- missing root `package.json`
- missing `.env.example` keys
- hidden laptop-only setup steps
- generated blobs or huge data inside `.env`

If the app must answer on more than one route or domain, keep the root scripts stable and document the routing in `VPS-INSTALL.MD`.

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
- if the custom DB host still points to the local VPS MySQL (`127.0.0.1`, `localhost`, or `::1`), Multidev should still bootstrap the local user/grants before `db:init` so sample-derived apps do not fail with `Access denied`

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
11. if PM2 is not online after install/update, Multidev retries the restart once and fails loudly if the project still does not come up
12. if a domain is set, Multidev verifies `/etc/app-map.csv` and the generated nginx vhost point to the installed port
13. if the mapping is stale, Multidev resyncs once and fails loudly if the domain still points at the wrong port
14. after PM2 is online, Multidev runs an HTTP host-header smoke test against the installed domain and compares it against the local app response; if the domain serves different content, installation fails loudly
15. after a successful install, the install form should clear the default entrypoint and project access password so the next install starts from a clean state

If anything is wrong, fix it before handoff.

## 10. Common failure modes

Check these first when an install is not smooth:
- wrong GitHub repo slug
- missing SSH key access to the repo
- wrong root `package.json` scripts
- env values not quoted correctly
- `DB_USER` / `DB_PASSWORD` mismatch
- last build metadata not recorded after pull/install
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

## 10.1 Port-change checklist

When a project changes port, treat it as a full runtime change, not just an env edit:
- update the runtime port in the repo `.env` and `.env.example` if the app reads one
- update `server/.env`, `client/.env`, or `dashboard/.env` when those folders own runtime values
- restart or re-run the Node runtime so it actually loads the new port
- regenerate nginx and `/etc/app-map.csv` so the public domain points at the new port
- verify the new port locally on the VPS with `curl http://127.0.0.1:<port>/health` or `curl http://127.0.0.1:<port>/`
- only after the local probe works, verify the public domain

Common mistakes after a port change:
- updated `.env` but not nginx => 502
- updated nginx but did not restart Node => Node still listens on the old port => 502
- PM2/systemd did not load the env file => the app falls back to a built-in port like `3000` or `config/twillo-settings.json`
- two instances exist at once, one on the old port and one on the new port, and nginx is proxying the wrong one
- `VITE_*` / `NEXT_PUBLIC_*` values are build-time frontend URLs, not the Node listen port, so changing them does not fix a 502 by itself

Quick rule:
- `curl http://127.0.0.1:<new-port>/health` works and the site still 502s => fix nginx/proxy mapping
- `curl` to the new port fails => fix the Node startup or PM2/service env first

## 11. What the repo should document

Before handing the app over to Multidev, the repo itself should explain:
- where the production start command lives
- which env values are required
- which system packages or browser binaries are required, and what `PREINSTALL_REQUIREMENTS.md` contains
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
- if a project has multiple domains, verify every alias is present in the app map and that each alias points at the intended env file before reporting success
- install/update should run `build all` automatically after the dependency step, so root, `server/`, `client/`, and `dashboard/` builds are verified before handoff
- after install, update, or restart, rerun app-sync after PM2 is online so `/etc/app-map.csv` and nginx are regenerated from the current project metadata
- if the repo name is too long for a MySQL username, shorten the generated DB user to stay within MySQL's 32-character limit while keeping the repo name as the base; existing overlong DB usernames should be normalized on update too
- keep `.env` files as config only; do not place huge generated payloads inside them, because the manage dashboard scans env files and a giant file can break the project list

## 13. GitHub SSH mapping

Multidev can keep multiple GitHub SSH identities on the VPS.

Rules:
- each saved SSH key should record the GitHub user it belongs to
- `shaykid` should use the default `git@github.com` host alias
- `hinbit` should use `git@github-hinbit`
- `projectctl` should pull using the host alias that matches the repo owner
- the manage panel should write the SSH config for those aliases automatically

This is required so a future Codex session can install or update repos from different GitHub accounts without manual SSH config edits on the server.
