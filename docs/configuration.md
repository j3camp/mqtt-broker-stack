# Configuration

## Environment Variables

Copy `.env.example` to `.env` and adjust values before starting the broker.

| Variable | Default | Description |
|----------|---------|-------------|
| `MOSQUITTO_VERSION` | `2.0.21` | Mosquitto Docker image version |
| `MQTT_TLS_PORT` | `8883` | Host port for external TLS listener |
| `MQTT_TLS_BIND_ADDRESS` | `0.0.0.0` | Host address to bind external listener |
| `MQTT_INITIAL_USERNAME` | `admin` | Username created during init |
| `MQTT_SERVER_HOSTNAME` | `localhost` | Hostname for TLS certificate SAN |

## Mosquitto Configuration

Configuration is split into numbered files in `mosquitto/config/conf.d/`:

| File | Purpose |
|------|---------|
| `10-base.conf` | Global settings safe for all listeners |
| `20-internal.conf` | Internal listener (port 1883, anonymous, no TLS) |
| `30-external.conf` | External listener (port 8883, TLS, username/password) |
| `40-websocket.conf.example` | Optional WebSocket listener template |
| `50-acl.conf.example` | ACL configuration example |

Files load in numeric order due to `include_dir` in `mosquitto.conf`.

## ACL Configuration

ACL is optional. To enable:

1. Create `mosquitto/config/security/acl` (see `acl.example` for format).
2. Run `./scripts/enable-acl.sh`.

To disable: `./scripts/disable-acl.sh`

## Optional WebSocket Listener

To enable a Secure WebSocket listener on port 9001:

1. Copy `40-websocket.conf.example` to `40-websocket.conf` in the same directory.
2. Use the console compose override: `docker compose -f compose.yaml -f compose.console.yaml up -d`

The WebSocket listener reuses the same TLS certificates and password file as the external listener.

## MQTTX Web Console

MQTTX Web is an optional developer MQTT client. It is **not** a broker administration console.

To start with MQTTX Web:

```bash
docker compose -f compose.yaml -f compose.console.yaml up -d
```

Access via browser at `http://localhost:80` (or the configured `MQTTX_PORT`).

MQTTX Web limitations:
- MQTT connection testing only
- Cannot manage users, ACL, certificates, or Docker
