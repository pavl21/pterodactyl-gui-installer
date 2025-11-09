#!/bin/bash

# Überprüfen, ob das System apt als Paketmanager verwendet
if ! command -v apt-get &> /dev/null; then
    echo "Abbruch: Für dein System ist dieses Script nicht vorgesehen. Derzeit wird nur Ubuntu, Debian und ähnliche Systeme unterstützt."
    exit 1
fi

# BEGINN VON Vorbereitung ODER existiert bereits ODER Reparatur

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


# Whiptail Menü Antworten auf Deutsch Einstellungen
export TEXTDOMAIN=dialog
export LANGUAGE=de_DE.UTF-8

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
            MAIN_MENU=$(whiptail --title "Pterodactyl Verwaltung/Wartung" --menu "Pterodactyl ist bereits installiert.\nWähle eine Aktion:" 30 90 13 \
                "1" "🔍 Problembehandlung" \
                "2" "📦 PhpMyAdmin installieren" \
                "3" "🐦 Wings nachinstallieren" \
                "4" "📂 Backup-Verwaltung öffnen" \
                "5" "🏢 Database-Host einrichten" \
                "6" "🖌️  SSH-Loginseite integrieren" \
                "7" "🔄 SWAP-Verwaltung öffnen" \
                "8" "🎨 Theme-Verwaltung öffnen" \
                "9" "🗑️  Pterodactyl deinstallieren" \
                "10" "🚪 Skript beenden" 3>&1 1>&2 2>&3)
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
                1) troubleshoot_issues ;;
                2) install_phpmyadmin ;;
                3) install_wings ;;
                4) setup_server_backups ;;
                5) setup_database_host ;;
                6) setup_ssh_login ;;
                7) manage_swap_storage ;;
                8) install_theme ;;
                9) uninstall_pterodactyl ;;
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




# Problembehandlung öffnen
troubleshoot_issues() {
    clear
    echo "Weiterleitung zu Problembehandlung..."
    curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/problem-verwaltung.sh | bash
    exit 0
}


# Wings installieren
install_wings() {
    clear
    echo "Weiterleitung zu Wings..."

    # Email aus Panel-Konfiguration auslesen, falls vorhanden
    if [ -f "/var/www/pterodactyl/.env" ]; then
        PANEL_EMAIL=$(grep "^MAIL_FROM_ADDRESS=" /var/www/pterodactyl/.env 2>/dev/null | cut -d'=' -f2)
        if [ -z "$PANEL_EMAIL" ]; then
            # Fallback: Admin-Email aus Datenbank holen
            DB_PASSWORD=$(grep "^DB_PASSWORD=" /var/www/pterodactyl/.env | cut -d'=' -f2)
            DB_USERNAME=$(grep "^DB_USERNAME=" /var/www/pterodactyl/.env | cut -d'=' -f2)
            DB_DATABASE=$(grep "^DB_DATABASE=" /var/www/pterodactyl/.env | cut -d'=' -f2)
            PANEL_EMAIL=$(mysql -u"$DB_USERNAME" -p"$DB_PASSWORD" -D"$DB_DATABASE" -se "SELECT email FROM users WHERE root_admin = 1 LIMIT 1" 2>/dev/null)
        fi
        export PANEL_EMAIL
    fi

    # Wings-Installer mit Email-Variable aufrufen
    curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/wings-installer.sh | bash
    exit 0
}

# Pelican Panel + Wings installieren
install_pelican() {
    clear
    echo "Weiterleitung zu PP + W..."
    curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/pelican-installer.sh | bash
    exit 0
}


