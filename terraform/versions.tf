# Minimal skeleton so the pipeline has real IaC to validate and scan.
# Full deployment for ONE environment (one AWS account); see environments/*.tfvars.
terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Plan-only: no remote backend. A real deployment would use an S3 backend in the
  # tooling account with KMS encryption, versioning and native state locking.
}
