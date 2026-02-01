#!/bin/bash
# Cleanup script - deletes all AWS Transform CLI resources

REGION="${AWS_REGION:-us-east-1}"

echo "=========================================="
echo "AWS Transform CLI - Cleanup"
echo "=========================================="
echo ""
echo "This will delete ALL resources created by the deployment."
echo ""
read -p "Are you sure? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cleanup cancelled"
    exit 0
fi

echo ""
echo "Deleting resources..."

# Disable and delete job queue
echo "1. Disabling job queue..."
aws batch update-job-queue --job-queue atx-job-queue --state DISABLED --region $REGION 2>/dev/null
sleep 10

# Disable and delete compute environment
echo "2. Disabling compute environment..."
aws batch update-compute-environment --compute-environment atx-fargate-compute --state DISABLED --region $REGION 2>/dev/null
sleep 15

echo "3. Deleting job queue..."
aws batch delete-job-queue --job-queue atx-job-queue --region $REGION 2>/dev/null
sleep 10

echo "4. Deleting compute environment..."
aws batch delete-compute-environment --compute-environment atx-fargate-compute --region $REGION 2>/dev/null
sleep 10

# Deregister job definitions
echo "5. Deregistering job definitions..."
aws batch describe-job-definitions --job-definition-name atx-transform-job --status ACTIVE --region $REGION --query 'jobDefinitions[*].revision' --output text 2>/dev/null | tr '\t' '\n' | while read rev; do
    aws batch deregister-job-definition --job-definition atx-transform-job:$rev --region $REGION 2>/dev/null
done

# Delete security group
echo "6. Deleting security group..."
aws ec2 delete-security-group --group-name atx-batch-sg --region $REGION 2>/dev/null

# Delete IAM roles
echo "7. Deleting IAM roles..."
# ATXBatchJobRole
aws iam detach-role-policy --role-name ATXBatchJobRole --policy-arn arn:aws:iam::aws:policy/AWSTransformCustomFullAccess 2>/dev/null
aws iam delete-role-policy --role-name ATXBatchJobRole --policy-name S3Access 2>/dev/null
aws iam delete-role --role-name ATXBatchJobRole 2>/dev/null

# ATXBatchExecutionRole
aws iam detach-role-policy --role-name ATXBatchExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null
aws iam delete-role --role-name ATXBatchExecutionRole 2>/dev/null

# ATXApiLambdaRole
aws iam detach-role-policy --role-name ATXApiLambdaRole --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null
aws iam delete-role-policy --role-name ATXApiLambdaRole --policy-name ATXApiPolicy 2>/dev/null
aws iam delete-role-policy --role-name ATXApiLambdaRole --policy-name LambdaSelfInvoke 2>/dev/null
aws iam delete-role-policy --role-name ATXApiLambdaRole --policy-name S3OutputBucketAccess 2>/dev/null
aws iam delete-role --role-name ATXApiLambdaRole 2>/dev/null

# Delete Lambda functions
echo "8. Deleting Lambda functions..."
for func in atx-trigger-job atx-trigger-batch-jobs atx-get-job-status atx-get-batch-status atx-configure-mcp atx-terminate-job atx-upload-code; do
    aws lambda delete-function --function-name $func --region $REGION 2>/dev/null
done

# Delete API Gateway
echo "9. Deleting API Gateway..."
API_ID=$(aws apigateway get-rest-apis --region $REGION --query "items[?name=='atx-transform-api'].id" --output text 2>/dev/null)
if [ -n "$API_ID" ]; then
    aws apigateway delete-rest-api --rest-api-id $API_ID --region $REGION 2>/dev/null
fi

# Delete CloudWatch dashboard
echo "10. Deleting CloudWatch dashboard..."
aws cloudwatch delete-dashboards --dashboard-names ATX-Transform-CLI-Dashboard --region $REGION 2>/dev/null

# Delete CloudWatch log group
echo "11. Deleting CloudWatch log group..."
aws logs delete-log-group --log-group-name /aws/batch/atx-transform --region $REGION 2>/dev/null

# Delete S3 buckets (empty first)
echo "12. Deleting S3 buckets..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
aws s3 rm s3://atx-source-code-$ACCOUNT_ID --recursive 2>/dev/null
aws s3 rb s3://atx-source-code-$ACCOUNT_ID 2>/dev/null
aws s3 rm s3://atx-custom-output-$ACCOUNT_ID --recursive 2>/dev/null
aws s3 rb s3://atx-custom-output-$ACCOUNT_ID 2>/dev/null

# Delete ECR repository
echo "13. Deleting ECR repository..."
aws ecr delete-repository --repository-name aws-transform-cli --force --region $REGION 2>/dev/null

echo ""
echo "✓ Cleanup complete!"
