output "repository_url" {
  description = "ECR repository URL."
  value       = aws_ecr_repository.api.repository_url
}

output "ci_image_push_role_arn" {
  description = "Role the build job assumes through GitHub OIDC."
  value       = aws_iam_role.ci_image_push.arn
}
