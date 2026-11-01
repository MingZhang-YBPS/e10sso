# shellcheck shell=bash
# 公共变量和函数，由 aws/*.sh 和 mock/*.sh 引用
set -euo pipefail
AWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$AWS_DIR/.." && pwd)"
REGION="${REGION:-$(aws configure get region || true)}"
REGION="${REGION:-ap-northeast-1}"
export AWS_DEFAULT_REGION="$REGION"
PREFIX="${PREFIX:-e10sso}"
KC_STACK="$PREFIX-keycloak"
MOCK_STACK="$PREFIX-mock-e10"          # 只有 mock/ 下的测试脚本用
ARTIFACT_PREFIX=e10sso                 # 代码桶里的路径前缀（模板参数 ArtifactPrefix 的默认值）

out() { # 栈名 输出名
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}
stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" > /dev/null 2>&1
}
secret_json() { # SecretArn
  aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text
}
account_id() {
  aws sts get-caller-identity --query Account --output text
}
bucket_name() {
  echo "${ARTIFACT_BUCKET:-$PREFIX-artifacts-$(account_id)-$REGION}"
}
# 代码桶不存在就创建（私有）
ensure_bucket() { # 桶名
  if ! aws s3api head-bucket --bucket "$1" > /dev/null 2>&1; then
    if [ "$REGION" = us-east-1 ]; then aws s3api create-bucket --bucket "$1" > /dev/null
    else aws s3api create-bucket --bucket "$1" --create-bucket-configuration "LocationConstraint=$REGION" > /dev/null; fi
    aws s3api put-public-access-block --bucket "$1" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    echo "已创建私有桶 $1"
  fi
}
# AMI：新建栈取最新的 AL2023 arm64；更新栈沿用当前实例的 AMI（换 AMI 会替换实例，数据会丢）
ami_for() { # 栈名
  local iid
  if stack_exists "$1" && iid=$(out "$1" InstanceId) && [ -n "$iid" ] && [ "$iid" != None ]; then
    aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].ImageId' --output text
  else
    aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
      --query Parameter.Value --output text
  fi
}
# 在实例上执行命令并等待结果。用法：run_on 实例ID 说明 命令1 [命令2 ...]
run_on() {
  local iid="$1" comment="$2"; shift 2
  local params; params=$(mktemp)
  python3 - "$@" > "$params" <<'PY'
import json, sys
print(json.dumps({"commands": sys.argv[1:], "executionTimeout": ["600"]}))
PY
  local cid
  cid=$(aws ssm send-command --instance-ids "$iid" --document-name AWS-RunShellScript \
        --comment "$comment" --parameters "file://$params" --query Command.CommandId --output text)
  rm -f "$params"
  local st=Pending
  for _ in $(seq 1 120); do
    st=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query Status --output text 2>/dev/null || echo Pending)
    case "$st" in Pending|InProgress|Delayed) sleep 3 ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query StandardOutputContent --output text
  local err; err=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query StandardErrorContent --output text)
  [ -n "$err" ] && [ "$err" != "None" ] && echo "$err" >&2
  [ "$st" = "Success" ]
}
