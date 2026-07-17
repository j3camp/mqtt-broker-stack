# mqtt-broker-stack 開發指引

## 專案定位

本專案以 Docker Compose 部署 Eclipse Mosquitto 2.1，採用 Mosquitto 原生開源 Dynamic Security plugin 實作帳號、角色、群組與 ACL。不要整合 Cedalo Management Center；MQTTX Web 僅可作為選配的開發 client，不是 Broker 管理後台。

## 固定架構

- 映像必須以 `.env` 的 `MOSQUITTO_IMAGE` 同時固定 2.1.x tag 與 multi-architecture manifest digest，不使用 `latest` 或可漂移 tag。
- 1883：只存在於 `mqtt-internal`，匿名、無 TLS、不使用 Dynamic Security，不得發布到主機。
- 8883：對外 MQTTS，TLS、Dynamic Security、禁止匿名。
- 9001：WSS，TLS、Dynamic Security、禁止匿名，預設只發布到 localhost。
- 1884：只存在於 `mqtt-control`，TLS、Dynamic Security、禁止匿名，不得發布到主機。
- 不得使用 `per_listener_settings`、`password_file` 或 runtime `acl_file`；Mosquitto 2.1 listener 必須明確使用 `listener_allow_anonymous`、`plugin_load` 與 `plugin_use`。
- 不得掛載 Docker socket、CA private key，或使用 privileged mode。

## Dynamic Security 原則

- 四類 default ACL access 均為 deny。
- 管理帳號只保留 `dynsec-admin` 與 `sys-observe`，不可發布一般應用 topic。
- 新應用帳號預設不指派角色；權限必須明確建立並記錄 owner。
- 明確 deny 使用高於 allow 的 priority。
- 管理命令只經過隔離的 `dynsec-admin` 容器及 TLS 控制 listener。
- 管理密碼、Dynamic Security JSON、migration ownership CSV 與備份都視為敏感資料，不得提交 Git。

## 遷移與相容性

- 密碼／ACL 遷移必須保留可支援的 `$7$` PBKDF2 與 Argon2id hash；只有不能安全轉換的 hash 才要求輪替。
- 切換前建立含 SHA-256 的 rollback checkpoint，候選狀態以 atomic rename 安裝。
- 切換後健康或權限驗證失敗必須自動回復。
- 升級與降版程序維護於 `docs/migration-dynamic-security.md`。

## 程式與驗證標準

- Bash script 使用 `set -Eeuo pipefail`；POSIX `sh` script 使用 `set -eu`。
- 引用所有變數、驗證外部輸入、使用 `mktemp` 與 `trap` 清理、避免 `eval` 與 `chmod 777`。
- 密碼不可出現在程序參數、log 或 Git；非互動密碼透過 stdin 或 secret 傳遞。
- 修改時先寫失敗測試，再做最小實作並執行 regression。
- 至少執行 `python3 tests/task7_migration_test.py`、shell syntax、YAML parse 與可用的整合測試。
- Docker 不可用時，完成靜態實作並明確列出尚待 CI 執行的 Docker 測試。
