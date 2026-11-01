# E10 → Keycloak → Amazon Quick 桥接方案

保底方案：Quick Web 和 Quick Desktop 都经过 Keycloak 登录，Keycloak 再通过 OIDC 对接 E10 统一认证中心。
E10 上只需建 **一个 OIDC 认证应用**（客户端就是 Keycloak）。

```
浏览器 / Quick Desktop
   │
   ├─ Desktop：OIDC 公共客户端 + PKCE ──┐
   └─ Web：SAML（经 IAM Identity Center）┤
                                        ▼
                         Keycloak（realm corp，CloudFront 提供 HTTPS）
                                        │  OIDC 授权码 + client_secret（机密客户端）
                                        ▼
                        E10 统一认证中心（客户为公网 http + 20600 端口）
```

| 文档 | 内容 |
|---|---|
| [aws/KEYCLOAK-DEPLOY.md](aws/KEYCLOAK-DEPLOY.md) | **Keycloak 栈怎么部署、怎么桥接客户 E10**（步骤、参数、输出、部署后修改、运维、排错） |
| [aws/QUICK-SETUP.md](aws/QUICK-SETUP.md) | **在 Amazon Quick 里怎么配置**（Desktop、Web 经 IAM Identity Center、E10 为 http 的影响、费用、PoC 限制） |

## 1. 部署

| 场景 | 命令 | 部署什么 |
|---|---|---|
| **客户环境** | `E10_BASE_URL=http://<E10地址>:20600 E10_CLIENT_ID=<应用标识> aws/deploy.sh` | 只部署 Keycloak，对接客户的 E10。步骤见 [aws/KEYCLOAK-DEPLOY.md](aws/KEYCLOAK-DEPLOY.md) |
| 测试环境 | `TEST_USER_EMAIL=<Quick 里已有用户的邮箱> mock/deploy-mock.sh` | 模拟 E10 + Keycloak（内部调用同一个 `aws/deploy.sh`） |

Keycloak 一侧（身份提供商、映射、登录流程、Desktop 客户端）由 `aws/deploy.sh` 自动配置；E10 一侧要客户在后台建认证应用，部署后再把 Keycloak 回调地址填进去。

- **Keycloak**（`<前缀>-keycloak`）：前面是 CloudFront（提供 HTTPS 和公网域名），安全组只放行 CloudFront 回源 IP；管理控制台和 master realm 在 CloudFront 上一律 403，只能通过 SSM 端口转发访问。实例用固定弹性 IP，停机再启动不影响 CloudFront 回源和 E10 白名单；签名密钥和 IAM Identity Center 的 SP 元数据另存在 Secrets Manager / SSM，实例重建后 IdP 证书和 SAML 客户端不变。E10 是公网 http 时，`setup-keycloak.py` 会把 corp realm 的 SSL 要求设为 none（否则 Keycloak 拒绝 http 的身份提供商）。
- **模拟 E10**（`<前缀>-mock-e10`，仅测试）：按客户实际情况，公网 **http + 20600 端口**、固定弹性 IP，没有 HTTPS。管理接口 `/__mock/*` 只接受实例本机请求（经 SSM 调用）。
- 所有密码在实例首次启动时随机生成，存在 Secrets Manager。部署代码放在私有 S3 桶 `<前缀>-artifacts-<账号>-<区域>`。

```bash
aws/info.sh                      # Keycloak 对接信息（加 --secrets 显示管理员密码）
mock/info-mock.sh --secrets      # 测试环境：模拟 E10 信息和测试密码
mock/verify.sh                   # 测试环境：端到端验证
mock/destroy-mock.sh             # 测试环境：删除模拟 E10
aws/destroy.sh --purge-bucket    # 删除 Keycloak（和代码桶）
```

2026-10-31 在账号 271547278201（ap-northeast-1）部署测试环境并验证（模拟 E10 为 http://13.112.194.233:20600）：
`mock/verify.sh` 14 项全部通过（Desktop 经 Keycloak 的 email 与 Quick 用户 `mingzhang@nwcdcloud.cn` 一致、Keycloak 端点全部 HTTPS、无警告；
直连 http 的 E10 被判定不能配给 Quick Desktop）。

## 2. 验证结论

| 路径 | 结果 | 说明 |
|---|---|---|
| Desktop（公共客户端 + PKCE） | 通过 | ID token 含 email、RS256 验签、iss/aud 正确；不带密钥能刷新；错误的 code_verifier 被拒绝 |
| Web（SAML → IAM Identity Center） | 通过 | NameID = emailAddress 格式的邮箱；断言和响应签名可用 IdP 元数据证书验签；未加密；Audience / Recipient / InResponseTo / RelayState 正确；IdP 元数据不含加密密钥 |
| 单点会话 | 通过 | 同一浏览器第二次登录不再输入 E10 密码 |
| E10 访问控制 | 通过 | 不在 E10 共享范围、未维护邮箱的用户停在 E10 提示页，进不了 Keycloak |
| 对照：Desktop 不经 Keycloak 直连 E10 | 不通过（符合预期） | 不带 client_secret 换 token 失败（`应用密钥(client_secret)不能为空`），刷新也要求密钥；E10 是 http，也不能配给 Quick |

Quick 和 IAM Identity Center 本身没有参与以上自动验证：SAML 由 `tests/saml-sp-test.js` 模拟 IAM Identity Center 检查（拦截发往 AWS ACS 的请求）；Desktop 由 `e10-oidc-pkce-test.py` 模拟（和 Desktop 一样的公共客户端 + PKCE 流程）。退出登录（单点登出）没有测试。

