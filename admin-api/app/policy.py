from __future__ import annotations

import re
from typing import Any


def _priority(item: dict[str, Any]) -> int:
    return int(item.get("priority", -1))


def topic_matches(pattern: str, topic: str, username: str, clientid: str, literal: bool = False) -> bool:
    levels = pattern.split("/")
    expanded: list[str] = []
    for level in levels:
        if level == "%u":
            if not username:
                return False
            expanded.append(username)
        elif level == "%c":
            if not clientid:
                return False
            expanded.append(clientid)
        else:
            expanded.append(level)
    pattern = "/".join(expanded)
    # MQTT wildcard filters that do not start with '$' never match system
    # topics. Mosquitto applies the same boundary in Dynamic Security ACLs.
    if topic.startswith("$") and not pattern.startswith("$"):
        return False
    if literal:
        return pattern == topic
    expression = "^" + "/".join(
        ".*" if level == "#" else "[^/]+" if level == "+" else re.escape(level)
        for level in pattern.split("/")
    ) + "$"
    if pattern.endswith("/#"):
        expression = expression.replace("/.*$", "(?:/.*)?$")
    return re.match(expression, topic) is not None


def evaluate_permission(
    *,
    client: dict[str, Any],
    groups: dict[str, dict[str, Any]],
    roles: dict[str, dict[str, Any]],
    username: str,
    clientid: str,
    topic: str,
    action: str,
    defaults: dict[str, bool],
) -> dict[str, Any]:
    role_checks: list[tuple[str, str, dict[str, Any]]] = []
    for assignment in sorted(client.get("roles", []), key=lambda value: (-_priority(value), value.get("rolename", ""))):
        role_checks.append(("client", username, assignment))
    for group_assignment in sorted(client.get("groups", []), key=lambda value: (-_priority(value), value.get("groupname", ""))):
        group_name = group_assignment.get("groupname", "")
        group = groups.get(group_name, {})
        for assignment in sorted(group.get("roles", []), key=lambda value: (-_priority(value), value.get("rolename", ""))):
            role_checks.append(("group", group_name, assignment))

    for source_type, source_name, assignment in role_checks:
        role_name = assignment.get("rolename", "")
        role = roles.get(role_name, {})
        relevant = [acl for acl in role.get("acls", []) if acl.get("acltype") == action]
        relevant.sort(key=lambda value: -_priority(value))
        for acl in relevant:
            literal = action in {"subscribeLiteral", "unsubscribeLiteral"}
            if topic_matches(str(acl.get("topic", "")), topic, username, clientid, literal):
                return {
                    "decision": "allow" if acl.get("allow") else "deny",
                    "matched": True,
                    "rule": acl,
                    "source": {"type": source_type, "name": source_name, "role": role_name, "role_priority": _priority(assignment)},
                }
    default_key = "subscribe" if action.startswith("subscribe") else "unsubscribe" if action.startswith("unsubscribe") else action
    allowed = bool(defaults.get(default_key, False))
    return {"decision": "allow" if allowed else "deny", "matched": False, "rule": None, "source": {"type": "default", "name": default_key}}