# SWAP-Speicher zuweisen
manage_swap_storage() {
    clear
    echo "Weiterleitung zu swap-config..."
    curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/swap-verwaltung.sh | bash
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


# Deinstallationsscript von Pterodactyl
uninstall_pterodactyl() {
    log_file="uninstall_pterodactyl.txt"
    : > "$log_file" # Leere die Log-Datei zu Beginn

    # Warnung vor der Deinstallation
    if ! whiptail --title "⚠️  WARNUNG" --yesno "Du bist dabei, das Panel und die dazugehörigen Server zu löschen. Fortfahren?" 10 50; then
        echo "Deinstallation abgebrochen."
        return
    fi

    # Entscheidung, ob Server behalten werden sollen
    if whiptail --title "💾  Server behalten?" --yesno "Möchtest du die angelegten Server behalten?" 10 50; then
        total_size=$(du -sb /var/lib/pterodactyl/volumes/ | cut -f1)
        (cd /var/lib/pterodactyl/volumes/ && tar -cf - . | pv -n -s "$total_size" | gzip > /Backup_von_allen_Pterodactyl-Servern.tar.gz) 2>&1 | whiptail --gauge "Backup wird erstellt..." 6 50 0
        if ! whiptail --title "🔍  Backup Überprüfung" --yesno "Backup erstellt. Fortfahren?" 10 50; then
            echo "Deinstallation abgebrochen."
            return
        fi
    fi

    # Bestätigung zur kompletten Löschung
    while true; do
        CONFIRMATION=$(whiptail --title "🗑️  Bestätigung" --inputbox "Gib 'Ich bestätige die komplette Löschung von Pterodactyl' ein." 10 50 3>&1 1>&2 2>&3)
        if [ "$CONFIRMATION" = "Ich bestätige die komplette Löschung von Pterodactyl" ]; then
            break
        else
            whiptail --title "❌  Falsche Eingabe" --msgbox "Falsche Bestätigung, versuche es erneut." 10 50
        fi
    done

    # Fortschritt der Deinstallation überwachen und aktualisieren
    progress=0
    {
        # Führe das Deinstallationsskript aus und lese die Ausgabe
        bash <(curl -s https://pterodactyl-installer.se) <<EOF 2>&1 | while IFS= read -r line; do
6
y
y
y
y
y
EOF
            echo "$line" >> "$log_file"
            case "$line" in
                *SUCCESS:\ Removed\ panel\ files.*)
                    progress=5 ;;
                *Removing\ cron\ jobs...*)
                    progress=10 ;;
                *SUCCESS:\ Removed\ cron\ jobs.*)
                    progress=20 ;;
                *Removing\ database...*)
                    progress=30 ;;
                *SUCCESS:\ Removed\ database\ and\ database\ user.*)
                    progress=40 ;;
                *Removing\ services...*)
                    progress=50 ;;
                *SUCCESS:\ Removed\ services.*)
                    progress=60 ;;
                *Removing\ docker\ containers\ and\ images...*)
                    progress=70 ;;
                *SUCCESS:\ Removed\ docker\ containers\ and\ images.*)
                    progress=80 ;;
                *Removing\ wings\ files...*)
                    progress=90 ;;
                *SUCCESS:\ Removed\ wings\ files.*)
                    progress=95 ;;
                *Thank\ you\ for\ using\ this\ script.*)
                    progress=100 ;;
            esac

            # Aktualisiere den Fortschritt
            echo "XXX"
            echo "Die Deinstallation wird durchgeführt..."
            echo "XXX"
            echo $progress
        done
    } | whiptail --title "🗑️  Deinstallation" --gauge "Die Deinstallation wird durchgeführt..." 6 50 0

    # Abschlussmeldung
    whiptail --title "✅  Deinstallation abgeschlossen" --msgbox "Pterodactyl wurde erfolgreich entfernt. Der Webserver nginx bleibt aktiv, damit andere Dienste weiterhin online bleiben können." 10 50
    clear
}



# Funktion für Phpmyadmin-Installation
install_phpmyadmin() {
    clear
    echo "Weiterleitung zu PhpMyAdmin..."
    curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/phpmyadmin-installer.sh | bash
    exit 0
}


