# One-Run Install Spec for Multidev Projects

This document is for future Codex agents and project authors.

Goal:
- build projects so they can be installed, wired, started, and verified in a single `projectctl install` run
- avoid manual post-install fixes
- make sure the project behaves correctly inside the Multidev VPS workflow

If a project needs a manual shell command after install to become usable, it is not compliant with this spec.

## Core Rule

The project must be installable from the Git repo alone.

That means:
- all required runtime env keys must exist in the repo templates
- database identity must be known from the env files
- the app must have a detectable start path
- the app must be able to bind to the installed port
- the app must not depend on hidden local-only state
- the app must not require interactive prompts during install

`projectctl install` should be able to:
- clone the repo
- seed `.env` files from templates
- normalize deployment env values
- install dependencies
- build assets
- provision the DB user/database
- start the runtime
- register the domain
- activate HTTPS if possible
- finish with a live service

## What the Repo Must Provide

At minimum, the repo should include:
- `package.json`
- a clear start script
- a build script if the project needs a build step
- `.env.example` or equivalent template files
- a DB init script if the app needs seeded schema/data

Recommended:
- `README.md`
- `CODEX.md`
- `PREINSTALL_REQUIREMENTS.md`
- `EMBEDDING_GUIDE.md` if the app has a special embedding or model setup

## Environment File Contract

The repo should ship env templates with all keys the app expects.

Important:
- include keys even if their values are empty in the template
- do not hide required keys behind only local machine state
- use `.env.example` as the source of truth when possible
- if the app has more than one runtime component, each component must have the keys it needs

Examples of keys that should usually exist in the template:
- `PORT`
- `HOST`
- `NODE_ENV`
- `APP_ENV`
- `ENVIRONMENT`
- `MODE`
- `SERVER_LOCATION`
- `APP_URL`
- `BASE_URL`
- `PUBLIC_URL`
- `DB_TYPE`
- `DB_NAME`
- `DB_DATABASE`
- `DB_USER`
- `DB_PASSWORD`
- `MYSQL_HOST`
- `MYSQL_PORT`
- `MYSQL_USER`
- `MYSQL_PASSWORD`
- `MYSQL_DATABASE`
- `DB_MACHINE_ID`
- `DB_MACHINE_HOST`
- `DB_MACHINE_PORT`
- `DB_MACHINE_ROOT_USER`
- `DB_MACHINE_ROOT_PASSWORD`

If the project uses extra service-specific keys, they should also be present in the template.

## Env Merge Rule

When pulling or installing a project, keep the current VPS values, but also merge in new keys from the repo templates.

The merge behavior should be:
- preserve existing VPS values where they already exist
- append new keys introduced by the repo
- normalize shell-sensitive values so they can be safely sourced

This is important because the repo may add new keys over time.

If a project already exists on the VPS and the repo adds:
- `GUI_PORT`
- `CONNECTOR_PORT`
- `SERVER_LOCATION`
- `APP_URL`

those keys should appear after the next update without losing the current live values.

## DB Contract

The app should expose enough DB info in `.env` for Multidev to manage it.

Required:
- database name
- database user
- database password
- DB host
- DB port
- DB machine identity if the project uses a dedicated machine

The installer should be able to:
- read the DB settings from the repo env templates
- create the DB user on the selected DB machine
- create the database if needed
- grant the user the correct privileges
- run `db:init` and `db:seed` if those scripts exist

The project should not assume a human will create the DB user later.

## Custom DB Machine Rule

If the project uses a custom or external DB host:
- the project must be able to save those details per project
- the project must not require root credentials for a simple connection save
- the project must only require root credentials when data migration is requested
- the app runtime must read the saved custom DB values, not fallback to the old machine

The UI should support:
- saving the custom connection only
- moving data separately
- changing DB name, DB user, and DB password independently

## Start Contract

The repo must have a detectable runtime entrypoint.

Preferred shapes:
- `npm start`
- `npm run serve`
- `npm run prod`
- `server/index.js`
- `ecosystem.config.js`

If the project uses an ecosystem file:
- the ecosystem file must define the real PM2 app name
- the ecosystem file must launch the real production entrypoint
- the ecosystem file name and app name should be stable

Do not rely on a hidden manual PM2 command after install.

## Port Contract

The app must accept the port chosen by the installer.

Rules:
- if the project is single-runtime, `PORT` should be the runtime port
- if the project is split-runtime, only the public-facing runtime should receive the public port
- internal UI/API/connector ports must stay on their own values
- reserved ports should not be clobbered during install
- common ports should be avoided when auto-picking a port

