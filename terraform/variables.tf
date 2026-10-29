variable "environment" {
  description = "Deployment environment. Each environment lives in its own AWS account."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "aws_account_id" {
  description = "Account ID for this environment (demo values: dev 444444444444, staging 555555555555, prod 666666666666)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "ap-southeast-3"
}

variable "log_retention_days" {
  description = "Retention for application logs."
  type        = number
  default     = 365
}

variable "tooling_account_id" {
  description = "Shared tooling account that holds the ECR repository (demo value 222222222222)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.tooling_account_id))
    error_message = "tooling_account_id must be a 12-digit AWS account ID."
  }
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose workflows may assume the CI roles."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name."
  }
}

variable "image_uri" {
  description = "Container image, always referenced by digest (the digest the pipeline scanned)."
  type        = string

  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.image_uri))
    error_message = "image_uri must be pinned by digest (repo@sha256:...), never by a mutable tag."
  }
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository in the tooling account."
  type        = string
  default     = "devsecops-api"
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener (issued and DNS-validated outside this configuration)."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Each environment uses a different range so accounts can be peered later."
  type        = string
}

variable "app_port" {
  description = "Port the container listens on."
  type        = number
  default     = 8080
}

variable "desired_count" {
  description = "Number of Fargate tasks."
  type        = number
  default     = 2
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_name" {
  description = "Application database name."
  type        = string
  default     = "app"
}

variable "db_app_user" {
  description = "Least-privilege database user the app connects as with IAM authentication (created by a migration, never the master user)."
  type        = string
  default     = "app_user"
}

variable "waf_rate_limit" {
  description = "Maximum requests per 5 minutes per source IP before WAF blocks."
  type        = number
  default     = 1000
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider in this account. Set false if the bootstrap already created it."
  type        = bool
  default     = true
}
