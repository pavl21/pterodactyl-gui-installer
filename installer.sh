#!/bin/bash

# Überprüfen, ob das System apt als Paketmanager verwendet
if ! command -v apt-get &> /dev/null; then
    echo "Abbruch: Für dein System ist dieses Script nicht vorgesehen. Derzeit wird nur Ubuntu, Debian und ähnliche Systeme unterstützt."
    exit 1
fi


# BEGINN VON Vorbereitung ODER existiert bereits ODER Reperatur
# TODO: Reperatur Modus etc. wieder einbinden mit Frage ob man das wirkluch will und benutzer erstellen. Derzeit nur Roh, nonfunktional.

# Funktion zur Überprüfung der E-Mail-Adresse
validate_email() {
    if [[ $1 =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Funktion zur Generierung einer zufälligen dreistelligen Zahl
generate_random_number() {
    echo $((RANDOM % 900 + 100))
}

# Hauptfunktion, um den Skript-Flow zu steuern
main_loop() {
    while true; do
        # Prüfe, ob das Pterodactyl-Verzeichnis existiert
        if [ -d "/var/www/pterodactyl" ]; then
            if whiptail --title "Benutzer erstellen" --yesno "Pterodactyl scheint bereits installiert zu sein.\nMöchtest du einen neuen Admin-Account erstellen?" 10 60; then
                # Benutzererstellung
                while true; do
                    ADMIN_EMAIL=$(whiptail --inputbox "Bitte gib eine gültige E-Mail-Adresse ein" 10 60 3>&1 1>&2 2>&3)
                    exitstatus=$?
                    if [ $exitstatus != 0 ]; then
                        return
                    fi
                    if validate_email $ADMIN_EMAIL; then
                        break
                    else
                        whiptail --title "Ungültige E-Mail" --msgbox "Die eingegebene E-Mail-Adresse ist ungültig. Bitte versuche es erneut." 10 60
                    fi
                done

                USER_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
                RANDOM_NUMBER=$(generate_random_number)
                COMMAND_OUTPUT=$(cd /var/www/pterodactyl && php artisan p:user:make --email=$ADMIN_EMAIL --username=admin_$RANDOM_NUMBER --name-first=Admin --name-last=User --password=$USER_PASSWORD --admin=1)

                if [[ $COMMAND_OUTPUT == *"+----------+--------------------------------------+"* ]]; then
                    if whiptail --title "Benutzer erstellen" --msgbox "🎉 Ein neuer Benutzer wurde erstellt.\n👤 Benutzername: admin_$RANDOM_NUMBER\n🔑 Passwort: $USER_PASSWORD" 12 78; then
                        if ! whiptail --title "Zugangsdaten" --yesno "Hast du dir die Zugangsdaten gespeichert?" 10 60; then
                            whiptail --title "Zugangsdaten" --msgbox "Bitte speichere die Zugangsdaten:\nBenutzername: admin_$RANDOM_NUMBER\nPasswort: $USER_PASSWORD" 12 78
                        fi
                        if whiptail --title "Login erfolgreich?" --yesno "Konntest du dich erfolgreich einloggen?" 10 60; then
                            return
                        else
                            LOGIN_ISSUE=$(whiptail --title "Login Problem" --menu "Wähle das Problem:" 15 60 3 \
                                "1" "Logindaten falsch" \
                                "2" "Panel nicht erreichbar" \
                                "3" "Pterodactyl deinstallieren" 3>&1 1>&2 2>&3)
                            case $LOGIN_ISSUE in
                                1) continue ;;
                                2) repair_panel ;;
                                3) uninstall_pterodactyl ;;
                            esac
                        fi
                    fi
                elif [[ $COMMAND_OUTPUT == *"The email has already been taken."* ]]; then
                    whiptail --title "Bereits vorhanden" --msgbox "Die E-Mail-Adresse ist bereits registriert. Bitte verwende eine andere E-Mail-Adresse." 10 60
                else
                    if whiptail --title "Fehler" --yesno "Die Benutzererstellung war nicht erfolgreich.\nMöchtest du es erneut versuchen?" 10 60; then
                        continue
                    else
                        return
                    fi
                fi
            else
                LOGIN_ISSUE=$(whiptail --title "Benutzer erstellen" --menu "Wähle das Problem:" 15 60 3 \
                    "1" "Logindaten falsch" \
                    "2" "Panel nicht erreichbar" \
                    "3" "Pterodactyl deinstallieren" 3>&1 1>&2 2>&3)
                case $LOGIN_ISSUE in
                    1) continue ;;
                    2) repair_panel ;;
                    3) uninstall_pterodactyl ;;
                esac
            fi
        else
            echo "Das Verzeichnis /var/www/pterodactyl existiert nicht. Fahre fort."
            return  # Beendet die Funktion und kehrt zur äußeren Schleife zurück
        fi
    done
}

# Funktion für die Reparatur des Panels
repair_panel() {
    # Reparaturlogik hier...
    echo "Panel-Reparaturfunktion ist noch zu implementieren."
}

# Funktion für die Deinstallation von Pterodactyl
uninstall_pterodactyl() {
    # Deinstallationslogik hier...
    echo "Deinstallationsfunktion ist noch zu implementieren."
}

