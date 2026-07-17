#!/usr/bin/env bash
# Contract test for the administration-console requirements, PoCs, scorecard, and ADR.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 "${REPO_ROOT}/tests/admin_console_architecture_test.py"
