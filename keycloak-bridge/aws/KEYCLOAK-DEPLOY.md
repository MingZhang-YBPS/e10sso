# Keycloak 桥接：CloudFormation 部署与对接 E10

本文说明 `aws/keycloak-bridge.yaml` 这个 CloudFormation 栈怎么部署、怎么让它桥接客户的 E10，以及部署后怎么改、怎么排错。
Quick（Desktop / Web）那一侧怎么配，见 [QUICK-SETUP.md](QUICK-SETUP.md)。
到客户那里只用 `aws/` 目录：**只部署 Keycloak，对接客户的 E10**。`mock/` 目录是模拟 E10 和测试工具，客户环境用不到。

**哪些是自动的，哪些要手工做**

| 步骤 | 谁来做 | 方式 |
|---|---|---|
| 在 E10 建 OIDC 认证应用（账号映射、Scope、共享范围），交出应用标识和密钥 | 客户的 E10 管理员 | 手工，3.1 |
| 部署 Keycloak，并在 Keycloak 里配好 E10 身份提供商、映射、登录流程、Desktop 客户端 | `aws/deploy.sh` | **自动**，3.2 |
| 部署前从服务发现取 issuer、核对 E10 接口地址；部署后从 Keycloak 实例检查能否访问 E10 | `aws/deploy.sh` | **自动**，3.2 |
| 把 Keycloak 回调地址填进 E10 认证应用的"业务系统 URL 地址"；需要时放行 Keycloak 出口 IP | 客户的 E10 管理员 | 手工，3.3（回调地址部署后才知道） |
| 验证 E10 → Keycloak 这一段 | 我方 | 运行测试脚本，3.4 |

```
用户浏览器 / Quick Desktop
        │ HTTPS
        ▼
CloudFront（xxxx.cloudfront.net，公网 HTTPS 证书；/admin 和 master realm 一律 403）
        │ HTTP 回源，安全组只放行 CloudFront 的回源 IP
        ▼
EC2（t4g，Amazon Linux 2023，Docker）
  ├─ keycloak（26.8.1，realm corp）  ── 0.0.0.0:8080 给 CloudFront；127.0.0.1:9080 管理控制台
  └─ kc-db（PostgreSQL 17，数据在实例磁盘 /opt/kc/pgdata）
        │ OIDC 授权码 + client_secret（服务端调用 E10 的 token、JWKS 接口）
        ▼
客户 E10 统一认证中心（http://<地址>:20600）
```

---

## 1. 栈里有什么

| 资源 | 说明 |
|---|---|
| VPC、公有子网、互联网网关 | 独立网络，默认 `10.89.0.0/24`，不影响账号里已有的 VPC |
| 安全组 | 只放行 CloudFront 回源 IP（托管前缀列表 `com.amazonaws.global.cloudfront.origin-facing`）访问 8080 |
| 弹性 IP + 网卡（ENI） | 先于实例创建，实例挂这块网卡。实例停机再启动、甚至重建，公网 IP 和公网 DNS 都不变（CloudFront 回源地址、E10 白名单都不用改） |
| EC2 实例 + IAM 角色 | 角色只有：SSM 托管、读代码桶里的 `setup-keycloak.py`、读写本栈的两个密钥、读本栈的 SSM 参数 |
| CloudFront 分发 + CloudFront Function | 提供 HTTPS 和公网域名；关闭缓存；拦截 `/admin*` 和 `/realms/master*`；回源时写入 `Forwarded: for=<用户IP>;proto=https`（CloudFront 会删掉 `X-Forwarded-Proto`，所以 Keycloak 改用标准的 `Forwarded` 头判断 HTTPS） |
| Secrets Manager × 2 | `KcSecret`：Keycloak 管理员密码、数据库密码、corp realm 的 RS256 签名密钥和证书（都在实例首次启动时生成）；`E10Secret`：E10 应用密钥（来自参数） |
| SSM 参数 | 栈创建：`/e10sso/<栈名>/public-host`（CloudFront 域名）、`/e10sso/<栈名>/e10-config`（E10 对接参数：地址、issuer、应用标识、scope 等）。`register-idc-sp.sh` 创建：`/e10sso/<栈名>/idc-sp-metadata`（IAM Identity Center 的 SP 元数据，`destroy.sh` 会一并删除） |
| WaitCondition | 实例装好 Keycloak 并完成配置后才算栈创建成功 |

实例启动时（UserData）会：装 Docker → 拉镜像 → 生成密码 → 启动 PostgreSQL 和 Keycloak → 运行 `/opt/kc/configure.sh`，它调用 `setup-keycloak.py` 通过管理接口把 Keycloak 配好。

