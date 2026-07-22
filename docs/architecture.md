# Architecture

## Overview

A single EC2 instance running Minecraft Java Edition on Amazon Linux 2023, with a
persistent EBS data volume, hourly backups to S3, a static Elastic IP, and administration
via AWS Systems Manager Session Manager. All infrastructure is defined in AWS CDK (TypeScript)
under `infra/`.

---

## Architecture Diagram

```
Minecraft Clients                    Admin (SSM Session Manager)
(TCP 25565)                          (HTTPS port 443)
     |                                       |
     v                                       v
 Elastic IP ──────────────────────── SSM Service (AWS managed)
 (static, RemovalPolicy.RETAIN)              |
     |                                       |
     v                                       |
 Security Group                              |
 Inbound: TCP 25565 only                     |
 No port 22                                  |
     |                                       |
     +───────────────────────────────────────+
                         |
                         v
              EC2 t3.medium (Amazon Linux 2023)
              ┌─────────────────────────────────┐
              │  minecraft.service (systemd)     │
              │  ├─ start-minecraft.sh           │
              │  │  ├─ mkfifo /run/minecraft/stdin│
              │  │  ├─ exec 3<>/run/minecraft/stdin│
              │  │  └─ exec java -jar server.jar  │
              │  └─ ExecStop: save-all flush, stop │
              │                                   │
              │  minecraft-backup.timer (hourly)  │
              │  └─ minecraft-backup.service      │
              │     └─ backup.sh                  │
              │        ├─ check service active    │
              │        ├─ flock (no overlap)      │
              │        ├─ save-off / flush        │
              │        ├─ tar | aws s3 cp (stream)│
              │        ├─ head-object (verify)    │
              │        └─ prune old backups       │
              └─────────────────────────────────┘
                    |                    |
                    v                    v
            EBS gp3 20 GiB         S3 Backup Bucket
            (encrypted)            (private, SSE-S3)
            UUID-mounted           RemovalPolicy.RETAIN
            at /opt/minecraft       5-backup retention
            RemovalPolicy.RETAIN
            DeleteOnTermination=false
                    |
                    v
            CloudWatch Logs
            /minecraft/server    (30-day retention)
            /minecraft/backup    (30-day retention)
                    |
                    v
            CloudWatch Alarms
            ├─ CPU > 90% for 15 min
            └─ BackupFailures >= 1 per hour

            AWS Budget
            └─ Monthly threshold + email alert
```

---

## Component Descriptions

### EC2 Instance

- **Type**: `t3.medium` (2 vCPU, 4 GB RAM, Nitro-based)
- **AMI**: Amazon Linux 2023 (latest, resolved at `cdk synth` time)
- **Subnet**: Single public subnet (no NAT gateway)
- **Public IP**: Elastic IP only - no auto-assigned public IP

The instance is treated as **replaceable**. All persistent state lives on the EBS
volume and S3 bucket, both of which survive instance replacement or termination.

### Minecraft Service (systemd)

The Minecraft server runs as a direct foreground process under systemd, supervised by
`minecraft.service`. This means:

- `Restart=on-failure` reliably restarts the JVM after a crash.
- Exit code 0 (clean `/stop`) does not trigger a restart.
- `systemctl status minecraft.service` accurately reflects the JVM state.

A named pipe (FIFO) at `/run/minecraft/stdin` provides a console input channel.
The `start-minecraft.sh` wrapper creates the FIFO, opens it read/write on fd 3 (to
prevent EOF when individual writers close), then `exec`s the JVM with stdin from fd 3.

### EBS Data Volume

- All Minecraft server data lives at `/opt/minecraft` on the EBS volume.
- The volume is identified by its EBS Volume ID (via NVMe serial number in sysfs)
  rather than by Linux device name, which is non-deterministic on Nitro instances.
- The volume is mounted by filesystem UUID (from `/etc/fstab`) for stability across
  reboots.
- The volume is attached out-of-band via `CfnVolumeAttachment` rather than being
  listed in the instance's own block device mapping. `DeleteOnTermination` only
  applies to volumes declared in that mapping - `CfnVolumeAttachment` has no such
  property - so the data volume is never deleted when the instance terminates,
  regardless of how the instance is replaced or torn down.

