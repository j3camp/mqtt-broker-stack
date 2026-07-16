#!/usr/bin/env bash
# Integration test: Docker healthcheck.
# Verifies the Mosquitto container reaches the 'healthy' Docker status.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="docker compose"
TIMEOUT=120

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

echo "--- Test: Mosquitto container reaches healthy status ---"

# Wait for the container to become healthy
DEADLINE=$((SECONDS + TIMEOUT))
while true; do
  STATUS="$(${COMPOSE} -f "${REPO_ROOT}/compose.yaml" ps --format json 2>/dev/null \
    | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
        if 'mosquitto' in d.get('Name','') or 'mosquitto' in d.get('Service',''):
            print(d.get('Health', d.get('State', 'unknown')))
            break
    except Exception:
        pass
" 2>/dev/null || true)"

  if [[ "${STATUS}" == "healthy" ]]; then
    pass "Mosquitto container is healthy"
    break
  fi

  if [[ $SECONDS -ge $DEADLINE ]]; then
    echo "Last healthcheck status: ${STATUS}"
    ${COMPOSE} -f "${REPO_ROOT}/compose.yaml" logs mosquitto --tail=20 >&2 || true
    die "Mosquitto container did not become healthy within ${TIMEOUT} seconds"
  fi

  echo "  Waiting for healthy status (current: ${STATUS:-unknown})..."
  sleep 5
done

echo ""
echo "Healthcheck test PASSED."
