#!/usr/bin/env bash
# Wait for the one-shot hardening container, including when it already exited.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "${REPO_ROOT}/compose.yaml")

die() { echo "ERROR: $*" >&2; exit 1; }

BOOTSTRAP_ID="$("${COMPOSE[@]}" ps -aq dynsec-bootstrap)"
[[ -n "${BOOTSTRAP_ID}" ]] || die "Dynamic Security bootstrap container was not created."

docker wait "${BOOTSTRAP_ID}" >/dev/null
BOOTSTRAP_EXIT="$(docker inspect --format '{{.State.ExitCode}}' "${BOOTSTRAP_ID}")"
if [[ "${BOOTSTRAP_EXIT}" -ne 0 ]]; then
  "${COMPOSE[@]}" logs dynsec-bootstrap >&2
  die "Dynamic Security bootstrap failed with exit code ${BOOTSTRAP_EXIT}."
fi

echo "==> Dynamic Security bootstrap completed."
