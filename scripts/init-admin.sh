#!/usr/bin/env bash
# Generate local administration secrets without placing them in .env.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_DIR="${REPO_ROOT}/admin/secrets"
mkdir -p "${SECRET_DIR}"
chmod 700 "${SECRET_DIR}"

generate_secret() {
  local path="$1" bytes="$2"
  if [[ -s "${path}" ]]; then
    echo "==> Keeping existing ${path#${REPO_ROOT}/}"
    return
  fi
  umask 077
  openssl rand -hex "${bytes}" > "${path}"
  chmod 600 "${path}"
  echo "==> Created ${path#${REPO_ROOT}/}"
}

generate_secret "${SECRET_DIR}/db-password" 24
generate_secret "${SECRET_DIR}/session-secret" 48

BOOTSTRAP_FILE="${SECRET_DIR}/bootstrap-password"
if [[ ! -s "${BOOTSTRAP_FILE}" ]]; then
  if [[ -n "${ADMIN_BOOTSTRAP_PASSWORD:-}" ]]; then
    [[ ${#ADMIN_BOOTSTRAP_PASSWORD} -ge 14 ]] || { echo "ERROR: ADMIN_BOOTSTRAP_PASSWORD must contain at least 14 characters." >&2; exit 1; }
    umask 077
    printf '%s\n' "${ADMIN_BOOTSTRAP_PASSWORD}" > "${BOOTSTRAP_FILE}"
  else
    generate_secret "${BOOTSTRAP_FILE}" 18
  fi
  chmod 600 "${BOOTSTRAP_FILE}"
fi

echo "==> Admin secrets are ready. Keep bootstrap-password in a secret manager and rotate it after first login."

