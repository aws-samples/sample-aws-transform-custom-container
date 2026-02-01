#!/bin/bash
set -e

# Automated AWS Transform CLI Deployment
# Reads configuration from config.env and deploys without user interaction

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$SCRIPT_DIR/config.env"

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
echo "AWS Transform CLI - Automated Deployment"
echo "=========================================="
echo ""

# Check prerequisites
log_info "Checking prerequisites..."

# Check Docker
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    echo ""
    echo "Please install Docker:"
    echo "  - Windows/Mac: https://www.docker.com/products/docker-desktop"
    echo "  - Linux: https://docs.docker.com/engine/install/"
    exit 1
fi

if ! docker info &> /dev/null; then
    log_error "Docker is not running"
    echo ""
    echo "Please start Docker Desktop or Docker daemon"
    exit 1
fi

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed or not in PATH"
    echo ""
    echo "Please install AWS CLI v2:"
    echo "  https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

log_success "Prerequisites check passed"
echo ""

# Check for config file
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    echo ""
    echo "Please create config.env from template:"
    echo "  cp config.env.template config.env"
    echo "  # Edit config.env with your settings"
    echo "  ./deploy-automated.sh"
    exit 1
fi

# Load configuration
log_info "Loading configuration from $CONFIG_FILE"
source "$CONFIG_FILE"

# Auto-detect AWS account ID if not set
if [ -z "$AWS_ACCOUNT_ID" ]; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    log_info "Auto-detected AWS Account: $AWS_ACCOUNT_ID"
fi

# Set defaults
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO_NAME="${ECR_REPO_NAME:-aws-transform-cli}"
S3_BUCKET_NAME="${S3_BUCKET_NAME:-atx-custom-output}"
COMPUTE_ENV_NAME="${COMPUTE_ENV_NAME:-atx-fargate-compute}"
JOB_QUEUE_NAME="${JOB_QUEUE_NAME:-atx-job-queue}"
JOB_DEFINITION_NAME="${JOB_DEFINITION_NAME:-atx-transform-job}"
FARGATE_VCPU="${FARGATE_VCPU:-2}"
FARGATE_MEMORY="${FARGATE_MEMORY:-4096}"
JOB_TIMEOUT="${JOB_TIMEOUT:-43200}"
JOB_RETRY_ATTEMPTS="${JOB_RETRY_ATTEMPTS:-3}"
ENABLE_ECR_SCANNING="${ENABLE_ECR_SCANNING:-true}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

# Make S3 bucket name unique if needed
if [[ "$S3_BUCKET_NAME" != *"$AWS_ACCOUNT_ID"* ]]; then
    S3_BUCKET_NAME="${S3_BUCKET_NAME}-${AWS_ACCOUNT_ID}"
    log_info "S3 bucket name: $S3_BUCKET_NAME (added account ID for uniqueness)"
fi

log_success "Configuration loaded"
echo ""

# ============================================
# STEP 1: Verify Container Dockerfile
# ============================================
echo "=========================================="
echo "STEP 1: Verify Container Dockerfile"
echo "=========================================="
echo ""

cd "$PROJECT_ROOT/container"

if [ ! -f "Dockerfile" ]; then
    log_error "Dockerfile not found in container/ directory"
    exit 1
fi

log_success "Dockerfile found"
echo ""

# ============================================
# STEP 2: Network Setup
# ============================================
echo "=========================================="
echo "STEP 2: Network Configuration"
echo "=========================================="
echo ""

# Auto-detect or create network resources
if [ -z "$VPC_ID" ]; then
    log_info "No VPC specified, detecting default VPC..."
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
    
    if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
        log_warning "No default VPC found"
        log_error "Please specify VPC_ID in config.env or create a default VPC"
        exit 1
    fi
    
    log_success "Using default VPC: $VPC_ID"
fi

