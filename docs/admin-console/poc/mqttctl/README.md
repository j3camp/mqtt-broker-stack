# MqttCtl PoC

這是 evaluation only 的隔離驗證環境，固定使用 MqttCtl commit
`9231e01e8b159957c777e0749b8c8e4d48c69b55`。它會建置 MqttCtl 與其
broker-agent，並啟動獨立的 Mosquitto 2.0.21；不得連接 production broker、
正式帳號、憑證、網路或資料。

先複製環境檔，並將 `config/*.json5` 與 `config/*.json` 內所有 `CHANGE_ME`
替換為僅供本機使用的隨機值：

```bash
cp .env.example .env
docker compose --env-file .env -f compose.yaml config
docker compose --env-file .env -f compose.yaml up --build
```

開啟 `http://127.0.0.1:13000`，依序驗證 local login、DynSec client／group／
role／ACL、有效權限、audit、snapshot 與 MQTT Explorer。完成後：

```bash
docker compose --env-file .env -f compose.yaml down
```

已由靜態測試確認：兩個建置 context 均固定在相同 commit、僅將 UI 綁定
loopback、使用內部網路，且未掛載 Docker socket。執行期建置會使用上游 Dockerfile
內的 Node 24 與 Mosquitto 2.0.21；這些基底尚未固定 digest，也尚未證明能接入本專案
的 Mosquitto 2.1 與分離 listener 架構，因此此 PoC 不能作為 production 核准依據。
