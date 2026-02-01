#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Test all API endpoints with real transformation examples
# Usage: ./test-apis.sh [aws-profile] [region]

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load env from redeploy.sh if exists
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

# Override with args if provided
if [ -n "$1" ]; then
    AWS_PROFILE="$1"
fi
REGION="${2:-${REGION:-us-east-1}}"

export AWS_PROFILE
export AWS_DEFAULT_REGION="$REGION"

# Validate profile
if [ -z "$AWS_PROFILE" ]; then
    echo -e "${RED}Error: AWS profile required. Run redeploy.sh first or provide profile.${NC}"
    echo "Usage: ./test-apis.sh <aws-profile> [region]"
    exit 1
fi

# Validate credentials
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$ACCOUNT_ID" ]; then
    echo -e "${RED}Error: Invalid AWS profile '$AWS_PROFILE'${NC}"
    exit 1
fi

# Get API endpoint if not in env
if [ -z "$API_ENDPOINT" ] || [ "$API_ENDPOINT" == "NOT_FOUND" ]; then
    API_ENDPOINT=$(aws cloudformation describe-stacks \
        --stack-name AtxApiStack \
        --query 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue' \
        --output text 2>/dev/null || echo "")
fi

if [ -z "$API_ENDPOINT" ] || [ "$API_ENDPOINT" == "None" ]; then
    echo -e "${RED}Error: API_ENDPOINT not found. Run redeploy.sh first.${NC}"
    exit 1
fi

# Get source bucket
if [ -z "$SOURCE_BUCKET" ] || [ "$SOURCE_BUCKET" == "NOT_FOUND" ]; then
    SOURCE_BUCKET="atx-source-code-$ACCOUNT_ID"
fi

echo "=============================================="
echo "  ATX API Test Suite - Real Examples"
echo "=============================================="
echo "Profile:      $AWS_PROFILE"
echo "Account:      $ACCOUNT_ID"
echo "Region:       $REGION"
echo "API Endpoint: $API_ENDPOINT"
echo "=============================================="

# Test tracking
TESTS_PASSED=0
TESTS_FAILED=0
RESULTS=()
JOB_IDS=()

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
pass() { 
    echo -e "${GREEN}✓ PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    RESULTS+=("PASS: $1")
}
fail() { 
    echo -e "${RED}✗ FAIL${NC}: $1 - $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    RESULTS+=("FAIL: $1 - $2")
}

# Helper to invoke API
invoke_api() {
    local method="$1"
    local path="$2"
    local data="$3"
    
    if [ -n "$data" ]; then
        AWS_PROFILE="$AWS_PROFILE" python3 "$PROJECT_DIR/utilities/invoke-api.py" \
            --endpoint "$API_ENDPOINT" \
            --method "$method" \
            --path "$path" \
            --data "$data" 2>&1
    else
        AWS_PROFILE="$AWS_PROFILE" python3 "$PROJECT_DIR/utilities/invoke-api.py" \
            --endpoint "$API_ENDPOINT" \
            --method "$method" \
            --path "$path" 2>&1
    fi
}

# ============================================
# TEST 1: Configure MCP Settings (must be first)
# ============================================
echo ""
echo "=============================================="
echo "  TEST 1: Configure MCP Settings"
echo "=============================================="
log "Uploading MCP configuration..."

RESPONSE=$(invoke_api POST "/mcp-config" '{
    "mcpConfig": {
        "mcpServers": {
            "cdk-server": {
                "command": "uvx",
                "args": ["awslabs.cdk-mcp-server@latest"],
                "env": {"FASTMCP_LOG_LEVEL": "ERROR"}
            },
            "aws-docs": {
                "command": "uvx",
                "args": ["awslabs.aws-documentation-mcp-server@latest"],
                "env": {"FASTMCP_LOG_LEVEL": "ERROR"}
            }
        }
    }
}')

echo "$RESPONSE" | head -20

if echo "$RESPONSE" | grep -qE '"status".*success|"message".*saved|"s3Path"'; then
    pass "Configure MCP Settings"
    
    # Test MCP configuration
    log "Testing MCP configuration with 'atx mcp tools'..."
    sleep 2
    
    MCP_TEST_RESPONSE=$(invoke_api POST "/jobs" '{"command": "atx mcp tools"}')
    echo "$MCP_TEST_RESPONSE" | head -20
    
    if echo "$MCP_TEST_RESPONSE" | grep -q '"batchJobId"'; then
        MCP_JOB_ID=$(echo "$MCP_TEST_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('batchJobId',''))" 2>/dev/null || echo "")
        if [ -n "$MCP_JOB_ID" ]; then
            pass "Test MCP Configuration - Job ID: $MCP_JOB_ID"
            JOB_IDS+=("$MCP_JOB_ID")
        else
            fail "Test MCP Configuration" "Could not extract job ID"
        fi
    else
        fail "Test MCP Configuration" "No batchJobId in response"
    fi
else
    fail "Configure MCP Settings" "Unexpected response"
fi

# ============================================
# TEST 2: List Available Transformations (without source)
# ============================================
echo ""
echo "=============================================="
echo "  TEST 2: List Available Transformations"
echo "=============================================="
log "Submitting job to list transformations (no source required)..."

RESPONSE=$(invoke_api POST "/jobs" '{
    "command": "atx custom def list"
}')

echo "$RESPONSE" | head -20

if echo "$RESPONSE" | grep -q '"batchJobId"'; then
    JOB_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('batchJobId',''))" 2>/dev/null || echo "")
    if [ -n "$JOB_ID" ]; then
        pass "List Transformations - Job ID: $JOB_ID"
        JOB_IDS+=("$JOB_ID")
    else
        fail "List Transformations" "Could not extract job ID"
    fi
