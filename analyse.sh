#!/bin/bash
# Pfad: analyse.sh
# Allgemeine Analyse des Servers und der Pterodactyl-Installation.
# Aufruf ohne Dialoge (z. B. per SSH oder cron): bash analyse.sh --text [--fix]

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

TEXT_MODE=false
[ "${1:-}" = "--text" ] && TEXT_MODE=true

ERRORS=(); WARNINGS=(); OKS=(); FIX_DESC=(); FIX_CMD=()
fail() { ERRORS+=("✖ $1"); }
add_fix() {
    # add_fix "Beschreibung" "funktion argumente" – automatisch behebbares Problem vormerken (ohne Doppelte)
    local d
    for d in "${FIX_DESC[@]}"; do [ "$d" = "$1" ] && return; done
    FIX_DESC+=("$1"); FIX_CMD+=("$2")
}
warn() { WARNINGS+=("⚠ $1"); }
ok()   { OKS+=("✔ $1"); }

step() {
    # Fortschritt anzeigen, damit die Analyse nie "eingefroren" wirkt
    if $TEXT_MODE; then echo "[$1%] $2"; else gd_progress "$1" "$2"; fi
}

WINGS_CONFIG="/etc/pterodactyl/config.yml"
PANEL_DOMAIN="$(gd_conf_get PANEL_DOMAIN)"
if [ -z "$PANEL_DOMAIN" ] && [ -f "$PTERO_DIR/.env" ]; then
    PANEL_DOMAIN="$(grep -E '^APP_URL=' "$PTERO_DIR/.env" | cut -d= -f2- | tr -d '"' | sed 's#^https\?://##; s#/.*##')"
fi
panel_env() { grep -E "^$1=" "$PTERO_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'; }

# ---------------------------------------------------------------------------
# Einzelprüfungen
# ---------------------------------------------------------------------------
check_system() {
    local usage free inodes mem swap
    usage="$(df -P / | awk 'NR==2{print $5}' | tr -d '%')"
    free="$(df -h / | awk 'NR==2{print $4}')"
    if [ "$usage" -ge 95 ]; then fail "Festplatte: ${usage} % belegt, nur ${free} frei – Server und Datenbank können abstürzen"
    elif [ "$usage" -ge 85 ]; then warn "Festplatte: ${usage} % belegt, ${free} frei"
    else ok "Festplatte: ${usage} % belegt, ${free} frei"; fi
    if [ -d /var/lib/pterodactyl ] && [ "$(df -P /var/lib/pterodactyl | awk 'NR==2{print $6}')" != "/" ]; then
        usage="$(df -P /var/lib/pterodactyl | awk 'NR==2{print $5}' | tr -d '%')"
        [ "$usage" -ge 85 ] && warn "Gameserver-Partition: ${usage} % belegt" || ok "Gameserver-Partition: ${usage} % belegt"
    fi
    inodes="$(df -Pi / | awk 'NR==2{print $5}' | tr -d '%')"
    [[ "$inodes" =~ ^[0-9]+$ ]] && [ "$inodes" -ge 90 ] && fail "Inodes: ${inodes} % belegt – es können keine Dateien mehr angelegt werden"

    mem="$(LC_ALL=C free -m | awk '/^Mem:/{print $7}')"
    swap="$(LC_ALL=C free -m | awk '/^Swap:/{print $2}')"
    if [ "${mem:-0}" -lt 200 ]; then fail "Arbeitsspeicher: nur ${mem} MB verfügbar"
    elif [ "${mem:-0}" -lt 500 ]; then warn "Arbeitsspeicher: nur ${mem} MB verfügbar (Swap: ${swap} MB)"
    else ok "Arbeitsspeicher: ${mem} MB verfügbar (Swap: ${swap} MB)"; fi

    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "no" ]; then
        warn "Systemzeit wird nicht synchronisiert (wichtig für SSL und Zwei-Faktor-Anmeldung)"; add_fix "Zeitsynchronisation aktivieren" "fix_ntp"
    fi
    [ -f /var/run/reboot-required ] && warn "Ein Neustart ist erforderlich, um installierte Updates (z. B. Kernel) zu aktivieren"
}