`setup-keycloak.py` 配出来的 Keycloak：

| 位置 | 配置 |
|---|---|
| realm `corp` | 姓、名非必填；E10 是公网 http 时 SSL 要求设为 none（否则 Keycloak 拒绝 http 的身份提供商） |
| 身份提供商 `e10`（OIDC） | 机密客户端，`client_secret_post`；不用 PKCE；不调用户信息接口（E10 的格式不标准）；默认不发 nonce；校验签名（E10 的 JWKS）；同步模式 FORCE；信任 email |
| `e10` 的映射 | username ← email（或 sub），email ← email（或 sub），firstName ← E10 的姓名 |
| 认证流程 | 首次登录不弹补填资料页；浏览器登录直接跳转到 E10 |
| 客户端 `amazon-quick-desktop` | 公共客户端 + PKCE S256，回调 `http://localhost:18080`（Quick Desktop） |
| realm 签名密钥 | 导入 `KcSecret` 里保存的密钥（组件名 `persisted-rsa-sig`），删除 Keycloak 自动生成的那把，所以实例重建后证书和 kid 不变 |
| IAM Identity Center 的 SAML 客户端 | 用 `register-idc-sp.sh` 另行登记：NameID=emailAddress、断言和响应签名、不加密。SP 元数据同时存进 SSM，之后每次配置（含实例重建）自动重新登记 |

---

## 2. 准备

**本机**：AWS CLI v2、python3、bash；要用管理控制台的话还要 `session-manager-plugin`。
**权限**：能创建 CloudFormation、EC2、VPC、IAM 角色、CloudFront、Secrets Manager、SSM 参数、S3 桶。
**区域**：任意支持 t4g 的区域都行（CloudFront 是全球的，和 Quick 所在区域无关）。默认取 `aws configure` 的区域，可用 `REGION=...` 指定。

**向客户要的信息**（客户在联调时已提供的、以及联调测试 B 的结果）：

| 信息 | 用途 | 对应部署变量 |
|---|---|---|
| E10 地址，例如 `http://oa.example.com:20600` | Keycloak 调用 E10 接口 | `E10_BASE_URL` |
| OIDC 服务发现里的 `issuer`（E10 的 issuer 就是访问地址：协议 + 域名:端口；一般不用手填，脚本从服务发现自动取） | Keycloak 校验 id_token 的 iss | `E10_ISSUER` |
| E10 认证应用的应用标识、应用密钥 | Keycloak 作为客户端 | `E10_CLIENT_ID`、`E10_CLIENT_SECRET` |
| id_token 里有没有 email（联调测试 B） | 没有就改用 sub | `EMAIL_FROM` |
| 20600 端口是否按来源 IP 限制 | 要放行 Keycloak 出口 IP | 部署后看输出 `OutboundIp` |

---

## 3. 对接客户 E10：完整步骤

### 3.1 客户在 E10 上建认证应用

统一认证中心 → 认证应用管理 → 新建 **OIDC** 应用：

| 配置项 | 值 |
|---|---|
| 业务系统 URL 地址 | 先填一个占位地址（如 `https://example.invalid/`）。Keycloak 的回调地址部署后才知道，3.3 再改 |
| 账号映射 | 电子邮箱 |
| Scope 配置 | 新建 Claim：人员属性"电子邮箱" → Claim 名 `email`；新建 scope `email` 引用它 |
| 共享范围 | 允许登录 Quick 的人员 |

拿到应用标识和应用密钥。

### 3.2 部署 Keycloak 栈

```bash
cd ~/e10sso/keycloak-bridge
E10_BASE_URL='http://oa.example.com:20600' \
E10_CLIENT_ID='<应用标识>' \
PREFIX=e10sso-prod \
aws/deploy.sh
# 运行后会提示输入 E10 应用密钥（不回显，不进命令历史）；也可以事先 export E10_CLIENT_SECRET
```

- `PREFIX` 决定栈名（`<PREFIX>-keycloak`）和代码桶名，和测试环境（默认 `e10sso`）分开。
- 服务发现地址默认是 `{E10_BASE_URL}/papi/sso/oidc/.well-known/openid-configuration`（E10 的固定路径；不同时用 `E10_DISCOVERY_URL` 指定）。脚本会在**部署前**从本机访问它：
  - 自动取出 `issuer`，不用手工填 `E10_ISSUER`；
  - 核对授权、token、JWKS 接口地址是否就是 `E10_BASE_URL` 加 E10 文档里的路径，不一致会提示。
