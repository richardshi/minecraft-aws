#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ec2-common.sh"

CONFIG_FILE="${CONFIG_FILE:-${ROOT_DIR}/config/server-config.ts}"
MANIFEST_URL="https://launchermeta.mojang.com/mc/game/version_manifest_v2.json"
# Matches the Amazon Corretto major version installed by assets/install.sh.
INSTALLED_JAVA_MAJOR=25

TARGET_VERSION=""
SKIP_BACKUP=false
ASSUME_YES=false

usage() {
  cat <<'EOF'
Usage: scripts/upgrade-minecraft-version.sh <version> [options]

Upgrades the Minecraft server to <version> by replacing the EC2 instance:
  1. Validates <version> against Mojang's release manifest and Java 25.
  2. Refuses downgrades (a world opened on a newer version cannot be
     loaded by an older one).
  3. Sets minecraftVersion in config/server-config.ts.
  4. Takes a verified pre-upgrade backup to S3 via SSM (if the instance is
     running).
  5. Hands off to scripts/deploy-check-and-push.sh, which shows the change
     set and asks for confirmation before replacing the instance. The world
     EBS volume is retained and moved to the new instance.

Upgrade options:
  --skip-backup            Skip the pre-upgrade backup.
  --yes                    Don't prompt before the backup. The deploy step
                           still asks for its own confirmation.
EOF
  usage_common
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# ---- Argument parsing --------------------------------------------------------
COMMON_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-backup)
      SKIP_BACKUP=true
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    --instance-id|--stack|--profile|--region|--outputs-file)
      COMMON_ARGS+=("$1" "${2:-}")
      shift
      [[ $# -gt 0 ]] && shift
      ;;
    -*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      [[ -z "${TARGET_VERSION}" ]] || { echo "Unexpected argument: $1" >&2; usage >&2; exit 1; }
      TARGET_VERSION="$1"
      shift
      ;;
  esac
done

parse_status=0
parse_common_args "${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"}" || parse_status=$?
if [[ ${parse_status} -ne 0 ]]; then
  usage >&2
  exit 1
fi

[[ -n "${TARGET_VERSION}" ]] || { usage >&2; exit 1; }
[[ "${TARGET_VERSION}" =~ ^[0-9A-Za-z._-]+$ ]] || fail "Invalid version string: ${TARGET_VERSION}"

require_commands
command -v curl >/dev/null 2>&1 || fail "Required command not found: curl"

# ---- 1. Validate target version (local only, no AWS calls) -------------------
printf '==> Checking Mojang manifest for %s\n' "${TARGET_VERSION}"
REQUIRED_JAVA="$(
  curl -fsSL "${MANIFEST_URL}" | python3 -c '
import json, sys, urllib.request
target = sys.argv[1]
for v in json.load(sys.stdin)["versions"]:
    if v["id"] == target:
        kind = v["type"]
        if kind != "release":
            sys.exit(f"{target} is a {kind}, not a release")
        meta = json.load(urllib.request.urlopen(v["url"]))
        print(meta["javaVersion"]["majorVersion"])
        break
else:
    sys.exit(f"{target} not found in Mojang version manifest")
' "${TARGET_VERSION}"
)" || fail "Version validation failed for ${TARGET_VERSION}"

if (( REQUIRED_JAVA > INSTALLED_JAVA_MAJOR )); then
  fail "${TARGET_VERSION} requires Java ${REQUIRED_JAVA}, but install.sh installs Corretto ${INSTALLED_JAVA_MAJOR}. Update the Java install step in assets/install.sh first."
fi
printf '    %s is a release requiring Java %s (OK)\n' "${TARGET_VERSION}" "${REQUIRED_JAVA}"

# ---- 2. Downgrade guard ------------------------------------------------------
CURRENT_VERSION="$(sed -n "s/^[[:space:]]*minecraftVersion: '\([^']*\)',.*/\1/p" "${CONFIG_FILE}")"
[[ -n "${CURRENT_VERSION}" ]] || fail "Could not read minecraftVersion from ${CONFIG_FILE}"

if [[ "${CURRENT_VERSION}" == "${TARGET_VERSION}" ]]; then
  printf '==> Config already set to %s (continuing; the deploy is a no-op if already applied)\n' "${TARGET_VERSION}"
