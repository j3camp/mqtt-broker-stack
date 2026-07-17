#!/usr/bin/env python3
"""Contract and unit tests for Task #7 Mosquitto 2.1/DynSec migration."""

from __future__ import annotations

import csv
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION_MODULE = ROOT / "scripts" / "migrate_dynsec.py"
IMAGE = (
    "eclipse-mosquitto:2.1.2-alpine@"
    "sha256:6f8d8a947c506f8a2290ec65cd4bd2bc7cb4d43fb5f6271f861cb013e2ef9797"
)


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def load_migration_module():
    if not MIGRATION_MODULE.is_file():
        raise AssertionError(f"Missing migration module: {MIGRATION_MODULE.relative_to(ROOT)}")
    spec = importlib.util.spec_from_file_location("migrate_dynsec", MIGRATION_MODULE)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class Task7ArchitectureContractTest(unittest.TestCase):
    def test_runtime_shell_entrypoints_are_executable_in_git(self) -> None:
        entrypoints = [
            "mosquitto/scripts/dynsec-entrypoint.sh",
            "mosquitto/scripts/harden-dynsec.sh",
            "mosquitto/scripts/install-dynsec-state.sh",
            "mosquitto/scripts/mosquitto-entrypoint.sh",
            "scripts/bootstrap-dynsec.sh",
            "scripts/dynsec-command.sh",
            "scripts/migrate-dynsec.sh",
            "scripts/rollback-dynsec.sh",
            "scripts/wait-dynsec-bootstrap.sh",
        ]
        for path in entrypoints:
            with self.subTest(path=path):
                index_entry = subprocess.check_output(
                    ["git", "ls-files", "--stage", "--", path],
                    cwd=ROOT,
                    text=True,
                )
                self.assertTrue(index_entry.startswith("100755 "), index_entry)

    def test_required_artifacts_exist(self) -> None:
        required = [
            "mosquitto/config/conf.d/35-control.conf",
            "mosquitto/config/conf.d/40-websocket.conf",
            "mosquitto/config/security/migration-owners.example.csv",
            "mosquitto/scripts/dynsec-entrypoint.sh",
            "mosquitto/scripts/harden-dynsec.sh",
            "mosquitto/scripts/install-dynsec-state.sh",
            "mosquitto/scripts/mosquitto-entrypoint.sh",
            "scripts/dynsec-command.sh",
            "scripts/migrate-dynsec.sh",
            "scripts/migrate_dynsec.py",
            "scripts/rollback-dynsec.sh",
            "scripts/wait-dynsec-bootstrap.sh",
            "tests/test-control-isolation.sh",
            "tests/test-migration-rollback.sh",
            "tests/test-wss-auth.py",
            "docs/migration-dynamic-security.md",
        ]
        missing = [path for path in required if not (ROOT / path).is_file()]
        self.assertEqual([], missing)

    def test_image_is_version_and_digest_pinned(self) -> None:
        env = read(".env.example")
        compose = read("compose.yaml")
        self.assertIn(f"MOSQUITTO_IMAGE={IMAGE}", env)
        self.assertIn("image: ${MOSQUITTO_IMAGE}", compose)
        self.assertNotIn("MOSQUITTO_VERSION=2.0", env)

    def test_listener_plugins_and_anonymous_policy_are_explicit(self) -> None:
        root_config = read("mosquitto/config/mosquitto.conf")
        internal = read("mosquitto/config/conf.d/20-internal.conf")
        external = read("mosquitto/config/conf.d/30-external.conf")
        control = read("mosquitto/config/conf.d/35-control.conf")
        websocket = read("mosquitto/config/conf.d/40-websocket.conf")
        active = "\n".join((root_config, internal, external, control, websocket))

        self.assertNotIn("per_listener_settings", active)
        self.assertIn("plugin_load dynsec /usr/lib/mosquitto_dynamic_security.so", root_config)
        self.assertIn("plugin_opt_config_file /mosquitto/data/dynamic-security.json", root_config)
        self.assertIn("plugin_opt_password_init_file /tmp/dynsec_admin_password", root_config)

        self.assertIn("listener 1883", internal)
        self.assertIn("listener_allow_anonymous true", internal)
        self.assertNotIn("plugin_use", internal)

        for config, port in ((external, 8883), (control, 1884), (websocket, 9001)):
            with self.subTest(port=port):
                self.assertRegex(config, rf"(?m)^listener {port}(?:\s|$)")
                self.assertIn("listener_allow_anonymous false", config)
                self.assertIn("plugin_use dynsec", config)
                self.assertIn("certfile /mosquitto/config/certs/server.crt", config)
                self.assertIn("keyfile /mosquitto/config/certs/server.key", config)
                self.assertNotIn("password_file", config)
                self.assertNotIn("acl_file", config)

        self.assertIn("listener 1884 172.31.0.2", control)

    def test_compose_isolates_control_network_and_ports(self) -> None:
        compose = read("compose.yaml")
        self.assertIn("mqtt-control:", compose)
        self.assertIn("ipv4_address: 172.31.0.2", compose)
        self.assertRegex(compose, r"(?ms)mqtt-control:.*?internal: true")
        self.assertIn("dynsec-admin:", compose)
        self.assertIn("dynsec-bootstrap:", compose)
        self.assertIn("profiles:", compose)
        self.assertIn('- "admin"', compose)
        self.assertNotRegex(compose, r"(?m)^\s*-\s*[\"']?[^\n]*:(?:1883|1884)(?:[\"']?\s*$)")
        self.assertRegex(compose, r"127\.0\.0\.1:\$\{MQTT_WSS_PORT:-9001\}:9001")
        self.assertNotIn("/var/run/docker.sock", compose)
        self.assertEqual(2, compose.count("DAC_READ_SEARCH"))
        self.assertNotIn("DAC_OVERRIDE", compose)
        self.assertIn("/mosquitto/scripts/mosquitto-entrypoint.sh", compose)
        self.assertIn("/usr/sbin/mosquitto", compose)
        broker_entrypoint = read("mosquitto/scripts/mosquitto-entrypoint.sh")
        self.assertIn("/run/secrets/dynsec_admin_password", broker_entrypoint)
        self.assertIn("/tmp/dynsec_admin_password", broker_entrypoint)
        self.assertIn("chown mosquitto:mosquitto", broker_entrypoint)
        self.assertIn("chmod 400", broker_entrypoint)
        self.assertIn('if [ "$#" -eq 0 ]', broker_entrypoint)
        self.assertIn("set -- /usr/sbin/mosquitto", broker_entrypoint)
        self.assertIn("exec /docker-entrypoint.sh", broker_entrypoint)

        workflow = read(".github/workflows/ci.yml")
        self.assertNotIn("docker compose wait dynsec-bootstrap", workflow)
        self.assertIn("./scripts/wait-dynsec-bootstrap.sh", workflow)
        bootstrap_wait = read("scripts/wait-dynsec-bootstrap.sh")
        self.assertIn("ps -aq dynsec-bootstrap", bootstrap_wait)
        self.assertIn("docker wait", bootstrap_wait)
        self.assertIn(".State.ExitCode", bootstrap_wait)
        hardener = read("mosquitto/scripts/harden-dynsec.sh")
        for acl_type in (
            "publishClientSend",
            "publishClientReceive",
            "subscribe",
            "unsubscribe",
        ):
            self.assertIn(f"setDefaultACLAccess {acl_type} deny", hardener)
        self.assertIn("deleteClient democlient", hardener)
        self.assertIn("removeClientRole", hardener)

    def test_migration_and_rollback_invariants_are_scripted(self) -> None:
        migration = read("scripts/migrate-dynsec.sh")
        rollback = read("scripts/rollback-dynsec.sh")
        installer = read("mosquitto/scripts/install-dynsec-state.sh")
        gitignore = read(".gitignore")

        for token in (
            "dynamic-security.json",
            "migration-owners",
            "DYNSEC_MIGRATION_FAIL_AFTER_CUTOVER",
            "rollback",
            "sha256",
        ):
            self.assertIn(token, migration)
        self.assertIn("dynamic-security.json", rollback)
        self.assertIn("mv", installer)
        self.assertIn("chown", installer)
        self.assertIn("dynsec-admin-password", gitignore)

        ci_user_helper = read(".github/scripts/ci-create-user.sh")
        self.assertIn("awk -F ':'", ci_user_helper)
        self.assertIn("$1 == user", ci_user_helper)

        tls_test = read("tests/test-tls-verification.sh")
        self.assertIn("-verify_return_error", tls_test)
        self.assertIn("-verify_ip", tls_test)
        self.assertNotIn('grep -c "Verify return code: 0"', tls_test)


