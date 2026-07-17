#!/usr/bin/env python3
"""Migrate Mosquitto password/ACL files into a least-privilege DynSec state.

The password and ACL parsing rules follow Eclipse Mosquitto's 2.1 migration
utility, with stricter default-deny behavior and mandatory ownership metadata.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path


class MigrationError(ValueError):
    """The source data cannot be migrated without operator correction."""


class RotationRequired(MigrationError):
    """At least one password hash cannot be safely migrated."""


@dataclass(frozen=True)
class Owner:
    owner: str
    group: str


ACCESS_TYPES = {
    "read": ("publishClientReceive", "subscribePattern", "unsubscribePattern"),
    "write": ("publishClientSend",),
    "readwrite": (
        "publishClientSend",
        "publishClientReceive",
        "subscribePattern",
        "unsubscribePattern",
    ),
    "deny": (
        "publishClientSend",
        "publishClientReceive",
        "subscribePattern",
        "unsubscribePattern",
    ),
}
NAME_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")
PRESERVED_ROLES = {"dynsec-admin", "sys-observe", "sys-notify"}


def parse_password_file(path: Path) -> dict[str, dict[str, object]]:
    clients: dict[str, dict[str, object]] = {}
    rotation: list[str] = []
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            raise MigrationError(f"Invalid password entry at {path}:{number}")
        username, password_hash = line.split(":", 1)
        if not username or not NAME_PATTERN.fullmatch(username):
            raise MigrationError(f"Invalid username at {path}:{number}: {username!r}")
        if username in clients:
            raise MigrationError(f"Duplicate password entry for {username!r}")

        client: dict[str, object] = {"username": username}
        if password_hash.startswith("$argon2id$"):
            client["encoded_password"] = password_hash
        elif password_hash.startswith("$7$"):
            parts = password_hash.split("$")
            if len(parts) != 5 or not parts[2].isdigit() or not parts[3] or not parts[4]:
                rotation.append(username)
                continue
            client.update(
                {
                    "password": parts[4],
                    "salt": parts[3],
                    "iterations": int(parts[2]),
                }
            )
        else:
            rotation.append(username)
            continue
        clients[username] = client

    if rotation:
        users = ", ".join(sorted(rotation))
        raise RotationRequired(
            f"Credential rotation required for unsupported hashes: {users}"
        )
    if not clients:
        raise MigrationError(f"No migratable identities found in {path}")
    return clients


def parse_owners(path: Path, usernames: set[str]) -> dict[str, Owner]:
    owners: dict[str, Owner] = {}
    with path.open(encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != ["username", "owner", "group"]:
            raise MigrationError(
                "Ownership CSV header must be exactly: username,owner,group"
            )
        for row in reader:
            username = (row.get("username") or "").strip()
            owner = (row.get("owner") or "").strip()
            group = (row.get("group") or "").strip()
            if not username or not owner or not group:
                raise MigrationError("Ownership rows may not contain empty fields")
            if not NAME_PATTERN.fullmatch(group):
                raise MigrationError(f"Invalid DynSec group name: {group!r}")
            if username in owners:
                raise MigrationError(f"Duplicate ownership row for {username!r}")
            owners[username] = Owner(owner=owner, group=group)

    missing = sorted(usernames - set(owners))
    extra = sorted(set(owners) - usernames)
    if missing or extra:
        details = []
        if missing:
            details.append(f"missing owners: {', '.join(missing)}")
        if extra:
            details.append(f"unknown identities: {', '.join(extra)}")
        raise MigrationError("Ownership coverage mismatch (" + "; ".join(details) + ")")
    return owners


def parse_acl_line(line: str, path: Path, number: int) -> list[dict[str, object]]:
    tokens = line.split()
    if len(tokens) < 2 or tokens[0] not in {"topic", "pattern"}:
        raise MigrationError(f"Invalid ACL at {path}:{number}: {line}")

    if len(tokens) == 2:
        access = "readwrite"
        topic = tokens[1]
    elif tokens[1] in ACCESS_TYPES:
        access = tokens[1]
        topic = " ".join(tokens[2:])
    else:
        raise MigrationError(f"ACL access type is required at {path}:{number}: {line}")
    if not topic:
        raise MigrationError(f"ACL topic is empty at {path}:{number}")

    allow = access != "deny"
    priority = 10 if allow else 100
    return [
        {
            "acltype": acl_type,
            "topic": topic,
            "priority": priority,
            "allow": allow,
        }
        for acl_type in ACCESS_TYPES[access]
    ]


def parse_acl_file(path: Path | None) -> tuple[list[dict[str, object]], dict[str, list[dict[str, object]]]]:
    if path is None or not path.exists():
        return [], {}

    global_acls: list[dict[str, object]] = []
    user_acls: dict[str, list[dict[str, object]]] = {}
    current_user: str | None = None
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("user "):
            current_user = line[5:].strip()
            if not current_user or not NAME_PATTERN.fullmatch(current_user):
                raise MigrationError(f"Invalid ACL user at {path}:{number}: {current_user!r}")
            user_acls.setdefault(current_user, [])
            continue
        if not line.startswith(("topic ", "pattern ")):
            raise MigrationError(f"Unsupported ACL directive at {path}:{number}: {line}")
        parsed = parse_acl_line(line, path, number)
        if line.startswith("pattern ") or current_user is None:
            global_acls.extend(parsed)
        else:
            user_acls.setdefault(current_user, []).extend(parsed)
    return global_acls, user_acls


def deduplicate_acls(acls: list[dict[str, object]]) -> list[dict[str, object]]:
    unique: dict[tuple[object, ...], dict[str, object]] = {}
    for acl in acls:
        key = (acl["acltype"], acl["topic"], acl["priority"], acl["allow"])
        unique[key] = acl
    return sorted(
        unique.values(),
        key=lambda acl: (-int(acl["priority"]), str(acl["topic"]), str(acl["acltype"])),
    )


def migrate(
    *,
    password_file: Path,
    acl_file: Path | None,
    owners_file: Path,
    base_config: Path,
    output: Path,
) -> dict[str, object]:
    clients = parse_password_file(password_file)
    owners = parse_owners(owners_file, set(clients))
    global_acls, user_acls = parse_acl_file(acl_file)
    unknown_acl_users = sorted(set(user_acls) - set(clients))
    if unknown_acl_users:
        raise MigrationError(
            "ACL entries have no password identity: " + ", ".join(unknown_acl_users)
        )

    base = json.loads(base_config.read_text(encoding="utf-8"))
    admin = next(
        (client for client in base.get("clients", []) if client.get("username") == "admin"),
        None,
    )
    if admin is None:
        raise MigrationError("Base DynSec state does not contain the admin identity")
    role_map = {
        role.get("rolename"): role
        for role in base.get("roles", [])
        if role.get("rolename") in PRESERVED_ROLES
    }
    required_admin_roles = {"dynsec-admin", "sys-observe"}
    if not required_admin_roles.issubset(role_map):
        raise MigrationError("Base DynSec state is missing required admin roles")

    admin = dict(admin)
    admin["textname"] = "Dynamic Security administrator"
    admin["textdescription"] = "Dedicated control-plane identity; no application topic access."
    admin["roles"] = [
        {"rolename": "dynsec-admin", "priority": 100},
        {"rolename": "sys-observe", "priority": 10},
    ]

    migrated_clients: list[dict[str, object]] = [admin]
    migrated_roles: list[dict[str, object]] = list(role_map.values())
    grouped_clients: dict[str, list[dict[str, object]]] = {}
    for username in sorted(clients):
        owner = owners[username]
        role_name = f"migrated-{username}"
        acls = deduplicate_acls(global_acls + user_acls.get(username, []))
        migrated_roles.append(
            {
                "rolename": role_name,
                "textname": f"Migrated permissions for {username}",
                "textdescription": f"Explicit legacy ACL mapping. Owner: {owner.owner}.",
                "allowwildcardsubs": True,
                "acls": acls,
            }
        )
        client = dict(clients[username])
        client.update(
            {
                "textname": username,
                "textdescription": (
                    f"Owner: {owner.owner}; migrated from password_file. "
                    "Permissions are explicit and default deny."
                ),
                "disabled": False,
                "roles": [{"rolename": role_name, "priority": 50}],
            }
        )
        migrated_clients.append(client)
        grouped_clients.setdefault(owner.group, []).append(
            {"username": username, "priority": 50}
        )

    groups: list[dict[str, object]] = [
        {
            "groupname": "unauthenticated",
            "textname": "Unauthenticated group",
            "textdescription": "No roles; anonymous external access is disabled.",
            "roles": [],
            "clients": [],
        }
    ]
    for group_name in sorted(grouped_clients):
        group_owners = sorted(
            {owners[item["username"]].owner for item in grouped_clients[group_name]}
        )
        groups.append(
            {
                "groupname": group_name,
                "textname": group_name,
                "textdescription": "Ownership group: " + ", ".join(group_owners),
                "roles": [],
                "clients": grouped_clients[group_name],
            }
        )

    result: dict[str, object] = {
        "defaultACLAccess": {
            "publishClientSend": False,
            "publishClientReceive": False,
            "subscribe": False,
            "unsubscribe": False,
        },
        "clients": migrated_clients,
        "groups": groups,
        "roles": migrated_roles,
        "anonymousGroup": "unauthenticated",
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=output.name + ".", dir=output.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(result, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, output)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--password-file", required=True, type=Path)
    parser.add_argument("--acl-file", type=Path)
    parser.add_argument("--owners-file", required=True, type=Path)
    parser.add_argument("--base-config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = migrate(
            password_file=args.password_file,
            acl_file=args.acl_file,
            owners_file=args.owners_file,
            base_config=args.base_config,
            output=args.output,
        )
    except RotationRequired as error:
        parser.exit(2, f"ERROR: {error}\n")
    except (MigrationError, OSError, json.JSONDecodeError) as error:
        parser.exit(1, f"ERROR: {error}\n")
    print(
        f"Migrated {len(result['clients']) - 1} application identities to {args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
