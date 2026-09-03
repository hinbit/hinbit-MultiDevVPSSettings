# MultiDev security hardening

This runbook separates controls that MultiDev can apply safely from changes that require operator access or a maintenance window.

## Applied by MultiDev

Run `sudo multidev-security-harden --audit` at any time. New installs and `--apply-safe` use these defaults:

- UFW deny-by-default inbound, allowing TCP 22, 80, and 443 only.
- The manage service listens on `127.0.0.1:8090` and is reached through nginx.
- fail2ban protects SSH with four attempts per ten minutes and a 24-hour ban.
- unattended security upgrades are enabled.
- nginx defines a reusable login rate-limit zone; the standard server configuration hides its version.
- project `.env*` and infrastructure credential files are restricted to mode `0600`.
- the built-in shared proxy password is removed; proxy access requires an explicitly configured password.

`--apply-safe` does not disable SSH passwords/root, restrict SSH to one source IP, stop services, patch/reboot, rotate secrets, or migrate root PM2 applications.

## Operator checklist

- [ ] Take snapshots of both VPSes and verify provider-console recovery.
- [ ] Create a named sudo user with a unique SSH key and test it in a second terminal.
- [ ] Put both Multidev hostnames behind Cloudflare Access with named users and MFA.
- [ ] Proxy every public application DNS record through Cloudflare.
- [ ] Enable Cloudflare managed WAF rules and rate limits for login, API, and upload routes.
- [ ] Enable zone-specific Authenticated Origin Pulls.
- [ ] After Cloudflare validation, allow TCP 80/443 at the origin only from current Cloudflare IP ranges.
- [ ] Choose fixed-IP, VPN, or Cloudflare Zero Trust SSH access, then restrict TCP 22 accordingly.
- [ ] Rotate VPS root passwords, OpenAI/API keys, GitHub keys, DB root credentials, portal passwords, and proxy credentials that have been shared or reused.
- [ ] During a maintenance window set `PermitRootLogin no`, `PasswordAuthentication no`, `MaxAuthTries 4`, `X11Forwarding no`, and `AllowTcpForwarding no`; preserve explicit SFTP `Match User` blocks.
- [ ] Remove SSH ports 26 and 22022 if no confirmed dependency uses them.
- [ ] Confirm whether CUPS 631, RPC 111, ports 10000/10050, and remote MySQL 3306 are needed; disable or narrowly allowlist them.
- [ ] Apply package updates, reboot when required, and verify nginx, PM2, MySQL, Certbot, and all domains.
- [ ] Repair the failed Certbot service on `seach-web` and test `certbot renew --dry-run`.
- [ ] Configure encrypted off-server backups with immutable retention and perform a restore test.
- [ ] Configure alerts for root login, new users, firewall changes, disk pressure, failed units, TLS expiry, and repeated deployment failures.
- [ ] Schedule migration of each root PM2 project to a dedicated unprivileged user or rootless container.

## Verification

```bash
sudo multidev-security-harden --audit
sudo ufw status verbose
sudo sshd -T | egrep 'permitrootlogin|passwordauthentication|maxauthtries|x11forwarding|allowtcpforwarding'
sudo ss -lntup
sudo fail2ban-client status sshd
sudo nginx -t
sudo certbot renew --dry-run
```

Do not close the current SSH session while changing SSH or firewall rules. Validate a new login first and retain provider-console access until verification is complete.
