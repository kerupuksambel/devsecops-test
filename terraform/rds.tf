# Data tier: PostgreSQL in private data subnets. No application password exists: the app uses
# IAM database authentication. The master password is generated and rotated by RDS in Secrets
# Manager, so it never appears in Terraform variables or state (Scenario C).

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "Database: PostgreSQL from the Fargate tasks only, no egress"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_tasks" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the Fargate tasks only"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_kms_key" "data" {
  description             = "Encrypts ${local.name} database storage, Performance Insights and the master secret"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "data" {
  name          = "alias/${local.name}-data"
  target_key_id = aws_kms_key.data.key_id
}

resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_db_parameter_group" "main" {
  name   = local.name
  family = "postgres17"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }
}

resource "aws_db_instance" "main" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = "17"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = aws_kms_key.data.arn

  db_name  = var.db_name
  username = "dbadmin"

  # RDS creates the master password in Secrets Manager, encrypts it with our key and rotates it.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.data.arn

  iam_database_authentication_enabled = true
  publicly_accessible                 = false
  db_subnet_group_name                = aws_db_subnet_group.main.name
  vpc_security_group_ids              = [aws_security_group.db.id]
  parameter_group_name                = aws_db_parameter_group.main.name

  multi_az                   = local.is_prod
  backup_retention_period    = local.is_prod ? 14 : 7
  deletion_protection        = local.is_prod
  skip_final_snapshot        = !local.is_prod
  final_snapshot_identifier  = local.is_prod ? "${local.name}-final" : null
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true

  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.data.arn
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
}
