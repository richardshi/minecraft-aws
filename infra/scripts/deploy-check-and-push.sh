#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STACK_NAME="MinecraftStack"
PROFILE="minecraft-prod"
REGION="us-west-2"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-574246332047}"

CHANGE_SET_NAME="minecraft-deploy-$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUTS_FILE="minecraft-outputs.json"

RUN_CHECKS=true
RUN_DIFF=true
AUTO_EXECUTE=false

run_step() {
  printf '\n==> %s\n' "$*"
  "$@"
}

usage() {
  cat <<'EOF'
Usage: scripts/deploy-check-and-push.sh [options]

Runs local validation, creates a CDK change set, displays it for review,
optionally executes it, and writes the final stack outputs.

Options:
  --stack <name>            Stack name. Default: MinecraftStack
  --profile <name>          AWS CLI profile. Default: minecraft-prod
  --region <region>         AWS region. Default: us-west-2
  --account-id <id>         Expected AWS account ID guard.
                            Default: 574246332047
  --change-set-name <name>  CloudFormation change-set name.
                            Default: timestamped minecraft-deploy-* name
  --outputs-file <path>     Final CDK outputs file.
                            Default: minecraft-outputs.json
  --skip-checks             Skip npm run predeploy
  --skip-diff               Skip npx cdk diff
  --yes                     Execute without interactive confirmation
  --help                    Show this help text

The Minecraft EULA acceptance variable is supplied explicitly to every
CDK synthesis/deployment command.
EOF
}

change_set_exists() {
  aws cloudformation describe-change-set \
    --stack-name "${STACK_NAME}" \
    --change-set-name "${CHANGE_SET_NAME}" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --no-cli-pager \
    >/dev/null 2>&1
}

stack_exists() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --no-cli-pager \
    >/dev/null 2>&1
}

print_change_set_failure() {
  aws cloudformation describe-change-set \
    --stack-name "${STACK_NAME}" \
    --change-set-name "${CHANGE_SET_NAME}" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --query '{Status:Status,ExecutionStatus:ExecutionStatus,Reason:StatusReason}' \
    --output table \
    --no-cli-pager
}

delete_change_set() {
  if change_set_exists; then
    run_step aws cloudformation delete-change-set \
      --stack-name "${STACK_NAME}" \
      --change-set-name "${CHANGE_SET_NAME}" \
      --profile "${PROFILE}" \
      --region "${REGION}" \
      --no-cli-pager
  fi
}

cd "${ROOT_DIR}"

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --account-id)
      EXPECTED_ACCOUNT_ID="${2:-}"
      [[ -n "${EXPECTED_ACCOUNT_ID}" ]] || { echo "--account-id requires a value" >&2; exit 1; }
      shift 2
      ;;
    --change-set-name)
      CHANGE_SET_NAME="${2:-}"
      [[ -n "${CHANGE_SET_NAME}" ]] || { echo "--change-set-name requires a value" >&2; exit 1; }
      shift 2
      ;;
    --outputs-file)
      OUTPUTS_FILE="${2:-}"
      [[ -n "${OUTPUTS_FILE}" ]] || { echo "--outputs-file requires a value" >&2; exit 1; }
      shift 2
      ;;
    --skip-checks)
      RUN_CHECKS=false
      shift
      ;;
    --skip-diff)
      RUN_DIFF=false
      shift
      ;;
    --yes)
      AUTO_EXECUTE=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for required_command in aws npm npx; do
  command -v "${required_command}" >/dev/null 2>&1 || {
    echo "Required command not found: ${required_command}" >&2
    exit 1
  }
done

command -v nc >/dev/null 2>&1 || {
  echo "Required command not found: nc" >&2
  exit 1
}

[[ -f package.json ]] || {
  echo "package.json not found under ${ROOT_DIR}" >&2
  echo "Check that this script is located under infra/scripts/." >&2
  exit 1
}

CDK_ENV=(
  env
  "AWS_REGION=${REGION}"
  "AWS_DEFAULT_REGION=${REGION}"
  "CDK_DEPLOY_REGION=${REGION}"
  "CDK_MINECRAFT_EULA_ACCEPTED=true"
)

if [[ "${RUN_CHECKS}" == "true" ]]; then
  run_step "${CDK_ENV[@]}" npm run predeploy
fi

run_step rm -rf cdk.out

