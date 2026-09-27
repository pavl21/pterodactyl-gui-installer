#!/bin/bash
# Pfad: lib/pelican.sh
# Pelican Panel (Beta, https://pelican.dev) und Pelican Wings – Installation nach offizieller Dokumentation.
# Pelican bringt Deutsch bereits mit (APP_LOCALE=de), GermanDactyl wird hier nicht benötigt.
# Benötigt lib/common.sh, lib/security.sh und lib/panel.sh (PHP-Repository, Composer).

PELICAN_DIR="/var/www/pelican"
PELICAN_PHP="8.4"
PELICAN_WINGS_CONFIG="/etc/pelican/config.yml"
PELICAN_WINGS_BIN="/usr/local/bin/wings"

gd_pelican_packages() {
    local v="$PELICAN_PHP"
    gd_apt_install "php${v}" "php${v}-cli" "php${v}-common" "php${v}-gd" "php${v}-mysql" "php${v}-mbstring" \
        "php${v}-bcmath" "php${v}-xml" "php${v}-fpm" "php${v}-curl" "php${v}-zip" "php${v}-intl" "php${v}-sqlite3" \
        nginx sqlite3 tar unzip git cron certbot python3-certbot-nginx || return 1
    update-alternatives --set php "/usr/bin/php${v}" 2>/dev/null
    gd_nginx_disable_default
    systemctl enable --now "php${v}-fpm" cron || return 1
    systemctl enable nginx && systemctl restart nginx
}

gd_pelican_download() {
    mkdir -p "$PELICAN_DIR"
    curl -fL "https://github.com/pelican/panel/releases/latest/download/panel.tar.gz" -o "$GD_TMP/pelican.tar.gz" || return 1
    tar -xzf "$GD_TMP/pelican.tar.gz" -C "$PELICAN_DIR" || return 1
    cd "$PELICAN_DIR" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
}

gd_pelican_nginx() {
    # gd_pelican_nginx <domain> <http|ssl>
    local domain="$1" mode="$2" sock="/run/php/php${PELICAN_PHP}-fpm.sock"
    if [ "$mode" = "http" ]; then
        cat > /etc/nginx/sites-available/pelican.conf <<EOF
# Angelegt von GermanDactyl Setup (vorläufig, wird nach der Zertifikatsausstellung ersetzt)
server {
    listen 80;
    server_name ${domain};
    root ${PELICAN_DIR}/public;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 503; }
}
EOF
    else
        cat > /etc/nginx/sites-available/pelican.conf <<EOF
# Angelegt von GermanDactyl Setup – Grundlage: offizielle Pelican-Dokumentation
server_tokens off;