For split-runtime apps, use clear env names like:
- `GUI_PORT`
- `GUI_HOST`
- `GUI_API_BASE_URL`
- `CONNECTOR_PORT`
- `CONNECTOR_TARGET_URL`

The installer must not overwrite internal ports with the public UI port.

## Production / Server Location Contract

When installed on the VPS, the project must resolve itself to production/server values, not local-dev values.

The installer should normalize:
- `SERVER_LOCATION`
- `APP_LOCATION`
- `DEPLOY_TARGET`
- `NODE_ENV`
- `APP_ENV`
- `ENVIRONMENT`
- `MODE`
- `DEPLOYMENT`

If a template gives both local and production variants, the VPS install should prefer the deployed/web value.

Examples:
- `local` -> `web`
- `development` -> `production`
- `test` -> `production`
- localhost URLs -> installed domain URLs

## Build Contract

The project should build in a non-interactive way.

Recommended patterns:
- root `build` script should do the full production build
- root `start` or `prod` script should be the runtime entry
- client builds should be reachable automatically if the repo has a `client/` workspace
- server dependencies should be installable automatically if the repo has a `server/` workspace

If the project has:
- root app
- `server/`
- `client/`

then the repo should be usable without manual per-folder setup.

## DB Bootstrap Scripts

If the project needs schema/data setup, include scripts like:
- `db:init`
- `db:seed`
- `db:migrate`

These should:
- work non-interactively
- read env from the repo files
- not require hardcoded machine-local assumptions
- not depend on the developer laptop

The installer should run them automatically when present.

## PM2 / Process Contract

The project should start cleanly under PM2.

Requirements:
- a stable PM2 process name
- one process per runtime responsibility unless the app is intentionally split
- no manual `pm2 start ...` after install
- `pm2 save` should preserve the runtime

If the app uses an ecosystem config:
- the ecosystem should name the app
- the ecosystem should point at the correct script
- the ecosystem should use production settings by default

## Domain and Routing Contract

The project must include a domain mapping that can be synced to nginx.

Rules:
- the domain must be stored in project metadata
- the domain must map to the correct app port
- if HTTPS is requested, the vhost should be generated automatically
- if a certificate exists, nginx should use it

The project should not depend on a human editing nginx by hand after install.

## Auth and Access Contract

If the project should be protected:
- the access password should be configurable
- the password should be saved in the project metadata
- the site should still be reachable after install

If the app is public:
- do not block the runtime behind accidental auth

## What “One Run” Means

After `projectctl install`, the project should already be:
- cloned
- configured
- dependency-installed
- built
- database-provisioned
- started
- mapped to the right domain
- listening on the expected port
- visible in the manage dashboard

If any of these require a second human action, the project design is incomplete.

## Post-Install Verification Checklist

After install, the automation should verify:
- the project appears in the project list
- the expected domain is in the app map
- nginx has the right vhost
- the correct PM2 process is online
- the port is listening locally
- the app returns content on the expected host header
- the DB user exists on the selected DB machine
- the DB init scripts completed
- the manage dashboard shows the right status

If any check fails, the automation should try to fix it automatically.

## Failure Policy

If the installer detects a missing piece, it should prefer fixing it automatically over stopping.

Examples:
- missing app-map entry -> regenerate it
- missing DB root host entry -> bootstrap it
- missing PM2 process -> restart it
- missing env keys -> merge them from templates
- wrong server/dev env values -> normalize them

Only stop and report back if:
- the repo is fundamentally missing required files
- the app cannot be started safely
- the DB credentials are not resolvable
- the project structure is too ambiguous to infer safely

## Good Project Shape

Recommended project shape:

```text
repo/
  package.json
  .env.example
  .env.production.example
  README.md
  CODEX.md
  server/
    package.json
    index.js
  client/
    package.json
    src/
  ecosystem.config.js
  scripts/
    init-db.mjs
    seed-db.mjs
```

Not every project needs every folder, but the important point is that the install path can discover everything automatically.

## Bad Project Shape

Avoid:
- required manual `.env` editing after install
- hidden local-only config that is not in the repo
- database users that must be created by hand
- start scripts that only work on the developer laptop
- start scripts that ignore the installer-provided port
- ecosystem configs that do not match the actual runtime name
- split-runtime apps that reuse the same port for everything
- routes that only work after a second manual nginx edit

## Final Rule for Future Codex Agents

Before merging a project into Multidev, make sure the repo can satisfy:

1. install in one run
2. DB provisioning in one run
3. production normalization in one run
4. domain mapping in one run
5. startup verification in one run

If the answer to any of those is “not yet,” the project structure should be changed before handoff.
