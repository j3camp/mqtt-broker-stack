#!/usr/bin/env bash
# Validate the mqtt-broker-stack configuration and environment.
#
# Usage:
#   ./scripts/validate.sh          # Full validation
#   ./scripts/validate.sh --quick  # Skip checks requiring running containers
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUICK=false
ERRORS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true; shift ;;
    -h|--help) echo "Usage: $0 [--quick]" >&2; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

pass() { echo "  [OK]  $*"; }
fail() { echo "  [FAIL] $*" >&2; ERRORS=$((ERRORS + 1)); }
skip() { echo "  [SKIP] $*"; }

echo "==> Validating mqtt-broker-stack"
echo ""

# Load .env if available
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi

MOSQUITTO_VERSION="${MOSQUITTO_VERSION:-2.0.21}"
MQTT_TLS_PORT="${MQTT_TLS_PORT:-8883}"

# --- Required files ---
echo "--- Required files ---"
REQUIRED_FILES=(
  "${REPO_ROOT}/compose.yaml"
  "${REPO_ROOT}/.env"
  "${REPO_ROOT}/.env.example"
  "${REPO_ROOT}/mosquitto/config/mosquitto.conf"
  "${REPO_ROOT}/mosquitto/config/conf.d/10-base.conf"
  "${REPO_ROOT}/mosquitto/config/conf.d/20-internal.conf"
  "${REPO_ROOT}/mosquitto/config/conf.d/30-external.conf"
  "${REPO_ROOT}/mosquitto/scripts/healthcheck.sh"
)
for f in "${REQUIRED_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    pass "$(basename "${f}")"
  else
    fail "Missing required file: ${f}"
  fi
done

# --- Required environment variables ---
echo ""
echo "--- Environment variables ---"
for var in MOSQUITTO_VERSION MQTT_TLS_PORT; do
  if [[ -n "${!var:-}" ]]; then
    pass "${var}=${!var}"
  else
    fail "${var} is not set"
  fi
done

# --- Docker Compose configuration ---
echo ""
echo "--- Docker Compose ---"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker compose -f "${REPO_ROOT}/compose.yaml" config >/dev/null 2>&1; then
    pass "docker compose config parses successfully"
  else
    fail "docker compose config failed"
  fi
else
  skip "Docker not available — skipping compose config check"
fi

# --- Port 1883 must not be published ---
echo ""
echo "--- Port security ---"
if grep -E '^\s+-\s+.*:1883' "${REPO_ROOT}/compose.yaml" 2>/dev/null; then
  fail "Port 1883 is published to the Docker host! Remove it from compose.yaml ports section."
else
  pass "Port 1883 is not published to the Docker host"
fi

# --- Port 8883 configured with TLS ---
if grep -q "8883" "${REPO_ROOT}/mosquitto/config/conf.d/30-external.conf" 2>/dev/null \
   && grep -q "cafile\|certfile\|keyfile" "${REPO_ROOT}/mosquitto/config/conf.d/30-external.conf" 2>/dev/null; then
  pass "Port 8883 configured with TLS"
else
  fail "Port 8883 does not appear to be configured with TLS in 30-external.conf"
fi

# --- External anonymous access disabled ---
if grep -q "allow_anonymous false" "${REPO_ROOT}/mosquitto/config/conf.d/30-external.conf" 2>/dev/null; then
  pass "External listener has allow_anonymous false"
else
  fail "allow_anonymous false not found in 30-external.conf"
fi

# --- Password file ---
echo ""
echo "--- Password file ---"
PASSWD_FILE="${REPO_ROOT}/mosquitto/config/security/passwords"
if [[ -f "${PASSWD_FILE}" ]]; then
  if [[ -s "${PASSWD_FILE}" ]]; then
    pass "Password file exists and is not empty"
  else
    fail "Password file exists but is empty"
  fi
  # Check permissions (not group/world readable)
  PERM="$(stat -c '%a' "${PASSWD_FILE}" 2>/dev/null || stat -f '%Lp' "${PASSWD_FILE}" 2>/dev/null || echo 'unknown')"
  if [[ "${PERM}" == "600" ]] || [[ "${PERM}" == "400" ]]; then
    pass "Password file permissions: ${PERM}"
  else
    fail "Password file permissions (${PERM}) should be 600 or 400"
  fi
