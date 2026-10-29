provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project   = "devsecops-home-test"
      ManagedBy = "terraform"
      Owner     = "platform-team"
      Scope     = "tooling"
    }
  }
}

resource "aws_kms_key" "ecr" {
  description             = "Encrypts the ${var.repository_name} ECR repository"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/${var.repository_name}-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

resource "aws_ecr_repository" "api" {
  name = var.repository_name

  # Tags can never be overwritten, so a deployed digest always maps to the image that was scanned.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }
}

resource "aws_inspector2_enabler" "ecr" {
  account_ids    = [var.aws_account_id]
  resource_types = ["ECR"]
}

# Enhanced scanning (Amazon Inspector): scans on push and keeps re-scanning stored images
# as new CVEs are published.
resource "aws_ecr_registry_scanning_configuration" "enhanced" {
  scan_type  = "ENHANCED"
  depends_on = [aws_inspector2_enabler.ecr]

  rule {
    scan_frequency = "CONTINUOUS_SCAN"

    repository_filter {
      filter      = var.repository_name
      filter_type = "WILDCARD"
    }
  }
}

# Workload accounts may only pull, and only through their own task execution role.
data "aws_iam_policy_document" "pull" {
  dynamic "statement" {
    for_each = var.workload_account_ids

    content {
      sid     = "Pull${title(statement.key)}"
      actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]

      principals {
        type        = "AWS"
        identifiers = ["arn:aws:iam::${statement.value}:root"]
      }

      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values   = ["arn:aws:iam::${statement.value}:role/devsecops-api-${statement.key}-execution"]
      }
    }
  }
}

resource "aws_ecr_repository_policy" "pull" {
  repository = aws_ecr_repository.api.name
  policy     = data.aws_iam_policy_document.pull.json
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 50 most recent images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 50 }
      action       = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# ci-image-push: push to this one repository, from main only.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "push_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "push" {
  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"] # no resource-level support
    resources = ["*"]
  }

  statement {
    sid = "PushToOneRepository"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [aws_ecr_repository.api.arn]
  }
}

resource "aws_iam_role" "ci_image_push" {
  name                 = "ci-image-push"
  assume_role_policy   = data.aws_iam_policy_document.push_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "ci_image_push" {
  name   = "push-one-repository"
  role   = aws_iam_role.ci_image_push.id
  policy = data.aws_iam_policy_document.push.json
}
