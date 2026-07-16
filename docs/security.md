# Security

## TLS

All external connections require TLS 1.2 or newer. Connections on port 8883 without valid TLS are rejected.

### Certificate Hierarchy

```
Development CA (certs/ca/ca.key + ca.crt)
  └── Server Certificate (mosquitto/config/certs/server.crt + server.key)
```

The CA private key is stored in `certs/ca/` — this directory is **never** mounted into Mosquitto.

### Certificate Requirements

- Server certificate must include Subject Alternative Name (DNS and/or IP).
- Server certificate uses SHA-256 signature.
- Server certificate must have `keyUsage: digitalSignature, keyEncipherment`.
- Server certificate must have `extendedKeyUsage: serverAuth`.
- `basicConstraints: CA:FALSE` on server certificate.

### Production Certificates

For production:

- Use a trusted CA (Let's Encrypt, internal PKI, or commercial CA).
- Do not use self-signed development certificates in production.
- Rotate server certificates before expiry.

## Authentication

External listener requires username and password. Passwords are stored in the Mosquitto password file format (bcrypt hashed). The password file is at `mosquitto/config/security/passwords`.

Passwords are never:
- Passed as command-line arguments.
- Logged or echoed.
- Stored in Git.

## Authorization (ACL)

ACL is disabled by default. When enabled, topic access is controlled per-user. See `mosquitto/config/security/acl.example` for examples.

Enable with: `./scripts/enable-acl.sh`
Disable with: `./scripts/disable-acl.sh`

## Sensitive Files

Files excluded from Git (see `.gitignore`):

| File | Reason |
|------|--------|
| `.env` | Contains deployment settings |
| `certs/ca/ca.key` | CA private key — never commit |
| `mosquitto/config/certs/server.key` | Server private key |
| `mosquitto/config/security/passwords` | Password hashes |
| `mosquitto/config/security/acl` | Runtime ACL |
| `backups/` | May contain sensitive data |

## Recommended File Permissions

| File | Recommended Mode |
|------|-----------------|
| `mosquitto/config/security/passwords` | `600` |
| `mosquitto/config/certs/server.key` | `600` |
| `certs/ca/ca.key` | `600` |

## Internal Listener Security

Port 1883 is accessible only via the `mqtt-internal` Docker bridge network. It is NOT published to the Docker host. Anonymous connections are allowed on this port for trusted containers.

Only add containers you trust to the `mqtt-internal` network.
