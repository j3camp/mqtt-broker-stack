# Eclipse Mosquitto Dashboard PoC

這是 evaluation only 的隔離驗證環境，用來確認 Mosquitto 2.1 原生 HTTP API
與官方 Dashboard 靜態介面的整合方式。它不是 production 部署範本，禁止連接正式
broker、網路、憑證、帳號或資料。

上游來源固定在 commit `7b8aba105b77253309de24664bbae69d0cae3da0`；建置時會
下載該版本原始碼，只複製 `dashboard/src`，再由 Mosquitto 2.1.2 的 `http_api`
listener 同源提供 API 與靜態內容。

```bash
cp .env.example .env
docker compose --env-file .env -f compose.yaml config
docker compose --env-file .env -f compose.yaml up --build
```

開啟 `http://127.0.0.1:18080`，檢查 broker 指標圖表與 listeners 頁面。完成後：

```bash
docker compose --env-file .env -f compose.yaml down
```

已由靜態測試確認：固定 commit、固定 Mosquitto 版本、loopback 發布、內部網路、
唯讀檔案系統、移除 capabilities，且未掛載 Docker socket。執行期仍須以可用的
Docker daemon 驗證建置、HTTP 回應與圖表資料；本機無 Docker 時不應宣稱已完成
該項驗證。

安全限制：Dashboard 本身沒有 OIDC、操作人員 RBAC、DynSec、稽核、有效權限分析
或 Topic Explorer。匿名 HTTP API 只因綁定 loopback 才適合此 PoC，production
環境必須改由具身分驗證的反向代理與網路政策保護。
