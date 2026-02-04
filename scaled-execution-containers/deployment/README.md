# Deployment Guide

Simple 3-step deployment with least-privilege IAM permissions.

## Getting Started

**Clone the repository:**
```bash
git clone https://github.com/aws-samples/aws-transform-custom-samples.git
cd aws-transform-custom-samples/custom-container/deployment
```

## Prerequisites

- Docker installed and running
- AWS CLI v2.13+ installed and AWS credentials configured
- Git, Bash

## AWS Profile Setup

**Using a specific AWS profile:** Set the `AWS_PROFILE` environment variable before running any commands:

```bash
export AWS_PROFILE=your_profile_name
```

This is especially important if you have multiple AWS accounts or profiles configured.

**Verify:** `./check-prereqs.sh`

---

## Configuration

```bash
cd deployment
cp config.env.template config.env
# Edit config.env if you want custom resource names (optional)
```

All settings have defaults and auto-detection. Customization is optional.

**Common customizations:**
- `ECR_REPO_NAME` - ECR repository name (default: `atx-custom-ecr`)
- `AWS_REGION` - AWS region (default: `us-east-1`)
- `FARGATE_VCPU` / `FARGATE_MEMORY` - Container resources
- `JOB_TIMEOUT` - Maximum job duration in seconds

---

## IAM Permissions Setup

**Generate a least-privilege IAM policy** instead of using broad permissions:

### Step 1: Generate Custom Policy

```bash
./generate-custom-policy.sh
```

This creates `iam-custom-policy.json` with minimum permissions scoped to your specific resources.

### Step 2: Create Policy in AWS

```bash
aws iam create-policy \
  --policy-name ATXCustomDeploymentPolicy \
  --policy-document file://iam-custom-policy.json
```

### Step 3: Attach to Your IAM User

```bash
# Replace YOUR_USERNAME with your IAM username
aws iam attach-user-policy \
  --user-name YOUR_USERNAME \
  --policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/ATXCustomDeploymentPolicy
```

**Alternative for AWS Admins:** If you have administrator access, you can skip this section and proceed directly to deployment.

---

## Quick Start

**For private repository access:** Customize `container/Dockerfile` before deployment. See [container/README.md](../container/README.md#extending-for-private-access) for examples.

```bash
cd deployment

# Step 0: Check prerequisites
./check-prereqs.sh
# If this fails, install missing tools (see Prerequisites section)

# Step 1: Build and push container
./1-build-and-push.sh
```

**What it does:**
- Builds container from Dockerfile
- Creates ECR repository in your AWS account
- Pushes container image to your ECR
- Saves ECR URI for next step

**Time:** 15-20 minutes (first build)

```bash
# Step 2: Deploy infrastructure
./2-deploy-infrastructure.sh
```

**What it does:**
- Creates S3 buckets (source and output) with encryption
- Creates IAM roles (job role and execution role)
- Deploys AWS Batch compute environment (Fargate)
- Creates job queue and job definition
- Sets up CloudWatch logs and dashboard
- Configures security groups

**Time:** 10 minutes

```bash
# Step 3: Deploy API (Recommended)
./3-deploy-api.sh
```

**What it does:**
- Deploys 7 Lambda functions
- Creates API Gateway with IAM authentication
- Configures all API endpoints and permissions

**Time:** 5 minutes

**Total time:** 20-30 minutes

**Note:** Step 3 (API) is optional if you only want to use AWS Batch CLI directly. However, the API provides easier job management, bulk submission, and status tracking.

**See [../api/README.md](../api/README.md) for complete API documentation and examples.**

---

## Next Steps

After successful deployment:

```bash
# Get API endpoint (if you deployed Step 3)
aws cloudformation describe-stacks \
  --stack-name atx-api-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue' \
  --output text

# Option 1: Run comprehensive test suite (recommended)
export API_ENDPOINT=<your-api-endpoint>
cd ../test
./test-apis.sh

# Option 2: Test with a single job
python3 ../utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "https://github.com/venuvasu/todoapilambda",
    "command": "atx custom def exec -n AWS/python-version-upgrade -p /source/todoapilambda -x -t"
  }'
```

**See [../api/README.md](../api/README.md) for complete API documentation, campaign setup, and bulk submission examples.**

---

## Cleanup

To remove all deployed resources:

```bash
cd deployment
./cleanup.sh
```

**What gets deleted:**
- AWS Batch resources (compute environment, job queue, job definitions)
- Lambda functions and API Gateway
- IAM roles
- S3 buckets (after emptying)
- CloudWatch logs and dashboard
- ECR repository

---

## Troubleshooting

**check-prereqs.sh fails:**
- **Docker not found**: Install from https://docs.docker.com/get-docker/
- **AWS CLI not found**: Install v2 from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
- **AWS not configured**: Run `aws configure` with your credentials
- **Git not found**: Install from https://git-scm.com/downloads

**Deployment fails:**
- Check IAM permissions (see IAM Permissions Setup section)
- Verify VPC has public subnets with internet access
- Check CloudFormation console for detailed error messages

**See [../docs/TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md) for more issues.**
