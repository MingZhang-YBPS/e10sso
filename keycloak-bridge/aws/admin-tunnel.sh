#!/bin/bash
# 通过 SSM 端口转发访问 Keycloak 管理控制台（控制台不对公网开放）。
# 运行后浏览器打开 http://localhost:9080/admin ，账号 admin，密码见 aws/info.sh --secrets。按 Ctrl+C 结束。
# 需要本机安装 session-manager-plugin。
source "$(dirname "$0")/common.sh"
IID=$(out "$KC_STACK" InstanceId)
echo "转发 localhost:9080 → $IID:9080，打开 http://localhost:9080/admin"
exec aws ssm start-session --target "$IID" --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9080"],"localPortNumber":["9080"]}'
