#!/usr/bin/env bash
# Generate a development CA and Server certificate for Mosquitto TLS.
# The CA private key is stored in certs/ca/ (never mounted into Mosquitto).
# Server cert and key are placed in mosquitto/config/certs/.
#
# Usage:
#   ./scripts/generate-cert.sh [--hostname <name>] [--ip <addr>] [--days <n>] [--force]
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CA_DIR="${REPO_ROOT}/certs/ca"
CERT_DIR="${REPO_ROOT}/mosquitto/config/certs"

HOSTNAME_VAL="localhost"
IP_ADDRS=()
CA_DAYS=3650
SERVER_DAYS=825
FORCE=false

usage() {
  cat >&2 <<EOF
Usage: $0 [OPTIONS]

Options:
  --hostname <name>   Server hostname / DNS SAN (default: localhost)
  --ip <addr>         IP SAN (may be repeated)
  --days <n>          Server certificate validity in days (default: 825)
  --ca-days <n>       CA certificate validity in days (default: 3650)
  --force             Overwrite existing certificates
  -h, --help          Show this help
EOF
  exit 1
}

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) HOSTNAME_VAL="$2"; shift 2 ;;
    --ip)       IP_ADDRS+=("$2"); shift 2 ;;
    --days)     SERVER_DAYS="$2"; shift 2 ;;
    --ca-days)  CA_DAYS="$2"; shift 2 ;;
    --force)    FORCE=true; shift ;;
    -h|--help)  usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# Check for existing certificates
if [[ -f "${CERT_DIR}/server.crt" ]] && [[ "${FORCE}" != "true" ]]; then
  die "Server certificate already exists at ${CERT_DIR}/server.crt. Use --force to replace."
fi

command -v openssl >/dev/null 2>&1 || die "openssl is required but not found."

mkdir -p "${CA_DIR}" "${CERT_DIR}"
chmod 700 "${CA_DIR}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

echo "==> Generating development CA and Server certificate"
echo "    Hostname : ${HOSTNAME_VAL}"
echo "    Days     : server=${SERVER_DAYS}, CA=${CA_DAYS}"

# Build SAN extension string
SAN_ENTRIES="DNS:${HOSTNAME_VAL}"
for ip in "${IP_ADDRS[@]:-}"; do
  SAN_ENTRIES="${SAN_ENTRIES},IP:${ip}"
done
# Add localhost/127.0.0.1 for convenience if not already included
if [[ "${HOSTNAME_VAL}" != "localhost" ]]; then
  SAN_ENTRIES="${SAN_ENTRIES},DNS:localhost"
fi
if ! printf '%s' "${SAN_ENTRIES}" | grep -q "IP:127.0.0.1"; then
  SAN_ENTRIES="${SAN_ENTRIES},IP:127.0.0.1"
fi

# --- Generate CA key and self-signed certificate ---
echo "==> Creating CA key and certificate..."
openssl genrsa -out "${CA_DIR}/ca.key" 4096 2>/dev/null
chmod 600 "${CA_DIR}/ca.key"

openssl req -new -x509 \
  -key "${CA_DIR}/ca.key" \
  -out "${CA_DIR}/ca.crt" \
  -days "${CA_DAYS}" \
  -subj "/CN=mqtt-broker-stack Dev CA/O=mqtt-broker-stack/OU=Development" \
  -extensions v3_ca \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

# Copy public CA cert to the certs directory Mosquitto reads
cp "${CA_DIR}/ca.crt" "${CERT_DIR}/ca.crt"

# --- Generate Server key and certificate ---
echo "==> Creating server key and certificate..."
openssl genrsa -out "${TMPDIR}/server.key" 2048 2>/dev/null

# Create CSR
cat > "${TMPDIR}/server.cnf" <<CONFEOF
[req]
prompt = no
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = ${HOSTNAME_VAL}
O = mqtt-broker-stack
OU = MQTT Broker

[req_ext]
subjectAltName = ${SAN_ENTRIES}
CONFEOF

openssl req -new \
  -key "${TMPDIR}/server.key" \
  -out "${TMPDIR}/server.csr" \
  -config "${TMPDIR}/server.cnf"

# Sign with CA
cat > "${TMPDIR}/ext.cnf" <<EXTEOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${SAN_ENTRIES}
EXTEOF

openssl x509 -req \
  -in "${TMPDIR}/server.csr" \
  -CA "${CA_DIR}/ca.crt" \
  -CAkey "${CA_DIR}/ca.key" \
  -CAcreateserial \
  -out "${TMPDIR}/server.crt" \
  -days "${SERVER_DAYS}" \
  -sha256 \
  -extfile "${TMPDIR}/ext.cnf"

# Install server certificate and key
cp "${TMPDIR}/server.crt" "${CERT_DIR}/server.crt"
cp "${TMPDIR}/server.key" "${CERT_DIR}/server.key"
# 644: world-readable so the Mosquitto process can read the key when the
# certs directory is mounted read-only in Docker (blocking the image's
# entrypoint chown).  The CA private key in CA_DIR keeps its 600 mode.
chmod 644 "${CERT_DIR}/server.key"

# Verify
echo "==> Verifying certificate chain..."
openssl verify -CAfile "${CERT_DIR}/ca.crt" "${CERT_DIR}/server.crt" >/dev/null
echo "==> Verifying certificate/key match..."
CERT_MOD="$(openssl x509 -noout -modulus -in "${CERT_DIR}/server.crt" | openssl md5)"
KEY_MOD="$(openssl rsa -noout -modulus -in "${CERT_DIR}/server.key" | openssl md5)"
[[ "${CERT_MOD}" == "${KEY_MOD}" ]] || die "Certificate and key modulus mismatch!"

echo ""
echo "Certificate details:"
openssl x509 -noout -subject -issuer -dates -ext subjectAltName \
  -in "${CERT_DIR}/server.crt" 2>/dev/null || true

echo ""
echo "==> Done."
echo "    CA cert    : ${CERT_DIR}/ca.crt  (distribute to clients)"
echo "    CA key     : ${CA_DIR}/ca.key    (SECRET — never commit)"
echo "    Server cert: ${CERT_DIR}/server.crt"
echo "    Server key : ${CERT_DIR}/server.key (SECRET)"
echo ""
echo "WARNING: This is a development certificate. Use a trusted CA for production."
