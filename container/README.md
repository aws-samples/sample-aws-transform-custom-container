# Container - All Languages Included

Production-ready container with Java, Python, Node.js, and all common tools pre-installed.

## What's Included

### Java
- **Versions:** Amazon Corretto 8, 11, 17, 21
- **Build Tools:** Maven 3.8.4, Gradle 8.5
- **Default:** Java 17 ✓

### Python
- **Versions:** Python 3.8, 3.9, 3.10, 3.11, 3.12, 3.13
- **System Python:** 3.9 (used by AWS CLI)
- **Available:** `python3.11`, `python3.12`, `python3.13` (direct access)
- **Via pyenv:** 3.8, 3.9, 3.10 (use `pyenv shell 3.8.18`)
- **Tools:** pip, virtualenv, uv
- **Packages:** boto3, botocore, requests
- **Note:** Use `python3.11` or higher for MCP servers ✓

### Node.js
- **Versions:** Node.js 16, 18, 20, 22, 24 (via nvm)
- **Package Managers:** npm, yarn, pnpm
- **Tools:** TypeScript, ts-node
- **Default:** Node.js 20 ✓
- **Switch versions:** `nvm use 22`

### Other Tools
- **AWS CLI v2** (official installer)
- **AWS Transform CLI**
- **Git**
- **Build essentials** (gcc, make, etc.)
- **Base OS:** Amazon Linux 2023

---

## When to Customize

**You DON'T need to customize if:**
- ✅ Using public repositories
- ✅ Using standard language versions (Java 17, Python 3.11, Node.js 20)
- ✅ Using public package registries (Maven Central, PyPI, npm)

**You NEED to customize if:**
- ❌ Accessing private Git repositories
- ❌ Using private artifact registries (Maven, npm, PyPI)
- ❌ Need additional tools or languages
- ❌ Need specific language versions not in defaults

---

## Private Repository Access

For accessing private Git repositories or artifact registries during transformations:

### Option 1: AWS Secrets Manager (RECOMMENDED)

Store credentials in Secrets Manager and fetch at runtime. Credentials never stored in image.

**1. Create secrets:**
```bash
# GitHub token
aws secretsmanager create-secret \
  --name atx/github-token \
  --secret-string "ghp_your_token_here"

# npm token
aws secretsmanager create-secret \
  --name atx/npm-token \
  --secret-string "npm_your_token_here"
```

**2. Grant IAM role access:**
```bash
# Add to ATXBatchJobRole policy
aws iam put-role-policy --role-name ATXBatchJobRole --policy-name SecretsAccess --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "secretsmanager:GetSecretValue",
    "Resource": "arn:aws:secretsmanager:*:*:secret:atx/*"
  }]
}'
```

**3. Uncomment placeholder in `container/entrypoint.sh`:**
```bash
# Find the "PRIVATE REPOSITORY ACCESS" section
# Uncomment the fetch_private_credentials() function and call
```

**4. Redeploy container:**

_If using CDK:_
```bash
cd cdk && ./deploy.sh
```

_If using bash scripts:_
```bash
cd deployment
./1-build-and-push.sh --rebuild
./2-deploy-infrastructure.sh
```

### Option 2: Hardcode in Dockerfile (NOT RECOMMENDED)

⚠️ **Security Risk**: Tokens permanently stored in image layers

Only use for testing or if you understand the risks. 

**1. Uncomment placeholder in `container/Dockerfile`:**
```bash
# Find the "PRIVATE REPOSITORY ACCESS" section
# Uncomment the credentials you need (GitHub, npm, Maven, etc.)
```

**2. Redeploy container:**

_If using CDK:_
```bash
cd cdk && ./deploy.sh
```

_If using bash scripts:_
```bash
cd deployment
./1-build-and-push.sh --rebuild
./2-deploy-infrastructure.sh
```

See "Detailed Examples" section below for complete examples.

---

## Redeploying After Customization

After customizing `Dockerfile` or `entrypoint.sh`:

**If using CDK:**
```bash
cd cdk && ./deploy.sh
```

CDK automatically detects Dockerfile changes and rebuilds. If changes aren't detected, force rebuild:
```bash
cd cdk && ./deploy.sh --force
```

