from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .models import AuditEvent


REDACTED = "[REDACTED]"
SENSITIVE_KEYS = {"password", "secret", "token", "authorization", "cookie", "private_key", "payload"}


def _timestamp(value: datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: REDACTED if any(part in key.lower() for part in SENSITIVE_KEYS) else redact(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


def append_event(
    db: Session,
    *,
    actor_id: str | None,
    actor_role: str | None,
    source_ip: str,
    correlation_id: str,
    action: str,
    target: str,
    result: str,
    metadata: dict[str, Any] | None = None,
) -> AuditEvent:
    # Serialize writers at the database level on PostgreSQL. SQLite serializes
    # writes itself, which is sufficient for local development and tests.
    query = select(AuditEvent).order_by(AuditEvent.sequence.desc()).limit(1)
    if db.bind and db.bind.dialect.name == "postgresql":
        db.execute(select(func.pg_advisory_xact_lock(80472013)))
        query = query.with_for_update()
    previous = db.scalar(query)
    sequence = (previous.sequence + 1) if previous else 1
    previous_hash = previous.event_hash if previous else "0" * 64
    occurred_at = datetime.now(timezone.utc)
    safe_metadata = redact(metadata or {})
    canonical = json.dumps(
        {
            "sequence": sequence,
            "occurred_at": _timestamp(occurred_at),
            "actor_id": actor_id,
            "actor_role": actor_role,
            "source_ip": source_ip,
            "correlation_id": correlation_id,
            "action": action,
            "target": target,
            "result": result,
            "metadata": safe_metadata,
            "previous_hash": previous_hash,
        },
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    event = AuditEvent(
        sequence=sequence,
        occurred_at=occurred_at,
        actor_id=actor_id,
        actor_role=actor_role,
        source_ip=source_ip,
        correlation_id=correlation_id,
        action=action,
        target=target,
        result=result,
        metadata_json=json.dumps(safe_metadata, ensure_ascii=False, separators=(",", ":"), sort_keys=True),
        previous_hash=previous_hash,
        event_hash=hashlib.sha256(canonical.encode()).hexdigest(),
    )
    db.add(event)
    db.commit()
    db.refresh(event)
    return event


def verify_chain(db: Session) -> dict[str, Any]:
    events = db.scalars(select(AuditEvent).order_by(AuditEvent.sequence)).all()
    expected_previous = "0" * 64
    for expected_sequence, event in enumerate(events, 1):
        canonical = json.dumps(
            {
                "sequence": event.sequence,
                "occurred_at": _timestamp(event.occurred_at),
                "actor_id": event.actor_id,
                "actor_role": event.actor_role,
                "source_ip": event.source_ip,
                "correlation_id": event.correlation_id,
                "action": event.action,
                "target": event.target,
                "result": event.result,
                "metadata": json.loads(event.metadata_json),
                "previous_hash": event.previous_hash,
            },
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        calculated = hashlib.sha256(canonical.encode()).hexdigest()
        if event.sequence != expected_sequence or event.previous_hash != expected_previous or event.event_hash != calculated:
            return {"valid": False, "failed_sequence": event.sequence, "count": len(events)}
        expected_previous = event.event_hash
    return {"valid": True, "failed_sequence": None, "count": len(events), "head": expected_previous}


def count_events(db: Session) -> int:
    return int(db.scalar(select(func.count(AuditEvent.id))) or 0)