# Auto-detect public subnets if not specified
if [ -z "$SUBNET_IDS" ]; then
    log_info "No subnets specified, auto-detecting public subnets..."
    
    SUBNETS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
        --query 'Subnets[*].SubnetId' --output text 2>/dev/null)
    
    if [ -z "$SUBNETS" ]; then
        log_error "No public subnets found in VPC $VPC_ID"
        log_error "Please specify SUBNET_IDS in config.env"
        exit 1
    fi
    
    # Use first 2 subnets
    SUBNET_IDS=$(echo "$SUBNETS" | tr '\t' ' ' | tr ' ' '\n' | head -2 | tr '\n' ',' | sed 's/,$//')
    log_success "Auto-detected public subnets: $SUBNET_IDS"
fi

# Create security group if not specified
if [ -z "$SECURITY_GROUP_ID" ]; then
    log_info "No security group specified, checking for existing..."
    
    EXISTING_SG=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=atx-batch-sg" "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
    
    if [[ "$EXISTING_SG" != "None" && -n "$EXISTING_SG" ]]; then
        SECURITY_GROUP_ID="$EXISTING_SG"
        log_success "Using existing security group: $SECURITY_GROUP_ID"
    else
        log_info "Creating security group..."
        SECURITY_GROUP_ID=$(aws ec2 create-security-group \
            --group-name atx-batch-sg \
            --description "AWS Transform Batch Security Group" \
            --vpc-id "$VPC_ID" \
            --query 'GroupId' --output text)
        
        # Allow HTTPS outbound traffic (required for AWS Transform, S3, ECR)
        aws ec2 authorize-security-group-egress \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port 443 \
            --cidr 0.0.0.0/0 2>/dev/null || true
        
        log_success "Created security group: $SECURITY_GROUP_ID"
    fi
fi

log_success "Network configuration complete"
echo "  VPC: $VPC_ID"
echo "  Subnets: $SUBNET_IDS (public)"
echo "  Security Group: $SECURITY_GROUP_ID"
echo ""

# ============================================
# STEP 3: Get Container Image URI
# ============================================
echo "=========================================="
echo "STEP 3: Get Container Image URI"
echo "=========================================="
echo ""

# Check if ECR URI file exists from step 1
ECR_URI_FILE="$SCRIPT_DIR/.ecr-uri.txt"
if [ ! -f "$ECR_URI_FILE" ]; then
    log_error "ECR URI file not found. Did you run step 1?"
    echo ""
    echo "Please run: ./1-build-and-push.sh"
    exit 1
fi

ECR_URI=$(cat "$ECR_URI_FILE")
log_info "Using container image: $ECR_URI"
log_success "Container image ready"
echo ""

# STEP 4: Create S3 Bucket
# ============================================
echo "=========================================="
echo "STEP 4: Create S3 Bucket"
echo "=========================================="
echo ""

aws s3 ls "s3://$S3_BUCKET_NAME" &>/dev/null || {
    log_info "Creating S3 bucket: $S3_BUCKET_NAME"
    aws s3 mb "s3://$S3_BUCKET_NAME" --region "$AWS_REGION"
    
    aws s3api put-bucket-versioning \
        --bucket "$S3_BUCKET_NAME" \
        --versioning-configuration Status=Enabled
    
    aws s3api put-bucket-encryption \
        --bucket "$S3_BUCKET_NAME" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }'
    
    # Block all public access
    aws s3api put-public-access-block \
        --bucket "$S3_BUCKET_NAME" \
        --public-access-block-configuration \
            BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    
    log_success "S3 bucket created with versioning, encryption, and public access blocks"
}

log_success "S3 bucket ready: s3://$S3_BUCKET_NAME"
echo ""

# ============================================
# STEP 5: Create IAM Roles
# ============================================
echo "=========================================="
echo "STEP 5: Create IAM Roles"
echo "=========================================="
echo ""

