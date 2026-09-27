#!/bin/bash
# Pfad: lib/manage.sh
# Verwaltung: Hauptmenü mit Statuszeile und Themen-Gruppen, Kurzbefehle (germandactyl/gmd),
# Ports freigeben, System-Updates, Firewall, fail2ban, automatische Updates, Logs und Support-Paket.
# Benötigt: common, security, panel, wings, blueprint, backup, autobackup, uninstall

GD_SHORTCUT="/usr/local/bin/germandactyl"
GD_SHORTCUT_SHORT="/usr/local/bin/gmd"

# ---------------------------------------------------------------------------
# Kurzbefehle
# ---------------------------------------------------------------------------
gd_shortcut_install() {
    # "germandactyl" startet immer die aktuelle Version; "gmd" nur, wenn es den Befehl noch nicht gibt
    cat > "$GD_SHORTCUT" <<EOF
#!/bin/bash
# Pfad: $GD_SHORTCUT – angelegt von GermanDactyl Setup
# Startet die jeweils aktuelle Version von GermanDactyl Setup (Installation und Verwaltung).
if [ "\$(id -u)" != "0" ]; then exec sudo "\$0" "\$@"; fi
script="\$(curl -fsSL "https://raw.githubusercontent.com/${GD_REPO}/${GD_BRANCH}/installer.sh")" || {
    echo "GermanDactyl Setup konnte nicht geladen werden. Prüfe die Internetverbindung."; exit 1; }
GD_BRANCH="${GD_BRANCH}" exec bash -c "\$script"
EOF
    chmod 755 "$GD_SHORTCUT"
    if [ ! -e "$GD_SHORTCUT_SHORT" ] && ! command -v gmd >/dev/null 2>&1; then
        ln -s "$GD_SHORTCUT" "$GD_SHORTCUT_SHORT"
        gd_conf_set SHORTCUT_GMD 1
    fi
    return 0
}

gd_shortcut_remove() {
    rm -f "$GD_SHORTCUT"
    if [ "$(gd_conf_get SHORTCUT_GMD)" = "1" ] && [ -L "$GD_SHORTCUT_SHORT" ]; then
        rm -f "$GD_SHORTCUT_SHORT"
    fi
    return 0
}

gd_shortcut_hint() {
    local hint="germandactyl"
    [ "$(readlink "$GD_SHORTCUT_SHORT" 2>/dev/null)" = "$GD_SHORTCUT" ] && hint="gmd (oder germandactyl)"
    echo "$hint"
}

# ---------------------------------------------------------------------------
# Status und Probleme (schnell, ohne Internet)
# ---------------------------------------------------------------------------
gd_has_panel() { [ -f "$PTERO_DIR/artisan" ]; }
gd_has_wings() { [ -x "$WINGS_BIN" ]; }

