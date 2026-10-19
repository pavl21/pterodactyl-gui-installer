#!/bin/bash
# Pfad: lib/autobackup.sh
# Automatische, inkrementelle Backups mit restic (verschlüsselt, dedupliziert) als systemd-Timer.
# Gesichert werden: Panel-Dateien, alle Datenbanken samt Benutzern und Rechten (Panel + Gameserver-Datenbanken),
# Konfigurationen (nginx, Wings, Zertifikate, systemd-Units, Crontabs) und optional die Gameserver-Daten.
# Ziel des Archivs: lokaler Pfad, SFTP, S3 oder rest-server. Benötigt lib/common.sh und lib/backup.sh.
#
# Ergebnis jedes Laufs (setup.conf): AUTO_BACKUP_LAST_RESULT = laufend|ok|fehler, AUTO_BACKUP_LAST_RUN = Zeitpunkt,
# AUTO_BACKUP_LAST_OK = letzter Erfolg, AUTO_BACKUP_LAST_CHECK = ok|fehler (letzte Integritätsprüfung).
# Fehler werden nur über die Anmeldeseite (MOTD) und die Statuszeile des Hauptmenüs gemeldet (keine E-Mail, keine Webhooks).

# GD_RESTORE_INFO, GD_BACKUP_SPACE_MSG und GD_AB_ERROR werden von den aufrufenden Skripten gelesen
# shellcheck disable=SC2034
GD_AB_CONF="$GD_CONF_DIR/auto-backup.conf"
GD_AB_PASS="$GD_CONF_DIR/restic-passwort"
GD_AB_SCRIPT="/usr/local/sbin/germandactyl-backup"
GD_AB_DUMPS="$GD_BACKUP_ROOT/.db-dumps"
GD_AB_TAG="germandactyl-auto"
# Snapshots, bei denen die Datenbanken nicht vollständig gesichert werden konnten (werden nie als "gutes" Backup gezählt)
GD_AB_TAG_BAD="germandactyl-unvollstaendig"
# Verzeichnisse für Units und Logrotate (per Umgebungsvariable überschreibbar, z. B. für Tests)
GD_AB_UNIT_DIR="${GD_AB_UNIT_DIR:-/etc/systemd/system}"
GD_AB_LOGROTATE="${GD_AB_LOGROTATE:-/etc/logrotate.d/germandactyl-backup}"

gd_ab_installed() { [ -f "$GD_AB_CONF" ] && [ -x "$GD_AB_SCRIPT" ]; }

gd_ab_load() {
    # Einstellungen laden und restic-Umgebung setzen (die Konfiguration kann Zugangsdaten per "export" setzen)
    # shellcheck disable=SC1090
    . "$GD_AB_CONF"
    export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$GD_AB_PASS" RESTIC_CACHE_DIR="/var/cache/restic"
}

gd_ab_scrub() {
    # Filter für Ausgaben: Passwörter in Repository-Adressen (rest:https://benutzer:passwort@host) nie ausgeben oder protokollieren
    sed -E 's#(://[^/:@[:space:]]+):[^@/[:space:]]*@#\1:***@#g'
}

gd_ab_mask_repo() {
    # gd_ab_mask_repo <repository> – Adresse ohne Passwort (für Anzeigen)
    printf '%s\n' "$1" | gd_ab_scrub
}