- **部署后**脚本会在 Keycloak 实例上访问 E10 的 JWKS 接口（这才是真正的访问来源），打印能否访问；访问不了会提示放行 Keycloak 出口 IP。
- 可选变量：`E10_ISSUER`（手工指定，优先于服务发现）、`E10_SCOPES`（默认 `openid email profile`）、`EMAIL_FROM`（`email`/`sub`）、`NONCE_MODE`（`disable`/`send`）、`KC_INSTANCE_TYPE`（默认 `t4g.medium`）、`REGION`、`DISABLE_ROLLBACK=1`（失败时保留实例便于排查）。
- 新建大约 10～15 分钟。脚本会自动建私有代码桶、上传 `setup-keycloak.py`、查 CloudFront 前缀列表 ID，最后打印"下一步"和对接信息（也可以随时运行 `PREFIX=e10sso-prod aws/info.sh`）。

### 3.3 回填 E10 的业务系统 URL，放行出口 IP

这一步只能在 E10 后台做，脚本代劳不了。

1. 把输出"下一步"里的业务系统 URL 地址（`E10RedirectUri`，形如 `https://xxxx.cloudfront.net/realms/corp/broker/e10/endpoint`）交给客户，替换 3.1 的占位地址。
2. 如果部署后检查提示访问不了 E10，或者客户按来源 IP 限制 20600 端口，放行输出里的"访问 E10 的出口 IP"。

### 3.4 验证桥接

**自动验证**（模拟 Quick Desktop，经 Keycloak → E10 登录；浏览器里用 E10 测试账号登录）：

```bash
python3 ~/e10sso/e10-oidc-pkce-test.py --base https://xxxx.cloudfront.net --client-id amazon-quick-desktop \
  --discovery https://xxxx.cloudfront.net/realms/corp/.well-known/openid-configuration \
  --expect-email <该测试人员在 Quick 里的邮箱>
```
全部"通过"（没有"不通过"）就说明 E10 → Keycloak 这段通了，ID token 满足 Quick Desktop 的要求。最后打印的"填到 Quick「Extension access」的值"可直接使用。

**手工验证**：浏览器无痕窗口打开 `https://xxxx.cloudfront.net/realms/corp/account`，应自动跳到 E10 登录页，登录后回到 Keycloak 的账户页面，显示的邮箱应为该人员的 E10 邮箱。

### 3.5 对接 Quick

见 [QUICK-SETUP.md](QUICK-SETUP.md)：Desktop 第 1 节；Web（IAM Identity Center）第 2 节，其中 SP 元数据用 `aws/register-idc-sp.sh` 登记到 Keycloak。

---

## 4. 不用脚本，在 CloudFormation 控制台部署

1. 建一个私有 S3 桶，把 `setup-keycloak.py` 上传到 `s3://<桶>/e10sso/keycloak/setup-keycloak.py`（路径前缀对应参数 `ArtifactPrefix`，默认 `e10sso`）。
2. 查 CloudFront 回源前缀列表 ID（每个区域不同）和最新的 AL2023 arm64 AMI：
   ```bash
   aws ec2 describe-managed-prefix-lists --region <区域> \
     --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
     --query 'PrefixLists[0].PrefixListId' --output text
   aws ssm get-parameter --region <区域> --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
     --query Parameter.Value --output text
   ```
3. CloudFormation 控制台 → 创建堆栈 → 上传 `aws/keycloak-bridge.yaml` → 按第 5 节填参数 → 勾选"我确认 AWS CloudFormation 可能创建 IAM 资源" → 创建。
   以后在控制台更新这个栈时，`AmiId` 保持不变，否则实例会被替换（后果见第 7 节）。
4. 创建完成后到"输出"页签取值，然后按 3.3、3.4 继续。

---

