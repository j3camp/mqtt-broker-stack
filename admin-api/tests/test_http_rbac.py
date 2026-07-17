from __future__ import annotations

from collections.abc import Iterator

import pytest
pytest.importorskip("argon2")
from fastapi.testclient import TestClient
from sqlalchemy import delete, select

from app.db import Base, SessionLocal, engine
from app.main import app, broker
from app.models import AuditEvent, Operator, OperatorSession


@pytest.fixture()
def client(monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    monkeypatch.setattr(broker, "overview", lambda: {
        "state": "healthy", "reachable": True, "version": "mosquitto version 2.1.2",
        "uptime": "60 seconds", "connected_clients": 2, "observed_at": "2026-07-17T00:00:00+00:00", "source": "$SYS",
    })
    monkeypatch.setattr(broker, "certificate_status", lambda: {
        "state": "healthy", "subject": "CN=localhost", "issuer": "CN=test-ca", "sans": ["localhost"],
        "not_after": "2027-07-17T00:00:00+00:00", "remaining_days": 365, "warning_threshold_days": 30,
    })
    monkeypatch.setattr(broker, "list_objects", lambda kind: [])

    def fake_command(command: str, **data):
        if command == "getDefaultACLAccess":
            return {"acls": [{"acltype": "publishClientSend", "allow": False}]}
        if command == "getClient":
            return {"username": data["username"], "disabled": False, "roles": [], "groups": []}
        return {}

    monkeypatch.setattr(broker, "command", fake_command)
    with TestClient(app) as test_client:
        yield test_client


def login(client: TestClient) -> str:
    response = client.post("/api/v1/auth/login", json={"username": "admin", "password": "a-secure-test-password"})
    assert response.status_code == 200
    return response.json()["csrf_token"]


def test_login_sets_protected_session_and_audits_success(client: TestClient) -> None:
    csrf = login(client)
    assert client.cookies.get("mqtt_admin_session")
    assert client.cookies.get("mqtt_admin_csrf") == csrf
    with SessionLocal() as db:
        event = db.scalar(select(AuditEvent).where(AuditEvent.action == "auth.login"))
        assert event.result == "success"
        assert event.actor_id == "local:admin"


def test_csrf_is_required_for_mutations(client: TestClient) -> None:
    login(client)
    response = client.post("/api/v1/clients", json={"username": "sensor", "password": "long-enough-password"})
    assert response.status_code == 403
    assert response.json()["detail"] == "CSRF validation failed"


def test_viewer_can_read_but_cannot_mutate(client: TestClient) -> None:
    csrf = login(client)
    with SessionLocal() as db:
        operator = db.scalar(select(Operator).where(Operator.subject == "local:admin"))
        operator.role = "viewer"
        db.commit()
    assert client.get("/api/v1/overview").status_code == 200
    response = client.post(
        "/api/v1/clients",
        headers={"X-CSRF-Token": csrf},
        json={"username": "sensor", "password": "long-enough-password"},
    )
    assert response.status_code == 403


def test_client_password_is_not_returned_or_written_to_audit(client: TestClient) -> None:
    csrf = login(client)
    password = "long-enough-password"
    response = client.post(
        "/api/v1/clients",
        headers={"X-CSRF-Token": csrf},
        json={"username": "sensor", "password": password},
    )
    assert response.status_code == 201
    assert password not in response.text
    with SessionLocal() as db:
        event = db.scalar(select(AuditEvent).where(AuditEvent.action == "client.create"))
        assert password not in event.metadata_json
        assert event.result == "success"


def test_password_rotation_uses_the_specific_route(client: TestClient) -> None:
    csrf = login(client)
    password = "another-long-password"
    response = client.post(
        "/api/v1/clients/sensor/password",
        headers={"X-CSRF-Token": csrf},
        json={"password": password},
    )
    assert response.status_code == 200
    assert response.json() == {"rotated": True}
    assert password not in response.text
    with SessionLocal() as db:
        event = db.scalar(select(AuditEvent).where(AuditEvent.action == "client.password.rotate"))
        assert password not in event.metadata_json
