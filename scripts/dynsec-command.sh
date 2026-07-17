#!/usr/bin/env bash
# Execute an authorized Dynamic Security command from the isolated admin service.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_FILE="${REPO_ROOT}/mosquitto/config/security/dynsec-admin-password"

[[ $# -gt 0 ]] || { echo "Usage: $0 <dynsec-command> [arguments...]" >&2; exit 1; }
[[ -s "${SECRET_FILE}" ]] || {
  echo "ERROR: Run ./scripts/bootstrap-dynsec.sh first." >&2
  exit 1
}

exec docker compose \
  -f "${REPO_ROOT}/compose.yaml" \
  --profile admin \
  run --rm dynsec-admin "$@"
