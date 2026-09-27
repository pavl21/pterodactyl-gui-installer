#!/bin/bash
# Pfad: lib/common.sh
# Gemeinsame Funktionen für alle Skripte von GermanDactyl Setup:
# Logging, whiptail-Helfer, Fortschrittsbalken, Validierung, IP/DNS, apt, Passwörter.
# Diese Datei wird nur eingebunden (source), nicht direkt ausgeführt.

# Doppeltes Einbinden verhindern
[ -n "${GD_COMMON_LOADED:-}" ] && return 0
GD_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Grundeinstellungen
# ---------------------------------------------------------------------------
GD_REPO="pavl21/pterodactyl-gui-installer"
GD_BRANCH="${GD_BRANCH:-main}"
GD_RAW="https://raw.githubusercontent.com/${GD_REPO}/${GD_BRANCH}"
GD_CONF_DIR="/etc/germandactyl"
GD_CONF_FILE="${GD_CONF_DIR}/setup.conf"
GD_LOG_DIR="/var/log/germandactyl-setup"
PTERO_DIR="/var/www/pterodactyl"
GD_PHP_VERSION="8.3"
GD_TIMEZONE="Europe/Berlin"

# whiptail benötigt eine UTF-8-Locale, damit Umlaute und Emojis korrekt dargestellt werden
case "${LC_ALL:-${LANG:-}}" in
    *UTF-8*|*utf8*) ;;
    *) export LC_ALL=C.UTF-8 LANG=C.UTF-8 ;;
esac
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

# Temporäres Arbeitsverzeichnis, wird beim Beenden automatisch entfernt
if [ -z "${GD_TMP:-}" ]; then
    GD_TMP="$(mktemp -d /tmp/germandactyl.XXXXXX)"
    export GD_TMP
    trap 'rm -rf "$GD_TMP"' EXIT
fi

# Log-Datei (nur für root lesbar, da Zugangsdaten auftauchen könnten)
if [ -z "${GD_LOG:-}" ]; then
    mkdir -p "$GD_LOG_DIR" 2>/dev/null
    chmod 700 "$GD_LOG_DIR" 2>/dev/null
    GD_LOG="${GD_LOG_DIR}/setup-$(date +%Y%m%d-%H%M%S).log"
    export GD_LOG
fi
touch "$GD_LOG" 2>/dev/null && chmod 600 "$GD_LOG" 2>/dev/null

# ---------------------------------------------------------------------------
# Ausgabe und Logging
# ---------------------------------------------------------------------------
gd_log() {
    echo "[$(date '+%F %T')] $*" >> "$GD_LOG"
}

gd_status() {
    clear
    echo ""
    echo "STATUS - - - - - - - - - - - - - - -"
    echo ""
    echo "$*"
    echo ""
}

gd_die() {
    gd_log "ABBRUCH: $*"
    echo ""
    echo "FEHLER - - - - - - - - - - - - - - -"
    echo "$*"
    echo "Details findest du im Log: $GD_LOG"
    exit 1
}

# ---------------------------------------------------------------------------
# whiptail-Helfer
# ---------------------------------------------------------------------------
whiptail() {
    # Deutsche Beschriftung der Buttons direkt setzen: Übersetzungen über die Spracheinstellung greifen
    # nur, wenn eine deutsche Locale installiert ist (auf VPS-Images meist nicht). Eigene Angaben des
    # Aufrufers (z. B. --ok-button) stehen danach und haben Vorrang.
    # Größe an das Terminal anpassen: Zu große Dialoge schneidet whiptail sonst einfach ab
    # (z. B. in kleinen SSH-Fenstern mit 80x24). Wird gekürzt, wird der Text scrollbar.
    local args=("$@") i rows=24 cols=80 size extra=()
    size="$(stty size < /dev/tty 2>/dev/null)" && read -r rows cols <<< "$size"
    [ "${rows:-0}" -ge 10 ] 2>/dev/null || rows=24
    [ "${cols:-0}" -ge 40 ] 2>/dev/null || cols=80
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
            --msgbox|--yesno|--inputbox|--passwordbox|--textbox|--gauge|--menu|--checklist|--radiolist|--infobox)
                local h="${args[i+2]:-0}" w="${args[i+3]:-0}"
                if [[ "$h" =~ ^[0-9]+$ ]] && [ "$h" -gt $((rows - 1)) ]; then
                    args[i+2]=$((rows - 1))
                    case "${args[i]}" in --msgbox|--yesno) extra=(--scrolltext) ;; esac
                    # Listenhöhe von Menüs mitverkleinern
                    if [[ "${args[i]}" =~ ^--(menu|checklist|radiolist)$ ]] && [[ "${args[i+4]:-}" =~ ^[0-9]+$ ]] \
                        && [ "${args[i+4]}" -gt $((rows - 9)) ]; then
                        args[i+4]=$((rows - 9))
                    fi
                fi
                if [[ "$w" =~ ^[0-9]+$ ]] && [ "$w" -gt $((cols - 2)) ]; then
                    args[i+3]=$((cols - 2))
                fi
                break ;;
        esac
    done
    command whiptail --yes-button "Ja" --no-button "Nein" --ok-button "OK" --cancel-button "Abbrechen" "${extra[@]}" "${args[@]}"
}

