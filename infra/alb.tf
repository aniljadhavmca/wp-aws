# ─── SECURITY GROUP - ALB (public facing) ──────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "ALB - public HTTP/HTTPS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-alb-sg" }
}

# ─── APPLICATION LOAD BALANCER ─────────────────────────────────────────────────

resource "aws_lb" "alb" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  enable_deletion_protection = false
  drop_invalid_header_fields = true

  tags = { Name = "${var.project_name}-alb" }
}

# ─── TARGET GROUP ──────────────────────────────────────────────────────────────

resource "aws_lb_target_group" "wordpress" {
  name     = "${var.project_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  tags = { Name = "${var.project_name}-tg" }
}

# Note: Target group attachment is handled by Auto Scaling Group
# See autoscaling.tf

# ─── LISTENERS ─────────────────────────────────────────────────────────────────

# HTTP → redirect to HTTPS (when SSL is configured)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.wordpress.arn
  }
}

# HTTPS listener (uncomment after adding ACM certificate)
# resource "aws_lb_listener" "https" {
#   load_balancer_arn = aws_lb.alb.arn
#   port              = 443
#   protocol          = "HTTPS"
#   ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
#   certificate_arn   = aws_acm_certificate.ssl.arn
#
#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.wordpress.arn
#   }
# }

# ─── ACM CERTIFICATE (uncomment when domain is ready) ─────────────────────────

# resource "aws_acm_certificate" "ssl" {
#   domain_name               = var.domain_name
#   subject_alternative_names = ["*.${var.domain_name}"]
#   validation_method         = "DNS"
#
#   lifecycle {
#     create_before_destroy = true
#   }
#
#   tags = { Name = "${var.project_name}-ssl" }
# }
