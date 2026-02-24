output "lambda" {
  description = "P0 connector Lambda"
  value       = aws_lambda_function.p0_connector
}

output "connector_security_group" {
  description = "Connector security group to allow connectivity to the service"
  value       = aws_security_group.lambda
}