check_updates() {
    timeout 120 apt-get update -qq >> "$GD_LOG" 2>&1
    local list count sec
    list="$(apt list --upgradable 2>/dev/null | grep -vE '^(Listing|Auflistung)')"
    count="$(grep -c . <<< "$list")"
    sec="$(grep -ci -- '-security' <<< "$list")"
    local pk="Pakete"; [ "$count" -eq 1 ] && pk="Paket"
    if [ "$sec" -gt 0 ]; then warn "Offene Updates: $count $pk, davon $sec mit Sicherheitsupdates (apt upgrade)"
    elif [ "$count" -gt 0 ]; then warn "Offene Updates: $count $pk (apt upgrade)"
    else ok "Alle Pakete sind aktuell"; fi
}

pkg_status() {
    # pkg_status <paket> <anzeigename> – installiert? aktuellste Version aus den Paketquellen?
    local installed candidate
    installed="$(dpkg-query -W -f='${Version}' "$1" 2>/dev/null)" || return 0
    [ -z "$installed" ] && return 0
    candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:|Installationskandidat:/{print $2}')"
    if [ -n "$candidate" ] && [ "$candidate" != "(none)" ] && [ "$candidate" != "$installed" ]; then
        warn "$2: Version $installed installiert, $candidate verfügbar"
    else
        ok "$2: Version $installed (aktuell)"
    fi
}

check_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        [ -d "$PTERO_DIR" ] && fail "nginx ist nicht installiert – das Panel ist nicht erreichbar"
        return
    fi
    local test_out warnings socks sock
    pkg_status nginx "nginx"
    test_out="$(nginx -t 2>&1)"
    if [[ "$test_out" == *"test is successful"* ]]; then
        ok "nginx-Konfiguration ist gültig"
    else
        fail "nginx-Konfiguration fehlerhaft: $(grep -m1 -E 'emerg|error' <<< "$test_out" | sed 's/^nginx: //' | cut -c1-110)"
    fi
    warnings="$(grep -E '\[warn\]' <<< "$test_out" | sed 's/^nginx: \[warn\] //' | sort -u | head -3)"
    while IFS= read -r line; do [ -n "$line" ] && warn "nginx-Hinweis: $(cut -c1-110 <<< "$line")"; done <<< "$warnings"
    if systemctl is-active --quiet nginx; then ok "nginx läuft"; else fail "nginx läuft NICHT (systemctl status nginx)"; add_fix "nginx neu starten" "fix_restart nginx"; fi

    # Existiert der PHP-FPM-Socket, den nginx verwendet? (häufigste Ursache für "502 Bad Gateway")
    socks="$(nginx -T 2>/dev/null | grep -oE 'fastcgi_pass +unix:[^;]+' | sed 's/.*unix://' | sort -u)"
    for sock in $socks; do
        if [ -S "$sock" ]; then ok "PHP-Socket vorhanden: $sock"
        else fail "nginx nutzt $sock, der nicht existiert → Fehler 502 Bad Gateway"; add_fix "PHP-Socket in nginx korrigieren (Ursache für 502)" "fix_php_socket"; fi
    done
    if [ -d "$PTERO_DIR" ] && [ ! -e /etc/nginx/sites-enabled/pterodactyl.conf ]; then
        warn "Die nginx-Seite für das Panel ist nicht aktiviert (/etc/nginx/sites-enabled/pterodactyl.conf fehlt)"
    fi
}

check_cert_file() {
    # check_cert_file <datei> <bezeichnung> [domain]
    local file="$1" label="$2" domain="${3:-}" days issuer
    if [ ! -f "$file" ]; then fail "$label: Zertifikatsdatei fehlt ($file)"; return; fi
    days="$(gd_cert_days_left "$file")" || { fail "$label: Zertifikat ist nicht lesbar ($file)"; return; }
    issuer="$(openssl x509 -noout -issuer -in "$file" 2>/dev/null)"
    if [ "$days" -lt 0 ]; then fail "$label: Zertifikat ist seit $(( -days )) Tagen ABGELAUFEN"
    elif [ "$days" -lt 14 ]; then warn "$label: Zertifikat läuft in $days Tagen ab – wird es automatisch erneuert?"
    else ok "$label: Zertifikat noch $days Tage gültig"; fi
    [[ "$issuer" == *STAGING* || "$issuer" == *"Fake LE"* ]] && fail "$label: Test-Zertifikat von Let's Encrypt (STAGING) – Browser vertrauen ihm nicht"
    if [ -n "$domain" ] && ! gd_cert_matches_domain "$file" "$domain"; then
        fail "$label: Zertifikat gilt nicht für $domain"
    fi
}

