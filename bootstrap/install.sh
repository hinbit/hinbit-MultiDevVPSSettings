#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="/var/lib/vps-bootstrap"
APP_MAP="/etc/app-map.csv"
APP_WATCH="/etc/app-watch.csv"
BIN_DIR="/usr/local/bin"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
PM2_SERVICE="/etc/systemd/system/pm2-root.service"
CRON_FILE="/etc/cron.d/vps-bootstrap"
PHPMA_FILE="/etc/nginx/sites-available/phpmyadmin.local"
MYSQL_CONF_FILE="/etc/mysql/mysql.conf.d/zz-vps-bootstrap.cnf"
SYSTEM_PORTAL_FILE="/etc/nginx/sites-available/system-portal.conf"
SYSTEM_PORTAL_WEBROOT="/var/www/system-portal"
SYSTEM_DOMAIN_FILE="/etc/vps-system-domain"
SYSTEM_ENV_FILE="/etc/vps-system.env"
DB_MACHINES_FILE="/etc/vps-db-machines.json"
SSH_KEYS_FILE="/etc/vps-ssh-keys.json"
SSH_KEYS_DIR="/root/.ssh/vps-managed-keys"
MANAGE_SERVICE="/etc/systemd/system/vps-manage.service"
SSH_HARDEN_FILE="/etc/ssh/sshd_config.d/99-vps-bootstrap.conf"
PHP_FPM_VERSION=""
PHP_FPM_SERVICE=""
PHP_FPM_SOCKET=""
NODE_BIN=""

log() {
  printf '[vps-bootstrap] %s\n' "$*"
}

generate_secret() {
  local secret=""
  secret="$(openssl rand -base64 18 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 18 || true)"
  if [[ -z "${secret}" ]]; then
    secret="$(openssl rand -hex 12 2>/dev/null || true)"
  fi
  [[ -n "${secret}" ]] || return 1
  printf '%s' "${secret}"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this as root." >&2
    exit 1
  fi
}

write_file() {
  local path="$1"
  shift
  install -D -m "${1:-0644}" /dev/stdin "$path"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update

  debconf-set-selections <<'EOF'
phpmyadmin phpmyadmin/dbconfig-install boolean false
phpmyadmin phpmyadmin/reconfigure-webserver multiselect
EOF

  apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    unzip \
    acl \
    git \
    build-essential \
    ufw \
    fail2ban \
    unattended-upgrades \
    nginx \
    certbot \
    python3-certbot-nginx \
    mysql-server \
    php-fpm \
    php-cli \
    php-mysql \
    php-xml \
    php-mbstring \
    php-curl \
    php-zip \
    phpmyadmin

  if ! command -v node >/dev/null 2>&1 || ! node -v | grep -Eq '^v20\.'; then
    log "Installing Node.js 20 from NodeSource"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  fi
  NODE_BIN="$(command -v node)"

  if ! command -v pm2 >/dev/null 2>&1; then
    log "Installing PM2"
    npm install -g pm2
  fi

  corepack enable >/dev/null 2>&1 || true

  PHP_FPM_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  PHP_FPM_SERVICE="php${PHP_FPM_VERSION}-fpm"
  PHP_FPM_SOCKET="/run/php/php${PHP_FPM_VERSION}-fpm.sock"
}

configure_timezone() {
  log "Setting timezone to Asia/Jerusalem"
  timedatectl set-timezone Asia/Jerusalem || true
}

configure_firewall() {
  log "Configuring UFW"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
}

configure_fail2ban() {
  log "Configuring fail2ban"
  install -d /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
backend = systemd
mode = aggressive
bantime = 1h
findtime = 10m
maxretry = 5
EOF
  systemctl enable --now fail2ban
}

configure_unattended_upgrades() {
  log "Enabling unattended upgrades"
  systemctl enable --now unattended-upgrades
}

