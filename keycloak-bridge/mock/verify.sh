#!/bin/bash
# 【仅测试用】对"模拟 E10 + Keycloak"做端到端验证（从本机用无头浏览器访问云上地址）：
#   1. Desktop 路径：公共客户端 + PKCE 经 Keycloak → 模拟 E10 登录，验签、email 与 Quick 用户一致、无密钥刷新
#   2. Desktop 负面：错误的 code_verifier 被拒绝
#   3. 对照（联调测试 B）：Desktop 不经 Keycloak 直连模拟 E10 → 应失败（E10 要求 client_secret）
#   4. Web 路径：临时登记模拟的 IAM Identity Center SP，检查 SAML 断言（验签等），测完删除
#   5. 公网安全：/admin、/realms/master 被 CloudFront 拒绝；模拟 E10 管理接口从公网一律拒绝
# 对接真实 E10 时不用这个脚本（它要用模拟 E10 的测试账号密码），改用 e10-oidc-pkce-test.py，见 aws/KEYCLOAK-DEPLOY.md 3.4。
# 说明：模拟 E10 按客户实际是 http + 指定端口（栈参数 E10Port，默认 20600）。Playwright 默认关闭了 Chrome 的 HTTPS 升级，
#      真实 Chrome 154+ 首次打开 http 的 E10 登录页会先出"连接不安全"提示，需要用户点继续（见 QUICK-SETUP.md）
# 本机需要：python3、node、mock/tests 下 npm install 过；无系统字体时设置 LD_LIBRARY_PATH/FONTCONFIG_FILE（见 README）
source "$(dirname "$0")/../aws/common.sh"
T="$ROOT/mock/tests"
KC=$(out "$KC_STACK" KeycloakUrl)
E10=$(out "$MOCK_STACK" E10BaseUrl)
EMAIL=$(out "$MOCK_STACK" TestUserEmail)
LOGIN=$(out "$MOCK_STACK" TestLoginId)
SJ=$(secret_json "$(out "$MOCK_STACK" SecretArn)")
PW=$(echo "$SJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["user_password"])')
DIRECT_SECRET=$(echo "$SJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["direct_client_secret"])')
export KC_BASE="$KC" E10_BASE="$E10" E10_USER="$LOGIN" E10_PASS="$PW"
mkdir -p "$T/out"
PASS=0; FAIL=0
res() { if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  [通过]   $1"; else FAIL=$((FAIL+1)); echo "  [不通过] $1 ${3:-}"; fi; }

echo "Keycloak：$KC"; echo "模拟 E10：$E10"; echo "测试人员：$LOGIN <$EMAIL>"; echo

# 1. Desktop
D=$("$T/run-pkce.sh" cloud-desktop --base "$KC" --client-id amazon-quick-desktop \
     --discovery "$KC/realms/corp/.well-known/openid-configuration" --expect-email "$EMAIL")
echo "$D" > "$T/out/cloud-desktop.txt"
if echo "$D" | grep -q '== 结果' && ! echo "$D" | grep -qE '\[(不通过|警告)\]'; then res "Desktop：PKCE 登录、验签、email=$EMAIL、无密钥刷新（无警告）" 0
else res "Desktop：PKCE 登录、验签、email、无密钥刷新" 1 "$(echo "$D" | grep -E '不通过|警告|HTTP 4' | head -3 | tr '\n' ' ')"; fi

# 2. Desktop 负面
D=$("$T/run-pkce.sh" cloud-wrongverifier --base "$KC" --client-id amazon-quick-desktop \
     --discovery "$KC/realms/corp/.well-known/openid-configuration" --wrong-verifier)
echo "$D" | grep -q '\[通过\] 错误的 code_verifier 被拒绝'; res "Desktop：错误的 code_verifier 被拒绝" $?

# 3. 对照：直连模拟 E10（联调测试 B）
D=$("$T/run-pkce.sh" cloud-direct --base "$E10" --client-id "$(out "$MOCK_STACK" DirectClientId)" \
     --discovery "$(out "$MOCK_STACK" DiscoveryUrl)" --expect-email "$EMAIL")
echo "$D" > "$T/out/cloud-direct.txt"
echo "$D" | grep -q '不带 client_secret 拿不到 id_token'; res "对照：Desktop 直连 E10 不带密钥失败（符合预期，所以需要桥接）" $?
D=$("$T/run-pkce.sh" cloud-direct-secret --base "$E10" --client-id "$(out "$MOCK_STACK" DirectClientId)" \
     --discovery "$(out "$MOCK_STACK" DiscoveryUrl)" --expect-email "$EMAIL" --client-secret "$DIRECT_SECRET")
echo "$D" > "$T/out/cloud-direct-secret.txt"
echo "$D" | grep -q '\[通过\] ID token 签名能用 JWKS 公钥验证'; res "对照：带密钥直连 E10，id_token 能用 E10 JWKS 验签" $?
echo "$D" | grep -q '\[不通过\] 端点均为 HTTPS'; res "对照：E10 是 http，脚本判定不能直接配给 Quick Desktop" $?

# 4. Web（SAML）：临时登记模拟 SP
FIX="$ROOT/mock/fixtures/iam-identity-center-sp-metadata.xml"
FIX_ID=$(python3 -c "import re,sys;print(re.search(r'entityID=\"([^\"]+)\"',open(sys.argv[1]).read()).group(1))" "$FIX")
"$AWS_DIR/register-idc-sp.sh" --no-persist "$FIX" > "$T/out/cloud-register-sp.txt" 2>&1 || cat "$T/out/cloud-register-sp.txt"
W=$(node "$T/saml-sp-test.js" "$LOGIN" "$PW" "$EMAIL" cloud-saml); RC=$?
echo "$W" > "$T/out/cloud-saml.txt"
res "Web：SAML 断言满足 IAM Identity Center 要求（NameID=$EMAIL、验签、未加密）" $RC "$(echo "$W" | grep '不通过' | head -3 | tr '\n' ' ')"
"$AWS_DIR/register-idc-sp.sh" --delete "$FIX_ID" > /dev/null 2>&1 && echo "  （已删除临时 SAML 客户端 $FIX_ID）"

# 5. 公网安全
c() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
[ "$(c "$KC/admin/")" = 403 ] && [ "$(c "$KC/admin/master/console/")" = 403 ]; res "公网访问 /admin 被拒绝（403）" $?
[ "$(c "$KC/realms/master/.well-known/openid-configuration")" = 403 ]; res "公网访问 master realm 被拒绝（403）" $?
[ "$(c "$E10/__mock/config")" = 403 ]; res "模拟 E10 管理接口无令牌被拒绝（403）" $?
TOKEN=$(echo "$SJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["admin_token"])')
[ "$(c -H "X-Mock-Token: $TOKEN" "$E10/__mock/config")" = 403 ]; res "模拟 E10 管理接口从公网带正确令牌也被拒绝（只接受本机）" $?
PORT=$(aws cloudformation describe-stacks --stack-name "$MOCK_STACK" --query "Stacks[0].Parameters[?ParameterKey=='E10Port'].ParameterValue" --output text)
case "$E10" in "http://"*":$PORT") R=0 ;; *) R=1 ;; esac; res "模拟 E10 是 http + 栈参数 E10Port 指定的端口（$E10）" $R
[ "$(c "http://${KC#https://}/realms/corp/.well-known/openid-configuration")" = 301 ]; res "Keycloak 的 http 访问被重定向到 https" $?
AUTHQ="$KC/realms/corp/protocol/openid-connect/auth?client_id=amazon-quick-desktop&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A18080&scope=openid&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"
CK=$(curl -s -o /dev/null -D - "$AUTHQ" | grep -i '^set-cookie: AUTH_SESSION_ID')
echo "$CK" | grep -q 'Secure' && echo "$CK" | grep -q 'SameSite=None'; res "Keycloak 登录 cookie 带 Secure; SameSite=None（Keycloak 识别出 HTTPS）" $?
CK=$(curl -s -o /dev/null -D - -H 'Forwarded: for=1.2.3.4;proto=http' "$AUTHQ" | grep -i '^set-cookie: AUTH_SESSION_ID')
echo "$CK" | grep -q 'Secure'; res "用户伪造的 Forwarded 头被 CloudFront 覆盖" $?

echo; echo "合计：通过 $PASS，不通过 $FAIL（详细输出在 mock/tests/out/cloud-*）"
[ $FAIL -eq 0 ]
