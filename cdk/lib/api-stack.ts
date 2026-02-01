import * as cdk from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as logs from 'aws-cdk-lib/aws-logs';
import { NagSuppressions } from 'cdk-nag';
import { Construct } from 'constructs';
import * as path from 'path';

export interface ApiStackProps extends cdk.StackProps {
  jobQueueName: string;
  jobDefinitionName: string;
  outputBucket: s3.IBucket;
  sourceBucket: s3.IBucket;
}

export class ApiStack extends cdk.Stack {
  public readonly api: apigateway.RestApi;

  constructor(scope: Construct, id: string, props: ApiStackProps) {
    super(scope, id, props);

    // IAM Role for Lambda functions
    const lambdaRole = new iam.Role(this, 'LambdaRole', {
      roleName: 'ATXApiLambdaRole',
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
    });

    // Grant permissions to Lambda role
    // Split into scoped and wildcard permissions for better security
    
    // Scoped Batch permissions
    lambdaRole.addToPolicy(new iam.PolicyStatement({
      actions: ['batch:SubmitJob'],
      resources: [
        `arn:aws:batch:${this.region}:${this.account}:job-definition/${props.jobDefinitionName}*`,
        `arn:aws:batch:${this.region}:${this.account}:job-queue/${props.jobQueueName}`,
      ],
    }));
    
    // Wildcard Batch permissions (required by AWS Batch API)
    lambdaRole.addToPolicy(new iam.PolicyStatement({
      actions: [
        'batch:DescribeJobs',
        'batch:ListJobs',
        'batch:TerminateJob',  // Requires dynamic job IDs
      ],
      resources: ['*'],
    }));

    // Allow Lambda to invoke itself (for async batch jobs)
    lambdaRole.addToPolicy(new iam.PolicyStatement({
      actions: ['lambda:InvokeFunction'],
      resources: [`arn:aws:lambda:${this.region}:${this.account}:function:atx-*`],
    }));

    props.outputBucket.grantReadWrite(lambdaRole);
    props.sourceBucket.grantReadWrite(lambdaRole);

    // Suppress cdk-nag findings for Lambda role
    NagSuppressions.addResourceSuppressions(lambdaRole, [
      {
        id: 'AwsSolutions-IAM4',
        reason: 'AWSLambdaBasicExecutionRole is the standard AWS-managed policy for Lambda CloudWatch Logs access.',
        appliesTo: ['Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole'],
      },
      {
        id: 'AwsSolutions-IAM5',
        reason: 'Wildcard permissions are required: (1) Batch API requires wildcard for DescribeJobs/ListJobs, (2) S3 wildcards for dynamic file paths, (3) Lambda wildcards for async invocations (atx-* pattern), (4) Job definition wildcard for version suffixes (:1, :2, etc.).',
        appliesTo: [
          'Resource::*',
          'Resource::arn:aws:lambda:*:*:function:atx-*',
          `Resource::arn:aws:lambda:${this.region}:${this.account}:function:atx-*`,
          `Resource::arn:aws:batch:${this.region}:${this.account}:job-definition/${props.jobDefinitionName}*`,
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

    // Common environment variables
    const commonEnv = {
      JOB_QUEUE: props.jobQueueName,
      JOB_DEFINITION: props.jobDefinitionName,
      OUTPUT_BUCKET: props.outputBucket.bucketName,
      SOURCE_BUCKET: props.sourceBucket.bucketName,
      // AWS_REGION is automatically set by Lambda runtime
    };

    // Lambda Functions
    const triggerJobFunction = new lambda.Function(this, 'TriggerJobFunction', {
      functionName: 'atx-trigger-job',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'trigger_job.lambda_handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../api/lambda')),
      role: lambdaRole,
      environment: commonEnv,
      timeout: cdk.Duration.seconds(30),
    });

    const getJobStatusFunction = new lambda.Function(this, 'GetJobStatusFunction', {
      functionName: 'atx-get-job-status',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'get_job_status.lambda_handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../api/lambda')),
      role: lambdaRole,
      environment: commonEnv,
      timeout: cdk.Duration.seconds(30),
    });

    const terminateJobFunction = new lambda.Function(this, 'TerminateJobFunction', {
      functionName: 'atx-terminate-job',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'terminate_job.lambda_handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../api/lambda')),
      role: lambdaRole,
      environment: commonEnv,
      timeout: cdk.Duration.seconds(30),
    });

    const triggerBatchJobsFunction = new lambda.Function(this, 'TriggerBatchJobsFunction', {
      functionName: 'atx-trigger-batch-jobs',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'trigger_batch_jobs.lambda_handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../api/lambda')),
      role: lambdaRole,
      environment: commonEnv,
      timeout: cdk.Duration.minutes(15),
    });

    const getBatchStatusFunction = new lambda.Function(this, 'GetBatchStatusFunction', {
      functionName: 'atx-get-batch-status',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'get_batch_status.lambda_handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../api/lambda')),
      role: lambdaRole,
      environment: commonEnv,
      timeout: cdk.Duration.seconds(30),
    });

    const configureMcpFunction = new lambda.Function(this, 'ConfigureMcpFunction', {
      functionName: 'atx-configure-mcp',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'configure_mcp.lambda_handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../api/lambda')),
      role: lambdaRole,
      environment: commonEnv,
      timeout: cdk.Duration.seconds(30),
    });

    const uploadCodeFunction = new lambda.Function(this, 'UploadCodeFunction', {
      functionName: 'atx-upload-code',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'upload_code.lambda_handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../api/lambda')),
      role: lambdaRole,
      environment: commonEnv,
      timeout: cdk.Duration.seconds(30),
    });

    // Suppress Python runtime warnings for all Lambda functions
    const pythonRuntimeSuppression = {
      id: 'AwsSolutions-L1',
      reason: 'Python 3.11 is stable and fully supported until October 2027. Python 3.13 is too new (released Oct 2024) for production use. Our Lambda functions use standard boto3 APIs that work reliably on 3.11.',
    };

    NagSuppressions.addResourceSuppressions(triggerJobFunction, [pythonRuntimeSuppression], true);
    NagSuppressions.addResourceSuppressions(getJobStatusFunction, [pythonRuntimeSuppression], true);
    NagSuppressions.addResourceSuppressions(terminateJobFunction, [pythonRuntimeSuppression], true);
    NagSuppressions.addResourceSuppressions(triggerBatchJobsFunction, [pythonRuntimeSuppression], true);
    NagSuppressions.addResourceSuppressions(getBatchStatusFunction, [pythonRuntimeSuppression], true);
    NagSuppressions.addResourceSuppressions(configureMcpFunction, [pythonRuntimeSuppression], true);
    NagSuppressions.addResourceSuppressions(uploadCodeFunction, [pythonRuntimeSuppression], true);

    // CloudWatch Log Group for API Gateway access logs
    const apiLogGroup = new logs.LogGroup(this, 'ApiAccessLogs', {
      logGroupName: '/aws/apigateway/atx-transform-api',
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // API Gateway
    this.api = new apigateway.RestApi(this, 'Api', {
      restApiName: 'atx-transform-api',
      description: 'AWS Transform CLI Batch API',
      deployOptions: {
        stageName: 'prod',
        accessLogDestination: new apigateway.LogGroupLogDestination(apiLogGroup),
        accessLogFormat: apigateway.AccessLogFormat.jsonWithStandardFields(),
        loggingLevel: apigateway.MethodLoggingLevel.INFO,
        dataTraceEnabled: true,
        throttlingRateLimit: 100,
        throttlingBurstLimit: 200,
      },
      defaultCorsPreflightOptions: {
        allowOrigins: apigateway.Cors.ALL_ORIGINS,
        allowMethods: apigateway.Cors.ALL_METHODS,
      },
    });

    // Request validator for API Gateway
    const requestValidator = new apigateway.RequestValidator(this, 'RequestValidator', {
      restApi: this.api,
      requestValidatorName: 'atx-request-validator',
      validateRequestBody: true,
      validateRequestParameters: true,
    });

    // API Resources and Methods
    const jobs = this.api.root.addResource('jobs');
    
    // POST /jobs - Trigger single job
    jobs.addMethod('POST', new apigateway.LambdaIntegration(triggerJobFunction), {
      authorizationType: apigateway.AuthorizationType.IAM,
      requestValidator,
    });

    // GET /jobs/{jobId} - Get job status
    const job = jobs.addResource('{jobId}');
    job.addMethod('GET', new apigateway.LambdaIntegration(getJobStatusFunction), {
      authorizationType: apigateway.AuthorizationType.IAM,
    });

    // DELETE /jobs/{jobId} - Terminate job
    job.addMethod('DELETE', new apigateway.LambdaIntegration(terminateJobFunction), {
      authorizationType: apigateway.AuthorizationType.IAM,
    });

    // POST /jobs/batch - Trigger batch jobs
    const batch = jobs.addResource('batch');
    batch.addMethod('POST', new apigateway.LambdaIntegration(triggerBatchJobsFunction), {
      authorizationType: apigateway.AuthorizationType.IAM,
      requestValidator,
    });

    // GET /jobs/batch/{batchId} - Get batch status
    const batchId = batch.addResource('{batchId}');
    batchId.addMethod('GET', new apigateway.LambdaIntegration(getBatchStatusFunction), {
      authorizationType: apigateway.AuthorizationType.IAM,
    });

    // POST /mcp-config - Configure MCP
    const mcpConfig = this.api.root.addResource('mcp-config');
    mcpConfig.addMethod('POST', new apigateway.LambdaIntegration(configureMcpFunction), {
      authorizationType: apigateway.AuthorizationType.IAM,
      requestValidator,
    });

    // POST /upload - Upload code
    const upload = this.api.root.addResource('upload');
    upload.addMethod('POST', new apigateway.LambdaIntegration(uploadCodeFunction), {
      authorizationType: apigateway.AuthorizationType.IAM,
      requestValidator,
    });

    // Suppress Cognito auth warnings - IAM auth is appropriate for backend API
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      '/AtxApiStack/Api/Default/jobs/POST/Resource',
      [{ id: 'AwsSolutions-COG4', reason: 'This is a backend API for programmatic access and automation. IAM authentication is more appropriate than Cognito for service-to-service communication.' }]
    );
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      '/AtxApiStack/Api/Default/jobs/{jobId}/GET/Resource',
      [{ id: 'AwsSolutions-COG4', reason: 'This is a backend API for programmatic access and automation. IAM authentication is more appropriate than Cognito for service-to-service communication.' }]
    );
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      '/AtxApiStack/Api/Default/jobs/{jobId}/DELETE/Resource',
      [{ id: 'AwsSolutions-COG4', reason: 'This is a backend API for programmatic access and automation. IAM authentication is more appropriate than Cognito for service-to-service communication.' }]
    );
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      '/AtxApiStack/Api/Default/jobs/batch/POST/Resource',
      [{ id: 'AwsSolutions-COG4', reason: 'This is a backend API for programmatic access and automation. IAM authentication is more appropriate than Cognito for service-to-service communication.' }]
    );
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      '/AtxApiStack/Api/Default/jobs/batch/{batchId}/GET/Resource',
      [{ id: 'AwsSolutions-COG4', reason: 'This is a backend API for programmatic access and automation. IAM authentication is more appropriate than Cognito for service-to-service communication.' }]
    );
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      '/AtxApiStack/Api/Default/mcp-config/POST/Resource',
      [{ id: 'AwsSolutions-COG4', reason: 'This is a backend API for programmatic access and automation. IAM authentication is more appropriate than Cognito for service-to-service communication.' }]
    );
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      '/AtxApiStack/Api/Default/upload/POST/Resource',
      [{ id: 'AwsSolutions-COG4', reason: 'This is a backend API for programmatic access and automation. IAM authentication is more appropriate than Cognito for service-to-service communication.' }]
    );

    // Suppress WAF warning - optional for internal APIs with IAM auth
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      '/AtxApiStack/Api/DeploymentStage.prod/Resource',
      [{ id: 'AwsSolutions-APIG3', reason: 'WAF is optional for internal APIs with IAM authentication and throttling. Can be added for additional DDoS protection if needed.' }]
    );

    // Outputs
    new cdk.CfnOutput(this, 'ApiEndpoint', {
      value: this.api.url,
      description: 'API Gateway endpoint URL',
      exportName: 'AtxApiEndpoint',
    });

    new cdk.CfnOutput(this, 'ApiId', {
      value: this.api.restApiId,
      description: 'API Gateway ID',
    });
  }
}
