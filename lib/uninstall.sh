#!/bin/bash
# Pfad: lib/uninstall.sh
# Eigene Deinstallation von Panel und/oder Wings. Entfernt gezielt nur Pterodactyl –
# nginx, MariaDB, PHP, Docker und fremde Container bleiben unangetastet.

GD_BACKUP_DIR="/opt/pterodactyl/backups"

gd_uninstall_backup() {
    # Sicherung der Server-Daten und der Panel-Datenbank vor dem Löschen
    local stamp db
    stamp="$(date +%Y-%m-%d_%H-%M)"
    mkdir -p "$GD_BACKUP_DIR"
    if [ -d /var/lib/pterodactyl/volumes ]; then
        tar -czf "$GD_BACKUP_DIR/Deinstallation_${stamp}_Server.tar.gz" -C /var/lib/pterodactyl volumes || return 1
    fi
    if [ -f "$PTERO_DIR/.env" ]; then
        db="$(gd_panel_env DB_DATABASE)"
        mysqldump --single-transaction "${db:-panel}" | gzip > "$GD_BACKUP_DIR/Deinstallation_${stamp}_Datenbank.sql.gz" || return 1
        cp "$PTERO_DIR/.env" "$GD_BACKUP_DIR/Deinstallation_${stamp}_panel.env"
        chmod 600 "$GD_BACKUP_DIR"/Deinstallation_"${stamp}"_*
    fi
    ls -lh "$GD_BACKUP_DIR"
}

gd_uninstall_panel() {
    local db dbuser
    db="$(gd_panel_env DB_DATABASE)"
    dbuser="$(gd_panel_env DB_USERNAME)"
    systemctl disable --now pteroq 2>/dev/null
    rm -f /etc/systemd/system/pteroq.service
    systemctl daemon-reload
    crontab -l 2>/dev/null | grep -vF "${PTERO_DIR}/artisan schedule:run" | crontab -
    if [ -n "$db" ]; then
        gd_mysql -e "DROP DATABASE IF EXISTS \`${db}\`;" || return 1
    fi
    if [ -n "$dbuser" ]; then
        gd_mysql -e "DROP USER IF EXISTS '${dbuser}'@'127.0.0.1'; DROP USER IF EXISTS '${dbuser}'@'localhost'; FLUSH PRIVILEGES;"
    fi
    rm -f /etc/nginx/sites-enabled/pterodactyl.conf /etc/nginx/sites-available/pterodactyl.conf
    nginx -t 2>/dev/null && systemctl reload nginx
    rm -rf "$PTERO_DIR"
    return 0
}

gd_uninstall_wings() {
    local ids
    systemctl disable --now wings 2>/dev/null
    if command -v docker >/dev/null 2>&1; then
        # Nur Container, die Wings angelegt hat (Label "Service=Pterodactyl")
        ids="$(docker ps -aq --filter label=Service=Pterodactyl)"
        [ -n "$ids" ] && docker rm -f $ids
        docker network rm pterodactyl_nw 2>/dev/null
    fi
    rm -f /etc/systemd/system/wings.service "$WINGS_BIN"
    systemctl daemon-reload
    rm -rf /etc/pterodactyl /var/lib/pterodactyl /var/log/pterodactyl /tmp/pterodactyl
    return 0
}

gd_uninstall() {
    local has_panel=false has_wings=false sel remove_panel=false remove_wings=false
    [ -d "$PTERO_DIR" ] && has_panel=true
    { [ -f "$WINGS_BIN" ] || [ -d /etc/pterodactyl ]; } && has_wings=true

    gd_warn_colors_on
    if ! gd_yesno "⚠️ WARNUNG" "Du bist dabei, Pterodactyl zu entfernen. Dabei können das Panel, die Datenbank und alle Gameserver unwiderruflich gelöscht werden.\n\nMöchtest du fortfahren?" 12 70; then
        gd_warn_colors_off
        return 1
    fi
    gd_warn_colors_off

    local items=()
    $has_panel && items+=("PANEL" "Panel, Panel-Datenbank, Cronjob und Queue-Dienst" ON)
    $has_wings && items+=("WINGS" "Wings, alle Gameserver-Container und deren Daten" ON)
    if [ ${#items[@]} -eq 0 ]; then
        gd_msg "Nichts gefunden" "Es wurde weder ein Panel noch Wings gefunden." 8 60
        return 1
    fi
    sel=$(whiptail --title "🗑️ Was soll entfernt werden?" --checklist "Wähle aus, was entfernt werden soll (Leertaste = an/aus):" 14 78 2 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
    [[ "$sel" == *'"PANEL"'* ]] && remove_panel=true
    [[ "$sel" == *'"WINGS"'* ]] && remove_wings=true
    $remove_panel || $remove_wings || return 1

    local do_backup=false
    if gd_yesno "💾 Sicherung" "Soll vorher eine Sicherung erstellt werden?\n\nGesichert werden die Gameserver-Daten sowie die Panel-Datenbank und die Panel-Konfiguration (.env) nach:\n$GD_BACKUP_DIR" 13 78; then
        do_backup=true
    fi

    local confirm_text="Ich bestätige die Löschung von Pterodactyl"
    while true; do
        local input
        input="$(gd_input "🗑️ Bestätigung" "Gib zur Bestätigung exakt folgenden Satz ein:\n\n$confirm_text" "" 12 70)" || return 1
        [ "$input" = "$confirm_text" ] && break
        gd_msg "❌ Falsche Eingabe" "Die Eingabe stimmt nicht überein. Versuche es erneut." 8 60
    done

    gd_gauge_open "🗑️ Deinstallation" "Deinstallation wird vorbereitet..."
    $do_backup && gd_step 10 "Sicherung wird erstellt (kann bei vielen Servern dauern)..." gd_uninstall_backup
    $remove_wings && gd_step 40 "Wings und Gameserver werden entfernt..." gd_uninstall_wings
    $remove_panel && gd_step 70 "Panel und Datenbank werden entfernt..." gd_uninstall_panel
    gd_progress 100 "Deinstallation abgeschlossen."
    gd_gauge_close
    rm -f "$GD_CONF_FILE"

    gd_msg "✅ Deinstallation abgeschlossen" "Pterodactyl wurde entfernt.\n\nWeiterhin installiert bleiben: nginx, MariaDB, PHP, Redis, Docker und vorhandene SSL-Zertifikate, damit andere Dienste auf diesem Server nicht beeinträchtigt werden.$( $do_backup && echo "\n\nDeine Sicherung liegt in: $GD_BACKUP_DIR")" 15 78
    return 0
}