gd_collect_status() {
    # Setzt GD_STATUS (Text für den Menükopf) und GD_PROBLEMS (Anzahl)
    local line1="" line2="" svc php_fpm days domain code last age usage
    GD_PROBLEMS=0
    domain="$(gd_conf_get PANEL_DOMAIN)"
    php_fpm="$(systemctl list-units --type=service --all 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | sort -V | tail -n1)"

    if gd_has_panel; then
        local ok=true
        for svc in nginx mariadb redis-server pteroq ${php_fpm%.service}; do
            systemctl is-active --quiet "$svc" || { ok=false; GD_PROBLEMS=$((GD_PROBLEMS + 1)); }
        done
        if $ok && [ -n "$domain" ]; then
            code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 4 --resolve "${domain}:443:127.0.0.1" "https://${domain}/auth/login")"
            case "$code" in 200|302) ;; *) ok=false; GD_PROBLEMS=$((GD_PROBLEMS + 1)) ;; esac
        fi
        line1+="Panel v$(gd_panel_installed_version) $($ok && echo ✔ || echo ✖)   "
    fi
    if gd_has_wings; then
        if systemctl is-active --quiet wings; then line1+="Wings ✔   "
        else line1+="Wings ✖   "; GD_PROBLEMS=$((GD_PROBLEMS + 1)); fi
    fi
    [ -z "$domain" ] && domain="$(gd_conf_get WINGS_FQDN)"
    if [ -n "$domain" ] && [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
        days="$(gd_cert_days_left "/etc/letsencrypt/live/$domain/fullchain.pem")"
        if [ "${days:-0}" -lt 0 ]; then line1+="Zertifikat ✖ abgelaufen"; GD_PROBLEMS=$((GD_PROBLEMS + 1))
        elif [ "$days" -lt 14 ]; then line1+="Zertifikat ⚠ ${days} Tage"; GD_PROBLEMS=$((GD_PROBLEMS + 1))
        else line1+="Zertifikat ✔ ${days} Tage"; fi
    fi

    if systemctl is-enabled --quiet germandactyl-backup.timer 2>/dev/null; then
        last="$(gd_conf_get AUTO_BACKUP_LAST_OK)"
        if [ -z "$last" ]; then line2+="Backups ⚠ noch keins   "; GD_PROBLEMS=$((GD_PROBLEMS + 1))
        else
            age=$(( ($(date +%s) - $(date -d "$last" +%s)) / 3600 ))
            if [ "$age" -gt 48 ]; then line2+="Backups ✖ vor ${age} Std.   "; GD_PROBLEMS=$((GD_PROBLEMS + 1))
            else line2+="Backups ✔ $(date -d "$last" '+%d.%m. %H:%M')   "; fi
        fi
    else
        line2+="Backups: aus   "
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then line2+="Firewall ✔   "
    else line2+="Firewall: aus   "; fi
    usage="$(df -P / | awk 'NR==2{print $5}' | tr -d '%')"
    if [ "$usage" -ge 90 ]; then line2+="Speicher ✖ ${usage} %"; GD_PROBLEMS=$((GD_PROBLEMS + 1))
    else line2+="Speicher ${usage} %"; fi

    GD_STATUS="${line1}\n${line2}"
}

gd_update_check() {
    # Neueste Panel-Version höchstens einmal am Tag abfragen (Ergebnis wird zwischengespeichert)
    local ts latest
    GD_UPDATE_VERSION=""
    gd_has_panel || return 0
    ts="$(gd_conf_get PANEL_LATEST_TS)"
    if [ -z "$ts" ] || [ $(( $(date +%s) - ts )) -gt 86400 ]; then
        latest="$(gd_latest_release pterodactyl/panel)"
        if [ -n "$latest" ]; then
            gd_conf_set PANEL_LATEST "$latest"
            gd_conf_set PANEL_LATEST_TS "$(date +%s)"
        fi
    fi
    latest="$(gd_conf_get PANEL_LATEST)"
    if [ -n "$latest" ] && ! gd_version_ge "$(gd_panel_installed_version)" "$latest"; then
        GD_UPDATE_VERSION="$latest"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Hauptmenü
# ---------------------------------------------------------------------------
gd_main_menu() {
    local choice items
    gd_shortcut_install >/dev/null 2>&1
    gd_update_check
    while true; do
        gd_collect_status
        items=()
        [ "$GD_PROBLEMS" -gt 0 ] && items+=("!" "⚠ $( [ "$GD_PROBLEMS" -eq 1 ] && echo "1 Problem" || echo "$GD_PROBLEMS Probleme") gefunden – jetzt prüfen und beheben")
        [ -n "$GD_UPDATE_VERSION" ] && items+=("U" "↑ Update verfügbar: Panel v$GD_UPDATE_VERSION")
        items+=("1" "✚ Hilfe & Analyse")
        items+=("2" "↑ Aktualisieren (Panel, Wings, System)")
        items+=("3" "↺ Backups")
        items+=("4" "⇄ Gameserver & Wings (Ports, Swap)")
        gd_has_panel && items+=("5" "❖ Erweiterungen & Aussehen")
        gd_has_panel && items+=("6" "▦ Datenbanken (phpMyAdmin, DB-Host)")
        items+=("7" "⚙ Server & Sicherheit (Firewall, SSH)")
        gd_has_panel || items+=("P" "✚ Panel auf diesem Server installieren")
        items+=("8" "✖ Deinstallieren")
        items+=("0" "⊗ Beenden")

        choice=$(whiptail --title "GermanDactyl Verwaltung" --menu "$GD_STATUS" $(( ${#items[@]} / 2 + 10 )) 78 $(( ${#items[@]} / 2 )) "${items[@]}" 3>&1 1>&2 2>&3) || choice=0
        case "$choice" in
            "!") gd_run analyse.sh ;;
            U) gd_panel_update && gd_conf_set PANEL_LATEST_TS 0 ;;
            1) gd_menu_help ;;
            2) gd_menu_update ;;
            3) gd_run backup-verwaltung.sh ;;
            4) gd_menu_game ;;
            5) gd_menu_extensions ;;
            6) gd_menu_databases ;;
            7) gd_menu_server ;;
            P) gd_install_menu; return ;;
            8) gd_uninstall && ! gd_has_panel && ! gd_has_wings && { gd_shortcut_remove; clear; echo "Pterodactyl wurde entfernt."; exit 0; } ;;
            0|*)
                clear
                echo ""
                echo "INFO - - - - - - - - - -"
                echo "Die Verwaltung wurde beendet. Du kannst sie jederzeit wieder starten mit: $(gd_shortcut_hint)"
                exit 0 ;;
        esac
    done
}

