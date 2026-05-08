terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
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
  effective_tag = var.use_latest_tag ? "latest" : var.image_tag
  tags = {
    ManagedBy  = "Terraform"
    ManagedFor = "P0"
    P0Service  = var.service
    VpcId      = var.vpc_id
  }
}

data "docker_registry_image" "upstream" {
  name = "p0security/${local.image_name}:${local.effective_tag}"

  lifecycle {
    precondition {
      condition     = var.use_latest_tag != (var.image_tag != null)
      error_message = "Exactly one of `use_latest_tag = true` or `image_tag` (non-null) must be set."
    }
    precondition {
      condition     = var.image_digest == null || !var.use_latest_tag
      error_message = "`image_digest` may only be set alongside `image_tag` (digest pinning requires an explicit tag, not `latest`)."
    }
    postcondition {
      condition     = var.image_digest == null || self.sha256_digest == var.image_digest
      error_message = "Provided `image_digest` does not match the upstream tag's actual digest. Either update the digest pin or remove it to accept the upstream content."
    }
  }
}

# Security group for Lambda
resource "aws_security_group" "lambda" {
  name        = local.resource_name
  description = "Security group for P0 connector Lambda function"
  vpc_id      = var.vpc_id

  tags = local.tags
}

# Security group for VPC endpoints
resource "aws_security_group" "vpc_endpoint" {
  name        = "p0-connector-vpc-endpoints-${var.service}-${var.vpc_id}"
  description = "Security group for VPC endpoints allowing traffic from Lambda"
  vpc_id      = var.vpc_id

  tags = local.tags
}

# Security group rules (separate to avoid cycles)
resource "aws_security_group_rule" "lambda_to_vpc_endpoint" {
  type                     = "egress"
  description              = "HTTPS outbound to VPC endpoints"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda.id
  source_security_group_id = aws_security_group.vpc_endpoint.id
}

resource "aws_security_group_rule" "vpc_endpoint_from_lambda" {
  type                     = "ingress"
  description              = "HTTPS traffic from Lambda"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpc_endpoint.id
  source_security_group_id = aws_security_group.lambda.id
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

  force_delete = true

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

      # Pull P0's public image by digest for determinism
      docker pull p0security/${local.image_name}@${data.docker_registry_image.upstream.sha256_digest} --platform linux/amd64

      # Tag for ECR repository
      docker tag p0security/${local.image_name}@${data.docker_registry_image.upstream.sha256_digest} \
        ${aws_ecr_repository.lambda.repository_url}:${local.effective_tag}

      # Push to ECR
      docker push ${aws_ecr_repository.lambda.repository_url}:${local.effective_tag}
    EOT
  }

  triggers_replace = {
    repository_url = aws_ecr_repository.lambda.repository_url
    digest         = data.docker_registry_image.upstream.sha256_digest
    tag            = local.effective_tag
  }
}

# Resolve the digest as stored in ECR after push. ECR may re-encode the manifest,
# so its digest can differ from the upstream Docker Hub digest. Lambda needs ECR's.
data "aws_ecr_image" "lambda" {
  repository_name = aws_ecr_repository.lambda.name
  image_tag       = local.effective_tag

  depends_on = [terraform_data.push_lambda_image]
}

# Lambda function (container image)
resource "aws_lambda_function" "p0_connector" {
  function_name = reverse(split(":", var.connector_arn))[0]
  role          = aws_iam_role.lambda_execution.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.lambda.repository_url}@${data.aws_ecr_image.lambda.image_digest}"
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

resource "aws_iam_role_policy" "lambda_invocation" {
  name = "${local.resource_name}-invoke"
  role = var.aws_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.p0_connector.arn
      }
    ]
  })
}
