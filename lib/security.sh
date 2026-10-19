#!/bin/bash
# Pfad: lib/security.sh
# Absicherung: Firewall (UFW), MariaDB-Härtung, Certbot-Hooks, optional fail2ban und automatische Sicherheitsupdates.

gd_ssh_ports() {
    # Alle Ports, auf denen sshd lauscht (Standard 22) – damit man sich nicht aussperrt
    # Vereinigung aus: sshd -T (port und ListenAddress mit Port), tatsächlich lauschende sshd-Sockets
    # (auch ssh.socket unter Ubuntu) und dem Port der aktuellen SSH-Verbindung
    local ports
    ports="$( {
        sshd -T 2>/dev/null | awk '$1=="port"{print $2} $1=="listenaddress"{n=split($2,a,":"); if (n>1) print a[n]}'
        systemctl show -p Listen ssh.socket 2>/dev/null | grep -oE ':[0-9]+ \(Stream' | grep -oE '[0-9]+'
        ss -Hltnp 2>/dev/null | grep '"sshd"' | awk '{n=split($4,a,":"); print a[n]}'
        [ -n "${SSH_CONNECTION:-}" ] && echo "${SSH_CONNECTION##* }"
    } | grep -E '^[0-9]+$' | sort -un)"
    [ -z "$ports" ] && ports="22"
    echo "$ports"
}

gd_firewall_setup() {
    # gd_firewall_setup <mit_wings:true/false> [portbereich]
    local with_wings="$1" range="${2:-}" p
    command -v ufw >/dev/null 2>&1 || gd_apt_install ufw || return 1

    # Eingehend alles sperren, was nicht ausdrücklich freigegeben wird; ausgehend alles erlauben
    ufw default deny incoming && ufw default allow outgoing || return 1
    for p in $(gd_ssh_ports); do
        # limit = freigeben, aber mehr als 6 Verbindungsversuche in 30 Sekunden pro IP sperren (unabhängig von fail2ban)
        ufw limit "$p/tcp" comment 'SSH' || return 1
        # Eine ältere "allow"-Regel für denselben Port würde die Begrenzung aushebeln (erste passende Regel gilt)
        ufw delete allow "$p/tcp" >/dev/null 2>&1 || true
    done
    ufw allow 80/tcp comment 'HTTP (Panel, Zertifikate)' || return 1
    ufw allow 443/tcp comment 'HTTPS (Panel)' || return 1
    if [ "$with_wings" = "true" ]; then
        ufw allow 8080/tcp comment 'Wings API' || return 1
        ufw allow 2022/tcp comment 'Wings SFTP' || return 1
        if [ -n "$range" ]; then
            ufw allow "${range/-/:}/tcp" comment 'Gameserver' || return 1
            ufw allow "${range/-/:}/udp" comment 'Gameserver' || return 1
        fi
    fi
    ufw --force enable || return 1
    ufw status verbose
}

gd_mariadb_harden() {
    # Entspricht den wichtigsten Schritten von mysql_secure_installation (ohne Rückfragen)
    gd_mysql <<'SQL' || return 1
DROP USER IF EXISTS ''@'localhost';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
    # Root-Konten für fremde Hosts (z. B. 'root'@'%') entfernen – nur root über localhost/Socket bleibt.
    # Über mysql.user (bei MariaDB >= 10.4 eine Ansicht auf mysql.global_priv, davor eine Tabelle),
    # damit es mit MariaDB 10.5 bis 11.x und MySQL gleichermaßen funktioniert.
    gd_mysql -N -e "SELECT CONCAT('DROP USER IF EXISTS \\'', User, '\\'@\\'', Host, '\\';') FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');" 2>/dev/null \
        | gd_mysql || return 1
    gd_mysql -e "FLUSH PRIVILEGES;" || return 1
    # Die Beispiel-Datenbank "test" nur entfernen, wenn sie leer ist (auf bestehenden Servern evtl. in Benutzung)
    if [ "$(gd_mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='test';" 2>/dev/null)" = "0" ]; then
        gd_mysql -e "DROP DATABASE IF EXISTS test;"
    fi
    # MariaDB darf nur lokal erreichbar sein (Standard unter Debian/Ubuntu). Nur prüfen und protokollieren.
    local bind
    bind="$(my_print_defaults mysqld mariadbd 2>/dev/null | grep -- '--bind-address' | tail -n1 | cut -d= -f2)"
    echo "MariaDB bind-address: ${bind:-Standard (127.0.0.1)}"
    return 0
}

gd_redis_check() {
    # Redis nur lokal erreichbar? (Standard der Distributionspakete)
    local bind
    bind="$(grep -E '^\s*bind\s' /etc/redis/redis.conf 2>/dev/null | tail -n1)"
    echo "Redis: ${bind:-kein bind gesetzt}"
    return 0
}

