#!/usr/bin/env bats
# storage.bats - Tests for infra/assets/find-ebs-device.sh and install.sh

FIND_EBS_DEVICE_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../assets" && pwd)/find-ebs-device.sh"
INSTALL_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../assets" && pwd)/install.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  BIN_DIR="${TEST_DIR}/bin"
  SYS_BLOCK_ROOT="${TEST_DIR}/sys/block"
  DISK_BY_ID_ROOT="${TEST_DIR}/dev/disk/by-id"
  FAKE_DEV_ROOT="${TEST_DIR}/dev"
  MINECRAFT_DIR="${TEST_DIR}/minecraft"
  LOG_DIR="${TEST_DIR}/log"
  FSTAB_FILE="${TEST_DIR}/fstab"

  mkdir -p "${BIN_DIR}" "${SYS_BLOCK_ROOT}" "${DISK_BY_ID_ROOT}" "${FAKE_DEV_ROOT}" "${MINECRAFT_DIR}" "${LOG_DIR}"
  : > "${FSTAB_FILE}"

  cat > "${BIN_DIR}/lsblk" <<'EOF'
#!/bin/bash
echo "$*" >> "${TEST_DIR}/lsblk-calls.log"
case "$*" in
  "-dn -o PATH,SERIAL")
    count_file="${TEST_DIR}/lsblk-path-serial-count"
    count=0
    if [[ -f "${count_file}" ]]; then
      count=$(cat "${count_file}")
    fi
    count=$((count + 1))
    printf '%s' "${count}" > "${count_file}"
    appear_on="${LSBLK_APPEAR_ON_CALL:-1}"
    if [[ "${count}" -ge "${appear_on}" ]]; then
      cat "${TEST_DIR}/lsblk-path-serial.txt" 2>/dev/null || true
    fi
    ;;
  "-dn -o PATH,SERIAL,SIZE,TYPE,MOUNTPOINT")
    cat "${TEST_DIR}/lsblk-diagnostics.txt" 2>/dev/null || true
    ;;
  *)
    if [[ "$1" == "-ndo" && "$2" == "SERIAL" ]]; then
      key=$(basename "$3")
      cat "${TEST_DIR}/serial-${key}.txt" 2>/dev/null || true
    fi
    ;;
esac
EOF
  chmod +x "${BIN_DIR}/lsblk"

  cat > "${BIN_DIR}/readlink" <<'EOF'
#!/bin/bash
if [[ "$1" == "-f" ]]; then
  target="${2}"
  while IFS='|' read -r input output; do
    if [[ "${input}" == "${target}" ]]; then
      printf '%s\n' "${output}"
      exit 0
    fi
  done < "${TEST_DIR}/readlink-map.txt" 2>/dev/null
fi
/usr/bin/readlink "$@"
EOF
  chmod +x "${BIN_DIR}/readlink"

  cat > "${BIN_DIR}/java" <<'EOF'
#!/bin/bash
if [[ "$1" == "-version" ]]; then
  echo 'openjdk version "25"' >&2
fi
exit 0
EOF
  chmod +x "${BIN_DIR}/java"

  cat > "${BIN_DIR}/amazon-cloudwatch-agent-ctl" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "${BIN_DIR}/amazon-cloudwatch-agent-ctl"

  cat > "${BIN_DIR}/yum" <<'EOF'
#!/bin/bash
echo "$*" >> "${TEST_DIR}/yum-calls.log"
exit 0
EOF
  chmod +x "${BIN_DIR}/yum"

  cat > "${BIN_DIR}/id" <<'EOF'
#!/bin/bash
exit "${ID_EXIT_CODE:-0}"
EOF
  chmod +x "${BIN_DIR}/id"

  cat > "${BIN_DIR}/useradd" <<'EOF'
#!/bin/bash
echo "$*" >> "${TEST_DIR}/useradd-calls.log"
exit 0
EOF
  chmod +x "${BIN_DIR}/useradd"

  cat > "${BIN_DIR}/curl" <<'EOF'
#!/bin/bash
url="${@: -1}"
case "${url}" in
  "http://169.254.169.254/latest/api/token")
    printf 'token\n'
    ;;
  "http://169.254.169.254/latest/meta-data/instance-id")
    printf '%s\n' "${MOCK_INSTANCE_ID:-i-test}"
    ;;
  *)
    printf '%s\n' "${CURL_DEFAULT_OUTPUT:-}"
    ;;