gd_submenu() {
    # gd_submenu "Titel" "Text" tag beschreibung ... -> gibt die Auswahl aus
    local title="$1" text="$2"
    shift 2
    whiptail --title "$title" --menu "$text" 20 76 $(( $# / 2 )) "$@" "0" "← Zurück" 3>&1 1>&2 2>&3
}

gd_menu_help() {
    local c
    while true; do
        c=$(gd_submenu "✚ Hilfe & Analyse" "Wobei können wir dir helfen?" \
            "1" "✚ Analyse starten (findet und behebt Probleme)" \
            "2" "✱ Ich habe mich ausgesperrt" \
            "3" "⚙ Das Panel ist fehlerhaft (reparieren)" \
            "4" "⊘ Das Panel ist nicht erreichbar" \
            "5" "✱ SSL-Zertifikate prüfen/erneuern" \
            "6" "☰ Logs anzeigen" \
            "7" "▣ Support-Paket erstellen") || return
        case "$c" in
            1) gd_run analyse.sh ;;
            2) gd_run problem-verwaltung.sh admin ;;
            3) gd_run problem-verwaltung.sh repair ;;
            4) gd_run problem-verwaltung.sh nginx ;;
            5) gd_run certbot-renew-verwaltung.sh ;;
            6) gd_logs_menu ;;
            7) gd_support_package ;;
            *) return ;;
        esac
    done
}

gd_menu_update() {
    local c items=()
    while true; do
        items=()
        gd_has_panel && items+=("1" "↑ Panel aktualisieren (installiert: v$(gd_panel_installed_version))")
        gd_has_wings && items+=("2" "↑ Wings aktualisieren (installiert: v$("$WINGS_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1))")
        gd_has_panel && gd_blueprint_installed && items+=("3" "❖ Blueprint aktualisieren")
        items+=("4" "⚙ System-Pakete aktualisieren (apt)")
        c=$(gd_submenu "↑ Aktualisieren" "Was soll aktualisiert werden?" "${items[@]}") || return
        case "$c" in
            1) gd_panel_update && gd_conf_set PANEL_LATEST_TS 0 ;;
            2) gd_wings_update ;;
            3) gd_blueprint_reapply_dialog ;;
            4) gd_system_update ;;
            *) return ;;
        esac
    done
}

gd_menu_game() {
    local c
    while true; do
        c=$(gd_submenu "⇄ Gameserver & Wings" "Wähle eine Aktion:" \
            "1" "⇄ Wings installieren/verwalten" \
            "2" "⚑ Ports für Gameserver freigeben" \
            "3" "⇅ Swap-Speicher verwalten") || return
        case "$c" in
            1) gd_run wings-installer.sh ;;
            2) gd_ports_dialog ;;
            3) gd_run swap-verwaltung.sh ;;
            *) return ;;
        esac
    done
}

gd_menu_extensions() {
    local c
    while true; do
        c=$(gd_submenu "❖ Erweiterungen & Aussehen" "Erweiterungen und Themes werden über Blueprint installiert." \
            "1" "❖ Blueprint & Erweiterungen" \
            "2" "✎ Themes / Original-Oberfläche wiederherstellen") || return
        case "$c" in
            1) gd_blueprint_menu ;;
            2) gd_run theme-verwaltung.sh ;;
            *) return ;;
        esac
    done
}

