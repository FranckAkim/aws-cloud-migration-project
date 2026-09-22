# Security groups are stateful: if a request is allowed in, its reply is
# allowed back out automatically. Rules are separate resources (not inline
# blocks) so one rule can change without rewriting the whole group.

# ------------------------------------------------------------------ ALB

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public entry point: the load balancer"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

# Open to the world ON PURPOSE: this is a public website's front door.
# The same rule on a database would be a serious mistake.
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere (redirected to HTTPS by the listener)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ------------------------------------------------------------------ app

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "API containers"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-app" }

  lifecycle {
    create_before_destroy = true
  }
}

# The key line of the whole design: the source is a SECURITY GROUP, not a
# CIDR. Only traffic from the load balancer can reach the API, whatever IP
# addresses the containers happen to get.
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "App port, only from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Allow all outbound (image pulls, logs, database)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ------------------------------------------------------------------ database

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "PostgreSQL. Reachable only from the app"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-db" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL, only from the app"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# No egress rule at all: the database has no reason to start connections.
