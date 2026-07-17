#!/usr/bin/env bash
# CI helper: create the initial Mosquitto user without interactive prompts.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

# shellcheck disable=SC1090
source "${REPO_ROOT}/.env"

MQTT_USER="${MQTT_INITIAL_USERNAME:?MQTT_INITIAL_USERNAME is required}"
MQTT_CREDENTIAL="${MQTT_INITIAL_PASSWORD:?MQTT_INITIAL_PASSWORD is required}"

PASSWD_FILE="${REPO_ROOT}/mosquitto/config/security/passwords"
mkdir -p "$(dirname "${PASSWD_FILE}")"

MOSQUITTO_IMG="${MOSQUITTO_IMAGE:?MOSQUITTO_IMAGE is required}"

printf '%s' "${MQTT_CREDENTIAL}" | docker run --rm -i \
  -e "MQTT_USER=${MQTT_USER}" \
  --entrypoint sh \
  "${MOSQUITTO_IMG}" \
  -c 'read -r cred; mosquitto_passwd -b -c /tmp/pw "${MQTT_USER}" "${cred}"; cat /tmp/pw' \
  > "${PASSWD_FILE}"

chmod 600 "${PASSWD_FILE}"
test -s "${PASSWD_FILE}" || die "Password file is empty after creation."
echo "Password file created for user '${MQTT_USER}'."
