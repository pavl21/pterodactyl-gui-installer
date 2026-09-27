#!/bin/bash
# Pfad: lib/backup.sh
# Gemeinsame Backup-Funktionen (Backup-Verwaltung und Deinstallation).
# Panel-Backup  = Panel-Dateien (ohne node_modules) + vollständiger Datenbank-Dump
# Server-Backup = Wings-Volumes aller Gameserver
# Jeder Schritt wird geprüft: Ein Backup gilt nur als erfolgreich, wenn tar, gzip UND der Datenbank-Dump fehlerfrei waren.

GD_BACKUP_ROOT="/opt/pterodactyl/backups"
GD_BACKUP_PANEL="$GD_BACKUP_ROOT/panel"
GD_BACKUP_SERVER="$GD_BACKUP_ROOT/server"
GD_VOLUMES_DIR="/var/lib/pterodactyl/volumes"
GD_BACKUP_KEEP=5   # Anzahl der Backups, die je Art behalten werden

gd_backup_prepare() {
    mkdir -p "$GD_BACKUP_PANEL" "$GD_BACKUP_SERVER"
    chmod 700 "$GD_BACKUP_ROOT"
    command -v pv >/dev/null 2>&1 || gd_apt_install pv >> "$GD_LOG" 2>&1
    return 0
}

gd_backup_name() {
    # Sortierbar und ohne ":" im Namen (Sekunden verhindern Überschreiben bei zwei Backups pro Minute)
    echo "Backup_$(date +%Y-%m-%d_%H-%M-%S).tar.gz"
}

gd_backup_rotate() {
    # Nur die neuesten $GD_BACKUP_KEEP Backups im Verzeichnis behalten
    find "$1" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n +$((GD_BACKUP_KEEP + 1)) | cut -d' ' -f2- | xargs -r -d '\n' rm -f
}

gd_backup_workdir() {
    # Arbeitsordner auf derselben Partition wie die Backups (/tmp ist oft klein oder ein RAM-Laufwerk)
    local dir="$GD_BACKUP_ROOT/.arbeit-$$"
    rm -rf "$dir"
    mkdir -p "$dir"
    chmod 700 "$dir"
    echo "$dir"
}

gd_backup_panel_db() {
    # Liest den Namen der Panel-Datenbank aus der .env
    local db
    db="$(grep -E '^DB_DATABASE=' "$PTERO_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"')"
    echo "${db:-panel}"
}

gd_backup_dump_db() {
    # gd_backup_dump_db <datenbank> <zieldatei.sql.gz> – Rückgabe != 0, wenn der Dump unvollständig ist
    local db="$1" target="$2" status
    gd_mysqldump --single-transaction --routines --triggers --databases "$db" 2>>"$GD_LOG" | gzip > "$target"
    status=("${PIPESTATUS[@]}")
    if [ "${status[0]}" -ne 0 ] || [ "${status[1]}" -ne 0 ]; then
        echo "Datenbank-Dump fehlgeschlagen (Dump: ${status[0]}, gzip: ${status[1]})" >> "$GD_LOG"
        return 1
    fi
    # Ein vollständiger Dump endet mit "-- Dump completed"
    if ! gunzip -c "$target" | tail -n 3 | grep -q "Dump completed"; then
        echo "Datenbank-Dump ist unvollständig: $target" >> "$GD_LOG"
        return 1
    fi
    return 0
}

gd_backup_tar() {
    # gd_backup_tar <zieldatei> <mit_balken:true/false> <titel> <größe in Byte> <tar-argumente...>
    # Packt mit Fortschrittsanzeige; wertet die Rückgabewerte aller Teile der Pipeline aus.
    local target="$1" gauge="$2" title="$3" size="$4" rcfile
    shift 4
    rcfile="$(mktemp)"
    if [ "$gauge" = "true" ]; then
        {
            tar -cf - "$@" 2>>"$GD_LOG" | pv -n -s "$size" | gzip > "$target"
            echo "${PIPESTATUS[*]}" > "$rcfile"
        } 2>&1 | gd_whip --title "$title" --gauge "Das Backup wird erstellt..." 7 60 0
    else
        tar -cf - "$@" 2>>"$GD_LOG" | gzip > "$target"
        echo "${PIPESTATUS[0]} 0 ${PIPESTATUS[1]}" > "$rcfile"
    fi
    local tar_rc pv_rc gz_rc
    read -r tar_rc pv_rc gz_rc < "$rcfile"
    rm -f "$rcfile"
    echo "tar=$tar_rc pv=$pv_rc gzip=$gz_rc -> $target" >> "$GD_LOG"
    # tar liefert 1, wenn sich Dateien während des Lesens geändert haben (laufende Server) – das ist nur eine Warnung
    [ "${tar_rc:-2}" -le 1 ] && [ "${pv_rc:-1}" -eq 0 ] && [ "${gz_rc:-1}" -eq 0 ] && gzip -t "$target" 2>>"$GD_LOG"
}

