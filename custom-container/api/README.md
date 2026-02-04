# AWS Transform CLI - REST API

REST API for triggering, monitoring, and managing AWS Transform CLI jobs on AWS Batch.

> **Quick Reference:** See [EXAMPLES.md](EXAMPLES.md) for curl examples with AWS Signature V4 and additional usage patterns.

## Quick Start

**Get API endpoint after deployment:**

_If using CDK:_
```bash
cd cdk
npx cdk output AtxApiStack.ApiEndpoint
# Or check the output printed during deployment
```

_If using bash scripts:_
```bash
# Endpoint is printed at end of deployment step 3
# Or check API Gateway console → APIs → atx-transform-api → Stages → prod
```

**Install Python dependencies:**
```bash
pip install boto3 requests
```

**Submit a job:**
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "https://github.com/spring-projects/spring-petclinic",
    "command": "atx custom def list"
  }'
```

**Submit a job without source (for commands that don't need a repository):**
```bash
# List transformations
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "command": "atx custom def list"
  }'

# Test MCP tools
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "command": "atx mcp tools"
  }'
```

**Note:** The `source` field is optional. When omitted, the job name is auto-generated from the command.

**Alternative (using curl with AWS SigV4):**
```bash
# Requires AWS CLI v2.13+
curl --request POST \
  --aws-sigv4 "aws:amz:us-east-1:execute-api" \
  --user "$(aws configure get aws_access_key_id):$(aws configure get aws_secret_access_key)" \
  --header "Content-Type: application/json" \
  --data '{"source":"https://github.com/spring-projects/spring-petclinic","command":"atx custom def list"}' \
  "$API_ENDPOINT/jobs"
```

**Check status:**
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --method GET \
  --path "/jobs/JOB_ID"
```

**See [../README.md](../README.md) for deployment instructions.**

---

## Prerequisites

**Authentication:** AWS IAM with execute-api:Invoke permission

**Grant access:**
```bash
aws iam put-user-policy \
  --user-name YOUR_USERNAME \
  --policy-name InvokeATXApi \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": "execute-api:Invoke",
      "Resource": "arn:aws:execute-api:REGION:ACCOUNT:API_ID/*"
    }]
  }'
```

**Tools:**
- Python 3 with boto3 (for utilities/invoke-api.py)
- OR AWS CLI v2.13+ (for curl --aws-sigv4)

---

## Pre-installed Languages

The container includes multiple language versions. Specify paths in `additionalPlanContext`:

**Python:** 3.8-3.13 at `/usr/bin/python3.X` (default: 3.11)
**Java:** 8, 11, 17, 21 at `/usr/lib/jvm/java-X-amazon-corretto` (default: 17)
**Node.js:** 16, 18, 20, 22, 24 via `nvm use X` (default: 20)

---

## Advanced: Environment Variables and Overrides

### Supported Environment Variables

Pass custom environment variables to the container:

```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "https://github.com/user/repo",
    "command": "atx custom def exec -n MyTransformation -p /source/repo -x -t",
    "environment": {
      "ATX_SHELL_TIMEOUT": "86400",
      "CUSTOM_VAR": "value"
    }
  }'
```

**Available environment variables:**
- `ATX_SHELL_TIMEOUT` - Timeout in seconds for transformation (default: 43200 = 12 hours)
- `S3_BUCKET` - Output bucket name (auto-set by deployment)
- `SOURCE_BUCKET` - Source bucket name (auto-set by deployment)
- `AWS_DEFAULT_REGION` - AWS region (auto-set by deployment)
- Custom variables for your transformation needs

### Resource Overrides

**Note:** Resource overrides (vCPU, memory, timeout) are not currently supported via the REST API. The job uses the default configuration from the job definition (2 vCPU, 4GB RAM, 12-hour timeout).

**For resource overrides, use direct AWS Batch CLI** (see section below).

**To change defaults for all jobs,** modify `cdk.json` or `deployment/config.env` before deployment:
- `fargateVcpu` - vCPU per job (0.25, 0.5, 1, 2, 4, 8, 16)
- `fargateMemory` - Memory in MB (512-30720, must match vCPU)
- `jobTimeout` - Max job duration in seconds

---

## Alternative: Direct AWS Batch CLI

For advanced users who need resource overrides or direct control, use AWS Batch CLI instead of the REST API.

**Security:** Both methods are equally secure - they use IAM permissions and the same job execution role. Direct Batch CLI requires `batch:SubmitJob` permission.

### Basic Job Submission

