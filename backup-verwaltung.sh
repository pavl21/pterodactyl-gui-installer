#!/bin/bash
# Pfad: backup-verwaltung.sh
# Backups des Panels (Dateien + Datenbank + .env) und der Gameserver (Wings-Volumes) erstellen,
# wiederherstellen und löschen. Ablage: /opt/pterodactyl/backups/{panel,server}

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

BACKUP_ROOT="/opt/pterodactyl/backups"
BACKUP_PANEL="$BACKUP_ROOT/panel"
BACKUP_SERVER="$BACKUP_ROOT/server"
VOLUMES_DIR="/var/lib/pterodactyl/volumes"
MAX_BACKUPS=5   # Ältere Backups werden automatisch gelöscht

mkdir -p "$BACKUP_PANEL" "$BACKUP_SERVER"
chmod 700 "$BACKUP_ROOT"
command -v pv >/dev/null 2>&1 || gd_apt_install pv >> "$GD_LOG" 2>&1

panel_env() {
    grep -E "^$1=" "$PTERO_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'
}

rotate_backups() {
    # Nur die neuesten $MAX_BACKUPS Backups behalten
    local dir="$1"
    ls -1t "$dir"/*.tar.gz 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f
}

create_panel_backup() {
    local file="$BACKUP_PANEL/Backup_$(date +%Y-%m-%d_%H-%M).tar.gz" work="$GD_TMP/panel-backup" size db
    [ -d "$PTERO_DIR" ] || { gd_msg "Fehler" "Es wurde kein Panel unter $PTERO_DIR gefunden." 8 60; return; }
    mkdir -p "$work/germandactyl-backup"
    clear; echo "Datenbank wird gesichert..."
    db="$(panel_env DB_DATABASE)"
    if ! mysqldump --single-transaction "${db:-panel}" 2>>"$GD_LOG" | gzip > "$work/germandactyl-backup/panel-db.sql.gz"; then
        gd_msg "Fehler" "Die Datenbank konnte nicht gesichert werden. Details: $GD_LOG" 9 70
        return
    fi
    echo "${db:-panel}" > "$work/germandactyl-backup/database-name"
    size="$(du -sb "$PTERO_DIR" --exclude=node_modules | awk '{print $1}')"
    (tar -cf - --exclude="${PTERO_DIR#/}/node_modules" -C / "${PTERO_DIR#/}" -C "$work" germandactyl-backup \
        | pv -n -s "$size" | gzip > "$file") 2>&1 | whiptail --title "Panel-Backup" --gauge "Das Backup wird erstellt..." 7 60 0
    rm -rf "$work"
    if [ -s "$file" ] && gzip -t "$file" 2>/dev/null; then
        chmod 600 "$file"
        rotate_backups "$BACKUP_PANEL"
        gd_msg "✅ Backup erstellt" "Das Panel-Backup (Dateien, Datenbank und Konfiguration) wurde erstellt:\n\n$file ($(du -h "$file" | cut -f1))\n\nEs werden automatisch die neuesten $MAX_BACKUPS Backups behalten." 13 78
    else
        rm -f "$file"
        gd_msg "Fehler" "Beim Erstellen des Backups ist ein Fehler aufgetreten. Ist genug Speicherplatz frei?" 9 70
    fi
}

create_server_backup() {
    local file="$BACKUP_SERVER/Backup_$(date +%Y-%m-%d_%H-%M).tar.gz" size stop=false
    [ -d "$VOLUMES_DIR" ] || { gd_msg "Fehler" "Es wurden keine Gameserver-Daten unter $VOLUMES_DIR gefunden." 8 70; return; }
    size="$(du -sb "$VOLUMES_DIR" | awk '{print $1}')"
    if [ "$(df -PB1 "$BACKUP_ROOT" | awk 'NR==2{print $4}')" -lt "$size" ]; then
        gd_msg "Zu wenig Speicherplatz" "Für das Backup ($(numfmt --to=iec "$size")) ist nicht genug Speicherplatz frei." 9 70
        return
    fi
    if systemctl is-active --quiet wings && gd_yesno "Gameserver anhalten?" "Laufende Gameserver schreiben während des Backups weiter in ihre Dateien. Das kann zu beschädigten Spielständen im Backup führen.\n\nSoll Wings (und damit alle Gameserver) während des Backups angehalten werden?\n\nEmpfehlung: Ja, sofern gerade niemand spielt." 15 74; then
        stop=true
        systemctl stop wings
        docker ps -q --filter label=Service=Pterodactyl | xargs -r docker stop >> "$GD_LOG" 2>&1
    fi
    (tar -cf - -C / "${VOLUMES_DIR#/}" | pv -n -s "$size" | gzip > "$file") 2>&1 \
        | whiptail --title "Server-Backup" --gauge "Das Backup wird erstellt..." 7 60 0
    $stop && systemctl start wings
    if [ -s "$file" ] && gzip -t "$file" 2>/dev/null; then
        chmod 600 "$file"
        rotate_backups "$BACKUP_SERVER"
        gd_msg "✅ Backup erstellt" "Das Backup aller Gameserver wurde erstellt:\n\n$file ($(du -h "$file" | cut -f1))$($stop && echo "\n\nWings wurde wieder gestartet. Starte deine Gameserver bei Bedarf im Panel.")" 13 78
    else
        rm -f "$file"
        gd_msg "Fehler" "Beim Erstellen des Backups ist ein Fehler aufgetreten. Ist genug Speicherplatz frei?" 9 70
    fi
}

select_backup() {
    # select_backup <verzeichnis> -> gibt den Pfad des ausgewählten Backups aus
    local dir="$1" files=() items=() i choice
    mapfile -t files < <(ls -1t "$dir"/*.tar.gz 2>/dev/null)
    if [ ${#files[@]} -eq 0 ]; then
        gd_msg "Keine Backups" "Im Verzeichnis $dir wurden keine Backups gefunden." 8 70
        return 1
    fi
    for i in "${!files[@]}"; do
        items+=("$((i + 1))" "$(basename "${files[$i]}") ($(du -h "${files[$i]}" | cut -f1))")
    done
    choice=$(whiptail --title "Backup auswählen" --menu "Wähle ein Backup aus:" 20 78 10 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
    echo "${files[$((choice - 1))]}"
}

restore_panel_backup() {
    local file work size db
    file="$(select_backup "$BACKUP_PANEL")" || return
    gd_yesno "⚠️ Wiederherstellen" "Das Panel wird auf den Stand von\n$(basename "$file")\nzurückgesetzt. Alle Änderungen seitdem (Benutzer, Server-Einträge, Einstellungen) gehen verloren.\n\nFortfahren?" 13 74 || return
    work="$GD_TMP/panel-restore"
    rm -rf "$work"; mkdir -p "$work"
    size="$(stat -c %s "$file")"
    (pv -n -s "$size" "$file" | tar -xzf - -C "$work") 2>&1 | whiptail --title "Wiederherstellung" --gauge "Backup wird entpackt..." 7 60 0
    if [ ! -d "$work/${PTERO_DIR#/}" ]; then
        gd_msg "Fehler" "Das Backup enthält keine Panel-Dateien." 8 60
        return
    fi
    clear; echo "Panel wird wiederhergestellt..."
    {
        (cd "$PTERO_DIR" 2>/dev/null && php artisan down)
        rm -rf "$PTERO_DIR"
        mv "$work/${PTERO_DIR#/}" "$PTERO_DIR"
        if [ -f "$work/germandactyl-backup/panel-db.sql.gz" ]; then
            db="$(cat "$work/germandactyl-backup/database-name" 2>/dev/null || echo panel)"
            gd_mysql -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\`;"
            gunzip -c "$work/germandactyl-backup/panel-db.sql.gz" | gd_mysql "$db"
        fi
        chown -R www-data:www-data "$PTERO_DIR"
        cd "$PTERO_DIR" && php artisan optimize:clear && php artisan queue:restart && php artisan up
        systemctl restart pteroq
    } >> "$GD_LOG" 2>&1
    rm -rf "$work"
    if [ -f "$file" ] && ! tar -tzf "$file" 2>/dev/null | grep -q germandactyl-backup; then
        gd_msg "✅ Dateien wiederhergestellt" "Die Panel-Dateien wurden wiederhergestellt. Dieses ältere Backup enthielt noch keine Datenbank – die Datenbank ist unverändert." 10 74
    else
        gd_msg "✅ Wiederherstellung abgeschlossen" "Panel-Dateien, Datenbank und Konfiguration wurden wiederhergestellt." 9 70
    fi
}

restore_server_backup() {
    local file size
    file="$(select_backup "$BACKUP_SERVER")" || return
    gd_yesno "⚠️ Wiederherstellen" "Die Dateien aller Gameserver werden auf den Stand von\n$(basename "$file")\nzurückgesetzt. Dafür wird Wings kurz angehalten.\n\nFortfahren?" 12 74 || return
    systemctl stop wings 2>/dev/null
    docker ps -q --filter label=Service=Pterodactyl | xargs -r docker stop >> "$GD_LOG" 2>&1
    size="$(stat -c %s "$file")"
    (pv -n -s "$size" "$file" | tar -xzf - -C /) 2>&1 | whiptail --title "Wiederherstellung" --gauge "Backup wird wiederhergestellt..." 7 60 0
    systemctl start wings 2>/dev/null
    gd_msg "✅ Wiederherstellung abgeschlossen" "Die Gameserver-Daten wurden wiederhergestellt und Wings wurde neu gestartet. Starte deine Gameserver bei Bedarf im Panel." 10 74
}

remove_backups() {
    local dir="$1" count
    count="$(ls -1 "$dir"/*.tar.gz 2>/dev/null | wc -l)"
    [ "$count" -eq 0 ] && { gd_msg "Keine Backups" "In $dir gibt es keine Backups." 8 60; return; }
    if gd_yesno "Backups löschen" "Alle $count Backups in\n$dir\nwerden unwiderruflich gelöscht. Fortfahren?" 11 70; then
        rm -f "$dir"/*.tar.gz
        gd_msg "Gelöscht" "Alle Backups wurden gelöscht." 8 50
    fi
}

backup_menu() {
    local kind="$1" choice
    while true; do
        choice=$(whiptail --title "$([ "$kind" = panel ] && echo "Panel-Backups" || echo "Server-Backups")" --menu "Wähle eine Option:" 14 60 4 \
            "1" "Backup erstellen" \
            "2" "Backup wiederherstellen" \
            "3" "Alle Backups löschen" \
            "4" "Zurück" 3>&1 1>&2 2>&3) || return
        case "$kind:$choice" in
            panel:1) create_panel_backup ;;
            panel:2) restore_panel_backup ;;
            panel:3) remove_backups "$BACKUP_PANEL" ;;
            server:1) create_server_backup ;;
            server:2) restore_server_backup ;;
            server:3) remove_backups "$BACKUP_SERVER" ;;
            *) return ;;
        esac
    done
}

gd_msg "📂 Backup-Verwaltung" "Hier erstellst du Backups deines Panels (Dateien, Datenbank und Konfiguration) und deiner Gameserver.\n\nAblage: $BACKUP_ROOT\n\nTipp: Ein Backup auf demselben Server schützt nicht vor einem Festplattenausfall. Kopiere wichtige Backups zusätzlich an einen anderen Ort." 14 74

while true; do
    choice=$(whiptail --title "📂 Backup-Verwaltung" --menu "Wähle die Backup-Art:" 14 60 3 \
        "1" "Panel-Backups" \
        "2" "Server-Backups (Gameserver)" \
        "3" "Zurück zum Hauptmenü" 3>&1 1>&2 2>&3) || exit 0
    case "$choice" in
        1) backup_menu panel ;;
        2) backup_menu server ;;
        *) exit 0 ;;
    esac
done
