# WordPress on AWS - Production Deployment

## OpenTofu + GitHub Actions + Auto Scaling + SSM (No SSH)

---

## 🏗️ Architecture

```
                         ┌──────────────┐
          HTTPS          │  CloudFront  │────── S3 (Product Images)
        ──────────────── │  (CDN+SSL)   │       Encrypted, Versioned
                         └──────┬───────┘
                                │
                         ┌──────▼───────┐
                         │     ALB      │  ← Free ACM SSL Certificate
                         │  (public)    │  ← Health Checks (/health)
                         │  Port 80/443 │  ← Sticky Sessions
                         └──────┬───────┘
                                │
              ┌─────────────────▼─────────────────────┐
              │           PRIVATE SUBNET               │
              │    (no public IP, no SSH port)          │
              │                                        │
              │  ┌──────────── ASG ─────────────────┐  │
              │  │  Min: 1 │ Max: 3 │ Desired: 1    │  │
              │  │                                  │  │
              │  │  ┌──────────┐    ┌──────────┐    │  │
              │  │  │ EC2 (1)  │    │ EC2 (2)  │    │  │
              │  │  │ t3.large │    │ (scaled) │    │  │
              │  │  │          │    │          │    │  │
              │  │  │ Nginx    │    │ Nginx    │    │  │
              │  │  │ PHP 8.2  │    │ PHP 8.2  │    │  │
              │  │  │ Redis    │    │ Redis    │    │  │
              │  │  │ WP-CLI   │    │ WP-CLI   │    │  │
              │  │  └──────────┘    └──────────┘    │  │
              │  │                                  │  │
              │  │  Scale UP:   Memory ≥ 70% (15m)  │  │
              │  │  Scale DOWN: < 70% stable (6hr)  │  │
              │  └──────────────────────────────────┘  │
              │                                        │
              │  ┌──────────────────────────────────┐  │
              │  │     RDS MySQL 8.0 (encrypted)    │  │
              │  │     db.t3.medium │ 2 vCPU 4GB    │  │
              │  │     100GB GP3 │ Auto → 200GB     │  │
              │  │     7-day automated backups       │  │
              │  └──────────────────────────────────┘  │
              └────────────────────────────────────────┘

              Server Access: SSM Session Manager only
              (No SSH │ No Bastion │ No Public IP)
```

---

## 💰 Cost Breakdown

### Base Cost (1 instance running)

| Service | Spec | Monthly Cost |
|---------|------|-------------|
| EC2 t3.large | 2 vCPU, 8GB RAM | $60.00 |
| RDS db.t3.medium | 2 vCPU, 4GB RAM, 100GB | $50.00 |
| ALB | Application Load Balancer | $22.00 |
| NAT Gateway | Private subnet outbound | $5.00 |
| CloudFront | 100GB transfer/month | $9.00 |
| S3 | 50GB media + backups | $3.00 |
| EBS GP3 | 100GB (3000 IOPS) | $8.00 |
| CloudWatch | Metrics + Alarms | $3.00 |
| **Total (base)** | | **~$160/month** |

### With Auto Scaling

| Scenario | Cost |
|----------|------|
| Normal (1 instance) | ~$160/month |
| Under load (2 instances) | ~$220/month |
| Peak (3 instances) | ~$280/month |

### Cost Savings Options

| Option | Savings |
|--------|---------|
| EC2 Reserved Instance (1-year) | -37% on EC2 = save $22/mo |
| RDS Reserved Instance (1-year) | -36% on RDS = save $18/mo |
| Both RIs | **~$120/month total** |

---

## 🔐 GitHub Secrets (Only 5 Required!)

Add in: **Repository → Settings → Secrets and variables → Actions**

