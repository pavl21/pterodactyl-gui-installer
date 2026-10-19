#!/bin/bash
# Pfad: installer.sh
# GermanDactyl Setup – Einstieg für Installation und Verwaltung von Pterodactyl (inkl. Wings und GermanDactyl)
# Start: sudo bash -c "$(curl -sSL https://setup.germandactyl.de/)"
#
# Das Skript ist eigenständig: Panel und Wings werden nach der offiziellen Dokumentation selbst eingerichtet,
# es werden keine fremden Installationsskripte mehr ausgeführt.

# Öffentlicher Schlüssel für die Signaturprüfung der nachgeladenen Skripte (SHA256SUMS + SHA256SUMS.sig).
# Inhalt der .pub-Datei, z. B. "ssh-ed25519 AAAA... germandactyl-setup"; leer = Prüfung noch nicht aktiv.
# Muss denselben Wert tragen wie GD_SIGNING_PUBKEY in lib/common.sh (hier wird er schon vor dem Laden von
# common.sh gebraucht). "scripts/sign-release.sh --check" prüft, dass beide Stellen übereinstimmen.
GD_SIGNING_PUBKEY=""

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
# Aus dem Repository geladene Dateien werden gegen eine signierte Prüfsummenliste (SHA256SUMS) geprüft, sobald
# GD_SIGNING_PUBKEY gesetzt ist und der Branch "main" ist. Test-Branches sind nicht signiert, lokale Checkouts
# werden nicht geprüft; beides vermerkt gd_signature_notice später im Log.
_gd_sig_abort() {
    echo ""
    echo "Abbruch: $*"
    echo "Aus Sicherheitsgründen werden die Skripte nicht ausgeführt."
    exit 1
}

_gd_sum_ok() {
    # _gd_sum_ok <pfad im repo> <datei> – Prüfsumme der Datei gegen den Eintrag in der geprüften SHA256SUMS
    local want have
    want="$(awk -v f="$1" '$2 == f { print $1; exit }' "$GD_TMP/SHA256SUMS")"
    [ -n "$want" ] || return 1
    have="$(sha256sum "$2" 2>/dev/null | awk '{ print $1 }')"
    [ -n "$have" ] && [ "$have" = "$want" ]
}

_gd_verify_sums() {
    # Lädt SHA256SUMS und SHA256SUMS.sig und prüft die Signatur mit OpenSSH (ssh-keygen -Y verify).
    # Erst danach gilt die Liste als vertrauenswürdig (GD_SUMS wird gesetzt und exportiert).
    local allowed
    command -v ssh-keygen >/dev/null 2>&1 \
        || _gd_sig_abort "ssh-keygen wurde nicht gefunden, die Signatur der Skripte kann nicht geprüft werden. Installiere es mit: apt-get install openssh-client"
    command -v sha256sum >/dev/null 2>&1 || _gd_sig_abort "sha256sum wurde nicht gefunden (Paket coreutils)."
    if ! curl -fsSL "$_gd_raw/SHA256SUMS" -o "$GD_TMP/SHA256SUMS" \
        || ! curl -fsSL "$_gd_raw/SHA256SUMS.sig" -o "$GD_TMP/SHA256SUMS.sig"; then
        _gd_sig_abort "Die signierte Prüfsummenliste (SHA256SUMS und SHA256SUMS.sig) konnte nicht geladen werden. Prüfe die Internetverbindung."
    fi
    allowed="$(umask 077; mktemp "$GD_TMP/allowed_signers.XXXXXX")" || _gd_sig_abort "Temporäre Datei konnte nicht angelegt werden."
    printf 'germandactyl-setup %s\n' "$GD_SIGNING_PUBKEY" > "$allowed"
    if ! ssh-keygen -Y verify -f "$allowed" -I germandactyl-setup -n germandactyl-setup \
        -s "$GD_TMP/SHA256SUMS.sig" < "$GD_TMP/SHA256SUMS" >/dev/null 2>&1; then
        rm -f "$allowed"
        _gd_sig_abort "Die Signatur der Prüfsummenliste (SHA256SUMS.sig) ist ungültig. Die Dateien im Repository wurden möglicherweise verändert."
    fi
    rm -f "$allowed"
    GD_SUMS="$GD_TMP/SHA256SUMS"
    export GD_SUMS
}

