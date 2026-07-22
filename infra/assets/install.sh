#!/bin/bash
# install.sh - Minecraft server bootstrap installer.
#
# Runs as root on first boot via EC2 user-data, and can be re-run manually
# via SSM Session Manager to apply updates (see docs/operations.md).
#
# Required environment variables (injected by CDK user-data):
#   MINECRAFT_EULA_ACCEPTED  - must be "true" (operator must accept EULA first)
#   MINECRAFT_VERSION        - e.g. "26.1.2"
#   MINECRAFT_PORT           - e.g. "25565"
#   JAVA_XMS                 - e.g. "2G"
#   JAVA_XMX                 - e.g. "2G"
#   BACKUP_BUCKET            - S3 bucket name for backups
#   BACKUP_RETENTION         - number of backups to keep, e.g. "5"
#   EBS_VOLUME_ID            - EBS volume ID, e.g. "vol-0abc1234"
#   AWS_DEFAULT_REGION       - AWS region

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINECRAFT_DIR="/opt/minecraft"
MINECRAFT_USER="minecraft"
LOG_DIR="/var/log/minecraft"
MARKER_FILE="${MINECRAFT_DIR}/.bootstrap-complete"

log() {
  echo "[install.sh] $(date -u --iso-8601=seconds) $*"
}

# ---- Guard: EULA acceptance --------------------------------------------------
# The Minecraft EULA must be read and accepted before deploying:
#   https://aka.ms/MinecraftEULA
# Set minecraftEulaAccepted=true in infra/config/server-config.ts only after
# you have read and accepted the EULA. Do not commit that change.
if [[ "${MINECRAFT_EULA_ACCEPTED:-false}" != "true" ]]; then
  echo "ERROR: Minecraft EULA has not been accepted." >&2
  echo "       Read https://aka.ms/MinecraftEULA, then set" >&2
  echo "       minecraftEulaAccepted=true in infra/config/server-config.ts" >&2
  echo "       Do not commit this change to version control." >&2
  exit 1
fi

log "Starting Minecraft server installation"
log "Minecraft version: ${MINECRAFT_VERSION}"
log "EBS volume: ${EBS_VOLUME_ID}"

# ---- Java 25 (Amazon Corretto) -----------------------------------------------
log "Installing Amazon Corretto 25..."
if ! java -version 2>&1 | grep -q 'openjdk version "25'; then
  yum install -y java-25-amazon-corretto-headless
else
  log "Amazon Corretto 25 already installed, skipping"
fi

# ---- CloudWatch agent --------------------------------------------------------
log "Installing Amazon CloudWatch agent..."
if ! command -v amazon-cloudwatch-agent-ctl &>/dev/null; then
  yum install -y amazon-cloudwatch-agent
else
  log "CloudWatch agent already installed, skipping"
fi

# ---- Minecraft system user ---------------------------------------------------
if ! id "${MINECRAFT_USER}" &>/dev/null; then
  log "Creating system user: ${MINECRAFT_USER}"
  useradd --system --no-create-home --shell /sbin/nologin "${MINECRAFT_USER}"
else
  log "User ${MINECRAFT_USER} already exists, skipping"
fi

# ---- EBS volume: identify, format (if needed), mount ------------------------
log "Identifying EBS device for volume ${EBS_VOLUME_ID}..."
DEVICE=""
for attempt in $(seq 1 180); do
  if DEVICE=$("${SCRIPT_DIR}/find-ebs-device.sh" "${EBS_VOLUME_ID}" 2>/dev/null); then
    break
  fi
  log "EBS device not visible yet (attempt ${attempt}/180), retrying in 2s..."
  sleep 2
done

if [[ -z "${DEVICE}" ]]; then
  echo "ERROR: Timed out waiting for EBS volume ${EBS_VOLUME_ID} to appear." >&2
  exit 1
fi

log "Found device: ${DEVICE}"

# Format only if no filesystem is present (idempotent)
if ! blkid -s TYPE "${DEVICE}" &>/dev/null; then
  log "No filesystem found on ${DEVICE}, formatting with ext4..."
  mkfs.ext4 -L minecraft "${DEVICE}"
  log "Filesystem created"
