terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_network_interfaces" "vpc_endpoint_enis" {
  count  = !var.setup_vpc_endpoints ? 1 : 0
  region = local.region

  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "interface-type"
    values = ["vpc_endpoint"]
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) > 0
      error_message = "setup_vpc_endpoints is false but VPC '${var.vpc_id}' has no VPC endpoint network interfaces. Create endpoints for: ${join(", ", var.aws_services)}, or set setup_vpc_endpoints = true."
    }
  }
}

data "aws_vpc_endpoint" "existing" {
  for_each = !var.setup_vpc_endpoints ? toset(var.aws_services) : toset([])
  region   = local.region

  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "service-name"
    values = ["com.amazonaws.${local.region}.${each.key}"]
  }

  depends_on = [data.aws_network_interfaces.vpc_endpoint_enis]
}

locals {
  account_id    = coalesce(var.aws_account_id, data.aws_caller_identity.current.account_id)
  image_name    = "p0-connector-${var.service}"
  region        = coalesce(var.aws_region, data.aws_region.current.id)
  resource_name = "p0-connector-${var.service}-${var.vpc_id}"
  service_image_tags = {
    mysql = "sha-0e7108e@sha256:33b1c2bae4a5e2a121eee0256fd7159eb916a4fbdedb4a4c91c8522e0eb3e375"
    pg    = "sha-0e7108e@sha256:2f55329258f2695456798255cb1959b465ded0d0cfa69384d6243e1ccf9cf118"
  }
  docker_image_parts   = split("@", local.service_image_tags[var.service])
  docker_tag_name      = local.docker_image_parts[0]
  docker_pinned_digest = local.docker_image_parts[1]
  tags = {
    ManagedBy  = "Terraform"
    ManagedFor = "P0"
    P0Service  = var.service
    VpcId      = var.vpc_id
  }
}

data "docker_registry_image" "upstream" {
  name = "p0security/${local.image_name}:${local.docker_tag_name}"

  lifecycle {
    postcondition {
      condition     = local.docker_pinned_digest == null || self.sha256_digest == local.docker_pinned_digest
      error_message = "Provided digest in `docker_image_tag` does not match the upstream tag's actual digest. Please check if a newer version of this terraform module is available, or contact support@p0.dev for assistance."
    }
  }
}

# Security group for Lambda
resource "aws_security_group" "lambda" {
  region      = local.region
  name        = local.resource_name
  description = "Security group for P0 connector Lambda function"
  vpc_id      = var.vpc_id

  tags = local.tags

}

# Security group for VPC endpoints
resource "aws_security_group" "vpc_endpoint" {
  count       = var.setup_vpc_endpoints ? 1 : 0
  region      = local.region
  name        = "p0-connector-vpc-endpoints-${var.service}-${var.vpc_id}"
  description = "Security group for VPC endpoints allowing traffic from Lambda"
  vpc_id      = var.vpc_id

  tags = local.tags
}

# Security group rules (separate to avoid cycles)
resource "aws_security_group_rule" "lambda_to_vpc_endpoint" {
  count                    = var.setup_vpc_endpoints ? 1 : 0
  region                   = local.region
  type                     = "egress"
  description              = "HTTPS outbound to VPC endpoints"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda.id
  source_security_group_id = aws_security_group.vpc_endpoint[0].id
}

resource "aws_security_group_rule" "vpc_endpoint_from_lambda" {
  count                    = var.setup_vpc_endpoints ? 1 : 0
  region                   = local.region
  type                     = "ingress"
  description              = "HTTPS traffic from Lambda"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpc_endpoint[0].id
  source_security_group_id = aws_security_group.lambda.id
}

# VPC endpoints for AWS services
resource "aws_vpc_endpoint" "aws_services" {
  for_each            = var.setup_vpc_endpoints ? toset(var.aws_services) : toset([])
  region              = local.region
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${local.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.service_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint[0].id]
  private_dns_enabled = true

  tags = local.tags
}

# ECR repository for Lambda container image
resource "aws_ecr_repository" "lambda" {
  region               = local.region
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
        ${aws_ecr_repository.lambda.repository_url}:${local.docker_tag_name}

      # Push to ECR
      docker push ${aws_ecr_repository.lambda.repository_url}:${local.docker_tag_name}
    EOT
  }

  triggers_replace = {
    repository_url = aws_ecr_repository.lambda.repository_url
    digest         = data.docker_registry_image.upstream.sha256_digest
    tag            = local.docker_tag_name
  }
}

# Resolve the digest as stored in ECR after push. ECR may re-encode the manifest,
# so its digest can differ from the upstream Docker Hub digest. Lambda needs ECR's.
data "aws_ecr_image" "lambda" {
  region          = local.region
  repository_name = aws_ecr_repository.lambda.name
  image_tag       = local.docker_tag_name

  depends_on = [terraform_data.push_lambda_image]
}

# Lambda function (container image)
resource "aws_lambda_function" "p0_connector" {
  region        = local.region
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
  region           = local.region
  name             = "latest"
  function_name    = aws_lambda_function.p0_connector.function_name
  function_version = aws_lambda_function.p0_connector.version
  lifecycle {
    ignore_changes       = [function_version]
    replace_triggered_by = [aws_lambda_function.p0_connector.image_uri]
  }
}

# Provisioned concurrency for Lambda
resource "aws_lambda_provisioned_concurrency_config" "connector" {
  region                            = local.region
  function_name                     = aws_lambda_function.p0_connector.function_name
  provisioned_concurrent_executions = 1
  qualifier                         = aws_lambda_function.p0_connector.version

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [qualifier]
    replace_triggered_by  = [aws_lambda_function.p0_connector.image_uri]
  }
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
