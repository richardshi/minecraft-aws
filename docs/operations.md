# Operations

This guide covers day-to-day operations: starting and stopping the server, checking
status, connecting to the console, managing the whitelist, and updating the bootstrap.

All administration commands use **AWS Systems Manager Session Manager**. No SSH key
or bastion host is needed.

---

## Prerequisites

Install the AWS CLI and Session Manager plugin:

```bash
# AWS CLI v2
# https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

# Session Manager plugin
# https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

# Verify
aws --version
session-manager-plugin --version
```

Set your default region:

```bash
export AWS_DEFAULT_REGION=us-west-2
```

Get the instance ID and Elastic IP from the CDK stack outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name MinecraftStack \
  --query 'Stacks[0].Outputs' \
  --output table
```

---

## Starting the Server

```bash
# Start the EC2 instance
aws ec2 start-instances --instance-ids <InstanceId>

# Wait for it to reach the running state
aws ec2 wait instance-running --instance-ids <InstanceId>

# The Minecraft service starts automatically via systemd.
# Allow ~60-90 seconds for the JVM to fully start.

# Confirm the Elastic IP (it does not change)
aws cloudformation describe-stacks \
  --stack-name MinecraftStack \
  --query 'Stacks[0].Outputs[?OutputKey==`ElasticIpAddress`].OutputValue' \
  --output text
```

The Minecraft connection address is: `<ElasticIpAddress>:25565`

---

## Stopping the Server

Before stopping the EC2 instance, the systemd unit's `ExecStop` sends `save-all flush`
then `stop` to the Minecraft server via the FIFO console, and waits up to 90 seconds
for a clean exit. The world is saved before the instance powers off.

```bash
# Stop the EC2 instance (triggers graceful Minecraft shutdown via systemd)
aws ec2 stop-instances --instance-ids <InstanceId>

# Wait for the instance to reach the stopped state
aws ec2 wait instance-stopped --instance-ids <InstanceId>

echo "Instance stopped. EBS data volume and world data are preserved."
```

> **Note**: `stop-instances` sends ACPI shutdown to the OS, triggering `systemctl poweroff`,
> which runs `ExecStop` before powering off. The world is saved before shutdown completes.

---

## Checking Server Status

### EC2 Instance State

```bash
aws ec2 describe-instances \
  --instance-ids <InstanceId> \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text
```

### Minecraft Service Status (via SSM)

```bash
aws ssm start-session --target <InstanceId>
# Then in the session:
systemctl status minecraft.service
```

### Bootstrap Verification Checklist

After first boot (or after re-running the installer), verify all components started
correctly. CloudFormation reporting success does **not** prove bootstrap succeeded -
check the marker file.

```bash
# Connect via SSM Session Manager
aws ssm start-session --target <InstanceId>

# Run all checks:
cat /opt/minecraft/.bootstrap-complete     # Must show a timestamp
java -version                              # Must show openjdk version "25...
findmnt /opt/minecraft                     # Must show the EBS volume UUID mount
systemctl status minecraft.service         # Must show: active (running)
systemctl status amazon-cloudwatch-agent   # Must show: active (running)
systemctl status minecraft-backup.timer    # Must show: active (waiting)
tail -20 /var/log/minecraft/server.log     # Must show server startup messages
```

If the bootstrap marker is missing, check the user-data log:

```bash
cat /var/log/user-data.log
```

---

## Connecting to the Minecraft Console

The Minecraft server console is accessible via the FIFO at `/run/minecraft/stdin`.
Connect via SSM Session Manager first.

```bash
aws ssm start-session --target <InstanceId>
# Then in the session (as root or using sudo):
sudo -u minecraft bash

# Send a command to the Minecraft console:
echo "list" > /run/minecraft/stdin

# Watch the server log for output:
tail -f /var/log/minecraft/server.log
```

---

## Managing the Whitelist

The whitelist is managed entirely via Minecraft server console commands. No file
editing or server restart is needed.

```bash
# Connect via SSM Session Manager
aws ssm start-session --target <InstanceId>

