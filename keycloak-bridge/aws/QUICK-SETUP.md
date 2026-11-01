# 在 Amazon Quick 里对接 Keycloak 桥接（云上实测指南）

本文说明 Keycloak 桥接部署好以后，在 Amazon Quick 里怎么配置。Keycloak 怎么部署、怎么对接 E10，见 [KEYCLOAK-DEPLOY.md](KEYCLOAK-DEPLOY.md)。

下面的地址是**测试环境**（模拟 E10 → Keycloak，用 `mock/deploy-mock.sh` 部署），重新部署后会变，以 `mock/info-mock.sh` 的输出为准。到客户那里时，Keycloak 的地址以 `aws/info.sh` 为准，E10 登录页是客户的真实 E10：

| 组件 | 地址 |
|---|---|
| 模拟 E10 | http://13.112.194.233:20600（与客户一致：公网 http + 20600 端口，固定弹性 IP） |
| Keycloak | https://dovqha5kkdnl5.cloudfront.net |
| 部署区域 / 账号 | ap-northeast-1 / 271547278201（CloudFront 是全球服务，与 Quick 所在区域无关） |

测试人员：模拟 E10 登录名 `quicktest`，邮箱 `mingzhang@nwcdcloud.cn`（= Quick 里 `zhangming-nwcd` 的邮箱，ADMIN_PRO），密码用 `mock/info-mock.sh --secrets` 查看。

---

## 0. 先看清这个测试账号的情况（重要）

我只读检查了账号 271547278201，有两点决定了能测什么：

| 项目 | 现状 | 影响 |
|---|---|---|
| Quick 账户 | Enterprise，身份区域 **us-east-1**，认证方式 **IDENTITY_POOL**（IAM 用户 / Quick 原生用户），不是 IAM Identity Center | **Desktop 可以直接测**（Desktop 支持所有身份类型）。**Web 走 IAM Identity Center 的路径在这个 Quick 账户上测不了**：认证方式创建后不能改，要改只能删除 Quick 账户重新订阅 |
| IAM Identity Center | us-east-1 有一个账号实例，2 个用户，挂着 2 个 Kiro 应用 | **不要改它的身份源**。改成 Keycloak 后，现有用户（包括 Kiro 登录）都会受影响 |

所以下面分两部分：
- **第 1 部分：Quick Desktop**，在这个账号上完整实测。
- **第 2 部分：Quick Web（IAM Identity Center）**，需要一个"Quick 用 IAM Identity Center 订阅"的账号（另一个测试账号，或客户环境）。步骤和脚本都已就绪。

---

## 1. Quick Desktop（本账号实测）

链路：Quick Desktop →（OIDC 公共客户端 + PKCE）→ Keycloak →（OIDC + client_secret）→ 模拟 E10 登录 → 回到 Desktop。
Quick 用 ID token 里的 email（`mingzhang@nwcdcloud.cn`）匹配账户里的用户。

### 1.1 准备

1. 确认对接信息：
   ```bash
   cd ~/e10sso/keycloak-bridge
   aws/info.sh                  # Keycloak 对接信息
   mock/info-mock.sh --secrets  # 测试环境：模拟 E10 的测试人员密码
   ```
2. 用**系统默认浏览器**登录 Quick Web（us-east-1），用你平时的方式（`zhangming-nwcd`）。
   Desktop 第一次登录时，会先在浏览器里检查有没有 Quick Web 会话，用它来找到账户配置的 IdP；没有会话就会先让你登录 Quick。

### 1.2 添加 Extension access（Quick 管理控制台）

1. Quick 控制台右上角头像 → **Manage account** → 左侧 **Permissions** → **Extension access** → **Add extension access**。
2. **Select Service** 选 **Amazon Quick (Desktop application for Quick)** → **Next**。
3. 按下表填写，然后 **Add**：

   | 字段 | 值 |
   |---|---|
   | Name | `QuickDesktop-keycloak`（只能字母、数字、连字符） |
   | Description | E10 via Keycloak（可选） |
   | Issuer URL | `https://dovqha5kkdnl5.cloudfront.net/realms/corp` |
   | Authorization Endpoint | `https://dovqha5kkdnl5.cloudfront.net/realms/corp/protocol/openid-connect/auth` |
   | Token Endpoint | `https://dovqha5kkdnl5.cloudfront.net/realms/corp/protocol/openid-connect/token` |
   | JWKS URI | `https://dovqha5kkdnl5.cloudfront.net/realms/corp/protocol/openid-connect/certs` |
   | Client ID | `amazon-quick-desktop` |

   - **建好后不能修改**，填错只能删除重建。Issuer URL 末尾**没有** `/`。
   - 如果控制台在添加第一个 Extension 前要求先配置 TTI（Trusted Token Issuer），那是旧版控制台的行为（见《Quick SSO集成FAQ》），Desktop 本身不需要 TTI。