ACTUAL_ACCOUNT_ID="$(
  aws sts get-caller-identity \
    --profile "${PROFILE}" \
    --query Account \
    --output text \
    --no-cli-pager
)"

if [[ "${ACTUAL_ACCOUNT_ID}" != "${EXPECTED_ACCOUNT_ID}" ]]; then
  echo "Refusing to deploy to unexpected AWS account." >&2
  echo "Expected: ${EXPECTED_ACCOUNT_ID}" >&2
  echo "Actual:   ${ACTUAL_ACCOUNT_ID}" >&2
  exit 1
fi

printf '\nDeployment target:\n'
printf '  Account:    %s\n' "${ACTUAL_ACCOUNT_ID}"
printf '  Region:     %s\n' "${REGION}"
printf '  Stack:      %s\n' "${STACK_NAME}"
printf '  Change set: %s\n' "${CHANGE_SET_NAME}"

if [[ "${RUN_DIFF}" == "true" ]]; then
  run_step "${CDK_ENV[@]}" \
    npx cdk diff "${STACK_NAME}" \
      --profile "${PROFILE}" \
      --method=change-set
fi

run_step "${CDK_ENV[@]}" \
  npx cdk deploy "${STACK_NAME}" \
    --profile "${PROFILE}" \
    --method=prepare-change-set \
    --change-set-name="${CHANGE_SET_NAME}"

read -r CHANGE_SET_STATUS EXECUTION_STATUS STATUS_REASON < <(
  aws cloudformation describe-change-set \
    --stack-name "${STACK_NAME}" \
    --change-set-name "${CHANGE_SET_NAME}" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --query '[Status,ExecutionStatus,StatusReason]' \
    --output text \
    --no-cli-pager
)

if [[ "${CHANGE_SET_STATUS}" != "CREATE_COMPLETE" || "${EXECUTION_STATUS}" != "AVAILABLE" ]]; then
  if [[ "${STATUS_REASON}" == *"didn't contain changes"* ]]; then
    echo "No infrastructure changes detected for ${STACK_NAME}."
    delete_change_set
    exit 0
  fi

  echo "Change set is not executable." >&2
  echo "Status:          ${CHANGE_SET_STATUS}" >&2
  echo "ExecutionStatus: ${EXECUTION_STATUS}" >&2
  print_change_set_failure
  exit 1
fi

run_step aws cloudformation describe-change-set \
  --stack-name "${STACK_NAME}" \
  --change-set-name "${CHANGE_SET_NAME}" \
  --profile "${PROFILE}" \
  --region "${REGION}" \
  --query 'Changes[].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement,PolicyAction:PolicyAction}' \
  --output table \
  --no-cli-pager

if [[ "${AUTO_EXECUTE}" != "true" ]]; then
  printf '\nReview the change set above carefully.\n'
  printf 'Durable resources must not be deleted or replaced:\n'
  printf '  - MinecraftDataVolume\n'
  printf '  - MinecraftBackupBucket\n'
  printf '  - MinecraftEip\n\n'

  reply=""
  read -r -p "Execute change set ${CHANGE_SET_NAME}? [y/N] " reply || true

  if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled. The unexecuted change set remains available."
    exit 0
  fi
fi

run_step "${CDK_ENV[@]}" \
  npx cdk deploy "${STACK_NAME}" \
    --profile "${PROFILE}" \
    --method=execute-change-set \
    --change-set-name="${CHANGE_SET_NAME}" \
    --outputs-file "${OUTPUTS_FILE}"

run_step aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --profile "${PROFILE}" \
  --region "${REGION}" \
  --query 'Stacks[0].{Status:StackStatus,TerminationProtection:EnableTerminationProtection,Outputs:Outputs}' \
  --output json \
  --no-cli-pager

ELASTIC_IP="$(
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='ElasticIpAddress'].OutputValue | [0]" \
    --output text \
    --no-cli-pager
)"

if [[ -n "${ELASTIC_IP}" && "${ELASTIC_IP}" != "None" ]]; then
  run_step nc -vz "${ELASTIC_IP}" 25565
else
  echo "Could not determine ElasticIpAddress output for ${STACK_NAME}." >&2
  exit 1
fi

printf '\nDeployment complete.\n'
printf 'Outputs written to: %s/%s\n' "${ROOT_DIR}" "${OUTPUTS_FILE}"