### E10 文档没写清楚的行为：对桥接的影响

早期用本机模拟环境（现已移除）把这些行为做成开关逐一测过：

| E10 的行为 | Keycloak 配置 | 结果 | 结论 |
|---|---|---|---|
| 不回传 nonce、无 token_type、JWKS 无 `use`、出错返回 HTTP 200（按文档推断的默认行为） | 默认（不发 nonce） | 通过 | **当前配置** |
| 不回传 nonce | 发送 nonce | 失败：`OpenID Provider [oidc] did not return a nonce` | E10 不回传 nonce 时，**必须不发 nonce**（`NONCE_MODE=disable`，默认） |
| 回传 nonce | 发送 nonce | 通过 | 确认真实 E10 回传 nonce 后，可以 `NONCE_MODE=send`，多一层防重放 |
| token 接口只读 URL 参数，不读 POST 表单 | 默认 | 失败：`No access_token from server` | **阻断性风险**。Keycloak 只会把参数放在 POST 表单里。联调测试 B2（带密钥）也用 POST 表单，能通过就排除 |
| 请求未配置的 scope 时报错 | 默认（只请求 `openid email profile`） | 通过 | Desktop 请求的 `offline_access` 由 Keycloak 处理，不会传给 E10 |
| id_token 里没有 email | `EMAIL_FROM=sub`（E10 账号映射设为电子邮箱） | 通过 | 兜底方案可用 |
| 更标准：出错 HTTP 400、带 token_type、JWKS 带 use | 默认 | 通过 | — |
| 公网 http（无 TLS） | 默认（脚本自动放宽 corp realm 的 SSL 要求） | 通过（云上验证） | 见 QUICK-SETUP.md 第 3 节的影响说明 |

Keycloak 实际发给 E10 token 接口的参数：`code, grant_type, redirect_uri, client_secret, client_id`，放在 POST 表单里，不带 code_verifier。

## 3. 目录

**`aws/`：到客户那里用的（只部署 Keycloak，对接客户 E10）**

| 路径 | 内容 |
|---|---|
| `aws/keycloak-bridge.yaml` | Keycloak 栈（Keycloak 26.8.1 + PostgreSQL 17），E10 地址/应用标识/密钥是参数 |
| `aws/deploy.sh` | 部署/更新 Keycloak 栈并自动配置 Keycloak；部署前核对 E10 服务发现，部署后检查 Keycloak 能否访问 E10 |
| `aws/info.sh [--secrets]` | 打印 Quick / IAM Identity Center / E10 要填的值 |
| `aws/register-idc-sp.sh` | 把 IAM Identity Center 的 SP 元数据登记到 Keycloak，并保存到 SSM（实例重建后自动重新登记；`--no-persist` 不保存）；`--reconfigure` 重新应用配置 |
| `aws/admin-tunnel.sh` | SSM 端口转发打开 Keycloak 管理控制台 |
| `aws/destroy.sh` | 删除 Keycloak 栈（可选删除代码桶） |
| `aws/common.sh` | 脚本共用的变量和函数 |
| `aws/KEYCLOAK-DEPLOY.md`、`aws/QUICK-SETUP.md` | 部署和对接文档 |
| `setup-keycloak.py` | 用 Admin REST API 配置 Keycloak（在 Keycloak 实例上由 `/opt/kc/configure.sh` 调用） |
| `../e10-oidc-pkce-test.py` | OIDC / PKCE 测试脚本（验证 E10 → Keycloak；联调测试 B 也用它） |

**`mock/`：只在测试时用（模拟 E10 和自动化验证）**

| 路径 | 内容 |
|---|---|
| `mock/deploy-mock.sh` | 部署模拟 E10，再调用 `aws/deploy.sh` 让 Keycloak 对接它，并替 E10 管理员登记回调地址 |
| `mock/info-mock.sh [--secrets]` | 模拟 E10 的信息和测试密码 |
| `mock/verify.sh` | 端到端验证（Desktop、Web SAML、负面用例、公网安全），要用模拟 E10 的测试账号 |
| `mock/destroy-mock.sh` | 删除模拟 E10 栈 |
| `mock/mock-e10.yaml` | 模拟 E10 栈（测试人员邮箱由参数指定，须与 Quick 用户邮箱一致） |
| `mock/mock-e10/` | 模拟 E10 统一认证中心 OIDC（`server.js` 按 E10 文档实现，顶部注释列出依据和行为开关）及数据模板 |
| `mock/fixtures/iam-identity-center-sp-metadata.xml` | 模拟的 IAM Identity Center SP 元数据（`verify.sh` 临时登记、测完删除） |
| `mock/tests/` | `verify.sh` 用到的无头浏览器脚本（Playwright）；运行结果写到 `mock/tests/out/` |

## 4. 在本机运行 `mock/verify.sh` 的前提

```bash
(cd mock/tests && npm install && npx playwright install chromium)    # 首次
# 这台电脑缺系统字体和部分 Chromium 依赖库，需要这两个变量（装好 Chromium 依赖的电脑可以省略）
export LD_LIBRARY_PATH=/tmp/pwlibs/root/usr/lib64 FONTCONFIG_FILE=/tmp/pwlibs/root/etc/fonts/fonts.conf
mock/verify.sh
```
