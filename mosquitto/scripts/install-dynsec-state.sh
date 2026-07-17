#!/bin/sh
# Atomically install a validated DynSec state into the shared data volume.
set -eu

SOURCE_NAME="${1:-}"
case "${SOURCE_NAME}" in
  ""|*/*|*..*)
    echo "ERROR: Expected a migration file name without path separators." >&2
    exit 1
    ;;
esac

SOURCE="/migration/${SOURCE_NAME}"
TARGET="/mosquitto/data/dynamic-security.json"
TEMPORARY="${TARGET}.new"

test -s "${SOURCE}" || {
  echo "ERROR: Migration state does not exist or is empty: ${SOURCE}" >&2
  exit 1
}

cp "${SOURCE}" "${TEMPORARY}"
chown mosquitto:mosquitto "${TEMPORARY}"
chmod 600 "${TEMPORARY}"
mv "${TEMPORARY}" "${TARGET}"
