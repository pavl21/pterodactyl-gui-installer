#!/bin/bash
# Pfad: motd.sh (wird nach /usr/local/bin/germandactyl-motd installiert)
# Loginseite von GermanDactyl Setup: Übersicht über den Zustand des Servers nach dem SSH-Login.
# Benötigt: lolcat, figlet, vnstat, jq, bc (werden von custom-ssh-login-config.sh installiert)

LOLCAT="/usr/games/lolcat"
[ -x "$LOLCAT" ] || LOLCAT="cat"

clear

# Logo
if command -v figlet >/dev/null 2>&1; then
    figlet -f small "GermanDactyl Panel" | $LOLCAT
fi
echo "Pterodactyl Panel mit deutscher Übersetzung – verwaltet mit GermanDactyl Setup" | $LOLCAT
echo "-----------------------------------------------------------------------------" | $LOLCAT

# Begrüßung je nach Tageszeit
HOUR=$((10#$(date +%H)))
if (( HOUR >= 5 && HOUR <= 11 )); then
    GREETING="Guten Morgen"
elif (( HOUR >= 12 && HOUR <= 14 )); then
    GREETING="Mahlzeit"
elif (( HOUR >= 15 && HOUR <= 17 )); then
    GREETING="Zeit für Kaffee und Kuchen"
else
    GREETING="Guten Abend"
fi
echo -e "\n${GREETING}, $(whoami)!\nWillkommen auf $(hostname -f 2>/dev/null || hostname)!" | $LOLCAT

# Paketupdates
UPDATES="$(apt list --upgradable 2>/dev/null | grep -v '^Listing' | grep -v '^Auflistung')"
UPDATE_COUNT="$(grep -c . <<< "$UPDATES")"
CRITICAL_UPDATE="$(grep -cE '^(containerd|docker)' <<< "$UPDATES")"
if [ "$CRITICAL_UPDATE" -gt 0 ]; then
    echo -e "\n▤ Es liegen $UPDATE_COUNT Updates vor, darunter Updates für Docker.\nInstalliere sie bei Gelegenheit – dabei werden alle Gameserver kurz neu gestartet." | $LOLCAT
elif [ "$UPDATE_COUNT" -gt 0 ]; then
    echo -e "\n▤ Es liegen $UPDATE_COUNT Updates vor. Du kannst sie bei Gelegenheit installieren." | $LOLCAT
else
    echo -e "\n▤ Keine Paketupdates verfügbar." | $LOLCAT
fi

# Fehlgeschlagene SSH-Logins der letzten 24 Stunden (nur als root lesbar)
if [ "$(id -u)" = "0" ]; then
    FAILED="$(journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null | grep -cE 'Failed password|Invalid user')"
    if [ "${FAILED:-0}" -lt 1000 ]; then
        echo -e "\n✱ Fehlgeschlagene SSH-Logins (24 h): ${FAILED:-0} – keine Auffälligkeiten." | $LOLCAT
    else
        echo -e "\n⚠  In den letzten 24 Stunden gab es ${FAILED} fehlgeschlagene SSH-Logins. Die aktivsten Absender:" | $LOLCAT
        journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null | grep -E 'Failed password|Invalid user' \
            | grep -oE 'from [0-9a-fA-F.:]+' | awk '{print $2}' | sort | uniq -c | sort -nr | head -3 \
            | awk '{print "Platz " NR ": " $2 " -> " $1 " Versuche"}' | $LOLCAT
        command -v fail2ban-client >/dev/null 2>&1 || echo "Tipp: fail2ban sperrt solche Angreifer automatisch." | $LOLCAT
    fi
fi

# Laufzeit des Systems
UPTIME_DAYS=$(( $(cut -d. -f1 /proc/uptime) / 86400 ))
UPTIME="$(uptime -p | sed 's/^up /seit /; s/ years\?/ J./; s/ weeks\?/ Wo./; s/ days\?/ Tg./; s/ hours\?/ Std./; s/ minutes\?/ Min./')"
if [ "$UPTIME_DAYS" -ge 30 ]; then
    echo -e "\n◷  Laufzeit: $UPTIME\nDer Server läuft seit über 30 Tagen. Ein Neustart bei Gelegenheit spielt z. B. Kernel-Updates ein." | $LOLCAT
else
    echo -e "\n◷  Laufzeit: $UPTIME" | $LOLCAT
fi

# Netzwerkdaten (Schnittstelle der Standardroute)
INTERFACE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
if command -v vnstat >/dev/null 2>&1 && [ -n "$INTERFACE" ]; then
    NETWORK_USAGE="$(vnstat -i "$INTERFACE" --oneline 2>/dev/null)"
    if [[ -z "$NETWORK_USAGE" || "$NETWORK_USAGE" == *"Not enough data"* || "$NETWORK_USAGE" == *"Error"* ]]; then
        echo -e "\n⇅ Netzwerk ($INTERFACE): Es liegen noch nicht genügend Daten vor." | $LOLCAT
    else
        # Format: 1;iface;tag;rx;tx;total;rate;monat;rx;tx;total;rate;...
        IFS=';' read -r _ _ _ TODAY_RX TODAY_TX _ _ _ MONTH_RX MONTH_TX _ <<< "$NETWORK_USAGE"
        echo -e "\n⇅ Netzwerk ($INTERFACE):\nHeute:        ↓ ${TODAY_RX}  ↑ ${TODAY_TX}\nDieser Monat: ↓ ${MONTH_RX}  ↑ ${MONTH_TX}" | $LOLCAT
    fi
fi
echo "IP-Adresse: $(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')" | $LOLCAT

# Dienste von Pterodactyl
STATUS_LINE=""
for svc in nginx pteroq wings; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 && systemctl cat "${svc}.service" >/dev/null 2>&1; then
        if systemctl is-active --quiet "$svc"; then STATUS_LINE+="✔ $svc  "; else STATUS_LINE+="✖ $svc  "; fi
    fi
done
[ -n "$STATUS_LINE" ] && echo -e "\n❖ Dienste: $STATUS_LINE" | $LOLCAT

# Letzter erfolgreicher Login (vor der aktuellen Sitzung)
LAST_LOGIN="$(last -i -n 2 -w 2>/dev/null | sed -n '2p')"
if [ -n "$LAST_LOGIN" ] && [[ "$LAST_LOGIN" != wtmp* ]]; then
    read -r L_USER _ L_IP L_REST <<< "$LAST_LOGIN"
    echo -e "\n✱ Vorheriger Login: $L_USER von $L_IP ($(awk '{print $1, $2, $3, $4}' <<< "$L_REST"))" | $LOLCAT
fi

# Trenner
printf '%*s\n' "${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}" '' | tr ' ' '-' | $LOLCAT
echo ""

# Das Skript ist ein Teil von GermanDactyl Setup und zeigt eine Übersicht über den Server.
# Du darfst es für private Zwecke nach Belieben anpassen.
