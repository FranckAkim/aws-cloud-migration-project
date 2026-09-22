# The ECR repository already exists (created by hand with the AWS CLI).
# This import block tells Terraform to adopt it instead of creating a second
# one. After the apply succeeds, the import block can be deleted.
import {
  to = aws_ecr_repository.api
  id = "novatech-api"
}

resource "aws_ecr_repository" "api" {
  name = "novatech-api"

  # Tags cannot be overwritten, so a given tag always means the same image.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

import {
  to = aws_ecr_lifecycle_policy.api
  id = "novatech-api"
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
