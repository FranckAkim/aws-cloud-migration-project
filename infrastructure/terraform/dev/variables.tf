variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used as a prefix on resource names"
  type        = string
  default     = "novatech"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "Address range for the VPC"
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

# COST SWITCH. A NAT Gateway costs roughly $33/month plus $0.045/GB, and it
# bills whether or not anything uses it. Turn it on only while the app runs
# in private subnets, and turn it off again afterwards.
variable "enable_nat" {
  description = "Create a NAT Gateway so private subnets can reach the internet"
  type        = bool
  default     = false
}
