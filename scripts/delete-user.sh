#!/usr/bin/env bash
# Delete a Dynamic Security client at runtime.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 1 ]] || { echo "Usage: $0 <username>" >&2; exit 1; }
USERNAME="$1"
[[ "${USERNAME}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: Invalid username." >&2; exit 1; }

if [[ -t 0 ]]; then
  read -rp "Delete Dynamic Security client '${USERNAME}'? [y/N] " CONFIRM
  [[ "${CONFIRM}" == "y" || "${CONFIRM}" == "Y" ]] || exit 0
fi
"${REPO_ROOT}/scripts/dynsec-command.sh" deleteClient "${USERNAME}"
