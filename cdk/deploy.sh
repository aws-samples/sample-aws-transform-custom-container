#!/bin/bash
set -e

# Parse arguments
FORCE_REBUILD=false
if [ "$1" == "--force" ] || [ "$1" == "-f" ]; then
    FORCE_REBUILD=true
    echo "Force rebuild enabled - will clear Docker cache"
fi

echo "=========================================="
echo "AWS Transform CLI - CDK Deployment"
echo "=========================================="
echo ""

cd "$(dirname "$0")"

# Check if AWS CLI is configured
if ! aws sts get-caller-identity &>/dev/null; then
    echo "❌ AWS CLI is not configured"
    echo "   Run: aws configure"
    exit 1
fi

# Get AWS account and region
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region || echo "us-east-1")

# Export for CDK
export CDK_DEFAULT_ACCOUNT=$AWS_ACCOUNT
export CDK_DEFAULT_REGION=$AWS_REGION

echo "✓ AWS Account: $AWS_ACCOUNT"
echo "✓ AWS Region: $AWS_REGION"
echo ""

# Authenticate with ECR Public to avoid rate limiting
echo "Authenticating with ECR Public..."
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws
echo ""

# Install dependencies
echo "Installing dependencies..."
npm install
echo ""

# Bootstrap CDK (if not already done)
echo "Checking CDK bootstrap..."
if ! aws cloudformation describe-stacks --stack-name CDKToolkit --region $AWS_REGION &>/dev/null; then
    echo "Bootstrapping CDK..."
    CDK_DEFAULT_ACCOUNT=$AWS_ACCOUNT CDK_DEFAULT_REGION=$AWS_REGION ./node_modules/.bin/cdk bootstrap aws://$AWS_ACCOUNT/$AWS_REGION
else
    echo "✓ CDK already bootstrapped"
fi
echo ""

# Build
echo "Building CDK project..."
npm run build
echo ""

# Deploy all stacks
echo "Deploying stacks..."
echo "This will deploy:"
echo "  1. AtxContainerStack (ECR + Docker Image)"
echo "  2. AtxInfrastructureStack (Batch, S3, IAM)"
echo "  3. AtxApiStack (Lambda + API Gateway)"
echo ""

if [ "$FORCE_REBUILD" = true ]; then
    echo "Force rebuild: Clearing CDK asset cache..."
    rm -rf cdk.out
    echo "Force rebuild: Adding --no-cache to Docker build..."
    export DOCKER_BUILDKIT=1
    CDK_DOCKER_BUILD_ARGS="--no-cache" CDK_DEFAULT_ACCOUNT=$AWS_ACCOUNT CDK_DEFAULT_REGION=$AWS_REGION ./node_modules/.bin/cdk deploy --all --require-approval never
else
    CDK_DEFAULT_ACCOUNT=$AWS_ACCOUNT CDK_DEFAULT_REGION=$AWS_REGION ./node_modules/.bin/cdk deploy --all --require-approval never
fi

echo ""
echo "=========================================="
echo "✅ Deployment Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo '  1. Get API endpoint: export API_ENDPOINT=$(aws cloudformation describe-stacks --stack-name AtxApiStack --query "Stacks[0].Outputs[?OutputKey=='"'"'ApiEndpoint'"'"'].OutputValue" --output text)'
echo "  2. Test job submission: See api/README.md"
echo ""
