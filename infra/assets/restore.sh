#!/bin/bash
# restore.sh - Restore a Minecraft world backup from S3.
#
# Usage:
#   restore.sh [--backup-key <s3-key>] [--dry-run]
#
# Options:
#   --backup-key <key>   S3 object key to restore (e.g. minecraft-backup-20260101-120000.tar.gz)
#                        If omitted, lists available backups and prompts for selection.
#   --dry-run            Print all steps without executing any changes.
#
# Required environment variables (set in /opt/minecraft/minecraft-env):
#   BACKUP_BUCKET      - S3 bucket name
#   AWS_DEFAULT_REGION - AWS region
#
# Restore sequence:
#   1. Select the backup (list-and-prompt, or --backup-key).
#   2. Download the archive.
#   3. Validate it's a well-formed tar.gz (tar -tzf) - no state touched yet.
#   4. Extract into a staging directory alongside the live data (same
#      filesystem, so the later swap-in is an instant rename, not a copy).
#   5. Verify the staged extraction actually contains the expected world
#      directory - no state touched yet.
#   6. Only now stop minecraft.service.
#   7. Rename the current world directories aside as a rollback copy.
#   8. Move the staged world into place and start minecraft.service.
#   9. Wait for the server to report ready in server.log. If it doesn't
#      come up healthy in time, roll back: preserve the failed attempt,
#      restore the rollback copy, and restart with the known-good world.
#
# Every failure through step 5 leaves minecraft.service untouched - the
# server keeps running the whole time a backup is being downloaded,
# validated, and staged. Only steps 6-9 involve any real downtime, and
# steps 8-9 are the only ones that can trigger an automatic rollback,
# since only from step 7 onward does a rollback copy exist to roll back to.
#
# See docs/backup-and-restore.md for a complete restoration walkthrough.

set -euo pipefail
shopt -s dotglob

# ---- Configuration -------------------------------------------------------
# Path variables use environment overrides when set, falling back to
# production defaults - mirrors backup.sh, so test harnesses can inject
# isolated paths without modifying the script itself.
MINECRAFT_DIR="${MINECRAFT_DIR:-/opt/minecraft}"
BACKUP_LOG="${BACKUP_LOG:-/var/log/minecraft/backup.log}"
SERVER_LOG="${SERVER_LOG:-/var/log/minecraft/server.log}"
STAGING_DIR="${STAGING_DIR:-${MINECRAFT_DIR}/.restore-staging}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-90}"

BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET environment variable is not set}"
REGION="${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION is not set}"
S3_PREFIX="minecraft-backup"

BACKUP_KEY=""
DRY_RUN=false

# ---- Logging -----------------------------------------------------------------
log() {
  local msg
  msg="$(date -u --iso-8601=seconds) [restore] $*"
  echo "$msg"
  echo "$msg" >> "${BACKUP_LOG}" 2>/dev/null || true
}

dry_log() {
  echo "[DRY-RUN] $*"
}

run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    dry_log "$*"
  else
    "$@"
  fi
}

# ---- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-key)
      BACKUP_KEY="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--backup-key <s3-key>] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "=== DRY-RUN mode - no changes will be made ==="
fi

