# E10 直接作为 IdP 对接 Amazon Quick：联调测试方案（40 分钟）

## 要回答的问题

客户的 E10 能不能**不经过 Keycloak**，直接作为身份提供商（IdP）对接 Quick？

| 测试 | 验证什么 | 会上用时 |
|---|---|---|
| **测试 A：Web** | E10 通过 SAML 登录 IAM Identity Center（Quick Web 走这条路） | 15 分钟 |
| **测试 B：Desktop** | E10 的 OIDC 能否满足 Quick Desktop 的要求（公共客户端 + PKCE、ID token 含 email） | 15 分钟 |

已知前提：客户 E10 是**公网 http + 20600 端口**。Quick Desktop 要求 IdP 的地址是 HTTPS，所以**现状下 Desktop 一定不能直连 E10**。测试 B 要回答的是：如果客户以后给 E10 加上 HTTPS，Desktop 能不能直连。

**为了 40 分钟做完，E10 和 AWS 的配置都在会前完成**，会上只登录测试、记录结果。

---

## 一、会前：客户做什么（提前 1～2 天，约 20 分钟）

> 这一节可以直接发给客户。入口：E10 **后台管理中心 → 集成中心 → 统一认证中心**。

### 1. 先确认三件事（任何一项不满足，本次联调取消）

- [ ] E10 是**私有化部署**（统一认证中心不支持 eteams 云端）
- [ ] 已购买 **统一认证中心** license（和"统一认证-集成登录"不是同一个）
- [ ] 基线版本 ≥ **10.0.2407.01**（SAML 需要这个版本；OIDC 需要 ≥ 10.0.2309.01）

### 2. 准备一个测试账号

- 新建或选一个 E10 人员，**基本信息里填好电子邮箱**。
- 把这个邮箱告诉我方。密码在会上提供，会后修改。

### 3. 配置 SAML（测试 A 用）

我方会先发给你一个文件 `idc-sp-metadata.xml`（IAM Identity Center 的 SP 元数据）。

1. **认证协议管理 → SAML 认证 → 启用**。证书类型保持默认"自签"。
2. 点 **下载 IDP 元数据文件**，把文件发给我方。
3. **认证应用管理 → 新建 → SAML**：

   | 配置项 | 填写 |
   |---|---|
   | 应用名称 | `AWS-Quick-测试` |
   | SP 元数据附件 | 上传我方发的 `idc-sp-metadata.xml`（SP EntityId 会自动带出；没带出就照文件里的 `entityID` 填） |
   | 启用断言签名 | **开启**（默认就是开启） |
   | 启用响应签名 | 开启 |
   | 账号映射 | **电子邮箱** |
   | 共享范围 | 加入测试账号 |

### 4. 配置 OIDC（测试 B 用）

1. **认证协议管理 → OIDC 认证 → 启用**。服务发现地址是 `http://<E10地址>:20600/papi/sso/oidc/.well-known/openid-configuration`，在浏览器里打开能看到 JSON 即可。
2. **认证应用管理 → 新建 → OIDC**：

   | 配置项 | 填写 |
   |---|---|
   | 应用名称 | `Quick-Desktop-测试` |
   | 业务系统 URL 地址 | `http://localhost:18080` |
   | 账号映射 | **电子邮箱** |
   | Scope 配置 | 新建 Claim：人员属性选"电子邮箱"，Claim 名填 `email`；再新建 scope `email`，引用这个 Claim |
   | 共享范围 | 加入测试账号 |

3. 把这个应用的 **应用标识** 和 **应用密钥** 发给我方。

### 5. 发给我方的东西（汇总）

| 内容 | 来自 |
|---|---|
| E10 的 IDP 元数据文件 | 第 3 步 |
| OIDC 应用的应用标识、应用密钥 | 第 4 步 |
| 测试账号的邮箱 | 第 2 步 |

---

## 二、会前：我方做什么（约 30 分钟）

用的是**单独的测试 AWS 账号**里的 IAM Identity Center。切换身份源会影响这个实例的所有用户，不要用生产账号或有人在用的实例。