configure_ssh_hardening() {
  if [[ -z "${ADMIN_USER:-}" ]]; then
    log "ADMIN_USER not set; leaving SSH auth unchanged"
    return
  fi

  if [[ -z "${ADMIN_SSH_PUBKEY:-}" ]]; then
    log "ADMIN_USER is set but ADMIN_SSH_PUBKEY is missing; leaving SSH auth unchanged"
    return
  fi

  log "Creating admin user ${ADMIN_USER}"
  if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "${ADMIN_USER}"
    usermod -aG sudo "${ADMIN_USER}"
  fi

  install -d -m 0700 "/home/${ADMIN_USER}/.ssh"
  chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"

  if [[ -n "${ADMIN_SSH_PUBKEY:-}" ]]; then
    printf '%s\n' "${ADMIN_SSH_PUBKEY}" > "/home/${ADMIN_USER}/.ssh/authorized_keys"
    chmod 0600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
    chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh/authorized_keys"
  fi

  install -d /etc/ssh/sshd_config.d
  cat > "${SSH_HARDEN_FILE}" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
EOF

  systemctl reload ssh || systemctl reload sshd || true
}

configure_mysql_server() {
  log "Configuring MySQL for remote access behind UFW"
  install -d /etc/mysql/mysql.conf.d
  cat > "${MYSQL_CONF_FILE}" <<'EOF'
[mysqld]
bind-address = 0.0.0.0
mysqlx-bind-address = 127.0.0.1
skip-name-resolve = ON
EOF
}

configure_local_db_machine_credentials() {
  if [[ ! -f "${DB_MACHINES_FILE}" ]]; then
    return 0
  fi

  local current_root_password
  current_root_password="$(
    python3 - "${DB_MACHINES_FILE}" <<'PY'
import json
import os
import sys

path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as handle:
        data = json.load(handle)
except Exception:
    data = []
for item in data if isinstance(data, list) else []:
    if str(item.get('id', '')) == 'local-current':
        print(str(item.get('rootPassword', '')).strip())
        break
PY
  )"

  if [[ -n "${current_root_password}" ]]; then
    return 0
  fi

  local local_password
  local_password="$(generate_secret)"

  mysql --protocol=socket -uroot -e "CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${local_password}';"
  mysql --protocol=socket -uroot -e "ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${local_password}';"
  mysql --protocol=socket -uroot -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;"
  mysql --protocol=socket -uroot -e "CREATE USER IF NOT EXISTS 'root'@'::1' IDENTIFIED BY '${local_password}';"
  mysql --protocol=socket -uroot -e "ALTER USER 'root'@'::1' IDENTIFIED BY '${local_password}';"
  mysql --protocol=socket -uroot -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1' WITH GRANT OPTION;"
  mysql --protocol=socket -uroot -e "FLUSH PRIVILEGES;"

  python3 - "${DB_MACHINES_FILE}" "${local_password}" <<'PY'
import json
import os
import sys

path = sys.argv[1]
password = sys.argv[2]
entry = {
    "id": "local-current",
    "name": "localhost (current)",
    "host": "127.0.0.1",
    "rootUser": "root",
    "rootPassword": password,
    "port": "3306",
    "notes": "Current VPS local DB on this VPS",
}

data = []
try:
    with open(path, 'r', encoding='utf-8') as handle:
        loaded = json.load(handle)
        if isinstance(loaded, list):
            data = loaded
except Exception:
    data = []

updated = False
for index, item in enumerate(data):
    if str(item.get('id', '')) == 'local-current':
        data[index] = entry
        updated = True
        break
if not updated:
    data.insert(0, entry)

with open(path, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, indent=2)
    handle.write('\n')
os.chmod(path, 0o600)
PY
}

install_system_files() {
  log "Installing app routing scripts and configs"
  install -d "${STATE_DIR}" /etc/vps-projects "${NGINX_AVAIL}" "${NGINX_ENABLED}" /var/www/html

  if [[ ! -f "${NGINX_AVAIL}/default" ]]; then
    cat > "${NGINX_AVAIL}/default" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 404;
    }
}
EOF
  fi

  if [[ ! -f "${APP_MAP}" ]]; then
    cat > "${APP_MAP}" <<'EOF'
domain,port,type,https
# example.com,3000,react,yes
EOF
  fi

  if [[ ! -f "${APP_WATCH}" ]]; then
    cat > "${APP_WATCH}" <<'EOF'
