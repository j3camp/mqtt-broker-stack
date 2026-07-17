# MqttCtl 評估

## Evidence snapshot

- 儲存庫：<https://github.com/Slyke/mqttctl>
- 固定 commit：`9231e01e8b159957c777e0749b8c8e4d48c69b55`
- 授權：MIT
- README 與原始碼顯示已涵蓋 DynSec、local／OIDC／trusted-header 登入、伺服器端
  RBAC、SHA-256 串鏈 audit、有效權限、snapshot 與 MQTT Explorer。
- 上游 Compose 會建置自己的 broker-agent 與 Mosquitto 2.0.21，沒有直接驗證本專案
  Mosquitto 2.1 與分離 listener 的接入方式。

一手證據：

- <https://github.com/Slyke/mqttctl/blob/9231e01e8b159957c777e0749b8c8e4d48c69b55/README.md>
- <https://github.com/Slyke/mqttctl/blob/9231e01e8b159957c777e0749b8c8e4d48c69b55/docker-compose.yml>
- <https://github.com/Slyke/mqttctl/blob/9231e01e8b159957c777e0749b8c8e4d48c69b55/dockerfiles/broker-agent.Dockerfile>
- <https://github.com/Slyke/mqttctl/blob/9231e01e8b159957c777e0749b8c8e4d48c69b55/LICENSE.md>

## PoC procedure

1. 以 `poc/mqttctl/compose.yaml` 建置固定 commit 的 UI 與 broker-agent。
2. 將 UI 只綁定 `127.0.0.1`，不發布 PoC broker 的 MQTT port。
3. 驗證 local login、DynSec CRUD、有效權限、audit、snapshot 與 MQTT Explorer。
4. 檢查 browser、UI、broker-agent 與 broker 之間的憑證及祕密流向。
5. 對照本專案 Mosquitto 2.1 listener／plugin 設定，列出 migration blocker。

## Findings

MqttCtl 在功能面最接近需求，必要的管理功能多數已有程式與文件證據。控制平面與
broker-agent 分離也是合理方向，避免 web app 直接取得 Docker socket。

主要阻礙在部署與成熟度：上游範例將 Mosquitto 2.0.21 包進 broker-agent 映像，
設定使用已於 2.1 棄用的 `per_listener_settings`，且專案建立於 2026 年、尚無正式
release。直接接入既有 broker 的最小權限、TLS、備份與回復邊界仍需實測。

## Security review

上游設計具有伺服器端 RBAC、稽核及不提供私鑰下載等正面控制。範例仍使用 HTTP、
固定示範祕密與廣泛 broker-agent 檔案權限。PoC 已限制 host port 與網路，但設定檔
中的 `CHANGE_ME` 只適合本機 evaluation；production 必須改用 secret store、TLS、
OIDC，並縮小 agent 可操作的檔案與程序。

## Limitations

- 尚未以 Docker runtime 執行本地 PoC；建置、登入及功能流程仍待動態驗證。
- 上游 Dockerfile 的 base image 使用 tag 而非 digest，供應鏈重現性不完整。
- 尚未證明 broker-agent 可安全管理本專案既有 Mosquitto 2.1 container。
- 尚無正式 release、升級相容矩陣或長期維護紀錄。

## Scorecard conclusion

加權 76.0 分，但 deployment fit 僅 2 分，未通過必要門檻，因此目前不直接採用為
production 控制平面。保留為設計與實作參考，於 2026-10-17 重新檢視 release、
Mosquitto 2.1 相容性及外接 broker 模式。
