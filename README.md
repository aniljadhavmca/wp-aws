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

### Base Cost (1 instance running 24/7)

| Service | Monthly Cost |
|---------|-------------|
| EC2 t3.large (2 vCPU, 8GB) | $60 |
| RDS db.t3.medium (100GB GP3) | $50 |
| ALB | $22 |
| CloudFront + S3 | $12 |
| NAT Gateway | $5 |
| EBS GP3 100GB | $8 |
| CloudWatch | $3 |
| **Total** | **~$160/month** |

### Auto Scaling Cost (pay only for hours used!)

EC2 is billed **per hour**. If traffic spikes and a 2nd instance runs for 3 hours then shuts down — you pay only for those 3 hours, not the full month.

| Scenario | Extra Cost |
|----------|-----------|
| 2nd EC2 runs 1 hour | +$0.08 |
| 2nd EC2 runs 1 day | +$2.00 |
| 2nd EC2 runs full week | +$14.00 |
| 2nd EC2 runs full month | +$60.00 |

**Example**: Traffic spike on sale day → 2nd instance UP for 6 hours → scales back down. Cost = **$0.50 extra** that day.

### Save with Reserved Instances

| Option | Savings |
|--------|---------|
| EC2 RI (1-year) | $60 → $38/mo |
| RDS RI (1-year) | $50 → $32/mo |
| **Both** | **~$120/month total** |

---

## 🔐 GitHub Secrets (Only 5!)

Repository → Settings → Secrets and variables → Actions:

| Secret | Example |
|--------|---------|
| `AWS_ACCESS_KEY_ID` | `AKIA...` |
| `AWS_SECRET_ACCESS_KEY` | `wJalr...` |
| `DB_PASSWORD` | `MyStr0ng!Pass#2024` |
| `WP_ADMIN_PASSWORD` | `Admin!Secure#99` |
| `WP_ADMIN_EMAIL` | `you@domain.com` |

---

## 🚀 Deploy

### Option 1: GitHub Actions (recommended)

1. Add the 5 secrets above
2. Push any change to `infra/` folder → auto deploys
3. Check **Actions** tab for progress

### Option 2: Local (first time)

```bash
brew install opentofu
cd infra/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars

tofu init
tofu plan
tofu apply    # ~10-12 minutes
```

### After Deploy

```bash
tofu output
# wordpress_url       = "http://wp-prod-alb-xxxxx.us-east-1.elb.amazonaws.com"
# wordpress_admin_url = "http://wp-prod-alb-xxxxx.../wp-admin/"
```

---

## 🌐 Access WordPress

| What | URL |
|------|-----|
| **Your site** | `http://<ALB_DNS>` |
| **Admin panel** | `http://<ALB_DNS>/wp-admin/` |
| **Username** | `admin` (default) |
| **Password** | Value of `WP_ADMIN_PASSWORD` secret |

Pre-installed: WordPress + WooCommerce + Redis Cache + S3 Media Offload + SEO permalinks.

---

## 🖥️ Server Access (SSM)

No SSH. No bastion. No key pairs.

```bash
# Find instance
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=wp-prod-wordpress-asg" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text --region us-east-1

# Connect
aws ssm start-session --target i-0abc123def456 --region us-east-1
```

Or: **AWS Console → EC2 → Select Instance → Connect → Session Manager**

---

## 📈 Auto Scaling

| Condition | Action | Cooldown |
|-----------|--------|----------|
| Memory ≥ 70% for 15 min | +1 instance | 10 min |
| CPU ≥ 70% for 15 min | +1 instance | 10 min |
| Memory < 70% for 6 hours | -1 instance | 6 hours |
| CPU < 70% for 6 hours | -1 instance | 6 hours |

- Min: 1 │ Max: 3
- New instances auto-join ALB after ~10 min (userdata completes)
- Scaled instances share the **same RDS database** (no data loss)
- You only pay for scaled instances **during the hours they run**

---

## 🔄 CI/CD

| Trigger | What Happens |
|---------|-------------|
| Push to `infra/` | `tofu plan` → `tofu apply` |
| Push to `scripts/` | Clears cache on all instances |
| Manual: `clear-cache` | Flush Nginx + Redis + OPcache |
| Manual: `backup` | DB dump → S3 |
| Manual: `restart-services` | Restart Nginx + PHP + Redis |
| Manual: `update-wordpress` | WP core + plugin updates |
| Daily 6 AM | Health check (status + response time) |
| Weekly Sunday | Security patches + WP updates |

Run manual actions: **Actions tab → "Deploy & Manage WordPress" → Run workflow**

---

## 🐛 Debugging

### Connect to server
```bash
aws ssm start-session --target <instance-id> --region us-east-1
```

### Check setup log
```bash
cat /var/log/userdata.log
# Look for "✅ WordPress Ready!" at the end
```

### WordPress issues
```bash
cd /var/www/wordpress
sudo -u www-data wp db check          # DB connection
sudo -u www-data wp plugin list       # Plugins
redis-cli ping                        # Redis (expect PONG)
sudo nginx -t                         # Nginx config
sudo systemctl status php8.2-fpm     # PHP status
```

### View logs
```bash
tail -f /var/log/nginx/error.log
tail -f /var/log/php/wordpress-error.log
```

### Clear everything
```bash
sudo rm -rf /var/cache/nginx/fastcgi/*
redis-cli FLUSHALL
sudo systemctl restart php8.2-fpm nginx
```

---

## 🔒 Security

| Feature | Status |
|---------|--------|
| EC2 in private subnet (no public IP) | ✅ |
| No SSH, no bastion | ✅ |
| ALB shields EC2 | ✅ |
| RDS in private subnet | ✅ |
| IMDSv2 enforced | ✅ |
| S3 private (OAC only) | ✅ |
| All storage encrypted | ✅ |
| Fail2Ban + UFW | ✅ |
| xmlrpc.php blocked | ✅ |
| Security headers | ✅ |
| WP file editing disabled | ✅ |

---

## 🌍 Custom Domain + SSL

1. Uncomment ACM + HTTPS listener in `infra/alb.tf`
2. Set `domain_name = "yourdomain.com"` in terraform.tfvars
3. Push to main → deploys automatically
4. Add DNS CNAME: `yourdomain.com → ALB DNS`
5. SSL is automatic (ACM + ALB, free forever)

---

## 📦 Migrate from SiteGround

```bash
brew install --cask session-manager-plugin
chmod +x scripts/migrate.sh
./scripts/migrate.sh
```

Interactive script that: exports DB → imports to RDS → syncs media to S3 → updates URLs → clears cache.

---

## 📁 Files

```
├── .github/workflows/
│   ├── infra.yml          # OpenTofu plan + apply
│   ├── deploy.yml         # Cache, backup, restart, update
│   └── maintenance.yml    # Health checks + weekly patches
├── infra/
│   ├── main.tf            # VPC, Subnets, NAT, Routes
│   ├── ec2.tf             # Security Group, IAM, AMI
│   ├── alb.tf             # ALB, Target Group, Listeners
│   ├── autoscaling.tf     # Launch Template, ASG, Scaling
│   ├── rds.tf             # MySQL 8.0, Parameters
│   ├── s3-cloudfront.tf   # S3 + CloudFront CDN
│   ├── monitoring.tf      # CloudWatch Alarms, SNS
│   ├── state.tf           # Remote state (S3 + DynamoDB)
│   ├── userdata.sh        # Server bootstrap
│   └── variables.tf       # Inputs
├── scripts/
│   ├── migrate.sh         # SiteGround → AWS
│   └── ssl-setup.sh       # Domain SSL
└── README.md
```