# Job Role
aws iam get-role --role-name ATXBatchJobRole &>/dev/null || {
    log_info "Creating IAM job role..."
    
    cat > /tmp/trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ecs-tasks.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
    
    aws iam create-role \
        --role-name ATXBatchJobRole \
        --assume-role-policy-document file:///tmp/trust-policy.json >/dev/null
    
    aws iam attach-role-policy \
        --role-name ATXBatchJobRole \
        --policy-arn arn:aws:iam::aws:policy/AWSTransformCustomFullAccess
    
    cat > /tmp/s3-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::$S3_BUCKET_NAME/*",
        "arn:aws:s3:::$S3_BUCKET_NAME",
        "arn:aws:s3:::atx-source-code-${AWS_ACCOUNT_ID}/*",
        "arn:aws:s3:::atx-source-code-${AWS_ACCOUNT_ID}"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": [
        "arn:aws:s3:::$S3_BUCKET_NAME/*"
      ]
    }
  ]
}
EOF
    
    aws iam put-role-policy \
        --role-name ATXBatchJobRole \
        --policy-name S3BucketAccess \
        --policy-document file:///tmp/s3-policy.json
    
    log_success "IAM job role created"
}

# Execution Role
aws iam get-role --role-name ATXBatchExecutionRole &>/dev/null || {
    log_info "Creating IAM execution role..."
    
    aws iam create-role \
        --role-name ATXBatchExecutionRole \
        --assume-role-policy-document file:///tmp/trust-policy.json >/dev/null
    
    aws iam attach-role-policy \
        --role-name ATXBatchExecutionRole \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    
    log_success "IAM execution role created"
}

log_info "Waiting for IAM roles to propagate (this may take up to 30 seconds)..."
sleep 15
log_success "IAM roles ready"
echo ""

# ============================================
# STEP 6: Create CloudWatch Log Group
# ============================================
echo "=========================================="
echo "STEP 6: Create CloudWatch Log Group"
echo "=========================================="
echo ""

aws logs describe-log-groups --log-group-name-prefix "/aws/batch/atx-transform" --region "$AWS_REGION" | grep -q "atx-transform" || {
    log_info "Creating CloudWatch log group..."
    aws logs create-log-group \
        --log-group-name /aws/batch/atx-transform \
        --region "$AWS_REGION"
    
    aws logs put-retention-policy \
        --log-group-name /aws/batch/atx-transform \
        --retention-in-days "$LOG_RETENTION_DAYS" \
        --region "$AWS_REGION"
    
    log_success "Log group created"
}

log_success "CloudWatch log group ready"
echo ""

# ============================================
# STEP 7: Create Batch Resources
# ============================================
echo "=========================================="
echo "STEP 7: Create AWS Batch Resources"
echo "=========================================="
echo ""

# Convert subnet IDs to JSON array
SUBNET_ARRAY=$(echo "$SUBNET_IDS" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')
SG_ARRAY="\"$SECURITY_GROUP_ID\""

# Create Compute Environment
COMPUTE_EXISTS=$(aws batch describe-compute-environments --compute-environments "$COMPUTE_ENV_NAME" --region "$AWS_REGION" --query "length(computeEnvironments)" --output text 2>/dev/null)
if [ "$COMPUTE_EXISTS" = "0" ] || [ -z "$COMPUTE_EXISTS" ]; then
    log_info "Creating compute environment..."
    
    COMPUTE_RESOURCES="{
        \"type\": \"FARGATE\",
        \"maxvCpus\": 256,
        \"subnets\": [$SUBNET_ARRAY],
        \"securityGroupIds\": [$SG_ARRAY]
    }"
    
    aws batch create-compute-environment \
        --compute-environment-name "$COMPUTE_ENV_NAME" \
        --type MANAGED \
        --state ENABLED \
        --compute-resources "$COMPUTE_RESOURCES" \
        --region "$AWS_REGION" >/dev/null
    
    log_info "Waiting for compute environment to become VALID..."
    while true; do
        STATUS=$(aws batch describe-compute-environments \
            --compute-environments "$COMPUTE_ENV_NAME" \
            --region "$AWS_REGION" \
            --query 'computeEnvironments[0].status' \
            --output text)
        
        if [ "$STATUS" = "VALID" ]; then
            break
        fi
        sleep 5
    done
    
    log_success "Compute environment created"
fi

# Create Job Queue
QUEUE_EXISTS=$(aws batch describe-job-queues --job-queues "$JOB_QUEUE_NAME" --region "$AWS_REGION" --query "length(jobQueues)" --output text 2>/dev/null)
if [ "$QUEUE_EXISTS" = "0" ] || [ -z "$QUEUE_EXISTS" ]; then
    log_info "Creating job queue..."
    
    aws batch create-job-queue \
        --job-queue-name "$JOB_QUEUE_NAME" \
        --state ENABLED \
        --priority 1 \
        --compute-environment-order "[{
            \"order\": 1,
            \"computeEnvironment\": \"$COMPUTE_ENV_NAME\"
        }]" \
        --region "$AWS_REGION" >/dev/null
    
    log_success "Job queue created"
fi

# Register Job Definition
log_info "Registering job definition..."

cat > /tmp/job-definition.json << EOF
{
  "jobDefinitionName": "$JOB_DEFINITION_NAME",
  "type": "container",
  "platformCapabilities": ["FARGATE"],
  "timeout": {
    "attemptDurationSeconds": $JOB_TIMEOUT
  },
  "retryStrategy": {
    "attempts": $JOB_RETRY_ATTEMPTS,
    "evaluateOnExit": [
      {"action": "RETRY", "onStatusReason": "Task failed to start"},
      {"action": "EXIT", "onExitCode": "0"}
    ]
  },
  "containerProperties": {
    "image": "$ECR_URI",
    "command": [],
    "jobRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/ATXBatchJobRole",
    "executionRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/ATXBatchExecutionRole",
    "resourceRequirements": [
      {"type": "VCPU", "value": "$FARGATE_VCPU"},
      {"type": "MEMORY", "value": "$FARGATE_MEMORY"}
    ],
    "fargatePlatformConfiguration": {
      "platformVersion": "LATEST"
    },
    "networkConfiguration": {
      "assignPublicIp": "ENABLED"
    },
    "environment": [
      {"name": "S3_BUCKET", "value": "$S3_BUCKET_NAME"},
      {"name": "SOURCE_BUCKET", "value": "atx-source-code-${AWS_ACCOUNT_ID}"},
      {"name": "AWS_DEFAULT_REGION", "value": "$AWS_REGION"},
      {"name": "ATX_SHELL_TIMEOUT", "value": "$JOB_TIMEOUT"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/aws/batch/atx-transform",
        "awslogs-region": "$AWS_REGION",
        "awslogs-stream-prefix": "atx"
      }
    }
  }
}
EOF

aws batch register-job-definition \
    --cli-input-json file:///tmp/job-definition.json \
    --region "$AWS_REGION" >/dev/null

log_success "Job definition registered"
echo ""

# ==========================================
# STEP 8: Create CloudWatch Dashboard
# ==========================================
echo "=========================================="
echo "STEP 8: Create CloudWatch Dashboard"
echo "=========================================="
echo ""

log_info "Creating CloudWatch dashboard for monitoring..."

DASHBOARD_NAME="ATX-Transform-CLI-Dashboard"

cat > /tmp/dashboard.json << DASHBOARD_EOF

{
  "widgets": [
    {
      "type": "log",
      "x": 0,
      "y": 0,
      "width": 24,
      "height": 6,
      "properties": {
        "query": "SOURCE '/aws/batch/atx-transform'\n| filter @message like /Results uploaded successfully/ or @message like /Command failed after/\n| stats sum(@message like /Results uploaded successfully/) as Completed, sum(@message like /Command failed after/) as Failed by bin(1h)",
        "region": "us-east-1",
        "title": "📊 Job Completion Rate (Hourly)",
        "view": "bar"
      }
    },
    {
      "type": "log",
      "x": 0,
      "y": 6,
      "width": 24,
      "height": 8,
      "properties": {
        "query": "SOURCE '/aws/batch/atx-transform'\n| parse @message 'Output: transformations/*/' as jobName\n| stats latest(jobName) as job, latest(@timestamp) as lastActivity, latest(@message) as lastMessage by @logStream\n| sort lastActivity desc\n| limit 25",
        "region": "us-east-1",
        "title": "📋 Recent Jobs (Job Name, Time, Last Message, Log Stream)"
      }
    },
    {
      "type": "metric",
      "x": 0,
      "y": 14,
      "width": 12,
      "height": 6,
      "properties": {
        "metrics": [
          ["AWS/ApiGateway", "Count", {"stat": "Sum"}],
          [".", "4XXError", {"stat": "Sum"}],
          [".", "5XXError", {"stat": "Sum"}]
        ],
        "view": "timeSeries",
        "region": "us-east-1",
        "title": "🔌 API Gateway",
        "period": 300
      }
    },
    {
      "type": "metric",
      "x": 12,
      "y": 14,
      "width": 12,
      "height": 6,
      "properties": {
        "metrics": [
          ["AWS/Lambda", "Invocations", "FunctionName", "atx-trigger-job"],
          ["...", "atx-trigger-batch-jobs"],
          ["...", "atx-get-job-status"],
          ["...", "atx-get-batch-status"]
        ],
        "view": "timeSeries",
        "region": "us-east-1",
        "title": "⚡ Lambda Invocations",
        "period": 300,
        "stat": "Sum"
      }
    },
    {
      "type": "metric",
      "x": 0,
      "y": 20,
      "width": 24,
      "height": 6,
      "properties": {
        "metrics": [
          ["AWS/Lambda", "Duration", "FunctionName", "atx-trigger-job", {"stat": "Average"}],
          ["...", "atx-trigger-batch-jobs", {"stat": "Average"}],
          ["...", "atx-get-job-status", {"stat": "Average"}],
          ["...", "atx-get-batch-status", {"stat": "Average"}]
        ],
        "view": "timeSeries",
        "region": "us-east-1",
        "title": "⚡ Lambda Duration (ms)",
        "period": 300
      }
    }
  ]
}