esac
EOF
  chmod +x "${BIN_DIR}/curl"

  cat > "${BIN_DIR}/aws" <<'EOF'
#!/bin/bash
echo "$*" >> "${TEST_DIR}/aws-calls.log"
if [[ "$1 $2" == "ec2 describe-volumes" ]]; then
  count_file="${TEST_DIR}/aws-describe-count"
  count=0
  if [[ -f "${count_file}" ]]; then
    count=$(cat "${count_file}")
  fi
  count=$((count + 1))
  printf '%s' "${count}" > "${count_file}"
  line=$(sed -n "${count}p" "${TEST_DIR}/aws-attachment-sequence.txt" 2>/dev/null || true)
  if [[ -z "${line}" ]]; then
    line="${AWS_ATTACHMENT_INFO:-None None None}"
  fi
  printf '%s\n' "${line}"
  exit 0
fi
exit 0
EOF
  chmod +x "${BIN_DIR}/aws"

  cat > "${BIN_DIR}/udevadm" <<'EOF'
#!/bin/bash
echo "$*" >> "${TEST_DIR}/udevadm-calls.log"
exit 0
EOF
  chmod +x "${BIN_DIR}/udevadm"

  cat > "${BIN_DIR}/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "${BIN_DIR}/sleep"

  cat > "${BIN_DIR}/blkid" <<'EOF'
#!/bin/bash
echo "$*" >> "${TEST_DIR}/blkid-calls.log"
device="${@: -1}"
device_key=$(basename "${device}")
if [[ "$1" == "-s" && "$2" == "TYPE" ]]; then
  type_file="${TEST_DIR}/blkid-type-${device_key}.txt"
  if [[ "$4" == "value" ]]; then
    cat "${type_file}" 2>/dev/null || exit 1
  else
    if [[ -f "${type_file}" ]]; then
      printf '%s: TYPE="%s"\n' "${device}" "$(cat "${type_file}")"
      exit 0
    fi
    exit 1
  fi
elif [[ "$1" == "-s" && "$2" == "UUID" ]]; then
  cat "${TEST_DIR}/blkid-uuid-${device_key}.txt" 2>/dev/null || printf 'uuid-test\n'
fi
EOF
  chmod +x "${BIN_DIR}/blkid"

  cat > "${BIN_DIR}/mkfs.ext4" <<'EOF'
#!/bin/bash
echo "$*" >> "${TEST_DIR}/mkfs-calls.log"
exit 0
EOF
  chmod +x "${BIN_DIR}/mkfs.ext4"

  cat > "${BIN_DIR}/mountpoint" <<'EOF'
#!/bin/bash
exit "${MOUNTPOINT_EXIT_CODE:-1}"
EOF
  chmod +x "${BIN_DIR}/mountpoint"

  cat > "${BIN_DIR}/mount" <<'EOF'
#!/bin/bash
echo "$*" >> "${TEST_DIR}/mount-calls.log"
exit 0
EOF
  chmod +x "${BIN_DIR}/mount"

  cat > "${BIN_DIR}/chown" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "${BIN_DIR}/chown"

  export PATH="${BIN_DIR}:${PATH}"
  export TEST_DIR SYS_BLOCK_ROOT DISK_BY_ID_ROOT
}

teardown() {
  rm -rf "${TEST_DIR}"
}

run_find() {
  run env \
    PATH="${BIN_DIR}:${PATH}" \
    SYS_BLOCK_ROOT="${SYS_BLOCK_ROOT}" \
    DISK_BY_ID_ROOT="${DISK_BY_ID_ROOT}" \
    bash "$FIND_EBS_DEVICE_SCRIPT" "$@"
}

