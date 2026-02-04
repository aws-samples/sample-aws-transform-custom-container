#!/bin/bash
set -e

# Generate custom IAM policy based on config.env values
# This creates the most restrictive policy possible using actual resource names

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
OUTPUT_FILE="$SCRIPT_DIR/iam-custom-policy.json"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

echo "=========================================="
echo "Generate Custom IAM Policy"
echo "=========================================="
echo ""

# Check for config file
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    echo ""
    echo "Please create config.env from template:"
    echo "  cp config.env.template config.env"
    echo "  # Edit config.env with your settings"
    echo "  ./generate-custom-policy.sh"
    exit 1
fi

# Load configuration
log_info "Loading configuration from $CONFIG_FILE"
source "$CONFIG_FILE"

# Auto-detect AWS account ID if not set
if [ -z "$AWS_ACCOUNT_ID" ]; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        log_warning "Could not auto-detect AWS Account ID"
        AWS_ACCOUNT_ID="REPLACE_WITH_ACCOUNT_ID"
    else
        log_info "Auto-detected AWS Account: $AWS_ACCOUNT_ID"
    fi
fi

# Set defaults from config or use standard defaults
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO_NAME="${ECR_REPO_NAME:-aws-transform-cli}"
S3_BUCKET_NAME="${S3_BUCKET_NAME:-atx-custom-output}"
SOURCE_BUCKET="${SOURCE_BUCKET:-atx-source-code}"
COMPUTE_ENV_NAME="${COMPUTE_ENV_NAME:-atx-fargate-compute}"
JOB_QUEUE_NAME="${JOB_QUEUE_NAME:-atx-job-queue}"
JOB_DEFINITION_NAME="${JOB_DEFINITION_NAME:-atx-transform-job}"
API_NAME="${API_NAME:-atx-transform-api}"
LOG_GROUP="${LOG_GROUP:-/aws/batch/atx-transform}"

# Generate S3 bucket names with account ID
S3_OUTPUT_BUCKET="${S3_BUCKET_NAME}-${AWS_ACCOUNT_ID}"
S3_SOURCE_BUCKET="${SOURCE_BUCKET}-${AWS_ACCOUNT_ID}"

log_info "Generating policy with these resources:"
echo "  • ECR Repository: $ECR_REPO_NAME"
echo "  • S3 Output Bucket: $S3_OUTPUT_BUCKET"
echo "  • S3 Source Bucket: $S3_SOURCE_BUCKET"
echo "  • Compute Environment: $COMPUTE_ENV_NAME"
echo "  • Job Queue: $JOB_QUEUE_NAME"
echo "  • Job Definition: $JOB_DEFINITION_NAME"
echo "  • API Name: $API_NAME"
echo "  • Log Group: $LOG_GROUP"
echo ""

