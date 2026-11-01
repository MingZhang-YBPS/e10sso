#!/usr/bin/env python3
"""
通过 Keycloak Admin REST API 配置 E10 桥接方案（只用 Python 标准库，可重复执行）。

配置内容：
  realm corp
  ├─ 身份提供商 e10：OIDC，连接 E10 统一认证中心（机密客户端，带 client_secret，不用 PKCE，不调用户信息接口）
  │    映射：username ← email，email ← email，firstName ← username(E10 的姓名 claim)
  ├─ 首次登录流程：不弹"补充资料"页；浏览器流程：自动跳转到 E10
  ├─ 客户端 amazon-quick-desktop：公共客户端 + PKCE(S256)，回调 http://localhost:18080
  └─ 客户端 IAM Identity Center：SAML，按 SP 元数据导入，NameID=emailAddress，断言签名，不加密

用法：由 Keycloak 实例上的 /opt/kc/configure.sh 调用（aws/deploy.sh、aws/register-idc-sp.sh 会经 SSM 触发），
管理接口走实例本机的 http://localhost:9080，对外地址用 --public-url：
  E10_CLIENT_SECRET=... python3 setup-keycloak.py --kc http://localhost:9080 --public-url https://xxxx.cloudfront.net \\
      --admin-pass ... --e10-base http://oa.example.com:20600 --e10-client-id ... [--sp-metadata IAM-Identity-Center的SP元数据.xml]
  python3 setup-keycloak.py ... --delete-client <clientId>  # 删除某个客户端后退出
"""
import argparse, ipaddress, json, os, sys, urllib.error, urllib.parse, urllib.request


ap = argparse.ArgumentParser()
ap.add_argument("--kc", default="http://localhost:9080", help="调用管理接口的地址")
ap.add_argument("--public-url", help="用户和 AWS 访问 Keycloak 的地址（默认同 --kc），只用于打印对接信息")
ap.add_argument("--admin-user", default="admin")
ap.add_argument("--admin-pass", default=os.environ.get("KC_ADMIN_PASSWORD"))
ap.add_argument("--realm", default="corp")
ap.add_argument("--reset", action="store_true", help="先删除 realm 再重建（会丢失用户和 SAML 客户端，慎用）")
ap.add_argument("--e10-base", required=True, help="E10 地址，含协议和端口，如 http://oa.example.com:20600")
ap.add_argument("--e10-issuer", help="E10 id_token 的 iss，默认等于 --e10-base（E10 的 issuer 就是访问地址：协议 + 域名:端口）")
ap.add_argument("--e10-client-id", required=True)
ap.add_argument("--e10-client-secret", default=os.environ.get("E10_CLIENT_SECRET"),
                help="E10 应用密钥。请用环境变量 E10_CLIENT_SECRET 传入，避免出现在命令历史里")
ap.add_argument("--e10-scopes", default="openid email profile", help="向 E10 请求的 scope，必须是 E10 Scope 配置里有的")
ap.add_argument("--nonce", choices=["disable", "send"], default="disable",
                help="E10 的 id_token 不回传 nonce 时必须 disable（默认）")
ap.add_argument("--email-from", choices=["email", "sub"], default="email",
                help="用户邮箱取自 E10 id_token 的哪个 claim；E10 Scope 配置不出 email 时用 sub（账号映射需设为电子邮箱）")
ap.add_argument("--desktop-redirect", default="http://localhost:18080")
ap.add_argument("--sp-metadata", default="none",
                help="IAM Identity Center 的 SP 元数据文件；none（默认）则不配置 SAML 客户端")
ap.add_argument("--delete-client", help="删除指定 clientId 的客户端后退出（例如删除测试用的 SAML 客户端）")
a = ap.parse_args()
if not a.admin_pass:
    sys.exit("缺少 Keycloak 管理员密码：--admin-pass 或环境变量 KC_ADMIN_PASSWORD")
if not a.e10_client_secret and not a.delete_client:
    sys.exit("缺少 E10 应用密钥：环境变量 E10_CLIENT_SECRET")
E10 = a.e10_base.rstrip("/")
ISSUER = a.e10_issuer or E10
R = a.realm
PUBLIC = (a.public_url or a.kc).rstrip("/")


