#!/bin/bash

# Überprüfen, ob das System apt als Paketmanager verwendet
if ! command -v apt-get &> /dev/null; then
    echo "Abbruch: Für dein System ist dieses Script nicht vorgesehen. Derzeit wird nur Ubuntu, Debian und ähnliche Systeme unterstützt."
    exit 1
fi


# BEGINN VON Vorbereitung ODER existiert bereits ODER Reperatur

# Funktion zur Überprüfung der E-Mail-Adresse
validate_email() {
    if [[ $1 =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Überprüfung der Panel-Erreichbarkeit
check_panel_reachability() {
    if curl --output /dev/null --silent --head --fail "https://$panel_domain"; then
        echo "Das Panel ist erreichbar."
    else
        echo "Das Panel ist nicht erreichbar. Bitte überprüfe die Installation und die Netzwerkeinstellungen."
        exit 1
    fi
}

# Globale Konfigurationsvariablen
DOMAIN_REGEX="^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,6}$"
LOG_FILE="wlog.txt"
INSTALLER_URL="https://pterodactyl-installer.se"

# Funktion zur Generierung einer zufälligen dreistelligen Zahl
generate_random_number() {
    echo $((RANDOM % 900 + 100))
}

main_loop() {
    while true; do
        if [ -d "/var/www/pterodactyl" ]; then
            MAIN_MENU=$(whiptail --title "Pterodactyl Verwaltung/Wartung" --menu "Pterodactyl ist bereits installiert.\nWähle eine Aktion:" 15 60 8 \
                "1" "Admin Passwort vergessen" \
                "2" "Panel meldet einen Fehler" \
                "3" "Panel nicht erreichbar" \
                "4" "Pterodactyl deinstallieren" \
                "5" "PhpMyAdmin installieren (Offen)" \
                "6" "Wings nachinstallieren" \
                "7" "Backup-Verwaltung öffnen (Alpha)" \
                "8" "Database-Host einrichten (Offen)" \
                "9" "Theme installieren (Offen)" \
                "10" "Skript beenden" 3>&1 1>&2 2>&3)
            exitstatus=$?

            # Überprüft, ob der Benutzer 'Cancel' gewählt hat oder das Fenster geschlossen hat
            if [ $exitstatus != 0 ]; then
                clear
                echo ""
                echo "HINWEIS - - - - - - - - - - -"
                echo "Die Verwaltung wurde beendet. Nur zur Info: Das Installationsscript wurde nicht gestartet, weil Pterodactyl bereits installiert ist."
                echo ""
                exit
            fi

            clear
            case $MAIN_MENU in
                1) create_admin_account ;;
                2) repair_panel ;;
                3) check_nginx_config ;;
                4) uninstall_pterodactyl ;;
                5) install_phpmyadmin ;;
                6) install_wings ;;
                7) setup_server_backups ;;
                8) setup_database_host ;;
                9) install_theme ;;
                10)
                   clear
                   echo ""
                   echo "INFO - - - - - - - - - -"
                   echo "Die Verwaltung/Wartung vom Panel wurde beendet. Starte das Script erneut, wenn du zurückkehren möchtest."
                   exit 0
                   ;;
            esac
        else
            echo "Das Verzeichnis /var/www/pterodactyl existiert nicht. Fahre fort."
            return
        fi
    done
}


# Wings installieren
install_wings() {
    clear
    echo "Weiterleitung zu Wings..."
    wget https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/wings-installer.sh -O wings
    chmod +x wings
    ./wings
}

