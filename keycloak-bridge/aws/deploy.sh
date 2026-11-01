#!/bin/bash
# 部署 Keycloak 桥接并对接客户的 E10（CloudFormation 栈 <PREFIX>-keycloak）。不部署模拟 E10。
#
# 用法：
#   E10_BASE_URL=http://oa.example.com:20600 \
#   E10_CLIENT_ID=<E10 认证应用的应用标识> \
#   [E10_DISCOVERY_URL=<E10 OIDC 服务发现地址>]   # 默认 {E10_BASE_URL}/papi/sso/oidc/.well-known/openid-configuration
#   aws/deploy.sh
#
#   E10 应用密钥：环境变量 E10_CLIENT_SECRET；没设置时会提示输入（不回显，不进命令历史）。
#   可选：E10_ISSUER（不填则取自服务发现，再不行用 E10_BASE_URL 本身）、E10_SCOPES（默认 openid email profile）、
#         EMAIL_FROM（email|sub）、NONCE_MODE（disable|send）、KC_INSTANCE_TYPE（默认 t4g.medium）、
#         REGION、PREFIX（栈名前缀，默认 e10sso）、DISABLE_ROLLBACK=1（失败时保留实例便于排查）
#   栈已存在时再次执行 = 用新参数更新，并在实例上重新应用 Keycloak 配置（实例不重建）。
source "$(dirname "$0")/common.sh"