gd_backup_panel_create() {
    # gd_backup_panel_create <zieldatei> <mit_balken:true/false>
    local target="$1" gauge="$2" work db
    [ -d "$PTERO_DIR" ] || { echo "Kein Panel unter $PTERO_DIR gefunden." >> "$GD_LOG"; return 1; }
    work="$(gd_backup_workdir)"
    mkdir -p "$work/germandactyl-backup"
    db="$(gd_backup_panel_db)"
    if ! gd_backup_dump_db "$db" "$work/germandactyl-backup/panel-db.sql.gz"; then
        rm -rf "$work"
        return 1
    fi
    echo "$db" > "$work/germandactyl-backup/database-name"
    date '+%F %T' > "$work/germandactyl-backup/erstellt"
    if ! gd_backup_tar "$target" "$gauge" "Panel-Backup" "$(du -sb --exclude=node_modules "$PTERO_DIR" | cut -f1)" \
        --exclude="${PTERO_DIR#/}/node_modules" -C / "${PTERO_DIR#/}" -C "$work" germandactyl-backup; then
        rm -rf "$work"; rm -f "$target"
        return 1
    fi
    rm -rf "$work"
    chmod 600 "$target"
    gd_backup_rotate "$GD_BACKUP_PANEL"
    return 0
}

gd_backup_server_create() {
    # gd_backup_server_create <zieldatei> <mit_balken:true/false>
    local target="$1" gauge="$2"
    [ -d "$GD_VOLUMES_DIR" ] || { echo "Keine Gameserver-Daten unter $GD_VOLUMES_DIR." >> "$GD_LOG"; return 1; }
    if ! gd_backup_tar "$target" "$gauge" "Server-Backup" "$(du -sb "$GD_VOLUMES_DIR" | cut -f1)" -C / "${GD_VOLUMES_DIR#/}"; then
        rm -f "$target"
        return 1
    fi
    chmod 600 "$target"
    gd_backup_rotate "$GD_BACKUP_SERVER"
    return 0
}

gd_backup_stop_servers() {
    # Wings und alle Gameserver-Container anhalten (für konsistente Backups/Wiederherstellungen)
    systemctl stop wings 2>/dev/null
    if command -v docker >/dev/null 2>&1; then
        docker ps -q --filter label=Service=Pterodactyl | xargs -r docker stop >> "$GD_LOG" 2>&1
    fi
    return 0
}

gd_backup_server_names() {
    # Ausgabe: "<uuid> <name>" aller Server laut Panel-Datenbank (leer, wenn kein Panel auf diesem Server)
    [ -f "$PTERO_DIR/.env" ] || return 0
    gd_mysql -N -D "$(gd_backup_panel_db)" -e "SELECT uuid, name FROM servers;" 2>/dev/null
}

gd_backup_panel_restore() {
    # gd_backup_panel_restore <backupdatei> – setzt GD_RESTORE_INFO mit einer Beschreibung des Ergebnisses
    local file="$1" work
    GD_RESTORE_INFO=""
    work="$(gd_backup_workdir)"
    tar -xzf "$file" -C "$work" 2>>"$GD_LOG" || { rm -rf "$work"; GD_RESTORE_INFO="Das Backup konnte nicht entpackt werden."; return 1; }
    gd_backup_panel_apply "$work"
}

