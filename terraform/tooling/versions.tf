# Shared tooling account (222222222222): the ECR repository and the image-push role.
# Separate root from ../ because it deploys to a different AWS account.
terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
