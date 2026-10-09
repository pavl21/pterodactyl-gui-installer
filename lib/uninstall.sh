#!/bin/bash
# Pfad: lib/uninstall.sh
# Eigene Deinstallation von Panel und/oder Wings. Entfernt gezielt nur Pterodactyl –
# nginx, MariaDB, PHP, Docker und fremde Container bleiben unangetastet.

gd_uninstall_backup() {
    # Sicherung vor dem Löschen – im selben Format wie die Backup-Verwaltung, damit sie dort
    # später auch wiederhergestellt werden kann. Schlägt ein Teil fehl, wird die Deinstallation abgebrochen.
    gd_backup_prepare
    if [ "${1:-}" = "panel" ] || [ "${1:-}" = "beides" ]; then
        gd_backup_panel_create "$GD_BACKUP_PANEL/$(gd_backup_name)" false || return 1
    fi
    if [ "${1:-}" = "wings" ] || [ "${1:-}" = "beides" ]; then
        if [ -d "$GD_VOLUMES_DIR" ]; then
            gd_backup_stop_servers
            if ! gd_backup_server_create "$GD_BACKUP_SERVER/$(gd_backup_name)" false; then
                # Abbruch: Gameserver nicht gestoppt zurücklassen
                systemctl start wings 2>/dev/null
                return 1
            fi
        fi
    fi
    ls -lhR "$GD_BACKUP_ROOT"
}

