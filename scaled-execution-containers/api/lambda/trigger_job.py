"""
Lambda function to trigger AWS Batch job for AWS Transform CLI
"""
import json
import boto3
import os
import re
from datetime import datetime

batch = boto3.client('batch')

def validate_command(command):
    """
    Validate command to prevent injection attacks
    
    Security checks:
    1. Must start with 'atx'
    2. Only allow safe characters
    3. Block shell operators and dangerous patterns
    """
    command = command.strip()
    
    # Must start with 'atx'
    if not command.startswith('atx'):
        raise ValueError("Command must start with 'atx'")
    
    # Block dangerous shell operators and patterns
    dangerous_patterns = [
        '&&', '||', ';', '|', '`', '$(', '${', 
        '\n', '\r', '>', '<', '>>', '<<'
    ]
    for pattern in dangerous_patterns:
        if pattern in command:
            raise ValueError(f"Command contains dangerous pattern: {pattern}")
    
    # Allow only safe characters: alphanumeric, spaces, and common CLI characters
    # This allows: atx custom def exec -n AWS/python-version-upgrade -p /path --flag="value"
    if not re.match(r'^[a-zA-Z0-9\s\-_./=:,"\'@\[\]]+$', command):
        raise ValueError("Command contains invalid characters")
    
    return True


def lambda_handler(event, context):
    """
    Trigger a new AWS Batch job
    
    Request body:
    {
        "source": "https://github.com/myorg/myapp.git" or "s3://bucket/path/" (optional),
        "output": "transformations/" (optional),
        "command": "atx custom def list" (required),
        "jobName": "java-sdk-upgrade-prod" (optional),
        "environment": {
            "JAVA_VERSION": "17",
            "PYTHON_VERSION": "11"
        } (optional),
        "tags": {
            "project": "migration",
            "team": "platform"
        } (optional)
    }
    
    Supported source formats (optional):
    - Git: https://github.com/user/repo.git
    - Git: https://gitlab.com/user/repo.git
    - Git: https://bitbucket.org/user/repo.git
    - S3: s3://bucket-name/path/to/code/
    - S3 ZIP: s3://bucket-name/path/file.zip
    - If omitted: Command runs without source code (e.g., "atx custom def list")
    
    Returns:
    {
        "batchJobId": "...",
        "jobName": "...",
        "status": "SUBMITTED",
        "submittedAt": "..."
    }
    """
    
    try:
        # Parse request body
        body = json.loads(event.get('body', '{}'))
        
        # Validate required fields
        if not body.get('command'):
            return error_response(400, 'Missing required field: command')
        
        # Validate command for security
        try:
            validate_command(body['command'])
        except ValueError as e:
            return error_response(400, f'Invalid command: {str(e)}')
        
        # Validate source format if provided
        source = body.get('source')
        if source:
            if not (source.startswith('s3://') or 
                    source.startswith('https://github.com/') or
                    source.startswith('https://gitlab.com/') or
                    source.startswith('https://bitbucket.org/') or
                    source.endswith('.git')):
                return error_response(
                    400, 
                    'Invalid source format. Supported: Git URLs (https://github.com/user/repo.git) or S3 paths (s3://bucket/path/)'
                )
        
        # Get configuration from environment
        job_queue = os.environ.get('JOB_QUEUE', 'atx-job-queue')
        job_definition = os.environ.get('JOB_DEFINITION', 'atx-transform-job')
        s3_bucket = os.environ.get('S3_BUCKET')
        
        # Generate job name first (needed for output path)
        job_name = body.get('jobName')
        if not job_name:
            source = body.get('source', '')
            command = body.get('command', '')
            
            # Extract repo name from source if provided
            if source:
                if source.endswith('.git'):
                    repo_name = source.split('/')[-1].replace('.git', '')
                elif 's3://' in source:
                    repo_name = source.split('/')[-1].replace('.zip', '')
                else:
                    repo_name = source.split('/')[-1] if '/' in source else 'job'
            else:
                # No source provided, generate name from command
                # Extract meaningful part from command (e.g., "atx mcp tools" -> "mcp-tools")
                cmd_parts = command.split()
                if len(cmd_parts) >= 3:
                    # Use subcommand and action (e.g., "mcp tools", "custom def")
                    repo_name = '-'.join(cmd_parts[1:4])  # Take up to 3 parts after 'atx'
                elif len(cmd_parts) >= 2:
                    repo_name = cmd_parts[1]
                else:
                    repo_name = 'job'
            
            # Extract transformation name
            transform_name = 'transform'
            if '-n ' in command:
                parts = command.split('-n ')
                if len(parts) > 1:
                    transform_full = parts[1].split()[0]
                    transform_name = transform_full.split('/')[-1]
            
            job_name = f"{repo_name}-{transform_name}".replace(' ', '-').replace('_', '-')[:128]
        
        # Build container command
        container_command = ['--command', body['command']]
        
        if body.get('source'):
            container_command = ['--source', body['source']] + container_command
        
        # Use jobName in output path for consistency with bulk API
        # Format: transformations/{jobName}/{conversationId}/
        output = body.get('output')
        if not output:
            # Auto-generate output path with job name
            output = f"transformations/{job_name}/"
        container_command = ['--output', output] + container_command
        
        # Build environment variables
        environment = []
        if s3_bucket:
            environment.append({'name': 'S3_BUCKET', 'value': s3_bucket})
        
        # Add custom environment variables if provided
        if body.get('environment'):
            for key, value in body['environment'].items():
                environment.append({'name': key, 'value': str(value)})
        
        # Submit job to AWS Batch
        response = batch.submit_job(
            jobName=job_name,
            jobQueue=job_queue,
            jobDefinition=job_definition,
            containerOverrides={
                'command': container_command,
                'environment': environment
            },
            tags=body.get('tags', {})
        )
        
        # Return success response
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'batchJobId': response['jobId'],
                'jobName': response['jobName'],
                'status': 'SUBMITTED',
                'submittedAt': datetime.now().isoformat() + 'Z',
                'message': 'Job submitted successfully. Use batchJobId to check status.'
            })
        }
        
    except json.JSONDecodeError:
        return error_response(400, 'Invalid JSON in request body')
    except Exception as e:
        print(f"Error: {str(e)}")
        return error_response(500, f'Internal server error: {str(e)}')


def error_response(status_code, message):
    """Return error response"""
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*'
        },
        'body': json.dumps({
            'error': message
        })
    }
