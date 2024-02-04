#!/bin/bash

# Info-Box, dass das Panel während des Prozesses nicht erreichbar ist
whiptail --title "Info zum Panel" --msgbox "Hier werden die SSL-Zertifikate erneuert. Sämtliche Websites, auch das Panel, die über diesen Server laufen, werden während des Vorgangs offline sein. Das dauert in der Regel nur 1 Minute." 15 50

# Fortschrittsanzeige in Whiptail starten
{
    echo 10; sleep 1
    systemctl is-active --quiet apache2 && systemctl stop apache2 && echo "Apache gestoppt."
    echo 30; sleep 1
    systemctl stop nginx && echo "Nginx gestoppt."
    echo 40; sleep 1
    sudo fuser -k 80/tcp
    sudo fuser -k 443/tcp
    echo 50; sleep 1
    renew_output=$(certbot renew -q 2>&1)
    echo 70; sleep 1
    systemctl is-active --quiet apache2 && systemctl restart apache2 && echo "Apache neu gestartet."
    systemctl restart nginx && echo "Nginx neu gestartet."
    echo 90; sleep 1
    echo 100; sleep 1
} | whiptail --title "Certbot erneuert Zertifikate" --gauge "Bitte warten, Certbot versucht die Zertifikate zu erneuern..." 10 50 0

clear
echo ""
echo ""
echo "DEBUG - - - - - - - -"
echo "Die Logs werden ausgewertet, bitte warte einen Moment..."

# Titel und Text für die Whiptail-Box vorbereiten
title=""
text=""

# Certbot erneuern und Ausgabe in Variable speichern
renew_output=$(certbot renew -q 2>&1)

# Überprüfen, ob Fehler aufgetreten sind
if echo "$renew_output" | grep -q "Failed to renew"; then
    title="Details der Erneuerung"
    text="Beim erneuern der Zertifikate sind Probleme aufgetreten.\n\n"

    # Jede Zeile der Ausgabe durchgehen
    while IFS= read -r line; do
        if echo "$line" | grep -q "Could not bind to IPv4 or IPv6"; then
            domain=$(echo "$line" | grep -oP '(?<=certificate ).*(?= with error)')
            text+="⚠ $domain war nicht erfolgreich: Anderer Webserver blockiert die Ports (Port 80 blockiert)\n"
        elif echo "$line" | grep -q "rateLimited"; then
            domain=$(echo "$line" | grep -oP '(?<=certificate ).*(?= with error)')
            text+="⚠ $domain war nicht erfolgreich: Validierungslimit überschritten, Domain temporär gesperrt.\n"
        fi
    done <<< "$(echo "$renew_output" | grep "Failed to renew")"

    text+="\nVersuche 'certbot renew' selbst nochmal auszuführen, wenn du weitere Infos benötigst."
else
    title="Erneuerung abgeschlossen"
    text="Alle Domains, die verbunden sind wurden bei Bedarf erneuert. Es wurden keine Probleme festgestellt."
fi

clear
# Whiptail-Box anzeigen
whiptail --title "$title" --msgbox "$text" 23 84

# Zurück zur Oberfläche
curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/problem-verwaltung.sh | bash

