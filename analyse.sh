#!/bin/bash

# Überprüfe, ob speedtest-cli installiert ist und installiere es falls notwendig
if ! command -v speedtest-cli &> /dev/null; then
    echo "speedtest-cli und jq ist nicht installiert. Installation wird durchgeführt..."
    sudo apt-get install -y speedtest-cli jq
fi


# Funktion zur Anzeige des Fortschritts
show_progress() {
    for ((i = 0; i <= 100; i += 10)); do
        echo "$i"
        sleep 0.6  # Ändere die Schlafdauer auf 0,6 Sekunden (6 Sekunden insgesamt für 100%)
    done
}

# Starte die Anzeige des Fortschritts in einer Hintergrundschleife
show_progress | whiptail --title "Test läuft" --gauge "Speedtest wird durchgeführt..." 8 40 0 &

# Bandbreitentest mit Speedtest CLI (im Hintergrund)
speedtest_result=$(speedtest-cli --simple)
download_speed=$(echo "$speedtest_result" | awk -F ' ' '/Download/{print $2}')
upload_speed=$(echo "$speedtest_result" | awk -F ' ' '/Upload/{print $2}')
download_speed+=" Mbit/s" # Hinzufügen von "Mbit/s" zur Download-Geschwindigkeit
upload_speed+=" Mbit/s"   # Hinzufügen von "Mbit/s" zur Upload-Geschwindigkeit

# Beende das Fortschrittsbalkenfenster
kill $!  # $! enthält die Prozess-ID des zuletzt gestarteten Hintergrundprozesses

# Prüfen, ob genügend Speicherplatz vorhanden ist
disk_usage=$(df -h / | awk 'NR==2{print $5}')
free_space=$(df -h / | awk 'NR==2{print $4}')
if [[ ${disk_usage%?} -lt 70 ]]; then
  disk_status="✔ Speicherplatz prüfen - OK ($disk_usage - $free_space frei)"
else
  disk_status="⚠ Speicherplatz prüfen - WARNUNG ($disk_usage - $free_space frei)"
fi

# Prüfen, ob Updates verfügbar sind
update_count=$(apt list --upgradable 2>/dev/null | grep -c -v 'Listing...')
if [[ $update_count -gt 0 ]]; then
  update_status="⚠ Offene Updates - Es liegen $update_count Updates vor"
else
  update_status="✔ Offene Updates - Auf den neuesten Stand"
fi

# Prüfen, ob Nginx einwandfrei funktioniert
nginx_check=$(nginx -t 2>&1)
if [[ $nginx_check == *"successful"* ]]; then
  nginx_status="✔ Nginx Einstellungen prüfen - Alles in Ordnung"
else
  nginx_status="⚠ Nginx Einstellungen prüfen - FEHLER"
fi

# Prüfen, ob DNS-Einstellungen in Ordnung sind und Zeit anzeigen
dns_check=$(ping -c 1 google.com | grep -o -P 'time=\K[^ ]+')
if [[ -n $dns_check ]]; then
  dns_status="✔ DNS-Einstellungen - Auflösung erfolgreich ($dns_check ms)"
else
  dns_status="⚠ DNS-Einstellungen - DNS-Auflösung fehlgeschlagen"
fi

# Prüfen, ob das Pterodactyl Panel ein Update hat
installed_version=$(cat "/var/www/pterodactyl/config/app.php" 2> /dev/null | grep "'version' =>" | cut -d\' -f4 | sed 's/^/v/') # Ersetze /path/to/installed/version.txt durch den tatsächlichen Pfad
latest_version=$(curl -s https://api.github.com/repos/pterodactyl/panel/releases/latest | jq -r '.tag_name')
if [[ "$installed_version" == "$latest_version" ]]; then
  panel_update_status="✔ Pterodactyl Panel - Auf den neuesten Stand"
else
  panel_update_status="⚠ Pterodactyl Panel - Ein Update ist verfügbar ($latest_version)"
fi

# Überprüfe die Berechtigungen von /var/www/pterodactyl
if [ "$(stat -c %U:%G /var/www/pterodactyl/public)" = "www-data:www-data" ]; then
    permissions_status="✔ Verzeichnisrechte - Die Berechtigungen sind korrekt"
else
    permissions_status="⚠ Verzeichnisrechte - Die Berechtigungen sind nicht korrekt"
fi

clear

# Whiptail-Fenster anzeigen mit breiteren Abmessungen
whiptail --title "Ergebnis der Analyse" --msgbox "
- ✔ Bandbreitentest - $download_speed Download und $upload_speed Upload
- $disk_status
- $update_status
- $nginx_status
- $dns_status
- $panel_update_status
- $permissions_status

Diese Informationen wurden mit Scripts von Pavl21 geholt, die Ergebnisse könnten fehlerhaft sein." 20 80


# Zur Problembehandlung zurück
curl -sSfL https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main/problem-verwaltung.sh | bash
