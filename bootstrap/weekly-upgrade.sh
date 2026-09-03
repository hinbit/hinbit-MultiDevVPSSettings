#!/usr/bin/env bash
set -euo pipefail

[[ "${EUID}" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

exec 9>/run/lock/multidev-weekly-upgrade.lock
flock -n 9 || { echo "Another package upgrade is already running"; exit 0; }
apt-get update
apt-get -y upgrade

if [[ -f /var/run/reboot-required ]]; then
  echo "NOTICE: reboot required; automatic reboot is disabled"
fi