gd_uninstall_panel() {
    local db dbuser dbhost
    db="$(gd_panel_env DB_DATABASE)"
    dbuser="$(gd_panel_env DB_USERNAME)"
    dbhost="$(gd_panel_env DB_HOST)"
    systemctl disable --now pteroq 2>/dev/null
    rm -f /etc/systemd/system/pteroq.service
    systemctl daemon-reload
    crontab -l 2>/dev/null | grep -vF "${PTERO_DIR}/artisan schedule:run" | crontab -
    case "${dbhost:-127.0.0.1}" in
        127.0.0.1|localhost|::1) ;;
        *) echo "Die Panel-Datenbank liegt auf einem anderen Server (${dbhost}) und wird nicht angetastet."; db=""; dbuser="" ;;
    esac
    # Systemkonten nie löschen; ebenso keinen Benutzer, der noch Rechte auf andere Datenbanken hat
    case "$dbuser" in root|mysql|mariadb.sys|debian-sys-maint|admin) dbuser="" ;; esac
    if [ -n "$dbuser" ] && gd_mysql -N -e "SHOW GRANTS FOR '${dbuser}'@'127.0.0.1';" 2>/dev/null \
        | grep -vE "GRANT USAGE ON \*\.\*|ON \\?\`?${db}\\?\`?\.\*" | grep -q .; then
        echo "Der Datenbank-Benutzer ${dbuser} hat weitere Rechte und wird nicht gelöscht."
        dbuser=""
    fi
    if [ -n "$db" ]; then
        gd_mysql -e "DROP DATABASE IF EXISTS \`${db}\`;" || return 1
    fi
    if [ -n "$dbuser" ]; then
        gd_mysql -e "DROP USER IF EXISTS '${dbuser}'@'127.0.0.1'; DROP USER IF EXISTS '${dbuser}'@'localhost'; FLUSH PRIVILEGES;"
    fi
    # Von GermanDactyl Setup angelegte Datenbankbenutzer mit Vollrechten entfernen
    # (phpMyAdmin: gd_admin_*, Database-Host: gd_dbhost_*) – sie würden sonst ungenutzt offen bleiben
    gd_mysql -N -e "SELECT CONCAT('DROP USER IF EXISTS \\'', User, '\\'@\\'', Host, '\\';') FROM mysql.user WHERE User LIKE 'gd\\_admin\\_%' OR User LIKE 'gd\\_dbhost\\_%';" 2>/dev/null \
        | gd_mysql
    # MariaDB wieder nur lokal lauschen lassen, falls der Database-Host sie geöffnet hatte
    if [ -f /etc/mysql/mariadb.conf.d/99-germandactyl.cnf ]; then
        rm -f /etc/mysql/mariadb.conf.d/99-germandactyl.cnf
        systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null
    fi
    # phpMyAdmin (nur wenn von GermanDactyl Setup installiert)
    if grep -qs "GermanDactyl" /usr/share/phpmyadmin/config.inc.php; then
        rm -rf /usr/share/phpmyadmin
    fi
    rm -f /etc/nginx/snippets/germandactyl-phpmyadmin.conf
    rm -f /etc/nginx/sites-enabled/pterodactyl.conf /etc/nginx/conf.d/pterodactyl.conf /etc/nginx/sites-available/pterodactyl.conf
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
    if ! gd_yesno "⚠ WARNUNG" "Du bist dabei, Pterodactyl zu entfernen. Dabei können das Panel, die Datenbank und alle Gameserver unwiderruflich gelöscht werden.\n\nMöchtest du fortfahren?" 12 70; then
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
    sel=$(whiptail --title "✖ Was soll entfernt werden?" --checklist "Wähle aus, was entfernt werden soll (Leertaste = an/aus):" 14 78 2 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
    [[ "$sel" == *'"PANEL"'* ]] && remove_panel=true
    [[ "$sel" == *'"WINGS"'* ]] && remove_wings=true
    $remove_panel || $remove_wings || return 1

    local do_backup=false
    if gd_yesno "▣ Sicherung" "Soll vorher eine Sicherung erstellt werden?\n\nGesichert wird das, was du entfernst (Panel mit Datenbank bzw. Gameserver-Daten), nach:\n$GD_BACKUP_ROOT\n\nSchlägt die Sicherung fehl, wird nichts gelöscht." 13 78; then
        do_backup=true
    fi

    local confirm_text="Ich bestätige die Löschung von Pterodactyl"
    while true; do
        local input
        input="$(gd_input "✖ Bestätigung" "Gib zur Bestätigung exakt folgenden Satz ein:\n\n$confirm_text" "" 12 70)" || return 1
        [ "$input" = "$confirm_text" ] && break
        gd_msg "✖ Falsche Eingabe" "Die Eingabe stimmt nicht überein. Versuche es erneut." 8 60
    done

    gd_gauge_open "✖ Deinstallation" "Deinstallation wird vorbereitet..."
    local what="beides"
    $remove_panel && ! $remove_wings && what="panel"
    ! $remove_panel && $remove_wings && what="wings"
    $do_backup && gd_step 10 "Sicherung wird erstellt und geprüft (kann bei vielen Servern dauern)..." gd_uninstall_backup "$what"
    # Erst das Panel: scheitert dort etwas (Datenbank), sind Wings und die Gameserver noch unberührt
    $remove_panel && gd_step 40 "Panel und Datenbank werden entfernt..." gd_uninstall_panel
    $remove_wings && gd_step 70 "Wings und Gameserver werden entfernt..." gd_uninstall_wings
    gd_progress 100 "Deinstallation abgeschlossen."
    gd_gauge_close
    rm -f /etc/germandactyl/zugangsdaten-ausstehend
    if [ -d "$PTERO_DIR" ] || [ -f "$WINGS_BIN" ]; then
        # Teil-Deinstallation: nur die Einträge des entfernten Teils löschen
        $remove_panel && sed -i -E '/^(PANEL_|INSTALL_)/d' "$GD_CONF_FILE" 2>/dev/null
        $remove_wings && sed -i -E '/^WINGS_/d' "$GD_CONF_FILE" 2>/dev/null
    else
        # Nichts mehr da: automatische Backups abschalten (Backups und Passwort bleiben erhalten)
        systemctl disable --now germandactyl-backup.timer 2>/dev/null
        rm -f "$GD_CONF_FILE"
    fi

    gd_msg "✔ Deinstallation abgeschlossen" "Pterodactyl wurde entfernt.\n\nWeiterhin installiert bleiben: nginx, MariaDB, PHP, Redis, Docker und vorhandene SSL-Zertifikate, damit andere Dienste auf diesem Server nicht beeinträchtigt werden.$( $do_backup && echo "\n\nDeine Sicherung liegt in: $GD_BACKUP_ROOT (über die Backup-Verwaltung wiederherstellbar)")$( $remove_panel && echo "\n\nHinweis: Datenbanken, die deine Gameserver über einen Database-Host angelegt hatten, bleiben erhalten.")" 15 78
    return 0
}
