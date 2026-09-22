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

# ------------------------------------------------------------------- database

variable "db_engine_version" {
  description = "PostgreSQL major version. Only the major number: RDS picks the latest minor."
  type        = string
  default     = "17"
}

# COST: db.t4g.micro is about $0.016/hour (~$11.70/month) in us-east-1.
variable "db_instance_class" {
  description = "RDS instance size"
  type        = string
  default     = "db.t4g.micro"
}

# COST: gp3 storage is about $0.115/GB-month. 20 GB is the minimum.
variable "db_allocated_storage" {
  description = "Initial storage in GB"
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Ceiling for storage autoscaling in GB. Set equal to allocated_storage to disable."
  type        = number
  default     = 50
}

# COST: Multi-AZ roughly doubles the instance cost. Off for dev, on for prod.
variable "db_multi_az" {
  description = "Run a standby in a second AZ"
  type        = bool
  default     = false
}

variable "db_backup_retention" {
  description = "Days of automated backups. Free up to the size of the database. 0 disables backups."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Refuse to delete the instance. True in production."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. NEVER true in production."
  type        = bool
  default     = true
}

variable "db_apply_immediately" {
  description = "Apply changes now instead of in the maintenance window. Can cause downtime."
  type        = bool
  default     = false
}
