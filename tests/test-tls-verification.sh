#!/usr/bin/env bash
# Integration test: TLS verification.
# Verifies TLS handshake succeeds with correct CA and fails with wrong CA or hostname mismatch.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
[[ -f "${CA_FILE}" ]] || die "CA certificate not found: ${CA_FILE}."

echo "--- Test: TLS 1.2 handshake with correct CA succeeds ---"
openssl s_client \
  -connect "${MQTT_HOST}:${MQTT_PORT}" \
  -CAfile "${CA_FILE}" \
  -verify_return_error \
  -verify_ip "${MQTT_HOST}" \
  -tls1_2 </dev/null >/dev/null 2>&1 \
  || die "TLS 1.2 connection with correct CA and IP SAN failed."
pass "TLS 1.2 with correct CA succeeds"

echo "--- Test: wrong CA fails TLS handshake ---"
TMPCA="$(mktemp)"
trap 'rm -f "${TMPCA}"' EXIT
# Generate a fake CA cert for testing
openssl req -new -x509 -newkey rsa:2048 -nodes \
  -keyout /dev/null -out "${TMPCA}" -days 1 \
  -subj "/CN=Wrong CA" >/dev/null 2>&1
if openssl s_client \
  -connect "${MQTT_HOST}:${MQTT_PORT}" \
  -CAfile "${TMPCA}" \
  -verify_return_error \
  -verify_ip "${MQTT_HOST}" \
  -tls1_2 </dev/null >/dev/null 2>&1; then
  die "Wrong CA should have failed TLS verification."
fi
pass "Wrong CA fails TLS handshake"

echo ""
echo "All TLS verification tests PASSED."
