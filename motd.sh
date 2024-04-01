#!/bin/bash
## Muss installiert sein: lolcat, figlet, vnstat, jq

clear

# "GermanDactyl Panel" Logo
figlet -f small "GermanDactyl Panel" | /usr/games/lolcat -f
echo -e "Pterodactyl Panel, übersetzt von Pavl21 und Verwaltung via GermanDactyl Setup" | /usr/games/lolcat
echo "-----------------------------------------------------------------------------" | /usr/games/lolcat


# Begrüßung basierend auf der Tageszeit
HOUR=$(date +"%H")
if (( HOUR >= 6 && HOUR <= 11 )); then
    GREETING="Guten Morgen"
elif (( HOUR >= 12 && HOUR <= 14 )); then
    GREETING="Mahlzeit"
elif (( HOUR >= 15 && HOUR <= 17 )); then
    GREETING="Genieß dein Cauken"
else
    GREETING="Guten Abend"
fi

echo -e "\n\e[32m${GREETING}, $(whoami)!\nWillkommen auf $(hostname -f)!\e[0m" | /usr/games/lolcat

# Paketupdates Überprüfung
UPDATES=$(apt list --upgradable 2>/dev/null | grep -v "Listing")
UPDATE_COUNT=$(echo "$UPDATES" | wc -l)
CRITICAL_UPDATE=$(echo "$UPDATES" | grep -E "containerd|docker" | wc -l)

if [ "$CRITICAL_UPDATE" -gt 0 ]; then
    echo -e "\n📦 Es liegen $UPDATE_COUNT Updates und auch Sicherheitsupdates für die Pterodactyl-Instanzen bereit.\nInstalliere diese nach Gelegenheit, denn dabei müssen sämtliche Pterodactyl-Instanzen neu gestartet werden." | /usr/games/lolcat
elif [ "$UPDATE_COUNT" -gt 0 ]; then
    echo -e "\n📦 Es liegen $UPDATE_COUNT Updates vor Du kannst sie bei Gelegenheit aktualisieren, aber derzeit ist es nicht notwendig." | /usr/games/lolcat
else
    echo -e "\n📦 Keine Paketupdates verfügbar." | /usr/games/lolcat
fi

# Fehlgeschlagene Loginversuche
LOGIN_ATTEMPTS=$(grep "Failed password" /var/log/auth.log | wc -l)

if (( LOGIN_ATTEMPTS < 10000 )); then
    echo -e "\n🔓 Keine nennenswerten Meldungen vorhanden. Sehr gut!" | /usr/games/lolcat
else
    echo -e "\n⚠️ Info: Es fanden im Hintergrund über 10k Loginversuche statt, hier sind die aktivsten Angreifer:" | /usr/games/lolcat
    grep "Failed password" /var/log/auth.log | awk '{print $(NF-3)}' | sort | uniq -c | sort -nr | head -3 | awk '{print "Platz " NR ": " $2 " -> " $1 " Loginversuche"}' | /usr/games/lolcat
fi

# System-Up-Time in deutscher Sprache
UPTIME=$(uptime -p | sed 's/up /Seit /; s/ days,/ Tagen,/; s/ day,/ Tag,/; s/ hours,/ Std.,/; s/ hour,/ Std.,/; s/ minutes/min./; s/ minute/min./;')
UPTIME_DAYS=$(echo $UPTIME | grep -o '[0-9]* Tage')
if [[ $UPTIME_DAYS == *Tage* ]] && [ "${UPTIME_DAYS% *} " -ge 30 ]; then
    echo -e "\n⏱ System-Up-Time: $UPTIME.\nEs wird empfohlen, den Server bei Gelegenheit neu zu starten. Ein Neustart kann bekannte Fehler beheben." | /usr/games/lolcat
else
    echo -e "\n⏱ System-Up-Time: $UPTIME" | /usr/games/lolcat
fi

