#!/usr/bin/env bash
# Integration test: internal MQTT listener.
#
# Verifies:
#   1. Mosquitto is running.
#   2. Port 1883 is not published to the Docker host.
#   3. Anonymous MQTT publish/subscribe works on port 1883 from within
#      the broker's private Docker network.
#
# Port 1883 must be exposed only inside Docker, for example:
#
#   expose:
#     - "1883"
#
# It must not appear in the service's ports section.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/compose.yaml"
COMPOSE=(docker compose -f "${COMPOSE_FILE}")

TEST_TOPIC="test/internal/$$/$(date +%s)"
TEST_MESSAGE="hello-internal-$$-${RANDOM}"
TIMEOUT="${MQTT_TEST_TIMEOUT:-10}"

die() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

command -v docker >/dev/null 2>&1 \
  || die "docker command is not available"

[[ -f "${COMPOSE_FILE}" ]] \
  || die "Compose file not found: ${COMPOSE_FILE}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi

MOSQUITTO_IMG="eclipse-mosquitto:${MOSQUITTO_VERSION:-2.0.21}"

BROKER_CONTAINER_ID="$(
  "${COMPOSE[@]}" ps -q mosquitto 2>/dev/null || true
)"

[[ -n "${BROKER_CONTAINER_ID}" ]] \
  || die "Mosquitto container is not running. Run: docker compose up -d mosquitto"

BROKER_RUNNING="$(
  docker inspect \
    --format '{{.State.Running}}' \
    "${BROKER_CONTAINER_ID}" 2>/dev/null || true
)"

[[ "${BROKER_RUNNING}" == "true" ]] \
  || die "Mosquitto container is not running"

NETWORK="$(
  docker inspect \
    --format '{{range $name, $network := .NetworkSettings.Networks}}{{if eq (index $network.Labels "com.docker.compose.network") "mqtt-internal"}}{{$name}}{{end}}{{end}}' \
    "${BROKER_CONTAINER_ID}" 2>/dev/null || true
)"

if [[ -z "${NETWORK}" ]]; then
  NETWORK="$(
    docker inspect \
      --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{"\n"}}{{end}}' \
      "${BROKER_CONTAINER_ID}" 2>/dev/null \
      | head -n 1
  )"
fi

[[ -n "${NETWORK}" ]] \
  || die "Unable to determine the Docker network used by Mosquitto"

echo "Using Docker network: ${NETWORK}"
echo ""

echo "--- Test: port 1883 not published to host ---"

PORT_BINDINGS="$(
  docker inspect \
    --format '{{with index .NetworkSettings.Ports "1883/tcp"}}{{range .}}{{.HostIp}}:{{.HostPort}}{{"\n"}}{{end}}{{end}}' \
    "${BROKER_CONTAINER_ID}" 2>/dev/null || true
)"

PORT_BINDINGS="${PORT_BINDINGS//$'\r'/}"
PORT_BINDINGS="${PORT_BINDINGS%$'\n'}"

if [[ -n "${PORT_BINDINGS}" ]]; then
  die "Port 1883 is published to the Docker host: ${PORT_BINDINGS}"
fi

pass "Port 1883 is not published to the Docker host"
echo ""

echo "--- Test: anonymous publish/subscribe on internal listener ---"

set +e
MQTT_OUTPUT="$(
  docker run --rm \
    --network "${NETWORK}" \
    "${MOSQUITTO_IMG}" \
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
        >"$output_file" 2>&1 &

      subscriber_pid=$!

      sleep 1

      if ! mosquitto_pub \
        -h "$broker_host" \
        -p 1883 \
        -t "$topic" \
        -m "$message"; then
        kill "$subscriber_pid" 2>/dev/null || true
        wait "$subscriber_pid" 2>/dev/null || true
        echo "mosquitto_pub failed" >&2
        exit 1
      fi

      if ! wait "$subscriber_pid"; then
        cat "$output_file" >&2
        exit 1
      fi

      cat "$output_file"
    ' sh \
    mosquitto \
    "${TEST_TOPIC}" \
    "${TEST_MESSAGE}" \
    "${TIMEOUT}" 2>&1
)"
MQTT_STATUS=$?
set -e

if [[ ${MQTT_STATUS} -ne 0 ]]; then
  echo "${MQTT_OUTPUT}" >&2
  die "Anonymous publish/subscribe failed on internal listener"
fi

MQTT_OUTPUT="${MQTT_OUTPUT//$'\r'/}"
MQTT_OUTPUT="${MQTT_OUTPUT%$'\n'}"

if [[ "${MQTT_OUTPUT}" != "${TEST_MESSAGE}" ]]; then
  die "Expected '${TEST_MESSAGE}' but received: '${MQTT_OUTPUT}'"
fi

pass "Anonymous publish/subscribe works on internal listener (mosquitto:1883)"

echo ""
echo "All internal listener tests PASSED."