| Secret | Description | Example |
|--------|-------------|---------|
| `AWS_ACCESS_KEY_ID` | IAM access key | `AKIA...` |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key | `wJalr...` |
| `DB_PASSWORD` | MySQL password (strong!) | `MyStr0ng!Pass#2024` |
| `WP_ADMIN_PASSWORD` | WordPress login password | `Admin!Secure#99` |
| `WP_ADMIN_EMAIL` | WordPress admin email | `you@domain.com` |

Optional:
| `WP_ADMIN_USER` | WordPress username (default: `admin`) | `myadmin` |

---

## 🚀 Quick Start

### Prerequisites
```bash
# Install OpenTofu
brew install opentofu

# Install AWS CLI
brew install awscli

# Install SSM Plugin (for server access)
brew install --cask session-manager-plugin

# Configure AWS CLI
aws configure
# Enter: Access Key, Secret Key, Region: us-east-1
```

### Deploy (First Time - Local)
```bash
cd infra/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your passwords and email

tofu init
tofu plan        # Review what will be created
tofu apply       # Deploy (~10-12 minutes)
```

### After Deployment
```bash
tofu output
# You'll see:
# wordpress_url = "http://wp-prod-alb-xxxxx.us-east-1.elb.amazonaws.com"
# wordpress_admin_url = "http://wp-prod-alb-xxxxx.../wp-admin/"
# ssm_connect_command = "aws ssm start-session --target i-xxxxx..."
```

---

## 🌐 Accessing WordPress

### Frontend (Your Website)
```
http://<ALB_DNS_NAME>
```
Get the URL: `tofu output wordpress_url`

### Admin Panel (Backend)
```
http://<ALB_DNS_NAME>/wp-admin/
```
- **Username**: Value you set in `wp_admin_user` (default: `admin`)
- **Password**: Value you set in `wp_admin_password`

### What's Pre-Installed
- ✅ WordPress (latest)
- ✅ WooCommerce plugin
- ✅ Redis Object Cache plugin (active)
- ✅ WP Offload Media Lite (S3 integration)
- ✅ SEO-friendly permalinks (`/%postname%/`)

---

## 🖥️ Server Access (SSM - No SSH!)

EC2 instances are in a **private subnet with no public IP** and **no SSH port open**. Access is through AWS Systems Manager Session Manager.

### Option 1: AWS Console (Browser)
```
AWS Console → EC2 → Instances → Select Instance → Connect → Session Manager → Connect
```

### Option 2: AWS CLI
```bash
# Find your instance ID
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=wp-prod-wordpress-asg" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text --region us-east-1

# Connect
aws ssm start-session --target i-0abc123def456 --region us-east-1
```

### Once Connected
```bash
# Switch to root
sudo su -

# Go to WordPress directory
cd /var/www/wordpress

# Run WP-CLI commands
sudo -u www-data wp plugin list
sudo -u www-data wp user list
sudo -u www-data wp option get siteurl

# Check services
systemctl status nginx
systemctl status php8.2-fpm
systemctl status redis-server

# View logs
tail -f /var/log/nginx/error.log
tail -f /var/log/php/wordpress-error.log
cat /var/log/userdata.log
```

---

## 📈 Auto Scaling - How It Works

### Scaling Rules

| Condition | Action | Cooldown |
|-----------|--------|----------|
| Memory **≥ 70%** for 15 minutes | Add 1 EC2 instance | 10 min before next scale up |
| CPU **≥ 70%** for 15 minutes | Add 1 EC2 instance | 10 min before next scale up |
| Memory **< 70%** for 6 hours | Remove 1 EC2 instance | 6 hours before next scale down |
| CPU **< 70%** for 6 hours | Remove 1 EC2 instance | 6 hours before next scale down |

### Limits
- **Minimum**: 1 instance (always running)
- **Maximum**: 3 instances
- **Instance warmup**: 10 minutes (time for userdata to complete)

### How New Instances Join

1. CloudWatch detects memory/CPU ≥ 70% for 15 minutes
2. ASG launches new EC2 from launch template
3. Userdata script runs (~8-10 min):
   - Installs Nginx, PHP, Redis
   - Connects to **same RDS database**
   - Detects WP is already installed → skips `wp core install`
   - Enables Redis cache
