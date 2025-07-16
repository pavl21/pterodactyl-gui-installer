#!/bin/bash

# Pfad, wo Wings installiert sein sollte. Wenn ja, Abbruch und fragen, ob man sonst noch helfen kann. Falls Wings nicht funktioniert!
WINGS_PATH="/usr/local/bin/wings"

# Überprüfen, ob Wings bereits auf dem System installiert ist und gegebenenfalls abbrechen. Sonst helfen, das es gestartet wird.
if [ -f "$WINGS_PATH" ]; then
    if whiptail --title "🚀 Wings bereits installiert" --yesno "Auf diesem System ist bereits Wings installiert. Wenn du versuchst Wings zu starten, falls es nicht reagiert, können wir das hier versuchen. Soll der Status ermittelt werden?" 10 60; then
        status_output=$(systemctl status wings)
        if [[ $status_output == *"Failed to start Pterodactyl Wings Daemon."* ]]; then
            whiptail --title "🔴 Wings Fehler" --msgbox "Es gab einen Fehler beim Starten von Wings. Versuche, Wings neu zu starten. Bestätige, wenn der Neustart erfolgen soll." 10 60
            sudo systemctl restart wings
            status_output=$(systemctl status wings)
            if [[ $status_output == *"Failed to start Pterodactyl Wings Daemon."* ]]; then
                whiptail --title "🔴 Wings Fehler" --msgbox "Wings konnte nicht gestartet werden, trotz Neustart. Überprüfe, ob eventuell Port-Konflikte vorhanden sind und versuche es erneut, dies kannst du mit dem Befehl 'sudo wings' nachprüfen." 10 80
            else
                whiptail --title "🟢 Wings Erfolgreich gestartet" --msgbox "Wings wurde erfolgreich gestartet. Die Server sollten in Kürze aktiv sein. Das Script wird nun beendet." 10 60
            fi
        elif [[ $status_output == *"inactive (dead)"* ]]; then
            sudo systemctl start wings
            status_output=$(systemctl status wings)
            if [[ $status_output == *"Active: active (running)"* ]]; then
                whiptail --title "🟢 Wings Erfolgreich gestartet" --msgbox "Wings wurde erfolgreich gestartet. Die Server sollten in Kürze aktiv sein." 10 60
            fi
        else
            whiptail --title "🚀 Wings bereits installiert" --msgbox "Wings ist bereits auf diesem System installiert und läuft." 10 60
            exit 0
        fi
    else
        whiptail --title "🚫 Wings Installation abgebrochen" --msgbox "Die Installation von Wings wurde abgebrochen." 10 60
    fi
fi

# Pfad zur Log-Datei definieren und Log-Datei zu Beginn leeren
LOG_FILE="wings-install.log"
> "$LOG_FILE"

# Integrationshilfe für Wings
integrate_wings() {
    local DOMAIN="$1"

    # Verfügbaren RAM in MB und freien Speicherplatz in MB ermitteln
    local mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local disk_avail_mb=$(df -m / | awk 'NR==2 {print $4}')
    local mem_total_mb=$((mem_total_kb / 1024))

    systemctl enable wings
    systemctl stop wings
    cd /var/www/pterodactyl

    # Versuche die notwendigen Einträge automatisch zu erzeugen
    php artisan p:location:make --short=DE --long="Hauptnetz" >/dev/null 2>&1
    php artisan p:node:make --location=1 --name="Wings" \
        --fqdn="$DOMAIN" --scheme=https --daemon-listen=443 \
        --daemon-sftp=2022 --behind-proxy=true --ssl=true \
        --memory=${mem_total_mb} --disk=${disk_avail_mb} --no-interaction >/dev/null 2>&1

    systemctl start wings
    whiptail --title "Wings Integration" --msgbox "Wings wurde automatisch in das Panel eingebunden." 10 60
    swap_question
}

