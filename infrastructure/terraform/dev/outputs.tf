output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  value = aws_subnet.data[*].id
}

output "security_group_ids" {
  value = {
    alb = aws_security_group.alb.id
    app = aws_security_group.app.id
    db  = aws_security_group.db.id
  }
}

output "ecr_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "nat_enabled" {
  value = var.enable_nat
}

output "db_endpoint" {
  description = "Hostname:port of the database. Resolvable only inside the VPC."
  value       = aws_db_instance.main.endpoint
}

output "db_name" {
  value = aws_db_instance.main.db_name
}

output "db_username" {
  value = aws_db_instance.main.username
}

# The ARN only. The password itself is never an output, never in state, and is
# read at runtime from Secrets Manager by whatever needs it.
output "db_master_secret_arn" {
  description = "Secrets Manager secret holding the master credentials"
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}
