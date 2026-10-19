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
# Pterodactyl 2.x hat einen anderen Stack und Update-Ablauf als 1.x – erst nach Anpassung der TUI freigeben
GD_PANEL_MAJOR="1"
# Headless-Modus (GD_HEADLESS=1, z. B. geplante Updates per systemd-Timer): Es gibt kein Terminal und keine Dialoge.
# Alle Dialog-, Fortschritts- und Fehlerfunktionen unten schreiben dann nur noch ins Log; Rückfragen gelten als "Nein".

# whiptail benötigt eine UTF-8-Locale, damit Umlaute und Emojis korrekt dargestellt werden
case "${LC_ALL:-${LANG:-}}" in
    *UTF-8*|*utf8*) ;;
    *) export LC_ALL=C.UTF-8 LANG=C.UTF-8 ;;
esac
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
# Ohne gültiges TERM verweigert whiptail jeden Dialog (jede Ja/Nein-Frage gälte dann als "Nein")
case "${TERM:-}" in ""|dumb|unknown) export TERM=xterm ;; esac
# Nach "su" (ohne "-") fehlen unter Debian die sbin-Verzeichnisse – dann wären nginx, sshd, ufw usw. nicht auffindbar
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

gd_cleanup() {
    # Aufräumen beim Beenden, auch bei Strg+C oder Abbruch der SSH-Verbindung (Trap in installer.sh)
    # Eine von uns angelegte policy-rc.d blockiert sonst systemweit jeden Dienststart durch apt.
    # Der Marker erkennt auch eine Datei, die ein Unterskript angelegt hat (GD_OWN_POLICY gilt nur dort).
    if [ "${GD_OWN_POLICY:-}" = true ] || grep -qs 'germandactyl-setup' /usr/sbin/policy-rc.d 2>/dev/null; then
        rm -f /usr/sbin/policy-rc.d
    fi
    # Die apt-Zeitgeber, die gd_apt_timers_stop für die Installation angehalten hat, laufen danach wieder.
    # Die Variable enthält nur die Zeitgeber, die wirklich aktiv waren und von uns gestoppt wurden.
    if [ -n "${GD_APT_TIMERS_STOPPED:-}" ]; then
        local t
        for t in $GD_APT_TIMERS_STOPPED; do
            systemctl start "$t" >/dev/null 2>&1
        done
        GD_APT_TIMERS_STOPPED=""
    fi
    declare -F gd_build_swap_off >/dev/null && gd_build_swap_off
    [ -n "${GD_TMP:-}" ] && rm -rf "$GD_TMP"
    [ -z "${GD_LOCAL_DIR:-}" ] && [ -n "${GD_LIB_DIR:-}" ] && rm -rf "$GD_LIB_DIR"
    return 0
}

# Temporäres Arbeitsverzeichnis, wird beim Beenden automatisch entfernt
if [ -z "${GD_TMP:-}" ]; then
    GD_TMP="$(mktemp -d /tmp/germandactyl.XXXXXX)"
    export GD_TMP
    trap gd_cleanup EXIT
    trap 'gd_cleanup; exit 130' INT HUP TERM
fi

