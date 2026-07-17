# Mosquitto 2.1 與 Dynamic Security 遷移手冊

本手冊說明如何由 Mosquitto 2.0 的 `password_file`／`acl_file` 遷移至固定版本的 Mosquitto 2.1.2 與 Dynamic Security。正式環境應先在同等資料副本演練，並保留舊映像、設定及備份，直到驗收期結束。

## 目標架構

| Listener | 用途 | 驗證與授權 | 網路邊界 |
|---|---|---|---|
| 1883/MQTT | 可信任應用程式 | 匿名；不載入 Dynamic Security | 僅 `mqtt-internal`，不發布到主機 |
| 8883/MQTTS | 外部應用程式 | TLS + Dynamic Security | 可依 `.env` 發布 |
| 9001/WSS | 瀏覽器應用程式 | TLS + Dynamic Security | 預設僅 `127.0.0.1` |
| 1884/MQTTS | 管理控制面 | TLS + 專用管理帳號 | 僅 `mqtt-control`，固定 `172.31.0.2`，不發布到主機 |

`admin` 只具有 `dynsec-admin` 與 `sys-observe` 角色，不具有應用 topic 發布權。應用容器只加入 `mqtt-internal`，管理命令由一次性的 `dynsec-admin` 容器執行。

## 遷移前檢查

1. 建立完整備份，確認可還原 Mosquitto 設定、持久化資料、舊密碼檔及 ACL。
2. 保留原本 2.0.x 映像的完整 tag 或 digest；降版時不可沿用 2.1 專用設定。
3. 複製 `.env.example` 為 `.env`，確認 `MOSQUITTO_IMAGE` 為已測試的 2.1.2 digest。
4. 產生憑證時必須包含控制面名稱：

   ```bash
   ./scripts/generate-cert.sh --hostname mqtt.example.local --dns mosquitto-control
   ```

5. 建立專用管理密碼。此檔不進 Git，也不會包含在一般備份內，應另存於秘密管理系統：

   ```bash
   ./scripts/bootstrap-dynsec.sh
   ```

6. 啟動 broker，等候健康檢查通過。2.1 首次啟動會由 secret 初始化 Dynamic Security 管理帳號。

## 身分所有權盤點

複製範例檔並逐一指定每個舊帳號的負責人及群組：

```bash
cp mosquitto/config/security/migration-owners.example.csv \
  mosquitto/config/security/migration-owners.csv
```

CSV 欄位必須精確為 `username,owner,group`，而且必須與密碼檔中的帳號一對一對應。群組只用於盤點及後續治理；遷移程式不會將使用者 ACL 提升為共用群組權限。

## 密碼與 ACL 轉換規則

- Mosquitto `$7$` PBKDF2 與 Argon2id 雜湊會直接保留，不要求無謂的密碼輪替。
- 未知或無法安全轉換的雜湊會讓遷移以狀態碼 2 結束，且不產生候選檔；必須先輪替該帳號密碼。
- 每個使用者取得獨立角色；舊 `read`、`write`、`readwrite` 與 `deny` 規則會轉為 Dynamic Security ACL。
- deny 規則 priority 為 100，allow 為 10，明確拒絕會優先。
- `pattern` 與 `%u` wildcard 會保留；所有預設 ACL 均為 deny。
- 未列 ACL 的應用帳號可以驗證，但沒有 topic 權限。

## 執行遷移

```bash
./scripts/migrate-dynsec.sh \
  --password-file mosquitto/config/security/passwords \
  --acl-file mosquitto/config/security/acl \
  --owners-file mosquitto/config/security/migration-owners.csv
```

流程會先從執行中的 broker 取出 Dynamic Security 原始狀態，連同舊密碼、ACL、所有權 CSV 與 SHA-256 建立 checkpoint；候選 JSON 通過語法檢查後才停止 broker，以同一 volume 內的 atomic rename 完成切換。切換後健康檢查或管理驗證失敗會自動回復 checkpoint。

## 驗收

```bash
./scripts/validate.sh
./scripts/dynsec-command.sh listClients
bash tests/test-internal.sh
bash tests/test-external-anonymous-denied.sh
bash tests/test-external-auth.sh
bash tests/test-acl.sh
python3 tests/test-wss-auth.py
bash tests/test-control-isolation.sh
```

驗收至少涵蓋匿名拒絕、允許／拒絕、wildcard、角色／群組 priority、WSS、控制面隔離，以及管理員不可發布應用 topic。CI 另以注入的切換後失敗驗證自動回復。

## 回復 Dynamic Security 狀態

使用遷移輸出的 checkpoint，或省略參數使用最後一次 checkpoint：

```bash
./scripts/rollback-dynsec.sh --checkpoint backups/dynsec-migration-<timestamp>
```

回復程式會先驗證 SHA-256，再停止 broker、atomic replace 狀態檔、重新啟動，最後驗證健康狀態與管理權限。

## 降版至 Mosquitto 2.0

若必須降回 2.0.x：

1. 停止 broker，保留目前 2.1 volume 的唯讀副本。
2. 還原遷移前的 2.0 設定、`password_file`、`acl_file` 與持久化資料。
3. 將 `.env` 改回原先保存的 2.0.x immutable image；不可讓 2.0 讀取本專案的 2.1 listener／plugin 設定。
4. 啟動並重新執行原版本的匿名、TLS、帳密與 ACL 測試。
5. 確認應用程式恢復後，才移除維護模式。

Dynamic Security JSON 不是 2.0 password/ACL 檔的替代降版來源，因此遷移前備份是必要條件。

## 營運注意事項

- `dynsec-admin-password`、TLS 私鑰及備份皆視為敏感資料，應限制為最小權限並分開保管。
- 不要將一般應用服務加入 `mqtt-control`，也不要把 1884 發布到主機。
- 變更角色、群組或 ACL 後，記錄資源 owner、變更理由及預期有效權限，並執行允許與拒絕測試。
- 升級其他 2.1.x 版本前，先更新 digest 並重跑完整 CI；tag 不視為 immutable pin。