# Funktionen zur Validierung
validate_domain() {
    local domain=$1
    if [[ $domain =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        local server_ip=$(hostname -I | awk '{print $1}')
        local dns_ip=$(dig +short $domain)
        if [[ "$dns_ip" == "$server_ip" ]]; then
            title="✅ Erfolg - Domain Überprüfung"
            message="Die IP-Adresse der Domain $domain stimmt mit der IP-Adresse des Servers überein. Die Installation wird fortgesetzt."
            whiptail --title "$title" --msgbox "$message" 10 60
            return 0
        else
            title="❌ Fehler - Domain Überprüfung"
            message="Die IP-Adresse der Domain $domain stimmt nicht mit der IP-Adresse des Servers überein.\n\nDomain -> $domain"
            whiptail --title "$title" --msgbox "$message" 10 60
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

# Funktion zur Installation von Wings mit Docker-Installation
install_wings_with_script() {
    # Erstelle ein Skript für die Eingaben
    echo -e "1\nN\nN\ny\n$DOMAIN\ny\n$admin_email\ny\n$( [[ ! -d "/var/www/pterodactyl" ]] && echo "Y" )" > inputs.txt

    # Führe zuerst den Befehl zur Docker-Installation im Hintergrund aus und leite die Ausgabe in die Log-Datei um
    curl -sSL https://get.docker.com/ | CHANNEL=stable sh >> "$LOG_FILE" 2>&1 &
    PID_DOCKER=$!

    # Starte den Fortschrittsmonitor im Hintergrund
    monitor_progress &
    PID_MONITOR=$!

    # Warte auf den Abschluss der Docker-Installation
    wait $PID_DOCKER
    # Beende den Fortschrittsmonitor
    kill $PID_MONITOR

    # Führe das Pterodactyl-Installer-Skript aus, wenn Docker erfolgreich installiert wurde
    bash <(curl -s https://pterodactyl-installer.se) < inputs.txt >> "$LOG_FILE" 2>&1

    # Entferne die Eingabedatei nach Gebrauch
    rm inputs.txt

    # Meldung anzeigen, dass die Installation abgeschlossen ist
    whiptail --title "Wings Integration" --msgbox "Wings wurde erfolgreich installiert und aktiviert. Jetzt muss Wings nur noch in das Panel als Node integriert werden. Damit fahren wir als nächstes fort." 10 60

    integrate_wings "$DOMAIN"
}






monitor_progress() {
    declare -A progress_messages=(
        ["+ sh -c DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apt-transport-https ca-certificates curl gnupg >/dev/null"]=15
        ["+ sh -c DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-ce-rootless-extras docker-buildx-plugin >/dev/null"]=27
        ["* Retrieving release information..."]=30
        ["* Installing virt-what..."]=35
        ["* - will not log or share any IP-information with any third-party."]=48
        ["SetCreated symlink /etc/systemd/system/timers.target.wants/certbot.timer → /lib/systemd/system/certbot.timer."]=56
        ["* SUCCESS: Pterodactyl Wings downloaded successfully"]=72
        ["* SUCCESS: Installed systemd service!"]=79
        ["* Configuring LetsEncrypt.."]=81
        ["Plugins selected: Authenticator standalone, Installer None"]=86
        ["Requesting a certificate for wings.pavl21.de"]=97
        ["* Wings installation completed"]=99
    )

    # Fortschrittsbalken initialisieren
    {
        for ((i=0; i<=100; i++)); do
            sleep 1
            # Lies die neueste Zeile aus der Log-Datei
            line=$(tail -n 1 "$LOG_FILE")
            for key in "${!progress_messages[@]}"; do
                if [[ "$line" == *"$key"* ]]; then
                    echo "${progress_messages[$key]}"
                    break
                fi
            done
        done
    } | whiptail --title "Wings wird installiert" --gauge "Bitte warte einen Moment, das kann je nach Leistung deines Servers einen Moment dauern..." 8 78 0
}

# SWAP-Speicher zuweisen
swap_question() {
    whiptail --title "Swap-Speicher für Wings" --yesno "Möchtest du SWAP-Speicher für Wings einbinden?" 10 60
    response=$?
    if [ $response -eq 0 ]; then
        size=$(whiptail --title "Swap-Speicher erstellen" --inputbox "Gebe die gewünschte Swap-Größe in MB ein:" 10 60 3>&1 1>&2 2>&3)
        response=$?
        if [ $response -eq 0 ]; then
            if [[ $size =~ ^[0-9]+$ ]]; then
                sudo fallocate -l ${size}M /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
                whiptail --title "Swap-Speicher erstellt" --msgbox "Swap-Speicher wurde erfolgreich erstellt und aktiviert. Das Script wird nun beendet." 10 60
                exit 0
            else
                whiptail --title "Das ist keine Zahl" --msgbox "Ungültige Eingabe. Bitte gebe eine Zahl ein." 10 60
            fi
        else
            whiptail --title "Wings installiert" --msgbox "Wings wurde nun ohne SWAP-Speicher installiert. Du kannst es im Nachhinein über die Verwaltung nachinstallieren. Das Script wird nun beendet." 10 60
            exit 0
        fi
    else
        exit 0
    fi
}

# Hauptinstallationsschleife zu Beginn ... ->
panel_domain_file="/var/.panel_domain"
if [ -f "$panel_domain_file" ]; then
    panel_domain=$(cat "$panel_domain_file")
    if whiptail --title "Panel-Domain gefunden" --yesno "Soll Wings auf dem gleichen Server wie das Panel laufen und die Domain $panel_domain verwenden?" 10 70; then
        DOMAIN="$panel_domain"
    fi
fi

while true; do
    if [ -z "$DOMAIN" ]; then
        DOMAIN=$(whiptail --title "Domain-Eingabe für Wings" --inputbox "Bitte gib die Domain für Wings ein, die du nutzen möchtest. Diese muss als DNS-Eintrag bei deiner Domain verfügbar sein." 10 70 3>&1 1>&2 2>&3)
    fi

    if [ -z "$DOMAIN" ]; then
        whiptail --title "Installation abgebrochen" --msgbox "Du hast keine Domain angegeben. Du musst eine Domain für Wings verwenden, streng genommen nicht zwingend aber dann unsicher. Das Script wird nun gestoppt, wenn du später fortfahren möchtest, dann kannst du das Script erneut über den Wartungsmodus starten." 10 60
        exit 0
    elif ! validate_domain "$DOMAIN"; then
        continue
    fi

    admin_email=$(whiptail --title "E-Mail für Let's Encrypt" --inputbox "Gib die E-Mail Adresse erneut ein, die informiert werden soll, wenn das SSL Zertifikat ausläuft. Diese Zertifikate halten 90 Tage, kurz vor Ablauf wird man informiert. Wenn man es nicht verlängert (Mit dem Befehl 'certbot renew' über SSH), wird Wings nicht mehr erreichbar sein und alle Server können nicht mehr kontrolliert werden, die über diese Node laufen" 17 80 3>&1 1>&2 2>&3)

    if [ -z "$admin_email" ]; then
        whiptail --title "Installation abgebrochen" --msgbox "Du hast keine E-Mail angegeben, die Installation wird abgebrochen, wenn du später fortfahren möchtest, dann kannst du das Script erneut über den Wartungsmodus starten." 10 70
        exit 0
    elif ! validate_email "$admin_email"; then
        continue
    fi

    install_wings_with_script
    break
done

# Code created by ChatGPT, zusammengesetzt und Idee der Struktur und Funktion mit einigen Vorgaben von Pavl21
