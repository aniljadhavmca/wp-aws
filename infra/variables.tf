variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "wp-prod"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "ec2_instance_type" {
  default = "t3.large"
}

variable "ec2_volume_size" {
  default = 100
}

variable "db_instance_class" {
  default = "db.t3.medium"
}

variable "db_allocated_storage" {
  default = 100
}

variable "db_name" {
  default = "wordpress"
}

variable "db_username" {
  default = "wpadmin"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "domain_name" {
  description = "Your domain (leave empty to use ALB DNS)"
  type        = string
  default     = ""
}

# WordPress Admin
variable "wp_admin_user" {
  description = "WordPress admin username"
  type        = string
  default     = "admin"
}

variable "wp_admin_password" {
  description = "WordPress admin password"
  type        = string
  sensitive   = true
}

variable "wp_admin_email" {
  description = "WordPress admin email"
  type        = string
}

variable "wp_site_title" {
  description = "WordPress site title"
  type        = string
  default     = "My WordPress Store"
}