server {
    listen 80;
    server_name ${domain};
    location /.well-known/acme-challenge/ { root ${PELICAN_DIR}/public; allow all; }
    location / { return 301 https://\$server_name\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    root ${PELICAN_DIR}/public;
    index index.php;

    access_log /var/log/nginx/pelican.app-access.log;
    error_log  /var/log/nginx/pelican.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${sock};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
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
    fi
    ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
    gd_nginx_disable_default
    nginx -t && systemctl reload nginx
}

gd_pelican_certbot() {
    local domain="$1" email="$2"
    [ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ] && return 0
    certbot certonly --webroot -w "${PELICAN_DIR}/public" -d "$domain" \
        --email "$email" --agree-tos --no-eff-email --non-interactive
}

gd_pelican_env_set() {
    local file="$PELICAN_DIR/.env"
    if grep -q "^$1=" "$file"; then
        sed -i "s|^$1=.*|$1=$2|" "$file"
    else
        # Die .env endet oft ohne Zeilenumbruch – sonst würde der neue Eintrag an die letzte Zeile angehängt
        [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ] && echo >> "$file"
        echo "$1=$2" >> "$file"
    fi
}

gd_pelican_configure() {
    # gd_pelican_configure <domain> <email> <benutzer> <passwort> – ohne Web-Installer (SQLite-Datenbank)
    local domain="$1" email="$2" user="$3" pw="$4"
    cd "$PELICAN_DIR" || return 1
    php artisan p:environment:setup --no-interaction || return 1
    gd_pelican_env_set APP_URL "https://${domain}"
    gd_pelican_env_set APP_LOCALE de
    gd_pelican_env_set APP_TIMEZONE "$GD_TIMEZONE"
    gd_pelican_env_set DB_CONNECTION sqlite
    touch database/database.sqlite
    php artisan migrate --seed --force || return 1
    php artisan p:user:make --no-interaction --email="$email" --username="$user" --password="$pw" --admin=1 || return 1
    gd_pelican_env_set APP_INSTALLED true
    php artisan optimize:clear
    chmod -R 755 storage/* bootstrap/cache/
    chown -R www-data:www-data "$PELICAN_DIR"
}

gd_pelican_services() {
    local cron_line="* * * * * /usr/bin/php${PELICAN_PHP} ${PELICAN_DIR}/artisan schedule:run >> /dev/null 2>&1"
    { crontab -l 2>/dev/null | grep -vF "${PELICAN_DIR}/artisan schedule:run"; echo "$cron_line"; } | crontab - || return 1
    # Entspricht "php artisan p:environment:queue-service", aber direkt geschrieben: der Befehl
    # weicht bei vorhandener /.dockerenv auf supervisor aus und liefert bei Fehlern trotzdem Exit-Code 0
    cat > /etc/systemd/system/pelican-queue.service <<EOF_SVC || return 1
# Pelican Queue File – angelegt von GermanDactyl Setup
[Unit]
Description=Pelican Queue Service
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php${PELICAN_PHP} ${PELICAN_DIR}/artisan queue:work --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF_SVC
    systemctl daemon-reload
    systemctl enable --now pelican-queue
}

gd_pelican_artisan_www() {
    (cd "$PELICAN_DIR" && runuser -u www-data -- env HOME=/tmp php artisan "$@")
}

gd_pelican_healthcheck() {
    local domain="$1" code i
    for i in 1 2 3 4 5; do
        code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${domain}:443:127.0.0.1" "https://${domain}/login")"
        echo "HTTP-Status der Anmeldeseite: $code"
        case "$code" in 200|302) return 0 ;; esac
        sleep 3
    done
    return 1
}

# ---------------------------------------------------------------------------
# Pelican Wings
# ---------------------------------------------------------------------------
gd_pelican_wings_binary() {
    local arch
    arch="$(gd_arch)"
    case "$arch" in amd64|arm64) ;; *) echo "Nicht unterstützte Architektur: $arch"; return 1 ;; esac
    mkdir -p /etc/pelican /var/lib/pelican/volumes
    curl -fL "https://github.com/pelican/wings/releases/latest/download/wings_linux_${arch}" -o "$GD_TMP/wings" || return 1
    install -m 0755 "$GD_TMP/wings" "$PELICAN_WINGS_BIN"
}

gd_pelican_wings_service() {
    # Service-Datei zuerst schreiben, danach aktivieren
    cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
PIDFile=/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable wings
}

gd_pelican_node() {
    # gd_pelican_node <fqdn> – Node anlegen und Konfiguration schreiben
    local fqdn="$1" out mem disk
    mem="$(LC_ALL=C free -m | awk '/^Mem:/{print $2}')"; mem=$((mem - 1024)); [ "$mem" -lt 1024 ] && mem=1024
    disk="$(df -Pm /var/lib/pelican | awk 'NR==2{print $4}')"; disk=$((disk * 90 / 100))
    out="$(gd_pelican_artisan_www p:node:make --no-interaction --name="Node-$(hostname -s)" \
        --description="Automatisch eingerichtet von GermanDactyl Setup" --fqdn="$fqdn" --scheme=https \
        --public=1 --proxy=0 --maintenance=0 --maxMemory="$mem" --overallocateMemory=0 --maxDisk="$disk" \
        --overallocateDisk=0 --maxCpu=0 --overallocateCpu=-1 --uploadSize=100 --daemonListeningPort=8080 \
        --daemonConnectingPort=8080 --daemonSFTPPort=2022 --daemonSFTPAlias="" --daemonBase=/var/lib/pelican/volumes)" \
        || { echo "$out"; return 1; }
    echo "$out"
    # Meldung ist übersetzt (APP_LOCALE=de: "... hat die ID 1", englisch: "... has an id of 1")
    GD_NODE_ID="$(grep -oiE '(id of|id) [0-9]+' <<< "$out" | grep -oE '[0-9]+' | tail -n1)"
    [ -n "$GD_NODE_ID" ] || return 1
    gd_pelican_artisan_www p:node:configuration "$GD_NODE_ID" --format=yaml > "$GD_TMP/pelican-config.yml" || return 1
    grep -q '^token:' "$GD_TMP/pelican-config.yml" || return 1
    install -m 600 "$GD_TMP/pelican-config.yml" "$PELICAN_WINGS_CONFIG"
}

gd_pelican_allocations() {
    local range="$1" ip
    ip="$(gd_local_ip)"
    [ -z "$ip" ] && ip="$(gd_public_ip)"
    gd_pelican_artisan_www tinker --execute="app(\\App\\Services\\Allocations\\AssignmentService::class)->handle(\\App\\Models\\Node::findOrFail(${GD_NODE_ID}), ['allocation_ip' => '${ip}', 'allocation_ports' => ['${range}']]); echo 'OK';" | grep -q OK
}
