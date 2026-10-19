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
    [ "$UPDATE_COUNT" -eq 1 ] && UPD_WORD="liegt 1 Update" || UPD_WORD="liegen $UPDATE_COUNT Updates"
    echo -e "\n▤ Es ${UPD_WORD} vor, darunter Updates für Docker.\nInstalliere sie bei Gelegenheit – dabei werden alle Gameserver kurz neu gestartet." | $LOLCAT
elif [ "$UPDATE_COUNT" -gt 0 ]; then
    if [ "$UPDATE_COUNT" -eq 1 ]; then
        UPDATE_TEXT="Es liegt 1 Update vor. Du kannst es bei Gelegenheit installieren."
    else
        UPDATE_TEXT="Es liegen $UPDATE_COUNT Updates vor. Du kannst sie bei Gelegenheit installieren."
    fi
    echo -e "\n▤ ${UPDATE_TEXT}" | $LOLCAT
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

# Automatische Backups und Updates: Die Ergebnisse stehen in setup.conf (nur für root lesbar, bei anderen Benutzern entfällt der Block).
# Die Datei besteht aus Zeilen SCHLÜSSEL=Wert (mit printf %q geschrieben) und wird deshalb in einer Subshell eingelesen.
GD_CONF="/etc/germandactyl/setup.conf"
# shellcheck disable=SC1090
conf_get() { ( . "$GD_CONF" 2>/dev/null; eval "printf '%s' \"\${$1:-}\"" ); }
fmt_time() { date -d "$1" '+%d.%m.%Y %H:%M' 2>/dev/null || echo "$1"; }
if [ -r "$GD_CONF" ]; then
    AUTO_TEXT=""
    # Backup (AUTO_BACKUP_LAST_RESULT = ok|fehler, AUTO_BACKUP_LAST_RUN = Zeitpunkt des letzten Laufs, AUTO_BACKUP_LAST_OK = letzter Erfolg)
    if systemctl cat germandactyl-backup.timer >/dev/null 2>&1; then
        BK_RESULT="$(conf_get AUTO_BACKUP_LAST_RESULT)"; BK_RUN="$(conf_get AUTO_BACKUP_LAST_RUN)"; BK_OK="$(conf_get AUTO_BACKUP_LAST_OK)"
        BK_AGE=0
        [ -n "$BK_OK" ] && BK_AGE=$(( ($(date +%s) - $(date -d "$BK_OK" +%s 2>/dev/null || date +%s)) / 3600 ))
        if [ "$BK_RESULT" = "fehler" ]; then
            AUTO_TEXT+="✖ Das letzte automatische Backup ist fehlgeschlagen${BK_RUN:+ ($(fmt_time "$BK_RUN"))}${BK_OK:+, letzter Erfolg: $(fmt_time "$BK_OK")}. Log: /var/log/germandactyl-setup/auto-backup.log"$'\n'
        elif [ -z "$BK_OK" ]; then
            AUTO_TEXT+="⚠ Automatische Backups sind eingerichtet, es gibt aber noch kein erfolgreiches Backup."$'\n'
        elif [ "$BK_AGE" -gt 48 ]; then
            AUTO_TEXT+="⚠ Das letzte erfolgreiche automatische Backup ist $BK_AGE Stunden alt ($(fmt_time "$BK_OK"))."$'\n'
        else
            AUTO_TEXT+="✔ Letztes automatisches Backup: $(fmt_time "$BK_OK")"$'\n'
        fi
    fi
    # Geplante Updates von Panel und Wings (LAST_UPDATE_* bzw. LAST_WINGS_UPDATE_*: ok|fehler|uebersprungen)
    AU_ON=false
    systemctl is-enabled --quiet germandactyl-update.timer 2>/dev/null && AU_ON=true
    for UP in "LAST_UPDATE:Panel" "LAST_WINGS_UPDATE:Wings"; do
        UP_RESULT="$(conf_get "${UP%%:*}_RESULT")"; UP_TIME="$(conf_get "${UP%%:*}_TIME")"; UP_NOTE="$(conf_get "${UP%%:*}_NOTE")"
        case "$UP_RESULT" in
            fehler)
                AUTO_TEXT+="✖ ${UP#*:}-Update fehlgeschlagen${UP_TIME:+ ($(fmt_time "$UP_TIME"))}${UP_NOTE:+: $UP_NOTE}"$'\n'
                if [ "${UP%%:*}" = "LAST_UPDATE" ]; then
                    UP_BACKUP="$(conf_get LAST_UPDATE_BACKUP)"
                    AUTO_TEXT+="  Sicherung: ${UP_BACKUP:-keine}, Log: /var/log/germandactyl-setup/auto-update.log"$'\n'
                fi ;;
            uebersprungen)
                AUTO_TEXT+="⚠ ${UP#*:}-Update übersprungen${UP_TIME:+ ($(fmt_time "$UP_TIME"))}${UP_NOTE:+: $UP_NOTE}"$'\n' ;;
            ok)
                $AU_ON && AUTO_TEXT+="✔ Letztes automatisches ${UP#*:}-Update: $(fmt_time "$UP_TIME")${UP_NOTE:+ ($UP_NOTE)}"$'\n' ;;
        esac
    done
    [ -n "$AUTO_TEXT" ] && printf '\n◷ Automatik:\n%s\n' "${AUTO_TEXT%$'\n'}" | $LOLCAT
fi

# Hinweis auf die Verwaltung (Kurzbefehl)
if [ -L /usr/local/bin/gmd ] || [ -x /usr/local/bin/gmd ]; then
    echo -e "\n▸ Verwaltung: gmd" | $LOLCAT
elif [ -x /usr/local/bin/germandactyl ]; then
    echo -e "\n▸ Verwaltung: germandactyl" | $LOLCAT
fi

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