name,path,check_minutes
# my-app,/var/www/my-app,2
EOF
  fi

  if [[ ! -f "${DB_MACHINES_FILE}" ]]; then
    cat > "${DB_MACHINES_FILE}" <<'EOF'
[
  {
    "id": "local-current",
    "name": "localhost (current)",
    "host": "127.0.0.1",
    "rootUser": "root",
    "rootPassword": "",
    "port": "3306",
    "notes": "Current VPS local DB on this VPS"
  }
]
EOF
    chmod 0600 "${DB_MACHINES_FILE}"
  fi

  if [[ ! -f "${SSH_KEYS_FILE}" ]]; then
    cat > "${SSH_KEYS_FILE}" <<'EOF'
[]
EOF
    chmod 0600 "${SSH_KEYS_FILE}"
  fi
  install -d -m 0700 "${SSH_KEYS_DIR}"

  if [[ -n "${SYSTEM_DOMAIN:-}" && ! -f "${SYSTEM_DOMAIN_FILE}" ]]; then
    printf '%s\n' "${SYSTEM_DOMAIN}" > "${SYSTEM_DOMAIN_FILE}"
  fi

  cat > "${BIN_DIR}/app-sync.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CSV="${1:-/etc/app-map.csv}"
STATE_DIR="/var/lib/vps-bootstrap"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
MARKER="# generated by vps-bootstrap"
MANIFEST="${STATE_DIR}/app-sync.manifest"
ACME_ROOT="/var/www/html"

mkdir -p "${STATE_DIR}"

declare -A desired_domains=()
declare -a desired_list=()

render_http_only() {
  local domain="$1"
  local port="$2"
  cat <<EOF2
${MARKER}
server {
    listen 80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
    }

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_redirect off;
    }
}
EOF2
}

render_https() {
  local domain="$1"
  local port="$2"
  cat <<EOF2
${MARKER}
server {
    listen 80;
    server_name ${domain};
    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_redirect off;
    }
}
EOF2
}

cert_email_args=()
if [[ -n "${ACME_EMAIL:-}" ]]; then
  cert_email_args=(-m "${ACME_EMAIL}")
else
  cert_email_args=(--register-unsafely-without-email)
fi

