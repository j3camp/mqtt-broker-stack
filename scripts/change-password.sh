#!/usr/bin/env bash
# Change the password for an existing Mosquitto user.
#
# Usage:
#   ./scripts/change-password.sh <username>
#   MQTT_NEW_PASSWORD='secret' ./scripts/change-password.sh <username>
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSWD_FILE="${REPO_ROOT}/mosquitto/config/security/passwords"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $# -ge 1 ]] || { echo "Usage: $0 <username>" >&2; exit 1; }
USERNAME="$1"

# Load .env
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi
MOSQUITTO_IMG="eclipse-mosquitto:${MOSQUITTO_VERSION:-2.0.21}"

[[ -f "${PASSWD_FILE}" ]] || die "Password file not found: ${PASSWD_FILE}. Run ./scripts/init.sh first."

# Verify user exists
grep -q "^${USERNAME}:" "${PASSWD_FILE}" || die "User '${USERNAME}' does not exist."

# Resolve new password
MQTT_NEW_PASS="${MQTT_NEW_PASSWORD:-}"
if [[ -z "${MQTT_NEW_PASS}" ]]; then
  read -rsp "New password for '${USERNAME}': " MQTT_NEW_PASS; echo
  read -rsp "Confirm new password: " MQTT_NEW_PASS2; echo
  [[ "${MQTT_NEW_PASS}" == "${MQTT_NEW_PASS2}" ]] || die "Passwords do not match."
fi
[[ -n "${MQTT_NEW_PASS}" ]] || die "Password cannot be empty."

TMPBAK="$(mktemp)"
trap 'rm -f "${TMPBAK}"' EXIT
cp "${PASSWD_FILE}" "${TMPBAK}"

info "Changing password for '${USERNAME}'..."

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

# Validate
grep -q "^${USERNAME}:" "${PASSWD_FILE}" || {
  cp "${TMPBAK}" "${PASSWD_FILE}"
  die "Failed to update password. Password file restored."
}

# Reload Mosquitto
info "Reloading Mosquitto..."
if docker compose -f "${REPO_ROOT}/compose.yaml" ps mosquitto 2>/dev/null | grep -q "running\|Up"; then
  docker compose -f "${REPO_ROOT}/compose.yaml" kill -s HUP mosquitto 2>/dev/null \
    || docker compose -f "${REPO_ROOT}/compose.yaml" restart mosquitto
fi

info "Password updated for '${USERNAME}'."
