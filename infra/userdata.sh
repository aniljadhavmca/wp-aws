#!/bin/bash
set -euo pipefail
exec > /var/log/userdata.log 2>&1

echo "=== Starting WordPress Server Setup ==="
echo "Timestamp: $(date)"

# ─── SYSTEM UPDATE ─────────────────────────────────────────────────────────────
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
apt-get install -y curl unzip jq fail2ban ufw bc mysql-client-core-8.0

# ─── FAIL2BAN ──────────────────────────────────────────────────────────────────
systemctl enable fail2ban
systemctl start fail2ban

# ─── UFW FIREWALL ──────────────────────────────────────────────────────────────
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw --force enable

# ─── NGINX ─────────────────────────────────────────────────────────────────────
apt-get install -y nginx
systemctl enable nginx

# ─── PHP 8.2 ───────────────────────────────────────────────────────────────────
apt-get install -y software-properties-common
add-apt-repository -y ppa:ondrej/php
apt-get update
apt-get install -y php8.2-fpm php8.2-mysql php8.2-redis php8.2-curl \
  php8.2-gd php8.2-intl php8.2-mbstring php8.2-xml php8.2-zip \
  php8.2-soap php8.2-imagick php8.2-bcmath php8.2-opcache

# ─── REDIS ─────────────────────────────────────────────────────────────────────
apt-get install -y redis-server
systemctl enable redis-server

cat > /etc/redis/redis.conf <<'REDISCONF'
bind 127.0.0.1
port 6379
maxmemory 512mb
maxmemory-policy allkeys-lru
save 900 1
save 300 10
save 60 10000
tcp-keepalive 300
timeout 0
databases 16
REDISCONF
systemctl restart redis-server

# ─── PHP-FPM ──────────────────────────────────────────────────────────────────
cat > /etc/php/8.2/fpm/pool.d/wordpress.conf <<'PHPFPM'
[wordpress]
user = www-data
group = www-data
listen = /run/php/php8.2-fpm-wordpress.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 25
pm.start_servers = 5
pm.min_spare_servers = 3
pm.max_spare_servers = 10
pm.max_requests = 1000
pm.process_idle_timeout = 10s

php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 128M
php_admin_value[post_max_size] = 128M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_vars] = 5000
php_admin_flag[display_errors] = off
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/php/wordpress-error.log
PHPFPM

rm -f /etc/php/8.2/fpm/pool.d/www.conf
mkdir -p /var/log/php
chown www-data:www-data /var/log/php

# OPcache
cat > /etc/php/8.2/fpm/conf.d/99-opcache-prod.ini <<'OPCACHE'
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=20000
opcache.revalidate_freq=120
opcache.save_comments=1
opcache.fast_shutdown=1
opcache.validate_timestamps=0
OPCACHE

systemctl restart php8.2-fpm

# ─── NGINX CONFIG ──────────────────────────────────────────────────────────────
mkdir -p /var/cache/nginx/fastcgi
chown www-data:www-data /var/cache/nginx/fastcgi

cat > /etc/nginx/nginx.conf <<'NGINXMAIN'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
worker_rlimit_nofile 65535;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 128M;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 4;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;
    gzip_min_length 1000;

    fastcgi_cache_path /var/cache/nginx/fastcgi levels=1:2 keys_zone=WPCACHE:128m inactive=60m max_size=1g use_temp_path=off;
    fastcgi_cache_key "$scheme$request_method$host$request_uri";

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXMAIN

cat > /etc/nginx/sites-available/wordpress <<'NGINXSITE'
server {
    listen 80;
    server_name _;
    root /var/www/wordpress;
    index index.php;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # FastCGI cache bypass
    set $skip_cache 0;
    if ($request_method = POST) { set $skip_cache 1; }
    if ($query_string != "") { set $skip_cache 1; }
    if ($request_uri ~* "/wp-admin/|/wp-login.php|/cart/|/checkout/|/my-account/|/wc-api/") { set $skip_cache 1; }
    if ($http_cookie ~* "wordpress_logged_in|woocommerce_items_in_cart|woocommerce_cart_hash") { set $skip_cache 1; }

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.2-fpm-wordpress.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;

        fastcgi_cache WPCACHE;
        fastcgi_cache_valid 200 301 60m;
        fastcgi_cache_valid 404 1m;
        fastcgi_cache_bypass $skip_cache;
        fastcgi_no_cache $skip_cache;
        fastcgi_cache_use_stale error timeout updating invalid_header http_500 http_503;
        fastcgi_cache_lock on;
        add_header X-Cache-Status $upstream_cache_status;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|otf|webp|avif)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location = /xmlrpc.php { deny all; }
    location ~ /\.(ht|git|env) { deny all; }
    location ~ /wp-config.php { deny all; }

    location ~ ^/wp-json/ {
        try_files $uri $uri/ /index.php?$args;
    }

    location = /health {
        access_log off;
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
NGINXSITE

ln -sf /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# ─── WP-CLI ───────────────────────────────────────────────────────────────────
curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp

# ─── WORDPRESS DOWNLOAD & CONFIG ──────────────────────────────────────────────
mkdir -p /var/www/wordpress
cd /var/www/wordpress
sudo -u www-data wp core download --quiet

sudo -u www-data wp config create \
  --dbhost="${db_host}" \
  --dbname="${db_name}" \
  --dbuser="${db_user}" \
  --dbpass="${db_pass}" \
  --extra-php <<WPCONFIG
// Performance
define('WP_CACHE', true);
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_DATABASE', 0);

// S3 Media Offload
define('AS3CF_SETTINGS', serialize(array(
    'provider' => 'aws',
    'use-server-roles' => true,
    'bucket' => '${s3_bucket}',
    'region' => '${region}',
    'copy-to-s3' => true,
    'serve-from-s3' => true,
    'remove-local-file' => true,
)));

// Security
define('DISALLOW_FILE_EDIT', true);
define('WP_AUTO_UPDATE_CORE', 'minor');
define('FORCE_SSL_ADMIN', false);

// Performance
define('WP_POST_REVISIONS', 5);
define('AUTOSAVE_INTERVAL', 120);
define('EMPTY_TRASH_DAYS', 7);

// Memory
define('WP_MEMORY_LIMIT', '512M');
define('WP_MAX_MEMORY_LIMIT', '512M');
WPCONFIG

chown -R www-data:www-data /var/www/wordpress
find /var/www/wordpress -type d -exec chmod 755 {} \;
find /var/www/wordpress -type f -exec chmod 644 {} \;

# ─── WAIT FOR RDS ─────────────────────────────────────────────────────────────
echo "Waiting for RDS to accept connections..."
for i in $(seq 1 60); do
  if mysql -h "${db_host}" -u "${db_user}" -p"${db_pass}" -e "SELECT 1" &>/dev/null; then
    echo "RDS is ready!"
    break
  fi
  echo "Attempt $i/60 - waiting 10s..."
  sleep 10
done

# ─── INSTALL WORDPRESS ─────────────────────────────────────────────────────────
cd /var/www/wordpress

# Check if WP is already installed (for ASG scaled instances sharing same RDS)
if ! sudo -u www-data wp core is-installed 2>/dev/null; then
  echo "Installing WordPress (first instance)..."
  sudo -u www-data wp core install \
    --url="http://${alb_dns}" \
    --title="${wp_site_title}" \
    --admin_user="${wp_admin_user}" \
    --admin_password="${wp_admin_pass}" \
    --admin_email="${wp_admin_email}" \
    --skip-email

  # Install essential plugins
  sudo -u www-data wp plugin install redis-cache --activate
  sudo -u www-data wp redis enable
  sudo -u www-data wp plugin install wp-offload-media-lite --activate
  sudo -u www-data wp plugin install woocommerce --activate

  # SEO-friendly permalinks
  sudo -u www-data wp rewrite structure '/%postname%/' --hard

  # Cleanup defaults
  sudo -u www-data wp plugin delete hello akismet 2>/dev/null || true
  sudo -u www-data wp theme delete twentytwentyone twentytwentytwo 2>/dev/null || true
else
  echo "WordPress already installed (scaled instance). Activating Redis..."
  sudo -u www-data wp plugin install redis-cache --activate 2>/dev/null || true
  sudo -u www-data wp redis enable 2>/dev/null || true
fi

echo "───────────────────────────────────────────"
echo "✅ WordPress Ready!"
echo "───────────────────────────────────────────"
echo "Frontend: http://${alb_dns}"
echo "Admin:    http://${alb_dns}/wp-admin/"
echo "Username: ${wp_admin_user}"
echo "───────────────────────────────────────────"

# ─── AUTOMATED BACKUPS ─────────────────────────────────────────────────────────

cat > /usr/local/bin/wp-backup.sh <<'BACKUP'
#!/bin/bash
set -euo pipefail
TIMESTAMP=$(date +%Y%m%d_%H%M)
BACKUP_DIR="/tmp/wp-backup-$TIMESTAMP"
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

mkdir -p "$BACKUP_DIR"
cd /var/www/wordpress
sudo -u www-data wp db export "$BACKUP_DIR/database.sql" --quiet

tar -czf "$BACKUP_DIR/backup.tar.gz" -C "$BACKUP_DIR" database.sql

# Get backup bucket name (media bucket name with 'media' replaced by 'backups')
MEDIA_BUCKET=$(sudo -u www-data wp eval "echo AS3CF_SETTINGS ? unserialize(AS3CF_SETTINGS)['bucket'] : '';" 2>/dev/null || echo "")
BACKUP_BUCKET="$${MEDIA_BUCKET/media/backups}"

if [ -n "$BACKUP_BUCKET" ]; then
  aws s3 cp "$BACKUP_DIR/backup.tar.gz" "s3://$BACKUP_BUCKET/db/$TIMESTAMP.tar.gz" --region "$REGION" --quiet
fi

rm -rf "$BACKUP_DIR"
echo "Backup complete: $TIMESTAMP"
BACKUP
chmod +x /usr/local/bin/wp-backup.sh
echo "0 2 * * * root /usr/local/bin/wp-backup.sh" > /etc/cron.d/wp-backup

# ─── MEMORY MONITORING (drives Auto Scaling) ──────────────────────────────────

cat > /usr/local/bin/memory-monitor.sh <<'MEMMON'
#!/bin/bash
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
ASG_NAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance/aws:autoscaling:groupName 2>/dev/null || echo "")

MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_AVAILABLE=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))
MEM_PERCENT=$(echo "scale=2; $MEM_USED * 100 / $MEM_TOTAL" | bc)

# Per-instance metric
aws cloudwatch put-metric-data \
  --namespace "Custom/WordPress" \
  --metric-name "MemoryUtilization" \
  --value "$MEM_PERCENT" \
  --unit "Percent" \
  --dimensions "InstanceId=$INSTANCE_ID" \
  --region "$REGION"

# Per-ASG metric (for auto scaling decisions)
if [ -n "$ASG_NAME" ]; then
  aws cloudwatch put-metric-data \
    --namespace "Custom/WordPress" \
    --metric-name "MemoryUtilization" \
    --value "$MEM_PERCENT" \
    --unit "Percent" \
    --dimensions "AutoScalingGroupName=$ASG_NAME" \
    --region "$REGION"
fi
MEMMON
chmod +x /usr/local/bin/memory-monitor.sh
echo "* * * * * root /usr/local/bin/memory-monitor.sh" > /etc/cron.d/memory-monitor

# ─── DISK MONITORING ──────────────────────────────────────────────────────────

cat > /usr/local/bin/disk-monitor.sh <<'DISKMON'
#!/bin/bash
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')

aws cloudwatch put-metric-data \
  --namespace "Custom/WordPress" \
  --metric-name "DiskSpaceUtilization" \
  --value "$DISK_USAGE" \
  --unit "Percent" \
  --dimensions "InstanceId=$INSTANCE_ID" \
  --region "$REGION"
DISKMON
chmod +x /usr/local/bin/disk-monitor.sh
echo "*/5 * * * * root /usr/local/bin/disk-monitor.sh" > /etc/cron.d/disk-monitor

# ─── LOG ROTATION ─────────────────────────────────────────────────────────────
cat > /etc/logrotate.d/wordpress <<'LOGROTATE'
/var/log/nginx/*.log /var/log/php/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}
LOGROTATE

# ─── CLOUDWATCH AGENT ─────────────────────────────────────────────────────────
wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E amazon-cloudwatch-agent.deb
rm -f amazon-cloudwatch-agent.deb

echo "=== WordPress Server Setup Complete ==="
echo "Timestamp: $(date)"
