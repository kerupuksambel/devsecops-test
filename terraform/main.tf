provider "aws" {
  region = var.aws_region

  # Refuse to run against any account other than the one for this environment.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = local.tags
  }
}

locals {
  name    = "devsecops-api-${var.environment}"
  is_prod = var.environment == "prod"

  # Each environment is its own AWS account (see variables.tf); this is the GitHub
  # Environment name that the deploy role trusts.
  github_environment = local.is_prod ? "production" : var.environment
  ci_deploy_role     = "ci-deploy-${var.environment}"

  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  log_group_names = {
    app   = "/ecs/${local.name}"
    flow  = "/vpc/${local.name}/flow-logs"
    waf   = "aws-waf-logs-${local.name}"
    dns   = "/vpc/${local.name}/dns-firewall"
    rdspg = "/aws/rds/instance/${local.name}/postgresql"
  }

  tags = {
    Project     = "devsecops-home-test"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "platform-team"
    DataClass   = "internal"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_iam_policy_document" "logs_key" {
  # Account administrators manage the key through IAM policies.
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:root"]
    }
  }

  # CloudWatch Logs may use the key only for this environment's log groups (app, flow logs, WAF, DNS firewall, RDS).
  statement {
    sid       = "CloudWatchLogsEncryption"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = [for n in values(local.log_group_names) : "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:${n}"]
    }
  }
}

resource "aws_kms_key" "logs" {
  description             = "Encrypts ${local.name} application logs"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.logs_key.json
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${local.name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_names.app
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}