```bash
aws batch submit-job \
  --job-name "python-upgrade" \
  --job-queue atx-job-queue \
  --job-definition atx-transform-job \
  --container-overrides '{
    "command": [
      "--source", "https://github.com/venuvasu/todoapilambda",
      "--output", "transformations/todoapilambda/",
      "--command", "atx custom def exec -n AWS/python-version-upgrade -p /source/todoapilambda -x -t"
    ]
  }'
```

### With Resource Overrides

```bash
aws batch submit-job \
  --job-name "large-java-upgrade" \
  --job-queue atx-job-queue \
  --job-definition atx-transform-job \
  --container-overrides '{
    "command": [
      "--source", "https://github.com/large/monorepo",
      "--command", "atx custom def exec -n AWS/java-version-upgrade -p /source/monorepo -x -t"
    ],
    "resourceRequirements": [
      {"type": "VCPU", "value": "4"},
      {"type": "MEMORY", "value": "8192"}
    ],
    "environment": [
      {"name": "ATX_SHELL_TIMEOUT", "value": "86400"}
    ]
  }' \
  --timeout attemptDurationSeconds=86400
```

**Available resources:**
- **vCPU:** 0.25, 0.5, 1, 2, 4, 8, 16
- **Memory:** 512-30720 MB (must match vCPU per Fargate requirements)
- **Timeout:** Up to 86400 seconds (24 hours)

**Grant IAM permission:**
```bash
aws iam put-user-policy \
  --user-name YOUR_USERNAME \
  --policy-name SubmitBatchJobs \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["batch:SubmitJob", "batch:DescribeJobs"],
      "Resource": "*"
    }]
  }'
```

---

## API Endpoints

### 1. Trigger Job

Submit a single transformation job.

**Endpoint:** `POST /jobs`

**Request:**
```json
{
  "source": "https://github.com/user/repo.git",
  "command": "atx custom def exec -n AWS/java-aws-sdk-v1-to-v2 -p /source/repo -x -t",
  "jobName": "my-job"  // Optional - auto-generated if not provided
}
```

**Response:**
```json
{
  "batchJobId": "abc-123",
  "jobName": "repo-java-aws-sdk-v1-to-v2",
  "status": "SUBMITTED",
  "submittedAt": "2025-12-27T10:00:00Z"
}
```

**Examples:**

Python version upgrade:
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "https://github.com/venuvasu/todoapilambda",
    "command": "atx custom def exec -n AWS/python-version-upgrade -p /source/todoapilambda -c noop --configuration \"validationCommands=pytest,additionalPlanContext=The target Python version to upgrade to is Python 3.13. Python 3.13 is already installed at /usr/bin/python3.13\" -x -t"
  }'
```



Node.js version upgrade (S3 source):

Note : Make sure you upload the code to s3 (refer below section) before trying the transformation

```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "s3://atx-source-code-{account}/uploads/nodejs-test/toapilambdanode16.zip",
    "command": "atx custom def exec -n AWS/nodejs-version-upgrade -p /source/toapilambdanode16 --configuration \"additionalPlanContext=The target nodejs version to upgrade to is 22. Node.js 22 is already installed at /home/atxuser/.nvm/versions/node/v22.12.0/bin/node\" -x -t"
  }'
```

Comprehensive codebase analysis:
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "https://github.com/spring-projects/spring-petclinic",
    "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/spring-petclinic -x -t"
  }'
```

Comprehensive codebase analysis with campaign:

```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "https://github.com/spring-projects/spring-petclinic",
    "command": "atx custom def exec --code-repository-path /source/spring-petclinic --non-interactive --trust-all-tools --campaign <your-campaign-id> --repo-name spring-petclinic --add-repo"
  }'
```


Java version upgrade:
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "https://github.com/aws-samples/aws-appconfig-java-sample.git",
    "command": "atx custom def exec -n AWS/java-version-upgrade -p /source/aws-appconfig-java-sample --configuration \"validationCommands=./gradlew clean build test,additionalPlanContext=The target Java version to upgrade to is Java 21. Java 21 is already installed at /usr/lib/jvm/java-21-amazon-corretto\" -x -t"
  }'
```

---

### 2. Get Job Status

Query status of a running or completed job.

**Endpoint:** `GET /jobs/{jobId}`

**Response:**
```json
{
  "batchJobId": "abc-123",
  "jobName": "my-job",
  "status": "RUNNING",
  "startedAt": "2025-12-27T10:00:00Z",
  "container": {
    "logStreamName": "atx/default/xxx"
  }
}
```

**Example:**
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --method GET \
  --path "/jobs/JOB_ID"
```

---

### 3. Upload Code

Upload source code as ZIP for S3-based transformations.

**Endpoint:** `POST /upload`

**Request:**
```json
{
  "filename": "myproject.zip"
}
```

**Response:**
```json
{
  "uploadUrl": "https://s3.../presigned-url",
  "s3Path": "s3://atx-source-code-{account}/uploads/{id}/myproject.zip"
}
```

