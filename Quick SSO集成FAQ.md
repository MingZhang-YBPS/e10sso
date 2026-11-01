# Quick SSO集成FAQ

## **Q\.**** 为什么 Amazon Quick 的 SSO 登录设计如此复杂？**

Amazon Quick Web 继承于 Amazon Quick Sight，在此基础上延展出了较多的Agentic AI的服务。因而在认证方式上，订阅的角色上做了扩充。即在认证方式上增添IAM Identity Center的方式，角色上添加了Reader Pro/Author Pro/Admin Pro\.

Quick Desktop可以被视作一个全新的产品，是一个纯桌面版本，这里的纯桌面版本是指他并不是Amazon Quick Web的本地端应用，而是在桌面上打造的全新的产品，业务逻辑都跑在本地，而不是服务器端，因此对认证和会话提出了更高的要求，而支持这一要求需要IdP不但支持OIDC协议，还要满足特殊的要求。

Quick Desktop和Quick Web通过Email来认定同一个用户，当Quick Desktop发起登录的时候，会首先检查其对应的Quick Web用户Email，然后才去OIDC IdP上进行认证，认证通过且邮箱一致，则登录成功。而如果二者的认证都终结于同一个IdP，只需要输入一次用户名和密码。

Quick Desktop和Quick Web打通后，在Quick Desktop上可以复用Quick Web上的设置，例如Space，Connector Agent等。

> Quick Desktop 和 Quick Web只要是同一个邮箱登录，就可以完成集成。如果二者的认证过程没有任何集成， 会发生两次登录认证过程。如果二者的的登录过程已经打通，例如 IAM Identity Center 配置了External Identity Provider，一次登录过程就可以完成 Quick Web 和 Quick Desktop 的登录认证。
> 
> 



## **Q\.**** 为什么Quick Desktop 对 Idp有特殊要求？**

Desktop 只认 OIDC IdP，以下为硬性要求，不满足则无法登录：

- **支持 public client：** Quick Desktop是纯客户端应用， 桌面应用装在用户机器上，藏不住密钥。

client\_secret 的作用是"证明我是合法应用"。但桌面程序分发到每个用户电脑上,任何人都能反编译、抓包拿到里面的 secret——一旦嵌入就等于公开。既然守不住,OAuth 规范就规定这类应用注册为 public client\(公共客户端\)、不使用 secret,改用 PKCE来保证安全。这不是 Quick Desktop的特殊设定，是 OAuth 对所有原生/桌面应用的通用要求。

- **授权码 \+ PKCE（S256）： **因为没有 secret，需要 PKCE 顶替它的安全职责，防授权码被截获。

public client 没有client\_secret, 需要PKCE机制，用来进行临时身份核验，登录时客户端本地生成一个随机值 `code_verifier`，把它的哈希 `code_challenge`\(S256\)先发给 IdP，换 token 时，再出示原始 `code_verifier`，dP 重新哈希比对一致才发 token。