### 1.3 创建 Extension

1. Quick 控制台左侧 **Extensions**（找不到就在 **More** 里）→ **Add extension**。
2. 选上一步建的 **Desktop application for Quick** 那条 extension access → **Next** → **Create**。

只做 1.2 不做 1.3，Desktop 会报 *"Enterprise sign-in for Quick Desktop has not been configured for this account."*

### 1.4 下载并登录 Desktop

1. **Extensions** → 选刚建的 Quick Desktop extension → 右侧 **⋯** → **Download for Windows** 或 **Download for Mac**，安装。
2. 打开 Quick Desktop → **Continue with SSO** → 区域选 **US East (N. Virginia)**（或 Dynamic）。
3. 浏览器自动打开，依次经过 Quick → Keycloak → **模拟 E10 登录页**（标题"泛微 E10（模拟）"，地址是 `http://13.112.194.233:20600/login…`）。
   - Chrome 154 起（2026 年 10 月）默认开启"始终使用安全连接"，第一次打开 http 的公网站点会先显示"连接不安全"提示页，点 **继续访问网站** 即可（两周内不再提示）。客户的真实 E10 也会遇到，见第 3 节。
4. 输入 `quicktest` 和 `mock/info-mock.sh --secrets` 显示的人员密码 → 登录（客户环境用 E10 的真实账号）。
5. 浏览器提示完成后回到 Desktop，进入首页即成功。Desktop 里显示的用户应为 `mingzhang@nwcdcloud.cn`。

### 1.5 建议顺带验证的负面场景

| 操作 | 预期 |
|---|---|
| 退出 Desktop，用 `lisi` 登录 | 停在模拟 E10 提示页"登录用户不在认证应用注册的适用对象范围内"（E10 共享范围生效） |
| 用 `zhangsan` 登录 | E10、Keycloak 都通过，但 Quick 里没有 `zhangsan@corp.example` 这个用户 → Desktop 报 User not found（证明 Quick 按 email 匹配） |

### 1.6 排错

| 现象 | 原因 / 处理 |
|---|---|
| 浏览器停在 Quick 登录页 | 默认浏览器里没有 Quick Web 会话，先登录 Quick Web 再点 Continue with SSO |
| Enterprise sign-in ... has not been configured | 1.3 没做 |
| Invalid issuer / token validation error | Extension access 的 Issuer URL 与上表不完全一致（删除重建） |
| User not found | ID token 的 email 与 Quick 用户邮箱不一致。核对 E10 人员邮箱（测试环境见 `mock/info-mock.sh`）与 Quick 用户邮箱 |
| 停在"泛微 E10（模拟）"提示页 | 按提示处理（共享范围、未维护邮箱、回调地址不在业务系统 URL 范围内） |
| Keycloak 报 "We are sorry..." | 看 Keycloak 日志（下面的命令），对照 [KEYCLOAK-DEPLOY.md](KEYCLOAK-DEPLOY.md) 第 9 节 |

查看日志：
```bash
source aws/common.sh
run_on "$(out e10sso-keycloak InstanceId)" logs "docker logs --since 30m keycloak 2>&1 | grep -E 'WARN|ERROR' | tail -20"
run_on "$(out e10sso-mock-e10 InstanceId)" logs "docker logs --since 30m mock-e10 2>&1 | tail -30"
```
Keycloak 管理控制台（不对公网开放）：`aws/admin-tunnel.sh`，再打开 http://localhost:9080/admin（admin / `aws/info.sh --secrets`）。

---

## 2. Quick Web（经 IAM Identity Center）

链路：浏览器 → AWS access portal / Quick → IAM Identity Center →（SAML）→ Keycloak →（OIDC）→ E10 登录 → 回到 Quick。
Keycloak 输出的 SAML 断言已在测试环境验证：NameID 为 emailAddress 格式、断言和响应签名可验、未加密（`mock/verify.sh` 第 4 项）。