**Method 1: Via presigned URL**
```bash
# Get URL
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/upload" \
  --data '{"filename":"myproject.zip"}'

# Upload
curl -X PUT "$UPLOAD_URL" -H "Content-Type: application/zip" --upload-file myproject.zip
```

**Method 2: Direct S3 upload**
```bash
aws s3 cp myproject.zip s3://atx-source-code-{account}/uploads/myproject/myproject.zip
```

---

### 4. Bulk Job Submission

Submit multiple jobs in a single request (1000s of repos).

**Endpoint:** `POST /jobs/batch`

**Request:**
```json
{
  "batchName": "my-batch",
  "jobs": [
    {"source": "https://github.com/org/repo1", "command": "atx ..."},
    {"source": "https://github.com/org/repo2", "command": "atx ..."}
  ]
}
```

**Response:**
```json
{
  "batchId": "batch-20251227-100000",
  "status": "PROCESSING",
  "totalJobs": 2
}
```

**Example:**
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs/batch" \
  --data '{
    "batchName": "codebase-analysis-2026",
    "jobs": [
      {"source": "https://github.com/spring-projects/spring-petclinic", "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/spring-petclinic -x -t"},
      {"source": "https://github.com/venuvasu/todoapilambda", "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/todoapilambda -x -t"},
      {"source": "https://github.com/venuvasu/toapilambdanode16", "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/toapilambdanode16 -x -t"}
    ]
  }'
```

---

### 4b. Bulk Job Submission with Campaign

Submit multiple repositories to a single campaign for centralized tracking and management.

**Endpoint:** `POST /jobs/batch`

**Benefits:**
- Track all transformations under one campaign ID
- Centralized reporting and analytics
- Easier management of related repositories

**Example:**
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs/batch" \
  --data '{
    "batchName": "codebase-analysis-campaign-2026",
    "jobs": [
      {
        "source": "https://github.com/spring-projects/spring-petclinic",
        "command": "atx custom def exec --code-repository-path /source/spring-petclinic --non-interactive --trust-all-tools --campaign <your-campaign-id> --repo-name spring-petclinic --add-repo"
      },
      {
        "source": "https://github.com/venuvasu/todoapilambda",
        "command": "atx custom def exec --code-repository-path /source/todoapilambda --non-interactive --trust-all-tools --campaign <your-campaign-id> --repo-name todoapilambda --add-repo"
      },
      {
        "source": "https://github.com/venuvasu/toapilambdanode16",
        "command": "atx custom def exec --code-repository-path /source/toapilambdanode16 --non-interactive --trust-all-tools --campaign <your-campaign-id> --repo-name toapilambdanode16 --add-repo"
      }
    ]
  }'
```

**Campaign Parameters:**
- `--campaign <id>` - Campaign UUID for grouping transformations
- `--repo-name <name>` - Repository identifier within the campaign
- `--add-repo` - Add this repository to the campaign
- `--code-repository-path` - Full path to repository (replaces `-p`)
- `--non-interactive` - Run without user prompts (replaces `-x`)
- `--trust-all-tools` - Trust all tools automatically (replaces `-t`)

---

### 5. Get Batch Status

Get aggregated status of all jobs in a batch.

**Endpoint:** `GET /jobs/batch/{batchId}`

**Response:**
```json
{
  "batchId": "batch-20251227-100000",
  "status": "RUNNING",
  "progress": 45.5,
  "totalJobs": 1000,
  "statusCounts": {
    "RUNNING": 195,
    "SUCCEEDED": 432,
    "FAILED": 23
  }
}
```

**Example:**
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --method GET \
  --path "/jobs/batch/BATCH_ID"
```

---

### 6. Configure MCP Settings

Upload MCP (Model Context Protocol) configuration.

**Endpoint:** `POST /mcp-config`

**Request:**
```json
{
  "mcpConfig": {
    "mcpServers": {
      "github": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-github"]
      }
    }
  }
}
```

**Example:**
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/mcp-config" \
  --data '{
    "mcpConfig": {
      "mcpServers": {
        "fetch": {"command": "uvx", "args": ["mcp-server-fetch"]},
        "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"]}
      }
    }
  }'
```

**Test MCP:**
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{"command": "atx mcp tools"}'
```

---

### 7. Terminate Job

Stop a running job.

**Endpoint:** `DELETE /jobs/{jobId}`

**Response:**
```json
{
  "message": "Job termination initiated",
  "jobId": "abc-123",
  "previousStatus": "RUNNING"
}
```

**Example:**
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --method DELETE \
  --path "/jobs/JOB_ID"
```

---

## Utilities

### invoke-api.py