GD_LIBS=(common germandactyl security panel wings blueprint backup autobackup uninstall manage)
GD_BRANCH="${GD_BRANCH:-main}"
_gd_self="${BASH_SOURCE[0]:-}"
unset GD_SUMS   # gilt erst nach erfolgreicher Signaturprüfung (aus der Umgebung wird nichts übernommen)
# Lokaler Checkout nur, wenn neben dem Skript lib/common.sh liegt. Startet der Kurzbefehl installer.sh als Datei aus
# einem Temp-Verzeichnis, liegt dort nur installer.sh samt Signaturdateien, kein lib/ – dann gilt der Zweig "Repository".
if [ -n "$_gd_self" ] && [ -f "$_gd_self" ] && [ -f "$(dirname "$_gd_self")/lib/common.sh" ]; then
    GD_LOCAL_DIR="$(cd "$(dirname "$_gd_self")" && pwd)"
    GD_LIB_DIR="$GD_LOCAL_DIR/lib"
else
    GD_LOCAL_DIR=""
    GD_LIB_DIR="$(mktemp -d /tmp/germandactyl-lib.XXXXXX)"
    # Arbeitsverzeichnis schon jetzt anlegen: common.sh übernimmt es, und die geprüfte Liste liegt darin
    if [ -z "${GD_TMP:-}" ]; then
        GD_TMP="$(mktemp -d /tmp/germandactyl.XXXXXX)"
        export GD_TMP
    fi
    trap 'rm -rf "$GD_LIB_DIR" "$GD_TMP"' EXIT
    _gd_raw="https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/${GD_BRANCH}"
    if [ -n "$GD_SIGNING_PUBKEY" ] && [ "$GD_BRANCH" = "main" ]; then
        _gd_verify_sums
    fi
    for _gd_lib in "${GD_LIBS[@]}"; do
        if ! curl -fsSL "$_gd_raw/lib/${_gd_lib}.sh" -o "$GD_LIB_DIR/${_gd_lib}.sh"; then
            echo "Abbruch: Die Datei lib/${_gd_lib}.sh konnte nicht geladen werden. Prüfe die Internetverbindung."
            exit 1
        fi
        if [ -n "${GD_SUMS:-}" ] && ! _gd_sum_ok "lib/${_gd_lib}.sh" "$GD_LIB_DIR/${_gd_lib}.sh"; then
            _gd_sig_abort "Die Datei lib/${_gd_lib}.sh passt nicht zur signierten Prüfsummenliste (oder steht nicht darin)."
        fi
    done
fi
export GD_LOCAL_DIR GD_LIB_DIR
for _gd_lib in "${GD_LIBS[@]}"; do
    # shellcheck disable=SC1090
    . "$GD_LIB_DIR/${_gd_lib}.sh"
done
# Aufräumen beim Beenden und bei Abbruch (Strg+C, SSH-Verbindung getrennt): temporäre Dateien, heruntergeladene
# Bibliotheken, eine ggf. angelegte policy-rc.d und die temporäre Swap-Datei
trap gd_cleanup EXIT
trap 'gd_cleanup; exit 130' INT HUP TERM

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
        gd_apt_update; gd_apt_install whiptail curl dnsutils ca-certificates gnupg lsb-release jq iproute2 psmisc tar
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
        if ! gd_yesno "Nicht getestetes Betriebssystem" "Dein System ($GD_OS_NAME) wurde mit diesem Skript nicht getestet.\n\nGetestet sind: Debian 12, 13 und Ubuntu 22.04, 24.04, 26.04.\n\nMöchtest du trotzdem fortfahren?" 14 70; then
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

    # Port 80/443 von einem anderen Webserver belegt (z. B. Apache)? Sonst scheitert nginx mitten in der Installation.
    local blocker
    blocker="$(ss -Hltnp '( sport = :80 or sport = :443 )' 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | cut -d'"' -f2 | grep -vx nginx | sort -u | tr '\n' ' ')"
    if [ -n "$blocker" ]; then
        if grep -qw apache2 <<< "$blocker" && gd_yesno "Port 80/443 belegt" "Auf diesem Server läuft bereits der Webserver Apache und belegt Port 80/443. Pterodactyl benötigt nginx auf diesen Ports.\n\nSoll Apache gestoppt und deaktiviert werden? (Seiten, die über Apache laufen, sind danach nicht mehr erreichbar.)" 14 76; then
            systemctl disable --now apache2 >> "$GD_LOG" 2>&1
        else
            gd_msg "Port 80/443 belegt" "Port 80 bzw. 443 wird bereits verwendet von: ${blocker}\n\nPterodactyl benötigt diese Ports für nginx und das SSL-Zertifikat. Beende bzw. deaktiviere das Programm und starte die Installation erneut." 13 74
            clear; echo "Die Installation wurde abgebrochen (Port 80/443 belegt: ${blocker})."; exit 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Neuinstallation
