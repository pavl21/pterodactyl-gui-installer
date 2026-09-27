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
gd_source_lib backup

gd_backup_prepare

create_panel_backup() {
    local file
    file="$GD_BACKUP_PANEL/$(gd_backup_name)"
    clear; echo "Datenbank und Panel-Dateien werden gesichert..."
    if gd_backup_panel_create "$file" true; then
        gd_msg "✅ Backup erstellt" "Das Panel-Backup (Dateien, Konfiguration und Datenbank) wurde erstellt und geprüft:\n\n$file ($(du -h "$file" | cut -f1))\n\nEs werden automatisch die neuesten $GD_BACKUP_KEEP Panel-Backups behalten." 13 78
    else
        gd_msg "❌ Backup fehlgeschlagen" "Das Backup konnte nicht vollständig erstellt werden und wurde verworfen.\n\nMögliche Ursachen: zu wenig Speicherplatz, Datenbank nicht erreichbar.\nDetails: $GD_LOG" 12 78
    fi
}

create_server_backup() {
    local file size free stop=false
    [ -d "$GD_VOLUMES_DIR" ] || { gd_msg "Keine Gameserver" "Unter $GD_VOLUMES_DIR wurden keine Gameserver-Daten gefunden." 8 70; return; }
    size="$(du -sb "$GD_VOLUMES_DIR" | cut -f1)"
    free="$(df -PB1 "$GD_BACKUP_ROOT" | awk 'NR==2{print $4}')"
    if [ "$free" -lt "$size" ]; then
        gd_msg "Zu wenig Speicherplatz" "Die Gameserver belegen $(numfmt --to=iec "$size"), frei sind nur $(numfmt --to=iec "$free"). Das Backup wird nicht erstellt." 10 74
        return
    fi
    if systemctl is-active --quiet wings && gd_yesno "Gameserver anhalten?" "Laufende Gameserver schreiben während des Backups weiter in ihre Dateien. Das kann zu beschädigten Spielständen im Backup führen.\n\nSollen alle Gameserver während des Backups angehalten werden?\n\nEmpfehlung: Ja, sofern gerade niemand spielt." 15 74; then
        stop=true
        clear; echo "Gameserver werden angehalten..."
        gd_backup_stop_servers
    fi
    file="$GD_BACKUP_SERVER/$(gd_backup_name)"
    if gd_backup_server_create "$file" true; then
        $stop && systemctl start wings
        gd_msg "✅ Backup erstellt" "Das Backup aller Gameserver wurde erstellt und geprüft:\n\n$file ($(du -h "$file" | cut -f1))$($stop && echo "\n\nWings läuft wieder. Starte deine Gameserver bei Bedarf im Panel.")" 13 78
    else
        $stop && systemctl start wings
        gd_msg "❌ Backup fehlgeschlagen" "Das Backup konnte nicht vollständig erstellt werden und wurde verworfen. Details: $GD_LOG" 10 74
    fi
}