check_served_cert() {
    # Vergleicht das ausgelieferte Zertifikat mit der Datei: erkennt z. B. "erneuert, aber nicht neu geladen"
    local label="$1" port="$2" domain="$3" file="$4" served_end file_end
    gd_served_cert 127.0.0.1 "$port" "$domain" > "$GD_TMP/served.pem"
    if [ ! -s "$GD_TMP/served.pem" ]; then
        fail "$label: Auf Port $port wird kein Zertifikat ausgeliefert (Dienst aus oder SSL nicht eingerichtet)"
        return
    fi
    served_end="$(openssl x509 -enddate -noout -in "$GD_TMP/served.pem" 2>/dev/null | cut -d= -f2)"
    file_end="$(openssl x509 -enddate -noout -in "$file" 2>/dev/null | cut -d= -f2)"
    if [ -n "$file_end" ] && [ "$served_end" != "$file_end" ]; then
        warn "$label: Es wird noch ein älteres Zertifikat ausgeliefert (gültig bis $served_end)"
        [ "$port" = "443" ] && add_fix "nginx neu laden (neues Zertifikat ausliefern)" "fix_restart nginx"
        [ "$port" != "443" ] && add_fix "Wings neu starten (neues Zertifikat ausliefern)" "fix_restart wings"
    fi
    # Vollständige Prüfung wie ein Browser (Kette, Domain, Gültigkeit)
    local rc
    curl -s --noproxy '*' -o /dev/null --max-time 10 --resolve "${domain}:${port}:127.0.0.1" "https://${domain}:${port}/" 2>/dev/null
    rc=$?
    case $rc in
        0|22) ok "$label: Zertifikat wird von Browsern als gültig anerkannt (https://${domain}:${port})" ;;
        60) fail "$label: Browser würden das Zertifikat ablehnen (Kette unvollständig, falsche Domain oder abgelaufen)" ;;
        7|28) fail "$label: Port $port ist nicht erreichbar" ;;
        *) warn "$label: TLS-Prüfung ergab Fehlercode $rc" ;;
    esac
}

