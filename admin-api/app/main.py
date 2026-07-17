from __future__ import annotations

import csv
import io
import json
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Any, Callable

from authlib.integrations.starlette_client import OAuth
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, RedirectResponse, StreamingResponse
from sqlalchemy import delete, or_, select, text
from sqlalchemy.orm import Session
from starlette.middleware.sessions import SessionMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from .audit import append_event, verify_chain
from .auth import (
    Actor,
    ROLES,
    SESSION_COOKIE,
    clear_session_cookies,
    create_session,
    current_actor,
    digest,
    ensure_bootstrap_operator,
    rate_limiter,
    require_csrf,
    require_mutation_role,
    require_role,
    source_ip,
    verify_password,
)
from .broker import BrokerError, MosquittoAdapter
from .config import get_settings
from .db import SessionLocal, engine, get_db
from .models import AuditEvent, Operator, OperatorSession
from .policy import evaluate_permission
from .schemas import ACLCreate, Assignment, ClientCreate, LoginRequest, NamedObject, PasswordRotate, PermissionQuery


settings = get_settings()
broker = MosquittoAdapter(settings)
logger = logging.getLogger("admin-api")
logging.basicConfig(level=os.getenv("ADMIN_LOG_LEVEL", "INFO"), format='{"time":"%(asctime)s","level":"%(levelname)s","message":"%(message)s"}')