# Log-Datei (nur für root lesbar, da Zugangsdaten auftauchen könnten)
if [ -z "${GD_LOG:-}" ]; then
    mkdir -p "$GD_LOG_DIR" 2>/dev/null
    chmod 700 "$GD_LOG_DIR" 2>/dev/null
    if [ "${GD_HEADLESS:-}" = 1 ]; then
        # Geplante Läufe (systemd-Timer) schreiben in ein gemeinsames Log statt jede Nacht eine neue Datei anzulegen
        GD_LOG="${GD_LOG_DIR}/auto-update.log"
    else
        GD_LOG="${GD_LOG_DIR}/setup-$(date +%Y%m%d-%H%M%S).log"
    fi
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
    [ "${GD_HEADLESS:-}" = 1 ] && { echo "FEHLER: $*" >&2; exit 1; }
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
    [ "${GD_HEADLESS:-}" = 1 ] && return 1
    local args=("$@") i rows=24 cols=80 size extra=()
    size="$(stty size < /dev/tty 2>/dev/null)" && read -r rows cols <<< "$size"
    # Unbekannte Größe -> 80x24 annehmen; sehr kleine Fenster nicht vergrößern, sondern auf ein Minimum begrenzen
    [ "${rows:-0}" -ge 1 ] 2>/dev/null || rows=24
    [ "$rows" -lt 8 ] && rows=8
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
                    # Schmalere Dialoge brechen mehr Zeilen um – Text scrollbar machen, damit nichts abgeschnitten wird
                    case "${args[i]}" in --msgbox|--yesno) extra=(--scrolltext) ;; esac
                fi
                break ;;
        esac
    done
    command whiptail --yes-button "Ja" --no-button "Nein" --ok-button "OK" --cancel-button "Abbrechen" "${extra[@]}" "${args[@]}"
}

gd_whip() {
    # Headless: kein Dialog (Rückgabe 1 = Abbruch/Nein)
    [ "${GD_HEADLESS:-}" = 1 ] && return 1
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
    [ "${GD_HEADLESS:-}" = 1 ] && { gd_log "[Meldung] $1: $(printf '%b' "$2" | tr '\n' ' ')"; return 0; }
    gd_whip --title "$1" --msgbox "$2" "${3:-12}" "${4:-70}"
}

gd_msg_secret() {
    # gd_msg_secret "Titel" "Text" [höhe] [breite] – wie gd_msg, aber für Passwörter und Token.
    # Der Text wird NICHT als Prozessargument übergeben (das sähe jeder lokale Benutzer per "ps" bzw. /proc),
    # sondern über eine nur für root lesbare Datei angezeigt, die danach sofort gelöscht wird.
    # Headless: Geheimnisse gehören nicht ins Log – nur der Titel wird vermerkt
    [ "${GD_HEADLESS:-}" = 1 ] && { gd_log "[Meldung] $1 (Inhalt nicht protokolliert)"; return 0; }
    local file rc
    file="$(umask 077; mktemp "${GD_TMP:-/tmp}/secret.XXXXXX")" || return 1
    printf '%b' "$2" > "$file"
    gd_whip --title "$1" --scrolltext --textbox "$file" "${3:-18}" "${4:-78}"
    rc=$?
    rm -f "$file"
    return $rc
}

gd_yesno() {
    # gd_yesno "Titel" "Text" [höhe] [breite]  -> Rückgabe 0 = Ja
    # Headless gibt es keine Rückfrage: immer "Nein"
    [ "${GD_HEADLESS:-}" = 1 ] && { gd_log "[Rückfrage, automatisch Nein] $1"; return 1; }
    gd_whip --title "$1" --yesno "$2" "${3:-12}" "${4:-70}"
}

gd_input() {
    # gd_input "Titel" "Text" [vorgabe] [höhe] [breite] -> gibt Eingabe aus, Rückgabe != 0 bei Abbruch
    whiptail --title "$1" --inputbox "$2" "${4:-12}" "${5:-70}" "${3:-}" 3>&1 1>&2 2>&3
}

gd_warn_colors_on() {
    [ "${GD_HEADLESS:-}" = 1 ] && return 0
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
    [ "${GD_HEADLESS:-}" = 1 ] && return 0
    export NEWT_COLORS="${GD_OLD_NEWT_COLORS:-}"
}

# ---------------------------------------------------------------------------
# Fortschrittsbalken (echter Fortschritt: jeder Schritt meldet sich selbst)
# ---------------------------------------------------------------------------
GD_GAUGE_OPEN=0

gd_gauge_open() {
    # gd_gauge_open "Titel" "Starttext"
    [ "${GD_HEADLESS:-}" = 1 ] && { gd_log "== $1: $2"; return 0; }
    exec 7> >(whiptail --title "$1" --gauge "$2" 10 78 0)
    GD_GAUGE_OPEN=1
}