gd_menu_databases() {
    local c
    while true; do
        c=$(gd_submenu "▦ Datenbanken" "Wähle eine Aktion:" \
            "1" "▤ phpMyAdmin installieren/aktualisieren" \
            "2" "▦ Database-Host für Gameserver einrichten") || return
        case "$c" in
            1) gd_run phpmyadmin-installer.sh ;;
            2) gd_run database-host-config.sh ;;
            *) return ;;
        esac
    done
}

gd_menu_server() {
    local c f2b upd
    while true; do
        f2b="aus"; systemctl is-active --quiet fail2ban 2>/dev/null && f2b="an"
        upd="aus"; grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades && upd="an"
        c=$(gd_submenu "⚙ Server & Sicherheit" "Wähle eine Aktion:" \
            "1" "✚ Firewall (Ports öffnen/schließen)" \
            "2" "✱ fail2ban – Schutz vor Angriffen ($f2b)" \
            "3" "↑ Automatische Sicherheitsupdates ($upd)" \
            "4" "▸ SSH-Loginseite einrichten/entfernen") || return
        case "$c" in
            1) gd_firewall_menu ;;
            2) gd_fail2ban_menu ;;
            3) gd_autoupdates_toggle ;;
            4) gd_run custom-ssh-login-config.sh ;;
            *) return ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Ports für Gameserver freigeben
# ---------------------------------------------------------------------------
gd_valid_port_or_range() {
    [[ "$1" =~ ^[0-9]{4,5}$ ]] && [ "$1" -gt 1024 ] && [ "$1" -le 65535 ] && return 0
    gd_valid_port_range "$1"
}

gd_ports_dialog() {
    local node ip alias ports nodes count items=() ips fw=false
    if ! gd_has_panel; then
        # Nur Wings auf diesem Server: Ports können hier nur in der Firewall geöffnet werden
        gd_msg "⚑ Ports freigeben" "Das Panel läuft auf einem anderen Server. Lege die Ports dort unter Admin → Nodes → deine Node → Allocation an.\n\nHier kannst du sie anschließend in der Firewall öffnen." 12 74
        gd_firewall_open_dialog
        return
    fi
    nodes="$(gd_panel_sql "SELECT id, name FROM nodes ORDER BY id;" 2>/dev/null)"
    count="$(grep -c . <<< "$nodes")"
    if [ "$count" -eq 0 ]; then
        gd_msg "Keine Node" "Im Panel gibt es noch keine Node. Richte zuerst Wings ein (Gameserver & Wings → Wings installieren)." 10 70
        return
    elif [ "$count" -eq 1 ]; then
        node="$(awk '{print $1}' <<< "$nodes")"
    else
        while IFS=$'\t' read -r id name; do items+=("$id" "$name"); done <<< "$nodes"
        node=$(whiptail --title "Node auswählen" --menu "Für welche Node sollen Ports freigegeben werden?" 18 70 8 "${items[@]}" 3>&1 1>&2 2>&3) || return
    fi

    # IP-Adresse: die bereits genutzte der Node verwenden, sonst ermitteln
    ips="$(gd_panel_sql "SELECT ip, IFNULL(ip_alias,'') FROM allocations WHERE node_id=${node} GROUP BY ip, ip_alias ORDER BY COUNT(*) DESC LIMIT 1;")"
    if [ -n "$ips" ]; then
        ip="$(cut -f1 <<< "$ips")"; alias="$(cut -f2 <<< "$ips")"
    else
        gd_allocation_ip || { gd_msg "Fehler" "Die IP-Adresse konnte nicht ermittelt werden." 8 60; return; }
        ip="$GD_ALLOC_IP"; alias="$GD_ALLOC_ALIAS"
    fi

    while true; do
        ports="$(gd_input "⚑ Ports freigeben" "Welche Ports sollen freigegeben werden?\n\nEinzelner Port: 27015\nBereich:        27015-27030 (höchstens 1000 Ports)\n\nErlaubt sind Ports von 1025 bis 65535." "" 15 70)" || return
        ports="$(tr -d '[:space:]' <<< "$ports")"
        gd_valid_port_or_range "$ports" && break
        gd_msg "Ungültige Eingabe" "Bitte gib einen Port (z. B. 27015) oder einen Bereich (z. B. 27015-27030) an." 9 70
    done
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" && fw=true
    gd_yesno "⚑ Ports freigeben" "Folgende Ports werden freigegeben:\n\nPorts:    $ports\nIP:       $ip${alias:+ (Alias: $alias)}\nNode-ID:  $node\nFirewall: $($fw && echo 'wird für TCP und UDP geöffnet' || echo 'nicht aktiv – nichts zu tun')\n\nFortfahren?" 15 72 || return

    clear; echo "Ports werden freigegeben..."
    if gd_allocations_add "$node" "$ip" "$alias" "$ports" >> "$GD_LOG" 2>&1; then
        if $fw; then
            ufw allow "${ports/-/:}/tcp" comment 'Gameserver' >> "$GD_LOG" 2>&1
            ufw allow "${ports/-/:}/udp" comment 'Gameserver' >> "$GD_LOG" 2>&1
        fi
        gd_msg "✔ Ports freigegeben" "Die Ports $ports sind im Panel angelegt$($fw && echo ' und in der Firewall geöffnet').\n\nDu kannst sie jetzt beim Erstellen oder Bearbeiten eines Servers zuweisen." 11 74
    else
        gd_msg "✖ Fehler" "Die Ports konnten nicht angelegt werden. Details: $GD_LOG" 9 70
    fi
}

