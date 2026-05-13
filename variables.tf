variable "vpc_id" {
  description = "The ID of the AWS VPC"
  type        = string
}

variable "aws_account_id" {
  description = "The AWS account ID"
  nullable    = true
  default     = null
  type        = string
}

variable "aws_region" {
  description = "The AWS region"
  nullable    = true
  default     = null
  type        = string
}

variable "aws_role_name" {
  description = "The name of the AWS IAM role that P0 assumes to connect to your infrastructure"
  type        = string
}

variable "aws_services" {
  description = "IDs of AWS service APIs that the P0 connector needs to reach"
  type        = list(string)
}

variable "connector_arn" {
  description = "The ARN of the connector as expected by P0"
  type        = string
}

variable "connector_env" {
  description = "Connector environment variables"
  type        = map(string)
  default     = {}
}

variable "service_subnet_ids" {
  description = "Subnet IDs of the connected service"
  type        = list(string)
  default     = []
}

variable "service" {
  description = "Identifier (within P0) of this service"
  type        = string
}

variable "docker_image_tag" {
  description = <<-EOT
    Tag of P0's published image on Docker Hub to deploy. To track the rolling latest release, set this to `latest`.

    Accepted formats:
      - `<tag>` — deploys whatever the upstream Docker Hub registry currently resolves the tag to.
        Examples: `latest`, `v1.2.3`.
      - `<tag>@sha256:<digest>` — pins the deployment to a specific image content digest. Terraform refuses to deploy if Docker Hub's tag no longer resolves to the given digest.
        Example: `v1.2.3@sha256:abc1234...` (64 hex chars after `sha256:`).
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^@]+(@sha256:[a-f0-9]{64})?$", var.docker_image_tag))
    error_message = "docker_image_tag must be `<tag>` or `<tag>@sha256:<64 hex chars>` (e.g. \"latest\" or \"v1.2.3@sha256:abc...\")."
  }
}
