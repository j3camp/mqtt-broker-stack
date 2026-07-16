#!/usr/bin/env bash
# Initialise the mqtt-broker-stack for first use.
# Creates .env, directories, password file, initial user, and development TLS certs.
#
# Usage:
#   ./scripts/init.sh [--force]
#
# Non-interactive usage:
#   MQTT_INITIAL_USERNAME=admin \
#   MQTT_INITIAL_PASSWORD='change-me' \
#   MQTT_SERVER_HOSTNAME=mqtt.example.local \
#   ./scripts/init.sh
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE=false

usage() {
  cat >&2 <<EOF
Usage: $0 [--force]

Options:
  --force    Overwrite existing .env and regenerate secrets
  -h, --help Show this help
EOF
  exit 1
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# --- 1. Check Docker availability ---
info "Checking Docker..."
command -v docker >/dev/null 2>&1 || die "docker is required but not found."
docker info >/dev/null 2>&1 || die "Cannot connect to Docker daemon. Is Docker running?"

# --- 2. Check Docker Compose availability ---
info "Checking Docker Compose..."
if docker compose version >/dev/null 2>&1; then
  : # docker compose plugin available
elif command -v docker-compose >/dev/null 2>&1; then
  : # docker-compose standalone available
else
  die "Docker Compose is required but not found."
fi

# --- 3. Copy .env.example to .env ---
if [[ ! -f "${REPO_ROOT}/.env" ]] || [[ "${FORCE}" == "true" ]]; then
  info "Creating .env from .env.example..."
  cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
else
  info ".env already exists — skipping (use --force to overwrite)."
fi

# Load .env
set -o allexport
# shellcheck disable=SC1090
source "${REPO_ROOT}/.env"
set +o allexport

# --- 4. Create required runtime directories ---
info "Creating runtime directories..."
mkdir -p "${REPO_ROOT}/mosquitto/config/security"
mkdir -p "${REPO_ROOT}/mosquitto/config/certs"
mkdir -p "${REPO_ROOT}/certs/ca"
chmod 700 "${REPO_ROOT}/certs/ca"
mkdir -p "${REPO_ROOT}/backups"

# --- 5. Resolve initial username ---
MQTT_USER="${MQTT_INITIAL_USERNAME:-}"
if [[ -z "${MQTT_USER}" ]]; then
  read -rp "Initial MQTT username: " MQTT_USER
fi
[[ -n "${MQTT_USER}" ]] || die "MQTT username cannot be empty."
# Validate: alphanumeric, hyphen, underscore, dot only
if ! [[ "${MQTT_USER}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  die "Invalid username '${MQTT_USER}'. Use only alphanumeric characters, dots, hyphens, or underscores."
fi

# --- 6. Create initial external MQTT user ---
PASSWD_FILE="${REPO_ROOT}/mosquitto/config/security/passwords"
if [[ -f "${PASSWD_FILE}" ]] && [[ "${FORCE}" != "true" ]]; then
  info "Password file already exists — skipping user creation (use --force to recreate)."
else
  info "Creating Mosquitto password file..."
  # Resolve password
  MQTT_PASS="${MQTT_INITIAL_PASSWORD:-}"
  if [[ -z "${MQTT_PASS}" ]]; then
    read -rsp "Password for '${MQTT_USER}': " MQTT_PASS
    echo
    read -rsp "Confirm password: " MQTT_PASS2
    echo
    [[ "${MQTT_PASS}" == "${MQTT_PASS2}" ]] || die "Passwords do not match."
  fi
  [[ -n "${MQTT_PASS}" ]] || die "Password cannot be empty."

  MOSQUITTO_IMG="eclipse-mosquitto:${MOSQUITTO_VERSION:-2.0.21}"

  # Create password file using stdin to avoid exposing password in process listing
  TMPPASSWD="$(mktemp)"
  trap 'rm -f "${TMPPASSWD}"' EXIT

  if command -v mosquitto_passwd >/dev/null 2>&1; then
    # Use local mosquitto_passwd if available
    mosquitto_passwd -b -c "${TMPPASSWD}" "${MQTT_USER}" "${MQTT_PASS}"
  else
    # Use docker to run mosquitto_passwd; pass password via stdin
    printf '%s' "${MQTT_PASS}" | docker run --rm -i \
      --entrypoint sh \
      "${MOSQUITTO_IMG}" \
      -c "read -r pw; mosquitto_passwd -b -c /tmp/pw '${MQTT_USER}' \"\${pw}\"; cat /tmp/pw" \
      > "${TMPPASSWD}"
  fi

  [[ -s "${TMPPASSWD}" ]] || die "Failed to create password file."
  cp "${TMPPASSWD}" "${PASSWD_FILE}"
  chmod 600 "${PASSWD_FILE}"
  unset MQTT_PASS MQTT_PASS2 TMPPASSWD
  info "Password file created for user '${MQTT_USER}'."
fi

# --- 7. Generate development TLS certificates ---
if [[ -f "${REPO_ROOT}/mosquitto/config/certs/server.crt" ]] && [[ "${FORCE}" != "true" ]]; then
  info "Server certificate already exists — skipping (use --force to regenerate)."
else
  info "Generating development TLS certificates..."
  HOSTNAME_VAL="${MQTT_SERVER_HOSTNAME:-localhost}"
  FORCE_FLAG=""
  [[ "${FORCE}" == "true" ]] && FORCE_FLAG="--force"
  # shellcheck disable=SC2086
  "${REPO_ROOT}/scripts/generate-cert.sh" --hostname "${HOSTNAME_VAL}" ${FORCE_FLAG}
fi

# --- 8. Validate generated Mosquitto configuration ---
info "Validating Mosquitto configuration..."
"${REPO_ROOT}/scripts/validate.sh" --quick || die "Configuration validation failed."

echo ""
echo "============================================================"
echo " Initialisation complete!"
echo "============================================================"
echo ""
echo "Next steps:"
echo "  Start the broker:      make up"
echo "  Check status:          make status"
echo "  View logs:             make logs"
echo "  Add another user:      make create-user"
echo "  Enable ACL:            make enable-acl"
echo "  Run tests:             make test"
echo ""
