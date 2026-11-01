#!/bin/bash
# 【仅测试用】删除模拟 E10 栈。Keycloak 栈用 aws/destroy.sh 删除。
source "$(dirname "$0")/../aws/common.sh"
read -r -p "将删除 $MOCK_STACK（区域 $REGION，账号 $(account_id)）。输入 yes 确认：" ans
[ "$ans" = yes ] || { echo "已取消"; exit 1; }
if stack_exists "$MOCK_STACK"; then
  aws cloudformation delete-stack --stack-name "$MOCK_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$MOCK_STACK"
  echo "已删除 $MOCK_STACK"
fi
stack_exists "$KC_STACK" && echo "注意：$KC_STACK 还在，它对接的是已删除的模拟 E10，需要时用 aws/deploy.sh 改为对接真实 E10，或用 aws/destroy.sh 删除"
true
