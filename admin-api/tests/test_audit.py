from __future__ import annotations

import json

from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session

from app.audit import append_event, redact, verify_chain
from app.db import Base
from app.models import AuditEvent


def database() -> Session:
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    return Session(engine)


def test_redaction_is_recursive() -> None:
    assert redact({"password": "value", "nested": {"api_token": "secret"}, "safe": "visible"}) == {
        "password": "[REDACTED]", "nested": {"api_token": "[REDACTED]"}, "safe": "visible"
    }


def test_audit_chain_is_verifiable_and_detects_tampering() -> None:
    db = database()
    append_event(db, actor_id="local:admin", actor_role="super_admin", source_ip="127.0.0.1", correlation_id="c1", action="client.create", target="client:sensor", result="success", metadata={"password": "never-store"})
    append_event(db, actor_id="local:admin", actor_role="super_admin", source_ip="127.0.0.1", correlation_id="c2", action="client.disable", target="client:sensor", result="success")
    assert verify_chain(db)["valid"] is True
    first = db.scalar(select(AuditEvent).where(AuditEvent.sequence == 1))
    assert json.loads(first.metadata_json)["password"] == "[REDACTED]"
    first.target = "client:tampered"
    db.commit()
    result = verify_chain(db)
    assert result["valid"] is False
    assert result["failed_sequence"] == 1

