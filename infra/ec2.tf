# ─── SECURITY GROUP - EC2 (private, only ALB can reach it) ─────────────────────

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "EC2 - only ALB inbound, no SSH"
  vpc_id      = aws_vpc.main.id

  # Only ALB can access port 80
  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Outbound (for updates, S3, SSM, etc.)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-ec2-sg" }
}

# ─── IAM ROLE (S3 + CloudWatch + SSM for server access) ───────────────────────

resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ec2_s3" {
  name = "${var.project_name}-ec2-s3"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.media.arn, "${aws_s3_bucket.media.arn}/*",
                    aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]
      }
    ]
  })
}

resource "aws_iam_role_policy" "ec2_cloudwatch" {
  name = "${var.project_name}-ec2-cw"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
        "cloudwatch:PutMetricData"
      ]
      Resource = "*"
    }]
  })
}

# SSM access (this allows Session Manager = browser-based terminal)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ─── AMI ────────────────────────────────────────────────────────────────────────

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# ─── EC2 is managed by Auto Scaling Group (see autoscaling.tf) ────────────────
# The launch template in autoscaling.tf uses the same config below.
# This standalone instance is NOT created — ASG handles instance lifecycle.
# Keeping this block commented for reference.

# If you want a standalone instance (no ASG), uncomment below and 
# remove autoscaling.tf + re-add target group attachment in alb.tf

# resource "aws_instance" "wordpress" {
#   ami                         = data.aws_ami.ubuntu.id
#   instance_type               = var.ec2_instance_type
#   subnet_id                   = aws_subnet.private_a.id
#   vpc_security_group_ids      = [aws_security_group.ec2.id]
#   iam_instance_profile        = aws_iam_instance_profile.ec2.name
#   associate_public_ip_address = false
#   ...
# }