**前提**：Quick 账户用 IAM Identity Center 订阅；IAM Identity Center 实例可以切换身份源（切换会影响该实例所有用户）。**本账号不满足**（见第 0 节）。

### 2.1 IAM Identity Center：切换身份源

1. IAM Identity Center 控制台 → **Settings** → **Identity source** → **Actions** → **Change identity source** → **External identity provider** → **Next**。
2. 在 **Service provider metadata** 处点 **Download metadata file**，保存为 `idc-sp.xml`。**页面先别关。**
3. 把 SP 元数据登记到 Keycloak（创建 SAML 客户端，NameID=email、签名、不加密）：
   ```bash
   aws/register-idc-sp.sh idc-sp.xml
   ```
   如果 Keycloak 和 IAM Identity Center 不在同一个账号，先在 Keycloak 所在账号的凭证下执行这条命令。
   SP 元数据会同时保存到 SSM 参数，Keycloak 实例重建后自动重新登记；签名证书也已持久化，所以第 4 步的 IdP 元数据只需上传一次。
4. 下载 Keycloak 的 IdP 元数据：
   ```bash
   curl -o keycloak-idp.xml https://dovqha5kkdnl5.cloudfront.net/realms/corp/protocol/saml/descriptor
   ```
5. 回到第 1 步的页面，**Identity provider metadata** → **IdP SAML metadata** 上传 `keycloak-idp.xml` → **Next** → 输入 `ACCEPT` → **Change identity source**。
6. **Automatic provisioning（SCIM）保持关闭**（E10 和 Keycloak 都不推送用户）。

### 2.2 创建用户和组

IAM Identity Center → **Users** → **Add user**：**Username 必须与 E10 邮箱逐字一致**（例如 `mingzhang@nwcdcloud.cn`），Email 填同一个值。再建组（如 `QuickAdmins`、`QuickReaders`）并加入用户。
批量创建可以用 CLI：
```bash
aws identitystore create-user --identity-store-id d-xxxxxxxxxx --user-name mingzhang@nwcdcloud.cn \
  --display-name "Quick 测试用户" --name GivenName=测试,FamilyName=用户 \
  --emails Value=mingzhang@nwcdcloud.cn,Type=work,Primary=true
```

### 2.3 订阅 Quick 并映射角色

用 IAM Identity Center 方式订阅 Quick（身份区域选 Desktop 支持的区域），在订阅页把组映射到 Admin Pro / Author Pro / Reader Pro 等角色。

### 2.4 测试

1. 无痕窗口打开 AWS access portal URL（IAM Identity Center → Settings 里的 *AWS access portal URL*）→ 应跳到 Keycloak → 模拟 E10 登录页。
2. 用 `quicktest` 登录 → 回到 access portal → 点 Amazon Quick 进入。
3. 同一浏览器再打开 Quick Desktop 的 Continue with SSO：E10 / Keycloak 会话还在，**不用再输密码**（Web 和 Desktop 都终结在 Keycloak）。

排错：IAM Identity Center 所在区域的 CloudTrail → Event history → Event name = `ExternalIdPDirectoryLogin`。

---

## 3. 换成客户的真实 E10

完整步骤（E10 建应用 → 部署 → 回填回调地址 → 验证）、参数说明和排错见 [KEYCLOAK-DEPLOY.md](KEYCLOAK-DEPLOY.md)。下面是概要。

客户 E10 是**公网 http + 20600 端口**。到客户那里只部署 Keycloak（不部署模拟 E10）：

```bash
E10_BASE_URL=http://<客户E10地址>:20600 E10_CLIENT_ID=<E10应用标识> \
PREFIX=e10sso-prod aws/deploy.sh     # 会提示输入 E10 应用密钥；服务发现和 issuer 自动获取
```
Keycloak 一侧的配置是自动完成的；部署完成后要把输出的业务系统 URL 交给客户，填到 E10 认证应用里（E10 侧的配置见 KEYCLOAK-DEPLOY.md 3.1、3.3）。
如果联调测试 B 测出 E10 的 id_token 没有 email，加 `E10_SCOPES="openid profile" EMAIL_FROM=sub`；如果 E10 回传 nonce，可加 `NONCE_MODE=send`。

E10 是 http 带来的影响（模拟环境已按这个情况验证）：