# Generate the custom policy
cat > "$OUTPUT_FILE" << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRSpecificRepository",
      "Effect": "Allow",
      "Action": [
        "ecr:CreateRepository",
        "ecr:DescribeRepositories",
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:PutImageScanningConfiguration"
      ],
      "Resource": [
        "arn:aws:ecr:$AWS_REGION:$AWS_ACCOUNT_ID:repository/$ECR_REPO_NAME"
      ]
    },
    {
      "Sid": "ECRAuthToken",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "S3SpecificBuckets",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:GetBucketVersioning",
        "s3:PutBucketVersioning",
        "s3:GetEncryptionConfiguration",
        "s3:PutEncryptionConfiguration",
        "s3:GetBucketLifecycleConfiguration",
        "s3:PutBucketLifecycleConfiguration",
        "s3:GetBucketPublicAccessBlock",
        "s3:PutBucketPublicAccessBlock",
        "s3:GetObject",
        "s3:PutObject",
        "s3:HeadObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::$S3_OUTPUT_BUCKET",
        "arn:aws:s3:::$S3_OUTPUT_BUCKET/*",
        "arn:aws:s3:::$S3_SOURCE_BUCKET",
        "arn:aws:s3:::$S3_SOURCE_BUCKET/*"
      ]
    },
    {
      "Sid": "IAMSpecificRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:PassRole"
      ],
      "Resource": [
        "arn:aws:iam::$AWS_ACCOUNT_ID:role/ATXBatchJobRole",
        "arn:aws:iam::$AWS_ACCOUNT_ID:role/ATXBatchExecutionRole",
        "arn:aws:iam::$AWS_ACCOUNT_ID:role/ATXApiLambdaRole",
        "arn:aws:iam::$AWS_ACCOUNT_ID:role/ATXApiConsumerRole"
      ]
    },
    {
      "Sid": "BatchDescribeAll",
      "Effect": "Allow",
      "Action": [
        "batch:DescribeComputeEnvironments",
        "batch:DescribeJobQueues",
        "batch:DescribeJobDefinitions",
        "batch:DescribeJobs",
        "batch:ListJobs"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BatchSpecificResources",
      "Effect": "Allow",
      "Action": [
        "batch:CreateComputeEnvironment",
        "batch:UpdateComputeEnvironment",
        "batch:CreateJobQueue",
        "batch:UpdateJobQueue",
        "batch:RegisterJobDefinition",
        "batch:SubmitJob",
        "batch:TerminateJob"
      ],
      "Resource": [
        "arn:aws:batch:$AWS_REGION:$AWS_ACCOUNT_ID:compute-environment/$COMPUTE_ENV_NAME",
        "arn:aws:batch:$AWS_REGION:$AWS_ACCOUNT_ID:job-queue/$JOB_QUEUE_NAME",
        "arn:aws:batch:$AWS_REGION:$AWS_ACCOUNT_ID:job-definition/$JOB_DEFINITION_NAME",
        "arn:aws:batch:$AWS_REGION:$AWS_ACCOUNT_ID:job-definition/$JOB_DEFINITION_NAME:*"
      ]
    },
    {
      "Sid": "EC2NetworkOperations",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:CreateSecurityGroup",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchDescribeAll",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchSpecificResources",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:PutRetentionPolicy",
        "logs:GetLogEvents",
        "logs:FilterLogEvents"
      ],
      "Resource": [
        "arn:aws:logs:$AWS_REGION:$AWS_ACCOUNT_ID:log-group:$LOG_GROUP*",
        "arn:aws:logs:$AWS_REGION:$AWS_ACCOUNT_ID:log-group:/aws/lambda/atx-*"
      ]
    },
    {
      "Sid": "CloudWatchDashboardAll",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutDashboard",
        "cloudwatch:GetDashboard",
        "cloudwatch:DeleteDashboard",
        "cloudwatch:ListDashboards"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LambdaSpecificFunctions",
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:GetFunction",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:AddPermission",
        "lambda:RemovePermission",
        "lambda:InvokeFunction",
        "lambda:ListFunctions"
      ],
      "Resource": [
        "arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:atx-trigger-job",
        "arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:atx-get-job-status",
        "arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:atx-upload-code",
        "arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:atx-terminate-job",
        "arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:atx-configure-mcp",
        "arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:atx-trigger-batch-jobs",
        "arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:atx-get-batch-status"
      ]
    },
    {
      "Sid": "APIGatewaySpecific",
      "Effect": "Allow",
      "Action": [
        "apigateway:GET",
        "apigateway:POST",
        "apigateway:PUT",
        "apigateway:DELETE",
        "apigateway:PATCH"
      ],
      "Resource": [
        "arn:aws:apigateway:$AWS_REGION::/restapis",
        "arn:aws:apigateway:$AWS_REGION::/restapis/*"
      ]
    },
    {
      "Sid": "ExecuteAPIPermissions",
      "Effect": "Allow",
      "Action": [
        "execute-api:Invoke"
      ],
      "Resource": [
        "arn:aws:execute-api:$AWS_REGION:$AWS_ACCOUNT_ID:*/prod/*/*"
      ]
    },
    {
      "Sid": "RequiredReadOnlyPermissions",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECSTaskDefinitionAccess",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeTaskDefinition",
        "ecs:RegisterTaskDefinition"
      ],
      "Resource": "*"
    }
  ]
}
EOF

log_success "Custom IAM policy generated: $OUTPUT_FILE"
echo ""

# Display summary
echo "=========================================="
echo "Policy Summary"
echo "=========================================="
echo ""
echo "This policy is customized for your specific configuration:"
echo ""
echo "🔒 Restricted Resources:"
echo "  • ECR: Only $ECR_REPO_NAME repository"
echo "  • S3: Only $S3_OUTPUT_BUCKET and $S3_SOURCE_BUCKET buckets (with correct encryption permissions)"
echo "  • Batch: Only $COMPUTE_ENV_NAME, $JOB_QUEUE_NAME, $JOB_DEFINITION_NAME"
echo "  • Lambda: Only atx-* functions"
echo "  • API Gateway: Only $API_NAME API (management + execution)"
echo "  • Execute API: Can invoke deployed API endpoints"
echo "  • CloudWatch: Only $LOG_GROUP log group"
echo "  • IAM: Only ATX* roles"
echo ""
echo "🔄 Policy Updates Applied:"
echo "  • Fixed S3 encryption permissions (s3:PutEncryptionConfiguration)"
echo "  • Added execute-api:Invoke for API endpoint access"
echo "  • Supports both deployment and API usage"
echo ""
echo "📋 Usage:"
echo "  aws iam create-policy \\"
echo "    --policy-name ATXCustomDeploymentPolicy \\"
echo "    --policy-document file://$OUTPUT_FILE"
echo ""
echo "  aws iam attach-user-policy \\"
echo "    --user-name YOUR_USERNAME \\"
echo "    --policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/ATXCustomDeploymentPolicy"
echo ""

if [ "$AWS_ACCOUNT_ID" = "REPLACE_WITH_ACCOUNT_ID" ]; then
    log_warning "Account ID could not be detected"
    echo "Please replace 'REPLACE_WITH_ACCOUNT_ID' in $OUTPUT_FILE with your actual AWS account ID"
    echo ""
fi

echo "🔄 To regenerate after config changes:"
echo "  ./generate-custom-policy.sh"
echo ""