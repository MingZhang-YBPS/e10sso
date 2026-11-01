#!/bin/bash
# 【仅测试用】在云上的模拟 E10 里新增（或更新）一个人员，并加入所有认证应用的共享范围。
# 用法：mock/add-user.sh <登录名> <邮箱> [姓名]
#   密码和其他测试人员相同（mock/info-mock.sh --secrets 查看）。
#   数据存在实例的 /opt/mock-e10/data/users-extra.json，容器重启后仍在；模拟 E10 栈重建后需要重新添加。
source "$(dirname "$0")/../aws/common.sh"
LOGIN="${1:?用法：mock/add-user.sh <登录名> <邮箱> [姓名]}"
EMAIL="${2:?用法：mock/add-user.sh <登录名> <邮箱> [姓名]}"
NAME="${3:-$LOGIN}"
BODY=$(python3 -c 'import json,sys;print(json.dumps({"loginid":sys.argv[1],"email":sys.argv[2],"name":sys.argv[3]},ensure_ascii=False))' "$LOGIN" "$EMAIL" "$NAME")
BUCKET=$(bucket_name)
# 先把实例上的模拟 E10 代码更新到最新（新增人员的接口是后加的），再调用管理接口
aws s3 cp --only-show-errors "$ROOT/mock/mock-e10/server.js" "s3://$BUCKET/$ARTIFACT_PREFIX/mock-e10/server.js"
B64=$(printf '%s' "$BODY" | base64 -w0)
run_on "$(out "$MOCK_STACK" InstanceId)" "e10sso add mock user" \
  "aws s3 cp --region $REGION --only-show-errors s3://$BUCKET/$ARTIFACT_PREFIX/mock-e10/server.js /opt/mock-e10/server.js.new" \
  "if ! cmp -s /opt/mock-e10/server.js.new /opt/mock-e10/server.js; then mv /opt/mock-e10/server.js.new /opt/mock-e10/server.js; docker restart mock-e10 > /dev/null; echo '模拟 E10 代码已更新并重启'; else rm -f /opt/mock-e10/server.js.new; fi" \
  ". /opt/mock-e10/env; for i in \$(seq 1 20); do curl -sf -o /dev/null http://127.0.0.1:\$PORT/ && break; sleep 1; done" \
  ". /opt/mock-e10/env; echo '$B64' | base64 -d | curl -sf -X POST http://127.0.0.1:\$PORT/__mock/users -H \"X-Mock-Token: \$MOCK_ADMIN_TOKEN\" -H 'Content-Type: application/json' --data-binary @- | jq -r '.[] | \"  \\(.loginid)\\t\\(.email)\\t共享范围：\\(.share|length) 个应用\"'"
