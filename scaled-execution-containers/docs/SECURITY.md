# Security Best Practices

Security considerations and best practices for the AWS Transform CLI container.

## Container Security

### Image Security

✅ **Implemented:**
- Non-root user (UID 1000)
- Minimal base image (Amazon Linux 2023)
- Official AWS base image from public ECR
- Regular security updates via dnf package manager
- Health checks
- Checksum verification for downloaded binaries (Maven, Gradle)
- Comprehensive .dockerignore

⚠️ **Recommendations:**
- Scan images regularly with `docker scan` or AWS ECR scanning
- Update base image regularly for security patches (Amazon Linux 2023 updates via dnf)
- Review and update language versions quarterly

### Runtime Security

✅ **Implemented:**
- IAM role-based authentication (no long-lived credentials)
- Automatic credential refresh (every 45 minutes)
- Encrypted S3 storage (AES256)
- CloudWatch logging with 30-day retention
- HTTPS-only egress (port 443)
- Public subnet deployment with assignPublicIp

⚠️ **Recommendations:**
- Enable VPC Flow Logs for network monitoring
- Implement least-privilege IAM policies
- Enable S3 bucket versioning and MFA delete
- Use KMS for S3 encryption (instead of AES256)

## AWS Batch Security

### Job Definition Security

✅ **Implemented:**
- Job timeout (12 hours default, configurable)
- Retry strategy (3 attempts with exponential backoff)
- Resource limits (2 vCPU, 4GB RAM default, configurable)
- Separate job role (ATXBatchJobRole) and execution role (ATXBatchExecutionRole)
- Fargate compute environment

⚠️ **Recommendations:**
- Adjust timeout based on workload size
- Monitor job duration and set CloudWatch alarms
- Review IAM role permissions quarterly

### Network Security

✅ **Implemented:**
- Public subnets with assignPublicIp=ENABLED
- Security group with HTTPS-only egress (port 443)
- Auto-detected VPC and subnets

⚠️ **Recommendations:**
- Restrict security group outbound to specific AWS service endpoints
- Enable VPC Flow Logs for audit
- Monitor network traffic patterns with CloudWatch

## REST API Security

### IAM Authentication

✅ **Implemented:**
- AWS IAM authentication (AWS Signature V4)
- No API keys or shared secrets
- IAM user/role permissions with `execute-api:Invoke`
- Full CloudTrail audit trail

⚠️ **Recommendations:**
- Grant users `execute-api:Invoke` permission on the API
- Use temporary credentials (AWS SSO or STS)
- Monitor API access via CloudTrail
- Set up CloudWatch Alarms for unusual activity

**Grant API access:**
```bash
aws iam put-user-policy \
  --user-name YOUR_USERNAME \
  --policy-name InvokeATXApi \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": "execute-api:Invoke",
      "Resource": "arn:aws:execute-api:*:*:*/prod/*"
    }]
  }'
```

**See:** [../api/README.md](../api/README.md) for IAM authentication setup.

## Secrets Management

### Private Repository Access

⚠️ **Critical:** Never hardcode credentials in Dockerfile or scripts

**Recommended Approach:**
1. Store secrets in AWS Secrets Manager
2. Grant IAM job role `secretsmanager:GetSecretValue` permission
3. Retrieve secrets at runtime in entrypoint.sh

**Example:**
```bash
# In entrypoint.sh
GITHUB_TOKEN=$(aws secretsmanager get-secret-value \
    --secret-id atx/github-token \
    --query SecretString \
    --output text | jq -r .token)
```

### AWS Credentials

✅ **Implemented:** IAM role-based authentication (preferred)

**Priority:**
1. ✅ IAM role (ECS task role, Batch job role) - **RECOMMENDED**
2. ⚠️ Environment variables (temporary credentials only)
3. ❌ Never use long-lived access keys

## S3 Security

### Bucket Configuration

✅ **Implemented:**
- S3 encryption at rest (AES256)
- Block public access enabled
- Versioning enabled on output bucket
- Server access logging
- Enforce SSL (deny non-HTTPS requests)

⚠️ **Recommendations:**
- Use KMS encryption instead of AES256 for compliance requirements
- Enable MFA delete for production buckets
- Implement S3 lifecycle policies to archive old results
- Enable S3 Object Lock for immutable results

**Bucket policies:**
```bash
# Verify bucket encryption
aws s3api get-bucket-encryption --bucket atx-custom-output-{account}

# Verify public access block
aws s3api get-public-access-block --bucket atx-custom-output-{account}
```

### Data Protection

✅ **Implemented:**
- Sensitive file exclusions (.git, .env, credentials, private keys)
- Encryption in transit (HTTPS)
- 7-day lifecycle for source code uploads