else
    fail "List Transformations" "No batchJobId in response"
fi

# ============================================
# TEST 3: Python Version Upgrade
# ============================================
echo ""
echo "=============================================="
echo "  TEST 3: Python Version Upgrade"
echo "=============================================="
log "Submitting Python upgrade job for todoapilambda..."

RESPONSE=$(invoke_api POST "/jobs" '{
    "source": "https://github.com/venuvasu/todoapilambda",
    "command": "atx custom def exec -n AWS/python-version-upgrade -p /source/todoapilambda -c noop --configuration \"validationCommands=pytest,additionalPlanContext=The target Python version to upgrade to is Python 3.13. Python 3.13 is already installed at /usr/bin/python3.13\" -x -t"
}')

echo "$RESPONSE" | head -20

if echo "$RESPONSE" | grep -q '"batchJobId"'; then
    JOB_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('batchJobId',''))" 2>/dev/null || echo "")
    if [ -n "$JOB_ID" ]; then
        pass "Python Version Upgrade - Job ID: $JOB_ID"
        JOB_IDS+=("$JOB_ID")
    else
        fail "Python Version Upgrade" "Could not extract job ID"
    fi
else
    fail "Python Version Upgrade" "No batchJobId in response"
fi

# ============================================
# TEST 4: Java Version Upgrade
# ============================================
echo ""
echo "=============================================="
echo "  TEST 4: Java Version Upgrade"
echo "=============================================="
log "Submitting Java upgrade job..."

RESPONSE=$(invoke_api POST "/jobs" '{
    "source": "https://github.com/aws-samples/aws-appconfig-java-sample.git",
    "command": "atx custom def exec -n AWS/java-version-upgrade -p /source/aws-appconfig-java-sample --configuration \"validationCommands=./gradlew clean build test,additionalPlanContext=The target Java version to upgrade to is Java 21. Java 21 is already installed at /usr/lib/jvm/java-21-amazon-corretto\" -x -t"
}')

echo "$RESPONSE" | head -20

if echo "$RESPONSE" | grep -q '"batchJobId"'; then
    JOB_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('batchJobId',''))" 2>/dev/null || echo "")
    if [ -n "$JOB_ID" ]; then
        pass "Java Version Upgrade - Job ID: $JOB_ID"
        JOB_IDS+=("$JOB_ID")
    else
        fail "Java Version Upgrade" "Could not extract job ID"
    fi
else
    fail "Java Version Upgrade" "No batchJobId in response"
fi

