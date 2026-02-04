#!/usr/bin/env python3
"""
Monitor AWS Batch job logs in real-time.
Usage: python3 tail-logs.py JOB_ID [--region REGION]
"""

import sys
import time
import argparse
import boto3

def get_log_stream(batch_client, job_id):
    """Get log stream name from job ID"""
    try:
        response = batch_client.describe_jobs(jobs=[job_id])
        if response['jobs']:
            job = response['jobs'][0]
            log_stream = job.get('container', {}).get('logStreamName')
            return log_stream
        return None
    except Exception as e:
        print(f"Error getting job info: {e}")
        return None

def tail_logs(logs_client, log_group, log_stream, follow=True):
    """Tail logs from CloudWatch"""
    next_token = None
    
    try:
        while True:
            kwargs = {
                'logGroupName': log_group,
                'logStreamName': log_stream,
                'startFromHead': False
            }
            
            if next_token:
                kwargs['nextToken'] = next_token
            
            response = logs_client.get_log_events(**kwargs)
            
            for event in response['events']:
                print(event['message'])
            
            next_token = response.get('nextForwardToken')
            
            if not follow or not response['events']:
                if not follow:
                    break
                time.sleep(2)  # Polling interval for new log events
                
    except KeyboardInterrupt:
        print("\nStopped tailing logs")
    except Exception as e:
        print(f"Error tailing logs: {e}")

def main():
    parser = argparse.ArgumentParser(description='Monitor AWS Batch job logs')
    parser.add_argument('job_id', help='AWS Batch job ID')
    parser.add_argument('--region', default='us-east-1', help='AWS region')
    parser.add_argument('--no-follow', action='store_true', help='Print logs once and exit')
    
    args = parser.parse_args()
    
    # Initialize AWS clients
    batch = boto3.client('batch', region_name=args.region)
    logs = boto3.client('logs', region_name=args.region)
    
    log_group = '/aws/batch/atx-transform'
    
    print(f"Getting log stream for job: {args.job_id}")
    
    # Wait for log stream to be available
    log_stream = None
    for attempt in range(30):
        log_stream = get_log_stream(batch, args.job_id)
        if log_stream:
            break
        if attempt == 0:
            print("Waiting for job to start...")
        time.sleep(5)  # Wait for job to start and create log stream
    
    if not log_stream:
        print("Error: Could not get log stream. Job may not have started yet.")
        sys.exit(1)
    
    print(f"Log stream: {log_stream}")
    print("=" * 80)
    print()
    
    # Tail logs
    tail_logs(logs, log_group, log_stream, follow=not args.no_follow)

if __name__ == '__main__':
    main()