# ---------------------------------------------------------------------------
gd_show_credentials() {
    # gd_msg_secret statt whiptail --msgbox: Das Passwort darf nicht als Argument in der Prozessliste stehen
    gd_msg_secret "✱ Deine Zugangsdaten" "Speichere dir diese Zugangsdaten jetzt ab. Dieses Fenster wird nicht noch einmal angezeigt.\n\nPanel:          https://${GD_DOMAIN}\nBenutzername:   ${GD_ADMIN_USER}\nE-Mail-Adresse: ${GD_EMAIL}\nPasswort:       ${GD_ADMIN_PASSWORD}\n\nDu kannst das Passwort nach dem ersten Login in den Kontoeinstellungen ändern." 18 78
}

GD_PENDING_CREDENTIALS="/etc/germandactyl/zugangsdaten-ausstehend"

gd_pending_credentials_save() {
    # Zugangsdaten zwischenspeichern (nur root), bis sie am Ende angezeigt wurden
    mkdir -p "$(dirname "$GD_PENDING_CREDENTIALS")"
    ( umask 077; printf 'GD_DOMAIN=%q\nGD_ADMIN_USER=%q\nGD_EMAIL=%q\nGD_ADMIN_PASSWORD=%q\n' \
        "$GD_DOMAIN" "$GD_ADMIN_USER" "$GD_EMAIL" "$GD_ADMIN_PASSWORD" > "$GD_PENDING_CREDENTIALS" )
}

