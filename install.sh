#!/usr/bin/env bash
# Fully automatic Pterodactyl Panel + Wings installer (same machine)
# Ubuntu 22.04, zero prompts.
#
#   sudo bash install-pterodactyl.sh --fqdn panel.example.com --email you@example.com
#
# Cloudflare Tunnel: add  --tunnel --node-fqdn node.example.com [--cf-token TOKEN]
# Optional: --tz Asia/Kolkata  --admin-user admin  --admin-pass 'Secret123'  --node-name Node1
# Credentials are printed at the end and saved to /root/pterodactyl-credentials.txt

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
export COMPOSER_ALLOW_SUPERUSER=1

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; N='\033[0m'
log()  { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
die()  { echo -e "${R}[x]${N} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 ..."

FQDN=""; EMAIL=""; TZ_NAME="Asia/Kolkata"
ADMIN_USER="admin"; ADMIN_PASS=""; NODE_NAME="Node1"
TUNNEL=0; NODE_FQDN=""; CF_TOKEN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tunnel)     TUNNEL=1; shift ;;            # Cloudflare Tunnel mode (no certbot, no public 80/443)
    --node-fqdn)  NODE_FQDN="$2"; shift 2 ;;    # tunnel mode: hostname that routes to Wings
    --cf-token)   CF_TOKEN="$2"; shift 2 ;;     # tunnel mode: optional, installs cloudflared with this token
    --fqdn)       FQDN="$2"; shift 2 ;;
    --email)      EMAIL="$2"; shift 2 ;;
    --tz)         TZ_NAME="$2"; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --admin-pass) ADMIN_PASS="$2"; shift 2 ;;
    --node-name)  NODE_NAME="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ -n "$FQDN" && -n "$EMAIL" ]] || die "Usage: bash $0 --fqdn panel.example.com --email you@example.com [--tunnel --node-fqdn node.example.com [--cf-token TOKEN]]"
if [[ $TUNNEL -eq 1 ]]; then
  [[ -n "$NODE_FQDN" ]] || die "Tunnel mode needs --node-fqdn (a second hostname routed to Wings, e.g. node.example.com)"
  [[ "$NODE_FQDN" != "$FQDN" ]] || die "--node-fqdn must differ from --fqdn"
else
  NODE_FQDN="$FQDN"
fi

rand() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}"; }
DB_PASS="$(rand 28)"
[[ -n "$ADMIN_PASS" ]] || ADMIN_PASS="$(rand 16)"
PANEL_DIR=/var/www/pterodactyl

. /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "22.04" ]] || warn "Built for Ubuntu 22.04, found ${PRETTY_NAME}. Continuing."

# ---------------- base ----------------
log "Installing base packages"
apt-get update -y
apt-get install -y software-properties-common curl ca-certificates gnupg lsb-release \
  tar unzip git dnsutils ufw cron

# ---------------- DNS check ----------------
SERVER_IP="$(curl -fsS https://api.ipify.org || true)"
DNS_IP="$(dig +short "$FQDN" | tail -n1 || true)"
if [[ $TUNNEL -eq 0 && -n "$SERVER_IP" && "$SERVER_IP" != "$DNS_IP" ]]; then
  die "DNS for ${FQDN} points to '${DNS_IP:-nothing}', but this server is ${SERVER_IP}.
    Create an A record -> ${SERVER_IP} (DNS-only / grey cloud if on Cloudflare), wait a minute, re-run."
fi

# ---------------- PHP / DB / web ----------------
log "Adding PHP repo and installing PHP 8.3, MariaDB, Nginx, Redis, Certbot"
add-apt-repository -y ppa:ondrej/php
apt-get update -y
apt-get install -y php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl} \
  mariadb-server nginx redis-server certbot
systemctl enable --now mariadb redis-server php8.3-fpm

log "Installing Composer"
curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# ---------------- SSL / firewall ----------------
log "Opening firewall"
ufw allow 22/tcp >/dev/null; ufw allow 2022/tcp >/dev/null
if [[ $TUNNEL -eq 0 ]]; then
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw allow 8080/tcp >/dev/null
fi
ufw --force enable >/dev/null

systemctl stop nginx || true
rm -f /etc/nginx/sites-enabled/default
if [[ $TUNNEL -eq 0 ]]; then
  log "Issuing Let's Encrypt certificate"
  certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL" -d "$FQDN" \
    --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  printf '#!/bin/sh\nsystemctl restart wings 2>/dev/null || true\n' > /etc/letsencrypt/renewal-hooks/deploy/wings-restart.sh
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/wings-restart.sh
else
  log "Tunnel mode: skipping Let's Encrypt (Cloudflare terminates TLS)"
  if [[ -n "$CF_TOKEN" ]]; then
    log "Installing cloudflared"
    case "$(uname -m)" in x86_64) CFA=amd64 ;; aarch64) CFA=arm64 ;; *) die "Unsupported arch" ;; esac
    curl -fsSL -o /tmp/cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CFA}.deb"
    dpkg -i /tmp/cloudflared.deb
    cloudflared service install "$CF_TOKEN"
  fi
fi

# ---------------- database ----------------
log "Creating database"
mysql -u root <<SQL
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
CREATE DATABASE IF NOT EXISTS panel;
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

# ---------------- panel ----------------
log "Downloading Panel"
mkdir -p "$PANEL_DIR"; cd "$PANEL_DIR"
curl -fsSL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz; rm -f panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
cp -n .env.example .env

log "Installing PHP dependencies (a few minutes)"
composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force

