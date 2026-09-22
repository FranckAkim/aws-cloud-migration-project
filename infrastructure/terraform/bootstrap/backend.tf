terraform {
  backend "s3" {
    bucket       = "novatech-tfstate-253490749032-us-east-1"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # S3-native locking (Terraform 1.10+); no DynamoDB table needed
  }
}
