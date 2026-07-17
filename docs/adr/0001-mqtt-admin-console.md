# ADR-0001: MQTT Administration Console Architecture

## Status

Accepted on 2026-07-17. Related work: #3, #4, #5, and #6.

## Context

The project needs a graphical administration console without weakening the
existing split-listener trust model. Human operator identity must remain
separate from MQTT client identity. The browser must not receive a broker
administrator credential or Docker socket access. Runtime MQTT identity and ACL
changes must use Mosquitto Dynamic Security, and every privileged mutation must
be attributable and recoverable.

The evaluation compared Eclipse Mosquitto Dashboard, MqttCtl, and a custom
hybrid control plane using the requirements and weighted scorecard under
`docs/admin-console/`.

## Decision drivers

- Mosquitto Dynamic Security coverage and effective-permission analysis
- Server-side OIDC and operator RBAC
- Append-only, redacted administration audit events
- Compatibility with Mosquitto 2.1 and existing listener boundaries
- Explicit OSI-approved licensing and maintainable upstream dependencies
- No browser administrator credential, private-key download, or Docker socket
- Reuse of established observability and MQTT diagnostic components

## Considered options

### Eclipse Mosquitto Dashboard

The official dashboard is dual-licensed under EPL-2.0 or BSD-3-Clause and is
maintained in the Eclipse Mosquitto repository. Mosquitto 2.1 can serve it from
the native HTTP API listener. It is a good read-only broker-overview foundation,
but it currently exposes only system-tree and listener data. It does not provide
Dynamic Security, operator authentication, RBAC, audit, effective permissions,
or a Topic Explorer. It scored 36.0 and failed four required criteria.

### MqttCtl

MqttCtl is MIT-licensed and covers most functional requirements, including
Dynamic Security, OIDC, RBAC, chained audit records, effective permissions,
snapshots, and an MQTT explorer. Its upstream deployment builds a bundled
Mosquitto 2.0.21 broker-agent stack and has not demonstrated safe integration
with this project's Mosquitto 2.1 split-listener deployment. The project is also
very new and has no formal release. It scored 76.0 but failed deployment fit.

### Custom hybrid control plane

The custom hybrid option builds a thin Mosquitto adapter and operator control
plane while reusing the official Eclipse Mosquitto Dashboard concepts for
read-only broker overview, Grafana/Prometheus/Loki for observability, and MQTTX
or a constrained server-side relay for topic diagnostics. It scored 86.4 and was
the only option to meet every required criterion under the documented design.

## Decision

Adopt the custom hybrid control-plane architecture.

The production boundary is:

1. An OIDC-authenticated web application enforces server-side operator RBAC.
2. A Mosquitto adapter uses a dedicated least-privilege MQTT identity to call
   Dynamic Security; the browser never receives that credential.
3. Read-only broker overview may reuse or derive from Eclipse Mosquitto
   Dashboard, but its HTTP API is not exposed directly to untrusted networks.
4. Grafana, Prometheus, Alloy, and Loki remain the observability plane.
5. Topic diagnostics use a separate scoped MQTT identity and rate limits.
6. Privileged file/process operations go through an allow-listed runner with
   preview, validation, health verification, audit, and rollback. No component
   mounts `/var/run/docker.sock`.

MqttCtl remains a reference implementation and a review candidate, not a
production dependency. Cedalo Management Center is intentionally excluded from
the final evaluation in favor of the more openly governed Eclipse option.

## Consequences

Positive consequences:

- Security and deployment boundaries remain under project control.
- The implementation can match Mosquitto 2.1 and existing Compose conventions.
- Open upstream components can be reused without depending on a commercial
  edition boundary.
- Required audit and effective-permission behavior can be contract-tested.

Negative consequences:

- Initial delivery and long-term ownership cost are higher.
- The project must maintain the Mosquitto adapter, policy simulator, audit
  schema, and privileged workflow runner.
- Planned scorecard evidence must be replaced with runtime evidence before the
  production console is approved.

## Rollout and rollback

Roll out as an additive Compose profile. Begin with read-only overview and
observability, then add OIDC/RBAC, Dynamic Security read paths, previewed writes,
audit, and privileged workflows. Each mutation path requires contract tests,
least-privilege credentials, health checks, and an explicit rollback action.

The broker remains independently operable throughout rollout. Rollback disables
the administration profile, revokes its MQTT and OIDC credentials, restores the
last validated Dynamic Security/configuration snapshot when necessary, and
leaves broker data-plane listeners running.

## Review

Review date: 2026-10-17

Re-evaluate MqttCtl if it publishes a stable release, documents Mosquitto 2.1
compatibility, supports an external least-privilege broker-agent boundary, and
provides migration and upgrade evidence. Re-check the Eclipse Mosquitto
Dashboard for new management APIs or a supported release. Revisit this ADR if
any candidate satisfies every required scorecard criterion with verified rather
than planned evidence.
