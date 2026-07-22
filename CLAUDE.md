# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

AWS CDK (TypeScript) project that provisions a single EC2 instance running a
Minecraft Java Edition server, with a persistent EBS data volume, hourly backups
to S3, a static Elastic IP, and admin access via SSM Session Manager (no SSH).
All CDK code lives under `infra/`; instance-side bash/systemd assets live under
`infra/assets/`; design docs live under `docs/`.

Read `docs/architecture.md` (component design + diagram), `docs/requirements.md`
(authoritative spec), and `docs/security.md` before making infrastructure changes -
they define constraints (e.g. no SSH, least-privilege IAM, `RemovalPolicy.RETAIN`
on stateful resources) that a change should not silently violate.

## Commands

All commands run from `infra/`:

```bash
npm run build          # tsc type-check (noEmit)
npm run watch          # tsc -w
npm test               # jest - CDK assertion tests in infra/test/*.test.ts
npx jest -t "<name>"   # run a single test by name
npx cdk synth          # emit CloudFormation template to cdk.out/
npx cdk diff           # compare deployed stack with current code
npx cdk deploy         # deploy - see "Safety" below
```

Bash unit tests for the backup script (bats), run from the repo root:

```bash
bats infra/test/backup.bats
```

`npx cdk` and jest are invoked via `npx`/`npm` scripts - there is no global CDK
install assumed. `cdk.json` runs the app as `npx tsc && npx tsx bin/minecraft.ts`,
so `cdk synth`/`diff`/`deploy` type-check first.

## Safety - read before touching infra

- **Never run `cdk deploy` or any AWS-mutating command** (`aws ec2 start/stop-instances`,
  `aws s3`, etc.) without the operator's explicit review and approval. This is a hard
  requirement from `docs/requirements.md`, not just a convention. `cdk synth`/`diff`
  and `npm test` are read-only/local and fine to run freely.
- `infra/config/server-config.ts` has `minecraftEulaAccepted: false` as the committed
  default. Never change this to `true` in a commit - `install.sh` refuses to run the
  server unless it's `true`, and flipping it is a local-only, operator-driven decision
  (see `docs/security.md`).
- Stateful resources (EBS data volume, S3 backup bucket, Elastic IP) use
  `RemovalPolicy.RETAIN` deliberately. Don't change these to `DESTROY`.
- The stack has `terminationProtection = true`. Don't disable it in code as a
  workaround for a blocked `cdk destroy`.
- No SSH: the security group intentionally has exactly one inbound rule (Minecraft's
  port, from `config.minecraftPort`). Don't add a port-22 rule or a KeyPair.

## Architecture

Two CDK stack files exist in `infra/lib/`; only one is real:

- `minecraft-stack.ts` - the actual stack, instantiated in `bin/minecraft.ts` as
  `MinecraftStack`. All work happens here.
- `infra-stack.ts` - leftover `cdk init` boilerplate (`InfraStack`), not imported
  or deployed anywhere. `test/infra.test.ts` is its matching stub, fully commented
  out. Ignore both unless explicitly asked to clean them up.

`MinecraftStack` (`infra/lib/minecraft-stack.ts`) is organized as one linear
constructor with commented `// Task N` sections; when extending it, follow that
section grouping (VPC/SG, EBS+S3, IAM, bootstrap asset, CloudWatch/budget, EIP+DNS,
EC2 instance+outputs) rather than scattering new resources.

Key design points that shape how changes should be made:

- **Everything server-side is a versioned S3 asset, not inline user-data.** User-data
  (built in `minecraft-stack.ts`) is a small script (<1 KB) that downloads
  `infra/assets/` as a zip, SHA256-verifies it, and runs `install.sh`. To change
  server/backup behavior, edit files under `infra/assets/` (`install.sh`,
  `start-minecraft.sh`, `backup.sh`, `restore.sh`, systemd units,
  `cloudwatch-agent-config.json`) - don't add logic directly into the CDK-generated
  user-data string unless it's a new environment variable to pass through.
- **Config is centralized** in `infra/config/server-config.ts` (`ServerConfig`
  interface + `defaultConfig`). All tunables (instance type, Minecraft version,
  volume size, Java heap, backup retention, budget, optional DNS) flow from there
  into both the CDK stack and, via user-data environment variables, into
  `install.sh`.
- **The EBS volume is identified by Volume ID -> NVMe serial, not by Linux device
  name** (`find-ebs-device.sh`), because Nitro instances don't guarantee `/dev/sdf`
  naming. It's then mounted by filesystem UUID via `/etc/fstab` for stability across
  reboots. The instance role has no `ec2:AttachVolume`; attachment is a
  `CfnVolumeAttachment` done by CloudFormation at deploy time.
- **Minecraft runs as a direct systemd-supervised foreground JVM**, not inside
  tmux/screen. Console input goes through a FIFO at `/run/minecraft/stdin`, opened
  read/write on fd 3 by `start-minecraft.sh` so it doesn't EOF between writers.
  `backup.sh` and `ExecStop` both send commands (`save-off`, `save-all flush`,
  `stop`) through this FIFO rather than RCON.
- **Backups stream directly to S3 with no disk staging**: `tar | aws s3 cp -` piped
  straight up, verified after the fact with `head-object`, and only then are old
  backups (beyond `backupRetentionCount`) pruned - so a failed/unverified upload
  never causes data loss. `backup.sh` uses `flock` to prevent overlapping runs and
  a bash `EXIT` trap to unconditionally send `save-on`, even on failure.
- **Bootstrap is idempotent and safe to re-run**: `install.sh` re-run via SSM
  (documented in `docs/operations.md`) skips already-done steps (existing user,
  formatted filesystem, downloaded jar) and never overwrites operator-modified
  `server.properties`/`whitelist.json`. This is the supported path for applying
  asset changes to a running instance without replacing it.
- Everything administrative goes through **SSM Session Manager**, never SSH -
  `docs/operations.md` has the exact commands for start/stop/status/console/logs/backup.

## Tests

- `infra/test/*.test.ts` - Jest + `aws-cdk-lib/assertions` `Template` snapshots
  against synthesized CloudFormation from `MinecraftStack` (security group rules,
  IAM policy scoping, resource properties, etc.). Use `makeStack(overrides)` helper
  to build a `Template` with a partial `ServerConfig` override.
- `infra/test/backup.bats` - bats tests for `infra/assets/backup.sh` in isolation,
  mocking the FIFO, `aws` CLI, and `systemctl` via a fake `PATH` entry so no real
  AWS access or running Minecraft server is needed.
