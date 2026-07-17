#!/usr/bin/env bash
# Integration test: the Dynamic Security control plane is isolated and least privilege.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "${REPO_ROOT}/compose.yaml")

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi

BROKER_ID="$("${COMPOSE[@]}" ps -q mosquitto)"
[[ -n "${BROKER_ID}" ]] || die "Mosquitto is not running."

if docker port "${BROKER_ID}" 1884/tcp 2>/dev/null | grep -q .; then
  die "Control listener 1884 must not be published to the host."
fi
pass "Control listener is not published"

INTERNAL_NETWORK="$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
  "${BROKER_ID}" | grep 'mqtt-internal' | head -1)"
[[ -n "${INTERNAL_NETWORK}" ]] || die "Could not determine mqtt-internal network."

if docker run --rm --network "${INTERNAL_NETWORK}" \
  --entrypoint sh "${MOSQUITTO_IMAGE:?MOSQUITTO_IMAGE is required}" \
  -c 'nc -z -w 3 mosquitto 1884'; then
  die "An application container on mqtt-internal reached the control listener."
fi
pass "mqtt-internal cannot route to the control listener"

"${REPO_ROOT}/scripts/dynsec-command.sh" listClients >/dev/null
pass "Dedicated administrator can execute Dynamic Security commands over TLS"

if "${COMPOSE[@]}" --profile admin run --rm --entrypoint sh dynsec-admin -c '
  mosquitto_pub --cafile /mosquitto/config/certs/ca.crt \
    -h "${MQTT_CONTROL_HOSTNAME:-mosquitto-control}" -p 1884 -V 5 \
    -u "${DYNSEC_ADMIN_USERNAME:-admin}" \
    -P "$(cat /run/secrets/dynsec_admin_password)" \
    -q 1 -t application/forbidden -m forbidden
' >/dev/null 2>&1; then
  die "Dynamic Security administrator published to an application topic."
fi
pass "Administrator has no application publish permission"