4. ALB health check passes (`/health` returns 200)
5. ALB starts sending traffic to new instance

### How Scale Down Works

1. Memory/CPU stays below 70% for **6 continuous hours**
2. ASG terminates 1 instance (keeps min: 1)
3. ALB drains connections gracefully before termination

### Monitor Auto Scaling
```bash
# Check current ASG state
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "wp-prod-asg" \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,Instances:Instances[].{Id:InstanceId,Health:HealthStatus}}' \
  --region us-east-1

# Check scaling activities
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "wp-prod-asg" \
  --max-items 5 --region us-east-1
```

---

## 🐛 Debugging & Troubleshooting

### Check If WordPress Setup Completed
```bash
# Connect via SSM first, then:
cat /var/log/userdata.log
# Look for: "✅ WordPress Ready!" at the end
```

### WordPress Not Loading
```bash
# 1. Check Nginx
sudo nginx -t
sudo systemctl status nginx
sudo tail -50 /var/log/nginx/error.log

# 2. Check PHP-FPM
sudo systemctl status php8.2-fpm
sudo tail -50 /var/log/php/wordpress-error.log

# 3. Check if WP can connect to RDS
cd /var/www/wordpress
sudo -u www-data wp db check

# 4. Check Redis
redis-cli ping   # Should return PONG
redis-cli info memory
```

### Slow Performance
```bash
# Check cache status (from browser)
curl -I http://<ALB_DNS>/
# Look for: X-Cache-Status: HIT (cached) or MISS (not cached)

# Check Redis hit rate
redis-cli info stats | grep hit

# Check PHP memory
sudo -u www-data wp eval "echo ini_get('memory_limit');"

# Check OPcache
php -i | grep opcache

# Check if FastCGI cache is working
ls -la /var/cache/nginx/fastcgi/
```

### ALB Health Check Failing
```bash
# Test health endpoint locally
curl http://localhost/health
# Should return: OK

# Check target group health
aws elbv2 describe-target-health \
  --target-group-arn <target-group-arn> --region us-east-1
```

### RDS Connection Issues
```bash
# Test connection from EC2
mysql -h <rds-endpoint> -u wpadmin -p -e "SELECT 1"

# Check WP database status
cd /var/www/wordpress
sudo -u www-data wp db check
sudo -u www-data wp db size
```

### View CloudWatch Metrics
```bash
# Memory usage (custom metric)
aws cloudwatch get-metric-statistics \
  --namespace "Custom/WordPress" \
  --metric-name "MemoryUtilization" \
  --dimensions "Name=AutoScalingGroupName,Value=wp-prod-asg" \
  --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 --statistics Average --region us-east-1
```

### Common Fixes
```bash
# Clear all caches
sudo rm -rf /var/cache/nginx/fastcgi/*
redis-cli FLUSHALL
sudo systemctl restart php8.2-fpm
sudo systemctl reload nginx

# Fix file permissions
sudo chown -R www-data:www-data /var/www/wordpress
sudo find /var/www/wordpress -type d -exec chmod 755 {} \;
sudo find /var/www/wordpress -type f -exec chmod 644 {} \;

# Restart everything
sudo systemctl restart nginx php8.2-fpm redis-server

# Re-enable OPcache timestamp validation (for debugging)
sudo sed -i 's/opcache.validate_timestamps=0/opcache.validate_timestamps=1/' /etc/php/8.2/fpm/conf.d/99-opcache-prod.ini
sudo systemctl restart php8.2-fpm
```

---

## 🔄 CI/CD Workflows

### Automatic Triggers

| Trigger | Workflow | Action |
|---------|----------|--------|
| Push to `infra/` on PR | `infra.yml` | `tofu plan` → comments on PR |
| Merge `infra/` to main | `infra.yml` | `tofu apply` → deploys infra |
| Push to `scripts/` | `deploy.yml` | Deploys + clears cache (all instances) |
| Daily 6 AM UTC | `maintenance.yml` | Health check + response time |
| Weekly Sunday | `maintenance.yml` | Security patches + WP updates |

