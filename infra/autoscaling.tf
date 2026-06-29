# ─── EC2 INSTANCE (POC mode - standalone) ──────────────────────────────────────
# For production: replace this with autoscaling.tf (Launch Template + ASG)

resource "aws_instance" "wordpress" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.private_a.id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = false

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = false
    delete_on_termination = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    db_host        = "localhost"
    db_name        = var.db_name
    db_user        = var.db_username
    db_pass        = var.db_password
    s3_bucket      = aws_s3_bucket.media.bucket
    region         = var.aws_region
    wp_admin_user  = var.wp_admin_user
    wp_admin_pass  = var.wp_admin_password
    wp_admin_email = var.wp_admin_email
    wp_site_title  = var.wp_site_title
    alb_dns        = aws_lb.alb.dns_name
  }))

  tags = { Name = "${var.project_name}-wordpress" }

  lifecycle {
    ignore_changes = [user_data, ami]
  }
}

# Register instance to ALB target group
resource "aws_lb_target_group_attachment" "wordpress" {
  target_group_arn = aws_lb_target_group.wordpress.arn
  target_id        = aws_instance.wordpress.id
  port             = 80
}
