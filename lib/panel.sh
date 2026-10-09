#!/bin/bash
# Pfad: lib/panel.sh
# Eigenständige Installation und Aktualisierung des Pterodactyl Panels nach offizieller Dokumentation
# (https://pterodactyl.io/panel/1.0/getting_started.html). Benötigt lib/common.sh und lib/germandactyl.sh.

GD_PANEL_DB="panel"
GD_PANEL_DB_USER="pterodactyl"

# ---------------------------------------------------------------------------
# Einzelschritte
# ---------------------------------------------------------------------------
gd_php_repo() {
    # PHP über das sury-Repository (Debian und Ubuntu, auch Ubuntu 26.04)
    gd_os_detect
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury-php.gpg || return 1
    echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${GD_OS_CODENAME} main" \
        > /etc/apt/sources.list.d/sury-php.list
    # Alte Einträge früherer Versionen dieses Skripts entfernen (doppelte Quellen führen zu apt-Warnungen)
    rm -f /etc/apt/sources.list.d/php.list /etc/apt/trusted.gpg.d/php.gpg
    gd_apt update
}

gd_php_packages() {
    local v="$GD_PHP_VERSION"
    gd_apt_install "php${v}" "php${v}-cli" "php${v}-common" "php${v}-gd" "php${v}-mysql" "php${v}-mbstring" \
        "php${v}-bcmath" "php${v}-xml" "php${v}-fpm" "php${v}-curl" "php${v}-zip" "php${v}-intl" || return 1
    update-alternatives --set php "/usr/bin/php${v}" 2>/dev/null
    systemctl enable --now "php${v}-fpm"
}

gd_nginx_disable_default() {
    # Die Standardseite von nginx nur entfernen, wenn es die unveränderte Vorgabe ist. Sie lauscht auch auf
    # [::]:80 – auf Servern ohne IPv6 startet nginx deshalb direkt nach der Installation nicht.
    if [ -L /etc/nginx/sites-enabled/default ] && [ "$(readlink -f /etc/nginx/sites-enabled/default)" = "/etc/nginx/sites-available/default" ]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
    return 0
}

gd_panel_packages() {
    gd_apt_install mariadb-server mariadb-client nginx redis-server tar unzip git cron \
        certbot python3-certbot-nginx || return 1
    gd_nginx_disable_default
    systemctl enable --now mariadb redis-server cron || return 1
    systemctl enable nginx && systemctl restart nginx
}

gd_composer_install() {
    # Composer mit Prüfung der offiziellen Signatur installieren
    local expected actual
    expected="$(curl -fsSL https://composer.github.io/installer.sig)" || return 1
    curl -fsSL https://getcomposer.org/installer -o "$GD_TMP/composer-setup.php" || return 1
    actual="$(php -r "echo hash_file('sha384', '$GD_TMP/composer-setup.php');")"
    if [ "$expected" != "$actual" ]; then
        echo "Die Signatur des Composer-Installers stimmt nicht überein – Abbruch."
        return 1
    fi
    php "$GD_TMP/composer-setup.php" --quiet --install-dir=/usr/local/bin --filename=composer
}