# Funktion zur Theme-Verwaltung
install_theme() {
    clear
    echo "Weiterleitung zu Theme-Verwaltung..."
    curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/theme-verwaltung.sh | bash
    exit 0
}



# Funktion zum Einrichten von Server-Backups + Panel-Backups
setup_server_backups() {
    clear
    echo "Weiterleitung zu Backup-Script..."
    curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/backup-verwaltung.sh | bash
    exit 0
}


# Funktion zum Einrichten des Database-Hosts - OFFEN
setup_database_host() {
    curl -sSL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/database-host-config.sh | bash
    exit 0
}

# Funktion zum integrieren der eigenen SSH Login-Page
setup_ssh_login() {
    curl -sSL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/custom-ssh-login-config.sh | bash
    exit 0
}




# Starte die Hauptfunktion
main_loop


# ENDE VON Vorbereitung ODER existiert bereits ODER Reparatur
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
clear
echo "----------------------------------"
echo "GermanDactyl Setup"
echo "Vereinfacht von Pavl21, Script von https://pterodactyl-installer.se/ wird zur Installation vom Panel und Wings verwendet. "
echo "----------------------------------"
sleep 3  # 3 Sekunden warten, bevor das Skript fortgesetzt wird

# Überprüfen, ob der Benutzer Root-Rechte hat
if [ "$(id -u)" != "0" ]; then
    echo "Abgebrochen: Für die Installation werden Root-Rechte benötigt, damit benötigte Pakete installiert werden können. Falls du nicht der Administrator des Servers bist, bitte ihn, dir temporär Zugriff zu erteilen."
    exit 1
fi

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
    dpkg --configure -a
    apt-get update &&
    apt-get upgrade -y &&
    sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get install -y whiptail dnsutils curl expect openssl bc certbot python3-certbot-nginx pv sudo wget ruby-full -y && sudo gem install lolcat && sudo apt autoremove -y
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

# Prüfen, ob das System im Heimnetz installiert wird
# Ermittle die IP-Adresse und den Systemnamen
IP_ADDRESS=$(hostname -I | awk '{print $1}')
SYSTEM_NAME=$(uname -o)

# Prüfe, ob die IP-Adresse im Heimnetz liegt (192.168.*, 10.0.*, 172.16.* oder 172.32.*. Stand zumindest so im Interbrett.)
if [[ $IP_ADDRESS == 192.168.* ]] || [[ $IP_ADDRESS == 10.0.* ]] || ([[ $IP_ADDRESS == 172.16.* ]] && [[ $IP_ADDRESS != 172.32.* ]]); then
    # Sichere die aktuelle NEWT_COLORS Umgebungsvariable
    OLD_NEWT_COLORS=$NEWT_COLORS

    # Setze NEWT_COLORS nur für dieses spezifische Fenster
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

    # Zeige das Whiptail-Fenster an
    if whiptail --title "Lokales Heimnetz" --yesno "Es scheint so, als wenn du dieses Script auf einem Rechner oder Server verwenden möchtest, der in deinem Heimnetz läuft. Wir möchten dich hier einmal darauf hinweisen, das wir dir nicht beim Einrichten bezüglich des Heimnetzes nach draußen helfen können. Vergewissere dich, das du das Script auf dem richtigen PC ausführst. Gerade startest du es über:\n\nSYSTEMNAME: $SYSTEM_NAME\nIP-Adresse: $IP_ADDRESS\n\nWenn das deine Absicht ist, dann bestätige mit Ja. Wenn du Abbrechen möchtest, mit Nein." 20 80; then
        echo "Fortsetzung des Scripts..."
    else
        echo "Das Script wird abgebrochen."
        exit 1
    fi

    # Stelle die ursprünglichen NEWT_COLORS nach dem Aufruf wieder her
    export NEWT_COLORS=$OLD_NEWT_COLORS
else
    echo "IP-Adresse liegt nicht im privaten Bereich. Fortsetzung des Scripts..."
    clear
fi


# Begrüßung im Script, ganz am Anfang wenn Pterodactyl noch nicht installiert ist.
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


