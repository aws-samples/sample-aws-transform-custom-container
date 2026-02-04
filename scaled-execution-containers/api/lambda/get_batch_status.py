import json
import boto3
import os
from datetime import datetime

s3 = boto3.client('s3')
batch = boto3.client('batch')

def lambda_handler(event, context):
    """
    Get batch job status.
    
    GET /jobs/batch/{batchId}
    
    Returns aggregated status of all jobs in the batch.
    """
    
    try:
        # Get batchId from path parameters
        batch_id = event.get('pathParameters', {}).get('batchId')
        
        if not batch_id:
            return error_response(400, 'Missing batchId in path')
        
        # Read output file from S3
        output_bucket = os.environ['OUTPUT_BUCKET']
        output_key = f'batch-jobs/{batch_id}-output.json'
        
        try:
            response = s3.get_object(Bucket=output_bucket, Key=output_key)
            batch_data = json.loads(response['Body'].read())
        except s3.exceptions.NoSuchKey:
            return error_response(404, f'Batch {batch_id} not found')
        
        # Get all job IDs
        job_ids = [job['batchJobId'] for job in batch_data['jobs'] if job.get('batchJobId')]
        
        if not job_ids:
            # No jobs were submitted successfully
            return {
                'statusCode': 200,
                'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
                'body': json.dumps({
                    'batchId': batch_id,
                    'batchName': batch_data.get('batchName'),
                    'status': 'FAILED',
                    'totalJobs': batch_data['totalJobs'],
                    'submitted': 0,
                    'failed': batch_data['totalJobs'],
                    'submittedAt': batch_data.get('submittedAt'),
                    'jobs': batch_data['jobs']
                })
            }
        
        # Query Batch API for current status (in chunks of 100)
        all_job_statuses = []
        for i in range(0, len(job_ids), 100):
            chunk = job_ids[i:i+100]
            response = batch.describe_jobs(jobs=chunk)
            all_job_statuses.extend(response['jobs'])
        
        # Update job statuses
        status_map = {job['jobId']: job['status'] for job in all_job_statuses}
        
        for job in batch_data['jobs']:
            if job.get('batchJobId'):
                job['currentStatus'] = status_map.get(job['batchJobId'], 'UNKNOWN')
        
        # Aggregate counts
        status_counts = {
            'SUBMITTED': 0,
            'PENDING': 0,
            'RUNNABLE': 0,
            'STARTING': 0,
            'RUNNING': 0,
            'SUCCEEDED': 0,
            'FAILED': 0
        }
        
        for job in batch_data['jobs']:
            current_status = job.get('currentStatus', job.get('status', 'FAILED'))
            if current_status in status_counts:
                status_counts[current_status] += 1
        
        # Determine overall batch status
        total_completed = status_counts['SUCCEEDED'] + status_counts['FAILED']
        total_jobs = batch_data['totalJobs']
        
        if total_completed == total_jobs:
            overall_status = 'COMPLETED'
        elif status_counts['RUNNING'] > 0 or status_counts['STARTING'] > 0:
            overall_status = 'RUNNING'
        elif status_counts['RUNNABLE'] > 0 or status_counts['PENDING'] > 0:
            overall_status = 'PENDING'
        else:
            overall_status = 'PROCESSING'
        
        progress = round((total_completed / total_jobs) * 100, 1) if total_jobs > 0 else 0
        
        # Get failed jobs
        failed_jobs = [
            {
                'jobName': job['jobName'],
                'batchJobId': job.get('batchJobId'),
                'error': job.get('error', 'Job failed during execution')
            }
            for job in batch_data['jobs']
            if job.get('currentStatus') == 'FAILED' or (job.get('status') == 'FAILED' and not job.get('batchJobId'))
        ]
        
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({
                'batchId': batch_id,
                'batchName': batch_data.get('batchName'),
                'status': overall_status,
                'totalJobs': total_jobs,
                'progress': progress,
                'statusCounts': status_counts,
                'submittedAt': batch_data.get('submittedAt'),
                's3Input': f's3://{os.environ["SOURCE_BUCKET"]}/batch-jobs/{batch_id}-input.json',
                's3Output': f's3://{output_bucket}/{output_key}',
                'failedJobs': failed_jobs[:10] if len(failed_jobs) > 10 else failed_jobs,
                'totalFailed': len(failed_jobs)
            })
        }
        
    except Exception as e:
        print(f"Error getting batch status: {str(e)}")
        return error_response(500, str(e))

def error_response(status_code, message):
    return {
        'statusCode': status_code,
        'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
        'body': json.dumps({'error': message})
    }
