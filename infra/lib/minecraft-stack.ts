import * as path from 'path';
import * as cdk from 'aws-cdk-lib/core';
import { RemovalPolicy, Duration, CfnOutput, Tags } from 'aws-cdk-lib/core';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3assets from 'aws-cdk-lib/aws-s3-assets';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as budgets from 'aws-cdk-lib/aws-budgets';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as cr from 'aws-cdk-lib/custom-resources';
import { Construct } from 'constructs';
import { ServerConfig } from '../config/server-config.js';

export interface MinecraftStackProps extends cdk.StackProps {
  serverConfig: ServerConfig;
}

export class MinecraftStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: MinecraftStackProps) {
    super(scope, id, props);

    const config = props.serverConfig;

    // -------------------------------------------------------------------------
    // Stack-level termination protection
    // -------------------------------------------------------------------------
    this.terminationProtection = true;

    // =========================================================================
    // Task 2 - VPC, security group, AZ selection
    // =========================================================================

    // Single public subnet, no NAT gateway (no cost for NAT).
    // maxAzs: 1 pins everything to one AZ, which is required for EBS attachment.
    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 1,
      natGateways: 0,
      subnetConfiguration: [
        {
          name: 'public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24,
        },
      ],
    });

    // The single public subnet - used for both the instance and the EBS volume AZ.
    const publicSubnet = vpc.publicSubnets[0];

    const securityGroup = new ec2.SecurityGroup(this, 'MinecraftSg', {
      vpc,
      description: 'Minecraft server security group - inbound TCP 25565 only',
      allowAllOutbound: true, // Required for SSM, S3, Mojang JAR download
    });

    // Allow Minecraft clients to connect. No SSH rule added.
    securityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(config.minecraftPort),
      `Minecraft Java Edition port ${config.minecraftPort}`,
    );

    // =========================================================================
    // Task 4 - Encrypted EBS volume and S3 backup bucket
    // =========================================================================

    // EBS volume pinned to the same AZ as the public subnet.
    // RemovalPolicy.RETAIN: the volume survives cdk destroy.
    // This data volume is attached separately from the root volume and retained
    // across instance replacement and stack deletion.
    const dataVolume = new ec2.Volume(this, 'MinecraftDataVolume', {
      availabilityZone: publicSubnet.availabilityZone,
      size: cdk.Size.gibibytes(config.ebsVolumeSizeGb),
      volumeType: ec2.EbsDeviceVolumeType.GP3,
      encrypted: true,
      removalPolicy: RemovalPolicy.RETAIN,
    });
    Tags.of(dataVolume).add('Name', 'minecraft-data');

    // Private encrypted S3 backup bucket.
    // RemovalPolicy.RETAIN: the bucket survives cdk destroy.
    const backupBucket = new s3.Bucket(this, 'MinecraftBackupBucket', {
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      versioned: false,
      removalPolicy: RemovalPolicy.RETAIN,
      autoDeleteObjects: false,
      enforceSSL: true, // Adds bucket policy denying non-HTTPS requests
    });

    // =========================================================================
    // Task 3 - IAM role (least privilege)
    // =========================================================================

    const instanceRole = new iam.Role(this, 'MinecraftInstanceRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      description: 'Minecraft EC2 instance role - SSM, S3 backup, CloudWatch Logs',
    });

    // SSM Session Manager (no SSH required)
    instanceRole.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
    );

    // S3 backup bucket access - scoped to this bucket only
    instanceRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'MinecraftBackupBucketAccess',
        effect: iam.Effect.ALLOW,
        actions: [
          's3:PutObject',
          's3:GetObject',
          's3:DeleteObject',
        ],
        resources: [`${backupBucket.bucketArn}/*`],
      }),
    );
    instanceRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'MinecraftBackupBucketList',
        effect: iam.Effect.ALLOW,
        actions: ['s3:ListBucket'],
        resources: [backupBucket.bucketArn],
      }),
    );

    // CloudWatch Logs - scoped to /minecraft/* log groups
    const logGroupArnPrefix = `arn:aws:logs:${this.region}:${this.account}:log-group:/minecraft`;
    instanceRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'MinecraftCloudWatchLogs',
        effect: iam.Effect.ALLOW,
        actions: [
          'logs:CreateLogGroup',
          'logs:CreateLogStream',
          'logs:PutLogEvents',
          'logs:DescribeLogStreams',
        ],
        resources: [
          `${logGroupArnPrefix}*`,
          `${logGroupArnPrefix}*:*`,
        ],
      }),
    );

    // CloudWatch agent needs to describe log groups and put metric data
    instanceRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'MinecraftCloudWatchMetrics',
        effect: iam.Effect.ALLOW,
        actions: [
          'cloudwatch:PutMetricData',
          'ec2:DescribeVolumes',
          'ec2:DescribeTags',
        ],
        resources: ['*'],
      }),
    );

    // =========================================================================
    // Task 5 - CDK S3 asset (bootstrap tarball)
    // =========================================================================

    // All instance-side files are packaged as a versioned S3 asset.
    // User-data downloads and runs the asset - stays well under 16 KB.
    const bootstrapAsset = new s3assets.Asset(this, 'BootstrapAsset', {
      path: path.join(__dirname, '../assets'),
    });

    // Grant the instance role read access to only this asset's object key.
    // Asset.grantRead() grants s3:GetBucket*/GetObject*/List* on the *entire*
    // CDK bootstrap-assets bucket (every asset from every stack ever published
    // under this account/region's CDK qualifier) - it does not scope to the
    // object key. Use an explicit statement scoped to the exact object ARN instead.
    instanceRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'MinecraftBootstrapAssetAccess',
        effect: iam.Effect.ALLOW,
        actions: ['s3:GetObject'],
        resources: [bootstrapAsset.bucket.arnForObjects(bootstrapAsset.s3ObjectKey)],
      }),
    );

    // =========================================================================
    // Task 10 - CloudWatch log groups, metric filters, alarms, and budget
    // =========================================================================

    const serverLogGroup = new logs.LogGroup(this, 'MinecraftServerLogGroup', {
      logGroupName: '/minecraft/server',
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: RemovalPolicy.DESTROY,
    });

    const backupLogGroup = new logs.LogGroup(this, 'MinecraftBackupLogGroup', {
      logGroupName: '/minecraft/backup',
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: RemovalPolicy.DESTROY,
    });

    // Metric filter: count BACKUP_FAILED log lines
    const backupFailureFilter = new logs.MetricFilter(this, 'BackupFailureFilter', {
      logGroup: backupLogGroup,
      metricNamespace: 'Minecraft',
      metricName: 'BackupFailures',
      filterPattern: logs.FilterPattern.literal('BACKUP_FAILED'),
      metricValue: '1',
      defaultValue: 0,
    });

    const backupFailureAlarm = new cloudwatch.Alarm(this, 'BackupFailureAlarm', {
      alarmName: 'MinecraftBackupFailure',
      alarmDescription: 'One or more Minecraft backups failed in the past hour',
      metric: backupFailureFilter.metric({
        statistic: 'Sum',
        period: Duration.hours(1),
      }),
      threshold: 1,
      evaluationPeriods: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // Budget alert email is never stored in source or config. It's read from
    // an existing SSM parameter via a CloudFormation dynamic reference
    // ({{resolve:ssm:...}}), resolved by CloudFormation at deploy time - the
    // real address never appears in the synthesized template, in source, or
    // in `describe-stacks` output (unlike AWS::SSM::Parameter::Value<String>
    // template parameters, dynamic references aren't echoed back anywhere).
    // Create the parameter once, before the first deploy:
    //   aws ssm put-parameter --name /minecraft/budget-alert-email \
    //     --type String --value "you@example.com" --region us-west-2
    const budgetAlertEmail = ssm.StringParameter.fromStringParameterAttributes(
      this,
      'BudgetAlertEmailParameter',
      {
        parameterName: '/minecraft/budget-alert-email',
        forceDynamicReference: true,
      },
    ).stringValue;

    // Monthly billing budget with email alert
    new budgets.CfnBudget(this, 'MinecraftBudget', {
      budget: {
        budgetName: 'MinecraftMonthlyBudget',
        budgetType: 'COST',
        timeUnit: 'MONTHLY',
        budgetLimit: {
          amount: config.monthlyBudgetUsd,
          unit: 'USD',
        },
      },
      notificationsWithSubscribers: [
        {
          notification: {
            notificationType: 'ACTUAL',
            comparisonOperator: 'GREATER_THAN',
            threshold: 80, // Alert at 80% of budget
            thresholdType: 'PERCENTAGE',
          },
          subscribers: [
            {
              subscriptionType: 'EMAIL',
              address: budgetAlertEmail,
            },
          ],
        },
        {
          notification: {
            notificationType: 'ACTUAL',
            comparisonOperator: 'GREATER_THAN',
            threshold: 100,
            thresholdType: 'PERCENTAGE',
          },
          subscribers: [
            {
              subscriptionType: 'EMAIL',
              address: budgetAlertEmail,
            },
          ],
        },
      ],
    });

    // =========================================================================
    // Task 11 - Elastic IP and optional Route 53 DNS
    // =========================================================================

    // Allocate a static Elastic IP.
    // RemovalPolicy.RETAIN prevents accidental release on cdk destroy.
    // After decommission, release manually:
    //   aws ec2 release-address --allocation-id <EipAllocationId output>
    const eip = new ec2.CfnEIP(this, 'MinecraftEip', {
      domain: 'vpc',
    });
    eip.applyRemovalPolicy(RemovalPolicy.RETAIN);

    // Optional Route 53 A record - only created when both fields are set
    if (config.dnsHostname && config.hostedZoneId) {
      const hostedZone = route53.HostedZone.fromHostedZoneAttributes(
        this,
        'HostedZone',
        {
          hostedZoneId: config.hostedZoneId,
          zoneName: config.dnsHostname.split('.').slice(1).join('.'),
        },
      );
      new route53.ARecord(this, 'MinecraftDnsRecord', {
        zone: hostedZone,
        recordName: config.dnsHostname,
        target: route53.RecordTarget.fromIpAddresses(eip.ref),
        ttl: Duration.minutes(5),
        comment: 'Minecraft server Elastic IP',
      });
    }

    // =========================================================================
    // Task 12 - EC2 instance, volume attachment, EIP association, outputs
    // =========================================================================

    // Build user-data: minimal script that downloads and runs the bootstrap asset.
    // All substitution values are passed as environment variables so the script
    // itself is generic and the 16 KB limit is not approached.
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      'set -euo pipefail',
      'exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1',
      '',
      '# ---- Bootstrap environment variables (injected by CDK) ----',
      `export ASSET_BUCKET="${bootstrapAsset.s3BucketName}"`,
      `export ASSET_KEY="${bootstrapAsset.s3ObjectKey}"`,
      `export MINECRAFT_VERSION="${config.minecraftVersion}"`,
      `export MINECRAFT_PORT="${config.minecraftPort}"`,
      `export MINECRAFT_EULA_ACCEPTED="${config.minecraftEulaAccepted}"`,
      `export JAVA_XMS="${config.javaMemoryXms}"`,
      `export JAVA_XMX="${config.javaMemoryXmx}"`,
      `export BACKUP_BUCKET="${backupBucket.bucketName}"`,
      `export BACKUP_RETENTION="${config.backupRetentionCount}"`,
      `export AWS_DEFAULT_REGION="${this.region}"`,
      // Volume ID is not known until synth time - use CloudFormation Ref via token
      `export EBS_VOLUME_ID="${dataVolume.volumeId}"`,
      '',
      // No separate checksum step: ASSET_KEY is itself content-addressed (a hash
      // of the source), the download is over TLS, and the instance role can only
      // read this exact object key (see MinecraftBootstrapAssetAccess policy) -
      // together these already give integrity and authenticity. A prior version
      // of this script compared against bootstrapAsset.assetHash, but that value
      // is CDK's own directory-fingerprint (used to name the S3 key), not the
      // SHA256 of the published .zip bytes, so the check could never pass.
      '# ---- Download bootstrap asset from S3 ----',
      'TMPDIR=$(mktemp -d)',
      'trap \'rm -rf "$TMPDIR"\' EXIT',
      '',
      'aws s3 cp "s3://${ASSET_BUCKET}/${ASSET_KEY}" "${TMPDIR}/bootstrap.zip"',
      '',
      '# ---- Extract and run installer ----',
      'unzip -q "${TMPDIR}/bootstrap.zip" -d "${TMPDIR}/bootstrap"',
      'chmod +x "${TMPDIR}/bootstrap/install.sh"',
      '"${TMPDIR}/bootstrap/install.sh"',
    );

    const instance = new ec2.Instance(this, 'MinecraftInstance', {
      vpc,
      vpcSubnets: { subnets: [publicSubnet] },
      instanceType: new ec2.InstanceType(config.instanceType),
      machineImage: ec2.MachineImage.latestAmazonLinux2023(),
      securityGroup,
      role: instanceRole,
      userData,
      // Disable auto-assigned public IP - the Elastic IP is the public address
      associatePublicIpAddress: false,
      requireImdsv2: true,
      userDataCausesReplacement: true,
    });

    // Bootstrap changes intentionally replace the EC2 instance. The retained
    // world volume is handed over separately by a custom resource below, since
    // CloudFormation's native VolumeAttachment replacement order cannot safely
    // move a single EBS volume between old and new instances during a rollout.

    // instanceInitiatedShutdownBehavior: stop - OS shutdown/reboot stops the
    // instance rather than terminating it. Protects against accidental data loss.
    const cfnInstance = instance.node.defaultChild as ec2.CfnInstance;
    cfnInstance.instanceInitiatedShutdownBehavior = 'stop';

    const volumeAttachmentHandler = new lambda.Function(this, 'VolumeAttachmentHandler', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      timeout: Duration.minutes(15),
      code: lambda.Code.fromInline(`
import json
import time
import urllib.request
import boto3
from botocore.exceptions import ClientError

ec2 = boto3.client("ec2")

SUCCESS = "SUCCESS"
FAILED = "FAILED"

def send(event, context, status, data=None, physical_id=None, reason=None):
    body = json.dumps({
        "Status": status,
        "Reason": reason or f"See CloudWatch Logs: {context.log_stream_name}",
        "PhysicalResourceId": physical_id or event.get("PhysicalResourceId") or event["LogicalResourceId"],
        "StackId": event["StackId"],
        "RequestId": event["RequestId"],
        "LogicalResourceId": event["LogicalResourceId"],
        "Data": data or {},
    }).encode("utf-8")
    req = urllib.request.Request(
        event["ResponseURL"],
        data=body,
        method="PUT",
        headers={"Content-Type": "", "Content-Length": str(len(body))},
    )
    with urllib.request.urlopen(req):
        return

def describe_instance_state(instance_id):
    try:
        result = ec2.describe_instances(InstanceIds=[instance_id])
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code in ("InvalidInstanceID.NotFound", "InvalidInstanceID.Malformed"):
            return None
        raise
    reservations = result.get("Reservations", [])
    if not reservations or not reservations[0].get("Instances"):
        return None
    return reservations[0]["Instances"][0]["State"]["Name"]

def wait_for_instance_stopped(instance_id, timeout_seconds=600):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        state = describe_instance_state(instance_id)
        if state in (None, "stopped", "terminated"):
            return
        time.sleep(5)
    raise RuntimeError(f"Timed out waiting for instance {instance_id} to stop")

def stop_instance(instance_id):
    state = describe_instance_state(instance_id)
    if state in (None, "stopped", "terminated"):
        return
    ec2.stop_instances(InstanceIds=[instance_id])
    wait_for_instance_stopped(instance_id)

def current_attachments(volume_id):
    response = ec2.describe_volumes(VolumeIds=[volume_id])
    return response["Volumes"][0].get("Attachments", [])

def wait_for_attachment_state(volume_id, instance_id, expected_state, timeout_seconds=600):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        for attachment in current_attachments(volume_id):
            if attachment.get("InstanceId") == instance_id and attachment.get("State") == expected_state:
                return
        time.sleep(5)
    raise RuntimeError(
        f"Timed out waiting for volume {volume_id} attachment on {instance_id} to reach {expected_state}"
    )

def wait_for_volume_available(volume_id, timeout_seconds=600):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        attachments = current_attachments(volume_id)
        if not attachments:
            return
        time.sleep(5)
    raise RuntimeError(f"Timed out waiting for volume {volume_id} to become detached")

def detach_from_other_instances(volume_id, target_instance_id):
    attachments = current_attachments(volume_id)
    for attachment in attachments:
        instance_id = attachment.get("InstanceId")
        state = attachment.get("State")
        if instance_id == target_instance_id and state in ("attaching", "attached"):
            return
        if instance_id != target_instance_id:
            stop_instance(instance_id)
            ec2.detach_volume(VolumeId=volume_id, InstanceId=instance_id)
            wait_for_volume_available(volume_id)

def ensure_attached(volume_id, instance_id, device):
    for attachment in current_attachments(volume_id):
        if attachment.get("InstanceId") == instance_id and attachment.get("State") in ("attaching", "attached"):
            wait_for_attachment_state(volume_id, instance_id, "attached")
            return
    ec2.attach_volume(VolumeId=volume_id, InstanceId=instance_id, Device=device)
    wait_for_attachment_state(volume_id, instance_id, "attached")

def handler(event, context):
    props = event["ResourceProperties"]
    volume_id = props["VolumeId"]
    instance_id = props["InstanceId"]
    device = props["Device"]
    physical_id = f"{volume_id}-attachment"
    try:
        request_type = event["RequestType"]
        if request_type == "Delete":
            send(event, context, SUCCESS, {"VolumeId": volume_id}, physical_id)
            return
        detach_from_other_instances(volume_id, instance_id)
        ensure_attached(volume_id, instance_id, device)
        send(event, context, SUCCESS, {"VolumeId": volume_id, "InstanceId": instance_id}, physical_id)
    except Exception as exc:
        send(event, context, FAILED, {"Error": str(exc)}, physical_id, str(exc))
`),
    });
    volumeAttachmentHandler.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'ec2:AttachVolume',
        'ec2:DescribeInstances',
        'ec2:DescribeVolumes',
        'ec2:DetachVolume',
        'ec2:StopInstances',
      ],
      resources: ['*'],
    }));

    const volumeAttachmentProvider = new cr.Provider(this, 'VolumeAttachmentProvider', {
      onEventHandler: volumeAttachmentHandler,
    });

    const volumeAttachment = new cdk.CustomResource(this, 'MinecraftVolumeHandoff', {
      serviceToken: volumeAttachmentProvider.serviceToken,
      properties: {
        InstanceId: instance.instanceId,
        VolumeId: dataVolume.volumeId,
        Device: '/dev/sdf',
      },
    });

    // Ensure volume is attached before instance starts initialising
    instance.node.addDependency(dataVolume);
    volumeAttachment.node.addDependency(instance);
    volumeAttachment.node.addDependency(dataVolume);

    // Only the root volume is declared here. The data volume is deliberately
    // absent from this list - it is attached separately above via a custom
    // control-plane AttachVolume operation, not part of the
    // instance's launch-time block device mapping). EBS volumes attached that
    // way are never deleted on instance termination; DeleteOnTermination only
    // applies to volumes declared in the mapping below. CfnVolumeAttachment
    // itself has no DeleteOnTermination property. Combined with the data
    // volume's own RemovalPolicy.RETAIN, this protects it across both
    // instance termination and cdk destroy.
    cfnInstance.blockDeviceMappings = [
      {
        // Root volume - keep default size, just ensure no accidental termination delete
        deviceName: '/dev/xvda',
        ebs: {
          deleteOnTermination: true, // Root volume is ephemeral, fine to delete
          volumeType: 'gp3',
        },
      },
    ];

    // Associate the Elastic IP with the instance.
    // CloudFormation automatically re-associates on instance replacement.
    const eipAssociation = new ec2.CfnEIPAssociation(this, 'MinecraftEipAssociation', {
      allocationId: eip.attrAllocationId,
      instanceId: instance.instanceId,
    });
    eipAssociation.node.addDependency(instance);

    // CPU utilization alarm - built from a CloudWatch Metric scoped to this instance
    const cpuAlarm = new cloudwatch.Alarm(this, 'CpuHighAlarm', {
      alarmName: 'MinecraftCpuHigh',
      alarmDescription: 'Minecraft EC2 CPU utilization > 90% for 15 minutes',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/EC2',
        metricName: 'CPUUtilization',
        dimensionsMap: { InstanceId: instance.instanceId },
        period: Duration.minutes(5),
        statistic: 'Average',
      }),
      threshold: 90,
      evaluationPeriods: 3, // 3 × 5 min = 15 min sustained
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // =========================================================================
    // Stack outputs
    // =========================================================================

    new CfnOutput(this, 'ElasticIpAddress', {
      value: eip.ref,
      description: 'Elastic IP address - stable across EC2 stop/start cycles',
    });

    new CfnOutput(this, 'EipAllocationId', {
      value: eip.attrAllocationId,
      description:
        'Elastic IP allocation ID. After decommission, release with: ' +
        'aws ec2 release-address --allocation-id <value>',
    });

    new CfnOutput(this, 'MinecraftConnectionAddress', {
      value: `${eip.ref}:${config.minecraftPort}`,
      description: 'Minecraft server connection address (IP:port)',
    });

    new CfnOutput(this, 'InstanceId', {
      value: instance.instanceId,
      description: 'EC2 instance ID',
    });

    new CfnOutput(this, 'BackupBucketName', {
      value: backupBucket.bucketName,
      description: 'S3 bucket for Minecraft world backups',
    });

    new CfnOutput(this, 'EbsVolumeId', {
      value: dataVolume.volumeId,
      description: 'EBS data volume ID (persists on cdk destroy)',
    });

    new CfnOutput(this, 'ServerLogGroupName', {
      value: serverLogGroup.logGroupName,
      description: 'CloudWatch log group for Minecraft server logs',
    });

    new CfnOutput(this, 'BackupLogGroupName', {
      value: backupLogGroup.logGroupName,
      description: 'CloudWatch log group for Minecraft backup logs',
    });

    // DNS output only when configured
    if (config.dnsHostname && config.hostedZoneId) {
      new CfnOutput(this, 'DnsConnectionAddress', {
        value: `${config.dnsHostname}:${config.minecraftPort}`,
        description: 'Minecraft server DNS connection address',
      });
    }

    // Suppress unused variable warnings for resources referenced only for side effects
    void backupFailureAlarm;
    void cpuAlarm;
    void volumeAttachment;
  }
}
