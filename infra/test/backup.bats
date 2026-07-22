#!/usr/bin/env bats
# backup.bats - Tests for infra/assets/backup.sh
#
# Mocks the filesystem, FIFO, S3 CLI, and systemctl so no AWS access or
# running Minecraft server is required.
#
# Run from the repo root:
#   bats infra/test/backup.bats

BACKUP_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../assets" && pwd)/backup.sh"

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  TEST_DIR="$(mktemp -d)"

  # Isolated directory layout
  MINECRAFT_DIR="${TEST_DIR}/minecraft"
  RUN_DIR="${TEST_DIR}/run"
  LOG_DIR="${TEST_DIR}/log"
  MOCK_S3="${TEST_DIR}/s3"
  BIN_DIR="${TEST_DIR}/bin"

  mkdir -p "${MINECRAFT_DIR}/world" \
           "${RUN_DIR}" \
           "${LOG_DIR}" \
           "${MOCK_S3}" \
           "${BIN_DIR}"

  # Paths that backup.sh reads via env overrides
  FIFO="${RUN_DIR}/stdin"
  SERVER_LOG="${LOG_DIR}/server.log"
  BACKUP_LOG="${LOG_DIR}/backup.log"
  LOCK_FILE="${RUN_DIR}/backup.lock"

  # Minimal server.properties
  printf 'level-name=world\nserver-port=25565\n' > "${MINECRAFT_DIR}/server.properties"

  # Create FIFO - backup.sh writes console commands here.
  # A fresh reader is opened by run_backup() before each invocation.
  mkfifo "${FIFO}"

  # AWS mock - writes to a log and simulates S3 using the filesystem.
  # Uses double-quoted heredoc so TEST_DIR, MOCK_S3 expand at write time.
  cat > "${BIN_DIR}/aws" <<AWS_MOCK
#!/bin/bash
AWS_LOG="${TEST_DIR}/aws-calls.log"
MOCK_S3="${MOCK_S3}"
echo "\$*" >> "\${AWS_LOG}"
case "\$1 \$2" in
  "s3 cp")
    # Streaming upload: aws s3 cp - s3://bucket/key
    if [[ "\$3" == "-" ]]; then
      KEY=\$(basename "\$4")
      local_exit=\${AWS_S3_CP_EXIT:-0}
      if [[ "\${local_exit}" -eq 0 ]]; then
        cat > "\${MOCK_S3}/\${KEY}"
      else
        cat > /dev/null
      fi
      exit "\${local_exit}"
    fi
    # Download: aws s3 cp s3://bucket/key localfile
    KEY=\$(basename "\$3")
    cp "\${MOCK_S3}/\${KEY}" "\$4" 2>/dev/null || exit 1
    exit 0
    ;;
  "s3api head-object")
    KEY=\$(echo "\$@" | grep -o -- '--key [^ ]*' | awk '{print \$2}')
    override=\${AWS_HEAD_OBJECT_SIZE:-}
    if [[ -n "\${override}" ]]; then
      echo "\${override}"
      [[ "\${override}" -gt 0 ]] && exit 0 || exit 0
    fi
    if [[ -f "\${MOCK_S3}/\${KEY}" ]]; then
      wc -c < "\${MOCK_S3}/\${KEY}"
      exit 0
    fi
    exit 1
    ;;
  "s3api list-objects-v2")
    ls "\${MOCK_S3}"/minecraft-backup-*.tar.gz 2>/dev/null \\
      | xargs -r -I{} basename {} \\
      | sort \\
      | tr '\\n' '\\t' \\
      | sed 's/\\t\$//'
    exit 0
    ;;
  "s3 rm")
    KEY=\$(basename "\$3")
    rm -f "\${MOCK_S3}/\${KEY}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
AWS_MOCK
  chmod +x "${BIN_DIR}/aws"

  # systemctl mock - default: minecraft.service is active
  cat > "${BIN_DIR}/systemctl" <<SYSTEMCTL_MOCK
#!/bin/bash
exit \${SYSTEMCTL_IS_ACTIVE_EXIT:-0}
SYSTEMCTL_MOCK
  chmod +x "${BIN_DIR}/systemctl"

  # Prepend mock bin directory to PATH for this test
  export PATH="${BIN_DIR}:${PATH}"

  # Required env vars for backup.sh
  export BACKUP_BUCKET="mock-bucket"
  export BACKUP_RETENTION="5"
  export AWS_DEFAULT_REGION="us-west-2"
  export AUTO_FLUSH_SUCCESS=false
  # Short timeouts for fast test execution
  export FLUSH_TIMEOUT=2
  export FIFO_WRITE_TIMEOUT=1

  # Override backup.sh internal paths via environment
  export MINECRAFT_DIR FIFO SERVER_LOG BACKUP_LOG LOCK_FILE

  # Export for use in helper functions
  export TEST_DIR MOCK_S3
}