# ---- Select backup -----------------------------------------------------------
if [[ -z "${BACKUP_KEY}" ]]; then
  log "Listing available backups in s3://${BUCKET}/ ..."

  mapfile -t KEYS < <(
    aws s3api list-objects-v2 \
      --bucket "${BUCKET}" \
      --prefix "${S3_PREFIX}" \
      --region "${REGION}" \
      --query 'sort_by(Contents, &LastModified)[].Key' \
      --output text \
      2>/dev/null \
    | tr '\t' '\n' \
    | grep -v '^None$' \
    | grep -v '^$'
  )

  if [[ ${#KEYS[@]} -eq 0 ]]; then
    log "ERROR: no backups found in s3://${BUCKET}/"
    exit 1
  fi

  echo ""
  echo "Available backups:"
  for i in "${!KEYS[@]}"; do
    echo "  $((i + 1)). ${KEYS[$i]}"
  done
  echo ""

  if [[ "${DRY_RUN}" == "true" ]]; then
    dry_log "Would prompt: Enter backup number [1-${#KEYS[@]}]"
    BACKUP_KEY="${KEYS[0]}"
    dry_log "Dry-run selecting: ${BACKUP_KEY}"
  else
    read -r -p "Enter backup number [1-${#KEYS[@]}]: " SELECTION
    if ! [[ "${SELECTION}" =~ ^[0-9]+$ ]] || \
       [[ "${SELECTION}" -lt 1 ]] || \
       [[ "${SELECTION}" -gt ${#KEYS[@]} ]]; then
      echo "Invalid selection: ${SELECTION}" >&2
      exit 1
    fi
    BACKUP_KEY="${KEYS[$((SELECTION - 1))]}"
  fi
fi

log "Selected backup: s3://${BUCKET}/${BACKUP_KEY}"

# Read level-name from the *live* server.properties. This determines both
# what's currently active (renamed aside as the rollback copy) and what
# directory name we expect to find in the restored archive.
LEVEL_NAME="world"
PROPS_FILE="${MINECRAFT_DIR}/server.properties"
if [[ -f "${PROPS_FILE}" ]]; then
  LEVEL_NAME_RAW=$(grep '^level-name=' "${PROPS_FILE}" | cut -d= -f2 | tr -d '[:space:]')
  [[ -n "${LEVEL_NAME_RAW}" ]] && LEVEL_NAME="${LEVEL_NAME_RAW}"
fi
log "Current level-name: '${LEVEL_NAME}'"

# ---- Download backup ---------------------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

ARCHIVE="${TMPDIR}/restore.tar.gz"
log "Downloading s3://${BUCKET}/${BACKUP_KEY} ..."
run aws s3 cp "s3://${BUCKET}/${BACKUP_KEY}" "${ARCHIVE}" --region "${REGION}"

# ---- Validate archive (no state touched yet) ---------------------------------
log "Validating archive..."
if [[ "${DRY_RUN}" == "true" ]]; then
  dry_log "tar -tzf ${ARCHIVE}"
else
  if ! tar -tzf "${ARCHIVE}" > /dev/null 2>&1; then
    log "BACKUP_FAILED: ${BACKUP_KEY} is not a valid tar.gz archive - aborting (minecraft.service was not touched)"
    exit 1
  fi
fi

# ---- Extract into staging (same filesystem as MINECRAFT_DIR, so the later
#      swap-in is an instant rename rather than a cross-device copy) --------
log "Extracting into staging directory ${STAGING_DIR} ..."
if [[ "${DRY_RUN}" == "true" ]]; then
  dry_log "rm -rf ${STAGING_DIR} && mkdir -p ${STAGING_DIR}"
  dry_log "tar -xzf ${ARCHIVE} -C ${STAGING_DIR}"
else
  rm -rf "${STAGING_DIR}"
  mkdir -p "${STAGING_DIR}"
  tar -xzf "${ARCHIVE}" -C "${STAGING_DIR}"
fi

# ---- Verify staged content before touching anything live -------------------
if [[ "${DRY_RUN}" == "true" ]]; then
  dry_log "Would verify ${STAGING_DIR}/${LEVEL_NAME} exists"
else
  if [[ ! -d "${STAGING_DIR}/${LEVEL_NAME}" ]]; then
    log "BACKUP_FAILED: ${BACKUP_KEY} does not contain expected world directory '${LEVEL_NAME}/' - aborting (minecraft.service was not touched)"
    rm -rf "${STAGING_DIR}"
    exit 1
  fi
  log "Verified staged archive contains '${LEVEL_NAME}/'"
fi

# ---- Stop Minecraft service (first point of any real downtime) --------------
log "Stopping minecraft.service..."
if systemctl is-active --quiet minecraft.service; then
  run systemctl stop minecraft.service
  log "minecraft.service stopped"
else
  log "minecraft.service was not running"
fi

# ---- Rename current world aside as a rollback copy ---------------------------
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)

for dir in \
  "${MINECRAFT_DIR}/${LEVEL_NAME}" \
  "${MINECRAFT_DIR}/${LEVEL_NAME}_nether" \
  "${MINECRAFT_DIR}/${LEVEL_NAME}_the_end"; do
  if [[ -d "${dir}" ]]; then
    ROLLBACK_NAME="${dir}.pre-restore.${TIMESTAMP}"
    log "Renaming ${dir} -> ${ROLLBACK_NAME}"
    run mv "${dir}" "${ROLLBACK_NAME}"
  fi
done

# ---- Swap the staged world into place, start, and health-check --------------
# On any failure in this region, roll_back() restores the pre-restore copy
# and restarts the server with it. set -e is deliberately not allowed to
# abort mid-way here: do_swap_and_start is only ever invoked as an `if`
# condition, and every command inside it that we care about is explicitly
# checked (`|| return 1`) rather than left to errexit.
do_swap_and_start() {
  for entry in "${STAGING_DIR}"/*; do
    [[ -e "${entry}" ]] || continue
    mv "${entry}" "${MINECRAFT_DIR}/$(basename "${entry}")" || return 1
  done
  rm -rf "${STAGING_DIR}"
  chown -R minecraft:minecraft "${MINECRAFT_DIR}" || return 1

  log "Starting minecraft.service..."
  local log_size_before_start
  log_size_before_start=$(wc -c < "${SERVER_LOG}" 2>/dev/null || echo 0)
  systemctl start minecraft.service || return 1

  log "Waiting up to ${STARTUP_TIMEOUT}s for minecraft.service to report ready..."
  local elapsed=0
  local confirmed=false
  while [[ ${elapsed} -lt ${STARTUP_TIMEOUT} ]]; do
    if tail -c "+$((log_size_before_start + 1))" "${SERVER_LOG}" 2>/dev/null | grep -q 'Done ('; then
      confirmed=true
      break
    fi
    if ! systemctl is-active --quiet minecraft.service; then
      log "minecraft.service is not active after start - not waiting further"
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  [[ "${confirmed}" == "true" ]]
}

roll_back() {
  log "BACKUP_FAILED: restore of ${BACKUP_KEY} did not come up healthy - rolling back"
  systemctl stop minecraft.service 2>/dev/null || true

  for dir in \
    "${MINECRAFT_DIR}/${LEVEL_NAME}" \
    "${MINECRAFT_DIR}/${LEVEL_NAME}_nether" \
    "${MINECRAFT_DIR}/${LEVEL_NAME}_the_end"; do
    ROLLBACK_NAME="${dir}.pre-restore.${TIMESTAMP}"
    if [[ -d "${dir}" ]]; then
      FAILED_NAME="${dir}.failed-restore.${TIMESTAMP}"
      log "Preserving failed restore: ${dir} -> ${FAILED_NAME}"
      mv "${dir}" "${FAILED_NAME}"
    fi
    if [[ -d "${ROLLBACK_NAME}" ]]; then
      log "Restoring previous world: ${ROLLBACK_NAME} -> ${dir}"
      mv "${ROLLBACK_NAME}" "${dir}"
    fi
  done

  log "Starting minecraft.service with rolled-back world data..."
  systemctl start minecraft.service || true

  log "BACKUP_FAILED: rollback complete. Server restarted with the pre-restore world."
  log "  Failed restore attempt (if preserved) is under: ${MINECRAFT_DIR}/${LEVEL_NAME}.failed-restore.${TIMESTAMP}"
  log "  Verify manually: systemctl status minecraft.service ; tail -f /var/log/minecraft/server.log"
}

if [[ "${DRY_RUN}" == "true" ]]; then
  dry_log "Would move staged content from ${STAGING_DIR} into ${MINECRAFT_DIR}/"
  dry_log "Would start minecraft.service and wait up to ${STARTUP_TIMEOUT}s for it to report ready"
  dry_log "On failure, would roll back to the pre-restore world"
else
  if do_swap_and_start; then
    log "BACKUP_SUCCESS: minecraft.service is running with restored backup ${BACKUP_KEY}"
    log "Pre-restore world data preserved at: ${MINECRAFT_DIR}/${LEVEL_NAME}.pre-restore.${TIMESTAMP}"
    log ""
    log "IMPORTANT: Verify the server started correctly:"
    log "  systemctl status minecraft.service"
    log "  tail -f /var/log/minecraft/server.log"
  else
    roll_back
    exit 1
  fi
fi
