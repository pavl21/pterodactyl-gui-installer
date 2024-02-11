trouble_menu() {
    while true; do
        TROUBLE_MENU=$(whiptail --title "Problembehandlung" --menu "Wobei können wir dir weiterhelfen?" 20 60 10 \
            "1" "🔒 Ich habe mich ausgesperrt" \
            "2" "🔧 Das Panel ist fehlerhaft" \
            "3" "🚫 Das Panel kann nicht erreicht werden" \
            "4" "🔓 SSL-Zertifikate sind abgelaufen" \
            "5" "🔍 Allgemeine Analyse starten" 3>&1 1>&2 2>&3)
        exitstatus=$?

        # Überprüft, ob der Benutzer 'Cancel' gewählt hat oder das Fenster geschlossen hat
        if [ $exitstatus != 0 ]; then
            exec curl -sSL https://setup.germandactyl.de/ | sudo bash -s --
            exit 0
        fi

        case $TROUBLE_MENU in
            1) create_admin_account ;;
            2) repair_panel ;;
            3) check_nginx_config ;;
            4) run_certbot_renew ;;
            5) global_test ;;
        esac
    done
}

# Funktion zum Ausführen der Zertifikatserneuerung in Bash
run_certbot_renew() {
    curl -sSL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/certbot-renew-verwaltung.sh | sudo bash -
    exit 0
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
        whiptail --title "Benutzer erstellen" --msgbox "🎉 Ein neuer Benutzer wurde erstellt.\n👤 Benutzername: admin_$RANDOM_NUMBER\n🔑 Passwort: $USER_PASSWORD" 12 78
        if ! whiptail --title "Zugangsdaten" --yesno "Hast du dir die Zugangsdaten gespeichert?" 10 60; then
            whiptail --title "Zugangsdaten" --msgbox "Bitte speichere die Zugangsdaten:\nBenutzername: admin_$RANDOM_NUMBER\nPasswort: $USER_PASSWORD" 12 78
        fi
        if ! whiptail --title "Login erfolgreich?" --yesno "Konntest du dich erfolgreich einloggen?" 10 60; then
            return  # Kehrt zum Hauptmenü zurück, wenn der Login nicht erfolgreich war
        fi
    elif [[ $COMMAND_OUTPUT == *"The email has already been taken."* ]]; then
        whiptail --title "Bereits vorhanden" --msgbox "Die E-Mail-Adresse ist bereits registriert. Bitte verwende eine andere E-Mail-Adresse." 10 60
    else
        if whiptail --title "Fehler" --yesno "Die Benutzererstellung war nicht erfolgreich.\nMöchtest du es erneut versuchen?" 10 60; then
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

        whiptail --title "Panel Reparatur abgeschlossen" --msgbox "Ein Versuch wurde unternommen, das Panel zu reparieren. Bitte teste, ob das Panel jetzt erreichbar ist. Sollte es immernoch nicht funktionieren, kannst dich an die Community von Pterodactyl auf Discord melden." 12 78

        clear
        echo "Zurück zum Hauptmenü..."
    else
        return  # Kehrt zum Hauptmenü zurück, wenn der Benutzer die Reparatur ablehnt
    fi
}

# Webserver-Reperatur Teil, um die Config einzustellen für allgemeine Erreichbarkeit des Panels.
check_nginx_config() {
    # Domain-Abfrage
    DOMAIN_CHECK=$(whiptail --title "Reperatur" --inputbox "Unter welcher Domain soll das Panel erreichbar sein? Gebe bitte nur die Domain ein, die du vorher bereits für dieses Panel verwendet hast. Nicht für Wings!" 10 60 3>&1 1>&2 2>&3)
    exitstatus=$?
    if [ $exitstatus != 0 ]; then
        return  # Kehrt zum Hauptmenü zurück, wenn abgebrochen wird
    fi
    if ! validate_domain "$DOMAIN_CHECK"; then
        whiptail --title "Ungültige Domain" --msgbox "Die eingegebene Domain ist ungültig. Bitte versuche es erneut." 10 60
        return
    fi

    # Überprüfen, ob SSL-Zertifikate existieren
    if [ ! -d "/etc/letsencrypt/live/$DOMAIN_CHECK" ]; then
        if whiptail --title "Kein SSL-Zertifikat" --yesno "Keine SSL-Zertifikate gefunden. Möchtest du diese jetzt erstellen?" 10 60; then
            repair_email=$(whiptail --inputbox "Bitte gib eine gültige E-Mail-Adresse für das SSL-Zertifikat ein" 10 60 3>&1 1>&2 2>&3)
            apt-get update && sudo apt-get install certbot python3-certbot-nginx -y
            systemctl stop nginx
            certbot --nginx -d $DOMAIN_CHECK --email $repair_email --agree-tos --non-interactive
            fuser -k 80/tcp
            fuser -k 443/tcp
            systemctl restart nginx
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
        whiptail --title "Erfolg" --msgbox "Glückwunsch, die Reparatur war erfolgreich. Ein Stern für das GitHub-Projekt würde mich freuen. Das Script wird jetzt beendet." 10 60
    else
        whiptail --title "Problem" --msgbox "Es scheint ein Problem zu geben. Bitte versuche, das Panel direkt zu reparieren. Das Script wird beendet." 10 60
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
    curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/analyse.sh | bash
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

# Funktion zur Generierung einer zufälligen dreistelligen Zahl
generate_random_number() {
    echo $((RANDOM % 900 + 100))
}

trouble_menu
