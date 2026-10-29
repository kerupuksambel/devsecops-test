output "log_group_name" {
  description = "Application log group."
  value       = aws_cloudwatch_log_group.app.name
}

output "logs_kms_key_arn" {
  description = "KMS key that encrypts the application logs."
  value       = aws_kms_key.logs.arn
}