def call(method, path, body=None, raw=None, ctype="application/json", ok=(200, 201, 204)):
    url = a.kc.rstrip("/") + path
    data = raw.encode() if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, data=data, method=method, headers={"Authorization": "Bearer " + TOKEN})
    if data is not None:
        req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            txt = r.read().decode()
            return json.loads(txt) if txt.strip().startswith(("{", "[")) else txt
    except urllib.error.HTTPError as e:
        if e.code in ok:
            return None
        sys.exit(f"{method} {path} 失败：HTTP {e.code} {e.read().decode()[:500]}")


# ---------- 管理员登录 ----------
form = urllib.parse.urlencode({"grant_type": "password", "client_id": "admin-cli",
                               "username": a.admin_user, "password": a.admin_pass}).encode()
with urllib.request.urlopen(a.kc.rstrip("/") + "/realms/master/protocol/openid-connect/token", data=form, timeout=30) as r:
    TOKEN = json.load(r)["access_token"]

if a.delete_client:
    found = call("GET", f"/admin/realms/{R}/clients?clientId={urllib.parse.quote(a.delete_client, safe='')}")
    for c in found or []:
        call("DELETE", f"/admin/realms/{R}/clients/{c['id']}")
    print(f"已删除客户端 {a.delete_client}" if found else f"客户端 {a.delete_client} 不存在")
    sys.exit(0)

# ---------- realm ----------
exists = any(x["realm"] == R for x in call("GET", "/admin/realms"))
if exists and a.reset:
    call("DELETE", f"/admin/realms/{R}")
    exists = False
    print(f"已删除 realm {R}")
if not exists:
    call("POST", "/admin/realms", {"realm": R, "enabled": True, "displayName": "企业统一登录（E10 桥接）"})
    print(f"已创建 realm {R}")

# 持久化的签名密钥：实例重建后 realm 会重新生成密钥，导致 SAML 证书和 OIDC 公钥都变。
# 环境变量 REALM_SIGNING_KEY / REALM_SIGNING_CERT（PEM 内容，可不带头尾）存在时，导入这把密钥并删除自动生成的 RS256 密钥，
# 这样 IAM Identity Center 里的 IdP 元数据和 Quick Desktop 看到的公钥都保持不变。
SIG_KEY, SIG_CERT = os.environ.get("REALM_SIGNING_KEY", "").strip(), os.environ.get("REALM_SIGNING_CERT", "").strip()
if SIG_KEY and SIG_CERT:
    realm_id = call("GET", f"/admin/realms/{R}")["id"]
    comps = call("GET", f"/admin/realms/{R}/components?parent={realm_id}&type=org.keycloak.keys.KeyProvider")
    want = {"priority": ["200"], "enabled": ["true"], "active": ["true"], "algorithm": ["RS256"],
            "keyUse": ["SIG"], "privateKey": [SIG_KEY], "certificate": [SIG_CERT]}
    cur = next((c for c in comps if c.get("name") == "persisted-rsa-sig"), None)
    if cur is None:
        call("POST", f"/admin/realms/{R}/components", {"name": "persisted-rsa-sig", "providerId": "rsa",
             "providerType": "org.keycloak.keys.KeyProvider", "parentId": realm_id, "config": want})
        print("已导入持久化的签名密钥（SAML 证书、OIDC 公钥与之前一致）")
    elif cur.get("config", {}).get("certificate") != [SIG_CERT]:
        call("PUT", f"/admin/realms/{R}/components/{cur['id']}", {**cur, "config": want})
        print("已更新持久化的签名密钥")
    for c in comps:
        if c.get("providerId") == "rsa-generated":
            call("DELETE", f"/admin/realms/{R}/components/{c['id']}")
            print("已删除自动生成的 RS256 签名密钥（改用持久化的密钥）")

# E10 是公网 http（客户 E10 为 http + 20600）时，Keycloak 默认拒绝把它配成身份提供商
# （"requires secure connections"）。这个检查取决于 realm 的 SSL 要求，只能把 corp realm 的 SSL 要求改为 none。
# 用户访问 Keycloak 仍然只能经 CloudFront 的 HTTPS（源站安全组只放行 CloudFront），影响的只是对 E10 的 http 调用。
def _e10_is_public_http():
    u = urllib.parse.urlparse(E10)
    if u.scheme != "http":
        return False
    if u.hostname in ("localhost",):
        return False
    try:
        return not ipaddress.ip_address(u.hostname).is_private
    except ValueError:
        return True   # 域名：按公网处理