gd_ab_repo_kind() {
    # gd_ab_repo_kind <repository> -> lokal|sftp|s3|rest|sonstige
    case "$1" in
        /*) echo lokal ;;
        sftp:*) echo sftp ;;
        s3:*) echo s3 ;;
        rest:*) echo rest ;;
        *) echo sonstige ;;
    esac
}

gd_ab_repo_mount() {
    # gd_ab_repo_mount <lokaler pfad> – Einhängepunkt, auf dem der Pfad liegt (auch wenn er noch nicht existiert)
    local p="$1"
    while [ ! -e "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done
    df -P "$p" 2>/dev/null | awk 'NR==2{print $6}'
}

gd_ab_repo_on_root() {
    # gd_ab_repo_on_root <repository> – wahr, wenn das Archiv lokal auf derselben Platte wie / liegt
    [[ "$1" == /* ]] || return 1
    [ "$(gd_ab_repo_mount "$1")" = "/" ]
}

gd_ab_yesno_default_no() {
    # Wie gd_yesno, aber mit "Nein" als Vorauswahl (Headless: immer Nein)
    gd_whip --defaultno --title "$1" --yesno "$2" "${3:-12}" "${4:-70}"
}

gd_ab_write_conf() {
    # gd_ab_write_conf <repo> <server:true/false> <uhrzeit HH:MM> <täglich> <wöchentlich> <monatlich>
    # Zugangsdaten für S3 kommen aus GD_AB_AWS_KEY / GD_AB_AWS_SECRET; sind sie nicht gesetzt, bleiben bereits
    # gespeicherte erhalten. Die Datei ist nur für root lesbar (600) und wird nie protokolliert.
    local repo="$1" key="${GD_AB_AWS_KEY:-}" secret="${GD_AB_AWS_SECRET:-}" creds=""
    if [[ "$repo" == s3:* ]]; then
        if [ -z "$key" ] && [ -f "$GD_AB_CONF" ]; then
            # shellcheck disable=SC1090
            key="$( . "$GD_AB_CONF" 2>/dev/null; printf '%s' "${AWS_ACCESS_KEY_ID:-}")"
            # shellcheck disable=SC1090
            secret="$( . "$GD_AB_CONF" 2>/dev/null; printf '%s' "${AWS_SECRET_ACCESS_KEY:-}")"
        fi
        if [ -n "$key" ]; then
            creds="export AWS_ACCESS_KEY_ID=$(printf '%q' "$key")
export AWS_SECRET_ACCESS_KEY=$(printf '%q' "$secret")"
        fi
    fi
    mkdir -p "$GD_CONF_DIR"; chmod 700 "$GD_CONF_DIR"
    (
        umask 077
        cat > "$GD_AB_CONF" <<EOF
# Angelegt von GermanDactyl Setup – Einstellungen der automatischen Backups (enthält ggf. Zugangsdaten, nur für root lesbar)
REPO=$(printf '%q' "$repo")
INCLUDE_SERVERS=$2
TIME=$3
KEEP_DAILY=$4
KEEP_WEEKLY=$5
KEEP_MONTHLY=$6
${creds}
EOF
    )
    chmod 600 "$GD_AB_CONF"
}

gd_ab_write_script() {
    # Eigenständiges Backup-Skript (läuft ohne die Bibliotheken, z. B. nachts per Timer)
    cat > "$GD_AB_SCRIPT" <<'SCRIPT'
#!/bin/bash
# Pfad: /usr/local/sbin/germandactyl-backup – angelegt von GermanDactyl Setup
# Automatisches inkrementelles Backup mit restic. Aufruf manuell: germandactyl-backup
# Mit dem Argument --check läuft zusätzlich die Wochenwartung (Aufräumen mit prune und Integritätsprüfung).
set -o pipefail
umask 077
CONF=/etc/germandactyl/auto-backup.conf
STATE=/etc/germandactyl/setup.conf
LOG=/var/log/germandactyl-setup/auto-backup.log
DUMPS=/opt/pterodactyl/backups/.db-dumps
TAG_OK=germandactyl-auto
# Eigener Haupt-Tag für Snapshots ohne vollständige Datenbanken: "restic forget --tag germandactyl-auto" trifft
# jeden Snapshot, dessen Tag-Liste diesen Tag enthält – ein Zusatz-Tag würde also nicht schützen.
TAG_BAD=germandactyl-unvollstaendig
# Fester Host-Name im Archiv: Mit --host "$(hostname)" und --group-by host,tags würden alle bisherigen Snapshots
# nach einer Umbenennung des Servers eine eigene Gruppe bilden und nie mehr aufgeräumt. Snapshots, die vor dieser
# Umstellung unter dem echten Host-Namen angelegt wurden, bleiben als eigene Gruppe bestehen (sie werden weiter
# nach denselben Regeln ausgedünnt, aber nicht mehr mit den neuen Ständen zusammengefasst; Löschen: restic forget).
HOST_NAME=germandactyl
# shellcheck disable=SC1090
. "$CONF" || { echo "Konfiguration $CONF fehlt"; exit 1; }
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE=/etc/germandactyl/restic-passwort RESTIC_CACHE_DIR=/var/cache/restic
export LC_ALL=C
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
# Passwörter in Repository-Adressen (rest:https://benutzer:passwort@host) nie ins Log schreiben
scrub() { sed -E 's#(://[^/:@[:space:]]+):[^@/[:space:]]*@#\1:***@#g'; }
# restic mit gefilterter Ausgabe im Log; Rückgabe = Exit-Code von restic
restic_log() { restic "$@" 2>&1 | scrub >> "$LOG"; return "${PIPESTATUS[0]}"; }
state_set() {
    # state_set SCHLÜSSEL WERT – in setup.conf schreiben (für Statuszeile, Anmeldeseite und Analyse)
    [ -e "$STATE" ] || { mkdir -p "$(dirname "$STATE")"; : > "$STATE"; chmod 600 "$STATE"; }
    sed -i "/^$1=/d" "$STATE" 2>/dev/null
    printf '%s=%q\n' "$1" "$2" >> "$STATE"
}
finish() {
    # finish <exit-code> – Ergebnis immer festhalten
    local now
    now="$(date '+%F %T')"
    state_set AUTO_BACKUP_LAST_RUN "$now"
    if [ "$1" -eq 0 ]; then
        state_set AUTO_BACKUP_LAST_RESULT ok
        state_set AUTO_BACKUP_LAST_OK "$now"
        log "=== Backup erfolgreich ==="
    else
        state_set AUTO_BACKUP_LAST_RESULT fehler
        log "=== Backup mit Fehlern beendet ==="
    fi
    exit "$1"
}

# Nicht doppelt laufen lassen
exec 9>/run/germandactyl-backup.lock
# Exit-Code 75 = "läuft bereits" (kein Erfolg, aber auch kein Fehler; die Unit wertet 75 als erfolgreich).
# Der Zustand in setup.conf bleibt dabei unberührt (er gehört dem laufenden Backup).
flock -n 9 || { log "Ein Backup läuft bereits – übersprungen."; exit 75; }

rc=0
dbfail=0
trap 'rm -rf "$DUMPS"' EXIT
trap 'log "FEHLER: Das Backup wurde durch ein Signal abgebrochen"; finish 1' TERM INT HUP
# "laufend" festhalten: Stirbt das Skript hart (Speichermangel, kill -9), bleibt dieser Zustand stehen.
# Ist er älter als 6 Stunden, werten Statuszeile, Anmeldeseite und Analyse das als Fehler.
state_set AUTO_BACKUP_LAST_RESULT laufend
state_set AUTO_BACKUP_LAST_RUN "$(date '+%F %T')"
log "=== Backup gestartet ==="

# Wochenwartung (sonntags oder mit --check): Aufräumen mit prune und Integritätsprüfung
weekly=false
{ [ "$(date +%u)" = "7" ] || [ "${1:-}" = "--check" ]; } && weekly=true

# Ist das Archiv erreichbar (Netzwerkziel, eingehängtes Laufwerk) und das Passwort richtig? Sonst gar nicht erst Dumps erzeugen.
if ! out="$(timeout 120 restic cat config 2>&1)"; then
    log "FEHLER: Das Backup-Archiv ist nicht erreichbar oder das Passwort stimmt nicht:"
    printf '%s\n' "$out" | scrub | tail -n 5 >> "$LOG"
    finish 1
fi
# Verwaiste Sperren eines abgebrochenen Laufs (Neustart, Speichermangel) entfernen – nur alte, nicht aktive
restic_log unlock

# Speicherort der Gameserver-Daten und der Wings-Backups laut Wings-Konfiguration (system.data / system.backup_directory)
VOLUMES="$(awk '/^system:/{f=1;next} f && /^[^[:space:]]/{f=0} f && $1=="data:"{print $2; exit}' /etc/pterodactyl/config.yml 2>/dev/null | tr -d "'\"")"
VOLUMES="${VOLUMES:-/var/lib/pterodactyl/volumes}"
WINGS_BACKUPS="$(awk '/^system:/{f=1;next} f && /^[^[:space:]]/{f=0} f && $1=="backup_directory:"{print $2; exit}' /etc/pterodactyl/config.yml 2>/dev/null | tr -d "'\"")"
WINGS_BACKUPS="${WINGS_BACKUPS:-/var/lib/pterodactyl/backups}"

dberr() { log "FEHLER: $*"; dbfail=1; rc=1; }

# 1) Alle Datenbanken einzeln sichern (Panel und Datenbanken der Gameserver)
DUMP=mariadb-dump; command -v mariadb-dump >/dev/null 2>&1 || DUMP=mysqldump
SQL=mariadb; command -v mariadb >/dev/null 2>&1 || SQL=mysql
rm -rf "$DUMPS"; mkdir -p "$DUMPS"; chmod 700 "$DUMPS"
if command -v "$SQL" >/dev/null 2>&1 && ! "$SQL" -e "SELECT 1" >/dev/null 2>&1; then
    dberr "Die Datenbank ist nicht erreichbar – Datenbanken wurden NICHT gesichert"
elif command -v "$SQL" >/dev/null 2>&1; then
    # Genug Platz für die (unkomprimierten) Dumps? Sonst läuft die Platte voll und MariaDB/Gameserver stürzen ab
    need="$("$SQL" -N -e "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys');" 2>/dev/null)"
    free="$(df -PB1 "$DUMPS" | awk 'NR==2{print $4}')"
    if [ -n "$need" ] && [ -n "$free" ] && [ "$free" -lt $(( need + need / 5 + 1073741824 )) ]; then
        dberr "Zu wenig Speicherplatz für die Datenbank-Dumps (benötigt ca. $(( need / 1048576 )) MB + Reserve, frei $(( free / 1048576 )) MB)"
    else
        while IFS= read -r db; do
            [ -z "$db" ] && continue
            if "$DUMP" --single-transaction --routines --triggers --events --databases "$db" > "$DUMPS/$db.sql" 2>>"$LOG" \
                && tail -n 3 "$DUMPS/$db.sql" | grep -q "Dump completed"; then
                log "Datenbank gesichert: $db ($(du -h "$DUMPS/$db.sql" | cut -f1))"
            else
                dberr "Datenbank $db konnte nicht gesichert werden"
            fi
        done < <("$SQL" -N -e "SHOW DATABASES" | grep -vxE 'information_schema|performance_schema|mysql|sys' | grep -v '^#mysql50#')

        # Benutzer und Rechte (SHOW GRANTS), damit eine Wiederherstellung auf einem frischen Server funktioniert.
        # Jede Zeile wird mit ";" abgeschlossen; _grants.sql enthält Passwort-Hashes (Archiv ist verschlüsselt, Datei 600).
        grants="$DUMPS/_grants.sql"
        : > "$grants"; chmod 600 "$grants"
        q="'"; gcount=0; gfail=0
        if ! users="$("$SQL" -N --raw -e "SELECT User, Host FROM mysql.user WHERE User NOT IN ('root','mariadb.sys','mysql','','PUBLIC') ORDER BY User, Host" 2>>"$LOG")"; then
            dberr "Datenbank-Benutzer konnten nicht gelesen werden"; gfail=1
        else
            while IFS=$'\t' read -r gu gh; do
                [ -z "$gu" ] && continue
                if gout="$("$SQL" -N --raw -e "SHOW GRANTS FOR '${gu//$q/$q$q}'@'${gh//$q/$q$q}'" 2>>"$LOG")"; then
                    [ -n "$gout" ] && sed 's/$/;/' <<< "$gout" >> "$grants"
                    gcount=$((gcount + 1))
                else
                    dberr "Rechte von Datenbank-Benutzer $gu@$gh konnten nicht gesichert werden"; gfail=1
                fi
            done <<< "$users"
        fi
        if [ $gfail -eq 0 ]; then
            echo "FLUSH PRIVILEGES;" >> "$grants"
            log "Datenbank-Benutzer und Rechte gesichert ($gcount Benutzer)"
        fi
    fi
fi
# Pelican nutzt standardmäßig SQLite: konsistente Kopie über die SQLite-Backup-API statt der laufenden Datei
PELICAN_SQLITE=/var/www/pelican/database/database.sqlite
if [ -f "$PELICAN_SQLITE" ]; then
    if php -r '$s = new SQLite3($argv[1], SQLITE3_OPEN_READONLY); $d = new SQLite3($argv[2]); exit($s->backup($d) ? 0 : 1);' \
        "$PELICAN_SQLITE" "$DUMPS/pelican-database.sqlite" 2>>"$LOG"; then
        log "Datenbank gesichert: Pelican (SQLite, $(du -h "$DUMPS/pelican-database.sqlite" | cut -f1))"
    else
        dberr "Pelican-Datenbank (SQLite) konnte nicht gesichert werden"
    fi
fi

# 2) Dateien sichern (restic speichert nur Änderungen seit dem letzten Backup)
shopt -s nullglob
paths=()
for p in /var/www/pterodactyl /var/www/pelican /etc/pterodactyl /etc/pelican /etc/nginx /etc/letsencrypt /etc/germandactyl \
    /etc/systemd/system/wings.service /etc/systemd/system/pteroq.service \
    /etc/systemd/system/germandactyl-*.service /etc/systemd/system/germandactyl-*.timer \
    /var/spool/cron/crontabs /etc/mysql /etc/redis /etc/ufw /etc/fail2ban/jail.d \
    /usr/local/sbin/germandactyl-backup /usr/local/sbin/germandactyl-update "$DUMPS"; do
    [ -e "$p" ] && paths+=("$p")
done
if [ "$INCLUDE_SERVERS" = "true" ]; then
    for p in "$VOLUMES" /var/lib/pelican/volumes "$WINGS_BACKUPS"; do [ -d "$p" ] && paths+=("$p"); done
    running=0; note=""
    command -v docker >/dev/null 2>&1 && running="$(docker ps -q --filter label=Service=Pterodactyl 2>/dev/null | wc -l)"
    [ "${running:-0}" -gt 0 ] && note=" (gerade laufen $running Server)"
    log "Hinweis: Die Gameserver-Dateien werden im laufenden Betrieb gesichert${note}. Laufende Gameserver schreiben weiter, deshalb können Spielstände im Backup inkonsistent sein."
fi
shopt -u nullglob
TAG="$TAG_OK"
if [ $dbfail -ne 0 ]; then
    # Snapshot ohne vollständige Datenbanken: anderer Haupt-Tag, damit "forget" ihn nie mit vollständigen Ständen verrechnet
    TAG="$TAG_BAD"
    log "Warnung: Die Datenbanken sind nicht vollständig gesichert. Der Snapshot wird als \"$TAG_BAD\" abgelegt, ältere vollständige Stände bleiben erhalten."
fi
restic_log backup --tag "$TAG" --host "$HOST_NAME" \
    --exclude /var/www/pterodactyl/node_modules --exclude /var/www/pterodactyl/storage/framework/cache \
    --exclude /var/www/pelican/node_modules --exclude /var/www/pelican/storage/framework/cache \
    --exclude /etc/germandactyl/restic-passwort "${paths[@]}"
brc=$?
backup_ok=true
# 3 = Snapshot erstellt, aber einzelne Dateien waren nicht lesbar (z. B. während des Schreibens) -> Warnung
if [ $brc -eq 3 ]; then log "Warnung: einzelne Dateien konnten nicht gelesen werden (siehe Log)"
elif [ $brc -ne 0 ]; then log "FEHLER: restic backup (Code $brc)"; rc=1; backup_ok=false; fi
rm -rf "$DUMPS"

# 3) Alte Stände nach den Aufbewahrungsregeln entfernen
# Nach Host und Tag gruppieren (nicht nach Pfaden) – sonst würden alte Stände nie entfernt, sobald sich
# die gesicherten Pfade ändern (z. B. Gameserver ab- oder zugeschaltet).
# Das eigentliche Löschen der Daten (--prune) ist aufwendig und läuft nur bei der Wochenwartung.
prune=()
$weekly && prune=(--prune)
if [ $dbfail -ne 0 ]; then
    log "Aufräumen der vollständigen Stände übersprungen (dieser Lauf war unvollständig)."
elif ! $backup_ok; then
    log "Aufräumen übersprungen (das Backup ist fehlgeschlagen)."
else
    restic_log forget --tag "$TAG_OK" --group-by host,tags --keep-last 3 --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" "${prune[@]}" || { log "FEHLER: Aufräumen alter Backups"; rc=1; }
fi
# Unvollständige Snapshots getrennt begrenzen (nur die letzten 2 bleiben)
restic_log forget --tag "$TAG_BAD" --group-by host,tags --keep-last 2 "${prune[@]}" || { log "FEHLER: Aufräumen unvollständiger Backups"; rc=1; }

# 4) Wochenwartung: Integrität prüfen (Struktur und 10 % der Daten, jede Woche andere Teile sind eher zufällig)
if $weekly; then
    CHECK_ARGS=(--read-data-subset=10%)
    restic check --help 2>&1 | grep -q 'x%' || CHECK_ARGS=()
    if restic_log check "${CHECK_ARGS[@]}"; then
        log "Integritätsprüfung erfolgreich"; state_set AUTO_BACKUP_LAST_CHECK ok
    else
        log "FEHLER: Integritätsprüfung"; state_set AUTO_BACKUP_LAST_CHECK fehler; rc=1
    fi
    state_set AUTO_BACKUP_LAST_CHECK_TIME "$(date '+%F %T')"
fi
# Am 1. des Monats den Zwischenspeicher von restic aufräumen
if [ "$(date +%d)" = "01" ]; then
    restic_log cache --cleanup || log "Warnung: Der restic-Zwischenspeicher konnte nicht aufgeräumt werden"
fi

finish $rc
SCRIPT
    chmod 750 "$GD_AB_SCRIPT"
}

gd_ab_write_units() {
    # gd_ab_write_units <uhrzeit HH:MM> [repository] – Service, Timer und Logrotate-Datei schreiben, Timer aktivieren.
    # Ohne Angabe wird das geladene Repository (REPO aus gd_ab_load) verwendet.
    local time="$1" repo="${2:-${REPO:-}}" deps="" mnt
    if [[ "$repo" == /* ]]; then
        # Lokaler Pfad auf einem eigenen Laufwerk: erst starten, wenn es eingehängt ist (sonst landet das Archiv unbemerkt auf /)
        mnt="$(gd_ab_repo_mount "$repo")"
        [ -n "$mnt" ] && [ "$mnt" != "/" ] && deps="RequiresMountsFor=$repo"
    elif [ -n "$repo" ]; then
        # Netzwerkziel (SFTP, S3, rest-server): erst starten, wenn das Netzwerk steht
        deps="Wants=network-online.target"
    fi
    cat > "$GD_AB_UNIT_DIR/germandactyl-backup.service" <<EOF
[Unit]
Description=GermanDactyl Setup – automatisches Backup (restic)
After=network-online.target mariadb.service
${deps}

[Service]
Type=oneshot
# HOME, damit mariadb-dump eine /root/.my.cnf (root mit Passwort) und restic die SSH-Schlüssel in /root/.ssh findet
Environment=HOME=/root
ExecStart=$GD_AB_SCRIPT
SuccessExitStatus=75
Nice=10
IOSchedulingClass=idle
EOF
    cat > "$GD_AB_UNIT_DIR/germandactyl-backup.timer" <<EOF
[Unit]
Description=GermanDactyl Setup – tägliches Backup um ${time} Uhr

[Timer]
OnCalendar=*-*-* ${time}:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    # Das Log wöchentlich rotieren (8 Wochen behalten). Das Skript öffnet das Log bei jedem Schreiben neu, copytruncate ist unnötig.
    cat > "$GD_AB_LOGROTATE" <<'EOF'
# Angelegt von GermanDactyl Setup
/var/log/germandactyl-setup/auto-backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
    chmod 644 "$GD_AB_LOGROTATE"
    systemctl daemon-reload
    systemctl enable --now germandactyl-backup.timer
}

gd_ab_check_repo() {
    # Prüft den Zugriff auf das Archiv (restic cat config) und legt bei einem neuen Ziel ein Archiv an (restic init).
    # Rückgabe 1 mit klarer Meldung in GD_AB_ERROR (und auf der Standardausgabe). Zugangsdaten werden nie ausgegeben.
    local out rc
    GD_AB_ERROR=""
    out="$(LC_ALL=C timeout 120 restic cat config 2>&1)"; rc=$?
    if [ $rc -eq 0 ]; then
        return 0
    elif [ $rc -eq 124 ]; then
        GD_AB_ERROR="Zeitüberschreitung: Das Backup-Ziel antwortet nicht. Prüfe Adresse, Netzwerk und Firewall."
    elif grep -qi 'wrong password' <<< "$out"; then
        GD_AB_ERROR="Das Archiv existiert bereits, ist aber mit einem anderen Passwort angelegt worden. Das Passwort in $GD_AB_PASS passt nicht dazu. Wähle ein leeres Ziel oder trage das ursprüngliche Passwort dort ein."
    elif grep -qi 'Is there a repository' <<< "$out" || [[ "$(gd_ab_repo_kind "$REPO")" == lokal ]]; then
        # Noch kein Archiv an diesem Ziel: neu anlegen
        if out="$(LC_ALL=C timeout 300 restic init 2>&1)"; then
            printf '%s\n' "$out" | gd_ab_scrub | head -n 3
            return 0
        fi
        GD_AB_ERROR="Am Backup-Ziel konnte kein Archiv angelegt werden: $(printf '%s' "$out" | gd_ab_scrub | tail -n 2 | tr '\n' ' ' | cut -c1-160)"
    else
        GD_AB_ERROR="Das Backup-Ziel ist nicht erreichbar: $(printf '%s' "$out" | gd_ab_scrub | tail -n 2 | tr '\n' ' ' | cut -c1-160)"
    fi
    echo "FEHLER: $GD_AB_ERROR"
    return 1
}

gd_ab_setup() {
    # gd_ab_setup <repo> <server> <uhrzeit> – restic installieren, Ziel prüfen, Archiv anlegen, Timer aktivieren.
    # <repo>: lokaler Pfad oder restic-Adresse (sftp://..., s3:..., rest:...). Zugangsdaten: siehe gd_ab_write_conf.
    local repo="$1" old_conf=""
    GD_AB_ERROR=""
    command -v restic >/dev/null 2>&1 || gd_apt_install restic || { GD_AB_ERROR="restic konnte nicht installiert werden."; echo "FEHLER: $GD_AB_ERROR"; return 1; }
    gd_backup_prepare
    mkdir -p /var/cache/restic
    if [[ "$repo" == /* ]]; then
        mkdir -p "$repo"
        chmod 700 "$repo"
        # Ein Ordner mit fremdem Inhalt ist kein Archiv – nicht einfach hineinschreiben
        if [ ! -f "$repo/config" ] && [ -n "$(ls -A "$repo" 2>/dev/null)" ]; then
            GD_AB_ERROR="Der Ordner $repo ist nicht leer und enthält kein Backup-Archiv. Wähle einen leeren Ordner."
            echo "FEHLER: $GD_AB_ERROR"
            return 1
        fi
    fi
    mkdir -p "$GD_CONF_DIR"; chmod 700 "$GD_CONF_DIR"
    if [ ! -s "$GD_AB_PASS" ]; then
        (umask 077; gd_gen_password 40 > "$GD_AB_PASS")
    fi
    # Alte Einstellungen merken: Schlägt das neue Ziel fehl, darf eine bestehende Einrichtung nicht kaputtgehen
    if [ -f "$GD_AB_CONF" ]; then
        old_conf="$(mktemp)" && cp -p "$GD_AB_CONF" "$old_conf"
    fi
    gd_ab_write_conf "$repo" "$2" "$3" 7 4 6
    gd_ab_load
    if ! gd_ab_check_repo; then
        if [ -n "$old_conf" ]; then cp -p "$old_conf" "$GD_AB_CONF"; else rm -f "$GD_AB_CONF"; fi
        [ -n "$old_conf" ] && rm -f "$old_conf"
        return 1
    fi
    [ -n "$old_conf" ] && rm -f "$old_conf"
    gd_ab_write_script
    gd_ab_write_units "$3" "$repo"
}

gd_ab_snapshots() {
    # Ausgabe: "<id> <datum> <uhrzeit> <server:ja/nein> <ok|unv>" – neueste zuerst.
    # Snapshots ohne vollständige Datenbanken (Tag germandactyl-unvollstaendig) sind mit "unv" markiert.
    # Gameserver-Daten erkennt man am Wings-Datenordner (GD_VOLUMES_DIR laut config.yml) bzw. dem von Pelican.
    local vol="${GD_VOLUMES_DIR:-/var/lib/pterodactyl/volumes}"
    gd_ab_load
    restic snapshots --tag "$GD_AB_TAG" --tag "$GD_AB_TAG_BAD" --json 2>/dev/null \
        | jq -r --arg v "$vol" --arg bad "$GD_AB_TAG_BAD" '.[] | "\(.short_id) \(.time[0:16] | sub("T"; " ")) \(if any((.paths // [])[]; . == $v or . == "/var/lib/pelican/volumes") then "ja" else "nein" end) \(if ((.tags // []) | index($bad)) then "unv" else "ok" end)"' \
        | sort -k2,3 -r
}

gd_ab_volume_dirs() {
    # Datenordner der Gameserver (Pterodactyl bzw. laut Wings-Konfiguration und Pelican), einer je Zeile
    printf '%s\n' "${GD_VOLUMES_DIR:-/var/lib/pterodactyl/volumes}"
    [ "${GD_VOLUMES_DIR:-}" != "/var/lib/pelican/volumes" ] && echo "/var/lib/pelican/volumes"
    return 0
}

gd_ab_restore_panel() {
    # gd_ab_restore_panel <snapshot> – Panel-Dateien + Panel-Datenbank aus einem Snapshot einspielen.
    # Erst werden nur die Panel-Dateien geholt, daraus der Datenbankname (.env des Snapshots) gelesen und dann genau
    # dieser Dump nachgeladen – der Name auf dem aktuellen Server kann sich davon unterscheiden.
    local snap="$1" work db
    GD_RESTORE_INFO=""
    gd_ab_load
    work="$(gd_backup_workdir)"
    if ! restic restore "$snap" --target "$work" --include "$PTERO_DIR" >> "$GD_LOG" 2>&1; then
        rm -rf "$work"; GD_RESTORE_INFO="Der Snapshot konnte nicht gelesen werden."; return 1
    fi
    db="$(grep -E '^DB_DATABASE=' "$work$PTERO_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d "\"'\r")"
    [ -z "$db" ] && db="$(gd_backup_panel_db)"
    if [[ "$db" == */* ]] || [[ "$db" == .* ]]; then
        rm -rf "$work"; GD_RESTORE_INFO="Der Datenbankname in der .env des Snapshots ist ungültig."; return 1
    fi
    restic restore "$snap" --target "$work" --include "$GD_AB_DUMPS/$db.sql" >> "$GD_LOG" 2>&1
    if [ -f "$work${GD_AB_DUMPS}/$db.sql" ]; then
        mkdir -p "$work/germandactyl-backup"
        gzip -c "$work${GD_AB_DUMPS}/$db.sql" > "$work/germandactyl-backup/panel-db.sql.gz"
        rm -f "$work${GD_AB_DUMPS}/$db.sql"
        echo "$db" > "$work/germandactyl-backup/database-name"
    elif ! gd_yesno "⚠ Datenbank-Dump fehlt" "Datenbank-Dump fehlt im Snapshot – nur Dateien wiederherstellen?\n\nDer Snapshot enthält keine Sicherung der Datenbank '$db' (z. B. weil die Datenbank beim Backup nicht erreichbar war, siehe Markierung \"ohne Datenbanken\"). Die aktuelle Datenbank bleibt dann unverändert und passt eventuell nicht zu den Panel-Dateien.\n\nNur die Dateien wiederherstellen?" 17 74; then
        rm -rf "$work"; GD_RESTORE_INFO="Abgebrochen. Es wurde nichts verändert."; return 1
    fi
    gd_backup_panel_apply "$work"
}

