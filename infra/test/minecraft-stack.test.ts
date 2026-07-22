import * as cdk from 'aws-cdk-lib/core';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { MinecraftStack } from '../lib/minecraft-stack';
import { ServerConfig, defaultConfig } from '../config/server-config';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeStack(overrides: Partial<ServerConfig> = {}): Template {
  const app = new cdk.App();
  const config: ServerConfig = { ...defaultConfig, ...overrides };
  const stack = new MinecraftStack(app, 'TestStack', {
    env: { account: '123456789012', region: 'us-west-2' },
    serverConfig: config,
  });
  return Template.fromStack(stack);
}

// ---------------------------------------------------------------------------
// Task 2 — VPC and Security Group
// ---------------------------------------------------------------------------

describe('Security Group', () => {
  let template: Template;
  beforeAll(() => { template = makeStack(); });

  test('has exactly one inbound rule on the configured Minecraft port', () => {
    template.hasResourceProperties('AWS::EC2::SecurityGroup', {
      SecurityGroupIngress: Match.arrayWith([
        Match.objectLike({
          IpProtocol: 'tcp',
          FromPort: defaultConfig.minecraftPort,
          ToPort: defaultConfig.minecraftPort,
          CidrIp: '0.0.0.0/0',
        }),
      ]),
    });

    // Confirm the ingress array has exactly one rule
    const sgs = template.findResources('AWS::EC2::SecurityGroup', {
      Properties: Match.objectLike({
        SecurityGroupIngress: Match.anyValue(),
      }),
    });
    // There should be exactly one security group with ingress rules (the Minecraft SG)
    const sgKeys = Object.keys(sgs);
    const minecraftSg = sgKeys.find(k => {
      const ingress = sgs[k].Properties.SecurityGroupIngress;
      return Array.isArray(ingress) && ingress.length === 1 &&
        ingress[0].FromPort === defaultConfig.minecraftPort;
    });
    expect(minecraftSg).toBeDefined();
    const ingressRules = sgs[minecraftSg!].Properties.SecurityGroupIngress;
    expect(ingressRules).toHaveLength(1);
  });

  test('has no inbound rule for SSH (port 22)', () => {
    // Find all security groups and assert none have a port-22 ingress rule
    const allSgs = template.findResources('AWS::EC2::SecurityGroup');
    for (const sg of Object.values(allSgs)) {
      const ingress: Array<{ FromPort?: number; ToPort?: number }> =
        sg.Properties.SecurityGroupIngress ?? [];
      const sshRule = ingress.find(r => r.FromPort === 22 || r.ToPort === 22);
      expect(sshRule).toBeUndefined();
    }
  });

  test('allows all outbound traffic', () => {
    template.hasResourceProperties('AWS::EC2::SecurityGroup', {
      SecurityGroupEgress: Match.arrayWith([
        Match.objectLike({ IpProtocol: '-1', CidrIp: '0.0.0.0/0' }),
      ]),
    });
  });
});

describe('VPC', () => {
  let template: Template;
  beforeAll(() => { template = makeStack(); });

  test('has no NAT gateways', () => {
    template.resourceCountIs('AWS::EC2::NatGateway', 0);
  });

  test('has at least one public subnet', () => {
    // Public subnets are indicated by MapPublicIpOnLaunch or RouteTable with an IGW route
    template.resourceCountIs('AWS::EC2::InternetGateway', 1);
  });
});

// ---------------------------------------------------------------------------
// Task 3 — IAM Role
// ---------------------------------------------------------------------------

