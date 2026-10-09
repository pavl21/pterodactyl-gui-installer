#!/bin/bash
# Pfad: lib/autobackup.sh
# Automatische, inkrementelle Backups mit restic (verschlüsselt, dedupliziert) als systemd-Timer.
# Gesichert werden: Panel-Dateien, alle Datenbanken (Panel + Gameserver-Datenbanken), Konfigurationen
# (nginx, Wings, Zertifikate) und optional die Gameserver-Daten. Benötigt lib/common.sh und lib/backup.sh.

GD_AB_CONF="$GD_CONF_DIR/auto-backup.conf"
GD_AB_PASS="$GD_CONF_DIR/restic-passwort"
GD_AB_SCRIPT="/usr/local/sbin/germandactyl-backup"
GD_AB_DUMPS="$GD_BACKUP_ROOT/.db-dumps"
GD_AB_TAG="germandactyl-auto"

gd_ab_installed() { [ -f "$GD_AB_CONF" ] && [ -x "$GD_AB_SCRIPT" ]; }

gd_ab_load() {
    # Einstellungen laden und restic-Umgebung setzen
    # shellcheck disable=SC1090
    . "$GD_AB_CONF"
    export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$GD_AB_PASS" RESTIC_CACHE_DIR="/var/cache/restic"
}

gd_ab_write_conf() {
    # gd_ab_write_conf <repo> <server:true/false> <uhrzeit HH:MM> <täglich> <wöchentlich> <monatlich>
    mkdir -p "$GD_CONF_DIR"; chmod 700 "$GD_CONF_DIR"
    cat > "$GD_AB_CONF" <<EOF
# Angelegt von GermanDactyl Setup – Einstellungen der automatischen Backups
REPO=$(printf '%q' "$1")
INCLUDE_SERVERS=$2
TIME=$3
KEEP_DAILY=$4
KEEP_WEEKLY=$5
KEEP_MONTHLY=$6
EOF
    chmod 600 "$GD_AB_CONF"
}