# ============================================
# TEST 5: Get Job Status
# ============================================
echo ""
echo "=============================================="
echo "  TEST 5: Get Job Status"
echo "=============================================="

if [ ${#JOB_IDS[@]} -gt 0 ]; then
    sleep 3
    JOB_TO_CHECK="${JOB_IDS[0]}"
    log "Getting status for job: $JOB_TO_CHECK"
    
    RESPONSE=$(invoke_api GET "/jobs/$JOB_TO_CHECK")
    echo "$RESPONSE" | head -25
    
    if echo "$RESPONSE" | grep -q '"status"'; then
        STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
        pass "Get Job Status - Status: $STATUS"
    else
        fail "Get Job Status" "No status in response"
    fi
else
    fail "Get Job Status" "No job ID from previous tests"
fi

# ============================================
# TEST 6: Upload Code & Submit S3 Job
# ============================================
echo ""
echo "=============================================="
echo "  TEST 6: Upload Code (toapilambdanode16)"
echo "=============================================="
log "Cloning toapilambdanode16 and uploading to S3..."

# Clone, zip, and upload
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

if git clone --depth 1 https://github.com/venuvasu/toapilambdanode16.git 2>/dev/null; then
    cd toapilambdanode16
    rm -rf .git
    zip -r ../toapilambdanode16.zip . >/dev/null 2>&1
    cd ..
    
    # Get presigned URL
    log "Getting presigned URL..."
    RESPONSE=$(invoke_api POST "/upload" '{"filename":"toapilambdanode16.zip"}')
    echo "$RESPONSE" | head -10
    
    if echo "$RESPONSE" | grep -q '"uploadUrl"'; then
        UPLOAD_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('uploadUrl',''))" 2>/dev/null || echo "")
        S3_PATH=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('s3Path',''))" 2>/dev/null || echo "")
        
        # Upload file
        log "Uploading ZIP to S3..."
        UPLOAD_RESULT=$(curl -s -w "%{http_code}" -X PUT "$UPLOAD_URL" \
            -H "Content-Type: application/zip" \
            --upload-file toapilambdanode16.zip)
        
        HTTP_CODE="${UPLOAD_RESULT: -3}"
        if [ "$HTTP_CODE" == "200" ]; then
            pass "Upload Code - Uploaded to $S3_PATH"
            
            # Submit Node.js upgrade job using S3 source
            log "Submitting Node.js upgrade job with S3 source..."
            RESPONSE=$(invoke_api POST "/jobs" "{
                \"source\": \"$S3_PATH\",
                \"command\": \"atx custom def exec -n AWS/nodejs-version-upgrade -p /source/toapilambdanode16 --configuration \\\"additionalPlanContext=The target nodejs version to upgrade to is 22. Node.js 22 is already installed at /home/atxuser/.nvm/versions/node/v22.12.0/bin/node\\\" -x -t\"
            }")
            echo "$RESPONSE" | head -15
            
            if echo "$RESPONSE" | grep -q '"batchJobId"'; then
                JOB_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('batchJobId',''))" 2>/dev/null || echo "")
                pass "S3 Source Job (Node.js Upgrade) - Job ID: $JOB_ID"
                JOB_IDS+=("$JOB_ID")
            else
                fail "S3 Source Job" "No batchJobId in response"
            fi
        else
            fail "Upload Code" "HTTP $HTTP_CODE"
        fi
    else
        fail "Upload Code" "No uploadUrl in response"
    fi
else
    fail "Upload Code" "Failed to clone repository"
fi

rm -rf "$TEMP_DIR"
cd "$PROJECT_DIR"

# ============================================
# TEST 7: Bulk Job Submission (Codebase Analysis 2026)
# ============================================
echo ""
echo "=============================================="
echo "  TEST 7: Bulk Job - Codebase Analysis 2026"
echo "=============================================="
log "Submitting batch of 3 codebase analysis jobs..."

RESPONSE=$(invoke_api POST "/jobs/batch" '{
    "batchName": "codebase-analysis-2026",
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
            "source": "https://github.com/aws-samples/aws-appconfig-java-sample",
            "command": "atx custom def exec -n AWS/early-access-comprehensive-codebase-analysis -p /source/aws-appconfig-java-sample -x -t"
        }
    ]
}')