⚠️ **Recommendations:**
- Implement S3 Intelligent-Tiering for cost optimization
- Enable S3 Inventory for compliance reporting
- Use S3 Access Points for fine-grained access control

## Input Validation

✅ **Implemented:**
- Argument parsing with validation
- Path traversal prevention

⚠️ **Note:** `eval` is used in entrypoint.sh for command execution. This is acceptable since commands come from trusted AWS Batch job definitions, not user input.

## Monitoring & Auditing

### CloudWatch Logging

✅ **Implemented:**
- Structured logging with ISO 8601 timestamps
- 30-day log retention
- Real-time log streaming

⚠️ **Recommendations:**
- Set up CloudWatch Alarms for:
  - Job failures
  - Long-running jobs (> 6 hours)
  - High error rates
- Export logs to S3 for long-term retention
- Use CloudWatch Insights for analysis

### AWS CloudTrail

⚠️ **Recommendations:**
- Enable CloudTrail for API audit logging
- Enable S3 access logging for result buckets
- Monitor for:
  - Unauthorized API calls
  - IAM policy changes
  - S3 bucket policy changes

## Compliance

### Data Protection

✅ **Implemented:**
- S3 encryption at rest (AES256)
- Encryption in transit (HTTPS)
- Sensitive file exclusions from S3 uploads

⚠️ **Recommendations:**
- Use KMS for S3 encryption (instead of AES256)
- Enable S3 bucket versioning
- Implement S3 lifecycle policies
- Enable MFA delete for production buckets

### Access Control

✅ **Implemented:**
- IAM role-based access
- Least-privilege IAM policies
- Non-root container user

⚠️ **Recommendations:**
- Implement IAM permission boundaries
- Use AWS Organizations SCPs for guardrails
- Regular IAM access reviews
- Enable AWS Config for compliance monitoring

## Vulnerability Management

### Container Scanning

⚠️ **Critical:** Enable ECR image scanning

```bash
# Enable scanning on push
aws ecr put-image-scanning-configuration \
    --repository-name aws-transform-cli \
    --image-scanning-configuration scanOnPush=true

# Scan existing images
aws ecr start-image-scan \
    --repository-name aws-transform-cli \
    --image-id imageTag=latest
```

### Dependency Management

⚠️ **Recommendations:**
- Update language versions quarterly
- Monitor security advisories for:
  - Java (OpenJDK)
  - Python
  - Node.js
  - npm packages (@aws/atx-cli)
- Use Dependabot or Renovate for automated updates

## Incident Response

### Logging

✅ **Implemented:**
- CloudWatch Logs with structured logging
- IAM role ARN logging
- Command execution logging

⚠️ **Recommendations:**
- Define incident response procedures
- Set up CloudWatch Alarms for anomalies
- Implement automated remediation with Lambda

### Backup & Recovery

⚠️ **Recommendations:**
- Enable S3 versioning for results
- Implement S3 cross-region replication
- Regular backup testing
- Document recovery procedures

## Security Checklist

### Before Deployment

- [ ] Review and customize IAM policies
- [ ] Configure VPC and subnets
- [ ] Set up security groups
- [ ] Enable ECR image scanning
- [ ] Configure CloudWatch Alarms
- [ ] Enable CloudTrail
- [ ] Set up S3 bucket policies
- [ ] Configure secrets in Secrets Manager

### After Deployment

- [ ] Test IAM role permissions
- [ ] Verify network connectivity
- [ ] Test job submission and execution
- [ ] Verify CloudWatch logging
- [ ] Test credential refresh
- [ ] Review CloudTrail logs
- [ ] Scan container images
- [ ] Document configuration

### Ongoing

- [ ] Monthly: Update base image and rebuild container
- [ ] Quarterly: Update language versions
- [ ] Quarterly: Review IAM policies
- [ ] Quarterly: Review CloudWatch Alarms
- [ ] Annually: Security audit
- [ ] Annually: Penetration testing

## Known Limitations

1. **eval in entrypoint.sh:** Used for command execution. Acceptable since commands come from trusted AWS Batch job definitions.

2. **Writable filesystem:** Required by ATX CLI for transformations. Cannot use read-only root filesystem.

3. **Version switching:** Helper scripts use symlinks in user directory (no root required).

4. **Network access:** AWS Transform Custom service requires internet access (no VPC endpoint available).

## Reporting Security Issues

If you discover a security vulnerability:

1. **Do not** create a public GitHub issue
2. Email security contact (configure this)
3. Include:
   - Description of vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

## References

- [AWS Batch Security Best Practices](https://docs.aws.amazon.com/batch/latest/userguide/security.html)
- [Container Security Best Practices](https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/security.html)
- [AWS Well-Architected Framework - Security Pillar](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html)
- [CIS Docker Benchmark](https://www.cisecurity.org/benchmark/docker)
