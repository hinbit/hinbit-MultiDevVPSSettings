#!/usr/bin/env bash
set -euo pipefail

META_DIR="/etc/vps-projects"
APP_ROOT="/var/www"
APP_MAP="/etc/app-map.csv"
AUTH_DIR="/etc/nginx/project-auth"
DB_MACHINES_FILE="/etc/vps-db-machines.json"
AUTH_USER="project"
PORT_MIN="${PROJECT_PORT_START:-3000}"
PORT_MAX="${PROJECT_PORT_END:-9999}"
LOCAL_DB_MACHINE_ID="local-current"
LOCAL_DB_MACHINE_HOST="127.0.0.1"
COMMON_RESERVED_PORTS=(
  3000
  3001
  3002
  3306
  5432
  6379
  8080
  8081
  8443
  8787
  8788
  9000
  9200
  9306
  10000
)
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
  projectctl install [--domain example.com] [--https yes|no] [--branch main] [--pm2-name name] [--port N] [--db-machine id] [--env-file path] [--entrypoint path] owner/repo
  projectctl update owner/repo
  projectctl restart owner/repo
  projectctl stop owner/repo
  projectctl status owner/repo
  projectctl script [--pm2] [--dir path] owner/repo package-script
  projectctl password [--password secret|--clear] owner/repo
  projectctl mysql [--move-data] [--db-name name] [--db-user user] [--db-password password] [--machine id] [--machine-name name] [--machine-host host] [--machine-port port] [--machine-root-user user] [--machine-root-password password] [--machine-notes notes] [--ips ip1,ip2] owner/repo
  projectctl ssh [--password secret|--generate] owner/repo
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
  - `projectctl script` runs a package.json script, with optional `--pm2` for runtime scripts and `--dir` for scripts living in `server/` or `client/`
  - `projectctl password` enables or clears nginx basic auth for a project's domain
  - `projectctl mysql` manages MySQL access IPs and DB machine placement for a project's DB user, and `--move-data` copies the DB to the selected machine before switching over
  - `projectctl ssh` shows or rotates the project's SSH/SFTP upload credentials
  - `projectctl update` prompts before pulling local changes; set PROJECTCTL_PULL_MODE=merge-env|stash-all to force the choice
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

  if [[ "${#value}" -ge 2 && "${value:0:1}" == "'"'"'" && "${value: -1}" == "'"'"'" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "${#value}" -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
    value="${value:1:${#value}-2}"
  fi

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

project_env_has_key() {
  local key="$1"
  local file=""

  for file in "${ENV_CANDIDATES[@]}"; do
    [[ -f "${APP_DIR}/${file}" ]] || continue
    if grep -qE "^[[:space:]]*${key}=" "${APP_DIR}/${file}" 2>/dev/null; then
      printf '%s' "yes"
      return 0
    fi
  done

  printf '%s' "no"
}

project_db_value_exact() {
  local key=""
  for key in "$@"; do
    local value=""
    local file=""
    local line=""
    for file in "${ENV_CANDIDATES[@]}"; do
      [[ -f "${APP_DIR}/${file}" ]] || continue
      line="$(grep -hE "^[[:space:]]*${key}=" "${APP_DIR}/${file}" 2>/dev/null | tail -n1 || true)"
      if [[ -n "${line}" ]] || grep -qE "^[[:space:]]*${key}=" "${APP_DIR}/${file}" 2>/dev/null; then
        value="${line#*=}"
      fi
    done

    if [[ "${#value}" -ge 2 && "${value:0:1}" == "'"'"'" && "${value: -1}" == "'"'"'" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${#value}" -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:${#value}-2}"
    fi

    if [[ -n "${value}" || "$(project_env_has_key "${key}")" == "yes" ]]; then
      printf '%s' "${value}"
      return
    fi
  done

  printf '%s' ""
}

project_custom_db_machine_details() {
  local machine_name=""
  local machine_host=""
  local machine_root_user=""
  local machine_root_password=""
  local machine_port=""
  local machine_notes=""

  machine_name="$(project_db_value_exact DB_MACHINE_NAME)"
  machine_host="$(project_db_value_exact DB_MACHINE_HOST DB_HOST MYSQL_HOST POSTGRES_HOST)"
  machine_root_user="$(project_db_value_exact DB_MACHINE_ROOT_USER)"
  machine_root_password="$(project_db_value_exact DB_MACHINE_ROOT_PASSWORD)"
  machine_port="$(project_db_value_exact DB_MACHINE_PORT DB_PORT MYSQL_PORT POSTGRES_PORT)"
  machine_notes="$(project_db_value_exact DB_MACHINE_NOTES)"

  [[ -n "${machine_host}" ]] || return 1
  [[ -n "${machine_name}" ]] || machine_name="custom"
  [[ -n "${machine_root_user}" ]] || machine_root_user="root"
  [[ -n "${machine_port}" ]] || machine_port="3306"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${machine_name}" \
    "${machine_host}" \
    "${machine_root_user}" \
    "${machine_root_password}" \
    "${machine_port}" \
    "${machine_notes}"
}

repo_name_from_ref() {
  local ref="$1"
  printf '%s' "${ref##*/}"
}

sanitize_db_identifier() {
  local value="$1"
  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  printf '%s' "${value}"
}

project_default_db_identifier() {
  local ref="${1:-${REPO_REF}}"
  local name=""

  name="$(sanitize_db_identifier "$(repo_name_from_ref "${ref}")")"
  if [[ -z "${name}" ]]; then
    name="$(sanitize_db_identifier "${PROJECT_SLUG:-}")"
  fi
  if [[ -z "${name}" ]]; then
    name="$(sanitize_db_identifier "$(generate_secret)")"
  fi
  printf '%s' "${name}"
}

project_db_env_paths() {
  local project_dir="${1:-${APP_DIR}}"
  local candidate=""

  [[ -d "${project_dir}" ]] || return 0

  printf '%s\n' "${project_dir}/.env"
  for candidate in .env.local .env.production .env.credentials .env.production.local .env.development; do
    [[ -f "${project_dir}/${candidate}" ]] || continue
    printf '%s\n' "${project_dir}/${candidate}"
  done

  if [[ -d "${project_dir}/server" ]]; then
    printf '%s\n' "${project_dir}/server/.env"
    for candidate in .env.local .env.production .env.credentials .env.production.local .env.development; do
      [[ -f "${project_dir}/server/${candidate}" ]] || continue
      printf '%s\n' "${project_dir}/server/${candidate}"
    done
  fi
}

normalize_env_file_shell_safe() {
  local env_file="$1"
  local tmp=""

  [[ -f "${env_file}" ]] || return 0

  tmp="$(mktemp)"
  python3 - "$env_file" "$tmp" <<'PY'
import re
import sys

source_path, target_path = sys.argv[1:3]
line_re = re.compile(r'^([ \t]*)(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=(.*)$')

def unquote(value):
  if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
    inner = value[1:-1]
    if value[0] == '"':
      inner = (
        inner.replace('\\n', '\n')
        .replace('\\r', '\r')
        .replace('\\t', '\t')
        .replace('\\"', '"')
        .replace('\\\\', '\\')
      )
    return inner
  return value

def shell_quote(value):
  return "'" + value.replace("'", "'\"'\"'") + "'"

with open(source_path, 'r', encoding='utf-8', errors='surrogateescape') as handle:
  lines = handle.read().splitlines(True)

out = []
for line in lines:
  stripped = line.strip()
  if not stripped or stripped.startswith('#'):
    out.append(line)
    continue

  match = line_re.match(line.rstrip('\n'))
  if not match:
    out.append(line)
    continue

  indent, key, raw_value = match.groups()
  value = unquote(raw_value.strip())
  out.append(f"{indent}{key}={shell_quote(value)}\n")

with open(target_path, 'w', encoding='utf-8', errors='surrogateescape') as handle:
  handle.writelines(out)
PY
  cp -p "${tmp}" "${env_file}"
  rm -f "${tmp}" >/dev/null 2>&1 || true
}

env_file_value_exact() {
  local env_file="$1"
  shift
  local key=""
  local line=""
  local value=""

  [[ -f "${env_file}" ]] || return 1

  for key in "$@"; do
    line="$(grep -hE "^[[:space:]]*${key}=" "${env_file}" 2>/dev/null | tail -n1 || true)"
    if [[ -n "${line}" ]] || grep -qE "^[[:space:]]*${key}=" "${env_file}" 2>/dev/null; then
      value="${line#*=}"
      if [[ "${#value}" -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "${#value}" -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
      fi
      printf '%s' "${value}"
      return 0
    fi
  done

  return 1
}

normalize_project_deployment_env_file() {
  local env_file="$1"
  local key=""
  local value=""
  local chosen=""
  local app_domain="${APP_DOMAIN:-}"
  local app_https="${APP_HTTPS:-yes}"
  local base_url="https"

  [[ -f "${env_file}" ]] || return 0
  if [[ "${app_https,,}" == "no" ]]; then
    base_url="http"
  fi

  is_localish_value() {
    local candidate="${1:-}"
    case "${candidate,,}" in
      ''|local|localhost|127.0.0.1|::1|dev|development|testing|test|local-current)
        return 0
        ;;
    esac
    return 1
  }

  for key in SERVER_LOCATION APP_LOCATION LOCATION DEPLOY_LOCATION DEPLOY_TARGET TARGET_LOCATION RUNTIME_TARGET SERVER_MODE; do
    value="$(env_file_value_exact "${env_file}" "${key}" 2>/dev/null || true)"
    if is_localish_value "${value}"; then
      update_meta_value "${env_file}" "${key}" "web"
    fi
  done

  for key in NODE_ENV APP_ENV ENVIRONMENT MODE DEPLOYMENT RUNTIME_ENV BUILD_ENV STAGE; do
    value="$(env_file_value_exact "${env_file}" "${key}" 2>/dev/null || true)"
    if is_localish_value "${value}"; then
      update_meta_value "${env_file}" "${key}" "production"
    fi
  done

  for key in SERVER_URL APP_URL BASE_URL PUBLIC_URL SITE_URL ORIGIN_URL WEB_URL API_BASE_URL FRONTEND_URL BACKEND_URL NEXT_PUBLIC_SITE_URL NEXT_PUBLIC_API_URL NUXT_PUBLIC_SITE_URL VITE_API_BASE_URL VITE_APP_URL VITE_SERVER_URL; do
    value="$(env_file_value_exact "${env_file}" "${key}" 2>/dev/null || true)"
    chosen=""
    if ! is_localish_value "${value}" && [[ -n "${value}" ]]; then
      continue
    fi

    for suffix in WEB PRODUCTION PROD REMOTE LIVE; do
      chosen="$(env_file_value_exact "${env_file}" "${key}_${suffix}" 2>/dev/null || true)"
      if ! is_localish_value "${chosen}" && [[ -n "${chosen}" ]]; then
        break
      fi
      chosen=""
    done

    if [[ -z "${chosen}" && -n "${app_domain}" ]]; then
      chosen="${base_url}://${app_domain}"
    fi

    if [[ -n "${chosen}" ]]; then
      update_meta_value "${env_file}" "${key}" "${chosen}"
    fi
  done

  normalize_env_file_shell_safe "${env_file}"
}

sync_project_db_env() {
  local project_dir="${1:-${APP_DIR}}"
  local db_name="${2:-}"
  local db_user="${3:-}"
  local db_password="${4:-}"
  local db_type="${5:-}"
  local default_db_name=""
  local default_db_user=""
  local env_file=""

  [[ -d "${project_dir}" ]] || return 0

  default_db_name="$(project_default_db_identifier "${REPO_REF}")"
  default_db_user="${default_db_name}"

  [[ -n "${db_name}" ]] || db_name="$(project_db_value DB_NAME DB_DATABASE MYSQL_DATABASE POSTGRES_DB)"
  [[ -n "${db_user}" ]] || db_user="$(project_db_value DB_USER MYSQL_USER POSTGRES_USER)"
  [[ -n "${db_password}" ]] || db_password="$(project_db_value DB_PASSWORD MYSQL_PASSWORD POSTGRES_PASSWORD)"
  [[ -n "${db_type}" ]] || db_type="$(project_db_value DB_TYPE VITE_DB_TYPE)"

  [[ -n "${db_name}" ]] || db_name="${default_db_name}"
  [[ -n "${db_user}" ]] || db_user="${default_db_user}"
  [[ -n "${db_password}" ]] || db_password="$(generate_secret)"
  [[ -n "${db_type}" ]] || db_type="mysql"

  while IFS= read -r env_file; do
    [[ -n "${env_file}" ]] || continue
    touch "${env_file}"
    chmod 0600 "${env_file}"
    update_meta_value "${env_file}" "DB_TYPE" "${db_type}"
    update_meta_value "${env_file}" "VITE_DB_TYPE" "${db_type}"
    update_meta_value "${env_file}" "DB_NAME" "${db_name}"
    update_meta_value "${env_file}" "DB_DATABASE" "${db_name}"
    update_meta_value "${env_file}" "MYSQL_DATABASE" "${db_name}"
    update_meta_value "${env_file}" "DB_USER" "${db_user}"
    update_meta_value "${env_file}" "MYSQL_USER" "${db_user}"
    update_meta_value "${env_file}" "DB_PASSWORD" "${db_password}"
    update_meta_value "${env_file}" "MYSQL_PASSWORD" "${db_password}"
    normalize_env_file_shell_safe "${env_file}"
  done < <(project_db_env_paths "${project_dir}")

  printf '%s\t%s\t%s\t%s\n' "${db_name}" "${db_user}" "${db_password}" "${db_type}"
}

generate_secret() {
  local secret=""
  secret="$(openssl rand -base64 18 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 18 || true)"
  if [[ -z "${secret}" ]]; then
    secret="$(openssl rand -hex 12 2>/dev/null || true)"
  fi
  [[ -n "${secret}" ]] || die "Unable to generate a secret"
  printf '%s' "${secret}"
}

git_repo_dirty_status() {
  local repo_dir="${1:-${APP_DIR}}"

  git -C "${repo_dir}" status --porcelain 2>/dev/null || true
}

is_preserved_env_file() {
  local path="$1"
  local candidate=""

  for candidate in "${ENV_CANDIDATES[@]}"; do
    [[ "${path}" == "${candidate}" ]] && return 0
  done

  return 1
}

confirm_pull_mode_before_pull() {
  local repo_dir="${1:-${APP_DIR}}"
  local dirty_status="${2:-}"
  local label="${3:-${REPO_REF:-${PROJECT_SLUG:-project}}}"
  local answer=""
  local pref="${PROJECTCTL_PULL_MODE:-}"

  case "${pref,,}" in
    merge-env|merge|env|default)
      printf '%s' 'merge-env'
      return 0
      ;;
    stash-all|stash|all)
      printf '%s' 'stash-all'
      return 0
      ;;
  esac

  case "${PROJECTCTL_PULL_STASH:-}" in
    yes|y|true|1)
      printf '%s' 'merge-env'
      return 0
      ;;
    no|n|false|0)
      return 1
      ;;
  esac

  if [[ -t 0 && -t 1 ]]; then
    printf '[projectctl] Local changes detected in %s (%s):\n' "${label}" "${repo_dir}"
    if [[ -n "${dirty_status}" ]]; then
      printf '%s\n' "${dirty_status}" | sed 's/^/[projectctl]   /'
    fi
    printf '[projectctl]   1) Merge .env (default; keep current VPS env values after pull)\n'
    printf '[projectctl]   2) Stash all local changes before pulling\n'
    read -r -p "[projectctl] Choose [M]erge .env/[s]tash all/[c]ancel? [M/s/c] " answer || answer=""
    answer="${answer:-M}"
    case "${answer,,}" in
      s|stash|stash-all|2)
        printf '%s' 'stash-all'
        return 0
        ;;
      c|cancel|n|no)
        return 1
        ;;
    esac
    printf '%s' 'merge-env'
    return 0
  fi

  printf '[projectctl] Local changes detected in %s; auto-merging .env before pull (set PROJECTCTL_PULL_MODE=stash-all to stash everything)\n' "${label}" >&2
  printf '%s' 'merge-env'
}