run_install_storage() {
  run env \
    PATH="${BIN_DIR}:${PATH}" \
    MINECRAFT_DIR="${MINECRAFT_DIR}" \
    LOG_DIR="${LOG_DIR}" \
    MINECRAFT_USER="minecraft" \
    FSTAB_FILE="${FSTAB_FILE}" \
    EXIT_AFTER_STORAGE_SETUP=true \
    EBS_ATTACH_WAIT_SECONDS="${EBS_ATTACH_WAIT_SECONDS:-15}" \
    EBS_ATTACH_POLL_SECONDS="${EBS_ATTACH_POLL_SECONDS:-1}" \
    SYS_BLOCK_ROOT="${SYS_BLOCK_ROOT}" \
    DISK_BY_ID_ROOT="${DISK_BY_ID_ROOT}" \
    MINECRAFT_EULA_ACCEPTED=true \
    MINECRAFT_VERSION="26.1.2" \
    MINECRAFT_PORT="25565" \
    JAVA_XMS="2G" \
    JAVA_XMX="2G" \
    BACKUP_BUCKET="mock-bucket" \
    BACKUP_RETENTION="5" \
    AWS_DEFAULT_REGION="us-west-2" \
    EBS_VOLUME_ID="vol-0123" \
    bash "$INSTALL_SCRIPT"
}

make_serial() {
  local device="$1"
  local serial="$2"
  mkdir -p "${SYS_BLOCK_ROOT}/${device}/device"
  printf '%s\n' "${serial}" > "${SYS_BLOCK_ROOT}/${device}/device/serial"
}

set_readlink_map() {
  local input="$1"
  local output="$2"
  printf '%s|%s\n' "${input}" "${output}" >> "${TEST_DIR}/readlink-map.txt"
}

set_device_serial() {
  local device_basename="$1"
  local serial="$2"
  printf '%s\n' "${serial}" > "${TEST_DIR}/serial-${device_basename}.txt"
}

@test "vol-0123 input matches lsblk serial vol0123" {
  printf '/dev/nvme1n1 vol0123\n' > "${TEST_DIR}/lsblk-path-serial.txt"

  run_find vol-0123

  [ "$status" -eq 0 ]
  [ "$output" = "/dev/nvme1n1" ]
}

@test "Root EBS volume is ignored" {
  make_serial "nvme0n1" "volroot999"
  printf '/dev/nvme0n1 volroot999\n' > "${TEST_DIR}/lsblk-path-serial.txt"

  run_find vol-0123

  [ "$status" -ne 0 ]
}

@test "Correct data volume returns /dev/nvme1n1" {
  make_serial "nvme0n1" "volroot999"
  make_serial "nvme1n1" "vol0123"

  run_find vol-0123

  [ "$status" -eq 0 ]
  [ "$output" = "/dev/nvme1n1" ]
}

@test "/dev/disk/by-id fallback resolves correctly" {
  local by_id_path="${DISK_BY_ID_ROOT}/nvme-Amazon_Elastic_Block_Store_vol0123"
  touch "${FAKE_DEV_ROOT}/nvme1n1"
  touch "${by_id_path}"
  set_readlink_map "${by_id_path}" "/dev/nvme1n1"

  run_find vol-0123

  [ "$status" -eq 0 ]
  [ "$output" = "/dev/nvme1n1" ]
}

@test "/dev/sdf symlink fallback resolves correctly" {
  local alias_path="${TEST_DIR}/sdf"
  touch "${alias_path}"
  set_device_serial "sdf" "vol0123"
  set_readlink_map "${alias_path}" "/dev/nvme1n1"

  run env \
    PATH="${BIN_DIR}:${PATH}" \
    SYS_BLOCK_ROOT="${SYS_BLOCK_ROOT}" \
    DISK_BY_ID_ROOT="${DISK_BY_ID_ROOT}" \
    DEVICE_ALIAS_PATHS="${alias_path}" \
    bash "$FIND_EBS_DEVICE_SCRIPT" vol-0123

  [ "$status" -eq 0 ]
  [ "$output" = "/dev/nvme1n1" ]
}

@test "Device appearing after several retries succeeds" {
  printf '/dev/nvme1n1 vol0123\n' > "${TEST_DIR}/lsblk-path-serial.txt"
  printf 'None None None\nNone None None\ni-test attached /dev/sdf\n' > "${TEST_DIR}/aws-attachment-sequence.txt"
  export LSBLK_APPEAR_ON_CALL=4
  printf 'uuid-retry\n' > "${TEST_DIR}/blkid-uuid-nvme1n1.txt"

  run_install_storage

  [ "$status" -eq 0 ]
  grep -q "EXIT_AFTER_STORAGE_SETUP requested" <<< "$output"
  [ "$(cat "${TEST_DIR}/lsblk-path-serial-count")" -ge 4 ]
}

