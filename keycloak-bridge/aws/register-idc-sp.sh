#!/bin/bash
# 把 IAM Identity Center 的 SP 元数据登记到云上 Keycloak（创建/更新 SAML 客户端）。
# 用法：
#   aws/register-idc-sp.sh <从 IAM Identity Center 下载的 SP 元数据.xml>   # 登记，并保存到 SSM 参数（实例重建后自动重新登记）
#   aws/register-idc-sp.sh --no-persist <SP 元数据.xml>                        # 只登记，不保存（临时测试用）
#   aws/register-idc-sp.sh --delete <SAML 客户端 ID（= SP entityID）>         # 删除；如果是已保存的那个，同时删除 SSM 参数
#   aws/register-idc-sp.sh --reconfigure                                        # 按最新的 setup-keycloak.py 和栈参数重新配置（已保存的 SP 会重新登记）
source "$(dirname "$0")/common.sh"
IID=$(out "$KC_STACK" InstanceId)
PARAM="/e10sso/$KC_STACK/idc-sp-metadata"
BUCKET_CMD="aws s3 cp --region $REGION --only-show-errors s3://$(bucket_name)/$ARTIFACT_PREFIX/keycloak/setup-keycloak.py /opt/kc/setup-keycloak.py"
entity_of() { python3 -c "import re,sys;m=re.search(r'entityID=\"([^\"]+)\"',sys.stdin.read());print(m.group(1) if m else '')"; }

PERSIST=true
[ "${1:-}" = --no-persist ] && { PERSIST=false; shift; }

case "${1:-}" in
  --delete)
    : "${2:?缺少客户端 ID}"
    run_on "$IID" "e10sso delete saml client" "/opt/kc/configure.sh none --delete-client '$2'"
    SAVED=$(aws ssm get-parameter --name "$PARAM" --query Parameter.Value --output text 2>/dev/null | entity_of || true)
    if [ -n "$SAVED" ] && [ "$SAVED" = "$2" ]; then
      aws ssm delete-parameter --name "$PARAM" && echo "已删除保存的 SP 元数据（$PARAM）"
    fi ;;
  --reconfigure)
    run_on "$IID" "e10sso reconfigure" "$BUCKET_CMD" "/opt/kc/configure.sh none" ;;
  ""|-h|--help)
    sed -n '2,7p' "$0"; exit 1 ;;
  *)
    F="$1"; [ -f "$F" ] || { echo "文件不存在：$F"; exit 1; }
    grep -q 'SPSSODescriptor' "$F" || { echo "$F 不是 SAML SP 元数据"; exit 1; }
    [ "$(wc -c < "$F")" -lt 30000 ] || { echo "元数据文件过大"; exit 1; }
    B64=$(base64 -w0 "$F")
    run_on "$IID" "e10sso register idc sp" \
      "echo '$B64' | base64 -d > /opt/kc/sp-metadata.xml" "$BUCKET_CMD" "/opt/kc/configure.sh /opt/kc/sp-metadata.xml"
    if $PERSIST; then
      aws ssm put-parameter --name "$PARAM" --type String --tier Intelligent-Tiering --overwrite \
        --description "IAM Identity Center SP metadata for $KC_STACK" --value "file://$F" > /dev/null
      echo "已保存 SP 元数据到 SSM 参数 $PARAM（实例重建后自动重新登记）"
    fi ;;
esac