oauth = OAuth()
if settings.oidc_enabled:
    oauth.register(
        name="oidc",
        server_metadata_url=settings.oidc_discovery_url,
        client_id=settings.oidc_client_id,
        client_secret=settings.oidc_client_secret,
        client_kwargs={"scope": "openid profile email"},
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    with SessionLocal() as db:
        ensure_bootstrap_operator(db, settings)
        db.execute(delete(OperatorSession).where(OperatorSession.expires_at < datetime.now(timezone.utc)))
        db.commit()
    yield


app = FastAPI(title="MQTT Broker Administration API", version="0.1.0", lifespan=lifespan, docs_url=None, redoc_url=None)
app.add_middleware(TrustedHostMiddleware, allowed_hosts=list(settings.allowed_hosts) or ["localhost"])
app.add_middleware(
    SessionMiddleware,
    secret_key=settings.session_secret or "development-only-oidc-state-key",
    session_cookie="mqtt_admin_oidc_state",
    same_site="lax",
    https_only=settings.cookie_secure,
)


@app.exception_handler(BrokerError)
async def broker_error_handler(request: Request, exc: BrokerError) -> JSONResponse:
    return JSONResponse(
        {"detail": str(exc)},
        status_code=status.HTTP_502_BAD_GATEWAY,
        headers={"X-Correlation-ID": getattr(request.state, "correlation_id", "")},
    )


@app.middleware("http")
async def request_context(request: Request, call_next: Callable):
    correlation_id = request.headers.get("x-correlation-id", str(uuid.uuid4()))[:64]
    request.state.correlation_id = correlation_id
    response = await call_next(request)
    response.headers["X-Correlation-ID"] = correlation_id
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none'"
    return response


def audit(
    db: Session,
    request: Request,
    *,
    actor: Actor | None,
    action: str,
    target: str,
    result: str,
    metadata: dict[str, Any] | None = None,
) -> None:
    append_event(
        db,
        actor_id=actor.subject if actor else None,
        actor_role=actor.role if actor else None,
        source_ip=source_ip(request),
        correlation_id=request.state.correlation_id,
        action=action,
        target=target,
        result=result,
        metadata=metadata,
    )


def broker_mutation(
    db: Session,
    request: Request,
    actor: Actor,
    *,
    action: str,
    target: str,
    command: str,
    before: dict[str, Any] | None = None,
    after: dict[str, Any] | None = None,
    **data: Any,
) -> dict[str, Any]:
    try:
        rate_limiter.check(f"mutation:{actor.subject}:{source_ip(request)}", limit=60, window_seconds=60)
    except HTTPException:
        audit(db, request, actor=actor, action=action, target=target, result="rate_limited")
        raise
    try:
        result = broker.command(command, **data)
        audit(db, request, actor=actor, action=action, target=target, result="success", metadata={"before": before, "after": after if after is not None else result})
        return result
    except BrokerError as exc:
        audit(db, request, actor=actor, action=action, target=target, result="failure", metadata={"before": before, "error": str(exc)})
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc


def require_confirmation(value: str | None, expected: str) -> None:
    if value != expected:
        raise HTTPException(status.HTTP_409_CONFLICT, f"Confirm this action with X-Confirm-Action: {expected}")


@app.get("/health/live")
def liveness() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/health/ready")
def readiness() -> JSONResponse:
    failures: list[str] = []
    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
    except Exception:
        failures.append("database")
    if not settings.broker_password or not Path(settings.broker_ca_file).is_file():
        failures.append("broker_credentials")
    else:
        try:
            broker.command("getDefaultACLAccess")
        except BrokerError:
            failures.append("broker")
    if settings.environment == "production" and not settings.session_secret:
        failures.append("session_secret")
    status_code = 200 if not failures else 503
    return JSONResponse({"status": "ready" if not failures else "not_ready", "failures": failures}, status_code=status_code)


@app.get("/api/v1/capabilities")
def capabilities() -> dict[str, Any]:
    return {"local_auth": settings.local_auth_enabled, "oidc": settings.oidc_enabled}


@app.post("/api/v1/auth/login")
def login(payload: LoginRequest, request: Request, response: Response, db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    if not settings.local_auth_enabled:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Local authentication is disabled")
    try:
        rate_limiter.check(f"login:{source_ip(request)}:{payload.username}", limit=5, window_seconds=300)
    except HTTPException:
        audit(db, request, actor=None, action="auth.login", target=f"local:{payload.username}", result="rate_limited")
        raise
    operator = db.scalar(select(Operator).where(Operator.subject == f"local:{payload.username}"))
    if operator is None or not operator.enabled or not verify_password(payload.password, operator.password_hash):
        audit(db, request, actor=None, action="auth.login", target=f"local:{payload.username}", result="failure")
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid credentials")
    csrf = create_session(db, operator, request, response, settings)
    actor = Actor(operator, db.scalar(select(OperatorSession).where(OperatorSession.csrf_hash == digest(csrf))))
    audit(db, request, actor=actor, action="auth.login", target=operator.subject, result="success")
    return {"operator": operator_view(operator), "csrf_token": csrf}


@app.get("/api/v1/auth/oidc/login")
async def oidc_login(request: Request, db: Annotated[Session, Depends(get_db)]):
    if not settings.oidc_enabled:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "OIDC is not configured")
    try:
        rate_limiter.check(f"oidc:{source_ip(request)}", limit=10, window_seconds=300)
    except HTTPException:
        audit(db, request, actor=None, action="auth.oidc_start", target="oidc", result="rate_limited")
        raise
    return await oauth.oidc.authorize_redirect(request, f"{settings.public_url}/api/v1/auth/oidc/callback")


@app.get("/api/v1/auth/oidc/callback")
async def oidc_callback(request: Request, db: Annotated[Session, Depends(get_db)]):
    if not settings.oidc_enabled:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "OIDC is not configured")
    response = RedirectResponse("/")
    try:
        token = await oauth.oidc.authorize_access_token(request)
        claims = token.get("userinfo") or await oauth.oidc.userinfo(token=token)
        subject = f"oidc:{claims.get('iss', settings.oidc_discovery_url)}:{claims['sub']}"
        raw_role = claims.get(settings.oidc_role_claim, "viewer")
        if isinstance(raw_role, list):
            raw_role = next((role for role in reversed(ROLES) if role in raw_role), "viewer")
        role = raw_role if raw_role in ROLES else "viewer"
        operator = db.scalar(select(Operator).where(Operator.subject == subject))
        if operator is None:
            operator = Operator(subject=subject, display_name=claims.get("name") or claims.get("email") or claims["sub"], role=role)
            db.add(operator)
        else:
            operator.display_name = claims.get("name") or operator.display_name
            operator.role = role
        db.commit()
        db.refresh(operator)
        csrf = create_session(db, operator, request, response, settings)
        actor = Actor(operator, db.scalar(select(OperatorSession).where(OperatorSession.csrf_hash == digest(csrf))))
        audit(db, request, actor=actor, action="auth.oidc_login", target=subject, result="success")
        return response
    except Exception as exc:
        audit(db, request, actor=None, action="auth.oidc_login", target="oidc", result="failure", metadata={"error": type(exc).__name__})
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "OIDC authentication failed") from exc


