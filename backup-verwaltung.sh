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
gd_source_lib autobackup

gd_backup_prepare

create_panel_backup() {
    local file
    file="$GD_BACKUP_PANEL/$(gd_backup_name)"
    clear; echo "Datenbank und Panel-Dateien werden gesichert..."
    if gd_backup_panel_create "$file" true; then
        gd_msg "✔ Backup erstellt" "Das Panel-Backup (Dateien, Konfiguration und Datenbank) wurde erstellt und geprüft:\n\n$file ($(du -h "$file" | cut -f1))\n\nEs werden automatisch die neuesten $GD_BACKUP_KEEP Panel-Backups behalten." 13 78
    else
        gd_msg "✖ Backup fehlgeschlagen" "Das Backup konnte nicht vollständig erstellt werden und wurde verworfen.\n\nMögliche Ursachen: zu wenig Speicherplatz, Datenbank nicht erreichbar.\nDetails: $GD_LOG" 12 78
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
        gd_msg "✔ Backup erstellt" "Das Backup aller Gameserver wurde erstellt und geprüft:\n\n$file ($(du -h "$file" | cut -f1))$($stop && echo "\n\nWings läuft wieder. Starte deine Gameserver bei Bedarf im Panel.")" 13 78
    else
        $stop && systemctl start wings
        gd_msg "✖ Backup fehlgeschlagen" "Das Backup konnte nicht vollständig erstellt werden und wurde verworfen. Details: $GD_LOG" 10 74
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
    gd_yesno "⚠ Wiederherstellen" "Das Panel wird auf den Stand von\n$(basename "$file")\nzurückgesetzt. Alle Änderungen seitdem (Benutzer, Server-Einträge, Einstellungen) gehen verloren.\n\nSchlägt etwas fehl, wird automatisch der vorherige Stand wiederhergestellt.\n\nFortfahren?" 15 74 || return
    clear; echo "Panel wird wiederhergestellt, bitte warten..."
    if gd_backup_panel_restore "$file"; then
        gd_msg "✔ Wiederherstellung abgeschlossen" "$GD_RESTORE_INFO" 10 74
    else
        gd_msg "✖ Wiederherstellung fehlgeschlagen" "$GD_RESTORE_INFO\n\nDetails: $GD_LOG" 11 74
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

    gd_yesno "⚠ Wiederherstellen" "$( [ -n "$target" ] && echo "Der Server $target" || echo "Alle Gameserver") wird auf den Stand von\n$(basename "$file")\nzurückgesetzt. Dateien, die seitdem entstanden sind, werden entfernt.\n\nDafür werden Wings und alle Gameserver kurz angehalten.\n\nFortfahren?" 15 78 || return
    clear; echo "Gameserver werden angehalten und das Backup wird eingespielt..."
    gd_backup_stop_servers
    if gd_backup_server_restore "$file" "$target"; then
        systemctl start wings 2>/dev/null
        gd_msg "✔ Wiederherstellung abgeschlossen" "Die Daten wurden wiederhergestellt und Wings läuft wieder. Starte die Gameserver bei Bedarf im Panel." 10 74
    else
        systemctl start wings 2>/dev/null
        gd_msg "✖ Wiederherstellung fehlgeschlagen" "Das Backup konnte nicht eingespielt werden. Der vorherige Stand wurde beibehalten.\n\nDetails: $GD_LOG" 11 74
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

# ---------------------------------------------------------------------------
# Automatische inkrementelle Backups (restic)
# ---------------------------------------------------------------------------
ab_setup_dialog() {
    local repo servers=false time
    gd_msg "◷ Automatische Backups" "Automatische Backups laufen jeden Tag von selbst und sind inkrementell: Nach dem ersten Backup werden nur noch Änderungen gespeichert. Das spart viel Speicherplatz und Zeit.\n\nGesichert werden:\n- Panel-Dateien und Konfigurationen (nginx, Wings, Zertifikate)\n- ALLE Datenbanken (Panel und Datenbanken deiner Gameserver)\n- optional die Dateien aller Gameserver\n\nAufbewahrt werden 7 tägliche, 4 wöchentliche und 6 monatliche Stände. Das Archiv ist verschlüsselt (restic) und wird jeden Sonntag auf Beschädigungen geprüft." 20 78
    if gd_yesno "⚑ Gameserver mitsichern?" "Sollen auch die Dateien aller Gameserver (Welten, Spielstände, Plugins) gesichert werden?\n\nDas erste Backup kann je nach Größe länger dauern, danach werden nur Änderungen gespeichert.\nAktuell belegt: $(du -sh "$GD_VOLUMES_DIR" 2>/dev/null | cut -f1 || echo 0)" 13 74; then
        servers=true
    fi
    while true; do
        time="$(gd_input "◷ Uhrzeit" "Um wie viel Uhr soll das tägliche Backup laufen? (Format HH:MM, am besten nachts)" "04:00" 10 70)" || return
        [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
        gd_msg "Ungültige Uhrzeit" "Bitte gib die Uhrzeit im Format HH:MM an, z. B. 04:00." 8 60
    done
    repo="$(gd_input "▸ Speicherort" "Wo sollen die Backups gespeichert werden?\n\nTipp: Ein eingebundenes externes Laufwerk oder eine Storage Box schützt auch vor einem Ausfall dieses Servers." "$GD_BACKUP_ROOT/restic" 13 74)" || return
    [[ "$repo" == /* ]] || { gd_msg "Ungültiger Pfad" "Bitte gib einen absoluten Pfad an (beginnend mit /)." 8 60; return; }

    gd_gauge_open "◷ Automatische Backups" "Einrichtung läuft..."
    gd_step 30 "restic wird installiert, das Archiv wird angelegt..." gd_ab_setup "$repo" "$servers" "$time"
    gd_step 50 "jq wird installiert..." gd_apt_install jq
    gd_progress 100 "Fertig."
    gd_gauge_close
    gd_conf_set AUTO_BACKUP_SETUP "$(date '+%F %T')"

    gd_msg "✱ Wichtig: Passwort des Backup-Archivs" "Die Backups sind verschlüsselt. Ohne dieses Passwort können sie NICHT wiederhergestellt werden, falls dieser Server ausfällt:\n\n$(cat "$GD_AB_PASS")\n\nSpeichere es an einem sicheren Ort (z. B. Passwortmanager). Auf dem Server liegt es in $GD_AB_PASS." 16 78
    if gd_yesno "Erstes Backup" "Die automatischen Backups sind eingerichtet (täglich um $time Uhr).\n\nSoll das erste Backup jetzt sofort erstellt werden?" 10 70; then
        ab_run_now
    fi
}

ab_run_now() {
    clear
    echo "Backup läuft... (Fortschritt: tail -f /var/log/germandactyl-setup/auto-backup.log)"
    if "$GD_AB_SCRIPT" >> "$GD_LOG" 2>&1; then
        gd_msg "✔ Backup erfolgreich" "Das Backup wurde erstellt.\n\n$(tail -n 4 /var/log/germandactyl-setup/auto-backup.log | cut -c1-90)" 13 90
    else
        gd_msg "✖ Backup mit Fehlern" "Das Backup ist fehlgeschlagen oder unvollständig.\n\n$(grep -E 'FEHLER|Warnung' /var/log/germandactyl-setup/auto-backup.log | tail -n 5 | cut -c1-90)\n\nLog: /var/log/germandactyl-setup/auto-backup.log" 16 90
    fi
}

ab_status() {
    local snaps count next size
    gd_ab_load
    snaps="$(gd_ab_snapshots)"
    count="$(grep -c . <<< "$snaps")"
    next="$(systemctl list-timers germandactyl-backup.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3}')"
    size="$(du -sh "$REPO" 2>/dev/null | cut -f1)"
    gd_msg "☰ Status der automatischen Backups" "Zeitplan:        täglich um $TIME Uhr ($(systemctl is-active germandactyl-backup.timer))\nNächster Lauf:   ${next:-unbekannt}\nLetzter Erfolg:  $(gd_conf_get AUTO_BACKUP_LAST_OK | grep . || echo noch keiner)\nGameserver:      $( [ "$INCLUDE_SERVERS" = true ] && echo mitgesichert || echo nicht gesichert)\nSpeicherort:     $REPO ($size)\nStände:          $count\n\nNeueste Stände:\n$(head -n 5 <<< "$snaps" | awk '{print "  " $2 " " $3 "  (" $1 ")"}')" 22 80
}

ab_restore() {
    local snaps items=() snap what choice names uuid name dbs
    snaps="$(gd_ab_snapshots)"
    [ -z "$snaps" ] && { gd_msg "Keine Backups" "Es gibt noch keine automatischen Backups." 8 60; return; }
    while read -r id d t srv; do
        items+=("$id" "$d $t Uhr$( [ "$srv" = ja ] && echo ' (mit Gameservern)')")
    done <<< "$snaps"
    snap=$(whiptail --title "Stand auswählen" --menu "Welcher Stand soll wiederhergestellt werden? (neueste zuerst)" 20 78 10 "${items[@]}" 3>&1 1>&2 2>&3) || return
    what=$(whiptail --title "Was wiederherstellen?" --menu "Was soll aus dem Stand $snap wiederhergestellt werden?" 15 78 3 \
        "PANEL" "Panel komplett (Dateien, Konfiguration, Panel-Datenbank)" \
        "DB" "Eine einzelne Datenbank (z. B. eines Gameservers)" \
        "SERVER" "Gameserver-Dateien" 3>&1 1>&2 2>&3) || return
    case "$what" in
        PANEL)
            gd_yesno "⚠ Panel wiederherstellen" "Das Panel wird auf den gewählten Stand zurückgesetzt. Änderungen seitdem gehen verloren. Schlägt etwas fehl, wird der vorherige Stand automatisch wiederhergestellt.\n\nFortfahren?" 12 74 || return
            clear; echo "Panel wird wiederhergestellt..."
            if gd_ab_restore_panel "$snap"; then gd_msg "✔ Wiederhergestellt" "$GD_RESTORE_INFO" 10 74
            else gd_msg "✖ Fehlgeschlagen" "$GD_RESTORE_INFO\n\nDetails: $GD_LOG" 11 74; fi ;;
        DB)
            clear; echo "Stand wird gelesen..."
            dbs="$(gd_ab_list_dbs "$snap")"
            [ -z "$dbs" ] && { gd_msg "Keine Datenbanken" "Dieser Stand enthält keine Datenbanken." 8 60; return; }
            items=(); for name in $dbs; do items+=("$name" ""); done
            choice=$(whiptail --title "Datenbank wählen" --menu "Welche Datenbank soll wiederhergestellt werden?" 20 70 10 "${items[@]}" 3>&1 1>&2 2>&3) || return
            gd_yesno "⚠ Datenbank wiederherstellen" "Die Datenbank '$choice' wird auf den gewählten Stand zurückgesetzt. Der aktuelle Inhalt wird vorher gesichert und bei einem Fehler zurückgespielt.\n\nFortfahren?" 12 74 || return
            clear; echo "Datenbank wird wiederhergestellt..."
            if gd_ab_restore_db "$snap" "$choice"; then gd_msg "✔ Wiederhergestellt" "Die Datenbank '$choice' wurde wiederhergestellt." 8 70
            else gd_msg "✖ Fehlgeschlagen" "Die Datenbank konnte nicht wiederhergestellt werden, der vorherige Inhalt ist unverändert.\n\nDetails: $GD_LOG" 11 74; fi ;;
        SERVER)
            clear; echo "Stand wird gelesen..."
            local uuids; uuids="$(gd_ab_list_servers "$snap")"
            [ -z "$uuids" ] && { gd_msg "Keine Gameserver" "Dieser Stand enthält keine Gameserver-Dateien." 8 60; return; }
            names="$(gd_backup_server_names)"
            items=("ALLE" "Alle Gameserver")
            while read -r uuid; do
                name="$(awk -v u="$uuid" '$1==u {$1=""; sub(/^ /,""); print; exit}' <<< "$names")"
                items+=("$uuid" "${name:-(Name unbekannt)}")
            done <<< "$uuids"
            choice=$(whiptail --title "Server wählen" --menu "Welcher Gameserver soll wiederhergestellt werden?" 20 90 10 "${items[@]}" 3>&1 1>&2 2>&3) || return
            [ "$choice" = "ALLE" ] && choice=""
            gd_yesno "⚠ Gameserver wiederherstellen" "$( [ -n "$choice" ] && echo "Der Server $choice" || echo "Alle Gameserver") wird auf den gewählten Stand zurückgesetzt. Wings und alle Gameserver werden dafür kurz angehalten.\n\nFortfahren?" 12 78 || return
            clear; echo "Gameserver werden angehalten und wiederhergestellt..."
            gd_backup_stop_servers
            if gd_ab_restore_server "$snap" "$choice"; then
                systemctl start wings 2>/dev/null
                gd_msg "✔ Wiederhergestellt" "Die Gameserver-Dateien wurden wiederhergestellt. Starte die Server bei Bedarf im Panel." 9 74
            else
                systemctl start wings 2>/dev/null
                gd_msg "✖ Fehlgeschlagen" "Die Wiederherstellung ist fehlgeschlagen, der vorherige Stand wurde beibehalten.\n\nDetails: $GD_LOG" 11 74
            fi ;;
    esac
}

ab_settings() {
    gd_ab_load
    local servers="$INCLUDE_SERVERS" time="$TIME"
    if gd_yesno "⚑ Gameserver mitsichern?" "Sollen die Dateien aller Gameserver mitgesichert werden?\n\nAktuell: $( [ "$servers" = true ] && echo ja || echo nein)" 10 70; then servers=true; else servers=false; fi
    while true; do
        time="$(gd_input "◷ Uhrzeit" "Uhrzeit des täglichen Backups (HH:MM):" "$TIME" 9 60)" || return
        [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
    done
    gd_ab_write_conf "$REPO" "$servers" "$time" "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_MONTHLY"
    gd_ab_write_units "$time" >> "$GD_LOG" 2>&1
    gd_msg "Gespeichert" "Die Einstellungen wurden übernommen." 8 50
}

ab_menu() {
    local choice
    if ! gd_ab_installed; then
        ab_setup_dialog
        gd_ab_installed || return
    fi
    while true; do
        choice=$(whiptail --title "◷ Automatische Backups" --menu "Status: $(systemctl is-active germandactyl-backup.timer) – letzter Erfolg: $(gd_conf_get AUTO_BACKUP_LAST_OK | grep . || echo noch keiner)" 17 78 6 \
            "1" "Status anzeigen" \
            "2" "Jetzt sichern" \
            "3" "Wiederherstellen" \
            "4" "Einstellungen ändern" \
            "5" "Automatische Backups deaktivieren" \
            "6" "Zurück" 3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) ab_status ;;
            2) ab_run_now ;;
            3) ab_restore ;;
            4) ab_settings ;;
            5) if gd_yesno "Deaktivieren" "Die automatischen Backups werden abgeschaltet. Vorhandene Backups bleiben erhalten und können weiterhin wiederhergestellt werden.\n\nFortfahren?" 11 70; then
                   systemctl disable --now germandactyl-backup.timer >> "$GD_LOG" 2>&1
                   gd_msg "Deaktiviert" "Die automatischen Backups sind abgeschaltet. Über 'Einstellungen ändern' kannst du sie wieder aktivieren." 9 70
               fi ;;
            *) return ;;
        esac
    done
}

gd_msg "↺ Backup-Verwaltung" "Hier erstellst du Backups deines Panels (Dateien, Konfiguration und Datenbank) und deiner Gameserver. Jedes Backup wird nach dem Erstellen auf Vollständigkeit geprüft.\n\nAblage: $GD_BACKUP_ROOT\n\nTipp: Ein Backup auf demselben Server schützt nicht vor einem Festplattenausfall. Kopiere wichtige Backups zusätzlich an einen anderen Ort." 15 76

while true; do
    choice=$(whiptail --title "↺ Backup-Verwaltung" --menu "Wähle die Backup-Art:" 15 70 4 \
        "1" "◷ Automatische Backups (täglich, inkrementell)" \
        "2" "Panel-Backups (manuell)" \
        "3" "Server-Backups (manuell, Gameserver)" \
        "4" "Zurück zum Hauptmenü" 3>&1 1>&2 2>&3) || exit 0
    case "$choice" in
        1) ab_menu ;;
        2) backup_menu panel ;;
        3) backup_menu server ;;
        *) exit 0 ;;
    esac
done
