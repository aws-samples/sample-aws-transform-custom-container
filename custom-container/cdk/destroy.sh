#!/bin/bash
set -e

echo "=========================================="
echo "AWS Transform CLI - CDK Cleanup"
echo "=========================================="
echo ""

cd "$(dirname "$0")"

echo "⚠️  This will delete all deployed resources:"
echo "  - Lambda functions and API Gateway"
echo "  - Batch compute environment, job queue, job definition"
echo "  - S3 buckets (if empty)"
echo "  - IAM roles"
echo "  - CloudWatch log groups"
echo "  - ECR repository"
echo ""
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Destroying stacks..."
npx cdk destroy --all --force

echo ""
echo "=========================================="
echo "✅ Cleanup Complete!"
echo "=========================================="
echo ""
echo "Note: S3 buckets with data are retained by default."
echo "To delete them manually:"
echo "  aws s3 rb s3://atx-custom-output-ACCOUNT_ID --force"
echo "  aws s3 rb s3://atx-source-code-ACCOUNT_ID --force"
echo ""
