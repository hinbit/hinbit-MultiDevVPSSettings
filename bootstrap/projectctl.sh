#!/usr/bin/env bash
set -euo pipefail

META_DIR="/etc/vps-projects"
APP_ROOT="/var/www"
APP_MAP="/etc/app-map.csv"
AUTH_DIR="/etc/nginx/project-auth"
AUTH_USER="project"
PORT_MIN="${PROJECT_PORT_START:-3000}"
PORT_MAX="${PROJECT_PORT_END:-9999}"
ENV_CANDIDATES=(
  .env
  .env.local
  .env.production
  .env.credentials
  .env.machine
  .env.production.local
  .env.development
)

die() {
  printf '[projectctl] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  projectctl install [--domain example.com] [--https yes|no] [--branch main] [--pm2-name name] [--port N] [--env-file path] [--entrypoint path] owner/repo
  projectctl update owner/repo
  projectctl restart owner/repo
  projectctl stop owner/repo
  projectctl status owner/repo
  projectctl script [--pm2] owner/repo package-script
  projectctl password [--password secret|--clear] owner/repo
  projectctl mysql [--ips ip1,ip2] owner/repo
  projectctl uninstall owner/repo
  projectctl list

Defaults:
  - repo URL is git@github.com:owner/repo.git
  - project directory is /var/www/owner-repo
  - PM2 process name is owner-repo
  - default branch is the repo's current branch or "main"
  - port is auto-assigned if not provided
  - domain is optional, but when provided it is added to /etc/app-map.csv and synced to nginx
  - when a domain is provided, VITE_ALLOWED_HOSTS and CORS_ORIGIN are exported for the PM2 runtime
  - `projectctl script` runs a package.json script, with optional `--pm2` for runtime scripts
  - `projectctl password` enables or clears nginx basic auth for a project's domain
  - `projectctl mysql` manages MySQL access IPs for a project's DB user
EOF
}

