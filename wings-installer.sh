#!/bin/bash

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
    if whiptail --title "🚀 Wings bereits installiert" --yesno "Auf diesem System ist bereits Wings installiert. Wenn du versuchst Wings zu starten, falls es nicht reagiert, können wir das hier versuchen. Soll der Status ermittelt werden?" 10 60; then
        status_output=$(systemctl status wings 2>&1)
        if [[ $status_output == *"Failed to start Pterodactyl Wings Daemon."* ]]; then
            whiptail --title "🔴 Wings Fehler" --msgbox "Es gab einen Fehler beim Starten von Wings. Versuche, Wings neu zu starten. Bestätige, wenn der Neustart erfolgen soll." 10 60
            sudo systemctl restart wings
            status_output=$(systemctl status wings 2>&1)
            if [[ $status_output == *"Failed to start Pterodactyl Wings Daemon."* ]]; then
                whiptail --title "🔴 Wings Fehler" --msgbox "Wings konnte nicht gestartet werden, trotz Neustart. Überprüfe, ob eventuell Port-Konflikte vorhanden sind und versuche es erneut, dies kannst du mit dem Befehl 'sudo wings' nachprüfen." 10 80
            else
                whiptail --title "🟢 Wings Erfolgreich gestartet" --msgbox "Wings wurde erfolgreich gestartet. Die Server sollten in Kürze aktiv sein. Das Script wird nun beendet." 10 60
            fi
        elif [[ $status_output == *"inactive (dead)"* ]]; then
            sudo systemctl start wings
            status_output=$(systemctl status wings 2>&1)
            if [[ $status_output == *"Active: active (running)"* ]]; then
                whiptail --title "🟢 Wings Erfolgreich gestartet" --msgbox "Wings wurde erfolgreich gestartet. Die Server sollten in Kürze aktiv sein." 10 60
            fi
        else
            whiptail --title "🚀 Wings bereits installiert" --msgbox "Wings ist bereits auf diesem System installiert und läuft." 10 60
            exit 0
        fi
    else
        whiptail --title "🚫 Wings Installation abgebrochen" --msgbox "Die Installation von Wings wurde abgebrochen." 10 60
        exit 0
    fi
    exit 0
fi

