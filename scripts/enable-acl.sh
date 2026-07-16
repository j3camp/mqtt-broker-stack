#!/usr/bin/env bash
# Enable ACL enforcement on the external listener.
# Activates /mosquitto/config/security/acl by adding acl_file to 30-external.conf.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTERNAL_CONF="${REPO_ROOT}/mosquitto/config/conf.d/30-external.conf"
ACL_FILE="${REPO_ROOT}/mosquitto/config/security/acl"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# Verify ACL file exists
[[ -f "${ACL_FILE}" ]] || die "ACL file not found: ${ACL_FILE}. Create it first (see mosquitto/config/security/acl.example)."
[[ -s "${ACL_FILE}" ]] || die "ACL file is empty: ${ACL_FILE}."

# Check if ACL is already enabled
if grep -q "^acl_file" "${EXTERNAL_CONF}" 2>/dev/null; then
  info "ACL is already enabled in ${EXTERNAL_CONF}."
  exit 0
fi

# Backup current config
TMPBAK="$(mktemp)"
trap 'rm -f "${TMPBAK}"' EXIT
cp "${EXTERNAL_CONF}" "${TMPBAK}"

# Append acl_file directive
echo "" >> "${EXTERNAL_CONF}"
echo "acl_file /mosquitto/config/security/acl" >> "${EXTERNAL_CONF}"

# Validate the updated configuration
info "Validating configuration..."
if ! "${REPO_ROOT}/scripts/validate.sh" --quick 2>&1; then
  cp "${TMPBAK}" "${EXTERNAL_CONF}"
  die "Configuration validation failed. Reverted changes."
fi

# Reload Mosquitto
info "Reloading Mosquitto..."
if docker compose -f "${REPO_ROOT}/compose.yaml" ps mosquitto 2>/dev/null | grep -q "running\|Up"; then
  docker compose -f "${REPO_ROOT}/compose.yaml" restart mosquitto
fi

info "ACL enabled. Topics are now access-controlled."
