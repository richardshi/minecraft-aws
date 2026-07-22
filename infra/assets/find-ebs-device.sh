#!/bin/bash
# find-ebs-device.sh - Resolve an EBS Volume ID to its NVMe block device path.
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
DISK_BY_ID_ROOT="${DISK_BY_ID_ROOT:-/dev/disk/by-id}"
SYS_BLOCK_ROOT="${SYS_BLOCK_ROOT:-/sys/block}"
DEVICE_ALIAS_PATHS="${DEVICE_ALIAS_PATHS:-/dev/sdf /dev/xvdf}"

# Strip the "vol-" prefix for matching - the serial number format in sysfs
# may encode it differently across kernel versions.
VOLUME_ID_BARE="${VOLUME_ID#vol-}"
VOLUME_ID_NODASH="vol${VOLUME_ID_BARE}"

FOUND_DEVICES=()

record_device() {
  local device="$1"
  local existing
  for existing in "${FOUND_DEVICES[@]}"; do
    if [[ "${existing}" == "${device}" ]]; then
      return 0
    fi
  done
  FOUND_DEVICES+=("${device}")
}

matches_volume_id() {
  local value="$1"
  [[ "$value" == *"${VOLUME_ID_BARE}"* ]] || [[ "$value" == *"${VOLUME_ID_NODASH}"* ]]
}

record_if_serial_matches() {
  local device="$1"
  local serial
  serial="$(lsblk -ndo SERIAL "$device" 2>/dev/null || true)"
  if [[ -n "${serial}" ]] && matches_volume_id "${serial}"; then
    record_device "$(readlink -f "$device" 2>/dev/null || printf '%s\n' "$device")"
  fi
}

# First try the stable /dev/disk/by-id symlinks if they exist.
for by_id_path in "${DISK_BY_ID_ROOT}"/nvme-Amazon_Elastic_Block_Store_*; do
  [[ -e "$by_id_path" ]] || continue
  by_id_name=$(basename "$by_id_path")
  if matches_volume_id "${by_id_name}"; then
    resolved_device=$(readlink -f "$by_id_path" 2>/dev/null || true)
    [[ -n "${resolved_device}" ]] && record_device "${resolved_device}"
  fi
done

for serial_path in "${SYS_BLOCK_ROOT}"/nvme*n1/device/serial; do
  # Skip glob if no NVMe devices exist
  [[ -e "$serial_path" ]] || continue

  serial=$(cat "$serial_path" 2>/dev/null || true)

  # Match either the full volume ID or the bare ID (without "vol-" prefix).
  # AWS encodes the EBS volume ID in the NVMe serial as "vol<hex>" (no dash).
  if matches_volume_id "${serial}"; then
    # Derive block device path from sysfs path:
    # /sys/block/nvme1n1/device/serial -> /dev/nvme1n1
    device_name=$(basename "$(dirname "$(dirname "$serial_path")")")
    record_device "/dev/${device_name}"
  fi
done

# Fall back to lsblk serial matching when sysfs/by-id are missing or delayed.
while read -r device serial; do
  [[ -n "${device}" ]] || continue
  if [[ -n "${serial}" ]] && matches_volume_id "${serial}"; then
    record_device "${device}"
  fi
done < <(lsblk -dn -o PATH,SERIAL 2>/dev/null || true)

# Final fallback: check the expected attachment aliases directly.
for alias_path in ${DEVICE_ALIAS_PATHS}; do
  [[ -e "${alias_path}" ]] || continue
  record_if_serial_matches "${alias_path}"
done

if [[ ${#FOUND_DEVICES[@]} -eq 0 ]]; then
  echo "ERROR: No NVMe device found matching Volume ID '${VOLUME_ID}'" >&2
  echo "       Verify the volume is attached to this instance." >&2
  echo "       lsblk snapshot:" >&2
  lsblk -dn -o PATH,SERIAL,SIZE,TYPE,MOUNTPOINT 2>/dev/null >&2 || true
  exit 1
fi

if [[ ${#FOUND_DEVICES[@]} -gt 1 ]]; then
  echo "ERROR: Multiple NVMe devices matched Volume ID '${VOLUME_ID}'" >&2
  exit 1
fi

echo "${FOUND_DEVICES[0]}"
