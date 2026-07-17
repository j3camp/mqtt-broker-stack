from __future__ import annotations

import json
import ssl
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import paho.mqtt.client as mqtt
from cryptography import x509
from cryptography.hazmat.backends import default_backend

from .config import Settings


CONTROL_TOPIC = "$CONTROL/dynamic-security/v1"
RESPONSE_TOPIC = f"{CONTROL_TOPIC}/response"


class BrokerError(RuntimeError):
    pass


class MosquittoAdapter:
    def __init__(self, settings: Settings):
        self.settings = settings

    def command(self, command: str, **data: Any) -> dict[str, Any]:
        correlation = str(uuid.uuid4())
        request = {"commands": [{"command": command, "correlationData": correlation, **data}]}
        event = threading.Event()
        result: dict[str, Any] = {}
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"admin-api-{uuid.uuid4().hex[:12]}")
        client.username_pw_set(self.settings.broker_username, self.settings.broker_password)
        try:
            client.tls_set(ca_certs=self.settings.broker_ca_file, tls_version=ssl.PROTOCOL_TLS_CLIENT)
        except OSError as exc:
            raise BrokerError(f"broker TLS configuration unavailable: {exc}") from exc

        def on_connect(mqtt_client: mqtt.Client, userdata: Any, flags: Any, reason_code: Any, properties: Any) -> None:
            if int(reason_code) != 0:
                result["error"] = f"broker connection rejected ({reason_code})"
                event.set()
                return
            mqtt_client.subscribe(RESPONSE_TOPIC, qos=1)

        def on_subscribe(mqtt_client: mqtt.Client, userdata: Any, mid: int, reason_codes: Any, properties: Any) -> None:
            mqtt_client.publish(CONTROL_TOPIC, json.dumps(request, separators=(",", ":")), qos=1)

        def on_message(mqtt_client: mqtt.Client, userdata: Any, message: mqtt.MQTTMessage) -> None:
            try:
                payload = json.loads(message.payload)
                responses = payload.get("responses", [])
                response = next((item for item in responses if item.get("correlationData") == correlation), None)
                if response:
                    result["response"] = response
                    event.set()
            except (ValueError, TypeError) as exc:
                result["error"] = f"invalid broker response: {exc}"
                event.set()

        client.on_connect = on_connect
        client.on_subscribe = on_subscribe
        client.on_message = on_message
        try:
            client.connect(self.settings.broker_host, self.settings.broker_port, keepalive=10)
            client.loop_start()
            if not event.wait(self.settings.broker_timeout_seconds):
                raise BrokerError("broker response timed out")
            if result.get("error"):
                raise BrokerError(result["error"])
            response = result.get("response", {})
            if response.get("error"):
                raise BrokerError(str(response["error"]))
            return response.get("data", {})
        except (OSError, mqtt.WebsocketConnectionError) as exc:
            raise BrokerError(f"broker unavailable: {exc}") from exc
        finally:
            client.loop_stop()
            client.disconnect()

    def list_objects(self, kind: str) -> list[dict[str, Any]]:
        field = {"Clients": "clients", "Groups": "groups", "Roles": "roles"}[kind]
        data = self.command(f"list{kind}", verbose=True, count=-1, offset=0)
        return data.get(field, [])

    def overview(self) -> dict[str, Any]:
        metrics: dict[str, str] = {}
        event = threading.Event()
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"admin-overview-{uuid.uuid4().hex[:10]}")
        client.username_pw_set(self.settings.broker_username, self.settings.broker_password)
        try:
            client.tls_set(ca_certs=self.settings.broker_ca_file, tls_version=ssl.PROTOCOL_TLS_CLIENT)
        except OSError as exc:
            raise BrokerError(f"broker TLS configuration unavailable: {exc}") from exc
        topics = ["$SYS/broker/version", "$SYS/broker/uptime", "$SYS/broker/clients/connected"]

        def on_connect(mqtt_client: mqtt.Client, userdata: Any, flags: Any, reason_code: Any, properties: Any) -> None:
            if int(reason_code) == 0:
                mqtt_client.subscribe([(topic, 0) for topic in topics])
            else:
                event.set()

        def on_message(mqtt_client: mqtt.Client, userdata: Any, message: mqtt.MQTTMessage) -> None:
            metrics[message.topic] = message.payload.decode(errors="replace")
            if len(metrics) == len(topics):
                event.set()

        client.on_connect, client.on_message = on_connect, on_message
        try:
            client.connect(self.settings.broker_host, self.settings.broker_port, keepalive=10)
            client.loop_start()
            event.wait(min(self.settings.broker_timeout_seconds, 2.0))
            reachable = "$SYS/broker/version" in metrics
        except OSError:
            reachable = False
        finally:
            client.loop_stop()
            client.disconnect()
        return {
            "state": "healthy" if reachable and len(metrics) == len(topics) else ("degraded" if reachable else "unavailable"),
            "reachable": reachable,
            "version": metrics.get("$SYS/broker/version"),
            "uptime": metrics.get("$SYS/broker/uptime"),
            "connected_clients": int(metrics.get("$SYS/broker/clients/connected", "0")) if reachable else None,
            "observed_at": datetime.now(timezone.utc).isoformat(),
            "source": "$SYS over mqtt-control:1884",
        }

    def certificate_status(self) -> dict[str, Any]:
        path = Path(self.settings.certificate_file)
        if not path.is_file():
            return {"state": "unavailable", "error": "certificate file is unavailable"}
        cert = x509.load_pem_x509_certificate(path.read_bytes(), default_backend())
        now = datetime.now(timezone.utc)
        expiry = cert.not_valid_after_utc
        remaining_days = (expiry - now).total_seconds() / 86400
        try:
            san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
            sans = san.get_values_for_type(x509.DNSName) + [str(ip) for ip in san.get_values_for_type(x509.IPAddress)]
        except x509.ExtensionNotFound:
            sans = []
        state = "healthy" if remaining_days > self.settings.certificate_warning_days else "degraded"
        if remaining_days <= 0:
            state = "unavailable"
        return {
            "state": state,
            "subject": cert.subject.rfc4514_string(),
            "issuer": cert.issuer.rfc4514_string(),
            "sans": sans,
            "not_before": cert.not_valid_before_utc.isoformat(),
            "not_after": expiry.isoformat(),
            "remaining_days": round(remaining_days, 1),
            "warning_threshold_days": self.settings.certificate_warning_days,
        }
