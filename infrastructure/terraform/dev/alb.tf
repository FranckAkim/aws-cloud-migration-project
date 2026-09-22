# ---------------------------------------------------------------------- ALB
# COST: ~$0.0225/hour (~$16/month) plus a small per-LCU charge, billed from the
# moment it exists. Destroy it when you are not using the environment.

# Master switch for the serving layer. Off by default, because the load
# balancer bills ~$16/month whether or not anything uses it.
variable "enable_app" {
  description = "Create the load balancer and run the ECS service"
  type        = bool
  default     = false
}

resource "aws_lb" "main" {
  count = var.enable_app ? 1 : 0

  name               = local.name
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id # needs two AZs
  security_groups    = [aws_security_group.alb.id]

  # Dev: allow terraform destroy. True in production.
  enable_deletion_protection = false

  # Keep a connection open long enough for slow requests, short enough that
  # idle ones are not held.
  idle_timeout = 60

  tags = { Name = local.name }
}

# The target group holds the things traffic is sent to. target_type = "ip"
# because Fargate tasks have their own ENI and IP, not an instance id.
resource "aws_lb_target_group" "api" {
  count = var.enable_app ? 1 : 0

  name        = "${local.name}-api"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  # How the ALB decides a task is alive. /health was built for exactly this:
  # it checks the database and returns 503 if the database is unreachable.
  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30 # seconds between checks
    timeout             = 5  # a check must answer within this
    healthy_threshold   = 2  # 2 passes  -> in service
    unhealthy_threshold = 3  # 3 failures -> out of service
  }

  # How long to keep sending existing connections to a task being replaced.
  # 30s is plenty for a small API; the default 300s makes deploys feel slow.
  deregistration_delay = 30

  lifecycle {
    create_before_destroy = true
  }
}

# INTENTIONALLY INSECURE, FOR LEARNING ONLY:
# this listener serves plain HTTP. Tokens and passwords sent to it cross the
# internet unencrypted. THIS MUST NOT BE USED IN PRODUCTION. HTTPS needs a
# certificate, which needs a domain name (Route 53 ~$12/year, ACM certificates
# free). When a domain exists, this becomes a redirect to a 443 listener.
resource "aws_lb_listener" "http" {
  count = var.enable_app ? 1 : 0

  load_balancer_arn = aws_lb.main[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api[0].arn
  }
}

output "alb_dns_name" {
  description = "Public hostname of the load balancer"
  value       = one(aws_lb.main[*].dns_name)
}

output "app_url" {
  value = var.enable_app ? "http://${aws_lb.main[0].dns_name}" : null
}