gd_resume_install() {
    # Panel ist fertig, ein späterer Schritt (Wings oder Absicherung) wurde nicht abgeschlossen
    local mode text
    mode="$(gd_conf_get INSTALL_MODE)"
    if [ "$mode" = "panel_wings" ] && [ ! -f /etc/pterodactyl/config.yml ]; then
        text="Dein Panel ist installiert, aber die Einrichtung von Wings wurde nicht abgeschlossen.\n\nSoll Wings jetzt fertig eingerichtet werden? Das Panel bleibt dabei unverändert."
    else
        text="Dein Panel ist installiert, aber die letzten Schritte (z. B. Absicherung) wurden nicht abgeschlossen.\n\nFirewall, fail2ban, automatische Updates und Backups kannst du in der Verwaltung unter 'Server & Sicherheit' bzw. 'Backups' einrichten."
        mode="panel"
    fi
    if [ -s "$GD_PENDING_CREDENTIALS" ]; then
        # shellcheck disable=SC1090
        . "$GD_PENDING_CREDENTIALS"
        gd_show_credentials
    fi
    if [ "$mode" = "panel_wings" ]; then
        gd_yesno "⇄ Einrichtung fortsetzen" "$text" 13 76 || return 0
        gd_run wings-installer.sh
        [ -f /etc/pterodactyl/config.yml ] || return 0
    else
        gd_msg "⇄ Einrichtung fortsetzen" "$text" 13 76
    fi
    gd_conf_set INSTALL_STATE fertig
    rm -f "$GD_PENDING_CREDENTIALS"
    gd_shortcut_install >> "$GD_LOG" 2>&1
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

gd_check_database() {
    # Nur für die Panel-Installation (Pelican nutzt SQLite, reine Wings-Server brauchen keine Datenbank)
    # MySQL statt MariaDB: mariadb-server würde mysql-server entfernen, vorhandene Datenbanken wären unbrauchbar
    if dpkg-query -W -f='${Status}' 'mysql-server*' 2>/dev/null | grep -q "install ok installed"; then
        gd_msg "MySQL ist installiert" "Auf diesem Server ist MySQL installiert. Die Installation würde es durch MariaDB ersetzen, vorhandene Datenbanken wären danach nicht mehr nutzbar.\n\nDie Installation wird abgebrochen. Nutze einen frischen Server oder entferne MySQL vorher selbst (nach einem Backup)." 13 76
        clear; echo "Die Installation wurde abgebrochen (MySQL ist installiert)."; exit 1
    fi
    # MariaDB vorhanden, aber root nicht per unix_socket erreichbar (root-Passwort gesetzt)?
    if command -v mariadb >/dev/null 2>&1 && systemctl is-active --quiet mariadb && ! gd_mysql -e "SELECT 1" >/dev/null 2>&1; then
        gd_msg "Kein Zugriff auf MariaDB" "MariaDB ist installiert, aber root kann sich nicht ohne Passwort anmelden (unix_socket). Das Skript benötigt diesen Zugriff, um die Panel-Datenbank anzulegen.\n\nHinterlege das Passwort in /root/.my.cnf (Rechte 600):\n\n[client]\nuser=root\npassword=DEIN_PASSWORT\n\nStarte die Installation danach erneut." 18 76
        clear; echo "Die Installation wurde abgebrochen (kein root-Zugriff auf MariaDB)."; exit 1
    fi
}

gd_fresh_install() {
    local mode="$1"   # panel_wings | panel
    local with_wings=false
    [ "$mode" = "panel_wings" ] && with_wings=true
    gd_check_database

    # --- Eingaben -------------------------------------------------------------
    GD_DOMAIN="$(gd_ask_domain "⌂ Domain für das Panel" "Gib die Domain (FQDN) ein, unter der das Panel erreichbar sein soll, z. B. panel.deinedomain.de.\n\nDer DNS-Eintrag (A-Eintrag) muss bereits auf diesen Server zeigen, das wird im nächsten Schritt geprüft.")" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }

    # Läuft die Domain über den Cloudflare-Proxy, gibt es die Wahl: Proxy ausschalten oder DNS-01 per API-Token
    gd_ssl_method_ask "$GD_DOMAIN" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }

    GD_EMAIL="$(gd_ask_email "✉ E-Mail-Adresse" "Gib deine E-Mail-Adresse ein. Sie wird für das SSL-Zertifikat (Let's Encrypt) und dein Administrator-Konto verwendet.\n\nMit der Eingabe stimmst du den Nutzungsbedingungen von Let's Encrypt zu:\nhttps://letsencrypt.org/repository/")" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }

    while true; do
        GD_ADMIN_USER="$(gd_input "☺ Benutzername" "Wähle einen Benutzernamen für dein Administrator-Konto (nur Buchstaben, Zahlen, Punkt, Binde- und Unterstrich):" "admin" 11 70)" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }
        [[ "$GD_ADMIN_USER" =~ ^[A-Za-z0-9._-]{3,191}$ ]] && break
        gd_msg "Ungültiger Benutzername" "Der Benutzername muss mindestens 3 Zeichen lang sein und darf nur Buchstaben, Zahlen, Punkt, Binde- und Unterstrich enthalten." 10 70
    done

    GD_TELEMETRY=false
    if gd_yesno "☰ Anonyme Telemetrie" "Pterodactyl kann anonyme Nutzungsdaten (z. B. Versionen und Anzahl der Server, keine persönlichen Daten) an die Entwickler senden. Das hilft bei der Weiterentwicklung.\n\nMöchtest du die anonyme Telemetrie aktivieren?" 13 74; then
        GD_TELEMETRY=true
    fi

    gd_choose_panel_version || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }

    if $with_wings; then
        GD_WINGS_FQDN="$GD_DOMAIN"
        if [ "$GD_SSL_METHOD" = "cloudflare" ]; then
            # Das Panel bleibt hinter dem Cloudflare-Proxy – Wings darf das nicht: Die Verbindung zu Wings (Port 8080)
            # und SFTP (Port 2022) laufen nicht über den Proxy. Deshalb ist eine eigene Subdomain Pflicht.
            gd_msg "⇄ Eigene Domain für Wings" "Dein Panel (${GD_DOMAIN}) bleibt hinter dem Cloudflare-Proxy. Die Verbindung zu Wings (Port 8080) und SFTP (Port 2022) laufen nicht über den Cloudflare-Proxy.\n\nWings braucht deshalb eine eigene Subdomain, z. B. node1.deinedomain.de. Sie muss auf diesen Server zeigen und in Cloudflare auf 'DNS only' (graue Wolke) stehen." 15 76
            GD_WINGS_FQDN="$(gd_ask_wings_domain "$GD_DOMAIN" "Gib die Domain für Wings ein, z. B. node1.deinedomain.de. Sie muss auf diesen Server zeigen und darf nicht über den Cloudflare-Proxy laufen.")" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }
        elif ! gd_yesno "⇄ Domain für Wings" "Wings (die Verbindung zu deinen Gameservern) nutzt standardmäßig dieselbe Domain wie das Panel:\n\n${GD_DOMAIN} (Port 8080)\n\nDas ist die einfachste Variante. Möchtest du diese Domain verwenden?\n\nBei 'Nein' kannst du eine eigene Subdomain angeben (z. B. node1.deinedomain.de)." 15 76; then
            GD_WINGS_FQDN="$(gd_ask_wings_domain "$GD_DOMAIN" "Gib die Domain für Wings ein, z. B. node1.deinedomain.de. Sie muss ebenfalls auf diesen Server zeigen.")" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }
        elif gd_is_cloudflare_ip "$(gd_resolve_a "$GD_DOMAIN" | head -n1)"; then
            # Über den Cloudflare-Proxy (orange Wolke) funktioniert Port 8080 nicht – die Konsole im Panel bliebe tot
            gd_msg "⚠ Cloudflare-Proxy erkannt" "Die Domain ${GD_DOMAIN} läuft über den Cloudflare-Proxy (orange Wolke). Wings (Port 8080) ist darüber nicht erreichbar.\n\nGib im nächsten Schritt eine eigene Subdomain für Wings an, die in Cloudflare auf 'DNS only' (graue Wolke) steht." 13 76
            GD_WINGS_FQDN="$(gd_ask_wings_domain "$GD_DOMAIN" "Gib die Domain für Wings ein, z. B. node1.deinedomain.de. Sie muss auf diesen Server zeigen und darf nicht über den Cloudflare-Proxy laufen.")" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }
        fi
        while true; do
            GD_PORT_RANGE="$(gd_input "⚑ Ports für Gameserver" "Welche Ports sollen für Gameserver freigegeben werden?\n\nFormat: Start-Ende, z. B. 25565-25600 (höchstens 1000 Ports, jeweils größer als 1024). Du kannst später im Panel weitere Ports hinzufügen." "$GD_DEFAULT_PORT_RANGE" 14 74)" || { clear; echo "Die Installation wurde abgebrochen."; exit 0; }
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
            if ! gd_mysql -e "DROP DATABASE \`${GD_PANEL_DB}\`;" >> "$GD_LOG" 2>&1; then
                gd_warn_colors_off
                gd_msg "Fehler" "Die alte Datenbank konnte nicht gelöscht werden. Details: $GD_LOG" 9 70
                clear; echo "Die Installation wurde abgebrochen."; exit 1
            fi
        else
            gd_warn_colors_off
            clear; echo "Die Installation wurde abgebrochen."; exit 0
        fi
        gd_warn_colors_off
    fi

    # --- Zusammenfassung ------------------------------------------------------
    local summary
    summary="Panel:         https://${GD_DOMAIN}\nVersion:       v${GD_PANEL_VERSION} $( [ "$GD_APPLY_PATCH" = "true" ] && echo '(Deutsch, GermanDactyl)' || echo '(Englisch)')\nE-Mail:        ${GD_EMAIL}\nBenutzername:  ${GD_ADMIN_USER}\nTelemetrie:    $( $GD_TELEMETRY && echo an || echo aus)\n"
    summary+="Zertifikat:    $( [ "$GD_SSL_METHOD" = cloudflare ] && echo "Let's Encrypt über Cloudflare (DNS-01), Proxy bleibt an" || echo "Let's Encrypt (Webroot)")\n"
    if $with_wings; then
        summary+="Wings:         https://${GD_WINGS_FQDN}:8080 (automatisch verbunden)\nGameserver:    Ports ${GD_PORT_RANGE}\n"
    fi
    summary+="Firewall:      $( [ "$GD_SEC_UFW" = true ] && echo an || echo aus)   fail2ban: $( [ "$GD_SEC_FAIL2BAN" = true ] && echo an || echo aus)   Auto-Updates: $( [ "$GD_SEC_UPDATES" = true ] && echo an || echo aus)\n"
    summary+="Backups:       $( [ "$GD_SEC_BACKUP" = true ] && echo 'täglich 04:00 Uhr, inkrementell' || echo aus)\n"
    summary+="Blueprint:     $( [ "${GD_BLUEPRINT:-false}" = true ] && echo 'wird installiert' || echo 'nein')"
    if ! whiptail --title "☰ Zusammenfassung" --yesno "Bitte prüfe deine Angaben:\n\n${summary}\n\nDie Installation dauert je nach Server 5 bis 20 Minuten. Soll sie jetzt starten?" 22 80; then
        clear; echo "Die Installation wurde abgebrochen."; exit 0
    fi

    # --- Installation ---------------------------------------------------------
    GD_ADMIN_PASSWORD="$(gd_gen_password 24)"
    GD_DB_PASSWORD="$(gd_gen_password 48)"
    gd_log "Installation gestartet: mode=$mode domain=$GD_DOMAIN version=$GD_PANEL_VERSION patch=$GD_APPLY_PATCH ssl=$GD_SSL_METHOD"
    gd_conf_set SSL_METHOD "$GD_SSL_METHOD"

    gd_gauge_open "➜ Pterodactyl wird installiert" "Installation wird vorbereitet..."
    gd_panel_install_steps
    # Ab hier ist das Panel nutzbar. Scheitert ein späterer Schritt (Wings, Absicherung), gehen die
    # Zugangsdaten nicht verloren und der nächste Start setzt die Einrichtung fort, statt neu zu installieren.
    gd_conf_set INSTALL_STATE panel_fertig
    gd_conf_set INSTALL_MODE "$mode"
    gd_pending_credentials_save
    # Kein Passwort im Hinweis: gd_fail übergibt ihn als Argument an whiptail (in der Prozessliste sichtbar).
    # gd_resume_install zeigt die Zugangsdaten beim nächsten Start aus der Datei GD_PENDING_CREDENTIALS an.
    GD_FAIL_HINT="Das Panel selbst ist fertig installiert: https://${GD_DOMAIN}\nDie Zugangsdaten werden beim nächsten Start angezeigt (sie liegen unter ${GD_PENDING_CREDENTIALS}, nur für root lesbar).\nStarte das Skript erneut, um die Einrichtung fortzusetzen."
    if $with_wings; then
        gd_wings_local_steps 72
    fi
    gd_security_steps 91 "$with_wings" "${GD_PORT_RANGE:-}"
    gd_progress 100 "Installation abgeschlossen."
    gd_gauge_close
    GD_FAIL_HINT=""
    gd_conf_set INSTALL_STATE fertig
    rm -f "$GD_PENDING_CREDENTIALS"
    gd_shortcut_install >> "$GD_LOG" 2>&1

    # --- Abschluss ------------------------------------------------------------
    gd_show_credentials
    if [ "$GD_SEC_BACKUP" = true ] && [ -s "$GD_AB_PASS" ]; then
        gd_msg_secret "✱ Passwort der Backups" "Deine täglichen Backups sind verschlüsselt. Ohne dieses Passwort können sie nicht wiederhergestellt werden, falls der Server ausfällt:\n\n$(cat "$GD_AB_PASS")\n\nSpeichere es zusammen mit deinen Zugangsdaten." 15 78
    fi
    if gd_yesno "▣ Zugangsdaten speichern?" "Sollen die Zugangsdaten zusätzlich in einer Datei gespeichert werden, die nur root lesen kann?\n\n/root/germandactyl-zugangsdaten.txt" 11 70; then
        gd_save_credentials
    fi

    local done_text
    if $with_wings; then
        done_text="Dein Panel ist einsatzbereit und Wings ist bereits verbunden. Du kannst sofort loslegen:\n\n1. Melde dich an: https://${GD_DOMAIN}\n2. Öffne 'Admin' → 'Servers' → 'Create New' und lege deinen ersten Gameserver an.\n\nFreigegebene Gameserver-Ports: ${GD_PORT_RANGE}"
    else
        done_text="Dein Panel ist einsatzbereit: https://${GD_DOMAIN}\n\nDamit du Gameserver erstellen kannst, brauchst du noch Wings. Starte dazu die Verwaltung (Befehl: $(gd_shortcut_hint)) und wähle 'Gameserver & Wings → Wings installieren/verwalten'."
    fi
    [ -n "${GD_WARNINGS:-}" ] && done_text+="\n\n${GD_WARNINGS}\nDu kannst das später in der Verwaltung unter 'Server & Sicherheit' erneut versuchen."
    [ "$GD_SSL_METHOD" = "cloudflare" ] && done_text+="\n\nCloudflare: Stelle unter 'SSL/TLS' den Verschlüsselungsmodus auf 'Vollständig (streng)', sonst kann es zu Weiterleitungsschleifen kommen."
    gd_ufw_active && done_text+="\n\nDie Firewall ist aktiv. Weitere Ports gibst du in der Verwaltung unter 'Gameserver & Wings → Ports freigeben' frei."
    done_text+="\n\nDie Verwaltung startest du künftig einfach mit dem Befehl: $(gd_shortcut_hint)"
    gd_msg "✔ Installation erfolgreich" "$done_text" 22 78
    clear
    echo ""
    echo "FERTIG - - - - - - - - - - - - - - -"
    echo "Panel: https://${GD_DOMAIN}"
    echo "Log:   $GD_LOG"
    echo "Verwaltung: $(gd_shortcut_hint)"
    echo ""
}