# ---------- 参数 ----------
: "${E10_BASE_URL:?请设置 E10_BASE_URL，例如 http://oa.example.com:20600}"
: "${E10_CLIENT_ID:?请设置 E10_CLIENT_ID（E10 认证应用的应用标识）}"
E10_BASE_URL="${E10_BASE_URL%/}"
[[ "$E10_BASE_URL" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || { echo "E10_BASE_URL 格式不对：只写协议、地址和端口，不带路径"; exit 1; }
E10_DISCOVERY_URL="${E10_DISCOVERY_URL:-$E10_BASE_URL/papi/sso/oidc/.well-known/openid-configuration}"
if [ -z "${E10_CLIENT_SECRET:-}" ]; then
  read -r -s -p "E10 应用密钥（输入不回显）：" E10_CLIENT_SECRET; echo
  [ -n "$E10_CLIENT_SECRET" ] || { echo "应用密钥不能为空"; exit 1; }
fi

# ---------- 部署前检查（在本机访问 E10 服务发现）----------
echo "== 部署前检查 E10"
if [ -n "${E10_DISCOVERY_URL:-}" ]; then
  if D=$(curl -sS --max-time 15 "$E10_DISCOVERY_URL" 2>&1) && echo "$D" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null; then
    CHECK=$(echo "$D" | python3 -c '
import sys, json
base, iss_env = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)
print("ISSUER=" + d.get("issuer", ""))
expect = {"authorization_endpoint": "/papi/sso/oidc/authorize", "token_endpoint": "/papi/sso/oidc/accessToken",
          "jwks_uri": "/papi/sso/oidc/jwks"}
for k, p in expect.items():
    v = d.get(k, "")
    mark = "一致" if v == base + p else "不一致（Keycloak 按 E10 文档路径 " + base + p + " 调用，请核对）"
    print("  %-22s %s  %s" % (k, v or "(未声明)", mark))
if iss_env and d.get("issuer") and iss_env != d["issuer"]:
    print("  警告：E10_ISSUER=%s 与服务发现的 issuer=%s 不一致，以服务发现为准更稳妥" % (iss_env, d["issuer"]))
' "$E10_BASE_URL" "${E10_ISSUER:-}")
    DISC_ISSUER=$(echo "$CHECK" | sed -n 's/^ISSUER=//p')
    echo "$CHECK" | grep -v '^ISSUER='
    if [ -z "${E10_ISSUER:-}" ] && [ -n "$DISC_ISSUER" ]; then E10_ISSUER="$DISC_ISSUER"; fi
    echo "  issuer                 ${E10_ISSUER:-（未取到）}"
  else
    echo "  本机取不到服务发现 $E10_DISCOVERY_URL（${D:0:200}）。issuer 使用 ${E10_ISSUER:-默认值 $E10_BASE_URL}，继续部署，部署后会从 AWS 侧再检查一次"
  fi
else
  echo "  未提供 E10_DISCOVERY_URL：issuer 使用 ${E10_ISSUER:-默认值 $E10_BASE_URL}"
fi

# ---------- 部署 ----------
BUCKET=$(bucket_name)
ensure_bucket "$BUCKET"
aws s3 cp --only-show-errors "$ROOT/setup-keycloak.py" "s3://$BUCKET/$ARTIFACT_PREFIX/keycloak/setup-keycloak.py"
PL=$(aws ec2 describe-managed-prefix-lists \
      --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
      --query 'PrefixLists[0].PrefixListId' --output text)
EXISTED=false; stack_exists "$KC_STACK" && EXISTED=true
ROLLBACK=(); [ "${DISABLE_ROLLBACK:-}" = 1 ] && ROLLBACK=(--disable-rollback)

echo "== 部署 $KC_STACK（账号 $(account_id)，区域 $REGION），对接 E10：$E10_BASE_URL（新建约 10～15 分钟）"
aws cloudformation deploy --stack-name "$KC_STACK" --template-file "$AWS_DIR/keycloak-bridge.yaml" \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset --tags project=e10sso "${ROLLBACK[@]}" \
  --parameter-overrides ArtifactBucket="$BUCKET" CloudFrontPrefixListId="$PL" AmiId="$(ami_for "$KC_STACK")" \
    E10BaseUrl="$E10_BASE_URL" E10ClientId="$E10_CLIENT_ID" E10ClientSecret="$E10_CLIENT_SECRET" \
    E10Issuer="${E10_ISSUER:-}" E10Scopes="${E10_SCOPES:-openid email profile}" \
    EmailFrom="${EMAIL_FROM:-email}" NonceMode="${NONCE_MODE:-disable}" \
    InstanceType="${KC_INSTANCE_TYPE:-t4g.medium}"
IID=$(out "$KC_STACK" InstanceId)
if $EXISTED; then
  # 栈更新只改了 SSM 参数 / Secrets Manager，Keycloak 里的配置要在实例上重新应用一次
  echo "== 栈已存在：按新参数重新配置 Keycloak"
  "$AWS_DIR/register-idc-sp.sh" --reconfigure | grep -E '已|注意' || true
fi

# ---------- 部署后检查（在 Keycloak 实例上访问 E10，也就是真正的访问来源）----------
echo "== 从 Keycloak 实例检查 E10 连通性"
if R=$(run_on "$IID" "e10sso check e10" \
     "curl -sS --max-time 10 '$E10_BASE_URL/papi/sso/oidc/jwks' | jq -r '\"JWKS 公钥数量：\" + ((.keys // []) | length | tostring)'" 2>&1) \
   && echo "$R" | grep -qE 'JWKS 公钥数量：[1-9]'; then
  echo "  可以访问 E10，$R"
else
  echo "  访问 E10 的 JWKS 失败：$(echo "$R" | tr '\n' ' ' | cut -c1-200)"
  echo "  如果客户按来源 IP 限制 E10 端口，请放行 Keycloak 出口 IP：$(out "$KC_STACK" OutboundIp)"
fi

REDIRECT=$(out "$KC_STACK" E10RedirectUri)
KC=$(out "$KC_STACK" KeycloakUrl)
if [ "${E10_IS_MOCK:-}" = 1 ]; then
  echo "== 下一步：模拟 E10 的回调地址由 mock/deploy-mock.sh 自动登记"
else
  cat <<EOF

== 下一步（Keycloak 侧已自动配置好，E10 侧需要客户操作）
1. 在 E10 认证应用（应用标识 $E10_CLIENT_ID）的「业务系统 URL 地址」里填写：
     $REDIRECT
2. 如果客户按来源 IP 限制 E10 端口，放行 Keycloak 出口 IP：$(out "$KC_STACK" OutboundIp)
3. 验证（浏览器里用 E10 测试账号登录）：
     python3 $(cd "$ROOT/.." && pwd)/e10-oidc-pkce-test.py --base $KC --client-id amazon-quick-desktop \\
       --discovery $KC/realms/corp/.well-known/openid-configuration --expect-email <该人员在 Quick 里的邮箱>
EOF
fi
"$AWS_DIR/info.sh"
