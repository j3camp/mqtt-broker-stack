#!/usr/bin/env bash
# Restore the exact pre-migration Dynamic Security state from a checkpoint.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "${REPO_ROOT}/compose.yaml")
CHECKPOINT=""
CONFIRM=true
WORK_DIR="${REPO_ROOT}/tmp/dynsec"

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --checkpoint) CHECKPOINT="$2"; shift 2 ;;
    --no-confirm) CONFIRM=false; shift ;;
    -h|--help) echo "Usage: $0 --checkpoint <dir> [--no-confirm]"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ -z "${CHECKPOINT}" && -f "${REPO_ROOT}/backups/.last-dynsec-migration" ]]; then
  CHECKPOINT="$(<"${REPO_ROOT}/backups/.last-dynsec-migration")"
fi
[[ -n "${CHECKPOINT}" ]] || die "A checkpoint is required."
[[ -s "${CHECKPOINT}/dynamic-security.json" ]] || die "Checkpoint state is missing."
[[ -s "${CHECKPOINT}/sha256" ]] || die "Checkpoint checksum is missing."

EXPECTED="$(awk '{print $1}' "${CHECKPOINT}/sha256")"
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "${CHECKPOINT}/dynamic-security.json" | awk '{print $1}')"
else
  ACTUAL="$(shasum -a 256 "${CHECKPOINT}/dynamic-security.json" | awk '{print $1}')"
fi
[[ "${ACTUAL}" == "${EXPECTED}" ]] || die "Checkpoint checksum verification failed."

if [[ "${CONFIRM}" == "true" && -t 0 ]]; then
  read -rp "Restore Dynamic Security state from ${CHECKPOINT}? [y/N] " ANSWER
  [[ "${ANSWER}" == "y" || "${ANSWER}" == "Y" ]] || exit 0
fi

mkdir -p "${WORK_DIR}"
cp "${CHECKPOINT}/dynamic-security.json" "${WORK_DIR}/rollback.json"
"${COMPOSE[@]}" stop mosquitto
"${COMPOSE[@]}" --profile migration run --rm dynsec-migration rollback.json
"${COMPOSE[@]}" start mosquitto

BROKER_ID="$("${COMPOSE[@]}" ps -q mosquitto)"
for _ in $(seq 1 36); do
  STATUS="$(docker inspect --format '{{.State.Health.Status}}' "${BROKER_ID}" 2>/dev/null || true)"
  [[ "${STATUS}" == "healthy" ]] && break
  sleep 5
done
[[ "${STATUS:-}" == "healthy" ]] || die "Broker did not become healthy after rollback."
"${REPO_ROOT}/scripts/dynsec-command.sh" listClients >/dev/null
echo "==> Dynamic Security rollback completed from ${CHECKPOINT}."
