#!/bin/bash
# backup.sh - Minecraft hourly world backup.
#
# Triggered by minecraft-backup.timer (systemd). Can also be run manually.
#
# Backup sequence:
#   1. Check minecraft.service is active - exit cleanly if not.
#   2. Acquire flock to prevent overlapping backups.
#   3. Install EXIT trap to send "save-on" unconditionally on exit.
#   4. Read level-name from server.properties.
#   5. Send "save-off" then "save-all flush" via the FIFO console.
#   6. Poll server.log for "Saved the game" confirmation (30-second timeout).
#   7. Stream tar archive directly to S3 - no disk staging.
#   8. Verify upload via head-object (presence check, not integrity validation).
#   9. Prune backups beyond retention count - only on success.
#  10. EXIT trap fires "save-on" unconditionally.
#
# Required environment variables (set in /opt/minecraft/minecraft-env):
#   BACKUP_BUCKET      - S3 bucket name
#   BACKUP_RETENTION   - number of backups to keep (default: 5)
#   AWS_DEFAULT_REGION - AWS region

set -euo pipefail

# ---- Configuration -----------------------------------------------------------
# Path variables use environment overrides when set, falling back to production
# defaults. This allows test harnesses to inject isolated paths without modifying
# the script itself.
MINECRAFT_DIR="${MINECRAFT_DIR:-/opt/minecraft}"
FIFO="${FIFO:-/run/minecraft/stdin}"
SERVER_LOG="${SERVER_LOG:-/var/log/minecraft/server.log}"
BACKUP_LOG="${BACKUP_LOG:-/var/log/minecraft/backup.log}"
LOCK_FILE="${LOCK_FILE:-/run/minecraft/backup.lock}"

BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET environment variable is not set}"
RETENTION="${BACKUP_RETENTION:-5}"
FLUSH_TIMEOUT="${FLUSH_TIMEOUT:-30}"
FIFO_WRITE_TIMEOUT="${FIFO_WRITE_TIMEOUT:-5}"
S3_PREFIX="minecraft-backup"

# ---- Logging -----------------------------------------------------------------
log() {
  echo "$(date -u --iso-8601=seconds) $*" >> "${BACKUP_LOG}"
}

# ---- Guard: check minecraft.service is active --------------------------------
# Exit cleanly (exit 0) if the server is not running - the timer fires even
# when the instance is running but the server is down for maintenance.
if ! systemctl is-active --quiet minecraft.service; then
  log "INFO: minecraft.service is not active - skipping backup"
  exit 0
fi

# ---- Acquire lock (non-blocking) --------------------------------------------
# Prevents overlapping backups if a previous run is still in progress.
# The lock file lives in the RuntimeDirectory (/run/minecraft) which is owned
# by the minecraft user.
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log "BACKUP_FAILED: another backup is already running (lock: ${LOCK_FILE})"
  exit 1
fi

# ---- EXIT trap: always re-enable auto-saves ----------------------------------
# This fires on any exit - success, failure, or signal.
# The write to the FIFO uses a 5-second timeout so it never blocks indefinitely
# if there is no reader (e.g. the server has already stopped).
# The write is best-effort: if there is no reader the write will block briefly
# until the kernel timeout (FIFO_WRITE_TIMEOUT seconds) or succeed immediately.
_fifo_write() {
  timeout "${FIFO_WRITE_TIMEOUT}s" bash -c "printf '%s\n' \"$1\" > \"${FIFO}\"" 2>/dev/null || true
}
trap '_fifo_write "save-on"; log "INFO: save-on sent"' EXIT

# ---- Read level-name from server.properties ----------------------------------
PROPS_FILE="${MINECRAFT_DIR}/server.properties"
LEVEL_NAME="world" # safe default

if [[ -f "${PROPS_FILE}" ]]; then
  LEVEL_NAME_RAW="$(
    grep '^level-name=' "${PROPS_FILE}" 2>/dev/null \
      | cut -d= -f2 \
      | tr -d '[:space:]' \
      || true
  )"
  if [[ -n "${LEVEL_NAME_RAW}" ]]; then
    LEVEL_NAME="${LEVEL_NAME_RAW}"
  fi
fi

log "INFO: starting backup (level-name='${LEVEL_NAME}')"

# ---- Safe flush: save-off then save-all flush --------------------------------
LOG_SIZE_BEFORE_FLUSH=$(wc -c < "${SERVER_LOG}" 2>/dev/null || echo 0)
_fifo_write "save-off"
_fifo_write "save-all flush"

# Poll server.log for "Saved the game" confirmation
ELAPSED=0
FLUSH_CONFIRMED=false
while [[ ${ELAPSED} -lt ${FLUSH_TIMEOUT} ]]; do
  # Only consider log bytes written after this backup requested a flush.
  if tail -c "+$((LOG_SIZE_BEFORE_FLUSH + 1))" "${SERVER_LOG}" 2>/dev/null | grep -q "Saved the game"; then
    FLUSH_CONFIRMED=true
    break
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

