#!/bin/bash
# Pfad: installer.sh
# GermanDactyl Setup – Einstieg für Installation und Verwaltung von Pterodactyl (inkl. Wings und GermanDactyl)
# Start: sudo bash -c "$(curl -sSL https://setup.germandactyl.de/)"
#
# Das Skript ist eigenständig: Panel und Wings werden nach der offiziellen Dokumentation selbst eingerichtet,
# es werden keine fremden Installationsskripte mehr ausgeführt.

# Das Skript ist nur für Systeme mit apt vorgesehen
if ! command -v apt-get >/dev/null 2>&1; then
    echo "Abbruch: Für dein System ist dieses Skript nicht vorgesehen. Unterstützt werden Debian und Ubuntu."
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    echo "Abgebrochen: Für dieses Skript werden Root-Rechte benötigt. Starte es mit 'sudo' oder als root."
    echo "Falls du nicht der Administrator des Servers bist, bitte ihn, dir temporär Zugriff zu erteilen."
    exit 1
fi

# ---------------------------------------------------------------------------
# Bibliotheken laden: aus einem lokalen Checkout oder aus dem Repository
# ---------------------------------------------------------------------------
GD_LIBS=(common germandactyl security panel wings blueprint backup autobackup uninstall)
_gd_self="${BASH_SOURCE[0]:-}"
if [ -n "$_gd_self" ] && [ -f "$_gd_self" ] && [ -f "$(dirname "$_gd_self")/lib/common.sh" ]; then
    GD_LOCAL_DIR="$(cd "$(dirname "$_gd_self")" && pwd)"
    GD_LIB_DIR="$GD_LOCAL_DIR/lib"
else
    GD_LOCAL_DIR=""
    GD_LIB_DIR="$(mktemp -d /tmp/germandactyl-lib.XXXXXX)"
    trap 'rm -rf "$GD_LIB_DIR"' EXIT
    for _gd_lib in "${GD_LIBS[@]}"; do
        if ! curl -fsSL "https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/${GD_BRANCH:-main}/lib/${_gd_lib}.sh" \
            -o "$GD_LIB_DIR/${_gd_lib}.sh"; then
            echo "Abbruch: Die Datei lib/${_gd_lib}.sh konnte nicht geladen werden. Prüfe die Internetverbindung."
            exit 1
        fi
    done
fi
export GD_LOCAL_DIR GD_LIB_DIR
for _gd_lib in "${GD_LIBS[@]}"; do
    # shellcheck disable=SC1090
    . "$GD_LIB_DIR/${_gd_lib}.sh"
done
# Temporäre Dateien und heruntergeladene Bibliotheken beim Beenden entfernen
trap 'rm -rf "$GD_TMP"; [ -z "$GD_LOCAL_DIR" ] && rm -rf "$GD_LIB_DIR"' EXIT

