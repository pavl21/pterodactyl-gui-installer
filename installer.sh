#!/bin/bash

# Überprüfen, ob Whiptail installiert ist, und falls nicht, es installieren
if ! command -v whiptail &> /dev/null; then
    echo "Whiptail ist nicht installiert. Installiere Whiptail..."

    # Je nach Paketverwaltungssystem die Installation durchführen
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get upgrade -y
        sudo apt-get install whiptail -y
    elif command -v dnf &> /dev/null; then
        echo "Abbruch: Für dein System ist dieses Script nicht vorgesehen. Derzeit wird nur Ubuntu und Debian unterstützt."
    elif command -v yum &> /dev/null; then
        echo "Abbruch: Für dein System ist dieses Script nicht vorgesehen. Derzeit wird nur Ubuntu und Debian unterstützt."
    else
        echo "Paketverwaltungssystem nicht erkannt. Bitte installiere Whiptail manuell."
        exit 1
    fi
fi

# Kopfzeile für die Pterodactyl Panel Installation anzeigen
clear
echo "----------------------------------"
echo "Pterodactyl Panel Installation"
echo "Vereinfacht von Pavl21, Script von https://pterodactyl-installer.se/ wird verwendet. "
echo "----------------------------------"
sleep 3  # 3 Sekunden warten, bevor das Skript fortgesetzt wird

# Konfiguration von dpkg
echo ""
echo ""
echo "STATUS - - - - - - - - - - - - - - - -"
echo "⚙️ Konfiguration von dpkg..."
sudo dpkg --configure -a

# Notwendige Pakete installieren
echo "STATUS - - - - - - - - - - - - - - - -"
echo "⚙️ Abhängigkeiten werden installiert..."
sudo apt-get update
sudo apt-get install certbot python3-certbot-nginx bc dnsutils curl openssl -y


LOG_FILE="tmp.txt"
# Überprüfen, ob die Datei existiert. Falls nicht, wird sie erstellt.
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi

# Befehlszeile leeren
clear

