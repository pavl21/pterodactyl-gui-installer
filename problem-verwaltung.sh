#!/bin/bash

# Lade Whiptail-Farben
source "$(dirname "$0")/whiptail-colors.sh" 2>/dev/null || source /opt/pterodactyl/whiptail-colors.sh 2>/dev/null || true

# Lade install-scripts.sh für Logging und call_script()
source "$(dirname "$0")/install-scripts.sh" 2>/dev/null || source /opt/pterodactyl/install-scripts.sh 2>/dev/null || true

trouble_menu() {
    while true; do
        TROUBLE_MENU=$(whiptail --title "Problembehandlung" --menu "Wobei können wir dir weiterhelfen?" 25 70 12 \
            "1" "Ich habe mich ausgesperrt" \
            "2" "Das Panel ist fehlerhaft" \
            "3" "Das Panel kann nicht erreicht werden" \
            "4" "SSL-Zertifikate erneuern" \
            "5" "SSL-Zertifikate prüfen und Status anzeigen" \
            "6" "System-Diagnose durchführen" \
            "7" "Datenbank-Verbindung prüfen" \
            "8" "Services-Status prüfen" \
            "9" "Allgemeine Analyse starten" 3>&1 1>&2 2>&3)
        exitstatus=$?

        # Überprüft, ob der Benutzer 'Cancel' gewählt hat oder das Fenster geschlossen hat
        if [ $exitstatus != 0 ]; then
            sudo bash -c "$(curl -sSL https://setup.germandactyl.de/)"
            exit 0
        fi

        case $TROUBLE_MENU in
            1) create_admin_account ;;
            2) repair_panel ;;
            3) check_nginx_config ;;
            4) run_certbot_renew ;;
            5) check_ssl_certificates ;;
            6) run_system_diagnosis ;;
            7) check_database_connection ;;
            8) check_services_status ;;
            9) global_test ;;
        esac
    done
}

