terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id    = coalesce(var.aws_account_id, data.aws_caller_identity.current.account_id)
  image_name    = "p0-connector-${var.service}"
  region        = coalesce(var.aws_region, data.aws_region.current.id)
  resource_name = "p0-connector-${var.service}-${var.vpc_id}"
  tags = {
    ManagedBy  = "Terraform"
    ManagedFor = "P0"
    P0Service  = var.service
    VpcId      = var.vpc_id
  }
}

# Security group for Lambda communication to connected service
resource "aws_security_group" "lambda" {
  name        = local.resource_name
  description = "Security group allowing traffic from the P0 connector Lambda to the connected service"
  vpc_id      = var.vpc_id

  egress {
    description = "Outbound to service"
    from_port   = var.service_port_range.from
    to_port     = var.service_port_range.to
    protocol    = "tcp"
    cidr_blocks = var.service_cidr
  }

  tags = local.tags
}

# Security group for VPC endpoints
resource "aws_security_group" "vpc_endpoint" {
  name        = "p0-connector-vpc-endpoints-${var.service}-${var.vpc_id}"
  description = "Security group allowing all inbound traffic for VPC endpoint"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS traffic from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    description = "HTTPS outbound to VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  tags = local.tags
}

# VPC endpoints for AWS services
resource "aws_vpc_endpoint" "aws_services" {
  for_each            = toset(var.aws_services)
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${local.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.service_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = local.tags
}

# ECR repository for Lambda container image
resource "aws_ecr_repository" "lambda" {
  name                 = local.resource_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

# Pull and push P0's public image to ECR
resource "terraform_data" "push_lambda_image" {
  provisioner "local-exec" {
    command = <<-EOT
      # Login to ECR
      aws ecr get-login-password --region ${local.region} | \
        docker login --username AWS --password-stdin ${local.account_id}.dkr.ecr.${local.region}.amazonaws.com

      # Pull P0's public image
      docker pull p0security/${local.image_name}:latest --platform linux/amd64

      # Tag for ECR repository
      docker tag p0security/${local.image_name}:latest \
        ${aws_ecr_repository.lambda.repository_url}:latest

      # Push to ECR
      docker push ${aws_ecr_repository.lambda.repository_url}:latest
    EOT
  }

  triggers_replace = {
    repository_url = aws_ecr_repository.lambda.repository_url
  }
}

# Lambda function (container image)
resource "aws_lambda_function" "p0_connector" {
  function_name = local.resource_name
  role          = aws_iam_role.lambda_execution.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.lambda.repository_url}:latest"
  timeout       = 30
  architectures = ["x86_64"]
  publish       = true

  vpc_config {
    subnet_ids         = var.service_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = var.connector_env
  }

  depends_on = [
    terraform_data.push_lambda_image
  ]

  tags = local.tags
}

# Lambda alias for version management
resource "aws_lambda_alias" "latest" {
  name             = "latest"
  function_name    = aws_lambda_function.p0_connector.function_name
  function_version = aws_lambda_function.p0_connector.version
}

# Provisioned concurrency for Lambda
resource "aws_lambda_provisioned_concurrency_config" "connector" {
  function_name                     = aws_lambda_function.p0_connector.function_name
  provisioned_concurrent_executions = 1
  qualifier                         = aws_lambda_alias.latest.name
}

# Lambda Execution Role
resource "aws_iam_role" "lambda_execution" {
  name = local.resource_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

# Attach VPC access policy to Lambda execution role
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}
