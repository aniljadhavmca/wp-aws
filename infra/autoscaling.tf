# ─── LAUNCH TEMPLATE ───────────────────────────────────────────────────────────

resource "aws_launch_template" "wordpress" {
  name          = "${var.project_name}-lt"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t2.medium"

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  vpc_security_group_ids = [aws_security_group.ec2.id]

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = false
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
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

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-wordpress-asg"
    }
  }

  tags = { Name = "${var.project_name}-lt" }

  lifecycle {
    ignore_changes = [user_data]
  }
}

# ─── AUTO SCALING GROUP ────────────────────────────────────────────────────────

resource "aws_autoscaling_group" "wordpress" {
  name                      = "${var.project_name}-asg"
  desired_capacity          = 1
  min_size                  = 1
  max_size                  = 3
  vpc_zone_identifier       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  target_group_arns         = [aws_lb_target_group.wordpress.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 600

  launch_template {
    id      = aws_launch_template.wordpress.id
    version = "$Latest"
  }

  default_instance_warmup = 600

  tag {
    key                 = "Name"
    value               = "${var.project_name}-wordpress-asg"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# ─── SCALE UP (Memory/CPU >= 70% for 15 min) ──────────────────────────────────

resource "aws_autoscaling_policy" "scale_up" {
  name                   = "${var.project_name}-scale-up"
  autoscaling_group_name = aws_autoscaling_group.wordpress.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 600
}

# ─── SCALE DOWN (stable below 70% for 6 hours) ────────────────────────────────

resource "aws_autoscaling_policy" "scale_down" {
  name                   = "${var.project_name}-scale-down"
  autoscaling_group_name = aws_autoscaling_group.wordpress.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 21600
}

# ─── CLOUDWATCH ALARMS FOR SCALING ────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${var.project_name}-memory-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "MemoryUtilization"
  namespace           = "Custom/WordPress"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Scale up when memory >= 70% for 15 minutes"
  alarm_actions       = [aws_autoscaling_policy.scale_up.arn, aws_sns_topic.alerts.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.wordpress.name
  }
}

resource "aws_cloudwatch_metric_alarm" "memory_low" {
  alarm_name          = "${var.project_name}-memory-stable"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 72
  metric_name         = "MemoryUtilization"
  namespace           = "Custom/WordPress"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Scale down when memory < 70% stable for 6 hours"
  alarm_actions       = [aws_autoscaling_policy.scale_down.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.wordpress.name
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high_asg" {
  alarm_name          = "${var.project_name}-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Scale up when CPU >= 70% for 15 minutes"
  alarm_actions       = [aws_autoscaling_policy.scale_up.arn, aws_sns_topic.alerts.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.wordpress.name
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_low_asg" {
  alarm_name          = "${var.project_name}-cpu-stable"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 72
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Scale down when CPU < 70% stable for 6 hours"
  alarm_actions       = [aws_autoscaling_policy.scale_down.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.wordpress.name
  }
}