| 影响 | 说明 / 处理 |
|---|---|
| **Quick Desktop 不能直连 E10** | Quick 要求 OIDC 端点用 HTTPS（OIDC 规范也要求 issuer 用 https）。即使 E10 支持公共客户端也不行，**Desktop 必须走桥接**。测试脚本对公网 http 端点直接判"不通过" |
| Keycloak 默认拒绝 http 的身份提供商 | 报 `requires secure connections`。`setup-keycloak.py` 检测到 E10 是公网 http 时，自动把 corp realm 的 SSL 要求设为 none。用户仍只能经 CloudFront 的 HTTPS 访问 Keycloak（源站只放行 CloudFront），影响只在 Keycloak↔E10 这一段 |
| 明文传输 | E10 登录密码、授权码、Keycloak→E10 的 client_secret 都以明文经过公网。建议客户给 E10 加 HTTPS（例如前面放一个带证书的反向代理）；加了之后把 `E10_BASE_URL` 改成 https 重新部署即可 |
| Chrome 154+ 提示"连接不安全" | 用户第一次打开 E10 的 http 登录页会先看到提示页，点继续即可（两周内不再提示）。企业可用 Chrome 策略把 E10 地址加入 HTTP 白名单（`HttpAllowlist`），需在客户环境确认 |
| E10 端口若按来源 IP 限制 | 放行 Keycloak 的出口 IP（`aws/info.sh` 里"访问 E10 的出口 IP"）。这是弹性 IP，实例停机、重建都不变，删除栈才释放 |
| Web 端直连（联调测试 A） | E10 的 SAML 登录地址也是 http，IAM Identity Center 是否接受 http 的 IdP 登录地址需要联调测试 A 实测；走桥接不受影响（IAM Identity Center 只对接 Keycloak 的 https） |

---

## 4. 费用与清理

| 资源 | 规格 | 约每月（东京） |
|---|---|---|
| Keycloak 实例 | t4g.medium + 20 GB gp3 | 约 33 美元 |
| 模拟 E10 实例（仅测试环境） | t4g.micro + 16 GB gp3（http 直接对公网，无 CloudFront） | 约 9.5 美元 |
| 公网 IPv4 | Keycloak 的弹性 IP 1 个；测试环境再加模拟 E10 的弹性 IP 1 个 | 每个约 3.7 美元 |
| Secrets Manager / CloudFront / S3 | 2～3 个密钥，测试流量 | 约 1.5 美元 |

客户环境（只有 Keycloak）约 38 美元/月；测试环境（模拟 E10 + Keycloak）约 50 美元/月，按小时计费。测完删除：
```bash
mock/destroy-mock.sh               # 测试环境：删除模拟 E10
aws/destroy.sh --purge-bucket      # 删除 Keycloak（和代码桶）
```
**安全提醒**：模拟 E10 的测试人员密码可以以 `mingzhang@nwcdcloud.cn`（ADMIN_PRO）身份登录 Quick Desktop。密码是随机生成的，只存在 Secrets Manager 里；但模拟 E10 和客户一样是 http，登录时密码以明文经过公网。测试结束后应删除环境，并在 Quick 里删除 Extension access。

## 5. 这是 PoC 规格，上生产前要改的

| 项目 | 现在 | 生产建议 |
|---|---|---|
| 可用性 | 单台 EC2，Keycloak 和 PostgreSQL 同机，无备份 | ECS/EKS 至少 2 个 Keycloak 节点 + RDS PostgreSQL（多可用区、自动备份） |
| 域名 | CloudFront 默认域名 | 自有域名 + ACM 证书。换域名会改变 Issuer，Quick 的 Extension access 和 IAM Identity Center 的 IdP 元数据都要重配 |
| CloudFront → Keycloak 源站 | HTTP，安全组只放行 CloudFront 回源 IP | ALB + HTTPS 回源，或 CloudFront VPC origin（源站放私有子网） |
| Keycloak ↔ E10 | E10 是 http，corp realm 的 SSL 要求为 none | 客户 E10 启用 HTTPS 后重新部署，SSL 要求自动恢复为 external |
| Keycloak 实例公网地址 | 弹性 IP，停机再启动、实例重建都不变 | 改成 ALB 或 CloudFront VPC origin 后可不再需要公网 IP |
| 实例重建 | 签名密钥、SAML 客户端自动恢复；数据库清空（用户下次登录自动重建，会话失效） | 用 RDS 保存数据库 |
| 版本 | Keycloak 26.8.1 | 跟随 Keycloak 版本升级（小版本支持周期很短） |