# Panel + Wings, oder nur Wings? Das ist hier die Frage!
CHOICE=$(whiptail --title "Dienste installieren" --menu "Was möchtest du installieren?" 15 70 3 \
"1" "Panel + Wings installieren" \
"2" "Nur Wings installieren" \
"3" "Pelican Panel + Wings installieren" 3>&1 1>&2 2>&3)

EXITSTATUS=$?

if [ $EXITSTATUS = 0 ]; then
  # Benutzer hat eine Option gewählt
  case $CHOICE in
    1)
      echo "Panel wird installiert..."
      USE_STANDALONE=true
      ;;
    2)
      install_wings
      exit 0
      ;;
    3)
      echo "Pelican Panel und Wings werden installiert..."
      install_pelican
      exit 0
      ;;
  esac
else
  # Wenn man abbricht, dann wird das Script auch abgebrochen.
  exit 0
fi



# Überprüfen, ob die Datei existiert. Falls nicht, wird sie erstellt.
LOG_FILE="tmp.txt"
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi

clear

# Testen, ob CPU für den Betrieb ok ist.
#!/bin/bash

# Überprüfe die CPU-Architektur
output=$(uname -m)
echo "Aktuelle CPU-Architektur: $output"

# Wenn die Architektur nicht amd64 ist, führe die folgenden Befehle aus
if [ "$output" != "x86_64" ]; then
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

    # Zeige ein Dialogfenster mit Whiptail an
    if whiptail --title "Konflikt mit CPU-Architektur" --yesno "Die CPU, die in diesem Server verbaut ist, war in der Vergangenheit als Betrieb für das Panel für andere problematisch. Auch das Betreiben von Servern könnte zu unangenehmen Situationen kommen. Diese Probleme müssen nicht auftreten, aber es wäre zumindest bekannt. Du kannst trotzdem fortfahren, möchtest du?" 20 70; then
        echo
        echo "Fortsetzen des Scripts..."
        cpu_arch_conflict=true
    else
        clear
        echo "STATUS - - - - - - - - - -"
        echo ""
        echo "Das Script wurde abgebrochen."
        # Stelle die ursprünglichen NEWT_COLORS nach dem Aufruf wieder her
        export NEWT_COLORS=$OLD_NEWT_COLORS
        exit 0
    fi

    # Stelle die ursprünglichen NEWT_COLORS nach dem Aufruf wieder her
    export NEWT_COLORS=$OLD_NEWT_COLORS
else
    # Architektur ist amd64, kein Konflikt festgestellt
    echo "Die CPU-Architektur ist amd64, kein Konflikt festgestellt."
fi



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

# Funktion zum Generieren eines 32 Zeichen langen zufälligen Passworts ohne Sonderzeichen - Benutzerpasswort
generate_userpassword() {
    < /dev/urandom tr -dc A-Za-z0-9 | head -c32
}

user_password=$(generate_userpassword)



# Funktion zum Generieren eines 64 Zeichen langen zufälligen Passworts ohne Sonderzeichen für Datenbank - Braucht keiner wissen, weil die Datenbank sowieso nicht angerührt werden muss.
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