DASHBOARD_EOF

aws cloudwatch put-dashboard \
    --dashboard-name "$DASHBOARD_NAME" \
    --dashboard-body file:///tmp/dashboard.json \
    --region "$AWS_REGION" >/dev/null

rm -f /tmp/dashboard.json

log_success "CloudWatch dashboard created: $DASHBOARD_NAME"
echo ""

# Cleanup temp files
rm -f /tmp/trust-policy.json /tmp/s3-policy.json /tmp/job-definition.json

# ============================================
# Deployment Complete
# ============================================
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""
log_success "All resources created successfully"
echo ""
echo "Resources:"
echo "  • ECR Repository: $ECR_URI"
echo "  • S3 Bucket: s3://$S3_BUCKET_NAME"
echo "  • Job Queue: $JOB_QUEUE_NAME"
echo "  • Job Definition: $JOB_DEFINITION_NAME:1"
echo "  • CloudWatch Logs: /aws/batch/atx-transform"
echo "  • Dashboard: $DASHBOARD_NAME"
echo ""
echo "View Dashboard:"
echo "  https://console.aws.amazon.com/cloudwatch/home?region=$AWS_REGION#dashboards:name=$DASHBOARD_NAME"
echo ""
echo "Test your deployment:"
echo "  aws batch submit-job \\"
echo "    --job-name test \\"
echo "    --job-queue $JOB_QUEUE_NAME \\"
echo "    --job-definition $JOB_DEFINITION_NAME:1 \\"
echo "    --container-overrides '{\"command\":[\"--command\",\"atx custom def list\"]}'"
echo ""
