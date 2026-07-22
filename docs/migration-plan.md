# Migration Plan

This document covers two scenarios:

1. **Migrating an existing Minecraft world** into this AWS infrastructure
2. **Replacing the EC2 instance** (e.g., after an instance type change or forced replacement)

---

## Scenario 1: Migrating an Existing World

If you have an existing Minecraft world running locally or on another host, use this
procedure to import it into the AWS server.

### Prerequisites

- The CDK stack is deployed and the EC2 instance has completed bootstrap (verify
  with `cat /opt/minecraft/.bootstrap-complete` via SSM).
- The Minecraft server is running the same version as your existing world, or you have
  upgraded the world data to the target version first.
- `aws` CLI is configured with write access to the S3 backup bucket.

### Step 1: Prepare the World Archive

Create an archive of your existing world in the same format as a server backup:

```bash
# On your local machine or existing server, from the server root directory:
tar -czf minecraft-backup-import.tar.gz \
  world/ \
  world_nether/ \
  world_the_end/ \
  server.properties \
  whitelist.json \
  ops.json \
  banned-players.json \
  banned-ips.json

# Include only directories/files that actually exist.
# Adjust world directory names to match your level-name setting.
```

### Step 2: Upload to the S3 Backup Bucket

```bash
# Get the backup bucket name from stack outputs
BACKUP_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name MinecraftStack \
  --query 'Stacks[0].Outputs[?OutputKey==`BackupBucketName`].OutputValue' \
  --output text \
  --region us-west-2)

# Upload the archive
aws s3 cp minecraft-backup-import.tar.gz \
  "s3://${BACKUP_BUCKET}/minecraft-backup-import.tar.gz" \
  --region us-west-2

echo "Uploaded to s3://${BACKUP_BUCKET}/minecraft-backup-import.tar.gz"
```

### Step 3: Restore via the Script

```bash
# Connect via SSM Session Manager
INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name MinecraftStack \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
  --output text \
  --region us-west-2)

aws ssm start-session --target "${INSTANCE_ID}" --region us-west-2

# In the SSM session:
sudo /usr/local/bin/restore.sh --backup-key minecraft-backup-import.tar.gz
```

### Step 4: Verify

```bash
# In the SSM session:
systemctl status minecraft.service
tail -30 /var/log/minecraft/server.log

# Connect in Minecraft and verify the world loaded correctly
```

### Step 5: Migrate the Whitelist

If your existing server had a whitelist, add players via the console:

```bash
echo "whitelist add PlayerName" > /run/minecraft/stdin
# Repeat for each player
echo "whitelist list" > /run/minecraft/stdin
```

---

## Scenario 2: Replacing the EC2 Instance

The EC2 instance is designed to be **replaceable**. All persistent state lives on the
EBS data volume and S3 bucket, both of which survive instance replacement.

Instance replacement is needed when:
- Changing the instance type (e.g., upgrading from `t3.medium` to `t3.large`)
- The instance becomes unresponsive and cannot be recovered
- Updating the AMI (e.g., new Amazon Linux 2023 release)
- A CDK stack update forces instance replacement (e.g., changing user-data)

### Before Replacing

```bash
# 1. Ensure a recent backup exists
aws s3 ls "s3://${BACKUP_BUCKET}/" | grep minecraft-backup | sort | tail -5

# 2. Take a manual backup if needed
aws ssm start-session --target <InstanceId>
sudo systemctl start minecraft-backup.service
tail -20 /var/log/minecraft/backup.log

# 3. Note the EBS Volume ID and Elastic IP Allocation ID from stack outputs
aws cloudformation describe-stacks \
  --stack-name MinecraftStack \
  --query 'Stacks[0].Outputs' \
  --output table
```

### Replacing via CDK Deploy

If the replacement is driven by a CDK change (instance type, AMI, user-data):

```bash
# 1. Update server-config.ts with the desired changes
# 2. Deploy the stack
cd infra && npx cdk deploy

# CDK will:
# - Create the new EC2 instance
# - Detach the EBS volume from the old instance
# - Attach it to the new instance (via CfnVolumeAttachment)
# - Re-associate the Elastic IP (via CfnEIPAssociation)
# - Terminate the old instance
```

After deployment, verify bootstrap on the new instance:

```bash
# Get the new instance ID
NEW_INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name MinecraftStack \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
  --output text)

aws ssm start-session --target "${NEW_INSTANCE_ID}"
cat /opt/minecraft/.bootstrap-complete
systemctl status minecraft.service
```

### Re-associating the Elastic IP Manually

If the instance was replaced out-of-band (not via CDK), re-associate the Elastic IP:

```bash
# Get the Elastic IP Allocation ID from the stack output
EIP_ALLOC=$(aws cloudformation describe-stacks \
  --stack-name MinecraftStack \
  --query 'Stacks[0].Outputs[?OutputKey==`EipAllocationId`].OutputValue' \
  --output text)

# Associate with the new instance
aws ec2 associate-address \
  --allocation-id "${EIP_ALLOC}" \
  --instance-id <NewInstanceId> \
  --region us-west-2
```

### Re-attaching the EBS Volume Manually

If the volume is not automatically re-attached by CDK:

```bash
# Get the Volume ID from the stack output
VOLUME_ID=$(aws cloudformation describe-stacks \
  --stack-name MinecraftStack \
  --query 'Stacks[0].Outputs[?OutputKey==`EbsVolumeId`].OutputValue' \
  --output text)

# Attach to the new instance (instance must be stopped or running but not yet mounted)
aws ec2 attach-volume \
  --volume-id "${VOLUME_ID}" \
  --instance-id <NewInstanceId> \
  --device /dev/sdf \
  --region us-west-2
```

The bootstrap script (`install.sh`) will detect the existing filesystem (via `blkid`),
skip formatting, and mount the volume by UUID — preserving all world data.

---

## Decommissioning

To shut down the server permanently:

```bash
# 1. Take a final backup
aws ssm start-session --target <InstanceId>
sudo systemctl start minecraft-backup.service

# 2. Download any backups you want to keep locally
aws s3 sync s3://<BackupBucketName>/ ./minecraft-backups/ --region us-west-2

# 3. Disable stack termination protection
aws cloudformation update-termination-protection \
  --stack-name MinecraftStack \
  --no-enable-termination-protection \
  --region us-west-2

# 4. Destroy the CDK stack
#    The EBS volume, S3 bucket, and Elastic IP are RETAINED (not deleted).
cd infra && npx cdk destroy

# 5. Manually release the Elastic IP to stop ongoing charges ($0.005/hr)
EIP_ALLOC=<EipAllocationId output>
aws ec2 release-address --allocation-id "${EIP_ALLOC}" --region us-west-2

# 6. Optionally delete the EBS volume (irreversible — confirm world data is backed up)
aws ec2 delete-volume --volume-id <EbsVolumeId> --region us-west-2

# 7. Optionally empty and delete the S3 bucket
aws s3 rm s3://<BackupBucketName>/ --recursive --region us-west-2
aws s3 rb s3://<BackupBucketName>/ --region us-west-2
```

> **Warning**: Steps 6 and 7 are irreversible. Ensure you have local copies of any
> world data and backups you want to keep before proceeding.
