#!/bin/bash
# user-data.sh - Minimal EC2 user-data script.
#
# This script is embedded in the EC2 instance user-data by the CDK stack.
# It must remain well under the 16 KB EC2 user-data raw size limit.
#
# All installation logic lives in infra/assets/install.sh (packaged as a
# versioned CDK S3 asset). This script only:
#   1. Ensures aws-cli and unzip are available.
#   2. Downloads the bootstrap asset from S3.
#   3. Extracts and runs install.sh.
#
# All environment variables (MINECRAFT_VERSION, BACKUP_BUCKET, etc.) are
# injected by the CDK stack before this script runs.
#
# To update the bootstrap after a CDK asset change:
#   See docs/operations.md - "Updating the bootstrap installer"

set -euo pipefail

# Redirect all output to the console and a persistent log
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "[user-data] Starting bootstrap at $(date -u --iso-8601=seconds)"
echo "[user-data] Instance ID: $(curl -sf http://169.254.169.254/latest/meta-data/instance-id || echo unknown)"

# ---- Ensure required tools are available ------------------------------------
if ! command -v unzip &>/dev/null; then
  echo "[user-data] Installing unzip..."
  yum install -y unzip
fi

# aws-cli v2 is pre-installed on Amazon Linux 2023; verify it is present
if ! command -v aws &>/dev/null; then
  echo "ERROR: aws CLI not found. This AMI may not be Amazon Linux 2023." >&2
  exit 1
fi

# ---- Download bootstrap asset -----------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

ARCHIVE="${TMPDIR}/bootstrap.zip"

echo "[user-data] Downloading bootstrap asset from s3://${ASSET_BUCKET}/${ASSET_KEY}"
aws s3 cp "s3://${ASSET_BUCKET}/${ASSET_KEY}" "${ARCHIVE}" \
  --region "${AWS_DEFAULT_REGION}"

# ---- Extract and run installer ----------------------------------------------
unzip -q "${ARCHIVE}" -d "${TMPDIR}/bootstrap"
chmod +x "${TMPDIR}/bootstrap/install.sh"

echo "[user-data] Running install.sh..."
"${TMPDIR}/bootstrap/install.sh"

echo "[user-data] Bootstrap complete at $(date -u --iso-8601=seconds)"
