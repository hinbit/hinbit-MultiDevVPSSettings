# VPS Structure

This project rebuilds the VPS plumbing, not the app code.

## Installed system layout

- `/etc/app-map.csv`
  - Domain to port mapping for nginx
  - Format: `domain,port,type,https`
- `/etc/app-watch.csv`
  - PM2 app restart watch list
  - Format: `name,path,check_minutes`
- `/usr/local/bin/app-sync.sh`
  - Generates nginx vhosts from `app-map.csv`
  - Issues TLS certs when `https=yes`
  - Removes generated vhosts that were removed from the CSV
- `/usr/local/bin/pm2-smart-restart.sh`
  - Checks watched app trees and restarts PM2 apps when files change
- `/usr/local/bin/projectctl`
  - Clones GitHub repos into `/var/www/<owner-repo>`
  - Auto-assigns a port when none is provided
  - Accepts `--branch` and `--pm2-name`
  - Can add a new domain to `/etc/app-map.csv` and run `app-sync.sh`
  - Pulls updates and restarts PM2 for existing projects
  - Can uninstall a project cleanly
- `/etc/systemd/system/pm2-root.service`
  - Restores PM2 processes at boot
- `/etc/cron.d/vps-bootstrap`
  - Runs `app-sync.sh` at boot
  - Runs the PM2 watcher every minute
- `/etc/fail2ban/jail.d/sshd.local`
  - Basic SSH brute-force protection
- `/etc/ssh/sshd_config.d/99-vps-bootstrap.conf`
  - Optional SSH hardening when `ADMIN_USER` is set
- `/etc/vps-proxy-service.json`
  - Proxy service settings for `/manage/proxy/`
  - Rendered into `/etc/tinyproxy/tinyproxy.conf`
- `/etc/tinyproxy/tinyproxy.conf`
  - Tinyproxy config generated from the proxy service settings

## Security defaults

- UFW allows only SSH, HTTP, and HTTPS
- fail2ban is enabled for SSH
- unattended upgrades is enabled
- phpMyAdmin is installed but only bound locally on `127.0.0.1:8081`
- Tinyproxy is installed but stays local-only by default unless you change the proxy listen host

## App workflow

1. Put the app code under `/var/www/<app-name>`
2. Install or update the repo with `projectctl`
3. Add or sync the domain in `/etc/app-map.csv` if needed
4. Run `sudo app-sync.sh` when the map changes
5. Start, restart, or uninstall the app in PM2

## Notes

- This bootstrap does not copy or deploy app repositories.
- It assumes DNS is already pointed at the VPS before TLS issuance.
- If you want SSH hardening, provide `ADMIN_USER` and `ADMIN_SSH_PUBKEY` before running the installer.
- If you want the proxy service exposed beyond localhost, review the proxy allowlist and firewall rules first.