describe('IAM Role', () => {
  let template: Template;
  beforeAll(() => { template = makeStack(); });

  test('has AmazonSSMManagedInstanceCore managed policy attached', () => {
    // ManagedPolicyArns uses Fn::Join in synthesised CF, so match the policy
    // name within the serialised representation using objectLike.
    template.hasResourceProperties('AWS::IAM::Role', {
      ManagedPolicyArns: Match.arrayWith([
        Match.objectLike({
          'Fn::Join': Match.arrayWith([
            Match.arrayWith([
              Match.stringLikeRegexp('AmazonSSMManagedInstanceCore'),
            ]),
          ]),
        }),
      ]),
    });
  });

  test('has no wildcard Action (including suffix wildcards like s3:Get*) in any inline policy', () => {
    const policies = template.findResources('AWS::IAM::Policy');
    for (const policy of Object.values(policies)) {
      const statements: Array<{ Action: string | string[] }> =
        policy.Properties.PolicyDocument?.Statement ?? [];
      for (const stmt of statements) {
        const actions = Array.isArray(stmt.Action) ? stmt.Action : [stmt.Action];
        for (const action of actions) {
          if (typeof action === 'string') {
            expect(action).not.toContain('*');
          }
        }
      }
    }
  });

  test('has no EC2 attachment actions', () => {
    const policies = template.findResources('AWS::IAM::Policy');
    const attachmentActions = ['ec2:AttachVolume', 'ec2:DetachVolume'];
    for (const policy of Object.values(policies)) {
      const statements: Array<{ Action: string | string[] }> =
        policy.Properties.PolicyDocument?.Statement ?? [];
      for (const stmt of statements) {
        const actions = Array.isArray(stmt.Action) ? stmt.Action : [stmt.Action];
        for (const action of actions) {
          expect(attachmentActions).not.toContain(action);
        }
      }
    }
  });

  test('S3 actions are scoped to the backup bucket ARN (not wildcard resource)', () => {
    const policies = template.findResources('AWS::IAM::Policy');
    let foundS3Statement = false;
    for (const policy of Object.values(policies)) {
      const statements: Array<{ Action: string | string[]; Resource: unknown }> =
        policy.Properties.PolicyDocument?.Statement ?? [];
      for (const stmt of statements) {
        const actions = Array.isArray(stmt.Action) ? stmt.Action : [stmt.Action];
        const hasS3Put = actions.some(a => typeof a === 'string' && a === 's3:PutObject');
        if (hasS3Put) {
          foundS3Statement = true;
          // Resource must not be a plain '*'
          const resources = Array.isArray(stmt.Resource) ? stmt.Resource : [stmt.Resource];
          for (const res of resources) {
            expect(res).not.toBe('*');
          }
        }
      }
    }
    expect(foundS3Statement).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Task 4 — EBS Volume and S3 Bucket
// ---------------------------------------------------------------------------

describe('EBS Volume', () => {
  let template: Template;
  beforeAll(() => { template = makeStack(); });

  test('is encrypted', () => {
    template.hasResourceProperties('AWS::EC2::Volume', {
      Encrypted: true,
    });
  });

  test('has DeletionPolicy Retain', () => {
    const volumes = template.findResources('AWS::EC2::Volume');
    for (const vol of Object.values(volumes)) {
      expect(vol.DeletionPolicy).toBe('Retain');
    }
  });

  test('has volumeType gp3', () => {
    template.hasResourceProperties('AWS::EC2::Volume', {
      VolumeType: 'gp3',
    });
  });

  test('has the configured size', () => {
    template.hasResourceProperties('AWS::EC2::Volume', {
      Size: defaultConfig.ebsVolumeSizeGb,
    });
  });
});

describe('S3 Backup Bucket', () => {
  let template: Template;
  beforeAll(() => { template = makeStack(); });

  test('blocks all public access', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
    });
  });

  test('has DeletionPolicy Retain', () => {
    const buckets = template.findResources('AWS::S3::Bucket');
    for (const bucket of Object.values(buckets)) {
      expect(bucket.DeletionPolicy).toBe('Retain');
    }
  });

  test('uses SSE-S3 encryption', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketEncryption: {
        ServerSideEncryptionConfiguration: Match.arrayWith([
          Match.objectLike({
            ServerSideEncryptionByDefault: {
              SSEAlgorithm: 'AES256',
            },
          }),
        ]),
      },
    });
  });

  test('has a bucket policy enforcing HTTPS only', () => {
    template.hasResourceProperties('AWS::S3::BucketPolicy', {
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Deny',
            Condition: Match.objectLike({
              Bool: { 'aws:SecureTransport': 'false' },
            }),
          }),
        ]),
      }),
    });
  });

  test('does not have AutoDeleteObjects lambda', () => {
    // AutoDeleteObjects creates a custom resource with a specific logical ID pattern.
    // Verify no such resource exists.
    const customResources = template.findResources('Custom::S3AutoDeleteObjects');
    expect(Object.keys(customResources)).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// Task 5 — CDK Asset
// ---------------------------------------------------------------------------

describe('Bootstrap Asset', () => {
  let template: Template;
  beforeAll(() => { template = makeStack(); });

  test('instance role has s3:GetObject scoped to the bootstrap asset object key only', () => {
    const policies = template.findResources('AWS::IAM::Policy');
    let assetStatement: { Action: unknown; Effect: string; Resource: unknown } | undefined;
    for (const policy of Object.values(policies)) {
      const statements: Array<{ Action: unknown; Effect: string; Resource: unknown; Sid?: string }> =
        policy.Properties.PolicyDocument?.Statement ?? [];
      for (const stmt of statements) {
        if (stmt.Sid === 'MinecraftBootstrapAssetAccess') {
          assetStatement = stmt;
        }
      }
    }

    expect(assetStatement).toBeDefined();
    expect(assetStatement!.Effect).toBe('Allow');
    // Exactly s3:GetObject — not GetObject*, not a list of actions.
    expect(assetStatement!.Action).toBe('s3:GetObject');

    // Resource must resolve to a single object key ARN (ends in ".zip"), never
    // the bare bucket ARN or a "/*" wildcard — otherwise the instance could
    // read every asset in the shared CDK bootstrap-assets bucket.
    const resourceJson = JSON.stringify(assetStatement!.Resource);
    expect(resourceJson).toMatch(/\.zip"/);
    expect(resourceJson).not.toMatch(/\/\*"/);
  });
});

// ---------------------------------------------------------------------------
// Task 10 — CloudWatch Log Groups, Alarms, Budget
// ---------------------------------------------------------------------------

describe('CloudWatch Log Groups', () => {
  let template: Template;
  beforeAll(() => { template = makeStack(); });

  test('creates /minecraft/server log group with 30-day retention', () => {
    template.hasResourceProperties('AWS::Logs::LogGroup', {
      LogGroupName: '/minecraft/server',
      RetentionInDays: 30,
    });
  });

  test('creates /minecraft/backup log group with 30-day retention', () => {
    template.hasResourceProperties('AWS::Logs::LogGroup', {
      LogGroupName: '/minecraft/backup',
      RetentionInDays: 30,
    });
  });
});

describe('CloudWatch Alarms', () => {
  let template: Template;
  beforeAll(() => { template = makeStack(); });

  test('creates BackupFailure alarm with threshold >= 1', () => {
    template.hasResourceProperties('AWS::CloudWatch::Alarm', {
      AlarmName: 'MinecraftBackupFailure',
      Threshold: 1,
      ComparisonOperator: 'GreaterThanOrEqualToThreshold',
      TreatMissingData: 'notBreaching',
    });
  });

  test('creates CPU high alarm with threshold 90', () => {
    template.hasResourceProperties('AWS::CloudWatch::Alarm', {
      AlarmName: 'MinecraftCpuHigh',
      Threshold: 90,
      ComparisonOperator: 'GreaterThanThreshold',
      EvaluationPeriods: 3,
    });
  });
});

describe('Budget', () => {
  let template: Template;
  beforeAll(() => { template = makeStack(); });

  test('creates a monthly cost budget with the configured threshold', () => {
    template.hasResourceProperties('AWS::Budgets::Budget', {
      Budget: Match.objectLike({
        BudgetType: 'COST',
        TimeUnit: 'MONTHLY',
        BudgetLimit: Match.objectLike({
          Amount: defaultConfig.monthlyBudgetUsd,
          Unit: 'USD',
        }),
      }),
    });
  });
});

// ---------------------------------------------------------------------------
// Task 11 — Elastic IP
// ---------------------------------------------------------------------------

describe('Elastic IP', () => {
  let template: Template;
  beforeAll(() => { template = makeStack(); });

  test('allocates an Elastic IP in the vpc domain', () => {
    template.hasResourceProperties('AWS::EC2::EIP', {
      Domain: 'vpc',
    });
  });

  test('EIP has DeletionPolicy Retain', () => {
    const eips = template.findResources('AWS::EC2::EIP');
    for (const eip of Object.values(eips)) {
      expect(eip.DeletionPolicy).toBe('Retain');
    }
  });

  test('creates an EIP Association resource', () => {
    template.resourceCountIs('AWS::EC2::EIPAssociation', 1);
  });

  test('outputs ElasticIpAddress', () => {
    template.hasOutput('ElasticIpAddress', {});
  });

  test('outputs EipAllocationId', () => {
    template.hasOutput('EipAllocationId', {});
  });

  test('outputs MinecraftConnectionAddress', () => {
    template.hasOutput('MinecraftConnectionAddress', {});
  });
});

describe('DNS record — disabled by default', () => {
  test('no Route53 record when dnsHostname and hostedZoneId are empty', () => {
    const template = makeStack({ dnsHostname: '', hostedZoneId: '' });
    template.resourceCountIs('AWS::Route53::RecordSet', 0);
    // No DNS output either
    const outputs = template.findOutputs('DnsConnectionAddress');
    expect(Object.keys(outputs)).toHaveLength(0);
  });

  test('creates a Route53 A record when dnsHostname and hostedZoneId are set', () => {
    const template = makeStack({
      dnsHostname: 'mc.example.com',
      hostedZoneId: 'Z1234567890ABCDEF',
    });
    template.hasResourceProperties('AWS::Route53::RecordSet', {
      Type: 'A',
      Name: Match.stringLikeRegexp('mc\\.example\\.com'),
    });
  });

  test('outputs DnsConnectionAddress when DNS is configured', () => {
    const template = makeStack({
      dnsHostname: 'mc.example.com',
      hostedZoneId: 'Z1234567890ABCDEF',
    });
    template.hasOutput('DnsConnectionAddress', {
      Value: 'mc.example.com:25565',
    });
  });
});

// ---------------------------------------------------------------------------
// Task 12 — EC2 Instance
// ---------------------------------------------------------------------------

describe('EC2 Instance', () => {
  let template: Template;
  beforeAll(() => { template = makeStack(); });

  test('uses the configured instance type', () => {
    template.hasResourceProperties('AWS::EC2::Instance', {
      InstanceType: defaultConfig.instanceType,
    });
  });

  test('instanceInitiatedShutdownBehavior is stop', () => {
    template.hasResourceProperties('AWS::EC2::Instance', {
      InstanceInitiatedShutdownBehavior: 'stop',
    });
  });

  test('does not have a public IP auto-assigned (uses Elastic IP instead)', () => {
    // NetworkInterfaces AssociatePublicIpAddress should be false or absent
    const instances = template.findResources('AWS::EC2::Instance');
    for (const inst of Object.values(instances)) {
      const niList: Array<{ AssociatePublicIpAddress?: boolean }> =
        inst.Properties.NetworkInterfaces ?? [];
      for (const ni of niList) {
        if (ni.AssociatePublicIpAddress !== undefined) {
          expect(ni.AssociatePublicIpAddress).toBe(false);
        }
      }
    }
  });

  test('creates a CfnVolumeAttachment resource', () => {
    template.resourceCountIs('AWS::EC2::VolumeAttachment', 1);
  });

  test('VolumeAttachment uses device /dev/sdf', () => {
    template.hasResourceProperties('AWS::EC2::VolumeAttachment', {
      Device: '/dev/sdf',
    });
  });

  test('outputs InstanceId', () => {
    template.hasOutput('InstanceId', {});
  });

  test('outputs BackupBucketName', () => {
    template.hasOutput('BackupBucketName', {});
  });

  test('outputs EbsVolumeId', () => {
    template.hasOutput('EbsVolumeId', {});
  });
});

// ---------------------------------------------------------------------------
// Stack-level termination protection
// ---------------------------------------------------------------------------

describe('Stack termination protection', () => {
  test('is enabled on the stack', () => {
    const app = new cdk.App();
    const stack = new MinecraftStack(app, 'TestStack', {
      env: { account: '123456789012', region: 'us-west-2' },
      serverConfig: defaultConfig,
    });
    expect(stack.terminationProtection).toBe(true);
  });

  test('EC2 instance does NOT have DisableApiTermination set', () => {
    // Per plan revision #4: EC2 API termination protection is NOT set.
    // The instance is replaceable; data is protected by retained EBS + S3.
    const template = makeStack();
    const instances = template.findResources('AWS::EC2::Instance');
    for (const inst of Object.values(instances)) {
      expect(inst.Properties.DisableApiTermination).toBeUndefined();
    }
  });
});
