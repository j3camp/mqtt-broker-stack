# mqtt-broker-stack

以 Docker Compose 部署 Eclipse Mosquitto 2.1 的 MQTT Broker stack。專案採用 Mosquitto 原生開源 Dynamic Security plugin，不依賴 Cedalo Management Center，提供 TLS、WSS、RBAC、遷移、回復與 CI 安全測試。

## 快速開始

```bash
cp .env.example .env
./scripts/init.sh
docker compose up -d
./scripts/wait-dynsec-bootstrap.sh
./scripts/dynsec-command.sh listClients
```

映像使用 2.1.2 multi-architecture manifest digest 固定，不會因同名 tag 被更新而漂移。

## Listener 與信任邊界

| Listener | 協定 | 驗證 | 可達範圍 |
|---|---|---|---|
| 1883 | MQTT | 匿名，不使用 Dynamic Security | 僅內部 Docker network |
| 8883 | MQTTS | TLS + Dynamic Security | 主機對外 port |
| 9001 | WSS | TLS + Dynamic Security | 預設僅 localhost |
| 1884 | MQTTS | 專用管理帳號 + Dynamic Security | 僅隔離控制 network |

1883 與 1884 均不發布到主機。一般應用服務只能加入 `mqtt-internal`；只有一次性的管理容器能加入 `mqtt-control`。

## 使用者與權限管理

```bash
# 建立帳號；預設沒有角色，因此無 topic 權限
./scripts/create-user.sh device-01

# 執行原生 mosquitto_ctrl dynsec 命令
./scripts/dynsec-command.sh listClients
./scripts/dynsec-command.sh createRole telemetry-writer
./scripts/dynsec-command.sh addRoleACL \
  telemetry-writer publishClientSend 'devices/%u/telemetry/#' allow 10
./scripts/dynsec-command.sh addClientRole device-01 telemetry-writer 50
```

管理密碼由 Docker secret 傳入隔離的工具容器，不會直接出現在主機程序參數。應用帳號採 default deny；`admin` 僅能管理 Dynamic Security 與讀取 `$SYS`，不能發布一般應用 topic。

## 舊版遷移

由 Mosquitto password/ACL 檔遷移前，先填寫帳號 owner：

```bash
cp mosquitto/config/security/migration-owners.example.csv \
  mosquitto/config/security/migration-owners.csv
./scripts/migrate-dynsec.sh
```

完整的 hash 相容性、ACL priority、驗收及降版步驟請見 [Mosquitto 2.1 與 Dynamic Security 遷移手冊](docs/migration-dynamic-security.md)。

## 驗證

```bash
./scripts/validate.sh
python3 tests/task7_migration_test.py
make test
```

CI 會驗證內部匿名 listener、外部匿名拒絕、TLS/WSS、使用者驗證、allow/deny/wildcard、角色與群組 priority、控制面隔離，以及遷移失敗自動回復。

## 文件

- [架構](docs/architecture.md)
- [設定](docs/configuration.md)
- [營運](docs/operations.md)
- [安全](docs/security.md)
- [遷移與回復](docs/migration-dynamic-security.md)