# ---------------------------------------------------------------------------
# Vorbereitung
# ---------------------------------------------------------------------------
gd_spinner() {
    # gd_spinner <pid> "Text" – einfache Ladeanimation, solange der Prozess läuft
    local pid="$1" msg="$2" chars='|/-\' i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r [%c]  %s' "${chars:i++%4:1}" "$msg"
        sleep 0.3
    done
    printf '\r%*s\r' $((${#msg} + 8)) ''
}

gd_prepare_system() {
    gd_status "Vorbereitung: Benötigte Grundpakete werden installiert..."
    (
        dpkg --configure -a
        gd_apt update && gd_apt_install whiptail curl dnsutils ca-certificates gnupg lsb-release jq iproute2 psmisc tar
    ) >> "$GD_LOG" 2>&1 &
    local pid=$!
    gd_spinner "$pid" "Grundpakete werden installiert..."
    if ! wait "$pid"; then
        echo ""
        echo "Ein Fehler ist während der Vorbereitung aufgetreten. Mögliche Ursachen:"
        echo " - Fehlerhafte Paketquellen in apt (prüfe mit 'apt-get update')"
        echo " - Im Hintergrund läuft bereits ein Installations- oder Updateprozess"
        echo "Details findest du im Log: $GD_LOG"
        exit 1
    fi
}

gd_check_environment() {
    # Betriebssystem
    if ! gd_os_supported; then
        gd_warn_colors_on
        if ! gd_yesno "Nicht getestetes Betriebssystem" "Dein System ($GD_OS_NAME) wurde mit diesem Skript nicht getestet.\n\nGetestet sind: Debian 11, 12, 13 und Ubuntu 22.04, 24.04, 26.04.\n\nMöchtest du trotzdem fortfahren?" 14 70; then
            gd_warn_colors_off
            clear; echo "Die Installation wurde abgebrochen."; exit 0
        fi
        gd_warn_colors_off
    fi

    # CPU-Architektur: Pterodactyl unterstützt amd64 und arm64
    case "$(gd_arch)" in
        amd64) ;;
        arm64)
            gd_msg "Hinweis zur CPU-Architektur" "Dein Server nutzt eine ARM64-CPU. Panel und Wings laufen darauf, aber viele Gameserver-Images (Eggs) gibt es nur für amd64. Prüfe vor dem Erstellen eines Servers, ob das jeweilige Image ARM64 unterstützt." 12 74 ;;
        *)
            gd_msg "Nicht unterstützte CPU-Architektur" "Die CPU-Architektur '$(uname -m)' wird von Pterodactyl nicht unterstützt (nur amd64 und arm64). Die Installation wird abgebrochen." 10 70
            clear; exit 1 ;;
    esac

    # Heimnetz / NAT
    local local_ip
    local_ip="$(gd_local_ip)"
    if [ -n "$local_ip" ] && gd_is_private_ip "$local_ip"; then
        gd_warn_colors_on
        if ! gd_yesno "Lokales Netzwerk erkannt" "Dieser Server hat nur eine private IP-Adresse ($local_ip). Das ist der Fall, wenn er in deinem Heimnetz oder hinter NAT läuft.\n\nDamit Panel, Zertifikat und Gameserver von außen erreichbar sind, müssen die Ports 80, 443, 8080, 2022 und die Gameserver-Ports in deinem Router weitergeleitet werden. Dabei können wir dir leider nicht helfen.\n\nSystem: $(hostname) ($GD_OS_NAME)\n\nMöchtest du fortfahren?" 18 78; then
            gd_warn_colors_off
            clear; echo "Die Installation wurde abgebrochen."; exit 0
        fi
        gd_warn_colors_off
    fi
}

# ---------------------------------------------------------------------------
# Neuinstallation
# ---------------------------------------------------------------------------
gd_show_credentials() {
    whiptail --title "🔑 Deine Zugangsdaten" --msgbox "Speichere dir diese Zugangsdaten jetzt ab. Dieses Fenster wird nicht noch einmal angezeigt.\n\nPanel:          https://${GD_DOMAIN}\nBenutzername:   ${GD_ADMIN_USER}\nE-Mail-Adresse: ${GD_EMAIL}\nPasswort:       ${GD_ADMIN_PASSWORD}\n\nDu kannst das Passwort nach dem ersten Login in den Kontoeinstellungen ändern." 18 78
}

gd_save_credentials() {
    local file="/root/germandactyl-zugangsdaten.txt"
    umask 077
    cat > "$file" <<EOF
GermanDactyl Setup – Zugangsdaten ($(date '+%d.%m.%Y %H:%M'))
Panel:          https://${GD_DOMAIN}
Benutzername:   ${GD_ADMIN_USER}
E-Mail-Adresse: ${GD_EMAIL}
Passwort:       ${GD_ADMIN_PASSWORD}
$( [ "$GD_SEC_BACKUP" = true ] && [ -s "$GD_AB_PASS" ] && echo "Backup-Passwort: $(cat "$GD_AB_PASS")")

Lösche diese Datei, sobald du die Zugangsdaten sicher abgelegt hast:
rm ${file}
EOF
    chmod 600 "$file"
    umask 022
}

