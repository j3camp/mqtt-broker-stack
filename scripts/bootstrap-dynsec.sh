#!/usr/bin/env bash
# Create the Docker secret used by Mosquitto 2.1 automatic DynSec bootstrap.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_FILE="${REPO_ROOT}/mosquitto/config/security/dynsec-admin-password"
FORCE=false

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    -h|--help) echo "Usage: $0 [--force]"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ -s "${SECRET_FILE}" && "${FORCE}" != "true" ]]; then
  echo "==> Dynamic Security administrator secret already exists."
  exit 0
fi

PASSWORD="${DYNSEC_ADMIN_PASSWORD:-}"
if [[ -z "${PASSWORD}" ]]; then
  [[ -t 0 ]] || die "DYNSEC_ADMIN_PASSWORD is required for non-interactive bootstrap."
  read -rsp "Dynamic Security administrator password: " PASSWORD
  echo
  read -rsp "Confirm password: " CONFIRM
  echo
  [[ "${PASSWORD}" == "${CONFIRM}" ]] || die "Passwords do not match."
fi
[[ ${#PASSWORD} -ge 12 ]] || die "Administrator password must be at least 12 characters."
[[ "${PASSWORD}" != *$'\n'* ]] || die "Administrator password may not contain a newline."

mkdir -p "$(dirname "${SECRET_FILE}")"
umask 077
TEMPORARY="$(mktemp "${SECRET_FILE}.XXXXXX")"
trap 'rm -f "${TEMPORARY}"' EXIT
printf '%s\n' "${PASSWORD}" > "${TEMPORARY}"
chmod 600 "${TEMPORARY}"
mv "${TEMPORARY}" "${SECRET_FILE}"
unset PASSWORD CONFIRM DYNSEC_ADMIN_PASSWORD
trap - EXIT
echo "==> Dynamic Security administrator secret created."