# ---------------------------------------------------------------------------
# System-Updates
# ---------------------------------------------------------------------------
gd_system_update() {
    local count
    clear; echo "Paketlisten werden aktualisiert..."
    gd_apt update >> "$GD_LOG" 2>&1
    count="$(apt list --upgradable 2>/dev/null | grep -vcE '^(Listing|Auflistung)')"
    if [ "$count" -eq 0 ]; then
        gd_msg "✔ System ist aktuell" "Es gibt keine Paket-Updates." 8 50
        return
    fi
    gd_yesno "⚙ System-Pakete aktualisieren" "Es $( [ "$count" -eq 1 ] && echo "gibt 1 Update" || echo "gibt $count Updates").\n\nHinweis: Werden Docker-Pakete aktualisiert, starten alle Gameserver kurz neu.\n\nJetzt installieren?" 13 70 || return
    gd_gauge_open "⚙ System-Pakete werden aktualisiert" "Bitte warten..."
    gd_step 10 "Updates werden installiert ($count Pakete)..." gd_apt upgrade --with-new-pkgs
    gd_step 85 "Nicht mehr benötigte Pakete werden entfernt..." gd_apt autoremove
    gd_progress 100 "Fertig."
    gd_gauge_close
    if [ -f /var/run/reboot-required ]; then
        gd_msg "✔ Updates installiert" "Alle Updates wurden installiert.\n\nFür einige Updates (z. B. Kernel) ist ein Neustart nötig. Starte den Server bei Gelegenheit neu (reboot) – Panel, Wings und Gameserver starten danach automatisch." 13 74
    else
        gd_msg "✔ Updates installiert" "Alle Updates wurden installiert." 8 50
    fi
}

# ---------------------------------------------------------------------------
# Firewall, fail2ban, automatische Updates
# ---------------------------------------------------------------------------
gd_firewall_open_dialog() {
    local ports proto
    command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active" || {
        gd_msg "Firewall aus" "Die Firewall ist nicht aktiv – alle Ports sind bereits erreichbar." 8 64; return; }
    while true; do
        ports="$(gd_input "✚ Port öffnen" "Welcher Port oder Bereich soll geöffnet werden? (z. B. 25565 oder 27015-27030)" "" 10 70)" || return
        ports="$(tr -d '[:space:]' <<< "$ports")"
        [[ "$ports" =~ ^[0-9]{1,5}$ ]] && [ "$ports" -ge 1 ] && [ "$ports" -le 65535 ] && break
        [[ "$ports" =~ ^[0-9]{1,5}-[0-9]{1,5}$ ]] && break
        gd_msg "Ungültige Eingabe" "Bitte gib einen Port oder Bereich an." 8 50
    done
    proto=$(whiptail --title "Protokoll" --menu "Für welches Protokoll?" 12 60 3 \
        "beide" "TCP und UDP (empfohlen für Gameserver)" "tcp" "nur TCP" "udp" "nur UDP" 3>&1 1>&2 2>&3) || return
    if [ "$proto" = "beide" ]; then
        ufw allow "${ports/-/:}/tcp" >> "$GD_LOG" 2>&1 && ufw allow "${ports/-/:}/udp" >> "$GD_LOG" 2>&1
    else
        ufw allow "${ports/-/:}/$proto" >> "$GD_LOG" 2>&1
    fi && gd_msg "✔ Port geöffnet" "Port $ports ist jetzt geöffnet." 8 50
}

