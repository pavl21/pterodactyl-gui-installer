#!/bin/bash

# Lade Whiptail-Farben
source "$(dirname "$0")/whiptail-colors.sh" 2>/dev/null || source /opt/pterodactyl/whiptail-colors.sh 2>/dev/null || true

# Eigenständiger Pterodactyl Wings Installer
# Komplett unabhängig von Drittanbieter-Scripts
# Mit Config-First Ansatz für standalone Installation

# Pfad, wo Wings installiert sein sollte
WINGS_PATH="/usr/local/bin/wings"
CONFIG_PATH="/etc/pterodactyl/config.yml"
LOG_FILE="/tmp/wings_install.log"

# Prüfen ob Panel installiert ist
PANEL_INSTALLED=false
if [ -d "/var/www/pterodactyl" ]; then
    PANEL_INSTALLED=true
fi

# Log-Datei initialisieren
> "$LOG_FILE"

# Logging-Funktion
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Überprüfen, ob Wings bereits auf dem System installiert ist
if [ -f "$WINGS_PATH" ]; then
    if whiptail_warning --title "WARNUNG: Wings bereits installiert" --yesno "Auf diesem System ist bereits Wings installiert.\n\nMöchtest du:\n- JA: Neuinstallation fortsetzen (überschreibt bestehende Installation)\n- NEIN: Status prüfen und ggf. Wings neu starten" 14 75; then
        # Benutzer möchte neu installieren - Warnung und Bestätigung
        if ! whiptail_warning --title "Neuinstallation bestätigen" --yesno "ACHTUNG: Die Neuinstallation wird die bestehende Wings-Installation überschreiben!\n\nBist du sicher, dass du fortfahren möchtest?" 12 70; then
            whiptail_info --title "Abgebrochen" --msgbox "Installation wurde abgebrochen." 8 50
            exit 0
        fi
        # Fortfahren mit Installation (Script läuft weiter)
    else
        # Status prüfen und Wings neu starten
        status_output=$(systemctl status wings 2>&1)
        if [[ $status_output == *"Failed to start Pterodactyl Wings Daemon."* ]]; then
            whiptail_error --title "Wings Fehler" --msgbox "Es gab einen Fehler beim Starten von Wings. Versuche, Wings neu zu starten. Bestätige, wenn der Neustart erfolgen soll." 10 60
            sudo systemctl restart wings
            status_output=$(systemctl status wings 2>&1)
            if [[ $status_output == *"Failed to start Pterodactyl Wings Daemon."* ]]; then
                whiptail_error --title "Wings Fehler" --msgbox "Wings konnte nicht gestartet werden, trotz Neustart. Überprüfe, ob eventuell Port-Konflikte vorhanden sind und versuche es erneut, dies kannst du mit dem Befehl 'sudo wings' nachprüfen." 10 80
            else
                whiptail_success --title "Wings Erfolgreich gestartet" --msgbox "Wings wurde erfolgreich gestartet. Die Server sollten in Kürze aktiv sein. Das Script wird nun beendet." 10 60
            fi
        elif [[ $status_output == *"inactive (dead)"* ]]; then
            sudo systemctl start wings
            status_output=$(systemctl status wings 2>&1)
            if [[ $status_output == *"Active: active (running)"* ]]; then
                whiptail_success --title "Wings Erfolgreich gestartet" --msgbox "Wings wurde erfolgreich gestartet. Die Server sollten in Kürze aktiv sein." 10 60
            fi
        else
            whiptail_success --title "Wings bereits installiert" --msgbox "Wings ist bereits auf diesem System installiert und läuft." 10 60
        fi
        exit 0
    fi
fi