check_certificates() {
    local renew=false files f
    if [ -n "$PANEL_DOMAIN" ] && [ -d "$PTERO_DIR" ]; then
        f="$(nginx -T 2>/dev/null | awk -v d="$PANEL_DOMAIN" '$1=="server_name" && index($0, d) {s=1} s && $1=="ssl_certificate" {gsub(";","",$2); print $2; exit}')"
        [ -z "$f" ] && f="/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem"
        check_cert_file "$f" "Panel ($PANEL_DOMAIN)" "$PANEL_DOMAIN"
        systemctl is-active --quiet nginx && check_served_cert "Panel" 443 "$PANEL_DOMAIN" "$f"
    fi
    if [ -f "$WINGS_CONFIG" ] && grep -qE '^\s+enabled: true' "$WINGS_CONFIG"; then
        local wcert wdomain wport
        wcert="$(awk '/^\s+ssl:/{s=1} s && $1=="cert:" {print $2; exit}' "$WINGS_CONFIG" | tr -d "'\"")"
        wport="$(awk '/^api:/{a=1} a && $1=="port:" {print $2; exit}' "$WINGS_CONFIG")"
        wdomain="$(gd_conf_get WINGS_FQDN)"
        [ -z "$wdomain" ] && wdomain="$(basename "$(dirname "$wcert")")"
        check_cert_file "$wcert" "Wings ($wdomain)" "$wdomain"
        systemctl is-active --quiet wings && check_served_cert "Wings" "${wport:-8080}" "$wdomain" "$wcert"
    fi
    # Weitere Let's-Encrypt-Zertifikate auf dem Server
    for files in /etc/letsencrypt/live/*/fullchain.pem; do
        [ -f "$files" ] || continue
        f="$(basename "$(dirname "$files")")"
        [ "$f" = "$PANEL_DOMAIN" ] && continue
        [ "$f" = "$(gd_conf_get WINGS_FQDN)" ] && continue
        check_cert_file "$files" "Zertifikat $f"
    done
    # Automatische Erneuerung
    if systemctl is-enabled --quiet certbot.timer 2>/dev/null || [ -f /etc/cron.d/certbot ] || snap list certbot >/dev/null 2>&1; then
        renew=true
    fi
    if compgen -G "/etc/letsencrypt/live/*" >/dev/null; then
        $renew && ok "Automatische Zertifikatserneuerung ist aktiv" \
               || fail "Keine automatische Zertifikatserneuerung gefunden (certbot.timer) – Zertifikate laufen nach 90 Tagen ab"
        if [ -f "$WINGS_CONFIG" ] && [ ! -x /etc/letsencrypt/renewal-hooks/deploy/germandactyl.sh ]; then
            warn "Nach einer Zertifikatserneuerung wird Wings nicht automatisch neu gestartet"; add_fix "Deploy-Hook für Zertifikatserneuerung anlegen" "fix_deploy_hook"
        fi
    fi
}

check_services() {
    local svc php_fpm
    php_fpm="$(systemctl list-units --type=service --all 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | sed 's/\.service$//' | sort -V | tail -n1)"
    for svc in mariadb redis-server "$php_fpm" pteroq wings docker fail2ban; do
        [ -z "$svc" ] && continue
        systemctl cat "${svc}.service" >/dev/null 2>&1 || continue
        if systemctl is-active --quiet "$svc"; then ok "Dienst $svc läuft"
        else fail "Dienst $svc läuft NICHT (systemctl status $svc)"; add_fix "Dienst $svc neu starten" "fix_restart $svc"; fi
    done
    pkg_status mariadb-server "MariaDB"
    pkg_status redis-server "Redis"
    pkg_status docker-ce "Docker"
}

check_panel() {
    [ -f "$PTERO_DIR/config/app.php" ] || return
    local installed latest php_version code
    installed="$(grep "'version' =>" "$PTERO_DIR/config/app.php" | cut -d\' -f4)"
    latest="$(gd_latest_release pterodactyl/panel)"
    if [ -z "$latest" ]; then warn "Pterodactyl Panel v$installed – die neueste Version konnte nicht abgefragt werden (GitHub nicht erreichbar)"
    elif [ "$installed" = "$latest" ]; then ok "Pterodactyl Panel v$installed ist aktuell"
    elif gd_version_ge "$installed" "$latest"; then ok "Pterodactyl Panel v$installed (neuer als die letzte Veröffentlichung)"
    else warn "Pterodactyl Panel v$installed installiert, v$latest verfügbar (Hauptmenü → Panel aktualisieren)"; fi

    php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"
    if [ -z "$php_version" ]; then fail "PHP ist nicht installiert"
    elif gd_version_ge "$php_version" "8.2"; then ok "PHP $php_version"
    else fail "PHP $php_version ist zu alt (benötigt 8.2 oder 8.3) – Hauptmenü → Panel aktualisieren stellt um"; fi

    if [ "$(panel_env APP_DEBUG)" = "true" ]; then fail "APP_DEBUG=true in der .env – Fehlermeldungen verraten interne Daten"; add_fix "APP_DEBUG auf false setzen" "fix_app_debug"; fi
    [ "$(panel_env APP_ENV)" != "production" ] && warn "APP_ENV ist nicht 'production'"
    if [ "$(stat -c %U "$PTERO_DIR/storage")" = "www-data" ] && [ "$(stat -c %U "$PTERO_DIR/bootstrap/cache")" = "www-data" ]; then
        ok "Verzeichnisrechte des Panels sind korrekt"
    else
        fail "Verzeichnisrechte falsch (chown -R www-data:www-data $PTERO_DIR)"; add_fix "Verzeichnisrechte des Panels korrigieren" "fix_permissions"
    fi
    if [ "$(stat -c %a "$PTERO_DIR/.env" 2>/dev/null)" -gt 640 ] 2>/dev/null; then warn ".env ist für andere Benutzer lesbar"; add_fix "Zugriffsrechte der .env einschränken" "fix_permissions"; fi
    crontab -l 2>/dev/null | grep -q "$PTERO_DIR/artisan schedule:run" && ok "Cronjob des Panels ist eingerichtet" \
        || { fail "Cronjob des Panels fehlt – Zeitpläne und Aufräumarbeiten laufen nicht"; add_fix "Cronjob des Panels einrichten" "fix_cron"; }

    if [ -n "$PANEL_DOMAIN" ]; then
        code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${PANEL_DOMAIN}:443:127.0.0.1" "https://${PANEL_DOMAIN}/auth/login")"
        case "$code" in
            200|302) ok "Panel antwortet (https://${PANEL_DOMAIN})" ;;
            502) fail "Panel antwortet mit 502 Bad Gateway – PHP-FPM läuft nicht oder nginx nutzt einen falschen PHP-Socket"; add_fix "PHP-Socket in nginx korrigieren (Ursache für 502)" "fix_php_socket" ;;
            500) fail "Panel antwortet mit 500 – Fehler im Panel (storage/logs prüfen, Problembehandlung → Panel reparieren)" ;;
            000) fail "Panel ist lokal nicht erreichbar (nginx/SSL prüfen)" ;;
            *) warn "Panel antwortet mit HTTP $code" ;;
        esac
    fi
}

check_wings() {
    [ -x /usr/local/bin/wings ] || return
    local installed latest token port domain code
    installed="$(/usr/local/bin/wings version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    latest="$(gd_latest_release pterodactyl/wings)"
    if [ -z "$latest" ]; then warn "Wings v$installed – die neueste Version konnte nicht abgefragt werden"
    elif [ "$installed" = "$latest" ] || gd_version_ge "$installed" "$latest"; then ok "Wings v$installed ist aktuell"
    else warn "Wings v$installed installiert, v$latest verfügbar (Wings-Verwaltung → aktualisieren)"; fi
    [ -f "$WINGS_CONFIG" ] || { fail "Wings ist nicht konfiguriert ($WINGS_CONFIG fehlt)"; return; }
    token="$(awk '$1=="token:"{print $2; exit}' "$WINGS_CONFIG" | tr -d "'\"")"
    port="$(awk '/^api:/{a=1} a && $1=="port:" {print $2; exit}' "$WINGS_CONFIG")"
    domain="$(gd_conf_get WINGS_FQDN)"
    [ -z "$domain" ] && domain="localhost"
    code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${domain}:${port:-8080}:127.0.0.1" -H "Authorization: Bearer ${token}" "https://${domain}:${port:-8080}/api/system")"
    case "$code" in
        200) ok "Wings-API antwortet (Verbindung zum Panel möglich)" ;;
        401|403) fail "Wings-API lehnt den Token ab – config.yml passt nicht zur Node im Panel" ;;
        000) fail "Wings-API ist nicht erreichbar (Dienst, Port ${port:-8080} oder Zertifikat)" ;;
        *) warn "Wings-API antwortet mit HTTP $code" ;;
    esac
}

check_network() {
    if getent hosts github.com >/dev/null 2>&1; then ok "DNS-Auflösung funktioniert"; else fail "DNS-Auflösung funktioniert nicht (github.com)"; fi
    if [ -n "$PANEL_DOMAIN" ]; then
        local server_ip dns_ips
        server_ip="$(gd_public_ip)"
        dns_ips="$(gd_resolve_a "$PANEL_DOMAIN")"
        if [ -z "$dns_ips" ]; then fail "Die Domain $PANEL_DOMAIN hat keinen A-Eintrag"
        elif grep -qxF "$server_ip" <<< "$dns_ips"; then ok "Die Domain $PANEL_DOMAIN zeigt auf diesen Server ($server_ip)"
        elif gd_is_cloudflare_ip "$(head -n1 <<< "$dns_ips")"; then warn "Die Domain $PANEL_DOMAIN läuft über den Cloudflare-Proxy – für Wings und Zertifikate 'DNS only' verwenden"
        else fail "Die Domain $PANEL_DOMAIN zeigt auf $(head -n1 <<< "$dns_ips"), dieser Server hat $server_ip"; fi
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ok "Firewall (UFW) ist aktiv"
        if [ -x /usr/local/bin/wings ] && ! ufw status | grep -qE '^(8080|8080/tcp) '; then
            warn "Die Firewall gibt Port 8080 (Wings) nicht frei"
        fi
    fi
}

check_backups() {
    local last age
    if systemctl cat germandactyl-backup.timer >/dev/null 2>&1; then
        if systemctl is-active --quiet germandactyl-backup.timer; then
            last="$(gd_conf_get AUTO_BACKUP_LAST_OK)"
            if [ -z "$last" ]; then warn "Automatische Backups sind aktiv, aber noch nie erfolgreich gelaufen"
            else
                age=$(( ($(date +%s) - $(date -d "$last" +%s)) / 3600 ))
                if [ "$age" -gt 48 ]; then fail "Letztes erfolgreiches automatisches Backup ist $age Stunden alt ($last)"
                else ok "Letztes automatisches Backup: $last"; fi
            fi
        else
            warn "Automatische Backups sind eingerichtet, aber deaktiviert"
        fi
    elif [ -d "$PTERO_DIR" ]; then
        warn "Es sind keine automatischen Backups eingerichtet (Backup-Verwaltung → Automatische Backups)"
    fi
}

# ---------------------------------------------------------------------------
# Automatische Behebung
# ---------------------------------------------------------------------------
fix_restart() { systemctl restart "$1"; }
fix_permissions() { chown -R www-data:www-data "$PTERO_DIR" && chmod 640 "$PTERO_DIR/.env"; }
fix_app_debug() { sed -i 's/^APP_DEBUG=.*/APP_DEBUG=false/' "$PTERO_DIR/.env" && (cd "$PTERO_DIR" && php artisan config:clear); }
fix_ntp() { timedatectl set-ntp true; }
fix_cron() {
    { crontab -l 2>/dev/null | grep -vF "$PTERO_DIR/artisan schedule:run"; echo "* * * * * php $PTERO_DIR/artisan schedule:run >> /dev/null 2>&1"; } | crontab -
}
fix_deploy_hook() { gd_source_lib security; gd_certbot_hook; }
fix_php_socket() {
    # Vorhandene PHP-FPM-Version (>= 8.2) verwenden, sonst PHP 8.3 installieren. Danach nginx umstellen.
    local sock ver
    sock="$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1)"
    ver="$(sed -n 's#.*/php\([0-9.]*\)-fpm.sock#\1#p' <<< "$sock")"
    if [ -z "$sock" ] || ! gd_version_ge "$ver" "8.2"; then
        gd_source_lib germandactyl; gd_source_lib security; gd_source_lib panel
        gd_php_migrate || return 1
        sock="/run/php/php${GD_PHP_VERSION}-fpm.sock"
    fi
    systemctl restart "php${ver:-$GD_PHP_VERSION}-fpm" 2>/dev/null
    local f
    for f in /etc/nginx/sites-available/*.conf /etc/nginx/snippets/germandactyl-*.conf; do
        [ -f "$f" ] && sed -i -E "s#unix:/run/php/php[0-9]+\.[0-9]+-fpm\.sock#unix:${sock}#" "$f"
    done
    nginx -t && systemctl reload nginx
}

run_fixes() {
    local items=() i sel
    for i in "${!FIX_DESC[@]}"; do items+=("$i" "${FIX_DESC[$i]}" ON); done
    sel=$(gd_whip --title "⚙ Probleme beheben" --checklist "Diese Probleme können automatisch behoben werden (Leertaste = an/aus):" 18 86 8 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
    sel="$(tr -d '"' <<< "$sel")"
    [ -z "$sel" ] && return 1
    local total done_ok=() done_fail=() n=0
    total="$(wc -w <<< "$sel")"
    gd_gauge_open "⚙ Probleme werden behoben" "Bitte warten..."
    for i in $sel; do
        n=$((n + 1))
        gd_progress $(( n * 100 / (total + 1) )) "${FIX_DESC[$i]}..."
        if eval "${FIX_CMD[$i]}" >> "$GD_LOG" 2>&1; then done_ok+=("✔ ${FIX_DESC[$i]}"); else done_fail+=("✖ ${FIX_DESC[$i]}"); fi
    done
    gd_progress 100 "Fertig."
    gd_gauge_close
    gd_msg "⚙ Ergebnis" "$(printf '%s\n' "${done_ok[@]}" "${done_fail[@]}")\n\nDie Analyse wird jetzt erneut ausgeführt, um das Ergebnis zu prüfen." 18 86
    return 0
}

# ---------------------------------------------------------------------------
# Ablauf
# ---------------------------------------------------------------------------
SPEEDTEST=false
if ! $TEXT_MODE; then
    # Beim erneuten Lauf nach einer Behebung nicht noch einmal nach dem Geschwindigkeitstest fragen
    if [ -z "${GD_ANALYSE_RERUN:-}" ] && gd_whip --title "✚ Analyse" --defaultno --yesno "Die Analyse prüft System, Updates, nginx, SSL-Zertifikate (auch die tatsächlich ausgelieferten), Dienste, Panel, Wings, DNS und Backups.\n\nSoll zusätzlich die Geschwindigkeit der Internetverbindung gemessen werden? (ca. 30 Sekunden)" 14 76; then
        SPEEDTEST=true
    fi
    gd_gauge_open "✚ Analyse läuft" "Analyse wird vorbereitet..."
fi

step 5  "System wird geprüft (Speicher, Arbeitsspeicher, Zeit)..."; check_system
step 15 "Paketlisten werden aktualisiert und Updates gezählt..."; check_updates
step 35 "nginx wird geprüft..."; check_nginx
step 45 "SSL-Zertifikate werden geprüft..."; check_certificates
step 60 "Dienste werden geprüft..."; check_services
step 70 "Panel wird geprüft..."; check_panel
step 80 "Wings wird geprüft..."; check_wings
step 88 "Netzwerk und DNS werden geprüft..."; check_network
step 94 "Backups werden geprüft..."; check_backups
if $SPEEDTEST; then
    step 96 "Geschwindigkeit wird gemessen..."
    command -v speedtest-cli >/dev/null 2>&1 || gd_apt_install speedtest-cli >> "$GD_LOG" 2>&1
    result="$(timeout 90 speedtest-cli --simple 2>/dev/null)"
    if [ -n "$result" ]; then ok "Bandbreite: ↓ $(awk '/Download/{print $2, $3}' <<< "$result")  ↑ $(awk '/Upload/{print $2, $3}' <<< "$result")"
    else warn "Bandbreitentest fehlgeschlagen (speedtest-cli)"; fi
fi
step 100 "Fertig."
$TEXT_MODE || gd_gauge_close

REPORT="$GD_LOG_DIR/analyse-$(date +%Y%m%d-%H%M%S).txt"
{
    echo "Analyse vom $(date '+%d.%m.%Y %H:%M') – ${#ERRORS[@]} Fehler, ${#WARNINGS[@]} Warnungen, ${#OKS[@]} in Ordnung"
    echo ""
    [ ${#ERRORS[@]} -gt 0 ] && printf '%s\n' "${ERRORS[@]}" && echo ""
    [ ${#WARNINGS[@]} -gt 0 ] && printf '%s\n' "${WARNINGS[@]}" && echo ""
    printf '%s\n' "${OKS[@]}"
} > "$REPORT"
chmod 600 "$REPORT"

if [ ${#FIX_DESC[@]} -gt 0 ]; then
    { echo ""; echo "Automatisch behebbar:"; printf '  • %s\n' "${FIX_DESC[@]}"; } >> "$REPORT"
fi

if $TEXT_MODE; then
    cat "$REPORT"
    if [ "${2:-}" = "--fix" ] && [ ${#FIX_DESC[@]} -gt 0 ]; then
        for i in "${!FIX_DESC[@]}"; do
            if eval "${FIX_CMD[$i]}" >> "$GD_LOG" 2>&1; then echo "✔ behoben: ${FIX_DESC[$i]}"; else echo "✖ nicht behoben: ${FIX_DESC[$i]}"; fi
        done
    fi
else
    gd_whip --title "✚ Ergebnis der Analyse" --scrolltext --textbox "$REPORT" 30 110
    if [ ${#FIX_DESC[@]} -gt 0 ] && gd_yesno "⚙ Probleme beheben?" "$( [ ${#FIX_DESC[@]} -eq 1 ] && echo "1 gefundenes Problem kann" || echo "${#FIX_DESC[@]} gefundene Probleme können") automatisch behoben werden. Möchtest du das jetzt tun?" 10 70; then
        if run_fixes; then
            GD_ANALYSE_RERUN=1 exec bash "$0" "$@"   # Analyse erneut ausführen (ohne erneute Rückfrage)
        fi
    fi
fi
[ ${#ERRORS[@]} -eq 0 ]
