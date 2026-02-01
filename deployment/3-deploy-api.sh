#!/bin/bash
set -e

# Automated API Gateway + Lambda Deployment
# Deploys REST API for AWS Transform CLI job management

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LAMBDA_DIR="$PROJECT_ROOT/api/lambda"
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
echo "AWS Transform CLI - API Deployment"
echo "=========================================="
echo ""

# Check for config file
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    echo ""
    echo "Please create config.env from template:"
    echo "  cp config.env.template config.env"
    echo "  # Edit config.env with your settings"
    echo "  ./deploy-api.sh"
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
API_NAME="${API_NAME:-atx-transform-api}"
API_STAGE="${API_STAGE:-prod}"
OUTPUT_BUCKET="${OUTPUT_BUCKET:-atx-custom-output-${AWS_ACCOUNT_ID}}"
SOURCE_BUCKET="${SOURCE_BUCKET:-atx-source-code-${AWS_ACCOUNT_ID}}"
JOB_QUEUE_NAME="${JOB_QUEUE_NAME:-atx-job-queue}"
JOB_DEFINITION_NAME="${JOB_DEFINITION_NAME:-atx-transform-job}"

log_success "Configuration loaded"
echo ""

# ============================================
# STEP 1: Create Source S3 Bucket
# ============================================
echo "=========================================="
echo "STEP 1: Create Source S3 Bucket"
echo "=========================================="
echo ""

aws s3 ls "s3://$SOURCE_BUCKET" &>/dev/null || {
    log_info "Creating source S3 bucket: $SOURCE_BUCKET"
    aws s3 mb "s3://$SOURCE_BUCKET" --region "$AWS_REGION"
    
    # Enable encryption
    aws s3api put-bucket-encryption \
        --bucket "$SOURCE_BUCKET" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }'
    
    # Set lifecycle policy to delete uploads after 7 days
    cat > /tmp/lifecycle-policy.json << 'EOF'
{
  "Rules": [{
    "ID": "DeleteOldUploads",
    "Status": "Enabled",
    "Prefix": "uploads/",
    "Expiration": {
      "Days": 7
    }
  }]
}
EOF
    
    aws s3api put-bucket-lifecycle-configuration \
        --bucket "$SOURCE_BUCKET" \
        --lifecycle-configuration file:///tmp/lifecycle-policy.json
    
    rm /tmp/lifecycle-policy.json
    
    # Block all public access
    aws s3api put-public-access-block \
        --bucket "$SOURCE_BUCKET" \
        --public-access-block-configuration \
            BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    
    log_success "Source bucket created with encryption, lifecycle policy, and public access blocks"
}

log_success "Source S3 bucket ready: s3://$SOURCE_BUCKET"
echo ""

# ============================================
# STEP 2: Create IAM Role for Lambda
# ============================================
echo "=========================================="
echo "STEP 2: Create IAM Role for Lambda"
echo "=========================================="
echo ""

LAMBDA_ROLE_NAME="ATXApiLambdaRole"

if ! aws iam get-role --role-name "$LAMBDA_ROLE_NAME" &>/dev/null; then
    log_info "Creating IAM role for Lambda..."
    
    cat > /tmp/lambda-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

    aws iam create-role \
        --role-name "$LAMBDA_ROLE_NAME" \
        --assume-role-policy-document file:///tmp/lambda-trust-policy.json >/dev/null
    
    # Attach basic Lambda execution policy
    aws iam attach-role-policy \
        --role-name "$LAMBDA_ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    
    rm /tmp/lambda-trust-policy.json
    
    log_info "Waiting for IAM role to propagate..."
    sleep 15
    
    log_success "IAM role created"
else
    log_info "IAM role already exists"
fi

# Always update policy (in case it changed)
log_info "Updating Lambda role policy..."

