FROM python:3.13.3-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/home/admin/.local/bin:$PATH

RUN useradd --create-home --uid 10001 admin
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY alembic.ini ./
COPY migrations ./migrations
COPY app ./app
COPY entrypoint.sh ./
RUN chown -R admin:admin /app
RUN command -v setpriv >/dev/null

EXPOSE 8080
ENTRYPOINT ["/bin/sh", "/app/entrypoint.sh"]
