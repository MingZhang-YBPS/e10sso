#!/bin/bash
# 查看 Keycloak 最近的告警和错误（排查登录失败用）。用法：aws/logs.sh [最近几分钟，默认 15]
source "$(dirname "$0")/common.sh"
M="${1:-15}"
[[ "$M" =~ ^[0-9]+$ ]] || { echo "用法：aws/logs.sh [分钟数]"; exit 1; }
IID=$(out "$KC_STACK" InstanceId)
run_on "$IID" "e10sso logs" \
  "docker logs --since ${M}m keycloak 2>&1 | grep -E 'WARN|ERROR' | grep -vE 'hostname|Hostname' | tail -20 | cut -c1-400; echo '（以上为最近 ${M} 分钟的告警/错误，没有内容表示没有报错）'"
