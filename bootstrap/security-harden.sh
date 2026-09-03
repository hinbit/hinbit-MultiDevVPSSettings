#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---audit}"
[[ "${EUID}" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

audit() {
  echo "== firewall =="
  command -v ufw >/dev/null && ufw status verbose || echo "WARN: UFW is not installed"
  echo "== public listeners =="
  ss -lntup | awk '$5 ~ /^(0\.0\.0\.0|\[::\]|\*):/ {print}'
  echo "== effective SSH policy =="
  sshd -T 2>/dev/null | awk '$1 ~ /^(permitrootlogin|passwordauthentication|maxauthtries|x11forwarding|allowtcpforwarding)$/ {print}' || true
  echo "== failed services =="
  systemctl --failed --no-pager || true
  echo "== sensitive file permissions =="
  find /var/www -maxdepth 3 -type f -name '.env*' -printf '%m %u:%g %p\n' 2>/dev/null | sort
  echo "== pending package updates =="
  apt-get -s upgrade 2>/dev/null | awk '/^[0-9]+ upgraded/ {print}'
}

apply_safe() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ufw fail2ban unattended-upgrades

  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment 'SSH'
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
  ufw --force enable

  install -d -m 0755 /etc/nginx/conf.d /etc/fail2ban/jail.d
  cat > /etc/nginx/conf.d/00-multidev-security.conf <<'EOF'
limit_req_zone $binary_remote_addr zone=multidev_login:10m rate=10r/m;
EOF
  cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
backend = systemd
mode = aggressive
bantime = 24h
findtime = 10m
maxretry = 4
ignoreip = 127.0.0.1/8 ::1
EOF
  systemctl enable --now fail2ban unattended-upgrades

  find /var/www -maxdepth 3 -type f -name '.env*' -exec chmod 0600 {} + 2>/dev/null || true
  chmod 0600 /etc/vps-system.env /etc/vps-db-machines.json /etc/vps-ssh-keys.json /etc/vps-proxy-service.json 2>/dev/null || true

  if [[ -f /etc/systemd/system/vps-manage.service ]]; then
    sed -i 's/^Environment=MANAGE_BIND_HOST=.*/Environment=MANAGE_BIND_HOST=127.0.0.1/' /etc/systemd/system/vps-manage.service
    systemctl daemon-reload
    systemctl restart vps-manage
  fi
  nginx -t
  systemctl reload nginx
}

case "${MODE}" in
  --audit) audit ;;
  --apply-safe) apply_safe; audit ;;
  *) echo "Usage: $0 [--audit|--apply-safe]" >&2; exit 2 ;;
esac