want_ssl = "none" if _e10_is_public_http() else "external"
realm_rep = call("GET", f"/admin/realms/{R}")
if realm_rep.get("sslRequired") != want_ssl:
    call("PUT", f"/admin/realms/{R}", {"sslRequired": want_ssl})
if want_ssl == "none":
    print(f"注意：E10 是公网 http（{E10}），已将 realm {R} 的 SSL 要求设为 none；"
          "E10 登录密码、授权码、Keycloak→E10 的 client_secret 都以明文经过公网，建议客户为 E10 启用 HTTPS")

# 用户资料：姓、名改为非必填（E10 只有一个"姓名"字段），避免首次登录弹出补填页
up = call("GET", f"/admin/realms/{R}/users/profile")
for at in up["attributes"]:
    if at["name"] in ("firstName", "lastName"):
        at.pop("required", None)
call("PUT", f"/admin/realms/{R}/users/profile", up)

# ---------- 身份提供商：E10 ----------
idp = {
    "alias": "e10", "displayName": "泛微 E10", "providerId": "oidc", "enabled": True,
    "trustEmail": True, "storeToken": False, "linkOnly": False, "hideOnLogin": True,
    "firstBrokerLoginFlowAlias": "first broker login",
    "config": {
        "authorizationUrl": f"{E10}/papi/sso/oidc/authorize",
        "tokenUrl": f"{E10}/papi/sso/oidc/accessToken",
        "userInfoUrl": f"{E10}/papi/sso/oidc/profile",
        "jwksUrl": f"{E10}/papi/sso/oidc/jwks",
        "logoutUrl": f"{E10}/sp/integration/oidc/logout",
        "issuer": ISSUER,
        "clientId": a.e10_client_id,
        "clientSecret": a.e10_client_secret,
        "clientAuthMethod": "client_secret_post",   # E10 要求 client_secret 作为参数传
        "defaultScope": a.e10_scopes,
        "validateSignature": "true",
        "useJwksUrl": "true",
        "pkceEnabled": "false",                      # E10 文档未提 PKCE
        "disableUserInfo": "true",                   # E10 用户信息接口不是标准格式，只用 id_token
        "disableNonce": "true" if a.nonce == "disable" else "false",
        "syncMode": "FORCE",                         # 每次登录用 E10 数据刷新用户
        "backchannelSupported": "false",
        "sendIdTokenOnLogout": "false",
        "sendClientIdOnLogout": "false",
    },
}
if call("GET", f"/admin/realms/{R}/identity-provider/instances/e10", ok=(404,)) is None:
    call("POST", f"/admin/realms/{R}/identity-provider/instances", idp)
else:
    call("PUT", f"/admin/realms/{R}/identity-provider/instances/e10", idp)
for m in call("GET", f"/admin/realms/{R}/identity-provider/instances/e10/mappers"):
    call("DELETE", f"/admin/realms/{R}/identity-provider/instances/e10/mappers/{m['id']}")
mappers = [
    (f"username ← E10 {a.email_from}", "oidc-username-idp-mapper", {"template": "${CLAIM." + a.email_from + "}", "target": "LOCAL"}),
    (f"email ← E10 {a.email_from}", "oidc-user-attribute-idp-mapper", {"claim": a.email_from, "user.attribute": "email"}),
    ("firstName ← E10 姓名", "oidc-user-attribute-idp-mapper", {"claim": "username", "user.attribute": "firstName"}),
]
for name, typ, conf in mappers:
    call("POST", f"/admin/realms/{R}/identity-provider/instances/e10/mappers",
         {"name": name, "identityProviderAlias": "e10", "identityProviderMapper": typ,
          "config": {"syncMode": "INHERIT", **conf}})
print(f"已配置身份提供商 e10（nonce={a.nonce}，邮箱取自 {a.email_from}），回调地址：{PUBLIC}/realms/{R}/broker/e10/endpoint")

# ---------- 认证流程 ----------
def executions(flow):
    return call("GET", f"/admin/realms/{R}/authentication/flows/{urllib.parse.quote(flow)}/executions")