## 5. 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `E10BaseUrl` | （必填） | E10 地址，含协议和端口，不带路径。如 `http://oa.example.com:20600` |
| `E10Issuer` | 空 | E10 id_token 的 iss，原样填写；空则用 `E10BaseUrl` 本身（E10 的 issuer 就是访问地址） |
| `E10ClientId` | （必填） | E10 认证应用的应用标识 |
| `E10ClientSecret` | （必填，NoEcho） | E10 认证应用的应用密钥，存入 Secrets Manager |
| `E10Scopes` | `openid email profile` | 向 E10 请求的 scope，必须是 E10 Scope 配置里有的 |
| `EmailFrom` | `email` | 邮箱取自 id_token 的哪个 claim；E10 不出 email 时用 `sub`（账号映射须为电子邮箱） |
| `NonceMode` | `disable` | E10 的 id_token 不回传 nonce 时必须 `disable`；确认回传后可用 `send` |
| `ArtifactBucket` | （必填） | 放 `setup-keycloak.py` 的私有桶 |
| `ArtifactPrefix` | `e10sso` | 桶里的路径前缀 |
| `CloudFrontPrefixListId` | （必填） | 第 4 节第 2 步查到的 ID |
| `InstanceType` | `t4g.medium` | `t4g.small` / `t4g.medium` / `t4g.large`。small 内存偏紧 |
| `KeycloakImage` | `quay.io/keycloak/keycloak:26.8.1` | Keycloak 镜像 |
| `PostgresImage` | `public.ecr.aws/docker/library/postgres:17-alpine` | 数据库镜像 |
| `VpcCidr` | `10.89.0.0/24` | 栈自己的 VPC 网段 |
| `AmiId` | （必填） | Amazon Linux 2023 arm64 的 AMI ID。`deploy.sh` 新建栈时取最新版，更新栈时沿用当前实例的 AMI（换 AMI 会替换实例） |

## 6. 输出

| 输出 | 用途 |
|---|---|
| `KeycloakUrl` | Keycloak 公网地址 |
| `E10RedirectUri` | 填到 E10 认证应用的"业务系统 URL 地址" |
| `DesktopIssuer` / `DesktopAuthorizationEndpoint` / `DesktopTokenEndpoint` / `DesktopJwksUri` / `DesktopClientId` | 填到 Quick 的 Extension access（Desktop） |
| `SamlIdpMetadataUrl` | 下载后上传到 IAM Identity Center（Web） |
| `OutboundIp` | Keycloak 访问 E10 的出口 IP（弹性 IP，白名单用；停机、重建都不变，删除栈才释放） |
| `InstanceId` | SSM 运维用 |
| `KcSecretArn` | Keycloak 管理员密码所在的密钥 |

---

## 7. 部署后修改

**改 E10 对接参数**（地址、issuer、应用标识/密钥、scope、EmailFrom、NonceMode）：用新的变量重新执行 3.2 的命令。
栈更新只改 SSM 参数和 Secrets Manager，**实例不重建**；脚本会接着在实例上重新应用配置（`register-idc-sp.sh --reconfigure`），已登记的 IAM Identity Center SAML 客户端不受影响。
用控制台更新参数的话，更新完要自己执行一次 `PREFIX=<前缀> aws/register-idc-sp.sh --reconfigure`。

**会重建实例的修改**：`InstanceType`、`KeycloakImage`、`PostgresImage`、`AmiId`，以及修改模板里的 UserData。（`deploy.sh` 更新栈时会自动沿用当前 AMI，不会因为出了新 AMI 而重建。）实例重建的后果：

| 会变 | 不会变 |
|---|---|
| Keycloak 数据库清空：realm 由脚本重新创建；之前登录过的用户下次登录时自动重新创建（JIT） | CloudFront 域名（Issuer、各端点、E10 回调地址都不变） |
| 用户已有的 Keycloak 会话失效，要重新登录一次 | 签名密钥和证书（从 `KcSecret` 导入）：IAM Identity Center 的 IdP 元数据不用重新上传 |
| | IAM Identity Center 的 SAML 客户端（从 SSM 参数自动重新登记） |
| | 出口 IP（弹性 IP），E10 白名单不用改 |
| | Keycloak 管理员密码、Quick 的 Extension access |

实例**停机再启动**（不是重建）时数据库还在，什么都不变，Keycloak 约 20 秒后恢复服务。

只有 `register-idc-sp.sh --no-persist` 登记的 SAML 客户端不会保存，重建后会丢失。

## 8. 运维

| 要做的事 | 命令 |
|---|---|
| 查看对接信息 / 密码 | `aws/info.sh`，加 `--secrets` 显示管理员密码 |
| 打开管理控制台 | `aws/admin-tunnel.sh`，然后浏览器打开 http://localhost:9080/admin（账号 admin） |
| 登录实例 | `aws ssm start-session --target <InstanceId>`，再 `sudo docker logs --tail 100 keycloak` |
| 看最近的错误 | `source aws/common.sh; run_on <InstanceId> logs "docker logs --since 30m keycloak 2>&1 \| grep -E 'WARN\|ERROR' \| tail -20"` |
| 看登录事件 | 管理控制台 → corp → Realm settings → Events → 打开 Save events，之后在 Events 页查看 |
| 重新应用配置 | `aws/register-idc-sp.sh --reconfigure` |
| 登记 / 更换 IAM Identity Center 的 SP | `aws/register-idc-sp.sh <SP元数据.xml>`（同时保存到 SSM；临时测试加 `--no-persist` 不保存） |
| 删除 SAML 客户端 | `aws/register-idc-sp.sh --delete <SP entityID>`（删的是已保存的那个时，SSM 参数一并删除） |