# Anzeige einer Whiptail-GUI zur Eingabe der Panel-Domain
panel_domain=$(whiptail --inputbox "Bitte gebe die Domain/FQDN für das Panel ein:" 10 50 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then
    echo "Abbruch durch Benutzer."
    exit 1
fi

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
    admin_email=$(whiptail --inputbox "Bitte gebe die E-Mail-Adresse für das SSL-Zertifikat und den Admin-Benutzer ein. Durch Eingabe bestätigst du die Nutzungsbedingungen von Let's Encrypt." 10 50 3>&1 1>&2 2>&3)

    # Prüfen, ob whiptail erfolgreich war
    if [ $? -ne 0 ]; then
        echo "Die Installation wurde vom Nutzer abgebrochen."
        exit 1
    fi

    # Prüfen, ob die E-Mail-Adresse gültig ist. Sowas wie provider@sonstwas.de
    if validate_email "$admin_email"; then
        break
    else
        whiptail --msgbox "Ungültige E-Mail-Adresse. Bitte versuche es erneut." 10 50
    fi
done

# Funktion zum Generieren eines 64 Zeichen langen zufälligen Passworts ohne Sonderzeichen - Benutzerpasswort
generate_userpassword() {
    < /dev/urandom tr -dc A-Za-z0-9 | head -c64
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
                *"This script is not associated with the official Pterodactyl Project"*)
                    update_progress 1 "Installation wird gestartet" ;;
                *"(Reading database ... 100%"*)
                    update_progress 2 "Pakete werden geholt und installiert..." ;;
                *"redis-tools"*)
                    update_progress 6 "Notwendige Abhängigkeiten werden vorbereitet und installiert..." ;;
                *"Selecting previously unselected package zip"*)
                    update_progress 9 "Installation wird fortgesetzt\nDie Abhängigkeiten dauern i.d.R länger..." ;;
                *"Created symlink /etc/systemd/system/timers.target.wants/phpsessionclean.timer → /lib/systemd/system/phpsessionclean.timer."*)
                    update_progress 15 "PHP-Common wird entpackt" ;;
                *"Setting up php8.1-common"*)
                    update_progress 20 "PHP 8.1 wird konfiguriert" ;;
                *"Setting up mariadb-server"*)
                    update_progress 23 "MariaDB Server wird eingerichtet" ;;
                *"Installing composer.."*)
                    update_progress 25 "Composer wird installiert" ;;
                *"Downloading pterodactyl panel files .."*)
                    update_progress 28 "Pterodactyl Panel wird heruntergeladen" ;;
                *"resources/scripts/components/server/settings/"*)
                    update_progress 48 "Pterodactyl Panel Ressourcen werden installiert" ;;
                *"resources/views/vendor/pagination/"*)
                    update_progress 51 "Pterodactyl Panel Views werden installiert" ;;
                *"yarn.lock"*)
                    update_progress 52 "Yarn Konfigurationen werden installiert" ;;
                *"Installing composer dependencies.."*)
                    update_progress 53 "Composer Abhängigkeiten werden installiert" ;;
                *"Creating database user pterodactyl..."*)
                    update_progress 65 "Datenbankbenutzer wird erstellt" ;;
                *"Granting all privileges on panel to pterodactyl..."*)
                    update_progress 70 "Datenbankrechte werden eingerichtet" ;;
                *"Creating migration table"*)
                    update_progress 74 "Datenbankmigration wird durchgeführt" ;;
                *"Database\Seeders\EggSeeder"*)
                    update_progress 78 "Datenbank Seeds werden eingerichtet" ;;
                *"Installing cronjob.."*)
                    update_progress 87 "Cronjob wird eingerichtet" ;;
                *"Installed pteroq!"*)
                    update_progress 88 "Pteroq wird installiert" ;;
                *"Created symlink /etc/systemd/system/multi-user.target.wants/pteroq.service → /etc/systemd/system/pteroq.service."*)
                    update_progress 89 "Nginx wird konfiguriert" ;;
                *"SSL-Zertifikat erstellen und Nginx konfigurieren..."*)
                    update_progress 92 "SSL-Zertifikat wird bereitgestellt" ;;
                *"Neustarten von Nginx..."*)
                    update_progress 93 "Nginx wird neu gestartet" ;;
                *"GermanDactyl wird installiert..."*)
                    update_progress 94 "GermanDactyl wird installiert..." ;;
                *"Das Panel wird nun erneut kompiliert. Das dauert einen Moment."*)
                    update_progress 98 "GermanDactyl wird integriert..." ;;
                *"Der Patch wurde angewendet."*)
                    update_progress 100 "Installation abgeschlossen" ;;
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
    user
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
    sudo apt-get update && sudo apt-get install certbot python3-certbot-nginx -y
    sudo systemctl stop nginx
    sudo certbot --nginx -d $panel_domain --email $admin_email --agree-tos --non-interactive
    sudo fuser -k 80/tcp
    sudo fuser -k 443/tcp
    sudo systemctl restart nginx
    curl -sSL https://install.germandactyl.de/ | sudo bash -s -- -v1.11.3
    echo "Benutzer löschen..."
    cd /var/www/pterodactyl && echo -e "1\n1\nyes" | php artisan p:user:delete
    echo "Benutzer anlegen... Mit der Mail: $admin_email und dem Passwort: $user_password"
    cd /var/www/pterodactyl && php artisan p:user:make --email=$admin_email --username=user --name-first=Admin --name-last=User --password=$user_password --admin=1
} >> tmp.txt 2>&1

# Am Ende des Skripts den Überwachungsprozess beenden
kill $MONITOR_PID
sleep 1

# Schließe das Fortschrittsbalken-Fenster
whiptail --clear
clear


# Erfolgreiche Installationsnachricht in zugangsdaten.txt speichern
echo "PTERODACTYL ZUGANGSDATEN -----------------" > zugangsdaten.txt
echo "Installation des Panels erfolgreich." >> zugangsdaten.txt
echo "🌐 Die verwendete Domain ist: $panel_domain" >> zugangsdaten.txt
echo "🔑 Die generierten Zugangsdaten sind:" >> zugangsdaten.txt
echo "👤 Benutzername: User" >> zugangsdaten.txt
echo "🔒 Passwort (64 Zeichen): $user_password" >> zugangsdaten.txt
echo "PTERODACTYL ZUGANGSDATEN ------------------" >> zugangsdaten.txt
sleep 1
clear

# Whiptail-Nachrichtenbox anzeigen
whiptail --title "Installation abgeschlossen" --msgbox "Die Zugangsdaten wurden in die Datei 'zugangsdaten.txt' gespeichert, diese kannst du mit dem Befehl 'cat zugangsdaten.txt' sehen. Du kannst dich nun in $panel_domain anmelden.\n\nHINWEIS: Pterodactyl ist noch nicht vollständig eingerichtet. Du musst noch Wings einrichten und eine Node anlegen, damit du Server aufsetzen kannst. Im Panel findest du das Erstellen einer Node hier: https://$panel_domain/admin/nodes/new." 20 70

# rm tmp.txt - Löscht die tmp.txt, derzeit auskommentiert für Debugging.
# Fertig.
