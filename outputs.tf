output "lambda_execution_role" {
  description = "P0 connector Lambda service role"
  value       = aws_iam_role.lambda_execution
}

output "lambda" {
  description = "P0 connector Lambda"
  value       = aws_lambda_function.p0_connector
}

output "connector_security_group" {
  description = "Connector security group to allow connectivity to the service"
  value       = aws_security_group.lambda
}