gd_progress() {
    # gd_progress <prozent> "Text"
    GD_PROGRESS_LAST="$1"   # gd_wait_for_apt zeigt seine Wartemeldung auf dem aktuellen Stand des Balkens
    gd_log "== [$1%] $2"
    # Headless: Das Log ist das Ziel (kein Balken); die Konsole bekommt die Zeile für "Jetzt ausführen" mit
    [ "${GD_HEADLESS:-}" = 1 ] && { echo "[$1%] $2"; return 0; }
    if [ "$GD_GAUGE_OPEN" = "1" ]; then
        # In einer Subshell schreiben: Ist whiptail beendet, trifft das SIGPIPE nur die Subshell
        # und nicht die laufende Installation. Danach wird ohne Balken weitergearbeitet.
        # Lange Texte umbrechen: Der Balken ist 78 Zeichen breit und schneidet sonst einfach ab
        local text
        text="$(printf '%s' "$2" | fold -s -w 72)"
        if ! ( printf 'XXX\n%d\n%s\nXXX\n' "$1" "$text" >&7 ) 2>/dev/null; then
            GD_GAUGE_OPEN=0
            { exec 7>&-; } 2>/dev/null   # nur den Balken schließen, stderr des Skripts unverändert lassen
            echo "[$1%] $2"
        fi
    else
        echo "[$1%] $2"
    fi
}

