# VPS Wake Times and 🔩 Control Network

The `VPS Wake Times` portal section is the first phase of the VPS control
network. It keeps a root-only registry in `/etc/vps-wake-machines.json` and
does not reuse database machine credentials.

## What the portal stores

Each VPS can have:

- a display host and SSH host/port/user, used only for a TCP reachability check;
- an optional managed SSH private-key path on the MultiDev VPS, preferred for
  🔩 package upload and installation over a saved password;
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

`Wake` is sent only to the configured provider adapter and is enabled only
when that adapter reports `state: "off"`. `Shutdown` is sent first to the
healthy installed 🔩 agent, then MultiDev asks the provider adapter for status
and records its confirmation. It is enabled only when the VPS is `awake`, 🔩 is
healthy, and the provider adapter is reachable.

Control response example:

```json
{
  "status": "accepted",
  "state": "awake",
  "communication": "disabled"
}
```

## 🔩 bo.reg installation

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

Provider-specific calls stay in the MultiDev provider adapter. The portal stores
the credentials in the root-only VPS registry and does not expose private keys
in the list response.

### Native Oracle OCI connection

For an Oracle machine select provider `oracle` and enter:

- `providerResourceId`: the Compute instance OCID;
- `providerUserOcid`: the OCI user OCID;
- `providerTenancyOcid`: the tenancy OCID;
- `providerFingerprint`: the API-key fingerprint;
- `providerRegion`: for example `il-jerusalem-1`;
- `providerPrivateKey`: the PEM private key matching the fingerprint.

The controller signs OCI Compute requests directly. It reads lifecycle state
from `GET /20160918/instances/{instanceOcid}` and uses the Compute start/stop
actions for Wake and provider verification. For the IAM user/group, create a
policy in the compartment containing the instance with:

```text
Allow group <group-name> to manage instance-family in compartment <compartment-name>
```

If the user is in `Administrators`, replace `<group-name>` with
`Administrators`. The statement must cover the instance compartment, not only
the tenancy root. See the [OCI request signing reference](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/signingrequests.htm).

The adapter must accept `POST` JSON requests with `action: "status"` and
return a state such as `awake`, `off`, `starting`, or `shutting-down`. It also
accepts `action: "wake"` to start a stopped VPS. MultiDev never uses the
provider adapter to request shutdown; it uses 🔩 for that command and the
provider only for verification.

### Native GNS connection

For provider `gns`, MultiDev connects directly to the configured API server,
for example `https://console.gns.co.il/service`. It stores the GNS Access Key,
GNS Secret Key, and GNS Server ID only in the root-only VPS registry. MultiDev
authenticates with `POST /authenticate` using `{ "clientId", "secret" }`,
checks power using `GET /server/{serverId}`, and wakes a stopped VPS with
`PUT /server/{serverId}/power` and `{ "power": "on" }`. The short-lived GNS
bearer token is never stored.

The portal intentionally does not run shutdown commands through SSH. SSH
credentials are only a reachability probe. A power or communication action
needs an authenticated agent or configured provider endpoint.
