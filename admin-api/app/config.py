from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


def _read_secret(env_name: str, default_path: str | None = None) -> str:
    direct = os.getenv(env_name)
    if direct:
        return direct
    path = os.getenv(f"{env_name}_FILE", default_path or "")
    if path and Path(path).is_file():
        return Path(path).read_text(encoding="utf-8").strip()
    return ""


def _bool(name: str, default: bool) -> bool:
    return os.getenv(name, str(default)).lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    environment: str
    database_url: str
    public_url: str
    allowed_hosts: tuple[str, ...]
    cookie_secure: bool
    session_ttl_seconds: int
    session_secret: str
    local_auth_enabled: bool
    bootstrap_username: str
    bootstrap_password: str
    oidc_discovery_url: str
    oidc_client_id: str
    oidc_client_secret: str
    oidc_role_claim: str
    broker_host: str
    broker_port: int
    broker_username: str
    broker_password: str
    broker_ca_file: str
    broker_timeout_seconds: float
    certificate_file: str
    certificate_warning_days: int
    backup_max_age_hours: int
    backup_marker_file: str

    @property
    def oidc_enabled(self) -> bool:
        return bool(self.oidc_discovery_url and self.oidc_client_id and self.oidc_client_secret)


@lru_cache
def get_settings() -> Settings:
    environment = os.getenv("ADMIN_ENVIRONMENT", "production")
    return Settings(
        environment=environment,
        database_url=os.getenv("ADMIN_DATABASE_URL", "sqlite:///./admin.db"),
        public_url=os.getenv("ADMIN_PUBLIC_URL", "http://localhost:8088").rstrip("/"),
        allowed_hosts=tuple(v.strip() for v in os.getenv("ADMIN_ALLOWED_HOSTS", "localhost,127.0.0.1").split(",") if v.strip()),
        cookie_secure=_bool("ADMIN_COOKIE_SECURE", environment == "production"),
        session_ttl_seconds=int(os.getenv("ADMIN_SESSION_TTL_SECONDS", "28800")),
        session_secret=_read_secret("ADMIN_SESSION_SECRET", "/run/secrets/admin_session_secret"),
        local_auth_enabled=_bool("ADMIN_LOCAL_AUTH_ENABLED", environment != "production"),
        bootstrap_username=os.getenv("ADMIN_BOOTSTRAP_USERNAME", "admin"),
        bootstrap_password=_read_secret("ADMIN_BOOTSTRAP_PASSWORD", "/run/secrets/admin_bootstrap_password"),
        oidc_discovery_url=os.getenv("ADMIN_OIDC_DISCOVERY_URL", ""),
        oidc_client_id=os.getenv("ADMIN_OIDC_CLIENT_ID", ""),
        oidc_client_secret=_read_secret("ADMIN_OIDC_CLIENT_SECRET", "/run/secrets/admin_oidc_client_secret"),
        oidc_role_claim=os.getenv("ADMIN_OIDC_ROLE_CLAIM", "mqtt_admin_role"),
        broker_host=os.getenv("ADMIN_BROKER_HOST", "mosquitto-control"),
        broker_port=int(os.getenv("ADMIN_BROKER_PORT", "1884")),
        broker_username=os.getenv("DYNSEC_ADMIN_USERNAME", "admin"),
        broker_password=_read_secret("ADMIN_BROKER_PASSWORD", "/run/secrets/dynsec_admin_password"),
        broker_ca_file=os.getenv("ADMIN_BROKER_CA_FILE", "/mosquitto/config/certs/ca.crt"),
        broker_timeout_seconds=float(os.getenv("ADMIN_BROKER_TIMEOUT_SECONDS", "5")),
        certificate_file=os.getenv("ADMIN_CERTIFICATE_FILE", "/mosquitto/config/certs/server.crt"),
        certificate_warning_days=int(os.getenv("ADMIN_CERTIFICATE_WARNING_DAYS", "30")),
        backup_max_age_hours=int(os.getenv("ADMIN_BACKUP_MAX_AGE_HOURS", "24")),
        backup_marker_file=os.getenv("ADMIN_BACKUP_MARKER_FILE", "/broker-status/last-backup"),
    )