gd_firewall_menu() {
    local c active rules items=() num
    command -v ufw >/dev/null 2>&1 || gd_apt_install ufw >> "$GD_LOG" 2>&1
    while true; do
        active=false; ufw status | grep -q "Status: active" && active=true
        c=$(gd_submenu "✚ Firewall" "Status: $($active && echo 'aktiv' || echo 'aus')" \
            "1" "☰ Regeln anzeigen" \
            "2" "✚ Port öffnen" \
            "3" "✖ Port schließen" \
            "4" "$($active && echo '⊘ Firewall ausschalten' || echo '✔ Firewall einschalten (SSH wird automatisch freigegeben)')") || return
        case "$c" in
            1) ufw status verbose > "$GD_TMP/ufw.txt" 2>&1
               whiptail --title "Firewall-Regeln" --scrolltext --textbox "$GD_TMP/ufw.txt" 24 90 ;;
            2) gd_firewall_open_dialog ;;
            3) $active || { gd_msg "Firewall aus" "Die Firewall ist nicht aktiv." 8 50; continue; }
               items=()
               while IFS= read -r line; do
                   num="$(grep -oE '^\[ *[0-9]+\]' <<< "$line" | tr -d '[] ')"
                   [ -n "$num" ] && items+=("$num" "$(sed -E 's/^\[ *[0-9]+\] *//' <<< "$line" | tr -s ' ' | cut -c1-60)")
               done < <(ufw status numbered)
               [ ${#items[@]} -eq 0 ] && { gd_msg "Keine Regeln" "Es sind keine Regeln vorhanden." 8 50; continue; }
               num=$(whiptail --title "✖ Port schließen" --menu "Welche Regel soll entfernt werden?" 20 78 10 "${items[@]}" 3>&1 1>&2 2>&3) || continue
               if grep -qwE "$(gd_ssh_ports | paste -sd'|' -)" <<< "$(ufw status numbered | grep -E "^\[ *$num\]")" \
                   && ! gd_yesno "⚠ SSH-Regel" "Diese Regel gibt deinen SSH-Zugang frei. Wenn du sie entfernst, kannst du dich eventuell nicht mehr verbinden!\n\nTrotzdem entfernen?" 11 70; then
                   continue
               fi
               ufw --force delete "$num" >> "$GD_LOG" 2>&1 && gd_msg "✔ Entfernt" "Die Regel wurde entfernt." 8 40 ;;
            4) if $active; then
                   gd_yesno "⊘ Firewall ausschalten" "Danach sind alle Ports des Servers von außen erreichbar. Wirklich ausschalten?" 9 70 && ufw disable >> "$GD_LOG" 2>&1
               else
                   gd_msg "✔ Firewall einschalten" "Freigegeben werden automatisch: dein SSH-Port, 80, 443$(gd_has_wings && echo ', 8080, 2022 und die Gameserver-Ports') ." 9 74
                   clear; echo "Firewall wird eingerichtet..."
                   gd_firewall_setup "$(gd_has_wings && echo true || echo false)" "$(gd_conf_get WINGS_PORT_RANGE)" >> "$GD_LOG" 2>&1 \
                       && gd_msg "✔ Firewall aktiv" "Die Firewall ist eingeschaltet." 8 50 \
                       || gd_msg "✖ Fehler" "Die Firewall konnte nicht eingeschaltet werden. Details: $GD_LOG" 9 70
               fi ;;
            *) return ;;
        esac
    done
}

