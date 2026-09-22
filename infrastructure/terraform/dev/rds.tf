# ---------------------------------------------------------------- subnet group
# Tells RDS which subnets it may place the instance in. Must cover at least two
# AZs even for a single-AZ instance, so a failover can be enabled later without
# rebuilding. These are the data subnets, which have no route to the internet.
resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = aws_subnet.data[*].id

  tags = { Name = local.name }
}

# ------------------------------------------------------------ parameter group
# Server settings. A custom group is needed because the default one cannot be
# edited. Some parameters apply immediately; others are marked "pending-reboot".
resource "aws_db_parameter_group" "main" {
  name   = "${local.name}-pg${var.db_engine_version}"
  family = "postgres${var.db_engine_version}"

  # Refuse any connection that is not encrypted in transit.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # Log any statement slower than 1 second, for later tuning work.
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------- instance
resource "aws_db_instance" "main" {
  identifier = local.name

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  # gp3 is cheaper and faster than the older gp2 at this size.
  storage_type          = "gp3"
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage # autoscaling ceiling
  storage_encrypted     = true                         # free, uses the aws/rds KMS key

  db_name  = "novatech"
  username = "novatech_admin"

  # NO PASSWORD IN THIS FILE, IN VARIABLES, OR IN STATE.
  # RDS generates the password itself, stores it in Secrets Manager, and can
  # rotate it. Terraform only ever sees the secret's ARN.
  manage_master_user_password = true

  # Placement: private data subnets, reachable only from the app security group.
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az
  parameter_group_name   = aws_db_parameter_group.main.name

  # Backups and maintenance (times are UTC; these windows are quiet hours).
  backup_retention_period    = var.db_backup_retention
  backup_window              = "07:00-08:00"
  maintenance_window         = "Mon:08:30-Mon:09:30"
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  # Send Postgres logs to CloudWatch so they survive the instance.
  enabled_cloudwatch_logs_exports = ["postgresql"]

  # Dev settings. Both of these would be the opposite in production.
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.name}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  apply_immediately         = var.db_apply_immediately

  tags = { Name = local.name }

  lifecycle {
    # The snapshot name contains a timestamp, which would otherwise make every
    # plan show a change.
    ignore_changes = [final_snapshot_identifier]
  }
}