gd_gauge_close() {
    [ "${GD_HEADLESS:-}" = 1 ] && return 0
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

gd_step_optional() {
    # gd_step_optional <prozent> "Text" "Warnung bei Fehler" befehl [argumente...]
    # Wie gd_step, bricht aber nicht ab: der Fehler wird gesammelt (GD_WARNINGS) und am Ende angezeigt
    local pct="$1" text="$2" warn="$3"
    shift 3
    gd_progress "$pct" "$text"
    if ! "$@" >> "$GD_LOG" 2>&1; then
        gd_log "WARNUNG: $warn"
        GD_WARNINGS="${GD_WARNINGS:+$GD_WARNINGS\n}⚠ $warn"
    fi
    return 0
}

gd_fail() {
    gd_gauge_close
    # Optionaler Aufräum-Hook (z. B. Wartungsmodus beenden), gesetzt vom laufenden Ablauf
    if [ -n "${GD_FAIL_CLEANUP:-}" ] && declare -F "$GD_FAIL_CLEANUP" >/dev/null; then
        "$GD_FAIL_CLEANUP"
    fi
    if [ "${GD_HEADLESS:-}" = 1 ]; then
        local last_lines
        last_lines="$(tail -n 12 "$GD_LOG" 2>/dev/null | tr -d '\r' | cut -c1-200 | sed 's/^/    /')"
        gd_log "FEHLGESCHLAGEN: $1"
        gd_log "Letzte Log-Einträge vor dem Fehler:"
        [ -n "$last_lines" ] && printf '%s\n' "$last_lines" >> "$GD_LOG"
        echo "FEHLGESCHLAGEN: $1 (Details im Log: $GD_LOG)" >&2
        exit 1
    fi
    local tail_text
    tail_text="$(tail -n "$( [ -n "${GD_FAIL_HINT:-}" ] && echo 8 || echo 12)" "$GD_LOG" 2>/dev/null | tr -d '\r' | cut -c1-110)"
    gd_log "FEHLGESCHLAGEN: $1"
    # Titel: GD_FAIL_TITLE, sonst nach Ablauf – läuft eine Panel-Aktualisierung (GD_UPDATE_PHASE gesetzt, aber nicht
    # "fertig"), heißt es Aktualisierung, sonst Installation
    local title="${GD_FAIL_TITLE:-}"
    if [ -z "$title" ]; then
        if [ -n "${GD_UPDATE_PHASE:-}" ] && [ "$GD_UPDATE_PHASE" != "fertig" ]; then
            title="✖ Fehler bei der Aktualisierung"
        else
            title="✖ Fehler bei der Installation"
        fi
    fi
    # GD_FAIL_HINT: zusätzlicher Hinweis, z. B. wenn das Panel bereits fertig ist und nur ein späterer Schritt scheitert
    gd_whip --title "$title" --msgbox "Dieser Schritt ist fehlgeschlagen:\n$1${GD_FAIL_HINT:+\n\n$GD_FAIL_HINT}\n\nLetzte Log-Einträge:\n${tail_text}\n\nDas vollständige Log findest du hier:\n$GD_LOG" 30 118
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
    { gd_apt update; gd_apt_install "${miss[@]}"; } >/dev/null 2>&1 \
        || echo "Hinweis: Nicht alle Grundpakete konnten installiert werden (${miss[*]})."
    return 0
}

gd_apt_timers_stop() {
    # Hält die täglichen apt-Zeitgeber (apt-daily, apt-daily-upgrade) an, damit unattended-upgrades nicht mitten in der
    # Installation startet und die Paketverwaltung blockiert. Es wird nur gestoppt, nicht deaktiviert; gd_cleanup startet
    # die Zeitgeber beim Beenden wieder. GD_APT_TIMERS_STOPPED enthält die Namen der von uns gestoppten Zeitgeber.
    local t
    command -v systemctl >/dev/null 2>&1 || return 0
    for t in apt-daily.timer apt-daily-upgrade.timer; do
        if systemctl is-active --quiet "$t" 2>/dev/null && systemctl stop "$t" >/dev/null 2>&1; then
            GD_APT_TIMERS_STOPPED="${GD_APT_TIMERS_STOPPED:+$GD_APT_TIMERS_STOPPED }$t"
            gd_log "apt-Zeitgeber $t für die Dauer der Installation angehalten"
        fi
    done
    return 0
}

gd_wait_for_apt() {
    # Wartet (max. 20 Minuten), bis kein anderer apt/dpkg-Prozess mehr läuft – auf frischen Servern ist das meist
    # unattended-upgrades, das nach dem ersten Start Updates einspielt. Geprüft wird alle 2 Sekunden, eine Statusmeldung
    # gibt es alle 10 Sekunden (Fortschrittsbalken bzw. Headless-Ausgabe; sonst eine Datei, die gd_spinner anzeigt).
    local i=0 msg
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ $((i % 5)) -eq 0 ]; then
            msg="Warte auf laufenden Systemupdate-Prozess (unattended-upgrades) ... ($((i * 2)) s)"
            if [ "${GD_HEADLESS:-}" = 1 ] || [ "$GD_GAUGE_OPEN" = "1" ]; then
                gd_progress "${GD_PROGRESS_LAST:-0}" "$msg"
            else
                gd_log "$msg"
                [ -n "${GD_TMP:-}" ] && printf '%s\n' "$msg" > "$GD_TMP/apt-wait.msg" 2>/dev/null
                [ $i -eq 0 ] && echo "Warte auf laufenden Systemupdate-Prozess (unattended-upgrades) ..." >&2
            fi
        fi
        [ $i -ge 600 ] && { [ -n "${GD_TMP:-}" ] && rm -f "$GD_TMP/apt-wait.msg"; return 1; }
        sleep 2
        i=$((i + 1))
    done
    [ -n "${GD_TMP:-}" ] && rm -f "$GD_TMP/apt-wait.msg"
    return 0
}

