resource "aws_dynamodb_table" "visitor_counter" {
  name         = "VisitorCount-IaC"
  billing_mode = "PAY_PER_REQUEST" # This ensures you stay in the free tier
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = {
    Environment = "Production"
    Project     = "Cloud Resume Challenge"
  }
}


# The word "resource" tells Terraform we want to create a new piece of infrastructure.
# "aws_iam_role" is the specific resource type defined by the AWS provider.
# "lambda_exec_role" is our internal Terraform name for this block. We use this to reference it elsewhere in our code.
resource "aws_iam_role" "lambda_exec_role" {

  # This is the actual name the role will have inside the AWS console.
  name = "ResumeChallengeLambdaRole-IaC"

  # 'assume_role_policy' defines WHO or WHAT is allowed to use this role.
  # jsonencode() is a built-in Terraform function. It safely converts our HCL configuration into a perfectly formatted JSON string that AWS requires.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Action "sts:AssumeRole" grants permission to temporarily take on this identity.
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          # The Principal is the entity being granted the permission. Here, we specify the AWS Lambda service itself.
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}



# We declare another resource, this time an "aws_iam_policy".
# "dynamodb_access_policy" is our internal reference name.
resource "aws_iam_policy" "dynamodb_access_policy" {

  # The display name and description inside the AWS console.
  name        = "DynamoDBAccessPolicy-IaC"
  description = "Allows Lambda to read and update the visitor count"

  # The 'policy' argument contains the exact permissions being granted.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        # These are the three specific API actions Lambda needs to interact with your visitor count.
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]

        # THIS IS THE MAGIC OF TERRAFORM:
        # Instead of hardcoding the Amazon Resource Name (ARN) like "arn:aws:dynamodb:us-east-1:12345:table/VisitorCount-IaC", 
        # we reference the DynamoDB resource block we wrote earlier. 
        # Terraform will automatically grab the true ARN during deployment and insert it here.
        Resource = aws_dynamodb_table.visitor_counter.arn
      }
    ]
  })
}


# This resource doesn't create a new service; it creates a relationship between two existing resources.
resource "aws_iam_role_policy_attachment" "lambda_dynamodb_attach" {

  # We reference the Role block (from step 1) and ask for its generated 'name'.
  role = aws_iam_role.lambda_exec_role.name

  # We reference the Policy block (from step 2) and ask for its generated 'arn'.
  policy_arn = aws_iam_policy.dynamodb_access_policy.arn
}


# A "data" block is different from a "resource" block. 
# It doesn't create infrastructure in AWS; it performs a local action or reads existing information.
data "archive_file" "lambda_zip" {

  # We specify we want to create a zip archive.
  type = "zip"

  # This tells Terraform to look in your current folder for a file named "lambda_function.py".
  # (Make sure your Python script is saved in the exact same folder as your main.tf file with this name!)
  source_file = "lambda_function.py"

  # This is the name of the zip file Terraform will generate locally.
  output_path = "lambda_function.zip"
}




# We declare the actual Lambda function resource.
resource "aws_lambda_function" "visitor_counter_lambda" {

  # The display name of your function in the AWS Console.
  function_name = "VisitorCounter-IaC"

  # We reference the output of the data block above so Terraform knows exactly which zip file to upload.
  filename = data.archive_file.lambda_zip.output_path

  # We link the IAM Role we created in the previous step using its Amazon Resource Name (ARN).
  role = aws_iam_role.lambda_exec_role.arn

  # The handler tells AWS what the main function is called inside your Python script.
  # If your file is named "lambda_function.py" and the main method is "lambda_handler", it looks like this:
  handler = "lambda_function.lambda_handler"

  # The execution environment. Update this if you used a different Python version (e.g., "python3.10").
  runtime = "python3.9"

  # This is a clever Terraform trick. It creates a hash of your zip file.
  # If you modify your Python code later, the hash changes, and Terraform knows it needs to upload the new version.
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
}



# Create the base API Gateway
resource "aws_api_gateway_rest_api" "visitor_api" {
  name        = "VisitorCounterAPI-IaC"
  description = "API for Cloud Resume Challenge"
}

# Create the specific URL path (e.g., your-url.com/visitor-count)
resource "aws_api_gateway_resource" "visitor_resource" {
  rest_api_id = aws_api_gateway_rest_api.visitor_api.id
  parent_id   = aws_api_gateway_rest_api.visitor_api.root_resource_id
  path_part   = "visitor-count" # This matches the URL you fixed earlier!
}




# Define how the frontend is allowed to talk to this path (GET request)
resource "aws_api_gateway_method" "visitor_method" {
  rest_api_id   = aws_api_gateway_rest_api.visitor_api.id
  resource_id   = aws_api_gateway_resource.visitor_resource.id
  http_method   = "GET"
  authorization = "NONE" # Publicly accessible, no AWS credentials needed
}

# Connect the GET request directly to your Lambda function
resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id = aws_api_gateway_rest_api.visitor_api.id
  resource_id = aws_api_gateway_resource.visitor_resource.id
  http_method = aws_api_gateway_method.visitor_method.http_method

  # AWS strictly requires POST for Lambda proxy integrations under the hood
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.visitor_counter_lambda.invoke_arn
}



# Explicitly grant API Gateway permission to trigger your Lambda function.
# Without this, API Gateway would get a 403 Forbidden error.
resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.visitor_counter_lambda.function_name
  principal     = "apigateway.amazonaws.com"

  # This restricts permissions so ONLY this specific API can trigger the function
  source_arn = "${aws_api_gateway_rest_api.visitor_api.execution_arn}/*/*"
}


# Package the API and deploy it to a live URL
resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.visitor_api.id

  # This ensures the deployment waits for the integration to be built first
  depends_on = [aws_api_gateway_integration.lambda_integration]
}

# Create the specific stage environment (e.g., 'prod')
resource "aws_api_gateway_stage" "api_stage" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.visitor_api.id
  stage_name    = "prod"
}

output "api_invoke_url" {
  value = "${aws_api_gateway_stage.api_stage.invoke_url}/${aws_api_gateway_resource.visitor_resource.path_part}"
}
