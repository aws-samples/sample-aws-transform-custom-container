#!/bin/bash
# Prerequisites Check Script for AWS Transform CLI Deployment

echo "=========================================="
echo "Prerequisites Check"
echo "=========================================="
echo ""

ALL_GOOD=true

# Check Docker
echo "1. Checking Docker..."
if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version)
    echo "   ✅ Docker installed: $DOCKER_VERSION"
    
    if docker info &> /dev/null 2>&1; then
        echo "   ✅ Docker daemon is running"
    else
        echo "   ❌ Docker daemon is NOT running"
        echo "      → Start Docker Desktop or run: sudo systemctl start docker"
        ALL_GOOD=false
    fi
else
    echo "   ❌ Docker is NOT installed"
    echo "      → Install from: https://www.docker.com/products/docker-desktop"
    ALL_GOOD=false
fi
echo ""

# Check AWS CLI
echo "2. Checking AWS CLI..."
if command -v aws &> /dev/null; then
    AWS_VERSION=$(aws --version 2>&1)
    echo "   ✅ AWS CLI installed: $AWS_VERSION"
    
    # Check if it's v2
    if [[ "$AWS_VERSION" == *"aws-cli/2"* ]]; then
        echo "   ✅ AWS CLI v2 detected"
    else
        echo "   ⚠️  AWS CLI v1 detected - v2 is recommended"
        echo "      → Upgrade: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    fi
    
    # Check credentials
    if aws sts get-caller-identity &> /dev/null 2>&1; then
        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
        USER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
        echo "   ✅ AWS credentials configured"
        echo "      Account: $ACCOUNT_ID"
        echo "      Identity: $USER_ARN"
    else
        echo "   ❌ AWS credentials NOT configured"
        echo "      → Run: aws configure"
        ALL_GOOD=false
    fi
else
    echo "   ❌ AWS CLI is NOT installed"
    echo "      → Install from: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    ALL_GOOD=false
fi
echo ""

# Check Git
echo "3. Checking Git..."
if command -v git &> /dev/null; then
    GIT_VERSION=$(git --version)
    echo "   ✅ Git installed: $GIT_VERSION"
else
    echo "   ❌ Git is NOT installed"
    echo "      → Install from: https://git-scm.com/downloads"
    ALL_GOOD=false
fi
echo ""

# Check Bash
echo "4. Checking Bash..."
if command -v bash &> /dev/null; then
    BASH_VERSION=$(bash --version | head -n1)
    echo "   ✅ Bash installed: $BASH_VERSION"
else
    echo "   ❌ Bash is NOT installed"
    ALL_GOOD=false
fi
echo ""

# Check Node.js (for CDK deployment)
echo "5. Checking Node.js (for CDK deployment)..."
if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version)
    echo "   ✅ Node.js installed: $NODE_VERSION"
    
    # Check if it's v18+
    NODE_MAJOR=$(node --version | cut -d'.' -f1 | sed 's/v//')
    if [ "$NODE_MAJOR" -ge 18 ]; then
        echo "   ✅ Node.js version is 18+ (required for CDK)"
    else
        echo "   ⚠️  Node.js version is below 18 - CDK requires 18+"
        echo "      → Upgrade: https://nodejs.org/"
    fi
else
    echo "   ⚠️  Node.js is NOT installed (required for CDK deployment)"
    echo "      → Install from: https://nodejs.org/"
    echo "      → Or skip if using bash deployment only"
fi
echo ""

# Check AWS CDK CLI (for CDK deployment)
echo "6. Checking AWS CDK CLI (for CDK deployment)..."
if command -v cdk &> /dev/null || npx cdk --version &> /dev/null 2>&1; then
    if command -v cdk &> /dev/null; then
        CDK_VERSION=$(cdk --version 2>&1)
    else
        CDK_VERSION=$(npx cdk --version 2>&1)
    fi
    echo "   ✅ AWS CDK installed: $CDK_VERSION"
else
    echo "   ⚠️  AWS CDK is NOT installed (required for CDK deployment)"
    echo "      → Install: npm install -g aws-cdk"
    echo "      → Or skip if using bash deployment only"
fi
echo ""

# Check VPC and Subnets (if AWS CLI is configured)
if command -v aws &> /dev/null && aws sts get-caller-identity &> /dev/null 2>&1; then
    echo "7. Checking AWS Network Resources..."
    
    # Check for VPC
    VPC_COUNT=$(aws ec2 describe-vpcs --query 'length(Vpcs)' --output text 2>/dev/null || echo "0")
    if [ "$VPC_COUNT" -gt 0 ]; then
        echo "   ✅ Found $VPC_COUNT VPC(s)"
        
        # Check for default VPC
        DEFAULT_VPC=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
        if [[ "$DEFAULT_VPC" != "None" && -n "$DEFAULT_VPC" ]]; then
            echo "   ✅ Default VPC exists: $DEFAULT_VPC"
        fi
    else
        echo "   ⚠️  No VPCs found"
        echo "      → Create a VPC or use default VPC"
    fi
    
    # Check for public subnets
    SUBNET_COUNT=$(aws ec2 describe-subnets --filters "Name=map-public-ip-on-launch,Values=true" --query 'length(Subnets)' --output text 2>/dev/null || echo "0")
    if [ "$SUBNET_COUNT" -ge 2 ]; then
        echo "   ✅ Found $SUBNET_COUNT public subnet(s)"
    elif [ "$SUBNET_COUNT" -eq 1 ]; then
        echo "   ⚠️  Found only 1 public subnet (2+ recommended for high availability)"
    else
        echo "   ⚠️  No public subnets found"
        echo "      → Create public subnets or the deployment will fail"
    fi
    echo ""
fi

# Final summary
echo "=========================================="
if [ "$ALL_GOOD" = true ]; then
    echo "✅ All prerequisites met!"
    echo ""
    echo "Next steps:"
    echo "  1. Configure: cp config.env.template config.env"
    echo "  2. Setup IAM: ./generate-custom-policy.sh (see README.md)"
    echo "  3. Deploy: ./1-build-and-push.sh && ./2-deploy-infrastructure.sh"
else
    echo "❌ Some prerequisites are missing"
    echo ""
    echo "Please install missing components and try again."
fi
echo "=========================================="
