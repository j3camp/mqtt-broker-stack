#!/bin/sh
# Make a root-owned Compose file secret readable only by the Mosquitto process.
set -eu

SOURCE=/run/secrets/dynsec_admin_password
TARGET=/tmp/dynsec_admin_password

test -s "${SOURCE}" || {
  echo "ERROR: Dynamic Security administrator secret is missing or empty." >&2
  exit 1
}

umask 077
cp "${SOURCE}" "${TARGET}"
chown mosquitto:mosquitto "${TARGET}"
chmod 400 "${TARGET}"

exec /docker-entrypoint.sh "$@"
