import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as batch from 'aws-cdk-lib/aws-batch';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import { NagSuppressions } from 'cdk-nag';
import { Construct } from 'constructs';

export interface InfrastructureStackProps extends cdk.StackProps {
  imageUri: string;
  fargateVcpu: number;
  fargateMemory: number;
  jobTimeout: number;
  maxVcpus: number;
  existingOutputBucket?: string;
  existingSourceBucket?: string;
  existingVpcId?: string;
  existingSubnetIds?: string[];
  existingSecurityGroupId?: string;
}

export class InfrastructureStack extends cdk.Stack {
  public readonly outputBucket: s3.IBucket;
  public readonly sourceBucket: s3.IBucket;
  public readonly jobQueue: batch.CfnJobQueue;
  public readonly jobDefinition: batch.CfnJobDefinition;
  public readonly logGroup: logs.LogGroup;

  constructor(scope: Construct, id: string, props: InfrastructureStackProps) {
    super(scope, id, props);

    const accountId = cdk.Stack.of(this).account;

    // S3 Buckets - Use existing or create new
    
    // Create log bucket for S3 access logs (only if creating new buckets)
    let logBucket: s3.IBucket | undefined;
    if (!props.existingOutputBucket || !props.existingSourceBucket) {
      logBucket = new s3.Bucket(this, 'LogBucket', {
        bucketName: `atx-logs-${accountId}`,
        encryption: s3.BucketEncryption.S3_MANAGED,
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        removalPolicy: cdk.RemovalPolicy.RETAIN,
        enforceSSL: true,
      });
    }
    
    if (props.existingOutputBucket) {
      this.outputBucket = s3.Bucket.fromBucketName(this, 'OutputBucket', props.existingOutputBucket);
    } else {
      this.outputBucket = new s3.Bucket(this, 'OutputBucket', {
        bucketName: `atx-custom-output-${accountId}`,
        versioned: true,
        encryption: s3.BucketEncryption.S3_MANAGED,
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        removalPolicy: cdk.RemovalPolicy.RETAIN,
        enforceSSL: true,
        serverAccessLogsBucket: logBucket,
        serverAccessLogsPrefix: 'output-bucket/',
      });
    }

    if (props.existingSourceBucket) {
      this.sourceBucket = s3.Bucket.fromBucketName(this, 'SourceBucket', props.existingSourceBucket);
    } else {
      this.sourceBucket = new s3.Bucket(this, 'SourceBucket', {
        bucketName: `atx-source-code-${accountId}`,
        encryption: s3.BucketEncryption.S3_MANAGED,
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        lifecycleRules: [
          {
            expiration: cdk.Duration.days(7),
            prefix: 'uploads/',
          },
        ],
        removalPolicy: cdk.RemovalPolicy.RETAIN,
        enforceSSL: true,
        serverAccessLogsBucket: logBucket,
        serverAccessLogsPrefix: 'source-bucket/',
      });
    }

    // CloudWatch Log Group
    this.logGroup = new logs.LogGroup(this, 'LogGroup', {
      logGroupName: '/aws/batch/atx-transform',
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // IAM Role for Batch Job
    const jobRole = new iam.Role(this, 'BatchJobRole', {
      roleName: 'ATXBatchJobRole',
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AWSTransformCustomFullAccess'),
      ],
    });

    // Grant S3 access to job role
    this.outputBucket.grantReadWrite(jobRole);
    this.sourceBucket.grantRead(jobRole);

    // Suppress cdk-nag findings for job role
    NagSuppressions.addResourceSuppressions(jobRole, [
      {
        id: 'AwsSolutions-IAM4',
        reason: 'AWSTransformCustomFullAccess is required for AWS Transform API access. This is an AWS-managed policy specifically designed for this service.',
        appliesTo: ['Policy::arn:<AWS::Partition>:iam::aws:policy/AWSTransformCustomFullAccess'],
      },
      {
        id: 'AwsSolutions-IAM5',
        reason: 'S3 wildcard permissions are required for dynamic file operations. Jobs write results to unique paths (transformations/{jobName}/{conversationId}/).',
        appliesTo: [
          'Action::s3:Abort*',
          'Action::s3:DeleteObject*',
          'Action::s3:GetBucket*',
          'Action::s3:GetObject*',
          'Action::s3:List*',
          'Resource::<OutputBucket7114EB27.Arn>/*',
          'Resource::<SourceBucketDDD2130A.Arn>/*',
        ],
      },
    ], true);

    // IAM Role for Batch Execution
    const executionRole = new iam.Role(this, 'BatchExecutionRole', {
      roleName: 'ATXBatchExecutionRole',
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AmazonECSTaskExecutionRolePolicy'),
      ],
    });

    // Suppress cdk-nag findings for execution role
    NagSuppressions.addResourceSuppressions(executionRole, [
      {
        id: 'AwsSolutions-IAM4',
        reason: 'AmazonECSTaskExecutionRolePolicy is the standard AWS-managed policy for ECS task execution. It provides necessary permissions for ECR, CloudWatch Logs, and Secrets Manager.',
        appliesTo: ['Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy'],
      },
    ], true);

    // Get VPC - Use existing or default
    let vpc: ec2.IVpc;
    if (props.existingVpcId) {
      // Use fromVpcAttributes to avoid lookup
      const subnetIds = props.existingSubnetIds && props.existingSubnetIds.length > 0
        ? props.existingSubnetIds
        : [];
      
      vpc = ec2.Vpc.fromVpcAttributes(this, 'Vpc', {
        vpcId: props.existingVpcId,
        availabilityZones: ['us-east-1a', 'us-east-1b'],  // Dummy values, not used
        publicSubnetIds: subnetIds.length > 0 ? subnetIds : undefined,
      });
    } else {
      // Lookup default VPC
      vpc = ec2.Vpc.fromLookup(this, 'DefaultVpc', { isDefault: true });
    }

    // Security Group - Use existing or create new
    let securityGroup: ec2.ISecurityGroup;
    if (props.existingSecurityGroupId) {
      securityGroup = ec2.SecurityGroup.fromSecurityGroupId(this, 'SecurityGroup', props.existingSecurityGroupId);
    } else {
      securityGroup = new ec2.SecurityGroup(this, 'BatchSecurityGroup', {
        vpc,
        description: 'Security group for AWS Transform Batch jobs',
        allowAllOutbound: true,
      });
    }

    // Get subnets - Use existing or VPC public subnets
    const subnetIds = props.existingSubnetIds && props.existingSubnetIds.length > 0
      ? props.existingSubnetIds
      : vpc.publicSubnets.map(subnet => subnet.subnetId);

    // Batch Compute Environment
    const computeEnvironment = new batch.CfnComputeEnvironment(this, 'ComputeEnvironment', {
      computeEnvironmentName: 'atx-fargate-compute',
      type: 'MANAGED',
      state: 'ENABLED',
      computeResources: {
        type: 'FARGATE',
        maxvCpus: props.maxVcpus,
        subnets: subnetIds,
        securityGroupIds: [securityGroup.securityGroupId],
      },
    });

    // Batch Job Queue
    this.jobQueue = new batch.CfnJobQueue(this, 'JobQueue', {
      jobQueueName: 'atx-job-queue',
      state: 'ENABLED',
      priority: 1,
      computeEnvironmentOrder: [
        {
          order: 1,
          computeEnvironment: computeEnvironment.attrComputeEnvironmentArn,
        },
      ],
    });

    this.jobQueue.addDependency(computeEnvironment);

    // Batch Job Definition
    this.jobDefinition = new batch.CfnJobDefinition(this, 'JobDefinition', {
      jobDefinitionName: 'atx-transform-job',
      type: 'container',
      platformCapabilities: ['FARGATE'],
      timeout: {
        attemptDurationSeconds: props.jobTimeout,
      },
      retryStrategy: {
        attempts: 3,
      },
      containerProperties: {
        image: props.imageUri,
        jobRoleArn: jobRole.roleArn,
        executionRoleArn: executionRole.roleArn,
        resourceRequirements: [
          { type: 'VCPU', value: props.fargateVcpu.toString() },
          { type: 'MEMORY', value: props.fargateMemory.toString() },
        ],
        logConfiguration: {
          logDriver: 'awslogs',
          options: {
            'awslogs-group': this.logGroup.logGroupName,
            'awslogs-region': this.region,
            'awslogs-stream-prefix': 'atx',
          },
        },
        networkConfiguration: {
          assignPublicIp: 'ENABLED',
        },
        environment: [
          { name: 'S3_BUCKET', value: this.outputBucket.bucketName },
          { name: 'SOURCE_BUCKET', value: this.sourceBucket.bucketName },
          { name: 'AWS_DEFAULT_REGION', value: this.region },
        ],
      },
    });

    // CloudWatch Dashboard with all widgets
    const dashboard = new cloudwatch.Dashboard(this, 'Dashboard', {
      dashboardName: 'ATX-Transform-CLI-Dashboard',
    });

    // Row 1: Job Completion Rate (Log Insights)
    dashboard.addWidgets(
      new cloudwatch.LogQueryWidget({
        title: '📊 Job Completion Rate (Hourly)',
        logGroupNames: [this.logGroup.logGroupName],
        queryLines: [
          'filter @message like /Results uploaded successfully/ or @message like /Command failed after/',
          'stats sum(@message like /Results uploaded successfully/) as Completed, sum(@message like /Command failed after/) as Failed by bin(1h)',
        ],
        width: 24,
        height: 6,
      })
    );

    // Row 2: Recent Jobs (Log Insights)
    dashboard.addWidgets(
      new cloudwatch.LogQueryWidget({
        title: '📋 Recent Jobs (Job Name, Time, Last Message, Log Stream)',
        logGroupNames: [this.logGroup.logGroupName],
        queryLines: [
          "parse @message 'Output: transformations/*/' as jobName",
          'stats latest(jobName) as job, latest(@timestamp) as lastActivity, latest(@message) as lastMessage by @logStream',
          'sort lastActivity desc',
          'limit 25',
        ],
        width: 24,
        height: 8,
      })
    );

    // Row 3: API Gateway and Lambda Invocations
    dashboard.addWidgets(
      new cloudwatch.GraphWidget({
        title: '🔌 API Gateway',
        left: [
          new cloudwatch.Metric({
            namespace: 'AWS/ApiGateway',
            metricName: 'Count',
            statistic: 'Sum',
          }),
          new cloudwatch.Metric({
            namespace: 'AWS/ApiGateway',
            metricName: '4XXError',
            statistic: 'Sum',
          }),
          new cloudwatch.Metric({
            namespace: 'AWS/ApiGateway',
            metricName: '5XXError',
            statistic: 'Sum',
          }),
        ],
        width: 12,
        height: 6,
      }),
      new cloudwatch.GraphWidget({
        title: '⚡ Lambda Invocations',
        left: [
          new cloudwatch.Metric({
            namespace: 'AWS/Lambda',
            metricName: 'Invocations',
            dimensionsMap: { FunctionName: 'atx-trigger-job' },
            statistic: 'Sum',
          }),
          new cloudwatch.Metric({
            namespace: 'AWS/Lambda',
            metricName: 'Invocations',
            dimensionsMap: { FunctionName: 'atx-trigger-batch-jobs' },
            statistic: 'Sum',
          }),
          new cloudwatch.Metric({
            namespace: 'AWS/Lambda',
            metricName: 'Invocations',
            dimensionsMap: { FunctionName: 'atx-get-job-status' },
            statistic: 'Sum',
          }),
          new cloudwatch.Metric({
            namespace: 'AWS/Lambda',
            metricName: 'Invocations',
            dimensionsMap: { FunctionName: 'atx-get-batch-status' },
            statistic: 'Sum',
          }),
        ],
        width: 12,
        height: 6,
      })
    );

    // Row 4: Lambda Duration
    dashboard.addWidgets(
      new cloudwatch.GraphWidget({
        title: '⚡ Lambda Duration (ms)',
        left: [
          new cloudwatch.Metric({
            namespace: 'AWS/Lambda',
            metricName: 'Duration',
            dimensionsMap: { FunctionName: 'atx-trigger-job' },
            statistic: 'Average',
          }),
          new cloudwatch.Metric({
            namespace: 'AWS/Lambda',
            metricName: 'Duration',
            dimensionsMap: { FunctionName: 'atx-trigger-batch-jobs' },
            statistic: 'Average',
          }),
          new cloudwatch.Metric({
            namespace: 'AWS/Lambda',
            metricName: 'Duration',
            dimensionsMap: { FunctionName: 'atx-get-job-status' },
            statistic: 'Average',
          }),
          new cloudwatch.Metric({
            namespace: 'AWS/Lambda',
            metricName: 'Duration',
            dimensionsMap: { FunctionName: 'atx-get-batch-status' },
            statistic: 'Average',
          }),
        ],
        width: 24,
        height: 6,
      })
    );

    // Outputs
    new cdk.CfnOutput(this, 'OutputBucketName', {
      value: this.outputBucket.bucketName,
      description: 'S3 bucket for transformation outputs',
      exportName: 'AtxOutputBucketName',
    });

    new cdk.CfnOutput(this, 'SourceBucketName', {
      value: this.sourceBucket.bucketName,
      description: 'S3 bucket for source code uploads',
      exportName: 'AtxSourceBucketName',
    });

    new cdk.CfnOutput(this, 'JobQueueArn', {
      value: this.jobQueue.attrJobQueueArn,
      description: 'Batch job queue ARN',
      exportName: 'AtxJobQueueArn',
    });

    new cdk.CfnOutput(this, 'JobDefinitionArn', {
      value: this.jobDefinition.ref,
      description: 'Batch job definition ARN',
      exportName: 'AtxJobDefinitionArn',
    });

    new cdk.CfnOutput(this, 'LogGroupName', {
      value: this.logGroup.logGroupName,
      description: 'CloudWatch log group name',
    });
  }
}