gd_whip() {
    # whiptail zeichnet auf die Standardausgabe. Wird ein Dialog innerhalb von $(...) aufgerufen
    # (z. B. in gd_ask_domain), wäre er unsichtbar und das Skript würde hängen – daher dann direkt aufs Terminal.
    if [ -t 1 ] || [ ! -w /dev/tty ]; then
        whiptail "$@"
    else
        whiptail "$@" > /dev/tty
    fi
}

gd_msg() {
    # gd_msg "Titel" "Text" [höhe] [breite]
    gd_whip --title "$1" --msgbox "$2" "${3:-12}" "${4:-70}"
}

gd_yesno() {
    # gd_yesno "Titel" "Text" [höhe] [breite]  -> Rückgabe 0 = Ja
    gd_whip --title "$1" --yesno "$2" "${3:-12}" "${4:-70}"
}

gd_input() {
    # gd_input "Titel" "Text" [vorgabe] [höhe] [breite] -> gibt Eingabe aus, Rückgabe != 0 bei Abbruch
    whiptail --title "$1" --inputbox "$2" "${4:-12}" "${5:-70}" "${3:-}" 3>&1 1>&2 2>&3
}

gd_warn_colors_on() {
    GD_OLD_NEWT_COLORS="${NEWT_COLORS:-}"
    export NEWT_COLORS='
    root=,red
    window=,red
    border=white,red
    textbox=white,red
    button=black,white
    entry=,red
    checkbox=,red
    compactbutton=,red
    '
}

gd_warn_colors_off() {
    export NEWT_COLORS="${GD_OLD_NEWT_COLORS:-}"
}

# ---------------------------------------------------------------------------
# Fortschrittsbalken (echter Fortschritt: jeder Schritt meldet sich selbst)
# ---------------------------------------------------------------------------
GD_GAUGE_OPEN=0

gd_gauge_open() {
    # gd_gauge_open "Titel" "Starttext"
    exec 7> >(whiptail --title "$1" --gauge "$2" 10 78 0)
    GD_GAUGE_OPEN=1
}

gd_progress() {
    # gd_progress <prozent> "Text"
    gd_log "== [$1%] $2"
    if [ "$GD_GAUGE_OPEN" = "1" ]; then
        # In einer Subshell schreiben: Ist whiptail beendet, trifft das SIGPIPE nur die Subshell
        # und nicht die laufende Installation. Danach wird ohne Balken weitergearbeitet.
        if ! ( printf 'XXX\n%d\n%s\nXXX\n' "$1" "$2" >&7 ) 2>/dev/null; then
            GD_GAUGE_OPEN=0
            { exec 7>&-; } 2>/dev/null   # nur den Balken schließen, stderr des Skripts unverändert lassen
            echo "[$1%] $2"
        fi
    else
        echo "[$1%] $2"
    fi
}

gd_gauge_close() {
    if [ "$GD_GAUGE_OPEN" = "1" ]; then
        exec 7>&-
        GD_GAUGE_OPEN=0
        sleep 0.5
    fi
}

