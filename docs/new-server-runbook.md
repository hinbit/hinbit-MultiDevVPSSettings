# New Server Runbook

This is the install path for a clean Ubuntu VPS that will host multiple projects, plus an optional separate DB machine.

Assumptions:
- You have `root` access to the app VPS.
- You have `root` access to the DB machine if it is separate.
- DNS for app domains already points to the app VPS before TLS issuance.
- You have GitHub SSH access ready on the app VPS.

If you use Cloudflare Tunnel for the manage UI, run the tunnel on the app VPS that serves `/manage/` and map the hostname to the local manage port.
That setup avoids exposing the manage host publicly on `80/443`.

## 1. Prepare the app VPS

SSH into the app server as `root` and clone this repo:

```bash
git clone git@github.com:shaykid/MultiDevVPSSettings.git /root/MultiDevVPSSettings
cd /root/MultiDevVPSSettings
```

Run the bootstrap installer:

```bash
bash bootstrap/install.sh
```

Recommended environment variables for the installer:

- `ACME_EMAIL` for Let's Encrypt notifications
- `MANAGE_PASSWORD` for `https://multidev.hinbit.com/manage/`
- `ADMIN_USER` and `ADMIN_SSH_PUBKEY` if you want a non-root sudo user

The installer will set up:
- nginx
- Node.js
- PM2
- MySQL on the app server if needed
- certbot
- phpMyAdmin
- UFW and fail2ban
- the `/manage/` system portal
- `projectctl`

## Optional Cloudflare Tunnel for manage

Use this when you want `multidev.seach.co.il` to reach the manage UI without opening inbound HTTP/HTTPS on the server.

On the app VPS:

1. Install and start `cloudflared` with your tunnel token.
2. Point the hostname at the local manage service:

```text
multidev.seach.co.il -> http://127.0.0.1:8090
```

3. Make sure the tunnel config includes an ingress rule for the manage hostname and a fallback 404:

```yaml
ingress:
  - hostname: multidev.seach.co.il
    service: http://127.0.0.1:8090
  - service: http_status:404
```

4. Keep the manage UI bound to `127.0.0.1:8090` or `0.0.0.0:8090` on the app VPS.
5. Do not point the tunnel at the DB host unless the DB host is the machine actually serving `/manage/`.

In the current UI layout, `/` is the portal landing page and `/manage/` is the project dashboard.

## 2. Prepare the DB machine

If the DB is on a separate machine, install and expose MySQL there first.

On the DB machine as `root`:

```bash
apt update
apt install -y mysql-server
```

Set or confirm the MySQL bind address:

- For a remote DB machine, bind to the machine IP or `0.0.0.0`
- For a local-only DB, you can keep localhost/socket access

Make sure the DB machine allows the app server IP:

- MySQL access should be allowed from the app VPS IP
- If you also use OS firewall rules, open TCP `3306` from the app VPS IP only

Record these values for the DB machine entry:

- machine name
- host or IP
- MySQL root user
- MySQL root password
- port, usually `3306`
- approved client IPs

## 3. Register the DB machine

On the app VPS, open:

```text
https://multidev.hinbit.com/manage/db-machines/
```

Add the DB machine there, including:

- `localhost (current)` for the local VPS DB
- the remote DB machine if present

You can later edit the machine details, including the root credentials and approved IPs.

## 4. Install a new project

Use `projectctl install` from the app VPS:

```bash
projectctl install --domain example.com --branch main --pm2-name example-app --db-machine local-current owner/repo
```

For a separate DB machine:

```bash
projectctl install --domain example.com --branch main --pm2-name example-app --db-machine remote-db-1 owner/repo
```

If the repo needs a repo-specific env file:

```bash
projectctl install --domain example.com --branch main --pm2-name example-app --db-machine remote-db-1 --env-file /root/app.env --entrypoint server/index.js owner/repo
```

What the installer does:
- clones the GitHub repo into `/var/www/<owner-repo>`
- assigns a PM2 name and port
- maps the domain in `/etc/app-map.csv`
- runs `app-sync.sh` to build nginx and TLS
- creates a per-project SSH upload user
- creates or wires the project DB on the selected DB machine
- exports the correct domain-related env values for the runtime

## 5. Verify the project

After install, confirm:

- `https://example.com/` responds correctly
- the project is online in `/manage/`
- the MySQL panel shows the selected DB machine
- the DB exists on that machine and the project user has access
- the project starts cleanly under PM2

## 6. Change a project to another DB machine

From the manage dashboard:

1. Open `/manage/`
2. Click `MySQL` on the project row
3. Select the new DB machine
4. Save and move

This will:
- test the connection to the target DB machine
- create the project database there if needed
- create/update the project DB user and grants
- switch the project to the new DB machine
- restart the project

If the DB machine cannot be reached or the root credentials are wrong, the UI returns an error and the move does not complete.

## 7. Update existing projects

Use:

```bash
projectctl update owner/repo
projectctl restart owner/repo
```

`projectctl update` will:
- pull the repo
- preserve local env files
- rebuild when the repo has a build script
- restart PM2 and sidecar services

## 8. Env backup and restore

The manage dashboard supports:
- backup env files to `/etc/vps-project-env-backups/<project>/`
- restore latest backup
- restore a selected backup
- delete saved backups

Restores now create an automatic backup first.

## 9. What to avoid

- Do not commit `.env.machine` to GitHub
- Do not assume the DB machine is always local
- Do not skip the DB machine registration step if the project uses a remote DB
- Do not rely on browser localhost values in production env files

## 10. If something fails

Check these first:

- `/manage/` project list
- `/manage/db-machines/`
- `projectctl status owner/repo`
- `projectctl mysql owner/repo`
- PM2 logs for the project
- nginx config and TLS status for the domain
