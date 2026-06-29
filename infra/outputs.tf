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

output "ec2_instance_id" {
  value = aws_instance.wordpress.id
}

output "s3_media_bucket" {
  value = aws_s3_bucket.media.bucket
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "ssm_connect_command" {
  value = "aws ssm start-session --target ${aws_instance.wordpress.id} --region ${var.aws_region}"
}

output "tfstate_bucket" {
  value = "wp-prod-tfstate-bucket"
}