@app.post("/api/v1/auth/logout")
def logout(request: Request, response: Response, actor: Annotated[Actor, Depends(require_csrf)], db: Annotated[Session, Depends(get_db)]) -> dict[str, bool]:
    db.delete(actor.session)
    db.commit()
    clear_session_cookies(response, settings)
    audit(db, request, actor=actor, action="auth.logout", target=actor.subject, result="success")
    return {"ok": True}


def operator_view(operator: Operator) -> dict[str, Any]:
    return {"subject": operator.subject, "display_name": operator.display_name, "role": operator.role}


@app.get("/api/v1/auth/me")
def me(actor: Annotated[Actor, Depends(current_actor)]) -> dict[str, Any]:
    return operator_view(actor.operator)


@app.get("/api/v1/overview")
def overview(request: Request, actor: Annotated[Actor, Depends(require_role("viewer"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    status_data = broker.overview()
    certificate = broker.certificate_status()
    backup_file = Path(settings.backup_marker_file)
    if backup_file.is_file():
        age_hours = (datetime.now(timezone.utc).timestamp() - backup_file.stat().st_mtime) / 3600
        backup = {"state": "healthy" if age_hours <= settings.backup_max_age_hours else "degraded", "age_hours": round(age_hours, 1), "max_age_hours": settings.backup_max_age_hours}
    else:
        backup = {"state": "unavailable", "age_hours": None, "max_age_hours": settings.backup_max_age_hours}
    audit(db, request, actor=actor, action="overview.read", target="broker", result="success")
    return {
        "broker": status_data,
        "certificate": certificate,
        "persistence": {"state": "healthy" if status_data["reachable"] else "unavailable", "enabled": True, "backup": backup},
        "listeners": [
            {"port": 1883, "protocol": "MQTT", "exposure": "internal", "authentication": "Dynamic Security"},
            {"port": 8883, "protocol": "MQTTS", "exposure": "edge", "authentication": "TLS + Dynamic Security"},
            {"port": 9001, "protocol": "WSS", "exposure": "localhost", "authentication": "TLS + Dynamic Security"},
            {"port": 1884, "protocol": "MQTTS", "exposure": "control-only", "authentication": "TLS + Dynamic Security"},
        ],
    }


@app.get("/api/v1/clients")
def list_clients(actor: Annotated[Actor, Depends(require_role("viewer"))], q: str = Query("", max_length=128)) -> list[dict[str, Any]]:
    clients = broker.list_objects("Clients")
    if q:
        needle = q.casefold()
        clients = [client for client in clients if needle in str(client.get("username", "")).casefold() or needle in str(client.get("clientid", "")).casefold()]
    return clients


@app.post("/api/v1/clients", status_code=201)
def create_client(payload: ClientCreate, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    data = payload.model_dump(exclude_none=True)
    safe_after = {key: value for key, value in data.items() if key != "password"}
    safe_after["disabled"] = False
    broker_mutation(db, request, actor, action="client.create", target=f"client:{payload.username}", command="createClient", after=safe_after, **data)
    # Password is intentionally never returned.
    return broker.command("getClient", username=payload.username)


@app.post("/api/v1/clients/{username}/password")
def rotate_password(username: str, payload: PasswordRotate, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, bool]:
    before = broker.command("getClient", username=username)
    broker_mutation(db, request, actor, action="client.password.rotate", target=f"client:{username}", command="setClientPassword", before=before, after={"username": username, "credential": "rotated"}, username=username, password=payload.password)
    return {"rotated": True}


@app.post("/api/v1/clients/{username}/{operation}")
def client_state(username: str, operation: str, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    if operation not in {"enable", "disable"}:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Unknown client operation")
    before = broker.command("getClient", username=username)
    broker_mutation(db, request, actor, action=f"client.{operation}", target=f"client:{username}", command=f"{operation}Client", before=before, after={"username": username, "disabled": operation == "disable"}, username=username)
    return broker.command("getClient", username=username)


@app.delete("/api/v1/clients/{username}")
def delete_client(username: str, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)], confirmation: Annotated[str | None, Header(alias="X-Confirm-Action")] = None) -> Response:
    require_confirmation(confirmation, f"delete client {username}")
    before = broker.command("getClient", username=username)
    broker_mutation(db, request, actor, action="client.delete", target=f"client:{username}", command="deleteClient", before=before, after={"username": username, "deleted": True}, username=username)
    return Response(status_code=204)


@app.put("/api/v1/clients/{username}/roles")
def assign_client_role(username: str, payload: Assignment, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    broker_mutation(db, request, actor, action="client.role.assign", target=f"client:{username}/role:{payload.name}", command="addClientRole", username=username, rolename=payload.name, priority=payload.priority)
    return broker.command("getClient", username=username)


@app.delete("/api/v1/clients/{username}/roles/{rolename}")
def remove_client_role(username: str, rolename: str, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    broker_mutation(db, request, actor, action="client.role.remove", target=f"client:{username}/role:{rolename}", command="removeClientRole", username=username, rolename=rolename)
    return broker.command("getClient", username=username)


@app.put("/api/v1/clients/{username}/groups")
def assign_client_group(username: str, payload: Assignment, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    broker_mutation(db, request, actor, action="client.group.assign", target=f"client:{username}/group:{payload.name}", command="addGroupClient", groupname=payload.name, username=username, priority=payload.priority)
    return broker.command("getClient", username=username)


@app.delete("/api/v1/clients/{username}/groups/{groupname}")
def remove_client_group(username: str, groupname: str, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    broker_mutation(db, request, actor, action="client.group.remove", target=f"client:{username}/group:{groupname}", command="removeGroupClient", groupname=groupname, username=username)
    return broker.command("getClient", username=username)


def _object_routes(kind: str) -> tuple[str, str, str]:
    return kind.lower(), f"{kind.lower()}name", kind.capitalize()


@app.get("/api/v1/groups")
def list_groups(actor: Annotated[Actor, Depends(require_role("viewer"))]) -> list[dict[str, Any]]:
    return broker.list_objects("Groups")


@app.post("/api/v1/groups", status_code=201)
def create_group(payload: NamedObject, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    fields = payload.model_dump(exclude_none=True)
    fields["groupname"] = fields.pop("name")
    broker_mutation(db, request, actor, action="group.create", target=f"group:{payload.name}", command="createGroup", **fields)
    return broker.command("getGroup", groupname=payload.name)


@app.patch("/api/v1/groups/{groupname}")
def update_group(groupname: str, payload: NamedObject, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    before = broker.command("getGroup", groupname=groupname)
    fields = payload.model_dump(exclude_none=True, exclude={"name"})
    broker_mutation(db, request, actor, action="group.update", target=f"group:{groupname}", command="modifyGroup", before=before, groupname=groupname, **fields)
    return broker.command("getGroup", groupname=groupname)


@app.delete("/api/v1/groups/{groupname}")
def delete_group(groupname: str, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)], confirmation: Annotated[str | None, Header(alias="X-Confirm-Action")] = None) -> Response:
    require_confirmation(confirmation, f"delete group {groupname}")
    before = broker.command("getGroup", groupname=groupname)
    broker_mutation(db, request, actor, action="group.delete", target=f"group:{groupname}", command="deleteGroup", before=before, groupname=groupname)
    return Response(status_code=204)


@app.put("/api/v1/groups/{groupname}/roles")
def assign_group_role(groupname: str, payload: Assignment, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    broker_mutation(db, request, actor, action="group.role.assign", target=f"group:{groupname}/role:{payload.name}", command="addGroupRole", groupname=groupname, rolename=payload.name, priority=payload.priority)
    return broker.command("getGroup", groupname=groupname)


@app.delete("/api/v1/groups/{groupname}/roles/{rolename}")
def remove_group_role(groupname: str, rolename: str, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    broker_mutation(db, request, actor, action="group.role.remove", target=f"group:{groupname}/role:{rolename}", command="removeGroupRole", groupname=groupname, rolename=rolename)
    return broker.command("getGroup", groupname=groupname)


@app.get("/api/v1/roles")
def list_roles(actor: Annotated[Actor, Depends(require_role("viewer"))]) -> list[dict[str, Any]]:
    return broker.list_objects("Roles")


@app.post("/api/v1/roles", status_code=201)
def create_role(payload: NamedObject, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    fields = payload.model_dump(exclude_none=True)
    fields["rolename"] = fields.pop("name")
    broker_mutation(db, request, actor, action="role.create", target=f"role:{payload.name}", command="createRole", **fields)
    return broker.command("getRole", rolename=payload.name)


@app.patch("/api/v1/roles/{rolename}")
def update_role(rolename: str, payload: NamedObject, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    before = broker.command("getRole", rolename=rolename)
    fields = payload.model_dump(exclude_none=True, exclude={"name"})
    broker_mutation(db, request, actor, action="role.update", target=f"role:{rolename}", command="modifyRole", before=before, rolename=rolename, **fields)
    return broker.command("getRole", rolename=rolename)


@app.delete("/api/v1/roles/{rolename}")
def delete_role(rolename: str, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)], confirmation: Annotated[str | None, Header(alias="X-Confirm-Action")] = None) -> Response:
    require_confirmation(confirmation, f"delete role {rolename}")
    before = broker.command("getRole", rolename=rolename)
    broker_mutation(db, request, actor, action="role.delete", target=f"role:{rolename}", command="deleteRole", before=before, rolename=rolename)
    return Response(status_code=204)


@app.post("/api/v1/roles/{rolename}/acls", status_code=201)
def add_acl(rolename: str, payload: ACLCreate, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    if payload.topic in {"#", "$CONTROL/#", "$SYS/#"} and payload.allow and not payload.elevated_confirmation:
        raise HTTPException(status.HTTP_409_CONFLICT, "Broad allow rules require elevated_confirmation")
    if payload.topic.startswith("$CONTROL/") and actor.role != "super_admin":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only super_admin may grant control-topic access")
    fields = payload.model_dump(exclude={"elevated_confirmation"})
    broker_mutation(db, request, actor, action="role.acl.add", target=f"role:{rolename}/acl:{payload.acltype}:{payload.topic}", command="addRoleACL", rolename=rolename, **fields)
    return broker.command("getRole", rolename=rolename)


@app.delete("/api/v1/roles/{rolename}/acls")
def remove_acl(rolename: str, request: Request, actor: Annotated[Actor, Depends(require_mutation_role("security_admin"))], db: Annotated[Session, Depends(get_db)], acltype: str = Query(...), topic: str = Query(...)) -> dict[str, Any]:
    require_confirmation(request.headers.get("X-Confirm-Action"), f"remove ACL {rolename} {acltype} {topic}")
    broker_mutation(db, request, actor, action="role.acl.remove", target=f"role:{rolename}/acl:{acltype}:{topic}", command="removeRoleACL", rolename=rolename, acltype=acltype, topic=topic)
    return broker.command("getRole", rolename=rolename)


@app.post("/api/v1/permissions/evaluate")
def evaluate(payload: PermissionQuery, request: Request, actor: Annotated[Actor, Depends(require_role("viewer"))], db: Annotated[Session, Depends(get_db)]) -> dict[str, Any]:
    client_data = broker.command("getClient", username=payload.username)
    client = client_data.get("client", client_data)
    group_items = broker.list_objects("Groups")
    role_items = broker.list_objects("Roles")
    groups = {item.get("groupname", ""): item for item in group_items}
    roles = {item.get("rolename", ""): item for item in role_items}
    defaults_data = broker.command("getDefaultACLAccess")
    defaults = {item["acltype"]: bool(item["allow"]) for item in defaults_data.get("acls", [])}
    result = evaluate_permission(client=client, groups=groups, roles=roles, username=payload.username, clientid=payload.clientid, topic=payload.topic, action=payload.action, defaults=defaults)
    audit(db, request, actor=actor, action="permission.evaluate", target=f"client:{payload.username}", result="success", metadata={"query": payload.model_dump(), "decision": result["decision"]})
    return result


@app.get("/api/v1/connections")
def connections(actor: Annotated[Actor, Depends(require_role("viewer"))]) -> dict[str, Any]:
    clients = broker.list_objects("Clients")
    rows: list[dict[str, Any]] = []
    observed_at = datetime.now(timezone.utc).isoformat()
    for client in clients:
        connections_data = client.get("connections") or []
        if connections_data:
            for connection in connections_data:
                rows.append({
                    "username": client.get("username"), "clientid": client.get("clientid"),
                    "state": "online", "listener": None, "last_seen": observed_at,
                    "unavailable_fields": ["listener"] + ([] if client.get("clientid") else ["clientid"]),
                    **connection,
                })
        else:
            rows.append({
                "username": client.get("username"), "clientid": client.get("clientid"),
                "state": "offline", "listener": None, "last_seen": None,
                "unavailable_fields": ["listener", "last_seen"] + ([] if client.get("clientid") else ["clientid"]),
            })
    return {"source": "Dynamic Security listClients(verbose)", "observed_at": observed_at, "freshness": "live", "connections": rows}


def audit_view(event: AuditEvent) -> dict[str, Any]:
    return {
        "id": event.id, "sequence": event.sequence, "occurred_at": event.occurred_at.isoformat(),
        "actor_id": event.actor_id, "actor_role": event.actor_role, "source_ip": event.source_ip,
        "correlation_id": event.correlation_id, "action": event.action, "target": event.target,
        "result": event.result, "metadata": json.loads(event.metadata_json),
        "previous_hash": event.previous_hash, "event_hash": event.event_hash,
    }


@app.get("/api/v1/audit")
def audit_history(
    actor: Annotated[Actor, Depends(require_role("viewer"))],
    db: Annotated[Session, Depends(get_db)],
    action: str | None = None,
    result: str | None = None,
    q: str | None = None,
    limit: int = Query(100, ge=1, le=1000),
) -> dict[str, Any]:
    query = select(AuditEvent)
    if action:
        query = query.where(AuditEvent.action == action)
    if result:
        query = query.where(AuditEvent.result == result)
    if q:
        query = query.where(or_(AuditEvent.target.contains(q), AuditEvent.actor_id.contains(q), AuditEvent.correlation_id.contains(q)))
    events = db.scalars(query.order_by(AuditEvent.sequence.desc()).limit(limit)).all()
    return {"chain": verify_chain(db), "events": [audit_view(event) for event in events]}


@app.get("/api/v1/audit/export")
def audit_export(request: Request, actor: Annotated[Actor, Depends(require_role("operator"))], db: Annotated[Session, Depends(get_db)], format: str = Query("jsonl", pattern="^(jsonl|csv)$")) -> StreamingResponse:
    audit(db, request, actor=actor, action="audit.export", target=f"audit:{format}", result="success")
    events = db.scalars(select(AuditEvent).order_by(AuditEvent.sequence)).all()
    if format == "csv":
        output = io.StringIO()
        writer = csv.DictWriter(output, fieldnames=list(audit_view(events[0]).keys()) if events else ["sequence"])
        writer.writeheader()
        for event in events:
            row = audit_view(event)
            row["metadata"] = json.dumps(row["metadata"], ensure_ascii=False, separators=(",", ":"))
            writer.writerow(row)
        media_type, filename, content = "text/csv", "mqtt-admin-audit.csv", output.getvalue()
    else:
        media_type, filename = "application/x-ndjson", "mqtt-admin-audit.jsonl"
        content = "".join(json.dumps(audit_view(event), ensure_ascii=False, separators=(",", ":")) + "\n" for event in events)
    return StreamingResponse(iter([content]), media_type=media_type, headers={"Content-Disposition": f'attachment; filename="{filename}"'})