else
  FS_TYPE=$(blkid -s TYPE -o value "${DEVICE}")
  log "Filesystem already present on ${DEVICE}: ${FS_TYPE}"
fi

# Get stable UUID for fstab entry
FS_UUID=$(blkid -s UUID -o value "${DEVICE}")
log "Filesystem UUID: ${FS_UUID}"

# Create mount point
mkdir -p "${MINECRAFT_DIR}"

# Add fstab entry if not already present (mount by UUID for stability)
if ! grep -q "${FS_UUID}" /etc/fstab; then
  log "Adding fstab entry for UUID=${FS_UUID}..."
  echo "UUID=${FS_UUID}  ${MINECRAFT_DIR}  ext4  defaults,nofail  0  2" >> /etc/fstab
fi

# Mount if not already mounted
if ! mountpoint -q "${MINECRAFT_DIR}"; then
  log "Mounting ${MINECRAFT_DIR}..."
  mount "${MINECRAFT_DIR}"
fi

# ---- Directory structure and ownership ---------------------------------------
log "Creating directory structure under ${MINECRAFT_DIR}..."
mkdir -p "${MINECRAFT_DIR}"
mkdir -p "${LOG_DIR}"
chown -R "${MINECRAFT_USER}:${MINECRAFT_USER}" "${MINECRAFT_DIR}" "${LOG_DIR}"

# ---- Minecraft server JAR ----------------------------------------------------
JAR_PATH="${MINECRAFT_DIR}/server.jar"

if [[ ! -f "${JAR_PATH}" ]]; then
  log "Downloading Minecraft server JAR version ${MINECRAFT_VERSION}..."

  MANIFEST_URL="https://launchermeta.mojang.com/mc/game/version_manifest_v2.json"
  MANIFEST=$(curl -fsSL "${MANIFEST_URL}")

  VERSION_URL=$(echo "${MANIFEST}" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for v in data['versions']:
    if v['id'] == '${MINECRAFT_VERSION}':
        print(v['url'])
        break
else:
    sys.exit(1)
" 2>/dev/null) || {
    echo "ERROR: Minecraft version '${MINECRAFT_VERSION}' not found in version manifest." >&2
    echo "       Check https://launchermeta.mojang.com/mc/game/version_manifest_v2.json" >&2
    exit 1
  }

  VERSION_META=$(curl -fsSL "${VERSION_URL}")
  SERVER_URL=$(echo "${VERSION_META}" \
    | python3 -c "import json, sys; print(json.load(sys.stdin)['downloads']['server']['url'])")
  SERVER_SHA1=$(echo "${VERSION_META}" \
    | python3 -c "import json, sys; print(json.load(sys.stdin)['downloads']['server']['sha1'])")

  curl -fsSL -o "${JAR_PATH}.tmp" "${SERVER_URL}"

  # Verify SHA1 checksum
  ACTUAL_SHA1=$(sha1sum "${JAR_PATH}.tmp" | cut -d' ' -f1)
  if [[ "${ACTUAL_SHA1}" != "${SERVER_SHA1}" ]]; then
    echo "ERROR: server.jar SHA1 mismatch (expected ${SERVER_SHA1}, got ${ACTUAL_SHA1})" >&2
    rm -f "${JAR_PATH}.tmp"
    exit 1
  fi

  mv "${JAR_PATH}.tmp" "${JAR_PATH}"
  chown "${MINECRAFT_USER}:${MINECRAFT_USER}" "${JAR_PATH}"
  log "server.jar downloaded and verified (SHA1: ${SERVER_SHA1})"
else
  log "server.jar already present at ${JAR_PATH}, skipping download"
fi

# ---- server.properties (write only if absent - preserves operator edits) ----
PROPS_FILE="${MINECRAFT_DIR}/server.properties"
if [[ ! -f "${PROPS_FILE}" ]]; then
  log "Writing server.properties..."
  cat > "${PROPS_FILE}" <<EOF
# Minecraft server properties - managed by install.sh
# Edit via SSM Session Manager. See docs/operations.md.
server-port=${MINECRAFT_PORT}
online-mode=true
white-list=true
enforce-whitelist=true
level-name=world
motd=Minecraft Server
max-players=20
difficulty=normal
gamemode=survival
spawn-protection=16
view-distance=10
EOF
  chown "${MINECRAFT_USER}:${MINECRAFT_USER}" "${PROPS_FILE}"
