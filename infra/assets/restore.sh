#!/bin/bash
# restore.sh — Restore a Minecraft world backup from S3.
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
#   BACKUP_BUCKET      — S3 bucket name
#   AWS_DEFAULT_REGION — AWS region
#
# See docs/backup-and-restore.md for a complete restoration walkthrough.

set -euo pipefail

MINECRAFT_DIR="/opt/minecraft"
BACKUP_LOG="/var/log/minecraft/backup.log"
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
  echo "=== DRY-RUN mode — no changes will be made ==="
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

# ---- Stop Minecraft service --------------------------------------------------
log "Stopping minecraft.service..."
if systemctl is-active --quiet minecraft.service; then
  run systemctl stop minecraft.service
  log "minecraft.service stopped"
else
  log "minecraft.service was not running"
fi

# ---- Download backup ---------------------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

ARCHIVE="${TMPDIR}/restore.tar.gz"
log "Downloading s3://${BUCKET}/${BACKUP_KEY} ..."
run aws s3 cp "s3://${BUCKET}/${BACKUP_KEY}" "${ARCHIVE}" --region "${REGION}"

# ---- Safety copy of existing world data -------------------------------------
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)

# Read level-name from server.properties
LEVEL_NAME="world"
PROPS_FILE="${MINECRAFT_DIR}/server.properties"
if [[ -f "${PROPS_FILE}" ]]; then
  LEVEL_NAME_RAW=$(grep '^level-name=' "${PROPS_FILE}" | cut -d= -f2 | tr -d '[:space:]')
  [[ -n "${LEVEL_NAME_RAW}" ]] && LEVEL_NAME="${LEVEL_NAME_RAW}"
fi

log "Current level-name: '${LEVEL_NAME}'"

# Rename existing world directories (preserves them, does not delete)
for dir in \
  "${MINECRAFT_DIR}/${LEVEL_NAME}" \
  "${MINECRAFT_DIR}/${LEVEL_NAME}_nether" \
  "${MINECRAFT_DIR}/${LEVEL_NAME}_the_end"; do
  if [[ -d "${dir}" ]]; then
    BACKUP_NAME="${dir}.pre-restore.${TIMESTAMP}"
    log "Renaming ${dir} -> ${BACKUP_NAME}"
    run mv "${dir}" "${BACKUP_NAME}"
  fi
done

# ---- Extract archive ---------------------------------------------------------
log "Extracting ${BACKUP_KEY} into ${MINECRAFT_DIR}/ ..."
if [[ "${DRY_RUN}" == "true" ]]; then
  dry_log "tar -xzf ${ARCHIVE} -C ${MINECRAFT_DIR}/"
  dry_log "chown -R minecraft:minecraft ${MINECRAFT_DIR}/"
else
  tar -xzf "${ARCHIVE}" -C "${MINECRAFT_DIR}/"
  chown -R minecraft:minecraft "${MINECRAFT_DIR}/"
fi

# ---- Start Minecraft service -------------------------------------------------
log "Starting minecraft.service..."
run systemctl start minecraft.service

log "Restore complete. Server started with backup: ${BACKUP_KEY}"
log "Pre-restore world data preserved at: ${MINECRAFT_DIR}/${LEVEL_NAME}.pre-restore.${TIMESTAMP}"
log ""
log "IMPORTANT: Verify the server started correctly:"
log "  systemctl status minecraft.service"
log "  tail -f /var/log/minecraft/server.log"
