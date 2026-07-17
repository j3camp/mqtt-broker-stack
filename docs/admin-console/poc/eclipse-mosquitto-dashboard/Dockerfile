FROM alpine:3.22.1 AS dashboard-source

ARG MOSQUITTO_DASHBOARD_COMMIT
RUN test -n "${MOSQUITTO_DASHBOARD_COMMIT}" \
    && wget -q -O /tmp/mosquitto.tar.gz \
       "https://github.com/eclipse-mosquitto/mosquitto/archive/${MOSQUITTO_DASHBOARD_COMMIT}.tar.gz" \
    && mkdir /tmp/source \
    && tar -xzf /tmp/mosquitto.tar.gz --strip-components=1 -C /tmp/source \
    && test -f /tmp/source/dashboard/src/index.html

FROM eclipse-mosquitto:2.1.2

COPY --from=dashboard-source /tmp/source/dashboard/src /mosquitto/dashboard
COPY mosquitto.conf /mosquitto/config/mosquitto.conf