# Überwachungsfunktion für tmp.txt mit detaillierten Fortschrittsanzeigen
monitor_progress() {
    highest_progress=0
    {
        while read line; do
            current_progress=$highest_progress
            case "$line" in
                *"* Assume SSL? false"*)
                    current_progress=3
                    update_progress $current_progress "📋 Konfiguration wird vorbereitet..." ;;
                *"* Configuring panel environment.."*)
                    current_progress=5
                    update_progress $current_progress "⚙️  Umgebungsvariablen werden gesetzt..." ;;
                *"Selecting previously unselected package apt-transport-https."*)
                    current_progress=8
                    update_progress $current_progress "📦 Basis-Pakete werden installiert..." ;;
                *"Selecting previously unselected package mysql-common."*)
                    current_progress=12
                    update_progress $current_progress "🗄️  MariaDB-Abhängigkeiten werden heruntergeladen..." ;;
                *"Setting up mysql-common"*)
                    current_progress=15
                    update_progress $current_progress "🗄️  MariaDB wird konfiguriert..." ;;
                *"Unpacking php8.1"*)
                    current_progress=18
                    update_progress $current_progress "🐘 PHP 8.1 wird installiert..." ;;
                *"Setting up php8.1-common"*)
                    current_progress=22
                    update_progress $current_progress "🐘 PHP 8.1 Common wird konfiguriert..." ;;
                *"Setting up php8.1-cli"*)
                    current_progress=25
                    update_progress $current_progress "🐘 PHP CLI wird eingerichtet..." ;;
                *"Created symlink /etc/systemd/system/multi-user.target.wants/mariadb.service"*)
                    current_progress=28
                    update_progress $current_progress "🗄️  MariaDB-Service wird aktiviert..." ;;
                *"Created symlink /etc/systemd/system/multi-user.target.wants/php8.1-fpm.service"*)
                    current_progress=32
                    update_progress $current_progress "🐘 PHP-FPM Service wird aktiviert..." ;;
                *"Setting up mariadb-server"*)
                    current_progress=35
                    update_progress $current_progress "🗄️  MariaDB-Server wird gestartet..." ;;
                *"Setting up nginx"*)
                    current_progress=38
                    update_progress $current_progress "🌐 Nginx Webserver wird installiert..." ;;
                *"* Installing composer.."*)
                    current_progress=42
                    update_progress $current_progress "🎼 Composer wird heruntergeladen und installiert..." ;;
                *"* Downloading pterodactyl panel files"*)
                    current_progress=48
                    update_progress $current_progress "📥 Pterodactyl Panel-Dateien werden heruntergeladen..." ;;
                *"database/.gitignore"*)
                    current_progress=52
                    update_progress $current_progress "📂 Datenbank-Struktur wird vorbereitet..." ;;
                *"database/Seeders/eggs/"*)
                    current_progress=55
                    update_progress $current_progress "🥚 Standard-Eggs werden geladen..." ;;
                *"* Installing composer dependencies.."*)
                    current_progress=58
                    update_progress $current_progress "📦 Composer-Abhängigkeiten werden installiert (kann dauern)..." ;;
                *"Generating optimized autoload files"*)
                    current_progress=62
                    update_progress $current_progress "⚡ Autoloader wird optimiert..." ;;
                *"* Creating database user pterodactyl..."*)
                    current_progress=65
                    update_progress $current_progress "👤 Datenbank-Benutzer wird erstellt..." ;;
                *"* Creating database pterodactyl..."*)
                    current_progress=68
                    update_progress $current_progress "🗄️  Panel-Datenbank wird angelegt..." ;;
                *"INFO  Running migrations."*)
                    current_progress=72
                    update_progress $current_progress "🔄 Datenbank-Migrationen werden ausgeführt..." ;;
                *"INFO  Seeding database."*)
                    current_progress=75
                    update_progress $current_progress "🌱 Datenbank wird mit Basisdaten befüllt..." ;;
                *"* Installing cronjob.."*)
                    current_progress=78
                    update_progress $current_progress "⏰ Cronjob für automatische Aufgaben wird eingerichtet..." ;;
                *"* Installing pteroq service.."*)
                    current_progress=82
                    update_progress $current_progress "🔧 Queue-Worker-Service wird installiert..." ;;
                *"* Configuring nginx.."*)
                    current_progress=85
                    update_progress $current_progress "🌐 Nginx-Konfiguration wird erstellt..." ;;
                *"Saving debug log to /var/log/letsencrypt/letsencrypt.log"*)
                    current_progress=88
                    update_progress $current_progress "🔐 SSL-Zertifikat wird von Let's Encrypt angefordert..." ;;
                *"Requesting a certificate for"*)
                    current_progress=91
                    update_progress $current_progress "🔐 Zertifikat-Validierung läuft..." ;;
                *"Congratulations! You have successfully enabled"*)
                    current_progress=94
                    update_progress $current_progress "✅ SSL-Zertifikat erfolgreich installiert..." ;;
                *"Es wurde kein Instanzort angegeben"*)
                    current_progress=96
                    update_progress $current_progress "🇩🇪 GermanDactyl wird installiert..." ;;
                *"Der Patch wurde angewendet."*)
                    current_progress=99
                    update_progress $current_progress "🎉 Installation wird abgeschlossen..." ;;
            esac
            if [ "$current_progress" -gt "$highest_progress" ]; then
                highest_progress=$current_progress
            fi
        done < <(tail -n 0 -f tmp.txt)
    } | whiptail --title "Pterodactyl Panel Installation" --gauge "Installation läuft..." 10 80 0
}


