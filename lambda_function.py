import json          # Converts Python dictionaries into JSON for the API response
import boto3         # AWS SDK for Python, used to interact with AWS services

# Create a connection to the DynamoDB service
dynamodb = boto3.resource('dynamodb')

# Get a reference to the DynamoDB table named "VisitorCount"
table = dynamodb.Table('VisitorCount-IaC')

# AWS Lambda automatically calls this function whenever it is invoked.
def lambda_handler(event, context):

    # Update the item in DynamoDB.
    # This is an ATOMIC operation: the read and write happen in one step,
    # preventing race conditions if multiple people visit the site at once.
    response = table.update_item(
        
        # Identify the unique item to update (Partition Key)
        Key={'id': 'resume'},

        # ADD increments the numeric attribute safely.
        # '#c' is an alias for the reserved keyword 'count'.
        UpdateExpression="ADD #c :inc",

        # Map the alias to the actual attribute name
        ExpressionAttributeNames={
            '#c': 'count'
        },

        # Define the increment value (1)
        ExpressionAttributeValues={
            ':inc': 1
        },

        # Return the resulting value after the increment
        ReturnValues="UPDATED_NEW"
    )

    # Extract the new count from the response.
    # DynamoDB returns numbers as 'Decimal' objects, which aren't JSON serializable.
    new_count = response['Attributes']['count']

    # Convert the Decimal type to a standard Python integer for JSON compatibility
    new_count_int = int(new_count)

    # Return the response to API Gateway
    return {
        'statusCode': 200,
        'headers': {
            # 'Access-Control-Allow-Origin' is required to prevent browser CORS errors
            'Access-Control-Allow-Origin': '*'
        },
        'body': json.dumps({
            'visitor_count': new_count_int
        })
    }