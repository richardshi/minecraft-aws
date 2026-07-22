#!/bin/bash
# find-ebs-device.sh — Resolve an EBS Volume ID to its NVMe block device path.
#
# On Nitro-based EC2 instances (t3.*), EBS volumes appear as NVMe devices
# (/dev/nvme0n1, /dev/nvme1n1, etc.) regardless of the attachment device name
# specified in CloudFormation (/dev/sdf). The mapping is non-deterministic.
#
# This script identifies the correct device by reading the NVMe serial number
# from sysfs. For an EBS volume, the serial number contains the Volume ID.
#
# Usage:
#   find-ebs-device.sh <volume-id>
#   Example: find-ebs-device.sh vol-0abc1234def56789a
#
# Output:
#   Prints /dev/<device> on success (exit 0).
#   Prints an error to stderr and exits 1 on failure.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <volume-id>" >&2
  exit 1
fi

VOLUME_ID="$1"

# Strip the "vol-" prefix for matching — the serial number format in sysfs
# may encode it differently across kernel versions.
VOLUME_ID_BARE="${VOLUME_ID#vol-}"

FOUND_DEVICE=""
MATCH_COUNT=0

for serial_path in /sys/block/nvme*n1/device/serial; do
  # Skip glob if no NVMe devices exist
  [[ -e "$serial_path" ]] || continue

  serial=$(cat "$serial_path" 2>/dev/null || true)

  # Match either the full volume ID or the bare ID (without "vol-" prefix).
  # AWS encodes the EBS volume ID in the NVMe serial as "vol<hex>" (no dash).
  VOLUME_ID_NODASH="vol${VOLUME_ID_BARE}"

  if [[ "$serial" == *"${VOLUME_ID_BARE}"* ]] || [[ "$serial" == *"${VOLUME_ID_NODASH}"* ]]; then
    # Derive block device path from sysfs path:
    # /sys/block/nvme1n1/device/serial -> /dev/nvme1n1
    device_name=$(basename "$(dirname "$(dirname "$serial_path")")")
    FOUND_DEVICE="/dev/${device_name}"
    MATCH_COUNT=$((MATCH_COUNT + 1))
  fi
done

if [[ $MATCH_COUNT -eq 0 ]]; then
  echo "ERROR: No NVMe device found matching Volume ID '${VOLUME_ID}'" >&2
  echo "       Verify the volume is attached to this instance." >&2
  exit 1
fi

if [[ $MATCH_COUNT -gt 1 ]]; then
  echo "ERROR: Multiple NVMe devices matched Volume ID '${VOLUME_ID}'" >&2
  exit 1
fi

echo "$FOUND_DEVICE"
