#!/bin/sh
# Run mosquitto_ctrl from the isolated mqtt-control network without exposing
# the administrator password in the process arguments.
set -eu

SECRET_FILE="/run/secrets/dynsec_admin_password"
OPTIONS_FILE="/tmp/mosquitto_ctrl.options"

test -s "${SECRET_FILE}" || {
  echo "ERROR: Dynamic Security administrator secret is missing." >&2
  exit 1
}

umask 077
{
  printf '%s\n' "--cafile /mosquitto/config/certs/ca.crt"
  printf '%s\n' "-h ${MQTT_CONTROL_HOSTNAME:-mosquitto-control}"
  printf '%s\n' "-p 1884"
  printf '%s\n' "-u ${DYNSEC_ADMIN_USERNAME:-admin}"
  printf '%s\n' "-P $(cat "${SECRET_FILE}")"
} > "${OPTIONS_FILE}"

exec mosquitto_ctrl -o "${OPTIONS_FILE}" dynsec "$@"