gd_install_menu() {
    local choice
    if ! whiptail --title "Willkommen bei GermanDactyl Setup!" --yesno "Dieses Skript installiert das Pterodactyl Panel inklusive deutscher Übersetzung (GermanDactyl) und auf Wunsch Wings – vollautomatisch und fertig eingerichtet.\n\n⚠ Testphase: GermanDactyl Setup ist noch in der Testphase. Es können jederzeit unerwartete Fehler auftreten, nutze es zuerst auf einem Testserver.\n\nDu benötigst eine Domain bzw. Subdomain, deren DNS-Eintrag auf diesen Server zeigt.\n\nMit der Bestätigung stimmst du zu, dass:\n- benötigte Pakete installiert werden dürfen\n- du den Nutzungsbedingungen von Let's Encrypt zustimmst\n- du der Besitzer der Domain bist bzw. die Berechtigung dafür hast\n- die angegebene E-Mail-Adresse deine eigene ist\n\nMöchtest du fortfahren?" 24 78; then
        clear; echo "Die Installation wurde abgebrochen."; exit 0
    fi

    choice=$(whiptail --title "Was möchtest du installieren?" --menu "Wähle aus, was auf diesem Server eingerichtet werden soll:" 18 78 5 \
        "1" "Panel + Wings (empfohlen, sofort einsatzbereit)" \
        "2" "Nur Panel (Wings läuft auf einem anderen Server)" \
        "3" "Nur Wings (Panel läuft auf einem anderen Server)" \
        "4" "Pelican Panel + Wings (Beta)" \
        "5" "Nur Pelican-Wings (Pelican-Panel auf anderem Server)" 3>&1 1>&2 2>&3) || { clear; exit 0; }

    case "$choice" in
        1) gd_fresh_install panel_wings ;;
        2) gd_fresh_install panel ;;
        3) gd_run wings-installer.sh ;;
        4) gd_run pelican-installer.sh ;;
        5) gd_run wings-pelican.sh ;;
    esac
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
clear
echo "----------------------------------"
echo "GermanDactyl Setup"
echo "Pterodactyl Panel + Wings mit deutscher Übersetzung – von Pavl21"
echo "Testphase: Es können jederzeit unerwartete Fehler auftreten. Erstelle vor Änderungen ein Backup."
echo "----------------------------------"
gd_log "GermanDactyl Setup gestartet (Branch: $GD_BRANCH, lokal: ${GD_LOCAL_DIR:-nein})"