gd_ab_restore_db() {
    # gd_ab_restore_db <snapshot> <datenbank> – Pteroq und Cron ruht währenddessen (gd_backup_db_import)
    local snap="$1" db="$2" work rc
    gd_ab_load
    work="$(gd_backup_workdir)"
    restic restore "$snap" --target "$work" --include "$GD_AB_DUMPS/$db.sql" >> "$GD_LOG" 2>&1 || { rm -rf "$work"; return 1; }
    gd_backup_db_import "$db" "$work${GD_AB_DUMPS}/$db.sql" >> "$GD_LOG" 2>&1
    rc=$?
    rm -rf "$work"
    return $rc
}

gd_ab_has_grants() {
    # gd_ab_has_grants <snapshot> – enthält der Snapshot die Sicherung der Datenbank-Benutzer?
    gd_ab_load
    restic ls "$1" "$GD_AB_DUMPS" 2>/dev/null | grep -q '/_grants\.sql$'
}

gd_ab_restore_grants() {
    # gd_ab_restore_grants <snapshot> – Datenbank-Benutzer und Rechte (_grants.sql) einspielen, NUR auf ausdrückliche
    # Nachfrage (Vorauswahl "Nein"): Bestehende Benutzer würden dabei überschrieben (Passwörter, Rechte).
    # Rückgabe 0 = eingespielt, 1 = Fehler, 2 = nicht gewünscht oder nicht im Snapshot. GD_RESTORE_INFO beschreibt das Ergebnis.
    local snap="$1" work rc
    GD_RESTORE_INFO=""
    gd_ab_load
    if ! gd_ab_has_grants "$snap"; then
        GD_RESTORE_INFO="Dieser Stand enthält keine Datenbank-Benutzer (er stammt aus einer älteren Version der Backups)."
        return 2
    fi
    gd_ab_yesno_default_no "⚠ Datenbank-Benutzer einspielen?" "Dieser Stand enthält die Datenbank-Benutzer und ihre Rechte (z. B. den Benutzer des Panels und die Benutzer der Gameserver-Datenbanken).\n\nBeim Einspielen werden vorhandene Benutzer mit gleichem Namen überschrieben (Passwörter und Rechte). Das ist vor allem auf einem frischen Server nötig, auf dem diese Benutzer noch fehlen.\n\nBenutzer und Rechte aus dem Stand einspielen?" 16 74 || { GD_RESTORE_INFO="Die Datenbank-Benutzer wurden nicht verändert."; return 2; }
    work="$(gd_backup_workdir)"
    if ! restic restore "$snap" --target "$work" --include "$GD_AB_DUMPS/_grants.sql" >> "$GD_LOG" 2>&1 || [ ! -f "$work${GD_AB_DUMPS}/_grants.sql" ]; then
        rm -rf "$work"; GD_RESTORE_INFO="Die Sicherung der Datenbank-Benutzer konnte nicht gelesen werden."; return 1
    fi
    gd_mysql < "$work${GD_AB_DUMPS}/_grants.sql" >> "$GD_LOG" 2>&1
    rc=$?
    rm -rf "$work"
    if [ $rc -eq 0 ]; then GD_RESTORE_INFO="Die Datenbank-Benutzer und ihre Rechte wurden eingespielt."
    else GD_RESTORE_INFO="Die Datenbank-Benutzer konnten nicht (vollständig) eingespielt werden."; fi
    return $rc
}

