#!/usr/bin/env python3
"""
测试 OIDC IdP（E10，或桥接用的 Keycloak）是否满足 Amazon Quick Desktop 的要求：
  1. 公共客户端（换 token 时不带 client_secret）
  2. 授权码 + PKCE (S256)，回调 http://localhost:18080
  3. ID token 用非对称算法签名，且签名能用 JWKS 公钥验证（RS256/384/512 由本脚本验证）
  4. ID token 含 email，格式合法，并与 Quick 用户邮箱完全一致（--expect-email）
  5. iss 与 Issuer 完全一致（含末尾的 /），aud 含 client_id，exp/iat 合理
  6. 请求 offline_access 不报错；不带 client_secret 能刷新，刷新后的 id_token 仍含同一 email
  7. 端点为 HTTPS；token 响应格式是否标准（不标准只给警告）
最后打印应填到 Quick「Extension access」里的值。

只用 Python 标准库。用法（客户 E10 是公网 http + 20600 端口，--base 照实填写）：
  python3 e10-oidc-pkce-test.py --base http://oa.example.com:20600 --client-id <应用标识> \\
      --discovery <服务发现地址> --expect-email <该用户在 Quick 里的邮箱>
  python3 e10-oidc-pkce-test.py ... --wrong-verifier
      ↑ 负面测试：故意发错误的 code_verifier，如果仍然拿到 token，说明 IdP 没有真正校验 PKCE
  python3 e10-oidc-pkce-test.py ... --client-secret <应用密钥>
      ↑ 对照测试：带密钥换 token，用来区分"IdP 不支持公共客户端"和"应用配置有问题"
退出码：0 = 没有"不通过"项
"""
import argparse, base64, hashlib, hmac, http.server, json, re, secrets, socketserver, ssl, sys, threading, time
import urllib.error, urllib.parse, urllib.request, webbrowser

