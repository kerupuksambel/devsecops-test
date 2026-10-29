# Deliberately INSECURE example for Task 3, Scenario B. Never deployed; used only to show the
# IaC gate blocking it. Not part of the Terraform root (scan target: evidence/scenarios/).
resource "aws_security_group" "db" {
  name        = "db"
  description = "Database"
  vpc_id      = "vpc-12345678"
}

resource "aws_vpc_security_group_ingress_rule" "db_open" {
  security_group_id = aws_security_group.db.id
  description       = "PostgreSQL from anywhere"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_db_instance" "main" {
  identifier          = "app"
  engine              = "postgres"
  instance_class      = "db.t4g.micro"
  allocated_storage   = 20
  publicly_accessible = true
  storage_encrypted   = false
  username            = "dbadmin"
  password            = var.db_password
}

variable "db_password" {
  type = string
}
