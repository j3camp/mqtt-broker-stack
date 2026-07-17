#!/usr/bin/env bash
# Initialise Mosquitto 2.1, the DynSec bootstrap secret, and development TLS.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE=false

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    -h|--help) echo "Usage: $0 [--force]"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

command -v docker >/dev/null 2>&1 || die "docker is required but not found."
docker info >/dev/null 2>&1 || die "Cannot connect to Docker daemon."
docker compose version >/dev/null 2>&1 || die "Docker Compose is required."

if [[ ! -f "${REPO_ROOT}/.env" || "${FORCE}" == "true" ]]; then
  info "Creating .env from .env.example."
  cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
fi
set -o allexport
# shellcheck disable=SC1090
source "${REPO_ROOT}/.env"
set +o allexport

mkdir -p \
  "${REPO_ROOT}/mosquitto/config/security" \
  "${REPO_ROOT}/mosquitto/config/certs" \
  "${REPO_ROOT}/certs/ca" \
  "${REPO_ROOT}/backups" \
  "${REPO_ROOT}/tmp/dynsec"
chmod 700 "${REPO_ROOT}/certs/ca"

BOOTSTRAP_ARGS=()
[[ "${FORCE}" == "true" ]] && BOOTSTRAP_ARGS+=(--force)
"${REPO_ROOT}/scripts/bootstrap-dynsec.sh" "${BOOTSTRAP_ARGS[@]}"

if [[ -f "${REPO_ROOT}/mosquitto/config/certs/server.crt" && "${FORCE}" != "true" ]]; then
  info "Development certificate already exists."
else
  CERT_ARGS=(
    --hostname "${MQTT_SERVER_HOSTNAME:-localhost}"
    --dns "${MQTT_CONTROL_HOSTNAME:-mosquitto-control}"
  )
  [[ "${FORCE}" == "true" ]] && CERT_ARGS+=(--force)
  "${REPO_ROOT}/scripts/generate-cert.sh" "${CERT_ARGS[@]}"
fi

"${REPO_ROOT}/scripts/validate.sh" --quick

cat <<'EOF'

Initialisation complete.

Next steps:
  1. Start the broker: make up
  2. For an upgrade, follow docs/migration-dynamic-security.md
  3. For a new install, create explicit roles/ACLs, then run make create-user
  4. Run the security matrix: make test
EOF
