#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STACK_NAME="${STACK_NAME:-MinecraftStack}"
PROFILE="${PROFILE:-minecraft-prod}"
REGION="${REGION:-us-west-2}"
OUTPUTS_FILE="${OUTPUTS_FILE:-${ROOT_DIR}/minecraft-outputs.json}"
INSTANCE_ID="${INSTANCE_ID:-}"

usage_common() {
  cat <<'EOF'
Options:
  --instance-id <id>       EC2 instance ID. Overrides stack/output lookup.
  --stack <name>           CloudFormation stack name. Default: MinecraftStack
  --profile <name>         AWS CLI profile. Default: minecraft-prod
  --region <region>        AWS region. Default: us-west-2
  --outputs-file <path>    CDK outputs JSON file. Default: ./minecraft-outputs.json
  --help                   Show help
EOF
}

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --instance-id)
        INSTANCE_ID="${2:-}"
        [[ -n "${INSTANCE_ID}" ]] || { echo "--instance-id requires a value" >&2; exit 1; }
        shift 2
        ;;
      --stack)
        STACK_NAME="${2:-}"
        [[ -n "${STACK_NAME}" ]] || { echo "--stack requires a value" >&2; exit 1; }
        shift 2
        ;;
      --profile)
        PROFILE="${2:-}"
        [[ -n "${PROFILE}" ]] || { echo "--profile requires a value" >&2; exit 1; }
        shift 2
        ;;
      --region)
        REGION="${2:-}"
        [[ -n "${REGION}" ]] || { echo "--region requires a value" >&2; exit 1; }
        shift 2
        ;;
      --outputs-file)
        OUTPUTS_FILE="${2:-}"
        [[ -n "${OUTPUTS_FILE}" ]] || { echo "--outputs-file requires a value" >&2; exit 1; }
        shift 2
        ;;
      --help)
        return 2
        ;;
      *)
        echo "Unknown argument: $1" >&2
        return 1
        ;;
    esac
  done
}

require_commands() {
  local cmd
  for cmd in aws python3; do
    command -v "${cmd}" >/dev/null 2>&1 || {
      echo "Required command not found: ${cmd}" >&2
      exit 1
    }
  done
}

aws_cli() {
  aws --profile "${PROFILE}" --region "${REGION}" --no-cli-pager "$@"
}

load_output_value() {
  local output_key="$1"

  [[ -f "${OUTPUTS_FILE}" ]] || return 1

  python3 - "${OUTPUTS_FILE}" "${STACK_NAME}" "${output_key}" <<'PY'
import json
import sys

outputs_file, stack_name, output_key = sys.argv[1:4]
with open(outputs_file, "r", encoding="utf-8") as fh:
    data = json.load(fh)

stack_outputs = data.get(stack_name, {})
value = stack_outputs.get(output_key)
if isinstance(value, str) and value:
    print(value)
    sys.exit(0)
sys.exit(1)
PY
}

resolve_instance_id() {
  if [[ -n "${INSTANCE_ID}" ]]; then
    printf '%s\n' "${INSTANCE_ID}"
    return 0
  fi

  if INSTANCE_ID="$(load_output_value "InstanceId" 2>/dev/null)"; then
    printf '%s\n' "${INSTANCE_ID}"
    return 0
  fi

  INSTANCE_ID="$(
    aws_cli cloudformation describe-stacks \
      --stack-name "${STACK_NAME}" \
      --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue | [0]" \
      --output text
  )"

  if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
    echo "Could not determine InstanceId from --instance-id, ${OUTPUTS_FILE}, or stack ${STACK_NAME}." >&2
    exit 1
  fi

  printf '%s\n' "${INSTANCE_ID}"
}

stack_output_or_empty() {
  local output_key="$1"
  local value=""

  if value="$(load_output_value "${output_key}" 2>/dev/null)"; then
    printf '%s\n' "${value}"
    return 0
  fi

  value="$(
    aws_cli cloudformation describe-stacks \
      --stack-name "${STACK_NAME}" \
      --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue | [0]" \
      --output text \
      2>/dev/null || true
  )"

  if [[ "${value}" == "None" ]]; then
    value=""
  fi

  printf '%s\n' "${value}"
}

describe_instance() {
  local instance_id="$1"
  aws_cli ec2 describe-instances \
    --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0]' \
    --output json
}
