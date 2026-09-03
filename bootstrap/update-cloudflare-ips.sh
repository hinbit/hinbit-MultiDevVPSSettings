#!/usr/bin/env bash
set -euo pipefail
[[ "${EUID}" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
target=/etc/nginx/conf.d/01-cloudflare-real-ip.conf
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
{
  echo '# generated from Cloudflare published ranges'
  curl -fsS https://www.cloudflare.com/ips-v4 | awk 'NF {print "set_real_ip_from " $1 ";"}'
  curl -fsS https://www.cloudflare.com/ips-v6 | awk 'NF {print "set_real_ip_from " $1 ";"}'
  echo 'real_ip_header CF-Connecting-IP;'
  echo 'real_ip_recursive on;'
} > "$tmp"
[[ "$(wc -l < "$tmp")" -gt 10 ]] || { echo 'Cloudflare range download was incomplete' >&2; exit 1; }
install -m 0644 "$tmp" "$target"
nginx -t
systemctl reload nginx
