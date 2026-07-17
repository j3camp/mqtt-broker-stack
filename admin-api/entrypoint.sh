#!/bin/sh
set -eu

read_required_secret() {
  variable="$1"
  path="$2"
  test -s "${path}" || {
    echo "{\"level\":\"error\",\"message\":\"${path} is missing\"}" >&2
    exit 1
  }
  value="$(cat "${path}")"
  export "${variable}=${value}"
}

if [ -z "${ADMIN_DATABASE_URL:-}" ]; then
  read_required_secret ADMIN_DB_PASSWORD /run/secrets/admin_db_password
  ADMIN_DATABASE_URL="postgresql+psycopg://mqtt_admin:${ADMIN_DB_PASSWORD}@admin-db:5432/mqtt_admin"
  export ADMIN_DATABASE_URL
  unset ADMIN_DB_PASSWORD
fi

read_required_secret ADMIN_SESSION_SECRET /run/secrets/admin_session_secret
read_required_secret ADMIN_BOOTSTRAP_PASSWORD /run/secrets/admin_bootstrap_password
read_required_secret ADMIN_BROKER_PASSWORD /run/secrets/dynsec_admin_password

if [ -n "${ADMIN_OIDC_CLIENT_SECRET_FILE:-}" ]; then
  read_required_secret ADMIN_OIDC_CLIENT_SECRET "${ADMIN_OIDC_CLIENT_SECRET_FILE}"
  unset ADMIN_OIDC_CLIENT_SECRET_FILE
fi

# File-backed Compose secrets may preserve host ownership. Read them while the
# entrypoint is privileged, then permanently drop to the unprivileged account
# before opening the database or network sockets.
exec setpriv --reuid=10001 --regid=10001 --init-groups /bin/sh -c '
  alembic upgrade head
  exec uvicorn app.main:app \
    --host 0.0.0.0 \
    --port 8080 \
    --proxy-headers \
    --forwarded-allow-ips "${TRUSTED_PROXY_IPS:-127.0.0.1}"
'
