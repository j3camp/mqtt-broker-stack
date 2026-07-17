# MQTT 管理後台需求

本需求作為 [Story #4](https://github.com/j3camp/mqtt-broker-stack/issues/4)、
[#5](https://github.com/j3camp/mqtt-broker-stack/issues/5) 與
[#6](https://github.com/j3camp/mqtt-broker-stack/issues/6) 的評估契約。

## Personas（角色）

| Persona | 責任 | 允許影響範圍 |
|---|---|---|
| Viewer | 查看 broker 健康、指標、日誌與去敏 audit 事件 | 唯讀 |
| Operator | 診斷連線並使用受限 Topic Explorer | 低風險操作 |
| Security Admin | 管理 MQTT client、group、role、ACL 與憑證 | 安全性異動 |
| Super Admin | 管理操作人員權限與核准的高風險流程 | 必須明確確認的管理操作 |

人員身分必須與 MQTT 裝置／應用身分分離。正式環境使用 OIDC；本機 bootstrap 帳號
只供復原，完成設定後必須停用或輪替，且不得同時作為 broker credential。

## Primary workflows（主要流程）

1. 以唯讀權限檢查 broker 健康、listeners、persistence、憑證到期日與資料新鮮度。
2. 透過 Dynamic Security 建立、停用、啟用、輪替與刪除 MQTT client，不直接修改
   其 JSON state。
3. 指派 group 與 role、編輯 ACL priority，並在套用前預覽 username、client ID、
   topic 與 action 合併後的 allow／deny 結果。
4. 以連線資訊、broker log、metrics 與 audit event 診斷 online／offline client。
5. 透過具 rate limit 與最小權限的 Topic Explorer publish／subscribe，且瀏覽器不
   取得管理者 credential。
6. preview、validate、apply、health-check 並 rollback 設定或憑證變更。
7. 以經驗證的復原流程 backup／restore broker、Dynamic Security 與後台狀態。

## Capability classification（能力分級）

### 必要

- 明確的網路與 credential 邊界；web app 不得掛載 Docker socket。
- Mosquitto Dynamic Security client、group、role 與 ACL 管理。
- 伺服器端操作人員驗證、OIDC 與 RBAC。
- 安全性異動必須產生可歸屬、去敏、僅可附加的 audit event。
- 可分析 wildcard、priority 與 deny rule 的 effective permission。
- 相容本儲存庫 Docker Compose 與 internal／external listener 分離模型。
- 採可修改與散布、經 OSI 認可的開源授權。

任一必要條件低於 3／5，即使加權總分較高也不符合資格。

### 偏好

- Prometheus／Grafana metrics 與 Alloy／Loki log 整合。
- 受限 MQTT message explorer。
- 經驗證的設定、憑證、backup、restore 與 rollback 流程。
- 有正式 release、活躍維護與清楚升級路徑。
- 導入與長期交付成本低。

### 本次決策不含

- 更換 Mosquitto broker。
- broker clustering 或 high availability。
- 業務領域 IoT dashboard 與 device digital twin。
- 任意 remote shell、任意檔案系統存取或不受限 Docker daemon 存取。

## Functional requirements（功能需求）

- 顯示 broker version、uptime、listeners、連線狀態、憑證資訊與資料新鮮度。
- 透過 `$CONTROL/dynamic-security/v1` 管理 MQTT identity lifecycle。
- 管理 group、role、ACL type、topic filter、priority 與 default access。
- 在政策變更套用前模擬 effective permission。
- 搜尋與匯出 audit event，且不得洩漏 password、private key 或不受限 payload。
- 整合 broker metrics 與 logs，監控身分不得擁有 mutation 權限。
- Topic Explorer 同時受 application RBAC 與 broker ACL 約束。

## Non-functional requirements（非功能需求）

### 安全

- 管理入口使用 HTTPS，broker control traffic 必須加密。
- 祕密存放於 Docker Secrets 或核准的 secret store。
- 實作 least privilege、適用的 CSRF 防護、rate limit、安全 session cookie 與
  destructive-action confirmation。
- 管理應用不得掛載 `/var/run/docker.sock`，不得下載 private key。

### 可靠度

- apply 前先 validate，完成後驗證 broker health。
- 高風險操作使用 atomic replacement 與自動 rollback。
- monitoring 或 audit 故障不得阻斷 broker message flow。
- 保留既有未發布到 host 的 anonymous listener 信任邊界。

### 可維運性

- production 與 PoC dependency 必須固定明確 version 或 commit。
- 提供 health／readiness check、結構化 log、backup／rollback 說明與
  configuration-as-code 預設值。
- 必須顯示 stale、partial、unknown 與 planned 證據，不能把假設當成已驗證結果。

### 可維護性

- 協定細節放在 Mosquitto adapter 後方。
- 操作人員 identity、broker identity、observability 與 privileged host operation
  必須分離。
- CI 必須測試 scorecard、PoC security invariant 與 ADR 一致性。

## Out of scope（範圍外）

Task #3 只完成架構決策與可重現候選 PoC，不實作正式後台、不遷移 live broker，
也不把 evaluation service 公開到網路。

## Evidence requirements（證據要求）

每一項分數必須包含：

1. 依 `scorecard.json` 定義給予 0 至 5 分。
2. status 為 verified、partial、unknown、blocked 或 planned。
3. 簡潔、可檢查的事實說明。
4. 至少一個上游儲存庫或官方文件的一手來源。
5. 用於重現的固定 source commit。

PoC 文件必須分開記錄靜態驗證、需要 Docker runtime 才能驗證的項目，以及該結果
為何足以或不足以支持 production 決策。