repo_ref_from_arg() {
  local ref="$1"
  ref="${ref#git@github.com:}"
  ref="${ref#https://github.com/}"
  ref="${ref#github.com:}"
  ref="${ref%.git}"
  [[ "${ref}" == */* ]] || die "Expected owner/repo, got: ${1}"
  printf '%s' "${ref}"
}

slug_from_ref() {
  local ref="$1"
  printf '%s' "${ref//\//-}" | sed 's/[^A-Za-z0-9._-]/-/g'
}

repo_url_from_ref() {
  printf 'git@github.com:%s.git' "$1"
}

branch_from_repo() {
  local ref="$1"
  local branch="${2:-}"
  local resolved=""

  if [[ -n "${branch}" ]]; then
    printf '%s' "${branch}"
    return
  fi

  resolved="$(
    git ls-remote --symref "$(repo_url_from_ref "${ref}")" HEAD 2>/dev/null \
      | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }'
  )"

  if [[ -n "${resolved}" ]]; then
    printf '%s' "${resolved}"
    return
  fi

  printf 'main'
}

validate_domain() {
  local domain="$1"
  [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid domain: ${domain}"
}

meta_path_for_slug() {
  printf '%s/%s.env' "${META_DIR}" "$1"
}

project_env_value() {
  local key="$1"
  local file=""
  local line=""
  local value=""

  for file in "${ENV_CANDIDATES[@]}"; do
    [[ -f "${APP_DIR}/${file}" ]] || continue
    line="$(grep -hE "^[[:space:]]*${key}=" "${APP_DIR}/${file}" 2>/dev/null | tail -n1 || true)"
    if [[ -n "${line}" ]]; then
      value="${line#*=}"
    fi
  done

  printf '%s' "${value}"
}

project_db_value() {
  local key=""
  for key in "$@"; do
    local value
    value="$(project_env_value "${key}")"
    if [[ -n "${value}" ]]; then
      printf '%s' "${value}"
      return
    fi
  done
  printf '%s' ""
}

sql_quote() {
  local value
  value="$(printf '%s' "$1" | sed "s/'/''/g")"
  printf "'%s'" "${value}"
}

sql_ident() {
  local value
  value="$(printf '%s' "$1" | sed 's/`/``/g')"
  printf '`%s`' "${value}"
}

mysql_exec() {
  mysql --protocol=socket -uroot --batch --skip-column-names -e "$1"
}

normalize_mysql_ips() {
  local raw="${1:-}"
  python3 - "${raw}" <<'PY'
import ipaddress
import re
import sys

raw = sys.argv[1]
seen = []
for token in re.split(r'[\s,]+', raw.strip()):
    if not token:
        continue
    try:
        if '/' in token:
            ipaddress.ip_network(token, strict=False)
        else:
            ipaddress.ip_address(token)
    except ValueError:
        raise SystemExit(f"Invalid IP/CIDR: {token}")
    if token not in seen:
        seen.append(token)
print(",".join(seen))
PY
}

update_meta_value() {
  local meta="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { updated = 0 }
    $1 == key {
      print key "=" value
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) {
        print key "=" value
      }
    }
  ' "${meta}" > "${tmp}"
  mv "${tmp}" "${meta}"
}

ensure_meta_dir() {
  mkdir -p "${META_DIR}"
}

ensure_auth_dir() {
  mkdir -p "${AUTH_DIR}"
}

ensure_app_map() {
  if [[ ! -f "${APP_MAP}" ]]; then
    cat > "${APP_MAP}" <<'EOF'
domain,port,type,https
EOF
  fi
}

load_meta() {
  local meta="$1"
  [[ -f "${meta}" ]] || die "Missing project metadata: ${meta}"
  # shellcheck disable=SC1090
  source "${meta}"
}

package_has_script() {
  local script="$1"
  node -e '
    const fs = require("fs");
    const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
    const script = process.argv[1];
    process.exit(pkg.scripts && Object.prototype.hasOwnProperty.call(pkg.scripts, script) ? 0 : 1);
  ' "${script}"
}

detect_package_manager() {
  if [[ -f pnpm-lock.yaml ]]; then
    if command -v pnpm >/dev/null 2>&1; then
      printf 'pnpm'
      return
    fi
    if command -v corepack >/dev/null 2>&1; then
      printf 'corepack-pnpm'
      return
    fi
  fi

  if [[ -f yarn.lock ]]; then
    if command -v yarn >/dev/null 2>&1; then
      printf 'yarn'
      return
    fi
    if command -v corepack >/dev/null 2>&1; then
      printf 'corepack-yarn'
      return
    fi
  fi

  printf 'npm'
}

install_deps() {
  if [[ ! -f package.json ]]; then
    return
  fi

  local pm
  pm="${PACKAGE_MANAGER:-$(detect_package_manager)}"
  PACKAGE_MANAGER="${pm}"

  case "${pm}" in
    pnpm)
      pnpm install --frozen-lockfile
      ;;
    corepack-pnpm)
      corepack pnpm install --frozen-lockfile
      ;;
    yarn)
      yarn install --frozen-lockfile
      ;;
    corepack-yarn)
      corepack yarn install --frozen-lockfile
      ;;
    npm)
      if [[ -f package-lock.json ]]; then
        npm ci
      else
        npm install
      fi
      ;;
    *)
      die "Unsupported package manager: ${pm}"
      ;;
  esac
}

maybe_build() {
  if [[ -f package.json ]] && package_has_script build; then
    case "${PACKAGE_MANAGER:-npm}" in
      pnpm) pnpm run build ;;
      corepack-pnpm) corepack pnpm run build ;;
      yarn) yarn build ;;
      corepack-yarn) corepack yarn build ;;
      *) npm run build ;;
    esac
  fi
}

detect_start_kind() {
  local ecosystem_file=""
  for ecosystem_file in ecosystem.config.js ecosystem.config.cjs ecosystem.config.mjs process.yml processes.config.js; do
    if [[ -f "${ecosystem_file}" ]]; then
      printf 'ecosystem:%s' "${ecosystem_file}"
      return
    fi
  done

  if [[ -f server/index.js ]]; then
    printf 'node:server/index.js'
    return
  fi

  if [[ -f package.json ]]; then
    if package_has_script start; then
      printf 'npm-start'
      return
    fi

    if package_has_script dev; then
      printf 'npm-dev'
      return
    fi
  fi

  if [[ -f server.js ]]; then
    printf 'node:server.js'
    return
  fi

  if [[ -f index.js ]]; then
    printf 'node:index.js'
    return
  fi

  if [[ -d dist ]]; then
    printf 'serve:dist'
    return
  fi

  if [[ -d build ]]; then
    printf 'serve:build'
    return
  fi

  die "Could not detect a start command. Add ecosystem.config.js, a package.json start/dev script, server.js, index.js, or a dist/build folder."
}

start_kind_family() {
  local kind="$1"
  case "${kind}" in
    ecosystem:*|npm-start|npm-dev|node:*) printf 'node' ;;
    serve:*) printf 'static' ;;
    *) printf 'custom' ;;
  esac
}

start_kind_target() {
  local kind="$1"
  case "${kind}" in
    ecosystem:*) printf '%s' "${kind#ecosystem:}" ;;
    node:*) printf '%s' "${kind#node:}" ;;
    serve:*) printf '%s' "${kind#serve:}" ;;
    npm-start|npm-dev) printf '' ;;
    *) printf '' ;;
  esac
}

used_ports() {
  {
    if [[ -f /etc/app-map.csv ]]; then
      awk -F, 'NR > 1 && $2 ~ /^[0-9]+$/ { print $2 }' /etc/app-map.csv
    fi
    ss -Htanl 2>/dev/null | awk '
      {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /:[0-9]+$/) {
            sub(/^.*:/, "", $i);
            if ($i ~ /^[0-9]+$/) print $i;
          }
        }
      }
    '
  } | sort -n -u
}

pick_port() {
  local start="${1:-${PORT_MIN}}"
  local end="${2:-${PORT_MAX}}"
  local port
  local used
  used="$(used_ports)"

  for port in $(seq "${start}" "${end}"); do
    if ! printf '%s\n' "${used}" | grep -qx "${port}"; then
      printf '%s' "${port}"
      return
    fi
  done

  die "No free port found in range ${start}-${end}"
}

write_meta() {
  local meta="$1"
  cat > "${meta}" <<EOF
REPO_REF=${REPO_REF}
REPO_URL=${REPO_URL}
PROJECT_SLUG=${PROJECT_SLUG}
APP_DIR=${APP_DIR}
PM2_NAME=${PM2_NAME}
APP_PORT=${APP_PORT}
APP_DOMAIN=${APP_DOMAIN}
APP_HTTPS=${APP_HTTPS}
APP_TYPE=${APP_TYPE}
PACKAGE_MANAGER=${PACKAGE_MANAGER:-}
BRANCH=${BRANCH}
GIT_REMOTE=${GIT_REMOTE}
START_KIND=${START_KIND}
START_TARGET=${START_TARGET}
MYSQL_ALLOWED_IPS=${MYSQL_ALLOWED_IPS:-}
EOF
}

app_map_upsert() {
  local domain="$1"
  local port="$2"
  local type="$3"
  local https="$4"
  local tmp
  tmp="$(mktemp)"

  if [[ ! -f "${APP_MAP}" ]]; then
    ensure_app_map
  fi

  awk -F, -v OFS=, -v domain="${domain}" -v port="${port}" -v type="${type}" -v https="${https}" '
    BEGIN { updated = 0 }
    NR == 1 { print; next }
    $1 == domain {
      print domain, port, type, https
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) {
        print domain, port, type, https
      }
    }
  ' "${APP_MAP}" > "${tmp}"

  mv "${tmp}" "${APP_MAP}"
}

sync_app_map() {
  if [[ -n "${APP_DOMAIN:-}" ]]; then
    app_map_upsert "${APP_DOMAIN}" "${APP_PORT}" "${APP_TYPE:-project}" "${APP_HTTPS:-yes}"
    if [[ -x /usr/local/bin/app-sync.sh ]]; then
      /usr/local/bin/app-sync.sh
    fi
  fi
}

auth_file_for_domain() {
  local domain="$1"
  printf '%s/%s.htpasswd' "${AUTH_DIR}" "${domain}"
}

project_auth_enabled() {
  local domain="$1"
  [[ -n "${domain}" ]] && [[ -s "$(auth_file_for_domain "${domain}")" ]]
}

package_script_runner() {
  local script="$1"
  case "${PACKAGE_MANAGER:-npm}" in
    pnpm) printf 'pnpm run %q' "${script}" ;;
    corepack-pnpm) printf 'corepack pnpm run %q' "${script}" ;;
    yarn) printf 'yarn %q' "${script}" ;;
    corepack-yarn) printf 'corepack yarn %q' "${script}" ;;
    *) printf 'npm run %q' "${script}" ;;
  esac
}

clone_or_pull() {
  if [[ -d "${APP_DIR}/.git" ]]; then
    git -C "${APP_DIR}" remote set-url origin "${REPO_URL}" >/dev/null 2>&1 || true
    git -C "${APP_DIR}" pull --ff-only
  else
    rm -rf "${APP_DIR}"
    git clone --branch "${BRANCH}" --single-branch "${REPO_URL}" "${APP_DIR}"
  fi
}

start_pm2() {
  local -a runtime_env=()

  runtime_env+=("TZ=Asia/Jerusalem")

  if [[ -n "${APP_DOMAIN:-}" ]]; then
    runtime_env+=("VITE_ALLOWED_HOSTS=${APP_DOMAIN}")
    runtime_env+=("CORS_ORIGIN=https://${APP_DOMAIN}")
  fi

  if [[ "${START_KIND}" == "node:server/index.js" ]]; then
    runtime_env+=("NODE_ENV=production")
  fi

  start_with_env() {
    if [[ ${#runtime_env[@]} -gt 0 ]]; then
      env "${runtime_env[@]}" "$@"
    else
      "$@"
    fi
  }

  (
    cd "${APP_DIR}"
    case "${START_KIND}" in
      ecosystem)
        start_with_env pm2 start "${START_TARGET}" --name "${PM2_NAME}" --update-env --time
        ;;
      npm-start)
        case "${PACKAGE_MANAGER:-npm}" in
          pnpm) start_with_env env PORT="${APP_PORT}" pm2 start pnpm --name "${PM2_NAME}" --time -- start ;;
          corepack-pnpm) start_with_env env PORT="${APP_PORT}" pm2 start corepack --name "${PM2_NAME}" --time -- pnpm start ;;
          yarn) start_with_env env PORT="${APP_PORT}" pm2 start yarn --name "${PM2_NAME}" --time -- start ;;
          corepack-yarn) start_with_env env PORT="${APP_PORT}" pm2 start corepack --name "${PM2_NAME}" --time -- yarn start ;;
          *) start_with_env env PORT="${APP_PORT}" pm2 start npm --name "${PM2_NAME}" --time -- start ;;
        esac
        ;;
      npm-dev)
        case "${PACKAGE_MANAGER:-npm}" in
          pnpm) start_with_env env PORT="${APP_PORT}" pm2 start pnpm --name "${PM2_NAME}" --time -- dev ;;
          corepack-pnpm) start_with_env env PORT="${APP_PORT}" pm2 start corepack --name "${PM2_NAME}" --time -- pnpm dev ;;
          yarn) start_with_env env PORT="${APP_PORT}" pm2 start yarn --name "${PM2_NAME}" --time -- dev ;;
          corepack-yarn) start_with_env env PORT="${APP_PORT}" pm2 start corepack --name "${PM2_NAME}" --time -- yarn dev ;;
          *) start_with_env env PORT="${APP_PORT}" pm2 start npm --name "${PM2_NAME}" --time -- run dev ;;
        esac
        ;;
      node:*)
        start_with_env env PORT="${APP_PORT}" pm2 start "${START_TARGET}" --name "${PM2_NAME}" --update-env --time
        ;;
      serve:*)
        start_with_env pm2 serve "${START_TARGET}" "${APP_PORT}" --name "${PM2_NAME}" --spa --time
        ;;
      *)
        die "Unsupported start kind: ${START_KIND}"
        ;;
    esac
  )
  pm2 save
}

restart_pm2() {
  if pm2 describe "${PM2_NAME}" >/dev/null 2>&1; then
    pm2 delete "${PM2_NAME}" >/dev/null 2>&1 || true
  fi

  start_pm2
}

do_install() {
  local ref="$1"
  local domain="${2:-}"
  local https="${3:-yes}"
  local branch="${4:-}"
  local pm2_name="${5:-}"
  local forced_port="${6:-}"
  local env_file="${7:-}"
  local entrypoint="${8:-}"

  REPO_REF="$(repo_ref_from_arg "${ref}")"
  REPO_URL="$(repo_url_from_ref "${REPO_REF}")"
  PROJECT_SLUG="$(slug_from_ref "${REPO_REF}")"
  APP_DIR="${APP_ROOT}/${PROJECT_SLUG}"
  BRANCH="$(branch_from_repo "${REPO_REF}" "${branch}")"
  PM2_NAME="${pm2_name:-${PROJECT_SLUG}}"
  APP_PORT="${forced_port:-$(pick_port)}"
  APP_DOMAIN="${domain:-}"
  APP_HTTPS="${https:-yes}"
  APP_TYPE="project"
  GIT_REMOTE="origin"

  case "${APP_HTTPS,,}" in
    yes|no) ;;
    *) die "Invalid --https value: ${APP_HTTPS}. Use yes or no." ;;
  esac
  APP_HTTPS="${APP_HTTPS,,}"

  ensure_meta_dir
  ensure_app_map
  if [[ -n "${APP_DOMAIN}" ]]; then
    validate_domain "${APP_DOMAIN}"
  fi

  MYSQL_ALLOWED_IPS="$(project_env_value MYSQL_ALLOWED_IPS)"

  clone_or_pull

  git -C "${APP_DIR}" checkout "${BRANCH}" >/dev/null 2>&1 || git -C "${APP_DIR}" checkout -b "${BRANCH}" "origin/${BRANCH}"

  if [[ -n "${env_file}" ]]; then
    [[ -f "${env_file}" ]] || die "Missing env file: ${env_file}"
    install -m 0600 "${env_file}" "${APP_DIR}/.env"
    git -C "${APP_DIR}" update-index --skip-worktree .env >/dev/null 2>&1 || true
  fi

  PACKAGE_MANAGER="$(cd "${APP_DIR}" && detect_package_manager)"

  if [[ -n "${entrypoint}" ]]; then
    if [[ "${entrypoint}" == *.js || "${entrypoint}" == *.cjs || "${entrypoint}" == *.mjs ]]; then
      START_KIND="node:${entrypoint}"
    else
      START_KIND="${entrypoint}"
    fi
  else
    START_KIND="$(cd "${APP_DIR}" && detect_start_kind)"
  fi
  START_TARGET="$(start_kind_target "${START_KIND}")"
  APP_TYPE="$(start_kind_family "${START_KIND}")"

  (
    cd "${APP_DIR}"
    install_deps
    maybe_build
  )

  meta="$(meta_path_for_slug "${PROJECT_SLUG}")"
  write_meta "${meta}"
  chmod 0644 "${meta}"

  local db_name=""
  local db_user=""
  local db_password=""
  db_name="$(project_db_value DB_NAME DB_DATABASE MYSQL_DATABASE POSTGRES_DB)"
  db_user="$(project_db_value DB_USER MYSQL_USER POSTGRES_USER)"
  db_password="$(project_db_value DB_PASSWORD MYSQL_PASSWORD POSTGRES_PASSWORD)"
  if [[ -n "${db_name}" && -n "${db_user}" && -n "${db_password}" ]]; then
    sync_mysql_permissions "${db_name}" "${db_user}" "${db_password}" "${MYSQL_ALLOWED_IPS:-}" ""
  fi

  sync_app_map
  restart_pm2
  if [[ -n "${APP_DOMAIN}" ]]; then
    printf '[projectctl] installed %s in %s on port %s for %s\n' "${REPO_REF}" "${APP_DIR}" "${APP_PORT}" "${APP_DOMAIN}"
  else
    printf '[projectctl] installed %s in %s on port %s\n' "${REPO_REF}" "${APP_DIR}" "${APP_PORT}"
  fi
}

do_update() {
  local ref="$1"
  local slug
  local meta

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"

  [[ -d "${APP_DIR}/.git" ]] || die "Missing git repo at ${APP_DIR}"

  (
    cd "${APP_DIR}"
    git checkout "${BRANCH}" >/dev/null 2>&1 || true
    git pull --ff-only origin "${BRANCH}"
    install_deps
    maybe_build
  )

  sync_app_map
  restart_pm2
  printf '[projectctl] updated %s\n' "${REPO_REF}"
}

do_restart() {
  local ref="$1"
  local slug
  local meta

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"
  restart_pm2
  printf '[projectctl] restarted %s\n' "${REPO_REF}"
}

do_stop() {
  local ref="$1"
  local slug
  local meta

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"

  if pm2 describe "${PM2_NAME}" >/dev/null 2>&1; then
    pm2 stop "${PM2_NAME}" >/dev/null 2>&1 || true
    pm2 save || true
  fi

  printf '[projectctl] stopped %s\n' "${REPO_REF}"
}

do_status() {
  local ref="$1"
  local slug
  local meta
  local db_name
  local db_user

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"
  db_name="$(project_db_value DB_NAME DB_DATABASE MYSQL_DATABASE POSTGRES_DB)"
  db_user="$(project_db_value DB_USER MYSQL_USER POSTGRES_USER)"

  printf 'repo: %s\npath: %s\npm2: %s\nport: %s\ndomain: %s\nhttps: %s\nkind: %s\n' \
    "${REPO_REF}" "${APP_DIR}" "${PM2_NAME}" "${APP_PORT}" "${APP_DOMAIN:-}" "${APP_HTTPS:-yes}" "${START_KIND}"
  printf 'protected: %s\n' "$(project_auth_enabled "${APP_DOMAIN:-}" && printf yes || printf no)"
  printf 'mysql_allowed_ips: %s\n' "${MYSQL_ALLOWED_IPS:-}"
  printf 'db: %s\nuser: %s\n' "${db_name}" "${db_user}"
  (cd "${APP_DIR}" && git status -sb) || true
  pm2 describe "${PM2_NAME}" || true
}

do_script() {
  local ref="$1"
  local script="$2"
  local pm2_mode="${3:-no}"
  local slug
  local meta
  local runner
  local pm2_script_name

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"

  [[ -d "${APP_DIR}" ]] || die "Missing app directory: ${APP_DIR}"
  [[ -n "${script}" ]] || die "Missing package script name"
  [[ "${script}" =~ ^[A-Za-z0-9:_-]+$ ]] || die "Invalid script name: ${script}"

  runner="$(package_script_runner "${script}")"
  pm2_script_name="${PM2_NAME}-${script}"

  if [[ "${pm2_mode}" == "yes" ]]; then
    (
      cd "${APP_DIR}"
      pm2 delete "${pm2_script_name}" >/dev/null 2>&1 || true
      env TZ=Asia/Jerusalem PORT="${APP_PORT}" pm2 start /bin/bash --name "${pm2_script_name}" --no-autorestart --time -- -lc "${runner}"
    )
    pm2 save
    printf '[projectctl] activated %s script %s as %s\n' "${REPO_REF}" "${script}" "${pm2_script_name}"
    return
  fi

  (
    cd "${APP_DIR}"
    /bin/bash -lc "${runner}"
  )
  printf '[projectctl] ran %s script %s\n' "${REPO_REF}" "${script}"
}

do_password() {
  local ref="$1"
  local password="${2:-}"
  local clear="${3:-no}"
  local slug
  local meta
  local auth_file

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"

  [[ -n "${APP_DOMAIN:-}" ]] || die "Project has no domain; password protection needs a domain"
  auth_file="$(auth_file_for_domain "${APP_DOMAIN}")"

  ensure_auth_dir

  if [[ "${clear}" == "yes" ]]; then
    rm -f "${auth_file}"
    sync_app_map
    printf '[projectctl] cleared password for %s\n' "${REPO_REF}"
    return
  fi

  [[ -n "${password}" ]] || die "Missing project password"
  command -v openssl >/dev/null 2>&1 || die "openssl is required to set project passwords"
  {
    printf '%s:%s\n' "${AUTH_USER}" "$(openssl passwd -apr1 "${password}")"
  } > "${auth_file}"
  chmod 0640 "${auth_file}"
  sync_app_map
  printf '[projectctl] set password for %s\n' "${REPO_REF}"
}

sync_mysql_firewall_rules() {
  local new_ips="${1:-}"
  local old_ips="${2:-}"
  local -A desired=()
  local -a desired_list=()
  local -a old_list=()
  local ip=""

  if [[ -n "${new_ips}" ]]; then
    IFS=, read -r -a desired_list <<< "${new_ips}"
  fi

  if [[ -n "${old_ips}" ]]; then
    IFS=, read -r -a old_list <<< "${old_ips}"
  fi

  for ip in "${desired_list[@]}"; do
    [[ -n "${ip}" ]] || continue
    desired["$ip"]=1
  done

  for ip in "${old_list[@]}"; do
    [[ -n "${ip}" && "${ip}" != "localhost" ]] || continue
    if [[ -z "${desired[$ip]:-}" ]]; then
      ufw --force delete allow from "${ip}" to any port 3306 proto tcp >/dev/null 2>&1 || true
    fi
  done

  for ip in "${desired_list[@]}"; do
    [[ -n "${ip}" ]] || continue
    ufw allow from "${ip}" to any port 3306 proto tcp >/dev/null 2>&1 || true
  done
}

sync_mysql_permissions() {
  local db_name="$1"
  local db_user="$2"
  local db_password="$3"
  local new_ips="${4:-}"
  local old_ips="${5:-}"
  local db_ident
  local user_q
  local pass_q
  local current_hosts
  local host
  local -A desired=()
  local -a desired_list=()

  [[ -n "${db_name}" ]] || die "Missing database name in project env"
  [[ -n "${db_user}" ]] || die "Missing database user in project env"
  [[ -n "${db_password}" ]] || die "Missing database password in project env"

  db_ident="$(sql_ident "${db_name}")"
  user_q="$(sql_quote "${db_user}")"
  pass_q="$(sql_quote "${db_password}")"

  if [[ -n "${new_ips}" ]]; then
    IFS=, read -r -a desired_list <<< "${new_ips}"
  fi

  desired["localhost"]=1
  desired["127.0.0.1"]=1
  desired["::1"]=1
  mysql_exec "CREATE DATABASE IF NOT EXISTS ${db_ident} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  for host in localhost 127.0.0.1 ::1; do
    mysql_exec "CREATE USER IF NOT EXISTS ${user_q}@$(sql_quote "${host}") IDENTIFIED BY ${pass_q};"
    mysql_exec "ALTER USER ${user_q}@$(sql_quote "${host}") IDENTIFIED BY ${pass_q};"
    mysql_exec "GRANT ALL PRIVILEGES ON ${db_ident}.* TO ${user_q}@$(sql_quote "${host}");"
  done

  if [[ -n "${new_ips}" ]]; then
    desired["%"]=1
    mysql_exec "CREATE USER IF NOT EXISTS ${user_q}@'%' IDENTIFIED BY ${pass_q};"
    mysql_exec "ALTER USER ${user_q}@'%' IDENTIFIED BY ${pass_q};"
    mysql_exec "GRANT ALL PRIVILEGES ON ${db_ident}.* TO ${user_q}@'%';"
  fi

  current_hosts="$(mysql_exec "SELECT Host FROM mysql.user WHERE User=${user_q};" 2>/dev/null || true)"
  while IFS= read -r host; do
    [[ -n "${host}" ]] || continue
    if [[ -z "${desired[$host]:-}" ]]; then
      mysql_exec "DROP USER IF EXISTS ${user_q}@$(sql_quote "${host}");" >/dev/null 2>&1 || true
    fi
  done <<< "${current_hosts}"

  mysql_exec "FLUSH PRIVILEGES;"
  sync_mysql_firewall_rules "${new_ips}" "${old_ips}"
}

read_mysql_accounts() {
  local db_user="$1"
  local user_q

  [[ -n "${db_user}" ]] || return 0
  user_q="$(sql_quote "${db_user}")"
  mysql_exec "SELECT CONCAT(User, '@', Host) FROM mysql.user WHERE User=${user_q} ORDER BY Host;" 2>/dev/null || true
}

do_mysql() {
  local ref="$1"
  local ips="${2-__unset__}"
  local slug
  local meta
  local old_ips
  local new_ips
  local db_name
  local db_user
  local db_password

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"

  old_ips="${MYSQL_ALLOWED_IPS:-}"

  if [[ "${ips}" == "__unset__" ]]; then
    db_name="$(project_db_value DB_NAME DB_DATABASE MYSQL_DATABASE POSTGRES_DB)"
    db_user="$(project_db_value DB_USER MYSQL_USER POSTGRES_USER)"
    db_password="$(project_db_value DB_PASSWORD MYSQL_PASSWORD POSTGRES_PASSWORD)"
    printf 'repo: %s\npath: %s\ndb: %s\nuser: %s\npassword: %s\nallowed_ips: %s\n' \
      "${REPO_REF}" "${APP_DIR}" \
      "${db_name}" \
      "${db_user}" \
      "${db_password}" \
      "${MYSQL_ALLOWED_IPS:-}"
    if [[ -n "${db_user}" ]]; then
      printf 'mysql_accounts:\n%s\n' "$(read_mysql_accounts "${db_user}")"
    fi
    return
  fi

  new_ips="$(normalize_mysql_ips "${ips}")"
  db_name="$(project_db_value DB_NAME DB_DATABASE MYSQL_DATABASE POSTGRES_DB)"
  db_user="$(project_db_value DB_USER MYSQL_USER POSTGRES_USER)"
  db_password="$(project_db_value DB_PASSWORD MYSQL_PASSWORD POSTGRES_PASSWORD)"

  MYSQL_ALLOWED_IPS="${new_ips}"
  update_meta_value "${meta}" "MYSQL_ALLOWED_IPS" "${MYSQL_ALLOWED_IPS}"
  sync_mysql_permissions "${db_name}" "${db_user}" "${db_password}" "${MYSQL_ALLOWED_IPS}" "${old_ips}"
  printf '[projectctl] mysql permissions updated for %s (%s)\n' "${REPO_REF}" "${MYSQL_ALLOWED_IPS:-local only}"
}

remove_mysql_permissions() {
  local db_name="$1"
  local db_user="$2"
  local db_password="$3"
  local old_ips="${4:-}"
  local user_q
  local current_hosts
  local host

  [[ -n "${db_name}" ]] || return 0
  [[ -n "${db_user}" ]] || return 0
  [[ -n "${db_password}" ]] || return 0

  user_q="$(sql_quote "${db_user}")"

  current_hosts="$(mysql_exec "SELECT Host FROM mysql.user WHERE User=${user_q};" 2>/dev/null || true)"
  while IFS= read -r host; do
    [[ -n "${host}" ]] || continue
    mysql_exec "DROP USER IF EXISTS ${user_q}@$(sql_quote "${host}");" >/dev/null 2>&1 || true
  done <<< "${current_hosts}"

  sync_mysql_firewall_rules "" "${old_ips}"
  mysql_exec "FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
}

do_uninstall() {
  local ref="$1"
  local slug
  local meta
  local tmp
  local db_name
  local db_user
  local db_password

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"
  db_name="$(project_db_value DB_NAME DB_DATABASE MYSQL_DATABASE POSTGRES_DB)"
  db_user="$(project_db_value DB_USER MYSQL_USER POSTGRES_USER)"
  db_password="$(project_db_value DB_PASSWORD MYSQL_PASSWORD POSTGRES_PASSWORD)"

  if pm2 describe "${PM2_NAME}" >/dev/null 2>&1; then
    pm2 delete "${PM2_NAME}" >/dev/null 2>&1 || true
    pm2 save || true
  fi

  if [[ -n "${APP_DOMAIN:-}" ]]; then
    rm -f "$(auth_file_for_domain "${APP_DOMAIN}")"
  fi

  if [[ -n "${APP_DOMAIN:-}" ]] && [[ -f "${APP_MAP}" ]]; then
    tmp="$(mktemp)"
    awk -F, -v OFS=, -v domain="${APP_DOMAIN}" 'NR == 1 { print; next } $1 != domain { print }' "${APP_MAP}" > "${tmp}"
    mv "${tmp}" "${APP_MAP}"
    if [[ -x /usr/local/bin/app-sync.sh ]]; then
      /usr/local/bin/app-sync.sh
    fi
  fi

  remove_mysql_permissions "${db_name}" "${db_user}" "${db_password}" "${MYSQL_ALLOWED_IPS:-}"

  rm -rf "${APP_DIR}" "${meta}"
  printf '[projectctl] uninstalled %s\n' "${REPO_REF}"
}

do_list() {
  [[ -d "${META_DIR}" ]] || exit 0
  for meta in "${META_DIR}"/*.env; do
    [[ -e "${meta}" ]] || continue
    # shellcheck disable=SC1090
    source "${meta}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${PROJECT_SLUG:-}" "${REPO_REF:-}" "${APP_PORT:-}" "${APP_DOMAIN:-}" "${PM2_NAME:-}" "${BRANCH:-}" "${APP_DIR:-}"
  done
}

main() {
  [[ $# -gt 0 ]] || { usage; exit 1; }

  local cmd="$1"
  shift

  case "${cmd}" in
    install)
      local port=""
      local domain=""
      local https="yes"
      local branch=""
      local pm2_name=""
      local env_file=""
      local entrypoint=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --domain)
            domain="${2:-}"
            shift 2
            ;;
          --https)
            https="${2:-yes}"
            shift 2
            ;;
          --branch)
            branch="${2:-}"
            shift 2
            ;;
          --pm2-name)
            pm2_name="${2:-}"
            shift 2
            ;;
          --port)
            port="${2:-}"
            shift 2
            ;;
          --env-file)
            env_file="${2:-}"
            shift 2
            ;;
          --entrypoint)
            entrypoint="${2:-}"
            shift 2
            ;;
          --help|-h)
            usage
            exit 0
            ;;
          *)
            break
            ;;
        esac
      done
      [[ $# -eq 1 ]] || { usage; exit 1; }
      do_install "$1" "${domain}" "${https}" "${branch}" "${pm2_name}" "${port}" "${env_file}" "${entrypoint}"
      ;;
    update)
      [[ $# -eq 1 ]] || { usage; exit 1; }
      do_update "$1"
      ;;
    restart)
      [[ $# -eq 1 ]] || { usage; exit 1; }
      do_restart "$1"
      ;;
    stop)
      [[ $# -eq 1 ]] || { usage; exit 1; }
      do_stop "$1"
      ;;
    status)
      [[ $# -eq 1 ]] || { usage; exit 1; }
      do_status "$1"
      ;;
    script)
      local pm2_mode="no"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --pm2)
            pm2_mode="yes"
            shift
            ;;
          --help|-h)
            usage
            exit 0
            ;;
          *)
            break
            ;;
        esac
      done
      [[ $# -eq 2 ]] || { usage; exit 1; }
      do_script "$1" "$2" "${pm2_mode}"
      ;;
    password)
      local password=""
      local clear="no"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --password)
            password="${2:-}"
            shift 2
            ;;
          --clear)
            clear="yes"
            shift
            ;;
          --help|-h)
            usage
            exit 0
            ;;
          *)
            break
            ;;
        esac
      done
      [[ $# -eq 1 ]] || { usage; exit 1; }
      do_password "$1" "${password}" "${clear}"
      ;;
    mysql)
      local ips="__unset__"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --ips)
            ips="${2:-}"
            shift 2
            ;;
          --help|-h)
            usage
            exit 0
            ;;
          *)
            break
            ;;
        esac
      done
      [[ $# -eq 1 ]] || { usage; exit 1; }
      do_mysql "$1" "${ips}"
      ;;
    uninstall)
      [[ $# -eq 1 ]] || { usage; exit 1; }
      do_uninstall "$1"
      ;;
    list)
      do_list
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