gd_step() {
    # gd_step <prozent> "Text" befehl [argumente...]
    # Führt den Befehl aus, Ausgabe landet im Log. Bei Fehler: Abbruch mit Log-Auszug.
    local pct="$1" text="$2"
    shift 2
    gd_progress "$pct" "$text"
    if ! "$@" >> "$GD_LOG" 2>&1; then
        gd_fail "$text"
    fi
}

gd_fail() {
    gd_gauge_close
    local tail_text
    tail_text="$(tail -n 12 "$GD_LOG" 2>/dev/null | cut -c1-110)"
    gd_log "FEHLGESCHLAGEN: $1"
    gd_whip --title "✖ Fehler bei der Installation" --msgbox "Dieser Schritt ist fehlgeschlagen:\n$1\n\nLetzte Log-Einträge:\n${tail_text}\n\nDas vollständige Log findest du hier:\n$GD_LOG" 26 118
    clear
    gd_die "Schritt fehlgeschlagen: $1"
}

# ---------------------------------------------------------------------------
# System- und Paketverwaltung
# ---------------------------------------------------------------------------
gd_require_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "Abgebrochen: Für dieses Skript werden Root-Rechte benötigt. Starte es mit 'sudo' oder als root."
        echo "Falls du nicht der Administrator des Servers bist, bitte ihn, dir temporär Zugriff zu erteilen."
        exit 1
    fi
    gd_ensure_base_tools
}

gd_ensure_base_tools() {
    # Fehlen auf Minimal-Systemen Grundwerkzeuge (z. B. wenn ein Unterskript direkt gestartet wird),
    # werden sie still nachinstalliert – sonst scheitern DNS-/IP-Prüfungen mit irreführenden Meldungen
    local miss=() c
    for c in whiptail:whiptail curl:curl dig:dnsutils jq:jq ip:iproute2 gpg:gnupg fuser:psmisc; do
        command -v "${c%%:*}" >/dev/null 2>&1 || miss+=("${c#*:}")
    done
    [ ${#miss[@]} -eq 0 ] && return 0
    echo "Benötigte Grundpakete werden installiert: ${miss[*]} ..."
    { gd_apt update && gd_apt_install "${miss[@]}"; } >/dev/null 2>&1 \
        || echo "Hinweis: Nicht alle Grundpakete konnten installiert werden (${miss[*]})."
    return 0
}

gd_wait_for_apt() {
    # Wartet (max. 5 Minuten), bis kein anderer apt/dpkg-Prozess mehr läuft
    local i=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
        [ $i -eq 0 ] && gd_log "Warte auf laufenden apt/dpkg-Prozess..."
        i=$((i + 1))
        [ $i -gt 150 ] && return 1
        sleep 2
    done
    return 0
}

gd_apt() {
    # gd_apt <apt-get Argumente...> – nicht-interaktiv, behält vorhandene Konfigurationsdateien
    gd_wait_for_apt || { echo "Ein anderer Installations-/Updateprozess blockiert apt."; return 1; }
    apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

gd_apt_install() {
    gd_apt install --no-install-recommends "$@"
}

gd_os_detect() {
    # Setzt GD_OS_ID, GD_OS_VERSION, GD_OS_CODENAME, GD_OS_NAME
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        GD_OS_ID="${ID:-unbekannt}"
        GD_OS_VERSION="${VERSION_ID:-0}"
        GD_OS_CODENAME="${VERSION_CODENAME:-}"
        GD_OS_NAME="${PRETTY_NAME:-$GD_OS_ID $GD_OS_VERSION}"
    else
        GD_OS_ID="unbekannt"; GD_OS_VERSION="0"; GD_OS_CODENAME=""; GD_OS_NAME="unbekannt"
    fi
}

gd_os_supported() {
    gd_os_detect
    case "$GD_OS_ID:$GD_OS_VERSION" in
        debian:11|debian:12|debian:13) return 0 ;;
        ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) return 0 ;;
    esac
    return 1
}

gd_arch() {
    # amd64 / arm64 / sonstiges
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) uname -m ;;
    esac
}

gd_mysql() {
    # Zugriff als root über den unix_socket (Standard bei MariaDB unter Debian/Ubuntu)
    if command -v mariadb >/dev/null 2>&1; then
        mariadb "$@"
    else
        mysql "$@"
    fi
}

