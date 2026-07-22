# Backup and Restore

## Backup Overview

Backups run automatically every hour via a systemd timer (`minecraft-backup.timer`),
triggered only while the EC2 instance is running. If `minecraft.service` is not active
when the timer fires, the backup exits cleanly without error.

### What is Backed Up

Each backup archive (`minecraft-backup-YYYYMMDD-HHMMSS.tar.gz`) contains:

| File / Directory | Description |
|---|---|
| `world/` (and dimension dirs) | World data for all dimensions. Directory name comes from `level-name` in `server.properties`. |
| `server.properties` | Server configuration |
| `whitelist.json` | Player whitelist (if present) |
| `ops.json` | Operator list (if present) |
| `banned-players.json` | Banned players (if present) |
| `banned-ips.json` | Banned IPs (if present) |

The `level-name` value is read from `server.properties` at backup time. If the world
is named something other than `world`, the backup script handles it automatically.

### What is NOT Backed Up

- `server.jar` — re-downloaded from Mojang during bootstrap
- Logs — available in CloudWatch Logs (30-day retention)
- The EBS volume snapshot — not automated in v1

### Backup Location

All backups are stored in the S3 backup bucket:

```
s3://<BackupBucketName>/minecraft-backup-YYYYMMDD-HHMMSS.tar.gz
```

The bucket name is a stack output (`BackupBucketName`).

### Retention

The five most recent successful backups are retained. Older backups are pruned only
after a new backup is successfully uploaded and presence-verified. If a backup fails,
no existing backups are deleted.

### Upload Verification

After each upload, the script runs `aws s3api head-object` to confirm the object
exists in S3 and has a non-zero `ContentLength`. This is an **upload presence check**,
not a full archive integrity validation (the archive is not re-downloaded and extracted
as part of the automated backup). For periodic integrity verification, see
"Manual Backup Verification" below.

---

## Backup Logs

All backup events are logged to:

- **On instance**: `/var/log/minecraft/backup.log`
- **CloudWatch Logs**: `/minecraft/backup` log group

Key log lines to watch for:

```
BACKUP_SUCCESS: s3://bucket/minecraft-backup-20260101-120000.tar.gz (12345678 bytes)
BACKUP_FAILED: world flush timed out after 30s
BACKUP_FAILED: S3 object verification failed
BACKUP_FAILED: another backup is already running
INFO: minecraft.service is not active — skipping backup
```

A CloudWatch alarm (`MinecraftBackupFailure`) triggers when a `BACKUP_FAILED` line
appears in the backup log group.

---

## Listing Available Backups

```bash
# From your local machine
aws s3 ls s3://<BackupBucketName>/ \
  --region us-west-2 \
  | grep minecraft-backup \
  | sort

# Or via SSM on the instance
aws ssm start-session --target <InstanceId>
aws s3 ls s3://${BACKUP_BUCKET}/ | grep minecraft-backup | sort
```

---

## Running a Manual Backup

```bash
# Via SSM Session Manager
aws ssm start-session --target <InstanceId>

# Trigger via systemd (recommended — uses the same environment as the timer)
sudo systemctl start minecraft-backup.service

# Or run the script directly as the minecraft user
sudo -u minecraft /usr/local/bin/backup.sh

# Check the result
tail -20 /var/log/minecraft/backup.log
```

---

## Manual Backup Verification

To verify that a backup archive is intact and extractable:

```bash
# Download the backup to a temporary location
aws s3 cp s3://<BackupBucketName>/minecraft-backup-YYYYMMDD-HHMMSS.tar.gz /tmp/test-backup.tar.gz

# List contents (does not extract)
tar -tzf /tmp/test-backup.tar.gz

# Test extraction to a temp directory
mkdir /tmp/backup-verify
tar -xzf /tmp/test-backup.tar.gz -C /tmp/backup-verify
ls /tmp/backup-verify/

# Clean up
rm -rf /tmp/test-backup.tar.gz /tmp/backup-verify
```

---

## Restore Procedure

### When to Restore

- World corruption or accidental deletion
- Rolling back to an earlier game state
- Migrating the server to a new instance

### Restore Using the Script (Recommended)

The `restore.sh` script is installed at `/usr/local/bin/restore.sh` on the instance.
Run it via SSM Session Manager as root.

```bash
# Connect via SSM Session Manager
aws ssm start-session --target <InstanceId>

# List available backups and restore interactively
sudo /usr/local/bin/restore.sh

# Or specify a backup key directly
sudo /usr/local/bin/restore.sh --backup-key minecraft-backup-20260101-120000.tar.gz

# Dry run — prints all steps without making changes
sudo /usr/local/bin/restore.sh --dry-run
```

The script:
1. Lists available S3 backups (if no key is specified)
2. Stops `minecraft.service` gracefully
3. Downloads the selected archive to a temp directory
4. Renames existing world directories to `world.pre-restore.<timestamp>` (preserved)
5. Extracts the archive into `/opt/minecraft/`
6. Starts `minecraft.service`

### Post-Restore Verification

```bash
# Check the server started correctly
systemctl status minecraft.service
tail -30 /var/log/minecraft/server.log

# Verify the world loaded (look for "Preparing spawn area" or player join messages)
# Connect in Minecraft and verify the world state
```

### Pre-Restore World Data

The script renames (does not delete) the existing world directories before restoring:

```
/opt/minecraft/world.pre-restore.20260101-130000
/opt/minecraft/world_nether.pre-restore.20260101-130000
/opt/minecraft/world_the_end.pre-restore.20260101-130000
```

These directories are preserved. If the restore was incorrect, stop the server,
delete the restored world, and rename the pre-restore directories back:

```bash
sudo systemctl stop minecraft.service
sudo rm -rf /opt/minecraft/world /opt/minecraft/world_nether /opt/minecraft/world_the_end
sudo mv /opt/minecraft/world.pre-restore.20260101-130000 /opt/minecraft/world
sudo mv /opt/minecraft/world_nether.pre-restore.20260101-130000 /opt/minecraft/world_nether
sudo mv /opt/minecraft/world_the_end.pre-restore.20260101-130000 /opt/minecraft/world_the_end
sudo systemctl start minecraft.service
```

---

## Manual Restore (Without the Script)

If the script is unavailable, follow these steps:

```bash
# 1. Stop the server
sudo systemctl stop minecraft.service

# 2. Download the backup
aws s3 cp s3://<BackupBucketName>/minecraft-backup-YYYYMMDD-HHMMSS.tar.gz /tmp/restore.tar.gz

# 3. Preserve current world
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
sudo mv /opt/minecraft/world /opt/minecraft/world.pre-restore.${TIMESTAMP}

# 4. Extract
sudo tar -xzf /tmp/restore.tar.gz -C /opt/minecraft/
sudo chown -R minecraft:minecraft /opt/minecraft/

# 5. Start the server
sudo systemctl start minecraft.service

# 6. Clean up
rm /tmp/restore.tar.gz
```

---

## Downloading a Backup Locally

To inspect or import a backup on a local machine:

```bash
aws s3 cp s3://<BackupBucketName>/minecraft-backup-YYYYMMDD-HHMMSS.tar.gz ./backup.tar.gz

# Extract
mkdir ./restore
tar -xzf backup.tar.gz -C ./restore
ls ./restore/
```
