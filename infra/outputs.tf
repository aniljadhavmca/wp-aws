output "alb_dns_name" {
  value       = aws_lb.alb.dns_name
  description = "ALB URL - access WordPress here"
}

output "wordpress_url" {
  value = "http://${aws_lb.alb.dns_name}"
}

output "wordpress_admin_url" {
  value = "http://${aws_lb.alb.dns_name}/wp-admin/"
}

output "wordpress_admin_user" {
  value = var.wp_admin_user
}

output "rds_endpoint" {
  value       = "localhost (MySQL on EC2 - POC mode)"
  description = "Switch to RDS for production"
}

output "s3_media_bucket" {
  value = aws_s3_bucket.media.bucket
}

output "s3_backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.cdn.id
}

output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "asg_name" {
  value       = aws_autoscaling_group.wordpress.name
  description = "Auto Scaling Group name"
}

output "ssm_connect_command" {
  value       = "aws ssm start-session --target <instance-id> --region ${var.aws_region}"
  description = "Use: aws ec2 describe-instances to get instance ID, then connect via SSM"
}