select_backup() {
    # select_backup <verzeichnis> -> gibt den Pfad des ausgewählten Backups aus
    local dir="$1" files=() items=() i choice
    mapfile -t files < <(find "$dir" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    if [ ${#files[@]} -eq 0 ]; then
        gd_msg "Keine Backups" "Im Verzeichnis $dir wurden keine Backups gefunden." 8 70
        return 1
    fi
    for i in "${!files[@]}"; do
        items+=("$((i + 1))" "$(basename "${files[$i]}") ($(du -h "${files[$i]}" | cut -f1))")
    done
    choice=$(whiptail --title "Backup auswählen" --menu "Wähle ein Backup aus (neueste zuerst):" 20 78 10 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
    echo "${files[$((choice - 1))]}"
}

restore_panel_backup() {
    local file
    file="$(select_backup "$GD_BACKUP_PANEL")" || return
    gd_yesno "⚠️ Wiederherstellen" "Das Panel wird auf den Stand von\n$(basename "$file")\nzurückgesetzt. Alle Änderungen seitdem (Benutzer, Server-Einträge, Einstellungen) gehen verloren.\n\nSchlägt etwas fehl, wird automatisch der vorherige Stand wiederhergestellt.\n\nFortfahren?" 15 74 || return
    clear; echo "Panel wird wiederhergestellt, bitte warten..."
    if gd_backup_panel_restore "$file"; then
        gd_msg "✅ Wiederherstellung abgeschlossen" "$GD_RESTORE_INFO" 10 74
    else
        gd_msg "❌ Wiederherstellung fehlgeschlagen" "$GD_RESTORE_INFO\n\nDetails: $GD_LOG" 11 74
    fi
}

restore_server_backup() {
    local file uuids items=() names uuid name choice target=""
    file="$(select_backup "$GD_BACKUP_SERVER")" || return
    clear; echo "Backup wird gelesen..."
    uuids="$(gd_backup_list_servers_in "$file")"
    [ -z "$uuids" ] && { gd_msg "Leeres Backup" "Das Backup enthält keine Gameserver." 8 60; return; }
    names="$(gd_backup_server_names)"
    items+=("ALLE" "Alle Gameserver im Backup")
    while read -r uuid; do
        name="$(awk -v u="$uuid" '$1==u {$1=""; sub(/^ /,""); print; exit}' <<< "$names")"
        items+=("$uuid" "${name:-(Name unbekannt)}")
    done <<< "$uuids"
    choice=$(whiptail --title "Server wiederherstellen" --menu "Welcher Server soll wiederhergestellt werden?" 20 90 10 "${items[@]}" 3>&1 1>&2 2>&3) || return
    [ "$choice" != "ALLE" ] && target="$choice"

    gd_yesno "⚠️ Wiederherstellen" "$( [ -n "$target" ] && echo "Der Server $target" || echo "Alle Gameserver") wird auf den Stand von\n$(basename "$file")\nzurückgesetzt. Dateien, die seitdem entstanden sind, werden entfernt.\n\nDafür werden Wings und alle Gameserver kurz angehalten.\n\nFortfahren?" 15 78 || return
    clear; echo "Gameserver werden angehalten und das Backup wird eingespielt..."
    gd_backup_stop_servers
    if gd_backup_server_restore "$file" "$target"; then
        systemctl start wings 2>/dev/null
        gd_msg "✅ Wiederherstellung abgeschlossen" "Die Daten wurden wiederhergestellt und Wings läuft wieder. Starte die Gameserver bei Bedarf im Panel." 10 74
    else
        systemctl start wings 2>/dev/null
        gd_msg "❌ Wiederherstellung fehlgeschlagen" "Das Backup konnte nicht eingespielt werden. Der vorherige Stand wurde beibehalten.\n\nDetails: $GD_LOG" 11 74
    fi
}

remove_backups() {
    local dir="$1" count
    count="$(find "$dir" -maxdepth 1 -type f -name '*.tar.gz' | wc -l)"
    [ "$count" -eq 0 ] && { gd_msg "Keine Backups" "In $dir gibt es keine Backups." 8 60; return; }
    if gd_yesno "Backups löschen" "Alle $count Backups in\n$dir\nwerden unwiderruflich gelöscht. Fortfahren?" 11 70; then
        find "$dir" -maxdepth 1 -type f -name '*.tar.gz' -delete
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
            panel:3) remove_backups "$GD_BACKUP_PANEL" ;;
            server:1) create_server_backup ;;
            server:2) restore_server_backup ;;
            server:3) remove_backups "$GD_BACKUP_SERVER" ;;
            *) return ;;
        esac
    done
}

gd_msg "📂 Backup-Verwaltung" "Hier erstellst du Backups deines Panels (Dateien, Konfiguration und Datenbank) und deiner Gameserver. Jedes Backup wird nach dem Erstellen auf Vollständigkeit geprüft.\n\nAblage: $GD_BACKUP_ROOT\n\nTipp: Ein Backup auf demselben Server schützt nicht vor einem Festplattenausfall. Kopiere wichtige Backups zusätzlich an einen anderen Ort." 15 76

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
