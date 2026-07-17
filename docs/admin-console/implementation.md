# Broker 管理後台 MVP

本實作對應 Task #13 與 Stories #14–#19，沿用 ADR-0001 的 custom hybrid control-plane 決策。管理後台由三個獨立服務構成：

- `admin-ui`：僅提供靜態前端與同源 API reverse proxy，不持有 broker credential。
- `admin-api`：執行 OIDC／local operator 驗證、RBAC、CSRF、rate limit、Dynamic Security 操作、有效權限模擬與稽核。
- `admin-db`：保存 operator、session 與 append-only audit history；不保存 MQTT client 密碼。

Admin API 只加入 `mqtt-control` 與內部應用網路。它透過 TLS 連線至 `mosquitto-control:1884`，並發布 Mosquitto 官方 Dynamic Security topic API 命令；瀏覽器與 UI container 都無法取得管理 credential，也沒有任何服務掛載 Docker socket。

API entrypoint 只在啟動瞬間以 root 讀取 mode 600 的 file-backed Compose secrets，隨即以 `setpriv` 永久降權至 UID/GID 10001，再執行 migration 與 API server。Runtime process 不以 root 執行。

## 本機啟動

先完成 broker 初始化，再建立管理後台 secrets：

```bash
cp .env.example .env
./scripts/init.sh
bash ./scripts/init-admin.sh
docker compose -f compose.yaml -f compose.admin.yaml up -d --build
```

預設只在 `127.0.0.1:8088` 提供服務。本機 bootstrap operator 的帳號由 `ADMIN_BOOTSTRAP_USERNAME` 決定，密碼位於 `admin/secrets/bootstrap-password`；首次登入後應移入秘密管理系統並輪替。

## 正式環境驗證

正式環境必須使用 HTTPS，並至少設定：

```dotenv
ADMIN_ENVIRONMENT=production
ADMIN_PUBLIC_URL=https://mqtt-admin.example.com
ADMIN_ALLOWED_HOSTS=mqtt-admin.example.com
ADMIN_COOKIE_SECURE=true
ADMIN_LOCAL_AUTH_ENABLED=false
ADMIN_OIDC_DISCOVERY_URL=https://id.example.com/.well-known/openid-configuration
ADMIN_OIDC_CLIENT_ID=mqtt-admin
```

OIDC client secret 不可放入 `.env`。請以 deployment override 將秘密檔掛入 API container，並設定 `ADMIN_OIDC_CLIENT_SECRET_FILE`。OIDC claim `mqtt_admin_role` 預設接受 `viewer`、`operator`、`security_admin`、`super_admin`；claim 名稱可透過 `ADMIN_OIDC_ROLE_CLAIM` 調整。

## RBAC

| 操作 | 最低角色 |
|---|---|
| Broker overview、client／role／group／connection 讀取、有效權限模擬、audit 查詢 | Viewer |
| Audit export | Operator |
| MQTT client lifecycle、group／role／ACL mutation | Security Admin |
| 授予 `$CONTROL/` ACL | Super Admin |

所有 mutation 都檢查 session、角色與 CSRF token。刪除 client、group 或 role 還需要精確的 `X-Confirm-Action`，前端會要求 operator 輸入確認文字。

## 稽核完整性

Audit event 記錄 actor、角色、來源、時間、correlation ID、action、target、result 與遮罩後的 before／after metadata。每筆事件使用前一筆 hash 建立 SHA-256 chain；API 可驗證整條 chain。Migration 會在 PostgreSQL 與 SQLite 建立 trigger，阻止 application user 更新或刪除既有事件。

預設 audit policy 記錄成功與失敗的登入、rate limit、所有 security mutation、broker overview，以及有效權限模擬。高頻率且不改變狀態的 client／role／group list read 不逐筆記錄，避免稽核資料掩蓋安全事件；overview 與模擬 read 則因事故調查價值而保留。

密碼、token、secret、cookie、private key 與完整 payload 會在寫入前遞迴遮罩。Client 建立與密碼輪替回應都不會回傳密碼。

## 驗證

```bash
python3 -m pytest admin-api/tests
docker compose -f compose.yaml -f compose.admin.yaml config --quiet
```

啟動後應另行驗證 `health/live`、`health/ready`、OIDC redirect、Viewer mutation rejection、Dynamic Security mutation、生效後連線拒絕，以及 audit export 與 application／broker log correlation。
