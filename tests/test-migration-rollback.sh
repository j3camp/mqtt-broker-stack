#!/usr/bin/env bash
# Integration test: an injected post-cutover failure restores the exact DynSec state.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "${REPO_ROOT}/compose.yaml")
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

PASSWORD_FILE="${MIGRATION_PASSWORD_FILE:-${REPO_ROOT}/mosquitto/config/security/passwords}"
ACL_FILE="${MIGRATION_ACL_FILE:-${REPO_ROOT}/mosquitto/config/security/acl}"
OWNERS_FILE="${MIGRATION_OWNERS_FILE:-${REPO_ROOT}/mosquitto/config/security/migration-owners.csv}"
[[ -f "${PASSWORD_FILE}" ]] || die "Migration password fixture is missing."
[[ -f "${ACL_FILE}" ]] || die "Migration ACL fixture is missing."
[[ -f "${OWNERS_FILE}" ]] || die "Migration ownership fixture is missing."

BROKER_ID="$("${COMPOSE[@]}" ps -q mosquitto)"
[[ -n "${BROKER_ID}" ]] || die "Mosquitto is not running."
docker cp "${BROKER_ID}:/mosquitto/data/dynamic-security.json" "${TMPDIR}/before.json" >/dev/null

if DYNSEC_MIGRATION_FAIL_AFTER_CUTOVER=1 \
  "${REPO_ROOT}/scripts/migrate-dynsec.sh" \
    --password-file "${PASSWORD_FILE}" \
    --acl-file "${ACL_FILE}" \
    --owners-file "${OWNERS_FILE}" \
    --checkpoint-dir "${TMPDIR}/checkpoints"; then
  die "Injected migration failure unexpectedly succeeded."
fi

BROKER_ID="$("${COMPOSE[@]}" ps -q mosquitto)"
docker cp "${BROKER_ID}:/mosquitto/data/dynamic-security.json" "${TMPDIR}/after.json" >/dev/null
cmp -s "${TMPDIR}/before.json" "${TMPDIR}/after.json" \
  || die "Rollback did not restore the byte-identical Dynamic Security state."
"${REPO_ROOT}/scripts/dynsec-command.sh" listClients >/dev/null
pass "Injected failure automatically restored and validated the prior state"

