#!/bin/bash
set -euo pipefail

# ─── SSL Setup with Let's Encrypt ──────────────────────────────────────────────
# Run this AFTER DNS is pointed to EC2 IP
# Usage: ./ssl-setup.sh yourdomain.com

DOMAIN="${1:?Usage: ./ssl-setup.sh yourdomain.com}"

echo "Setting up SSL for: $DOMAIN"

# Install Certbot
apt-get install -y certbot python3-certbot-nginx

# Get certificate
certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --non-interactive --agree-tos --email "admin@$DOMAIN"

# Auto-renewal cron
echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" > /etc/cron.d/certbot-renew

# Update WordPress URLs
cd /var/www/wordpress
sudo -u www-data wp option update siteurl "https://$DOMAIN"
sudo -u www-data wp option update home "https://$DOMAIN"

echo "✅ SSL configured for $DOMAIN"
echo "   Auto-renewal enabled via cron"
