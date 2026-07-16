#!/bin/sh
# Mosquitto MQTT healthcheck.
# Verifies the broker responds on the internal listener using the MQTT protocol.
# Returns 0 on success, 1 on failure.
set -e

mosquitto_sub \
  -h 127.0.0.1 \
  -p 1883 \
  -t '$SYS/broker/uptime' \
  -C 1 \
  -W 5 \
  > /dev/null 2>&1
