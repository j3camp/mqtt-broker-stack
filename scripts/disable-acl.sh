#!/usr/bin/env bash
# Disable ACL enforcement on the external listener.
# Removes the acl_file directive from 30-external.conf.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTERNAL_CONF="${REPO_ROOT}/mosquitto/config/conf.d/30-external.conf"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# Check if ACL is currently enabled
if ! grep -q "^acl_file" "${EXTERNAL_CONF}" 2>/dev/null; then
  info "ACL is not currently enabled in ${EXTERNAL_CONF}."
  exit 0
fi

# Backup current config
TMPBAK="$(mktemp)"
trap 'rm -f "${TMPBAK}"' EXIT
cp "${EXTERNAL_CONF}" "${TMPBAK}"

# Remove acl_file directive and any blank line preceding it
grep -v "^acl_file" "${EXTERNAL_CONF}" | sed '/^[[:space:]]*$/N;/^\n[[:space:]]*$/d' \
  > "${TMPBAK}.new" && mv "${TMPBAK}.new" "${EXTERNAL_CONF}"

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

info "ACL disabled. All authenticated users now have access to all topics."
