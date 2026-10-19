#!/bin/bash
# Pfad: database-host-config.sh
# Database-Host für Pterodactyl einrichten, damit Gameserver eigene MySQL-Datenbanken erhalten können.
# Liegt das Panel auf diesem Server, wird der Host direkt im Panel angelegt (Panel-Dienst über tinker). Gelingt das
# nicht, bleibt die manuelle Einrichtung im Panel (Admin → Databases → Create New).

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
# gd_panel_sql und gd_panel_env (Datenbankzugriff auf das Panel)
gd_source_lib wings

MARIADB_CONF="/etc/mysql/mariadb.conf.d/99-germandactyl.cnf"
# MySQL (z. B. Ubuntu mysql-server) liest mariadb.conf.d nicht ein
if [ ! -d /etc/mysql/mariadb.conf.d ] && [ -d /etc/mysql/mysql.conf.d ]; then
    MARIADB_CONF="/etc/mysql/mysql.conf.d/zz-germandactyl.cnf"
fi

if ! gd_yesno "⚠ Sicherheitshinweis" "Mit diesem Skript wird ein Database-Host eingerichtet. Dafür wird MariaDB für Verbindungen von außen geöffnet, damit deine Gameserver ihre Datenbanken erreichen können.\n\nDen direkten Zugriff schützt dann nur noch das Passwort. Deshalb wird ein zufälliges Passwort mit 64 Zeichen erzeugt, und die Firewall lässt Verbindungen standardmäßig nur von diesem Server und seinen Gameservern zu.\n\nMöchtest du fortfahren?" 17 78; then
    exit 0
fi

command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1 || {
    gd_msg "MariaDB fehlt" "Auf diesem Server ist kein MariaDB/MySQL installiert." 8 60
    exit 1
}

# Adresse, unter der Panel und Gameserver die Datenbank erreichen. Hinter NAT (nur private IP am Server)
# wird die lokale IP genutzt, da Verbindungen über die öffentliche IP dort meist nicht zurückkommen.
IP_ADDRESS="$(gd_local_ip)"
if [ -z "$IP_ADDRESS" ] || ! gd_is_private_ip "$IP_ADDRESS"; then
    IP_ADDRESS="$(gd_public_ip)"
fi
if [ -z "$IP_ADDRESS" ]; then
    gd_msg "Fehler" "Die IP-Adresse dieses Servers konnte nicht ermittelt werden." 8 70
    exit 1
fi
# Die IP landet unten in SQL und im PHP-Code: nur gültige IP-Zeichen zulassen
if ! [[ "$IP_ADDRESS" =~ ^[0-9A-Fa-f.:]{1,45}$ ]]; then
    gd_msg "Fehler" "Die IP-Adresse dieses Servers ist ungültig: ${IP_ADDRESS}" 8 70
    exit 1
fi

HAS_PANEL=false
[ -f "$PTERO_DIR/artisan" ] && HAS_PANEL=true
NODE_ID=""

# Vorprüfung VOR dem Anlegen des Datenbank-Benutzers: Gibt es für diese Adresse schon einen Database-Host im Panel,
# wird nichts Neues angelegt. (Der Benutzername wird bei jedem Lauf neu zufällig erzeugt, deshalb nur nach der Adresse
# geprüft.) Außerdem die erste Node ermitteln, der der Host zugeordnet wird.
if $HAS_PANEL; then
    EXISTING="$(gd_panel_sql "SELECT COUNT(*) FROM database_hosts WHERE host='${IP_ADDRESS}';" 2>/dev/null | head -n1)"
    if [[ "$EXISTING" =~ ^[1-9][0-9]*$ ]]; then
        gd_msg "Database-Host vorhanden" "Im Panel gibt es bereits einen Database-Host für ${IP_ADDRESS}. Es wurde nichts Neues angelegt.\n\nDie vorhandenen Hosts findest du im Panel unter Admin → Databases." 12 74
        exit 0
    fi
    NODE_ID="$(gd_panel_sql "SELECT id FROM nodes ORDER BY id LIMIT 1;" 2>/dev/null | head -n1)"
    [[ "$NODE_ID" =~ ^[0-9]+$ ]] || NODE_ID=""
fi

USERNAME="gd_dbhost_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"
PASSWORD="$(gd_gen_password 64)"

