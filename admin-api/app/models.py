from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, ForeignKey, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Operator(Base):
    __tablename__ = "operators"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    subject: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(String(255), nullable=False)
    role: Mapped[str] = mapped_column(String(32), nullable=False)
    password_hash: Mapped[str | None] = mapped_column(String(512))
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utcnow)
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    sessions: Mapped[list["OperatorSession"]] = relationship(back_populates="operator", cascade="all, delete-orphan")


class OperatorSession(Base):
    __tablename__ = "operator_sessions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    operator_id: Mapped[str] = mapped_column(ForeignKey("operators.id", ondelete="CASCADE"), nullable=False)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    csrf_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    source_ip: Mapped[str] = mapped_column(String(64), nullable=False)
    user_agent: Mapped[str] = mapped_column(String(512), nullable=False, default="")
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utcnow)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utcnow)
    operator: Mapped[Operator] = relationship(back_populates="sessions")


class AuditEvent(Base):
    __tablename__ = "audit_events"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    sequence: Mapped[int] = mapped_column(Integer, nullable=False, unique=True)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utcnow)
    actor_id: Mapped[str | None] = mapped_column(String(255))
    actor_role: Mapped[str | None] = mapped_column(String(32))
    source_ip: Mapped[str] = mapped_column(String(64), nullable=False)
    correlation_id: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    action: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    target: Mapped[str] = mapped_column(String(512), nullable=False, index=True)
    result: Mapped[str] = mapped_column(String(32), nullable=False)
    metadata_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")
    previous_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    event_hash: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)


Index("ix_audit_occurred_sequence", AuditEvent.occurred_at, AuditEvent.sequence)

