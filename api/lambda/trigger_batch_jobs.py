import json
import boto3
import os
from datetime import datetime
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

s3 = boto3.client('s3')
batch = boto3.client('batch')
lambda_client = boto3.client('lambda')

def lambda_handler(event, context):
    """
    Bulk job submission endpoint.
    
    POST /jobs/batch
    {
      "batchName": "java-upgrade-q1",
      "jobs": [
        {"source": "https://github.com/org/repo1", "jobName": "repo1", "command": "atx ..."},
        {"source": "s3://bucket/repo2.zip", "jobName": "repo2", "command": "atx ..."}
      ]
    }
    """
    
    # Check if this is async invocation
    is_async = event.get('isAsync', False)
    
    if not is_async:
        # First invocation - return immediately and process async
        return handle_sync_request(event, context)
    else:
        # Async invocation - process jobs
        return handle_async_processing(event, context)

def handle_sync_request(event, context):
    """Handle initial request - upload to S3 and invoke async"""
    try:
        body = json.loads(event.get('body', '{}'))
        
        if 'jobs' not in body or not body['jobs']:
            return error_response(400, 'Missing or empty jobs array')
        
        batch_name = body.get('batchName', 'batch')
        jobs = body['jobs']
        
        # Auto-generate job names if not provided
        for i, job in enumerate(jobs):
            if 'source' not in job or 'command' not in job:
                return error_response(400, f'Job {i} missing required fields: source, command')
            
            # Auto-generate jobName if not provided
            if 'jobName' not in job or not job['jobName']:
                # Extract repo name from source
                source = job['source']
                if source.endswith('.git'):
                    repo_name = source.split('/')[-1].replace('.git', '')
                elif 's3://' in source:
                    repo_name = source.split('/')[-1].replace('.zip', '')
                else:
                    repo_name = source.split('/')[-1]
                
                # Extract transformation name from command
                transform_name = 'transform'
                if '-n ' in job['command']:
                    # Extract: -n AWS/early-access-comprehensive-codebase-analysis
                    parts = job['command'].split('-n ')
                    if len(parts) > 1:
                        transform_full = parts[1].split()[0]  # Get first word after -n
                        transform_name = transform_full.split('/')[-1]  # Get last part after /
                
                # Generate: spring-petclinic_comprehensive-codebase-analysis
                job_name = f"{repo_name}_{transform_name}"
                
                # Sanitize and truncate to 128 chars
                job_name = job_name.replace(' ', '-').replace('_', '-')[:128]
                job['jobName'] = job_name
        
        # Generate batch ID
        batch_id = f"batch-{datetime.utcnow().strftime('%Y%m%d-%H%M%S')}"
        
        # Upload input to source bucket
        source_bucket = os.environ['SOURCE_BUCKET']
        input_key = f'batch-jobs/{batch_id}-input.json'
        
        s3.put_object(
            Bucket=source_bucket,
            Key=input_key,
            Body=json.dumps(body, indent=2),
            ContentType='application/json',
            ServerSideEncryption='AES256'
        )
        
        # Invoke self asynchronously
        lambda_client.invoke(
            FunctionName=context.function_name,
            InvocationType='Event',
            Payload=json.dumps({
                'isAsync': True,
                'batchId': batch_id,
                'batchName': batch_name,
                'totalJobs': len(jobs),
                'jobs': jobs
            })
        )
        
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({
                'batchId': batch_id,
                'status': 'PROCESSING',
                'totalJobs': len(jobs),
                'message': f'Batch submission started. Check status at /jobs/batch/{batch_id}',
                's3Input': f's3://{source_bucket}/{input_key}'
            })
        }
        
    except Exception as e:
        print(f"Error in sync handler: {str(e)}")
        return error_response(500, str(e))

def handle_async_processing(event, context):
    """Process jobs asynchronously"""
    try:
        batch_id = event['batchId']
        batch_name = event['batchName']
        jobs = event['jobs']
        
        print(f"Processing batch {batch_id} with {len(jobs)} jobs")
        
        # Submit jobs with rate limiting (50 TPS)
        results = []
        job_queue = os.environ['JOB_QUEUE']
        job_definition = os.environ['JOB_DEFINITION']
        
        def submit_single_job(job):
            try:
                response = batch.submit_job(
                    jobName=job['jobName'],
                    jobQueue=job_queue,
                    jobDefinition=job_definition,
                    containerOverrides={
                        'command': [
                            '--source', job['source'],
                            '--output', f"transformations/{job['jobName']}/",
                            '--command', job['command']
                        ]
                    }
                )
                return {
                    'jobName': job['jobName'],
                    'batchJobId': response['jobId'],
                    'status': 'SUBMITTED',
                    'source': job['source'],
                    'command': job['command']
                }
            except Exception as e:
                return {
                    'jobName': job['jobName'],
                    'batchJobId': None,
                    'status': 'FAILED',
                    'error': str(e),
                    'source': job['source'],
                    'command': job['command']
                }
        
        # Submit in parallel with rate limiting
        with ThreadPoolExecutor(max_workers=10) as executor:
            futures = []
            for i, job in enumerate(jobs):
                futures.append(executor.submit(submit_single_job, job))
                
                # Rate limit: 50 jobs per second
                if (i + 1) % 50 == 0:
                    time.sleep(1)
            
            for future in as_completed(futures):
                results.append(future.result())
        
        # Save results to output bucket
        output_bucket = os.environ['OUTPUT_BUCKET']
        output_key = f'batch-jobs/{batch_id}-output.json'
        
        output_data = {
            'batchId': batch_id,
            'batchName': batch_name,
            'totalJobs': len(jobs),
            'submitted': sum(1 for r in results if r['status'] == 'SUBMITTED'),
            'failed': sum(1 for r in results if r['status'] == 'FAILED'),
            'submittedAt': datetime.utcnow().isoformat() + 'Z',
            'jobs': results
        }
        
        s3.put_object(
            Bucket=output_bucket,
            Key=output_key,
            Body=json.dumps(output_data, indent=2),
            ContentType='application/json',
            ServerSideEncryption='AES256'
        )
        
        print(f"Batch {batch_id} complete: {output_data['submitted']} submitted, {output_data['failed']} failed")
        print(f"Results saved to s3://{output_bucket}/{output_key}")
        
        return {'statusCode': 200, 'batchId': batch_id}
        
    except Exception as e:
        print(f"Error in async handler: {str(e)}")
        raise

def error_response(status_code, message):
    return {
        'statusCode': status_code,
        'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
        'body': json.dumps({'error': message})
    }
