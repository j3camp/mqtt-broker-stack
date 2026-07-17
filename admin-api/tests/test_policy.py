from __future__ import annotations

from app.policy import evaluate_permission, topic_matches


def test_topic_wildcards_and_substitution() -> None:
    assert topic_matches("devices/%u/+", "devices/sensor-1/temp", "sensor-1", "client-a")
    assert topic_matches("devices/%c/#", "devices/client-a", "sensor-1", "client-a")
    assert topic_matches("devices/%c/#", "devices/client-a/value", "sensor-1", "client-a")
    assert not topic_matches("devices/%u/+", "devices/other/temp", "sensor-1", "client-a")
    assert topic_matches("devices/+/state", "devices/a/state", "", "")
    assert not topic_matches("#", "$SYS/broker/version", "", "")
    assert topic_matches("$SYS/#", "$SYS/broker/version", "", "")


def test_literal_subscription_does_not_expand_wildcards() -> None:
    assert topic_matches("devices/+", "devices/+", "user", "id", literal=True)
    assert not topic_matches("devices/+", "devices/a", "user", "id", literal=True)


def test_client_roles_are_checked_before_higher_priority_groups() -> None:
    client = {
        "roles": [{"rolename": "client-deny", "priority": 1}],
        "groups": [{"groupname": "writers", "priority": 100}],
    }
    groups = {"writers": {"roles": [{"rolename": "group-allow", "priority": 100}]}}
    roles = {
        "client-deny": {"acls": [{"acltype": "publishClientSend", "topic": "devices/#", "allow": False, "priority": 1}]},
        "group-allow": {"acls": [{"acltype": "publishClientSend", "topic": "devices/#", "allow": True, "priority": 100}]},
    }
    result = evaluate_permission(
        client=client, groups=groups, roles=roles, username="sensor", clientid="a",
        topic="devices/a/value", action="publishClientSend", defaults={"publishClientSend": False},
    )
    assert result["decision"] == "deny"
    assert result["source"]["role"] == "client-deny"


def test_acl_priority_and_default_decision() -> None:
    roles = {
        "writer": {"acls": [
            {"acltype": "publishClientSend", "topic": "devices/#", "allow": True, "priority": 1},
            {"acltype": "publishClientSend", "topic": "devices/secret/#", "allow": False, "priority": 50},
        ]}
    }
    client = {"roles": [{"rolename": "writer", "priority": 10}], "groups": []}
    denied = evaluate_permission(client=client, groups={}, roles=roles, username="sensor", clientid="a", topic="devices/secret/key", action="publishClientSend", defaults={"publishClientSend": False})
    assert denied["decision"] == "deny"
    fallback = evaluate_permission(client={"roles": [], "groups": []}, groups={}, roles={}, username="sensor", clientid="a", topic="other", action="unsubscribePattern", defaults={"unsubscribe": True})
    assert fallback == {"decision": "allow", "matched": False, "rule": None, "source": {"type": "default", "name": "unsubscribe"}}