else
  log "server.properties already present, skipping (preserving operator edits)"
fi

# ---- eula.txt ----------------------------------------------------------------
# Only reached because the EULA guard above passed.
EULA_FILE="${MINECRAFT_DIR}/eula.txt"
log "Writing eula.txt (eula=true)..."
cat > "${EULA_FILE}" <<EOF
# Minecraft EULA - accepted by operator via minecraftEulaAccepted config flag.
# See https://aka.ms/MinecraftEULA
eula=true
EOF
chown "${MINECRAFT_USER}:${MINECRAFT_USER}" "${EULA_FILE}"

# ---- whitelist.json (write only if absent - preserves operator whitelist) ----
WHITELIST_FILE="${MINECRAFT_DIR}/whitelist.json"
if [[ ! -f "${WHITELIST_FILE}" ]]; then
  log "Writing empty whitelist.json..."
  echo '[]' > "${WHITELIST_FILE}"
  chown "${MINECRAFT_USER}:${MINECRAFT_USER}" "${WHITELIST_FILE}"
else
  log "whitelist.json already present, skipping (preserving existing whitelist)"
fi

# ---- minecraft-env (environment file for systemd unit) ----------------------
ENV_FILE="${MINECRAFT_DIR}/minecraft-env"
log "Writing minecraft-env..."
cat > "${ENV_FILE}" <<EOF
JAVA_XMS=${JAVA_XMS}
JAVA_XMX=${JAVA_XMX}
BACKUP_BUCKET=${BACKUP_BUCKET}
BACKUP_RETENTION=${BACKUP_RETENTION}
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}
EOF
chown root:root "${ENV_FILE}"
chmod 640 "${ENV_FILE}"

# ---- Install scripts to /usr/local/bin --------------------------------------
log "Installing scripts to /usr/local/bin/..."
for script in start-minecraft.sh backup.sh restore.sh find-ebs-device.sh; do
  install -o root -g root -m 0755 "${SCRIPT_DIR}/${script}" "/usr/local/bin/${script}"
done

# ---- Install systemd units --------------------------------------------------
log "Installing systemd unit files..."
for unit in minecraft.service minecraft-backup.service minecraft-backup.timer; do
  install -o root -g root -m 0644 "${SCRIPT_DIR}/${unit}" "/etc/systemd/system/${unit}"
done

systemctl daemon-reload

# ---- Configure and start CloudWatch agent ------------------------------------
log "Configuring CloudWatch agent..."
CW_CONFIG_DIR="/opt/aws/amazon-cloudwatch-agent/etc"
mkdir -p "${CW_CONFIG_DIR}"

# Substitute log group names and region into the template
sed \
  -e "s|__REGION__|${AWS_DEFAULT_REGION}|g" \
  "${SCRIPT_DIR}/cloudwatch-agent-config.json" \
  > "${CW_CONFIG_DIR}/amazon-cloudwatch-agent.json"

amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c "file:${CW_CONFIG_DIR}/amazon-cloudwatch-agent.json" \
  -s

# ---- Enable and start Minecraft service + backup timer ----------------------
log "Enabling minecraft.service and minecraft-backup.timer..."
systemctl enable minecraft.service
systemctl enable --now minecraft-backup.timer

# Start Minecraft (only if not already running)
if ! systemctl is-active --quiet minecraft.service; then
  systemctl start minecraft.service
  log "minecraft.service started"
else
  log "minecraft.service already running"
fi

# ---- Bootstrap success marker -----------------------------------------------
log "Writing bootstrap success marker..."
date -u --iso-8601=seconds > "${MARKER_FILE}"
chown "${MINECRAFT_USER}:${MINECRAFT_USER}" "${MARKER_FILE}"

log "Installation complete."
log ""
log "Verify bootstrap success with these commands (via SSM Session Manager):"
log "  cat ${MARKER_FILE}"
log "  java -version"
log "  findmnt ${MINECRAFT_DIR}"
log "  systemctl status minecraft.service"
log "  systemctl status amazon-cloudwatch-agent.service"
log "  systemctl status minecraft-backup.timer"