- **回调地址：**必须允许 [http://localhost:18080](http://localhost:18080)（本机回环）

因为Quick Desktop是纯桌面端，没有公网服务器,授权码只能回到本机自己，Desktop从该端口获取授权码。

- **Refresh Token\(offline\_access\)：**因为要让用户"登录一次、长期可用"，不必频繁重新输密码。

Access Token 很短命\(通常几分钟到一小时\)。如果没有 Refresh Token,用户每隔一会就要重新登录,体验极差。Refresh Token 让 Desktop 在后台静默续期,维持长会话。

- **Email claim: ** ID Token 必须含 email claim。

因为 Quick 靠 email 把登录用户对应到账户里的具体用户——email 是唯一的身份锚点。Quick 不认 IdP 内部的用户 ID,它认 email。登录成功后,Quick 从 ID Token 取出 email,去账户里找邮箱完全一致的用户,匹配上才建立会话。没有 email,Quick 就不知道"你是账户里的谁",直接报 User not found。对于默认不把Email放到ID Token，需要注意在设置的时候显式设定。

- **提供标准 OIDC 端点\(Issuer/Auth/Token/JWKS）：**支持Quick完成"跳转认证、换令牌、验签"的完整流程。

管理员在 Quick 控制台配 Extension Access 时,正是把这四个端点填进去,Quick 才知道去哪认证、去哪验签。这四个端点各司其职，缺一不可:

- **Authorization**:把用户带去登录的地址

- **Token**:用授权码换令牌的地址

- **JWKS**:公钥集,Quick 用它**验证 ID Token 签名**是不是这个 IdP 真签的

- **Issuer**:签发方标识,Quick 校验令牌来源\(Entra 必须含 `/v2.0`,否则 issuer 对不上、验签失败\)

## **Q\. ****在 Quick Desktop 设置的过程中，是否需要设置 TTI\(Trusted Token Issuer\)**

TTI\(Trusted Token Issuer，可信令牌签发方\) 是 IAM Identity Center 的一个 OAuth 2\.0 机制，用于可信身份传播\(Trusted Identity Propagation\)。如果下游 AWS 托管应用做授权只认 IAM Identity Center** 身份，**不接受外部 IdP 直接签发的令牌。TTI 负责把外部 OIDC JWT **交换**成 IDC 令牌\(见 [Using applications with a trusted token issuer](https://docs.aws.amazon.com/singlesignon/latest/userguide/using-apps-with-trusted-token-issuer.html)、[Trusted identity propagation overview](https://docs.aws.amazon.com/singlesignon/latest/userguide/trustedidentitypropagation-overview.html)\)。

**Quick Desktop 不需要 TTI。** 因为 Quick Desktop 作为客户端登录时，已经完成了与 Quick Web 的认证——它访问的是自己账户内的资源，不涉及"外部应用代表用户跨访问"，因此无需 TTI。

在 Quick 的 Extension 配置中：Quick Desktop Extension 本身不需要 TTI，只有配置 Slack 或 Teams 等 Extension 时才需要。TTI 是账户级的一次性设置，配一次即为该账户所有 Extension 共用。

**新旧控制台的差异:**

- **旧版控制台：**在配置第一个 Extension 之前就强制要求填入 TTI，无论该 Extension 是不是 Slack/Teams。因此即使 Quick Desktop Extension 是第一个配置的，也会被要求填 TTI\(但实际上 Quick Desktop 并不需要\)。

- **新版控制台：**已优化——只有在配置 Slack 或 Teams 等 Extension 时才要求填写 TTI， Quick Desktop不需要。

> 官方原文:"This is a **one\-time setup** that establishes a trusted identity source for **all extensions**\." —— [Amazon Quick Slack extension](https://docs.aws.amazon.com/quick/latest/userguide/slack-extension.html)
> 
> 

## **Q\. ****为什么 Slack 或 Teams 需要TTI配置：**

Slack 和 Teams Extension 在用户经 IdP 认证后,当用户用 @ 与 Quick 交流时,实际是 Slack/Teams 的服务器端作为请求方向 Quick 发起请求。请求携带的是 IdP 签发的 OIDC JWT\(其中含 email claim\)。此时 Quick App Integrations 服务会扮演配置的 Secretss Role,从 AWS Secrets Manager 取出应用的 client\_id/client\_secret\(用于与 IdP 的 OIDC 交互\)，并把这张 IdP JWT 提交给 IAM Identity Center 请求交换。IAM Identity Center 通过 TTI 验证该JWT公钥签名，并按 JWT 里的 email 映射到唯一的 IDC 用户——校验通过后签发 IDC 令牌。Quick App Integrations 服务持该 IDC 令牌，代表用户去访问 Amazon Quick。

在这个场景里，Amazon Quick 是Slack/Teams下游的AWS托管应用、是服务的接收方，而Slack/Teams 是服务的请求方。

**令牌交换流程简述如下**:

1. 请求方应用\(如 Slack 扩展\)拿到 IdP 签发的 JWT\(含 email、aud、iss、sub、exp,RS256\)。

2. 把 JWT 交给 IAM Identity Center 请求交换。

3. IDC 验签 \+ 按 **email** 在目录查到唯一用户 \+ 鉴权。

4. IDC 签发加密的 IDC 令牌\(含用户身份 \+ aud \+ scopes\)。

5. 请求方持 IDC 令牌访问下游 AWS 服务,下游按用户的 IDC Group 授权 \+ 审计。

> 你在 Slack @Quick 发指令后:① Slack 把事件转给云端 Quick 服务 → ② 首次需经 Okta OIDC 认证\(回调 idc\-tti/callback\)→ ③ Okta 签发含 email 的 JWT → ④ Quick 服务扮演 Secrets Role 读密钥、请求 IDC 交换 → ⑤ IDC 验签并按 email 查到唯一用户 → ⑥ 签发 IDC 令牌 → ⑦ 代表你访问 Quick、绑定身份 → ⑧ 按你本人的角色/组权限执行并回复 → ⑨ 后续 @Quick 直接响应。整套的关键是 TTI 令牌交换\(外部 JWT → IDC 令牌\),锚点是 email,授权按调用者本人权限。
> 
> 参考：[Setting up a trusted token issuer](https://docs.aws.amazon.com/singlesignon/latest/userguide/setuptrustedtokenissuer.html)
> 
> 

## **Q\. **为什么用 Quick Desktop， 选择哪个区域?

无论你选择哪条 SSO 路径，要使用 Desktop 桌面应用，Amazon Quick 账户的 home\(identity\)区域必须是受支持的区域。选择文档[AWS 区域、网站、IP 地址范围和端点](https://docs.aws.amazon.com/zh_cn/quick/latest/userguide/regions.html#regions-qs)中不带\*的区域，为收支持区域。

## **Q\. **Quick 中的角色和订阅之间的关系是什么？

- **Reader\(读者\)：**对仪表板拥有只读访问权限的用户，可以Chat BI 问答。

- **Author\(作者\)：**具有Reader权限的同时，还可以创建数据源、数据集、分析和仪表板的用户。

- **Admin\(管理员\)：**具有Author权限的同时，还能管理 Amazon Quick Sight 设置的用户。

- **Reader Pro\(Quick Professional\)：**在 Reader 角色基础上增加新的Quick能力，例如Space/Research/Flow等。

- **Author Pro\(Quick Enterprise\)：**在 Author 角色基础上增加新的Quick能力，例如Space/Research/Flow/Automate等。

- **Admin Pro\(Admin Pro\)：**Admin Pro在Author Pro的基础上增加管理设置的能力，Admin Pro 用户按 Author Pro 的价格计费。

> 参考：[Amazon Quick user types](https://docs.aws.amazon.com/quick/latest/userguide/user-types.html)
> 
> 