# Admin Account Passwort vergessen
create_admin_account() {
    if ! whiptail --yesno "Wenn du dein Passwort für dein Admin Account vergessen hast, können wir nur einen neuen Account anlegen, womit du wieder in dein Admin Panel kommst. Dort kannst du dann dein Passwort deines bestehenden Accounts ändern und den temporären löschen. Bist du damit einverstanden?" 12 78; then
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
    DOMAIN_CHECK=$(whiptail --inputbox "Unter welcher Domain soll das Panel erreichbar sein? Gebe bitte nur die Domain ein, die du vorher bereits für dieses Panel verwendet hast. Nicht für Wings!" 10 60 3>&1 1>&2 2>&3)
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
        if whiptail --yesno "Keine SSL-Zertifikate gefunden. Möchtest du diese jetzt erstellen?" 10 60; then
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


# Deinstallationsscript von Pterodactyl
uninstall_pterodactyl() {
    log_file="uninstall_pterodactyl.txt"
    : > "$log_file" # Leere die Log-Datei zu Beginn

    # Funktion zur Fortschrittsanzeige
    update_progress() {
        current_command=$((current_command + 1))
        percent=$((current_command * 100 / total_commands))
        echo "$percent"
    }

    # Warnung vor der Deinstallation
    if ! whiptail --title "WARNUNG" --yesno "Du bist dabei, das Panel und die dazugehörigen Server zu löschen. Fortfahren?" 10 50; then
        main_loop
        return
    fi

    # Entscheidung, ob Server behalten werden sollen
    if whiptail --title "Server behalten?" --yesno "Möchtest du die angelegten Server behalten?" 10 50; then
        total_size=$(du -sb /var/lib/pterodactyl/volumes/ | cut -f1)
        (cd /var/lib/pterodactyl/volumes/ && tar -cf - . | pv -n -s "$total_size" | gzip > /Backup_von_allen_Pterodactyl-Servern.tar.gz) 2>&1 | whiptail --gauge "Backup wird erstellt..." 6 50 0
        if ! whiptail --title "Backup Überprüfung" --yesno "Backup erstellt. Fortfahren?" 10 50; then
            main_loop
            return
        fi
    fi

    # Bestätigung zur kompletten Löschung
    while true; do
        CONFIRMATION=$(whiptail --title "Bestätige Löschung" --inputbox "Gib 'Ich bestätige die komplette Löschung von Pterodactyl' ein." 10 50 3>&1 1>&2 2>&3)
        if [ "$CONFIRMATION" = "Ich bestätige die komplette Löschung von Pterodactyl" ]; then
            break
        else
            whiptail --title "Falsche Eingabe" --msgbox "Falsche Bestätigung, versuche es erneut." 10 50
        fi
    done

    # Beginn des Löschvorgangs
    total_commands=9 # 9 Befehle entsprechen 100% Fortschritt
    current_command=0

    # Anpassung für das drehende Symbol in einem Whiptail-Fenster
    spinning_wheel() {
        local i=0
        local sp='/-\|'
        while [ "$i" -lt 100 ]; do
            echo "XXX"
            echo "$i"
            echo "Bitte warten, die Daten werden gelöscht... ${sp:i++%${#sp}:1}"
            echo "XXX"
            ((i=i+1))
            sleep 0.2
        done
    }

    # Starte das Spinning Wheel in einem Hintergrundprozess und speichere die Prozess-ID
    spinning_wheel | whiptail --title "Löschvorgang" --gauge "Bitte warten..." 6 50 0 &
    SPIN_PID=$!

    # Führe die Löschbefehle aus
    {
        for cmd in \
            "systemctl stop nginx" \
            "sudo rm -rf /var/www/pterodactyl" \
            "sudo rm /etc/systemd/system/pteroq.service" \
            "sudo unlink /etc/nginx/sites-enabled/pterodactyl.conf" \
            "sudo systemctl stop wings" \
            "sudo rm -rf /var/lib/pterodactyl" \
            "sudo rm -rf /etc/pterodactyl" \
            "sudo rm /usr/local/bin/wings" \
            "sudo rm /etc/systemd/system/wings.service"; do
            eval $cmd | tee -a "$log_file"
            sleep 1 # Warte 1 Sekunde nach jedem Befehl
        done
    }

    # Beende das Spinning Wheel, nachdem die Löschbefehle abgeschlossen sind
    kill $SPIN_PID

    # Abschlussmeldung
    whiptail --title "Deinstallation abgeschlossen" --msgbox "Pterodactyl wurde erfolgreich entferent. Der Webserver nginx bleibt aktiv, damit andere Dienste weiterhin online bleiben können." 10 50
    exit
    clear
}



# Funktion für Phpmyadmin-Installation - OFFEN
install_phpmyadmin() {
    # Hier kommt dein Skript zur Installation von Phpmyadmin
    echo "Phpmyadmin-Installationsskript ist noch zu implementieren."
    sleep 5
}


# Funktion zum Installieren von einer Auswahl an Themes - OFFEN
install_theme() {
    # Füge hier den Code für die Theme-Installation ein
    # Zum Beispiel: echo "Theme wurde erfolgreich installiert."
    echo "Diese Funktion ist noch in Arbeit."
    sleep 5
}


# Funktion zum Einrichten von Server-Backups
setup_server_backups() {
    clear
    echo "Weiterleitung zu Backup-Script..."
    wget https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/backup-verwaltung.sh -O backup-script
    chmod +x backup-script
    ./backup-script
}

# Funktion zum Einrichten des Database-Hosts - OFFEN
setup_database_host() {
    # Füge hier den Code für die Einrichtung des Database-Hosts ein
    # Zum Beispiel: echo "Database-Host wurde erfolgreich eingerichtet."
    echo "Diese Funktion ist noch in Arbeit."
    sleep 5
}



# Starte die Hauptfunktion
main_loop


# ENDE VON Vorbereitung ODER existiert bereits ODER Reperatur
# BEGINN DER TATSÄCHLICHEN INSTALLATION

# Funktion, um den Benutzer neu anzulegen
recreate_user() {
    {
        echo "10"; sleep 1
        echo "Benutzer löschen..."
        cd /var/www/pterodactyl && echo -e "1\n1\nyes" | php artisan p:user:delete
        echo "30"; sleep 1
        echo "Benutzer anlegen... Mit der Mail: $admin_email und dem Passwort: $user_password"
        cd /var/www/pterodactyl && php artisan p:user:make --email="$admin_email" --username=admin --name-first=Admin --name-last=User --password="$user_password" --admin=1
        echo "100"; sleep 1
    } | whiptail --gauge "Benutzer wird neu angelegt" 8 50 0
}

# Funktion zur Überprüfung einer gültigen Domain
isValidDomain() {
    DOMAIN_REGEX="^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
    if [[ $1 =~ $DOMAIN_REGEX ]]; then
        return 0
    else
        return 1
    fi
}


# Kopfzeile für die Pterodactyl Panel Installation anzeigen
clear
echo "----------------------------------"
echo "Pterodactyl Panel Installation"
echo "Vereinfacht von Pavl21, Script von https://pterodactyl-installer.se/ wird verwendet. "
echo "----------------------------------"
sleep 3  # 3 Sekunden warten, bevor das Skript fortgesetzt wird

# Überprüfen, ob der Benutzer Root-Rechte hat
if [ "$(id -u)" != "0" ]; then
    echo "Abbruch: Für die Installation werden Root-Rechte benötigt, damit benötigte Pakete installiert werden können. Falls du nicht der Administrator des Servers bist, bitte ihn, dir temporär Zugriff zu erteilen."
    exit 1
fi

# Konfiguration von dpkg
echo ""
echo ""
echo "STATUS - - - - - - - - - - - - - - - -"
echo "⚙️ Konfiguration von dpkg..."
dpkg --configure -a

# Notwendige Pakete installieren
clear
echo ""
echo ""
echo "STATUS - - - - - - - - - - - - - - -"
echo ""

# Eine verbesserte Ladeanimation, während alles Nötige installiert wird (Vorbereitung)
show_spinner() {
    local pid=$1
    local delay=0.45
    local spinstr='|/-\\'
    local msg="Notwendige Pakete werden installiert..."
    while [ "$(ps a | awk '{print $1}' | grep -w $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  $msg" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\r"
        for i in $(seq 1 $((${#msg} + 10))); do  # Korrigiert
            printf " "
        done
        printf "\r"
    done
    printf "                                             \r"
}

# Starte die Installation im Hintergrund und leite die Ausgabe um
(
    apt-get update &&
    apt-get upgrade -y &&
    apt-get install -y whiptail dnsutils curl openssl bc certbot python3-certbot-nginx pv sudo wget
) > /dev/null 2>&1 &

PID=$!

# Zeige die verbesserte Spinner-Animation, während die Installation läuft
show_spinner $PID

# Warte, bis die Installation abgeschlossen ist
wait $PID
exit_status=$?

# Überprüfe den Exit-Status
if [ $exit_status -ne 0 ]; then
    echo "Ein Fehler ist während der Vorbereitung aufgetreten. Einige Pakete scheinen entweder nicht zu existieren, oder es läuft im Hintergrund bereits ein Installations- oder Updateprozess. Im zweiten Fall muss gewartet werden, bis es abgeschlossen ist."
    exit $exit_status
fi

clear
echo ""
echo ""
echo "STATUS - - - - - - - - - - - - - - - -"
echo ""
echo "Vorbereitung abgeschlossen."
sleep 2


if whiptail --title "Willkommen!" --yesno "Dieses Script hilft dir dabei, das Pterodactyl Panel zu installieren. Beachte hierbei, dass du eine Domain benötigst (bzw. 2 Subdomains von einer bestehenden Domain).

Das Script zur Installation basiert auf dem Github-Projekt 'pterodactyl-installer.se' von Vilhelm Prytz. Durch Bestätigung stimmst du zu, dass:
- Abhängigkeiten, die benötigt werden, installiert werden dürfen
- Du den TOS von Let's Encrypt zustimmst
- Mit der Installation von GermanDactyl einverstanden bist
- Du der Besitzer der Domain bist bzw. die Berechtigung vorliegt
- Die angegebene E-Mail-Adresse deine eigene ist

Möchtest du fortfahren?" 22 70; then
    # Hier kommt der bestehende Code, der ausgeführt wird, wenn "Yes" ausgewählt wurde
    echo "Nice, weiter gehts, naja siehste sowieso nicht."
else
    # Hier kommt der Code, der ausgeführt wird, wenn "No" ausgewählt wurde
    echo "STATUS - - - - - - - - - - - - - - - -"
    echo ""
    echo "Die Installation wurde abgebrochen."
    exit 1
fi

# Überprüfen, ob die Datei existiert. Falls nicht, wird sie erstellt.
LOG_FILE="tmp.txt"
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi

clear

# Anzeige einer Whiptail-GUI zur Eingabe der Panel-Domain + Prüfung, ob es eine Domain ist.
while true; do
    panel_domain=$(whiptail --title "Pterodactyl Panel Installation" --inputbox "Bitte gebe die Domain/FQDN für das Panel ein, die du nutzen möchtest. Im nächsten Schritt wird geprüft, ob die Domain mit diesem Server als DNS-Eintrag verbunden ist." 12 60 3>&1 1>&2 2>&3)

    # Prüfen, ob der Benutzer die Eingabe abgebrochen hat
    if [ $? -ne 0 ]; then
        echo "Die Installation wurde abgebrochen."
        exit 1
    fi

    # Überprüfen, ob die eingegebene Domain einem gültigen Muster entspricht
    if [[ $panel_domain =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        break
    else
        whiptail --title "Domain ist ungültig" --msgbox "Bitte gib eine gültige Domain ein und prüfe auf Schreibfehler." 10 50
    fi
done

# IP-Adresse des Servers ermitteln
server_ip=$(hostname -I | awk '{print $1}')

# IP-Adresse aus dem DNS-A-Eintrag der Domain extrahieren
dns_ip=$(dig +short $panel_domain)

# Überprüfung, ob die Domain korrekt verknüpft ist
if [ "$dns_ip" == "$server_ip" ]; then
    whiptail --title "Domain-Überprüfung" --msgbox "✅ Die Domain $panel_domain ist mit der IP-Adresse dieses Servers ($server_ip) verknüpft. Die Installation wird fortgesetzt." 8 78
else
    whiptail --title "Domain-Überprüfung" --msgbox "❌ Die Domain $panel_domain ist mit einer anderen IP-Adresse verbunden ($dns_ip).\n\nPrüfe, ob die DNS-Einträge richtig sind, dass sich kein Schreibfehler eingeschlichen hat und ob du in Cloudflare (falls du es nutzt) den Proxy deaktiviert hast. Die Installation wird abgebrochen." 12 78
    exit 1
fi


# Funktion zur Überprüfung einer E-Mail-Adresse
validate_email() {
    if [[ $1 =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Schleife, die so lange läuft, bis eine gültige E-Mail-Adresse eingegeben wird. Soll ja schließlich später beim Certbot nicht schief gehen.
while true; do
    admin_email=$(whiptail --title "Pterodactyl Panel Installation" --inputbox "Bitte gebe die E-Mail-Adresse für das SSL-Zertifikat und den Admin-Benutzer ein. Durch Eingabe bestätigst du die Nutzungsbedingungen von Let's Encrypt.\n\nLink zu den Nutzungsbedingungen: https://community.letsencrypt.org/tos" 12 60 3>&1 1>&2 2>&3)


    # Prüfen, ob whiptail erfolgreich war
    if [ $? -ne 0 ]; then
        echo "Die Installation wurde vom Nutzer abgebrochen."
        exit 1
    fi

    # Prüfen, ob die E-Mail-Adresse gültig ist. Sowas wie provider@sonstwas.de
    if validate_email "$admin_email"; then
        break
    else
        whiptail --title "E-Mail Adresse ungültig" --msgbox  "Prüfe bitte die E-Mail und versuche es erneut." 10 50
    fi
done

# Funktion zum Generieren eines 16 Zeichen langen zufälligen Passworts ohne Sonderzeichen - Benutzerpasswort
generate_userpassword() {
    < /dev/urandom tr -dc A-Za-z0-9 | head -c16
}

user_password=$(generate_userpassword)



# Funktion zum Generieren eines 64 Zeichen langen zufälligen Passworts ohne Sonderzeichen für Datenbank - Braucht keiner wisssen, weil die Datenbank sowieso nicht angerührt werden muss.
generate_dbpassword() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c64
}

database_password=$(generate_dbpassword)

TITLE="STARTVORGANG"
MESSAGE="Bitte warte, bis die Installation abgeschlossen ist. Das kann je nach Leistung deines Servers einige Minuten dauern..."
TOTAL_TIME=10
STEP_DURATION=$((TOTAL_TIME * 1000 / 100)) # in Millisekunden
{
    for ((i=100; i>=0; i--)); do
        # Ausgabe des Fortschritts
        echo $i
        sleep 0.05
    done
} | whiptail --gauge "$MESSAGE" 8 78 0

# Funktion zur Aktualisierung des Fortschrittsbalkens mit Whiptail
update_progress() {
    percentage=$1
    message=$2
    echo -e "XXX\n$percentage\n$message\nXXX"
}

# Überwachungsfunktion für tmp.txt - Fortschritte müssen noch angepasst werden, Wert des Fortschritts springt dauernd hin und her.
monitor_progress() {
    highest_progress=0
    {
        while read line; do
            current_progress=0
            case "$line" in
                *"* Assume SSL? false"*)
                    update_progress 5 "Die Einstellungen werden festgelegt..." ;;
                *"Selecting previously unselected package apt-transport-https."*)
                    update_progress 10 "Der Installationsprozess beginnt in Kürze..." ;;
                *"Selecting previously unselected package mysql-common."*)
                    update_progress 15 "MariaDB wird jetzt installiert..." ;;
                *"Unpacking php8.1-zip"*)
                    update_progress 20 "Das Paket PHP 8.1 Common wird eingereichtet..." ;;
                *"Created symlink /etc/systemd/system/multi-user.target.wants/mariadb.service → /lib/systemd/system/mariadb.service."*)
                    update_progress 25 "MariaDB wird eingereichtet..." ;;
                *"Created symlink /etc/systemd/system/multi-user.target.wants/php8.1-fpm.service → /lib/systemd/system/php8.1-fpm.service."*)
                    update_progress 30 "Das Paket PHP 8.1 FPM wird aktiviert..." ;;
                *"Executing: /lib/systemd/systemd-sysv-install enable mariadb"*)
                    update_progress 35 "MariaDB wird aktiviert..." ;;
                *"* Installing composer.."*)
                    update_progress 40 "Composer wird installiert..." ;;
                *"* Downloading pterodactyl panel files .. "*)
                    update_progress 45 "Pterodactyl Panel Code wird heruntergeladen..." ;;
                *"database/.gitignore"*)
                    update_progress 50 "Datenbank-Migrations werden integriert..." ;;
                *"database/Seeders/eggs/"*)
                    update_progress 55 "Eggs werden vorbereitet..." ;;
                *"* Installing composer dependencies.."*)
                    update_progress 60 "Composer-Abhängigkeiten werden installiert..." ;;
                *"* Creating database user pterodactyl..."*)
                    update_progress 65 "Datenbank für Panel wird bereitgestellt..." ;;
                *"INFO  Running migrations."*)
                    update_progress 70 "Migrations werden gestartet..." ;;
                *"* Installing cronjob.. "*)
                    update_progress 75 "Cronjob wird bereitgestellt..." ;;
                *"* Installing pteroq service.."*)
                    update_progress 80 "Hintergrunddienste werden integriert..." ;;
                *"Saving debug log to /var/log/letsencrypt/letsencrypt.log"*)
                    update_progress 85 "SSL-Zertifikat wird bereigestellt..." ;;
                *"Congratulations! You have successfully enabled"*)
                    update_progress 90 "Zertifikat erfolgreich erstellt. GermanDactyl wird vorbereitet..." ;;
                *"Es wurde kein Instanzort angegeben. Deine Pterodactyl-Instanz wird im default-Ordner gesucht."*)
                    update_progress 95 "Die deutsche Übersetzung wird integriert..." ;;
                *"Der Patch wurde angewendet."*)
                    update_progress 100 "Prozesse werden beendet..." ;;
            esac
            if [ "$current_progress" -gt "$highest_progress" ]; then
                highest_progress=$current_progress
                update_progress $highest_progress "Aktueller Status..."
            fi
        done < <(tail -n 0 -f tmp.txt)
    } | whiptail --title "Pterodactyl Panel wird installiert" --gauge "Pterodactyl Panel - Installation" 10 70 0
}


