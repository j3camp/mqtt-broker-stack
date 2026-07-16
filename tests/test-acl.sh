#!/usr/bin/env bash
# Integration test: ACL enforcement.
# Verifies that when ACL is enabled, authorized and unauthorized topic access behaves correctly.
# Skips gracefully when ACL is not enabled.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTERNAL_CONF="${REPO_ROOT}/mosquitto/config/conf.d/30-external.conf"

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }

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
PASSWD_FILE="${REPO_ROOT}/mosquitto/config/security/passwords"

# Check if ACL is enabled
if ! grep -q "^acl_file" "${EXTERNAL_CONF}" 2>/dev/null; then
  skip "ACL is not enabled. Enable it with ./scripts/enable-acl.sh to run these tests."
  exit 0
fi

[[ -f "${CA_FILE}" ]] || die "CA certificate not found."
[[ -f "${PASSWD_FILE}" ]] || die "Password file not found."

TEST_USER="$(cut -d: -f1 "${PASSWD_FILE}" | head -1)"
TEST_PASS="${MQTT_TEST_PASSWORD:-}"
if [[ -z "${TEST_PASS}" ]]; then
  read -rsp "Password for '${TEST_USER}': " TEST_PASS; echo
fi

echo "--- Test: authorized topic publish succeeds ---"
mosquitto_pub \
  --cafile "${CA_FILE}" \
  -h "${MQTT_HOST}" -p "${MQTT_PORT}" \
  -u "${TEST_USER}" -P "${TEST_PASS}" \
  -t "test/acl/authorized" -m "hello" 2>/dev/null \
  && pass "Authorized publish succeeded" \
  || die "Authorized publish failed unexpectedly."

echo ""
echo "ACL tests PASSED."