# Validierungsfunktion für E-Mails (Beispiel)
validate_email() {
    local email=$1
    # Validierungslogik hier...
    return 0  # Angenommen, die E-Mail ist immer gültig
}

# Zufallszahlengenerator-Funktion (Beispiel)
generate_random_number() {
    echo $((RANDOM))
}

# Starte die Hauptfunktion
main_loop

# ENDE VON Vorbereitung ODER existiert bereits ODER Reperatur


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
    apt-get install -y whiptail dnsutils curl openssl bc certbot python3-certbot-nginx pv sudo
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

# Überwachungsfunktion für tmp.txt
monitor_progress() {
    {
        while read line; do
            case "$line" in
                *"Initial configuration completed. Continue with installation?"*)
                    update_progress 5 "Einstellungen werden festgelegt..." ;;
                *"Starting installation.. this might take a while!"*)
                    update_progress 10 "Installationsprozess beginnt" ;;
                *"Unpacking mariadb-server-10.5"*)
                    update_progress 15 "Entpacken des MariaDB-Servers" ;;
                *"Setting up php8.1-common"*)
                    update_progress 20 "Einrichtung von PHP 8.1 Common" ;;
                *"Setting up mariadb-server-10.5"*)
                    update_progress 25 "Einrichtung des MariaDB-Servers" ;;
                *"Unpacking php8.1-fpm"*)
                    update_progress 30 "Entpacken von PHP 8.1 FPM" ;;
                *"Setting up php8.1-fpm"*)
                    update_progress 35 "Einrichtung von PHP 8.1 FPM" ;;
                *"Created symlink /etc/systemd/system/timers.target.wants/phpsessionclean.timer"*)
                    update_progress 40 "Einrichtung der PHP Session Cleanup" ;;
                *"Unpacking redis-server"*)
                    update_progress 45 "Entpacken des Redis-Servers" ;;
                *"Setting up redis-server"*)
                    update_progress 50 "Einrichtung des Redis-Servers" ;;
                *"Setting up nginx"*)
                    update_progress 55 "Einrichtung von Nginx" ;;
                *"Created symlink /etc/systemd/system/multi-user.target.wants/redis-server.service"*)
                    update_progress 60 "Aktivierung des Redis-Servers" ;;
                *"Unpacking git"*)
                    update_progress 65 "Entpacken von Git" ;;
                *"Setting up git"*)
                    update_progress 70 "Einrichtung von Git" ;;
                *"Unpacking zip"*)
                    update_progress 75 "Entpacken von Zip" ;;
                *"Setting up zip"*)
                    update_progress 80 "Einrichtung von Zip" ;;
                *"Unpacking unzip"*)
                    update_progress 85 "Entpacken von Unzip" ;;
                *"Setting up unzip"*)
                    update_progress 90 "Einrichtung von Unzip" ;;
                *"Downloading pterodactyl panel files"*)
                    update_progress 95 "Download der Pterodactyl-Panel-Dateien" ;;
                *"Der Patch wurde angewendet."*)
                    update_progress 100 "Abschluss der Installation" ;;
            esac
        done < <(tail -n 0 -f tmp.txt)
    } | whiptail --gauge "Pterodactyl Panel - Installation" 10 70 0
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

# Info: Installation abgeschlossen
whiptail --title "Installation erfolgreich" --msgbox "Das Pterodactyl Panel sollte nun verfügbar sein. Du kannst dich nun einloggen, die generierten Zugangsdaten werden im nächsten Fenster angezeigt, wenn du dieses schließt.\n\nHinweis: Pterodactyl ist noch nicht vollständig eingerichtet. Du musst noch Wings einrichten und eine Node anlegen, damit du Server aufsetzen kannst. Im Panel findest du das Erstellen einer Node hier: https://$panel_domain/admin/nodes/new. Damit du dort hinkommst, musst du aber vorher angemeldet sein." 20 78

# Funktion, um die Zugangsdaten anzuzeigen
show_access_data() {
    whiptail --title "Deine Zugangsdaten" --msgbox "Speichere dir diese Zugangsdaten ab und ändere sie zeitnah, damit die Sicherheit deines Accounts gewährleistet ist.\n\nDeine Domain für das Panel: $panel_domain\n\n Benutzername: admin\n E-Mail-Adresse: $admin_email\n Passwort (16 Zeichen): $user_password \n\nDieses Fenster wird sich nicht nochmals öffnen, speichere dir jetzt die Zugangsdaten ab." 15 80
}

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

# Hauptlogik
while true; do
    show_access_data

    if whiptail --title "Bestätigung" --yesno "Hast du die Zugangsdaten gespeichert?" 10 60; then
        if whiptail --title "Zugangsdaten Test" --yesno "Funktionieren die Zugangsdaten?" 10 60; then
            whiptail --title "Bereit für den nächsten Schritt" --msgbox "Alles ist bereit! Als nächstes musst du Wings installieren, um Server aufsetzen zu können." 10 60
            break
        else
            recreate_user
        fi
    fi
done

echo "Fertig"
