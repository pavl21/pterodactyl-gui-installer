#!/bin/bash
# Pfad: lib/dbhost.sh
# Firewall des Database-Hosts (Port 3306/tcp) an die Nodes des Panels anpassen. Jede Node bekommt eine Freigabe für
# ihre IPv4-Adresse, entfernte Nodes und veraltete Adressen verlieren sie wieder. Die Regeln sind am Kommentar
# 'MariaDB (Node <fqdn>)' erkennbar. Benötigt lib/common.sh und lib/wings.sh (gd_panel_sql).

gd_dbhost_sync_firewall() {
    # Gleicht die ufw-Regeln für Port 3306 mit den Nodes im Panel ab. Ohne aktive Firewall oder ohne Database-Host
    # auf diesem Server (keine Regel 'MariaDB (Panel)' / 'MariaDB (Gameserver-Container)') passiert nichts.
    # Fehler werden nur protokolliert, die Rückgabe ist immer 0.
    #
    # Zu den Benutzern: Das Panel legt die Datenbanken und ihre Benutzer selbst an. Gameserver-Container auf
    # entfernten Nodes verbinden sich mit diesen Benutzern (Host '%'), dafür ist hier nichts zu tun. Freigegeben wird
    # nur der Netzzugang (Port 3306) für die Nodes.
    local rules nodes own fqdn ip ips num from node desc parsed
    local fqdns="" valid="" existing="" dels="" unsure=" "
    declare -F gd_panel_sql >/dev/null || gd_source_lib wings

    gd_ufw_active || return 0
    rules="$(LC_ALL=C ufw status numbered 2>/dev/null)"
    grep -qE '# MariaDB \((Panel|Gameserver-Container)\)' <<< "$rules" || return 0

    # Nodes aus dem Panel. Schlägt die Abfrage fehl, bleibt alles unverändert (sonst würden alle Node-Regeln gelöscht)
    nodes="$(gd_panel_sql "SELECT fqdn FROM nodes;" 2>>"$GD_LOG")" || {
        gd_log "Database-Host-Firewall: Nodes konnten nicht aus dem Panel gelesen werden, keine Änderung"
        return 0
    }

    # Eigene Adressen dieses Servers: Dafür braucht es keine Node-Freigabe (Panel und Gameserver-Container haben ihre Regeln)
    own="$( { gd_local_ips; gd_public_ip; } 2>/dev/null)"

    # Node-Adressen auflösen. Cloudflare-Adressen und fehlende A-Einträge sind unsicher: Bestehende Regeln dieser Node
    # werden dann nicht entfernt, weil die echte Adresse nicht bekannt ist.
    while IFS= read -r fqdn; do
        fqdn="${fqdn//[[:space:]]/}"
        [ -n "$fqdn" ] || continue
        if ! [[ "$fqdn" =~ ^[A-Za-z0-9.-]{1,253}$ ]]; then
            gd_log "Database-Host-Firewall: ungültiger Node-Name übersprungen: $fqdn"
            continue
        fi
        fqdns+="$fqdn"$'\n'
        if [[ "$fqdn" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ips="$fqdn"
        else
            ips="$(gd_resolve_a "$fqdn")"
        fi
        if [ -z "$ips" ]; then
            gd_log "Database-Host-Firewall: Node $fqdn ohne IPv4-Adresse, ihre Regeln bleiben unverändert"
            unsure+="$fqdn "
        fi
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            if gd_is_cloudflare_ip "$ip"; then
                gd_log "Node $fqdn hinter Cloudflare, IP unbekannt"
                unsure+="$fqdn "
                continue
            fi
            grep -qxF "$ip" <<< "$own" && continue
            valid+="$fqdn $ip"$'\n'
        done <<< "$ips"
    done <<< "$nodes"

    # Vorhandene Node-Regeln: "Regelnummer|Node Adresse". Veraltet ist eine Regel, deren Node nicht mehr im Panel steht,
    # oder deren Adresse nicht mehr zur Node gehört (nur wenn die Adresse eindeutig ermittelt werden konnte).
    parsed="$(awk '/# MariaDB \(Node [^)]+\)/ {
        num = ""; if (match($0, /^\[ *[0-9]+\]/)) { num = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", num) }
        from = ""; if (match($0, /ALLOW IN +[^ ]+/)) { from = substr($0, RSTART, RLENGTH); sub(/ALLOW IN +/, "", from) }
        node = $0; sub(/^.*# MariaDB \(Node /, "", node); sub(/\).*$/, "", node)
        print num "|" node " " from
    }' <<< "$rules")"
    while IFS='|' read -r num desc; do
        [ -n "$num" ] || continue
        node="${desc% *}"
        from="${desc##* }"
        existing+="$desc"$'\n'
        if ! grep -qxF "$node" <<< "$fqdns"; then
            dels+="$num|$desc"$'\n'
        elif [[ " $unsure " != *" $node "* ]] && ! grep -qxF "$node $from" <<< "$valid"; then
            dels+="$num|$desc"$'\n'
        fi
    done <<< "$parsed"

    # Zuerst löschen, von hinten nach vorn (die Nummern verschieben sich nach jedem Löschen)
    while IFS='|' read -r num desc; do
        [ -n "$num" ] || continue
        if ufw --force delete "$num" >> "$GD_LOG" 2>&1; then
            gd_log "Database-Host-Firewall: Regel $num entfernt ($desc)"
        else
            gd_log "Database-Host-Firewall: Regel $num konnte nicht entfernt werden ($desc)"
        fi
    done < <(sort -t'|' -k1,1 -rn <<< "$dels")

    # Dann fehlende Freigaben anlegen
    while IFS=' ' read -r fqdn ip; do
        [ -n "$ip" ] || continue
        grep -qxF "$fqdn $ip" <<< "$existing" && continue
        if ufw allow from "$ip" to any port 3306 proto tcp comment "MariaDB (Node $fqdn)" >> "$GD_LOG" 2>&1; then
            gd_log "Database-Host-Firewall: Freigabe für Node $fqdn ($ip) angelegt"
        else
            gd_log "Database-Host-Firewall: Freigabe für Node $fqdn ($ip) fehlgeschlagen"
        fi
    done <<< "$valid"
    return 0
}

gd_dbhost_timer_install() {
    # Nächtlicher Abgleich der Firewall mit den Nodes: Timer germandactyl-dbhost.timer (04:30 Uhr, bis zu 15 Minuten
    # Zufallsverzögerung, nachholen wenn der Server aus war). Der Dienst ruft "germandactyl dbhost-sync" auf (gd_dispatch).
    # Die Units liegen unter /etc/systemd/system und werden von gd_dbhost_timer_remove wieder entfernt.
    cat > /etc/systemd/system/germandactyl-dbhost.service <<'EOF_UNIT'
[Unit]
Description=GermanDactyl Setup – Firewall des Database-Hosts an die Nodes anpassen
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=oneshot
# HOME, damit der Kurzbefehl und die Zugangsdaten des Panels wie bei den anderen Diensten gefunden werden
Environment=HOME=/root
ExecStart=/usr/local/bin/germandactyl dbhost-sync
Nice=10
EOF_UNIT
    cat > /etc/systemd/system/germandactyl-dbhost.timer <<'EOF_UNIT'
[Unit]
Description=GermanDactyl Setup – nächtlicher Abgleich der Database-Host-Firewall

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF_UNIT
    systemctl daemon-reload || return 1
    systemctl enable --now germandactyl-dbhost.timer
}

gd_dbhost_timer_remove() {
    # Timer und Dienst entfernen (Deinstallation des Panels und Aufräumen nach der Deinstallation). Ohne Wirkung, wenn es
    # den Timer nicht gibt.
    systemctl disable --now germandactyl-dbhost.timer >/dev/null 2>&1
    rm -f /etc/systemd/system/germandactyl-dbhost.service /etc/systemd/system/germandactyl-dbhost.timer
    systemctl daemon-reload >/dev/null 2>&1
    return 0
}
