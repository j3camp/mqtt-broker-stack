#!/usr/bin/env bash
# Delete a Mosquitto user from the external listener password file.
#
# Usage:
#   ./scripts/delete-user.sh <username>
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSWD_FILE="${REPO_ROOT}/mosquitto/config/security/passwords"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $# -ge 1 ]] || { echo "Usage: $0 <username>" >&2; exit 1; }
USERNAME="$1"

# Load .env
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +o allexport
fi
MOSQUITTO_IMG="eclipse-mosquitto:${MOSQUITTO_VERSION:-2.0.21}"

[[ -f "${PASSWD_FILE}" ]] || die "Password file not found: ${PASSWD_FILE}."

# Verify user exists
grep -q "^${USERNAME}:" "${PASSWD_FILE}" || die "User '${USERNAME}' does not exist."

# Confirm deletion interactively unless stdin is not a terminal
if [[ -t 0 ]]; then
  read -rp "Delete user '${USERNAME}'? This cannot be undone. [y/N] " CONFIRM
  [[ "${CONFIRM}" == "y" || "${CONFIRM}" == "Y" ]] || { echo "Aborted."; exit 0; }
fi

TMPBAK="$(mktemp)"
trap 'rm -f "${TMPBAK}"' EXIT
cp "${PASSWD_FILE}" "${TMPBAK}"

info "Removing user '${USERNAME}'..."

if command -v mosquitto_passwd >/dev/null 2>&1; then
  mosquitto_passwd -D "${PASSWD_FILE}" "${USERNAME}"
else
  docker run --rm \
    -v "${PASSWD_FILE}:/etc/mosquitto/passwords" \
    --entrypoint mosquitto_passwd \
    "${MOSQUITTO_IMG}" \
    -D /etc/mosquitto/passwords "${USERNAME}"
fi

# Verify user is removed
if grep -q "^${USERNAME}:" "${PASSWD_FILE}" 2>/dev/null; then
  cp "${TMPBAK}" "${PASSWD_FILE}"
  die "Failed to remove user '${USERNAME}'. Password file restored."
fi

# Reload Mosquitto
info "Reloading Mosquitto..."
if docker compose -f "${REPO_ROOT}/compose.yaml" ps mosquitto 2>/dev/null | grep -q "running\|Up"; then
  docker compose -f "${REPO_ROOT}/compose.yaml" kill -s HUP mosquitto 2>/dev/null \
    || docker compose -f "${REPO_ROOT}/compose.yaml" restart mosquitto
fi

info "User '${USERNAME}' deleted."
