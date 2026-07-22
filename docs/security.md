# Security

## Principles

- **No public SSH**: The instance has no inbound SSH rule. All administration uses
  AWS Systems Manager Session Manager over HTTPS.
- **Least-privilege IAM**: The instance role grants only the specific permissions
  needed — SSM, scoped S3, scoped CloudWatch Logs. No wildcard resources or actions.
- **Encryption at rest**: The EBS data volume is encrypted. The S3 backup bucket uses
  SSE-S3 encryption. Both are enforced at the CDK resource level.
- **Encryption in transit**: The S3 bucket policy denies any request that does not use
  HTTPS (`aws:SecureTransport: false` → `Deny`).
- **No secrets in Git**: AWS credentials, RCON passwords, world files, and player data
  are never committed. The `.gitignore` enforces this.

---

## Network Security

### Security Group

The Minecraft security group has exactly one inbound rule:

| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 25565 | 0.0.0.0/0 | Minecraft Java Edition clients |
| Outbound | All | All | 0.0.0.0/0 | SSM, S3, Mojang, CloudWatch |

There is no inbound rule for SSH (port 22). The default VPC security group is not
attached to the instance.

### IMDSv2

The EC2 instance requires IMDSv2 (`requireImdsv2: true`). This prevents SSRF-based
attacks against the instance metadata service.

---

## Administration: SSM Session Manager

No bastion host or SSH key is needed. To open an interactive shell:

```bash
# Using AWS CLI (requires Session Manager plugin installed)
aws ssm start-session --target <instance-id> --region us-west-2

# Or use the AWS Console:
# EC2 → Instances → Select instance → Connect → Session Manager → Connect
```

The instance role includes `AmazonSSMManagedInstanceCore`, which grants the SSM agent
permission to register and receive commands. No inbound ports are opened for this.

### Least-Privilege Session Manager Policy

The `AmazonSSMManagedInstanceCore` managed policy grants:
- `ssm:DescribeAssociation`, `ssm:GetDocument`, `ssm:ListAssociations` (read-only SSM config)
- `ssmmessages:*` (secure channel for Session Manager)
- `ec2messages:*` (Run Command channel)

The operator's IAM user/role (not the instance role) requires `ssm:StartSession`
permission to initiate sessions.

---

## IAM Instance Role

The instance role (`MinecraftInstanceRole`) has the following permissions:

| Scope | Actions | Resource |
|---|---|---|
| SSM agent | Via `AmazonSSMManagedInstanceCore` managed policy | Various SSM/EC2 messages |
| S3 backup bucket | `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` | `arn:aws:s3:::bucket/*` |
| S3 backup bucket | `s3:ListBucket` | `arn:aws:s3:::bucket` |
| CloudWatch Logs | `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams` | `arn:aws:logs:region:account:log-group:/minecraft*` |
| CloudWatch metrics | `cloudwatch:PutMetricData` | `*` (required by CW agent) |
| EC2 metadata | `ec2:DescribeVolumes`, `ec2:DescribeTags` | `*` (required by CW agent) |

The role has **no** `ec2:AttachVolume`, `ec2:DetachVolume`, or any other EC2 control-plane
permissions. EBS attachment is managed by CloudFormation at deploy time via
`CfnVolumeAttachment`.

---

## EBS Encryption

The data volume is encrypted using the AWS-managed EBS key (`aws/ebs`) for the account
and region. This is enforced in the CDK resource (`encrypted: true`). Encryption cannot
be removed after volume creation.

---

## S3 Bucket Security

The backup bucket has the following protections:

- `BlockPublicAccess.BLOCK_ALL` — no public access under any circumstances
- SSE-S3 encryption on all objects
- Bucket policy denying requests that do not use HTTPS (`enforceSSL: true` in CDK)
- No bucket versioning (backups use timestamped keys; versioning adds cost without benefit)
- No public ACLs on objects

---

## Minecraft Whitelist

The whitelist is enforced at the Minecraft server level:

```properties
white-list=true
online-mode=true
enforce-whitelist=true
```

`enforce-whitelist=true` removes connected players who are not on the whitelist
when the whitelist is reloaded. `online-mode=true` requires Minecraft accounts to
be authenticated by Mojang — players cannot connect with cracked/offline accounts.

Managing the whitelist does not require editing files or restarting the server.
See [operations.md](operations.md) for commands.

---

## EULA Compliance

The `minecraftEulaAccepted` configuration flag must be set to `true` before deploying.
The bootstrap script (`install.sh`) exits with an error if this flag is not `true`.

**The repository default is `false`.**

Before deploying, read the Minecraft EULA at https://aka.ms/MinecraftEULA and, if
you accept it, set `minecraftEulaAccepted: true` in `infra/config/server-config.ts`
in your local working copy. Do not commit this change to version control.

---

## Secrets and Credentials

- No RCON password is configured (RCON is disabled).
- No Minecraft server password is configured (`online-mode=true` uses Mojang auth).
- No SSH keys are generated or stored.
- AWS credentials are provided to the instance via the IAM instance role — no
  long-term credentials are stored on disk or in environment variables.
- The `.gitignore` excludes `.env`, `*.pem`, `credentials`, and similar files.

---

## CDK Asset Bucket

The CDK bootstrap process creates an S3 bucket for CDK assets (the bootstrap tarball).
This bucket is managed by CDK and is not accessible to the public. The instance role
has `s3:GetObject` scoped to the specific asset object key — it cannot list or read
other objects in the bucket.
