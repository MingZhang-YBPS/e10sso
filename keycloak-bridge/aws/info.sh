#!/bin/bash
# 打印 Keycloak 桥接的对接信息。加 --secrets 同时打印 Keycloak 管理员密码。
source "$(dirname "$0")/common.sh"
SHOW_SECRETS=false; [ "${1:-}" = --secrets ] && SHOW_SECRETS=true
stack_exists "$KC_STACK" || { echo "没有找到栈 $KC_STACK（区域 $REGION）"; exit 1; }
CFG=$(aws ssm get-parameter --name "/e10sso/$KC_STACK/e10-config" --query Parameter.Value --output text 2>/dev/null || echo '{}')
echo "
================ Keycloak 桥接（$KC_STACK，区域 $REGION） ================
[对接的 E10]
  $(echo "$CFG" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("地址 %s，应用标识 %s，issuer %s" % (d.get("base"), d.get("client_id"), d.get("issuer") or "(默认等于地址)"))')
[E10 → 认证应用 → 业务系统 URL 地址]
  $(out "$KC_STACK" E10RedirectUri)
[Quick Desktop → Manage account → Permissions → Extension access]
  Issuer URL             $(out "$KC_STACK" DesktopIssuer)
  Authorization endpoint $(out "$KC_STACK" DesktopAuthorizationEndpoint)
  Token endpoint         $(out "$KC_STACK" DesktopTokenEndpoint)
  JWKS URI               $(out "$KC_STACK" DesktopJwksUri)
  Client ID              $(out "$KC_STACK" DesktopClientId)
[IAM Identity Center → 外部身份提供商 → IdP 元数据]
  $(out "$KC_STACK" SamlIdpMetadataUrl)
[运维]
  实例           $(out "$KC_STACK" InstanceId)（访问 E10 的出口 IP：$(out "$KC_STACK" OutboundIp)）
  管理控制台     aws/admin-tunnel.sh 后打开 http://localhost:9080/admin"
if $SHOW_SECRETS; then
  echo "  管理员         admin / $(secret_json "$(out "$KC_STACK" KcSecretArn)" | python3 -c 'import sys,json;print(json.load(sys.stdin)["admin_password"])')"
fi
