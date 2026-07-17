#!/usr/bin/env bash
# Integration test: Dynamic Security allow/deny, wildcard, group, role, and priority behavior.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE="ci-matrix-role-$$"
GROUP="ci-matrix-group-$$"

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi

HOST="127.0.0.1"
PORT="${MQTT_TLS_PORT:-8883}"
CA_FILE="${REPO_ROOT}/mosquitto/config/certs/ca.crt"
USERNAME="${MQTT_TEST_USERNAME:?MQTT_TEST_USERNAME is required}"
PASSWORD="${MQTT_TEST_PASSWORD:?MQTT_TEST_PASSWORD is required}"
AUTH=(--cafile "${CA_FILE}" -h "${HOST}" -p "${PORT}" -V 5 -u "${USERNAME}" -P "${PASSWORD}")

cleanup() {
  "${REPO_ROOT}/scripts/dynsec-command.sh" removeGroupClient "${GROUP}" "${USERNAME}" >/dev/null 2>&1 || true
  "${REPO_ROOT}/scripts/dynsec-command.sh" deleteGroup "${GROUP}" >/dev/null 2>&1 || true
  "${REPO_ROOT}/scripts/dynsec-command.sh" deleteRole "${ROLE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

publish_allowed() {
  mosquitto_pub "${AUTH[@]}" -q 1 -t "$1" -m allowed >/dev/null 2>&1 \
    || die "Expected publish allow for $1"
}

publish_denied() {
  if mosquitto_pub "${AUTH[@]}" -q 1 -t "$1" -m denied >/dev/null 2>&1; then
    die "Expected publish deny for $1"
  fi
}

publish_allowed "test/acl/allowed"
pass "Explicit allow rule"
publish_denied "test/private/blocked"
pass "Higher-priority explicit deny overrides broad allow"
publish_allowed "devices/${USERNAME}/telemetry/temperature"
publish_denied "devices/another-user/telemetry/temperature"
pass "Username wildcard substitution"

"${REPO_ROOT}/scripts/dynsec-command.sh" createRole "${ROLE}" >/dev/null
"${REPO_ROOT}/scripts/dynsec-command.sh" addRoleACL \
  "${ROLE}" publishClientSend 'group/ci/#' allow 10 >/dev/null
"${REPO_ROOT}/scripts/dynsec-command.sh" addRoleACL \
  "${ROLE}" publishClientSend 'group/ci/blocked' deny 100 >/dev/null
"${REPO_ROOT}/scripts/dynsec-command.sh" createGroup "${GROUP}" >/dev/null
"${REPO_ROOT}/scripts/dynsec-command.sh" addGroupRole "${GROUP}" "${ROLE}" 50 >/dev/null
"${REPO_ROOT}/scripts/dynsec-command.sh" addGroupClient "${GROUP}" "${USERNAME}" 50 >/dev/null

publish_allowed "group/ci/allowed"
publish_denied "group/ci/blocked"
pass "Group role assignment and ACL priority"