gd_ab_restore_config() {
    # gd_ab_restore_config <snapshot> – stellt Konfigurationen aus einem Snapshot wieder her: nginx, Zertifikate
    # (/etc/letsencrypt), Wings/Panel-Konfiguration (/etc/pterodactyl bzw. /etc/pelican), /etc/germandactyl, die systemd-Units
    # und die Crontabs. Vorher wird der aktuelle Stand nach $GD_BACKUP_ROOT/konfig-vor-wiederherstellung-<datum>.tar.gz gesichert.
    # Die Einstellungen der automatischen Backups (auto-backup.conf) bleiben unangetastet.
    local snap="$1" work safety p e rest="" info=""
    local -a pats=() existing=()
    GD_RESTORE_INFO=""
    gd_ab_load
    pats=(/etc/nginx /etc/letsencrypt /etc/pterodactyl /etc/pelican /etc/germandactyl
        /etc/systemd/system/wings.service /etc/systemd/system/pteroq.service
        '/etc/systemd/system/germandactyl-*.service' '/etc/systemd/system/germandactyl-*.timer'
        /var/spool/cron/crontabs)
    gd_backup_prepare
    # 1) Aktuellen Stand sichern (Rückweg bei Problemen)
    safety="$GD_BACKUP_ROOT/konfig-vor-wiederherstellung-$(date +%Y%m%d-%H%M%S).tar.gz"
    shopt -s nullglob
    for p in "${pats[@]}"; do
        # Muster mit * werden hier bewusst aufgelöst; nicht vorhandene Pfade überspringen
        # shellcheck disable=SC2086
        for e in $p; do [ -e "$e" ] && existing+=("${e#/}"); done
    done
    shopt -u nullglob
    if [ ${#existing[@]} -gt 0 ]; then
        if ! ( umask 077; tar -czf "$safety" -C / "${existing[@]}" 2>>"$GD_LOG" ); then
            rm -f "$safety"
            GD_RESTORE_INFO="Der aktuelle Stand konnte nicht gesichert werden (Speicherplatz?). Es wurde nichts verändert."
            return 1
        fi
        chmod 600 "$safety"
    fi
    # 2) Erst in einen Arbeitsordner holen (prüft den Snapshot), dann über die Dateien kopieren
    work="$(gd_backup_workdir)"
    local -a inc=()
    for p in "${pats[@]}"; do inc+=(--include "$p"); done
    if ! restic restore "$snap" --target "$work" "${inc[@]}" --exclude /etc/germandactyl/auto-backup.conf >> "$GD_LOG" 2>&1; then
        rm -rf "$work"; GD_RESTORE_INFO="Der Snapshot konnte nicht gelesen werden. Es wurde nichts verändert."; return 1
    fi
    local copied=0 rc=0
    for p in etc/nginx etc/letsencrypt etc/pterodactyl etc/pelican etc/germandactyl var/spool/cron/crontabs; do
        [ -d "$work/$p" ] || continue
        mkdir -p "/$p"
        cp -a "$work/$p/." "/$p/" 2>>"$GD_LOG" || rc=1
        copied=$((copied + 1))
    done
    shopt -s nullglob
    for p in "$work"/etc/systemd/system/wings.service "$work"/etc/systemd/system/pteroq.service \
        "$work"/etc/systemd/system/germandactyl-*.service "$work"/etc/systemd/system/germandactyl-*.timer; do
        [ -e "$p" ] || continue
        cp -a "$p" /etc/systemd/system/ 2>>"$GD_LOG" || rc=1
        copied=$((copied + 1))
    done
    shopt -u nullglob
    rm -rf "$work"
    if [ "$copied" -eq 0 ]; then
        GD_RESTORE_INFO="Der Snapshot enthält keine dieser Konfigurationen."
        return 1
    fi
    # 3) Dienste neu laden
    systemctl daemon-reload >> "$GD_LOG" 2>&1
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t >> "$GD_LOG" 2>&1; then
            systemctl reload nginx >> "$GD_LOG" 2>&1 || { rc=1; rest+=" nginx konnte nicht neu geladen werden."; }
        else
            rc=1; rest+=" Die wiederhergestellte nginx-Konfiguration ist fehlerhaft (nginx -t) – nginx wurde NICHT neu geladen."
        fi
    fi
    if systemctl cat wings >/dev/null 2>&1; then
        systemctl restart wings >> "$GD_LOG" 2>&1 || { rc=1; rest+=" Wings konnte nicht neu gestartet werden."; }
    fi
    [ -f "$safety" ] && info="\n\nDer vorherige Stand liegt in:\n$safety"
    if [ $rc -eq 0 ]; then
        GD_RESTORE_INFO="Die Konfiguration wurde wiederhergestellt: nginx, Zertifikate, Wings- und Panel-Konfiguration, systemd-Units und Crontabs (soweit im Stand enthalten).${info}"
    else
        GD_RESTORE_INFO="Die Konfiguration wurde eingespielt, aber nicht alles lief fehlerfrei.${rest}${info}"
    fi
    return $rc
}

gd_ab_restore_server() {
    # gd_ab_restore_server <snapshot> [uuid] – ohne uuid alle Gameserver
    local snap="$1" uuid="${2:-}" target aside u rc d vol=""
    gd_ab_load
    if [ -z "$uuid" ]; then
        # "Alle": jeden Server aus dem Snapshot einzeln – neuere Server bleiben unangetastet
        rc=0
        for u in $(gd_ab_list_servers "$snap"); do
            gd_ab_restore_server "$snap" "$u" || rc=1
        done
        return $rc
    fi
    # Liegt der Server im Datenordner von Wings oder von Pelican?
    for d in $(gd_ab_volume_dirs); do
        if restic ls "$snap" "$d/$uuid" 2>/dev/null | head -n1 | grep -q .; then vol="$d"; break; fi
    done
    vol="${vol:-$GD_VOLUMES_DIR}"
    target="$vol/$uuid"
    aside="${target}.vor-wiederherstellung-$(date +%Y%m%d-%H%M%S)"
    [ -d "$target" ] && { mv "$target" "$aside" || return 1; }
    if restic restore "$snap" --target / --include "$target" >> "$GD_LOG" 2>&1 && [ -d "$target" ]; then
        rm -rf "$aside"
        return 0
    fi
    rm -rf "$target"
    [ -d "$aside" ] && mv "$aside" "$target"
    return 1
}

gd_ab_list_dbs() {
    # Datenbanken, die in einem Snapshot enthalten sind (ohne die Sicherung der Benutzer, _grants.sql)
    gd_ab_load
    restic ls "$1" "$GD_AB_DUMPS" 2>/dev/null | grep -oE '[^/]+\.sql$' | sed 's/\.sql$//' | grep -vx '_grants' | sort
}

gd_ab_list_servers() {
    # UUIDs der Gameserver in einem Snapshot (Datenordner von Wings und von Pelican)
    local d
    gd_ab_load
    for d in $(gd_ab_volume_dirs); do
        restic ls "$1" "$d" 2>/dev/null | awk -F/ -v n="$(awk -F/ '{print NF}' <<< "$d")" 'NF == n + 1 {print $NF}'
    done | sort -u
}