if ! command -v whiptail >/dev/null 2>&1 || ! command -v dig >/dev/null 2>&1 \
    || { [ ! -d "$PTERO_DIR" ] && [ ! -f /etc/pterodactyl/config.yml ] && [ ! -d /var/www/pelican ]; }; then
    gd_prepare_system
fi

# Vermerkt im Log, ob die Skripte per Signatur geprüft wurden (bei Test-Branches zusätzlich ein Hinweis)
gd_signature_notice

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

if [ -d "$PTERO_DIR" ] && [ "$(gd_conf_get INSTALL_STATE)" = "panel_fertig" ]; then
    gd_resume_install
fi

if [ -d "$PTERO_DIR" ] || [ -f /etc/pterodactyl/config.yml ]; then
    gd_main_menu
elif [ -f /var/www/pelican/artisan ] || [ -f /etc/pelican/config.yml ]; then
    # Pelican-Server: direkt zur Pelican-Verwaltung (nicht das Pterodactyl-Installationsmenü – dessen
    # Wings-Installation würde Pelican-Wings überschreiben). Reiner Pelican-Wings-Server: Wings-Verwaltung.
    if [ -f /var/www/pelican/artisan ]; then
        gd_run pelican-installer.sh
    else
        gd_run wings-pelican.sh
    fi
    clear
    exit 0
else
    gd_check_environment
    gd_install_menu
fi