@test "Unknown volume times out with lsblk diagnostics" {
  export EBS_ATTACH_WAIT_SECONDS=3
  printf '/dev/nvme0n1 volroot999 8G disk /\n/dev/nvme1n1 vol9999 20G disk \n' > "${TEST_DIR}/lsblk-diagnostics.txt"
  printf 'i-old attached /dev/sdf\n' > "${TEST_DIR}/aws-attachment-sequence.txt"

  run_install_storage

  [ "$status" -ne 0 ]
  grep -q "Timed out waiting for EBS volume vol-0123 to appear" <<< "$output"
  grep -q "Local lsblk snapshot at timeout" <<< "$output"
  grep -q "/dev/nvme1n1 vol9999 20G disk" <<< "$output"
}

@test "Existing XFS filesystem is never reformatted" {
  printf '/dev/nvme1n1 vol0123\n' > "${TEST_DIR}/lsblk-path-serial.txt"
  printf 'xfs\n' > "${TEST_DIR}/blkid-type-nvme1n1.txt"
  printf 'uuid-xfs\n' > "${TEST_DIR}/blkid-uuid-nvme1n1.txt"

  run_install_storage

  [ "$status" -eq 0 ]
  grep -q "Filesystem already present on /dev/nvme1n1: xfs" <<< "$output"
  [ ! -f "${TEST_DIR}/mkfs-calls.log" ]
}

@test "Existing ext4 filesystem is never reformatted" {
  printf '/dev/nvme1n1 vol0123\n' > "${TEST_DIR}/lsblk-path-serial.txt"
  printf 'ext4\n' > "${TEST_DIR}/blkid-type-nvme1n1.txt"
  printf 'uuid-ext4\n' > "${TEST_DIR}/blkid-uuid-nvme1n1.txt"

  run_install_storage

  [ "$status" -eq 0 ]
  grep -q "Filesystem already present on /dev/nvme1n1: ext4" <<< "$output"
  [ ! -f "${TEST_DIR}/mkfs-calls.log" ]
}

@test "Blank volume is formatted exactly once" {
  printf '/dev/nvme1n1 vol0123\n' > "${TEST_DIR}/lsblk-path-serial.txt"
  printf 'uuid-new\n' > "${TEST_DIR}/blkid-uuid-nvme1n1.txt"

  run_install_storage

  [ "$status" -eq 0 ]
  [ "$(wc -l < "${TEST_DIR}/mkfs-calls.log")" -eq 1 ]
  grep -q "No filesystem found on /dev/nvme1n1, formatting with ext4" <<< "$output"
}

@test "Mounted volume is reused idempotently" {
  printf '/dev/nvme1n1 vol0123\n' > "${TEST_DIR}/lsblk-path-serial.txt"
  printf 'ext4\n' > "${TEST_DIR}/blkid-type-nvme1n1.txt"
  printf 'uuid-mounted\n' > "${TEST_DIR}/blkid-uuid-nvme1n1.txt"
  printf 'UUID=uuid-mounted  %s  ext4  defaults,nofail  0  2\n' "${MINECRAFT_DIR}" > "${FSTAB_FILE}"
  export MOUNTPOINT_EXIT_CODE=0

  run_install_storage

  [ "$status" -eq 0 ]
  [ ! -f "${TEST_DIR}/mount-calls.log" ]
  [ "$(grep -c "uuid-mounted" "${FSTAB_FILE}")" -eq 1 ]
}

@test "Wrong-size or wrong-ID disk is never selected" {
  make_serial "nvme0n1" "volroot999"
  printf '/dev/nvme0n1 volroot999 8G disk /\n/dev/nvme1n1 vol9999 100G disk \n' > "${TEST_DIR}/lsblk-diagnostics.txt"
  printf '/dev/nvme0n1 volroot999\n/dev/nvme1n1 vol9999\n' > "${TEST_DIR}/lsblk-path-serial.txt"

  run_find vol-0123

  [ "$status" -ne 0 ]
  grep -q "lsblk snapshot" <<< "$output"
}