else
  fail "Password file not found: ${PASSWD_FILE}"
fi

# --- Certificate checks ---
echo ""
echo "--- Certificates ---"
CERT_FILE="${REPO_ROOT}/mosquitto/config/certs/server.crt"
KEY_FILE="${REPO_ROOT}/mosquitto/config/certs/server.key"
CA_FILE="${REPO_ROOT}/mosquitto/config/certs/ca.crt"

if [[ -f "${CERT_FILE}" ]]; then
  pass "Server certificate exists"

  # Check expiry
  if openssl x509 -checkend 86400 -noout -in "${CERT_FILE}" 2>/dev/null; then
    pass "Server certificate is not expired"
  else
    fail "Server certificate is expired or expires within 24 hours"
  fi

  # Check SAN
  if openssl x509 -noout -text -in "${CERT_FILE}" 2>/dev/null | grep -q "Subject Alternative Name"; then
    pass "Server certificate contains Subject Alternative Name"
  else
    fail "Server certificate does not contain Subject Alternative Name"
  fi

  # Check cert/key match
  if [[ -f "${KEY_FILE}" ]]; then
    CERT_MOD="$(openssl x509 -noout -modulus -in "${CERT_FILE}" 2>/dev/null | openssl md5)"
    KEY_MOD="$(openssl rsa -noout -modulus -in "${KEY_FILE}" 2>/dev/null | openssl md5)"
    if [[ "${CERT_MOD}" == "${KEY_MOD}" ]]; then
      pass "Server certificate and key match"
    else
      fail "Server certificate and key do NOT match"
    fi
  else
    fail "Server key not found: ${KEY_FILE}"
  fi

  # Verify chain
  if [[ -f "${CA_FILE}" ]]; then
    if openssl verify -CAfile "${CA_FILE}" "${CERT_FILE}" >/dev/null 2>&1; then
      pass "Certificate chain verifies against CA"
    else
      fail "Certificate chain verification failed"
    fi
  else
    fail "CA certificate not found: ${CA_FILE}"
  fi
else
  fail "Server certificate not found: ${CERT_FILE}"
fi

# Check key permissions
if [[ -f "${KEY_FILE}" ]]; then
  KEY_PERM="$(stat -c '%a' "${KEY_FILE}" 2>/dev/null || stat -f '%Lp' "${KEY_FILE}" 2>/dev/null || echo 'unknown')"
  if [[ "${KEY_PERM}" == "600" ]] || [[ "${KEY_PERM}" == "400" ]] || [[ "${KEY_PERM}" == "644" ]]; then
    pass "Server key permissions: ${KEY_PERM}"
  else
    fail "Server key permissions (${KEY_PERM}) should be 600, 400, or 644"
  fi
fi

# --- ACL checks ---
echo ""
echo "--- ACL ---"
EXTERNAL_CONF="${REPO_ROOT}/mosquitto/config/conf.d/30-external.conf"
if grep -q "^acl_file" "${EXTERNAL_CONF}" 2>/dev/null; then
  ACL_FILE="${REPO_ROOT}/mosquitto/config/security/acl"
  if [[ -f "${ACL_FILE}" ]]; then
    pass "ACL is enabled and ACL file exists"
  else
    fail "ACL is enabled but ACL file not found: ${ACL_FILE}"
  fi
else
  pass "ACL is disabled (optional)"
fi

# --- Mosquitto configuration parse ---
echo ""
echo "--- Mosquitto configuration ---"
if [[ "${QUICK}" == "false" ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker compose -f "${REPO_ROOT}/compose.yaml" run --rm --no-deps --entrypoint="" \
      mosquitto mosquitto -c /mosquitto/config/mosquitto.conf --test-config >/dev/null 2>&1; then
    pass "Mosquitto configuration parses without errors"
  else
    fail "Mosquitto configuration has errors"
  fi
else
  skip "Mosquitto config parse check requires Docker (use without --quick)"
fi

# --- Summary ---
echo ""
if [[ "${ERRORS}" -eq 0 ]]; then
  echo "==> Validation PASSED (${ERRORS} errors)"
  exit 0
else
  echo "==> Validation FAILED (${ERRORS} errors)" >&2
  exit 1
fi
