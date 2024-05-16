#!/bin/bash

# Überprüfen, ob /var/www/pelican existiert
if [ -d "/var/www/pelican" ]; then
    # Whiptail-Menü für Pelican Panel Verwaltung/Wartung anzeigen
    choice=$(whiptail --title "Pelican Panel Verwaltung/Wartung" \
        --menu "Pelican ist bereits installiert. Was möchtest du tun?" 15 70 2 \
        "1" "Panel aktualisieren" \
        3>&1 1>&2 2>&3)

    # Fallunterscheidung basierend auf der Benutzerwahl
    case $choice in
        1)
            # Panel aktualisieren
            clear
            echo ""
            echo ""
            echo "STATUS - - - - - - - - - - - - - - -"
            echo ""
            echo "Update wird heruntergeladen..."
            sleep 2
            cd /var/www/pelican > /dev/null 2>&1
            curl -Lo panel.tar.gz https://github.com/pelican-dev/panel/archive/refs/heads/main.zip
            clear
            echo ""
            echo ""
            echo "STATUS - - - - - - - - - - - - - - -"
            echo ""
            echo "Update wird angewendet..."
            tar -xzvf panel.tar.gz > /dev/null 2>&1
            mkdir -p /var/www/pelican/storage/framework/cache
            mkdir -p /var/www/pelican/storage/framework/views
            mkdir -p /var/www/pelican/storage/framework/sessions
            mkdir -p /var/www/pelican/bootstrap/cache
            touch /var/www/pelican/storage/framework/cache/.gitignore
            touch /var/www/pelican/storage/framework/views/.gitignore
            touch /var/www/pelican/storage/framework/sessions/.gitignore
            touch /var/www/pelican/bootstrap/cache/.gitignore
            chmod -R 755 storage/* bootstrap/cache/
            sudo chown -R www-data:www-data /var/www/pelican
            rm panel.tar.gz
            systemctl restart nginx
            installed_version=$(cat "/var/www/pelican/config/app.php" 2> /dev/null | grep "'version' =>" | cut -d\' -f4 | sed 's/^/v/') > /dev/null 2>&1
            clear
            echo ""
            echo ""
            echo "UPDATE INTEGRIERT - - - - - - - - - - - - - - -"
            echo ""
            echo "Das neueste Update wurde nun bereitgestellt"
            echo "Installierte Version: $installed_version"
            exit 0
            ;;
        *)
            echo "Abbruch."
            ;;
    esac
else
    clear
fi



# Kopfzeile für die Pelican Panel Installation anzeigen
clear
clear
echo "----------------------------------"
echo "GermanDactyl Setup - Pelican Panel [Alpha]"
echo "Erstellt von Pavl21, basierend auf GermanDactyl Setup für Pterodactyl "
echo "----------------------------------"
sleep 3  # 3 Sekunden warten, bevor das Skript fortgesetzt wird

# Überprüfen, ob der Benutzer Root-Rechte hat
if [ "$(id -u)" != "0" ]; then
    echo "Abgebrochen: Für die Installation werden Root-Rechte benötigt, damit benötigte Pakete installiert werden können. Falls du nicht der Administrator des Servers bist, bitte ihn, dir temporär Zugriff zu erteilen."
    exit 1
fi

# Wings installieren
install_wings() {
    clear
    echo "Weiterleitung zu Wings..."
    curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/wings-pelican.sh | bash
    exit 0
}

# Whiptail Menü Antworten auf Deutsch Einstellungen
export TEXTDOMAIN=dialog
export LANGUAGE=de_DE.UTF-8

# Funktion, um den Benutzer neu anzulegen
recreate_user() {
    {
        echo "10"; sleep 1
        echo "Benutzer löschen..."
        cd /var/www/pelican && echo -e "1\n1\nyes" | php artisan p:user:delete
        echo "30"; sleep 1
        echo "Benutzer anlegen... Mit der Mail: $admin_email und dem Passwort: $user_password"
        cd /var/www/pelican && php artisan p:user:make --email="$admin_email" --username=admin --password="$user_password" --admin=1
        echo "100"; sleep 1
    } | whiptail --gauge "Benutzer wird angelegt..." 8 50 0
}

# Notwendige Pakete installieren - Vorbereitung
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
    local msg="Zusätzliche Pakete werden für Pelican Panel vorbereitet..."
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
    dpkg --configure -a
    sudo apt update
    sudo apt install apt-transport-https lsb-release ca-certificates wget -y
    sudo wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
    sudo sh -c 'echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'
    sudo apt update
    sudo apt upgrade -y
    sudo apt install curl whiptail tar jq php8.2-cli php8.2-fpm php8.2-common php8.2-mysql php8.2-zip php8.2-gd dnsutils php8.2-mbstring php8.2-curl php8.2-xml php8.2-bcmath php8.2-intl php8.2-redis php8.2-sqlite3 sqlite3 mariadb-server software-properties-common gpg php-intl nginx btop dmidecode ncdu certbot -y
    sudo apt update
    sudo apt full-upgrade -y
    curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
) > /dev/null 2>&1 &

PID=$!

# Zeige die verbesserte Spinner-Animation, während die Installation läuft
show_spinner $PID

# Warte, bis die Installation abgeschlossen ist
wait $PID
exit_status=$?

# Überprüfe den Exit-Status
if [ $exit_status -ne 0 ]; then
    echo "Ein Fehler ist während der Vorbereitung aufgetreten. Einige Pakete scheinen entweder nicht zu existieren, die Aktualisierung der Pakete ist wegen fehlerhafter Quellen in apt nicht möglich, oder es läuft im Hintergrund bereits ein Installations- oder Updateprozess. Im zweiten Fall muss gewartet werden, bis es abgeschlossen ist. Die Vorbereitung und Installation wurde abgebrochen."
    exit $exit_status
fi

clear
echo ""
echo ""
echo "STATUS - - - - - - - - - - - - - - - -"
echo ""
echo "Vorbereitung abgeschlossen."
sleep 2
clear

# Erstmal Moin sagen
if whiptail --title "Willkommen!" --yesno "Dieses Script hilft dir dabei, das Pelican Panel zu installieren. Es basiert auf den empfohlenen Angaben der Entwickler, welche Dienste verwendet werden. Es kann also passieren, dass die Installation zu einem späteren Zeitpunkt nicht mehr kompatibel ist.

Möchtest du fortfahren?" 15 70; then
    # Benutzer hat 'Ja' ausgewählt, das Skript fortsetzen
    echo "Benutzer möchte fortsetzen..."
    clear
else
    # Benutzer hat 'Nein' ausgewählt, das Skript beenden
    echo "Installation abgelehnt. Abbrechen..."
    clear
    echo "STATUS - - - - - - - - - - - - - - - -"
    echo ""
    echo "Die Installation wurde abgebrochen, du hast die möglichen Fehler nicht akzeptiert."
    sleep 1
    exit 0
fi


# Warnung wegen Inkompatibiltät von GermanDactyl
# Setze NEWT_COLORS nur für dieses spezifische Fenster
OLD_NEWT_COLORS=$NEWT_COLORS
export NEWT_COLORS='
root=,red
window=,red
border=white,red
textbox=white,red
button=black,white
entry=,red
checkbox=,red
compactbutton=,red
'

# Warnung am Anfang - GermanDactyl <-> Pelican Panel -> Pterodactyl
whiptail --title "Inkompatibilitätswarnung" --yesno "GermanDactyl ist aktuell nicht für das Pelican Panel vorgesehen, weswegen es nicht übersetzt werden kann. Das Script installiert dir somit die originale Version. Laut erster Ansichten des Codes sollen aber von Haus aus mehrere Sprachen direkt integriert werden. Andere Features zu diesem Script funktionieren hier auch aktuell nicht! Bist du damit einverstanden?" 20 70

# Überprüfe die Antwort des Benutzers
if [ $? -eq 0 ]; then
    # Benutzer hat zugestimmt, das Skript fortsetzen
    echo "Fortfahren mit der Installation..."
else
    # Benutzer hat abgelehnt, das Skript beenden
    echo "Die Installation wurde abgelehnt. Abbrechen..."
    exit 0
fi

# Stelle die ursprünglichen NEWT_COLORS nach dem Aufruf wieder her
export NEWT_COLORS=$OLD_NEWT_COLORS



# Passt alles? Dann ab zu den Eingabefragen
while true; do
    panel_domain=$(whiptail --title "Pelican Panel Installation" --inputbox "Bitte gebe die Domain/FQDN für das Panel ein, die du nutzen möchtest. Im nächsten Schritt wird geprüft, ob die Domain mit diesem Server als DNS-Eintrag verbunden ist." 12 60 3>&1 1>&2 2>&3)

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
    whiptail --title "Domain-Überprüfung" --msgbox "❌ Die Domain $panel_domain ist mit einer anderen IP-Adresse verbunden ($dns_ip).\n\nPrüfe, ob die DNS-Einträge richtig sind, dass sich kein Schreibfehler eingeschlichen hat und ob du in Cloudflare (falls du es nutzt) den Proxy deaktiviert hast. Die Installation wird abgebrochen." 15 80
    exit 1
fi


# Funktion zur Überprüfung einer E-Mail-Adresse
validate_email() {
    if [[ $1 =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,10}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Schleife, die so lange läuft, bis eine gültige E-Mail-Adresse eingegeben wird. Soll ja schließlich später beim Certbot nicht schief gehen.
while true; do
    admin_email=$(whiptail --title "Pelican Panel Installation" --inputbox "Bitte gebe die E-Mail-Adresse für das SSL-Zertifikat und den Admin-Benutzer ein. Durch Eingabe bestätigst du die Nutzungsbedingungen von Let's Encrypt.\n\nLink zu den Nutzungsbedingungen: https://community.letsencrypt.org/tos" 12 60 3>&1 1>&2 2>&3)


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

# Funktion zum Generieren eines 32 Zeichen langen zufälligen Passworts ohne Sonderzeichen - Benutzerpasswort
generate_userpassword() {
    < /dev/urandom tr -dc A-Za-z0-9 | head -c32
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


# Installationsprozess ANFANG

# Funktion zur Aktualisierung des Fortschrittsbalkens mit Whiptail
update_progress() {
    percentage=$1
    message=$2
    echo -e "XXX\n$percentage\n$message\nXXX"
}

# Fortschrittsanzeige in einer Subshell starten und Pipe zur Whiptail nutzen
{
update_progress 0 "Vorbereitung der Installation..."
sleep 1

# Composer installieren
update_progress 10 "Composer wird installiert..."
curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer > /dev/null 2>&1

# Verzeichnisse erstellen und bereitstellen
sudo mkdir -p /var/www/pelican
update_progress 25 "Verzeichnisse werden erstellt..."
cd /var/www/pelican
curl -Lo panel.tar.gz https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz > /dev/null 2>&1
tar -xzvf panel.tar.gz > /dev/null 2>&1
rm panel.tar.gz
update_progress 40 "Verzeichnisse erstellt und bereitgestellt."

# Composer einrichten
update_progress 50 "Composer wird eingerichtet..."
yes | COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader > /dev/null 2>&1

# Umgebungskonfiguration vorbereiten und Datenbank initialisieren
update_progress 62 "Key wird generiert (kann dauern)..."
sudo php artisan key:generate --force > /dev/null 2>&1
update_progress 70 "Datenbank für Panel wird aufgesetzt..."
sudo php artisan p:environment:setup <<EOF > /dev/null 2>&1
$panel_domain
file
file
sync
yes
EOF

sleep 1

# Datenbank erstellen
update_progress 79 "Datenbank für Panel wird vorbereitet..."
if /usr/bin/mariadb -u root -p"password" -e "CREATE USER 'pelican'@'127.0.0.1' IDENTIFIED BY '$database_password'; GRANT ALL PRIVILEGES ON *.* TO 'pelican'@'127.0.0.1' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>&1 | tee /dev/tty | grep -q "ERROR"; then
    echo "Fehler beim Erstellen von Datenbankbenutzer und -datenbank." > /dev/null 2>&1
else
    if /usr/bin/mariadb -u root -p"password" -e "CREATE DATABASE IF NOT EXISTS panel; GRANT ALL PRIVILEGES ON panel.* TO 'pelican'@'127.0.0.1' IDENTIFIED BY '$database_password'; FLUSH PRIVILEGES;" 2>&1 | tee /dev/tty | grep -q "ERROR"; then
        echo "Fehler beim Erstellen von Datenbankbenutzer und -datenbank." > /dev/null 2>&1
    else
        update_progress 85 "Datenbankbenutzer und -datenbank erfolgreich erstellt."
        sleep 1
    fi
fi

sleep 1

# Umgebungskonfiguration für die Datenbank vorbereiten
update_progress 90 "Datenbank für Panel wird eingerichtet..."
sudo php artisan p:environment:database <<EOF > /dev/null 2>&1
mysql
127.0.0.1
3306
panel
pelican
$database_password
EOF

# Migration durchführen
update_progress 92 "Migration wird durchgeführt..."
sudo php artisan migrate --seed --force > /dev/null 2>&1
sleep 1

# Webserver konfigurieren
update_progress 94 "Webserver wird konfiguriert."
sleep 1
rm /etc/nginx/sites-enabled/default > /dev/null 2>&1

# Herunterladen der Konfigurationsdatei und Ersetzen der Platzhalter
curl -s https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/pelican.conf | sed "s/<domain>/$panel_domain/g" > /etc/nginx/sites-available/pelican.conf

sudo ln -s /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
chown -R www-data:www-data /var/www/pelican/*
fuser -k 80/tcp > /dev/null 2>&1
fuser -k 443/tcp > /dev/null 2>&1
sudo systemctl restart nginx > /dev/null 2>&1

# Admin-Account erstellen
update_progress 99 "Admin Account wird angelegt..."
sleep 1
sudo php artisan p:user:make <<EOF > /dev/null 2>&1
yes
$admin_email
admin
$user_password
EOF


} | whiptail --title "Pelican Panel wird installiert" --gauge "Vorbereitung der Installation..." 7 50 0

# Schließe das Fortschrittsbalken-Fenster
whiptail --clear
cd /var/www/pelican
mkdir -p /var/www/pelican/storage/framework/cache
mkdir -p /var/www/pelican/storage/framework/views
mkdir -p /var/www/pelican/storage/framework/sessions
mkdir -p /var/www/pelican/bootstrap/cache
touch /var/www/pelican/storage/framework/cache/.gitignore
touch /var/www/pelican/storage/framework/views/.gitignore
touch /var/www/pelican/storage/framework/sessions/.gitignore
touch /var/www/pelican/bootstrap/cache/.gitignore
chmod -R 755 storage/* bootstrap/cache/
sudo chown -R www-data:www-data /var/www/pelican
clear
echo ""
echo ""
echo "STATUS - - - - - - - - - - - - - - -"
echo ""
echo "SSL Zertifikat wird ausgestellt..."
certbot certonly --standalone -d $panel_domain --email $admin_email --agree-tos --non-interactive
systemctl restart nginx
clear

# Hintergrundaktivitäten
crontab -l > /dev/null 2>&1 | { cat; echo "* * * * * php /var/www/pelican/artisan schedule:run >> /dev/null 2>&1"; } | crontab - > /dev/null 2>&1
clear

# Installationsprozess ENDE

# ----------------
# Zum Schluss:
# Funktion, um die Zugangsdaten anzuzeigen
show_access_data() {
    whiptail --title "Deine Zugangsdaten" --msgbox "Speichere dir diese Zugangsdaten ab und ändere sie zeitnah, damit die Sicherheit deines Accounts gewährleistet ist.\n\nDeine Domain für das Panel: $panel_domain\n\n Benutzername: admin\n E-Mail-Adresse: $admin_email\n Passwort (32 Zeichen): $user_password \n\nDieses Fenster wird sich nicht nochmals öffnen, speichere dir jetzt die Zugangsdaten ab." 22 80
}

# Info: Installation abgeschlossen
# Diese Pfade scheinen zu fehlen, die werden hier manuell nachgefertigt
cd /var/www/pelican
mkdir -p /var/www/pelican/storage/framework/cache
mkdir -p /var/www/pelican/storage/framework/views
mkdir -p /var/www/pelican/storage/framework/sessions
mkdir -p /var/www/pelican/bootstrap/cache
touch /var/www/pelican/storage/framework/cache/.gitignore
touch /var/www/pelican/storage/framework/views/.gitignore
touch /var/www/pelican/storage/framework/sessions/.gitignore
touch /var/www/pelican/bootstrap/cache/.gitignore
chmod -R 755 storage/* bootstrap/cache/
sudo chown -R www-data:www-data /var/www/pelican
echo $panel_domain > /var/.panel_domain
clear
whiptail --title "Installation erfolgreich" --msgbox "Das Pelican Panel sollte nun verfügbar sein. Du kannst dich nun einloggen, die generierten Zugangsdaten werden im nächsten Fenster angezeigt, wenn du dieses schließt.\n\nHinweis: Pelican Panel ist noch nicht vollständig eingerichtet. Du musst noch Wings einrichten und eine Node anlegen, damit du Server aufsetzen kannst. Im Panel findest du das Erstellen einer Node hier: https://$panel_domain/admin/nodes/new. Damit du dort hinkommst, musst du aber vorher angemeldet sein." 22 80

# Hauptlogik für die Zugangsdaten und die Entscheidung zur Installation von Wings
while true; do
    show_access_data

    if whiptail --title "Noch ne Frage" --yesno "Hast du die Zugangsdaten gespeichert?" 10 60; then
        if whiptail --title "Zugang geht?" --yesno "Funktionieren die Zugangsdaten?" 10 60; then
            if whiptail --title "Bereit für den nächsten Schritt" --yesno "Alles ist bereit! Als nächstes musst du Wings installieren, um Server aufsetzen zu können. Möchtest du Wings jetzt installieren? Beachte, bei Pelican ist das etwas anders!" 10 60; then
                clear
                install_wings
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

clear
echo "Fertig"
