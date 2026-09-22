terraform {
  # 1.10+ can lock state with S3 alone (no DynamoDB table needed)
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # any 6.x, never 7.0 (major versions can break things)
    }
  }
}

provider "aws" {
  region = var.region

  # Every resource this provider creates gets these tags automatically.
  default_tags {
    tags = {
      Project   = "novatech"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