gd_ab_write_script() {
    # Eigenständiges Backup-Skript (läuft ohne die Bibliotheken, z. B. nachts per Timer)
    cat > "$GD_AB_SCRIPT" <<'SCRIPT'
#!/bin/bash
# Pfad: /usr/local/sbin/germandactyl-backup – angelegt von GermanDactyl Setup
# Automatisches inkrementelles Backup mit restic. Aufruf manuell: germandactyl-backup
set -o pipefail
CONF=/etc/germandactyl/auto-backup.conf
STATE=/etc/germandactyl/setup.conf
LOG=/var/log/germandactyl-setup/auto-backup.log
DUMPS=/opt/pterodactyl/backups/.db-dumps
# shellcheck disable=SC1090
. "$CONF" || { echo "Konfiguration $CONF fehlt"; exit 1; }
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE=/etc/germandactyl/restic-passwort RESTIC_CACHE_DIR=/var/cache/restic
export LC_ALL=C
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# Nicht doppelt laufen lassen
exec 9>/run/germandactyl-backup.lock
# Exit-Code 75 = "läuft bereits" (kein Erfolg, aber auch kein Fehler; die Unit wertet 75 als erfolgreich)
flock -n 9 || { log "Ein Backup läuft bereits – übersprungen."; exit 75; }

rc=0
log "=== Backup gestartet ==="
# Verwaiste Sperren eines abgebrochenen Laufs (Neustart, Speichermangel) entfernen – nur alte, nicht aktive
restic unlock >> "$LOG" 2>&1

# Speicherort der Gameserver-Daten laut Wings-Konfiguration (system.data)
VOLUMES="$(awk '/^system:/{f=1;next} f && /^[^[:space:]]/{f=0} f && $1=="data:"{print $2; exit}' /etc/pterodactyl/config.yml 2>/dev/null | tr -d "'\"")"
VOLUMES="${VOLUMES:-/var/lib/pterodactyl/volumes}"

# 1) Alle Datenbanken einzeln sichern (Panel und Datenbanken der Gameserver)
DUMP=mariadb-dump; command -v mariadb-dump >/dev/null 2>&1 || DUMP=mysqldump
SQL=mariadb; command -v mariadb >/dev/null 2>&1 || SQL=mysql
rm -rf "$DUMPS"; mkdir -p "$DUMPS"; chmod 700 "$DUMPS"
if command -v "$SQL" >/dev/null 2>&1 && ! "$SQL" -e "SELECT 1" >/dev/null 2>&1; then
    log "FEHLER: Die Datenbank ist nicht erreichbar – Datenbanken wurden NICHT gesichert"; rc=1
elif command -v "$SQL" >/dev/null 2>&1; then
    # Genug Platz für die (unkomprimierten) Dumps? Sonst läuft die Platte voll und MariaDB/Gameserver stürzen ab
    need="$("$SQL" -N -e "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys');" 2>/dev/null)"
    free="$(df -PB1 "$DUMPS" | awk 'NR==2{print $4}')"
    if [ -n "$need" ] && [ -n "$free" ] && [ "$free" -lt $(( need + need / 5 + 1073741824 )) ]; then
        log "FEHLER: Zu wenig Speicherplatz für die Datenbank-Dumps (benötigt ca. $(( need / 1048576 )) MB + Reserve, frei $(( free / 1048576 )) MB)"; rc=1
    else
        while IFS= read -r db; do
            [ -z "$db" ] && continue
            if "$DUMP" --single-transaction --routines --triggers --databases "$db" > "$DUMPS/$db.sql" 2>>"$LOG" \
                && tail -n 3 "$DUMPS/$db.sql" | grep -q "Dump completed"; then
                log "Datenbank gesichert: $db ($(du -h "$DUMPS/$db.sql" | cut -f1))"
            else
                log "FEHLER: Datenbank $db konnte nicht gesichert werden"; rc=1
            fi
        done < <("$SQL" -N -e "SHOW DATABASES" | grep -vxE 'information_schema|performance_schema|mysql|sys' | grep -v '^#mysql50#')
    fi
fi
# Pelican nutzt standardmäßig SQLite: konsistente Kopie über die SQLite-Backup-API statt der laufenden Datei
PELICAN_SQLITE=/var/www/pelican/database/database.sqlite
if [ -f "$PELICAN_SQLITE" ]; then
    if php -r '$s = new SQLite3($argv[1], SQLITE3_OPEN_READONLY); $d = new SQLite3($argv[2]); exit($s->backup($d) ? 0 : 1);' \
        "$PELICAN_SQLITE" "$DUMPS/pelican-database.sqlite" 2>>"$LOG"; then
        log "Datenbank gesichert: Pelican (SQLite, $(du -h "$DUMPS/pelican-database.sqlite" | cut -f1))"
    else
        log "FEHLER: Pelican-Datenbank (SQLite) konnte nicht gesichert werden"; rc=1
    fi
fi

# 2) Dateien sichern (restic speichert nur Änderungen seit dem letzten Backup)
paths=()
for p in /var/www/pterodactyl /var/www/pelican /etc/pterodactyl /etc/pelican /etc/nginx /etc/letsencrypt /etc/germandactyl "$DUMPS"; do
    [ -e "$p" ] && paths+=("$p")
done
if [ "$INCLUDE_SERVERS" = "true" ]; then
    for p in "$VOLUMES" /var/lib/pelican/volumes; do [ -d "$p" ] && paths+=("$p"); done
fi
restic backup --tag germandactyl-auto --host "$(hostname)" \
    --exclude /var/www/pterodactyl/node_modules --exclude /var/www/pterodactyl/storage/framework/cache \
    --exclude /var/www/pelican/node_modules --exclude /var/www/pelican/storage/framework/cache \
    --exclude /etc/germandactyl/restic-passwort "${paths[@]}" >> "$LOG" 2>&1
brc=$?
# 3 = Snapshot erstellt, aber einzelne Dateien waren nicht lesbar (z. B. während des Schreibens) -> Warnung
if [ $brc -eq 3 ]; then log "Warnung: einzelne Dateien konnten nicht gelesen werden (siehe Log)"
elif [ $brc -ne 0 ]; then log "FEHLER: restic backup (Code $brc)"; rc=1; fi
rm -rf "$DUMPS"

# 3) Alte Stände nach den Aufbewahrungsregeln entfernen
# Nach Host und Tag gruppieren (nicht nach Pfaden) – sonst würden alte Stände nie entfernt, sobald sich
# die gesicherten Pfade ändern (z. B. Gameserver ab- oder zugeschaltet)
restic forget --tag germandactyl-auto --group-by host,tags --keep-last 3 --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" --prune >> "$LOG" 2>&1 || { log "FEHLER: Aufräumen alter Backups"; rc=1; }

# 4) Einmal pro Woche (sonntags) die Integrität des Archivs prüfen
if [ "$(date +%u)" = "7" ] || [ "${1:-}" = "--check" ]; then
    restic check >> "$LOG" 2>&1 && log "Integritätsprüfung erfolgreich" || { log "FEHLER: Integritätsprüfung"; rc=1; }
fi

if [ $rc -eq 0 ]; then
    sed -i '/^AUTO_BACKUP_LAST_OK=/d' "$STATE" 2>/dev/null
    printf 'AUTO_BACKUP_LAST_OK=%q\n' "$(date '+%F %T')" >> "$STATE"
    log "=== Backup erfolgreich ==="
else
    log "=== Backup mit Fehlern beendet ==="
fi
exit $rc
SCRIPT
    chmod 750 "$GD_AB_SCRIPT"
}

