#!/bin/sh
# Replace Mosquitto 2.1 bootstrap defaults with the repository's least-privilege baseline.
set -eu

CTRL=/mosquitto/scripts/dynsec-entrypoint.sh
ADMIN="${DYNSEC_ADMIN_USERNAME:-admin}"

"${CTRL}" setDefaultACLAccess publishClientSend deny
"${CTRL}" setDefaultACLAccess publishClientReceive deny
"${CTRL}" setDefaultACLAccess subscribe deny
"${CTRL}" setDefaultACLAccess unsubscribe deny

# The bootstrap administrator keeps dynsec-admin and sys-observe. Remove any
# broader role that an upstream default or older state may have assigned.
for role in super-admin topic-observe client broker-admin sys-notify; do
  "${CTRL}" removeClientRole "${ADMIN}" "${role}" >/dev/null 2>&1 || true
done

# A demonstration identity must never survive production bootstrap.
"${CTRL}" deleteClient democlient >/dev/null 2>&1 || true
"${CTRL}" getClient "${ADMIN}" >/dev/null
echo "Dynamic Security least-privilege baseline applied."