while IFS=, read -r domain port type https; do
  [[ -z "${domain:-}" ]] && continue
  [[ "${domain}" == "domain" ]] && continue
  [[ "${domain:0:1}" == "#" ]] && continue

  domain="${domain//$'\r'/}"
  port="${port//$'\r'/}"
  type="${type//$'\r'/}"
  https="${https//$'\r'/}"

  if ! [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "[WARN] Skipping invalid domain: ${domain}" >&2
    continue
  fi

  if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
    echo "[WARN] Skipping ${domain} due to invalid port: ${port}" >&2
    continue
  fi

  desired_domains["${domain}"]=1
  desired_list+=("${domain}")

  conf="${NGINX_AVAIL}/${domain}.conf"
  tmp="$(mktemp)"

  if [[ "${https,,}" == "yes" ]]; then
    cert_ready="no"
    if [[ ! -s "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
      if certbot certonly \
        --webroot \
        -w "${ACME_ROOT}" \
        -d "${domain}" \
        --non-interactive \
        --agree-tos \
        "${cert_email_args[@]}" \
        --keep-until-expiring; then
        cert_ready="yes"
      else
        echo "[WARN] TLS issuance failed for ${domain}; keeping HTTP only for now" >&2
      fi
    else
      cert_ready="yes"
    fi

    if [[ "${cert_ready}" == "yes" ]]; then
      render_https "${domain}" "${port}" > "${tmp}"
    else
      render_http_only "${domain}" "${port}" > "${tmp}"
    fi
  else
    render_http_only "${domain}" "${port}" > "${tmp}"
  fi

  install -m 0644 "${tmp}" "${conf}"
  ln -sfn "${conf}" "${NGINX_ENABLED}/${domain}.conf"
  rm -f "${tmp}"
done < "${CSV}"

if [[ -f "${MANIFEST}" ]]; then
  while IFS= read -r old_domain; do
    [[ -z "${old_domain}" ]] && continue
    if [[ -z "${desired_domains[$old_domain]+x}" ]]; then
      conf="${NGINX_AVAIL}/${old_domain}.conf"
      if [[ -f "${conf}" ]] && grep -q "${MARKER}" "${conf}"; then
        rm -f "${conf}" "${NGINX_ENABLED}/${old_domain}.conf"
      fi
    fi
  done < "${MANIFEST}"
fi

{
  for domain in "${desired_list[@]}"; do
    printf '%s\n' "${domain}"
  done
} | sort -u > "${MANIFEST}"

nginx -t
systemctl reload nginx
EOF
  chmod 0755 "${BIN_DIR}/app-sync.sh"

  cat > "${BIN_DIR}/pm2-smart-restart.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CSV="/etc/app-watch.csv"
STATE_DIR="/var/lib/vps-bootstrap/pm2-restart"
mkdir -p "${STATE_DIR}"

now="$(date +%s)"

while IFS=, read -r name path minutes; do
  [[ -z "${name:-}" ]] && continue
  [[ "${name}" == "name" ]] && continue
  [[ "${name:0:1}" == "#" ]] && continue

  minutes="${minutes:-2}"
  if ! [[ "${minutes}" =~ ^[0-9]+$ ]]; then
    minutes=2
  fi

  check_file="${STATE_DIR}/${name}.last_check"
  change_file="${STATE_DIR}/${name}.last_change"

  if [[ -f "${check_file}" ]]; then
    last_check="$(cat "${check_file}")"
    if (( now - last_check < minutes * 60 )); then
      continue
    fi
  fi
  printf '%s\n' "${now}" > "${check_file}"

  if ! pm2 describe "${name}" >/dev/null 2>&1; then
    echo "[WARN] PM2 app not found: ${name}" >&2
    continue
  fi

  if [[ ! -d "${path}" ]]; then
    echo "[WARN] Watched path missing for ${name}: ${path}" >&2
    continue
  fi

  last_change="$(find "${path}" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 || true)"
  [[ -z "${last_change}" ]] && continue

  previous_change="0"
  if [[ -f "${change_file}" ]]; then
    previous_change="$(cat "${change_file}")"
  fi

  if awk "BEGIN { exit !(${last_change} > ${previous_change}) }"; then
    echo "Restarting ${name}"
    pm2 restart "${name}"
  fi

  printf '%s\n' "${last_change}" > "${change_file}"
done < "${CSV}"
EOF
  chmod 0755 "${BIN_DIR}/pm2-smart-restart.sh"
  install -m 0755 "${ROOT_DIR}/bootstrap/projectctl.sh" "${BIN_DIR}/projectctl"

  cat > "${BIN_DIR}/system-sync.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SYSTEM_DOMAIN_FILE="${SYSTEM_DOMAIN_FILE}"
SYSTEM_DOMAIN="\${SYSTEM_DOMAIN:-}"
SYSTEM_PORTAL_WEBROOT="${SYSTEM_PORTAL_WEBROOT}"
SYSTEM_PORTAL_FILE="${SYSTEM_PORTAL_FILE}"
PHP_FPM_SOCKET="${PHP_FPM_SOCKET}"
ACME_ROOT="/var/www/html"

if [[ -z "\${SYSTEM_DOMAIN}" && -f "\${SYSTEM_DOMAIN_FILE}" ]]; then
  SYSTEM_DOMAIN="\$(cat "\${SYSTEM_DOMAIN_FILE}")"
fi

if [[ -z "\${SYSTEM_DOMAIN}" ]]; then
  echo "[system-sync] SYSTEM_DOMAIN not set" >&2
  exit 1
fi

mkdir -p "\${SYSTEM_PORTAL_WEBROOT}"

app_links="\$(awk -F, 'NR > 1 && \$1 !~ /^#/ && \$1 != "" { printf(\"<li><a href=\\\"https://%s/\\\">%s</a></li>\\n\", \$1, \$1) }' /etc/app-map.csv)"

cat > "\${SYSTEM_PORTAL_WEBROOT}/index.html" <<EOF2
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MultiDev Control Panel</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 40px; padding-top: 60px; background: #0b1020; color: #e6edf3; }
    a { color: #7dd3fc; }
    .card { max-width: 900px; background: #111936; border: 1px solid #24304f; border-radius: 16px; padding: 24px; }
    h1 { margin-top: 0; }
    ul { line-height: 1.8; }
    .muted { color: #93a4bf; }
    .hinbit-brand {
      position: fixed;
      top: 16px;
      left: 16px;
      z-index: 80;
      display: inline-flex;
      align-items: center;
      gap: 10px;
      padding: 10px 14px;
      border-radius: 999px;
      background: rgba(17, 25, 54, 0.88);
      border: 1px solid #24304f;
      box-shadow: 0 12px 32px rgba(0,0,0,0.25);
      text-decoration: none;
      color: #e6edf3;
      backdrop-filter: blur(12px);
    }
    .hinbit-brand img {
      width: 22px;
      height: 22px;
      display: block;
      object-fit: contain;
    }
    .hinbit-brand span {
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.02em;
      white-space: nowrap;
    }
  </style>
</head>
<body>
  <a class="hinbit-brand" href="https://hinbit.com" target="_blank" rel="noreferrer">
    <img src="https://hinbit.com/hebrew_site/hinbit-logo-symbol.png" alt="Hinbit">
    <span>Powered by Hinbit Development</span>
  </a>
  <div class="card">
    <h1>MultiDev Control Panel</h1>
    <p class="muted">System services and deployed apps for \${SYSTEM_DOMAIN}</p>
    <h2>Admin</h2>
    <ul>
      <li><a href="/manage/">Manage projects</a></li>
      <li><a href="/manage/ssh-keys/">Manage SSH Keys</a></li>
    </ul>
    <h2>DB Management</h2>
    <ul>
      <li><a href="/phpmyadmin/">phpMyAdmin</a></li>
      <li><a href="/manage/vault/">DB Vault</a></li>
      <li><a href="/manage/db-machines/">DB machines</a></li>
    </ul>
    <h2>Apps</h2>
    <ul>
\${app_links}
    </ul>
  </div>
</body>
</html>
EOF2

render_http() {
  cat <<EOF2
server {
    listen 80;
    server_name \${SYSTEM_DOMAIN};

    location /.well-known/acme-challenge/ {
        root \${ACME_ROOT};
    }

    location = /phpmyadmin {
        return 301 /phpmyadmin/;
    }

    location /phpmyadmin/ {
        proxy_pass http://127.0.0.1:8081/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }

    location / {
        root \${SYSTEM_PORTAL_WEBROOT};
        index index.html;
        try_files \$uri /index.html;
    }
}
EOF2
}

render_https() {
  cat <<EOF2
server {
    listen 80;
    server_name \${SYSTEM_DOMAIN};

    location /.well-known/acme-challenge/ {
        root \${ACME_ROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name \${SYSTEM_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/\${SYSTEM_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/\${SYSTEM_DOMAIN}/privkey.pem;

    location = /phpmyadmin {
        return 301 /phpmyadmin/;
    }

    location /phpmyadmin/ {
        proxy_pass http://127.0.0.1:8081/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }

    location / {
        root \${SYSTEM_PORTAL_WEBROOT};
        index index.html;
        try_files \$uri /index.html;
    }
}
EOF2
}

if [[ -s "/etc/letsencrypt/live/\${SYSTEM_DOMAIN}/fullchain.pem" ]]; then
  render_https > "\${SYSTEM_PORTAL_FILE}"
else
  if certbot certonly --webroot -w "\${ACME_ROOT}" -d "\${SYSTEM_DOMAIN}" --non-interactive --agree-tos --register-unsafely-without-email; then
    render_https > "\${SYSTEM_PORTAL_FILE}"
  else
    render_http > "\${SYSTEM_PORTAL_FILE}"
  fi
fi

nginx -t
systemctl reload nginx
EOF
  chmod 0755 "${BIN_DIR}/system-sync.sh"

  install -m 0755 "${ROOT_DIR}/bootstrap/app-sync.sh" "${BIN_DIR}/app-sync.sh"
  install -m 0755 "${ROOT_DIR}/bootstrap/system-sync.sh" "${BIN_DIR}/system-sync.sh"
  install -m 0755 "${ROOT_DIR}/bootstrap/projectctl.sh" "${BIN_DIR}/projectctl"
  install -m 0755 "${ROOT_DIR}/bootstrap/manage-server.mjs" "${BIN_DIR}/manage-server.mjs"

  if [[ -n "${MANAGE_PASSWORD:-}" ]]; then
    cat > "${SYSTEM_ENV_FILE}" <<EOF
MANAGE_PASSWORD=${MANAGE_PASSWORD}
EOF
    chmod 0600 "${SYSTEM_ENV_FILE}"
  fi

  cat > "${MANAGE_SERVICE}" <<EOF
[Unit]
Description=MultiDev manage panel
After=network.target nginx.service pm2-root.service
Requires=pm2-root.service

[Service]
Type=simple
User=root
WorkingDirectory=/root
EnvironmentFile=-${SYSTEM_ENV_FILE}
Environment=MANAGE_PORT=8090
Environment=TZ=Asia/Jerusalem
ExecStart=${NODE_BIN} ${BIN_DIR}/manage-server.mjs
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat > "${PM2_SERVICE}" <<'EOF'
[Unit]
Description=PM2 process manager
Documentation=https://pm2.keymetrics.io/
After=network.target

[Service]
Type=forking
User=root
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin
Environment=PM2_HOME=/root/.pm2
Environment=TZ=Asia/Jerusalem
PIDFile=/root/.pm2/pm2.pid
Restart=on-failure

ExecStart=/usr/lib/node_modules/pm2/bin/pm2 resurrect
ExecReload=/usr/lib/node_modules/pm2/bin/pm2 reload all
ExecStop=/usr/lib/node_modules/pm2/bin/pm2 kill

[Install]
WantedBy=multi-user.target
EOF

  cat > "${CRON_FILE}" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

@reboot root /usr/local/bin/app-sync.sh
* * * * * root /usr/local/bin/pm2-smart-restart.sh
EOF

  cat > "${PHPMA_FILE}" <<EOF
server {
    listen 127.0.0.1:8081;
    server_name phpmyadmin.local;

    root /usr/share/phpmyadmin;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCKET};
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|ttf|woff|woff2)$ {
        expires max;
        log_not_found off;
    }
}
EOF

  ln -sfn "${PHPMA_FILE}" "${NGINX_ENABLED}/phpmyadmin.local"
  if [[ -n "${SYSTEM_DOMAIN:-}" ]]; then
    ln -sfn "${SYSTEM_PORTAL_FILE}" "${NGINX_ENABLED}/system-portal.conf"
  fi
  ln -sfn "${NGINX_AVAIL}/default" "${NGINX_ENABLED}/default"

  systemctl enable --now "${PHP_FPM_SERVICE}"
  systemctl enable --now nginx
  systemctl enable --now mysql
  systemctl enable --now unattended-upgrades

  systemctl daemon-reload
  systemctl enable --now pm2-root
  systemctl enable --now vps-manage

  if [[ -n "${SYSTEM_DOMAIN:-}" ]]; then
    /usr/local/bin/system-sync.sh
  fi
}

main() {
  require_root
  mkdir -p "${STATE_DIR}"
  install_packages
  configure_timezone
  configure_firewall
  configure_fail2ban
  configure_unattended_upgrades
  configure_ssh_hardening
  configure_mysql_server
  install_system_files

  systemctl restart "${PHP_FPM_SERVICE}"
  systemctl restart nginx
  systemctl restart mysql
  configure_local_db_machine_credentials

  log "Bootstrap complete"
  log "Add domains to /etc/app-map.csv and run /usr/local/bin/app-sync.sh"
  log "Add PM2 watch entries to /etc/app-watch.csv if you want auto-restart checks"
}

main "$@"