echo "$RESPONSE" | head -20

if echo "$RESPONSE" | grep -q '"batchId"'; then
    BATCH_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('batchId',''))" 2>/dev/null || echo "")
    TOTAL_JOBS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalJobs',''))" 2>/dev/null || echo "")
    pass "Bulk Job Submission - Batch: $BATCH_ID, Jobs: $TOTAL_JOBS"
else
    fail "Bulk Job Submission" "No batchId in response"
fi

# ============================================
# TEST 7b: Individual Job with Campaign
# ============================================
echo ""
echo "=============================================="
echo "  TEST 7b: Codebase Analysis with Campaign"
echo "=============================================="
log "Submitting individual job with campaign..."

RESPONSE=$(invoke_api POST "/jobs" '{
    "source": "https://github.com/spring-projects/spring-petclinic",
    "command": "atx custom def exec --code-repository-path /source/spring-petclinic --non-interactive --trust-all-tools --campaign 0d0c7e9f-5cb2-4569-8c81-7878def8e49e --repo-name spring-petclinic --add-repo"
}')

echo "$RESPONSE" | head -20

if echo "$RESPONSE" | grep -q '"batchJobId"'; then
    JOB_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('batchJobId',''))" 2>/dev/null || echo "")
    if [ -n "$JOB_ID" ]; then
        pass "Codebase Analysis with Campaign - Job ID: $JOB_ID"
        JOB_IDS+=("$JOB_ID")
    else
        fail "Codebase Analysis with Campaign" "Could not extract job ID"
    fi
else
    fail "Codebase Analysis with Campaign" "No batchJobId in response"
fi

# ============================================
# TEST 8: Get Batch Status
# ============================================
echo ""
echo "=============================================="
echo "  TEST 8: Get Batch Status"
echo "=============================================="

if [ -n "$BATCH_ID" ]; then
    sleep 3
    log "Getting batch status: $BATCH_ID"
    
    RESPONSE=$(invoke_api GET "/jobs/batch/$BATCH_ID")
    echo "$RESPONSE" | head -25
    
    if echo "$RESPONSE" | grep -q '"totalJobs"'; then
        TOTAL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalJobs',''))" 2>/dev/null || echo "")
        PROGRESS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('progress',''))" 2>/dev/null || echo "")
        pass "Get Batch Status - Jobs: $TOTAL, Progress: $PROGRESS%"
    else
        fail "Get Batch Status" "No totalJobs in response"
    fi
else
    fail "Get Batch Status" "No batch ID from previous test"
fi

# ============================================
# TEST 9: Terminate Job
# ============================================
echo ""
echo "=============================================="
echo "  TEST 9: Terminate Job"
echo "=============================================="

if [ ${#JOB_IDS[@]} -gt 0 ]; then
    JOB_TO_TERMINATE="${JOB_IDS[0]}"
    log "Terminating job: $JOB_TO_TERMINATE"
    
    RESPONSE=$(invoke_api DELETE "/jobs/$JOB_TO_TERMINATE")
    echo "$RESPONSE" | head -15
    
    if echo "$RESPONSE" | grep -qE '"message"|"status"'; then
        pass "Terminate Job - $JOB_TO_TERMINATE"
    else
        fail "Terminate Job" "Unexpected response"
    fi
else
    fail "Terminate Job" "No job ID to terminate"
fi

# ============================================
# SUMMARY
# ============================================
echo ""
echo "=============================================="
echo "  TEST SUMMARY"
echo "=============================================="
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo ""
echo "Results:"
for result in "${RESULTS[@]}"; do
    if [[ "$result" == PASS* ]]; then
        echo -e "  ${GREEN}$result${NC}"
    else
        echo -e "  ${RED}$result${NC}"
    fi
done
echo ""
echo "Jobs Submitted: ${#JOB_IDS[@]}"
echo "  ${JOB_IDS[*]}"
echo ""
if [ -n "$BATCH_ID" ]; then
    echo "Batch ID: $BATCH_ID"
fi
echo "=============================================="

if [ $TESTS_FAILED -gt 0 ]; then
    exit 1
fi