gd_certbot_hook() {
    # Nach jeder Zertifikatserneuerung nginx neu laden (nur mit gültiger Konfiguration) und Wings neu starten, wenn
    # es das erneuerte Zertifikat nutzt (Wings liest das Zertifikat nur beim Start). Das Ergebnis steht im Log
    # /var/log/germandactyl-setup/certbot-hook.log. Der Hook liegt in renewal-hooks/deploy, certbot ruft ihn dort mit
    # RENEWED_LINEAGE (Pfad unter /etc/letsencrypt/live) und RENEWED_DOMAINS auf – auch bei "certbot renew --dry-run".
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/germandactyl.sh <<'EOF'
#!/bin/sh
# Angelegt von GermanDactyl Setup: Dienste nach Zertifikatserneuerung neu laden
LOG_DIR=/var/log/germandactyl-setup
LOG="$LOG_DIR/certbot-hook.log"
mkdir -p "$LOG_DIR" 2>/dev/null && chmod 700 "$LOG_DIR" 2>/dev/null
log() { echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null; }
log "Zertifikat erneuert: ${RENEWED_LINEAGE:-unbekannt} (${RENEWED_DOMAINS:-keine Angabe})"

# nginx nur mit gültiger Konfiguration neu laden: Bei einem Fehler bleibt die laufende Konfiguration aktiv
if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
    if out="$(nginx -t 2>&1)"; then
        if systemctl reload nginx >> "$LOG" 2>&1; then
            log "nginx neu geladen"
        else
            log "FEHLER: nginx konnte nicht neu geladen werden"
        fi
    else
        log "FEHLER: Die nginx-Konfiguration ist ungültig, nginx wird NICHT neu geladen. Ausgabe von nginx -t:"
        echo "$out" >> "$LOG" 2>/dev/null
    fi
fi

# Wings (Pterodactyl bzw. Pelican) nur neu starten, wenn sein Zertifikat erneuert wurde. Ist unklar, welches
# Zertifikat erneuert wurde (RENEWED_LINEAGE leer, z. B. beim manuellen Aufruf), wird sicherheitshalber neu gestartet.
wings_cert() {
    awk '/^api:/{a=1;next} a && /^[^[:space:]]/{a=0} a && /^[[:space:]]+ssl:/{s=1;next} s && $1=="cert:"{print $2; exit}' "$1" 2>/dev/null | tr -d "'\""
}
restart=0
for cfg in /etc/pterodactyl/config.yml /etc/pelican/config.yml; do
    [ -f "$cfg" ] || continue
    if [ -z "${RENEWED_LINEAGE:-}" ]; then
        restart=1
        continue
    fi
    case "$(wings_cert "$cfg")" in
        "$RENEWED_LINEAGE"/*) restart=1 ;;
    esac
done
if systemctl is-enabled --quiet wings 2>/dev/null; then
    if [ "$restart" = 1 ]; then
        if systemctl restart wings >> "$LOG" 2>&1; then
            log "Wings neu gestartet"
        else
            log "FEHLER: Wings konnte nicht neu gestartet werden"
        fi
    else
        log "Wings nutzt dieses Zertifikat nicht, kein Neustart nötig"
    fi
fi
exit 0
EOF
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/germandactyl.sh
}

gd_fail2ban_setup() {
    # python3-systemd wird für "backend = systemd" benötigt (nur "empfohlen" – ohne startet fail2ban nicht)
    gd_apt_install fail2ban python3-systemd || return 1
    local ports
    ports="$(gd_ssh_ports | paste -sd, -)"
    cat > /etc/fail2ban/jail.d/germandactyl.local <<EOF
# Angelegt von GermanDactyl Setup
[sshd]
enabled  = true
port     = ${ports}
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
    systemctl enable --now fail2ban && systemctl restart fail2ban || return 1
    sleep 2
    systemctl is-active --quiet fail2ban || { journalctl -u fail2ban -n 20 --no-pager; return 1; }
}

gd_autoupdates_enabled() {
    # Tatsächlich wirksamer Wert (berücksichtigt alle Dateien in apt.conf.d)
    apt-config dump 2>/dev/null | grep -q '^APT::Periodic::Unattended-Upgrade "1";'
}

gd_autoupdates_set() {
    # gd_autoupdates_set 1|0 – eigene Datei mit hoher Priorität, vorhandene Einstellungen bleiben unangetastet.
    # Zusätzlich zu den Sicherheitsupdates der Distribution werden Updates aus der PHP-Quelle des Panels erlaubt
    # (sury: "Origin: deb.sury.org", das Ubuntu-PPA von ondrej: "Origin: LP-PPA-ondrej-php"), sonst bleibt PHP auf dem
    # Stand der Installation stehen. Die Liste wird an die Origins-Pattern der Distribution angehängt, nicht ersetzt.
    # Das Docker-Repository bleibt bewusst außen vor: Ein Docker-Update startet alle Gameserver neu.
    printf '// Angelegt von GermanDactyl Setup\nAPT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "%s";\nUnattended-Upgrade::Origins-Pattern { "origin=deb.sury.org"; "origin=LP-PPA-ondrej-php"; };\n' "$1" \
        > /etc/apt/apt.conf.d/99germandactyl-auto-upgrades
}

gd_unattended_upgrades_setup() {
    gd_apt_install unattended-upgrades apt-listchanges || return 1
    echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
    dpkg-reconfigure -f noninteractive unattended-upgrades
    # Direkt setzen: dpkg-reconfigure überschreibt eine bereits geänderte Datei nicht
    gd_autoupdates_set 1
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    return 0
}

gd_security_ask() {
    # Fragt die optionalen Sicherheitsfunktionen ab. Setzt GD_SEC_UFW, GD_SEC_FAIL2BAN, GD_SEC_UPDATES (true/false)
    local sel
    sel=$(whiptail --title "✚ Absicherung des Servers" --checklist "Welche Schutzmaßnahmen sollen eingerichtet werden? (Leertaste = an/aus)\n\nDie Firewall gibt automatisch deinen SSH-Port frei, damit du dich nicht aussperrst." 19 80 4 \
        "UFW" "Firewall aktivieren und benötigte Ports freigeben" ON \
        "FAIL2BAN" "Angriffe auf SSH automatisch sperren" ON \
        "UPDATES" "Sicherheits- und PHP-Updates automatisch (Docker nicht)" ON \
        "BACKUP" "Tägliche Backups (inkrementell, inkl. Datenbanken)" ON 3>&1 1>&2 2>&3) || sel=""
    GD_SEC_UFW=false; GD_SEC_FAIL2BAN=false; GD_SEC_UPDATES=false; GD_SEC_BACKUP=false
    [[ "$sel" == *'"UFW"'* ]] && GD_SEC_UFW=true
    [[ "$sel" == *'"FAIL2BAN"'* ]] && GD_SEC_FAIL2BAN=true
    [[ "$sel" == *'"UPDATES"'* ]] && GD_SEC_UPDATES=true
    [[ "$sel" == *'"BACKUP"'* ]] && GD_SEC_BACKUP=true
    return 0
}

gd_security_steps() {
    # gd_security_steps <start-prozent> <mit_wings> [portbereich] – innerhalb eines offenen Fortschrittsbalkens
    local p="$1" with_wings="$2" range="${3:-}"
    # Pelican nutzt standardmäßig SQLite – MariaDB/Redis nur prüfen, wenn sie installiert sind
    if command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1; then
        gd_step "$p" "Sicherheit: Datenbank wird abgesichert..." gd_mariadb_harden
    fi
    [ -f /etc/redis/redis.conf ] && gd_step "$p" "Sicherheit: Redis wird geprüft..." gd_redis_check
    if [ "${GD_SEC_UFW:-false}" = "true" ]; then
        gd_step_optional $((p + 1)) "Sicherheit: Firewall wird eingerichtet..." "Die Firewall (UFW) konnte nicht aktiviert werden (z. B. in LXC/OpenVZ-Containern nicht erlaubt)." gd_firewall_setup "$with_wings" "$range"
    fi
    if [ "${GD_SEC_FAIL2BAN:-false}" = "true" ]; then
        gd_step_optional $((p + 2)) "Sicherheit: fail2ban wird eingerichtet..." "fail2ban konnte nicht gestartet werden." gd_fail2ban_setup
    fi
    if [ "${GD_SEC_UPDATES:-false}" = "true" ]; then
        gd_step $((p + 3)) "Sicherheit: Automatische Sicherheitsupdates werden aktiviert..." gd_unattended_upgrades_setup
    fi
    if [ "${GD_SEC_BACKUP:-false}" = "true" ] && declare -F gd_ab_setup >/dev/null; then
        # Täglich 04:00 Uhr, lokal, Gameserver nur mit Wings auf diesem Server.
        # Optional: Ein Fehler (z. B. Archiv mit anderem Passwort, kein Speicherplatz) bricht die Installation nicht ab,
        # sondern landet als Warnung am Ende.
        GD_AB_SETUP_OK=false
        gd_step_optional $((p + 4)) "Automatische Backups werden eingerichtet..." "Automatische Backups konnten nicht eingerichtet werden – später über Backups → Automatische Backups." gd_security_backup_setup "$with_wings"
        if [ "$GD_AB_SETUP_OK" = "true" ]; then
            # Erstes Backup sofort erstellen (auf einem neuen Server geht das schnell)
            gd_step_optional $((p + 5)) "Erstes Backup wird erstellt..." "Das erste Backup ist fehlgeschlagen (Details: /var/log/germandactyl-setup/auto-backup.log)." "$GD_AB_SCRIPT"
        else
            # Ohne eingerichtete Backups gibt es auch kein Backup-Passwort, das am Ende angezeigt werden müsste
            GD_SEC_BACKUP=false
        fi
    fi
}

gd_security_backup_setup() {
    # gd_security_backup_setup <mit_wings:true/false> – Archiv lokal unter $GD_BACKUP_ROOT/restic, täglich 04:00 Uhr.
    # Setzt GD_AB_SETUP_OK=true nur bei vollständigem Erfolg (läuft im selben Shell-Prozess wie gd_step_optional).
    gd_ab_setup "$GD_BACKUP_ROOT/restic" "$1" "04:00" || return 1
    gd_apt_install jq || return 1
    GD_AB_SETUP_OK=true
}
