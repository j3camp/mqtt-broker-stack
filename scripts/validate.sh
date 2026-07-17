#!/usr/bin/env bash
# Validate Mosquitto 2.1, listener boundaries, DynSec bootstrap, and TLS files.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUICK=false
ERRORS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true; shift ;;
    -h|--help) echo "Usage: $0 [--quick]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

pass() { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*" >&2; ERRORS=$((ERRORS + 1)); }
skip() { echo "  [SKIP] $*"; }

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi
MOSQUITTO_IMAGE="${MOSQUITTO_IMAGE:-}"

echo "==> Validating mqtt-broker-stack"
REQUIRED_FILES=(
  compose.yaml
  .env
  .env.example
  mosquitto/config/mosquitto.conf
  mosquitto/config/conf.d/20-internal.conf
  mosquitto/config/conf.d/30-external.conf
  mosquitto/config/conf.d/35-control.conf
  mosquitto/config/conf.d/40-websocket.conf
  mosquitto/config/security/dynsec-admin-password
  mosquitto/scripts/dynsec-entrypoint.sh
  mosquitto/scripts/mosquitto-entrypoint.sh
)
for relative in "${REQUIRED_FILES[@]}"; do
  [[ -f "${REPO_ROOT}/${relative}" ]] && pass "${relative}" || fail "Missing ${relative}"
done

if [[ "${MOSQUITTO_IMAGE}" =~ ^eclipse-mosquitto:2\.1\.2-alpine@sha256:[0-9a-f]{64}$ ]]; then
  pass "Mosquitto 2.1.2 image is digest pinned"
else
  fail "MOSQUITTO_IMAGE must pin eclipse-mosquitto:2.1.2-alpine by sha256 digest"
fi

ACTIVE_CONFIG="$({
  cat "${REPO_ROOT}/mosquitto/config/mosquitto.conf"
  cat "${REPO_ROOT}"/mosquitto/config/conf.d/*.conf
} 2>/dev/null)"
if grep -Eq '^[[:space:]]*(per_listener_settings|password_file|acl_file)([[:space:]]|$)' \
    <<<"${ACTIVE_CONFIG}"; then
  fail "Deprecated or legacy authentication directive is active"
else
  pass "No per_listener_settings, password_file, or acl_file directive is active"
fi

ROOT_CONFIG="${REPO_ROOT}/mosquitto/config/mosquitto.conf"
grep -q '^plugin_load dynsec /usr/lib/mosquitto_dynamic_security.so$' "${ROOT_CONFIG}" \
  && pass "Dynamic Security plugin is loaded once" || fail "plugin_load dynsec is missing"
grep -q '^plugin_opt_config_file /mosquitto/data/dynamic-security.json$' "${ROOT_CONFIG}" \
  && pass "Dynamic Security state is persistent" || fail "DynSec state path is missing"
grep -q '^plugin_opt_password_init_file /tmp/dynsec_admin_password$' "${ROOT_CONFIG}" \
  && pass "Dynamic Security bootstrap uses the protected container copy" \
  || fail "DynSec bootstrap password path is invalid"

INTERNAL="${REPO_ROOT}/mosquitto/config/conf.d/20-internal.conf"
grep -q '^listener_allow_anonymous true$' "${INTERNAL}" \
  && ! grep -q '^plugin_use ' "${INTERNAL}" \
  && pass "Internal listener remains anonymous without DynSec" \
  || fail "Internal listener boundary is invalid"

for config in 30-external.conf 35-control.conf 40-websocket.conf; do
  path="${REPO_ROOT}/mosquitto/config/conf.d/${config}"
  if grep -q '^listener_allow_anonymous false$' "${path}" \
      && grep -q '^plugin_use dynsec$' "${path}" \
      && grep -q '^certfile ' "${path}" \
      && grep -q '^keyfile ' "${path}"; then
    pass "${config} requires TLS and Dynamic Security"
  else
    fail "${config} does not enforce TLS and Dynamic Security"
  fi
done

grep -q '^listener 1884 172\.31\.0\.2$' \
  "${REPO_ROOT}/mosquitto/config/conf.d/35-control.conf" \
  && pass "Control listener is bound only to the isolated broker interface" \
  || fail "Control listener must bind to 172.31.0.2"

if grep -Eq '^[[:space:]]*-[[:space:]]*"?[^#]*:(1883|1884)"?[[:space:]]*$' \
    "${REPO_ROOT}/compose.yaml"; then
  fail "Internal or control listener is published to the host"
else
  pass "Ports 1883 and 1884 are not host-published"
fi

SECRET_FILE="${REPO_ROOT}/mosquitto/config/security/dynsec-admin-password"
if [[ -s "${SECRET_FILE}" ]]; then
  PERM="$(stat -c '%a' "${SECRET_FILE}" 2>/dev/null || stat -f '%Lp' "${SECRET_FILE}" 2>/dev/null || true)"
  [[ "${PERM}" == "600" ]] && pass "DynSec bootstrap secret mode is 600" \
    || fail "DynSec bootstrap secret mode must be 600 (found ${PERM:-unknown})"
fi

CERT_FILE="${REPO_ROOT}/mosquitto/config/certs/server.crt"
KEY_FILE="${REPO_ROOT}/mosquitto/config/certs/server.key"
CA_FILE="${REPO_ROOT}/mosquitto/config/certs/ca.crt"
if [[ -f "${CERT_FILE}" && -f "${KEY_FILE}" && -f "${CA_FILE}" ]]; then
  openssl verify -CAfile "${CA_FILE}" "${CERT_FILE}" >/dev/null 2>&1 \
    && pass "Certificate chain verifies" || fail "Certificate chain verification failed"
  openssl x509 -noout -text -in "${CERT_FILE}" 2>/dev/null \
    | grep -q 'DNS:mosquitto-control' \
    && pass "Control hostname is present in certificate SAN" \
    || fail "Certificate SAN must contain mosquitto-control"
else
  fail "TLS certificate, key, or CA is missing"
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker compose -f "${REPO_ROOT}/compose.yaml" config >/dev/null \
    && pass "Docker Compose configuration parses" || fail "Docker Compose configuration failed"
  if [[ "${QUICK}" == "false" ]]; then
    BROKER_ID="$(docker compose -f "${REPO_ROOT}/compose.yaml" ps -q mosquitto)"
    if [[ -n "${BROKER_ID}" ]]; then
      pass "Mosquitto service is running"
      for acl_type in publishClientSend publishClientReceive subscribe unsubscribe; do
        DEFAULT_ACCESS="$("${REPO_ROOT}/scripts/dynsec-command.sh" \
          getDefaultACLAccess "${acl_type}" 2>/dev/null || true)"
        grep -qi 'deny' <<<"${DEFAULT_ACCESS}" \
          && pass "Default ${acl_type} access is deny" \
          || fail "Default ${acl_type} access must be deny"
      done
      ADMIN_STATE="$("${REPO_ROOT}/scripts/dynsec-command.sh" \
        getClient "${DYNSEC_ADMIN_USERNAME:-admin}" 2>/dev/null || true)"
      if grep -q 'dynsec-admin' <<<"${ADMIN_STATE}" \
          && grep -q 'sys-observe' <<<"${ADMIN_STATE}" \
          && ! grep -Eq 'super-admin|topic-observe|broker-admin|(^|[^[:alnum:]_-])client([^[:alnum:]_-]|$)' \
            <<<"${ADMIN_STATE}"; then
        pass "Dynamic Security administrator is least privilege"
      else
        fail "Dynamic Security administrator roles are not least privilege"
      fi
      CLIENTS="$("${REPO_ROOT}/scripts/dynsec-command.sh" listClients 2>/dev/null || true)"
      ! grep -qx 'democlient' <<<"${CLIENTS}" \
        && pass "Demonstration client is absent" || fail "democlient must be removed"
    else
      fail "Mosquitto service is not running"
    fi
  fi
else
  skip "Docker runtime checks are unavailable"
fi

if [[ ${ERRORS} -eq 0 ]]; then
  echo "==> Validation PASSED"
else
  echo "==> Validation FAILED (${ERRORS} errors)" >&2
  exit 1
fi
