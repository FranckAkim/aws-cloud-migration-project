# ---------------------------------------------------------------- variables

variable "image_tag" {
  description = "Image tag to deploy. A git SHA, never 'latest': a deploy must name exactly one image."
  type        = string
}

variable "container_port" {
  description = "Port the API listens on inside the container"
  type        = number
  default     = 8000
}

# COST: 0.25 vCPU + 0.5 GB is about $0.0123/hour (~$9/month) per task.
variable "task_cpu" {
  description = "Fargate CPU units (1024 = 1 vCPU)"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate memory in MiB. Valid values depend on task_cpu."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of tasks to run. 0 stops the service without destroying it."
  type        = number
  default     = 1
}

# ------------------------------------------------------------------- logging

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.name}-api"
  retention_in_days = 7 # COST: logs are billed for ingestion and storage
}

# --------------------------------------------------------------- IAM: 2 roles
# The distinction matters:
#   EXECUTION role - used by the ECS agent BEFORE the container starts, to pull
#                    the image, read secrets and write logs.
#   TASK role      - assumed by the application code itself, for AWS APIs it
#                    calls at runtime. Ours calls none, so it stays empty.

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Read exactly the two secrets this task needs. Nothing else.
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.app_db.arn,
      aws_secretsmanager_secret.app_jwt.arn,
    ]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-app-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  # Deliberately no policies: the application calls no AWS APIs.
}

# ------------------------------------------------------------------- cluster

resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "disabled" # COST: Container Insights bills per metric
  }
}

# ----------------------------------------------------------- task definition
# The blueprint for a container: image, resources, configuration, logging.
# Each apply that changes it creates a new REVISION; the service then rolls
# tasks over to it.

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # Fargate's only option: each task gets its own ENI
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # must match the image you built
  }

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = "${aws_ecr_repository.api.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      # Non-sensitive configuration.
      environment = [
        { name = "APP_ENV", value = var.environment },
        { name = "LOG_LEVEL", value = "INFO" },
        { name = "DATABASE_HOST", value = aws_db_instance.main.address },
        { name = "DATABASE_PORT", value = tostring(aws_db_instance.main.port) },
        { name = "DATABASE_NAME", value = aws_db_instance.main.db_name },
        { name = "DATABASE_USER", value = "novatech_app" },
        { name = "DATABASE_SSLMODE", value = "require" },
        { name = "DB_POOL_MIN", value = "1" },
        { name = "DB_POOL_MAX", value = "5" },
      ]

      # Sensitive configuration. ECS fetches these from Secrets Manager using
      # the EXECUTION role and injects them as environment variables. The values
      # never appear in this file, in state, in the task definition, or in logs.
      # The "…:key::" suffix selects one field from the JSON secret.
      secrets = [
        {
          name      = "DATABASE_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.app_db.arn}:password::"
        },
        {
          name      = "SECRET_KEY"
          valueFrom = aws_secretsmanager_secret.app_jwt.arn
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "api"
        }
      }

      # ECS's own check, independent of the load balancer's. A task that fails
      # this is replaced even if the ALB has not noticed yet.
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request;urllib.request.urlopen('http://127.0.0.1:${var.container_port}/health')\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 20
      }
    }
  ])
}

# ------------------------------------------------------------------- service
# Keeps the desired number of tasks running, registers them with the load
# balancer, and replaces any that die.

resource "aws_ecs_service" "api" {
  name            = "${local.name}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.app[*].id      # private
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false                     # image pulls go out via NAT
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = var.container_port
  }

  # Give a new task time to start before health checks count against it.
  health_check_grace_period_seconds = 60

  # If a deployment cannot reach a steady state, roll back to the previous
  # task definition automatically instead of leaving the service broken.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Rolling deployment: allow one extra task, never drop below 100%.
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  # The listener must exist before targets can be registered.
  depends_on = [aws_lb_listener.http]
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.api.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.api.name
}
