# The application's own database credentials.
#
# Terraform creates the SECRET CONTAINER but never the secret VALUE. The value
# is written once, by hand, straight from a generator into Secrets Manager, so
# the password never exists in:
#   - this repository
#   - Terraform state
#   - a shell command line or shell history
#   - anyone's screen
#
# COST: about $0.40/month per secret, plus $0.05 per 10,000 retrievals.
resource "aws_secretsmanager_secret" "app_db" {
  name        = "${local.name}/db/app"
  description = "NovaTech application database user. Value is set out of band."

  # Dev convenience: deleted secrets normally sit in a 7-30 day recovery window
  # during which the NAME cannot be reused. 0 deletes immediately.
  # In production leave this at the default so a mistaken delete is reversible.
  recovery_window_in_days = 0

  lifecycle {
    # Terraform manages the container. Whoever rotates the password owns the
    # contents, so version changes are not drift.
    ignore_changes = [tags]
  }
}

output "app_db_secret_arn" {
  description = "Secret holding the application's database credentials"
  value       = aws_secretsmanager_secret.app_db.arn
}

output "app_db_secret_name" {
  value = aws_secretsmanager_secret.app_db.name
}
