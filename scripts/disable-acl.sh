#!/usr/bin/env bash
set -Eeuo pipefail
echo "ERROR: Dynamic Security is mandatory on external listeners and cannot be disabled." >&2
exit 1