1. **发 SP 元数据给客户**：IAM Identity Center → Settings → Identity source → Actions → **Change identity source** → External identity provider → 下载 **Service provider metadata**，发给客户。页面先不提交。
2. **收到客户的 IDP 元数据后，完成切换**：回到这个页面，上传 E10 的 IDP 元数据 → Next → 输入 `ACCEPT` → 完成。**Automatic provisioning（SCIM）不开。**
3. **建测试用户**：IAM Identity Center → Users → Add user，**Username 和 Email 都填测试账号的 E10 邮箱**，必须逐字一致，包括大小写。
4. 记下 **AWS access portal URL**（Settings 页面里）。
5. 本机准备：Python 3、`e10-oidc-pkce-test.py`；Chrome 装好 **SAML-tracer** 扩展。在终端里先设好变量：
   ```bash
   export E10=http://<E10地址>:20600
   export DISC=$E10/papi/sso/oidc/.well-known/openid-configuration
   export CID='<OIDC 应用标识>'
   export SECRET='<OIDC 应用密钥>'
   export EMAIL='<测试账号邮箱>'
   ```

---

## 三、会上 40 分钟

| 时间 | 做什么 | 谁 |
|---|---|---|
| 0–5 | 对一遍会前清单：客户三项确认、两个应用都已建好、测试账号密码 | 双方 |
| 5–20 | **测试 A：Web** | 我方操作，客户提供密码、按需改 E10 配置 |
| 20–35 | **测试 B：Desktop** | 我方操作，客户提供密码 |
| 35–40 | 填结果表，对齐结论和会后事项 | 双方 |

### 测试 A：Web（E10 SAML → IAM Identity Center）

**操作**
1. Chrome 打开 SAML-tracer，再开一个**无痕窗口**访问 AWS access portal URL。
2. 页面应跳到 E10 登录页。Chrome 可能先提示"连接不安全"，因为 E10 是 http，点继续。
3. 用测试账号登录。

**怎么判断**

| 看到的结果 | 结论 | 当场怎么处理 |
|---|---|---|
| 进入 AWS access portal（页面上没有应用也算） | **✅ 通过：E10 可以直接作为 Quick Web 的 IdP** | 进入测试 B |
| 没有跳到 E10，或 E10 直接报错 | ❌ E10 不接受 IAM Identity Center 的登录请求 | 截图 E10 报错，交泛微。不在会上排查，进入测试 B |
| E10 提示"不在适用对象范围内" / "未维护电子邮箱" | 配置问题 | 客户改共享范围或邮箱，重试 |
| 登录 E10 后回到 AWS，显示错误页 | ❌ AWS 不接受 E10 返回的断言 | 按下面 3 步收集信息，**只做一次修正尝试** |

**AWS 报错时（限 10 分钟）**
1. 在 SAML-tracer 里找到发往 `…signin.aws.amazon.com/platform/saml/acs/…` 的 POST 请求，点 SAML 标签页，看下表 3 项：

   | 检查项 | 正确的样子 | 不对时 |
   |---|---|---|
   | `<saml2:NameID>` 的值 | 等于测试账号邮箱，并且和 IAM Identity Center 的 Username 一致 | 客户把 SAML 应用的账号映射改成电子邮箱 / 我方改 Username，重试 |
   | NameID 的 `Format` | `urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress` | E10 文档里的示例是 `X509SubjectName`。E10 后台如果能改就改，不能改就记下来交泛微，**这是最可能的失败原因** |
   | 有没有 `<ds:Signature>`，有没有 `EncryptedAssertion` | 有签名、没有加密 | 客户开启断言签名、关闭加密，重试 |

2. 导出这次的 SAML 内容（SAML-tracer → Export），会后发给泛微。
3. 会后在 CloudTrail 里查 Event name = `ExternalIdPDirectoryLogin`，看 `errorMessage`（事件会延迟几分钟出现）。

### 测试 B：Desktop（E10 OIDC）

**操作**：在我方电脑上依次运行。每次会自动打开浏览器到 E10 登录页，客户提供密码登录，登录后看终端。

```bash
# 测试 B1：模拟 Quick Desktop（不带密钥，用 PKCE）
python3 e10-oidc-pkce-test.py --base $E10 --client-id $CID --discovery "$DISC" --expect-email $EMAIL

# 测试 B2：带密钥（B1 拿不到 token 时才跑，用来确认应用本身配置没问题）
python3 e10-oidc-pkce-test.py --base $E10 --client-id $CID --discovery "$DISC" --expect-email $EMAIL --client-secret "$SECRET"
```

**看哪几行**：脚本最后的 `== 结果 ==` 列表里，下面两项**必然显示"不通过"或"警告"，不用管**：
- "端点均为 HTTPS"：E10 是 http，这是已知情况
- "token 响应包含 token_type"