cat > /tmp/lambda-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "batch:SubmitJob",
        "batch:DescribeJobs",
        "batch:ListJobs",
        "batch:TerminateJob"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::$OUTPUT_BUCKET/*",
        "arn:aws:s3:::$OUTPUT_BUCKET"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:HeadObject"
      ],
      "Resource": [
        "arn:aws:s3:::$SOURCE_BUCKET/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:GetLogEvents",
        "logs:FilterLogEvents"
      ],
      "Resource": "arn:aws:logs:$AWS_REGION:$AWS_ACCOUNT_ID:log-group:/aws/batch/atx-transform:*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "lambda:InvokeFunction"
      ],
      "Resource": [
        "arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:atx-trigger-batch-jobs"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-name ATXApiPolicy \
    --policy-document file:///tmp/lambda-policy.json

rm /tmp/lambda-policy.json

log_success "Lambda role policy updated"

LAMBDA_ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:role/$LAMBDA_ROLE_NAME"
log_success "Lambda role ready: $LAMBDA_ROLE_ARN"
echo ""

# ============================================
# STEP 3: Package and Deploy Lambda Functions
# ============================================
echo "=========================================="
echo "STEP 3: Deploy Lambda Functions"
echo "=========================================="
echo ""

cd "$LAMBDA_DIR"

# Create deployment package
log_info "Creating Lambda deployment package..."
rm -rf /tmp/lambda-package
mkdir -p /tmp/lambda-package

# Install dependencies
pip install -q -t /tmp/lambda-package boto3

# Copy Lambda functions
cp *.py /tmp/lambda-package/

# Create ZIP
cd /tmp/lambda-package
zip -q -r /tmp/lambda-deployment.zip .

log_success "Deployment package created"

# Deploy each Lambda function
LAMBDA_FUNCTIONS=(
    "trigger_job"
    "get_job_status"
    "upload_code"
    "terminate_job"
    "configure_mcp"
    "trigger_batch_jobs"
    "get_batch_status"
)

for FILE_NAME in "${LAMBDA_FUNCTIONS[@]}"; do
    # Convert underscores to hyphens for Lambda function name
    LAMBDA_NAME="atx-${FILE_NAME//_/-}"
    
    log_info "Deploying Lambda: $LAMBDA_NAME"
    
    # Check if function exists
    if aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" &>/dev/null; then
        # Update existing function
        if aws lambda update-function-code \
            --function-name "$LAMBDA_NAME" \
            --zip-file fileb:///tmp/lambda-deployment.zip \
            --region "$AWS_REGION" >/dev/null 2>&1; then
            
            # Update environment variables and handler
            aws lambda update-function-configuration \
                --function-name "$LAMBDA_NAME" \
                --handler "${FILE_NAME}.lambda_handler" \
                --environment "Variables={
                    OUTPUT_BUCKET=$OUTPUT_BUCKET,
                    SOURCE_BUCKET=$SOURCE_BUCKET,
                    JOB_QUEUE=$JOB_QUEUE_NAME,
                    JOB_DEFINITION=$JOB_DEFINITION_NAME,
                    LOG_GROUP=/aws/batch/atx-transform
                }" \
                --region "$AWS_REGION" >/dev/null 2>&1 || {
                log_warning "Function $LAMBDA_NAME update in progress, skipping configuration update"
            }
            
            log_success "Updated: $LAMBDA_NAME"
        else
            log_warning "Function $LAMBDA_NAME update in progress, skipping"
        fi
    else
        # Create new function
        aws lambda create-function \
            --function-name "$LAMBDA_NAME" \
            --runtime python3.11 \
            --role "$LAMBDA_ROLE_ARN" \
            --handler "${FILE_NAME}.lambda_handler" \
            --zip-file fileb:///tmp/lambda-deployment.zip \
            --timeout 30 \
            --memory-size 256 \
            --environment "Variables={
                OUTPUT_BUCKET=$OUTPUT_BUCKET,
                SOURCE_BUCKET=$SOURCE_BUCKET,
                JOB_QUEUE=$JOB_QUEUE_NAME,
                JOB_DEFINITION=$JOB_DEFINITION_NAME,
                LOG_GROUP=/aws/batch/atx-transform
            }" \
            --region "$AWS_REGION" >/dev/null
        
        log_success "Created: $LAMBDA_NAME"
    fi
done

rm -rf /tmp/lambda-package /tmp/lambda-deployment.zip

log_success "All Lambda functions deployed"
echo ""

# ============================================
# STEP 4: Create API Gateway
# ============================================
echo "=========================================="
echo "STEP 4: Create API Gateway"
echo "=========================================="
echo ""

# Check if API exists
API_ID=$(aws apigateway get-rest-apis --region "$AWS_REGION" --query "items[?name=='$API_NAME'].id" --output text)

if [ -z "$API_ID" ]; then
    log_info "Creating API Gateway..."
    API_ID=$(aws apigateway create-rest-api \
        --name "$API_NAME" \
        --description "AWS Transform CLI Job Management API" \
        --region "$AWS_REGION" \
        --query 'id' --output text)
    log_success "API created: $API_ID"
else
    log_info "Using existing API: $API_ID"
fi

# Get root resource ID
ROOT_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$AWS_REGION" --query 'items[?path==`/`].id' --output text)

log_success "API Gateway ready"
echo ""

# ============================================
# STEP 5: Create API Resources and Methods
# ============================================
echo "=========================================="
echo "STEP 5: Configure API Resources"
echo "=========================================="
echo ""

# Helper function to create resource
create_resource() {
    local PARENT_ID=$1
    local PATH_PART=$2
    
    RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$AWS_REGION" \
        --query "items[?pathPart=='$PATH_PART' && parentId=='$PARENT_ID'].id" --output text)
    
    if [ -z "$RESOURCE_ID" ]; then
        RESOURCE_ID=$(aws apigateway create-resource \
            --rest-api-id "$API_ID" \
            --parent-id "$PARENT_ID" \
            --path-part "$PATH_PART" \
            --region "$AWS_REGION" \
            --query 'id' --output text)
    fi
    
    echo "$RESOURCE_ID"
}

# Helper function to create method
create_method() {
    local RESOURCE_ID=$1
    local HTTP_METHOD=$2
    local LAMBDA_NAME=$3
    
    # Check if method exists
    if ! aws apigateway get-method --rest-api-id "$API_ID" --resource-id "$RESOURCE_ID" \
        --http-method "$HTTP_METHOD" --region "$AWS_REGION" &>/dev/null; then
        
        # Create method
        aws apigateway put-method \
            --rest-api-id "$API_ID" \
            --resource-id "$RESOURCE_ID" \
            --http-method "$HTTP_METHOD" \
            --authorization-type NONE \
            --region "$AWS_REGION" >/dev/null
        
        # Set integration
        LAMBDA_ARN="arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:$LAMBDA_NAME"
        aws apigateway put-integration \
            --rest-api-id "$API_ID" \
            --resource-id "$RESOURCE_ID" \
            --http-method "$HTTP_METHOD" \
            --type AWS_PROXY \
            --integration-http-method POST \
            --uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations" \
            --region "$AWS_REGION" >/dev/null
        
        # Add Lambda permission
        aws lambda add-permission \
            --function-name "$LAMBDA_NAME" \
            --statement-id "apigateway-${RESOURCE_ID}-${HTTP_METHOD}" \
            --action lambda:InvokeFunction \
            --principal apigateway.amazonaws.com \
            --source-arn "arn:aws:execute-api:$AWS_REGION:$AWS_ACCOUNT_ID:$API_ID/*/$HTTP_METHOD/*" \
            --region "$AWS_REGION" &>/dev/null || true
    fi
}

# Create /upload resource
log_info "Creating /upload endpoint..."
UPLOAD_ID=$(create_resource "$ROOT_ID" "upload")
create_method "$UPLOAD_ID" "POST" "atx-upload-code"
log_success "POST /upload"

# Create /mcp-config resource
log_info "Creating /mcp-config endpoint..."
MCP_CONFIG_ID=$(create_resource "$ROOT_ID" "mcp-config")
create_method "$MCP_CONFIG_ID" "POST" "atx-configure-mcp"
log_success "POST /mcp-config"

# Create /jobs resource
log_info "Creating /jobs endpoints..."
JOBS_ID=$(create_resource "$ROOT_ID" "jobs")
create_method "$JOBS_ID" "POST" "atx-trigger-job"
log_success "POST /jobs"

# Create /jobs/batch resource
BATCH_ID=$(create_resource "$JOBS_ID" "batch")
create_method "$BATCH_ID" "POST" "atx-trigger-batch-jobs"
log_success "POST /jobs/batch"

# Create /jobs/batch/{batchId} resource
BATCHID_ID=$(create_resource "$BATCH_ID" "{batchId}")
create_method "$BATCHID_ID" "GET" "atx-get-batch-status"
log_success "GET /jobs/batch/{batchId}"

# Create /jobs/{jobId} resource
JOBID_ID=$(create_resource "$JOBS_ID" "{jobId}")
create_method "$JOBID_ID" "GET" "atx-get-job-status"
log_success "GET /jobs/{jobId}"

# Add DELETE method for terminating jobs
create_method "$JOBID_ID" "DELETE" "atx-terminate-job"
log_success "DELETE /jobs/{jobId}"

echo ""

# ============================================
# STEP 6: Enable IAM Authorization
# ============================================
echo "=========================================="
echo "STEP 6: Enable IAM Authorization"
echo "=========================================="
echo ""

log_info "Updating API methods to require IAM authorization..."

# Get all resources
RESOURCES=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$AWS_REGION" --output json)

# Update each method to use AWS_IAM authorization
echo "$RESOURCES" | python3 -c "
import sys, json
resources = json.load(sys.stdin)
for resource in resources['items']:
    if 'resourceMethods' in resource:
        for method in resource['resourceMethods']:
            print(f\"{resource['id']}:{method}\")
" | while IFS=: read -r RESOURCE_ID METHOD; do
    aws apigateway update-method \
        --rest-api-id "$API_ID" \
        --resource-id "$RESOURCE_ID" \
        --http-method "$METHOD" \
        --patch-operations "op=replace,path=/authorizationType,value=AWS_IAM" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true
done

log_success "IAM authorization enabled on all methods"
echo ""

# ============================================
# STEP 7: Deploy API
# ============================================
echo "=========================================="
echo "STEP 7: Deploy API"
echo "=========================================="
echo ""

log_info "Deploying API to $API_STAGE stage..."

aws apigateway create-deployment \
    --rest-api-id "$API_ID" \
    --stage-name "$API_STAGE" \
    --description "Automated deployment with IAM auth $(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --region "$AWS_REGION" >/dev/null

log_success "API deployed"
echo ""

# ============================================
# STEP 8: Update IAM Roles
# ============================================
echo "=========================================="
echo "STEP 8: Update IAM Roles"
echo "=========================================="
echo ""

log_info "Updating ATXBatchJobRole with source bucket access..."

# Add source bucket read access to Batch job role
cat > /tmp/batch-s3-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::$OUTPUT_BUCKET/*",
        "arn:aws:s3:::$OUTPUT_BUCKET",
        "arn:aws:s3:::$SOURCE_BUCKET/*",
        "arn:aws:s3:::$SOURCE_BUCKET"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": [
        "arn:aws:s3:::$OUTPUT_BUCKET/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
    --role-name ATXBatchJobRole \
    --policy-name S3BucketAccess \
    --policy-document file:///tmp/batch-s3-policy.json

rm /tmp/batch-s3-policy.json

log_success "Batch job role updated"
echo ""

# ============================================
# STEP 9: Create API Consumer Role
# ============================================
echo "=========================================="
echo "STEP 9: Create API Consumer Role"
echo "=========================================="
echo ""

API_CONSUMER_ROLE="ATXApiConsumerRole"

# Check if role exists
if ! aws iam get-role --role-name "$API_CONSUMER_ROLE" &>/dev/null; then
    log_info "Creating API consumer role..."
    
    # Create trust policy for users/services
    cat > /tmp/api-consumer-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::ACCOUNT_ID:root"
    },
    "Action": "sts:AssumeRole"
  }]
}
EOF
    
    # Replace ACCOUNT_ID
    sed -i '' "s/ACCOUNT_ID/$AWS_ACCOUNT_ID/g" /tmp/api-consumer-trust.json
    
    aws iam create-role \
        --role-name "$API_CONSUMER_ROLE" \
        --assume-role-policy-document file:///tmp/api-consumer-trust.json \
        --description "Role for consuming AWS Transform CLI API" >/dev/null
    
    rm /tmp/api-consumer-trust.json
    
    log_success "API consumer role created"
else
    log_info "API consumer role already exists"
fi

# Create/update API access policy
log_info "Creating API access policy..."

cat > /tmp/api-access-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "execute-api:Invoke",
    "Resource": [
      "arn:aws:execute-api:$AWS_REGION:$AWS_ACCOUNT_ID:$API_ID/prod/POST/jobs",
      "arn:aws:execute-api:$AWS_REGION:$AWS_ACCOUNT_ID:$API_ID/prod/POST/upload",
      "arn:aws:execute-api:$AWS_REGION:$AWS_ACCOUNT_ID:$API_ID/prod/POST/mcp-config",
      "arn:aws:execute-api:$AWS_REGION:$AWS_ACCOUNT_ID:$API_ID/prod/GET/jobs/*",
      "arn:aws:execute-api:$AWS_REGION:$AWS_ACCOUNT_ID:$API_ID/prod/DELETE/jobs/*",
      "arn:aws:execute-api:$AWS_REGION:$AWS_ACCOUNT_ID:$API_ID/prod/GET/results/*",
      "arn:aws:execute-api:$AWS_REGION:$AWS_ACCOUNT_ID:$API_ID/prod/GET/logs/*"
    ]
  }]
}
EOF

aws iam put-role-policy \
    --role-name "$API_CONSUMER_ROLE" \
    --policy-name ATXApiAccessPolicy \
    --policy-document file:///tmp/api-access-policy.json

rm /tmp/api-access-policy.json

log_success "API access policy attached"
echo ""

# ============================================
# Deployment Complete
# ============================================
API_ENDPOINT="https://$API_ID.execute-api.$AWS_REGION.amazonaws.com/$API_STAGE"

echo "=========================================="
echo "API Deployment Complete!"
echo "=========================================="
echo ""
log_success "All resources created successfully"
echo ""
echo "API Endpoint: $API_ENDPOINT"
echo ""
echo "🔒 Security: IAM Authorization ENABLED"
echo ""
echo "Available Endpoints:"
echo "  • POST   $API_ENDPOINT/upload"
echo "  • POST   $API_ENDPOINT/mcp-config"
echo "  • POST   $API_ENDPOINT/jobs"
echo "  • GET    $API_ENDPOINT/jobs/{jobId}"
echo "  • DELETE $API_ENDPOINT/jobs/{jobId}"
echo ""
echo "IAM Roles Created:"
echo "  • ATXApiConsumerRole - For API consumers"
echo "    ARN: arn:aws:iam::$AWS_ACCOUNT_ID:role/ATXApiConsumerRole"
echo ""
echo "Grant Access to Users:"
echo "  # Allow user to assume the API consumer role"
echo "  aws iam attach-user-policy \\"
echo "    --user-name <username> \\"
echo "    --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess"
echo ""
echo "  # Or create inline policy for user"
echo "  aws iam put-user-policy \\"
echo "    --user-name <username> \\"
echo "    --policy-name AssumeATXApiRole \\"
echo "    --policy-document '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Resource\":\"arn:aws:iam::$AWS_ACCOUNT_ID:role/ATXApiConsumerRole\"}]}'"
echo ""
echo "Test the API:"
echo "  ./test-api.sh"
echo ""
echo "Next steps:"
echo "  1. Grant users access to ATXApiConsumerRole (see above)"
echo "  2. Use AWS Signature V4 to sign requests"
echo "  3. Read API documentation: cat README.md"
echo ""
