output "log_group_name" {
  description = "Application log group."
  value       = aws_cloudwatch_log_group.app.name
}

output "logs_kms_key_arn" {
  description = "KMS key that encrypts the application logs."
  value       = aws_kms_key.logs.arn
}

output "alb_dns_name" {
  description = "Public ALB hostname (point DNS here)."
  value       = aws_lb.main.dns_name
}

output "ecs_cluster_name" {
  description = "ECS cluster (GitHub Environment variable ECS_CLUSTER)."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service (GitHub Environment variable ECS_SERVICE)."
  value       = aws_ecs_service.app.name
}

output "ci_deploy_role_arn" {
  description = "Role the deploy job assumes through GitHub OIDC."
  value       = aws_iam_role.ci_deploy.arn
}

output "ci_terraform_plan_role_arn" {
  description = "Role the plan scan job assumes through GitHub OIDC."
  value       = aws_iam_role.ci_terraform_plan.arn
}

output "db_master_secret_arn" {
  description = "RDS-managed master secret (break-glass only; the app never reads it)."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}
