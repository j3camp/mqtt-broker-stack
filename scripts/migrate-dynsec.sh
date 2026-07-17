#!/usr/bin/env bash
# Cut over legacy password_file/acl_file identities to Dynamic Security.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSWORD_FILE="${REPO_ROOT}/mosquitto/config/security/passwords"
ACL_FILE="${REPO_ROOT}/mosquitto/config/security/acl"
OWNERS_FILE="${REPO_ROOT}/mosquitto/config/security/migration-owners.csv"
CHECKPOINT_ROOT="${REPO_ROOT}/backups"
WORK_DIR="${REPO_ROOT}/tmp/dynsec"
COMPOSE=(docker compose -f "${REPO_ROOT}/compose.yaml")
CUTOVER_STARTED=false
CHECKPOINT_DIR=""

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --password-file <path>  Legacy Mosquitto password file
  --acl-file <path>       Legacy Mosquitto ACL file (optional)
  --owners-file <path>    CSV with username,owner,group
  --checkpoint-dir <path> Parent directory for rollback checkpoints
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password-file) PASSWORD_FILE="$2"; shift 2 ;;
    --acl-file) ACL_FILE="$2"; shift 2 ;;
    --owners-file) OWNERS_FILE="$2"; shift 2 ;;
    --checkpoint-dir) CHECKPOINT_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -f "${PASSWORD_FILE}" ]] || die "Password file not found: ${PASSWORD_FILE}"
[[ -f "${OWNERS_FILE}" ]] || die "Ownership file not found: ${OWNERS_FILE}"
[[ -s "${REPO_ROOT}/mosquitto/config/security/dynsec-admin-password" ]] \
  || die "Dynamic Security administrator secret is missing."
command -v docker >/dev/null 2>&1 || die "docker is required."
docker info >/dev/null 2>&1 || die "Cannot connect to Docker daemon."

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi

BROKER_ID="$("${COMPOSE[@]}" ps -q mosquitto)"
[[ -n "${BROKER_ID}" ]] || die "Mosquitto must be running before migration."

# Make the pre-cutover checkpoint safe even if the operator started only the
# broker service and the normal one-shot bootstrap service did not run.
"${COMPOSE[@]}" run --rm --no-deps \
  --entrypoint /mosquitto/scripts/harden-dynsec.sh dynsec-admin >/dev/null

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

wait_for_health() {
  local status
  for _ in $(seq 1 36); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "${BROKER_ID}" 2>/dev/null || true)"
    [[ "${status}" == "healthy" ]] && return 0
    sleep 5
  done
  return 1
}

rollback_on_error() {
  local status=$?
  trap - ERR
  if [[ "${CUTOVER_STARTED}" == "true" && -n "${CHECKPOINT_DIR}" ]]; then
    echo "ERROR: Migration failed after cutover; starting rollback." >&2
    "${REPO_ROOT}/scripts/rollback-dynsec.sh" \
      --checkpoint "${CHECKPOINT_DIR}" --no-confirm \
      || echo "ERROR: Automatic rollback failed; use ${CHECKPOINT_DIR} manually." >&2
  fi
  exit "${status}"
}
trap rollback_on_error ERR

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CHECKPOINT_DIR="${CHECKPOINT_ROOT}/dynsec-migration-${TIMESTAMP}"
mkdir -p "${CHECKPOINT_DIR}" "${WORK_DIR}"

info "Creating migration rollback checkpoint: ${CHECKPOINT_DIR}"
docker cp "${BROKER_ID}:/mosquitto/data/dynamic-security.json" \
  "${CHECKPOINT_DIR}/dynamic-security.json"
cp "${PASSWORD_FILE}" "${CHECKPOINT_DIR}/passwords"
cp "${OWNERS_FILE}" "${CHECKPOINT_DIR}/migration-owners.csv"
[[ -f "${ACL_FILE}" ]] && cp "${ACL_FILE}" "${CHECKPOINT_DIR}/acl"
STATE_SHA256="$(sha256_file "${CHECKPOINT_DIR}/dynamic-security.json")"
printf '%s  %s\n' "${STATE_SHA256}" "dynamic-security.json" \
  > "${CHECKPOINT_DIR}/sha256"
printf '%s\n' "${CHECKPOINT_DIR}" > "${CHECKPOINT_ROOT}/.last-dynsec-migration"

cp "${CHECKPOINT_DIR}/dynamic-security.json" "${WORK_DIR}/base.json"
MIGRATION_ARGS=(
  --password-file "${PASSWORD_FILE}"
  --owners-file "${OWNERS_FILE}"
  --base-config "${WORK_DIR}/base.json"
  --output "${WORK_DIR}/candidate.json"
)
[[ -f "${ACL_FILE}" ]] && MIGRATION_ARGS+=(--acl-file "${ACL_FILE}")
python3 "${REPO_ROOT}/scripts/migrate_dynsec.py" "${MIGRATION_ARGS[@]}"
python3 -m json.tool "${WORK_DIR}/candidate.json" >/dev/null

CUTOVER_STARTED=true
info "Stopping broker for atomic Dynamic Security state replacement."
"${COMPOSE[@]}" stop mosquitto
"${COMPOSE[@]}" --profile migration run --rm dynsec-migration candidate.json
"${COMPOSE[@]}" start mosquitto
if ! wait_for_health; then
  echo "ERROR: Broker did not become healthy after Dynamic Security cutover." >&2
  false
fi

if [[ "${DYNSEC_MIGRATION_FAIL_AFTER_CUTOVER:-0}" == "1" ]]; then
  echo "ERROR: Injected migration failure after cutover." >&2
  false
fi

"${REPO_ROOT}/scripts/dynsec-command.sh" listClients >/dev/null
CUTOVER_STARTED=false
trap - ERR
info "Migration completed. Rollback checkpoint: ${CHECKPOINT_DIR}"