# Funktionen zur Validierung
validate_domain() {
    local domain=$1
    if [[ $domain =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        local server_ip=$(hostname -I | awk '{print $1}')
        local dns_ip=$(dig +short $domain | head -n1)
        if [[ "$dns_ip" == "$server_ip" ]]; then
            title="Erfolg - Domain Überprüfung"
            message="Die IP-Adresse der Domain $domain stimmt mit der IP-Adresse des Servers überein. Die Installation wird fortgesetzt."
            whiptail --title "$title" --msgbox "$message" 10 60
            return 0
        else
            title="Fehler - Domain Überprüfung"
            message="Die IP-Adresse der Domain $domain stimmt nicht mit der IP-Adresse des Servers überein.\n\nDomain -> $domain\nServer IP -> $server_ip\nDNS IP -> $dns_ip"
            whiptail --title "$title" --msgbox "$message" 12 70
            return 1
        fi
    else
        title="Fehler - Domain Überprüfung"
        message="Die eingegebene Domain $domain ist keine gültige Domain-Struktur."
        whiptail --title "$title" --msgbox "$message" 10 60
        return 1
    fi
}

validate_email() {
    local email=$1
    if [[ $email =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        whiptail --title "E-Mail Überprüfung" --msgbox "Die eingegebene E-Mail-Adresse ist kein gültiges E-Mail-Format." 10 60
        return 1
    fi
}

# Fortschrittsanzeige-Funktion
show_progress() {
    local percentage=$1
    local message=$2
    echo "XXX"
    echo "$percentage"
    echo "$message"
    echo "XXX"
}

# Config-First Ansatz für Standalone Installation
prepare_config_for_standalone() {
    whiptail_info --title "Standalone Wings Installation" --msgbox "Du installierst Wings ohne Panel auf diesem Server.\n\nVor der Installation muss die Konfigurationsdatei vorbereitet werden.\n\nIm nächsten Schritt wird das Verzeichnis /etc/pterodactyl/ erstellt und eine leere config.yml Datei angelegt." 14 75

    # Erstelle Verzeichnis und leere config.yml
    mkdir -p /etc/pterodactyl
    touch "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"

    log "Config-Verzeichnis erstellt: /etc/pterodactyl/"
    log "Leere config.yml erstellt: $CONFIG_PATH"

    # Zeige Anleitung
    whiptail_info --title "WICHTIG: Config vorbereiten" --msgbox "BEVOR die Installation fortfährt, musst du folgendes tun:\n\n1. Gehe in dein Pterodactyl Panel (Admin-Bereich)\n2. Erstelle eine neue Node (Location -> Nodes -> Create New)\n3. Trage die Daten für diesen Server ein:\n     - FQDN: Die Domain, die du gleich angibst\n     - Memory & Disk: Ressourcen dieses Servers\n4. Nach dem Erstellen: Klicke auf 'Configuration'\n5. Kopiere den KOMPLETTEN Inhalt der config.yml\n6. Öffne eine ZWEITE SSH-Verbindung zu diesem Server\n7. Führe aus: nano /etc/pterodactyl/config.yml\n8. Füge den kopierten Inhalt ein (Rechtsklick -> Paste)\n9. Speichere mit STRG+O, Enter, dann STRG+X\n\nErst NACH diesem Schritt kannst du fortfahren!" 24 85

    # Warte auf Bestätigung in Schleife
    while true; do
        if whiptail --title "Config bereit?" --yesno "Hast du die config.yml aus dem Panel in /etc/pterodactyl/config.yml eingefügt?\n\nWenn ja, wird jetzt geprüft ob die Datei gültig ist." 12 70; then
            # Prüfe ob config.yml nicht leer ist
            if [ ! -s "$CONFIG_PATH" ]; then
                whiptail_error --title "Config ist leer" --msgbox "Die Datei /etc/pterodactyl/config.yml ist leer oder existiert nicht.\n\nBitte füge die Konfiguration aus dem Panel ein und versuche es erneut." 10 70
                continue
            fi

            # Prüfe ob config.yml valides YAML mit benötigten Feldern enthält
            if ! grep -q "token_id:" "$CONFIG_PATH" || ! grep -q "token:" "$CONFIG_PATH" || ! grep -q "api:" "$CONFIG_PATH"; then
                whiptail_error --title "Config ungültig" --msgbox "Die config.yml scheint nicht vollständig zu sein.\n\nStelle sicher, dass du den KOMPLETTEN Inhalt aus dem Panel kopiert hast.\n\nBenötigte Felder: token_id, token, api" 12 70
                continue
            fi

            whiptail_success --title "Config validiert" --msgbox "Die config.yml wurde erfolgreich validiert!\n\nDie Installation wird jetzt fortgesetzt." 10 60
            log "Config validiert und bereit"
            break
        else
            if whiptail --title "Installation abbrechen?" --yesno "Möchtest du die Installation abbrechen?\n\nWenn Nein, kehren wir zur Config-Anleitung zurück." 10 60; then
                whiptail_info --title "Installation abgebrochen" --msgbox "Die Wings-Installation wurde abgebrochen.\n\nDu kannst sie später über die Wartung erneut starten." 10 60
                exit 0
            fi
        fi
    done
}

# Eigenständige Docker-Installation
install_docker_standalone() {
    log "Starte Docker-Installation"

    exec 3>&1
    {
        show_progress 5 "Docker-Repository wird hinzugefügt..."

        # Alte Docker-Versionen entfernen
        apt-get remove -y docker docker-engine docker.io containerd runc >> "$LOG_FILE" 2>&1

        # Docker GPG Key hinzufügen
        install -m 0755 -d /etc/apt/keyrings
        if ! curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg -o /etc/apt/keyrings/docker.asc >> "$LOG_FILE" 2>&1; then
            log "FEHLER: Docker GPG Key konnte nicht heruntergeladen werden"
            return 1
        fi
        chmod a+r /etc/apt/keyrings/docker.asc

        show_progress 10 "Docker-Repository wird konfiguriert..."

        # Repository hinzufügen
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

        show_progress 15 "Paketquellen werden aktualisiert..."
        apt-get update >> "$LOG_FILE" 2>&1

        show_progress 20 "Docker wird installiert..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1

        show_progress 30 "Docker wird konfiguriert..."
        systemctl enable docker >> "$LOG_FILE" 2>&1
        systemctl start docker >> "$LOG_FILE" 2>&1

        log "Docker erfolgreich installiert"

    } | whiptail --title "Docker Installation" --gauge "Docker wird installiert..." 8 70 0 3>&1
}

# Eigenständige Wings-Installation
install_wings_standalone() {
    local DOMAIN=$1
    local admin_email=$2

    log "Starte Wings-Installation für Domain: $DOMAIN"

    exec 3>&1
    {
        show_progress 35 "Wings Binary wird heruntergeladen..."

        # Neueste Wings-Version ermitteln
        if ! WINGS_VERSION=$(curl -s https://api.github.com/repos/pterodactyl/wings/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'); then
            log "WARNUNG: Konnte Wings-Version nicht von GitHub abrufen"
            WINGS_VERSION="latest"
        fi
        log "Wings Version: $WINGS_VERSION"

        # Wings herunterladen
        if ! curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64" >> "$LOG_FILE" 2>&1; then
            log "FEHLER: Wings Binary konnte nicht heruntergeladen werden"
            show_progress 37 "FEHLER: Wings-Download fehlgeschlagen"
            return 1
        fi
        chmod u+x /usr/local/bin/wings

        show_progress 45 "Wings Systemd Service wird erstellt..."

        # Systemd Service erstellen
        cat > /etc/systemd/system/wings.service << 'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

        log "Wings Systemd Service erstellt"

        show_progress 50 "Certbot wird installiert..."

        # Certbot installieren
        apt-get install -y certbot >> "$LOG_FILE" 2>&1

        show_progress 60 "SSL-Zertifikat wird erstellt..."

        # Stoppe Docker temporär für certbot
        systemctl stop docker >> "$LOG_FILE" 2>&1

        # SSL-Zertifikat erstellen
        certbot certonly --standalone -d "${DOMAIN}" --email "${admin_email}" --agree-tos --non-interactive --preferred-challenges http >> "$LOG_FILE" 2>&1
        CERT_RESULT=$?

        if [ $CERT_RESULT -ne 0 ]; then
            log "WARNUNG: SSL-Zertifikat konnte nicht erstellt werden"
            show_progress 65 "SSL-Zertifikat fehlgeschlagen, fahre ohne SSL fort..."
        else
            log "SSL-Zertifikat erfolgreich erstellt"
            show_progress 70 "SSL-Zertifikat erfolgreich erstellt"
        fi

        # Docker wieder starten
        systemctl start docker >> "$LOG_FILE" 2>&1

        show_progress 75 "Wings wird konfiguriert..."

        # Wings Service aktivieren
        systemctl enable wings >> "$LOG_FILE" 2>&1

        show_progress 80 "Automatische SSL-Erneuerung wird eingerichtet..."

        # Crontab für automatische SSL-Zertifikat-Erneuerung (alle 4 Tage, 3 Uhr nachts)
        CRON_CMD="0 3 */4 * * systemctl stop wings && systemctl stop docker && certbot renew --quiet && systemctl start docker && systemctl start wings"
        (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_CMD") | crontab -
        log "SSL Auto-Renewal Cronjob eingerichtet"

        show_progress 90 "Wings wird gestartet..."

        # Wings starten
        systemctl start wings >> "$LOG_FILE" 2>&1

        sleep 2

        show_progress 95 "Installation wird abgeschlossen..."

        log "Wings Installation abgeschlossen"

        show_progress 100 "Wings erfolgreich installiert!"
        sleep 1

    } | whiptail --title "Wings Installation" --gauge "Wings wird installiert..." 8 70 0 3>&1
}

# Integrationshilfe für Wings (wenn Panel vorhanden)
integrate_wings() {
    local DOMAIN="$1"

    log "Starte Wings-Integration mit Panel"

    # Starte die Integration
    systemctl enable wings
    systemctl stop wings
    cd /var/www/pterodactyl
    php artisan p:location:make --short=DE --long="Hauptnetz" >> "$LOG_FILE" 2>&1

    # Zeige Infotext und frage, ob der Node erstellt wurde
    while true; do
        if whiptail --title "Wings Integration" --yesno "Erstelle jetzt im Panel mit der Domain für Wings ($DOMAIN) eine Node mit den Vorgaben des Servers. Bist du soweit? Dann fahren wir fort." 10 60; then
            # Infotext zur Wings-Integration
            whiptail --title "Manuelle Handlung notwendig" --msgbox "Öffne eine neue SSH-Verbindung und bearbeite die config.yml in /etc/pterodactyl/ (Mit dem Befehl 'nano /etc/pterodactyl/config.yml'). Im Panel unter der erstellten Node findest du den Punkt 'Configuration'. Dort findest du eine config.yml, die dort in dem genannten Pfad eingebunden werden muss. Wenn du das getan hast, bestätige das. Es wird dann überprüft, ob du alles richtig gemacht hast." 15 100

            # Prüfe, ob die Integration abgeschlossen ist
            if whiptail --title "Wings Integration" --yesno "Hast du die Wings-Integration abgeschlossen?" 10 60; then
                if [ -f /etc/pterodactyl/config.yml ] && [ -s /etc/pterodactyl/config.yml ]; then
                    systemctl start wings
                    sleep 2
                    if whiptail --title "Wings Status prüfen" --yesno "Wings wurde nun gestartet. Überprüfe jetzt bitte, ob die Node aktiv ist. Das siehst du an einem grünen Herz, das schlägt." 10 60; then
                        whiptail_success --title "Pterodactyl ist nun eingerichtet" --msgbox "Die Installation ist nun abgeschlossen, du kannst nun Server für dich (und andere) anlegen. Bevor du das aber tust, musst du noch einige Ports freigeben. Das kannst du unter der Node im Panel unter dem Reiter 'Allocations' machen. Dort trägst du dann rechts oben die IP Adresse des Servers ein, in der Mitte einen Alias (zum Beispiel die Domain, unter der dein Server auch erreichbar ist. Das ist kein Pflichtfeld, kannst du auch frei lassen) und darunter die Ports, die du nutzen möchtest. Mit einem Komma kannst du mehrere eingeben. Viel Spaß mit deinem Panel und empfehle GermanDactyl gerne weiter, wenn wir dir weiterhelfen konnten :)." 18 100
                        swap_question
                        return 0
                    else
                        whiptail_error --title "Node nicht aktiv" --msgbox "Die Node scheint nicht aktiv zu sein. Überprüfe folgendes:\n\n1. Ist die config.yml korrekt?\n2. Läuft Wings? (systemctl status wings)\n3. Sind Ports freigegeben?\n4. Firewall-Regeln korrekt?" 14 70
                        break
                    fi
                else
                    whiptail_error --title "Wings Integration" --msgbox "Die Datei /etc/pterodactyl/config.yml existiert nicht oder ist leer. Hast du es eventuell falsch abgelegt oder vergessen zu speichern?" 10 70
                fi
            else
                continue
            fi
        else
            whiptail --title "Wings Integration" --msgbox "Erstelle bitte erst eine neue Node im Pterodactyl Panel. Gebe dort die Daten an, die benötigt werden. Bei den Ressourcen kannst du die Gigabyte-Zahl mit 1024 multiplizieren (16*1024). Wenn du soweit bist, dann können wir weitermachen." 10 70
        fi
    done
}

# HDD Backup-Speicher konfigurieren (ALPHA FEATURE)
configure_hdd_backup_storage() {
    log "Checking for additional hard drives for backup storage"

    # Systemfestplatte ermitteln (wo / gemountet ist)
    SYSTEM_DISK=$(lsblk --noheadings --raw -o NAME,MOUNTPOINT,TYPE | grep "/$" | awk '{print $1}' | sed 's/[0-9]*$//')

    # Alle Festplatten auflisten (TYPE=disk), die nicht gemountet sind und nicht die Systemfestplatte sind
    mapfile -t AVAILABLE_DISKS < <(lsblk --noheadings --raw -o NAME,SIZE,TYPE,MOUNTPOINT | \
        awk -v sys="$SYSTEM_DISK" '$3=="disk" && $4=="" && $1!=sys {print $1 " (" $2 ")"}')

    # Wenn keine zusätzlichen Festplatten gefunden wurden
    if [ ${#AVAILABLE_DISKS[@]} -eq 0 ]; then
        log "No additional unmounted hard drives found"
        return 0
    fi

    log "Found ${#AVAILABLE_DISKS[@]} unmounted disk(s)"

    # Benutzer fragen ob HDD für Backups verwendet werden soll
    if ! whiptail_warning --title "ALPHA: HDD für Backups erkannt" --yesno "Es wurde(n) ${#AVAILABLE_DISKS[@]} zusätzliche Festplatte(n) gefunden!\n\nMöchtest du eine davon für Server-Backups verwenden?\n\nVorteile:\n• Schneller Speicher (SSD) bleibt für Server frei\n• Backups auf separater Festplatte\n• Bessere Datensicherheit\n\nWARNUNG: Dies ist ein ALPHA-Feature!\nDie gewählte Festplatte wird formatiert und alle Daten gehen verloren!" 20 75; then
        log "User declined HDD backup storage"
        return 0
    fi

    # Wenn nur eine Festplatte: direkt verwenden
    # Wenn mehrere: Auswahlmenü anzeigen
    local SELECTED_DISK
    if [ ${#AVAILABLE_DISKS[@]} -eq 1 ]; then
        SELECTED_DISK=$(echo "${AVAILABLE_DISKS[0]}" | awk '{print $1}')
    else
        # Menü-Array erstellen
        local menu_options=()
        for i in "${!AVAILABLE_DISKS[@]}"; do
            DISK_NAME=$(echo "${AVAILABLE_DISKS[$i]}" | awk '{print $1}')
            DISK_SIZE=$(echo "${AVAILABLE_DISKS[$i]}" | grep -oP '\(.*?\)')
            menu_options+=("$DISK_NAME" "$DISK_SIZE")
        done

        SELECTED_DISK=$(whiptail --title "Festplatte auswählen" --menu "Wähle die Festplatte für Backups:" 18 60 10 "${menu_options[@]}" 3>&1 1>&2 2>&3)

        if [ -z "$SELECTED_DISK" ]; then
            log "User cancelled disk selection"
            return 0
        fi
    fi

    log "User selected disk: $SELECTED_DISK"

    # Finale Bestätigung
    DISK_INFO=$(lsblk "/dev/$SELECTED_DISK" --noheadings -o NAME,SIZE,MODEL 2>/dev/null | head -n 1)
    if ! whiptail_warning --title "WARNUNG: Festplatte formatieren" --yesno "ACHTUNG: Die Festplatte wird jetzt formatiert!\n\nFestplatte: /dev/$SELECTED_DISK\nInfo: $DISK_INFO\n\nALLE DATEN AUF DIESER FESTPLATTE GEHEN VERLOREN!\n\nFortfahren?" 16 70; then
        log "User cancelled HDD formatting"
        return 0
    fi

    # Festplatte vorbereiten
    {
        echo 10
        echo "XXX"
        echo "Erstelle Partitionstabelle..."
        echo "XXX"
        # Partition erstellen
        echo -e "o\nn\np\n1\n\n\nw" | fdisk "/dev/$SELECTED_DISK" >> "$LOG_FILE" 2>&1
        sleep 2

        echo 30
        echo "XXX"
        echo "Formatiere Festplatte (ext4)..."
        echo "XXX"
        # Formatieren mit ext4
        mkfs.ext4 -F "/dev/${SELECTED_DISK}1" >> "$LOG_FILE" 2>&1
        sleep 1

        echo 50
        echo "XXX"
        echo "Erstelle Mount-Point..."
        echo "XXX"
        # Mount-Point erstellen
        mkdir -p /mnt/storage

        echo 60
        echo "XXX"
        echo "Mounte Festplatte..."
        echo "XXX"
        # Temporär mounten
        mount "/dev/${SELECTED_DISK}1" /mnt/storage >> "$LOG_FILE" 2>&1

        echo 70
        echo "XXX"
        echo "Konfiguriere automatisches Mounten (fstab)..."
        echo "XXX"
        # UUID ermitteln
        DISK_UUID=$(blkid -s UUID -o value "/dev/${SELECTED_DISK}1")

        # fstab Backup
        cp /etc/fstab /etc/fstab.backup-$(date +%Y%m%d-%H%M%S)

        # Zu fstab hinzufügen (wenn noch nicht vorhanden)
        if ! grep -q "$DISK_UUID" /etc/fstab 2>/dev/null; then
            echo "UUID=$DISK_UUID /mnt/storage ext4 defaults,nofail 0 2" >> /etc/fstab
        fi

        echo 80
        echo "XXX"
        echo "Aktualisiere Wings Konfiguration..."
        echo "XXX"
        # Wings config.yml updaten
        if [ -f "$CONFIG_PATH" ]; then
            # Backup der config
            cp "$CONFIG_PATH" "${CONFIG_PATH}.backup-$(date +%Y%m%d-%H%M%S)"

            # Backup-Verzeichnis in config.yml aktualisieren
            # Suche nach "backup_directory:" und ersetze den Wert
            if grep -q "backup_directory:" "$CONFIG_PATH"; then
                sed -i 's|backup_directory:.*|backup_directory: /mnt/storage/backups|g' "$CONFIG_PATH"
            else
                # Falls nicht vorhanden, hinzufügen (nach system: Sektion)
                sed -i '/^system:/a\  backup_directory: /mnt/storage/backups' "$CONFIG_PATH"
            fi
        fi

        echo 90
        echo "XXX"
        echo "Setze Berechtigungen..."
        echo "XXX"
        # Backup-Verzeichnis erstellen und Berechtigungen setzen
        mkdir -p /mnt/storage/backups
        chown -R www-data:www-data /mnt/storage
        chmod -R 755 /mnt/storage

        echo 100
        echo "XXX"
        echo "Fertig!"
        echo "XXX"
        sleep 1
    } | whiptail --title "HDD Backup-Speicher einrichten" --gauge "Festplatte wird konfiguriert..." 8 70 0

    # Wings neu starten um neue Config zu laden
    systemctl restart wings >> "$LOG_FILE" 2>&1

    # Erfolgsmeldung
    whiptail_success --title "HDD Backup-Speicher konfiguriert" --msgbox "Die Festplatte wurde erfolgreich konfiguriert!\n\nMount-Point: /mnt/storage\nBackup-Verzeichnis: /mnt/storage/backups\n\nWings wurde neu gestartet und verwendet jetzt den neuen Backup-Speicher.\n\nDie Konfiguration wird auch nach Neustarts automatisch geladen (fstab)." 16 75

    log "HDD backup storage configured successfully: /dev/$SELECTED_DISK mounted at /mnt/storage"
}

# SWAP-Speicher zuweisen
swap_question() {
    if whiptail --title "Swap-Speicher für Wings" --yesno "Möchtest du SWAP-Speicher für Wings einbinden?\n\nSWAP ist virtueller Arbeitsspeicher auf der Festplatte und kann hilfreich sein, wenn der RAM knapp wird." 12 70; then
        size=$(whiptail --title "Swap-Speicher erstellen" --inputbox "Gebe die gewünschte Swap-Größe in MB ein (z.B. 2048 für 2GB):" 10 60 3>&1 1>&2 2>&3)
        exitstatus=$?
        if [ $exitstatus -eq 0 ]; then
            if [[ $size =~ ^[0-9]+$ ]]; then
                {
                    show_progress 20 "Swap-Datei wird erstellt..."
                    fallocate -l ${size}M /swapfile >> "$LOG_FILE" 2>&1

                    show_progress 40 "Berechtigungen werden gesetzt..."
                    chmod 600 /swapfile

                    show_progress 60 "Swap wird konfiguriert..."
                    mkswap /swapfile >> "$LOG_FILE" 2>&1

                    show_progress 80 "Swap wird aktiviert..."
                    swapon /swapfile

                    show_progress 100 "Swap erfolgreich erstellt!"
                    sleep 1
                } | whiptail --title "Swap-Erstellung" --gauge "SWAP-Speicher wird erstellt..." 8 70 0

                whiptail_success --title "Swap-Speicher erstellt" --msgbox "Swap-Speicher wurde erfolgreich erstellt und aktiviert (${size}MB).\n\nDas Script wird nun beendet." 10 60
                exit 0
            else
                whiptail_error --title "Ungültige Eingabe" --msgbox "Ungültige Eingabe. Bitte gebe eine Zahl ein." 10 60
                swap_question
            fi
        else
            whiptail_info --title "Wings installiert" --msgbox "Wings wurde ohne SWAP-Speicher installiert. Du kannst es im Nachhinein über die Verwaltung nachinstallieren.\n\nDas Script wird nun beendet." 10 70
            exit 0
        fi
    else
        whiptail_success --title "Installation abgeschlossen" --msgbox "Wings wurde erfolgreich installiert!\n\nDas Script wird nun beendet." 10 60
        exit 0
    fi
}

# Hauptinstallationsschleife
main() {
    # Bei Standalone-Installation: Config zuerst vorbereiten
    if [ "$PANEL_INSTALLED" = false ]; then
        prepare_config_for_standalone
    fi

    # Domain und Email abfragen mit verbesserter Validierung
    while true; do
        DOMAIN=$(whiptail --title "Domain-Eingabe für Wings" --inputbox "Bitte gib die Domain für Wings ein, die du nutzen möchtest. Diese muss als DNS-Eintrag bei deiner Domain verfügbar sein.\n\nBeispiel: wings.meinedomain.de" 12 70 3>&1 1>&2 2>&3)

        # Prüfe ob Eingabe abgebrochen wurde
        if [ $? -ne 0 ]; then
            whiptail_info --title "Installation abgebrochen" --msgbox "Installation wurde abgebrochen." 10 60
            exit 0
        fi

        # Prüfe ob Domain leer ist
        if [ -z "$DOMAIN" ]; then
            whiptail_warning --title "Domain erforderlich" --msgbox "Du musst eine Domain eingeben.\n\nDie Installation erfordert eine gültige Domain für SSL-Zertifikate." 10 70
            continue
        fi

        # Validiere Domain-Format
        if ! validate_domain "$DOMAIN"; then
            continue
        fi
        break
    done

    # Email abfragen mit verbesserter Validierung
    while true; do
        # Prüfen, ob Email bereits aus Panel-Installation vorhanden ist
        if [ -n "$PANEL_EMAIL" ]; then
            admin_email="$PANEL_EMAIL"
            whiptail_info --title "E-Mail automatisch übernommen" --msgbox "Die E-Mail-Adresse wurde automatisch aus der Panel-Installation übernommen:\n\n$admin_email\n\nDiese wird für das SSL-Zertifikat von Wings verwendet." 12 70
            break
        else
            admin_email=$(whiptail --title "E-Mail für Let's Encrypt" --inputbox "Gib die E-Mail Adresse ein, die informiert werden soll, wenn das SSL Zertifikat ausläuft. Diese Zertifikate halten 90 Tage, kurz vor Ablauf wird man informiert.\n\nDie automatische Erneuerung ist bereits eingerichtet (alle 4 Tage)." 15 80 3>&1 1>&2 2>&3)

            # Prüfe ob Eingabe abgebrochen wurde
            if [ $? -ne 0 ]; then
                whiptail_info --title "Installation abgebrochen" --msgbox "Installation wurde abgebrochen." 10 60
                exit 0
            fi

            # Prüfe ob Email leer ist
            if [ -z "$admin_email" ]; then
                whiptail_warning --title "E-Mail erforderlich" --msgbox "Du musst eine gültige E-Mail-Adresse eingeben.\n\nDiese wird für das SSL-Zertifikat benötigt." 10 70
                continue
            fi

            # Validiere Email-Format
            if ! validate_email "$admin_email"; then
                whiptail_error --title "Ungültige E-Mail" --msgbox "Die eingegebene E-Mail-Adresse ist ungültig.\n\nBitte gib eine gültige E-Mail-Adresse ein." 10 70
                continue
            fi
            break
        fi
    done

    # Docker installieren
    if ! command -v docker &> /dev/null; then
        install_docker_standalone
    else
        log "Docker bereits installiert, überspringe Installation"
    fi

    # Wings installieren
    install_wings_standalone "$DOMAIN" "$admin_email"

    # Bei Panel-Installation: Integration durchführen
    if [ "$PANEL_INSTALLED" = true ]; then
        whiptail_info --title "Wings Integration" --msgbox "Wings wurde erfolgreich installiert!\n\nJetzt muss Wings noch in das Panel als Node integriert werden. Damit fahren wir als nächstes fort." 10 70
        integrate_wings "$DOMAIN"
    else
        # Standalone: Erfolgsmeldung und Hinweis auf Panel
        whiptail_success --title "Wings installiert" --msgbox "Wings wurde erfolgreich installiert!\n\nDa du Wings standalone installiert hast, sollte die Node im Panel jetzt als AKTIV angezeigt werden (grünes schlagendes Herz).\n\nFalls nicht, überprüfe:\n• Ist die config.yml korrekt?\n• Läuft Wings? (systemctl status wings)\n• Sind die Firewall-Ports offen?" 16 75

        # HDD Backup-Speicher konfigurieren (falls zusätzliche Festplatten vorhanden)
        configure_hdd_backup_storage

        swap_question
    fi

    # Spenden-Info
    whiptail_info --title "Projekt unterstützen" --msgbox "Wenn dir dieses Projekt weitergeholfen hat und du es unterstützen möchtest, würde ich mich über eine Spende freuen!\n\nSpenden-Link:\nhttps://spenden.24fire.de/pavl\n\nVielen Dank für deine Unterstützung!\n\n- GermanDactyl Setup Team" 16 78
}

# Starte Hauptinstallation
main

# Code created with assistance, implemented and structured by Pavl21
