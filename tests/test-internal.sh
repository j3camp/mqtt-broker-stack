#!/usr/bin/env bash
# Integration test: internal listener.
# Verifies anonymous MQTT access works on port 1883 within the private Docker network.
# Also verifies port 1883 is NOT published to the Docker host.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="docker compose"
TEST_TOPIC="test/internal/$$"
TIMEOUT=10

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Load .env
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi
MOSQUITTO_IMG="eclipse-mosquitto:${MOSQUITTO_VERSION:-2.0.21}"
NETWORK="$(${COMPOSE} -f "${REPO_ROOT}/compose.yaml" config --format json 2>/dev/null \
  | python3 -c "import sys,json; cfg=json.load(sys.stdin); print(list(cfg['networks'].keys())[0])" \
  2>/dev/null || echo "mqtt-broker-stack_mqtt-internal")"

# Verify port 1883 is not published
echo "--- Test: port 1883 not published to host ---"
PORT_PUBLISHED="$(${COMPOSE} -f "${REPO_ROOT}/compose.yaml" port mosquitto 1883 2>/dev/null || true)"
if [[ -n "${PORT_PUBLISHED}" && ! "${PORT_PUBLISHED}" =~ :0$ ]]; then
  die "Port 1883 is published to the Docker host: ${PORT_PUBLISHED}"
fi
pass "Port 1883 is not published to the Docker host"

# Test anonymous publish and subscribe via internal listener
echo "--- Test: anonymous publish/subscribe on internal listener ---"

RECEIVED="$(docker run --rm \
  --network "${NETWORK}" \
  "${MOSQUITTO_IMG}" \
  sh -c "
    mosquitto_sub -h mosquitto -p 1883 -t '${TEST_TOPIC}' -C 1 -W ${TIMEOUT} &
    SUB_PID=\$!
    sleep 1
    mosquitto_pub -h mosquitto -p 1883 -t '${TEST_TOPIC}' -m 'hello-internal'
    wait \$SUB_PID
  " 2>/dev/null)"

[[ "${RECEIVED}" == "hello-internal" ]] \
  || die "Expected 'hello-internal' but received: '${RECEIVED}'"
pass "Anonymous publish/subscribe works on internal listener (mosquitto:1883)"

echo ""
echo "All internal listener tests PASSED."
