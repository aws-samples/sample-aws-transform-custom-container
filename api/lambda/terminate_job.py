import json
import boto3
import os
from datetime import datetime

batch = boto3.client('batch')

def lambda_handler(event, context):
    """
    Terminate a running AWS Batch job.
    
    Path: DELETE /jobs/{jobId}
    
    Returns:
        200: Job termination initiated
        400: Invalid request
        404: Job not found
        500: Internal error
    """
    
    try:
        # Get job ID from path parameters
        job_id = event.get('pathParameters', {}).get('jobId')
        
        if not job_id:
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': 'Missing jobId in path parameters'
                })
            }
        
        # Get optional reason from query parameters or body
        reason = 'Terminated by user'
        
        if event.get('queryStringParameters'):
            reason = event['queryStringParameters'].get('reason', reason)
        
        if event.get('body'):
            try:
                body = json.loads(event['body'])
                reason = body.get('reason', reason)
            except Exception as e:
                print(f"Warning: Could not parse reason from request body: {e}")
                pass
        
        # Get current job status first
        try:
            describe_response = batch.describe_jobs(jobs=[job_id])
            
            if not describe_response['jobs']:
                return {
                    'statusCode': 404,
                    'headers': {
                        'Content-Type': 'application/json',
                        'Access-Control-Allow-Origin': '*'
                    },
                    'body': json.dumps({
                        'error': f'Job {job_id} not found'
                    })
                }
            
            job = describe_response['jobs'][0]
            current_status = job['status']
            
            # Check if job can be terminated
            if current_status in ['SUCCEEDED', 'FAILED']:
                return {
                    'statusCode': 400,
                    'headers': {
                        'Content-Type': 'application/json',
                        'Access-Control-Allow-Origin': '*'
                    },
                    'body': json.dumps({
                        'error': f'Job {job_id} is already in {current_status} state and cannot be terminated',
                        'jobId': job_id,
                        'status': current_status
                    })
                }
            
        except batch.exceptions.ClientException as e:
            return {
                'statusCode': 404,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': f'Job {job_id} not found'
                })
            }
        
        # Terminate the job
        terminate_response = batch.terminate_job(
            jobId=job_id,
            reason=reason
        )
        
        # Get updated job status
        describe_response = batch.describe_jobs(jobs=[job_id])
        job = describe_response['jobs'][0]
        
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'message': 'Job termination initiated',
                'jobId': job_id,
                'reason': reason,
                'previousStatus': current_status,
                'currentStatus': job['status'],
                'terminatedAt': datetime.utcnow().isoformat() + 'Z'
            })
        }
        
    except batch.exceptions.ClientException as e:
        error_message = str(e)
        return {
            'statusCode': 400,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'error': f'Failed to terminate job: {error_message}'
            })
        }
        
    except Exception as e:
        print(f"Error terminating job: {str(e)}")
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'error': 'Internal server error',
                'message': str(e)
            })
        }
