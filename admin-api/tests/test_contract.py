from __future__ import annotations

from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_compose_preserves_control_plane_boundaries() -> None:
    compose = yaml.safe_load(read("compose.admin.yaml"))
    api = compose["services"]["admin-api"]
    assert "mqtt-control" in api["networks"]
    assert "ports" not in api
    assert compose["networks"]["mqtt-admin-internal"]["internal"] is True
    assert "/var/run/docker.sock" not in read("compose.admin.yaml")
    assert "dynsec_admin_password" in api["secrets"]
    assert "dynsec_admin_password" not in compose["services"]["admin-ui"].get("secrets", [])
    assert set(api["cap_add"]) == {"SETGID", "SETUID"}
    entrypoint = read("admin-api/entrypoint.sh")
    assert "setpriv --reuid=10001 --regid=10001" in entrypoint
    assert entrypoint.index("cat \"${path}\"") < entrypoint.index("setpriv --reuid=10001")


def test_no_runtime_secret_is_committed() -> None:
    gitignore = read(".gitignore")
    env_example = read(".env.example")
    assert "admin/secrets/" in gitignore
    assert "ADMIN_OIDC_CLIENT_SECRET=" not in env_example
    assert "ADMIN_BOOTSTRAP_PASSWORD=" not in env_example


def test_api_contains_all_mvp_boundaries() -> None:
    source = read("admin-api/app/main.py")
    for route in ("/api/v1/overview", "/api/v1/clients", "/api/v1/groups", "/api/v1/roles", "/api/v1/permissions/evaluate", "/api/v1/connections", "/api/v1/audit"):
        assert route in source
    assert "require_mutation_role" in source
    assert "X-Confirm-Action" in source
    assert "password is intentionally never returned" in source.lower()


def test_migration_makes_audit_records_immutable() -> None:
    migration = read("admin-api/migrations/versions/0001_admin_foundation.py")
    assert "BEFORE UPDATE OR DELETE ON audit_events" in migration
    assert "audit_events_no_update" in migration
    assert "audit_events_no_delete" in migration
