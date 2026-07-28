# VPS Wake Times and Control Network

The `VPS Wake Times` portal section is the first phase of the VPS control
network. It keeps a root-only registry in `/etc/vps-wake-machines.json` and
does not reuse database machine credentials.

## What the portal stores

Each VPS can have:

- a display host and SSH host/port/user, used only for a TCP reachability check;
- a provider type: `oracle`, `gns`, `agent`, or `manual`;
- a VPS agent URL and token;
- an optional provider action endpoint, bearer token, and provider resource ID;
- a per-VPS JSON living policy; and
- the last reported awake/offline and communication state.

Secrets are never returned by the portal API and the registry file is written
with mode `0600`.

## Agent protocol

Install a small HTTPS token agent on every VPS that needs operational control.
The portal calls these endpoints:

```text
GET  /health
Authorization: Bearer <agent-token>

POST /v1/control
Authorization: Bearer <agent-token>
Content-Type: application/json
```

Health response example:

```json
{
  "state": "awake",
  "communication": "enabled",
  "version": "1.0.0"
}
```

Control request example:

```json
{
  "action": "communication-off",
  "machineId": "vps-...",
  "resourceId": "optional-provider-resource-id",
  "policy": {
    "timezone": "Asia/Jerusalem",
    "rules": [
      { "when": "shabbat", "communication": "off" },
      { "when": "night", "power": "off" }
    ],
    "processes": { "speaker": "disabled" }
  },
  "requestedAt": "2026-07-28T00:00:00.000Z"
}
```

The supported action names are `communication-off`, `communication-on`,
`shutdown`, and `wake`. The agent must enforce its own allowlist. In the next
phase it should also accept a process selector or PM2/systemd process list,
then report per-process state.

Control response example:

```json
{
  "status": "accepted",
  "state": "awake",
  "communication": "disabled"
}
```

## bo.reg installation

The portal's `Install bo.reg` button fetches `hinbit/bo.reg` with the
controller's configured GitHub key, builds a package tarball, uploads it over
the saved password SSH connection, creates
`/opt/bo.reg/.env` with a generated 256-bit token, and enables
`bo-reg.service`. The VPS card then displays the installed package version and
offers `Update bo.reg`.

The agent's default port is `9088`. Bind it to `0.0.0.0` only when its firewall
allows that port from the MultiDev controller alone. For a controller running
on the same VPS, use `127.0.0.1` as the agent URL and bind host.

The policy editor has valid editable presets for Shabbat communication off,
Shabbat shutdown, nightly 20:00-06:00 power off, a weekly two-hour maintenance
wake period, and a combined policy. Shabbat shutdown includes the explicit
`BO_REG_ALLOW_SHUTDOWN=true` requirement. A preset only fills the JSON field;
it does not send a command until a later policy scheduler/agent phase is
enabled.

## Oracle and GNS adapters

Do not put provider-specific calls directly in the portal UI. Configure a
small adapter endpoint that validates the portal bearer token, translates the
generic control request into the current Oracle Cloud or GNS Console API call,
and returns the response shape above. This keeps provider API changes isolated
and allows the same policy to work for local, Oracle, and GNS VPS machines.

The portal intentionally does not run shutdown commands through SSH. SSH
credentials are only a reachability probe. A power or communication action
needs an authenticated agent or configured provider endpoint.
