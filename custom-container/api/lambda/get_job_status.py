"""
Lambda function to get AWS Batch job status and extract ATX conversation ID
"""
import json
import boto3
import os
import re
from datetime import datetime

batch = boto3.client('batch')
logs = boto3.client('logs')
s3 = boto3.client('s3')

def lambda_handler(event, context):
    """
    Get job status and extract ATX conversation ID
    
    Path parameter: batchJobId
    
    Returns:
    {
        "batchJobId": "...",
        "jobName": "...",
        "status": "RUNNING|SUCCEEDED|FAILED",
        "submittedAt": "...",
        "startedAt": "...",
        "completedAt": "...",
        "duration": 123,
        "atxConversationId": "conv_abc123" (null if not available yet),
        "s3OutputPath": "s3://..." (if available)
    }
    """
    
    try:
        # Get job ID from path parameters
        batch_job_id = event.get('pathParameters', {}).get('jobId')
        
        if not batch_job_id:
            return error_response(400, 'Missing jobId in path')
        
        # Get job details from AWS Batch
        response = batch.describe_jobs(jobs=[batch_job_id])
        
        if not response.get('jobs'):
            return error_response(404, f'Job not found: {batch_job_id}')
        
        job = response['jobs'][0]
        
        # Extract basic job info
        job_info = {
            'batchJobId': job['jobId'],
            'jobName': job['jobName'],
            'status': job['status'],
            'submittedAt': format_timestamp(job.get('createdAt')),
            'startedAt': format_timestamp(job.get('startedAt')),
            'completedAt': format_timestamp(job.get('stoppedAt')),
            'duration': calculate_duration(job.get('startedAt'), job.get('stoppedAt')),
            'atxConversationId': None,
            's3OutputPath': None
        }
        
        # Only include statusReason if job failed or has meaningful reason
        if job['status'] == 'FAILED' and job.get('statusReason'):
            reason = job.get('statusReason', '')
            # Filter out generic "Essential container in task exited" message
            if reason != 'Essential container in task exited':
                job_info['statusReason'] = reason
        
        # If job is completed, try to extract conversation ID
        if job['status'] in ['SUCCEEDED', 'FAILED']:
            conversation_id = extract_conversation_id(job)
            if conversation_id:
                job_info['atxConversationId'] = conversation_id
                
                # Build S3 path
                s3_bucket = get_s3_bucket_from_job(job)
                if s3_bucket:
                    output_prefix = get_output_prefix_from_job(job)
                    job_info['s3OutputPath'] = f"s3://{s3_bucket}/{output_prefix}{conversation_id}/"
        
        # Add container info if available
        if job.get('container'):
            container_info = {
                'exitCode': job['container'].get('exitCode')
            }
            
            # Add CloudWatch log info
            if job['container'].get('logStreamName'):
                container_info['logGroup'] = '/aws/batch/atx-transform'
                container_info['logStreamName'] = job['container']['logStreamName']
            
            job_info['container'] = container_info
        
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps(job_info)
        }
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return error_response(500, f'Internal server error: {str(e)}')


def extract_conversation_id(job):
    """
    Extract ATX conversation ID from CloudWatch logs or S3
    """
    try:
        # Try to get from CloudWatch logs
        log_stream_name = job.get('container', {}).get('logStreamName')
        if log_stream_name:
            log_group = '/aws/batch/atx-transform'
            
            # Get recent log events
            response = logs.get_log_events(
                logGroupName=log_group,
                logStreamName=log_stream_name,
                limit=100,
                startFromHead=False  # Get most recent logs
            )
            
            # Search for conversation ID in logs
            for event in response.get('events', []):
                message = event.get('message', '')
                # Look for pattern: "Conversation ID: ..."
                match = re.search(r'Conversation ID:\s*([a-zA-Z0-9_]+)', message)
                if match:
                    return match.group(1)
                
                # Also look for S3 path with conversation ID
                match = re.search(r's3://[^/]+/transformations/([a-zA-Z0-9_]+)/', message)
                if match:
                    return match.group(1)
        
        # Try to get from S3 (list objects and find conversation ID in path)
        s3_bucket = get_s3_bucket_from_job(job)
        output_prefix = get_output_prefix_from_job(job)
        
        if s3_bucket and output_prefix:
            response = s3.list_objects_v2(
                Bucket=s3_bucket,
                Prefix=output_prefix,
                MaxKeys=10
            )
            
            for obj in response.get('Contents', []):
                key = obj['Key']
                # Extract conversation ID from path: transformations/{conversation_id}/
                match = re.search(r'/transformations/([a-zA-Z0-9_]+)/', key)
                if match:
                    return match.group(1)
        
        return None
        
    except Exception as e:
        print(f"Error extracting conversation ID: {str(e)}")
        return None


def get_s3_bucket_from_job(job):
    """Extract S3 bucket from job environment variables"""
    env_vars = job.get('container', {}).get('environment', [])
    for var in env_vars:
        if var.get('name') == 'S3_BUCKET':
            return var.get('value')
    return None


def get_output_prefix_from_job(job):
    """Extract output prefix from job command"""
    command = job.get('container', {}).get('command', [])
    try:
        output_index = command.index('--output')
        if output_index + 1 < len(command):
            return command[output_index + 1]
    except (ValueError, IndexError):
        pass
    return 'transformations/'


def format_timestamp(timestamp_ms):
    """Convert millisecond timestamp to ISO 8601 string"""
    if timestamp_ms:
        return datetime.fromtimestamp(timestamp_ms / 1000).isoformat() + 'Z'
    return None


def calculate_duration(start_ms, end_ms):
    """
    Calculate duration in seconds between start and end timestamps
    
    Args:
        start_ms: Start timestamp in milliseconds (from AWS Batch)
        end_ms: End timestamp in milliseconds (from AWS Batch)
    
    Returns:
        Duration in seconds, or None if either timestamp is missing
    """
    if start_ms and end_ms:
        return int((end_ms - start_ms) / 1000)
    return None


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