**If using bash scripts:**
```bash
cd deployment
./1-build-and-push.sh --rebuild
./2-deploy-infrastructure.sh
```

---

## Files

- **Dockerfile** - Complete container definition with all languages
- **entrypoint.sh** - Container entry point with credential management
- **download-source.sh** - Source code download logic
- **upload-results.sh** - S3 upload logic with security exclusions
- **helpers/** - Version switching scripts (optional)

## Container Arguments

```bash
docker run aws-transform-cli \
  [--source <git-url|s3-url>] \
  [--output <s3-path>] \
  --command <atx-command>
```

**Arguments:**
- `--source` (optional): Git repo or S3 bucket with source code
- `--output` (optional): S3 path for results (requires S3_BUCKET env var)
- `--command` (required): ATX CLI command to execute

**Environment Variables:**
- `S3_BUCKET` - S3 bucket name for output (results storage)
- `SOURCE_BUCKET` - S3 bucket name for source code uploads and MCP config (optional)
- `AWS_ACCESS_KEY_ID` - AWS access key (or use IAM role)
- `AWS_SECRET_ACCESS_KEY` - AWS secret key (or use IAM role)
- `AWS_DEFAULT_REGION` - AWS region (default: us-east-1)
- `ATX_SHELL_TIMEOUT` - Timeout in seconds (default: 43200 = 12 hours)

## Building Locally (Optional)

```bash
cd container
docker build -t aws-transform-cli .
```

**Build time:** ~15-18 minutes (one-time)
**Image size:** ~3.5GB

## Testing Locally (Optional)

```bash
# Test with explicit credentials
docker run --rm \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e AWS_SESSION_TOKEN \
  aws-transform-cli \
  --command "atx --version"

# Test with source code
docker run --rm \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e S3_BUCKET=my-bucket \
  aws-transform-cli \
  --source "https://github.com/user/repo.git" \
  --output "results/" \
  --command "atx custom def exec -n MyDefinition -c noop -x -t"
```

## Supported Transformations

This container supports all AWS-managed transformations:

### Java
- ✅ **AWS/java-aws-sdk-v1-to-v2** - Upgrade AWS SDK from v1 to v2
- ✅ Java version upgrades (8→11, 11→17, 17→21)
- ✅ Maven and Gradle project support

### Python
- ✅ **AWS/python-boto2-to-boto3** - Migrate from boto2 to boto3
- ✅ Python version upgrades (3.8→3.11, 3.11→3.12, etc.)

### Node.js
- ✅ **AWS/nodejs-aws-sdk-v2-to-v3** - Upgrade AWS SDK from v2 to v3
- ✅ Node.js version upgrades (16→18, 18→20, 20→22, etc.)
- ✅ TypeScript support

### Custom
- ✅ Any custom transformation definitions
- ✅ Comprehensive codebase analysis

## Advanced: Version Switching (Optional)

**Most users don't need this** - the defaults (Java 17, Python 3.11, Node.js 20) work for 90% of cases.

If your codebase requires a specific version, set environment variables:

```bash
aws batch submit-job \
  --container-overrides '{
    "environment": [
      {"name": "JAVA_VERSION", "value": "8"},      # For legacy Java 8
      {"name": "PYTHON_VERSION", "value": "13"},   # For Python 3.13
      {"name": "NODE_VERSION", "value": "22"}      # For Node.js 22
    ]
  }'
```

**Available versions:**
- Java: 8, 11, 17, 21
- Python: 8, 9, 10, 11, 12, 13 (refers to 3.8, 3.9, etc.)
- Node.js: 16, 18, 20, 22, 24

### Helper Commands (For Interactive Use)

If running the container interactively:

```bash
# Show all installed versions
show-versions

# Switch versions
use-java 21
use-python 13
use-node 22
```

## Security

- **Non-root execution:** Container runs as `atxuser` (UID 1000)
- **IAM role credentials:** Automatic retrieval from Batch job role
- **Credential refresh:** Every 30 minutes for long-running jobs
- **S3 security exclusions:** .git, .env, credentials files excluded from uploads
- **Base image:** Amazon Linux 2023 from public.ecr.aws/amazonlinux/amazonlinux:2023

## Next Steps

After customizing the container (if needed):

1. **Deploy:** See [../deployment/README.md](../deployment/README.md) or [../cdk/README.md](../cdk/README.md) for deployment instructions
2. **Test:** Run `cd ../test && ./test-apis.sh` to validate all endpoints
3. **Monitor:** View logs in CloudWatch Console or use `python3 ../utilities/tail-logs.py <job-id>`

---

## Detailed Examples

**Note:** This section provides detailed examples for reference. For actual implementation, use the commented placeholders in `Dockerfile` and `entrypoint.sh` as described in the "Private Repository Access" section above.

The examples below show the syntax for various package managers and registries. Simply uncomment the relevant sections in the source files rather than creating separate files.

### Private Git Repositories

**Use case:** Clone private repos during transformation

**Create `Dockerfile.custom`:**
```dockerfile
FROM {account}.dkr.ecr.us-east-1.amazonaws.com/aws-transform-cli:latest

# Configure Git credentials (use Personal Access Token)
RUN git config --global credential.helper store && \
    echo "https://USERNAME:TOKEN@github.com" > /home/atxuser/.git-credentials && \
    chown atxuser:atxuser /home/atxuser/.git-credentials && \
    chmod 600 /home/atxuser/.git-credentials
```

### Private npm Registry

**Use case:** Install private npm packages during transformation (package.json dependencies)

**Create `.npmrc`:**
```
registry=https://npm.company.com/
//npm.company.com/:_authToken=YOUR_NPM_TOKEN
```

**Create `Dockerfile.custom`:**
```dockerfile
FROM {account}.dkr.ecr.us-east-1.amazonaws.com/aws-transform-cli:latest

# Copy npm config for runtime use
COPY .npmrc /home/atxuser/.npmrc
RUN chown atxuser:atxuser /home/atxuser/.npmrc

# Optional: Pre-install global packages at build time
RUN npm install -g @company/cli-tool --registry https://npm.company.com/
```

### Private Maven/Gradle Repository

**Use case:** Download private artifacts during transformation (pom.xml dependencies)

**Create `settings.xml`:**
```xml
<settings>
  <servers>
    <server>
      <id>company-repo</id>
      <username>USERNAME</username>
      <password>PASSWORD</password>
    </server>
  </servers>
  <mirrors>
    <mirror>
      <id>company-repo</id>
      <url>https://artifactory.company.com/maven</url>
      <mirrorOf>*</mirrorOf>
    </mirror>
  </mirrors>
</settings>
```

**Create `Dockerfile.custom`:**
```dockerfile
FROM {account}.dkr.ecr.us-east-1.amazonaws.com/aws-transform-cli:latest

# Copy Maven settings for runtime use
COPY settings.xml /home/atxuser/.m2/settings.xml
RUN chown atxuser:atxuser /home/atxuser/.m2/settings.xml
```

### Private Python Package Index

**Use case:** Install private Python packages during transformation (requirements.txt)

**Create `Dockerfile.custom`:**
```dockerfile
FROM {account}.dkr.ecr.us-east-1.amazonaws.com/aws-transform-cli:latest

# Configure pip for private index (runtime)
RUN pip config set global.index-url https://pypi.company.com/simple && \
    pip config set global.trusted-host pypi.company.com && \
    pip config set global.extra-index-url https://pypi.org/simple

# Optional: Pre-install private packages (build time)
RUN pip install company-lib==1.0.0
```

---

## Security Best Practices

1. **Use tokens, not passwords** - GitHub PAT, npm tokens, Maven encrypted passwords
2. **Limit token scope** - Read-only access to specific repos
3. **Rotate credentials** - Rebuild container when tokens change
4. **Use build secrets** - Docker BuildKit secrets for sensitive data during build
5. **Scan images** - Use ECR image scanning for vulnerabilities

**Example: Using Docker BuildKit Secrets**

```dockerfile
# syntax=docker/dockerfile:1
FROM {account}.dkr.ecr.us-east-1.amazonaws.com/aws-transform-cli:latest

# Use build secret (not baked into image)
RUN --mount=type=secret,id=npm_token \
    echo "//npm.company.com/:_authToken=$(cat /run/secrets/npm_token)" > /home/atxuser/.npmrc
```

**Build with secret:**
```bash
docker build --secret id=npm_token,src=.npm_token -f Dockerfile.custom -t custom:latest .
```