gd_fresh_install() {
    local mode="$1"   # panel_wings | panel
    local with_wings=false
    [ "$mode" = "panel_wings" ] && with_wings=true

    # --- Eingaben -------------------------------------------------------------
    GD_DOMAIN="$(gd_ask_domain "🌐 Domain für das Panel" "Gib die Domain (FQDN) ein, unter der das Panel erreichbar sein soll, z. B. panel.deinedomain.de.\n\nDer DNS-Eintrag (A-Eintrag) muss bereits auf diesen Server zeigen, das wird im nächsten Schritt geprüft.")" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }

    GD_EMAIL="$(gd_ask_email "📧 E-Mail-Adresse" "Gib deine E-Mail-Adresse ein. Sie wird für das SSL-Zertifikat (Let's Encrypt) und dein Administrator-Konto verwendet.\n\nMit der Eingabe stimmst du den Nutzungsbedingungen von Let's Encrypt zu:\nhttps://letsencrypt.org/repository/")" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }

    while true; do
        GD_ADMIN_USER="$(gd_input "👤 Benutzername" "Wähle einen Benutzernamen für dein Administrator-Konto (nur Buchstaben, Zahlen, Punkt, Binde- und Unterstrich):" "admin" 11 70)" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }
        [[ "$GD_ADMIN_USER" =~ ^[A-Za-z0-9._-]{3,191}$ ]] && break
        gd_msg "Ungültiger Benutzername" "Der Benutzername muss mindestens 3 Zeichen lang sein und darf nur Buchstaben, Zahlen, Punkt, Binde- und Unterstrich enthalten." 10 70
    done

    GD_TELEMETRY=false
    if gd_yesno "📊 Anonyme Telemetrie" "Pterodactyl kann anonyme Nutzungsdaten (z. B. Versionen und Anzahl der Server, keine persönlichen Daten) an die Entwickler senden. Das hilft bei der Weiterentwicklung.\n\nMöchtest du die anonyme Telemetrie aktivieren?" 13 74; then
        GD_TELEMETRY=true
    fi

    gd_choose_panel_version || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }

    if $with_wings; then
        GD_WINGS_FQDN="$GD_DOMAIN"
        if ! gd_yesno "🐦 Domain für Wings" "Wings (die Verbindung zu deinen Gameservern) nutzt standardmäßig dieselbe Domain wie das Panel:\n\n${GD_DOMAIN} (Port 8080)\n\nDas ist die einfachste Variante. Möchtest du diese Domain verwenden?\n\nBei 'Nein' kannst du eine eigene Subdomain angeben (z. B. node1.deinedomain.de)." 15 76; then
            GD_WINGS_FQDN="$(gd_ask_domain "🐦 Domain für Wings" "Gib die Domain für Wings ein, z. B. node1.deinedomain.de. Sie muss ebenfalls auf diesen Server zeigen.")" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }
        fi
        while true; do
            GD_PORT_RANGE="$(gd_input "🎮 Ports für Gameserver" "Welche Ports sollen für Gameserver freigegeben werden?\n\nFormat: Start-Ende, z. B. 25565-25600 (höchstens 1000 Ports, jeweils größer als 1024). Du kannst später im Panel weitere Ports hinzufügen." "$GD_DEFAULT_PORT_RANGE" 14 74)" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }
            gd_valid_port_range "$GD_PORT_RANGE" && break
            gd_msg "Ungültiger Portbereich" "Bitte gib einen Bereich wie 25565-25600 an (größer als 1024, höchstens 65535, maximal 1000 Ports)." 10 70
        done
    fi

    gd_security_ask
    gd_blueprint_ask

    # Reste einer früheren Installation in der Datenbank?
    if command -v mariadb >/dev/null 2>&1 && gd_panel_db_has_tables; then
        gd_warn_colors_on
        if gd_yesno "Alte Panel-Datenbank gefunden" "Es existiert bereits eine Datenbank '${GD_PANEL_DB}' mit Tabellen, vermutlich von einer früheren Installation.\n\nSoll sie gelöscht werden? Bei 'Nein' wird die Installation abgebrochen, damit keine Daten verloren gehen." 14 74; then
            gd_mysql -e "DROP DATABASE \`${GD_PANEL_DB}\`;" >> "$GD_LOG" 2>&1
        else
            gd_warn_colors_off
            clear; echo "Die Installation wurde abgebrochen."; exit 0
        fi
        gd_warn_colors_off
    fi

    # --- Zusammenfassung ------------------------------------------------------
    local summary
    summary="Panel:         https://${GD_DOMAIN}\nVersion:       v${GD_PANEL_VERSION} $( [ "$GD_APPLY_PATCH" = "true" ] && echo '(Deutsch, GermanDactyl)' || echo '(Englisch)')\nE-Mail:        ${GD_EMAIL}\nBenutzername:  ${GD_ADMIN_USER}\nTelemetrie:    $( $GD_TELEMETRY && echo an || echo aus)\n"
    if $with_wings; then
        summary+="Wings:         https://${GD_WINGS_FQDN}:8080 (automatisch verbunden)\nGameserver:    Ports ${GD_PORT_RANGE}\n"
    fi
    summary+="Firewall:      $( [ "$GD_SEC_UFW" = true ] && echo an || echo aus)   fail2ban: $( [ "$GD_SEC_FAIL2BAN" = true ] && echo an || echo aus)   Auto-Updates: $( [ "$GD_SEC_UPDATES" = true ] && echo an || echo aus)\n"
    summary+="Backups:       $( [ "$GD_SEC_BACKUP" = true ] && echo 'täglich 04:00 Uhr, inkrementell' || echo aus)\n"
    summary+="Blueprint:     $( [ "${GD_BLUEPRINT:-false}" = true ] && echo 'wird installiert' || echo 'nein')"
    if ! whiptail --title "📋 Zusammenfassung" --yesno "Bitte prüfe deine Angaben:\n\n${summary}\n\nDie Installation dauert je nach Server 5 bis 20 Minuten. Soll sie jetzt starten?" 22 80; then
        clear; echo "Die Installation wurde abgebrochen."; exit 0
    fi

    # --- Installation ---------------------------------------------------------
    GD_ADMIN_PASSWORD="$(gd_gen_password 24)"
    GD_DB_PASSWORD="$(gd_gen_password 48)"
    gd_log "Installation gestartet: mode=$mode domain=$GD_DOMAIN version=$GD_PANEL_VERSION patch=$GD_APPLY_PATCH"

    gd_gauge_open "🚀 Pterodactyl wird installiert" "Installation wird vorbereitet..."
    gd_panel_install_steps
    if $with_wings; then
        gd_wings_local_steps 72
    fi
    gd_security_steps 91 "$with_wings" "${GD_PORT_RANGE:-}"
    gd_progress 100 "Installation abgeschlossen."
    gd_gauge_close
    gd_conf_set INSTALL_STATE fertig

    # --- Abschluss ------------------------------------------------------------
    gd_show_credentials
    if [ "$GD_SEC_BACKUP" = true ] && [ -s "$GD_AB_PASS" ]; then
        gd_msg "🔑 Passwort der Backups" "Deine täglichen Backups sind verschlüsselt. Ohne dieses Passwort können sie nicht wiederhergestellt werden, falls der Server ausfällt:\n\n$(cat "$GD_AB_PASS")\n\nSpeichere es zusammen mit deinen Zugangsdaten." 15 78
    fi
    if gd_yesno "💾 Zugangsdaten speichern?" "Sollen die Zugangsdaten zusätzlich in einer Datei gespeichert werden, die nur root lesen kann?\n\n/root/germandactyl-zugangsdaten.txt" 11 70; then
        gd_save_credentials
    fi

    local done_text
    if $with_wings; then
        done_text="Dein Panel ist einsatzbereit und Wings ist bereits verbunden. Du kannst sofort loslegen:\n\n1. Melde dich an: https://${GD_DOMAIN}\n2. Öffne 'Admin' → 'Servers' → 'Create New' und lege deinen ersten Gameserver an.\n\nFreigegebene Gameserver-Ports: ${GD_PORT_RANGE}"
    else
        done_text="Dein Panel ist einsatzbereit: https://${GD_DOMAIN}\n\nDamit du Gameserver erstellen kannst, brauchst du noch Wings. Starte dieses Skript dazu einfach erneut und wähle 'Wings installieren'."
    fi
    [ "$GD_SEC_UFW" = true ] && done_text+="\n\nDie Firewall ist aktiv. Weitere Ports gibst du mit 'ufw allow <port>' frei."
    gd_msg "✅ Installation erfolgreich" "$done_text" 20 78
    clear
    echo ""
    echo "FERTIG - - - - - - - - - - - - - - -"
    echo "Panel: https://${GD_DOMAIN}"
    echo "Log:   $GD_LOG"
    echo ""
}

