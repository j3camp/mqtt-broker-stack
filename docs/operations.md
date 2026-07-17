# 營運

## 初始化與啟動

```bash
./scripts/init.sh
docker compose up -d
./scripts/wait-dynsec-bootstrap.sh
./scripts/validate.sh
```

非互動初始化可用 `DYNSEC_ADMIN_PASSWORD` 提供管理密碼；請只在受保護的 CI secret 或秘密管理工具中設定。

## 帳號與 RBAC

```bash
MQTT_NEW_PASSWORD='temporary-secret' ./scripts/create-user.sh device-01
./scripts/dynsec-command.sh createRole telemetry-writer
./scripts/dynsec-command.sh addRoleACL \
  telemetry-writer publishClientSend 'devices/%u/telemetry/#' allow 10
./scripts/dynsec-command.sh addClientRole device-01 telemetry-writer 50
./scripts/change-password.sh device-01
./scripts/delete-user.sh device-01
```

每次權限異動都應記錄資源 owner、角色／群組 priority 與有效權限，並測試一個應允許及一個應拒絕的案例。

## 遷移與回復

```bash
./scripts/migrate-dynsec.sh
./scripts/rollback-dynsec.sh
```

詳細作業與降版流程請見 [遷移手冊](migration-dynamic-security.md)。遷移會自動建立帶 SHA-256 的 checkpoint；切換後驗證失敗時自動回復。

## 備份與還原

```bash
./scripts/backup.sh
./scripts/restore.sh backups/mqtt-broker-backup-<timestamp>.tar.gz
```

備份包含 Mosquitto 設定、公開憑證、持久化資料、Dynamic Security 狀態，以及仍存在的 legacy 遷移輸入。備份不包含管理員明文 secret 或 TLS private key。備份本身具有敏感權限資料，必須加密並限制存取。

## 監控與疑難排解

```bash
docker compose ps
docker compose logs mosquitto
./scripts/dynsec-command.sh listClients
openssl x509 -noout -dates -in mosquitto/config/certs/server.crt
```

驗證失敗時依序檢查：憑證 SAN 是否包含實際 hostname、管理 secret mode 是否為 600、broker 健康狀態、帳號是否 disabled、角色／群組與 ACL priority。

## 常用 Make target

| Target | 用途 |
|---|---|
| `make init` | 初始化 `.env`、憑證與管理 secret |
| `make up`／`down` | 啟停 stack |
| `make validate` | 靜態與執行期驗證 |
| `make dynsec ARGS='listClients'` | 執行管理命令 |
| `make migrate-dynsec` | 遷移舊帳密與 ACL |
| `make rollback-dynsec` | 回復最後一次遷移 |
| `make backup`／`restore` | 備份與還原 |
| `make test` | 執行 shell 整合測試 |