log "Configuring Panel"
php artisan p:environment:setup --no-interaction \
  --author="$EMAIL" --url="https://${FQDN}" --timezone="$TZ_NAME" \
  --cache=redis --session=redis --queue=redis \
  --redis-host=127.0.0.1 --redis-pass=null --redis-port=6379 --settings-ui=true
php artisan p:environment:database --no-interaction \
  --host=127.0.0.1 --port=3306 --database=panel --username=pterodactyl --password="$DB_PASS"
php artisan migrate --seed --force

log "Creating admin user"
php artisan p:user:make --no-interaction \
  --email="$EMAIL" --username="$ADMIN_USER" --name-first=Admin --name-last=User \
  --password="$ADMIN_PASS" --admin=1

# ---------------- cron + queue worker ----------------
echo "* * * * * root php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1" > /etc/cron.d/pterodactyl
cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# ---------------- nginx ----------------
log "Configuring Nginx"
cat > /etc/nginx/sites-available/pterodactyl.conf <<'EOF'
server {
    listen 80;
    server_name __FQDN__;
    return 301 https://$server_name$request_uri;
}
server {
    listen 443 ssl http2;
    server_name __FQDN__;
    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate /etc/letsencrypt/live/__FQDN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__FQDN__/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF
sed -i "s/__FQDN__/${FQDN}/g" /etc/nginx/sites-available/pterodactyl.conf
if [[ $TUNNEL -eq 1 ]]; then
  # Cloudflare terminates TLS; nginx only listens on localhost:80
  cat > /etc/nginx/sites-available/pterodactyl.conf <<'EOF'
server {
    listen 127.0.0.1:80;
    server_name __FQDN__;
    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param HTTPS on;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF
  sed -i "s/__FQDN__/${FQDN}/g" /etc/nginx/sites-available/pterodactyl.conf
fi
ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t

chown -R www-data:www-data "${PANEL_DIR}"/*
chown www-data:www-data "${PANEL_DIR}/.env"
systemctl daemon-reload
systemctl enable --now pteroq.service
systemctl restart php8.3-fpm
systemctl enable nginx; systemctl restart nginx

# ---------------- docker + wings ----------------
log "Installing Docker"
command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

log "Downloading Wings"
mkdir -p /etc/pterodactyl /var/lib/pterodactyl/{volumes,archive,backups} /var/log/pterodactyl
case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; *) die "Unsupported arch $(uname -m)" ;; esac
curl -fsSL -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH}"
chmod u+x /usr/local/bin/wings

# ---------------- auto-create location + node, pull wings config ----------------
log "Creating location and node in the Panel"
cd "$PANEL_DIR"
MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
DISK_MB=$(df -m --output=avail / | tail -n1 | tr -d ' ')
DISK_MB=$(( DISK_MB * 80 / 100 ))

php artisan p:location:make --no-interaction --short=main --long="Main Location"
LOC_ID=$(mysql -N -u root panel -e "SELECT id FROM locations ORDER BY id DESC LIMIT 1;")
php artisan p:node:make --no-interaction \
  --name="$NODE_NAME" --description="Auto-created node" --locationId="$LOC_ID" \
  --fqdn="$NODE_FQDN" --public=1 --scheme=https --proxy="$TUNNEL" --maintenance=0 \
  --maxMemory="$MEM_MB" --overallocateMemory=0 \
  --maxDisk="$DISK_MB" --overallocateDisk=0 \
  --uploadSize=100 --daemonListeningPort="$([[ $TUNNEL -eq 1 ]] && echo 443 || echo 8080)" --daemonSFTPPort=2022 \
  --daemonBase=/var/lib/pterodactyl/volumes
NODE_ID=$(mysql -N -u root panel -e "SELECT id FROM nodes ORDER BY id DESC LIMIT 1;")
[[ -n "$NODE_ID" ]] || die "Node creation failed"

php artisan p:node:configuration "$NODE_ID" > /etc/pterodactyl/config.yml
[[ -s /etc/pterodactyl/config.yml ]] || die "Could not generate Wings config"
chmod 600 /etc/pterodactyl/config.yml
if [[ $TUNNEL -eq 1 ]]; then
  # Panel talks to https://NODE_FQDN:443 via Cloudflare; Wings itself listens on plain HTTP 8080 locally
  sed -i '0,/^  port: [0-9]*/s//  port: 8080/' /etc/pterodactyl/config.yml
  grep -q '^  port: 8080' /etc/pterodactyl/config.yml || die "Could not set Wings api port to 8080 in config.yml"
fi

cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now wings
sleep 4
systemctl is-active --quiet wings || { journalctl -u wings -n 30 --no-pager; die "Wings failed to start"; }

# ---------------- done ----------------
cat > /root/pterodactyl-credentials.txt <<EOF
Panel URL : https://${FQDN}
Username  : ${ADMIN_USER}
Email     : ${EMAIL}
Password  : ${ADMIN_PASS}
DB user   : pterodactyl
DB pass   : ${DB_PASS}
Node      : ${NODE_NAME} (id ${NODE_ID}) -> ${NODE_FQDN}
EOF
chmod 600 /root/pterodactyl-credentials.txt

echo
log "ALL DONE"
cat /root/pterodactyl-credentials.txt
echo
if [[ $TUNNEL -eq 1 ]]; then
  warn "TUNNEL MODE: in Cloudflare Zero Trust > Tunnels > Public hostnames, add:"
  warn "   ${FQDN}       ->  HTTP  localhost:80"
  warn "   ${NODE_FQDN}  ->  HTTP  localhost:8080"
fi
warn "Saved to /root/pterodactyl-credentials.txt. Node should show a green heart in Admin > Nodes."
