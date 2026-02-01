#!/bin/bash
set -e

# Initialize nvm for Node.js
export NVM_DIR="/home/atxuser/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Cleanup function
cleanup() {
    rm -f /tmp/repo_name.txt
}
trap cleanup EXIT

# Logging function with timestamps
log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $1"
}

# Retry function for network operations
retry() {
    local max_attempts=3
    local timeout=5
    local attempt=1
    local exitCode=0

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        else
            exitCode=$?
        fi

        if [ $attempt -lt $max_attempts ]; then
            log "Command failed (attempt $attempt/$max_attempts). Retrying in $timeout seconds..."
            sleep $timeout
            timeout=$((timeout * 2))
        fi
        attempt=$((attempt + 1))
    done

    log "Command failed after $max_attempts attempts."
    return $exitCode
}

# Function to refresh IAM role credentials (for long-running jobs)
refresh_credentials() {
    # Only refresh if we're using IAM role (not explicit credentials)
    if [[ -z "${USING_EXPLICIT_CREDS:-}" ]]; then
        log "Refreshing temporary credentials from IAM role..."
        
        TEMP_CREDS=$(aws configure export-credentials --format env 2>/dev/null)
        
        if [[ $? -eq 0 && -n "$TEMP_CREDS" ]]; then
            # Source the credentials directly to export them
            eval "$TEMP_CREDS"
            
            # Also configure AWS CLI with these credentials
            aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
            aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
            if [[ -n "$AWS_SESSION_TOKEN" ]]; then
                aws configure set aws_session_token "$AWS_SESSION_TOKEN"
            fi
            
            log "Credentials refreshed successfully"
        else
            log "Warning: Failed to refresh credentials, continuing with existing credentials"
        fi
    fi
}

# Parse arguments
SOURCE=""
OUTPUT=""
COMMAND=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --source)
            SOURCE="$2"
            shift 2
            ;;
        --output)
            OUTPUT="$2"
            shift 2
            ;;
        --command)
            COMMAND="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: [--source <git-url|s3-url>] --output <s3-bucket-url> --command <atx-command>"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$COMMAND" ]]; then
    echo "Error: Missing required arguments"
    echo "Usage: [--source <git-url|s3-url>] [--output <s3-path>] --command <atx-command>"
    echo ""
    echo "Environment Variables:"
    echo "  S3_BUCKET - S3 bucket name for output (required if --output is specified)"
    echo ""
    echo "Examples:"
    echo "  --command \"atx custom def list\""
    echo "  --source https://github.com/user/repo.git --output results/job1/ --command \"atx custom def exec\""
    echo "  With S3_BUCKET=my-bucket, output goes to s3://my-bucket/results/job1/"
    exit 1
fi

# Check if output is specified and S3_BUCKET is set
if [[ -n "$OUTPUT" && -z "$S3_BUCKET" ]]; then
    echo "Error: S3_BUCKET environment variable must be set when using --output"
    echo "Example: docker run -e S3_BUCKET=my-bucket ... --output results/job1/"
    exit 1
fi

log "Starting AWS Transform CLI execution..."
log "Source: $SOURCE"
log "Output: $OUTPUT"
log "Command: $COMMAND"

# Set global git configuration for ATX
log "Configuring git identity for ATX..."
git config --global user.email "${GIT_USER_EMAIL:-atx-container@aws-transform.local}"
git config --global user.name "${GIT_USER_NAME:-AWS Transform Container}"

# Set ATX shell timeout for long-running jobs (default: 12 hours)
export ATX_SHELL_TIMEOUT="${ATX_SHELL_TIMEOUT:-43200}"
log "Set ATX_SHELL_TIMEOUT=$ATX_SHELL_TIMEOUT for long-running transformations"

# Configure AWS credentials for ATX CLI
# ATX CLI requires credentials as environment variables
if [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]]; then
    log "Using explicit AWS credentials from environment variables"
    export USING_EXPLICIT_CREDS=true
    aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
    aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
    aws configure set region "${AWS_DEFAULT_REGION:-us-east-1}"
    
    if [[ -n "$AWS_SESSION_TOKEN" ]]; then
        aws configure set aws_session_token "$AWS_SESSION_TOKEN"
    fi
