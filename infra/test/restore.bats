#!/usr/bin/env bats
# restore.bats - Tests for infra/assets/restore.sh
#
# Mocks the filesystem, S3 CLI, systemctl, and chown so no AWS access, real
# minecraft/root privileges, or running Minecraft server is required.
#
# Run from the repo root:
#   bats infra/test/restore.bats

RESTORE_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../assets" && pwd)/restore.sh"

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  TEST_DIR="$(mktemp -d)"

  MINECRAFT_DIR="${TEST_DIR}/minecraft"
  LOG_DIR="${TEST_DIR}/log"
  MOCK_S3="${TEST_DIR}/s3"
  BIN_DIR="${TEST_DIR}/bin"

  mkdir -p "${MINECRAFT_DIR}/world" "${LOG_DIR}" "${MOCK_S3}" "${BIN_DIR}"

  # Pre-existing "live" world data, so tests can tell old vs. restored content apart.
  printf 'old chunk\n' > "${MINECRAFT_DIR}/world/r.0.0.mca"
  printf 'level-name=world\nserver-port=25565\n' > "${MINECRAFT_DIR}/server.properties"

  SERVER_LOG="${LOG_DIR}/server.log"
  BACKUP_LOG="${LOG_DIR}/backup.log"
  : > "${SERVER_LOG}"

  # ---- aws mock: only the download direction is needed (restore never uploads) ----
  cat > "${BIN_DIR}/aws" <<AWS_MOCK
#!/bin/bash
echo "\$*" >> "${TEST_DIR}/aws-calls.log"
case "\$1 \$2" in
  "s3 cp")
    KEY=\$(basename "\$3")
    cp "${MOCK_S3}/\${KEY}" "\$4" 2>/dev/null || exit 1
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
AWS_MOCK
  chmod +x "${BIN_DIR}/aws"

  # ---- systemctl mock: independently controllable per-subcommand exit codes ----
  cat > "${BIN_DIR}/systemctl" <<SYSTEMCTL_MOCK
#!/bin/bash
echo "\$*" >> "${TEST_DIR}/systemctl-calls.log"
case "\$1" in
  is-active) exit "\${SYSTEMCTL_IS_ACTIVE_EXIT:-0}" ;;
  start) exit "\${SYSTEMCTL_START_EXIT:-0}" ;;
  stop) exit "\${SYSTEMCTL_STOP_EXIT:-0}" ;;
  *) exit 0 ;;
esac
SYSTEMCTL_MOCK
  chmod +x "${BIN_DIR}/systemctl"

  # ---- chown mock: restore.sh chowns to the minecraft user, which doesn't
  #      exist (and isn't permitted) in the test environment ----
  cat > "${BIN_DIR}/chown" <<'CHOWN_MOCK'
#!/bin/bash
exit 0
CHOWN_MOCK
  chmod +x "${BIN_DIR}/chown"

  export PATH="${BIN_DIR}:${PATH}"

  export BACKUP_BUCKET="mock-bucket"
  export AWS_DEFAULT_REGION="us-west-2"
  export STARTUP_TIMEOUT=2

  export MINECRAFT_DIR SERVER_LOG BACKUP_LOG
  export TEST_DIR MOCK_S3
}

teardown() {
  rm -rf "${TEST_DIR}"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_restore() {
  run bash "${RESTORE_SCRIPT}" "$@"
}

# Builds a backup archive at ${MOCK_S3}/<key>. Contains world/ (with the given
# content marker) and server.properties unless include_world=false.
make_backup_archive() {
  local key="$1"
  local content_marker="${2:-new chunk}"
  local include_world="${3:-true}"
  local build_dir
  build_dir="$(mktemp -d)"

  if [[ "${include_world}" == "true" ]]; then
    mkdir -p "${build_dir}/world"
    printf '%s\n' "${content_marker}" > "${build_dir}/world/r.0.0.mca"
  fi
  printf 'level-name=world\nserver-port=25565\n' > "${build_dir}/server.properties"

  tar -czf "${MOCK_S3}/${key}" -C "${build_dir}" .
  rm -rf "${build_dir}"
}

seed_ready_log() {
  printf '[12:00:00] [Server thread/INFO]: Done (1.234s)! For help, type "help"\n' > "${SERVER_LOG}"
}

# ---------------------------------------------------------------------------
# 1. Successful restore
# ---------------------------------------------------------------------------

@test "exits 0 and logs BACKUP_SUCCESS when restore completes and server reports ready" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  seed_ready_log

  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz

  [ "$status" -eq 0 ]
  grep -q "BACKUP_SUCCESS" "${BACKUP_LOG}"
}