# Funktion zum Prüfen der SSL-Zertifikate
check_ssl_certificates() {
    clear
    echo "SSL-Zertifikate werden geprüft..."

    # Alle Zertifikate finden
    if [ ! -d "/etc/letsencrypt/live" ]; then
        whiptail_error --title "Keine Zertifikate gefunden" --msgbox "Es wurden keine Let's Encrypt Zertifikate auf diesem System gefunden." 10 60
        return
    fi

    cert_info=""
    all_valid=true
    expiring_soon=false

    for cert_dir in /etc/letsencrypt/live/*/; do
        if [ -d "$cert_dir" ]; then
            domain=$(basename "$cert_dir")
            cert_file="$cert_dir/cert.pem"

            if [ -f "$cert_file" ]; then
                # Ablaufdatum ermitteln
                expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
                expiry_epoch=$(date -d "$expiry_date" +%s)
                current_epoch=$(date +%s)
                days_until_expiry=$(( ($expiry_epoch - $current_epoch) / 86400 ))

                # Zertifikat-Informationen sammeln
                if [ $days_until_expiry -lt 0 ]; then
                    cert_info="${cert_info}FEHLER: $domain: ABGELAUFEN (vor $((days_until_expiry * -1)) Tagen)\n"
                    all_valid=false
                elif [ $days_until_expiry -lt 30 ]; then
                    cert_info="${cert_info}Warnung: $domain: Läuft in $days_until_expiry Tagen ab\n"
                    expiring_soon=true
                else
                    cert_info="${cert_info}OK: $domain: Gültig (noch $days_until_expiry Tage)\n"
                fi
            fi
        fi
    done

    # Zusammenfassung anzeigen
    if [ "$all_valid" = true ] && [ "$expiring_soon" = false ]; then
        whiptail_success --title "SSL-Zertifikate Status" --msgbox "Alle Zertifikate sind gültig:\n\n$cert_info" 20 70
    elif [ "$expiring_soon" = true ]; then
        if whiptail_warning --title "SSL-Zertifikate Status" --yesno "Einige Zertifikate laufen bald ab:\n\n${cert_info}\nMöchtest du jetzt alle Zertifikate erneuern?" 20 70; then
            run_certbot_renew
        fi
    else
        if whiptail_error --title "SSL-Zertifikate Status" --yesno "WARNUNG - Abgelaufene Zertifikate gefunden:\n\n${cert_info}\nMöchtest du jetzt alle Zertifikate erneuern?" 20 70; then
            run_certbot_renew
        fi
    fi
}

# Funktion für System-Diagnose
run_system_diagnosis() {
    clear
    echo "System-Diagnose wird durchgeführt..."

    diagnosis_text="SYSTEM-DIAGNOSE\n\n"

    # Speicherplatz prüfen
    disk_usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ "$disk_usage" -gt 90 ]; then
        diagnosis_text="${diagnosis_text}KRITISCH: Speicherplatz: KRITISCH ($disk_usage% belegt)\n"
    elif [ "$disk_usage" -gt 80 ]; then
        diagnosis_text="${diagnosis_text}Warnung: Speicherplatz: Warnung ($disk_usage% belegt)\n"
    else
        diagnosis_text="${diagnosis_text}OK: Speicherplatz: OK ($disk_usage% belegt)\n"
    fi

    # RAM prüfen
    mem_usage=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
    if [ "$mem_usage" -gt 90 ]; then
        diagnosis_text="${diagnosis_text}KRITISCH: RAM-Auslastung: KRITISCH ($mem_usage%)\n"
    elif [ "$mem_usage" -gt 80 ]; then
        diagnosis_text="${diagnosis_text}Warnung: RAM-Auslastung: Hoch ($mem_usage%)\n"
    else
        diagnosis_text="${diagnosis_text}OK: RAM-Auslastung: OK ($mem_usage%)\n"
    fi

    # CPU Load prüfen
    cpu_load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    diagnosis_text="${diagnosis_text}Info: CPU Load: $cpu_load\n\n"

    # Nginx Status
    if systemctl is-active --quiet nginx; then
        diagnosis_text="${diagnosis_text}OK: Nginx: Läuft\n"
    else
        diagnosis_text="${diagnosis_text}FEHLER: Nginx: Gestoppt\n"
    fi

    # MariaDB/MySQL Status
    if systemctl is-active --quiet mariadb; then
        diagnosis_text="${diagnosis_text}OK: MariaDB: Läuft\n"
    elif systemctl is-active --quiet mysql; then
        diagnosis_text="${diagnosis_text}OK: MySQL: Läuft\n"
    else
        diagnosis_text="${diagnosis_text}FEHLER: Datenbank: Gestoppt\n"
    fi

    # Redis Status
    if systemctl is-active --quiet redis-server || systemctl is-active --quiet redis; then
        diagnosis_text="${diagnosis_text}OK: Redis: Läuft\n"
    else
        diagnosis_text="${diagnosis_text}Info: Redis: Gestoppt (optional)\n"
    fi

    # PHP-FPM Status
    if systemctl is-active --quiet php8.1-fpm; then
        diagnosis_text="${diagnosis_text}OK: PHP-FPM: Läuft\n"
    elif systemctl is-active --quiet php8.2-fpm; then
        diagnosis_text="${diagnosis_text}OK: PHP-FPM: Läuft\n"
    elif systemctl is-active --quiet php8.3-fpm; then
        diagnosis_text="${diagnosis_text}OK: PHP-FPM: Läuft\n"
    else
        diagnosis_text="${diagnosis_text}FEHLER: PHP-FPM: Gestoppt\n"
    fi

    # Wings Status (falls installiert)
    if [ -f "/usr/local/bin/wings" ]; then
        if systemctl is-active --quiet wings; then
            diagnosis_text="${diagnosis_text}OK: Wings: Läuft\n"
        else
            diagnosis_text="${diagnosis_text}FEHLER: Wings: Gestoppt\n"
        fi
    fi

    whiptail_info --title "System-Diagnose" --msgbox "$diagnosis_text" 25 70
}

# Funktion zum Prüfen der Datenbank-Verbindung
check_database_connection() {
    clear
    echo "Datenbank-Verbindung wird geprüft..."

    if [ ! -f "/var/www/pterodactyl/.env" ]; then
        whiptail_error --title "Fehler" --msgbox "Die Panel-Konfigurationsdatei wurde nicht gefunden." 10 60
        return
    fi

    # Datenbankdaten aus .env auslesen
    db_host=$(grep "^DB_HOST=" /var/www/pterodactyl/.env | cut -d'=' -f2)
    db_port=$(grep "^DB_PORT=" /var/www/pterodactyl/.env | cut -d'=' -f2)
    db_database=$(grep "^DB_DATABASE=" /var/www/pterodactyl/.env | cut -d'=' -f2)
    db_username=$(grep "^DB_USERNAME=" /var/www/pterodactyl/.env | cut -d'=' -f2)
    db_password=$(grep "^DB_PASSWORD=" /var/www/pterodactyl/.env | cut -d'=' -f2)

    # Verbindung testen
    if mysql -h"$db_host" -P"$db_port" -u"$db_username" -p"$db_password" -e "USE $db_database;" 2>/dev/null; then
        whiptail_success --title "Datenbank-Verbindung" --msgbox "Verbindung zur Datenbank erfolgreich!\n\nHost: $db_host:$db_port\nDatenbank: $db_database\nBenutzer: $db_username" 12 60
    else
        whiptail_error --title "Datenbank-Verbindung" --msgbox "Verbindung zur Datenbank fehlgeschlagen!\n\nHost: $db_host:$db_port\nDatenbank: $db_database\n\nBitte prüfe die Zugangsdaten in /var/www/pterodactyl/.env" 14 70
    fi
}

# Funktion zum Prüfen des Service-Status
check_services_status() {
    clear
    echo "Service-Status wird geprüft..."

    services_text="SERVICE-STATUS\n\n"

    # Liste der zu prüfenden Services
    declare -A services=(
        ["nginx"]="Webserver"
        ["mariadb"]="Datenbank (MariaDB)"
        ["mysql"]="Datenbank (MySQL)"
        ["redis-server"]="Redis Cache"
        ["redis"]="Redis Cache"
        ["php8.1-fpm"]="PHP 8.1 FPM"
        ["php8.2-fpm"]="PHP 8.2 FPM"
        ["php8.3-fpm"]="PHP 8.3 FPM"
        ["wings"]="Pterodactyl Wings"
        ["pteroq"]="Pterodactyl Queue Worker"
    )

    for service in "${!services[@]}"; do
        if systemctl list-unit-files | grep -q "^$service.service"; then
            if systemctl is-active --quiet "$service"; then
                services_text="${services_text}OK: ${services[$service]}: Aktiv\n"
            else
                services_text="${services_text}FEHLER: ${services[$service]}: Inaktiv\n"
            fi
        fi
    done

    if whiptail_info --title "Services-Status" --yesno "$services_text\nMöchtest du inaktive Services neu starten?" 25 70; then
        # Versuche kritische Services neu zu starten mit verbesserter Validierung
        restart_results=""
        for service in nginx mariadb mysql php8.1-fpm php8.2-fpm php8.3-fpm pteroq; do
            # Prüfe ob Service existiert
            if systemctl list-unit-files | grep -q "^$service.service"; then
                # Prüfe ob Service inaktiv ist
                if ! systemctl is-active --quiet "$service"; then
                    # Versuche Service zu starten und prüfe Erfolg
                    if systemctl start "$service" 2>/dev/null; then
                        restart_results="${restart_results}✓ $service: Erfolgreich gestartet\n"
                    else
                        restart_results="${restart_results}✗ $service: Start fehlgeschlagen\n"
                    fi
                fi
            fi
        done

        if [ -n "$restart_results" ]; then
            whiptail_info --title "Services neu gestartet" --msgbox "Neustart-Ergebnisse:\n\n$restart_results" 18 70
        else
            whiptail_info --title "Keine Änderungen" --msgbox "Alle Services liefen bereits oder es gab nichts zu starten." 10 60
        fi
    fi
}

# Funktion zum Ausführen der Zertifikatserneuerung in Bash
run_certbot_renew() {
    # Prüfe ob certbot installiert ist
    if ! command -v certbot &> /dev/null; then
        whiptail_error --title "Certbot nicht gefunden" --msgbox "Certbot ist nicht installiert.\n\nBitte installiere certbot zuerst:\nsudo apt-get install certbot" 10 65
        return 1
    fi

    # Führe Zertifikatserneuerung aus mit Error-Handling
    if ! call_script "certbot-renew-verwaltung.sh"; then
        whiptail_error --title "Fehler" --msgbox "FEHLER: Zertifikatserneuerung fehlgeschlagen.\n\nBitte prüfe:\n• Ist die Internetverbindung aktiv?\n• Ist das certbot-renew-verwaltung.sh Script verfügbar?\n\nVersuche es manuell: certbot renew" 14 70
        return 1
    fi
    exit 0
}


# Domain auf Gültigkeit prüfen
validate_domain() {
    local domain=$1

    # Einfache Überprüfung, ob die Domain-Struktur gültig ist
    if [[ $domain =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        return 0  # 0 bedeutet 'erfolgreich' oder 'wahr' in Bash
    else
        return 1  # 1 bedeutet 'Fehler' oder 'falsch'
    fi
}




# Admin Account Passwort vergessen
create_admin_account() {
    if ! whiptail --title "Passwort vergessen" --yesno "Wenn du dein Passwort für dein Admin Account vergessen hast, können wir nur einen neuen Account anlegen, womit du wieder in dein Admin Panel kommst. Dort kannst du dann dein Passwort deines bestehenden Accounts ändern und den temporären löschen. Bist du damit einverstanden?" 12 80; then
        return  # Kehrt zum Hauptmenü zurück, wenn "Nein" ausgewählt wird
    fi

    # Generiert eine zufällige Zahl für die E-Mail-Adresse
    local random_number=$(generate_random_number)
    ADMIN_EMAIL="email${random_number}@example.com"

    # Generiert ein Passwort mit 8 Zeichen, Groß- und Kleinbuchstaben sowie Zahlen
    USER_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)

    # Der restliche Code für die Accounterstellung...
    RANDOM_NUMBER=$(generate_random_number)
    COMMAND_OUTPUT=$(cd /var/www/pterodactyl && php artisan p:user:make --email="$ADMIN_EMAIL" --username="admin_$RANDOM_NUMBER" --name-first=Admin --name-last=User --password="$USER_PASSWORD" --admin=1)

    if [[ $COMMAND_OUTPUT == *"+----------+--------------------------------------+"* ]]; then
        whiptail_success --title "Benutzer erstellen" --msgbox "Ein neuer Benutzer wurde erstellt.\nBenutzername: admin_$RANDOM_NUMBER\nPasswort: $USER_PASSWORD" 12 78
        if ! whiptail --title "Zugangsdaten" --yesno "Hast du dir die Zugangsdaten gespeichert?" 10 60; then
            whiptail_info --title "Zugangsdaten" --msgbox "Bitte speichere die Zugangsdaten:\nBenutzername: admin_$RANDOM_NUMBER\nPasswort: $USER_PASSWORD" 12 78
        fi
        if ! whiptail --title "Login erfolgreich?" --yesno "Konntest du dich erfolgreich einloggen?" 10 60; then
            return  # Kehrt zum Hauptmenü zurück, wenn der Login nicht erfolgreich war
        fi
    elif [[ $COMMAND_OUTPUT == *"The email has already been taken."* ]]; then
        whiptail_warning --title "Bereits vorhanden" --msgbox "Die E-Mail-Adresse ist bereits registriert. Bitte verwende eine andere E-Mail-Adresse." 10 60
    else
        if whiptail_error --title "Fehler" --yesno "Die Benutzererstellung war nicht erfolgreich.\nMöchtest du es erneut versuchen?" 10 60; then
            return  # Kehrt zum Hauptmenü zurück, um es erneut zu versuchen
        fi
    fi
}

# Pterodactyl Panel reparieren - Panel neu builden (Entfernt alle Änderungen an der Optik und holt sich die neueste Version von Github)
repair_panel() {
    if whiptail --title "Panel reparieren" --yesno "Möchtest du versuchen, das Panel zu reparieren?\nAchtung: Modifikationen könnten entfernt werden! Zugleich wird die neueste Version des Panels heruntergeladen. Nutze es nur, wenn du einen Error beim aufrufen bekommst, der vom Panel stammt." 12 78; then
        (
            cd /var/www/pterodactyl/ &&
            clear
            echo "Update wird heruntergeladen" &&
            sleep 2 &&
            curl -L https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xzv &&
            chmod -R 755 storage/* bootstrap/cache &&
            echo "Dependency- und Datenbankupdates werden jetzt installiert..." &&
            sleep 3 &&
            COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader &&
            sleep 2 &&
            php artisan migrate --seed --force &&
            php artisan view:clear &&
            php artisan config:clear &&
            chown -R www-data:www-data /var/www/pterodactyl/* &&
            echo "Panel wird jetzt gestartet..." &&
            sleep 2 &&
            php artisan queue:restart &&
            php artisan up &&
            sleep 1 &&
            curl -sSL https://install.germandactyl.de/ | sudo bash -s -- -v1.11.3
            cd ~ &&
            echo "Das Panel wurde erfolgreich neu gebaut. Bitte teste, ob es jetzt funktioniert."
            clear
        ) 2>&1 | sed -u 's/^[ \t]*//'

        whiptail_info --title "Panel Reparatur abgeschlossen" --msgbox "Ein Versuch wurde unternommen, das Panel zu reparieren. Bitte teste, ob das Panel jetzt erreichbar ist. Sollte es immer noch nicht funktionieren, kannst dich an die Community von Pterodactyl auf Discord melden." 12 78

        clear
        echo "Zurück zum Hauptmenü..."
    else
        return  # Kehrt zum Hauptmenü zurück, wenn der Benutzer die Reparatur ablehnt
    fi
}