gd_install_menu() {
    local choice
    if ! whiptail --title "Willkommen bei GermanDactyl Setup!" --yesno "Dieses Skript installiert das Pterodactyl Panel inklusive deutscher Übersetzung (GermanDactyl) und auf Wunsch Wings – vollautomatisch und fertig eingerichtet.\n\nDu benötigst eine Domain bzw. Subdomain, deren DNS-Eintrag auf diesen Server zeigt.\n\nMit der Bestätigung stimmst du zu, dass:\n- benötigte Pakete installiert werden dürfen\n- du den Nutzungsbedingungen von Let's Encrypt zustimmst\n- du der Besitzer der Domain bist bzw. die Berechtigung dafür hast\n- die angegebene E-Mail-Adresse deine eigene ist\n\nMöchtest du fortfahren?" 22 78; then
        clear; echo "Die Installation wurde abgebrochen."; exit 0
    fi

    choice=$(whiptail --title "Was möchtest du installieren?" --menu "Wähle aus, was auf diesem Server eingerichtet werden soll:" 17 78 4 \
        "1" "Panel + Wings (empfohlen, sofort einsatzbereit)" \
        "2" "Nur Panel (Wings läuft auf einem anderen Server)" \
        "3" "Nur Wings (Panel läuft auf einem anderen Server)" \
        "4" "Pelican Panel + Wings (Beta)" 3>&1 1>&2 2>&3) || { clear; exit 0; }

    case "$choice" in
        1) gd_fresh_install panel_wings ;;
        2) gd_fresh_install panel ;;
        3) gd_run wings-installer.sh ;;
        4) gd_run pelican-installer.sh ;;
    esac
}

