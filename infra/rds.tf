# ─── RDS Configuration ──────────────────────────────────────────────────────────
# 
# ⚠️ POC MODE: RDS is commented out. MySQL runs on EC2 instead.
# For production (real AWS account), uncomment this entire file
# and set use_local_db = false in variables.tf
#
# resource "aws_security_group" "rds" {
#   name        = "${var.project_name}-rds-sg"
#   description = "RDS MySQL - only from EC2"
#   vpc_id      = aws_vpc.main.id
#
#   ingress {
#     description     = "MySQL from EC2"
#     from_port       = 3306
#     to_port         = 3306
#     protocol        = "tcp"
#     security_groups = [aws_security_group.ec2.id]
#   }
#
#   tags = { Name = "${var.project_name}-rds-sg" }
# }
#
# resource "aws_db_subnet_group" "wordpress" {
#   name       = "${var.project_name}-db-subnet"
#   subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
#   tags       = { Name = "${var.project_name}-db-subnet" }
# }
#
# resource "aws_db_parameter_group" "wordpress" {
#   name   = "${var.project_name}-mysql8"
#   family = "mysql8.0"
#
#   parameter {
#     name  = "innodb_buffer_pool_size"
#     value = "{DBInstanceClassMemory*3/4}"
#   }
#
#   parameter {
#     name  = "max_connections"
#     value = "150"
#   }
#
#   parameter {
#     name  = "slow_query_log"
#     value = "1"
#   }
#
#   parameter {
#     name  = "long_query_time"
#     value = "2"
#   }
#
#   parameter {
#     name  = "innodb_io_capacity"
#     value = "1000"
#   }
#
#   parameter {
#     name  = "innodb_io_capacity_max"
#     value = "2000"
#   }
#
#   parameter {
#     name         = "performance_schema"
#     value        = "1"
#     apply_method = "pending-reboot"
#   }
#
#   tags = { Name = "${var.project_name}-mysql8-params" }
# }
#
# resource "aws_db_instance" "wordpress" {
#   identifier = "${var.project_name}-mysql"
#   engine     = "mysql"
#   engine_version = "8.0"
#
#   instance_class        = var.db_instance_class
#   allocated_storage     = var.db_allocated_storage
#   max_allocated_storage = 200
#   storage_type          = "gp3"
#   storage_encrypted     = true
#
#   db_name  = var.db_name
#   username = var.db_username
#   password = var.db_password
#
#   db_subnet_group_name   = aws_db_subnet_group.wordpress.name
#   vpc_security_group_ids = [aws_security_group.rds.id]
#   parameter_group_name   = aws_db_parameter_group.wordpress.name
#
#   multi_az            = false
#   publicly_accessible = false
#
#   backup_retention_period   = 7
#   backup_window             = "03:00-04:00"
#   maintenance_window        = "mon:04:00-mon:05:00"
#   copy_tags_to_snapshot     = true
#   delete_automated_backups  = false
#   skip_final_snapshot       = false
#   final_snapshot_identifier = "${var.project_name}-final-${random_id.suffix.hex}"
#
#   enabled_cloudwatch_logs_exports = ["slowquery", "error"]
#
#   tags = { Name = "${var.project_name}-mysql" }
#
#   lifecycle {
#     ignore_changes = [password]
#   }
# }