class DynSecMigrationUnitTest(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_migration_module()
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def write(self, name: str, content: str) -> Path:
        path = self.root / name
        path.write_text(content, encoding="utf-8")
        return path

    def base_config(self) -> Path:
        return self.write(
            "base.json",
            json.dumps(
                {
                    "defaultACLAccess": {
                        "publishClientSend": False,
                        "publishClientReceive": True,
                        "subscribe": False,
                        "unsubscribe": True,
                    },
                    "clients": [
                        {
                            "username": "admin",
                            "encoded_password": "$argon2id$v=19$m=1,t=1,p=1$c2FsdA$aGFzaA",
                            "roles": [
                                {"rolename": "super-admin"},
                                {"rolename": "topic-observe"},
                            ],
                        },
                        {
                            "username": "democlient",
                            "encoded_password": "$argon2id$v=19$m=1,t=1,p=1$c2FsdA$aGFzaA",
                            "roles": [{"rolename": "client"}],
                        },
                    ],
                    "groups": [{"groupname": "unauthenticated", "roles": []}],
                    "roles": [
                        {"rolename": "super-admin", "acls": []},
                        {"rolename": "topic-observe", "acls": []},
                        {"rolename": "client", "acls": []},
                        {
                            "rolename": "dynsec-admin",
                            "acls": [
                                {
                                    "acltype": "publishClientSend",
                                    "topic": "$CONTROL/dynamic-security/#",
                                    "priority": 10,
                                    "allow": True,
                                }
                            ],
                        },
                        {"rolename": "sys-observe", "acls": []},
                    ],
                    "anonymousGroup": "unauthenticated",
                }
            ),
        )

    def migrate(self, password_content: str, acl_content: str, owners: list[list[str]]):
        password_file = self.write("passwords", password_content)
        acl_file = self.write("acl", acl_content)
        owners_file = self.root / "owners.csv"
        with owners_file.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(["username", "owner", "group"])
            writer.writerows(owners)
        output = self.root / "dynamic-security.json"
        result = self.module.migrate(
            password_file=password_file,
            acl_file=acl_file,
            owners_file=owners_file,
            base_config=self.base_config(),
            output=output,
        )
        self.assertEqual(result, json.loads(output.read_text(encoding="utf-8")))
        return result

    def test_migrates_supported_hashes_and_records_ownership(self) -> None:
        result = self.migrate(
            "sensor-a:$7$101$c2FsdA==$aGFzaA==\n"
            "sensor-b:$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA\n",
            "user sensor-a\ntopic readwrite devices/sensor-a/#\n"
            "user sensor-b\ntopic read devices/sensor-b/#\n",
            [
                ["sensor-a", "team-iot", "sensors"],
                ["sensor-b", "team-iot", "sensors"],
            ],
        )
        clients = {client["username"]: client for client in result["clients"]}
        self.assertEqual(101, clients["sensor-a"]["iterations"])
        self.assertIn("encoded_password", clients["sensor-b"])
        self.assertIn("Owner: team-iot", clients["sensor-a"]["textdescription"])
        sensors = next(group for group in result["groups"] if group["groupname"] == "sensors")
        self.assertEqual({"sensor-a", "sensor-b"}, {item["username"] for item in sensors["clients"]})

    def test_sets_strict_defaults_and_restricts_admin(self) -> None:
        result = self.migrate(
            "sensor-a:$7$101$c2FsdA==$aGFzaA==\n",
            "user sensor-a\ntopic readwrite devices/sensor-a/#\n",
            [["sensor-a", "team-iot", "sensors"]],
        )
        self.assertEqual(
            {
                "publishClientSend": False,
                "publishClientReceive": False,
                "subscribe": False,
                "unsubscribe": False,
            },
            result["defaultACLAccess"],
        )
        clients = {client["username"]: client for client in result["clients"]}
        self.assertNotIn("democlient", clients)
        self.assertEqual(
            {"dynsec-admin", "sys-observe"},
            {role["rolename"] for role in clients["admin"]["roles"]},
        )
        self.assertNotIn(
            "super-admin", {role["rolename"] for role in result["roles"]}
        )

    def test_maps_allow_deny_wildcards_and_priorities(self) -> None:
        result = self.migrate(
            "sensor-a:$7$101$c2FsdA==$aGFzaA==\n",
            "pattern write devices/%u/telemetry/#\n"
            "user sensor-a\n"
            "topic read test/#\n"
            "topic deny test/private/#\n",
            [["sensor-a", "team-iot", "sensors"]],
        )
        role = next(role for role in result["roles"] if role["rolename"] == "migrated-sensor-a")
        wildcard = [acl for acl in role["acls"] if acl["topic"] == "devices/%u/telemetry/#"]
        denied = [acl for acl in role["acls"] if acl["topic"] == "test/private/#"]
        allowed = [acl for acl in role["acls"] if acl["topic"] == "test/#"]
        self.assertEqual(["publishClientSend"], [acl["acltype"] for acl in wildcard])
        self.assertTrue(all(not acl["allow"] and acl["priority"] == 100 for acl in denied))
        self.assertTrue(all(acl["allow"] and acl["priority"] == 10 for acl in allowed))

    def test_rejects_missing_owner_without_output(self) -> None:
        with self.assertRaises(self.module.MigrationError):
            self.migrate(
                "sensor-a:$7$101$c2FsdA==$aGFzaA==\n",
                "user sensor-a\ntopic read test/#\n",
                [],
            )

    def test_requires_rotation_for_unknown_hash_without_output(self) -> None:
        output = self.root / "dynamic-security.json"
        password_file = self.write("passwords", "sensor-a:unsupported-hash\n")
        owners_file = self.write("owners.csv", "username,owner,group\nsensor-a,team-iot,sensors\n")
        with self.assertRaises(self.module.RotationRequired):
            self.module.migrate(
                password_file=password_file,
                acl_file=None,
                owners_file=owners_file,
                base_config=self.base_config(),
                output=output,
            )
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
