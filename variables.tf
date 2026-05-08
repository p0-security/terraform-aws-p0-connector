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

variable "use_latest_tag" {
  description = "If true, deploy the `latest` tag of P0's published image from Docker Hub and auto-update on every apply. Mutually exclusive with `image_tag`."
  type        = bool
  default     = false
}

variable "image_tag" {
  description = "Pinned tag of P0's published image on Docker Hub. Mutually exclusive with `use_latest_tag`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.image_tag == null || length(var.image_tag) > 0
    error_message = "image_tag must not be an empty string."
  }
}

variable "image_digest" {
  description = "Optional digest pin (e.g. \"sha256:abc...\") for P0's published image. When set, Terraform refuses to deploy if Docker Hub's actual digest for the tag differs. Only valid alongside `image_tag`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.image_digest == null || can(regex("^sha256:[a-f0-9]{64}$", var.image_digest))
    error_message = "image_digest must be in the form sha256:<64 hex chars>."
  }
}
