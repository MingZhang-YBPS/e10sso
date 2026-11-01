#!/bin/bash
# 【仅测试用】把本机的模拟 E10 代码（mock/mock-e10/server.js）更新到云上实例，有变化才重启容器。
# 模拟 E10 栈的 UserData 只在实例首次启动时执行，改了 server.js 之后用这个脚本同步，不用重建实例。
source "$(dirname "$0")/../aws/common.sh"
BUCKET=$(bucket_name)
aws s3 cp --only-show-errors "$ROOT/mock/mock-e10/server.js" "s3://$BUCKET/$ARTIFACT_PREFIX/mock-e10/server.js"
run_on "$(out "$MOCK_STACK" InstanceId)" "e10sso update mock code" \
  "aws s3 cp --region $REGION --only-show-errors s3://$BUCKET/$ARTIFACT_PREFIX/mock-e10/server.js /opt/mock-e10/server.js.new" \
  "if ! cmp -s /opt/mock-e10/server.js.new /opt/mock-e10/server.js; then mv /opt/mock-e10/server.js.new /opt/mock-e10/server.js; docker restart mock-e10 > /dev/null; echo '模拟 E10 代码已更新并重启'; else rm -f /opt/mock-e10/server.js.new; echo '模拟 E10 代码没有变化'; fi" \
  ". /opt/mock-e10/env; for i in \$(seq 1 20); do curl -sf -o /dev/null http://127.0.0.1:\$PORT/ && break; sleep 1; done"
