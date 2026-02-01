"""
Lambda function to generate presigned URLs for uploading source code ZIP files.

API: POST /upload
Request Body:
{
    "filename": "my-project.zip",
    "expiresIn": 3600  // Optional, default 3600 seconds (1 hour)
}

Response:
{
    "uploadUrl": "https://s3.amazonaws.com/...",
    "s3Path": "s3://atx-source-code-{account}/uploads/{uuid}/my-project.zip",
    "expiresIn": 3600,
    "expiresAt": "2024-01-15T12:00:00Z"
}
"""

import json
import os
import boto3
import uuid
from datetime import datetime, timedelta

s3_client = boto3.client('s3')

# Environment variables
SOURCE_BUCKET = os.environ.get('SOURCE_BUCKET')  # atx-source-code-{account}
DEFAULT_EXPIRATION = 3600  # 1 hour
MAX_EXPIRATION = 86400  # 24 hours


def lambda_handler(event, context):
    """Generate presigned URL for uploading source code ZIP file."""
    
    try:
        # Parse request body
        body = json.loads(event.get('body', '{}'))
        filename = body.get('filename')
        expires_in = body.get('expiresIn', DEFAULT_EXPIRATION)
        
        # Validate inputs
        if not filename:
            return {
                'statusCode': 400,
                'headers': {'Content-Type': 'application/json'},
                'body': json.dumps({
                    'error': 'Missing required field: filename',
                    'message': 'Please provide a filename for the upload'
                })
            }
        
        # Validate filename is a ZIP file
        if not filename.lower().endswith('.zip'):
            return {
                'statusCode': 400,
                'headers': {'Content-Type': 'application/json'},
                'body': json.dumps({
                    'error': 'Invalid file type',
                    'message': 'Only ZIP files are supported. Filename must end with .zip'
                })
            }
        
        # Validate expiration
        if expires_in < 60 or expires_in > MAX_EXPIRATION:
            return {
                'statusCode': 400,
                'headers': {'Content-Type': 'application/json'},
                'body': json.dumps({
                    'error': 'Invalid expiresIn value',
                    'message': f'expiresIn must be between 60 and {MAX_EXPIRATION} seconds'
                })
            }
        
        # Generate unique upload path
        upload_id = str(uuid.uuid4())
        s3_key = f"uploads/{upload_id}/{filename}"
        s3_path = f"s3://{SOURCE_BUCKET}/{s3_key}"
        
        # Generate presigned URL for PUT operation
        presigned_url = s3_client.generate_presigned_url(
            'put_object',
            Params={
                'Bucket': SOURCE_BUCKET,
                'Key': s3_key,
                'ContentType': 'application/zip'
            },
            ExpiresIn=expires_in
        )
        
        # Calculate expiration timestamp
        expires_at = datetime.utcnow() + timedelta(seconds=expires_in)
        
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({
                'uploadUrl': presigned_url,
                's3Path': s3_path,
                'uploadId': upload_id,
                'filename': filename,
                'expiresIn': expires_in,
                'expiresAt': expires_at.strftime('%Y-%m-%dT%H:%M:%SZ'),
                'instructions': {
                    'step1': f'Upload your ZIP file to the uploadUrl using HTTP PUT',
                    'step2': f'Use the s3Path in trigger-job API: POST /jobs with {{"source": "{s3_path}", ...}}',
                    'step3': 'The container will automatically extract the ZIP file'
                }
            })
        }
        
    except json.JSONDecodeError:
        return {
            'statusCode': 400,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({
                'error': 'Invalid JSON',
                'message': 'Request body must be valid JSON'
            })
        }
    
    except Exception as e:
        print(f"Error generating presigned URL: {str(e)}")
        return {
            'statusCode': 500,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({
                'error': 'Internal server error',
                'message': 'Failed to generate upload URL'
            })
        }
