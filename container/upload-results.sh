#!/bin/bash
set -e

# Logging function with timestamps
log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $1"
}

OUTPUT_PATH="$1"
S3_BUCKET="$2"

if [[ -z "$OUTPUT_PATH" ]]; then
    log "Error: Output path is required"
    exit 1
fi

if [[ -z "$S3_BUCKET" ]]; then
    log "Error: S3_BUCKET is required"
    exit 1
fi

# Remove leading/trailing slashes from OUTPUT_PATH
OUTPUT_PATH="${OUTPUT_PATH#/}"
OUTPUT_PATH="${OUTPUT_PATH%/}"

# Construct full S3 URL
S3_BASE_URL="s3://${S3_BUCKET}/${OUTPUT_PATH}"

# Ensure it ends with /
[[ "$S3_BASE_URL" != */ ]] && S3_BASE_URL="${S3_BASE_URL}/"

# Find the conversation ID from ATX logs
# ATX stores logs in ~/.aws/atx/custom/ not ~/.atx/
CONVERSATION_ID=""
if [ -d "$HOME/.aws/atx/custom" ]; then
    # Get the most recent conversation directory
    CONVERSATION_ID=$(ls -t "$HOME/.aws/atx/custom" 2>/dev/null | head -n 1)
fi

# Use conversation ID or generate timestamp-based ID
if [[ -z "$CONVERSATION_ID" ]]; then
    CONVERSATION_ID="job_$(date +"%Y%m%d_%H%M%S")"
    log "No conversation ID found, using: $CONVERSATION_ID"
else
    log "Found conversation ID: $CONVERSATION_ID"
fi

# Create S3 structure: s3://<bucket>/<output-path><conversation-id>/code/ and /logs/
# Note: OUTPUT_PATH should end with / if it's a prefix (e.g., "transformations/")
S3_BASE="${S3_BASE_URL}${CONVERSATION_ID}"
S3_CODE="${S3_BASE}/code/"
S3_LOGS="${S3_BASE}/logs/"

log "Uploading results to S3 structure:"
log "  Base: $S3_BASE"
log "  Code: $S3_CODE"
log "  Logs: $S3_LOGS"

# Upload transformed source code
if [ -d "/source" ] && [ "$(ls -A /source 2>/dev/null)" ]; then
    log "Uploading transformed source code..."
    aws s3 sync /source/ "$S3_CODE" \
        --exclude ".git/*" \
        --exclude ".env*" \
        --exclude "*.pem" \
        --exclude "*.key" \
        --exclude "node_modules/*" \
        --exclude ".aws/*" \
        --exclude "*.log" \
        --quiet
    log "Code uploaded to: $S3_CODE"
else
    log "No source code to upload"
fi

# Upload ATX artifacts and logs
if [ -d "$HOME/.aws/atx" ]; then
    log "Uploading ATX artifacts and logs..."
    aws s3 sync "$HOME/.aws/atx/" "$S3_LOGS" --quiet
    log "Logs uploaded to: $S3_LOGS"
else
    log "No ATX logs found"
fi

log ""
log "Results uploaded successfully!"
log "Conversation ID: $CONVERSATION_ID"
log "S3 Location: $S3_BASE"
log "  - Code: $S3_CODE"
log "  - Logs: $S3_LOGS"