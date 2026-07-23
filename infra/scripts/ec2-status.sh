#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ec2-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/ec2-status.sh [options]

Prints the current AWS-visible state of the Minecraft EC2 instance.
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

aws_cli ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].{
    InstanceId: InstanceId,
    State: State.Name,
    PrivateIp: PrivateIpAddress,
    PublicIp: PublicIpAddress,
    LaunchTime: LaunchTime,
    SubnetId: SubnetId,
    VpcId: VpcId
  }' \
  --output table

aws_cli ec2 describe-instance-status \
  --include-all-instances \
  --instance-ids "${INSTANCE_ID}" \
  --query 'InstanceStatuses[0].{
    InstanceState: InstanceState.Name,
    SystemStatus: SystemStatus.Status,
    InstanceStatus: InstanceStatus.Status
  }' \
  --output table

CONNECTION_ADDRESS="$(stack_output_or_empty "MinecraftConnectionAddress")"
if [[ -n "${CONNECTION_ADDRESS}" ]]; then
  printf 'Connection address: %s\n' "${CONNECTION_ADDRESS}"
fi
