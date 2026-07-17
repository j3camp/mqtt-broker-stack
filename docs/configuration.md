# 設定

## 環境變數

| 變數 | 預設值 | 用途 |
|---|---|---|
| `MOSQUITTO_IMAGE` | 2.1.2 immutable digest | Broker 與 helper 的相同映像 |
| `MQTT_TLS_PORT` | `8883` | 主機 MQTTS port |
| `MQTT_TLS_BIND_ADDRESS` | `0.0.0.0` | MQTTS bind address |
| `MQTT_WSS_PORT` | `9001` | localhost WSS port |
| `DYNSEC_ADMIN_USERNAME` | `admin` | 2.1 bootstrap 管理帳號 |
| `MQTT_CONTROL_HOSTNAME` | `mosquitto-control` | TLS 控制面名稱 |
| `MQTT_SERVER_HOSTNAME` | `localhost` | 開發憑證主要 SAN |
| `ADMIN_PUBLIC_URL` | `http://localhost:8088` | Operator 可見的管理後台 URL |
| `ADMIN_ALLOWED_HOSTS` | `localhost,127.0.0.1` | API 接受的 Host header |
| `ADMIN_LOCAL_AUTH_ENABLED` | `true`（本機） | 是否啟用 bootstrap local login；正式環境完成 OIDC 後應關閉 |
| `ADMIN_COOKIE_SECURE` | `false`（本機） | 正式環境必須設為 `true` |
| `ADMIN_CERTIFICATE_WARNING_DAYS` | `30` | 憑證到期警示門檻 |
| `ADMIN_BACKUP_MAX_AGE_HOURS` | `24` | 備份過舊門檻 |
| `ADMIN_OIDC_DISCOVERY_URL` | 空 | OIDC discovery endpoint |
| `ADMIN_OIDC_CLIENT_ID` | 空 | OIDC client ID |
| `ADMIN_OIDC_ROLE_CLAIM` | `mqtt_admin_role` | Operator role claim |

`.env.example` 的 image 同時固定 tag 與 manifest digest。升級時必須更新完整值並執行所有測試。

管理後台的 database、session、bootstrap 密碼位於 `admin/secrets/`，以 Compose secrets 注入。OIDC client secret 也必須使用 `ADMIN_OIDC_CLIENT_SECRET_FILE` 注入，不可寫入 `.env`。

## Mosquitto 設定檔

| 檔案 | 用途 |
|---|---|
| `mosquitto.conf` | persistence、`plugin_load`、DynSec 狀態與 bootstrap secret |
| `10-base.conf` | 不帶 listener scope 的共用註解／保留區 |
| `20-internal.conf` | 1883 匿名內部 MQTT，不使用 DynSec |
| `30-external.conf` | 8883 TLS + DynSec |
| `35-control.conf` | 1884 隔離 TLS 管理 listener |
| `40-websocket.conf` | 9001 WSS + DynSec |

## 憑證

所有需要 TLS 的 listener 共用 server certificate。SAN 至少應包含對外服務名稱與 `mosquitto-control`：

```bash
./scripts/generate-cert.sh \
  --hostname mqtt.example.local \
  --dns mosquitto-control \
  --ip 192.0.2.10
```

正式環境應替換為組織 PKI 或受信任 CA 簽發的憑證。

## Dynamic Security 狀態

狀態儲存於 named volume 的 `/mosquitto/data/dynamic-security.json`，不是 Git 內的設定檔。第一次啟動前執行：

```bash
./scripts/bootstrap-dynsec.sh
```

管理 secret 路徑為 `mosquitto/config/security/dynsec-admin-password`，必須是 mode 600 且不提交。Broker entrypoint 會在 container 內複製成 mode 400、owner 為 `mosquitto` 的 `/tmp/dynsec_admin_password`，避免 file-backed Compose secret 保留 root-only 權限而無法初始化。ACL、角色與群組均透過 `scripts/dynsec-command.sh` 線上變更。