@test "successful restore replaces world content with the restored archive" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  seed_ready_log

  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz

  [ "$status" -eq 0 ]
  grep -q "new chunk" "${MINECRAFT_DIR}/world/r.0.0.mca"
}

@test "successful restore preserves the old world as a pre-restore copy" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  seed_ready_log

  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz

  [ "$status" -eq 0 ]
  local rollback_dir
  rollback_dir=$(compgen -G "${MINECRAFT_DIR}/world.pre-restore.*" | head -1)
  [ -n "${rollback_dir}" ]
  grep -q "old chunk" "${rollback_dir}/r.0.0.mca"
}

@test "successful restore cleans up the staging directory" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  seed_ready_log

  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz

  [ "$status" -eq 0 ]
  [ ! -d "${MINECRAFT_DIR}/.restore-staging" ]
}

@test "successful restore stops and starts minecraft.service" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  seed_ready_log

  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz

  [ "$status" -eq 0 ]
  grep -q "^stop minecraft.service$" "${TEST_DIR}/systemctl-calls.log"
  grep -q "^start minecraft.service$" "${TEST_DIR}/systemctl-calls.log"
}

# ---------------------------------------------------------------------------
# 2. Invalid archive - abort before touching minecraft.service
# ---------------------------------------------------------------------------

@test "aborts with non-zero exit when the archive is not a valid tar.gz" {
  printf 'this is not a real archive\n' > "${MOCK_S3}/bad.tar.gz"

  run_restore --backup-key bad.tar.gz

  [ "$status" -ne 0 ]
  grep -q "BACKUP_FAILED" "${BACKUP_LOG}"
  grep -q "not a valid tar.gz" "${BACKUP_LOG}"
}

@test "does not stop minecraft.service when the archive is invalid" {
  printf 'this is not a real archive\n' > "${MOCK_S3}/bad.tar.gz"

  run_restore --backup-key bad.tar.gz

  [ "$status" -ne 0 ]
  if [[ -f "${TEST_DIR}/systemctl-calls.log" ]]; then
    run grep "stop" "${TEST_DIR}/systemctl-calls.log"
    [ "$status" -ne 0 ]
  fi
}

@test "leaves the live world untouched when the archive is invalid" {
  printf 'this is not a real archive\n' > "${MOCK_S3}/bad.tar.gz"

  run_restore --backup-key bad.tar.gz

  [ "$status" -ne 0 ]
  grep -q "old chunk" "${MINECRAFT_DIR}/world/r.0.0.mca"
  ! compgen -G "${MINECRAFT_DIR}/world.pre-restore.*" > /dev/null
}

# ---------------------------------------------------------------------------
# 3. Archive missing the expected world directory - abort before touching service
# ---------------------------------------------------------------------------

@test "aborts with non-zero exit when the archive has no world directory" {
  make_backup_archive "minecraft-backup-no-world.tar.gz" "unused" false

  run_restore --backup-key minecraft-backup-no-world.tar.gz

  [ "$status" -ne 0 ]
  grep -q "BACKUP_FAILED" "${BACKUP_LOG}"
  grep -q "does not contain expected world directory" "${BACKUP_LOG}"
}

@test "does not stop minecraft.service when the archive has no world directory" {
  make_backup_archive "minecraft-backup-no-world.tar.gz" "unused" false

  run_restore --backup-key minecraft-backup-no-world.tar.gz

  [ "$status" -ne 0 ]
  if [[ -f "${TEST_DIR}/systemctl-calls.log" ]]; then
    run grep "stop" "${TEST_DIR}/systemctl-calls.log"
    [ "$status" -ne 0 ]
  fi
}

