import json
import boto3
import os
from datetime import datetime

s3 = boto3.client('s3')

def lambda_handler(event, context):
    """
    Configure MCP settings for AWS Transform CLI containers.
    
    Path: POST /mcp-config
    
    Request Body:
    {
        "mcpConfig": {
            "mcpServers": {
                "server-name": {
                    "command": "command",
                    "args": ["arg1", "arg2"]
                }
            }
        }
    }
    
    Returns:
        200: Configuration saved successfully
        400: Invalid request
        500: Internal error
    """
    
    try:
        # Parse request body
        if not event.get('body'):
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': 'Missing request body',
                    'message': 'Request body with mcpConfig is required'
                })
            }
        
        try:
            body = json.loads(event['body'])
        except json.JSONDecodeError as e:
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': 'Invalid JSON',
                    'message': f'Request body must be valid JSON: {str(e)}'
                })
            }
        
        # Validate mcpConfig field exists
        if 'mcpConfig' not in body:
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': 'Missing mcpConfig field',
                    'message': 'Request body must contain mcpConfig object'
                })
            }
        
        mcp_config = body['mcpConfig']
        
        # Validate mcpConfig is a dict
        if not isinstance(mcp_config, dict):
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': 'Invalid mcpConfig type',
                    'message': 'mcpConfig must be a JSON object'
                })
            }
        
        # Get S3 bucket from environment
        source_bucket = os.environ.get('SOURCE_BUCKET')
        if not source_bucket:
            return {
                'statusCode': 500,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': 'Configuration error',
                    'message': 'SOURCE_BUCKET environment variable not set'
                })
            }
        
        # S3 key for MCP config
        s3_key = 'mcp-config/mcp.json'
        
        # Convert config to JSON string
        config_json = json.dumps(mcp_config, indent=2)
        config_bytes = config_json.encode('utf-8')
        
        # Upload to S3
        s3.put_object(
            Bucket=source_bucket,
            Key=s3_key,
            Body=config_bytes,
            ContentType='application/json',
            ServerSideEncryption='AES256'
        )
        
        s3_path = f"s3://{source_bucket}/{s3_key}"
        
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'message': 'MCP configuration saved successfully',
                's3Path': s3_path,
                'timestamp': datetime.utcnow().isoformat() + 'Z',
                'size': len(config_bytes)
            })
        }
        
    except s3.exceptions.NoSuchBucket:
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'error': 'S3 bucket not found',
                'message': f'Source bucket {source_bucket} does not exist'
            })
        }
        
    except Exception as e:
        print(f"Error saving MCP configuration: {str(e)}")
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
