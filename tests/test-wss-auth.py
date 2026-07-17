#!/usr/bin/env python3
"""Verify WSS rejects anonymous clients and accepts a migrated identity."""

from __future__ import annotations

import os
import ssl
import threading
import time
import uuid

import paho.mqtt.client as mqtt


HOST = os.getenv("MQTT_WSS_HOST", "localhost")
PORT = int(os.getenv("MQTT_WSS_PORT", "9001"))
CA_FILE = os.getenv("MQTT_CA_FILE", "mosquitto/config/certs/ca.crt")
USERNAME = os.environ["MQTT_TEST_USERNAME"]
PASSWORD = os.environ["MQTT_TEST_PASSWORD"]


def new_client(name: str) -> mqtt.Client:
    client = mqtt.Client(
        callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"task7-{name}-{uuid.uuid4().hex}",
        protocol=mqtt.MQTTv5,
        transport="websockets",
    )
    client.tls_set(ca_certs=CA_FILE, cert_reqs=ssl.CERT_REQUIRED)
    return client


def anonymous_is_denied() -> None:
    completed = threading.Event()
    accepted: list[bool] = []
    client = new_client("anonymous")

    def on_connect(_client, _userdata, _flags, reason_code, _properties):
        accepted.append(not reason_code.is_failure)
        completed.set()

    client.on_connect = on_connect
    try:
        client.connect(HOST, PORT, keepalive=10)
        client.loop_start()
        if not completed.wait(10):
            raise AssertionError("anonymous WSS connection did not receive CONNACK")
    finally:
        client.loop_stop()
        client.disconnect()
    if accepted != [False]:
        raise AssertionError("anonymous WSS connection was accepted")


def authenticated_pubsub_succeeds() -> None:
    connected = threading.Event()
    received = threading.Event()
    payload = f"wss-{uuid.uuid4().hex}"
    topic = f"test/wss/{uuid.uuid4().hex}"
    client = new_client("authenticated")
    client.username_pw_set(USERNAME, PASSWORD)

    def on_connect(active_client, _userdata, _flags, reason_code, _properties):
        if reason_code.is_failure:
            return
        active_client.subscribe(topic)
        connected.set()

    def on_subscribe(active_client, _userdata, _mid, reason_codes, _properties):
        if any(code.is_failure for code in reason_codes):
            return
        active_client.publish(topic, payload, qos=1)

    def on_message(_client, _userdata, message):
        if message.topic == topic and message.payload.decode() == payload:
            received.set()

    client.on_connect = on_connect
    client.on_subscribe = on_subscribe
    client.on_message = on_message
    try:
        client.connect(HOST, PORT, keepalive=10)
        client.loop_start()
        if not connected.wait(10):
            raise AssertionError("authenticated WSS connection was not accepted")
        if not received.wait(10):
            raise AssertionError("authenticated WSS publish/subscribe failed")
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    anonymous_is_denied()
    time.sleep(0.2)
    authenticated_pubsub_succeeds()
    print("PASS: WSS authentication and authorization policy")