# Bewusst gesetzte bind-address (z. B. eine private IP) nicht stillschweigend auf 0.0.0.0 erweitern
CUR_BIND="$(my_print_defaults mysqld mariadbd 2>/dev/null | grep -- '--bind-address' | tail -n1 | cut -d= -f2)"
if [ -n "$CUR_BIND" ] && ! grep -qxE '127\.0\.0\.1|localhost|0\.0\.0\.0|::|\*' <<< "$CUR_BIND" && [ ! -f "$MARIADB_CONF" ]; then
    gd_yesno "Eigene bind-address" "MariaDB lauscht bereits gezielt auf ${CUR_BIND}. Für einen Database-Host muss sie auf allen Schnittstellen (0.0.0.0) erreichbar sein.\n\nSoll das geändert werden?" 12 74 || exit 0
fi

OPEN_WORLD=false
if whiptail --title "⌂ Zugriff aus dem Internet?" --defaultno --yesno "Sollen sich auch externe Programme (z. B. dein PC mit HeidiSQL) direkt mit den Gameserver-Datenbanken verbinden können?\n\n'Nein' (empfohlen): Nur dieser Server und seine Gameserver haben Zugriff.\n'Ja': Port 3306 wird für das gesamte Internet geöffnet." 14 78; then
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
if ! { systemctl restart mariadb 2>/dev/null || systemctl restart mysql; }; then
    # Startet die Datenbank nicht mehr, wäre auch das Panel offline – Änderung zurücknehmen
    rm -f "$MARIADB_CONF"
    systemctl restart mariadb 2>/dev/null || systemctl restart mysql
    gd_mysql -e "DROP USER IF EXISTS '${USERNAME}'@'${IP_ADDRESS}';" >> "$GD_LOG" 2>&1
    gd_msg "✖ Fehler" "MariaDB ließ sich mit der neuen Einstellung nicht starten. Die Änderung wurde zurückgenommen.\n\nDetails: journalctl -u mariadb -n 50" 11 74
    exit 1
fi
echo "MariaDB wurde neu gestartet."

