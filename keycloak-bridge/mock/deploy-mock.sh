#!/bin/bash
# 【仅测试用】部署模拟 E10（栈 <PREFIX>-mock-e10），并让 Keycloak 桥接对接它。到客户那里不需要这个脚本，用 aws/deploy.sh。
#
# 用法：
#   TEST_USER_EMAIL=<Quick 里已有用户的邮箱> mock/deploy-mock.sh        # 模拟 E10 + Keycloak（对接模拟 E10）
#   TEST_USER_EMAIL=... mock/deploy-mock.sh mock                         # 只部署/更新模拟 E10
# 模拟 E10 按客户实际情况：公网 http + 指定端口。可选：MOCK_E10_PORT（默认用模板参数 E10Port 的默认值 20600）、REGION、PREFIX（默认 e10sso）
source "$(dirname "$0")/../aws/common.sh"
MOCK_DIR="$ROOT/mock"
WHAT="${1:-all}"
: "${TEST_USER_EMAIL:?请设置 TEST_USER_EMAIL（Quick 里已有用户的邮箱）}"

BUCKET=$(bucket_name)
ensure_bucket "$BUCKET"
for f in server.js config.json make-cloud-config.py; do
  aws s3 cp --only-show-errors "$MOCK_DIR/mock-e10/$f" "s3://$BUCKET/$ARTIFACT_PREFIX/mock-e10/$f"
done
echo "== 部署 $MOCK_STACK（约 3～5 分钟）"
MOCK_EXISTED=false; stack_exists "$MOCK_STACK" && MOCK_EXISTED=true
aws cloudformation deploy --stack-name "$MOCK_STACK" --template-file "$MOCK_DIR/mock-e10.yaml" \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset --tags project=e10sso \
  --parameter-overrides ArtifactBucket="$BUCKET" TestUserEmail="$TEST_USER_EMAIL" AmiId="$(ami_for "$MOCK_STACK")" \
    ${MOCK_E10_PORT:+E10Port="$MOCK_E10_PORT"}
# 栈已存在时实例不会重跑 UserData，把最新的模拟 E10 代码同步到实例上
$MOCK_EXISTED && "$MOCK_DIR/update-mock.sh"

if [ "$WHAT" = all ]; then
  # 用模拟 E10 的信息部署 Keycloak（和对接真实 E10 用的是同一个 aws/deploy.sh）
  SJ=$(secret_json "$(out "$MOCK_STACK" SecretArn)")
  E10_BASE_URL=$(out "$MOCK_STACK" E10BaseUrl) \
  E10_CLIENT_ID=$(out "$MOCK_STACK" BrokerClientId) \
  E10_CLIENT_SECRET=$(echo "$SJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["broker_client_secret"])') \
  E10_DISCOVERY_URL=$(out "$MOCK_STACK" DiscoveryUrl) \
  E10_IS_MOCK=1 "$AWS_DIR/deploy.sh"

  # 替 E10 管理员在认证应用里填"业务系统 URL 地址"（模拟 E10 的管理接口只接受本机请求，经 SSM 调用）
  REDIRECT=$(out "$KC_STACK" E10RedirectUri)
  BODY="{\"client_id\":\"$(out "$MOCK_STACK" BrokerClientId)\",\"business_urls\":[\"$REDIRECT\"]}"
  run_on "$(out "$MOCK_STACK" InstanceId)" "e10sso register keycloak redirect" \
    ". /opt/mock-e10/env && curl -sf -X POST http://127.0.0.1:\$PORT/__mock/apps -H \"X-Mock-Token: \$MOCK_ADMIN_TOKEN\" -H 'Content-Type: application/json' -d '$BODY' > /dev/null" > /dev/null
  echo "已在模拟 E10 的认证应用里登记业务系统 URL：$REDIRECT"
fi
"$MOCK_DIR/info-mock.sh"