else
    log "No explicit credentials found, retrieving temporary credentials from IAM role..."
    
    # Verify IAM role is available
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
        log "Error: No credentials available (neither environment variables nor IAM role)"
        exit 1
    fi
    
    # Retrieve temporary credentials from IAM role (EC2 instance profile, ECS task role, or Batch job role)
    log "Retrieving temporary credentials from IAM role..."
    
    # Use AWS CLI to export credentials from the credential chain
    # The aws configure export-credentials command outputs in env format
    TEMP_CREDS=$(aws configure export-credentials --format env 2>/dev/null)
    
    if [[ $? -eq 0 && -n "$TEMP_CREDS" ]]; then
        # Source the credentials directly to export them
        eval "$TEMP_CREDS"
        
        # Verify credentials were exported
        if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
            log "Error: Failed to export credentials from IAM role"
            log "TEMP_CREDS output: $TEMP_CREDS"
            exit 1
        fi
        
        # Also configure AWS CLI with these credentials for consistency
        aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
        aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
        aws configure set region "${AWS_DEFAULT_REGION:-us-east-1}"
        if [[ -n "$AWS_SESSION_TOKEN" ]]; then
            aws configure set aws_session_token "$AWS_SESSION_TOKEN"
        fi
        
        log "Successfully retrieved and exported temporary credentials from IAM role"
        
        # Log the role ARN for debugging (without exposing credentials)
        ROLE_ARN=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo "Unable to retrieve role ARN")
        log "Using IAM role: $ROLE_ARN"
    else
        log "Error: Failed to retrieve credentials from IAM role"
        exit 1
    fi
fi

# Verify AWS credentials are working with retry
log "Verifying AWS credentials..."
log "AWS_ACCESS_KEY_ID is set: $([ -n "$AWS_ACCESS_KEY_ID" ] && echo 'yes' || echo 'no')"
log "AWS_SECRET_ACCESS_KEY is set: $([ -n "$AWS_SECRET_ACCESS_KEY" ] && echo 'yes' || echo 'no')"
log "AWS_SESSION_TOKEN is set: $([ -n "$AWS_SESSION_TOKEN" ] && echo 'yes' || echo 'no')"

retry aws sts get-caller-identity || {
    log "Error: Unable to authenticate with AWS after multiple attempts"
    exit 1
}
log "AWS credentials verified successfully"

# ============================================================================
# PRIVATE REPOSITORY ACCESS (Optional - RECOMMENDED)
# ============================================================================
# Fetch credentials from AWS Secrets Manager for private repositories
# This is the RECOMMENDED approach (credentials never stored in image)
#
# Uncomment and customize the secret names for your environment:
#
# fetch_private_credentials() {
#     log "Fetching private repository credentials from Secrets Manager..."
#     
#     # GitHub token for private repos
#     GITHUB_TOKEN=$(aws secretsmanager get-secret-value \
#         --secret-id "atx/github-token" --query SecretString --output text 2>/dev/null || true)
#     if [[ -n "$GITHUB_TOKEN" ]]; then
#         echo "https://${GITHUB_TOKEN}@github.com" > /home/atxuser/.git-credentials
#         git config --global credential.helper store
#         log "✓ GitHub credentials configured"
#     fi
#     
#     # npm token for private packages
#     NPM_TOKEN=$(aws secretsmanager get-secret-value \
#         --secret-id "atx/npm-token" --query SecretString --output text 2>/dev/null || true)
#     if [[ -n "$NPM_TOKEN" ]]; then
#         echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > /home/atxuser/.npmrc
#         log "✓ npm credentials configured"
#     fi
#     
#     # Maven credentials for private artifacts
#     MAVEN_USER=$(aws secretsmanager get-secret-value \
#         --secret-id "atx/maven-user" --query SecretString --output text 2>/dev/null || true)
#     MAVEN_PASS=$(aws secretsmanager get-secret-value \
#         --secret-id "atx/maven-pass" --query SecretString --output text 2>/dev/null || true)
#     if [[ -n "$MAVEN_USER" && -n "$MAVEN_PASS" ]]; then
#         cat > /home/atxuser/.m2/settings.xml <<EOF
# <settings>
#   <servers>
#     <server>
#       <id>company-repo</id>
#       <username>${MAVEN_USER}</username>
#       <password>${MAVEN_PASS}</password>
#     </server>
#   </servers>
# </settings>
# EOF
#         log "✓ Maven credentials configured"
#     fi
# }
# 
# fetch_private_credentials
# ============================================================================

# Download MCP configuration from S3 if available
log "Checking for MCP configuration..."
MCP_CONFIG_KEY="mcp-config/mcp.json"
MCP_CONFIG_PATH="/home/atxuser/.aws/atx/mcp.json"

# SOURCE_BUCKET is set as environment variable in job definition
if [ -n "$SOURCE_BUCKET" ] && aws s3 ls "s3://$SOURCE_BUCKET/$MCP_CONFIG_KEY" &>/dev/null; then
    log "MCP configuration found in S3, downloading..."
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$MCP_CONFIG_PATH")"
    
    # Download MCP config
    if aws s3 cp "s3://$SOURCE_BUCKET/$MCP_CONFIG_KEY" "$MCP_CONFIG_PATH" --quiet; then
        # Set proper ownership
        chown atxuser:atxuser "$MCP_CONFIG_PATH"
        chmod 644 "$MCP_CONFIG_PATH"
        log "MCP configuration downloaded successfully to $MCP_CONFIG_PATH"
    else
        log "Warning: Failed to download MCP configuration, continuing without it"
    fi