# Firewall: nur wenn UFW aktiv ist
if gd_ufw_active; then
    if $OPEN_WORLD; then
        ufw allow 3306/tcp comment 'MariaDB (Database-Host)' >> "$GD_LOG" 2>&1
    else
        ufw allow from "$IP_ADDRESS" to any port 3306 proto tcp comment 'MariaDB (Panel)' >> "$GD_LOG" 2>&1
        # Nur das Docker-Netz von Wings (config.yml, Standard 172.18.0.0/16) freigeben, nicht den ganzen Bereich 172.16.0.0/12
        DOCKER_SUBNET="$(awk '/v4:/{f=1} f && $1=="subnet:" {print $2; exit}' /etc/pterodactyl/config.yml 2>/dev/null | tr -d "'\"")"
        [[ "$DOCKER_SUBNET" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || DOCKER_SUBNET="172.18.0.0/16"
        ufw allow from "$DOCKER_SUBNET" to any port 3306 proto tcp comment 'MariaDB (Gameserver-Container)' >> "$GD_LOG" 2>&1
    fi
    echo "Firewall-Regeln für Port 3306 wurden gesetzt."
elif ! $OPEN_WORLD; then
    gd_msg "⚠ Firewall ist aus" "Die Firewall (UFW) ist nicht aktiv. Port 3306 ist damit aus dem ganzen Internet erreichbar, auch wenn du 'Nein' gewählt hast – geschützt nur durch das 64-stellige Passwort.\n\nEmpfehlung: Schalte die Firewall in der Verwaltung unter 'Server & Sicherheit → Firewall' ein und führe dieses Skript danach erneut aus." 14 78
fi

# Den Host im Panel anlegen (über den Panel-Dienst; prüft die Verbindung selbst und verschlüsselt das Passwort).
# Das Passwort geht nur über die Umgebungsvariable, nicht als Argument – so sieht es niemand in der Prozessliste.
PANEL_OK=false
if $HAS_PANEL; then
    echo "Database-Host wird im Panel angelegt..."
    OUT="$(GD_DBH_PW="$PASSWORD" gd_artisan_www tinker --execute="app(\\Pterodactyl\\Services\\Databases\\Hosts\\HostCreationService::class)->handle(['name' => 'Hauptdatenbank', 'host' => '${IP_ADDRESS}', 'port' => 3306, 'username' => '${USERNAME}', 'password' => getenv('GD_DBH_PW'), 'node_id' => ${NODE_ID:-null}]); echo 'GD_DBH_OK';" 2>&1)"
    # Ausgabe ins Log – das Passwort wird dabei unkenntlich gemacht
    { echo "[$(date '+%F %T')] Database-Host im Panel anlegen (tinker), Ausgabe:"; printf '%s\n' "${OUT//$PASSWORD/***}" | tail -n 20 | cut -c1-300; } >> "$GD_LOG"
    grep -q 'GD_DBH_OK' <<< "$OUT" && PANEL_OK=true
fi

if $PANEL_OK; then
    # Firewall-Freigaben für alle Nodes setzen und den nächtlichen Abgleich einrichten (Timer germandactyl-dbhost)
    gd_source_lib dbhost
    gd_dbhost_sync_firewall
    gd_dbhost_timer_install >> "$GD_LOG" 2>&1
    gd_msg "★ Database-Host angelegt" "Der Database-Host wurde im Panel eingetragen (Name: Hauptdatenbank, Host: ${IP_ADDRESS}, Node: ${NODE_ID:-keine}). Deine Gameserver können jetzt im Reiter 'Databases' eigene Datenbanken anlegen." 12 78
    exit 0
fi

# Rückfall: manuelle Einrichtung im Panel
if $HAS_PANEL; then
    ERR_TEXT="$(printf '%s\n' "$OUT" | grep -v '^[[:space:]]*$' | head -n 2 | cut -c1-200 | tr -d '\\')"
    gd_msg "✖ Automatisch nicht möglich" "Der Database-Host konnte nicht automatisch im Panel angelegt werden. Details stehen im Log: $GD_LOG\n\n${ERR_TEXT:-Das Panel hat keine Ausgabe geliefert.}\n\nDu richtest ihn deshalb von Hand ein." 14 78
fi
gd_msg "Database-Host von Hand anlegen" "Öffne in deinem Panel: Admin → Databases → Create New.\n\nIm nächsten Fenster siehst du die Daten, die du dort eintragen musst." 10 78
gd_msg_secret "✱ Zugangsdaten des Database-Hosts" "Name:          frei wählbar, z. B. Hauptdatenbank\nHost:          ${IP_ADDRESS}\nPort:          3306\nBenutzername:  ${USERNAME}\nPasswort:      ${PASSWORD}\nLinked Node:   deine Node auswählen" 16 78
# Download-Link nur mit Panel: Die Datei wird über die Domain des Panels ausgeliefert
if $HAS_PANEL; then
    gd_source_lib download
    gd_download_offer "Database-Host-Zugangsdaten" "Name: Hauptdatenbank (frei wählbar)\nHost: ${IP_ADDRESS}\nPort: 3306\nBenutzername: ${USERNAME}\nPasswort: ${PASSWORD}\nLinked Node: deine Node auswählen"
fi

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

if gd_yesno "✔ Einrichtung prüfen" "Konnte der Database-Host im Panel erfolgreich angelegt werden?" 9 70; then
    if $HAS_PANEL; then
        gd_source_lib dbhost
        gd_dbhost_sync_firewall
        gd_dbhost_timer_install >> "$GD_LOG" 2>&1
    fi
    gd_msg "★ Erfolg" "Super! Der Database-Host ist eingerichtet. Deine Gameserver können jetzt im Reiter 'Databases' eigene Datenbanken anlegen." 10 70
else
    gd_mysql -e "DROP USER IF EXISTS '${USERNAME}'@'${IP_ADDRESS}'; FLUSH PRIVILEGES;" >> "$GD_LOG" 2>&1
    # Gibt es keinen weiteren Database-Host, MariaDB wieder nur lokal lauschen lassen
    if [ "$(gd_mysql -N -e "SELECT COUNT(*) FROM mysql.user WHERE User LIKE 'gd\\_dbhost\\_%';" 2>/dev/null)" = "0" ]; then
        rm -f "$MARIADB_CONF"
        systemctl restart mariadb 2>/dev/null || systemctl restart mysql
    fi
    gd_msg "Vorgang zurückgesetzt" "Der Datenbank-Benutzer wurde aus Sicherheitsgründen wieder gelöscht und MariaDB ist wieder nur lokal erreichbar. Prüfe deine Eingaben auf Schreibfehler und versuche es erneut." 10 74
fi
