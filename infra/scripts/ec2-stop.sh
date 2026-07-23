#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ec2-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/ec2-stop.sh [options]

Stops the Minecraft EC2 instance and verifies it reaches AWS "stopped".
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
printf 'State before stop: %s\n' "${STATE}"

if [[ "${STATE}" == "stopped" ]]; then
  echo "Instance is already stopped."
else
  aws_cli ec2 stop-instances --instance-ids "${INSTANCE_ID}" >/dev/null
  aws_cli ec2 wait instance-stopped --instance-ids "${INSTANCE_ID}"
fi

printf 'Verified stopped: %s\n' "${INSTANCE_ID}"
