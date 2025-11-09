#!/bin/bash

# Eigenständiger Pterodactyl Panel Installer
# Komplett unabhängig von Drittanbieter-Scripts
# Mit detailliertem Fortschritt und Fallbacks

# Globale Variablen
PTERODACTYL_VERSION="v1.11.5"
PHP_VERSION="8.1"
PANEL_DIR="/var/www/pterodactyl"
LOG_FILE="/tmp/pterodactyl_install.log"

# Fortschrittsanzeige-Funktion
show_progress() {
    local percentage=$1
    local message=$2
    echo "XXX"
    echo "$percentage"
    echo "$message"
    echo "XXX"
}

# Logging-Funktion
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Fehlerbehandlung
handle_error() {
    local exit_code=$1
    local step=$2
    if [ $exit_code -ne 0 ]; then
        log "FEHLER bei Schritt: $step (Exit-Code: $exit_code)"
        whiptail --title "❌ Installationsfehler" --msgbox "Ein Fehler ist aufgetreten bei:\n$step\n\nBitte prüfe die Log-Datei: $LOG_FILE" 12 70
        exit 1
    fi
}

# Hauptinstallationsfunktion
install_pterodactyl_standalone() {
    # Parameter übernehmen
    local panel_domain=$1
    local admin_email=$2
    local user_password=$3
    local database_password=$4

    exec 3>&1
    {
        show_progress 0 "🚀 Installation wird gestartet..."
        sleep 1

        # Schritt 1: System-Update (0-5%)
        show_progress 1 "📦 Paketquellen werden aktualisiert..."
        log "Aktualisiere apt-Paketquellen"
        apt-get update >> "$LOG_FILE" 2>&1
        handle_error $? "Paketquellen aktualisieren"

        # Schritt 2: Abhängigkeiten installieren (5-15%)
        show_progress 3 "📦 Basis-Pakete werden installiert..."
        log "Installiere Basis-Pakete"
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            software-properties-common \
            curl \
            wget \
            apt-transport-https \
            ca-certificates \
            gnupg \
            lsb-release \
            git \
            tar \
            unzip \
            >> "$LOG_FILE" 2>&1
        handle_error $? "Basis-Pakete installieren"

        show_progress 5 "📦 PHP-Repository wird hinzugefügt..."
        log "Füge Sury PHP-Repository hinzu"

        # Prüfe OS-Version
        OS_VERSION=$(lsb_release -cs)
        if [ "$OS_VERSION" = "focal" ] || [ "$OS_VERSION" = "jammy" ]; then
            # Ubuntu
            LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php >> "$LOG_FILE" 2>&1
        else
            # Debian
            curl -sSL https://packages.sury.org/php/README.txt | bash -x >> "$LOG_FILE" 2>&1
        fi
        handle_error $? "PHP-Repository hinzufügen"

        show_progress 7 "📦 Paketquellen werden erneut aktualisiert..."
        apt-get update >> "$LOG_FILE" 2>&1
        handle_error $? "Paketquellen nach Repository-Hinzufügung aktualisieren"

        # Schritt 3: PHP installieren (15-30%)
        show_progress 10 "🐘 PHP ${PHP_VERSION} und Extensions werden installiert..."
        log "Installiere PHP ${PHP_VERSION} und alle benötigten Extensions"

        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            php${PHP_VERSION} \
            php${PHP_VERSION}-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,sqlite3,redis,opcache} \
            >> "$LOG_FILE" 2>&1
        handle_error $? "PHP ${PHP_VERSION} installieren"

        # Zusätzliche PHP-Extensions für erweiterte Funktionalität
        show_progress 15 "🐘 Zusätzliche PHP-Extensions werden installiert..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            php${PHP_VERSION}-{dom,fileinfo,pdo,tokenizer,xmlwriter} \
            >> "$LOG_FILE" 2>&1
        # Kein Error-Handle hier, da manche Extensions optional sind

        show_progress 18 "🐘 PHP-Konfiguration wird optimiert..."
        log "Konfiguriere PHP für Pterodactyl"

        # PHP-Konfiguration anpassen
        sed -i 's/upload_max_filesize = .*/upload_max_filesize = 100M/' /etc/php/${PHP_VERSION}/fpm/php.ini
        sed -i 's/post_max_size = .*/post_max_size = 100M/' /etc/php/${PHP_VERSION}/fpm/php.ini
        sed -i 's/memory_limit = .*/memory_limit = 256M/' /etc/php/${PHP_VERSION}/fpm/php.ini

        show_progress 22 "🗄️  MariaDB-Repository wird eingerichtet..."
        log "Füge MariaDB-Repository hinzu"

        # MariaDB 10.11 Repository
        curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash >> "$LOG_FILE" 2>&1
        handle_error $? "MariaDB-Repository einrichten"

        show_progress 25 "🗄️  MariaDB-Server wird installiert..."
        log "Installiere MariaDB"

        DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server mariadb-client >> "$LOG_FILE" 2>&1
        handle_error $? "MariaDB installieren"

        # MariaDB starten und aktivieren
        systemctl start mariadb
        systemctl enable mariadb >> "$LOG_FILE" 2>&1

        show_progress 28 "🗄️  MariaDB wird abgesichert..."
        log "Sichere MariaDB ab"

        # MariaDB absichern
        mysql -e "DELETE FROM mysql.user WHERE User='';" >> "$LOG_FILE" 2>&1
        mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" >> "$LOG_FILE" 2>&1
        mysql -e "DROP DATABASE IF EXISTS test;" >> "$LOG_FILE" 2>&1
        mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" >> "$LOG_FILE" 2>&1
        mysql -e "FLUSH PRIVILEGES;" >> "$LOG_FILE" 2>&1

        # Schritt 4: Nginx installieren (30-35%)
        show_progress 32 "🌐 Nginx Webserver wird installiert..."
        log "Installiere Nginx"

        apt-get install -y nginx >> "$LOG_FILE" 2>&1
        handle_error $? "Nginx installieren"

        systemctl enable nginx >> "$LOG_FILE" 2>&1

        # Schritt 5: Redis installieren (35-38%)
        show_progress 35 "💾 Redis-Cache wird installiert..."
        log "Installiere Redis"

        apt-get install -y redis-server >> "$LOG_FILE" 2>&1
        handle_error $? "Redis installieren"

        systemctl start redis-server
        systemctl enable redis-server >> "$LOG_FILE" 2>&1

        # Schritt 6: Composer installieren (38-42%)
        show_progress 38 "🎼 Composer wird heruntergeladen..."
        log "Installiere Composer"

        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer >> "$LOG_FILE" 2>&1
        handle_error $? "Composer installieren"

        show_progress 40 "🎼 Composer-Berechtigungen werden gesetzt..."
        chmod +x /usr/local/bin/composer

        # Schritt 7: Panel-Verzeichnis vorbereiten (42-45%)
        show_progress 42 "📂 Panel-Verzeichnis wird vorbereitet..."
        log "Erstelle Panel-Verzeichnis"

        mkdir -p "$PANEL_DIR"
        cd "$PANEL_DIR" || exit 1

        # Schritt 8: Pterodactyl Panel herunterladen (45-52%)
        show_progress 45 "📥 Pterodactyl Panel wird heruntergeladen..."
        log "Lade Pterodactyl Panel ${PTERODACTYL_VERSION} herunter"

        curl -Lo panel.tar.gz "https://github.com/pterodactyl/panel/releases/download/${PTERODACTYL_VERSION}/panel.tar.gz" >> "$LOG_FILE" 2>&1
        handle_error $? "Panel herunterladen"

        show_progress 48 "📦 Panel-Archiv wird entpackt..."
        log "Entpacke Panel"

        tar -xzf panel.tar.gz >> "$LOG_FILE" 2>&1
        handle_error $? "Panel entpacken"

        rm panel.tar.gz

        show_progress 50 "🔐 Dateiberechtigungen werden gesetzt..."
        log "Setze Berechtigungen"

        chmod -R 755 storage/* bootstrap/cache/

        # Schritt 9: Datenbank erstellen (52-58%)
        show_progress 52 "🗄️  Pterodactyl-Datenbank wird erstellt..."
        log "Erstelle Datenbank und Benutzer"

        mysql -e "CREATE DATABASE IF NOT EXISTS panel;" >> "$LOG_FILE" 2>&1
        handle_error $? "Datenbank erstellen"

        mysql -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${database_password}';" >> "$LOG_FILE" 2>&1
        mysql -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;" >> "$LOG_FILE" 2>&1
        mysql -e "FLUSH PRIVILEGES;" >> "$LOG_FILE" 2>&1

        # Schritt 10: Composer-Abhängigkeiten installieren (58-68%)
        show_progress 58 "📦 Composer-Abhängigkeiten werden installiert (kann mehrere Minuten dauern)..."
        log "Installiere Composer-Abhängigkeiten"

        COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader >> "$LOG_FILE" 2>&1
        handle_error $? "Composer-Abhängigkeiten installieren"

        # Schritt 11: .env Datei erstellen (68-72%)
        show_progress 68 "⚙️  Umgebungskonfiguration wird erstellt..."
        log "Erstelle .env-Datei"

        cp .env.example .env

        # APP_URL setzen
        sed -i "s|APP_URL=.*|APP_URL=https://${panel_domain}|g" .env

        # Datenbank-Konfiguration
        sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|g" .env
        sed -i "s|DB_PORT=.*|DB_PORT=3306|g" .env
        sed -i "s|DB_DATABASE=.*|DB_DATABASE=panel|g" .env
        sed -i "s|DB_USERNAME=.*|DB_USERNAME=pterodactyl|g" .env
        sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${database_password}|g" .env

        # Cache & Session auf Redis setzen
        sed -i "s|CACHE_DRIVER=.*|CACHE_DRIVER=redis|g" .env
        sed -i "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|g" .env
        sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|g" .env

        # Redis-Konfiguration
        sed -i "s|REDIS_HOST=.*|REDIS_HOST=127.0.0.1|g" .env
        sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=null|g" .env
        sed -i "s|REDIS_PORT=.*|REDIS_PORT=6379|g" .env

        show_progress 70 "🔑 Applikations-Schlüssel wird generiert..."
        log "Generiere APP_KEY"

        php artisan key:generate --force >> "$LOG_FILE" 2>&1
        handle_error $? "APP_KEY generieren"

        # Schritt 12: Datenbank-Migrations (72-78%)
        show_progress 72 "🔄 Datenbank-Schema wird erstellt..."
        log "Führe Datenbank-Migrations aus"

        php artisan migrate --seed --force >> "$LOG_FILE" 2>&1
        handle_error $? "Datenbank-Migrations ausführen"

        show_progress 75 "👤 Admin-Benutzer wird erstellt..."
        log "Erstelle Admin-Benutzer"

        php artisan p:user:make \
            --email="${admin_email}" \
            --username=admin \
            --name-first=Admin \
            --name-last=User \
            --password="${user_password}" \
            --admin=1 >> "$LOG_FILE" 2>&1
        handle_error $? "Admin-Benutzer erstellen"

        # Schritt 13: Dateiberechtigungen final setzen (78-80%)
        show_progress 78 "🔐 Finale Berechtigungen werden gesetzt..."
        log "Setze finale Berechtigungen"

        chown -R www-data:www-data "$PANEL_DIR"

        # Schritt 14: Cronjob einrichten (80-82%)
        show_progress 80 "⏰ Cronjob für automatische Aufgaben wird eingerichtet..."
        log "Richte Cronjob ein"

        CRON_JOB="* * * * * php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1"
        (crontab -u www-data -l 2>/dev/null | grep -v "artisan schedule:run"; echo "$CRON_JOB") | crontab -u www-data -
        handle_error $? "Cronjob einrichten"

        # Schritt 15: Queue Worker Service (82-85%)
        show_progress 82 "🔧 Queue-Worker-Service wird erstellt..."
        log "Erstelle pteroq-Service"

        cat > /etc/systemd/system/pteroq.service << EOF
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

        systemctl enable pteroq.service >> "$LOG_FILE" 2>&1
        systemctl start pteroq.service >> "$LOG_FILE" 2>&1
        handle_error $? "pteroq-Service starten"

        # Schritt 16: Nginx-Konfiguration (85-88%)
        show_progress 85 "🌐 Nginx wird konfiguriert..."
        log "Erstelle Nginx-Konfiguration"

        # Alte Standard-Konfiguration entfernen
        rm -f /etc/nginx/sites-enabled/default

        cat > /etc/nginx/sites-available/pterodactyl.conf << EOF
server {
    listen 80;
    server_name ${panel_domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${panel_domain};

    root ${PANEL_DIR}/public;
    index index.html index.htm index.php;
    charset utf-8;

    # SSL-Zertifikate (werden von Certbot hinzugefügt)
    # ssl_certificate /etc/letsencrypt/live/${panel_domain}/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/${panel_domain}/privkey.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    # allow larger file uploads and longer script runtimes
    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
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

        ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
        handle_error $? "Nginx-Konfiguration verlinken"

        show_progress 87 "🌐 Nginx-Konfiguration wird getestet..."
        log "Teste Nginx-Konfiguration"

        nginx -t >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            log "WARNUNG: Nginx-Konfiguration hat Fehler, versuche Fallback"
            # Fallback: Einfachere Konfiguration ohne SSL
            cat > /etc/nginx/sites-available/pterodactyl.conf << 'EOFNGINX'
server {
    listen 80;
    server_name _;
    root /var/www/pterodactyl/public;
    index index.php;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOFNGINX
        fi

        # Schritt 17: SSL-Zertifikat mit Certbot (88-95%)
        show_progress 88 "📦 Certbot wird installiert..."
        log "Installiere Certbot"

        apt-get install -y certbot python3-certbot-nginx >> "$LOG_FILE" 2>&1
        handle_error $? "Certbot installieren"

        show_progress 90 "🔐 SSL-Zertifikat wird von Let's Encrypt angefordert..."
        log "Fordere SSL-Zertifikat an"

        # Ports freigeben
        fuser -k 80/tcp 2>/dev/null
        fuser -k 443/tcp 2>/dev/null

        # Nginx stoppen für Standalone-Authentifizierung
        systemctl stop nginx

        certbot certonly --standalone -d "${panel_domain}" --email "${admin_email}" --agree-tos --non-interactive --preferred-challenges http >> "$LOG_FILE" 2>&1
        CERT_RESULT=$?

        if [ $CERT_RESULT -ne 0 ]; then
            log "WARNUNG: SSL-Zertifikat konnte nicht erstellt werden (Exit-Code: $CERT_RESULT)"
            # Fallback: Nginx ohne SSL starten
            show_progress 92 "⚠️  SSL-Fehler - Starte ohne SSL (HTTP only)..."

            # Erstelle einfache HTTP-Only Konfiguration
            cat > /etc/nginx/sites-available/pterodactyl.conf << EOFSSL
server {
    listen 80;
    server_name ${panel_domain};

    root ${PANEL_DIR}/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        client_max_body_size 100m;
    }
}
EOFSSL
        else
            # SSL-Zeilen in Nginx-Config aktivieren
            sed -i "s|# ssl_certificate|ssl_certificate|g" /etc/nginx/sites-available/pterodactyl.conf
            sed -i "s|# ssl_certificate_key|ssl_certificate_key|g" /etc/nginx/sites-available/pterodactyl.conf

            # SSL-Optionen hinzufügen
            sed -i "/ssl_certificate_key/a \    ssl_session_cache shared:SSL:10m;\n    ssl_session_timeout 10m;\n    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256';\n    ssl_prefer_server_ciphers on;" /etc/nginx/sites-available/pterodactyl.conf

            # Crontab für automatische Erneuerung
            CRON_CMD="0 3 */4 * * systemctl stop nginx && certbot renew --quiet && systemctl start nginx"
            (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_CMD") | crontab -

            show_progress 92 "✅ SSL-Zertifikat erfolgreich installiert..."
        fi

        # Nginx Konfiguration testen
        nginx -t >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            log "FEHLER: Nginx-Konfigurationstest fehlgeschlagen"
            # Letzte Fallback-Konfiguration
            cat > /etc/nginx/sites-available/pterodactyl.conf << 'EOFFALLBACK'
server {
    listen 80 default_server;
    root /var/www/pterodactyl/public;
    index index.php;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOFFALLBACK
        fi

        # Nginx neu starten
        systemctl restart nginx >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            log "FEHLER beim Nginx-Neustart, versuche Problembehandlung"
            systemctl stop nginx
            sleep 2
            systemctl start nginx
        fi

        # Schritt 18: Abschluss (95-100%)
        show_progress 95 "🧹 Aufräumarbeiten werden durchgeführt..."
        log "Führe Aufräumarbeiten durch"

        # Cache leeren
        php artisan view:clear >> "$LOG_FILE" 2>&1
        php artisan config:clear >> "$LOG_FILE" 2>&1
        php artisan cache:clear >> "$LOG_FILE" 2>&1

        # Finale Berechtigungen
        chown -R www-data:www-data "$PANEL_DIR"

        show_progress 98 "✅ Installation wird finalisiert..."
        log "Installation abgeschlossen"

        sleep 1
        show_progress 100 "🎉 Installation erfolgreich abgeschlossen!"
        sleep 2

    } | whiptail --title "Pterodactyl Panel Installation" --gauge "Bitte warten..." 10 80 0 3>&1 1>&2 2>&3

    exec 3>&-

    # Erfolgsmeldung
    whiptail --title "✅ Installation erfolgreich" --msgbox "Pterodactyl Panel wurde erfolgreich installiert!\n\n🌐 Domain: https://${panel_domain}\n👤 Benutzer: admin\n📧 E-Mail: ${admin_email}\n🔑 Passwort: ${user_password}\n\n📋 Log-Datei: ${LOG_FILE}" 16 80
}

# Export der Funktion für Verwendung in anderen Scripts
export -f install_pterodactyl_standalone
