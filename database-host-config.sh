#!/bin/bash
# Pfad: database-host-config.sh
# Database-Host für Pterodactyl einrichten, damit Gameserver eigene MySQL-Datenbanken erhalten können.

# Gemeinsame Bibliotheken laden (vom Hauptskript übergeben, lokal oder aus dem Repository)
_gd_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "${GD_LIB_DIR:-}" ] && [ -f "$_gd_dir/lib/common.sh" ]; then GD_LIB_DIR="$_gd_dir/lib"; GD_LOCAL_DIR="$_gd_dir"; fi
if [ -n "${GD_LIB_DIR:-}" ] && [ -f "$GD_LIB_DIR/common.sh" ]; then
    . "$GD_LIB_DIR/common.sh"
else
    _gd_c="$(mktemp)"
    curl -fsSL "https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/${GD_BRANCH:-main}/lib/common.sh" -o "$_gd_c" \
        || { echo "Die Bibliothek lib/common.sh konnte nicht geladen werden."; exit 1; }
    . "$_gd_c"; rm -f "$_gd_c"
fi
gd_require_root

MARIADB_CONF="/etc/mysql/mariadb.conf.d/99-germandactyl.cnf"

if ! gd_yesno "⚠️ Sicherheitshinweis" "Mit diesem Skript wird ein Database-Host eingerichtet. Dafür wird MariaDB für Verbindungen von außen geöffnet, damit deine Gameserver ihre Datenbanken erreichen können.\n\nDen direkten Zugriff schützt dann nur noch das Passwort. Deshalb wird ein zufälliges Passwort mit 64 Zeichen erzeugt, und die Firewall lässt Verbindungen standardmäßig nur von diesem Server und seinen Gameservern zu.\n\nMöchtest du fortfahren?" 17 78; then
    exit 0
fi

command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1 || {
    gd_msg "MariaDB fehlt" "Auf diesem Server ist kein MariaDB/MySQL installiert." 8 60
    exit 1
}

IP_ADDRESS="$(gd_public_ip)"
if [ -z "$IP_ADDRESS" ]; then
    gd_msg "Fehler" "Die öffentliche IP-Adresse dieses Servers konnte nicht ermittelt werden." 8 70
    exit 1
fi

USERNAME="gd_dbhost_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"
PASSWORD="$(gd_gen_password 64)"

OPEN_WORLD=false
if whiptail --title "🌍 Zugriff aus dem Internet?" --defaultno --yesno "Sollen sich auch externe Programme (z. B. dein PC mit HeidiSQL) direkt mit den Gameserver-Datenbanken verbinden können?\n\n'Nein' (empfohlen): Nur dieser Server und seine Gameserver haben Zugriff.\n'Ja': Port 3306 wird für das gesamte Internet geöffnet." 14 78; then
    OPEN_WORLD=true
fi

clear
echo "### Database-Host wird eingerichtet ###"

# Benutzer für das Panel (verbindet sich über die öffentliche IP)
if ! gd_mysql <<SQL >> "$GD_LOG" 2>&1
CREATE USER '${USERNAME}'@'${IP_ADDRESS}' IDENTIFIED BY '${PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${USERNAME}'@'${IP_ADDRESS}' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
then
    gd_msg "Fehler" "Der Datenbank-Benutzer konnte nicht angelegt werden. Details: $GD_LOG" 9 70
    exit 1
fi
echo "Datenbank-Benutzer ${USERNAME} wurde angelegt."

# MariaDB auf allen Schnittstellen lauschen lassen (eigene Datei, wird nicht bei jedem Lauf erneut angehängt)
mkdir -p "$(dirname "$MARIADB_CONF")"
printf '%s\n' '# Angelegt von GermanDactyl Setup (Database-Host)' '[mysqld]' 'bind-address = 0.0.0.0' > "$MARIADB_CONF"
systemctl restart mariadb 2>/dev/null || systemctl restart mysql
echo "MariaDB wurde neu gestartet."

# Firewall: nur wenn UFW aktiv ist
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    if $OPEN_WORLD; then
        ufw allow 3306/tcp comment 'MariaDB (Database-Host)' >> "$GD_LOG" 2>&1
    else
        ufw allow from "$IP_ADDRESS" to any port 3306 proto tcp comment 'MariaDB (Panel)' >> "$GD_LOG" 2>&1
        ufw allow from 172.16.0.0/12 to any port 3306 proto tcp comment 'MariaDB (Gameserver-Container)' >> "$GD_LOG" 2>&1
    fi
    echo "Firewall-Regeln für Port 3306 wurden gesetzt."
fi

gd_msg "🎉 Database-Host angelegt" "Der Database-Host ist eingerichtet. Öffne jetzt in deinem Panel: Admin → Databases → Create New.\n\nIm nächsten Fenster siehst du die Daten, die du dort eintragen musst." 12 78
gd_msg "🔐 Zugangsdaten des Database-Hosts" "Name:          frei wählbar, z. B. Hauptdatenbank\nHost:          ${IP_ADDRESS}\nPort:          3306\nBenutzername:  ${USERNAME}\nPasswort:      wird im nächsten Schritt angezeigt\nLinked Node:   deine Node auswählen\n\nDrücke Enter, um das Passwort anzuzeigen." 16 78

clear
echo ""
echo "PASSWORT - - - - - - - - - - - - - - -"
echo ""
echo "Passwort zum Kopieren:"
echo ""
echo "$PASSWORD"
echo ""
echo "Trage es im Panel ein und drücke ERST DANN die Taste Enter."
read -r _ < /dev/tty

if gd_yesno "✅ Einrichtung prüfen" "Konnte der Database-Host im Panel erfolgreich angelegt werden?" 9 70; then
    gd_msg "🎊 Erfolg" "Super! Der Database-Host ist eingerichtet. Deine Gameserver können jetzt im Reiter 'Databases' eigene Datenbanken anlegen." 10 70
else
    gd_mysql -e "DROP USER IF EXISTS '${USERNAME}'@'${IP_ADDRESS}'; FLUSH PRIVILEGES;" >> "$GD_LOG" 2>&1
    gd_msg "Vorgang zurückgesetzt" "Der Datenbank-Benutzer wurde aus Sicherheitsgründen wieder gelöscht. Prüfe deine Eingaben auf Schreibfehler und versuche es erneut." 10 74
fi
