#!/bin/bash
set -euo pipefail
exec > /var/log/userdata.log 2>&1
echo "=== WordPress Setup Started: $(date) ==="

# Variables from OpenTofu
DB_HOST="${db_host}"
DB_NAME="${db_name}"
DB_USER="${db_user}"
DB_PASS="${db_pass}"
S3_BUCKET="${s3_bucket}"
REGION="${region}"
WP_ADMIN_USER="${wp_admin_user}"
WP_ADMIN_PASS="${wp_admin_pass}"
WP_ADMIN_EMAIL="${wp_admin_email}"
WP_SITE_TITLE="${wp_site_title}"
ALB_DNS="${alb_dns}"

export DEBIAN_FRONTEND=noninteractive

# System update + core packages
apt-get update && apt-get upgrade -y
apt-get install -y curl unzip jq fail2ban ufw bc nginx redis-server mysql-server software-properties-common

# PHP 8.2
add-apt-repository -y ppa:ondrej/php && apt-get update
apt-get install -y php8.2-fpm php8.2-mysql php8.2-redis php8.2-curl php8.2-gd \
  php8.2-intl php8.2-mbstring php8.2-xml php8.2-zip php8.2-soap php8.2-imagick \
  php8.2-bcmath php8.2-opcache

# Firewall
ufw default deny incoming && ufw default allow outgoing
ufw allow 80/tcp && ufw --force enable

# MySQL setup
systemctl enable mysql && systemctl start mysql
mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;"

# Redis
cat > /etc/redis/redis.conf <<'EOF'
bind 127.0.0.1
port 6379
maxmemory 512mb
maxmemory-policy allkeys-lru
save 900 1
save 300 10
EOF
systemctl enable redis-server && systemctl restart redis-server

# PHP-FPM
cat > /etc/php/8.2/fpm/pool.d/wordpress.conf <<'EOF'
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
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 128M
php_admin_value[post_max_size] = 128M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_vars] = 5000
php_admin_flag[display_errors] = off
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/php/wordpress-error.log
EOF
rm -f /etc/php/8.2/fpm/pool.d/www.conf
mkdir -p /var/log/php && chown www-data:www-data /var/log/php

cat > /etc/php/8.2/fpm/conf.d/99-opcache.ini <<'EOF'
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=20000
opcache.revalidate_freq=120
opcache.validate_timestamps=0
EOF
systemctl restart php8.2-fpm

# Nginx
mkdir -p /var/cache/nginx/fastcgi && chown www-data:www-data /var/cache/nginx/fastcgi

cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 4096; multi_accept on; }
http {
    sendfile on; tcp_nopush on; tcp_nodelay on;
    keepalive_timeout 30; server_tokens off;
    client_max_body_size 128M;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    gzip on; gzip_vary on; gzip_proxied any; gzip_comp_level 4;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;
    fastcgi_cache_path /var/cache/nginx/fastcgi levels=1:2 keys_zone=WPCACHE:128m inactive=60m max_size=1g use_temp_path=off;
    fastcgi_cache_key "$scheme$request_method$host$request_uri";
    include /etc/nginx/sites-enabled/*;
}
EOF

cat > /etc/nginx/sites-available/wordpress <<'EOF'
server {
    listen 80; server_name _; root /var/www/wordpress; index index.php;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    set $skip_cache 0;
    if ($request_method = POST) { set $skip_cache 1; }
    if ($query_string != "") { set $skip_cache 1; }
    if ($request_uri ~* "/wp-admin/|/wp-login.php|/cart/|/checkout/|/my-account/") { set $skip_cache 1; }
    if ($http_cookie ~* "wordpress_logged_in|woocommerce_items_in_cart") { set $skip_cache 1; }
    location / { try_files $uri $uri/ /index.php?$args; }
    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.2-fpm-wordpress.sock;
        fastcgi_index index.php; include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_cache WPCACHE; fastcgi_cache_valid 200 60m;
        fastcgi_cache_bypass $skip_cache; fastcgi_no_cache $skip_cache;
        add_header X-Cache-Status $upstream_cache_status;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2|webp)$ { expires 30d; access_log off; }
    location = /xmlrpc.php { deny all; }
    location ~ /\.(ht|git|env) { deny all; }
    location = /health { access_log off; return 200 'OK'; add_header Content-Type text/plain; }
}
EOF
ln -sf /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# WP-CLI
curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp

# WordPress
mkdir -p /var/www/wordpress
chown www-data:www-data /var/www/wordpress
cd /var/www/wordpress
sudo -u www-data wp core download --quiet
sudo -u www-data wp config create --dbhost="$DB_HOST" --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --extra-php <<WPCONF
define('WP_CACHE', true);
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('AS3CF_SETTINGS', serialize(array('provider'=>'aws','use-server-roles'=>true,'bucket'=>'$S3_BUCKET','region'=>'$REGION','copy-to-s3'=>true,'serve-from-s3'=>true,'remove-local-file'=>true)));
define('DISALLOW_FILE_EDIT', true);
define('WP_MEMORY_LIMIT', '512M');
define('WP_POST_REVISIONS', 5);
WPCONF

chown -R www-data:www-data /var/www/wordpress

# Install WordPress
if ! sudo -u www-data wp core is-installed 2>/dev/null; then
  sudo -u www-data wp core install --url="http://$ALB_DNS" --title="$WP_SITE_TITLE" \
    --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASS" --admin_email="$WP_ADMIN_EMAIL" --skip-email
  sudo -u www-data wp plugin install redis-cache --activate
  sudo -u www-data wp redis enable
  sudo -u www-data wp plugin install woocommerce --activate
  sudo -u www-data wp rewrite structure '/%postname%/' --hard
  sudo -u www-data wp plugin delete hello akismet 2>/dev/null || true
else
  sudo -u www-data wp plugin install redis-cache --activate 2>/dev/null || true
  sudo -u www-data wp redis enable 2>/dev/null || true
fi

# Memory monitor (for auto scaling)
cat > /usr/local/bin/memory-monitor.sh <<'MEMSCRIPT'
#!/bin/bash
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
RG=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
ASG=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance/aws:autoscaling:groupName 2>/dev/null || echo "")
MT=$(grep MemTotal /proc/meminfo|awk '{print $2}')
MA=$(grep MemAvailable /proc/meminfo|awk '{print $2}')
MP=$(echo "scale=0;($MT-$MA)*100/$MT"|bc)
aws cloudwatch put-metric-data --namespace "Custom/WordPress" --metric-name "MemoryUtilization" --value "$MP" --unit "Percent" --dimensions "InstanceId=$ID" --region "$RG"
[ -n "$ASG" ] && aws cloudwatch put-metric-data --namespace "Custom/WordPress" --metric-name "MemoryUtilization" --value "$MP" --unit "Percent" --dimensions "AutoScalingGroupName=$ASG" --region "$RG"
MEMSCRIPT
chmod +x /usr/local/bin/memory-monitor.sh
echo "* * * * * root /usr/local/bin/memory-monitor.sh" > /etc/cron.d/memory-monitor

# Daily backup
cat > /usr/local/bin/wp-backup.sh <<'BKSCRIPT'
#!/bin/bash
cd /var/www/wordpress
sudo -u www-data wp db export "/tmp/db-$(date +\%Y\%m\%d).sql" --quiet
gzip "/tmp/db-$(date +\%Y\%m\%d).sql"
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
RG=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
aws s3 cp "/tmp/db-$(date +\%Y\%m\%d).sql.gz" "s3://$${S3_BUCKET/media/backups}/db/" --region "$RG" --quiet 2>/dev/null || true
rm -f /tmp/db-*.sql.gz
BKSCRIPT
chmod +x /usr/local/bin/wp-backup.sh
echo "0 2 * * * root /usr/local/bin/wp-backup.sh" > /etc/cron.d/wp-backup

# Fail2Ban + CloudWatch agent
systemctl enable fail2ban && systemctl start fail2ban
wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E amazon-cloudwatch-agent.deb && rm -f amazon-cloudwatch-agent.deb

echo "✅ WordPress Ready!"
echo "Frontend: http://$ALB_DNS"
echo "Admin: http://$ALB_DNS/wp-admin/"
echo "=== Setup Complete: $(date) ==="
