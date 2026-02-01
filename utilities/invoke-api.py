#!/usr/bin/env python3
"""
Helper script to invoke AWS Transform CLI API with automatic IAM signing.
Works with any AWS CLI version.
"""

import sys
import json
import argparse
import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
import urllib.request

def invoke_api(endpoint, method, path, data=None):
    """Invoke API with AWS Signature V4 authentication"""
    
    # Validate endpoint URL scheme
    if not endpoint.startswith(('https://', 'http://')):
        raise ValueError(f"Invalid endpoint URL scheme. Must start with https:// or http://. Got: {endpoint}")
    
    url = f"{endpoint}{path}"
    
    # Get AWS credentials
    session = boto3.Session()
    credentials = session.get_credentials()
    
    # Prepare request
    headers = {'Content-Type': 'application/json'}
    body = json.dumps(data) if data else None
    
    # Create AWS request
    request = AWSRequest(method=method, url=url, data=body, headers=headers)
    
    # Sign request
    SigV4Auth(credentials, 'execute-api', session.region_name or 'us-east-1').add_auth(request)
    
    # Execute request
    req = urllib.request.Request(
        url,
        data=body.encode('utf-8') if body else None,
        headers=dict(request.headers),
        method=method
    )
    
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        return json.loads(e.read().decode('utf-8'))

def main():
    parser = argparse.ArgumentParser(description='Invoke AWS Transform CLI API')
    parser.add_argument('--endpoint', required=True, help='API endpoint URL')
    parser.add_argument('--method', default='POST', help='HTTP method (default: POST)')
    parser.add_argument('--path', required=True, help='API path (e.g., /jobs)')
    parser.add_argument('--data', help='JSON data (or use stdin)')
    
    args = parser.parse_args()
    
    # Get data from argument or stdin
    if args.data:
        data = json.loads(args.data)
    elif not sys.stdin.isatty():
        data = json.load(sys.stdin)
    else:
        data = None
    
    # Invoke API
    response = invoke_api(args.endpoint, args.method, args.path, data)
    
    # Print response
    print(json.dumps(response, indent=2))

if __name__ == '__main__':
    main()