for ex in executions("first broker login"):
    if ex.get("providerId") == "idp-review-profile":
        cfg = {"alias": "review profile config", "config": {"update.profile.on.first.login": "off"}}
        if ex.get("authenticationConfig"):
            cur = call("GET", f"/admin/realms/{R}/authentication/config/{ex['authenticationConfig']}")
            cur["config"]["update.profile.on.first.login"] = "off"
            call("PUT", f"/admin/realms/{R}/authentication/config/{ex['authenticationConfig']}", cur)
        else:
            call("POST", f"/admin/realms/{R}/authentication/executions/{ex['id']}/config", cfg)
for ex in executions("browser"):
    if ex.get("providerId") == "identity-provider-redirector":
        if ex.get("authenticationConfig"):
            cur = call("GET", f"/admin/realms/{R}/authentication/config/{ex['authenticationConfig']}")
            cur["config"]["defaultProvider"] = "e10"
            call("PUT", f"/admin/realms/{R}/authentication/config/{ex['authenticationConfig']}", cur)
        else:
            call("POST", f"/admin/realms/{R}/authentication/executions/{ex['id']}/config",
                 {"alias": "redirect-to-e10", "config": {"defaultProvider": "e10"}})
print("已配置：首次登录不弹补填页；浏览器登录自动跳转 E10")

# ---------- 客户端 ----------
def upsert_client(rep):
    found = call("GET", f"/admin/realms/{R}/clients?clientId={urllib.parse.quote(rep['clientId'], safe='')}")
    if found:
        call("PUT", f"/admin/realms/{R}/clients/{found[0]['id']}", {**found[0], **rep,
             "attributes": {**found[0].get("attributes", {}), **rep.get("attributes", {})}})
    else:
        call("POST", f"/admin/realms/{R}/clients", rep)

upsert_client({
    "clientId": "amazon-quick-desktop", "name": "Amazon Quick Desktop", "protocol": "openid-connect",
    "publicClient": True, "standardFlowEnabled": True, "directAccessGrantsEnabled": False,
    "implicitFlowEnabled": False, "serviceAccountsEnabled": False,
    "redirectUris": [a.desktop_redirect], "webOrigins": [],
    "attributes": {"pkce.code.challenge.method": "S256", "post.logout.redirect.uris": "+"},
})
print("已配置客户端 amazon-quick-desktop（公共客户端 + PKCE S256）")

if a.sp_metadata and a.sp_metadata.lower() != "none":
    sp_xml = open(a.sp_metadata, encoding="utf-8").read()
    saml = call("POST", f"/admin/realms/{R}/client-description-converter", raw=sp_xml, ctype="application/xml")
    saml["name"] = "AWS IAM Identity Center"
    saml.setdefault("attributes", {}).update({
        "saml_name_id_format": "email",          # NameID 用 emailAddress 格式，值为用户邮箱
        "saml_force_name_id_format": "true",
        "saml.assertion.signature": "true",      # 断言签名
        "saml.server.signature": "true",         # 响应签名
        "saml.signature.algorithm": "RSA_SHA256",
        "saml.client.signature": "false",        # IAM Identity Center 不对 AuthnRequest 签名
        "saml.encrypt": "false",                 # IAM Identity Center 不支持加密断言
        "saml.force.post.binding": "true",
        "saml.authnstatement": "true",
    })
    saml["frontchannelLogout"] = False
    upsert_client(saml)
    print(f"已配置 SAML 客户端 {saml['clientId']}")
else:
    print("未提供 SP 元数据，跳过 SAML 客户端（拿到 IAM Identity Center 的 SP 元数据后再配置）")

kc = PUBLIC
print(f"""
================ 交给 AWS 侧的信息 ================
[Quick Desktop → Extension access]
  Issuer URL             {kc}/realms/{R}
  Authorization endpoint {kc}/realms/{R}/protocol/openid-connect/auth
  Token endpoint         {kc}/realms/{R}/protocol/openid-connect/token
  JWKS URI               {kc}/realms/{R}/protocol/openid-connect/certs
  Client ID              amazon-quick-desktop
[IAM Identity Center → External IdP 元数据]
  {kc}/realms/{R}/protocol/saml/descriptor
[E10 → OIDC 认证应用 → 业务系统 URL]
  {kc}/realms/{R}/broker/e10/endpoint
""")