gd_backup_panel_apply() {
    # gd_backup_panel_apply <arbeitsordner> – spielt einen entpackten Stand ein:
    #   <arbeitsordner>/var/www/pterodactyl und optional <arbeitsordner>/germandactyl-backup/panel-db.sql.gz
    # Bei Fehlern wird automatisch der vorherige Stand wiederhergestellt. Der Arbeitsordner wird entfernt.
    local work="$1" stamp old db current_db safety
    stamp="$(date +%Y%m%d-%H%M%S)"
    if [ ! -f "$work/${PTERO_DIR#/}/artisan" ]; then
        rm -rf "$work"; GD_RESTORE_INFO="Das Backup enthält keine Panel-Dateien."; return 1
    fi
    if [ -f "$work/germandactyl-backup/panel-db.sql.gz" ] \
        && ! gunzip -c "$work/germandactyl-backup/panel-db.sql.gz" | tail -n 3 | grep -q "Dump completed"; then
        rm -rf "$work"; GD_RESTORE_INFO="Der Datenbank-Dump im Backup ist unvollständig. Es wurde nichts verändert."; return 1
    fi

    # Sicherung des aktuellen Stands, falls etwas schiefgeht
    old="${PTERO_DIR}.vor-wiederherstellung-${stamp}"
    current_db="$(gd_backup_panel_db)"
    safety="$work/aktuelle-db.sql.gz"
    if [ -d "$PTERO_DIR" ]; then
        (cd "$PTERO_DIR" && php artisan down) >> "$GD_LOG" 2>&1
        gd_backup_dump_db "$current_db" "$safety" || safety=""
        mv "$PTERO_DIR" "$old" || { rm -rf "$work"; GD_RESTORE_INFO="Der aktuelle Panel-Ordner konnte nicht gesichert werden."; return 1; }
    fi
    mv "$work/${PTERO_DIR#/}" "$PTERO_DIR"

    if [ -f "$work/germandactyl-backup/panel-db.sql.gz" ]; then
        db="$(cat "$work/germandactyl-backup/database-name" 2>/dev/null)"
        db="${db:-panel}"
        # Der Dump enthält "CREATE DATABASE"/"USE" (Option --databases); alte Dumps ohne diese Zeilen werden gezielt eingespielt
        gd_mysql -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\`;" >> "$GD_LOG" 2>&1
        if ! gunzip -c "$work/germandactyl-backup/panel-db.sql.gz" | gd_mysql "$db" >> "$GD_LOG" 2>&1; then
            # Zurückrollen: alten Ordner und alte Datenbank wiederherstellen
            rm -rf "$PTERO_DIR"
            [ -d "$old" ] && mv "$old" "$PTERO_DIR"
            if [ -n "$safety" ]; then
                gd_mysql -e "DROP DATABASE IF EXISTS \`$current_db\`; CREATE DATABASE \`$current_db\`;" >> "$GD_LOG" 2>&1
                gunzip -c "$safety" | gd_mysql "$current_db" >> "$GD_LOG" 2>&1
            fi
            (cd "$PTERO_DIR" && php artisan up) >> "$GD_LOG" 2>&1
            rm -rf "$work"
            GD_RESTORE_INFO="Die Datenbank konnte nicht eingespielt werden. Der vorherige Stand wurde wiederhergestellt."
            return 1
        fi
        GD_RESTORE_INFO="Panel-Dateien, Konfiguration und Datenbank wurden wiederhergestellt."
    else
        GD_RESTORE_INFO="Die Panel-Dateien wurden wiederhergestellt. Dieses ältere Backup enthielt noch keine Datenbank – die Datenbank ist unverändert."
    fi

    chown -R www-data:www-data "$PTERO_DIR"
    (cd "$PTERO_DIR" && php artisan optimize:clear && php artisan queue:restart && php artisan up) >> "$GD_LOG" 2>&1
    systemctl restart pteroq 2>/dev/null
    rm -rf "$work" "$old"
    return 0
}

gd_backup_db_import() {
    # gd_backup_db_import <datenbank> <dump.sql oder dump.sql.gz> – ersetzt eine Datenbank,
    # vorher wird der aktuelle Stand gesichert und bei einem Fehler zurückgespielt.
    local db="$1" dump="$2" safety cat_cmd=cat
    [[ "$dump" == *.gz ]] && cat_cmd="gunzip -c"
    $cat_cmd "$dump" | tail -n 3 | grep -q "Dump completed" || { echo "Dump unvollständig: $dump"; return 1; }
    safety="$(mktemp -p "$GD_BACKUP_ROOT" .db-sicherung.XXXXXX)"
    if gd_mysql -N -e "SHOW DATABASES LIKE '$db';" | grep -qx "$db"; then
        gd_backup_dump_db "$db" "$safety" || { rm -f "$safety"; return 1; }
    else
        rm -f "$safety"; safety=""
    fi
    gd_mysql -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\`;" || return 1
    if ! $cat_cmd "$dump" | gd_mysql "$db"; then
        if [ -n "$safety" ]; then
            gd_mysql -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\`;"
            gunzip -c "$safety" | gd_mysql "$db"
        fi
        rm -f "$safety"
        return 1
    fi
    rm -f "$safety"
    return 0
}

gd_backup_server_restore() {
    # gd_backup_server_restore <backupdatei> [uuid] – ohne uuid werden alle Server zurückgesetzt
    local file="$1" uuid="${2:-}" member target aside rc
    if [ -n "$uuid" ]; then
        member="${GD_VOLUMES_DIR#/}/$uuid"
        target="$GD_VOLUMES_DIR/$uuid"
    else
        member="${GD_VOLUMES_DIR#/}"
        target="$GD_VOLUMES_DIR"
    fi
    aside="${target}.vor-wiederherstellung-$(date +%Y%m%d-%H%M%S)"
    # Aktuellen Stand beiseite legen (nur umbenennen, kein zusätzlicher Speicherplatz), damit der
    # Server exakt dem Backup entspricht und nicht neue Dateien übrig bleiben
    [ -d "$target" ] && { mv "$target" "$aside" || return 1; }
    tar -xzf "$file" -C / "$member" 2>>"$GD_LOG"
    rc=$?
    if [ $rc -ne 0 ] || [ ! -d "$target" ]; then
        rm -rf "$target"
        [ -d "$aside" ] && mv "$aside" "$target"
        return 1
    fi
    rm -rf "$aside"
    return 0
}

gd_backup_list_servers_in() {
    # UUIDs der Server, die in einem Server-Backup enthalten sind
    tar -tzf "$1" 2>/dev/null | awk -F/ -v d="${GD_VOLUMES_DIR#/}" 'index($0, d "/") == 1 { split(substr($0, length(d) + 2), p, "/"); if (p[1] != "") print p[1] }' | sort -u
}