gd_fail2ban_menu() {
    local banned items=() ip
    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        gd_yesno "✱ fail2ban" "fail2ban sperrt IP-Adressen automatisch, wenn sie wiederholt falsche SSH-Passwörter versuchen.\n\nJetzt einrichten?" 11 70 || return
        clear; echo "fail2ban wird eingerichtet..."
        gd_fail2ban_setup >> "$GD_LOG" 2>&1 && gd_msg "✔ fail2ban aktiv" "fail2ban schützt jetzt deinen SSH-Zugang." 8 60 \
            || gd_msg "✖ Fehler" "fail2ban konnte nicht eingerichtet werden. Details: $GD_LOG" 9 70
        return
    fi
    banned="$(fail2ban-client status sshd 2>/dev/null | sed -n 's/.*Banned IP list:\s*//p' | tr ' ' '\n' | grep .)"
    if [ -z "$banned" ]; then
        gd_msg "✱ fail2ban" "fail2ban ist aktiv. Aktuell ist keine IP-Adresse gesperrt.\n\n$(fail2ban-client status sshd 2>/dev/null | grep -E 'Total failed|Total banned' | sed 's/^[|` -]*//')" 12 70
        return
    fi
    for ip in $banned; do items+=("$ip" "gesperrt"); done
    ip=$(whiptail --title "✱ Gesperrte IP-Adressen" --menu "Diese IP-Adressen sind gesperrt. Wähle eine aus, um sie zu entsperren (z. B. deine eigene):" 20 70 10 "${items[@]}" 3>&1 1>&2 2>&3) || return
    fail2ban-client set sshd unbanip "$ip" >> "$GD_LOG" 2>&1 && gd_msg "✔ Entsperrt" "$ip wurde entsperrt." 8 50
}

gd_autoupdates_toggle() {
    if grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
        gd_yesno "↑ Automatische Sicherheitsupdates" "Automatische Sicherheitsupdates sind eingeschaltet (empfohlen).\n\nMöchtest du sie ausschalten?" 10 70 || return
        printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "0";\n' > /etc/apt/apt.conf.d/20auto-upgrades
        gd_msg "Ausgeschaltet" "Automatische Sicherheitsupdates sind ausgeschaltet." 8 60
    else
        gd_yesno "↑ Automatische Sicherheitsupdates" "Sicherheitsupdates werden automatisch täglich installiert. Das schließt Sicherheitslücken, ohne dass du daran denken musst.\n\nEinschalten?" 11 70 || return
        clear; echo "Wird eingerichtet..."
        gd_unattended_upgrades_setup >> "$GD_LOG" 2>&1 && gd_msg "✔ Eingeschaltet" "Automatische Sicherheitsupdates sind eingeschaltet." 8 60
    fi
}

# ---------------------------------------------------------------------------
# Logs und Support-Paket
# ---------------------------------------------------------------------------
gd_panel_log_file() {
    ls -t "$PTERO_DIR"/storage/logs/*.log 2>/dev/null | head -n1
}

gd_logs_menu() {
    local c f="$GD_TMP/log-ansicht.txt"
    while true; do
        c=$(gd_submenu "☰ Logs anzeigen" "Welches Protokoll möchtest du ansehen? (die letzten 300 Zeilen)" \
            "1" "Panel (Fehler des Panels)" \
            "2" "Wings" \
            "3" "nginx (Webserver-Fehler)" \
            "4" "Queue-Dienst (pteroq)" \
            "5" "Automatische Backups" \
            "6" "Letzte Installation/Aktion dieses Skripts") || return
        case "$c" in
            1) tail -n 300 "$(gd_panel_log_file)" > "$f" 2>&1 ;;
            2) journalctl -u wings -n 300 --no-pager > "$f" 2>&1 ;;
            3) tail -n 300 /var/log/nginx/pterodactyl.app-error.log /var/log/nginx/error.log > "$f" 2>&1 ;;
            4) journalctl -u pteroq -n 300 --no-pager > "$f" 2>&1 ;;
            5) tail -n 300 "$GD_LOG_DIR/auto-backup.log" > "$f" 2>&1 ;;
            6) tail -n 300 "$(ls -t "$GD_LOG_DIR"/setup-*.log | sed -n 2p)" > "$f" 2>&1 ;;
            *) return ;;
        esac
        [ -s "$f" ] || echo "(Das Protokoll ist leer oder nicht vorhanden.)" > "$f"
        whiptail --title "☰ Log" --scrolltext --textbox "$f" 30 120
    done
}

gd_sanitize() {
    # Entfernt Passwörter, Schlüssel und Tokens aus Textdateien (für das Support-Paket)
    sed -E -i \
        -e 's/((PASSWORD|PASS|SECRET|KEY|TOKEN|SALT)[A-Z_]*=).*/\1***/I' \
        -e 's/("?(password|passwd|token|secret|api_key)"?\s*[:=]\s*)"?[^",} ]+"?/\1***/Ig' \
        -e 's/(Bearer )[A-Za-z0-9._-]+/\1***/g' \
        -e 's/\b(ptl[acr]_)[A-Za-z0-9]+/\1***/g' \
        -e 's/base64:[A-Za-z0-9+\/=]+/base64:***/g' \
        "$@"
}