pull_repo_with_optional_stash() {
  local repo_dir="${1:-${APP_DIR}}"
  local branch="${2:-${BRANCH}}"
  local repo_url="${3:-${REPO_URL}}"
  local dirty_status=""
  local dirty_paths=()
  local did_stash=0
  local pull_mode=""
  local env_backup_dir=""
  local pull_rc=0
  local non_env_dirty_status=""
  local non_env_dirty_paths=()
  local all_dirty_status=""
  local line=""
  local path=""

  for file in "${ENV_CANDIDATES[@]}"; do
    if git -C "${repo_dir}" ls-files --error-unmatch -- "${file}" >/dev/null 2>&1; then
      git -C "${repo_dir}" update-index --no-skip-worktree -- "${file}" >/dev/null 2>&1 || true
    fi
  done

  dirty_status="$(git_repo_dirty_status "${repo_dir}")"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    path="${line:3}"
    [[ -n "${path}" ]] || continue
    dirty_paths+=("${path}")
    if ! is_preserved_env_file "${path}"; then
      non_env_dirty_paths+=("${path}")
    fi
  done <<< "${dirty_status}"
  if [[ ${#dirty_paths[@]} -gt 0 ]]; then
    pull_mode="$(confirm_pull_mode_before_pull "${repo_dir}" "${dirty_status}" "${REPO_REF:-${PROJECT_SLUG:-project}}")" || die "Pull cancelled"
  fi

  env_backup_dir="$(mktemp -d)"

  if [[ "${pull_mode:-merge-env}" == "merge-env" ]]; then
    for file in "${ENV_CANDIDATES[@]}"; do
      [[ -f "${repo_dir}/${file}" ]] || continue
      mkdir -p "${env_backup_dir}/$(dirname "${file}")"
      cp -p "${repo_dir}/${file}" "${env_backup_dir}/${file}"
      if git -C "${repo_dir}" ls-files --error-unmatch -- "${file}" >/dev/null 2>&1; then
        git -C "${repo_dir}" checkout -- "${file}" >/dev/null 2>&1 || true
      fi
    done
  else
    all_dirty_status="${dirty_status}"
    if [[ -n "${all_dirty_status}" ]]; then
      git -C "${repo_dir}" stash push -u -m "projectctl auto-stash before pull ${REPO_REF:-${PROJECT_SLUG:-project}} $(date -u +%Y-%m-%dT%H:%M:%SZ)" -- "${dirty_paths[@]}"
      did_stash=1
    fi
  fi

  set +e
  git -C "${repo_dir}" remote set-url origin "${repo_url}" >/dev/null 2>&1
  git -C "${repo_dir}" fetch origin "${branch}" >/dev/null 2>&1
  git -C "${repo_dir}" checkout "${branch}" >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    git -C "${repo_dir}" checkout -B "${branch}" "origin/${branch}" >/dev/null 2>&1
  fi
  git -C "${repo_dir}" pull --ff-only origin "${branch}"
  pull_rc=$?
  set -e

  if [[ "${did_stash}" -eq 1 ]]; then
    if ! git -C "${repo_dir}" stash pop --index; then
      printf '[projectctl] Warning: stash pop did not apply cleanly; your stash may still be present.\n' >&2
    fi
  fi

  if [[ "${pull_mode:-merge-env}" == "merge-env" ]]; then
    for file in "${ENV_CANDIDATES[@]}"; do
      [[ -f "${env_backup_dir}/${file}" ]] || continue
      mkdir -p "${repo_dir}/$(dirname "${file}")"
      merge_env_file_preserving_current_values "${env_backup_dir}/${file}" "${repo_dir}/${file}" "${repo_dir}/${file}"
      if git -C "${repo_dir}" ls-files --error-unmatch -- "${file}" >/dev/null 2>&1; then
        git -C "${repo_dir}" update-index --skip-worktree -- "${file}" >/dev/null 2>&1 || true
      fi
    done
    for file in "${ENV_CANDIDATES[@]}"; do
      [[ -f "${repo_dir}/${file}" ]] || continue
      normalize_env_file_shell_safe "${repo_dir}/${file}"
    done
  fi

  rm -rf "${env_backup_dir}" >/dev/null 2>&1 || true

  return "${pull_rc}"
}

normalize_login_name() {
  local value="$1"
  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/-\+/-/g; s/^-//; s/-$//')"
  [[ -n "${value}" ]] || value="project"
  printf '%s' "${value}"
}

ssh_upload_user_from_slug() {
  local slug="$1"
  local clean
  local hash
  local base

  clean="$(normalize_login_name "${slug}")"
  hash="$(printf '%s' "${slug}" | sha1sum | awk '{print substr($1,1,6)}')"
  base="up-${clean}-${hash}"
  printf '%s' "${base:0:32}"
}

sql_quote() {
  local value
  value="$(printf '%s' "$1" | sed "s/'/''/g")"
  printf "'%s'" "${value}"
}

shell_quote() {
  local value
  value="$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"
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

db_machine_record() {
  local machine_id="${1:-}"
  local field="${2:-}"

  python3 - "${DB_MACHINES_FILE}" "${machine_id}" "${field}" <<'PY'
import json
import os
import sys

path, machine_id, field = sys.argv[1:4]
local_default = {
    "id": "local-current",
    "name": "localhost (current)",
    "host": "127.0.0.1",
    "rootUser": "root",
    "rootPassword": "",
    "port": "3306",
    "notes": "Current VPS local DB on this VPS",
}

machines = []
try:
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
            if isinstance(data, list):
                machines = data
except Exception:
    machines = []

record = None
for item in machines:
    if str(item.get("id", "")) == machine_id:
        record = item
        break

if record is None and machine_id == local_default["id"]:
    record = local_default

if record is None:
    sys.exit(1)

normalized = {
    "id": str(record.get("id", machine_id or "")),
    "name": str(record.get("name", "")),
    "host": str(record.get("host", "")),
    "rootUser": str(record.get("rootUser", record.get("user", ""))),
    "rootPassword": str(record.get("rootPassword", record.get("password", ""))),
    "port": str(record.get("port", "3306") or "3306"),
    "notes": str(record.get("notes", "")),
}

if field:
    print(normalized.get(field, ""))
else:
    for item in [
        normalized["id"],
        normalized["name"],
        normalized["host"],
        normalized["rootUser"],
        normalized["rootPassword"],
        normalized["port"],
        normalized["notes"],
    ]:
        print(item)
PY
}

write_db_machine_record() {
  local machine_id="$1"
  local name="$2"
  local host="$3"
  local root_user="$4"
  local root_password="$5"
  local port="$6"
  local notes="$7"

  python3 - "${DB_MACHINES_FILE}" "${machine_id}" "${name}" "${host}" "${root_user}" "${root_password}" "${port}" "${notes}" <<'PY'
import json
import os
import sys

path, machine_id, name, host, root_user, root_password, port, notes = sys.argv[1:9]
entry = {
    "id": machine_id,
    "name": name,
    "host": host,
    "rootUser": root_user,
    "rootPassword": root_password,
    "port": port or "3306",
    "notes": notes,
}

machines = []
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
            if isinstance(data, list):
                machines = data
    except Exception:
        machines = []

updated = False
for index, item in enumerate(machines):
    if str(item.get("id", "")) == machine_id:
        machines[index] = entry
        updated = True
        break

if not updated:
    machines.append(entry)

if not any(str(item.get("id", "")) == "local-current" for item in machines):
    machines.insert(0, {
        "id": "local-current",
        "name": "localhost (current)",
        "host": "127.0.0.1",
        "rootUser": "root",
        "rootPassword": "",
        "port": "3306",
        "notes": "Current VPS local DB on this VPS",
    })

machines.sort(key=lambda item: str(item.get("name", "")))
with open(path, "w", encoding="utf-8") as handle:
    json.dump(machines, handle, indent=2)
    handle.write("\n")
os.chmod(path, 0o600)
PY
}

ensure_local_db_machine_password() {
  local current
  local local_name
  local local_host
  local local_root_user
  local local_root_password
  local local_port
  local local_notes
  local password

  mapfile -t local_fields < <(db_machine_record "${LOCAL_DB_MACHINE_ID}" 2>/dev/null || true)
  local_name="${local_fields[1]:-}"
  local_host="${local_fields[2]:-}"
  local_root_user="${local_fields[3]:-}"
  local_root_password="${local_fields[4]:-}"
  local_port="${local_fields[5]:-}"
  local_notes="${local_fields[6]:-}"
  local_host="${local_host:-127.0.0.1}"
  local_root_user="${local_root_user:-root}"
  local_port="${local_port:-3306}"
  local_notes="${local_notes:-Current VPS local DB on this VPS}"
  if [[ ! "${local_port}" =~ ^[0-9]+$ ]]; then
    local_port="3306"
  fi

  if [[ -n "${local_root_password:-}" && "${local_host}" == "127.0.0.1" ]]; then
    if [[ "${local_port}" != "3306" ]]; then
      write_db_machine_record "${LOCAL_DB_MACHINE_ID}" "localhost (current)" "127.0.0.1" "${local_root_user}" "${local_root_password}" "${local_port}" "${local_notes}"
    fi
    return 0
  fi

  password="$(generate_secret)"

  mysql_exec "CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY $(sql_quote "${password}");"
  mysql_exec "ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY $(sql_quote "${password}");"
  mysql_exec "GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;"
  mysql_exec "CREATE USER IF NOT EXISTS 'root'@'::1' IDENTIFIED BY $(sql_quote "${password}");"
  mysql_exec "ALTER USER 'root'@'::1' IDENTIFIED BY $(sql_quote "${password}");"
  mysql_exec "GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1' WITH GRANT OPTION;"
  mysql_exec "FLUSH PRIVILEGES;"

  write_db_machine_record "${LOCAL_DB_MACHINE_ID}" "localhost (current)" "127.0.0.1" "${local_root_user}" "${password}" "${local_port}" "${local_notes}"
}

resolve_db_machine() {
  local machine_id="${1:-${LOCAL_DB_MACHINE_ID}}"
  local machine_output=""

  if machine_output="$(db_machine_record "${machine_id}" 2>/dev/null)"; then
    mapfile -t machine_fields <<< "${machine_output}"
    DB_MACHINE_ID="${machine_fields[0]:-${LOCAL_DB_MACHINE_ID}}"
    DB_MACHINE_NAME="${machine_fields[1]:-}"
    DB_MACHINE_HOST="${machine_fields[2]:-127.0.0.1}"
    DB_MACHINE_ROOT_USER="${machine_fields[3]:-root}"
    DB_MACHINE_ROOT_PASSWORD="${machine_fields[4]:-}"
    DB_MACHINE_PORT="${machine_fields[5]:-3306}"
    DB_MACHINE_NOTES="${machine_fields[6]:-}"
  else
    if machine_output="$(project_custom_db_machine_details 2>/dev/null)"; then
      IFS=$'\t' read -r -a machine_fields <<< "${machine_output}"
      DB_MACHINE_ID="${machine_id:-custom}"
      DB_MACHINE_NAME="${machine_fields[0]:-custom}"
      DB_MACHINE_HOST="${machine_fields[1]:-}"
      DB_MACHINE_ROOT_USER="${machine_fields[2]:-root}"
      DB_MACHINE_ROOT_PASSWORD="${machine_fields[3]:-}"
      DB_MACHINE_PORT="${machine_fields[4]:-3306}"
      DB_MACHINE_NOTES="${machine_fields[5]:-}"
    else
      die "Unknown DB machine: ${machine_id}"
    fi
  fi

  if [[ "${DB_MACHINE_ID}" == "${LOCAL_DB_MACHINE_ID}" ]]; then
    ensure_local_db_machine_password
    machine_output="$(db_machine_record "${LOCAL_DB_MACHINE_ID}" 2>/dev/null)" || die "Unknown DB machine: ${LOCAL_DB_MACHINE_ID}"
    mapfile -t machine_fields <<< "${machine_output}"
    DB_MACHINE_ID="${machine_fields[0]:-${LOCAL_DB_MACHINE_ID}}"
    DB_MACHINE_NAME="${machine_fields[1]:-}"
    DB_MACHINE_HOST="${machine_fields[2]:-127.0.0.1}"
    DB_MACHINE_ROOT_USER="${machine_fields[3]:-root}"
    DB_MACHINE_ROOT_PASSWORD="${machine_fields[4]:-}"
    DB_MACHINE_PORT="${machine_fields[5]:-3306}"
    DB_MACHINE_NOTES="${machine_fields[6]:-}"
  fi
}

remote_db_bootstrap_ssh_details() {
  local service_file="/etc/systemd/system/vps-mysql-tunnel.service"
  local exec_line=""
  local ssh_key=""
  local ssh_target=""

  [[ -f "${service_file}" ]] || return 1
  exec_line="$(grep -E '^ExecStart=' "${service_file}" | tail -n1 | sed 's/^ExecStart=//')"
  [[ -n "${exec_line}" ]] || return 1

  ssh_key="$(printf '%s\n' "${exec_line}" | awk '{for (i = 1; i <= NF; i++) { if ($i == "-i") { print $(i + 1); exit } }}')"
  ssh_target="$(printf '%s\n' "${exec_line}" | awk '{print $NF}')"
  [[ -n "${ssh_key}" && -n "${ssh_target}" ]] || return 1

  printf '%s\t%s\n' "${ssh_key}" "${ssh_target}"
}

ensure_db_root_hosts() {
  local machine_id="${1:-${LOCAL_DB_MACHINE_ID}}"
  local root_password=""
  local sql_file=""
  local ssh_key=""
  local ssh_target=""

  if [[ "${machine_id}" == "custom" ]]; then
    return 0
  fi

  resolve_db_machine "${machine_id}"
  root_password="${DB_MACHINE_ROOT_PASSWORD:-}"
  [[ -n "${root_password}" ]] || die "Missing root password for DB machine ${machine_id}"

  sql_file="$(mktemp)"
  cat > "${sql_file}" <<EOF
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY $(sql_quote "${root_password}");
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY $(sql_quote "${root_password}");
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED BY $(sql_quote "${root_password}");
ALTER USER 'root'@'localhost' IDENTIFIED BY $(sql_quote "${root_password}");
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'root'@'::1' IDENTIFIED BY $(sql_quote "${root_password}");
ALTER USER 'root'@'::1' IDENTIFIED BY $(sql_quote "${root_password}");
GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

  if [[ "${machine_id}" == "${LOCAL_DB_MACHINE_ID}" ]]; then
    if ! sudo -n mysql < "${sql_file}" >/dev/null 2>&1; then
      rm -f "${sql_file}"
      die "Unable to bootstrap root access on local DB machine ${machine_id}"
    fi
  else
    IFS=$'\t' read -r ssh_key ssh_target < <(remote_db_bootstrap_ssh_details) || die "Missing SSH tunnel details for remote DB bootstrap"
    [[ -n "${ssh_key}" && -n "${ssh_target}" ]] || die "Invalid SSH tunnel details for remote DB bootstrap"
    if ! ssh -i "${ssh_key}" -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new "${ssh_target}" "sudo -n env MYSQL_PWD=$(shell_quote "${root_password}") mysql --protocol=socket -uroot --batch --skip-column-names" < "${sql_file}" >/dev/null 2>&1; then
      rm -f "${sql_file}"
      die "Unable to bootstrap root access on remote DB machine ${machine_id}"
    fi
  fi

  rm -f "${sql_file}"
}

mysql_exec_machine() {
  local query="$1"
  [[ -n "${DB_MACHINE_HOST:-}" ]] || die "Missing DB machine host"
  [[ -n "${DB_MACHINE_ROOT_USER:-}" ]] || die "Missing DB machine root user"
  MYSQL_PWD="${DB_MACHINE_ROOT_PASSWORD:-}" mysql --protocol=tcp -h "${DB_MACHINE_HOST}" -P "${DB_MACHINE_PORT:-3306}" -u "${DB_MACHINE_ROOT_USER}" --batch --skip-column-names -e "${query}"
}

mysql_exec_with_details() {
  local host="$1"
  local port="$2"
  local user="$3"
  local password="$4"
  local query="$5"

  [[ -n "${host}" ]] || die "Missing MySQL host"
  [[ -n "${user}" ]] || die "Missing MySQL user"
  MYSQL_PWD="${password}" mysql --protocol=tcp -h "${host}" -P "${port:-3306}" -u "${user}" --batch --skip-column-names -e "${query}"
}

mysql_dump_with_details() {
  local host="$1"
  local port="$2"
  local user="$3"
  local password="$4"
  local db_name="$5"
  local dump_file="$6"

  [[ -n "${host}" ]] || die "Missing MySQL host for dump"
  [[ -n "${db_name}" ]] || die "Missing database name for dump"
  MYSQL_PWD="${password}" mysqldump \
    --protocol=tcp \
    -h "${host}" \
    -P "${port:-3306}" \
    -u "${user}" \
    --single-transaction \
    --skip-lock-tables \
    --routines \
    --triggers \
    --events \
    --hex-blob \
    --default-character-set=utf8mb4 \
    --add-drop-table \
    "${db_name}" > "${dump_file}"
}

mysql_import_with_details() {
  local host="$1"
  local port="$2"
  local user="$3"
  local password="$4"
  local db_name="$5"
  local dump_file="$6"

  [[ -n "${host}" ]] || die "Missing MySQL host for import"
  [[ -n "${db_name}" ]] || die "Missing database name for import"
  MYSQL_PWD="${password}" mysql \
    --protocol=tcp \
    -h "${host}" \
    -P "${port:-3306}" \
    -u "${user}" \
    --default-character-set=utf8mb4 \
    "${db_name}" < "${dump_file}"
}

migrate_mysql_database() {
  local source_host="$1"
  local source_port="$2"
  local source_user="$3"
  local source_password="$4"
  local target_host="$5"
  local target_port="$6"
  local target_user="$7"
  local target_password="$8"
  local db_name="$9"
  local source_label="${10:-source}"
  local target_label="${11:-target}"
  local dump_file=""
  local source_marker=""
  local target_marker=""

  [[ -n "${db_name}" ]] || die "Missing database name for migration"
  [[ -n "${source_host}" ]] || die "Missing source MySQL host for migration"
  [[ -n "${target_host}" ]] || die "Missing target MySQL host for migration"

  source_marker="${source_host}:${source_port:-3306}/${source_label}"
  target_marker="${target_host}:${target_port:-3306}/${target_label}"
  printf '[projectctl] migrating database %s from %s to %s\n' "${db_name}" "${source_marker}" "${target_marker}"

  dump_file="$(mktemp)"
  trap 'rm -f "'"${dump_file}"'"' RETURN

  mysql_dump_with_details "${source_host}" "${source_port:-3306}" "${source_user}" "${source_password}" "${db_name}" "${dump_file}"
  mysql_exec_with_details "${target_host}" "${target_port:-3306}" "${target_user}" "${target_password}" "CREATE DATABASE IF NOT EXISTS $(sql_ident "${db_name}") CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql_import_with_details "${target_host}" "${target_port:-3306}" "${target_user}" "${target_password}" "${db_name}" "${dump_file}"
  rm -f "${dump_file}"
  trap - RETURN
}

project_db_machine_id() {
  local machine_id=""
  machine_id="$(project_db_value DB_MACHINE_ID)"
  printf '%s' "${machine_id:-${LOCAL_DB_MACHINE_ID}}"
}

project_sidecar_ports() {
  local -a keys=(
    MYSQL_API_PORT
    VITE_REACT_PORT
    VITE_DEV_PORT
    API_PORT
    GUI_PORT
    FRONTEND_PORT
    BACKEND_PORT
    SERVER_PORT
    WEB_PORT
    ADMIN_PORT
  )
  local key=""
  local value=""
  local -a ports=()

  for key in "${keys[@]}"; do
    value="$(project_db_value "${key}")"
    [[ "${value}" =~ ^[0-9]+$ ]] || continue
    case "${value}" in
      22|80|443|3306)
        continue
        ;;
    esac
    if [[ " ${ports[*]} " != *" ${value} "* ]]; then
      ports+=("${value}")
    fi
  done

  printf '%s\n' "${ports[@]}"
}

kill_listening_pids_on_port() {
  local port="$1"
  local listeners=""
  local pid=""

  command -v ss >/dev/null 2>&1 || return 0

  listeners="$(ss -ltnp "sport = :${port}" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true)"
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    kill -TERM "${pid}" >/dev/null 2>&1 || true
  done <<< "${listeners}"

  sleep 1
  listeners="$(ss -ltnp "sport = :${port}" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true)"
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    kill -KILL "${pid}" >/dev/null 2>&1 || true
  done <<< "${listeners}"
}

cleanup_project_sidecars() {
  local port=""
  while IFS= read -r port; do
    [[ -n "${port}" ]] || continue
    kill_listening_pids_on_port "${port}"
  done < <(project_sidecar_ports)
}

sync_project_db_machine_env() {
  local machine_id="${1:-${LOCAL_DB_MACHINE_ID}}"
  local machine_host="${2:-127.0.0.1}"
  local machine_port="${3:-3306}"
  local machine_root_user="${4:-root}"
  local machine_root_password="${5:-}"
  local machine_name="${6:-}"
  local machine_notes="${7:-}"
  local env_file="${APP_DIR}/.env.machine"
  local db_type=""
  local project_env=""
  local custom_mode="no"

  touch "${env_file}"
  chmod 0600 "${env_file}"
  if [[ "${machine_id}" == "custom" ]]; then
    custom_mode="yes"
  fi
  update_meta_value "${env_file}" "DB_MACHINE_ID" "${machine_id}"
  if [[ "${custom_mode}" == "yes" ]]; then
    update_meta_value "${env_file}" "DB_MACHINE_NAME" "${machine_name}"
    update_meta_value "${env_file}" "DB_MACHINE_HOST" "${machine_host}"
    update_meta_value "${env_file}" "DB_MACHINE_PORT" "${machine_port}"
    update_meta_value "${env_file}" "DB_MACHINE_ROOT_USER" "${machine_root_user}"
    update_meta_value "${env_file}" "DB_MACHINE_ROOT_PASSWORD" "${machine_root_password}"
    update_meta_value "${env_file}" "DB_MACHINE_NOTES" "${machine_notes}"
    update_meta_value "${env_file}" "DB_HOST" "${machine_host}"
    update_meta_value "${env_file}" "DB_PORT" "${machine_port}"
    update_meta_value "${env_file}" "MYSQL_HOST" "${machine_host}"
    update_meta_value "${env_file}" "MYSQL_PORT" "${machine_port}"
  else
    [[ -n "${machine_name}" ]] && update_meta_value "${env_file}" "DB_MACHINE_NAME" "${machine_name}"
    [[ -n "${machine_host}" ]] && update_meta_value "${env_file}" "DB_MACHINE_HOST" "${machine_host}"
    [[ -n "${machine_port}" ]] && update_meta_value "${env_file}" "DB_MACHINE_PORT" "${machine_port}"
    [[ -n "${machine_root_user}" ]] && update_meta_value "${env_file}" "DB_MACHINE_ROOT_USER" "${machine_root_user}"
    [[ -n "${machine_root_password}" ]] && update_meta_value "${env_file}" "DB_MACHINE_ROOT_PASSWORD" "${machine_root_password}"
    [[ -n "${machine_notes}" ]] && update_meta_value "${env_file}" "DB_MACHINE_NOTES" "${machine_notes}"
    [[ -n "${machine_host}" ]] && update_meta_value "${env_file}" "DB_HOST" "${machine_host}"
    [[ -n "${machine_port}" ]] && update_meta_value "${env_file}" "DB_PORT" "${machine_port}"
    [[ -n "${machine_host}" ]] && update_meta_value "${env_file}" "MYSQL_HOST" "${machine_host}"
    [[ -n "${machine_port}" ]] && update_meta_value "${env_file}" "MYSQL_PORT" "${machine_port}"
  fi
  db_type="$(project_db_value DB_TYPE VITE_DB_TYPE)"
  if [[ "${db_type,,}" == "mysql" ]]; then
    if [[ "${custom_mode}" == "yes" ]]; then
      update_meta_value "${env_file}" "MYSQL_USER" "${machine_root_user}"
      update_meta_value "${env_file}" "MYSQL_PASSWORD" "${machine_root_password}"
    else
      [[ -n "${machine_root_user}" ]] && update_meta_value "${env_file}" "MYSQL_USER" "${machine_root_user}"
      [[ -n "${machine_root_password}" ]] && update_meta_value "${env_file}" "MYSQL_PASSWORD" "${machine_root_password}"
    fi
  fi

  for project_env in "${APP_DIR}/.env" "${APP_DIR}/server/.env"; do
    [[ -f "${project_env}" ]] || continue
    update_meta_value "${project_env}" "DB_MACHINE_ID" "${machine_id}"
    if [[ "${custom_mode}" == "yes" ]]; then
      update_meta_value "${project_env}" "DB_MACHINE_NAME" "${machine_name}"
      update_meta_value "${project_env}" "DB_MACHINE_HOST" "${machine_host}"
      update_meta_value "${project_env}" "DB_MACHINE_PORT" "${machine_port}"
      update_meta_value "${project_env}" "DB_MACHINE_NOTES" "${machine_notes}"
      update_meta_value "${project_env}" "DB_HOST" "${machine_host}"
      update_meta_value "${project_env}" "DB_PORT" "${machine_port}"
      update_meta_value "${project_env}" "MYSQL_HOST" "${machine_host}"
      update_meta_value "${project_env}" "MYSQL_PORT" "${machine_port}"
      update_meta_value "${project_env}" "DB_MACHINE_ROOT_USER" "${machine_root_user}"
      update_meta_value "${project_env}" "DB_MACHINE_ROOT_PASSWORD" "${machine_root_password}"
    else
      [[ -n "${machine_name}" ]] && update_meta_value "${project_env}" "DB_MACHINE_NAME" "${machine_name}"
      [[ -n "${machine_host}" ]] && update_meta_value "${project_env}" "DB_MACHINE_HOST" "${machine_host}"
      [[ -n "${machine_port}" ]] && update_meta_value "${project_env}" "DB_MACHINE_PORT" "${machine_port}"
      [[ -n "${machine_notes}" ]] && update_meta_value "${project_env}" "DB_MACHINE_NOTES" "${machine_notes}"
      [[ -n "${machine_host}" ]] && update_meta_value "${project_env}" "DB_HOST" "${machine_host}"
      [[ -n "${machine_port}" ]] && update_meta_value "${project_env}" "DB_PORT" "${machine_port}"
      [[ -n "${machine_host}" ]] && update_meta_value "${project_env}" "MYSQL_HOST" "${machine_host}"
      [[ -n "${machine_port}" ]] && update_meta_value "${project_env}" "MYSQL_PORT" "${machine_port}"
      [[ -n "${machine_root_user}" ]] && update_meta_value "${project_env}" "DB_MACHINE_ROOT_USER" "${machine_root_user}"
      [[ -n "${machine_root_password}" ]] && update_meta_value "${project_env}" "DB_MACHINE_ROOT_PASSWORD" "${machine_root_password}"
    fi
  done
}

sync_project_db_identity_env() {
  local db_name="${1:-}"
  local db_user="${2:-}"
  local db_password="${3:-}"
  local project_env=""

  for project_env in "${APP_DIR}/.env" "${APP_DIR}/server/.env"; do
    [[ -f "${project_env}" ]] || continue
    update_meta_value "${project_env}" "DB_NAME" "${db_name}"
    update_meta_value "${project_env}" "DB_DATABASE" "${db_name}"
    update_meta_value "${project_env}" "MYSQL_DATABASE" "${db_name}"
    update_meta_value "${project_env}" "DB_USER" "${db_user}"
    update_meta_value "${project_env}" "MYSQL_USER" "${db_user}"
    update_meta_value "${project_env}" "DB_PASSWORD" "${db_password}"
    update_meta_value "${project_env}" "MYSQL_PASSWORD" "${db_password}"
    normalize_env_file_shell_safe "${project_env}"
  done
}

read_project_db_machine_accounts() {
  local db_user="$1"
  local machine_id="${2:-${LOCAL_DB_MACHINE_ID}}"
  local user_q

  [[ -n "${db_user}" ]] || return 0
  resolve_db_machine "${machine_id}"
  user_q="$(sql_quote "${db_user}")"
  mysql_exec_machine "SELECT CONCAT(User, '@', Host) FROM mysql.user WHERE User=${user_q} ORDER BY Host;" 2>/dev/null || true
}

update_meta_value() {
  local meta="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { updated = 0 }
    {
      line = $0
      split(line, parts, "=")
      current = parts[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", current)
      if (current == key) {
        if (!updated) {
          print key "=" value
          updated = 1
        }
        next
      }
      print line
    }
    END {
      if (!updated) {
        print key "=" value
      }
    }
  ' "${meta}" > "${tmp}"
  mv "${tmp}" "${meta}"
  if [[ "${meta}" == /var/www/* ]]; then
    normalize_env_file_shell_safe "${meta}"
  fi
}

merge_env_file_preserving_current_values() {
  local current_file="$1"
  local new_file="$2"
  local dest_file="$3"
  local tmp
  tmp="$(mktemp)"

  if [[ ! -f "${current_file}" && ! -f "${new_file}" ]]; then
    : > "${dest_file}"
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 0
  fi

  if [[ ! -f "${current_file}" ]]; then
    cp -p "${new_file}" "${dest_file}"
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 0
  fi

  if [[ ! -f "${new_file}" ]]; then
    cp -p "${current_file}" "${dest_file}"
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 0
  fi

  python3 - "$current_file" "$new_file" "$tmp" <<'PY'
import os
import re
import sys

current_path, new_path, out_path = sys.argv[1:4]
line_re = re.compile(r'^([ \t]*)([A-Za-z_][A-Za-z0-9_]*)[ \t]*=(.*)$')

def read_lines(path):
    with open(path, 'r', encoding='utf-8', errors='surrogateescape') as handle:
        return handle.read().splitlines(True)

current_lines = read_lines(current_path)
new_lines = read_lines(new_path)
seen = set()
out = []

for line in current_lines:
    match = line_re.match(line)
    if match:
        seen.add(match.group(2))
    out.append(line)

for line in new_lines:
    match = line_re.match(line)
    if not match:
        continue
    key = match.group(2)
    if key in seen:
        continue
    seen.add(key)
    out.append(line)

with open(out_path, 'w', encoding='utf-8', errors='surrogateescape') as handle:
    handle.writelines(out)
PY
  cp -p "${tmp}" "${dest_file}"
  rm -f "${tmp}" >/dev/null 2>&1 || true
}

seed_project_env_from_templates() {
  local project_dir="${1:-${APP_DIR}}"
  local candidate=""
  local template=""
  local suffix=""
  local -a template_suffixes=(".example" ".sample" ".template" ".default")

  [[ -d "${project_dir}" ]] || return 0

  for candidate in ".env" ".env.local" ".env.production" ".env.credentials" ".env.production.local" ".env.development"; do
    template=""
    for suffix in "${template_suffixes[@]}"; do
      if [[ -f "${project_dir}/${candidate}${suffix}" ]]; then
        template="${project_dir}/${candidate}${suffix}"
        break
      fi
    done
    if [[ -z "${template}" && "${candidate}" == ".env" ]]; then
      for suffix in "${template_suffixes[@]}"; do
        if [[ -f "${project_dir}/.env${suffix}" ]]; then
          template="${project_dir}/.env${suffix}"
          break
        fi
      done
    fi
    [[ -n "${template}" ]] || continue

    if [[ -f "${project_dir}/${candidate}" ]]; then
      merge_env_file_preserving_current_values "${project_dir}/${candidate}" "${template}" "${project_dir}/${candidate}"
    else
      cp -p "${template}" "${project_dir}/${candidate}"
    fi
    normalize_env_file_shell_safe "${project_dir}/${candidate}"
  done
}

ensure_meta_dir() {
  mkdir -p "${META_DIR}"
}

ensure_auth_dir() {
  mkdir -p "${AUTH_DIR}"
}

ensure_auth_file_accessible() {
  local domain="$1"
  local auth_file=""

  [[ -n "${domain}" ]] || return 0
  auth_file="$(auth_file_for_domain "${domain}")"
  [[ -e "${auth_file}" ]] || return 0
  chown root:www-data "${auth_file}" 2>/dev/null || true
  chmod 0640 "${auth_file}" 2>/dev/null || true
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

package_script_value() {
  local script="$1"
  node -e '
    const fs = require("fs");
    const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
    const script = process.argv[1];
    process.stdout.write(pkg.scripts && pkg.scripts[script] ? String(pkg.scripts[script]) : "");
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

install_deps_in_dir() {
  local dir="$1"
  [[ -f "${dir}/package.json" ]] || return 0

  (
    cd "${dir}"
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
  )
}

install_deps() {
  if [[ ! -f package.json ]]; then
    return
  fi

  if package_has_script install:all; then
    local pm
    pm="${PACKAGE_MANAGER:-$(detect_package_manager)}"
    PACKAGE_MANAGER="${pm}"
    case "${pm}" in
      pnpm) pnpm run install:all ;;
      corepack-pnpm) corepack pnpm run install:all ;;
      yarn) yarn run install:all ;;
      corepack-yarn) corepack yarn run install:all ;;
      *) npm run install:all ;;
    esac
    return
  fi

  install_deps_in_dir "${PWD}"

  if [[ -d server && -f server/package.json ]]; then
    install_deps_in_dir "server"
  fi

  if [[ -d client && -f client/package.json ]]; then
    install_deps_in_dir "client"
  fi
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
    local start_script=""
    local prod_script=""

    if package_has_script prod; then
      prod_script="$(package_script_value prod)"
    fi

    if package_has_script start; then
      start_script="$(package_script_value start)"
      if [[ -n "${prod_script}" && "${start_script}" =~ (npm[[:space:]]+run[[:space:]]+dev|yarn[[:space:]]+dev|pnpm[[:space:]]+run[[:space:]]+dev|concurrently|vite|nodemon) ]]; then
        printf 'npm-prod'
        return
      fi
      printf 'npm-start'
      return
    fi

    if [[ -n "${prod_script}" ]]; then
      printf 'npm-prod'
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

refresh_project_start_kind() {
  local meta="$1"
  local detected=""

  [[ -n "${meta}" ]] || return 0
  [[ -f "${meta}" ]] || return 0
  [[ -d "${APP_DIR}" ]] || return 0

  detected="$(cd "${APP_DIR}" && detect_start_kind)"
  if [[ -n "${detected}" && "${detected}" != "${START_KIND:-}" ]]; then
    START_KIND="${detected}"
    START_TARGET="$(start_kind_target "${START_KIND}")"
    APP_TYPE="$(start_kind_family "${START_KIND}")"
    update_meta_value "${meta}" "START_KIND" "${START_KIND}"
    update_meta_value "${meta}" "START_TARGET" "${START_TARGET}"
    update_meta_value "${meta}" "APP_TYPE" "${APP_TYPE}"
  fi
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

is_common_reserved_port() {
  local port="$1"
  local reserved=""

  for reserved in "${COMMON_RESERVED_PORTS[@]}"; do
    [[ "${port}" == "${reserved}" ]] && return 0
  done

  return 1
}

pick_port() {
  local start="${1:-${PORT_MIN}}"
  local end="${2:-${PORT_MAX}}"
  local port
  local used
  used="$(used_ports)"

  for port in $(seq "${start}" "${end}"); do
    if is_common_reserved_port "${port}"; then
      continue
    fi
    if ! printf '%s\n' "${used}" | grep -qx "${port}"; then
      printf '%s' "${port}"
      return
    fi
  done

  die "No free port found in range ${start}-${end}"
}

project_has_split_runtime() {
  local key=""
  for key in GUI_PORT GUI_API_BASE_URL CONNECTOR_PORT CONNECTOR_TARGET_URL; do
    if [[ -n "$(project_db_value "${key}")" ]]; then
      return 0
    fi
  done
  return 1
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
DB_MACHINE_ID=${DB_MACHINE_ID:-${LOCAL_DB_MACHINE_ID}}
MYSQL_ALLOWED_IPS=${MYSQL_ALLOWED_IPS:-}
SSH_UPLOAD_USER=${SSH_UPLOAD_USER:-}
SSH_UPLOAD_PASSWORD=${SSH_UPLOAD_PASSWORD:-}
EOF
}

sync_project_runtime_ports() {
  local port="$1"
  local project_dir="${2:-${APP_DIR}}"
  local candidate=""
  local subdir=""
  local env_file=""
  local split_runtime=0

  [[ -n "${port}" ]] || return 0
  [[ -d "${project_dir}" ]] || return 0
  if project_has_split_runtime; then
    split_runtime=1
  fi

  env_file="${project_dir}/.env"
  touch "${env_file}"
  chmod 0600 "${env_file}"
  if [[ "${split_runtime}" -eq 0 ]]; then
    update_meta_value "${env_file}" "PORT" "${port}"
  fi
  update_meta_value "${env_file}" "APP_PORT" "${port}"
  normalize_env_file_shell_safe "${env_file}"

  for candidate in .env.local .env.production .env.credentials .env.production.local .env.development; do
    env_file="${project_dir}/${candidate}"
    [[ -f "${env_file}" ]] || continue
    if [[ "${split_runtime}" -eq 0 ]]; then
      update_meta_value "${env_file}" "PORT" "${port}"
    fi
    update_meta_value "${env_file}" "APP_PORT" "${port}"
    normalize_env_file_shell_safe "${env_file}"
  done

  for subdir in server client; do
    [[ -d "${project_dir}/${subdir}" ]] || continue
    for candidate in .env .env.local .env.production .env.credentials .env.production.local .env.development; do
      env_file="${project_dir}/${subdir}/${candidate}"
      [[ -f "${env_file}" ]] || continue
      if [[ "${split_runtime}" -eq 0 ]]; then
        update_meta_value "${env_file}" "PORT" "${port}"
      fi
      update_meta_value "${env_file}" "APP_PORT" "${port}"
      normalize_env_file_shell_safe "${env_file}"
    done
  done
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
    ensure_auth_file_accessible "${APP_DOMAIN}"
    app_map_upsert "${APP_DOMAIN}" "${APP_PORT}" "${APP_TYPE:-project}" "${APP_HTTPS:-yes}"
    if [[ -x /usr/local/bin/app-sync.sh ]]; then
      /usr/local/bin/app-sync.sh
    fi
  fi
}

verify_https_vhost() {
  local domain="${1:-}"
  local https="${2:-yes}"
  local conf=""
  local cert=""

  [[ "${https,,}" == "yes" ]] || return 0
  [[ -n "${domain}" ]] || return 0

  conf="/etc/nginx/sites-available/${domain}.conf"
  cert="/etc/letsencrypt/live/${domain}/fullchain.pem"

  if [[ -s "${conf}" ]] && [[ -s "${cert}" ]] && grep -q 'listen 443 ssl' "${conf}"; then
    return 0
  fi

  if [[ -x /usr/local/bin/app-sync.sh ]]; then
    /usr/local/bin/app-sync.sh
  fi

  if [[ ! -s "${conf}" ]] || [[ ! -s "${cert}" ]] || ! grep -q 'listen 443 ssl' "${conf}"; then
    printf '[projectctl] Warning: HTTPS was requested for %s, but the SSL vhost is not active yet. The project will remain available over HTTP until DNS and certificate provisioning finish. Re-run app sync after the domain resolves to this VPS.\n' "${domain}" >&2
  fi
}

auth_file_for_domain() {
  local domain="$1"
  printf '%s/%s.htpasswd' "${AUTH_DIR}" "${domain}"
}

ssh_upload_meta_path() {
  printf '%s/%s.conf' "/etc/ssh/sshd_config.d" "99-vps-project-uploads"
}

ensure_acl_tools() {
  command -v setfacl >/dev/null 2>&1 || die "acl package is required (setfacl missing)"
}

ensure_project_ssh_acl() {
  local app_dir="$1"
  local user="$2"
  local dir=""
  local acl_spec="u:${user}:rwX"
  local default_acl_spec="d:u:${user}:rwX"

  ensure_acl_tools
  [[ -d "${app_dir}" ]] || return 0

  setfacl -R -m "${acl_spec}" "${app_dir}"
  while IFS= read -r -d '' dir; do
    setfacl -m "${default_acl_spec}" "${dir}"
  done < <(find "${app_dir}" -type d -print0)
}

refresh_project_ssh_config() {
  local conf
  local meta
  local blocks=()
  local user=""

  conf="$(ssh_upload_meta_path)"
  mkdir -p "$(dirname "${conf}")"

  while IFS= read -r meta; do
    [[ -e "${meta}" ]] || continue
    # shellcheck disable=SC1090
    source "${meta}"
    user="${SSH_UPLOAD_USER:-}"
    [[ -n "${user}" ]] || continue
    blocks+=("Match User ${user}"$'\n'"  PasswordAuthentication yes"$'\n'"  KbdInteractiveAuthentication no"$'\n'"  PubkeyAuthentication no"$'\n'"  AllowTcpForwarding no"$'\n'"  X11Forwarding no"$'\n'"  PermitTTY no"$'\n'"  ForceCommand internal-sftp")
  done < <(find "${META_DIR}" -maxdepth 1 -name '*.env' -print | sort)

  {
    printf '# generated by projectctl\n'
    printf '# project upload users use SFTP over password auth only\n'
    if [[ ${#blocks[@]} -gt 0 ]]; then
      printf '%s\n' "${blocks[@]}"
    fi
  } > "${conf}"

  systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
}

ensure_project_ssh_user() {
  local user="$1"
  local password="$2"
  local app_dir="$3"

  [[ -n "${user}" ]] || die "Missing SSH upload user"
  [[ -n "${password}" ]] || die "Missing SSH upload password"
  [[ -n "${app_dir}" ]] || die "Missing project directory for SSH upload user"

  if ! id -u "${user}" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" --home "${app_dir}" --shell /bin/bash --no-create-home "${user}" >/dev/null
  else
    usermod -d "${app_dir}" -s /bin/bash "${user}" >/dev/null 2>&1 || true
  fi

  printf '%s:%s\n' "${user}" "${password}" | chpasswd
  ensure_project_ssh_acl "${app_dir}" "${user}"
}

remove_project_ssh_user() {
  local user="$1"
  if [[ -z "${user}" ]]; then
    return 0
  fi
  if id -u "${user}" >/dev/null 2>&1; then
    userdel "${user}" >/dev/null 2>&1 || true
  fi
  if getent group "${user}" >/dev/null 2>&1; then
    groupdel "${user}" >/dev/null 2>&1 || true
  fi
}

show_project_ssh_details() {
  local ref="$1"
  local slug
  local meta
  local ssh_user
  local ssh_password
  local ssh_host=""

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"
  ssh_user="${SSH_UPLOAD_USER:-}"
  ssh_password="${SSH_UPLOAD_PASSWORD:-}"
  if [[ -s /etc/vps-system-domain ]]; then
    ssh_host="$(tr -d '\r\n' < /etc/vps-system-domain)"
  fi
  if [[ -z "${ssh_host}" ]]; then
    ssh_host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'server')"
  fi

  printf 'repo: %s\npath: %s\nuser: %s\npassword: %s\nhome: %s\nhost: %s\nport: %s\nmode: sftp-only\n' \
    "${REPO_REF}" "${APP_DIR}" \
    "${ssh_user}" \
    "${ssh_password}" \
    "${APP_DIR}" \
    "${SSH_UPLOAD_HOST:-${ssh_host}}" \
    "22"
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

package_json_has_script_in_dir() {
  local project_dir="$1"
  local script="$2"

  [[ -f "${project_dir}/package.json" ]] || return 1
  node -e '
    const fs = require("fs");
    const projectDir = process.argv[1];
    const scriptName = process.argv[2];
    try {
      const pkg = JSON.parse(fs.readFileSync(`${projectDir}/package.json`, "utf8"));
      process.exit(pkg && pkg.scripts && Object.prototype.hasOwnProperty.call(pkg.scripts, scriptName) ? 0 : 1);
    } catch {
      process.exit(1);
    }
  ' "${project_dir}" "${script}"
}

run_package_script_in_dir() {
  local project_dir="$1"
  local script="$2"

  (
    cd "${project_dir}"
    PACKAGE_MANAGER="$(detect_package_manager)"
    /bin/bash -lc 'set -a; [ -f .env ] && . ./.env; [ -f .env.machine ] && . ./.env.machine; set +a; '"$(package_script_runner "${script}")"
  )
}

run_install_db_scripts() {
  local project_dir="${1:-${APP_DIR}}"
  local script
  local script_dir
  declare -A seen_scripts=()

  [[ -d "${project_dir}" ]] || return 0
  for script in db:init db:seed; do
    for script_dir in "" "server" "client"; do
      [[ -z "${seen_scripts[$script]:-}" ]] || break
      if [[ -n "${script_dir}" ]]; then
        [[ -d "${project_dir}/${script_dir}" ]] || continue
        if ! package_json_has_script_in_dir "${project_dir}/${script_dir}" "${script}"; then
          continue
        fi
        printf '[projectctl] running %s in %s/%s\n' "${script}" "${project_dir}" "${script_dir}"
        run_package_script_in_dir "${project_dir}/${script_dir}" "${script}"
      else
        if ! package_json_has_script_in_dir "${project_dir}" "${script}"; then
          continue
        fi
        printf '[projectctl] running %s in %s\n' "${script}" "${project_dir}"
        run_package_script_in_dir "${project_dir}" "${script}"
      fi
      seen_scripts["${script}"]=1
      break
    done
  done
}

clone_or_pull() {
  if [[ -d "${APP_DIR}/.git" ]]; then
    pull_repo_with_optional_stash "${APP_DIR}" "${BRANCH}" "${REPO_URL}"
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
      ecosystem:*)
        start_with_env pm2 start "${START_TARGET}" --name "${PM2_NAME}" --update-env --time
        ;;
      npm-prod)
        case "${PACKAGE_MANAGER:-npm}" in
          pnpm) start_with_env env PORT="${APP_PORT}" pm2 start pnpm --name "${PM2_NAME}" --time -- prod ;;
          corepack-pnpm) start_with_env env PORT="${APP_PORT}" pm2 start corepack --name "${PM2_NAME}" --time -- pnpm run prod ;;
          yarn) start_with_env env PORT="${APP_PORT}" pm2 start yarn --name "${PM2_NAME}" --time -- prod ;;
          corepack-yarn) start_with_env env PORT="${APP_PORT}" pm2 start corepack --name "${PM2_NAME}" --time -- yarn prod ;;
          *) start_with_env env PORT="${APP_PORT}" pm2 start npm --name "${PM2_NAME}" --time -- run prod ;;
        esac
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
  cleanup_project_sidecars
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
  local db_machine_id="${7:-}"
  local env_file="${8:-}"
  local entrypoint="${9:-}"

  REPO_REF="$(repo_ref_from_arg "${ref}")"
  REPO_URL="$(repo_url_from_ref "${REPO_REF}")"
  PROJECT_SLUG="$(slug_from_ref "${REPO_REF}")"
  APP_DIR="${APP_ROOT}/${PROJECT_SLUG}"
  local meta
  meta="$(meta_path_for_slug "${PROJECT_SLUG}")"
  BRANCH="$(branch_from_repo "${REPO_REF}" "${branch}")"
  PM2_NAME="${pm2_name:-${PROJECT_SLUG}}"
  APP_PORT="${forced_port:-$(pick_port)}"
  APP_DOMAIN="${domain:-}"
  APP_HTTPS="${https:-yes}"
  APP_TYPE="project"
  GIT_REMOTE="origin"
  SSH_UPLOAD_USER="$(ssh_upload_user_from_slug "${PROJECT_SLUG}")"
  SSH_UPLOAD_PASSWORD="$(generate_secret)"
  DB_MACHINE_ID="${db_machine_id:-${LOCAL_DB_MACHINE_ID}}"

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

  seed_project_env_from_templates "${APP_DIR}"
  sync_project_runtime_ports "${APP_PORT}" "${APP_DIR}"
  local db_name=""
  local db_user=""
  local db_password=""
  local db_type=""
  local custom_db_machine=0
  IFS=$'\t' read -r db_name db_user db_password db_type < <(sync_project_db_env "${APP_DIR}")
  normalize_project_deployment_env_file "${APP_DIR}/.env"
  normalize_project_deployment_env_file "${APP_DIR}/server/.env"
  normalize_project_deployment_env_file "${APP_DIR}/client/.env"
  if [[ "${DB_MACHINE_ID}" == "custom" ]]; then
    custom_db_machine=1
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

  if [[ "${custom_db_machine}" -eq 0 ]]; then
    resolve_db_machine "${DB_MACHINE_ID}"
    write_meta "${meta}"
    chmod 0644 "${meta}"
    sync_project_db_machine_env "${DB_MACHINE_ID}" "${DB_MACHINE_HOST}" "${DB_MACHINE_PORT}" "${DB_MACHINE_ROOT_USER}" "${DB_MACHINE_ROOT_PASSWORD}" "${DB_MACHINE_NAME}" "${DB_MACHINE_NOTES}"
  else
    write_meta "${meta}"
    chmod 0644 "${meta}"
    sync_project_db_machine_env "custom" "" "" "" "" "Custom / manual DB machine" "Configure DB host and credentials in MySQL Access after install"
  fi

  (
    cd "${APP_DIR}"
    install_deps
    maybe_build
  )

  if [[ "${custom_db_machine}" -eq 0 ]]; then
    if [[ -n "${db_name}" && -n "${db_user}" && -n "${db_password}" ]]; then
      sync_mysql_permissions "${db_name}" "${db_user}" "${db_password}" "${MYSQL_ALLOWED_IPS:-}" "" "${DB_MACHINE_ID}"
    fi
    run_install_db_scripts "${APP_DIR}"
  else
    printf '[projectctl] custom DB machine selected for %s; skipping automatic DB bootstrap until MySQL Access is filled in.\n' "${REPO_REF}"
  fi

  ensure_project_ssh_user "${SSH_UPLOAD_USER}" "${SSH_UPLOAD_PASSWORD}" "${APP_DIR}"
  refresh_project_ssh_config

  sync_app_map
  verify_https_vhost "${APP_DOMAIN:-}" "${APP_HTTPS:-yes}"
  restart_pm2
  if [[ -n "${APP_DOMAIN}" ]]; then
    printf '[projectctl] installed %s in %s on port %s for %s\n' "${REPO_REF}" "${APP_DIR}" "${APP_PORT}" "${APP_DOMAIN}"
  else
    printf '[projectctl] installed %s in %s on port %s\n' "${REPO_REF}" "${APP_DIR}" "${APP_PORT}"
  fi
  printf '[projectctl] ssh upload user: %s\n' "${SSH_UPLOAD_USER}"
  printf '[projectctl] ssh upload password: %s\n' "${SSH_UPLOAD_PASSWORD}"
}

do_update() {
  local ref="$1"
  local slug
  local meta
  local db_name=""
  local db_user=""
  local db_password=""
  local db_type=""

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"
  if [[ -z "${DB_MACHINE_ID:-}" ]]; then
    DB_MACHINE_ID="$(project_db_machine_id)"
  fi
  if [[ "${DB_MACHINE_ID}" == "custom" ]]; then
    if project_custom_db_machine_details >/dev/null 2>&1; then
      resolve_db_machine "${DB_MACHINE_ID}"
      sync_project_db_machine_env "${DB_MACHINE_ID}" "${DB_MACHINE_HOST}" "${DB_MACHINE_PORT}" "${DB_MACHINE_ROOT_USER}" "${DB_MACHINE_ROOT_PASSWORD}" "${DB_MACHINE_NAME}" "${DB_MACHINE_NOTES}"
    else
      sync_project_db_machine_env "custom" "" "" "" "" "Custom / manual DB machine" "Configure DB host and credentials in MySQL Access"
    fi
  else
    resolve_db_machine "${DB_MACHINE_ID:-${LOCAL_DB_MACHINE_ID}}"
    sync_project_db_machine_env "${DB_MACHINE_ID}" "${DB_MACHINE_HOST}" "${DB_MACHINE_PORT}" "${DB_MACHINE_ROOT_USER}" "${DB_MACHINE_ROOT_PASSWORD}" "${DB_MACHINE_NAME}" "${DB_MACHINE_NOTES}"
  fi

  [[ -d "${APP_DIR}/.git" ]] || die "Missing git repo at ${APP_DIR}"
  IFS=$'\t' read -r db_name db_user db_password db_type < <(sync_project_db_env "${APP_DIR}")

  (
    cd "${APP_DIR}"
    pull_repo_with_optional_stash "${APP_DIR}" "${BRANCH}" "${REPO_URL}"
    seed_project_env_from_templates "${APP_DIR}"
    sync_project_runtime_ports "${APP_PORT}" "${APP_DIR}"
    normalize_project_deployment_env_file "${APP_DIR}/.env"
    normalize_project_deployment_env_file "${APP_DIR}/server/.env"
    normalize_project_deployment_env_file "${APP_DIR}/client/.env"
    install_deps
    maybe_build
  )

  if [[ "${DB_MACHINE_ID}" != "custom" && -n "${db_name}" && -n "${db_user}" && -n "${db_password}" ]]; then
    sync_mysql_permissions "${db_name}" "${db_user}" "${db_password}" "${MYSQL_ALLOWED_IPS:-}" "${MYSQL_ALLOWED_IPS:-}" "${DB_MACHINE_ID}"
  fi
  refresh_project_start_kind "${meta}"

  if [[ -z "${SSH_UPLOAD_USER:-}" ]]; then
    SSH_UPLOAD_USER="$(ssh_upload_user_from_slug "${PROJECT_SLUG}")"
  fi
  if [[ -z "${SSH_UPLOAD_PASSWORD:-}" ]]; then
    SSH_UPLOAD_PASSWORD="$(generate_secret)"
  fi
  update_meta_value "${meta}" "SSH_UPLOAD_USER" "${SSH_UPLOAD_USER}"
  update_meta_value "${meta}" "SSH_UPLOAD_PASSWORD" "${SSH_UPLOAD_PASSWORD}"
  ensure_project_ssh_user "${SSH_UPLOAD_USER}" "${SSH_UPLOAD_PASSWORD}" "${APP_DIR}"
  refresh_project_ssh_config

  sync_app_map
  verify_https_vhost "${APP_DOMAIN:-}" "${APP_HTTPS:-yes}"
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
  if [[ -z "${DB_MACHINE_ID:-}" ]]; then
    DB_MACHINE_ID="$(project_db_machine_id)"
  fi

  printf 'repo: %s\npath: %s\npm2: %s\nport: %s\ndomain: %s\nhttps: %s\nkind: %s\n' \
    "${REPO_REF}" "${APP_DIR}" "${PM2_NAME}" "${APP_PORT}" "${APP_DOMAIN:-}" "${APP_HTTPS:-yes}" "${START_KIND}"
  printf 'protected: %s\n' "$(project_auth_enabled "${APP_DOMAIN:-}" && printf yes || printf no)"
  printf 'mysql_allowed_ips: %s\n' "${MYSQL_ALLOWED_IPS:-}"
  printf 'db_machine_id: %s\n' "${DB_MACHINE_ID:-${LOCAL_DB_MACHINE_ID}}"
  printf 'ssh_user: %s\n' "${SSH_UPLOAD_USER:-}"
  printf 'db: %s\nuser: %s\n' "${db_name}" "${db_user}"
  (cd "${APP_DIR}" && git status -sb) || true
  pm2 describe "${PM2_NAME}" || true
}

do_ssh() {
  local ref="$1"
  local password="${2:-}"
  local generate="${3:-no}"
  local slug
  local meta

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"

  if [[ -z "${SSH_UPLOAD_USER:-}" ]]; then
    SSH_UPLOAD_USER="$(ssh_upload_user_from_slug "${PROJECT_SLUG}")"
  fi
  if [[ "${generate}" == "yes" || -z "${SSH_UPLOAD_PASSWORD:-}" ]]; then
    SSH_UPLOAD_PASSWORD="$(generate_secret)"
    update_meta_value "${meta}" "SSH_UPLOAD_USER" "${SSH_UPLOAD_USER}"
    update_meta_value "${meta}" "SSH_UPLOAD_PASSWORD" "${SSH_UPLOAD_PASSWORD}"
  fi
  if [[ -n "${password}" ]]; then
    SSH_UPLOAD_PASSWORD="${password}"
    update_meta_value "${meta}" "SSH_UPLOAD_PASSWORD" "${SSH_UPLOAD_PASSWORD}"
  fi

  ensure_project_ssh_user "${SSH_UPLOAD_USER}" "${SSH_UPLOAD_PASSWORD}" "${APP_DIR}"
  refresh_project_ssh_config
  show_project_ssh_details "${ref}"
}

do_script() {
  local ref="$1"
  local script="$2"
  local pm2_mode="${3:-no}"
  local script_dir="${4:-}"
  local slug
  local meta
  local runner
  local pm2_script_name
  local pm2_script_suffix="${script}"
  local script_path=""

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"

  [[ -d "${APP_DIR}" ]] || die "Missing app directory: ${APP_DIR}"
  script_path="${APP_DIR}"
  [[ -n "${script}" ]] || die "Missing package script name"
  [[ "${script}" =~ ^[A-Za-z0-9:_-]+$ ]] || die "Invalid script name: ${script}"
  if [[ -n "${script_dir}" ]]; then
    [[ "${script_dir}" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid script directory: ${script_dir}"
    [[ "${script_dir}" != *".."* ]] || die "Invalid script directory: ${script_dir}"
    script_path="${APP_DIR}/${script_dir}"
    [[ -d "${script_path}" ]] || die "Missing script directory: ${script_dir}"
    PACKAGE_MANAGER="$(cd "${script_path}" && detect_package_manager)"
    pm2_script_suffix="${script_dir//\//-}-${script}"
  else
    PACKAGE_MANAGER="${PACKAGE_MANAGER:-$(cd "${APP_DIR}" && detect_package_manager)}"
  fi

  runner="$(package_script_runner "${script}")"
  pm2_script_name="${PM2_NAME}-${pm2_script_suffix}"

  if [[ "${pm2_mode}" == "yes" ]]; then
    (
      cd "${script_path}"
      pm2 delete "${pm2_script_name}" >/dev/null 2>&1 || true
      env TZ=Asia/Jerusalem PORT="${APP_PORT}" pm2 start /bin/bash --name "${pm2_script_name}" --no-autorestart --time -- -lc 'set -a; [ -f .env ] && . ./.env; [ -f .env.machine ] && . ./.env.machine; set +a; '"${runner}"'; exit $?'
    )
    pm2 save
    printf '[projectctl] activated %s script %s as %s\n' "${REPO_REF}" "${script}" "${pm2_script_name}"
    return
  fi

  (
    cd "${script_path}"
    /bin/bash -lc 'set -a; [ -f .env ] && . ./.env; [ -f .env.machine ] && . ./.env.machine; set +a; '"${runner}"'; exit $?'
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
  chown root:www-data "${auth_file}" 2>/dev/null || true
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
  local machine_id="${6:-${LOCAL_DB_MACHINE_ID}}"
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
  resolve_db_machine "${machine_id}"
  ensure_db_root_hosts "${machine_id}"
  mysql_exec_machine "SELECT 1;"

  if [[ -n "${new_ips}" ]]; then
    IFS=, read -r -a desired_list <<< "${new_ips}"
  fi

  desired["localhost"]=1
  desired["127.0.0.1"]=1
  desired["::1"]=1
  mysql_exec_machine "CREATE DATABASE IF NOT EXISTS ${db_ident} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  for host in localhost 127.0.0.1 ::1; do
    mysql_exec_machine "CREATE USER IF NOT EXISTS ${user_q}@$(sql_quote "${host}") IDENTIFIED BY ${pass_q};"
    mysql_exec_machine "ALTER USER ${user_q}@$(sql_quote "${host}") IDENTIFIED BY ${pass_q};"
    mysql_exec_machine "GRANT ALL PRIVILEGES ON ${db_ident}.* TO ${user_q}@$(sql_quote "${host}");"
  done

  if [[ -n "${new_ips}" ]]; then
    desired["%"]=1
    mysql_exec_machine "CREATE USER IF NOT EXISTS ${user_q}@'%' IDENTIFIED BY ${pass_q};"
    mysql_exec_machine "ALTER USER ${user_q}@'%' IDENTIFIED BY ${pass_q};"
    mysql_exec_machine "GRANT ALL PRIVILEGES ON ${db_ident}.* TO ${user_q}@'%';"
  fi

  current_hosts="$(mysql_exec_machine "SELECT Host FROM mysql.user WHERE User=${user_q};" 2>/dev/null || true)"
  while IFS= read -r host; do
    [[ -n "${host}" ]] || continue
    if [[ -z "${desired[$host]:-}" ]]; then
      mysql_exec_machine "DROP USER IF EXISTS ${user_q}@$(sql_quote "${host}");" >/dev/null 2>&1 || true
    fi
  done <<< "${current_hosts}"

  mysql_exec_machine "FLUSH PRIVILEGES;"
  sync_mysql_firewall_rules "${new_ips}" "${old_ips}"
}

read_mysql_accounts() {
  local db_user="$1"
  local machine_id="${2:-${LOCAL_DB_MACHINE_ID}}"
  local user_q

  [[ -n "${db_user}" ]] || return 0
  resolve_db_machine "${machine_id}"
  user_q="$(sql_quote "${db_user}")"
  mysql_exec_machine "SELECT CONCAT(User, '@', Host) FROM mysql.user WHERE User=${user_q} ORDER BY Host;" 2>/dev/null || true
}

do_mysql() {
  local ref="$1"
  local ips="${2-__unset__}"
  local machine_id="${3:-__unset__}"
  local machine_name="${4-__unset__}"
  local machine_host="${5-__unset__}"
  local machine_port="${6-__unset__}"
  local machine_root_user="${7-__unset__}"
  local machine_root_password="${8-__unset__}"
  local machine_notes="${9-__unset__}"
  local db_name_override="${10:-__unset__}"
  local db_user_override="${11:-__unset__}"
  local db_password_override="${12:-__unset__}"
  local move_data="${13:-no}"
  local slug
  local meta
  local old_ips
  local new_ips
  local db_name
  local db_user
  local db_password
  local custom_db_name
  local custom_db_user
  local custom_db_password
  local source_machine_id
  local source_machine_name
  local source_machine_host
  local source_machine_port
  local source_machine_root_user
  local source_machine_root_password
  local source_machine_notes
  local active_machine_id
  local active_machine_host
  local active_machine_port
  local active_machine_name
  local active_machine_root_user
  local active_machine_root_password
  local active_machine_notes
  local current_machine_id
  local mutate="no"
  local custom_requested="no"
  local custom_machine_name=""
  local custom_machine_host=""
  local custom_machine_port=""
  local custom_machine_root_user=""
  local custom_machine_root_password=""
  local custom_machine_notes=""

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"
  source_machine_id="$(project_db_machine_id)"
  resolve_db_machine "${source_machine_id}"
  source_machine_name="${DB_MACHINE_NAME}"
  source_machine_host="${DB_MACHINE_HOST}"
  source_machine_port="${DB_MACHINE_PORT}"
  source_machine_root_user="${DB_MACHINE_ROOT_USER}"
  source_machine_root_password="${DB_MACHINE_ROOT_PASSWORD}"
  source_machine_notes="${DB_MACHINE_NOTES}"
  custom_db_name="$(project_db_value DB_NAME DB_DATABASE MYSQL_DATABASE POSTGRES_DB)"
  custom_db_user="$(project_db_value DB_USER MYSQL_USER POSTGRES_USER)"
  custom_db_password="$(project_db_value DB_PASSWORD MYSQL_PASSWORD POSTGRES_PASSWORD)"
  if [[ "${db_name_override}" != "__unset__" ]]; then
    custom_db_name="${db_name_override}"
  fi
  if [[ "${db_user_override}" != "__unset__" ]]; then
    custom_db_user="${db_user_override}"
  fi
  if [[ "${db_password_override}" != "__unset__" ]]; then
    custom_db_password="${db_password_override}"
  fi

  if [[ "${machine_name}" != "__unset__" || "${machine_host}" != "__unset__" || "${machine_port}" != "__unset__" || "${machine_root_user}" != "__unset__" || "${machine_root_password}" != "__unset__" || "${machine_notes}" != "__unset__" ]]; then
    custom_requested="yes"
  fi

  old_ips="${MYSQL_ALLOWED_IPS:-}"
  current_machine_id="${source_machine_id}"
  active_machine_id="${current_machine_id}"
  if [[ "${machine_id}" != "__unset__" && -n "${machine_id}" ]]; then
    active_machine_id="${machine_id}"
    if [[ "${active_machine_id}" != "${current_machine_id}" ]]; then
      mutate="yes"
    fi
  fi
  if [[ "${ips}" != "__unset__" ]]; then
    mutate="yes"
  fi
  if [[ "${move_data}" == "yes" ]]; then
    mutate="yes"
  fi

  if [[ "${custom_requested}" == "yes" ]]; then
    active_machine_id="custom"
    mutate="yes"
    custom_machine_name="${machine_name}"
    custom_machine_host="${machine_host}"
    custom_machine_port="${machine_port}"
    custom_machine_root_user="${machine_root_user}"
    custom_machine_root_password="${machine_root_password}"
    custom_machine_notes="${machine_notes}"
    [[ "${custom_machine_name}" != "__unset__" ]] || custom_machine_name="$(project_db_value DB_MACHINE_NAME)"
    [[ "${custom_machine_host}" != "__unset__" ]] || custom_machine_host="$(project_db_value DB_MACHINE_HOST DB_HOST MYSQL_HOST POSTGRES_HOST)"
    [[ "${custom_machine_port}" != "__unset__" ]] || custom_machine_port="$(project_db_value DB_MACHINE_PORT DB_PORT MYSQL_PORT POSTGRES_PORT)"
    [[ "${custom_machine_root_user}" != "__unset__" ]] || custom_machine_root_user="$(project_db_value DB_MACHINE_ROOT_USER)"
    [[ "${custom_machine_root_password}" != "__unset__" ]] || custom_machine_root_password="$(project_db_value DB_MACHINE_ROOT_PASSWORD)"
    [[ "${custom_machine_notes}" != "__unset__" ]] || custom_machine_notes="$(project_db_value DB_MACHINE_NOTES)"
    [[ -n "${custom_machine_name}" ]] || custom_machine_name="custom"
    [[ -n "${custom_machine_host}" ]] || die "Missing custom DB machine host"
    [[ -n "${custom_machine_port}" ]] || custom_machine_port="3306"
    [[ -n "${custom_machine_root_user}" ]] || custom_machine_root_user="root"
    sync_project_db_machine_env "${active_machine_id}" "${custom_machine_host}" "${custom_machine_port}" "${custom_machine_root_user}" "${custom_machine_root_password}" "${custom_machine_name}" "${custom_machine_notes}"
    sync_project_db_identity_env "${custom_db_name}" "${custom_db_user}" "${custom_db_password}"
  fi

  if [[ "${move_data}" == "yes" && "${source_machine_id}" != "${active_machine_id}" ]]; then
    resolve_db_machine "${active_machine_id}"
    active_machine_name="${DB_MACHINE_NAME}"
    active_machine_host="${DB_MACHINE_HOST}"
    active_machine_port="${DB_MACHINE_PORT}"
    active_machine_root_user="${DB_MACHINE_ROOT_USER}"
    active_machine_root_password="${DB_MACHINE_ROOT_PASSWORD}"
    active_machine_notes="${DB_MACHINE_NOTES}"
  fi

  if [[ "${mutate}" != "yes" ]]; then
    db_name="$(project_db_value DB_NAME DB_DATABASE MYSQL_DATABASE POSTGRES_DB)"
    db_user="$(project_db_value DB_USER MYSQL_USER POSTGRES_USER)"
    db_password="$(project_db_value DB_PASSWORD MYSQL_PASSWORD POSTGRES_PASSWORD)"
    resolve_db_machine "${active_machine_id}"
    active_machine_name="${DB_MACHINE_NAME}"
    active_machine_host="${DB_MACHINE_HOST}"
    active_machine_port="${DB_MACHINE_PORT}"
    active_machine_root_user="${DB_MACHINE_ROOT_USER}"
    active_machine_root_password="${DB_MACHINE_ROOT_PASSWORD}"
    active_machine_notes="${DB_MACHINE_NOTES}"
    printf 'repo: %s\npath: %s\ndb: %s\nuser: %s\npassword: %s\nallowed_ips: %s\n' \
      "${REPO_REF}" "${APP_DIR}" \
      "${db_name}" \
      "${db_user}" \
      "${db_password}" \
      "${MYSQL_ALLOWED_IPS:-}"
    printf 'db_machine: %s\n' "${active_machine_name}"
    printf 'db_machine_id: %s\n' "${active_machine_id}"
    printf 'db_machine_host: %s\n' "${active_machine_host}"
    printf 'db_machine_port: %s\n' "${active_machine_port}"
    printf 'db_machine_root_user: %s\n' "${active_machine_root_user}"
    printf 'db_machine_root_password: %s\n' "${active_machine_root_password}"
    printf 'db_machine_notes: %s\n' "${active_machine_notes}"
    if [[ -n "${db_user}" ]]; then
      printf 'mysql_accounts:\n%s\n' "$(read_mysql_accounts "${db_user}" "${active_machine_id}")"
    fi
    return
  fi

  if [[ "${ips}" == "__unset__" ]]; then
    new_ips="${old_ips}"
  else
    new_ips="$(normalize_mysql_ips "${ips}")"
  fi
  db_name="$(project_db_value DB_NAME DB_DATABASE MYSQL_DATABASE POSTGRES_DB)"
  db_user="$(project_db_value DB_USER MYSQL_USER POSTGRES_USER)"
  db_password="$(project_db_value DB_PASSWORD MYSQL_PASSWORD POSTGRES_PASSWORD)"

  MYSQL_ALLOWED_IPS="${new_ips}"
  if [[ "${move_data}" == "yes" && "${source_machine_id}" != "${active_machine_id}" ]]; then
    if [[ "${source_machine_host}" =~ ^(localhost|127\.0\.0\.1|::1)$ && -z "${source_machine_root_password}" ]]; then
      source_machine_root_password="$(db_machine_record "${LOCAL_DB_MACHINE_ID}" "rootPassword" 2>/dev/null || true)"
    fi
    if [[ "${active_machine_host}" =~ ^(localhost|127\.0\.0\.1|::1)$ && -z "${active_machine_root_password}" ]]; then
      active_machine_root_password="$(db_machine_record "${LOCAL_DB_MACHINE_ID}" "rootPassword" 2>/dev/null || true)"
    fi
    if [[ -z "${db_name}" ]]; then
      die "Missing database name in project env"
    fi
    if [[ -z "${source_machine_host}" ]]; then
      die "Missing source DB machine host"
    fi
    if [[ -z "${source_machine_root_user}" ]]; then
      die "Missing source DB machine root user"
    fi
    if [[ -z "${source_machine_root_password}" ]]; then
      die "Missing source DB machine root password"
    fi
    if [[ -z "${active_machine_host}" ]]; then
      die "Missing target DB machine host"
    fi
    if [[ -z "${active_machine_root_user}" ]]; then
      die "Missing target DB machine root user"
    fi
    if [[ -z "${active_machine_root_password}" && ! "${active_machine_host}" =~ ^(localhost|127\.0\.0\.1|::1)$ ]]; then
      die "Missing target DB machine root password"
    fi
    migrate_mysql_database "${source_machine_host}" "${source_machine_port}" "${source_machine_root_user}" "${source_machine_root_password}" "${active_machine_host}" "${active_machine_port}" "${active_machine_root_user}" "${active_machine_root_password}" "${db_name}" "${source_machine_name:-${source_machine_id}}" "${active_machine_name:-${active_machine_id}}"
  fi

  local should_sync_permissions="yes"
  if [[ "${custom_requested}" == "yes" && "${move_data}" != "yes" && -z "${custom_machine_root_password}" ]]; then
    should_sync_permissions="no"
  fi

  if [[ "${custom_requested}" != "yes" ]]; then
    resolve_db_machine "${active_machine_id}"
    sync_project_db_machine_env "${active_machine_id}" "${DB_MACHINE_HOST}" "${DB_MACHINE_PORT}" "${DB_MACHINE_ROOT_USER}" "${DB_MACHINE_ROOT_PASSWORD}" "${DB_MACHINE_NAME}" "${DB_MACHINE_NOTES}"
  else
    resolve_db_machine "${active_machine_id}"
  fi
  if [[ "${should_sync_permissions}" == "yes" ]]; then
    sync_mysql_permissions "${db_name}" "${db_user}" "${db_password}" "${MYSQL_ALLOWED_IPS}" "${old_ips}" "${active_machine_id}"
  fi
  update_meta_value "${meta}" "MYSQL_ALLOWED_IPS" "${MYSQL_ALLOWED_IPS}"
  update_meta_value "${meta}" "DB_MACHINE_ID" "${active_machine_id}"
  if [[ "${move_data}" == "yes" && "${source_machine_id}" != "${active_machine_id}" ]]; then
    printf '[projectctl] mysql data moved and permissions updated for %s (%s)\n' "${REPO_REF}" "${MYSQL_ALLOWED_IPS:-local only}"
  elif [[ "${should_sync_permissions}" != "yes" ]]; then
    printf '[projectctl] saved custom DB connection for %s without permission sync (root password not provided)\n' "${REPO_REF}"
  else
    printf '[projectctl] mysql permissions updated for %s (%s)\n' "${REPO_REF}" "${MYSQL_ALLOWED_IPS:-local only}"
  fi
}

remove_mysql_permissions() {
  local db_name="$1"
  local db_user="$2"
  local db_password="$3"
  local old_ips="${4:-}"
  local machine_id="${5:-${LOCAL_DB_MACHINE_ID}}"
  local user_q
  local current_hosts
  local host

  [[ -n "${db_name}" ]] || return 0
  [[ -n "${db_user}" ]] || return 0
  [[ -n "${db_password}" ]] || return 0

  resolve_db_machine "${machine_id}"
  user_q="$(sql_quote "${db_user}")"

  current_hosts="$(mysql_exec_machine "SELECT Host FROM mysql.user WHERE User=${user_q};" 2>/dev/null || true)"
  while IFS= read -r host; do
    [[ -n "${host}" ]] || continue
    mysql_exec_machine "DROP USER IF EXISTS ${user_q}@$(sql_quote "${host}");" >/dev/null 2>&1 || true
  done <<< "${current_hosts}"

  sync_mysql_firewall_rules "" "${old_ips}"
  mysql_exec_machine "FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
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
  if [[ -z "${DB_MACHINE_ID:-}" ]]; then
    DB_MACHINE_ID="$(project_db_machine_id)"
  fi

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

  remove_mysql_permissions "${db_name}" "${db_user}" "${db_password}" "${MYSQL_ALLOWED_IPS:-}" "${DB_MACHINE_ID:-${LOCAL_DB_MACHINE_ID}}"
  remove_project_ssh_user "${SSH_UPLOAD_USER:-}"

  rm -rf "${APP_DIR}" "${meta}"
  refresh_project_ssh_config
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
      local db_machine_id=""
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
          --db-machine)
            db_machine_id="${2:-}"
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
      do_install "$1" "${domain}" "${https}" "${branch}" "${pm2_name}" "${port}" "${db_machine_id}" "${env_file}" "${entrypoint}"
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
      local script_dir=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --pm2)
            pm2_mode="yes"
            shift
            ;;
          --dir)
            script_dir="${2:-}"
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
      [[ $# -eq 2 ]] || { usage; exit 1; }
      do_script "$1" "$2" "${pm2_mode}" "${script_dir}"
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
      local db_name="__unset__"
      local db_user="__unset__"
      local db_password="__unset__"
      local machine_id="__unset__"
      local machine_name="__unset__"
      local machine_host="__unset__"
      local machine_port="__unset__"
      local machine_root_user="__unset__"
      local machine_root_password="__unset__"
      local machine_notes="__unset__"
      local move_data="no"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --move-data)
            move_data="yes"
            shift
            ;;
          --db-name)
            db_name="${2:-}"
            shift 2
            ;;
          --db-user)
            db_user="${2:-}"
            shift 2
            ;;
          --db-password)
            db_password="${2:-}"
            shift 2
            ;;
          --ips)
            ips="${2:-}"
            shift 2
            ;;
          --machine)
            machine_id="${2:-}"
            shift 2
            ;;
          --machine-name)
            machine_name="${2:-}"
            shift 2
            ;;
          --machine-host)
            machine_host="${2:-}"
            shift 2
            ;;
          --machine-port)
            machine_port="${2:-}"
            shift 2
            ;;
          --machine-root-user)
            machine_root_user="${2:-}"
            shift 2
            ;;
          --machine-root-password)
            machine_root_password="${2:-}"
            shift 2
            ;;
          --machine-notes)
            machine_notes="${2:-}"
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
      do_mysql "$1" "${ips}" "${machine_id}" "${machine_name}" "${machine_host}" "${machine_port}" "${machine_root_user}" "${machine_root_password}" "${machine_notes}" "${db_name}" "${db_user}" "${db_password}" "${move_data}"
      ;;
    ssh)
      local password=""
      local generate="no"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --password)
            password="${2:-}"
            shift 2
            ;;
          --generate)
            generate="yes"
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
      do_ssh "$1" "${password}" "${generate}"
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
