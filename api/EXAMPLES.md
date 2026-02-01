# API Examples

Quick reference for using the AWS Transform CLI REST API.

## Prerequisites

**Get API endpoint:**
```bash
API_ENDPOINT="https://{api-id}.execute-api.us-east-1.amazonaws.com/prod"
```

**Authentication:** All requests use AWS IAM authentication via AWS Signature V4.

**Requirements:**
- AWS CLI v2.13+ (for curl --aws-sigv4)
- Or use `utilities/invoke-api.py` helper (works with any AWS CLI version)

---

## Pre-installed Languages

The container includes multiple language versions. Specify installation paths in `additionalPlanContext`:

**Python:** 3.8, 3.9, 3.10, 3.11 (default), 3.12, 3.13 at `/usr/bin/python3.X`

**Java:** 8, 11, 17 (default), 21 at `/usr/lib/jvm/java-X-amazon-corretto`

**Node.js:** 16, 18, 20 (default), 22, 24 via `nvm use X`

---

## 1. Trigger Job

### Example: Python Version Upgrade

```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "https://github.com/venuvasu/todoapilambda",
    "command": "atx custom def exec -n AWS/python-version-upgrade -p /source/todoapilambda -c noop --configuration \"validationCommands=pytest,additionalPlanContext=The target Python version to upgrade to is Python 3.13. Python 3.13 is already installed at /usr/bin/python3.13\" -x -t"
  }'
```

**Using curl (requires AWS CLI v2.13+):**
```bash
curl -X POST "$API_ENDPOINT/jobs" \
  --aws-sigv4 "aws:amz:us-east-1:execute-api" \
  -H "Content-Type: application/json" \
  -d '{
    "source": "https://github.com/venuvasu/todoapilambda",
    "command": "atx custom def exec -n AWS/python-version-upgrade -p /source/todoapilambda -c noop --configuration \"validationCommands=pytest,additionalPlanContext=The target Python version to upgrade to is Python 3.13. Python 3.13 is already installed at /usr/bin/python3.13\" -x -t"
  }'
```

### Example: Java Version Upgrade

```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "https://github.com/aws-samples/aws-appconfig-java-sample.git",
    "command": "atx custom def exec -n AWS/java-version-upgrade -p /source/aws-appconfig-java-sample --configuration \"validationCommands=./gradlew clean build test,additionalPlanContext=The target Java version to upgrade to is Java 21. Java 21 is already installed at /usr/lib/jvm/java-21-amazon-corretto\" -x -t"
  }'
```

### Example: Node.js Upgrade (S3 Source)

```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "s3://atx-source-code-{account}/uploads/nodejs-test/toapilambdanode16.zip",
    "command": "atx custom def exec -n AWS/nodejs-version-upgrade -p /source/toapilambdanode16 --configuration \"additionalPlanContext=The target nodejs version to upgrade to is 22. Node.js 22 is already installed at /home/atxuser/.nvm/versions/node/v22.12.0/bin/node\" -x -t"
  }'
```

### Example: Comprehensive Codebase Analysis

```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "https://github.com/spring-projects/spring-petclinic",
    "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/spring-petclinic -x -t"
  }'
```

### Example: List Available Transformations

```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{
    "source": "https://github.com/spring-projects/spring-petclinic",
    "command": "atx custom def list"
  }'
```

---

## 2. Check Job Status

```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --method GET \
  --path "/jobs/JOB_ID"
```

**Using curl:**
```bash
curl "$API_ENDPOINT/jobs/JOB_ID" \
  --aws-sigv4 "aws:amz:us-east-1:execute-api"
```

**Response:**
```json
{
  "batchJobId": "abc-123",
  "jobName": "spring-petclinic-transform",
  "status": "RUNNING",
  "startedAt": "2025-12-26T20:00:00Z"
}
```

---

## 3. Upload Code (for S3 Source)

### Method 1: Via Upload API

