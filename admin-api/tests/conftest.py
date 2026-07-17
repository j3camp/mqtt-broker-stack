from __future__ import annotations

import sys
import os
from pathlib import Path

API_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API_ROOT))
os.environ.setdefault("ADMIN_ENVIRONMENT", "development")
os.environ.setdefault("ADMIN_DATABASE_URL", "sqlite:///./tmp/admin-api-http-test.db")
os.environ.setdefault("ADMIN_ALLOWED_HOSTS", "testserver,localhost")
os.environ.setdefault("ADMIN_COOKIE_SECURE", "false")
os.environ.setdefault("ADMIN_LOCAL_AUTH_ENABLED", "true")
os.environ.setdefault("ADMIN_BOOTSTRAP_USERNAME", "admin")
os.environ.setdefault("ADMIN_BOOTSTRAP_PASSWORD", "a-secure-test-password")
os.environ.setdefault("ADMIN_SESSION_SECRET", "test-session-secret-that-is-long-enough")
os.environ.setdefault("ADMIN_BROKER_PASSWORD", "test-broker-password")