### Bootstrap Asset

All instance-side files (installer, scripts, systemd units, CloudWatch config) are
packaged as a versioned CDK S3 asset. The EC2 user-data script (under 1 KB) downloads
and runs the installer. Integrity and authenticity come from the download being over
TLS, from the object key itself being content-addressed (a hash of the asset's
contents), and from the instance role being scoped to read only that exact object key
(`MinecraftBootstrapAssetAccess`) - not from a separate checksum step. This keeps
user-data well under the 16 KB limit and allows updates without re-creating the
instance (see [operations.md](operations.md)).

### Elastic IP

A static public IPv4 address allocated to the AWS account. It is associated with the
EC2 instance via a `CfnEIPAssociation` CloudFormation resource. When the instance is
replaced (stack update or manual), CloudFormation automatically re-creates the
association.

`RemovalPolicy.RETAIN` prevents `cdk destroy` from releasing the address. After
decommission, release it manually to stop ongoing charges:

```bash
aws ec2 release-address --allocation-id <EipAllocationId>
```

The allocation ID is a stack output (`EipAllocationId`).

### Backup Pipeline

1. systemd timer fires every hour (`OnCalendar=hourly`)
2. `backup.sh` checks `minecraft.service` is active
3. Acquires `flock` - prevents overlapping runs
4. Installs EXIT trap for `save-on`
5. Sends `save-off` and `save-all flush` to the FIFO
6. Polls `server.log` for `"Saved the game"` (30-second timeout)
7. Streams `tar | aws s3 cp` - no disk staging
8. Verifies upload via `head-object` (presence check + non-zero ContentLength)
9. Prunes backups beyond retention count (oldest first) - only on success
10. EXIT trap fires: `save-on` sent unconditionally

---

## Design Decisions

| Decision | Rationale |
|---|---|
| Single EC2 instance | Simplest architecture; meets requirements for a small group |
| EBS for world data | Block storage survives stop/start; lower latency than EFS for Minecraft I/O |
| Systemd direct supervision | Reliable crash detection; no multiplexer (tmux/screen) between systemd and JVM |
| FIFO for console input | Allows ExecStop and backup.sh to send commands without a PTY or RCON |
| CDK S3 asset for bootstrap | Stays under 16 KB user-data limit; supports updates via SSM re-run |
| No disk staging for backups | Eliminates risk of filling the data volume; streams directly to S3 |
| Elastic IP | Stable address across stop/start; eliminates IP-change friction |
| RemovalPolicy.RETAIN everywhere | Protects persistent data from accidental deletion during CDK operations |
| Stack termination protection | Prevents accidental `cdk destroy` from running without explicit override |
| No EC2 API termination protection | Instance is replaceable; data is protected by EBS and S3 retention policies |

---

## Estimated Monthly Cost (us-west-2)

| Resource | Rate | 20 hrs/mo | 100 hrs/mo | 730 hrs/mo (24/7) |
|---|---|---|---|---|
| EC2 t3.medium | $0.0464/hr | $0.93 | $4.64 | $33.87 |
| Elastic IP | $0.005/hr flat | $3.65 | $3.65 | $3.65 |
| EBS gp3 20 GiB | $1.60/mo flat | $1.60 | $1.60 | $1.60 |
| S3 storage (~1 GB) | ~$0.023/GB-mo | $0.03 | $0.03 | $0.03 |
| CloudWatch Logs | $0.50/GB | ~$0.05 | ~$0.10 | ~$0.30 |
| Data transfer out | $0.09/GB | ~$0.10 | ~$0.30 | ~$1.00 |
| **Estimated total** | | **~$6.36** | **~$10.32** | **~$40.45** |

The Elastic IP is the dominant cost at low usage (20 hrs/month = ~$3.65 of the total).
It costs $0.005/hr whether the instance is running or stopped.

> These are estimates. Actual costs depend on player count, world size, and data transfer.
> The AWS Budget resource in the stack sends an email alert at 80% and 100% of the
> configured monthly threshold.
