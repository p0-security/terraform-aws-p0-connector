output "lambda_execution_role" {
  description = "P0 connector Lambda service role"
  value       = aws_iam_role.lambda_execution
}

output "lambda" {
  description = "P0 connector Lambda"
  value       = aws_lambda_function.p0_connector
}