gd_ab_write_units() {
    local time="$1"
    cat > /etc/systemd/system/germandactyl-backup.service <<EOF
[Unit]
Description=GermanDactyl Setup – automatisches Backup (restic)
After=network-online.target mariadb.service

[Service]
Type=oneshot
# HOME, damit mariadb-dump eine /root/.my.cnf (root mit Passwort) findet
Environment=HOME=/root
ExecStart=$GD_AB_SCRIPT
SuccessExitStatus=75
Nice=10
IOSchedulingClass=idle
EOF
    cat > /etc/systemd/system/germandactyl-backup.timer <<EOF
[Unit]
Description=GermanDactyl Setup – tägliches Backup um ${time} Uhr

[Timer]
OnCalendar=*-*-* ${time}:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now germandactyl-backup.timer
}

gd_ab_setup() {
    # gd_ab_setup <repo> <server> <uhrzeit> – restic installieren, Archiv anlegen, Timer aktivieren
    local repo="$1"
    command -v restic >/dev/null 2>&1 || gd_apt_install restic || return 1
    gd_backup_prepare
    mkdir -p /var/cache/restic "$repo"
    chmod 700 "$repo"
    mkdir -p "$GD_CONF_DIR"; chmod 700 "$GD_CONF_DIR"
    if [ ! -s "$GD_AB_PASS" ]; then
        (umask 077; gd_gen_password 40 > "$GD_AB_PASS")
    fi
    gd_ab_write_conf "$repo" "$2" "$3" 7 4 6
    gd_ab_load
    if ! restic cat config >/dev/null 2>&1; then
        restic init || return 1
    fi
    gd_ab_write_script
    gd_ab_write_units "$3"
}

gd_ab_snapshots() {
    # Ausgabe: "<id> <datum uhrzeit> <server:ja/nein>" – neueste zuerst
    gd_ab_load
    restic snapshots --tag "$GD_AB_TAG" --json 2>/dev/null \
        | jq -r '.[] | "\(.short_id) \(.time[0:16] | sub("T"; " ")) \(if (.paths | index("/var/lib/pterodactyl/volumes")) then "ja" else "nein" end)"' \
        | sort -k2,3 -r
}

gd_ab_restore_panel() {
    # gd_ab_restore_panel <snapshot> – Panel-Dateien + Panel-Datenbank aus einem Snapshot einspielen
    local snap="$1" work db
    GD_RESTORE_INFO=""
    gd_ab_load
    work="$(gd_backup_workdir)"
    db="$(gd_backup_panel_db)"
    if ! restic restore "$snap" --target "$work" --include "$PTERO_DIR" --include "$GD_AB_DUMPS/$db.sql" >> "$GD_LOG" 2>&1; then
        rm -rf "$work"; GD_RESTORE_INFO="Der Snapshot konnte nicht gelesen werden."; return 1
    fi
    if [ -f "$work${GD_AB_DUMPS}/$db.sql" ]; then
        mkdir -p "$work/germandactyl-backup"
        gzip -c "$work${GD_AB_DUMPS}/$db.sql" > "$work/germandactyl-backup/panel-db.sql.gz"
        echo "$db" > "$work/germandactyl-backup/database-name"
    fi
    gd_backup_panel_apply "$work"
}

gd_ab_restore_db() {
    # gd_ab_restore_db <snapshot> <datenbank>
    local snap="$1" db="$2" work rc
    gd_ab_load
    work="$(gd_backup_workdir)"
    restic restore "$snap" --target "$work" --include "$GD_AB_DUMPS/$db.sql" >> "$GD_LOG" 2>&1 || { rm -rf "$work"; return 1; }
    gd_backup_db_import "$db" "$work${GD_AB_DUMPS}/$db.sql" >> "$GD_LOG" 2>&1
    rc=$?
    rm -rf "$work"
    return $rc
}

gd_ab_restore_server() {
    # gd_ab_restore_server <snapshot> [uuid] – ohne uuid alle Gameserver
    local snap="$1" uuid="${2:-}" target aside u rc
    gd_ab_load
    if [ -z "$uuid" ]; then
        # "Alle": jeden Server aus dem Snapshot einzeln – neuere Server bleiben unangetastet
        rc=0
        for u in $(gd_ab_list_servers "$snap"); do
            gd_ab_restore_server "$snap" "$u" || rc=1
        done
        return $rc
    fi
    target="$GD_VOLUMES_DIR/$uuid"
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
    # Datenbanken, die in einem Snapshot enthalten sind
    gd_ab_load
    restic ls "$1" "$GD_AB_DUMPS" 2>/dev/null | grep -oE '[^/]+\.sql$' | sed 's/\.sql$//' | sort
}

gd_ab_list_servers() {
    gd_ab_load
    restic ls "$1" "$GD_VOLUMES_DIR" 2>/dev/null | awk -F/ -v n="$(awk -F/ '{print NF}' <<< "$GD_VOLUMES_DIR")" 'NF == n + 1 {print $NF}' | sort -u
}
