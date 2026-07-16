# GitHub Copilot Instructions for `mqtt-broker-stack`

## Project Overview

`mqtt-broker-stack` is a Docker Compose-based commercial MQTT Broker deployment stack built around Eclipse Mosquitto.

The project starts as a secure, maintainable Mosquitto deployment package and may later expand with:

* User management
* ACL management
* TLS and certificate management
* Mutual TLS
* Monitoring and metrics
* Backup and restore
* Upgrade tooling
* Operations tooling
* A lightweight web administration console

Do not integrate Cedalo Management Center.

MQTTX Web may be integrated only as an optional developer MQTT client console. It must not be treated as the Broker administration console.

---

## Core Architecture

The Mosquitto Broker must provide separate internal and external listeners.

### Internal MQTT Listener

```text
Port: 1883
Protocol: MQTT
Network scope: Docker private network only
TLS: Disabled
Authentication: Disabled
ACL: Disabled
Anonymous access: Allowed
Host port mapping: Prohibited
```

Internal containers connect with:

```text
mosquitto:1883
```

Port `1883` must never appear under the Compose `ports` section.

Using `expose` is acceptable because it does not publish the port to the Docker host.

The internal listener is intended only for trusted containers connected to the private MQTT Docker network.

### External MQTT Listener

```text
Port: 8883
Protocol: MQTT over TLS
TLS: Required
Authentication: Username and password required
Anonymous access: Prohibited
ACL: Optional
Host port mapping: Enabled
```

The external listener must:

* Always use TLS.
* Require a valid username and password.
* Use a Mosquitto password file.
* Set `allow_anonymous false`.
* Support optional file-based ACL.
* Never provide plaintext MQTT on port `8883`.

Use:

```conf
per_listener_settings true
```

Listener-specific authentication and authorization settings must not unintentionally affect other listeners.

---

## Technical Stack

Use:

* Docker Compose
* Eclipse Mosquitto 2.x
* POSIX shell or Bash
* OpenSSL
* Mosquitto command-line tools
* Makefile
* GitHub Actions

Avoid adding another programming language unless it provides a clear operational benefit.

The Mosquitto image must use an explicit version supplied through `.env`.

Example:

```dotenv
MOSQUITTO_VERSION=2.1.2
```

Compose usage:

```yaml
image: eclipse-mosquitto:${MOSQUITTO_VERSION}
```

Do not use:

```text
latest
```

Do not use an unpinned floating image tag unless the task explicitly requires it.

---

## Expected Repository Structure

Prefer the following structure:

```text
mqtt-broker-stack/
├── .github/
│   ├── copilot-instructions.md
│   └── workflows/
│       └── ci.yml
├── compose.yaml
├── compose.console.yaml
├── .env.example
├── .gitignore
├── .editorconfig
├── Makefile
├── README.md
│
├── mosquitto/
│   ├── config/
│   │   ├── mosquitto.conf
│   │   ├── conf.d/
│   │   │   ├── 10-base.conf
│   │   │   ├── 20-internal.conf
│   │   │   ├── 30-external.conf
│   │   │   ├── 40-websocket.conf.example
│   │   │   └── 50-acl.conf.example
│   │   ├── security/
│   │   │   ├── .gitkeep
│   │   │   └── acl.example
│   │   └── certs/
│   │       └── .gitkeep
│   └── scripts/
│       └── healthcheck.sh
│
├── scripts/
│   ├── init.sh
│   ├── validate.sh
│   ├── generate-cert.sh
│   ├── create-user.sh
│   ├── change-password.sh
│   ├── delete-user.sh
│   ├── enable-acl.sh
│   ├── disable-acl.sh
│   ├── backup.sh
│   └── restore.sh
│
├── tests/
│   ├── test-internal.sh
│   ├── test-external-auth.sh
│   ├── test-external-anonymous-denied.sh
│   ├── test-tls-verification.sh
│   ├── test-acl.sh
│   └── test-healthcheck.sh
│
└── docs/
    ├── architecture.md
    ├── security.md
    ├── configuration.md
    └── operations.md
```

This layout may be adjusted when necessary, but configuration, runtime secrets, tests, operations scripts, and documentation must remain clearly separated.

---

## Docker Compose Requirements

The primary Mosquitto service must include:

* An explicitly versioned Mosquitto image.
* `restart: unless-stopped`.
* Host mapping for port `8883` only.
* No Host mapping for port `1883`.
* A private Docker network for internal MQTT clients.
* Persistent Mosquitto data.
* Configuration and certificate mounts.
* A protocol-level Docker healthcheck.
* A reasonable stop grace period.
* No privileged mode.
* No Docker socket mount.
* No CA private key mount.
* No unnecessary Linux capabilities.

---

## Shell Coding Standards

All maintained shell scripts must:

```bash
set -Eeuo pipefail
```

Also:

* Quote variable expansions.
* Correctly handle paths containing spaces.
* Validate external input.
* Use `mktemp` for temporary files.
* Use `trap` to clean temporary files.
* Avoid `eval`.
* Send error messages to stderr.
* Return meaningful exit codes.
* Avoid silently ignoring errors.
* Be safe to run repeatedly.
* Avoid requiring root unless necessary.
* Document operations that require elevated privileges.
* Avoid `chmod 777`.
* Avoid making private keys world-readable.
* Avoid exposing passwords in process listings or shell history.

---

## Instructions for Copilot Agent Mode

When asked to build or modify this repository:

* Modify files directly instead of only describing code.
* Inspect existing files before writing replacements.
* Avoid overwriting user changes unnecessarily.
* Implement complete vertical slices.
* Run available validation after each coherent phase.
* Fix errors discovered during validation.
* Do not leave required core behavior as a TODO.
* Clearly distinguish completed work from unverified work.
* If Docker is unavailable, complete static implementation and list the Docker-dependent tests that could not be run.
* Prefer official Mosquitto behavior and executable verification over assumptions.
