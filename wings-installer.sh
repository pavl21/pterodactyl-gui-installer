#!/bin/bash

# Pfad, wo Wings installiert sein sollte. Wenn ja, Abbruch!
WINGS_PATH="/usr/local/bin/wings"

# Prüfen, ob Wings bereits installiert ist
if [ -f "$WINGS_PATH" ]; then
    whiptail --title "Wings bereits installiert" --msgbox "Wings ist bereits auf diesem System installiert. Die Installation wird abgebrochen." 10 60
    exit 0  # Beendet das Skript, da Wings bereits installiert ist
fi

# Pfad zur Log-Datei definieren
LOG_FILE="wlog.txt"

# Log-Datei zu Beginn des Skripts erstellen oder leeren
> "$LOG_FILE"

# Funktion zur Überprüfung, ob die Domain-Struktur gültig ist
validate_domain() {
    local domain=$1
    if [[ $domain =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0  # Erfolg
    else
        return 1  # Fehler
    fi
}

# Funktion zur Überprüfung der E-Mail-Adresse
validate_email() {
    local email=$1
    if [[ $email =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; then
        return 0  # Erfolg
    else
        return 1  # Fehler
    fi
}

# Wenn die Installation fertig ist, weitere Anweisungen.
on_installation_complete() {
    # Hier kannst du deinen eigenen Code einfügen, der nach Abschluss der Installation ausgeführt wird
    echo "Installation abgeschlossen. Deine benutzerdefinierte Aktion hier."
}

# Funktion zur Überprüfung, ob die IPv4-Adresse zur angegebenen Domain passt
isMatchingIPv4() {
    local domain=$1
    local server_ip=$(hostname -I | awk '{print $1}')
    local dns_ip=$(dig +short $domain)
    echo "Server IP: $server_ip"
    echo "DNS IP: $dns_ip"
    if [[ "$dns_ip" == "$server_ip" ]]; then
        echo "Die IP-Adressen stimmen überein."
        return 0  # Erfolg
    else
        echo "Die IP-Adressen stimmen nicht überein."
        return 1  # Fehler
    fi
}

# Funktion zur Installation von Wings mit dem externen Script
install_wings_with_script() {
    # Führe das externe Skript im Hintergrund aus und leite die Ausgabe in LOG_FILE um
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
    # Wings aktivieren und stoppen (möglicherweise für Konfigurationszwecke)
    systemctl enable wings
    systemctl stop wings
}

monitor_progress() {
    declare -A progress_messages=(
        ["Installing virt-what"]=1
        ["this script will not start Wings automatically"]=5
        ["Installing pterodactyl wings"]=10
        ["ca-certificates is already the newest version"]=25
        ["Executing: /lib/systemd/systemd-sysv-install enable docker"]=40
        ["Pterodactyl Wings downloaded successfully"]=50
        ["Installed systemd service!"]=65
        ["Saving debug log to /var/log/letsencrypt/letsencrypt.log"]=70
        ["Requesting a certificate"]=85
        ["Waiting for verification..."]=90
        ["The process of obtaining a Let's Encrypt certificate succeeded!"]=100
    )

    highest_progress=0
    {
    while read line; do
        for key in "${!progress_messages[@]}"; do
            if [[ "$line" == *"$key"* ]]; then
                current_progress="${progress_messages[$key]}"
                if [ "$current_progress" -gt "$highest_progress" ]; then
                    highest_progress=$current_progress
                    if [ "$highest_progress" -eq 100 ]; then
                        whiptail --title "Installation abgeschlossen" --msgbox "Wings wurde erfolgreich installiert!" 10 60
                        sleep 2
                        whiptail --clear
                        sleep 1
                        on_installation_complete
                    else
                        # Aktualisiere den Fortschritt im Whiptail-Popup
                        echo "$highest_progress"
                    fi
                fi
            fi
        done
    done < <(tail -n 0 -f "$LOG_FILE") # Überwache LOG_FILE statt wlog.txt
} | whiptail --gauge "Wings wird installiert..." 10 70 0

# Funktion zur Abfrage und Validierung der E-Mail-Adresse des SSL Zertifikats Let's Encrypt
ask_for_admin_email() {
    while true; do
        admin_email=$(whiptail --title "E-Mail-Adresse für den Admin" --inputbox "Bitte gib die E-Mail-Adresse für den Administrator ein:" 10 60 3>&1 1>&2 2>&3)

        if [ -z "$admin_email" ]; then
            if whiptail --title "Abbrechen" --yesno "Möchtest du die Eingabe wirklich abbrechen?" 10 60; then
                exit 0
            fi
        elif ! validate_email "$admin_email"; then
            whiptail --title "Ungültige E-Mail-Adresse" --msgbox "Die angegebene E-Mail-Adresse ist ungültig. Bitte gib eine gültige E-Mail-Adresse ein." 10 60
            continue
        else
            echo "$admin_email"  # Gibt die gültige E-Mail-Adresse zurück
            install_wings_with_script
            return
        fi
    done
}

# Beginn von Wings-Installation, weiter zu...
# ...der tatsächlichen Installation
while true; do
    DOMAIN=$(whiptail --title "Domain-Eingabe für Wings" --inputbox "Bitte gib die Domain für Wings ein, die du nutzen möchtest" 10 60 3>&1 1>&2 2>&3)

    if [ -z "$DOMAIN" ]; then
        if whiptail --title "Abbrechen" --yesno "Möchtest du die Eingabe wirklich abbrechen?" 10 60; then
            exit 0  # Das Skript wird bei Abbruch beendet
        else
            continue  # Zurück zur Domain-Eingabe
        fi
    fi

    if validate_domain "$DOMAIN"; then
        if isMatchingIPv4 "$DOMAIN"; then
            whiptail --title "DNS-Eintrag gefunden" --msgbox "Es wurde ein Eintrag gefunden, der mit diesem Server und der Domain verknüpft ist. Die Installation wird fortgesetzt." 10 60
            ask_for_admin_email
            break
        else
            dns_ipv4=$(dig +short A "$DOMAIN")
            server_ipv4=$(curl -4s ifconfig.me)

            if whiptail --title "Kein DNS-Eintrag gefunden" --yesno "Die DNS-Einstellungen der Domain sind nicht korrekt oder die Domain ist nicht mit der IPv4-Adresse dieses Servers verknüpft.\n\n$DOMAIN -> $dns_ipv4\nServer IPv4: $server_ipv4\n\nMöchtest du es erneut versuchen?" 16 78; then
                continue
            else
                if whiptail --title "Abbrechen" --yesno "Möchtest du die Installation abbrechen?" 10 60; then
                    exit 0
                else
                    continue
                fi
            fi
        fi
    else
        whiptail --title "Ungültige Domain" --msgbox "Die angegebene Domain ist ungültig. Bitte gib eine gültige Domain ein." 10 60
        continue
    fi
done