gd_apt() {
    # gd_apt <apt-get Argumente...> – nicht-interaktiv, behält vorhandene Konfigurationsdateien
    gd_wait_for_apt || { echo "Ein anderer Installations-/Updateprozess blockiert apt."; return 1; }
    apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

gd_apt_update() {
    # Paketlisten aktualisieren. Ein kaputtes Fremd-Repository (abgelaufener Schlüssel, toter PPA) soll die
    # Einrichtung nicht abbrechen – erst eine fehlgeschlagene Paketinstallation ist ein echter Fehler.
    gd_apt update || { echo "Warnung: 'apt-get update' meldete Fehler (siehe oben) – es wird trotzdem fortgefahren."; return 0; }
}

gd_apt_has_candidate() {
    # gd_apt_has_candidate <paket> – gibt es für das Paket einen installierbaren Kandidaten? Prüft gezielt eine frisch
    # eingerichtete Paketquelle, deren Fehler gd_apt_update bewusst verschluckt. LC_ALL=C: apt übersetzt "Candidate".
    LC_ALL=C apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [0-9]'
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

# shellcheck disable=SC2034  # GD_OS_UNTESTED wird von installer.sh gelesen
gd_os_supported() {
    # Rückgabe 0 = getestet oder neuer als die getesteten Versionen, 1 = unbekanntes System.
    # Neuere Versionen (Debian > 13, Ubuntu > 26.04, auch künftige LTS wie 28.04) werden angenommen, aber mit
    # GD_OS_UNTESTED=true markiert: der Aufrufer weist darauf hin, dass sie nicht getestet sind.
    gd_os_detect
    GD_OS_UNTESTED=false
    case "$GD_OS_ID:$GD_OS_VERSION" in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) return 0 ;;
    esac
    case "$GD_OS_ID" in
        debian)
            [[ "$GD_OS_VERSION" =~ ^[0-9]+$ ]] && [ "$GD_OS_VERSION" -gt 13 ] && { GD_OS_UNTESTED=true; return 0; } ;;
        ubuntu)
            [[ "$GD_OS_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] && gd_version_ge "$GD_OS_VERSION" 26.04 \
                && { GD_OS_UNTESTED=true; return 0; } ;;
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
    local diff=$(( $(date -d "$end" +%s) - $(date +%s) ))
    # Abgelaufen (auch seit weniger als einem Tag) ergibt immer einen negativen Wert
    if [ "$diff" -lt 0 ]; then echo $(( -((-diff + 86399) / 86400) )); else echo $(( diff / 86400 )); fi
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

gd_curl() {
    # Einheitlicher Download-Helfer: folgt Weiterleitungen, bricht bei HTTP-Fehlern ab, wiederholt bei Netzwerkfehlern
    # (5 Versuche, 3 s Pause) und begrenzt Verbindungsaufbau (20 s) und Gesamtdauer (600 s). Weitere Optionen des
    # Aufrufers stehen danach und haben Vorrang (z. B. --max-time 15 oder -o <datei>).
    # --retry-all-errors gibt es erst ab curl 7.71; ohne die Option wird nur bei vorübergehenden Fehlern wiederholt.
    local retry_all=()
    curl --help all 2>/dev/null | grep -q -- '--retry-all-errors' && retry_all=(--retry-all-errors)
    curl -fsSL --retry 5 --retry-delay 3 "${retry_all[@]}" --connect-timeout 20 --max-time 600 "$@"
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
    # Für das Panel (pterodactyl/panel) werden nur Versionen der Major-Version GD_PANEL_MAJOR zurückgegeben
    local tag
    tag="$(gd_latest_tag "$1")" || return 1
    tag="${tag#v}"
    [[ "$tag" =~ ^[0-9]+(\.[0-9]+)+(-[0-9A-Za-z.]+)?$ ]] || return 1
    if [ "$1" = "pterodactyl/panel" ] && [ "${tag%%.*}" != "$GD_PANEL_MAJOR" ]; then
        # Neuestes Release hat eine andere Major-Version (z. B. 2.x): höchste Version der freigegebenen Major suchen
        tag="$(curl -fsSL --max-time 20 "https://api.github.com/repos/pterodactyl/panel/releases?per_page=50" 2>/dev/null \
            | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 \
            | grep -E "^v${GD_PANEL_MAJOR}\.[0-9]+\.[0-9]+$" | sed 's/^v//' | sort -V | tail -n1)"
        [ -n "$tag" ] || return 1
    fi
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

gd_dotenv_set() {
    # gd_dotenv_set <datei> <KEY> <WERT> – setzt bzw. ergänzt KEY=WERT in einer .env-Datei.
    # Der Wert wird unverändert geschrieben (auch mit |, & oder \ – sed würde daran scheitern): Er geht per
    # Umgebungsvariable an awk, nicht als Argument. Das Ergebnis entsteht in einer privaten Temp-Datei und wird
    # mit "cat >" zurückgeschrieben, damit Besitzer und Inode erhalten bleiben. Die .env bekommt dabei immer 640.
    local file="$1" key="$2" tmp rc
    [ -f "$file" ] || return 1
    # Ein Zeilenumbruch im Wert würde die Datei zerlegen
    case "$3" in *$'\n'*) return 1 ;; esac
    tmp="$(umask 077; mktemp "${GD_TMP:-/tmp}/dotenv.XXXXXX")" || return 1
    if grep -q "^${key}=" "$file"; then
        GD_DOTENV_VAL="$3" awk -v k="$key" 'index($0, k "=") == 1 { print k "=" ENVIRON["GD_DOTENV_VAL"]; next } { print }' "$file" > "$tmp"
        rc=$?
    else
        {
            cat "$file"
            # Die .env endet oft ohne Zeilenumbruch – sonst würde der neue Eintrag an die letzte Zeile angehängt
            if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then echo; fi
            printf '%s=%s\n' "$key" "$3"
        } > "$tmp"
        rc=$?
    fi
    # Bei einem Fehler ist die Temp-Datei unvollständig: dann die .env nicht anfassen
    if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
    cat "$tmp" > "$file" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    chmod 640 "$file"
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

gd_has_ipv4_route() {
    # Gibt es eine IPv4-Route ins Internet? (Pterodactyl, GitHub und Let's Encrypt brauchen IPv4)
    ip -4 route get 1.1.1.1 >/dev/null 2>&1
}

gd_local_ips() {
    # Alle globalen IPv4-Adressen dieses Servers (auch Zusatz- und Failover-IPs)
    ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}'
}

gd_has_ipv6() {
    # IPv6 tatsächlich nutzbar? (Modul geladen und nicht per sysctl abgeschaltet)
    grep -q . /proc/net/if_inet6 2>/dev/null || return 1
    [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]
}

gd_local_ips6() {
    # Alle globalen IPv6-Adressen dieses Servers
    ip -6 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}'
}

