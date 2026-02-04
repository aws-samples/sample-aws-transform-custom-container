# Troubleshooting Guide

Common issues customers may encounter and how to resolve them.

---

## Deployment Issues

### Deployment Script Fails

**Symptom:** `deploy-automated.sh` exits with errors

**Common Causes:**
1. **Missing AWS credentials**
   ```bash
   # Verify credentials
   aws sts get-caller-identity
   ```

2. **Insufficient IAM permissions**
   - Need permissions for: ECR, S3, IAM, Batch, EC2, CloudWatch Logs
   - Check error message for specific missing permission
   
   **Solution:** Generate least-privilege policy:
   ```bash
   cd deployment
   ./generate-custom-policy.sh
   # Follow instructions to create and attach the policy
   ```

3. **VPC/Subnet not found**
   ```bash
   # List available VPCs
   aws ec2 describe-vpcs --query 'Vpcs[*].[VpcId,IsDefault]' --output table
   
   # List public subnets
   aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-xxx" --query 'Subnets[*].[SubnetId,AvailabilityZone,MapPublicIpOnLaunch]' --output table
   ```

**Solution:** Ensure AWS CLI is configured and you have necessary permissions.

---

### Docker Login to ECR Fails

**Symptom:** `docker login` fails during CDK deployment or manual push

**Error:** `exited with error code 1`

**Solution:**
```bash
# Login to ECR manually
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin {account-id}.dkr.ecr.us-east-1.amazonaws.com

# Verify Docker is running
docker info
```

### API Gateway CloudWatch Logs Role Missing

**Symptom:** CDK deployment fails with "CloudWatch Logs role ARN must be set in account settings"

**Cause:** First-time API Gateway deployment in this account/region

**Solution (one-time per account/region):**
```bash
# Create role
aws iam create-role \
  --role-name APIGatewayCloudWatchLogsRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "apigateway.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

# Attach policy
aws iam attach-role-policy \
  --role-name APIGatewayCloudWatchLogsRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs

# Set in API Gateway
aws apigateway update-account \
  --patch-operations op=replace,path=/cloudwatchRoleArn,value=arn:aws:iam::{account-id}:role/APIGatewayCloudWatchLogsRole \
  --region us-east-1
```

Then redeploy.

### cdk-nag Validation Errors

**Symptom:** CDK deployment fails with "AwsSolutions-IAM5" or similar errors

**Cause:** cdk-nag security validation is enabled

**Solution:**

The cdk-nag suppressions are already configured in the code. If you see errors for your account:
1. Check that `cdk/lib/api-stack.ts` uses dynamic `${this.account}` (not hardcoded)
2. Redeploy after fixing

Or disable cdk-nag temporarily in `cdk/bin/cdk.ts`:
```typescript
// Comment out this line:
// Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));
```

---

## Job Execution Issues

### Job Stays in RUNNABLE Status

**Symptom:** Job never starts, stuck in RUNNABLE

**Causes:**
- Compute environment is disabled or has no capacity
- Image pull fails (ECR permissions)

**Solution:**
```bash
# Check compute environment
aws batch describe-compute-environments --compute-environments atx-compute-env

# Check job queue
aws batch describe-job-queues --job-queues atx-job-queue

# View job details
aws batch describe-jobs --jobs <job-id>
```

### Job Fails Immediately (FAILED status)

**Symptom:** Job goes from SUBMITTED → FAILED quickly

**Common Causes:**

1. **Invalid Git URL**
   ```bash
   # Test Git URL manually
   git ls-remote https://github.com/user/repo.git
   ```

2. **Invalid command syntax**
   - Check quotes in command
   - Verify transformation name exists: `atx custom def list`

3. **Network connectivity issues**
   - Verify security group allows HTTPS outbound (port 443)
   - Check subnet has internet access

**Solution:** Check CloudWatch logs for specific error:
```bash
# Get log stream
JOB_ID="your-job-id"
LOG_STREAM=$(aws batch describe-jobs --jobs $JOB_ID --query 'jobs[0].container.logStreamName' --output text)

# View logs
aws logs get-log-events \
  --log-group-name /aws/batch/atx-transform \
  --log-stream-name $LOG_STREAM \
  --query 'events[*].message' \
  --output text
```

### Job Times Out

**Symptom:** Job runs for hours then fails with timeout

**Causes:**
- Transformation is too complex for allocated resources
- Repository is very large

**Solution:**
```bash
# Increase timeout and resources
curl -X POST "$API_ENDPOINT/jobs" \
  -H "Content-Type: application/json" \
  -d '{
    "source": "https://github.com/user/repo.git",
    "command": "atx custom def exec ...",
    "vcpu": "4",
    "memory": "8192",
    "timeout": 86400
  }'
```

### Transformation Compiles Language from Source (Very Slow)

**Symptom:** Job takes 1-2 hours, logs show "Compiling Python/Java/Node.js"

**Cause:** ATX doesn't know the language is pre-installed

**Solution:** Specify installation path in `additionalPlanContext`:

**Python:**
```bash
"additionalPlanContext": "Target Python 3.13. Python 3.13 is already installed at /usr/bin/python3.13"
```

**Java:**
```bash
"additionalPlanContext": "Target Java 21. Java 21 is already installed at /usr/lib/jvm/java-21-openjdk-amd64"
```