以上命令都按 `PREFIX`（默认 `e10sso`）和 `REGION` 找栈；生产栈加 `PREFIX=e10sso-prod`。

## 9. 排错

| 现象 | 原因 / 处理 |
|---|---|
| 部署前检查：接口地址"不一致" | E10 服务发现里的地址和 `E10_BASE_URL` + 文档路径不同（例如服务发现给的是内网地址或别的端口）。Keycloak 按 `E10_BASE_URL` 调用，确认客户给的地址是 Keycloak 能访问的那个 |
| 部署后检查：访问 E10 的 JWKS 失败 | 20600 端口对 AWS 不通：放行脚本打印的出口 IP，或确认 E10 地址、端口 |
| Keycloak 日志：`Non-secure context detected; cookies are not secured` | Keycloak 没识别出用户是经 HTTPS 访问的，登录 cookie 不带 Secure、SameSite=Lax，跨站 POST 登录（如 SAML）可能丢会话。检查 CloudFront Function 是否写入了 `Forwarded` 头、实例 `/opt/kc/kc.env` 里是否为 `KC_PROXY_HEADERS=forwarded`。从实例本机访问 localhost 时出现这条属正常 |
| 创建失败：`WaitCondition received failed message: 'bootstrap failed at line N'` | 实例上的安装或配置脚本出错。加 `DISABLE_ROLLBACK=1` 重新部署，失败后登录实例看 `/var/log/e10sso-bootstrap.log`；看完删除栈再重来 |
| 创建失败：`Eip` 报 `AddressLimitExceeded` | 该区域弹性 IP 配额（默认 5 个）已满。释放不用的弹性 IP，或在 Service Quotas 申请提高 *EC2-VPC Elastic IPs* |
| 浏览器停在 E10 提示页"回调地址不在…业务系统URL地址范围内" | 3.3 的业务系统 URL 没改，或改的不是这个应用 |
| E10 提示"不在适用对象范围内" / "未维护电子邮箱" | E10 共享范围、人员邮箱 |
| Keycloak 页面 "We are sorry… Unexpected error when authenticating with identity provider" | 看 Keycloak 日志，按下面几行处理 |
| 日志：`did not return a nonce` | E10 不回传 nonce，`NONCE_MODE=disable`（默认值就是） |
| 日志：`No access_token from server` | E10 拒绝了换 token 请求：应用密钥不对、回调地址不在业务系统 URL 范围内，或 E10 不接受 POST 表单参数。看 E10 的统一认证中心 → 应用日志管理 → 接口日志 |
| 日志：issuer 不匹配（`Wrong issuer` / `invalid token issuer`） | `E10_ISSUER` 要和 E10 id_token 的 iss 原样一致（E10 一般是 `http://域名:端口`，注意有没有末尾的 `/`） |
| 日志：签名验证失败 | Keycloak 拿 E10 JWKS 的公钥验不过，E10 可能换过证书，请泛微排查 |
| 日志：连接 E10 超时 | 20600 端口对 Keycloak 不通，放行出口 IP（`aws/info.sh`） |
| 日志：`requires secure connections` | 正常情况下脚本已自动处理；如果 E10 用的是内网地址，脚本不会放宽，需要确认 E10 地址 |
| Keycloak 登录后用户没有邮箱 / Quick 报 User not found | E10 的 id_token 没有 email：改用 `EMAIL_FROM=sub`（E10 账号映射设为电子邮箱），或检查 E10 Scope 配置 |

## 10. 删除

```bash
PREFIX=e10sso-prod aws/destroy.sh                  # 删除 <前缀>-keycloak
PREFIX=e10sso-prod aws/destroy.sh --purge-bucket   # 同时删除代码桶
```
Keycloak 数据库在实例磁盘上，删除后无法恢复。删除后记得在 Quick 里删掉 Extension access，在 E10 里停用这个认证应用。

PoC 规格的限制和上生产要改的地方，见 [QUICK-SETUP.md](QUICK-SETUP.md) 第 5 节。