ASYMMETRIC = {"RS256", "RS384", "RS512", "PS256", "PS384", "PS512", "ES256", "ES384", "ES512"}
# RSASSA-PKCS1-v1_5 的 DigestInfo 前缀（RFC 8017 第 9.2 节）
RSA_DIGEST = {
    "RS256": ("sha256", bytes.fromhex("3031300d060960864801650304020105000420")),
    "RS384": ("sha384", bytes.fromhex("3041300d060960864801650304020205000430")),
    "RS512": ("sha512", bytes.fromhex("3051300d060960864801650304020305000440")),
}
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
PASS, FAIL, WARN, SKIP = "通过", "不通过", "警告", "未验证"


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def b64url_decode(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def decode_jwt(jwt):
    h, p, _ = jwt.split(".")
    return json.loads(b64url_decode(h)), json.loads(b64url_decode(p))


def rsa_verify(jwt, jwk, alg):
    """纯 Python 验证 RS256/384/512 签名：s^e mod n 后比对 PKCS#1 v1.5 编码。"""
    h, p, s = jwt.split(".")
    n = int.from_bytes(b64url_decode(jwk["n"]), "big")
    e = int.from_bytes(b64url_decode(jwk["e"]), "big")
    k = (n.bit_length() + 7) // 8
    sig = b64url_decode(s)
    if len(sig) != k:
        return False
    em = pow(int.from_bytes(sig, "big"), e, n).to_bytes(k, "big")
    name, prefix = RSA_DIGEST[alg]
    digest = hashlib.new(name, f"{h}.{p}".encode()).digest()
    pad = k - 3 - len(prefix) - len(digest)
    return pad >= 8 and hmac.compare_digest(em, b"\x00\x01" + b"\xff" * pad + b"\x00" + prefix + digest)


def verify_jwt(jwt, header, keys):
    """返回 (状态, 说明)。"""
    alg, kid = header.get("alg"), header.get("kid")
    if kid:
        cands = [k for k in keys if k.get("kid") == kid]
        if not cands:
            return FAIL, f"JWKS 里没有 kid={kid}（现有 {[k.get('kid') for k in keys]}），IdP 可能换过密钥"
    else:
        cands = [k for k in keys if k.get("kty") == "RSA"]
    if alg not in RSA_DIGEST:
        return SKIP, f"本脚本只验 RS256/384/512，{alg} 的签名需另行确认"
    notes = []
    for k in cands:
        if k.get("kty") != "RSA":
            continue
        if k.get("use") == "enc":
            notes.append(f"kid={k.get('kid')} 标为加密用途(use=enc)")
            continue
        if k.get("alg") and k["alg"] != alg:
            notes.append(f"kid={k.get('kid')} 的 alg={k['alg']} 与 token 的 {alg} 不一致")
        if rsa_verify(jwt, k, alg):
            return PASS, f"kid={k.get('kid')}，{alg}" + (f"（注意：{'；'.join(notes)}）" if notes else "")
    return FAIL, "签名验证失败：JWKS 里的公钥与签名不匹配（换过密钥、JWKS 内容不对或 token 被改过）" + \
        (f"；{'；'.join(notes)}" if notes else "")


def http_get_json(url, ctx):
    with urllib.request.urlopen(url, timeout=20, context=ctx) as r:
        return json.loads(r.read().decode())


def post_form(url, form, ctx):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(form).encode(),
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=20, context=ctx) as r:
            status, text = r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read().decode(errors="replace")
    try:
        data = json.loads(text)
    except ValueError:
        data = {}
    return status, text, data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="IdP 地址，含协议和端口，如 http://oa.example.com:20600（提供 --discovery 时以服务发现为准）")
    ap.add_argument("--client-id", required=True, help="IdP 里注册的应用标识（client_id）")
    ap.add_argument("--discovery", help="OIDC 服务发现地址；不填则用 {base}/papi/sso/oidc/.well-known/openid-configuration（E10 的路径）")
    ap.add_argument("--expect-email", help="该测试用户在 Quick 里的邮箱，用于逐字比对 ID token 的 email")
    ap.add_argument("--port", type=int, default=18080, help="本地回调端口，回调地址为 http://localhost:<port>")
    ap.add_argument("--scope", default="openid email profile offline_access")
    ap.add_argument("--wrong-verifier", action="store_true", help="负面测试：用错误的 code_verifier 换 token")
    ap.add_argument("--client-secret", help="对照测试：换 token 时带上 client_secret，用来确认应用配置本身没问题")
    ap.add_argument("--insecure", action="store_true", help="跳过 TLS 证书校验（仅测试环境自签证书时用）")
    a = ap.parse_args()

    ctx = ssl._create_unverified_context() if a.insecure else ssl.create_default_context()
    base = a.base.rstrip("/")
    ep = {
        "issuer": None,
        "authorization_endpoint": base + "/papi/sso/oidc/authorize",
        "token_endpoint": base + "/papi/sso/oidc/accessToken",
        "jwks_uri": base + "/papi/sso/oidc/jwks",
    }

    print("== 1. 服务发现 ==")
    discovery = a.discovery or base + "/papi/sso/oidc/.well-known/openid-configuration"
    if not a.discovery:
        print(f"  未提供 --discovery，使用 E10 的服务发现路径：{discovery}")
    if discovery:
        try:
            d = http_get_json(discovery, ctx)
            for k in ("issuer", "authorization_endpoint", "token_endpoint", "jwks_uri"):
                if d.get(k):
                    ep[k] = d[k]
            for k in ("issuer", "authorization_endpoint", "token_endpoint", "jwks_uri",
                      "code_challenge_methods_supported", "token_endpoint_auth_methods_supported",
                      "id_token_signing_alg_values_supported", "scopes_supported", "claims_supported",
                      "grant_types_supported"):
                print(f"  {k}: {d.get(k, '(未声明)')}")
        except Exception as e:
            print(f"  取服务发现失败：{e}，改用 E10 文档里的默认路径（无法核对 issuer）")
    for k, v in ep.items():
        print(f"  使用 {k}: {v}")

    verifier = b64url(secrets.token_bytes(32))
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    state = secrets.token_urlsafe(16)
    redirect_uri = f"http://localhost:{a.port}"
    result = {}

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if "code" in q or "error" in q:
                result.update({k: v[0] for k, v in q.items()})
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write("已收到回调，可以关闭此页面，回到终端查看结果。".encode())
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, *args):
            pass

    socketserver.TCPServer.allow_reuse_address = True
    srv = socketserver.TCPServer(("127.0.0.1", a.port), H)

    auth_url = ep["authorization_endpoint"] + "?" + urllib.parse.urlencode({
        "client_id": a.client_id, "response_type": "code", "redirect_uri": redirect_uri,
        "scope": a.scope, "state": state, "code_challenge": challenge, "code_challenge_method": "S256",
    })
    print("\n== 2. 授权（浏览器里登录）==")
    print("  如果浏览器没有自动打开，手动访问：\n  " + auth_url)
    try:
        webbrowser.open(auth_url)
    except Exception:
        pass
    srv.serve_forever()
    srv.server_close()

    if "error" in result:
        print(f"  授权失败：{result}")
        if "offline_access" in a.scope.split():
            print("  如果报错和 scope 有关，可能是 IdP 不认 offline_access。用下面的参数再跑一次对比：")
            print('    --scope "openid email profile"')
            print("  去掉后能成功，就说明是 offline_access 导致的（Quick Desktop 登录时会带这个 scope）。")
        sys.exit(1)
    if result.get("state") != state:
        print(f"  [警告] state 不一致：发出 {state}，收到 {result.get('state')}")
    print(f"  拿到授权码：{result['code'][:20]}...")

    mode = "带 client_secret（对照测试）" if a.client_secret else "不带 client_secret"
    print(f"\n== 3. 换 token（{mode}，带 code_verifier）==")
    sent_verifier = b64url(secrets.token_bytes(32)) if a.wrong_verifier else verifier
    form = {
        "grant_type": "authorization_code", "client_id": a.client_id, "code": result["code"],
        "redirect_uri": redirect_uri, "code_verifier": sent_verifier,
    }
    if a.client_secret:
        form["client_secret"] = a.client_secret
    status, text, tok = post_form(ep["token_endpoint"], form, ctx)
    print(f"  HTTP {status}: {text[:500]}")
    id_token = tok.get("id_token")

    if a.wrong_verifier:
        if id_token or tok.get("access_token"):
            print("\n[不通过] 用错误的 code_verifier 也拿到了 token：IdP 没有校验 PKCE")
            sys.exit(1)
        print("\n[通过] 错误的 code_verifier 被拒绝：IdP 校验了 PKCE")
        return
    if not id_token:
        if status == 200:
            print("  [警告] 出错时仍返回 HTTP 200（不符合 RFC 6749，标准做法是 400 + error 字段）")
        if a.client_secret:
            print("\n[不通过] 带 client_secret 也拿不到 id_token：应用配置有问题（回调地址、共享范围、scope），先排查配置")
        else:
            print("\n[不通过] 不带 client_secret 拿不到 id_token：IdP 大概率不支持公共客户端 + PKCE")
            print("  请再用 --client-secret <应用密钥> 跑一次对照测试，确认应用配置本身是通的")
        sys.exit(1)
    if a.client_secret:
        print("\n  注意：这是带 client_secret 的对照测试，Quick Desktop 实际不会带密钥")

    checks = []

    def add(name, st, detail=""):
        checks.append((name, st, str(detail)))

    print("\n== 4. 检查 ID token ==")
    try:
        header, payload = decode_jwt(id_token)
    except Exception as e:
        print(f"\n[不通过] id_token 不是合法的 JWT：{e}")
        sys.exit(1)
    print("  header :", json.dumps(header, ensure_ascii=False))
    print("  payload:", json.dumps(payload, ensure_ascii=False, indent=2))

    alg = header.get("alg")
    add("签名算法为非对称算法", PASS if alg in ASYMMETRIC else FAIL,
        alg if alg in ASYMMETRIC else f"{alg}（Quick 不接受 HS* 和 none）")
    try:
        keys = http_get_json(ep["jwks_uri"], ctx).get("keys", [])
        add("JWKS 可访问", PASS, f"{len(keys)} 个公钥")
    except Exception as e:
        keys = None
        add("JWKS 可访问", FAIL, e)
    if keys is not None:
        add("ID token 签名能用 JWKS 公钥验证", *verify_jwt(id_token, header, keys))

    email = payload.get("email")
    add("ID token 包含 email claim", PASS if email else FAIL, email or "无（Quick 会报 User not found）")
    if email:
        add("email 格式合法", PASS if isinstance(email, str) and EMAIL_RE.match(email) else FAIL, repr(email))
        if not a.expect_email:
            add("email 与 Quick 用户邮箱完全一致", SKIP, "未提供 --expect-email")
        elif email == a.expect_email:
            add("email 与 Quick 用户邮箱完全一致", PASS, email)
        elif str(email).strip().lower() == a.expect_email.strip().lower():
            add("email 与 Quick 用户邮箱完全一致", FAIL, f"只差大小写或空格：token={email!r}，Quick={a.expect_email!r}")
        else:
            add("email 与 Quick 用户邮箱完全一致", FAIL, f"token={email}，Quick={a.expect_email}")

    aud = payload.get("aud")
    add("aud 包含 client_id", PASS if a.client_id in (aud if isinstance(aud, list) else [aud]) else FAIL, aud)

    iss = payload.get("iss")
    if not iss:
        add("iss 与 Issuer 完全一致", FAIL, "id_token 没有 iss")
    elif ep["issuer"] is None:
        add("iss 与 Issuer 完全一致", SKIP, f"未提供 --discovery，无法比对；Quick 的 Issuer URL 必须原样填 {iss}")
    elif iss == ep["issuer"]:
        add("iss 与 Issuer 完全一致", PASS, iss)
    elif iss.rstrip("/") == ep["issuer"].rstrip("/"):
        add("iss 与 Issuer 完全一致", FAIL, f"只差末尾的 /：token={iss}，服务发现={ep['issuer']}")
    else:
        add("iss 与 Issuer 完全一致", FAIL, f"token={iss}，服务发现={ep['issuer']}")

    now = time.time()
    exp, iat = payload.get("exp"), payload.get("iat")
    if not isinstance(exp, (int, float)):
        add("exp 有效", FAIL, "id_token 没有 exp")
    elif exp <= now:
        add("exp 有效", FAIL, f"已过期 {int(now - exp)} 秒（检查 IdP 服务器时间）")
    else:
        add("exp 有效", PASS, f"还剩 {int(exp - now)} 秒")
    if isinstance(iat, (int, float)) and abs(iat - now) > 120:
        add("iat 与本机时间接近", WARN, f"相差 {int(iat - now)} 秒，IdP 或本机时钟可能不准")

    tt = tok.get("token_type")
    add("token 响应包含 token_type=Bearer", PASS if isinstance(tt, str) and tt.lower() == "bearer" else WARN,
        tt or "无（不符合 RFC 6749，Quick Desktop 是否接受需实测）")
    add("返回 refresh_token", PASS if tok.get("refresh_token") else FAIL,
        "有" if tok.get("refresh_token") else "无，用户会频繁重新登录")

    plain = [f"{k}={v}" for k, v in (("issuer", iss), ("authorization", ep["authorization_endpoint"]),
                                    ("token", ep["token_endpoint"]), ("jwks", ep["jwks_uri"]))
             if v and not v.startswith("https://")]
    local = all(urllib.parse.urlparse(x.split("=", 1)[1]).hostname in ("localhost", "127.0.0.1") for x in plain)
    if not plain:
        add("端点均为 HTTPS", PASS, "全部 https")
    elif local:
        add("端点均为 HTTPS", WARN, "；".join(plain) + "（本机测试可以，正式环境必须是公网 HTTPS）")
    else:
        add("端点均为 HTTPS", FAIL, "；".join(plain) + "。Quick 要求 OIDC 端点用 HTTPS（OIDC 规范也要求 issuer 用 https），"
            "这个 IdP 不能直接配给 Quick Desktop；走 Keycloak 桥接时只要求 Keycloak 是 HTTPS")

    refresh_token = tok.get("refresh_token")
    if refresh_token:
        print("\n== 5. 用 refresh_token 刷新（不带 client_secret）==")
        rform = {"grant_type": "refresh_token", "client_id": a.client_id, "refresh_token": refresh_token}
        status, text, rtok = post_form(ep["token_endpoint"], rform, ctx)
        print(f"  HTTP {status}: {text[:500]}")
        ok = bool(rtok.get("access_token"))
        add("不带 client_secret 能刷新 token", PASS if ok else FAIL,
            "刷新成功" if ok else "刷新失败，access token 过期后用户需要重新登录")
        if ok:
            rid = rtok.get("id_token")
            if not rid:
                add("刷新后返回新的 id_token", WARN, "无")
            else:
                try:
                    rh, rp = decode_jwt(rid)
                    if keys is not None:
                        add("刷新后的 id_token 签名有效", *verify_jwt(rid, rh, keys))
                    same = rp.get("email") == email and rp.get("iss") == iss
                    add("刷新后的 id_token 仍含同一 email、iss", PASS if same else FAIL,
                        f"email={rp.get('email')}，iss={rp.get('iss')}")
                except Exception as e:
                    add("刷新后的 id_token 可解析", FAIL, e)
        elif a.client_secret:
            print("\n== 5b. 对照：带 client_secret 刷新 ==")
            rform["client_secret"] = a.client_secret
            status, text, rtok = post_form(ep["token_endpoint"], rform, ctx)
            print(f"  HTTP {status}: {text[:500]}")
            ok2 = bool(rtok.get("access_token"))
            add("对照：带 client_secret 能刷新 token", PASS if ok2 else FAIL,
                "能刷新，说明 IdP 刷新时强制要求密钥" if ok2 else "也失败，检查 refresh_token 有效期配置")

    print("\n== 有效期 ==")
    print(f"  access_token  ：{tok.get('expires_in', '未返回')} 秒（expires_in）")
    print(f"  refresh_token ：{tok.get('refresh_expires_in', '未返回（E10 在 认证应用→高级设置→时效设置 里配，默认 5 天、最长 10 天）')}"
          + (" 秒（refresh_expires_in，0 表示离线会话不按此过期）" if "refresh_expires_in" in tok else ""))
    if isinstance(exp, (int, float)) and isinstance(iat, (int, float)):
        print(f"  id_token      ：{int(exp - iat)} 秒（exp - iat）")

    print("\n== 结果 ==")
    for name, st, detail in checks:
        print(f"  [{st}] {name}{'：' + detail if detail else ''}")

    print("\n== 填到 Quick「Extension access」的值 ==")
    if a.client_secret:
        print("  （这是带密钥的对照测试，仅供参考：Quick Desktop 不会带密钥）")
    print(f"  Issuer URL             {iss}    ← 取自 id_token 的 iss，必须原样填写" + ("（包括末尾的 /）" if iss and iss.endswith("/") else ""))
    print(f"  Authorization endpoint {ep['authorization_endpoint']}")
    print(f"  Token endpoint         {ep['token_endpoint']}")
    print(f"  JWKS URI               {ep['jwks_uri']}")
    print(f"  Client ID              {a.client_id}")
    print("  提醒：Quick 在 AWS 侧访问 JWKS 验签，JWKS 地址必须能从公网访问、证书由公网 CA 签发（可在 AWS CloudShell 里用 curl 访问 JWKS 地址验证）。")
    print("  Extension access 建好后不能修改，填错只能删除重建。")
    print("\n别忘了再用 --wrong-verifier 跑一次负面测试。")
    sys.exit(1 if any(st == FAIL for _, st, _ in checks) else 0)


if __name__ == "__main__":
    main()
