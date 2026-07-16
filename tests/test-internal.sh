#!/usr/bin/env bash
# Integration test: internal listener.
# Verifies anonymous MQTT access works on port 1883 within the private Docker network.
# Also verifies port 1883 is NOT published to the Docker host.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/compose.yaml"
COMPOSE=(docker compose -f "${COMPOSE_FILE}")
TEST_TOPIC="test/internal/$$-$(date +%s)"
TEST_MESSAGE="hello-internal-$$-$(date +%s)"
TIMEOUT="${MQTT_TEST_TIMEOUT:-10}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

# Load repository environment variables when available.
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi

MOSQUITTO_IMAGE="eclipse-mosquitto:${MOSQUITTO_VERSION:-2.0.21}"

command -v docker >/dev/null 2>&1 || fail "docker is not installed"
docker compose version >/dev/null 2>&1 || fail "docker compose is unavailable"
[[ -f "${COMPOSE_FILE}" ]] || fail "Compose file not found: ${COMPOSE_FILE}"

BROKER_CONTAINER_ID="$("${COMPOSE[@]}" ps -q mosquitto 2>/dev/null || true)"
[[ -n "${BROKER_CONTAINER_ID}" ]] \
  || fail "Mosquitto container is not running. Run: docker compose up -d mosquitto"

RUNNING_STATE="$(docker inspect --format '{{.State.Running}}' "${BROKER_CONTAINER_ID}" 2>/dev/null || true)"
[[ "${RUNNING_STATE}" == "true" ]] || fail "Mosquitto container is not running"

# Resolve the actual Docker network attached to the Mosquitto service.
# Prefer the network whose Compose logical name is mqtt-internal.
NETWORK="$({
  docker inspect --format '{{range $name, $settings := .NetworkSettings.Networks}}{{printf "%s\n" $name}}{{end}}' \
    "${BROKER_CONTAINER_ID}"
} | awk '/mqtt-internal$/ { print; exit }')"

if [[ -z "${NETWORK}" ]]; then
  NETWORK="$(
    docker inspect --format '{{range $name, $settings := .NetworkSettings.Networks}}{{printf "%s\n" $name}}{{end}}' \
      "${BROKER_CONTAINER_ID}" | head -n 1
  )"
fi

[[ -n "${NETWORK}" ]] || fail "Unable to determine Mosquitto Docker network"

echo "Using Docker network: ${NETWORK}"

# Verify port 1883 is not published to the Docker host.
echo ""
echo "--- Test: port 1883 not published to host ---"
PORT_PUBLISHED="$("${COMPOSE[@]}" port mosquitto 1883 2>/dev/null || true)"

if [[ -n "${PORT_PUBLISHED}" ]]; then
  fail "Port 1883 is published to the Docker host: ${PORT_PUBLISHED}"
fi

pass "Port 1883 is not published to the Docker host"

# Verify anonymous publish/subscribe from a temporary client container
# attached to the same private Docker network.
echo ""
echo "--- Test: anonymous publish/subscribe on internal listener ---"

set +e
OUTPUT="$(
  docker run --rm \
    --network "${NETWORK}" \
    "${MOSQUITTO_IMAGE}" \
    sh -eu -c '
      broker_host="$1"
      topic="$2"
      message="$3"
      timeout="$4"
      output_file="$(mktemp)"

      cleanup() {
        rm -f "$output_file"
      }
      trap cleanup EXIT

      mosquitto_sub \
        -h "$broker_host" \
        -p 1883 \
        -t "$topic" \
        -C 1 \
        -W "$timeout" \
        >"$output_file" &
      subscriber_pid=$!

      sleep 1

      mosquitto_pub \
        -h "$broker_host" \
        -p 1883 \
        -t "$topic" \
        -m "$message"

      wait "$subscriber_pid"
      cat "$output_file"
    ' sh mosquitto "${TEST_TOPIC}" "${TEST_MESSAGE}" "${TIMEOUT}" \
    2>&1
)"
STATUS=$?
set -e

if (( STATUS != 0 )); then
  echo "${OUTPUT}" >&2
  fail "Anonymous publish/subscribe failed on internal listener"
fi

if [[ "${OUTPUT}" != "${TEST_MESSAGE}" ]]; then
  printf 'MQTT client output:\n%s\n' "${OUTPUT}" >&2
  fail "Expected '${TEST_MESSAGE}' but received different output"
fi

pass "Anonymous publish/subscribe works on internal listener (mosquitto:1883)"

echo ""
echo "All internal listener tests PASSED."