```bash
# Get presigned URL
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/upload" \
  --data '{"filename":"myproject.zip"}'

# Upload file (use uploadUrl from response)
curl -X PUT "$UPLOAD_URL" -H "Content-Type: application/zip" --upload-file myproject.zip

# Use s3Path in job submission
```

### Method 2: Direct S3 Upload

```bash
aws s3 cp myproject.zip s3://atx-source-code-{account}/uploads/myproject/myproject.zip

# Use in job
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{"source":"s3://atx-source-code-{account}/uploads/myproject/myproject.zip","command":"atx ..."}'
```

---

## 4. Bulk Job Submission

```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs/batch" \
  --data '{
    "batchName": "codebase-analysis-2025",
    "jobs": [
      {
        "source": "https://github.com/spring-projects/spring-petclinic",
        "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/spring-petclinic -x -t"
      },
      {
        "source": "https://github.com/venuvasu/todoapilambda",
        "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/todoapilambda -x -t"
      },
      {
        "source": "https://github.com/venuvasu/toapilambdanode16",
        "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/toapilambdanode16 -x -t"
      },
      {
        "source": "https://github.com/aws-samples/aws-appconfig-java-sample",
        "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/aws-appconfig-java-sample -x -t"
      },
      {
        "source": "https://github.com/junit-team/junit5",
        "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/junit5 -x -t"
      }
    ]
  }'
```

**Using curl:**
```bash
curl -X POST "$API_ENDPOINT/jobs/batch" \
  --aws-sigv4 "aws:amz:us-east-1:execute-api" \
  -H "Content-Type: application/json" \
  -d '{
    "batchName": "codebase-analysis-2025",
    "jobs": [
      {"source": "https://github.com/spring-projects/spring-petclinic", "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/spring-petclinic -x -t"},
      {"source": "https://github.com/Netflix/eureka", "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/eureka -x -t"}
    ]
  }'
```

**Check batch status:**
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --method GET \
  --path "/jobs/batch/BATCH_ID"
```

---

## 5. Configure MCP Settings

```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/mcp-config" \
  --data '{
    "mcpConfig": {
      "mcpServers": {
        "fetch": {
          "command": "uvx",
          "args": ["mcp-server-fetch"]
        },
        "github": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-github"]
        }
      }
    }
  }'
```

**Test MCP tools:**
```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --path "/jobs" \
  --data '{"command": "atx mcp tools"}'
```

---

## 6. Terminate Job

```bash
python3 utilities/invoke-api.py \
  --endpoint "$API_ENDPOINT" \
  --method DELETE \
  --path "/jobs/JOB_ID"
```

---

## 7. Monitor Job Logs

```bash
# Get job ID from submission, then monitor
python3 utilities/tail-logs.py JOB_ID --region us-east-1

# Print logs once and exit
python3 utilities/tail-logs.py JOB_ID --no-follow
```

---

## Programmatic Usage (Python)

```python
import boto3
import requests
from requests_aws4auth import AWS4Auth

# Setup authentication
session = boto3.Session()
credentials = session.get_credentials()
auth = AWS4Auth(
    credentials.access_key,
    credentials.secret_key,
    'us-east-1',
    'execute-api',
    session_token=credentials.token
)

# Trigger job
response = requests.post(
    f'{API_ENDPOINT}/jobs',
    json={
        'source': 'https://github.com/aws-samples/aws-java-sample',
        'command': 'atx custom def exec -n AWS/java-aws-sdk-v1-to-v2 -p /source/aws-java-sample -t -c "mvn package"'
    },
    auth=auth
)

print(response.json())
```

---

## Notes

- Job names are auto-generated from source and transformation
- Results stored in: `s3://atx-custom-output-{account}/transformations/{jobName}/{conversationId}/`
- All requests require AWS IAM authentication
- Use `utilities/invoke-api.py` for easy API access
- Use `utilities/tail-logs.py` for log monitoring
