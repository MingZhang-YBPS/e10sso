#!/bin/bash
# 用法：run-pkce.sh <标签> <e10-oidc-pkce-test.py 的参数...>
# 后台运行 PKCE 测试脚本，抓到授权地址后用无头浏览器自动登录，最后输出脚本结果。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="$1"; shift
OUT="$HERE/out/pkce-$LABEL.txt"
mkdir -p "$HERE/out"
PYTHONUNBUFFERED=1 BROWSER=true python3 "$HERE/../../../e10-oidc-pkce-test.py" "$@" > "$OUT" 2>&1 &
PID=$!
URL=""
for _ in $(seq 1 50); do
  URL=$(grep -oE 'https?://[^ ]*/(authorize|auth)\?[^ ]*' "$OUT" | head -1)
  [ -n "$URL" ] && break
  sleep 0.2
done
if [ -z "$URL" ]; then echo "未拿到授权地址"; cat "$OUT"; kill $PID 2>/dev/null; exit 1; fi
node "$HERE/autologin.js" "$URL" "http://localhost:18080" "${E10_USER:-zhangsan}" "${E10_PASS:-Passw0rd!}" "pkce-$LABEL" > "$HERE/out/pkce-$LABEL-browser.json"
BR=$?
for _ in $(seq 1 300); do kill -0 $PID 2>/dev/null || break; sleep 0.2; done   # 最多等 60 秒（验签、刷新都要访问网络）
kill $PID 2>/dev/null
if [ $BR -ne 0 ]; then echo "浏览器未完成登录：$(cat "$HERE/out/pkce-$LABEL-browser.json")"; fi
cat "$OUT"