**怎么判断**

| B1 的结果 | B2 的结果 | 结论 |
|---|---|---|
| 终端显示"不带 client_secret 拿不到 id_token" | 拿到了 id_token | **❌ E10 不支持公共客户端。即使加了 HTTPS，Desktop 也不能直连**（除非泛微支持） |
| 终端显示"不带 client_secret 拿不到 id_token" | 也拿不到 | 应用配置有问题（回调地址、共享范围、Scope）。客户检查后重跑一次；还不行就记录报错，交泛微 |
| 拿到了 id_token，结果里除上面两项外**全部通过** | 不用跑 | **✅ E10 加上 HTTPS 后，Desktop 可以直连**。补跑一次加 `--wrong-verifier` 的命令，结果应提示"错误的 code_verifier 被拒绝" |
| 拿到了 id_token，但"包含 email claim"或"email 与 Quick 用户邮箱完全一致"不通过 | 不用跑 | 客户检查 OIDC 应用的 Scope 配置（email），重跑。还不行就交泛微 |
| 拿到了 id_token，但"ID token 签名能用 JWKS 公钥验证"不通过 | 不用跑 | ❌ 交泛微排查证书 |
| 登录后浏览器停在 E10 提示页，终端没有输出 | — | 截图提示内容，按 Ctrl+C 结束。常见原因："回调地址不在业务系统 URL 地址范围内"，即业务系统 URL 没填 `http://localhost:18080` |

两次的终端输出都**整段保存**，会后要用。

---

## 四、结果和结论

### 结果记录（会上填）

| 项目 | 结果 | 备注 |
|---|---|---|
| E10 版本 / license / 私有化 | | |
| A：跳到 E10 登录页 | 是 / 否 | |
| A：登录后进入 access portal | 是 / 否 | 否：报错内容 |
| A：NameID 的值 / Format | | |
| B1：不带密钥拿到 id_token | 是 / 否 | |
| B2：带密钥拿到 id_token | 是 / 否 / 未跑 | |
| id_token 有 email、与 Quick 邮箱一致 | 是 / 否 | |
| id_token 验签 | 通过 / 不通过 | |

### 结论怎么下

**Web（测试 A）**

| 测试 A | 结论 |
|---|---|
| 通过 | Quick Web 可以直接用 E10 作为 IdP（经 IAM Identity Center） |
| 失败，且 NameID Format 是 `X509SubjectName` | 需要泛微把 NameID Format 改成 emailAddress。泛微改不了，Web 走 Keycloak 桥接 |
| 失败，其他原因 | 把 SAML 内容和 CloudTrail 报错交泛微；泛微解决不了，Web 走 Keycloak 桥接 |

**Desktop（测试 B）**

| 测试 B | 结论 |
|---|---|
| B1 通过（除已知两项外） | 现状（http）不能直连。**客户给 E10 加 HTTPS 后可以直连** |
| B1 失败、B2 通过 | **Desktop 不能直连 E10**，必须走 Keycloak 桥接（或泛微支持公共客户端 + PKCE） |
| B1、B2 都失败 | 先解决应用配置问题再测；在那之前按"不能直连"规划 |

**总体方案**

| Web | Desktop | 建议 |
|---|---|---|
| 可直连 | 不能直连 | Web 直连 E10，Desktop 走 Keycloak 桥接。也可以两者都走 Keycloak，E10 上只维护一个 OIDC 应用 |
| 可直连 | 加 HTTPS 后可直连 | 客户给 E10 加 HTTPS，两者都直连 E10，不需要 Keycloak |
| 不能直连 | 任意 | 两者都走 Keycloak 桥接 |

测试 B 能拿到 id_token 的话，也顺带说明 Keycloak 桥接可以对接这套 E10：Keycloak 用的就是"带密钥换 token"的方式，和 B2 一样。

---

## 五、会后

**客户**
- 修改测试账号密码。
- 两个测试应用先保留，结论定了再决定删除还是转为正式使用。

**我方**
- 测试 A 失败的话：查 CloudTrail，连同 SAML 内容整理给泛微。
- 发结论给客户：结果表 + 结论 + 下一步。
- 测试用的 IAM Identity Center 实例：结论是 Web 走 Keycloak 的话，之后把它的身份源改到 Keycloak 继续用。