Python helper for API invocation with automatic IAM signing.

**Usage:**
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{"source":"...","command":"..."}'
```

**Options:**
- `--method` - HTTP method (default: POST)
- `--data` - JSON data
- Reads from stdin if no --data

### tail-logs.py

Monitor job logs in real-time.

**Usage:**
```bash
python3 utilities/tail-logs.py JOB_ID --region us-east-1

# Options
python3 utilities/tail-logs.py JOB_ID --no-follow  # Print once and exit
```

---

## Using curl (Alternative)

If you have AWS CLI v2.13+, you can use curl:

```bash
curl -X POST "$API_ENDPOINT/jobs" \
  --aws-sigv4 "aws:amz:us-east-1:execute-api" \
  -H "Content-Type: application/json" \
  -d '{"source":"https://github.com/...","command":"atx ..."}'
```

**Note:** Requires AWS CLI v2.13+ and proper AWS credential configuration.

---

## Programmatic Usage (Python)

```python
import boto3
import requests
from requests_aws4auth import AWS4Auth

session = boto3.Session()
credentials = session.get_credentials()
auth = AWS4Auth(
    credentials.access_key,
    credentials.secret_key,
    'us-east-1',
    'execute-api',
    session_token=credentials.token
)

response = requests.post(
    f'{API_ENDPOINT}/jobs',
    json={'source': '...', 'command': '...'},
    auth=auth
)
```

---

## Troubleshooting

**403 Forbidden:**
- Check IAM permissions (execute-api:Invoke)
- Verify API Gateway resource ARN

**Job fails to start:**
- Check Batch queue and compute environment status
- Verify IAM roles (ATXBatchJobRole)

**Missing Authentication Token:**
- Ensure AWS credentials are configured
- Check AWS_PROFILE environment variable

---

## Notes

- Job names auto-generated from source and transformation
- Results: `s3://atx-custom-output-{account}/transformations/{jobName}/{conversationId}/`
- Logs: CloudWatch `/aws/batch/atx-transform`
- Dashboard: ATX-Transform-CLI-Dashboard

---

## Results and Downloads

### S3 Output Structure

Results are organized by job name and conversation ID:

```
s3://atx-custom-output-{account-id}/
└── transformations/
    └── {job-name}/                           # e.g., guava-early-access-comprehensive-codebase-analysis
        └── {timestamp}_{conversation-id}/    # e.g., 20251227_051626_8f344f5f
            ├── code/                         # Full source code + transformed changes
            └── logs/                         # Execution logs and artifacts
                └── custom/
                    └── {timestamp}_{conversation-id}/
                        └── artifacts/
                            └── validation_summary.md
```

### Download Examples

**Download all results for a specific job:**
```bash
aws s3 sync s3://atx-custom-output-{account-id}/transformations/{job-name}/{timestamp}_{conversation-id}/ ./local-results/
```

**Download just the validation summary:**
```bash
aws s3 cp s3://atx-custom-output-{account-id}/transformations/{job-name}/{timestamp}_{conversation-id}/logs/custom/{timestamp}_{conversation-id}/artifacts/validation_summary.md ./
```

**Download transformed code only:**
```bash
aws s3 sync s3://atx-custom-output-{account-id}/transformations/{job-name}/{timestamp}_{conversation-id}/code/ ./transformed-code/
```

### Validation Summary

AWS Transform CLI generates a validation summary showing all changes made:

**Location:** `s3://atx-custom-output-{account-id}/transformations/{job-name}/{timestamp}_{conversation-id}/logs/custom/{timestamp}_{conversation-id}/artifacts/validation_summary.md`

**Contains:**
- Summary of all code changes
- Files modified, added, or deleted
- Validation results
- Transformation statistics

---

## Monitoring and Dashboard

### CloudWatch Dashboard

The solution includes a CloudWatch dashboard with operational metrics:

**Dashboard Name:** `ATX-Transform-CLI-Dashboard`

**Job Tracking:**
- Completion rate with hourly trends (completed vs failed)
- Recent jobs table showing job name, timestamp, last message, and log stream
- Real-time visibility into job execution

**API and Lambda Health:**
- API Gateway request counts and error rates
- Lambda invocation metrics per function
- Performance monitoring (duration by function)

### CloudWatch Logs

All logs are centralized in CloudWatch Logs (`/aws/batch/atx-transform`) with real-time streaming.

**View logs via AWS CLI:**
```bash
aws logs tail /aws/batch/atx-transform --follow --region us-east-1
```

**Use the included utility:**
```bash
python3 utilities/tail-logs.py JOB_ID --region us-east-1
```

**View in AWS Console:** CloudWatch → Log Groups → `/aws/batch/atx-transform`