# Webserver-Reparatur Teil, um die Config einzustellen für allgemeine Erreichbarkeit des Panels.
check_nginx_config() {
    # Domain-Abfrage
    DOMAIN_CHECK=$(whiptail --title "Reparatur" --inputbox "Unter welcher Domain soll das Panel erreichbar sein? Gebe bitte nur die Domain ein, die du vorher bereits für dieses Panel verwendet hast. Nicht für Wings!" 10 60 3>&1 1>&2 2>&3)
    exitstatus=$?
    if [ $exitstatus != 0 ]; then
        return  # Kehrt zum Hauptmenü zurück, wenn abgebrochen wird
    fi
    if ! validate_domain "$DOMAIN_CHECK"; then
        whiptail_error --title "Ungültige Domain" --msgbox "Die eingegebene Domain ist ungültig. Bitte versuche es erneut." 10 60
        return
    fi

    # Überprüfen, ob SSL-Zertifikate existieren
    if [ ! -d "/etc/letsencrypt/live/$DOMAIN_CHECK" ]; then
        if whiptail_warning --title "Kein SSL-Zertifikat" --yesno "Keine SSL-Zertifikate gefunden. Möchtest du diese jetzt erstellen?" 10 60; then
            repair_email=$(whiptail --inputbox "Bitte gib eine gültige E-Mail-Adresse für das SSL-Zertifikat ein" 10 60 3>&1 1>&2 2>&3)

            # Validiere Email
            if [ -z "$repair_email" ] || ! [[ $repair_email =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                whiptail_error --title "Ungültige E-Mail" --msgbox "Die eingegebene E-Mail-Adresse ist ungültig.\n\nVorgang wird abgebrochen." 10 60
                return
            fi

            # Installiere certbot mit Error-Handling
            if ! apt-get update >> /dev/null 2>&1; then
                whiptail_error --title "Fehler" --msgbox "apt-get update fehlgeschlagen.\n\nBitte prüfe die Paketquellen." 10 60
                return
            fi

            if ! apt-get install -y certbot python3-certbot-nginx >> /dev/null 2>&1; then
                whiptail_error --title "Fehler" --msgbox "Certbot-Installation fehlgeschlagen.\n\nBitte installiere certbot manuell." 10 60
                return
            fi

            # Stoppe nginx mit Validierung
            if ! systemctl stop nginx 2>/dev/null; then
                whiptail_warning --title "Warnung" --msgbox "Nginx konnte nicht gestoppt werden.\n\nFahre trotzdem fort." 10 60
            fi

            # Erstelle Zertifikat mit Error-Handling
            if ! certbot --nginx -d "$DOMAIN_CHECK" --email "$repair_email" --agree-tos --non-interactive 2>&1 | tee /tmp/certbot.log; then
                whiptail_error --title "Certbot fehlgeschlagen" --msgbox "SSL-Zertifikat konnte nicht erstellt werden.\n\nBitte prüfe:\n• Domain zeigt auf diesen Server\n• Port 80 und 443 sind offen\n• Keine Firewall blockiert\n\nLog: /tmp/certbot.log" 16 70
                systemctl start nginx 2>/dev/null
                return
            fi

            # Cleanup
            fuser -k 80/tcp 2>/dev/null
            fuser -k 443/tcp 2>/dev/null

            # Starte nginx mit Validierung
            if ! systemctl restart nginx 2>/dev/null; then
                whiptail_error --title "Fehler" --msgbox "Nginx konnte nicht neu gestartet werden.\n\nBitte starte nginx manuell:\nsudo systemctl restart nginx" 10 70
                return
            fi

            whiptail_success --title "Erfolg" --msgbox "SSL-Zertifikat wurde erfolgreich erstellt." 10 60
        else
            return  # Kehrt zum Hauptmenü zurück, wenn abgebrochen wird
        fi
    fi

    # Überprüfen, ob das Panel erreichbar ist
    if whiptail --yesno "Prüfe bitte nochmal, ob du das Panel über andere Browser/Computer erreichen kannst. Ist es dort erreichbar?" 10 60; then
        return  # Kehrt zum Hauptmenü zurück, wenn das Panel erreichbar ist
    fi

    # Überprüfen, ob eine Nginx-Konfiguration existiert
    if [ -f "/etc/nginx/sites-enabled/pterodactyl.conf" ]; then
        if ! whiptail --yesno "Es scheint schon eine Nginx-Konfiguration zu existieren. Möchtest du sie ersetzen?" 10 60; then
            return  # Kehrt zum Hauptmenü zurück, wenn abgebrochen wird
        fi
    elif [ -d "/etc/nginx" ]; then
        if ! whiptail --yesno "Es scheint keine Nginx-Konfiguration für Pterodactyl zu existieren. Möchtest du eine erstellen?" 10 60; then
            return  # Kehrt zum Hauptmenü zurück, wenn abgebrochen wird
        fi
    else
        if ! whiptail --yesno "Es scheint, dass Nginx nicht installiert ist. Möchtest du Nginx installieren und eine Konfiguration erstellen?" 10 60; then
            return  # Kehrt zum Hauptmenü zurück, wenn abgebrochen wird
        fi
        apt-get install nginx -y
    fi

    # VORGANG: Erstellen der Nginx-Konfiguration
    create_nginx_config "$DOMAIN_CHECK"

    # Nginx neu starten und überprüfen, ob das Panel erreichbar ist
    systemctl restart nginx
    if whiptail --yesno "Änderungen wurden angewendet. Kannst du das Panel wieder erreichen?" 10 60; then
        whiptail_success --title "Erfolg" --msgbox "Glückwunsch, die Reparatur war erfolgreich. Ein Stern für das GitHub-Projekt würde mich freuen. Das Script wird jetzt beendet." 10 60
    else
        whiptail_error --title "Problem" --msgbox "Es scheint ein Problem zu geben. Bitte versuche, das Panel direkt zu reparieren. Das Script wird beendet." 10 60
    fi
}

create_nginx_config() {
    local DOMAIN_CHECK=$1
    cat > /etc/nginx/sites-enabled/pterodactyl.conf <<EOL
server {
    server_name $DOMAIN_CHECK;

    root /var/www/pterodactyl/public;
    index index.html index.htm index.php;
    charset utf-8;

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

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
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

    listen 443 ssl; # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_CHECK/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_CHECK/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

}
server {
    if (\$host = $DOMAIN_CHECK) {
        return 301 https://\$host\$request_uri;
    } # managed by Certbot

    listen 80;

    server_name $DOMAIN_CHECK;
    return 404; # managed by Certbot
}
EOL
}


# Funktion für die globale Analyse
global_test() {
    echo "Weiterleitung zur Analyse..."
    call_script "analyse.sh"
    exit 0
}

# Funktion zur Generierung einer zufälligen dreistelligen Zahl
generate_random_number() {
    echo $((RANDOM % 900 + 100))
}

trouble_menu
