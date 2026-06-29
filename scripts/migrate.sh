#!/bin/bash
set -euo pipefail

# ─── WordPress Migration: SiteGround → AWS ─────────────────────────────────────
# This script uses AWS SSM to communicate with the private EC2 instance.
# Prerequisites: AWS CLI configured, SSM plugin installed
#
# Install SSM plugin: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
#
# Usage: ./migrate.sh

echo "============================================"
echo "  WordPress Migration: SiteGround → AWS"
echo "============================================"
echo ""

# Get instance ID from ASG
ASG_NAME="wp-prod-asg"
REGION="us-east-1"

echo "Finding EC2 instance..."
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' \
  --output text --region "$REGION")

if [ "$INSTANCE_ID" == "None" ] || [ -z "$INSTANCE_ID" ]; then
  echo "❌ No running instance found in ASG: $ASG_NAME"
  exit 1
fi
echo "✅ Found instance: $INSTANCE_ID"

# Get ALB DNS
ALB_DNS=$(aws elbv2 describe-load-balancers --names "wp-prod-alb" \
  --query 'LoadBalancers[0].DNSName' --output text --region "$REGION")
echo "✅ ALB: $ALB_DNS"

# Get S3 bucket
S3_BUCKET=$(aws s3 ls | grep "wp-prod-media" | awk '{print $3}')
echo "✅ S3: $S3_BUCKET"
echo ""

# Step 1: Export database
echo "─── Step 1: Export Database from SiteGround ───"
echo ""
echo "  Export your database from SiteGround:"
echo "  - SiteGround Site Tools → Site → MySQL → phpMyAdmin → Export"
echo "  - Or SSH: mysqldump -u <user> -p <dbname> > wp_backup.sql"
echo ""
read -p "Path to exported SQL file (local): " SQL_FILE

if [ ! -f "$SQL_FILE" ]; then
  echo "❌ File not found: $SQL_FILE"
  exit 1
fi

# Step 2: Upload SQL to S3 (since EC2 is private, we go through S3)
echo ""
echo "─── Step 2: Upload SQL dump to S3 ───"
aws s3 cp "$SQL_FILE" "s3://$S3_BUCKET/migration/database.sql" --region "$REGION"
echo "✅ SQL uploaded to S3"

# Step 3: Import to RDS via SSM
echo ""
echo "─── Step 3: Import Database to RDS ───"
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    \"aws s3 cp s3://$S3_BUCKET/migration/database.sql /tmp/database.sql\",
    \"cd /var/www/wordpress\",
    \"sudo -u www-data wp db import /tmp/database.sql\",
    \"rm /tmp/database.sql\"
  ]" \
  --comment "Migration: Import database" \
  --region "$REGION" \
  --output text
echo "✅ Database import command sent. Wait 1-2 minutes..."
sleep 30

# Step 4: Sync media to S3
echo ""
echo "─── Step 4: Sync Media Files to S3 ───"
read -p "Path to wp-content/uploads/ folder (local): " UPLOADS_DIR
aws s3 sync "$UPLOADS_DIR" "s3://$S3_BUCKET/wp-content/uploads/" --region "$REGION"
echo "✅ Media synced to S3"

# Step 5: Sync plugins and themes
echo ""
echo "─── Step 5: Sync Plugins & Themes ───"
read -p "Path to wp-content/ folder (local): " WPCONTENT_DIR

# Upload to S3 first, then pull from EC2
aws s3 sync "$WPCONTENT_DIR/plugins/" "s3://$S3_BUCKET/migration/plugins/" --region "$REGION"
aws s3 sync "$WPCONTENT_DIR/themes/" "s3://$S3_BUCKET/migration/themes/" --region "$REGION"

aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    \"aws s3 sync s3://$S3_BUCKET/migration/plugins/ /var/www/wordpress/wp-content/plugins/\",
    \"aws s3 sync s3://$S3_BUCKET/migration/themes/ /var/www/wordpress/wp-content/themes/\",
    \"chown -R www-data:www-data /var/www/wordpress/wp-content/\"
  ]" \
  --comment "Migration: Sync plugins and themes" \
  --region "$REGION" \
  --output text
echo "✅ Plugins & themes synced"

# Step 6: Search-replace URLs
echo ""
echo "─── Step 6: Update URLs ───"
read -p "Old domain (e.g., yoursite.com): " OLD_DOMAIN

aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    \"cd /var/www/wordpress\",
    \"sudo -u www-data wp search-replace '$OLD_DOMAIN' '$ALB_DNS' --all-tables --precise\",
    \"sudo -u www-data wp plugin install redis-cache --activate\",
    \"sudo -u www-data wp redis enable\",
    \"sudo -u www-data wp cache flush\",
    \"sudo rm -rf /var/cache/nginx/fastcgi/*\",
    \"sudo systemctl restart php8.2-fpm\",
    \"sudo systemctl reload nginx\"
  ]" \
  --comment "Migration: URL replacement and cache clear" \
  --region "$REGION" \
  --output text

# Cleanup migration files from S3
aws s3 rm "s3://$S3_BUCKET/migration/" --recursive --region "$REGION"

echo ""
echo "============================================"
echo "  ✅ Migration Complete!"
echo "============================================"
echo ""
echo "  Frontend: http://$ALB_DNS"
echo "  Admin:    http://$ALB_DNS/wp-admin/"
echo ""
echo "  Next steps:"
echo "  1. Test all pages + WooCommerce checkout"
echo "  2. Point DNS CNAME to: $ALB_DNS"
echo "  3. Uncomment ACM cert in alb.tf for free SSL"
echo "  4. Run: tofu apply"
echo "============================================"
