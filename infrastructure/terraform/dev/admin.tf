# A throwaway jump host used only for database administration: schema loads,
# dumps, restores and ad-hoc psql. It has NO inbound rules and NO public IP.
# Access is via AWS Systems Manager Session Manager, which works because the
# instance makes an OUTBOUND connection to AWS and the session is tunnelled back
# over it. No SSH keys, no open ports, nothing to rotate.
#
# COST while enabled: t4g.nano ~$0.0042/hour, plus the NAT gateway it needs
# (~$0.045/hour). About 5 cents an hour in total. Destroy it when finished:
#   terraform apply   (the defaults switch both off again)

variable "enable_admin_host" {
  description = "Create the SSM-managed admin instance. Requires enable_nat = true."
  type        = bool
  default     = false
}

variable "admin_instance_type" {
  description = "Instance type for the admin host"
  type        = string
  default     = "t4g.nano"
}

# Latest Amazon Linux 2023 for arm64, published by AWS as an SSM parameter, so
# the AMI id is never hard-coded and never goes stale.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# ------------------------------------------------------------------ IAM role

# Trust policy: only the EC2 service may assume this role.
data "aws_iam_policy_document" "admin_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "admin" {
  count = var.enable_admin_host ? 1 : 0

  name               = "${local.name}-admin"
  assume_role_policy = data.aws_iam_policy_document.admin_assume.json
}

# AWS-managed policy that grants exactly what the SSM agent needs. Using the
# managed policy means AWS maintains it as the service changes.
resource "aws_iam_role_policy_attachment" "admin_ssm" {
  count = var.enable_admin_host ? 1 : 0

  role       = aws_iam_role.admin[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Least privilege: read ONLY this database's master secret, nothing else.
data "aws_iam_policy_document" "admin_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.main.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "admin_secret" {
  count = var.enable_admin_host ? 1 : 0

  name   = "read-db-master-secret"
  role   = aws_iam_role.admin[0].id
  policy = data.aws_iam_policy_document.admin_secret.json
}

# The bridge between an IAM role and an EC2 instance.
resource "aws_iam_instance_profile" "admin" {
  count = var.enable_admin_host ? 1 : 0

  name = "${local.name}-admin"
  role = aws_iam_role.admin[0].name
}

# ------------------------------------------------------------ security group

resource "aws_security_group" "admin" {
  count = var.enable_admin_host ? 1 : 0

  name        = "${local.name}-admin"
  description = "Admin jump host. No inbound rules at all."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-admin" }

  lifecycle {
    create_before_destroy = true
  }
}

# Outbound only: SSM endpoints, package repositories, and the database.
resource "aws_vpc_security_group_egress_rule" "admin_all" {
  count = var.enable_admin_host ? 1 : 0

  security_group_id = aws_security_group.admin[0].id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Let the admin host reach PostgreSQL. Disappears with the host.
resource "aws_vpc_security_group_ingress_rule" "db_from_admin" {
  count = var.enable_admin_host ? 1 : 0

  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the admin host"
  referenced_security_group_id = aws_security_group.admin[0].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# ------------------------------------------------------------------ instance

resource "aws_instance" "admin" {
  count = var.enable_admin_host ? 1 : 0

  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.admin_instance_type
  subnet_id              = aws_subnet.app[0].id # private: no public IP
  vpc_security_group_ids = [aws_security_group.admin[0].id]
  iam_instance_profile   = aws_iam_instance_profile.admin[0].name

  # Require IMDSv2: blocks the SSRF class of attacks that steal role credentials
  # from the metadata service.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOT
    #!/bin/bash
    dnf install -y postgresql17
  EOT

  tags = { Name = "${local.name}-admin" }
}

output "admin_instance_id" {
  description = "Target for: aws ssm start-session --target <id>"
  value       = var.enable_admin_host ? aws_instance.admin[0].id : null
}
