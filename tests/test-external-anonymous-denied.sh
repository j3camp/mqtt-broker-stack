#!/usr/bin/env bash
# Integration test: external listener anonymous access denial.
# Verifies anonymous connections are rejected on the external listener.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMEOUT=5

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Load .env
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi

MQTT_HOST="127.0.0.1"
MQTT_PORT="${MQTT_TLS_PORT:-8883}"
CA_FILE="${REPO_ROOT}/mosquitto/config/certs/ca.crt"

[[ -f "${CA_FILE}" ]] || die "CA certificate not found: ${CA_FILE}. Run ./scripts/init.sh first."

echo "--- Test: anonymous connection rejected on external listener ---"
mosquitto_sub \
  --cafile "${CA_FILE}" \
  -h "${MQTT_HOST}" -p "${MQTT_PORT}" \
  -t "test/anonymous/$$" -C 1 -W ${TIMEOUT} 2>/dev/null \
  && die "Anonymous connection to external listener should have been rejected" \
  || pass "Anonymous connection rejected on external listener"

echo ""
echo "External anonymous denial test PASSED."
