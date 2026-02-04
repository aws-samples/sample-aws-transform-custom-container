#!/bin/bash
# Usage: ./1-build-and-push.sh [--rebuild]
#   --rebuild: Force rebuild with --no-cache (ignore Docker layer cache)
set -e

# Build and push container to customer's ECR

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

# Check for --rebuild flag
FORCE_REBUILD=false
if [ "$1" = "--rebuild" ]; then
    FORCE_REBUILD=true
    log_info "Force rebuild requested"
fi

echo "=========================================="
echo "Step 1: Build and Push Container to ECR"
echo "=========================================="
echo ""

# Load configuration if exists
if [ -f "$CONFIG_FILE" ]; then
    log_info "Loading configuration from config.env"
    source "$CONFIG_FILE"
fi

# Detect or use configured AWS account ID
if [ -z "$AWS_ACCOUNT_ID" ]; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        log_error "Failed to detect AWS account ID. Is AWS CLI configured?"
        exit 1
    fi
    log_info "Auto-detected AWS Account: $AWS_ACCOUNT_ID"
else
    log_info "Using configured AWS Account: $AWS_ACCOUNT_ID"
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO_NAME="${ECR_REPO_NAME:-aws-transform-cli}"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"

log_info "Region: $AWS_REGION"
log_info "ECR Repository: $ECR_REPO_NAME"
echo ""

# Create ECR repository if it doesn't exist
log_info "Creating ECR repository..."
aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" &>/dev/null || {
    aws ecr create-repository \
        --repository-name "$ECR_REPO_NAME" \
        --region "$AWS_REGION" >/dev/null
    log_success "ECR repository created"
}
log_success "ECR repository ready: $ECR_URI"
echo ""

# Build container from Dockerfile
log_info "Building container from Dockerfile..."
if [ "$FORCE_REBUILD" = true ]; then
    log_info "Using --no-cache for clean build"
    cd "$PROJECT_ROOT/container"
    docker build --no-cache -t "$ECR_REPO_NAME:latest" .
else
    log_info "Building with Docker layer cache (use --rebuild to force clean build)"
    cd "$PROJECT_ROOT/container"
    docker build -t "$ECR_REPO_NAME:latest" .
fi
log_success "Container built"

echo ""
log_info "Pushing to ECR..."

# Login to ECR
aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Tag and push
docker tag "$ECR_REPO_NAME:latest" "$ECR_URI:latest"
docker push "$ECR_URI:latest"

log_success "Container pushed to ECR"
echo ""

# Save ECR URI for step 2
echo "$ECR_URI:latest" > "$SCRIPT_DIR/.ecr-uri.txt"

echo "=========================================="
echo "Step 1 Complete!"
echo "=========================================="
echo ""
log_success "Container available at: $ECR_URI:latest"
echo ""
echo "Next step:"
echo "  ./2-deploy-cloudformation.sh"
echo ""
