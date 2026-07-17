from __future__ import annotations

import hashlib
import hmac
import secrets
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Annotated, Callable

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from fastapi import Cookie, Depends, Header, HTTPException, Request, Response, status
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from .config import Settings, get_settings
from .db import get_db
from .models import Operator, OperatorSession


ROLES = {"viewer": 0, "operator": 1, "security_admin": 2, "super_admin": 3}
SESSION_COOKIE = "mqtt_admin_session"
CSRF_COOKIE = "mqtt_admin_csrf"
password_hasher = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def source_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


@dataclass(frozen=True)
class Actor:
    operator: Operator
    session: OperatorSession

    @property
    def subject(self) -> str:
        return self.operator.subject

    @property
    def role(self) -> str:
        return self.operator.role


class RateLimiter:
    def __init__(self) -> None:
        self._attempts: dict[str, deque[float]] = defaultdict(deque)

    def check(self, key: str, *, limit: int, window_seconds: int) -> None:
        now = time.monotonic()
        attempts = self._attempts[key]
        while attempts and attempts[0] <= now - window_seconds:
            attempts.popleft()
        if len(attempts) >= limit:
            raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many requests")
        attempts.append(now)


rate_limiter = RateLimiter()


def verify_password(password: str, password_hash: str | None) -> bool:
    if not password_hash:
        return False
    try:
        return password_hasher.verify(password_hash, password)
    except VerifyMismatchError:
        return False


def ensure_bootstrap_operator(db: Session, settings: Settings) -> None:
    if not settings.local_auth_enabled or not settings.bootstrap_password:
        return
    subject = f"local:{settings.bootstrap_username}"
    operator = db.scalar(select(Operator).where(Operator.subject == subject))
    if operator is None:
        db.add(
            Operator(
                subject=subject,
                display_name=settings.bootstrap_username,
                role="super_admin",
                password_hash=password_hasher.hash(settings.bootstrap_password),
            )
        )
        db.commit()


def create_session(db: Session, operator: Operator, request: Request, response: Response, settings: Settings) -> str:
    token, csrf = secrets.token_urlsafe(48), secrets.token_urlsafe(32)
    expires = datetime.now(timezone.utc) + timedelta(seconds=settings.session_ttl_seconds)
    db.add(
        OperatorSession(
            operator_id=operator.id,
            token_hash=digest(token),
            csrf_hash=digest(csrf),
            source_ip=source_ip(request),
            user_agent=request.headers.get("user-agent", "")[:512],
            expires_at=expires,
        )
    )
    operator.last_login_at = datetime.now(timezone.utc)
    db.commit()
    common = {"secure": settings.cookie_secure, "samesite": "strict", "path": "/"}
    response.set_cookie(SESSION_COOKIE, token, httponly=True, max_age=settings.session_ttl_seconds, **common)
    response.set_cookie(CSRF_COOKIE, csrf, httponly=False, max_age=settings.session_ttl_seconds, **common)
    return csrf


def clear_session_cookies(response: Response, settings: Settings) -> None:
    response.delete_cookie(SESSION_COOKIE, path="/", secure=settings.cookie_secure, samesite="strict")
    response.delete_cookie(CSRF_COOKIE, path="/", secure=settings.cookie_secure, samesite="strict")


def current_actor(
    db: Annotated[Session, Depends(get_db)],
    token: Annotated[str | None, Cookie(alias=SESSION_COOKIE)] = None,
) -> Actor:
    if not token:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Authentication required")
    session = db.scalar(select(OperatorSession).where(OperatorSession.token_hash == digest(token)))
    now = datetime.now(timezone.utc)
    if session is None or session.expires_at.replace(tzinfo=timezone.utc) <= now:
        if session:
            db.delete(session)
            db.commit()
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Session expired")
    operator = session.operator
    if not operator.enabled or operator.role not in ROLES:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Operator is disabled")
    session.last_seen_at = now
    db.commit()
    return Actor(operator=operator, session=session)


def require_role(minimum: str) -> Callable[..., Actor]:
    def dependency(actor: Annotated[Actor, Depends(current_actor)]) -> Actor:
        if ROLES[actor.role] < ROLES[minimum]:
            raise HTTPException(status.HTTP_403_FORBIDDEN, f"{minimum} role required")
        return actor
    return dependency


def require_csrf(
    actor: Annotated[Actor, Depends(current_actor)],
    csrf_header: Annotated[str | None, Header(alias="X-CSRF-Token")] = None,
    csrf_cookie: Annotated[str | None, Cookie(alias=CSRF_COOKIE)] = None,
) -> Actor:
    if not csrf_header or not csrf_cookie or not hmac.compare_digest(csrf_header, csrf_cookie):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "CSRF validation failed")
    if not hmac.compare_digest(digest(csrf_header), actor.session.csrf_hash):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "CSRF validation failed")
    return actor


def require_mutation_role(minimum: str) -> Callable[..., Actor]:
    def dependency(actor: Annotated[Actor, Depends(require_csrf)]) -> Actor:
        if ROLES[actor.role] < ROLES[minimum]:
            raise HTTPException(status.HTTP_403_FORBIDDEN, f"{minimum} role required")
        return actor
    return dependency

