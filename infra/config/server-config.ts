/**
 * Centralized configuration for the Minecraft AWS stack.
 *
 * IMPORTANT - EULA:
 *   minecraftEulaAccepted is intentionally false in this repository.
 *   Before deploying, you must read and accept the Minecraft End User
 *   License Agreement at https://aka.ms/MinecraftEULA, then set the
 *   deploy-time environment variable CDK_MINECRAFT_EULA_ACCEPTED=true.
 *   Do NOT commit minecraftEulaAccepted: true to version control.
 *
 * NOTE - budgetAlertEmail:
 *   Not part of this config. The real address lives in AWS Systems Manager
 *   Parameter Store (see infra/lib/minecraft-stack.ts, parameter
 *   "/minecraft/budget-alert-email") and is resolved by CloudFormation at
 *   deploy time via a dynamic reference - it never appears in source, in
 *   the synthesized template, or in `describe-stacks` output.
 */
export interface ServerConfig {
  /** AWS region to deploy into. */
  region: string;

  /** EC2 instance type. t3.medium provides 4 GB RAM and is suitable for small groups. */
  instanceType: string;

  /** Minecraft Java Edition version string, e.g. '26.1.2'. */
  minecraftVersion: string;

  /** TCP port the Minecraft server listens on. Default is 25565. */
  minecraftPort: number;

  /** EBS data volume size in GiB. Minimum 20 GiB recommended. */
  ebsVolumeSizeGb: number;

  /** Java heap minimum size passed to -Xms. */
  javaMemoryXms: string;

  /** Java heap maximum size passed to -Xmx. */
  javaMemoryXmx: string;

  /** Number of hourly backups to retain. Oldest are pruned after a successful upload. */
  backupRetentionCount: number;

  /**
   * Must be set to true to deploy. Only change this after reading and accepting
   * the Minecraft EULA at https://aka.ms/MinecraftEULA.
   * Never commit this as true.
   */
  minecraftEulaAccepted: boolean;

  /** CloudWatch log retention in days. */
  logRetentionDays: number;

  /** Monthly billing budget threshold in USD. An alert email is sent when exceeded. */
  monthlyBudgetUsd: number;

  /**
   * Optional: hostname for a Route 53 A record pointing to the Elastic IP.
   * Leave empty to skip DNS record creation.
   * Example: 'minecraft.example.com'
   */
  dnsHostname: string;

  /**
   * Optional: Route 53 hosted zone ID for the DNS record.
   * Leave empty to skip DNS record creation.
   * Example: 'Z1234567890ABCDEF'
   */
  hostedZoneId: string;
}

/**
 * Default server configuration.
 *
 * Override individual values for your deployment. Do not commit
 * minecraftEulaAccepted: true.
 */
export const defaultConfig: ServerConfig = {
  region: 'us-west-2',
  instanceType: 't3.medium',
  minecraftVersion: '26.2',
  minecraftPort: 25565,
  ebsVolumeSizeGb: 20,
  javaMemoryXms: '2G',
  javaMemoryXmx: '2G',
  backupRetentionCount: 5,

  // EULA: false is the safe repository default.
  // Enable only at deploy time via CDK_MINECRAFT_EULA_ACCEPTED=true
  minecraftEulaAccepted: false,

  logRetentionDays: 30,
  monthlyBudgetUsd: 50,

  // Leave both empty to skip Route 53 DNS record creation.
  dnsHostname: '',
  hostedZoneId: '',
};

export function resolveConfigFromEnv(baseConfig: ServerConfig = defaultConfig): ServerConfig {
  const region =
    process.env.CDK_DEPLOY_REGION ??
    process.env.AWS_REGION ??
    process.env.AWS_DEFAULT_REGION ??
    baseConfig.region;

  return {
    ...baseConfig,
    region,
    minecraftEulaAccepted: process.env.CDK_MINECRAFT_EULA_ACCEPTED === 'true',
  };
}