# Add a player (by Minecraft username)
echo "whitelist add PlayerName" > /run/minecraft/stdin

# Remove a player
echo "whitelist remove PlayerName" > /run/minecraft/stdin

# List whitelisted players
echo "whitelist list" > /run/minecraft/stdin

# Reload whitelist from whitelist.json (if the file was edited manually)
echo "whitelist reload" > /run/minecraft/stdin

# Watch for confirmation in the server log
tail -20 /var/log/minecraft/server.log
```

> **Note**: Minecraft usernames are case-sensitive. Use the exact username as
> registered with the Mojang/Microsoft account.

---

## Viewing Logs

### On the Instance (via SSM)

```bash
# Live server log
tail -f /var/log/minecraft/server.log

# Backup log
tail -f /var/log/minecraft/backup.log

# User-data bootstrap log
cat /var/log/user-data.log
```

### In CloudWatch Logs (AWS Console or CLI)

```bash
# Tail server logs
aws logs tail /minecraft/server --follow --region us-west-2

# Tail backup logs
aws logs tail /minecraft/backup --follow --region us-west-2

# Search for backup failures in the last 24 hours
aws logs filter-log-events \
  --log-group-name /minecraft/backup \
  --filter-pattern "BACKUP_FAILED" \
  --start-time $(date -d '24 hours ago' +%s000) \
  --region us-west-2
```

---

## Running a Manual Backup

```bash
# Connect via SSM Session Manager
aws ssm start-session --target <InstanceId>

# Run backup manually as the minecraft user
sudo -u minecraft /usr/local/bin/backup.sh

# Or trigger via systemd
sudo systemctl start minecraft-backup.service

# Check the result
tail -20 /var/log/minecraft/backup.log
```

---

## Updating the Bootstrap Installer

User-data runs only on the first boot. To apply changes to the bootstrap scripts,
systemd units, or CloudWatch config after a CDK asset update:

### Option A: Re-run the Installer via SSM (Recommended)

```bash
# 1. Deploy the updated CDK stack (updates the S3 asset)
#    (from your local machine, after review)
cd infra && npx cdk deploy

# 2. Connect via SSM Session Manager
aws ssm start-session --target <InstanceId>

# 3. Download and re-run the installer
ASSET_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name MinecraftStack \
  --query 'Stacks[0].Outputs[?OutputKey==`AssetBucket`].OutputValue' \
  --output text)
# (Obtain ASSET_KEY and ASSET_HASH from cdk.out or stack outputs)

aws s3 cp "s3://${ASSET_BUCKET}/${ASSET_KEY}" /tmp/bootstrap.zip
echo "${ASSET_HASH}  /tmp/bootstrap.zip" | sha256sum --check
unzip -q /tmp/bootstrap.zip -d /tmp/bootstrap
sudo /tmp/bootstrap/install.sh
```

### Option B: Replace the EC2 Instance

If a full re-bootstrap is needed (e.g., changing the AMI or instance type):

```bash
# 1. Take a manual backup first
sudo systemctl start minecraft-backup.service

# 2. Update config in server-config.ts, then deploy
cd infra && npx cdk deploy

# CDK will replace the instance. The EBS volume is preserved.
# The new instance downloads and runs the updated bootstrap on first boot.
```

> After instance replacement, the Elastic IP is automatically re-associated by
> CloudFormation. The EBS volume is re-attached. The world data is intact.

---

## Sending Server Commands

Any Minecraft server command can be sent via the FIFO:

```bash
# Announce a message to all players
echo "say Server will restart in 5 minutes" > /run/minecraft/stdin

# Check online players
echo "list" > /run/minecraft/stdin

# Give a player operator permissions
echo "op PlayerName" > /run/minecraft/stdin

# Set the time
echo "time set day" > /run/minecraft/stdin

# Save the world manually
echo "save-all" > /run/minecraft/stdin
```

Always watch `/var/log/minecraft/server.log` to see the output.