@test "cleans up staging when the archive has no world directory" {
  make_backup_archive "minecraft-backup-no-world.tar.gz" "unused" false

  run_restore --backup-key minecraft-backup-no-world.tar.gz

  [ "$status" -ne 0 ]
  [ ! -d "${MINECRAFT_DIR}/.restore-staging" ]
}

# ---------------------------------------------------------------------------
# 4. Server never reports ready - rollback on timeout
# ---------------------------------------------------------------------------

@test "rolls back when the server never reports ready within the startup timeout" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  # SERVER_LOG stays empty - "Done (" never appears.
  export SYSTEMCTL_IS_ACTIVE_EXIT=0

  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz

  [ "$status" -ne 0 ]
  grep -q "BACKUP_FAILED" "${BACKUP_LOG}"
  grep -q "rolling back" "${BACKUP_LOG}"
}

@test "does not treat a stale ready line from a previous boot as a successful restore" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  printf '[11:59:00] [Server thread/INFO]: Done (1.234s)! For help, type "help"\n' > "${SERVER_LOG}"
  export SYSTEMCTL_IS_ACTIVE_EXIT=0

  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz

  [ "$status" -ne 0 ]
  grep -q "rolling back" "${BACKUP_LOG}"
  grep -q "old chunk" "${MINECRAFT_DIR}/world/r.0.0.mca"
}

@test "timeout rollback restores the previous world content" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  export SYSTEMCTL_IS_ACTIVE_EXIT=0

  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz

  [ "$status" -ne 0 ]
  grep -q "old chunk" "${MINECRAFT_DIR}/world/r.0.0.mca"
}

@test "timeout rollback preserves the failed restore attempt rather than deleting it" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  export SYSTEMCTL_IS_ACTIVE_EXIT=0

  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz

  [ "$status" -ne 0 ]
  local failed_dir
  failed_dir=$(compgen -G "${MINECRAFT_DIR}/world.failed-restore.*" | head -1)
  [ -n "${failed_dir}" ]
  grep -q "new chunk" "${failed_dir}/r.0.0.mca"
}

@test "timeout rollback restarts minecraft.service" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  export SYSTEMCTL_IS_ACTIVE_EXIT=0

  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz

  [ "$status" -ne 0 ]
  local start_count
  start_count=$(grep -c "^start minecraft.service$" "${TEST_DIR}/systemctl-calls.log")
  [ "${start_count}" -ge 2 ]
}

# ---------------------------------------------------------------------------
# 5. Service goes inactive right after start - rollback without waiting
# ---------------------------------------------------------------------------

@test "rolls back promptly (without waiting the full timeout) when the service goes inactive after start" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  export SYSTEMCTL_IS_ACTIVE_EXIT=1
  export STARTUP_TIMEOUT=90

  local start_ts end_ts duration
  start_ts=$(date +%s)
  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz
  end_ts=$(date +%s)
  duration=$((end_ts - start_ts))

  [ "$status" -ne 0 ]
  [ "${duration}" -lt 10 ]
  grep -q "old chunk" "${MINECRAFT_DIR}/world/r.0.0.mca"
}

# ---------------------------------------------------------------------------
# 6. Dry run - no changes
# ---------------------------------------------------------------------------

@test "dry-run makes no changes to the live world" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  seed_ready_log

  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz --dry-run

  [ "$status" -eq 0 ]
  grep -q "old chunk" "${MINECRAFT_DIR}/world/r.0.0.mca"
}

@test "dry-run does not create a staging directory or pre-restore copy" {
  make_backup_archive "minecraft-backup-20260101-000000.tar.gz" "new chunk"
  seed_ready_log

  run_restore --backup-key minecraft-backup-20260101-000000.tar.gz --dry-run

  [ "$status" -eq 0 ]
  [ ! -d "${MINECRAFT_DIR}/.restore-staging" ]
  ! compgen -G "${MINECRAFT_DIR}/world.pre-restore.*" > /dev/null
}
