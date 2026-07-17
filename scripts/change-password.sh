#!/usr/bin/env bash
# Rotate a Dynamic Security client password at runtime.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 1 ]] || { echo "Usage: $0 <username>" >&2; exit 1; }
USERNAME="$1"
[[ "${USERNAME}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: Invalid username." >&2; exit 1; }

if [[ -n "${MQTT_NEW_PASSWORD:-}" ]]; then
  [[ "${MQTT_NEW_PASSWORD}" != *$'\n'* ]] || { echo "ERROR: Password may not contain a newline." >&2; exit 1; }
  printf '%s\n%s\n' "${MQTT_NEW_PASSWORD}" "${MQTT_NEW_PASSWORD}" \
    | "${REPO_ROOT}/scripts/dynsec-command.sh" setClientPassword "${USERNAME}"
else
  "${REPO_ROOT}/scripts/dynsec-command.sh" setClientPassword "${USERNAME}"
fi
unset MQTT_NEW_PASSWORD
