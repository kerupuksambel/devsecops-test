variable "aws_account_id" {
  description = "Shared tooling account ID (demo value 222222222222)."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "ap-southeast-3"
}

variable "workload_account_ids" {
  description = "Workload accounts allowed to pull images (demo: dev, staging, prod)."
  type        = map(string)
  default = {
    dev     = "444444444444"
    staging = "555555555555"
    prod    = "666666666666"
  }
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose main branch may push images."
  type        = string
}

variable "repository_name" {
  description = "ECR repository name."
  type        = string
  default     = "devsecops-api"
}