else
  LOWER="$(printf '%s\n%s\n' "${CURRENT_VERSION}" "${TARGET_VERSION}" | sort -V | head -n1)"
  if [[ "${LOWER}" == "${TARGET_VERSION}" ]]; then
    fail "Refusing to downgrade ${CURRENT_VERSION} -> ${TARGET_VERSION}. Worlds cannot be loaded by an older version; restore a pre-upgrade backup instead (docs/backup-and-restore.md)."
  fi

  # ---- 3. Bump config --------------------------------------------------------
  printf '==> Updating minecraftVersion: %s -> %s\n' "${CURRENT_VERSION}" "${TARGET_VERSION}"
  sed -i "s/^\([[:space:]]*minecraftVersion: '\)[^']*\(',.*\)/\1${TARGET_VERSION}\2/" "${CONFIG_FILE}"
  grep -q "minecraftVersion: '${TARGET_VERSION}'," "${CONFIG_FILE}" || fail "Config update did not apply"
  git -C "${ROOT_DIR}" --no-pager diff -- "${CONFIG_FILE}" || true
fi

# ---- 4. Pre-upgrade backup ---------------------------------------------------
if [[ "${SKIP_BACKUP}" == "true" ]]; then
  echo "==> Skipping pre-upgrade backup (--skip-backup)"
else
  INSTANCE_ID="$(resolve_instance_id)"
  STATE="$(
    aws_cli ec2 describe-instances \
      --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].State.Name' \
      --output text
  )"

  if [[ "${STATE}" != "running" ]]; then
    printf '==> Instance %s is %s; skipping pre-upgrade backup (world is not changing while stopped)\n' \
      "${INSTANCE_ID}" "${STATE}"
  else
    if [[ "${ASSUME_YES}" != "true" ]]; then
      reply=""
      read -r -p "Run a pre-upgrade backup on ${INSTANCE_ID} via SSM? [y/N] " reply || true
      [[ "${reply}" =~ ^[Yy]$ ]] || { echo "Cancelled. Config change (if any) is left in place."; exit 1; }
    fi

    printf '==> Running pre-upgrade backup on %s\n' "${INSTANCE_ID}"
    COMMAND_ID="$(
      aws_cli ssm send-command \
        --instance-ids "${INSTANCE_ID}" \
        --document-name AWS-RunShellScript \
        --comment "Pre-upgrade backup before Minecraft ${TARGET_VERSION}" \
        --parameters '{"commands":["systemctl start minecraft-backup.service","tail -n 20 /var/log/minecraft/backup.log"],"executionTimeout":["1800"]}' \
        --query 'Command.CommandId' \
        --output text
    )"

    STATUS="Pending"
    while [[ "${STATUS}" == "Pending" || "${STATUS}" == "InProgress" || "${STATUS}" == "Delayed" ]]; do
      sleep 10
      STATUS="$(
        aws_cli ssm get-command-invocation \
          --command-id "${COMMAND_ID}" \
          --instance-id "${INSTANCE_ID}" \
          --query 'Status' \
          --output text 2>/dev/null || echo "Pending"
      )"
      printf '    backup status: %s\n' "${STATUS}"
    done

    aws_cli ssm get-command-invocation \
      --command-id "${COMMAND_ID}" \
      --instance-id "${INSTANCE_ID}" \
      --query '[StandardOutputContent,StandardErrorContent]' \
      --output text || true

    [[ "${STATUS}" == "Success" ]] || fail "Pre-upgrade backup ${STATUS}; aborting before deploy."

    BACKUP_BUCKET="$(stack_output_or_empty "BackupBucketName")"
    if [[ -n "${BACKUP_BUCKET}" ]]; then
      LATEST_BACKUP="$(
        aws_cli s3api list-objects-v2 \
          --bucket "${BACKUP_BUCKET}" \
          --query 'sort_by(Contents, &LastModified)[-1].Key' \
          --output text 2>/dev/null || true
      )"
      printf '    latest backup: s3://%s/%s\n' "${BACKUP_BUCKET}" "${LATEST_BACKUP}"
    fi
  fi
fi

# ---- 5. Deploy (instance replacement) ----------------------------------------
cat <<EOF

==> Handing off to deploy-check-and-push.sh
    Expect the change set to REPLACE MinecraftInstance (user-data changed).
    MinecraftDataVolume, MinecraftBackupBucket and MinecraftEip must NOT be replaced.

After the deploy completes, verify via SSM (aws ssm start-session --target <new InstanceId>):
    cat /opt/minecraft/.minecraft-version      # ${TARGET_VERSION}
    systemctl status minecraft.service         # active (running)
    grep 'Done (' /var/log/minecraft/server.log
Then connect with a ${TARGET_VERSION} client. Commit config/server-config.ts.

EOF

exec bash "${SCRIPT_DIR}/deploy-check-and-push.sh" \
  --stack "${STACK_NAME}" \
  --profile "${PROFILE}" \
  --region "${REGION}"
