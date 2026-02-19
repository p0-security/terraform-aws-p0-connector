output "lambda_execution_role" {
  description = "P0 connector Lambda service role"
  value       = aws_iam_role.lambda_execution
}
