#!/bin/bash

# Pfad, wo Wings installiert sein sollte. Wenn ja, Abbruch!
WINGS_PATH="/usr/local/bin/wings"

# Überprüfen, ob Wings bereits auf dem System installiert ist und gegebenenfalls abbrechen. Sonst helfen, das es gestartet wird.
if [ -f "$WINGS_PATH" ]; then
    if whiptail --title "🚀 Wings bereits installiert" --yesno "Auf diesem System ist bereits Wings installiert. Wenn du versuchst, Wings zu starten, falls es nicht reagiert, können wir das hier versuchen. Soll der Status ermittelt werden?" 10 60; then
        status_output=$(systemctl status wings)
        if [[ $status_output == *"Failed to start Pterodactyl Wings Daemon."* ]]; then
            whiptail --title "🔴 Wings Fehler" --msgbox "Es gab einen Fehler beim Starten von Wings. Versuche, Wings neu zu starten." 10 60
            sudo systemctl restart wings
            status_output=$(systemctl status wings)
            if [[ $status_output == *"Failed to start Pterodactyl Wings Daemon."* ]]; then
                whiptail --title "🔴 Wings Fehler" --msgbox "Wings konnte nicht gestartet werden, trotz Neustart. Überprüfe die Port-Konflikte und versuche es erneut." 10 60
            else
                whiptail --title "🟢 Wings Erfolgreich gestartet" --msgbox "Wings wurde erfolgreich gestartet. Die Server sollten in Kürze aktiv sein." 10 60
            fi
        elif [[ $status_output == *"inactive (dead)"* ]]; then
            sudo systemctl start wings
            status_output=$(systemctl status wings)
            if [[ $status_output == *"Active: active (running)"* ]]; then
                whiptail --title "🟢 Wings Erfolgreich gestartet" --msgbox "Wings wurde erfolgreich gestartet. Die Server sollten in Kürze aktiv sein." 10 60
            fi
        else
            whiptail --title "🚀 Wings bereits installiert" --msgbox "Wings ist bereits auf diesem System installiert und läuft." 10 60
        fi
    else
        whiptail --title "🚫 Wings Installation abgebrochen" --msgbox "Die Installation von Wings wurde abgebrochen." 10 60
    fi
else
    whiptail --title "❌ Wings nicht gefunden" --msgbox "Wings wurde auf diesem System nicht gefunden." 10 60
fi

# Pfad zur Log-Datei definieren und Log-Datei zu Beginn leeren
LOG_FILE="wings-install.log"
> "$LOG_FILE"

# Integrationshilfe für Wings
integrate_wings() {
    local DOMAIN="$1"

    # Starte die Integration
    systemctl enable wings
    systemctl stop wings

    # Zeige Infotext und frage, ob der Node erstellt wurde
    while true; do
        if whiptail --yesno "Erstelle jetzt im Panel mit der Domain $DOMAIN als Node. Hast du den Node erstellt?" 10 60; then
            # Infotext zur Wings-Integration
            whiptail --msgbox "So bindest du Wings ein: Öffne eine neue SSH-Verbindung und bearbeite die config.yml in /etc/pterodactyl/" 10 60

            # Prüfe, ob die Integration abgeschlossen ist
            if whiptail --yesno "Hast du die Wings-Integration abgeschlossen?" 10 60; then
                if [ -f /etc/pterodactyl/config.yml ]; then
                    systemctl start wings
                    if whiptail --yesno "Prüfe im Panel, ob das Herz bei der Node grün schlägt. Ist die Installation erfolgreich?" 10 60; then
                        whiptail --msgbox "Installation erfolgreich abgeschlossen!" 10 60
                        break
                    else
                        # Node erstellen, falls nötig
                        cd /var/www/pterodactyl
                        php artisan p:location:make --short=DE --long="Hauptnetz"
                        break
                    fi
                else
                    whiptail --msgbox "Die Datei /etc/pterodactyl/config.yml existiert nicht. Bitte überprüfe die Integration." 10 60
                fi
            else
                continue
            fi
        else
            whiptail --msgbox "Bitte erstelle den Node im Panel und versuche es erneut." 10 60
        fi
    done
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

# Funktion zur Installation von Wings
install_wings_with_script() {
    # Führe das externe Skript aus und leite die Ausgabe in die Log-Datei um
    bash <(curl -s https://pterodactyl-installer.se) <<EOF > "$LOG_FILE" 2>&1 &
1
N
N
y
$DOMAIN
y
$admin_email
y
EOF
    # Starte das Monitoring im Vordergrund
    monitor_progress
    # Warte auf den Abschluss des im Hintergrund laufenden Prozesses
    wait $!

    whiptail --title "Installation abgeschlossen" --msgbox "Wings wurde erfolgreich installiert und aktiviert. Jetzt muss Wings nur noch in das Panel als Node integriert werden. Damit fahren wir als nächstes fort." 10 60
    integrate_wings
}

monitor_progress() {
    declare -A progress_messages=(
        ["* Installing virt-what..."]=10
        ["* SUCCESS: System is compatible with docker"]=20
        ["* DNS verified!"]=30
        ["Selecting previously unselected package docker-ce-cli."]=40
        ["* SUCCESS: Dependencies installed!"]=50
        ["* SUCCESS: Pterodactyl Wings downloaded successfully"]=60
        ["* SUCCESS: Installed systemd service!"]=70
        ["Plugins selected: Authenticator standalone, Installer None"]=80
        ["IMPORTANT NOTES:"]=90
        ["* SUCCESS: The process of obtaining a Let's Encrypt certificate succeeded!"]=95
        ["* Wings installation completed"]=100
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
    } | whiptail --title "Wings wird installiert" --gauge "Bitte warten, dies kann je nach Leistung deines Systems einen Moment dauern..." 8 78 0
}

# Hauptinstallationsschleife
while true; do
    DOMAIN=$(whiptail --title "Domain-Eingabe für Wings" --inputbox "Bitte gib die Domain für Wings ein, die du nutzen möchtest:" 10 60 3>&1 1>&2 2>&3)

    if [ -z "$DOMAIN" ]; then
        whiptail --title "Installation abgebrochen" --msgbox "Keine Domain eingegeben. Installation wird abgebrochen." 10 60
        exit 0
    elif ! validate_domain "$DOMAIN"; then
        continue
    fi

    admin_email=$(whiptail --title "Admin-E-Mail-Eingabe" --inputbox "Bitte gib eine Admin-E-Mail-Adresse ein:" 10 60 3>&1 1>&2 2>&3)

    if [ -z "$admin_email" ]; then
        whiptail --title "Installation abgebrochen" --msgbox "Keine E-Mail-Adresse eingegeben. Installation wird abgebrochen." 10 60
        exit 0
    elif ! validate_email "$admin_email"; then
        continue
    fi

    install_wings_with_script
    break
done


