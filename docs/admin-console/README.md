# MQTT 管理後台架構決策套件

本目錄包含 [Task #3](https://github.com/j3camp/mqtt-broker-stack/issues/3)
可由測試驗證的架構選型成果：

- `requirements.md`：角色、流程、範圍與證據規則。
- `scorecard.json`：機器可讀的加權比較。
- `evaluations/`：各候選的一手證據、PoC 結果與限制。
- `poc/`：隔離且固定版本的評估環境。
- `../adr/0001-mqtt-admin-console.md`：已接受的架構決策。

執行下列測試驗證決策套件：

```bash
bash tests/test-admin-console-architecture.sh
```

PoC 只供評估，不得連接正式 broker、帳號、網路、憑證或資料。

## 決策摘要

採用薄型自行開發混合控制平面：以 Mosquitto adapter 封裝 Dynamic Security；
官方 Eclipse Mosquitto Dashboard 僅作為唯讀 broker overview 的重用基底；Topic
Explorer 重用 MQTTX 或受限 relay；監控重用 Grafana、Prometheus、Alloy 與 Loki。

目前不把官方 Dashboard 或 MqttCtl 直接當作 production 控制平面。MqttCtl 功能覆蓋
高，但需在 2026-10-17 重新檢視正式 release、Mosquitto 2.1 相容性與外接 broker
的最小權限部署證據。
