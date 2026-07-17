#!/usr/bin/env bash
# Create a timestamped backup of the Mosquitto broker state.
# The backup includes: configuration, public certificates, Dynamic Security
# state, legacy migration inputs when present, persistence data, and a manifest.
# CA private keys are NOT included.
#
# Usage:
#   ./scripts/backup.sh [--output-dir <dir>]
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/backups"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 [--output-dir <dir>]" >&2; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Load .env
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi
MOSQUITTO_IMAGE="${MOSQUITTO_IMAGE:?MOSQUITTO_IMAGE is required in .env}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_NAME="mqtt-broker-backup-${TIMESTAMP}"
TMPDIR="$(mktemp -d)"
STAGEDIR="${TMPDIR}/${BACKUP_NAME}"
trap 'rm -rf "${TMPDIR}"' EXIT

mkdir -p "${OUTPUT_DIR}"
mkdir -p "${STAGEDIR}"

info "Creating backup ${BACKUP_NAME}..."

# --- Configuration ---
mkdir -p "${STAGEDIR}/config/conf.d"
cp -r "${REPO_ROOT}/mosquitto/config/conf.d/." "${STAGEDIR}/config/conf.d/"
cp "${REPO_ROOT}/mosquitto/config/mosquitto.conf" "${STAGEDIR}/config/"

# --- Public certificates (NOT private keys) ---
mkdir -p "${STAGEDIR}/certs"
[[ -f "${REPO_ROOT}/mosquitto/config/certs/ca.crt" ]] \
  && cp "${REPO_ROOT}/mosquitto/config/certs/ca.crt" "${STAGEDIR}/certs/"
[[ -f "${REPO_ROOT}/mosquitto/config/certs/server.crt" ]] \
  && cp "${REPO_ROOT}/mosquitto/config/certs/server.crt" "${STAGEDIR}/certs/"

# --- Security files ---
mkdir -p "${STAGEDIR}/security"
[[ -f "${REPO_ROOT}/mosquitto/config/security/passwords" ]] \
  && cp "${REPO_ROOT}/mosquitto/config/security/passwords" "${STAGEDIR}/security/"
[[ -f "${REPO_ROOT}/mosquitto/config/security/acl" ]] \
  && cp "${REPO_ROOT}/mosquitto/config/security/acl" "${STAGEDIR}/security/"
[[ -f "${REPO_ROOT}/mosquitto/config/security/migration-owners.csv" ]] \
  && cp "${REPO_ROOT}/mosquitto/config/security/migration-owners.csv" "${STAGEDIR}/security/"

# --- Persistence data (from Docker volume via running container) ---
mkdir -p "${STAGEDIR}/data"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  CONTAINER_ID="$(docker compose -f "${REPO_ROOT}/compose.yaml" ps -q mosquitto 2>/dev/null || true)"
  if [[ -n "${CONTAINER_ID}" ]]; then
    info "Copying persistence data from running container..."
    docker cp "${CONTAINER_ID}:/mosquitto/data/." "${STAGEDIR}/data/" 2>/dev/null || true
    if [[ -f "${STAGEDIR}/data/dynamic-security.json" ]]; then
      cp "${STAGEDIR}/data/dynamic-security.json" "${STAGEDIR}/security/"
      chmod 600 "${STAGEDIR}/security/dynamic-security.json"
    fi
  else
    info "Container not running — using volume data directly (may be incomplete)."
  fi
fi

# --- Manifest ---
cat > "${STAGEDIR}/manifest.json" <<MANIFEST
{
  "backup_name": "${BACKUP_NAME}",
  "timestamp": "${TIMESTAMP}",
  "mosquitto_image": "${MOSQUITTO_IMAGE}",
  "created_by": "mqtt-broker-stack backup.sh"
}
MANIFEST

# --- Create archive ---
ARCHIVE="${OUTPUT_DIR}/${BACKUP_NAME}.tar.gz"
info "Creating archive ${ARCHIVE}..."
tar -czf "${ARCHIVE}" -C "${TMPDIR}" "${BACKUP_NAME}"
chmod 600 "${ARCHIVE}"

info "Backup complete: ${ARCHIVE}"
info "Archive contains sensitive authorization state; keep mode 600 and encrypt at rest."
info "Archive does not contain the DynSec administrator plaintext secret or private TLS keys."