# Funktionen zur Validierung
validate_domain() {
    local domain=$1
    if [[ $domain =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        local server_ip=$(hostname -I | awk '{print $1}')
        local dns_ip=$(dig +short $domain | head -n1)
        if [[ "$dns_ip" == "$server_ip" ]]; then
            title="✅ Erfolg - Domain Überprüfung"
            message="Die IP-Adresse der Domain $domain stimmt mit der IP-Adresse des Servers überein. Die Installation wird fortgesetzt."
            whiptail --title "$title" --msgbox "$message" 10 60
            return 0
        else
            title="❌ Fehler - Domain Überprüfung"
            message="Die IP-Adresse der Domain $domain stimmt nicht mit der IP-Adresse des Servers überein.\n\nDomain -> $domain\nServer IP -> $server_ip\nDNS IP -> $dns_ip"
            whiptail --title "$title" --msgbox "$message" 12 70
            return 1
        fi
    else
        title="❌ Fehler - Domain Überprüfung"
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
    whiptail --title "📋 Standalone Wings Installation" --msgbox "Du installierst Wings ohne Panel auf diesem Server.\n\nVor der Installation muss die Konfigurationsdatei vorbereitet werden.\n\nIm nächsten Schritt wird das Verzeichnis /etc/pterodactyl/ erstellt und eine leere config.yml Datei angelegt." 14 75

    # Erstelle Verzeichnis und leere config.yml
    mkdir -p /etc/pterodactyl
    touch "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"

    log "Config-Verzeichnis erstellt: /etc/pterodactyl/"
    log "Leere config.yml erstellt: $CONFIG_PATH"

    # Zeige Anleitung
    whiptail --title "⚠️  WICHTIG: Config vorbereiten" --msgbox "BEVOR die Installation fortfährt, musst du folgendes tun:\n\n1️⃣  Gehe in dein Pterodactyl Panel (Admin-Bereich)\n2️⃣  Erstelle eine neue Node (Location -> Nodes -> Create New)\n3️⃣  Trage die Daten für diesen Server ein:\n     - FQDN: Die Domain, die du gleich angibst\n     - Memory & Disk: Ressourcen dieses Servers\n4️⃣  Nach dem Erstellen: Klicke auf 'Configuration'\n5️⃣  Kopiere den KOMPLETTEN Inhalt der config.yml\n6️⃣  Öffne eine ZWEITE SSH-Verbindung zu diesem Server\n7️⃣  Führe aus: nano /etc/pterodactyl/config.yml\n8️⃣  Füge den kopierten Inhalt ein (Rechtsklick -> Paste)\n9️⃣  Speichere mit STRG+O, Enter, dann STRG+X\n\n⚠️  Erst NACH diesem Schritt kannst du fortfahren!" 24 85

    # Warte auf Bestätigung in Schleife
    while true; do
        if whiptail --title "Config bereit?" --yesno "Hast du die config.yml aus dem Panel in /etc/pterodactyl/config.yml eingefügt?\n\nWenn ja, wird jetzt geprüft ob die Datei gültig ist." 12 70; then
            # Prüfe ob config.yml nicht leer ist
            if [ ! -s "$CONFIG_PATH" ]; then
                whiptail --title "❌ Config ist leer" --msgbox "Die Datei /etc/pterodactyl/config.yml ist leer oder existiert nicht.\n\nBitte füge die Konfiguration aus dem Panel ein und versuche es erneut." 10 70
                continue
            fi

            # Prüfe ob config.yml valides YAML mit benötigten Feldern enthält
            if ! grep -q "token_id:" "$CONFIG_PATH" || ! grep -q "token:" "$CONFIG_PATH" || ! grep -q "api:" "$CONFIG_PATH"; then
                whiptail --title "❌ Config ungültig" --msgbox "Die config.yml scheint nicht vollständig zu sein.\n\nStelle sicher, dass du den KOMPLETTEN Inhalt aus dem Panel kopiert hast.\n\nBenötigte Felder: token_id, token, api" 12 70
                continue
            fi

            whiptail --title "✅ Config validiert" --msgbox "Die config.yml wurde erfolgreich validiert!\n\nDie Installation wird jetzt fortgesetzt." 10 60
            log "Config validiert und bereit"
            break
        else
            if whiptail --title "Installation abbrechen?" --yesno "Möchtest du die Installation abbrechen?\n\nWenn Nein, kehren wir zur Config-Anleitung zurück." 10 60; then
                whiptail --title "🚫 Installation abgebrochen" --msgbox "Die Wings-Installation wurde abgebrochen.\n\nDu kannst sie später über die Wartung erneut starten." 10 60
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
        show_progress 5 "🐳 Docker-Repository wird hinzugefügt..."

        # Alte Docker-Versionen entfernen
        apt-get remove -y docker docker-engine docker.io containerd runc >> "$LOG_FILE" 2>&1

        # Docker GPG Key hinzufügen
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg -o /etc/apt/keyrings/docker.asc >> "$LOG_FILE" 2>&1
        chmod a+r /etc/apt/keyrings/docker.asc

        show_progress 10 "🐳 Docker-Repository wird konfiguriert..."

        # Repository hinzufügen
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

        show_progress 15 "📦 Paketquellen werden aktualisiert..."
        apt-get update >> "$LOG_FILE" 2>&1

        show_progress 20 "🐳 Docker wird installiert..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1

        show_progress 30 "🐳 Docker wird konfiguriert..."
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
        show_progress 35 "🚀 Wings Binary wird heruntergeladen..."

        # Neueste Wings-Version ermitteln
        WINGS_VERSION=$(curl -s https://api.github.com/repos/pterodactyl/wings/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        log "Wings Version: $WINGS_VERSION"

        # Wings herunterladen
        curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64" >> "$LOG_FILE" 2>&1
        chmod u+x /usr/local/bin/wings

        show_progress 45 "🔧 Wings Systemd Service wird erstellt..."

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

        show_progress 50 "📦 Certbot wird installiert..."

        # Certbot installieren
        apt-get install -y certbot >> "$LOG_FILE" 2>&1

        show_progress 60 "🔒 SSL-Zertifikat wird erstellt..."

        # Stoppe Docker temporär für certbot
        systemctl stop docker >> "$LOG_FILE" 2>&1

        # SSL-Zertifikat erstellen
        certbot certonly --standalone -d "${DOMAIN}" --email "${admin_email}" --agree-tos --non-interactive --preferred-challenges http >> "$LOG_FILE" 2>&1
        CERT_RESULT=$?

        if [ $CERT_RESULT -ne 0 ]; then
            log "WARNUNG: SSL-Zertifikat konnte nicht erstellt werden"
            show_progress 65 "⚠️  SSL-Zertifikat fehlgeschlagen, fahre ohne SSL fort..."
        else
            log "SSL-Zertifikat erfolgreich erstellt"
            show_progress 70 "✅ SSL-Zertifikat erfolgreich erstellt"
        fi

        # Docker wieder starten
        systemctl start docker >> "$LOG_FILE" 2>&1

        show_progress 75 "🔧 Wings wird konfiguriert..."

        # Wings Service aktivieren
        systemctl enable wings >> "$LOG_FILE" 2>&1

        show_progress 80 "⏰ Automatische SSL-Erneuerung wird eingerichtet..."

        # Crontab für automatische SSL-Zertifikat-Erneuerung (alle 4 Tage, 3 Uhr nachts)
        CRON_CMD="0 3 */4 * * systemctl stop wings && systemctl stop docker && certbot renew --quiet && systemctl start docker && systemctl start wings"
        (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_CMD") | crontab -
        log "SSL Auto-Renewal Cronjob eingerichtet"

        show_progress 90 "🚀 Wings wird gestartet..."

        # Wings starten
        systemctl start wings >> "$LOG_FILE" 2>&1

        sleep 2

        show_progress 95 "✅ Installation wird abgeschlossen..."

        log "Wings Installation abgeschlossen"

        show_progress 100 "✅ Wings erfolgreich installiert!"
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
                        whiptail --title "🟢 Pterodactyl ist nun eingerichtet" --msgbox "Die Installation ist nun abgeschlossen, du kannst nun Server für dich (und andere) anlegen. Bevor du das aber tust, musst du noch einige Ports freigeben. Das kannst du unter der Node im Panel unter dem Reiter 'Allocations' machen. Dort trägst du dann rechts oben die IP Adresse des Servers ein, in der Mitte einen Alias (zum Beispiel die Domain, unter der dein Server auch erreichbar ist. Das ist kein Pflichtfeld, kannst du auch frei lassen) und darunter die Ports, die du nutzen möchtest. Mit einem Komma kannst du mehrere eingeben. Viel Spaß mit deinem Panel und empfehle GermanDactyl gerne weiter, wenn wir dir weiterhelfen konnten :)." 18 100
                        swap_question
                        return 0
                    else
                        whiptail --title "⚠️  Node nicht aktiv" --msgbox "Die Node scheint nicht aktiv zu sein. Überprüfe folgendes:\n\n1. Ist die config.yml korrekt?\n2. Läuft Wings? (systemctl status wings)\n3. Sind Ports freigegeben?\n4. Firewall-Regeln korrekt?" 14 70
                        break
                    fi
                else
                    whiptail --title "Wings Integration" --msgbox "Die Datei /etc/pterodactyl/config.yml existiert nicht oder ist leer. Hast du es eventuell falsch abgelegt oder vergessen zu speichern?" 10 70
                fi
            else
                continue
            fi
        else
            whiptail --title "Wings Integration" --msgbox "Erstelle bitte erst eine neue Node im Pterodactyl Panel. Gebe dort die Daten an, die benötigt werden. Bei den Ressourcen kannst du die Gigabyte-Zahl mit 1024 multiplizieren (16*1024). Wenn du soweit bist, dann können wir weitermachen." 10 70
        fi
    done
}

# SWAP-Speicher zuweisen
swap_question() {
    if whiptail --title "Swap-Speicher für Wings" --yesno "Möchtest du SWAP-Speicher für Wings einbinden?\n\nSWAP ist virtueller Arbeitsspeicher auf der Festplatte und kann hilfreich sein, wenn der RAM knapp wird." 12 70; then
        size=$(whiptail --title "Swap-Speicher erstellen" --inputbox "Gebe die gewünschte Swap-Größe in MB ein (z.B. 2048 für 2GB):" 10 60 3>&1 1>&2 2>&3)
        exitstatus=$?
        if [ $exitstatus -eq 0 ]; then
            if [[ $size =~ ^[0-9]+$ ]]; then
                {
                    show_progress 20 "💾 Swap-Datei wird erstellt..."
                    fallocate -l ${size}M /swapfile >> "$LOG_FILE" 2>&1

                    show_progress 40 "🔒 Berechtigungen werden gesetzt..."
                    chmod 600 /swapfile

                    show_progress 60 "🔧 Swap wird konfiguriert..."
                    mkswap /swapfile >> "$LOG_FILE" 2>&1

                    show_progress 80 "✅ Swap wird aktiviert..."
                    swapon /swapfile

                    show_progress 100 "✅ Swap erfolgreich erstellt!"
                    sleep 1
                } | whiptail --title "Swap-Erstellung" --gauge "SWAP-Speicher wird erstellt..." 8 70 0

                whiptail --title "Swap-Speicher erstellt" --msgbox "Swap-Speicher wurde erfolgreich erstellt und aktiviert (${size}MB).\n\nDas Script wird nun beendet." 10 60
                exit 0
            else
                whiptail --title "Ungültige Eingabe" --msgbox "Ungültige Eingabe. Bitte gebe eine Zahl ein." 10 60
                swap_question
            fi
        else
            whiptail --title "Wings installiert" --msgbox "Wings wurde ohne SWAP-Speicher installiert. Du kannst es im Nachhinein über die Verwaltung nachinstallieren.\n\nDas Script wird nun beendet." 10 70
            exit 0
        fi
    else
        whiptail --title "✅ Installation abgeschlossen" --msgbox "Wings wurde erfolgreich installiert!\n\nDas Script wird nun beendet." 10 60
        exit 0
    fi
}

# Hauptinstallationsschleife
main() {
    # Bei Standalone-Installation: Config zuerst vorbereiten
    if [ "$PANEL_INSTALLED" = false ]; then
        prepare_config_for_standalone
    fi

    # Domain und Email abfragen
    while true; do
        DOMAIN=$(whiptail --title "Domain-Eingabe für Wings" --inputbox "Bitte gib die Domain für Wings ein, die du nutzen möchtest. Diese muss als DNS-Eintrag bei deiner Domain verfügbar sein.\n\nBeispiel: wings.meinedomain.de" 12 70 3>&1 1>&2 2>&3)

        if [ -z "$DOMAIN" ]; then
            whiptail --title "Installation abgebrochen" --msgbox "Du hast keine Domain angegeben. Du musst eine Domain für Wings verwenden, streng genommen nicht zwingend aber dann unsicher. Das Script wird nun gestoppt, wenn du später fortfahren möchtest, dann kannst du das Script erneut über den Wartungsmodus starten." 12 70
            exit 0
        elif ! validate_domain "$DOMAIN"; then
            continue
        fi
        break
    done

    # Email abfragen
    while true; do
        # Prüfen, ob Email bereits aus Panel-Installation vorhanden ist
        if [ -n "$PANEL_EMAIL" ]; then
            admin_email="$PANEL_EMAIL"
            whiptail --title "E-Mail automatisch übernommen" --msgbox "Die E-Mail-Adresse wurde automatisch aus der Panel-Installation übernommen:\n\n$admin_email\n\nDiese wird für das SSL-Zertifikat von Wings verwendet." 12 70
            break
        else
            admin_email=$(whiptail --title "E-Mail für Let's Encrypt" --inputbox "Gib die E-Mail Adresse ein, die informiert werden soll, wenn das SSL Zertifikat ausläuft. Diese Zertifikate halten 90 Tage, kurz vor Ablauf wird man informiert.\n\n✅ Die automatische Erneuerung ist bereits eingerichtet (alle 4 Tage)." 15 80 3>&1 1>&2 2>&3)

            if [ -z "$admin_email" ]; then
                whiptail --title "Installation abgebrochen" --msgbox "Du hast keine E-Mail angegeben, die Installation wird abgebrochen, wenn du später fortfahren möchtest, dann kannst du das Script erneut über den Wartungsmodus starten." 10 70
                exit 0
            elif ! validate_email "$admin_email"; then
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
        whiptail --title "Wings Integration" --msgbox "Wings wurde erfolgreich installiert!\n\nJetzt muss Wings noch in das Panel als Node integriert werden. Damit fahren wir als nächstes fort." 10 70
        integrate_wings "$DOMAIN"
    else
        # Standalone: Erfolgsmeldung und Hinweis auf Panel
        whiptail --title "✅ Wings installiert" --msgbox "Wings wurde erfolgreich installiert!\n\nDa du Wings standalone installiert hast, sollte die Node im Panel jetzt als AKTIV angezeigt werden (grünes schlagendes Herz).\n\nFalls nicht, überprüfe:\n• Ist die config.yml korrekt?\n• Läuft Wings? (systemctl status wings)\n• Sind die Firewall-Ports offen?" 16 75
        swap_question
    fi
}

# Starte Hauptinstallation
main

# Code created with assistance, implemented and structured by Pavl21
