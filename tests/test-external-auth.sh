#!/usr/bin/env bash
# Integration test: external Dynamic Security authentication.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TOPIC="test/external-auth/$$"
TIMEOUT=10

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi

MQTT_HOST="127.0.0.1"
MQTT_PORT="${MQTT_TLS_PORT:-8883}"
CA_FILE="${REPO_ROOT}/mosquitto/config/certs/ca.crt"
TEST_USER="${MQTT_TEST_USERNAME:-${MQTT_INITIAL_USERNAME:-}}"
TEST_PASS="${MQTT_TEST_PASSWORD:-}"
[[ -f "${CA_FILE}" ]] || die "CA certificate not found: ${CA_FILE}."
[[ -n "${TEST_USER}" ]] || die "MQTT_TEST_USERNAME is required."
if [[ -z "${TEST_PASS}" ]]; then
  read -rsp "Password for test user '${TEST_USER}': " TEST_PASS; echo
fi
[[ -n "${TEST_PASS}" ]] || die "Test password is required."

RECEIVED="$(mosquitto_sub \
  --cafile "${CA_FILE}" -h "${MQTT_HOST}" -p "${MQTT_PORT}" \
  -u "${TEST_USER}" -P "${TEST_PASS}" -t "${TEST_TOPIC}" -C 1 -W ${TIMEOUT} &
SUB_PID=$!
sleep 1
mosquitto_pub --cafile "${CA_FILE}" -h "${MQTT_HOST}" -p "${MQTT_PORT}" \
  -u "${TEST_USER}" -P "${TEST_PASS}" -t "${TEST_TOPIC}" -m hello-external
wait "${SUB_PID}" 2>/dev/null)" 2>/dev/null || true
[[ "${RECEIVED}" == "hello-external" ]] \
  || die "Correct credentials did not allow publish/subscribe."
pass "Correct credentials succeed on external listener"

mosquitto_sub --cafile "${CA_FILE}" -h "${MQTT_HOST}" -p "${MQTT_PORT}" \
  -t "${TEST_TOPIC}" -C 1 -W 5 >/dev/null 2>&1 \
  && die "Connection without credentials should have failed" \
  || pass "Missing credentials rejected"

mosquitto_sub --cafile "${CA_FILE}" -h "${MQTT_HOST}" -p "${MQTT_PORT}" \
  -u "${TEST_USER}" -P "wrong-password-$$" -t "${TEST_TOPIC}" -C 1 -W 5 >/dev/null 2>&1 \
  && die "Connection with wrong password should have failed" \
  || pass "Invalid password rejected"