**Node.js:**
```bash
"additionalPlanContext": "Target Node.js 22. Node.js 22 is already installed at /home/atxuser/.nvm/versions/node/v22.12.0/bin/node"
```

See [../api/EXAMPLES.md](../api/EXAMPLES.md) for complete examples.

---

## API Issues

### API Returns 403 Forbidden

**Symptom:** All API calls return 403

**Cause:** Missing IAM permissions for API Gateway

**Solution:**

Grant your IAM user permission to invoke the API:
```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws iam put-user-policy \
  --user-name YOUR_USERNAME \
  --policy-name InvokeATXApi \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"execute-api:Invoke\",
      \"Resource\": \"arn:aws:execute-api:us-east-1:${AWS_ACCOUNT_ID}:*/prod/*\"
    }]
  }"
```

Then use `utilities/invoke-api.py` which handles AWS Signature V4 automatically.

### Cannot Find Conversation ID

**Symptom:** Job succeeds but `atxConversationId` is null

**Causes:**
- Job completed but results weren't uploaded to S3
- Check CloudWatch logs for upload errors

**Solution:**
```bash
# Check S3 bucket for results
aws s3 ls s3://atx-custom-output-{account}/transformations/ --recursive

# Check CloudWatch logs for conversation ID
aws logs filter-log-events \
  --log-group-name /aws/batch/atx-transform \
  --filter-pattern "Conversation ID" \
  --query 'events[*].message'
```

---

## Results Issues

### No Results in S3

**Symptom:** Job completes but logs show "Command failed after 3 attempts" when uploading to S3

**Cause:** IAM role lacks permissions to write to S3 bucket

**Solution:**
```bash
# Update the IAM role policy to include S3 permissions
# See deployment/README.md for IAM policy configuration
```

This ensures ATXBatchJobRole has correct permissions for:
- `atx-custom-output-{ACCOUNT_ID}` (read/write)
- `atx-source-code-{ACCOUNT_ID}` (read)

**Verify permissions:**
```bash
aws iam get-role-policy --role-name ATXBatchJobRole --policy-name S3BucketAccess
```

---

## Debugging Commands

### View Real-Time Logs

**Using tail-logs utility (recommended):**
```bash
# Tail logs for specific job
python3 utilities/tail-logs.py <job-id> --region us-east-1

# Follow logs in real-time (omit --no-follow)
python3 utilities/tail-logs.py <job-id> --region us-east-1
```

**Using AWS CLI:**
```bash
# Tail all jobs
aws logs tail /aws/batch/atx-transform --follow --region us-east-1

# Tail specific job
aws logs tail /aws/batch/atx-transform \
  --log-stream-names "atx/default/{stream-name}" \
  --follow
```

### Check Job Status

```bash
# Via API
curl "$API_ENDPOINT/jobs/{job-id}"

# Via AWS CLI
aws batch describe-jobs --jobs {job-id} --region us-east-1
```

### List Recent Jobs

```bash
aws batch list-jobs \
  --job-queue atx-job-queue \
  --job-status SUCCEEDED \
  --max-results 10
```

### Check IAM Permissions

```bash
# Verify role exists
aws iam get-role --role-name ATXBatchJobRole

# List attached policies
aws iam list-attached-role-policies --role-name ATXBatchJobRole

# View inline policies
aws iam list-role-policies --role-name ATXBatchJobRole
aws iam get-role-policy --role-name ATXBatchJobRole --policy-name {policy-name}
```

### Verify Network Configuration

```bash
# Check security group
aws ec2 describe-security-groups --group-ids {sg-id}

# Check subnet internet access
aws ec2 describe-subnets --subnet-ids {subnet-id} \
  --query 'Subnets[*].[SubnetId,MapPublicIpOnLaunch]'

# Check route table
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values={subnet-id}"
```

---

## Common Error Messages

### "Essential container in task exited"

**Meaning:** Container crashed or exited with error

**Action:** Check CloudWatch logs for actual error message

### "CannotPullContainerError"

**Meaning:** Cannot pull Docker image from ECR

**Causes:**
- Image doesn't exist
- Network cannot reach ECR
- Missing ECR permissions

**Solution:**
```bash
# Verify image exists
aws ecr describe-images \
  --repository-name aws-transform-cli \
  --region us-east-1

# Check execution role has ECR permissions
aws iam get-role --role-name ATXBatchExecutionRole
```

### "ResourceInitializationError"

**Meaning:** Cannot initialize task resources

**Causes:**
- Network configuration issues
- IAM permission issues

**Solution:**
- Verify subnet has internet access
- Check security group allows outbound HTTPS
- Verify execution role permissions

---

## Getting Help

If you're still stuck:

1. **Check CloudWatch Logs** - Most issues are explained in logs
2. **Review Configuration** - Verify all resources are created correctly
3. **Test Incrementally** - Start with simple commands like `atx custom def list`
4. **Check AWS Service Health** - Verify AWS Batch/ECR/S3 are operational in your region

**Useful Log Patterns:**
```bash
# Search for errors
aws logs filter-log-events \
  --log-group-name /aws/batch/atx-transform \
  --filter-pattern "ERROR"

# Search for specific job
aws logs filter-log-events \
  --log-group-name /aws/batch/atx-transform \
  --filter-pattern "{job-name}"
```
