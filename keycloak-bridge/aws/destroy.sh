#!/bin/bash
# 删除 Keycloak 桥接栈。用法：aws/destroy.sh [--purge-bucket]
#   --purge-bucket：同时清空并删除代码桶（同前缀的模拟 E10 栈还在时不删桶）
# 注意：Keycloak 的 PostgreSQL 数据在实例磁盘上，删除栈后无法恢复。模拟 E10 用 mock/destroy-mock.sh 删除。
source "$(dirname "$0")/common.sh"
BUCKET=$(bucket_name)
read -r -p "将删除 $KC_STACK（区域 $REGION，账号 $(account_id)）。输入 yes 确认：" ans
[ "$ans" = yes ] || { echo "已取消"; exit 1; }
if stack_exists "$KC_STACK"; then
  echo "删除 $KC_STACK ..."
  aws cloudformation delete-stack --stack-name "$KC_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$KC_STACK"
fi
# register-idc-sp.sh 保存的 SP 元数据不在栈里，单独删除
aws ssm delete-parameter --name "/e10sso/$KC_STACK/idc-sp-metadata" > /dev/null 2>&1 && echo "已删除 SSM 参数 /e10sso/$KC_STACK/idc-sp-metadata" || true
if [ "${1:-}" = --purge-bucket ]; then
  if stack_exists "$MOCK_STACK"; then
    echo "模拟 E10 栈 $MOCK_STACK 还在，暂不删除代码桶"
  elif aws s3api head-bucket --bucket "$BUCKET" > /dev/null 2>&1; then
    aws s3 rm --recursive --only-show-errors "s3://$BUCKET" && aws s3api delete-bucket --bucket "$BUCKET"
    echo "已删除桶 $BUCKET"
  fi
fi
echo "完成。记得在 Quick 里删除 Extension access，在 E10 里停用对应的认证应用。"
