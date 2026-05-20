#!/usr/bin/env bash
set -euo pipefail

META_DIR="/etc/vps-projects"
APP_ROOT="/var/www"
APP_MAP="/etc/app-map.csv"
PORT_MIN="${PROJECT_PORT_START:-3000}"
PORT_MAX="${PROJECT_PORT_END:-9999}"

die() {
  printf '[projectctl] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  projectctl install [--domain example.com] [--https yes|no] [--branch main] [--pm2-name name] [--port N] owner/repo
  projectctl update owner/repo
  projectctl restart owner/repo
  projectctl status owner/repo
  projectctl uninstall owner/repo
  projectctl list

Defaults:
  - repo URL is git@github.com:owner/repo.git
  - project directory is /var/www/owner-repo
  - PM2 process name is owner-repo
  - default branch is the repo's current branch or "main"
  - port is auto-assigned if not provided
  - domain is optional, but when provided it is added to /etc/app-map.csv and synced to nginx
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

ensure_meta_dir() {
  mkdir -p "${META_DIR}"
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
PACKAGE_MANAGER=${PACKAGE_MANAGER}
BRANCH=${BRANCH}
GIT_REMOTE=${GIT_REMOTE}
START_KIND=${START_KIND}
START_TARGET=${START_TARGET}
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
  (
    cd "${APP_DIR}"
    case "${START_KIND}" in
      ecosystem)
        pm2 start "${START_TARGET}" --name "${PM2_NAME}" --update-env
        ;;
      npm-start)
        case "${PACKAGE_MANAGER:-npm}" in
          pnpm) PORT="${APP_PORT}" pm2 start pnpm --name "${PM2_NAME}" -- start ;;
          corepack-pnpm) PORT="${APP_PORT}" pm2 start corepack --name "${PM2_NAME}" -- pnpm start ;;
          yarn) PORT="${APP_PORT}" pm2 start yarn --name "${PM2_NAME}" -- start ;;
          corepack-yarn) PORT="${APP_PORT}" pm2 start corepack --name "${PM2_NAME}" -- yarn start ;;
          *) PORT="${APP_PORT}" pm2 start npm --name "${PM2_NAME}" -- start ;;
        esac
        ;;
      npm-dev)
        case "${PACKAGE_MANAGER:-npm}" in
          pnpm) PORT="${APP_PORT}" pm2 start pnpm --name "${PM2_NAME}" -- dev ;;
          corepack-pnpm) PORT="${APP_PORT}" pm2 start corepack --name "${PM2_NAME}" -- pnpm dev ;;
          yarn) PORT="${APP_PORT}" pm2 start yarn --name "${PM2_NAME}" -- dev ;;
          corepack-yarn) PORT="${APP_PORT}" pm2 start corepack --name "${PM2_NAME}" -- yarn dev ;;
          *) PORT="${APP_PORT}" pm2 start npm --name "${PM2_NAME}" -- run dev ;;
        esac
        ;;
      node:*)
        PORT="${APP_PORT}" pm2 start "${START_TARGET}" --name "${PM2_NAME}" --update-env
        ;;
      serve:*)
        pm2 serve "${START_TARGET}" "${APP_PORT}" --name "${PM2_NAME}" --spa
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
    pm2 restart "${PM2_NAME}" --update-env
    pm2 save
    return
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

  clone_or_pull

  git -C "${APP_DIR}" checkout "${BRANCH}" >/dev/null 2>&1 || git -C "${APP_DIR}" checkout -b "${BRANCH}" "origin/${BRANCH}"

  START_KIND="$(detect_start_kind)"
  START_TARGET="$(start_kind_target "${START_KIND}")"
  APP_TYPE="$(start_kind_family "${START_KIND}")"

  install_deps
  maybe_build

  meta="$(meta_path_for_slug "${PROJECT_SLUG}")"
  write_meta "${meta}"
  chmod 0644 "${meta}"

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

do_status() {
  local ref="$1"
  local slug
  local meta

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"

  printf 'repo: %s\npath: %s\npm2: %s\nport: %s\ndomain: %s\nhttps: %s\nkind: %s\n' \
    "${REPO_REF}" "${APP_DIR}" "${PM2_NAME}" "${APP_PORT}" "${APP_DOMAIN:-}" "${APP_HTTPS:-yes}" "${START_KIND}"
  (cd "${APP_DIR}" && git status -sb) || true
  pm2 describe "${PM2_NAME}" || true
}

do_uninstall() {
  local ref="$1"
  local slug
  local meta
  local tmp

  slug="$(slug_from_ref "$(repo_ref_from_arg "${ref}")")"
  meta="$(meta_path_for_slug "${slug}")"
  load_meta "${meta}"

  if pm2 describe "${PM2_NAME}" >/dev/null 2>&1; then
    pm2 delete "${PM2_NAME}" >/dev/null 2>&1 || true
    pm2 save || true
  fi

  if [[ -n "${APP_DOMAIN:-}" ]] && [[ -f "${APP_MAP}" ]]; then
    tmp="$(mktemp)"
    awk -F, -v OFS=, -v domain="${APP_DOMAIN}" 'NR == 1 { print; next } $1 != domain { print }' "${APP_MAP}" > "${tmp}"
    mv "${tmp}" "${APP_MAP}"
    if [[ -x /usr/local/bin/app-sync.sh ]]; then
      /usr/local/bin/app-sync.sh
    fi
  fi

  rm -rf "${APP_DIR}" "${meta}"
  printf '[projectctl] uninstalled %s\n' "${REPO_REF}"
}

do_list() {
  [[ -d "${META_DIR}" ]] || exit 0
  for meta in "${META_DIR}"/*.env; do
    [[ -e "${meta}" ]] || continue
    # shellcheck disable=SC1090
    source "${meta}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${PROJECT_SLUG:-}" "${APP_PORT:-}" "${APP_DOMAIN:-}" "${PM2_NAME:-}" "${BRANCH:-}" "${APP_DIR:-}"
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
      do_install "$1" "${domain}" "${https}" "${branch}" "${pm2_name}" "${port}"
      ;;
    update)
      [[ $# -eq 1 ]] || { usage; exit 1; }
      do_update "$1"
      ;;
    restart)
      [[ $# -eq 1 ]] || { usage; exit 1; }
      do_restart "$1"
      ;;
    status)
      [[ $# -eq 1 ]] || { usage; exit 1; }
      do_status "$1"
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
