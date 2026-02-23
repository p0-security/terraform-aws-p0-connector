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
