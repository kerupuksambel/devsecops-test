# CI/CD identity: GitHub Actions assumes these roles through OIDC. No IAM users, no access keys.
# Each environment lives in its own account, so only this environment's deploy role exists here.

locals {
  github_oidc_url = "token.actions.githubusercontent.com"
  github_oidc_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${var.aws_account_id}:oidc-provider/${local.github_oidc_url}"
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://${local.github_oidc_url}"
  client_id_list = ["sts.amazonaws.com"]
}

# ---------------------------------------------------------------------------
# ci-deploy-<env>: deploy only. Trusts this repository AND this GitHub Environment only.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_url}:sub"
      values   = ["repo:${var.github_repository}:environment:${local.github_environment}"]
    }
  }
}

data "aws_iam_policy_document" "deploy" {
  # RegisterTaskDefinition does not support resource-level permissions.
  statement {
    sid       = "RegisterTaskDefinition"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "UpdateOnlyThisService"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [aws_ecs_service.app.id]
  }

  # The pipeline can deploy the app but cannot act as anything except the two ECS roles.
  statement {
    sid       = "PassOnlyTheTwoTaskRoles"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution.arn, aws_iam_role.task.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ci_deploy" {
  name                 = local.ci_deploy_role
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "ci_deploy" {
  name   = "deploy-ecs-service"
  role   = aws_iam_role.ci_deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

# ---------------------------------------------------------------------------
# ci-terraform-plan: metadata-only read. Pull requests and main only.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_url}:sub"
      values = [
        "repo:${var.github_repository}:pull_request",
        "repo:${var.github_repository}:ref:refs/heads/main",
      ]
    }
  }
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid = "ReadConfigurationMetadata"
    actions = [
      "ec2:Describe*",
      "ecs:Describe*",
      "ecs:List*",
      "elasticloadbalancing:Describe*",
      "rds:Describe*",
      "rds:ListTagsForResource",
      "wafv2:Get*",
      "wafv2:List*",
      "logs:Describe*",
      "logs:ListTagsForResource",
      "kms:Describe*",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListAliases",
      "kms:ListResourceTags",
      "iam:Get*",
      "iam:List*",
      "route53resolver:Get*",
      "route53resolver:List*",
      "s3:GetBucket*",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
    ]
    resources = ["*"] #trivy:ignore:AVD-AWS-0057 read-only metadata; data-plane reads are denied below
  }

  # Explicit deny on data-plane reads: the plan role can see how things are configured,
  # never what they contain.
  statement {
    sid    = "DenyDataPlaneReads"
    effect = "Deny"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "secretsmanager:GetSecretValue",
      "ssm:GetParameter*",
      "kms:Decrypt",
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "rds-data:*",
    ]
    resources = ["*"] #trivy:ignore:AVD-AWS-0057
  }
}

resource "aws_iam_role" "ci_terraform_plan" {
  name                 = "ci-terraform-plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "ci_terraform_plan" {
  name   = "read-metadata-deny-data"
  role   = aws_iam_role.ci_terraform_plan.id
  policy = data.aws_iam_policy_document.plan.json
}