gd_cert_days_left() {
    # gd_cert_days_left <zertifikatsdatei> -> verbleibende Tage (negativ = abgelaufen), Rückgabe 1 bei Fehler
    local end
    end="$(openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2)" || return 1
    [ -n "$end" ] || return 1
    echo $(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
}

gd_served_cert() {
    # gd_served_cert <host> <port> <sni-domain> -> gibt das tatsächlich ausgelieferte Zertifikat (PEM) aus
    timeout 10 openssl s_client -connect "$1:$2" -servername "$3" </dev/null 2>/dev/null \
        | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' | sed '/-----END CERTIFICATE-----/q'
}

gd_cert_matches_domain() {
    # gd_cert_matches_domain <zertifikatsdatei> <domain> – berücksichtigt auch Wildcards (*.domain.de)
    local names n
    names="$(openssl x509 -noout -ext subjectAltName -in "$1" 2>/dev/null | grep -oE 'DNS:[^, ]+' | cut -d: -f2)"
    [ -z "$names" ] && names="$(openssl x509 -noout -subject -in "$1" 2>/dev/null | sed -n 's/.*CN *= *//p')"
    for n in $names; do
        [ "$n" = "$2" ] && return 0
        [[ "$n" == \*.* ]] && [ "${2#*.}" = "${n#\*.}" ] && return 0
    done
    return 1
}

gd_mysqldump() {
    # Datenbank-Dump: MariaDB 11 liefert "mysqldump" nicht mehr in jedem Fall mit
    if command -v mariadb-dump >/dev/null 2>&1; then
        mariadb-dump "$@"
    else
        mysqldump "$@"
    fi
}

gd_latest_tag() {
    # gd_latest_tag <owner/repo> -> Name des neuesten Release-Tags, z. B. "v1.15.1" oder "beta-2026-08"
    local url
    url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" 2>/dev/null)"
    if [[ "$url" != */tag/* ]]; then
        # Rückfallebene: GitHub-API (max. 60 Anfragen pro Stunde ohne Anmeldung)
        url="$(curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
            | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\/tag\/\1/')"
    fi
    [[ "$url" == */tag/* ]] || return 1
    url="${url##*/tag/}"
    [[ "$url" =~ ^[0-9A-Za-z._-]+$ ]] || return 1
    echo "$url"
}

gd_latest_release() {
    # gd_latest_release <owner/repo> -> Versionsnummer ohne "v", z. B. "1.15.1"
    local tag
    tag="$(gd_latest_tag "$1")" || return 1
    tag="${tag#v}"
    [[ "$tag" =~ ^[0-9]+(\.[0-9]+)+(-[0-9A-Za-z.]+)?$ ]] || return 1
    echo "$tag"
}

gd_version_ge() {
    # gd_version_ge 1.12.2 1.11.3 -> wahr, wenn $1 >= $2
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# ---------------------------------------------------------------------------
# Konfiguration von GermanDactyl Setup (ersetzt /var/.panel_domain)
# ---------------------------------------------------------------------------
gd_conf_set() {
    # gd_conf_set KEY WERT
    mkdir -p "$GD_CONF_DIR"
    chmod 700 "$GD_CONF_DIR"
    touch "$GD_CONF_FILE"
    chmod 600 "$GD_CONF_FILE"
    sed -i "/^$1=/d" "$GD_CONF_FILE"
    printf '%s=%q\n' "$1" "$2" >> "$GD_CONF_FILE"
}

gd_conf_get() {
    # gd_conf_get KEY -> Wert (leer, falls nicht gesetzt)
    [ -r "$GD_CONF_FILE" ] || return 0
    (
        # shellcheck disable=SC1090
        . "$GD_CONF_FILE" 2>/dev/null
        eval "printf '%s' \"\${$1:-}\""
    )
}

# ---------------------------------------------------------------------------
# Validierung
# ---------------------------------------------------------------------------
gd_valid_domain() {
    # Mindestens eine Subdomain-Ebene + TLD (auch lange TLDs wie .gratis oder .online)
    local d="$1"
    [ ${#d} -le 253 ] || return 1
    [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

gd_valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

gd_valid_port_range() {
    # Portbereich wie 25565-25600 (Pterodactyl: > 1024, <= 65535, max. 1000 Ports je Bereich)
    local r="$1" a b
    [[ "$r" =~ ^([0-9]{4,5})-([0-9]{4,5})$ ]] || return 1
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
    [ "$a" -gt 1024 ] && [ "$b" -le 65535 ] && [ "$a" -le "$b" ] && [ $((b - a + 1)) -le 1000 ]
}

# ---------------------------------------------------------------------------
# Passwörter
# ---------------------------------------------------------------------------
gd_gen_password() {
    # gd_gen_password [länge] – nur Buchstaben/Zahlen, garantiert Groß-, Kleinbuchstaben und Zahl
    local len="${1:-32}" pw
    while true; do
        pw="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$len")"
        if [[ "$pw" =~ [A-Z] ]] && [[ "$pw" =~ [a-z] ]] && [[ "$pw" =~ [0-9] ]]; then
            echo "$pw"
            return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# Netzwerk: IP-Adressen und DNS
# ---------------------------------------------------------------------------
gd_is_private_ip() {
    # RFC1918, CGNAT (100.64/10), Loopback und Link-Local
    local ip="$1" a b
    IFS=. read -r a b _ _ <<< "$ip"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 1
    [ "$a" -eq 10 ] && return 0
    [ "$a" -eq 127 ] && return 0
    [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
    [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
    [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0
    [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 0
    return 1
}

gd_local_ip() {
    # IPv4-Adresse der Schnittstelle mit der Standardroute
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

gd_default_iface() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

gd_public_ip() {
    # Öffentliche IPv4: lokale Adresse, falls öffentlich – sonst per HTTPS ermitteln (NAT)
    local ip
    ip="$(gd_local_ip)"
    if [ -n "$ip" ] && ! gd_is_private_ip "$ip"; then
        echo "$ip"
        return 0
    fi
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null)"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip"
}

gd_resolve_a() {
    # Nur IPv4-Adressen der Domain (CNAME-Zeilen werden verworfen), über öffentliche Resolver
    local out
    out="$(dig +short A "$1" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')"
    [ -z "$out" ] && out="$(dig +short A "$1" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')"
    echo "$out"
}

gd_is_cloudflare_ip() {
    # Grobe Prüfung auf die bekanntesten Cloudflare-Proxy-Netze
    case "$1" in
        104.1[6-9].*|104.2[0-9].*|104.3[01].*|172.6[4-9].*|172.7[01].*|162.15[89].*|188.114.9[6-9].*|190.93.2[4-5][0-9].*|141.101.*|108.162.*|173.245.*|103.21.24[4-7].*|103.22.20[0-3].*|103.31.[4-7].*|197.234.24[0-3].*|198.41.1[2-9][0-9].*|198.41.2[0-5][0-9].*) return 0 ;;
    esac
    return 1
}

gd_dns_check_dialog() {
    # gd_dns_check_dialog <domain> – zeigt Ergebnis, Rückgabe 0 = passt
    local domain="$1" server_ip dns_ips
    server_ip="$(gd_public_ip)"
    dns_ips="$(gd_resolve_a "$domain")"

    if [ -z "$dns_ips" ]; then
        gd_msg "✖ Domain-Überprüfung" "Für die Domain $domain wurde kein A-Eintrag (IPv4) gefunden.\n\nLege bei deinem Domain-Anbieter einen A-Eintrag an, der auf die IP-Adresse dieses Servers zeigt:\n\n$server_ip\n\nDNS-Änderungen können einige Minuten dauern." 16 78
        return 1
    fi

    if grep -qxF "$server_ip" <<< "$dns_ips"; then
        gd_msg "✔ Domain-Überprüfung" "Die Domain $domain ist mit der IP-Adresse dieses Servers ($server_ip) verknüpft." 10 78
        return 0
    fi

    local first_ip hint=""
    first_ip="$(head -n1 <<< "$dns_ips")"
    if gd_is_cloudflare_ip "$first_ip"; then
        hint="\n\nDie Domain zeigt auf Cloudflare. Deaktiviere in Cloudflare den Proxy (graue Wolke, 'DNS only'), sonst können weder das SSL-Zertifikat noch Wings funktionieren."
    fi
    gd_msg "✖ Domain-Überprüfung" "Die Domain $domain zeigt auf eine andere IP-Adresse.\n\nDNS-Eintrag: $(tr '\n' ' ' <<< "$dns_ips")\nDieser Server: $server_ip\n\nPrüfe die DNS-Einträge auf Schreibfehler.${hint}" 18 78
    return 1
}

gd_ask_domain() {
    # gd_ask_domain "Titel" "Text" [vorgabe] -> gibt geprüfte Domain aus, Rückgabe 1 bei Abbruch
    local title="$1" text="$2" value="${3:-}"
    while true; do
        value="$(gd_input "$title" "$text" "$value" 12 72)" || return 1
        value="$(tr '[:upper:]' '[:lower:]' <<< "$value" | tr -d '[:space:]')"
        if ! gd_valid_domain "$value"; then
            gd_msg "Domain ist ungültig" "Bitte gib eine gültige Domain ein (z. B. panel.deinedomain.de) und prüfe sie auf Schreibfehler." 10 70
            continue
        fi
        if gd_dns_check_dialog "$value"; then
            echo "$value"
            return 0
        fi
        gd_yesno "Erneut versuchen?" "Möchtest du die Domain korrigieren bzw. nach der DNS-Änderung erneut prüfen?\n\nBei 'Nein' wird der Vorgang abgebrochen." 11 70 || return 1
    done
}

gd_ask_email() {
    # gd_ask_email "Titel" "Text" [vorgabe] -> gibt geprüfte E-Mail aus, Rückgabe 1 bei Abbruch
    local title="$1" text="$2" value="${3:-}"
    while true; do
        value="$(gd_input "$title" "$text" "$value" 14 72)" || return 1
        value="$(tr -d '[:space:]' <<< "$value")"
        if gd_valid_email "$value"; then
            echo "$value"
            return 0
        fi
        gd_msg "E-Mail-Adresse ungültig" "Bitte prüfe die E-Mail-Adresse und versuche es erneut." 9 60
    done
}

# ---------------------------------------------------------------------------
# Weitere Skripte aus dem Repository ausführen/laden
# ---------------------------------------------------------------------------
gd_fetch() {
    # gd_fetch <pfad im repo> <ziel> – lokale Kopie bevorzugen, sonst herunterladen
    local rel="$1" dest="$2"
    if [ -n "${GD_LOCAL_DIR:-}" ] && [ -f "$GD_LOCAL_DIR/$rel" ]; then
        cp "$GD_LOCAL_DIR/$rel" "$dest"
    else
        curl -fsSL "$GD_RAW/$rel" -o "$dest"
    fi
}

gd_source_lib() {
    # gd_source_lib <name> – bindet lib/<name>.sh ein
    local name="$1"
    if [ -n "${GD_LIB_DIR:-}" ] && [ -f "$GD_LIB_DIR/$name.sh" ]; then
        # shellcheck disable=SC1090
        . "$GD_LIB_DIR/$name.sh"
        return
    fi
    mkdir -p "$GD_TMP/lib"
    gd_fetch "lib/$name.sh" "$GD_TMP/lib/$name.sh" || gd_die "Die Datei lib/$name.sh konnte nicht geladen werden."
    # shellcheck disable=SC1090
    . "$GD_TMP/lib/$name.sh"
}

gd_run() {
    # gd_run <skript.sh> – lädt ein Skript des Projekts und führt es aus.
    # Die Standardeingabe bleibt das Terminal (wichtig für 'read'), danach geht es im Aufrufer weiter.
    local script="$1" target="$GD_TMP/run-$1"
    shift
    if ! gd_fetch "$script" "$target"; then
        gd_msg "Fehler" "Das Skript $script konnte nicht geladen werden. Prüfe die Internetverbindung." 9 70
        return 1
    fi
    GD_LIB_DIR="${GD_LIB_DIR:-}" GD_LOCAL_DIR="${GD_LOCAL_DIR:-}" GD_BRANCH="$GD_BRANCH" \
        GD_LOG="$GD_LOG" GD_TMP="$GD_TMP" bash "$target" "$@" < /dev/tty
}