teardown() {
  rm -rf "${TEST_DIR}"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_backup() {
  # Start the FIFO reader first (reader must open before writer on a FIFO)
  cat "${FIFO}" >> "${TEST_DIR}/fifo-received.txt" &
  local reader_pid=$!
  local flush_pid=""

  # Now open a persistent writer fd - keeps the write-end open so individual
  # printf writes in backup.sh complete immediately without blocking, and
  # the cat reader above doesn't see spurious EOF between writes.
  exec 8>"${FIFO}"

  # Successful backup cases need the flush confirmation to appear after
  # backup.sh has started and recorded the pre-flush log offset.
  if [[ "${AUTO_FLUSH_SUCCESS:-false}" == "true" ]]; then
    (
      sleep 0.2
      printf '[12:00:00] [Server thread/INFO]: Saved the game\n' >> "${SERVER_LOG}"
      sleep 0.2
      printf '[12:00:01] [Server thread/INFO]: Saved the game\n' >> "${SERVER_LOG}"
    ) &
    flush_pid=$!
  fi

  run bash "${BACKUP_SCRIPT}"

  # Close writer, drain reader
  exec 8>&-
  if [[ -n "${flush_pid}" ]]; then
    wait "${flush_pid}" 2>/dev/null || true
  fi
  sleep 0.3
  kill "${reader_pid}" 2>/dev/null || true
  wait "${reader_pid}" 2>/dev/null || true
}

simulate_flush_success() {
  export AUTO_FLUSH_SUCCESS=true
}

# Create N pre-existing backup objects in mock S3
create_mock_backups() {
  local count="$1"
  for i in $(seq 1 "${count}"); do
    printf 'backup-%s\n' "${i}" > "${MOCK_S3}/minecraft-backup-202601$(printf '%02d' "${i}")-000000.tar.gz"
  done
}

# ---------------------------------------------------------------------------
# 1. Service not active - exit cleanly
# ---------------------------------------------------------------------------

@test "exits 0 cleanly when minecraft.service is not active" {
  export SYSTEMCTL_IS_ACTIVE_EXIT=1
  run_backup
  [ "$status" -eq 0 ]
}

@test "logs skip message when service is not active" {
  export SYSTEMCTL_IS_ACTIVE_EXIT=1
  run_backup
  grep -q "not active" "${BACKUP_LOG}"
}

# ---------------------------------------------------------------------------
# 2. Flush timeout - no upload, save-on fired, exit non-zero
# ---------------------------------------------------------------------------

@test "fails with non-zero exit when world flush times out" {
  printf '[12:00:00] [Server thread/INFO]: Starting server\n' > "${SERVER_LOG}"
  run_backup
  [ "$status" -ne 0 ]
}

@test "logs BACKUP_FAILED when flush times out" {
  printf '[12:00:00] [Server thread/INFO]: Starting server\n' > "${SERVER_LOG}"
  run_backup
  grep -q "BACKUP_FAILED" "${BACKUP_LOG}"
  grep -q "timed out" "${BACKUP_LOG}"
}

@test "sends save-on via FIFO when flush times out" {
  printf '[12:00:00] [Server thread/INFO]: Starting server\n' > "${SERVER_LOG}"
  run_backup
  sleep 0.3
  grep -q "save-on" "${TEST_DIR}/fifo-received.txt"
}

@test "does not attempt S3 upload when flush times out" {
  printf '[12:00:00] [Server thread/INFO]: Starting server\n' > "${SERVER_LOG}"
  run_backup
  # No s3 cp call should appear in the aws call log
  if [[ -f "${TEST_DIR}/aws-calls.log" ]]; then
    run grep "s3 cp" "${TEST_DIR}/aws-calls.log"
    [ "$status" -ne 0 ]
  fi
}

@test "does not treat a stale 'Saved the game' line as the current flush confirmation" {
  printf '[11:59:00] [Server thread/INFO]: Saved the game\n' > "${SERVER_LOG}"
  run_backup
  [ "$status" -ne 0 ]
  grep -q "timed out" "${BACKUP_LOG}"
}

# ---------------------------------------------------------------------------
# 3. Upload failure - no pruning, save-on fired, exit non-zero
# ---------------------------------------------------------------------------

@test "fails with non-zero exit when S3 upload fails" {
  simulate_flush_success
  export AWS_S3_CP_EXIT=1
  run_backup
  [ "$status" -ne 0 ]
}

@test "logs BACKUP_FAILED when S3 upload fails" {
  simulate_flush_success
  export AWS_S3_CP_EXIT=1
  run_backup
  grep -q "BACKUP_FAILED" "${BACKUP_LOG}"
}

@test "does not prune existing backups when S3 upload fails" {
  simulate_flush_success
  create_mock_backups 3
  export AWS_S3_CP_EXIT=1
  run_backup
  local count
  count=$(ls "${MOCK_S3}"/minecraft-backup-*.tar.gz 2>/dev/null | wc -l)
  [ "$count" -eq 3 ]
}

@test "sends save-on when S3 upload fails" {
  simulate_flush_success
  export AWS_S3_CP_EXIT=1
  run_backup
  sleep 0.3
  grep -q "save-on" "${TEST_DIR}/fifo-received.txt"
}

# ---------------------------------------------------------------------------
# 4. Upload verification failure - no pruning, exit non-zero
# ---------------------------------------------------------------------------

@test "fails with non-zero exit when head-object returns zero size" {
  simulate_flush_success
  export AWS_HEAD_OBJECT_SIZE=0
  run_backup
  [ "$status" -ne 0 ]
}

@test "logs BACKUP_FAILED when upload verification fails" {
  simulate_flush_success
  export AWS_HEAD_OBJECT_SIZE=0
  run_backup
  grep -q "BACKUP_FAILED" "${BACKUP_LOG}"
}

@test "does not prune backups when verification fails" {
  simulate_flush_success
  create_mock_backups 3
  export AWS_HEAD_OBJECT_SIZE=0
  run_backup
  local count
  count=$(ls "${MOCK_S3}"/minecraft-backup-*.tar.gz 2>/dev/null | wc -l)
  [ "$count" -ge 3 ]
}

# ---------------------------------------------------------------------------
# 5. Successful backup
# ---------------------------------------------------------------------------

@test "exits 0 on successful backup" {
  simulate_flush_success
  run_backup
  [ "$status" -eq 0 ]
}

@test "logs BACKUP_SUCCESS on a successful backup" {
  simulate_flush_success
  run_backup
  grep -q "BACKUP_SUCCESS" "${BACKUP_LOG}"
}

@test "sends save-off and save-all flush before archiving" {
  simulate_flush_success
  run_backup
  sleep 0.3
  grep -q "save-off" "${TEST_DIR}/fifo-received.txt"
  grep -q "save-all flush" "${TEST_DIR}/fifo-received.txt"
}

@test "sends save-on after a successful backup" {
  simulate_flush_success
  run_backup
  sleep 0.3
  grep -q "save-on" "${TEST_DIR}/fifo-received.txt"
}

@test "uploads exactly one backup object to S3 on success" {
  simulate_flush_success
  run_backup
  local count
  count=$(ls "${MOCK_S3}"/minecraft-backup-*.tar.gz 2>/dev/null | wc -l)
  [ "$count" -eq 1 ]
}

@test "backup archive contains the world directory" {
  simulate_flush_success
  printf 'chunk data\n' > "${MINECRAFT_DIR}/world/r.0.0.mca"
  run_backup
  [ "$status" -eq 0 ]
  local archive
  archive=$(ls "${MOCK_S3}"/minecraft-backup-*.tar.gz 2>/dev/null | head -1)
  [ -n "${archive}" ]
  tar -tzf "${archive}" | grep -q "world/"
}

@test "backup archive contains server.properties" {
  simulate_flush_success
  run_backup
  [ "$status" -eq 0 ]
  local archive
  archive=$(ls "${MOCK_S3}"/minecraft-backup-*.tar.gz 2>/dev/null | head -1)
  [ -n "${archive}" ]
  tar -tzf "${archive}" | grep -q "server.properties"
}

@test "succeeds when optional files ops.json and banned-players.json are absent" {
  simulate_flush_success
  # No ops.json or banned-players.json present
  run_backup
  [ "$status" -eq 0 ]
  grep -q "BACKUP_SUCCESS" "${BACKUP_LOG}"
}

@test "uses level-name from server.properties for world directory" {
  simulate_flush_success
  printf 'level-name=myworld\nserver-port=25565\n' > "${MINECRAFT_DIR}/server.properties"
  mkdir -p "${MINECRAFT_DIR}/myworld"
  printf 'chunk\n' > "${MINECRAFT_DIR}/myworld/r.0.0.mca"
  run_backup
  [ "$status" -eq 0 ]
  local archive
  archive=$(ls "${MOCK_S3}"/minecraft-backup-*.tar.gz 2>/dev/null | head -1)
  [ -n "${archive}" ]
  tar -tzf "${archive}" | grep -q "myworld/"
}

# ---------------------------------------------------------------------------
# 6. Pruning
# ---------------------------------------------------------------------------

@test "prunes oldest backups to the retention count after a successful backup" {
  simulate_flush_success
  create_mock_backups 6   # 6 existing + 1 new = 7, retention=5 -> prune to 5
  run_backup
  [ "$status" -eq 0 ]
  local count
  count=$(ls "${MOCK_S3}"/minecraft-backup-*.tar.gz 2>/dev/null | wc -l)
  [ "$count" -le 5 ]
}

@test "does not prune when total backups are within retention limit" {
  simulate_flush_success
  create_mock_backups 2   # 2 existing + 1 new = 3, under retention of 5
  run_backup
  [ "$status" -eq 0 ]
  local count
  count=$(ls "${MOCK_S3}"/minecraft-backup-*.tar.gz 2>/dev/null | wc -l)
  [ "$count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# 7. Concurrent run prevention (flock)
# ---------------------------------------------------------------------------

@test "second concurrent invocation exits with error when lock is held" {
  simulate_flush_success

  # Hold the lock in the background
  exec 9>"${LOCK_FILE}"
  flock -n 9

  run_backup

  [ "$status" -ne 0 ]
  grep -q "another backup is already running" "${BACKUP_LOG}"

  exec 9>&-
}