convert_to_mb() {
    local value=$1
    # Ersetzt Kommas durch Punkte für die Berechnung und fügt eine führende Null hinzu, falls erforderlich
    local number=$(echo "$value" | sed 's/,/./' | awk '{printf "%.1f", $0}')
    local unit=$(echo "$value" | grep -o '[a-zA-Z]*$')

    local result
    case $unit in
        KiB) result=$(echo "scale=1; $number / 1024" | bc) ;;
        MiB) result="$number" ;;
        GiB) result=$(echo "scale=1; $number * 1024" | bc) ;;
        B) result=$(echo "scale=1; $number / 1048576" | bc) ;; # Konvertierung von Bytes in MB
        *) result="0" ;; # Fallback, falls keine gültige Einheit erkannt wurde
    esac

    # Überprüft, ob das Ergebnis eine führende Null benötigt
    if [[ $result == .* ]]; then
        echo "0$result"
    else
        echo $result
    fi
}


# Netzwerkdaten mit vnstat für eine spezifische Schnittstelle (z.B. eth0)
INTERFACE="eth0" # Setze dies auf deine spezifische Schnittstelle
if hash vnstat 2>/dev/null; then
    NETWORK_USAGE=$(vnstat -i $INTERFACE --oneline | grep $INTERFACE)
    if [[ $NETWORK_USAGE == *"Not enough data available yet."* ]]; then
        echo -e "\n📶 Netzwerkdaten: Es stehen noch nicht genügend Daten für die Auswertung zur Verfügung." | /usr/games/lolcat
    else
        # Daten extrahieren und in MB umrechnen
        TODAY_UP=$(convert_to_mb "$(echo $NETWORK_USAGE | cut -d ';' -f 4)")
        TODAY_DOWN=$(convert_to_mb "$(echo $NETWORK_USAGE | cut -d ';' -f 5)")
        MONTH_UP=$(convert_to_mb "$(echo $NETWORK_USAGE | cut -d ';' -f 9)")
        MONTH_DOWN=$(convert_to_mb "$(echo $NETWORK_USAGE | cut -d ';' -f 10)")

        # Ergebnisse ausgeben
        echo -e "\n📶 Netzwerkdaten für die Schnittstelle $INTERFACE:" | /usr/games/lolcat
        echo -e "Heute: ↑ ${TODAY_UP}MB - ↓ ${TODAY_DOWN}MB\nDieser Monat:  ↑ ${MONTH_UP}MB - ↓ ${MONTH_DOWN}MB" | /usr/games/lolcat
        echo "IP-Adresse: $(hostname -I | awk '{print $1}')" | /usr/games/lolcat
        echo "Standort: $(curl -s http://ip-api.com/json/$(hostname -I | awk '{print $1}') | jq -r '.country')" | /usr/games/lolcat

    fi
else
    echo -e "\n📶 Netzwerkdaten: vnstat ist nicht installiert, keine Informationen verfügbar." | /usr/games/lolcat
fi

# Letzter erfolgreicher Login
LAST_LOGIN=$(last -i | grep -m 1 "logged in")
LAST_LOGIN_USER=$(echo $LAST_LOGIN | awk '{print $1}')
LAST_LOGIN_IP=$(echo $LAST_LOGIN | awk '{print $3}')
LAST_LOGIN_TIME=$(echo $LAST_LOGIN | awk '{print $4, $5, $6, $7}')
LAST_LOGIN_TIMESTAMP=$(date -d "$LAST_LOGIN_TIME" +'%d.%m.%Y - %H:%M:%S')

echo -e "\n🔑 Letzter erfolgreicher Login:" | /usr/games/lolcat
echo -e "Benutzer: $LAST_LOGIN_USER\nLogin von IP: $LAST_LOGIN_IP\nZeitpunkt: $LAST_LOGIN_TIMESTAMP" | /usr/games/lolcat

# Bunter Trenner und Abschluss des Scripts
echo -e "$(printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' '-')\n" | /usr/games/lolcat

# Das Script ist ein Teil vom GermanDactyl-Setup Projekt, zur Übersicht aller aktuellen Infos des Servers und der Pterodactyl-Instanzen
# Du kannst es unter privater Nutzung nach deinen belieben anpassen, wenn du möchtest.
