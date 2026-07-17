# 安全設計

## 驗證與傳輸

- 8883、9001 與 1884 皆要求 TLS 1.2 以上及 Dynamic Security 驗證。
- 1883 允許匿名，只存在於可信任的 internal Docker network。
- 外部與控制 listener 明確 `listener_allow_anonymous false`。
- 管理密碼使用 Docker secret；一般備份刻意不包含其明文。

## 最小權限

- Dynamic Security 的四項 default ACL access 均為 deny。
- 應用帳號建立後若未指派角色，只有驗證身分，不能存取任何 topic。
- 遷移帳號各自擁有明確角色，避免把個人權限意外提升為群組權限。
- `admin` 只保留 `dynsec-admin` 與 `sys-observe`，不保留 `super-admin`、`client` 或 `topic-observe`。
- deny ACL 使用較高 priority，確保明確拒絕優先於較廣的 allow。

## 控制面

控制 listener 綁定 `mqtt-control` 的固定 broker IP，沒有 host port。管理 helper 唯讀、drop 所有 capabilities、禁止 privilege escalation，也沒有 Docker socket。一般應用 network 對 1884 不可達。

## 敏感檔案

| 檔案 | 保護方式 |
|---|---|
| `.env` | 不提交，限制部署主機讀取權 |
| `dynsec-admin-password` | mode 600、Docker secret、另存秘密管理系統 |
| `dynamic-security.json` | named volume、備份加密、不得公開 |
| `migration-owners.csv` | 不提交，視為帳號治理資料 |
| server／CA private key | 不提交，正式環境交由 PKI 管理 |
| `backups/` | mode 600、加密、限制保存期限 |

## 安全驗證

CI 同時測試成功與失敗路徑。除了 TLS 與正確帳密，還會驗證匿名與錯誤密碼拒絕、應用 admin publish 拒絕、wildcard 邊界、ACL priority、控制面隔離及 rollback 完整性。
