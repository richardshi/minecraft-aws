#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ec2-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/ec2-start.sh [options]

Starts the Minecraft EC2 instance and verifies it reaches AWS "running"
and status-check-ok.
EOF
  usage_common
}

parse_status=0
parse_common_args "$@" || parse_status=$?
if [[ ${parse_status} -eq 1 ]]; then
  usage >&2
  exit 1
fi
if [[ ${parse_status} -eq 2 ]]; then
  usage
  exit 0
fi

require_commands

INSTANCE_ID="$(resolve_instance_id)"
STATE="$(
  aws_cli ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text
)"

printf 'Instance: %s\n' "${INSTANCE_ID}"
printf 'State before start: %s\n' "${STATE}"

if [[ "${STATE}" == "running" ]]; then
  echo "Instance is already running."
else
  aws_cli ec2 start-instances --instance-ids "${INSTANCE_ID}" >/dev/null
  aws_cli ec2 wait instance-running --instance-ids "${INSTANCE_ID}"
fi

aws_cli ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}"

CONNECTION_ADDRESS="$(stack_output_or_empty "MinecraftConnectionAddress")"
printf 'Verified running: %s\n' "${INSTANCE_ID}"
if [[ -n "${CONNECTION_ADDRESS}" ]]; then
  printf 'Connection address: %s\n' "${CONNECTION_ADDRESS}"
fi
