#!/usr/bin/env bash
# Create a new Mosquitto user in the external listener password file.
#
# Usage:
#   ./scripts/create-user.sh <username>
#   MQTT_NEW_PASSWORD='secret' ./scripts/create-user.sh <username>
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSWD_FILE="${REPO_ROOT}/mosquitto/config/security/passwords"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $# -ge 1 ]] || { echo "Usage: $0 <username>" >&2; exit 1; }
USERNAME="$1"

# Validate username
if ! [[ "${USERNAME}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  die "Invalid username '${USERNAME}'. Use only alphanumeric characters, dots, hyphens, or underscores."
fi

# Load .env for MOSQUITTO_VERSION
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi
MOSQUITTO_IMG="eclipse-mosquitto:${MOSQUITTO_VERSION:-2.0.21}"

[[ -f "${PASSWD_FILE}" ]] || die "Password file not found: ${PASSWD_FILE}. Run ./scripts/init.sh first."

# Check for duplicate
if grep -q "^${USERNAME}:" "${PASSWD_FILE}" 2>/dev/null; then
  die "User '${USERNAME}' already exists. Use change-password.sh to update the password."
fi

# Resolve password
MQTT_NEW_PASS="${MQTT_NEW_PASSWORD:-}"
if [[ -z "${MQTT_NEW_PASS}" ]]; then
  read -rsp "Password for '${USERNAME}': " MQTT_NEW_PASS; echo
  read -rsp "Confirm password: " MQTT_NEW_PASS2; echo
  [[ "${MQTT_NEW_PASS}" == "${MQTT_NEW_PASS2}" ]] || die "Passwords do not match."
fi
[[ -n "${MQTT_NEW_PASS}" ]] || die "Password cannot be empty."

# Backup current password file
TMPBAK="$(mktemp)"
trap 'rm -f "${TMPBAK}"' EXIT
cp "${PASSWD_FILE}" "${TMPBAK}"

info "Adding user '${USERNAME}'..."

# Add user using mosquitto_passwd (prefer docker to avoid local install requirement)
if command -v mosquitto_passwd >/dev/null 2>&1; then
  mosquitto_passwd -b "${PASSWD_FILE}" "${USERNAME}" "${MQTT_NEW_PASS}"
else
  printf '%s' "${MQTT_NEW_PASS}" | docker run --rm -i \
    -v "${PASSWD_FILE}:/etc/mosquitto/passwords" \
    --entrypoint sh \
    "${MOSQUITTO_IMG}" \
    -c "read -r pw; mosquitto_passwd -b /etc/mosquitto/passwords '${USERNAME}' \"\${pw}\""
fi

unset MQTT_NEW_PASS MQTT_NEW_PASS2

# Validate the password file is non-empty and contains the new user
grep -q "^${USERNAME}:" "${PASSWD_FILE}" || {
  cp "${TMPBAK}" "${PASSWD_FILE}"
  die "Failed to add user '${USERNAME}'. Password file restored."
}

# Reload Mosquitto configuration
info "Reloading Mosquitto..."
if docker compose -f "${REPO_ROOT}/compose.yaml" ps mosquitto 2>/dev/null | grep -q "running\|Up"; then
  docker compose -f "${REPO_ROOT}/compose.yaml" kill -s HUP mosquitto 2>/dev/null \
    || docker compose -f "${REPO_ROOT}/compose.yaml" restart mosquitto
fi

info "User '${USERNAME}' created successfully."
