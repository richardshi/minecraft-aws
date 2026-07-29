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

- `server.jar` - re-downloaded from Mojang during bootstrap
- Logs - available in CloudWatch Logs (30-day retention)
- The EBS volume snapshot - not automated in v1

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
INFO: minecraft.service is not active - skipping backup
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

# Trigger via systemd (recommended - uses the same environment as the timer)
sudo systemctl start minecraft-backup.service

# Or run the script directly as the minecraft user
sudo -u minecraft /usr/local/bin/backup.sh

# Check the result
tail -20 /var/log/minecraft/backup.log
```

### Expected Output

A healthy run of `backup.log` looks like this (timestamps/size/level-name will vary):

```
2026-07-29T19:51:22+00:00 INFO: starting backup (level-name='world')
2026-07-29T19:51:23+00:00 INFO: world flush confirmed after 1s
2026-07-29T19:51:23+00:00 INFO: archiving: world/ server.properties whitelist.json ops.json banned-players.json banned-ips.json
2026-07-29T19:51:23+00:00 INFO: uploading to s3://<BackupBucketName>/minecraft-backup-20260729-195123.tar.gz
2026-07-29T19:51:26+00:00 INFO: upload verified (ContentLength=18657785 bytes)
2026-07-29T19:51:26+00:00 INFO: pruning backups (retention=5)
2026-07-29T19:51:27+00:00 INFO: found 1 backup(s) in S3
2026-07-29T19:51:27+00:00 INFO: no pruning needed (1 <= 5)
2026-07-29T19:51:27+00:00 BACKUP_SUCCESS: s3://<BackupBucketName>/minecraft-backup-20260729-195123.tar.gz (18657785 bytes)
2026-07-29T19:51:27+00:00 INFO: save-on sent
```

Confirm the `BACKUP_SUCCESS` line has no preceding `Permission denied` errors, then verify
the object actually landed in S3:

```bash
aws s3api list-objects-v2 --bucket <BackupBucketName> --prefix minecraft-backup \
  --query 'sort_by(Contents, &LastModified)[].[Key,LastModified,Size]' --output table
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
Run it via SSM Session Manager as root. It automatically loads `BACKUP_BUCKET` and
`AWS_DEFAULT_REGION` from `/opt/minecraft/minecraft-env` (the same file `backup.sh`'s
systemd unit uses) if they aren't already set in your shell.

```bash
# Connect via SSM Session Manager
aws ssm start-session --target <InstanceId>

# List available backups and restore interactively
sudo /usr/local/bin/restore.sh

# Or specify a backup key directly
sudo /usr/local/bin/restore.sh --backup-key minecraft-backup-20260101-120000.tar.gz

# Dry run - prints all steps without making changes
sudo /usr/local/bin/restore.sh --dry-run
```

The script:
1. Lists available S3 backups (if no key is specified)
2. Downloads the selected archive
3. Validates it's a well-formed `tar.gz` (`minecraft.service` is not touched yet)
4. Extracts it into a staging directory (`/opt/minecraft/.restore-staging`, on the
   same volume as the live world) and verifies it actually contains the expected
   world directory - still no live data touched, so the server keeps running while
   a bad backup is downloaded, validated, and staged
5. Stops `minecraft.service` - the first point of any real downtime
6. Renames the current world directories to `world.pre-restore.<timestamp>` (preserved)
7. Moves the staged world into place
8. Starts `minecraft.service`
9. Waits (up to `STARTUP_TIMEOUT`, default 90s) for the server to report ready in
   `server.log`. If it doesn't come up healthy, the script **automatically rolls
   back**: it preserves the failed attempt as `world.failed-restore.<timestamp>`
   (never deleted), moves the `world.pre-restore.<timestamp>` copy back into place,
   and restarts the server with the known-good world.

Because steps 1-4 never touch the live world or the running server, an invalid or
empty backup is caught with zero downtime. Only steps 5-9 involve stopping the
server, and 8-9 are the only steps that can trigger the automatic rollback - that's
also the point at which a `world.pre-restore.*` copy first exists to roll back to.

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

If the server fails to come up healthy after a restore, the script rolls this back
**automatically** (see "Restore Using the Script" above): the bad attempt is preserved
as `world.failed-restore.<timestamp>` (same naming convention, never deleted) and the
`.pre-restore.*` copy is moved back into place, with no operator action required.

Manual recovery is only needed when the restore *succeeded* (the server came up
healthy) but the restored world turns out to be the wrong one, or wrong in some way
the startup health check can't detect. In that case, stop the server, delete the
restored world, and rename the pre-restore directories back:

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