# ---------------------------------------------------------------------------
# Verwaltung einer bestehenden Installation
# ---------------------------------------------------------------------------
gd_manage_menu() {
    local choice version
    while true; do
        version="$(gd_panel_installed_version)"
        choice=$(whiptail --title "Pterodactyl Verwaltung/Wartung" --menu "Pterodactyl ist bereits installiert (v${version:-?}).\nWähle eine Aktion:" 24 78 14 \
            "1"  "🔍 Problembehandlung" \
            "2"  "🔼 Panel aktualisieren" \
            "3"  "🐦 Wings installieren/verwalten" \
            "4"  "🧩 Blueprint (Erweiterungen) verwalten" \
            "5"  "📦 phpMyAdmin installieren" \
            "6"  "📂 Backup-Verwaltung" \
            "7"  "🏢 Database-Host einrichten" \
            "8"  "💻 SSH-Loginseite einrichten/entfernen" \
            "9"  "🔄 SWAP-Verwaltung" \
            "10" "🎨 Theme-Verwaltung" \
            "11" "🧹 Pterodactyl deinstallieren" \
            "12" "🚪 Skript beenden" 3>&1 1>&2 2>&3) || choice=12

        case "$choice" in
            1)  gd_run problem-verwaltung.sh ;;
            2)  gd_panel_update ;;
            3)  gd_run wings-installer.sh ;;
            4)  gd_blueprint_menu ;;
            5)  gd_run phpmyadmin-installer.sh ;;
            6)  gd_run backup-verwaltung.sh ;;
            7)  gd_run database-host-config.sh ;;
            8)  gd_run custom-ssh-login-config.sh ;;
            9)  gd_run swap-verwaltung.sh ;;
            10) gd_run theme-verwaltung.sh ;;
            11) gd_uninstall && { clear; echo "Pterodactyl wurde entfernt."; exit 0; } ;;
            12)
                clear
                echo ""
                echo "INFO - - - - - - - - - -"
                echo "Die Verwaltung wurde beendet. Starte das Skript erneut, wenn du zurückkehren möchtest."
                exit 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
clear
echo "----------------------------------"
echo "GermanDactyl Setup"
echo "Pterodactyl Panel + Wings mit deutscher Übersetzung – von Pavl21"
echo "----------------------------------"
gd_log "GermanDactyl Setup gestartet (Branch: $GD_BRANCH, lokal: ${GD_LOCAL_DIR:-nein})"

if ! command -v whiptail >/dev/null 2>&1 || ! command -v dig >/dev/null 2>&1 || [ ! -d "$PTERO_DIR" ]; then
    gd_prepare_system
fi

# Sicherheitskorrektur für ältere Installationen: Die Loginseite war früher für alle Benutzer beschreibbar (777)
if [ -f /etc/motd.sh ]; then
    chown root:root /etc/motd.sh
    chmod 755 /etc/motd.sh
fi

# Abgebrochene Installation? Dann nicht die Verwaltung eines halbfertigen Panels öffnen, sondern neu installieren.
if [ -d "$PTERO_DIR" ] && [ "$(gd_conf_get INSTALL_STATE)" = "laeuft" ]; then
    gd_warn_colors_on
    if gd_yesno "Unvollständige Installation" "Die letzte Installation wurde nicht abgeschlossen (Details im Log unter $GD_LOG_DIR).\n\nSoll die unvollständige Installation entfernt und neu gestartet werden?\n\nBereits installierte Pakete bleiben erhalten, der Neustart geht deshalb schneller." 14 76; then
        rm -rf "$PTERO_DIR"
        gd_conf_set INSTALL_STATE neu
    fi
    gd_warn_colors_off
fi

if [ -d "$PTERO_DIR" ]; then
    gd_manage_menu
else
    gd_check_environment
    gd_install_menu
fi
