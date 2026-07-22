# Requirements

## Overview

This document records the functional, infrastructure, and safety requirements for the
Minecraft Java Edition server hosted on AWS. It is the authoritative reference for what
the system must do and what constraints it must satisfy.

---

## Functional Requirements

### 1. Public Minecraft Access with Player Whitelist

- The Minecraft server must be reachable from the internet via a stable public IPv4 address.
- A static Elastic IP address is allocated and associated with the EC2 instance. The address
  does not change across stop/start cycles.
- Only TCP port 25565 (Minecraft's default port) is exposed publicly.
- SSH (port 22) is never exposed. Administration uses AWS Systems Manager Session Manager.
- The Minecraft whitelist is enabled (`white-list=true`, `enforce-whitelist=true`).
- Only approved Minecraft player accounts (identified by username and UUID) can join.
- Whitelist entries are managed via Minecraft server console commands - no file editing
  or server restart required. See [operations.md](operations.md).

### 2. Manual Server Start and Stop

- The EC2 instance is started and stopped manually via the AWS Console or AWS CLI.
- Minecraft starts automatically when the EC2 instance starts (via systemd).
- Before the instance stops, Minecraft saves the world and shuts down gracefully
  (via `ExecStop` in the systemd unit).
- The EBS data volume and world data are preserved while the instance is stopped.
- The EC2 instance is configured with `instanceInitiatedShutdownBehavior=stop`
  so an OS-level shutdown or reboot stops the instance rather than terminating it.
- The EBS volume has `RemovalPolicy.RETAIN`, and - because it is attached
  out-of-band via `CfnVolumeAttachment` rather than declared in the instance's
  block device mapping - it is never deleted on instance termination. Together
  these survive both `cdk destroy` and accidental instance termination.
- Exact start, stop, status, and connection commands are documented in [operations.md](operations.md).

### 3. Hourly Backups with Five-Backup Retention

- A systemd timer triggers a backup every hour while the instance is running.
- The backup script checks whether `minecraft.service` is active before proceeding;
  if not, it exits cleanly without error.
- Before archiving, the script sends `save-off` and `save-all flush` via the server
  console FIFO, then waits for `"Saved the game"` in the server log.
- The `save-on` command is sent unconditionally on exit (via a bash `trap`), even
  if the backup fails.
- Backups are streamed directly to S3 using `tar | aws s3 cp` - no temporary files
  are written to the data volume.
- Each backup archive includes: world data (all dimension directories), `server.properties`,
  `whitelist.json`, `ops.json`, `banned-players.json`, `banned-ips.json` (all that exist).
- After a successful upload, the S3 object is presence-verified via `head-object`.
- Only after successful verification: old backups beyond the retention count are pruned.
- If the upload or verification fails, no existing backups are deleted.
- All backup events are logged to `/var/log/minecraft/backup.log` and shipped to
  CloudWatch Logs (`/minecraft/backup`).
- A documented restore procedure and restore script are provided.
  See [backup-and-restore.md](backup-and-restore.md).

---

## Infrastructure Requirements

| Resource | Specification |
|---|---|
| EC2 instance | `t3.medium`, Amazon Linux 2023, single public subnet |
| EBS data volume | 20 GiB, gp3, encrypted, `RemovalPolicy.RETAIN`, `DeleteOnTermination=false` |
| S3 backup bucket | Private, SSE-S3 encryption, HTTPS-only, `RemovalPolicy.RETAIN` |
| Security group | Inbound TCP 25565 only; no SSH rule |
| IAM role | Least-privilege: SSM, scoped S3, scoped CloudWatch Logs |
| Elastic IP | Static public IPv4, `RemovalPolicy.RETAIN` |
| CloudWatch log groups | `/minecraft/server` and `/minecraft/backup`, 30-day retention |
| CloudWatch alarms | CPU > 90% (15 min), backup failure metric filter |
| AWS Budget | Monthly threshold with email alert |
| CDK location | `infra/` subdirectory |
| Stack termination protection | Enabled |

### Centralized Configuration

All tunable parameters are defined in `infra/config/server-config.ts`:

- AWS region
- EC2 instance type
- Minecraft version
- Minecraft port
- EBS volume size
- Java memory allocation (`-Xms`, `-Xmx`)
- Backup retention count
- Log retention days
- Monthly budget threshold (`monthlyBudgetUsd`). The alert email itself is
  *not* part of this file or any local config - see "Budget Alert Email" below
- EULA acceptance flag
- Optional DNS hostname and hosted zone ID

### Budget Alert Email

The budget alert email address is deliberately kept out of source, config files,
and `.env` files. It's stored in AWS Systems Manager Parameter Store as a
standard `String` parameter, `/minecraft/budget-alert-email`, and referenced
from `infra/lib/minecraft-stack.ts` via a CloudFormation dynamic reference
(`{{resolve:ssm:...}}`). CloudFormation resolves it at deploy time - the real
address never appears in the synthesized template, in `cdk.out/`, or in
`describe-stacks` output.

The parameter must exist before the first deploy:

```bash
aws ssm put-parameter --name /minecraft/budget-alert-email \
  --type String --value "you@example.com" --region us-west-2
```

To change the alert address later, overwrite the parameter (`--overwrite`) and
redeploy - no code change is needed.

---

## Safety Requirements

- `cdk deploy` is never run without operator review and approval.
- No AWS write operations are performed by the planning or implementation process.
- AWS credentials, secrets, world files, and player data are never stored in Git.
- The EC2 instance role has no administrator permissions and no EC2 attachment actions.
- Deletion-sensitive resources (EBS volume, S3 bucket, Elastic IP) use `RemovalPolicy.RETAIN`.
- The `minecraftEulaAccepted` flag defaults to `false` in the repository. It must be set
  to `true` locally only after the operator reads and accepts the Minecraft EULA.
  This value must never be committed as `true`.

---

## Assumptions and Constraints

- Minecraft Java Edition 26.1.2 requires Java 25 (Amazon Corretto 25).
- The server is intended for a small group (2-10 players). The `t3.medium` instance
  type is appropriate for this scale.
- No load balancer, ECS, EKS, GameLift, or multiple EC2 instances are used.
- DNS is optional. If `dnsHostname` and `hostedZoneId` are both set in config, a
  Route 53 A record is created. Otherwise, players connect by IP address.
- The public IPv4 address is stable (Elastic IP) but costs $0.005/hr at all times,
  including while the instance is stopped.

---

## Out of Scope (Version 1)

- Automatic EC2 instance start/stop scheduling
- Player activity monitoring or auto-shutdown on idle
- Minecraft mod support or mod management
- Multiple server instances or server switching
- Web-based administration panel
- Automated DNS provisioning or domain registration
