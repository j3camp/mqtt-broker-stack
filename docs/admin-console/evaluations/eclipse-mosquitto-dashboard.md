# Eclipse Mosquitto Dashboard 評估

## Evidence snapshot

- 儲存庫：<https://github.com/eclipse-mosquitto/mosquitto>
- 固定 commit：`7b8aba105b77253309de24664bbae69d0cae3da0`
- 授權：EPL-2.0 OR BSD-3-Clause
- Dashboard README 明確稱其為 Mosquitto 的簡易網頁圖形介面，並要求搭配
  Mosquitto HTTP API。
- `src/app/consts.js` 只有 `/api/v1/systree` 與 `/api/v1/listeners` 兩個端點。
- Mosquitto 2.1 官方 `mosquitto.conf` 文件說明 `protocol http_api` listener 可透過
  `http_dir` 同時提供靜態檔案。

一手證據：

- <https://github.com/eclipse-mosquitto/mosquitto/blob/7b8aba105b77253309de24664bbae69d0cae3da0/dashboard/README.md>
- <https://github.com/eclipse-mosquitto/mosquitto/blob/7b8aba105b77253309de24664bbae69d0cae3da0/dashboard/src/app/consts.js>
- <https://github.com/eclipse-mosquitto/mosquitto/blob/7b8aba105b77253309de24664bbae69d0cae3da0/LICENSE.txt>
- <https://mosquitto.org/man/mosquitto-conf-5.html>

## PoC procedure

1. 以 `poc/eclipse-mosquitto-dashboard/compose.yaml` 建置固定 commit 的 Dashboard。
2. 由 Mosquitto 2.1.2 `http_api` listener 同源提供 UI 與 API。
3. 確認首頁 broker／client／message 圖表及 listeners 頁面可讀。
4. 確認只有 `127.0.0.1` 可存取，沒有 Docker socket 與 production 資料。
5. 記錄瀏覽器網路錯誤、API 回應及頁面截圖；本機沒有 Docker 時標記為未執行。

## Findings

這是三個候選中治理最直接的上游方案：Dashboard 原始碼與 Mosquitto 位於同一個
Eclipse 儲存庫，授權明確，且 Mosquitto 2.1 原生提供相符的 HTTP API。它能作為
唯讀 broker overview 的低成本基底，也能減少另外維護 metrics collector 的需求。

功能邊界同樣明確：目前程式只讀取 system tree 與 listeners，不含 Dynamic
Security、後台使用者、稽核、有效權限模擬或 Topic Explorer。因此它是監控介面，
不是完整管理後台。

## Security review

PoC 將 HTTP listener 綁定 loopback、使用 internal network、唯讀檔案系統、移除
Linux capabilities，且沒有 MQTT 或管理憑證送到瀏覽器。官方 Dashboard 本身沒有
登入與 RBAC；匿名 HTTP API 不得直接發布到 production 網路。正式整合時必須由
OIDC 反向代理或自有控制平面保護，並將其維持唯讀。

## Limitations

- 尚無 Dashboard 獨立 release、容器映像、production 部署文件或升級承諾。
- 未提供 DynSec、OIDC、RBAC、audit、effective permission 或 Topic Explorer。
- PoC 建置需從 GitHub 下載固定 commit；基底映像目前固定 tag、未固定 digest。
- 本機沒有 Docker daemon 時，只能完成靜態驗證，不能宣稱 runtime 已通過。

## Scorecard conclusion

加權 36.0 分，因 Dynamic Security、操作人員登入／RBAC、稽核與有效權限分析低於
必要門檻而不符合直接採用資格。建議在 custom hybrid 中重用其唯讀資訊架構或靜態
資產，但不把它當成 production 控制平面。