### Manual Triggers (GitHub Actions → Run workflow)

| Action | What It Does |
|--------|-------------|
| `clear-cache` | Flushes Nginx + Redis + OPcache on ALL instances |
| `backup` | Database dump → S3 |
| `restart-services` | Restart Nginx + PHP + Redis on ALL instances |
| `update-wordpress` | WP core (minor) + all plugin updates |

### How to Run Manual Actions
```
GitHub → Actions tab → "Deploy & Manage WordPress" → Run workflow → Select action
```

---

## 🔒 Security

| Feature | Status |
|---------|--------|
| EC2 in private subnet (no public IP) | ✅ |
| No SSH port (port 22 closed) | ✅ |
| No bastion host needed | ✅ |
| ALB shields EC2 from direct traffic | ✅ |
| RDS in private subnet | ✅ |
| IMDSv2 enforced (no v1 metadata) | ✅ |
| S3 fully private (OAC access only) | ✅ |
| All storage encrypted at rest | ✅ |
| Fail2Ban (brute force protection) | ✅ |
| UFW firewall (only port 80 open) | ✅ |
| xmlrpc.php blocked | ✅ |
| wp-config.php blocked via Nginx | ✅ |
| Security headers (XSS, Frame, etc.) | ✅ |
| WordPress file editing disabled | ✅ |
| Session Manager audit logging | ✅ |

---

## ⚡ Performance Stack

| Layer | Technology | What It Does |
|-------|-----------|-------------|
| CDN | CloudFront (HTTP/2 + HTTP/3) | Global edge caching, <50ms |
| SSL | ACM (free) | Terminated at ALB (no EC2 overhead) |
| Page Cache | Nginx FastCGI Cache | Full pages served without PHP (~10ms) |
| Object Cache | Redis 512MB (local) | 30K products cached in memory |
| PHP | PHP 8.2 + OPcache 256MB | Bytecode cached, no recompilation |
| Database | InnoDB 75% RAM buffer pool | Most queries from memory |
| Disk | GP3 3000 IOPS baseline | Fast I/O for DB + files |
| Compression | Gzip (Nginx) | Smaller responses, faster transfer |

### Expected Performance
- **Cached pages**: ~10-50ms response time
- **Uncached pages**: ~200-500ms
- **WooCommerce product pages**: ~100-300ms (with Redis)
- **Admin panel**: ~300-800ms

---

## 📁 Project Structure

```
WP-AWS/
├── .github/workflows/
│   ├── infra.yml             # OpenTofu plan + apply
│   ├── deploy.yml            # Deploy, cache, backup, restart
│   └── maintenance.yml       # Health checks + updates
├── infra/
│   ├── main.tf               # VPC, Subnets, NAT, Routes
│   ├── variables.tf          # Input variables
│   ├── outputs.tf            # Deployment outputs
│   ├── ec2.tf                # Security Group, IAM, AMI
│   ├── alb.tf                # ALB, Target Group, Listeners
│   ├── autoscaling.tf        # Launch Template, ASG, Scaling Policies
│   ├── rds.tf                # MySQL 8.0, Parameter Group
│   ├── s3-cloudfront.tf      # S3 + CloudFront CDN
│   ├── monitoring.tf         # CloudWatch Alarms, SNS
│   ├── state.tf              # Remote state (S3 + DynamoDB)
│   ├── userdata.sh           # Server bootstrap script
│   └── terraform.tfvars.example
├── scripts/
│   ├── migrate.sh            # SiteGround → AWS migration
│   └── ssl-setup.sh          # Custom domain SSL setup
├── .gitignore
└── README.md
```

---

## 🌍 Adding Custom Domain + SSL