else
    log "No MCP configuration found in S3, using default ATX settings"
fi

# Start background credential refresh for long-running jobs (every 45 minutes)
# Only if using IAM role credentials (not explicit credentials)
if [[ -z "${USING_EXPLICIT_CREDS:-}" ]]; then
    log "Starting background credential refresh (every 45 minutes) for long-running transformations..."
    (
        while true; do
            sleep 2700  # 45 minutes
            refresh_credentials
        done
    ) &
    REFRESH_PID=$!
    log "Credential refresh background process started (PID: $REFRESH_PID)"
fi

# ============================================================================
# CUSTOM INITIALIZATION (Optional)
# ============================================================================
# If you've extended this container with custom configurations, they're already
# set up from your Dockerfile (e.g., .npmrc, settings.xml, .git-credentials).
# 
# Add any runtime-specific initialization here if needed:
# - Additional environment variables
# - Dynamic credential retrieval
# - Custom tool initialization
#
# See container/README.md for extending the base image with private repo access.
# ============================================================================


# Download source code if provided
if [[ -n "$SOURCE" ]]; then
    log "Downloading source code..."
    retry /app/download-source.sh "$SOURCE"
    
    # Get the repo/project directory name
    REPO_NAME=$(cat /tmp/repo_name.txt)
    PROJECT_PATH="/source/$REPO_NAME"
    
    # Initialize git repo if not present
    cd "$PROJECT_PATH"
    if [ ! -d ".git" ]; then
        log "Initializing git repository..."
        git init
        git config user.email "${GIT_USER_EMAIL:-container@aws-transform.local}"
        git config user.name "${GIT_USER_NAME:-AWS Transform Container}"
        git add .
        git commit -m "Initial commit"
    fi
    
    # Smart -p flag handling
    # Only replace -p if it exists in the original command
    if [[ "$COMMAND" == *" -p "* ]] || [[ "$COMMAND" == *" --project-path "* ]]; then
        log "Detected -p flag in command, replacing with container path"
        # Remove existing -p and its value
        COMMAND=$(echo "$COMMAND" | sed 's/-p [^ ]*//g' | sed 's/--project-path [^ ]*//g')
        # Add correct -p flag with container path
        COMMAND="$COMMAND -p $PROJECT_PATH"
        log "Replaced with: -p $PROJECT_PATH"
    else
        log "No -p flag in command, ATX will use current directory"
    fi
    
    # Execute the ATX command
    # Note: Using eval here is intentional to support complex commands with pipes/redirects
    # COMMAND should only come from trusted sources (AWS Batch job definition)
    log "Executing command: $COMMAND"
    eval "$COMMAND"
else
    # Execute command without source (e.g., atx custom def list)
    # Note: Using eval here is intentional to support complex commands with pipes/redirects
    # COMMAND should only come from trusted sources (AWS Batch job definition)
    log "Executing command (no source code): $COMMAND"
    mkdir -p /source
    cd /source
    eval "$COMMAND"
fi

# Upload results if output is specified
if [[ -n "$OUTPUT" ]]; then
    log "Uploading results..."
    retry /app/upload-results.sh "$OUTPUT" "$S3_BUCKET"
else
    log "No output specified, skipping S3 upload"
fi

# ============================================================================
# CUSTOM POST-TRANSFORMATION ACTIONS (Optional)
# ============================================================================
# After transformation and S3 upload, create PR and push changes to remote.
#
# Option 1: Script-based PR creation (add git credentials in Dockerfile)
# ----------------------------------------------------------------------------
# if [[ -n "$SOURCE" ]] && [[ -n "$GIT_REMOTE_URL" ]]; then
#     log "Creating PR and pushing changes to remote..."
#     cd "$PROJECT_PATH"
#     
#     # AWS Transform CLI auto-creates a branch for changes
#     CURRENT_BRANCH=$(git branch --show-current)
#     log "Current branch: $CURRENT_BRANCH"
#     
#     git add .
#     git commit -m "Automated transformation by AWS Transform CLI" || true
#     git push "$GIT_REMOTE_URL" "$CURRENT_BRANCH"
#     
#     # Create PR using GitHub CLI (install gh in Dockerfile)
#     # gh pr create --title "Automated transformation" --body "..." --base main
# fi
#
# Option 2: Use AWS Transform Custom Definition with MCP (Recommended)
# ----------------------------------------------------------------------------
# Use a Custom Transformation definition along with PR creation using MCP
# connecting to your git repos for more sophisticated workflows.
# ============================================================================

log "AWS Transform CLI execution completed successfully!"