if [[ "${FLUSH_CONFIRMED}" != "true" ]]; then
  log "BACKUP_FAILED: world flush timed out after ${FLUSH_TIMEOUT}s (no 'Saved the game' in log)"
  exit 1
fi

log "INFO: world flush confirmed after ${ELAPSED}s"

# ---- Build tar path array (only existing paths) ------------------------------
declare -a TAR_PATHS=()

# World directories (level-name and dimension variants)
[[ -d "${MINECRAFT_DIR}/${LEVEL_NAME}" ]]           && TAR_PATHS+=("${LEVEL_NAME}/")
[[ -d "${MINECRAFT_DIR}/${LEVEL_NAME}_nether" ]]    && TAR_PATHS+=("${LEVEL_NAME}_nether/")
[[ -d "${MINECRAFT_DIR}/${LEVEL_NAME}_the_end" ]]   && TAR_PATHS+=("${LEVEL_NAME}_the_end/")

# Required config files
[[ -f "${MINECRAFT_DIR}/server.properties" ]]       && TAR_PATHS+=("server.properties")

# Optional files - included only if present
[[ -f "${MINECRAFT_DIR}/whitelist.json" ]]          && TAR_PATHS+=("whitelist.json")
[[ -f "${MINECRAFT_DIR}/ops.json" ]]                && TAR_PATHS+=("ops.json")
[[ -f "${MINECRAFT_DIR}/banned-players.json" ]]     && TAR_PATHS+=("banned-players.json")
[[ -f "${MINECRAFT_DIR}/banned-ips.json" ]]         && TAR_PATHS+=("banned-ips.json")

if [[ ${#TAR_PATHS[@]} -eq 0 ]]; then
  log "BACKUP_FAILED: no world data found under ${MINECRAFT_DIR} (level-name='${LEVEL_NAME}')"
  exit 1
fi

log "INFO: archiving: ${TAR_PATHS[*]}"

# ---- Stream tar directly to S3 - no disk staging ----------------------------
KEY="${S3_PREFIX}-$(date -u +%Y%m%d-%H%M%S).tar.gz"

log "INFO: uploading to s3://${BUCKET}/${KEY}"

# tar streams to stdout; aws s3 cp reads from stdin.
# Errors in either command cause the pipeline to fail (set -o pipefail).
tar -czf - \
  -C "${MINECRAFT_DIR}" \
  "${TAR_PATHS[@]}" \
  | aws s3 cp - "s3://${BUCKET}/${KEY}" \
      --region "${AWS_DEFAULT_REGION}" \
      --content-type "application/gzip" || {
  log "BACKUP_FAILED: S3 upload failed for s3://${BUCKET}/${KEY}"
  exit 1
}

# ---- Verify upload (presence check) -----------------------------------------
# head-object confirms the object exists in S3 and has non-zero size.
# This is an upload presence check, not a full archive integrity validation.
CONTENT_LENGTH=$(aws s3api head-object \
  --bucket "${BUCKET}" \
  --key "${KEY}" \
  --region "${AWS_DEFAULT_REGION}" \
  --query 'ContentLength' \
  --output text 2>/dev/null || echo "0")

if [[ "${CONTENT_LENGTH}" == "None" ]] || [[ "${CONTENT_LENGTH}" -le 0 ]]; then
  log "BACKUP_FAILED: S3 object verification failed for s3://${BUCKET}/${KEY} (ContentLength=${CONTENT_LENGTH})"
  exit 1
fi

log "INFO: upload verified (ContentLength=${CONTENT_LENGTH} bytes)"

# ---- Prune old backups - only on successful upload --------------------------
# List all backup objects, sort oldest-first, delete any beyond retention count.
log "INFO: pruning backups (retention=${RETENTION})"

# Get list of backup keys sorted by LastModified (oldest first)
mapfile -t ALL_KEYS < <(
  aws s3api list-objects-v2 \
    --bucket "${BUCKET}" \
    --prefix "${S3_PREFIX}" \
    --region "${AWS_DEFAULT_REGION}" \
    --query 'sort_by(Contents, &LastModified)[].Key' \
    --output text \
    2>/dev/null \
  | tr '\t' '\n' \
  | grep -v '^None$' \
  | grep -v '^$'
)

TOTAL=${#ALL_KEYS[@]}
log "INFO: found ${TOTAL} backup(s) in S3"

if [[ ${TOTAL} -gt ${RETENTION} ]]; then
  DELETE_COUNT=$((TOTAL - RETENTION))
  log "INFO: deleting ${DELETE_COUNT} old backup(s)"

  for (( i=0; i<DELETE_COUNT; i++ )); do
    OLD_KEY="${ALL_KEYS[$i]}"
    log "INFO: deleting s3://${BUCKET}/${OLD_KEY}"
    aws s3 rm "s3://${BUCKET}/${OLD_KEY}" --region "${AWS_DEFAULT_REGION}"
  done
else
  log "INFO: no pruning needed (${TOTAL} <= ${RETENTION})"
fi

log "BACKUP_SUCCESS: s3://${BUCKET}/${KEY} (${CONTENT_LENGTH} bytes)"
# EXIT trap fires here: "save-on" is sent to the server
