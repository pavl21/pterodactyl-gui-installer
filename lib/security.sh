#!/bin/bash
# Pfad: lib/security.sh
# Absicherung: Firewall (UFW), MariaDB-Härtung, Certbot-Hooks, optional fail2ban und automatische Sicherheitsupdates.

gd_ssh_ports() {
    # Alle Ports, auf denen sshd lauscht (Standard 22) – damit man sich nicht aussperrt
    local ports
    ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u)"
    [ -z "$ports" ] && ports="22"
    echo "$ports"
}

gd_firewall_setup() {
    # gd_firewall_setup <mit_wings:true/false> [portbereich]
    local with_wings="$1" range="${2:-}" p
    command -v ufw >/dev/null 2>&1 || gd_apt_install ufw || return 1

    for p in $(gd_ssh_ports); do
        ufw allow "$p/tcp" comment 'SSH' || return 1
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
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
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
    # Nach jeder Zertifikatserneuerung nginx neu laden und Wings neu starten (Wings liest das Zertifikat beim Start)
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/germandactyl.sh <<'EOF'
#!/bin/sh
# Angelegt von GermanDactyl Setup: Dienste nach Zertifikatserneuerung neu laden
systemctl reload nginx 2>/dev/null || true
if systemctl is-enabled --quiet wings 2>/dev/null; then
    systemctl restart wings
fi
EOF
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/germandactyl.sh
}

gd_fail2ban_setup() {
    gd_apt_install fail2ban || return 1
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
    systemctl enable --now fail2ban && systemctl restart fail2ban
}

gd_unattended_upgrades_setup() {
    gd_apt_install unattended-upgrades apt-listchanges || return 1
    echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
    dpkg-reconfigure -f noninteractive unattended-upgrades
}

gd_security_ask() {
    # Fragt die optionalen Sicherheitsfunktionen ab. Setzt GD_SEC_UFW, GD_SEC_FAIL2BAN, GD_SEC_UPDATES (true/false)
    local sel
    sel=$(whiptail --title "🛡️ Absicherung des Servers" --checklist "Welche Schutzmaßnahmen sollen eingerichtet werden? (Leertaste = an/aus)\n\nDie Firewall gibt automatisch deinen SSH-Port frei, damit du dich nicht aussperrst." 19 80 4 \
        "UFW" "Firewall aktivieren und benötigte Ports freigeben" ON \
        "FAIL2BAN" "Angriffe auf SSH automatisch sperren" ON \
        "UPDATES" "Sicherheitsupdates automatisch installieren" ON \
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
    gd_step "$p" "Sicherheit: Datenbank wird abgesichert..." gd_mariadb_harden
    gd_step "$p" "Sicherheit: Redis wird geprüft..." gd_redis_check
    if [ "${GD_SEC_UFW:-false}" = "true" ]; then
        gd_step $((p + 1)) "Sicherheit: Firewall wird eingerichtet..." gd_firewall_setup "$with_wings" "$range"
    fi
    if [ "${GD_SEC_FAIL2BAN:-false}" = "true" ]; then
        gd_step $((p + 2)) "Sicherheit: fail2ban wird eingerichtet..." gd_fail2ban_setup
    fi
    if [ "${GD_SEC_UPDATES:-false}" = "true" ]; then
        gd_step $((p + 3)) "Sicherheit: Automatische Sicherheitsupdates werden aktiviert..." gd_unattended_upgrades_setup
    fi
    if [ "${GD_SEC_BACKUP:-false}" = "true" ] && declare -F gd_ab_setup >/dev/null; then
        # Täglich 04:00 Uhr, lokal, Gameserver nur mit Wings auf diesem Server
        gd_step $((p + 4)) "Automatische Backups werden eingerichtet..." gd_ab_setup "$GD_BACKUP_ROOT/restic" "$with_wings" "04:00"
        gd_step $((p + 4)) "jq wird installiert..." gd_apt_install jq
    fi
}