# Eigenständige Installation starten
clear
echo "Installation wird vorbereitet..."

# Lade die eigenständige Installationsfunktion
source <(curl -sSL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/claude/review-script-parts-011CUxB2vXFZC4SE3gdGGWt1/standalone-panel-installer.sh)

# Fallback: Lokale Datei verwenden, falls GitHub nicht erreichbar
if [ $? -ne 0 ] && [ -f "$(dirname "$0")/standalone-panel-installer.sh" ]; then
    source "$(dirname "$0")/standalone-panel-installer.sh"
fi

# Installationsfunktion aufrufen
install_pterodactyl_standalone "$panel_domain" "$admin_email" "$user_password" "$database_password"

# GermanDactyl nachinstallieren
echo "GermanDactyl wird installiert..."
cd /var/www/pterodactyl
curl -sSL https://install.germandactyl.de/ | sudo bash -s -- -v1.11.3 >> /tmp/germandactyl_install.log 2>&1

# Benutzer neu anlegen mit korrekten Daten
recreate_user


# Funktion, um die Zugangsdaten anzuzeigen
show_access_data() {
    whiptail --title "Deine Zugangsdaten" --msgbox "Speichere dir diese Zugangsdaten ab und ändere sie zeitnah, damit die Sicherheit deines Accounts gewährleistet ist.\n\nDeine Domain für das Panel: $panel_domain\n\n Benutzername: admin\n E-Mail-Adresse: $admin_email\n Passwort (32 Zeichen): $user_password \n\nDieses Fenster wird sich nicht noch einmal öffnen, speichere dir jetzt die Zugangsdaten ab." 22 80
}

# Info: Installation abgeschlossen
clear
whiptail --title "Installation erfolgreich" --msgbox "Das Pterodactyl Panel sollte nun verfügbar sein. Du kannst dich nun einloggen, die generierten Zugangsdaten werden im nächsten Fenster angezeigt, wenn du dieses schließt.\n\nHinweis: Pterodactyl ist noch nicht vollständig eingerichtet. Du musst noch Wings einrichten und eine Node anlegen, damit du Server aufsetzen kannst. Im Panel findest du das Erstellen einer Node hier: https://$panel_domain/admin/nodes/new. Damit du dort hinkommst, musst du aber vorher angemeldet sein." 22 80

# Hauptlogik für die Zugangsdaten und die Entscheidung zur Installation von Wings
while true; do
    show_access_data

    if whiptail --title "Noch ne Frage" --yesno "Hast du die Zugangsdaten gespeichert?" 10 60; then
        if whiptail --title "Zugang geht?" --yesno "Funktionieren die Zugangsdaten?" 10 60; then
            if whiptail --title "Bereit für den nächsten Schritt" --yesno "Alles ist bereit! Als nächstes musst du Wings installieren, um Server aufsetzen zu können. Möchtest du Wings jetzt installieren?" 10 60; then
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


# Code created by ChatGPT, zusammengesetzt und Idee der Struktur und Funktion mit einigen Vorgaben von Pavl21