gd_panel_download() {
    # gd_panel_download <version> – lädt genau diese Version herunter und entpackt sie nach $PTERO_DIR
    local version="$1"
    mkdir -p "$PTERO_DIR"
    curl -fL "https://github.com/pterodactyl/panel/releases/download/v${version}/panel.tar.gz" -o "$GD_TMP/panel.tar.gz" || return 1
    tar -xzf "$GD_TMP/panel.tar.gz" -C "$PTERO_DIR" || return 1
    chmod -R 755 "$PTERO_DIR"/storage/* "$PTERO_DIR"/bootstrap/cache/
}

gd_nginx_backup() {
    # gd_nginx_backup <site.conf> – vorhandene Site-Konfiguration vor dem Überschreiben sichern
    if [ -f "/etc/nginx/sites-available/$1" ]; then
        cp -p "/etc/nginx/sites-available/$1" "$GD_TMP/nginx-$1.bak"
    else
        rm -f "$GD_TMP/nginx-$1.bak"
    fi
}

gd_nginx_activate() {
    # gd_nginx_activate <site.conf> – aktivieren und testen; bei Fehler den vorherigen Stand
    # wiederherstellen, damit nginx (und andere Seiten auf dem Server) weiterlaufen
    local name="$1"
    ln -sf "/etc/nginx/sites-available/$name" "/etc/nginx/sites-enabled/$name"
    if nginx -t; then
        systemctl reload nginx || systemctl restart nginx
        return
    fi
    echo "Die neue nginx-Konfiguration ist fehlerhaft (siehe oben) – der vorherige Stand wird wiederhergestellt."
    if [ -f "$GD_TMP/nginx-$name.bak" ]; then
        cp -p "$GD_TMP/nginx-$name.bak" "/etc/nginx/sites-available/$name"
    else
        rm -f "/etc/nginx/sites-enabled/$name"
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    return 1
}

gd_nginx_http_config() {
    # Vorläufige Konfiguration nur für die Zertifikatsausstellung (Webroot-Verfahren)
    local domain="$1"
    gd_nginx_backup pterodactyl.conf
    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
# Angelegt von GermanDactyl Setup (vorläufig, wird nach der Zertifikatsausstellung ersetzt)
server {
    listen 80;
    server_name ${domain};
    server_tokens off;
    root ${PTERO_DIR}/public;

    location /.well-known/acme-challenge/ {
        allow all;
    }
    location / {
        return 503;
    }
}
EOF
    gd_nginx_disable_default
    gd_nginx_activate pterodactyl.conf
}

gd_php_fpm_socket() {
    # Aktuell installierten PHP-FPM-Socket ermitteln (neueste Version zuerst)
    local sock
    sock="/run/php/php${GD_PHP_VERSION}-fpm.sock"
    if [ ! -S "$sock" ]; then
        sock="$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1)"
    fi
    echo "${sock:-/run/php/php${GD_PHP_VERSION}-fpm.sock}"
}

gd_nginx_ssl_config() {
    # Offizielle SSL-Konfiguration (https://pterodactyl.io/panel/1.0/webserver_configuration.html)
    local domain="$1" sock
    sock="$(gd_php_fpm_socket)"
    gd_nginx_backup pterodactyl.conf
    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
# Angelegt von GermanDactyl Setup – Grundlage: offizielle Pterodactyl-Dokumentation
server {
    listen 80;
    server_name ${domain};
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root ${PTERO_DIR}/public;
        allow all;
    }
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${domain};
    server_tokens off;

    root ${PTERO_DIR}/public;
    index index.php;
$( [ -f /etc/nginx/snippets/germandactyl-phpmyadmin.conf ] && echo "    include snippets/germandactyl-phpmyadmin.conf;" )

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    # allow larger file uploads and longer script runtimes
    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    # See https://hstspreload.org/ before uncommenting the line below.
    # add_header Strict-Transport-Security "max-age=15768000; preload;";
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
    gd_nginx_activate pterodactyl.conf
}

gd_certbot_issue() {
    # gd_certbot_issue <domain> <email> – Zertifikat per Webroot (nginx läuft dabei weiter)
    local domain="$1" email="$2"
    if [ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
        echo "Zertifikat für ${domain} ist bereits vorhanden."
        return 0
    fi
    certbot certonly --webroot -w "${PTERO_DIR}/public" -d "$domain" \
        --email "$email" --agree-tos --no-eff-email --non-interactive
}

gd_panel_database() {
    # Datenbank und Benutzer anlegen (nur Rechte auf die Panel-Datenbank)
    local pw="$1"
    gd_mysql <<SQL
CREATE USER IF NOT EXISTS '${GD_PANEL_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${pw}';
ALTER USER '${GD_PANEL_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${pw}';
CREATE DATABASE IF NOT EXISTS \`${GD_PANEL_DB}\`;
GRANT ALL PRIVILEGES ON \`${GD_PANEL_DB}\`.* TO '${GD_PANEL_DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

gd_panel_db_has_tables() {
    local n
    n="$(gd_mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${GD_PANEL_DB}';" 2>/dev/null)"
    [ "${n:-0}" -gt 0 ]
}

gd_panel_composer() {
    cd "$PTERO_DIR" || return 1
    [ -f .env ] || cp .env.example .env
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
}

gd_env_set() {
    # gd_env_set KEY WERT – setzt einen Wert in der .env des Panels
    local file="$PTERO_DIR/.env"
    if grep -q "^$1=" "$file"; then
        sed -i "s|^$1=.*|$1=$2|" "$file"
    else
        # Die .env endet oft ohne Zeilenumbruch – sonst würde der neue Eintrag an die letzte Zeile angehängt
        [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ] && echo >> "$file"
        echo "$1=$2" >> "$file"
    fi
}

gd_panel_configure() {
    # gd_panel_configure <domain> <email> <db-passwort> <telemetrie true/false>
    local domain="$1" email="$2" dbpw="$3" telemetry="$4"
    cd "$PTERO_DIR" || return 1
    php artisan key:generate --force || return 1
    php artisan p:environment:setup --no-interaction \
        --author="$email" --url="https://${domain}" --timezone="$GD_TIMEZONE" \
        --cache=redis --session=redis --queue=redis \
        --redis-host=127.0.0.1 --redis-pass=null --redis-port=6379 \
        --settings-ui=true --telemetry="$telemetry" || return 1
    # Das Panel wertet --telemetry=false fehlerhaft aus (Operator-Rangfolge), daher explizit setzen
    gd_env_set PTERODACTYL_TELEMETRY_ENABLED "$telemetry"
    php artisan p:environment:database --no-interaction \
        --host=127.0.0.1 --port=3306 --database="$GD_PANEL_DB" \
        --username="$GD_PANEL_DB_USER" --password="$dbpw" || return 1
    php artisan migrate --seed --force
}

gd_panel_admin() {
    # gd_panel_admin <email> <benutzername> <passwort>
    cd "$PTERO_DIR" || return 1
    php artisan p:user:make --no-interaction --email="$1" --username="$2" \
        --name-first=Admin --name-last=User --password="$3" --admin=1
}

gd_panel_permissions() {
    chown -R www-data:www-data "$PTERO_DIR"
    chmod 640 "$PTERO_DIR/.env"
}

gd_panel_services() {
    # Cronjob (bestehende Einträge bleiben erhalten) und Queue-Worker
    local cron_line="* * * * * php ${PTERO_DIR}/artisan schedule:run >> /dev/null 2>&1"
    { crontab -l 2>/dev/null | grep -vF "${PTERO_DIR}/artisan schedule:run"; echo "$cron_line"; } | crontab - || return 1

    cat > /etc/systemd/system/pteroq.service <<EOF
# Pterodactyl Queue Worker File
# ----------------------------------

[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
# On some systems the user and group might be different.
# Some systems use \`apache\` or \`nginx\` as the user and group.
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php ${PTERO_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now redis-server pteroq
}

gd_panel_healthcheck() {
    # Prüft lokal (ohne Umweg über den Router), ob das Panel per HTTPS antwortet
    local domain="$1" code i
    for i in 1 2 3 4 5; do
        code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${domain}:443:127.0.0.1" "https://${domain}/auth/login")"
        echo "HTTP-Status der Anmeldeseite: $code"
        case "$code" in 200|302) return 0 ;; esac
        sleep 3
    done
    return 1
}

gd_artisan_www() {
    # Artisan-Befehle als Webserver-Benutzer ausführen (verhindert root-eigene Log-/Cache-Dateien)
    # HOME=/tmp, da www-data kein beschreibbares Home-Verzeichnis hat (tinker legt dort Dateien an)
    (cd "$PTERO_DIR" && runuser -u www-data -- env HOME=/tmp php artisan "$@")
}

# ---------------------------------------------------------------------------
# Komplette Installation (wird aus installer.sh aufgerufen)
# ---------------------------------------------------------------------------
gd_panel_install_steps() {
    # Erwartet: GD_DOMAIN, GD_EMAIL, GD_ADMIN_USER, GD_ADMIN_PASSWORD, GD_DB_PASSWORD, GD_TELEMETRY,
    #           GD_PANEL_VERSION, GD_APPLY_PATCH (aus gd_choose_panel_version)
    # Markierung: Bricht die Installation ab, erkennt der nächste Start die unvollständige Installation
    gd_conf_set INSTALL_STATE laeuft
    gd_step 2  "Paketquellen werden aktualisiert..." gd_apt update
    gd_step 5  "PHP ${GD_PHP_VERSION}-Paketquelle wird eingerichtet..." gd_php_repo
    gd_step 10 "PHP ${GD_PHP_VERSION} wird installiert..." gd_php_packages
    gd_step 18 "MariaDB, Redis, nginx und Certbot werden installiert..." gd_panel_packages
    gd_step 24 "Composer wird installiert..." gd_composer_install
    gd_step 27 "Pterodactyl Panel v${GD_PANEL_VERSION} wird heruntergeladen..." gd_panel_download "$GD_PANEL_VERSION"
    gd_step 30 "Webserver wird für das SSL-Zertifikat vorbereitet..." gd_nginx_http_config "$GD_DOMAIN"
    gd_step 33 "SSL-Zertifikat wird bei Let's Encrypt angefordert..." gd_certbot_issue "$GD_DOMAIN" "$GD_EMAIL"
    gd_step 36 "Webserver wird mit SSL eingerichtet..." gd_nginx_ssl_config "$GD_DOMAIN"
    gd_step 37 "Automatische Zertifikatserneuerung wird eingerichtet..." gd_certbot_hook
    gd_step 39 "Datenbank für das Panel wird angelegt..." gd_panel_database "$GD_DB_PASSWORD"
    gd_step 42 "Composer-Abhängigkeiten werden installiert (dauert etwas)..." gd_panel_composer
    gd_step 52 "Panel wird konfiguriert und die Datenbank eingerichtet..." gd_panel_configure "$GD_DOMAIN" "$GD_EMAIL" "$GD_DB_PASSWORD" "$GD_TELEMETRY"
    gd_step 58 "Administrator-Konto wird angelegt..." gd_panel_admin "$GD_EMAIL" "$GD_ADMIN_USER" "$GD_ADMIN_PASSWORD"
    gd_step 60 "Berechtigungen werden gesetzt..." gd_panel_permissions
    gd_step 62 "Cronjob und Hintergrunddienst (Queue) werden eingerichtet..." gd_panel_services
    # Reihenfolge wichtig: Blueprint ersetzt Dateien der Oberfläche, die Übersetzung kommt danach
    if [ "${GD_BLUEPRINT:-false}" = "true" ]; then
        gd_blueprint_install_step 63
    fi
    if [ "$GD_APPLY_PATCH" = "true" ]; then
        gd_germandactyl_steps 64
    fi
    gd_step 70 "Panel wird auf Erreichbarkeit geprüft..." gd_panel_healthcheck "$GD_DOMAIN"

    gd_conf_set PANEL_DOMAIN "$GD_DOMAIN"
    gd_conf_set PANEL_EMAIL "$GD_EMAIL"
    gd_conf_set PANEL_VERSION "$GD_PANEL_VERSION"
}

# ---------------------------------------------------------------------------
# Aktualisierung / Reparatur einer bestehenden Installation
# ---------------------------------------------------------------------------
gd_php_current() {
    php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null
}

gd_php_migrate() {
    # Ältere Installationen (z. B. PHP 8.1) auf die benötigte PHP-Version umstellen
    gd_php_repo || return 1
    gd_php_packages || return 1
    if [ -f /etc/nginx/sites-available/pterodactyl.conf ]; then
        sed -i -E "s#unix:/run/php/php[0-9]+\.[0-9]+-fpm\.sock#unix:/run/php/php${GD_PHP_VERSION}-fpm.sock#" \
            /etc/nginx/sites-available/pterodactyl.conf
    fi
    nginx -t && systemctl reload nginx
}

gd_panel_installed_version() {
    grep "'version' =>" "$PTERO_DIR/config/app.php" 2>/dev/null | cut -d\' -f4
}

gd_panel_update_steps() {
    # Erwartet GD_PANEL_VERSION und GD_APPLY_PATCH
    local current
    current="$(gd_php_current)"
    if [ -z "$current" ] || ! gd_version_ge "$current" "8.2"; then
        gd_step 5 "PHP wird von ${current:-unbekannt} auf ${GD_PHP_VERSION} aktualisiert..." gd_php_migrate
    fi
    gd_step 12 "Panel wird in den Wartungsmodus versetzt..." bash -c "cd '$PTERO_DIR' && (php artisan down || true)"
    gd_step 20 "Pterodactyl Panel v${GD_PANEL_VERSION} wird heruntergeladen..." gd_panel_download "$GD_PANEL_VERSION"
    gd_step 35 "Composer wird aktualisiert..." bash -c "composer self-update --2 >/dev/null 2>&1 || true"
    gd_step 40 "Composer-Abhängigkeiten werden installiert..." gd_panel_composer
    gd_step 55 "Zwischenspeicher werden geleert..." bash -c "cd '$PTERO_DIR' && php artisan view:clear && php artisan config:clear"
    gd_step 60 "Datenbank wird aktualisiert..." bash -c "cd '$PTERO_DIR' && php artisan migrate --seed --force"
    gd_step 65 "Berechtigungen werden gesetzt..." gd_panel_permissions
    gd_step 68 "Hintergrunddienste werden neu gestartet..." bash -c "cd '$PTERO_DIR' && php artisan queue:restart && systemctl restart pteroq"
    # Blueprint wird durch das Update teilweise überschrieben und muss erneut angewendet werden
    if gd_blueprint_installed; then
        gd_blueprint_install_step 69
    fi
    if [ "$GD_APPLY_PATCH" = "true" ]; then
        gd_germandactyl_steps 70
    fi
    gd_step 95 "Panel wird wieder freigegeben..." bash -c "cd '$PTERO_DIR' && php artisan up"
    gd_conf_set PANEL_VERSION "$GD_PANEL_VERSION"
}

gd_panel_update() {
    # Interaktive Aktualisierung/Reparatur inklusive GermanDactyl
    local installed
    installed="$(gd_panel_installed_version)"
    gd_choose_panel_version || return 1
    gd_yesno "↑ Panel aktualisieren" "Installiert: v${installed:-unbekannt}\nZiel: v${GD_PANEL_VERSION} $( [ "$GD_APPLY_PATCH" = "true" ] && echo '(mit deutscher Übersetzung)' || echo '(Englisch)')\n\nDas Panel ist während der Aktualisierung einige Minuten nicht erreichbar. Änderungen an Dateien des Panels (Themes/Addons) werden dabei überschrieben.\n\nEmpfehlung: Erstelle vorher ein Backup über die Backup-Verwaltung.\n\nMöchtest du fortfahren?" 18 78 || return 1
    gd_gauge_open "↑ Panel wird aktualisiert" "Aktualisierung wird vorbereitet..."
    gd_panel_update_steps
    gd_progress 100 "Aktualisierung abgeschlossen."
    gd_gauge_close
    gd_msg "✔ Aktualisierung abgeschlossen" "Das Panel wurde auf v${GD_PANEL_VERSION} aktualisiert$(gd_blueprint_installed && echo ', Blueprint wurde erneut angewendet').\n\nFalls dein Browser noch die alte Oberfläche anzeigt, lade die Seite mit Strg + F5 neu." 12 70
}