gd_ufw_active() {
    # Unabhängig von der Sprache des Systems (ufw übersetzt seine Ausgabe)
    command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q "^Status: active"
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

gd_resolve_aaaa() {
    dig +short AAAA "$1" @1.1.1.1 2>/dev/null | grep -E '^[0-9a-fA-F:]+$'
}

gd_ip_to_int() {
    # gd_ip_to_int <ipv4> -> 32-Bit-Zahl, Rückgabe 1 bei ungültiger Adresse
    local a b c d
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$1"
    # 10# verhindert, dass führende Nullen als Oktalzahl gelten
    [ $((10#$a)) -le 255 ] && [ $((10#$b)) -le 255 ] && [ $((10#$c)) -le 255 ] && [ $((10#$d)) -le 255 ] || return 1
    echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

gd_ip_in_cidr() {
    # gd_ip_in_cidr <ipv4> <netz/länge> – wahr, wenn die Adresse im Netz liegt
    local ip net bits mask
    ip="$(gd_ip_to_int "$1")" || return 1
    net="$(gd_ip_to_int "${2%/*}")" || return 1
    bits="${2#*/}"
    [[ "$bits" =~ ^[0-9]+$ ]] && [ "$bits" -le 32 ] || return 1
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    [ $(( ip & mask )) -eq $(( net & mask )) ]
}

# Offizielle IPv4-Netze des Cloudflare-Proxys, Quelle: https://www.cloudflare.com/ips-v4 (Stand: 19.10.2026).
# Bewusst fest hinterlegt, damit keine Netzabfrage nötig ist. Die Liste ändert sich selten.
GD_CLOUDFLARE_NETS=(
    173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18
    108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17
    162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
)

gd_is_cloudflare_ip() {
    # Liegt die IPv4-Adresse in einem Cloudflare-Proxy-Netz?
    local net
    for net in "${GD_CLOUDFLARE_NETS[@]}"; do
        gd_ip_in_cidr "$1" "$net" && return 0
    done
    return 1
}

gd_dns_check_dialog() {
    # gd_dns_check_dialog <domain> – zeigt Ergebnis, Rückgabe 0 = passt
    local domain="$1" server_ip dns_ips
    server_ip="$(gd_public_ip)"
    dns_ips="$(gd_resolve_a "$domain")"

    if [ -z "$dns_ips" ]; then
        gd_msg "✖ Domain-Überprüfung" "Für die Domain $domain wurde kein A-Eintrag (IPv4) gefunden.\n\nLege bei deinem Domain-Anbieter einen A-Eintrag an, der auf die IP-Adresse dieses Servers zeigt:\n\n${server_ip:-unbekannt}\n\nDNS-Änderungen können einige Minuten dauern." 16 78
        return 1
    fi

    # Treffer auf die öffentliche IP oder eine beliebige eigene Adresse (Zusatz-/Failover-IP)
    local ip match=""
    for ip in $server_ip $(gd_local_ips); do
        grep -qxF "$ip" <<< "$dns_ips" && { match="$ip"; break; }
    done
    if [ -n "$match" ]; then
        # Ein AAAA-Eintrag, der nicht auf diesen Server zeigt, lässt Let's Encrypt scheitern (IPv6 wird bevorzugt)
        local aaaa own6 a6 ok6=false
        aaaa="$(gd_resolve_aaaa "$domain")"
        if [ -n "$aaaa" ]; then
            own6="$(gd_local_ips6)"
            for a6 in $aaaa; do grep -qixF "$a6" <<< "$own6" && ok6=true; done
            if ! $ok6; then
                gd_yesno "⚠ IPv6-Eintrag passt nicht" "Die Domain $domain zeigt per IPv4 korrekt auf diesen Server ($match), hat aber zusätzlich einen IPv6-Eintrag (AAAA), der nicht zu diesem Server gehört:\n\n$(tr '\n' ' ' <<< "$aaaa")\n\nLet's Encrypt prüft bevorzugt über IPv6 – das SSL-Zertifikat schlägt dann fehl, und Besucher mit IPv6 landen auf dem falschen Server. Entferne den AAAA-Eintrag oder lass ihn auf diesen Server zeigen.\n\nTrotzdem fortfahren?" 18 78 || return 1
                return 0
            fi
        fi
        gd_msg "✔ Domain-Überprüfung" "Die Domain $domain ist mit der IP-Adresse dieses Servers ($match) verknüpft." 10 78
        return 0
    fi

    local first_ip hint=""
    first_ip="$(head -n1 <<< "$dns_ips")"
    if gd_is_cloudflare_ip "$first_ip"; then
        hint="\n\nDie Domain zeigt auf Cloudflare. Deaktiviere in Cloudflare den Proxy (graue Wolke, 'DNS only'), sonst können weder das SSL-Zertifikat noch Wings funktionieren."
    fi
    gd_msg "✖ Domain-Überprüfung" "Die Domain $domain zeigt auf eine andere IP-Adresse.\n\nDNS-Eintrag: $(tr '\n' ' ' <<< "$dns_ips")\nDieser Server: ${server_ip:-unbekannt}\n\nPrüfe die DNS-Einträge auf Schreibfehler.${hint}" 18 78
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
        local choice
        choice="$(gd_whip --title "Wie möchtest du fortfahren?" --menu "Die Domain $value zeigt (noch) nicht auf diesen Server." 14 74 3 \
            "1" "Domain korrigieren bzw. nach DNS-Änderung erneut prüfen" \
            "2" "Trotzdem fortfahren (z. B. Proxy/Weiterleitung – SSL kann scheitern)" \
            "3" "Abbrechen" 3>&1 1>&2 2>&3)" || return 1
        case "$choice" in
            2) echo "$value"; return 0 ;;
            3) return 1 ;;
        esac
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

gd_ask_email_optional() {
    # gd_ask_email_optional "Titel" "Text" -> gibt eine geprüfte E-Mail ODER einen leeren String aus (Feld leer =
    # anonym). Rückgabe 1 nur bei Abbruch.
    local title="$1" text="$2" value=""
    while true; do
        value="$(gd_input "$title" "$text" "$value" 22 78)" || return 1
        value="$(tr -d '[:space:]' <<< "$value")"
        if [ -z "$value" ]; then
            return 0
        fi
        if gd_valid_email "$value"; then
            echo "$value"
            return 0
        fi
        gd_msg "E-Mail-Adresse ungültig" "Bitte prüfe die E-Mail-Adresse und versuche es erneut oder lass das Feld leer." 9 60
    done
}

gd_certbot_mail_args() {
    # gd_certbot_mail_args <email> – setzt das Array GD_CERTBOT_MAIL für certbot (leere E-Mail = ohne Kontakt-Adresse).
    # Verwendung: gd_certbot_mail_args "$email"; certbot ... "${GD_CERTBOT_MAIL[@]}" ...
    if [ -z "${1:-}" ]; then
        GD_CERTBOT_MAIL=(--register-unsafely-without-email)
    else
        GD_CERTBOT_MAIL=(--email "$1")
    fi
}

gd_admin_email() {
    # gd_admin_email <email> <domain> – Adresse des Administrator-Kontos: die E-Mail oder admin@<domain>
    if [ -n "${1:-}" ]; then
        printf '%s' "$1"
    else
        printf 'admin@%s' "${2:-}"
    fi
}

gd_conf_has() {
    # gd_conf_has KEY – Rückgabe 0, wenn der Schlüssel in der Konfiguration steht (auch mit leerem Wert)
    [ -r "$GD_CONF_FILE" ] && grep -q "^$1=" "$GD_CONF_FILE"
}

# ---------------------------------------------------------------------------
# Weitere Skripte aus dem Repository ausführen/laden
# ---------------------------------------------------------------------------
gd_fetch() {
    # gd_fetch <pfad im repo> <ziel> – lokale Kopie bevorzugen, sonst herunterladen.
    local rel="$1" dest="$2"
    if [ -n "${GD_LOCAL_DIR:-}" ] && [ -f "$GD_LOCAL_DIR/$rel" ]; then
        cp "$GD_LOCAL_DIR/$rel" "$dest"
    else
        curl -fsSL "$GD_RAW/$rel" -o "$dest" || return 1
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
    gd_fetch "lib/$name.sh" "$GD_TMP/lib/$name.sh" || gd_die "Die Datei lib/$name.sh konnte nicht geladen werden (Internetverbindung prüfen)."
    # shellcheck disable=SC1090
    . "$GD_TMP/lib/$name.sh"
}

gd_run() {
    # gd_run <skript.sh> – lädt ein Skript des Projekts und führt es aus.
    # Die Standardeingabe bleibt das Terminal (wichtig für 'read'), danach geht es im Aufrufer weiter.
    local script="$1" target="$GD_TMP/run-$1"
    shift
    if ! gd_fetch "$script" "$target"; then
        gd_msg "Fehler" "Das Skript $script konnte nicht geladen werden. Prüfe die Internetverbindung (Details im Log)." 10 70
        return 1
    fi
    GD_LIB_DIR="${GD_LIB_DIR:-}" GD_LOCAL_DIR="${GD_LOCAL_DIR:-}" GD_BRANCH="$GD_BRANCH" \
        GD_LOG="$GD_LOG" GD_TMP="$GD_TMP" bash "$target" "$@" < /dev/tty
}
