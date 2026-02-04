#!/bin/bash
set -e

# Logging function with timestamps
log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $1"
}

SOURCE_URL="$1"

if [[ -z "$SOURCE_URL" ]]; then
    log "No source URL provided, skipping download"
    # Create a default working directory for commands that don't need source
    mkdir -p /source/workspace
    cd /source/workspace
    # Initialize empty git repo for ATX CLI compatibility
    git init
    git config user.email "container@aws-transform.local"
    git config user.name "AWS Transform Container"
    echo "workspace" > /tmp/repo_name.txt
    log "Created workspace directory at /source/workspace"
    exit 0
fi

# Clear /source directory
rm -rf /source/*

# Determine if it's a git URL or S3 URL
if [[ "$SOURCE_URL" == s3://* ]]; then
    log "Downloading from S3: $SOURCE_URL"
    
    # Check if it's a ZIP file
    if [[ "$SOURCE_URL" == *.zip ]]; then
        log "Detected ZIP file, downloading and extracting..."
        
        # Extract ZIP filename without extension for folder name
        ZIP_BASENAME=$(basename "$SOURCE_URL" .zip)
        
        # Download ZIP file
        ZIP_FILE="/tmp/source.zip"
        aws s3 cp "$SOURCE_URL" "$ZIP_FILE" --quiet
        
        # Extract ZIP file to /source
        unzip -q "$ZIP_FILE" -d /source/
        rm "$ZIP_FILE"
        
        # Find the extracted directory (could be nested)
        EXTRACTED_DIRS=$(find /source -mindepth 1 -maxdepth 1 -type d)
        DIR_COUNT=$(echo "$EXTRACTED_DIRS" | wc -l)
        
        if [ "$DIR_COUNT" -eq 1 ]; then
            # Single directory extracted, use it
            DIR_NAME=$(basename "$EXTRACTED_DIRS")
            log "Extracted to directory: $DIR_NAME"
            echo "$DIR_NAME" > /tmp/repo_name.txt
        else
            # Multiple files/dirs or no directory, create wrapper with ZIP name
            log "Multiple items extracted, creating '$ZIP_BASENAME' wrapper directory"
            mkdir -p "/source/$ZIP_BASENAME"
            # Move all items into wrapper directory
            find /source -mindepth 1 -maxdepth 1 ! -name "$ZIP_BASENAME" -exec mv {} "/source/$ZIP_BASENAME/" \;
            echo "$ZIP_BASENAME" > /tmp/repo_name.txt
            log "All files moved to /source/$ZIP_BASENAME/"
        fi
    else
        # Regular S3 directory sync
        log "Syncing S3 directory..."
        mkdir -p /source/project
        aws s3 sync "$SOURCE_URL" /source/project/ --quiet
        echo "project" > /tmp/repo_name.txt
    fi
    
elif [[ "$SOURCE_URL" == *.git ]] || [[ "$SOURCE_URL" == *github.com* ]] || [[ "$SOURCE_URL" == *gitlab.com* ]] || [[ "$SOURCE_URL" == *bitbucket.org* ]]; then
    log "Cloning git repository: $SOURCE_URL"
    # Extract repo name for directory
    REPO_NAME=$(basename "$SOURCE_URL" .git)
    git clone "$SOURCE_URL" "/source/$REPO_NAME"
    # Export repo name for use by entrypoint
    echo "$REPO_NAME" > /tmp/repo_name.txt
else
    log "Error: Unsupported source URL format: $SOURCE_URL"
    log "Supported formats:"
    log "  - Git repositories: https://github.com/user/repo.git"
    log "  - S3 directories: s3://bucket-name/path/"
    log "  - S3 ZIP files: s3://bucket-name/path/file.zip"
    exit 1
fi

log "Source code downloaded successfully to /source/"
ls -la /source/