# Starte die Überwachungsfunktion
monitor_progress &
MONITOR_PID=$!


# Installationscode hier, leite Ausgaben in tmp.txt um für listening der Logs.... ist das deutsch?
{
    bash <(curl -s https://pterodactyl-installer.se) <<EOF
    0
    panel
    pterodactyl
    $database_password
    Europe/Berlin
    $admin_email
    $admin_email
    admin
    Admin
    User
    $user_password
    $panel_domain
    N
    N
    N
    y
    yes
EOF
} >> tmp.txt 2>&1

{
    apt-get update && sudo apt-get install certbot python3-certbot-nginx -y
    systemctl stop nginx
    certbot --nginx -d $panel_domain --email $admin_email --agree-tos --non-interactive
    fuser -k 80/tcp
    fuser -k 443/tcp
    systemctl restart nginx
    curl -sSL https://install.germandactyl.de/ | sudo bash -s -- -v1.11.3
} >> tmp.txt 2>&1

# Am Ende des Skripts den Überwachungsprozess beenden
kill $MONITOR_PID
sleep 1

# Schließe das Fortschrittsbalken-Fenster
whiptail --clear
clear


# Funktion, um die Zugangsdaten anzuzeigen
show_access_data() {
    whiptail --title "Deine Zugangsdaten" --msgbox "Speichere dir diese Zugangsdaten ab und ändere sie zeitnah, damit die Sicherheit deines Accounts gewährleistet ist.\n\nDeine Domain für das Panel: $panel_domain\n\n Benutzername: admin\n E-Mail-Adresse: $admin_email\n Passwort (16 Zeichen): $user_password \n\nDieses Fenster wird sich nicht nochmals öffnen, speichere dir jetzt die Zugangsdaten ab." 15 80
}

# Info: Installation abgeschlossen
whiptail --title "Installation erfolgreich" --msgbox "Das Pterodactyl Panel sollte nun verfügbar sein. Du kannst dich nun einloggen, die generierten Zugangsdaten werden im nächsten Fenster angezeigt, wenn du dieses schließt.\n\nHinweis: Pterodactyl ist noch nicht vollständig eingerichtet. Du musst noch Wings einrichten und eine Node anlegen, damit du Server aufsetzen kannst. Im Panel findest du das Erstellen einer Node hier: https://$panel_domain/admin/nodes/new. Damit du dort hinkommst, musst du aber vorher angemeldet sein." 20 78

# Hauptlogik für die Zugangsdaten und die Entscheidung zur Installation von Wings
while true; do
    show_access_data

    if whiptail --title "Noch ne Frage" --yesno "Hast du die Zugangsdaten gespeichert?" 10 60; then
        if whiptail --title "Zugang geht?" --yesno "Funktionieren die Zugangsdaten?" 10 60; then
            if whiptail --title "Bereit für den nächsten Schritt" --yesno "Alles ist bereit! Als nächstes musst du Wings installieren, um Server aufsetzen zu können. Möchtest du Wings jetzt installieren?" 10 60; then
                clear
                echo "Weiterleitung zu Wings..."
                wget https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/wings-installer.sh -O wings
                chmod +x wings
                ./wings
                exit 0
            else
                whiptail --title "Installation abgebrochen" --msgbox "Wings-Installation wurde abgebrochen. Du kannst das Skript später erneut ausführen, um Wings zu installieren." 10 60
                exit 0
            fi
        else
            recreate_user
        fi
    else
        # Verlasse die Schleife, wenn "Nein" gewählt wird
        break
    fi
done

}

echo "Fertig"

# Code created by ChatGPT, zusammengesetzt und Idee der Struktur und Funktion mit einigen Vorgaben von Pavl21
