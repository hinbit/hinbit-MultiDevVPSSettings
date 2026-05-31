#!/usr/bin/env bash
set -euo pipefail

SYSTEM_DOMAIN_FILE="/etc/vps-system-domain"
SYSTEM_DOMAIN="${SYSTEM_DOMAIN:-}"
SYSTEM_PORTAL_WEBROOT="/var/www/system-portal"
SYSTEM_PORTAL_FILE="/etc/nginx/sites-available/system-portal.conf"
ACME_ROOT="/var/www/html"
CUSTOM_CERT_ROOT="/etc/vps-custom-certs/server"

if [[ -z "${SYSTEM_DOMAIN}" && -f "${SYSTEM_DOMAIN_FILE}" ]]; then
  SYSTEM_DOMAIN="$(cat "${SYSTEM_DOMAIN_FILE}")"
fi

if [[ -z "${SYSTEM_DOMAIN}" ]]; then
  echo "[system-sync] SYSTEM_DOMAIN not set" >&2
  exit 1
fi

mkdir -p "${SYSTEM_PORTAL_WEBROOT}"

app_links="$(
  awk -F, 'NR > 1 && $1 !~ /^#/ && $1 != "" { printf("<li><a href=\"https://%s/\">%s</a></li>\n", $1, $1) }' /etc/app-map.csv
)"

cat > "${SYSTEM_PORTAL_WEBROOT}/index.html" <<EOF
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
    <p class="muted">System services and deployed apps for ${SYSTEM_DOMAIN}</p>
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
${app_links}
    </ul>
  </div>
</body>
</html>
EOF

render_http() {
  cat <<EOF
server {
    listen 80;
    server_name ${SYSTEM_DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
    }

    location = /phpmyadmin {
        return 301 /phpmyadmin/;
    }

    location = /manage {
        return 301 /manage/;
    }

    location /manage/ {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
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
        root ${SYSTEM_PORTAL_WEBROOT};
        index index.html;
        try_files \$uri /index.html;
    }
}
EOF
}

render_https() {
  local cert_path="$1"
  local key_path="$2"
  cat <<EOF
server {
    listen 80;
    server_name ${SYSTEM_DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${SYSTEM_DOMAIN};

    ssl_certificate ${cert_path};
    ssl_certificate_key ${key_path};

    location = /phpmyadmin {
        return 301 /phpmyadmin/;
    }

    location = /manage {
        return 301 /manage/;
    }

    location /manage/ {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
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
        root ${SYSTEM_PORTAL_WEBROOT};
        index index.html;
        try_files \$uri /index.html;
    }
}
EOF
}

custom_cert_dir="${CUSTOM_CERT_ROOT}/${SYSTEM_DOMAIN}"
custom_cert="${custom_cert_dir}/fullchain.pem"
custom_key="${custom_cert_dir}/privkey.pem"

if [[ -s "${custom_cert}" && -s "${custom_key}" ]]; then
  render_https "${custom_cert}" "${custom_key}" > "${SYSTEM_PORTAL_FILE}"
elif [[ -s "/etc/letsencrypt/live/${SYSTEM_DOMAIN}/fullchain.pem" ]]; then
  render_https "/etc/letsencrypt/live/${SYSTEM_DOMAIN}/fullchain.pem" "/etc/letsencrypt/live/${SYSTEM_DOMAIN}/privkey.pem" > "${SYSTEM_PORTAL_FILE}"
else
  if certbot certonly --webroot -w "${ACME_ROOT}" -d "${SYSTEM_DOMAIN}" --non-interactive --agree-tos --register-unsafely-without-email; then
    render_https "/etc/letsencrypt/live/${SYSTEM_DOMAIN}/fullchain.pem" "/etc/letsencrypt/live/${SYSTEM_DOMAIN}/privkey.pem" > "${SYSTEM_PORTAL_FILE}"
  else
    render_http > "${SYSTEM_PORTAL_FILE}"
  fi
fi

ln -sfn "${SYSTEM_PORTAL_FILE}" /etc/nginx/sites-enabled/system-portal.conf
nginx -t
systemctl reload nginx
