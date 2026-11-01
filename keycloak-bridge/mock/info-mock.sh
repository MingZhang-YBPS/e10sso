#!/bin/bash
# 【仅测试用】打印模拟 E10 的信息。加 --secrets 显示测试人员密码等。
source "$(dirname "$0")/../aws/common.sh"
SHOW_SECRETS=false; [ "${1:-}" = --secrets ] && SHOW_SECRETS=true
stack_exists "$MOCK_STACK" || { echo "没有找到栈 $MOCK_STACK（区域 $REGION）"; exit 1; }
echo "
================ 模拟 E10（$MOCK_STACK，仅测试用） ================
  地址             $(out "$MOCK_STACK" E10BaseUrl)    （http，端口由栈参数 E10Port 决定，固定 IP $(out "$MOCK_STACK" PublicIp)）
  服务发现         $(out "$MOCK_STACK" DiscoveryUrl)
  Keycloak 用的应用 $(out "$MOCK_STACK" BrokerClientId)
  测试人员         $(out "$MOCK_STACK" TestLoginId) <$(out "$MOCK_STACK" TestUserEmail)>
  其他人员         zhangsan / lisi（不在共享范围）/ wangwu（未维护邮箱），密码同测试人员
  直连测试应用     $(out "$MOCK_STACK" DirectClientId)（对应联调测试 B）"
if $SHOW_SECRETS; then
  secret_json "$(out "$MOCK_STACK" SecretArn)" | python3 -c '
import sys,json;s=json.load(sys.stdin)
print("  人员密码        ", s["user_password"]); print("  直连应用密钥    ", s["direct_client_secret"])'
else
  echo "  （密码：mock/info-mock.sh --secrets）"
fi
stack_exists "$KC_STACK" && "$AWS_DIR/info.sh" "$@"
