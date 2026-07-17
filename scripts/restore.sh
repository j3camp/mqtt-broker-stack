#!/usr/bin/env bash
# Restore a Mosquitto broker backup created by backup.sh.
# Creates a safety backup of the current state before restoring.
#
# Usage:
#   ./scripts/restore.sh <backup-archive.tar.gz>
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $# -ge 1 ]] || { echo "Usage: $0 <backup-archive.tar.gz>" >&2; exit 1; }
ARCHIVE="$1"

[[ -f "${ARCHIVE}" ]] || die "Archive not found: ${ARCHIVE}"

# 1. Validate the archive
info "Validating archive..."
tar -tzf "${ARCHIVE}" >/dev/null 2>&1 || die "Archive is corrupt or not a valid tar.gz file."

# Extract to temp dir
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

tar -xzf "${ARCHIVE}" -C "${TMPDIR}"
BACKUP_DIR="$(ls "${TMPDIR}")"
STAGEDIR="${TMPDIR}/${BACKUP_DIR}"

# 2. Verify required files
info "Verifying required files in archive..."
[[ -f "${STAGEDIR}/manifest.json" ]] || die "Missing manifest.json in archive."
[[ -d "${STAGEDIR}/config" ]] || die "Missing config directory in archive."
[[ -f "${STAGEDIR}/config/mosquitto.conf" ]] || die "Missing mosquitto.conf in archive."
if [[ ! -f "${STAGEDIR}/security/dynamic-security.json" \
      && ! -f "${STAGEDIR}/data/dynamic-security.json" \
      && ! -f "${STAGEDIR}/security/passwords" ]]; then
  die "Archive has neither Dynamic Security state nor a legacy password file."
fi
info "Archive validated."

# Display manifest
echo "Manifest:"
cat "${STAGEDIR}/manifest.json"
echo ""

# Confirm restore
if [[ -t 0 ]]; then
  read -rp "Restore from ${ARCHIVE}? This will overwrite current configuration. [y/N] " CONFIRM
  [[ "${CONFIRM}" == "y" || "${CONFIRM}" == "Y" ]] || { echo "Aborted."; exit 0; }
fi

# 3. Create safety backup of current state
info "Creating safety backup of current state..."
"${REPO_ROOT}/scripts/backup.sh" || info "WARNING: Could not create safety backup. Proceeding anyway."

# 4. Stop the broker
info "Stopping Mosquitto..."
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker compose -f "${REPO_ROOT}/compose.yaml" stop mosquitto 2>/dev/null || true
fi

# 5. Restore data
info "Restoring configuration..."
if [[ -d "${STAGEDIR}/config" ]]; then
  cp -r "${STAGEDIR}/config/." "${REPO_ROOT}/mosquitto/config/"
fi

info "Restoring certificates (public only)..."
if [[ -d "${STAGEDIR}/certs" ]]; then
  mkdir -p "${REPO_ROOT}/mosquitto/config/certs"
  cp "${STAGEDIR}/certs/"*.crt "${REPO_ROOT}/mosquitto/config/certs/" 2>/dev/null || true
fi

info "Restoring security files..."
if [[ -d "${STAGEDIR}/security" ]]; then
  mkdir -p "${REPO_ROOT}/mosquitto/config/security"
  [[ -f "${STAGEDIR}/security/passwords" ]] \
    && cp "${STAGEDIR}/security/passwords" "${REPO_ROOT}/mosquitto/config/security/passwords" \
    && chmod 600 "${REPO_ROOT}/mosquitto/config/security/passwords"
  [[ -f "${STAGEDIR}/security/acl" ]] \
    && cp "${STAGEDIR}/security/acl" "${REPO_ROOT}/mosquitto/config/security/acl"
  [[ -f "${STAGEDIR}/security/migration-owners.csv" ]] \
    && cp "${STAGEDIR}/security/migration-owners.csv" \
      "${REPO_ROOT}/mosquitto/config/security/migration-owners.csv"
fi

info "Restoring persistence data..."
if [[ -d "${STAGEDIR}/data" ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # Start a temporary container to restore volume data
  MOSQUITTO_IMAGE="$(grep '"mosquitto_image"' "${STAGEDIR}/manifest.json" 2>/dev/null \
    | sed 's/.*: *"\(.*\)".*/\1/' || true)"
  [[ -n "${MOSQUITTO_IMAGE}" ]] || die "Backup manifest does not contain mosquitto_image."
  docker run --rm \
    -v mqtt-broker-stack_mosquitto-data:/mosquitto/data \
    -v "${STAGEDIR}/data:/restore-data:ro" \
    "${MOSQUITTO_IMAGE}" \
    sh -c 'cp -r /restore-data/. /mosquitto/data/ && chown -R mosquitto:mosquitto /mosquitto/data' \
    || die "Could not restore persistence data."
fi

# 6. Validate restored configuration
info "Validating restored configuration..."
if ! "${REPO_ROOT}/scripts/validate.sh" --quick; then
  die "Validation failed after restore. Check the configuration manually. The safety backup is in the backups/ directory."
fi

# 7. Start the broker
info "Starting Mosquitto..."
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker compose -f "${REPO_ROOT}/compose.yaml" start mosquitto
fi

info "Restore complete."
info ""
info "If something is wrong, restore from the safety backup in the backups/ directory."