gd_support_package() {
    local dir="$GD_TMP/support" out stamp analyse_script
    gd_yesno "▣ Support-Paket" "Es wird ein Archiv mit Informationen für eine Support-Anfrage erstellt: Versionen, Dienst-Status, Analyse-Ergebnis, Konfiguration und die letzten Log-Einträge.\n\nPasswörter, Schlüssel und Tokens werden automatisch entfernt. Es wird nichts hochgeladen – du entscheidest selbst, wem du die Datei gibst.\n\nErstellen?" 15 76 || return
    stamp="$(date +%Y-%m-%d_%H-%M)"
    out="/root/germandactyl-support-${stamp}.tar.gz"
    rm -rf "$dir"; mkdir -p "$dir"
    gd_gauge_open "▣ Support-Paket" "Informationen werden gesammelt..."
    gd_progress 10 "System und Versionen..."
    {
        echo "Erstellt: $(date)"; echo
        . /etc/os-release 2>/dev/null; echo "System:    $PRETTY_NAME ($(uname -r), $(uname -m))"
        echo "Panel:     $(gd_panel_installed_version)"
        echo "Wings:     $("$WINGS_BIN" version 2>/dev/null | head -n1)"
        echo "PHP:       $(php -v 2>/dev/null | head -n1)"
        echo "nginx:     $(nginx -v 2>&1)"
        echo "MariaDB:   $(mariadb --version 2>/dev/null)"
        echo "Docker:    $(docker --version 2>/dev/null)"
        echo "Blueprint: $(blueprint -v 2>/dev/null | tail -n1)"
        echo; echo "== setup.conf (ohne Geheimnisse)"; grep -vE 'PASS|KEY|TOKEN' "$GD_CONF_FILE" 2>/dev/null
        echo; echo "== Dienste"
        for s in nginx php8.3-fpm mariadb redis-server pteroq wings docker fail2ban germandactyl-backup.timer; do
            printf '%-28s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
        done
        echo; echo "== Ressourcen"; LC_ALL=C free -m; df -h /
    } > "$dir/system.txt" 2>&1
    gd_progress 35 "Analyse wird ausgeführt..."
    analyse_script="$GD_TMP/analyse-support.sh"
    gd_fetch analyse.sh "$analyse_script" && GD_LIB_DIR="${GD_LIB_DIR:-}" timeout 300 bash "$analyse_script" --text > "$dir/analyse.txt" 2>&1
    gd_progress 65 "Logs und Konfiguration..."
    tail -n 300 "$(gd_panel_log_file)" > "$dir/panel.log" 2>/dev/null
    journalctl -u wings -n 300 --no-pager > "$dir/wings.log" 2>/dev/null
    journalctl -u pteroq -n 100 --no-pager > "$dir/pteroq.log" 2>/dev/null
    tail -n 200 /var/log/nginx/pterodactyl.app-error.log > "$dir/nginx-error.log" 2>/dev/null
    tail -n 300 "$(ls -t "$GD_LOG_DIR"/setup-*.log 2>/dev/null | sed -n 2p)" > "$dir/setup.log" 2>/dev/null
    nginx -T > "$dir/nginx-config.txt" 2>&1
    [ -f "$PTERO_DIR/.env" ] && cp "$PTERO_DIR/.env" "$dir/panel.env"
    [ -f "$WINGS_CONFIG" ] && cp "$WINGS_CONFIG" "$dir/wings-config.yml"
    gd_progress 85 "Passwörter und Schlüssel werden entfernt..."
    gd_sanitize "$dir"/*
    tar -czf "$out" -C "$GD_TMP" support && chmod 600 "$out"
    gd_progress 100 "Fertig."
    gd_gauge_close
    gd_msg "✔ Support-Paket erstellt" "Das Support-Paket liegt hier:\n\n$out ($(du -h "$out" | cut -f1))\n\nPasswörter, Schlüssel und Tokens wurden entfernt. Prüfe den Inhalt trotzdem kurz, bevor du die Datei weitergibst (z. B. mit: tar -tzf $out)." 14 78
}