### Step 1: Uncomment ACM in `alb.tf`
Uncomment the `aws_acm_certificate` resource and HTTPS listener.

### Step 2: Set domain
```hcl
# terraform.tfvars
domain_name = "yourdomain.com"
```

### Step 3: Deploy
```bash
tofu apply
```

### Step 4: DNS
Add CNAME record at your domain registrar:
```
yourdomain.com → wp-prod-alb-xxxxx.us-east-1.elb.amazonaws.com
```

### Step 5: SSL is automatic
ACM validates via DNS → ALB serves HTTPS → Done!

---

## 📦 Migration from SiteGround

### Quick Migration
```bash
chmod +x scripts/migrate.sh
./scripts/migrate.sh
```

The script will:
1. Find your running EC2 instance
2. Upload your database SQL via S3
3. Import into RDS
4. Sync media files to S3
5. Sync plugins/themes
6. Update URLs (search-replace)
7. Clear all caches

### Manual Migration Steps
1. Export database from SiteGround (phpMyAdmin or mysqldump)
2. Download wp-content folder (plugins, themes, uploads)
3. Run migrate.sh or do it step by step via SSM

---

## 🔧 Maintenance

| Task | Frequency | How |
|------|-----------|-----|
| Database backups | Daily 2 AM | Auto (cron → S3) |
| Security patches | Weekly (Sunday) | Auto (GitHub Actions) |
| WP minor updates | Weekly | Auto (GitHub Actions) |
| Log rotation | Daily | Auto (logrotate, 14 days) |
| Health checks | Daily | Auto (GitHub Actions) |
| Memory monitoring | Every 1 min | Auto (cron → CloudWatch) |
| Disk monitoring | Every 5 min | Auto (cron → CloudWatch) |
| Manual backup | On demand | GitHub Actions dispatch |
| Cache clear | On demand | GitHub Actions dispatch |

---

## 🔮 Future Scaling Path

When your traffic grows beyond what this handles:

| Traffic Level | Action | Cost Impact |
|---------------|--------|-------------|
| Current (2K/month) | 1 EC2, auto scales if needed | Base ~$160 |
| 10K/month | Auto scale handles it | +$0-60 (if scales) |
| 50K+/month | Consider t3.xlarge instances | Update instance type in tfvars |
| 100K+/month | Enable RDS Multi-AZ | +$50/month |
| 500K+/month | ElastiCache Redis + larger DB | +$150/month |

### How to Upgrade
```bash
# Change instance type (in terraform.tfvars)
ec2_instance_type = "t3.xlarge"

# Apply
tofu apply
# ASG will rolling-update instances
```

---

## ❓ FAQ

**Q: How do I check if auto scaling triggered?**
```bash
aws autoscaling describe-scaling-activities --auto-scaling-group-name wp-prod-asg --max-items 5
```

**Q: How do I manually scale up for expected traffic?**
```bash
aws autoscaling set-desired-capacity --auto-scaling-group-name wp-prod-asg --desired-capacity 2
```

**Q: How do I update WordPress plugins?**
Run the "update-wordpress" action in GitHub Actions, or via SSM:
```bash
cd /var/www/wordpress && sudo -u www-data wp plugin update --all
```

**Q: Where are my backups?**
```bash
aws s3 ls s3://wp-prod-backups-<suffix>/db/ --region us-east-1
```

**Q: How do I restore a backup?**
```bash
# Download backup
aws s3 cp s3://wp-prod-backups-<suffix>/db/20240101_0200.tar.gz /tmp/
tar -xzf /tmp/20240101_0200.tar.gz -C /tmp/
# Import
cd /var/www/wordpress && sudo -u www-data wp db import /tmp/database.sql
```

**Q: How do I check which instance is handling my request?**
The `X-Cache-Status` header in responses tells you if it's cached or going to PHP.

**Q: Can I still use SSH if I really need to?**
Add port 22 to the EC2 security group and a key pair to the launch template. But SSM is better (audited, no keys to manage).
