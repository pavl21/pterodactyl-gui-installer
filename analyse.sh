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
# Verzeichnisse von certbot (per Umgebungsvariable überschreibbar, z. B. für Tests)
LE_DIR="${GD_LE_DIR:-/etc/letsencrypt}"
LE_LOG_DIR="${GD_LE_LOG_DIR:-/var/log/letsencrypt}"
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
    check_auto_update
}

check_auto_update() {
    # Geplante Updates von Panel und Wings (Timer germandactyl-update.timer, standardmäßig aus) und das Ergebnis des
    # letzten Laufs (setup.conf: LAST_UPDATE_* für das Panel, LAST_WINGS_UPDATE_* für Wings)
    local on=false p name res when note backup
    if systemctl cat germandactyl-update.timer >/dev/null 2>&1 && systemctl is-enabled --quiet germandactyl-update.timer 2>/dev/null; then
        on=true
        ok "Automatische Updates für Panel/Wings sind eingerichtet"
    elif systemctl cat germandactyl-update.timer >/dev/null 2>&1; then
        warn "Automatische Updates für Panel/Wings sind eingerichtet, aber deaktiviert"
    else
        ok "Automatische Updates für Panel/Wings sind aus (Standard, Verwaltung → Aktualisieren → Automatische Updates)"
    fi
    for p in "LAST_UPDATE:Panel" "LAST_WINGS_UPDATE:Wings"; do
        name="${p#*:}"
        res="$(gd_conf_get "${p%%:*}_RESULT")"
        when="$(gd_conf_get "${p%%:*}_TIME")"
        note="$(gd_conf_get "${p%%:*}_NOTE")"
        case "$res" in
            fehler)
                backup=""
                [ "$name" = "Panel" ] && backup="$(gd_conf_get LAST_UPDATE_BACKUP)"
                fail "Letztes Update ($name) ist fehlgeschlagen${when:+ ($when)}${note:+: $note} – ${backup:+Sicherung: $backup, }Log: $GD_LOG_DIR/auto-update.log" ;;
            uebersprungen)
                warn "Letztes Update ($name) wurde übersprungen${when:+ ($when)}${note:+: $note}" ;;
            ok)
                $on && ok "Letztes automatisches Update ($name): ${when:-unbekannt}${note:+ ($note)}" ;;
        esac
    done
    return 0
}

pkg_status() {
    # pkg_status <paket> <anzeigename> – installiert? aktuellste Version aus den Paketquellen?
    local installed candidate
    # Nur wirklich installierte Pakete (nicht "rc" = entfernt, Konfiguration noch vorhanden)
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = "installed" ] || return 0
    installed="$(dpkg-query -W -f='${Version}' "$1" 2>/dev/null)"
    [ -z "$installed" ] && return 0
    candidate="$(LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}')"
    if [ -n "$candidate" ] && [ "$candidate" != "(none)" ] && dpkg --compare-versions "$candidate" gt "$installed"; then
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
    if [ -d "$PTERO_DIR" ] && [ ! -e /etc/nginx/sites-enabled/pterodactyl.conf ] && [ ! -e /etc/nginx/conf.d/pterodactyl.conf ]; then
        warn "Die nginx-Seite für das Panel ist nicht aktiviert (pterodactyl.conf fehlt in sites-enabled bzw. conf.d)"
    fi
}

n_tage() { [ "$1" -eq 1 ] && echo "1 Tag" || echo "$1 Tagen"; }
tage_gueltig() { [ "$1" -eq 1 ] && echo "noch 1 Tag gültig" || echo "noch $1 Tage gültig"; }

# ---------------------------------------------------------------------------
# Hilfsfunktionen für Zertifikate, certbot und Firewall
# ---------------------------------------------------------------------------
yaml_get() {
    # yaml_get <datei> <pfad.mit.punkten> – einfacher Wert aus einer YAML-Datei (z. B. api.ssl.cert).
    # Nur verschachtelte Schlüssel, keine Listen. mawk-kompatibel (mawk kennt weder \s noch gensub).
    [ -f "$1" ] || return 0
    awk -v path="$2" '
        BEGIN { n = split(path, want, "."); q = "\047" }
        /^[[:space:]]*(#|$)/ { next }
        {
            match($0, /^[[:space:]]*/); ind = RLENGTH
            line = substr($0, ind + 1)
            if (line ~ /^-/) next
            i = index(line, ":"); if (i == 0) next
            key = substr(line, 1, i - 1); val = substr(line, i + 1)
            while (depth > 0 && indent[depth] >= ind) depth--
            depth++; indent[depth] = ind; keys[depth] = key
            if (depth != n) next
            for (j = 1; j <= n; j++) if (keys[j] != want[j]) next
            sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+#.*$/, "", val); sub(/[[:space:]]+$/, "", val)
            gsub("^[\"" q "]|[\"" q "]$", "", val)
            if (val != "") { print val; exit }
        }' "$1"
}

le_name_from_path() {
    # /etc/letsencrypt/live/<name>/fullchain.pem -> <name> (leer bei Zertifikaten, die nicht von certbot stammen)
    local r
    case "$1" in
        "$LE_DIR"/live/*/*) r="${1#"$LE_DIR"/live/}"; echo "${r%%/*}" ;;
    esac
}

valid_cert_name() {
    # Zertifikatsnamen landen in Befehlen (eval in den Behebungen) – nur harmlose Zeichen zulassen
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]
}

wings_domain() {
    # Domain, unter der Wings erreichbar ist: Einstellung, sonst Name des Zertifikats, sonst erster Name im Zertifikat
    local d cert
    d="$(gd_conf_get WINGS_FQDN)"
    if [ -n "$d" ]; then echo "$d"; return; fi
    cert="$(yaml_get "$WINGS_CONFIG" api.ssl.cert)"
    d="$(le_name_from_path "$cert")"
    if [ -n "$d" ] && gd_valid_domain "$d"; then echo "$d"; return; fi
    d=""
    [ -f "$cert" ] && d="$(openssl x509 -noout -ext subjectAltName -in "$cert" 2>/dev/null | grep -oE 'DNS:[^, ]+' | cut -d: -f2 | grep -v '^\*' | head -n1)"
    echo "${d:-localhost}"
}

load_nginx_dump() {
    # nginx -T nur einmal je Analyse ausführen (nicht in $(...) aufrufen, sonst geht der Zwischenspeicher verloren)
    [ -n "${NGINX_DUMP_LOADED:-}" ] && return 0
    NGINX_DUMP_LOADED=1
    NGINX_DUMP=""
    command -v nginx >/dev/null 2>&1 && NGINX_DUMP="$(nginx -T 2>/dev/null)"
    return 0
}

nginx_listens_80() {
    # Gibt es in der nginx-Konfiguration einen Server-Block für Port 80? (auskommentierte Zeilen zählen nicht)
    grep -vE '^[[:space:]]*#' <<< "${NGINX_DUMP:-}" | grep -Eq '(^|[[:space:]])listen[[:space:]]+([^;]*:)?80[[:space:];]'
}

cert_referenced() {
    # cert_referenced <name> – nutzt nginx, Wings oder eine andere Konfiguration in /etc dieses Zertifikat?
    grep -qF "/live/$1/" <<< "${NGINX_DUMP:-}" && return 0
    grep -rIqF --exclude-dir=letsencrypt -- "/live/$1/" "${GD_ETC_DIR:-/etc}" 2>/dev/null
}

certbot_is_snap() {
    case "$(command -v certbot 2>/dev/null)" in /snap/*) return 0 ;; esac
    [ -d /snap/certbot ]
}

rc_get() {
    # rc_get <name> <schlüssel> – Wert aus der Erneuerungskonfiguration von certbot (Kopf und [renewalparams])
    local conf="$LE_DIR/renewal/$1.conf"
    [ -f "$conf" ] || return 0
    awk -v k="$2" '
        /^[[:space:]]*\[\[/ { sec = 2; next }
        /^[[:space:]]*\[/ { sec = ($0 ~ /^[[:space:]]*\[renewalparams\]/) ? 1 : 2; next }
        /^[[:space:]]*#/ { next }
        sec != 2 {
            i = index($0, "="); if (i == 0) next
            key = substr($0, 1, i - 1); gsub(/[[:space:]]/, "", key)
            if (key != k) next
            val = substr($0, i + 1); sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
            print val; exit
        }' "$conf"
}

rc_webroots() {
    # rc_webroots <name> – alle webroot-Verzeichnisse (webroot_path und [[webroot_map]]), eines je Zeile
    local conf="$LE_DIR/renewal/$1.conf"
    [ -f "$conf" ] || return 0
    awk '
        /^[[:space:]]*\[\[webroot_map\]\]/ { sec = 3; next }
        /^[[:space:]]*\[\[/ { sec = 2; next }
        /^[[:space:]]*\[/ { sec = ($0 ~ /^[[:space:]]*\[renewalparams\]/) ? 1 : 2; next }
        /^[[:space:]]*#/ { next }
        {
            i = index($0, "="); if (i == 0) next
            key = substr($0, 1, i - 1); gsub(/[[:space:]]/, "", key); val = substr($0, i + 1)
            if (sec == 1 && key == "webroot_path") {
                n = split(val, a, ",")
                for (j = 1; j <= n; j++) { v = a[j]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); if (v != "") print v }
            } else if (sec == 3) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", val); if (val != "") print val
            }
        }' "$conf" | sort -u
}

le_uses_port80() {
    # Gibt es ein Zertifikat, dessen Erneuerung über Port 80 läuft (webroot, standalone, nginx, apache)?
    local c
    for c in "$LE_DIR"/renewal/*.conf; do
        [ -f "$c" ] || continue
        case "$(rc_get "$(basename "$c" .conf)" authenticator)" in webroot|standalone|nginx|apache) return 0 ;; esac
    done
    return 1
}

renewal_timer_active() {
    # Läuft die automatische Erneuerung? Der Timer muss tatsächlich laufen (nur "enabled" reicht nicht – das
    # Debian-Paket startet ihn nicht, wenn es unter policy-rc.d installiert wurde). Snap-Installationen haben
    # einen eigenen Timer. Ohne systemd genügt der Cronjob des Pakets.
    systemctl is-active --quiet certbot.timer 2>/dev/null \
        || systemctl is-active --quiet snap.certbot.renew.timer 2>/dev/null \
        || { [ ! -d /run/systemd/system ] && [ -f /etc/cron.d/certbot ]; }
}

renewal_timer_enabled() {
    systemctl is-enabled --quiet certbot.timer 2>/dev/null || systemctl is-enabled --quiet snap.certbot.renew.timer 2>/dev/null
}

renew_threshold_days() {
    # renew_threshold_days <datei> <name> – Restlaufzeit in Tagen, unterhalb der certbot das Zertifikat längst hätte erneuern müssen.
    # certbot erneuert, wenn noch ein Drittel der Laufzeit übrig ist (90 Tage -> 30 Tage); davon 5 Tage Puffer = 25.
    # Eine eigene Einstellung (renew_before_expiry) und kürzere Laufzeiten werden berücksichtigt.
    local file="$1" name="$2" rb s e se ee thr=25
    rb="$(rc_get "$name" renew_before_expiry)"
    if [[ "$rb" =~ ^([0-9]+)[[:space:]]*days?$ ]]; then
        thr=$(( BASH_REMATCH[1] - 5 ))
    else
        s="$(openssl x509 -noout -startdate -in "$file" 2>/dev/null | cut -d= -f2)"
        e="$(openssl x509 -noout -enddate -in "$file" 2>/dev/null | cut -d= -f2)"
        se="$(date -d "$s" +%s 2>/dev/null)"; ee="$(date -d "$e" +%s 2>/dev/null)"
        if [[ "$se" =~ ^[0-9]+$ && "$ee" =~ ^[0-9]+$ ]]; then
            thr=$(( (ee - se) / 86400 / 3 - 5 ))
            [ "$thr" -gt 25 ] && thr=25
        fi
    fi
    [ "$thr" -lt 1 ] && thr=1
    echo "$thr"
}

certbot_log_status() {
    # Wertet die letzten Erneuerungsläufe aus /var/log/letsencrypt aus. certbot rotiert das Log bei jedem Aufruf
    # (letsencrypt.log -> .1 -> .2 ...), deshalb werden alle Dateien der Reihe nach gelesen (älteste zuerst).
    # Ausgabe (tabulatorgetrennt): "R<TAB>Zeitpunkt des letzten Laufs" und je Zertifikat
    # "C<TAB>name<TAB>ok|fail<TAB>Zeitpunkt<TAB>due|renewed|dry|-<TAB>Ursache|-"
    local f files=()
    for f in "$LE_LOG_DIR"/letsencrypt.log.{9,8,7,6,5,4,3,2,1} "$LE_LOG_DIR/letsencrypt.log"; do
        [ -f "$f" ] && files+=("$f")
    done
    [ ${#files[@]} -eq 0 ] && return 0
    awk '
        function stamp(l) {
            if (l ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) return substr(l, 1, 19)
            return ""
        }
        function clean(s) {
            sub(/^[0-9-]+ [0-9:,]+:[A-Z]+:[^:]+:/, "", s)
            gsub(/\t/, " ", s); sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
            return s
        }
        function setcert(n, s, k, m) {
            if (!(n in st)) order[++cnt] = n
            st[n] = s; when[n] = last; kind[n] = k; msg[n] = m
        }
        FNR == 1 { cur = ""; detail = "" }
        {
            t = stamp($0); if (t != "") last = t
            lc = tolower($0)
            if (lc ~ /processing .*\/renewal\/[^\/ ]+\.conf/) {
                match($0, /renewal\/[^\/ ]+\.conf/)
                cur = substr($0, RSTART + 8, RLENGTH - 13)
                detail = ""; run = last
                next
            }
            if (lc ~ /failed to renew certificate|attempting to renew cert .* produced an unexpected error/) {
                n = cur
                if (match($0, /[Ff]ailed to renew certificate [^ ]+/)) {
                    n = substr($0, RSTART, RLENGTH); sub(/^[Ff]ailed to renew certificate /, "", n)
                } else if (match($0, /[Aa]ttempting to renew cert \([^)]+\)/)) {
                    n = substr($0, RSTART, RLENGTH); sub(/^[Aa]ttempting to renew cert \(/, "", n); sub(/\)$/, "", n)
                }
                m = $0
                if ((i = index(m, "with error: ")) > 0) m = substr(m, i + 12)
                else if ((i = index(m, "unexpected error: ")) > 0) m = substr(m, i + 18)
                else m = clean(m)
                sub(/\. Skipping\.?$/, "", m); gsub(/\t/, " ", m)
                if (detail != "") m = detail
                if (m == "") m = "-"
                if (n != "") setcert(n, "fail", "-", m)
                next
            }
            if (cur != "" && lc ~ /detail: |could not bind|address already in use|ratelimited|too many certificates|dns problem|nxdomain|connection refused|timeout during connect/) {
                d = $0; i = index(tolower(d), "detail: ")
                if (i > 0) d = substr(d, i + 8); else d = clean(d)
                gsub(/\t/, " ", d); detail = d
            }
            if (cur != "" && lc !~ /all (simulated )?renewals succeeded/ &&
                lc ~ /not yet due for renewal|congratulations! your certificate|successfully renewed|renewal succeeded|renewed successfully|new certificate deployed (with|without) reload/) {
                k = "renewed"
                if (lc ~ /not yet due/) k = "due"
                else if (lc ~ /without reload/) k = "dry"
                setcert(cur, "ok", k, "-")
            }
        }
        END {
            if (run != "") print "R\t" run
            for (i = 1; i <= cnt; i++) { n = order[i]; print "C\t" n "\t" st[n] "\t" when[n] "\t" kind[n] "\t" msg[n] }
        }' "${files[@]}"
}

# UFW: Gibt es eine Regel, die eingehenden Verkehr auf einen Port erlaubt?
ufw_spec_match() {
    # ufw_spec_match <angabe> <port> <proto> – passt z. B. "80,443/tcp" oder "25565:25600/udp" auf den Port?
    local spec="$1" port="$2" proto="$3" pr="" item a b
    if [[ "$spec" == */* ]]; then pr="${spec##*/}"; spec="${spec%%/*}"; fi
    [ -n "$pr" ] && [ "$pr" != "$proto" ] && return 1
    [[ "$spec" =~ ^[0-9][0-9,:]*$ ]] || return 1
    for item in ${spec//,/ }; do
        if [[ "$item" == *:* ]]; then
            a="${item%%:*}"; b="${item##*:}"
            [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] && [ "$port" -ge "$a" ] && [ "$port" -le "$b" ] && return 0
        elif [ "$item" = "$port" ]; then
            return 0
        fi
    done
    return 1
}

ufw_port_open() {
    # ufw_port_open <port> [tcp|udp] – berücksichtigt Port-, Bereichs- und Anwendungsregeln (z. B. "Nginx Full")
    local port="$1" proto="${2:-tcp}" to spec
    while IFS= read -r to; do
        [ -n "$to" ] || continue
        [ "$to" = "Anywhere" ] && return 0
        if [[ "$to" =~ ^[0-9][0-9,:]*(/(tcp|udp))?$ ]]; then
            ufw_spec_match "$to" "$port" "$proto" && return 0
        else
            for spec in $(LC_ALL=C ufw app info "$to" 2>/dev/null | awk '/^Ports:/{p=1;next} p && NF{print $1}'); do
                ufw_spec_match "$spec" "$port" "$proto" && return 0
            done
        fi
    done <<< "$(LC_ALL=C ufw status 2>/dev/null | awk '
        match($0, /[[:space:]]+(ALLOW|LIMIT)[[:space:]]/) {
            to = substr($0, 1, RSTART - 1); rest = substr($0, RSTART + RLENGTH)
            if (rest ~ /^(OUT|FWD)/) next
            sub(/[[:space:]]+\(v6\)$/, "", to); sub(/[[:space:]]+on [^[:space:]]+$/, "", to); sub(/[[:space:]]+$/, "", to)
            print to
        }')"
    return 1
}

check_cert_file() {
    # check_cert_file <datei> <bezeichnung> [domain] [unused]
    # Zertifikate unter /etc/letsencrypt/live erneuert certbot ab 30 Tagen Restlaufzeit: Bleiben nur noch wenige Tage
    # übrig, ist die automatische Erneuerung gescheitert. Zertifikate anderer Herkunft werden nur frühzeitig gemeldet.
    # "unused" = Zertifikat wird nirgends mehr verwendet: dann nur ein Hinweis statt eines Fehlers.
    local file="$1" label="$2" domain="${3:-}" mode="${4:-}" days issuer name thr when
    if [ ! -f "$file" ]; then fail "$label: Zertifikatsdatei fehlt ($file)"; return; fi
    days="$(gd_cert_days_left "$file")" || { fail "$label: Zertifikat ist nicht lesbar ($file)"; return; }
    issuer="$(openssl x509 -noout -issuer -in "$file" 2>/dev/null)"
    name="$(le_name_from_path "$file")"
    if [ -n "$name" ]; then
        thr="$(renew_threshold_days "$file" "$name")"
        if [ "$days" -lt 0 ]; then when="ist seit $(n_tage $(( -days ))) ABGELAUFEN"
        elif [ "$days" -eq 0 ]; then when="läuft heute ab"
        else when="läuft in $(n_tage "$days") ab"; fi
        if [ "$days" -ge "$thr" ]; then
            ok "$label: Zertifikat $(tage_gueltig "$days")"
        elif [ "$mode" = "unused" ]; then
            warn "$label: Zertifikat $when, wird aber nicht mehr verwendet (weder nginx noch Wings verweisen darauf) – bei Bedarf entfernen mit: certbot delete --cert-name $name"
            valid_cert_name "$name" && add_fix "Nicht mehr genutztes Zertifikat $name entfernen" "fix_certbot_delete $name"
        else
            if [ "$days" -lt 0 ]; then fail "$label: Zertifikat $when – die automatische Erneuerung schlägt offenbar fehl"
            else fail "$label: Zertifikat $when, obwohl certbot ab $((thr + 5)) Tagen erneuert – die automatische Erneuerung schlägt offenbar fehl"; fi
            add_fix "Zertifikate jetzt erneuern (certbot renew)" "fix_certbot_renew"
        fi
    else
        if [ "$days" -lt 0 ]; then fail "$label: Zertifikat ist seit $(n_tage $(( -days ))) ABGELAUFEN"
        elif [ "$days" -eq 0 ]; then warn "$label: Zertifikat läuft heute ab – wird es automatisch erneuert?"
        elif [ "$days" -lt 14 ]; then warn "$label: Zertifikat läuft in $(n_tage "$days") ab – wird es automatisch erneuert?"
        else ok "$label: Zertifikat $(tage_gueltig "$days")"; fi
    fi
    [[ "$issuer" == *STAGING* || "$issuer" == *"Fake LE"* ]] && fail "$label: Test-Zertifikat von Let's Encrypt (STAGING) – Browser vertrauen ihm nicht"
    if [ -n "$domain" ] && ! gd_cert_matches_domain "$file" "$domain"; then
        fail "$label: Zertifikat gilt nicht für $domain"
    fi
}

cert_names() {
    # Alle DNS-Namen eines Zertifikats (sortiert, kommagetrennt)
    openssl x509 -noout -ext subjectAltName -in "$1" 2>/dev/null | grep -oE 'DNS:[^, ]+' | sort | paste -sd, -
}

check_served_cert() {
    # check_served_cert <bezeichnung> <port> <domain> <datei> [adresse]
    # Vergleicht das ausgelieferte Zertifikat mit der Datei: erkennt "erneuert, aber nicht neu geladen" und den Fall,
    # dass für die Domain (SNI) ein ganz anderes Zertifikat ausgeliefert wird
    local label="$1" port="$2" domain="$3" file="$4" host="${5:-127.0.0.1}" fp_served fp_file other=false
    gd_served_cert "$host" "$port" "$domain" > "$GD_TMP/served.pem"
    if [ ! -s "$GD_TMP/served.pem" ]; then
        fail "$label: Auf Port $port wird kein Zertifikat ausgeliefert (Dienst aus oder SSL nicht eingerichtet)"
        return
    fi
    fp_served="$(openssl x509 -noout -fingerprint -sha256 -in "$GD_TMP/served.pem" 2>/dev/null)"
    fp_file="$(openssl x509 -noout -fingerprint -sha256 -in "$file" 2>/dev/null)"
    if [ -n "$fp_file" ] && [ "$fp_served" != "$fp_file" ]; then
        # Gleicher Inhaber (Subject und Namen), nur anderes Exemplar = älteres Zertifikat. Der Aussteller zählt nicht:
        # Let's Encrypt wechselt zwischen mehreren Zwischenzertifikaten.
        [ "$(openssl x509 -noout -subject -in "$GD_TMP/served.pem" 2>/dev/null)" != "$(openssl x509 -noout -subject -in "$file" 2>/dev/null)" ] && other=true
        [ "$(cert_names "$GD_TMP/served.pem")" != "$(cert_names "$file")" ] && other=true
        gd_cert_matches_domain "$GD_TMP/served.pem" "$domain" || other=true
        if $other; then
            if [ "$port" = "443" ]; then
                fail "$label: nginx liefert für $domain ein anderes Zertifikat (Server-Block fehlt oder default_server greift)"
            else
                fail "$label: Auf Port $port wird für $domain ein anderes Zertifikat ausgeliefert (läuft dort ein anderer Dienst?)"
            fi
            return
        fi
        warn "$label: Es wird noch ein älteres Zertifikat ausgeliefert (gültig bis $(openssl x509 -enddate -noout -in "$GD_TMP/served.pem" 2>/dev/null | cut -d= -f2))"
        [ "$port" = "443" ] && add_fix "nginx neu laden (neues Zertifikat ausliefern)" "fix_restart nginx"
        [ "$port" != "443" ] && add_fix "Wings neu starten (neues Zertifikat ausliefern)" "fix_restart wings"
    fi
    # Vollständige Prüfung wie ein Browser (Kette, Domain, Gültigkeit)
    local rc
    curl -s --noproxy '*' -o /dev/null --max-time 10 --resolve "${domain}:${port}:${host}" "https://${domain}:${port}/" 2>/dev/null
    rc=$?
    case $rc in
        0|22) ok "$label: Zertifikat wird von Browsern als gültig anerkannt (https://${domain}:${port})" ;;
        60) fail "$label: Browser würden das Zertifikat ablehnen (Kette unvollständig, falsche Domain oder abgelaufen)" ;;
        7|28) fail "$label: Port $port ist nicht erreichbar" ;;
        *) warn "$label: TLS-Prüfung ergab Fehlercode $rc" ;;
    esac
}

check_renewal_conf() {
    # check_renewal_conf <zertifikatsname> <bezeichnung> – kann certbot dieses Zertifikat tatsächlich erneuern?
    # Liest /etc/letsencrypt/renewal/<name>.conf und prüft, ob die dort eingetragene Methode auf diesem Server funktioniert.
    local name="$1" label="$2" conf auth web bad="" root roots
    conf="$LE_DIR/renewal/$name.conf"
    if [ ! -f "$conf" ]; then
        fail "$label: keine Erneuerungskonfiguration (certbot kennt das Zertifikat nicht) – wird nicht erneuert"
        return 1
    fi
    auth="$(rc_get "$name" authenticator)"
    case "$auth" in
        standalone)
            web=""
            if systemctl is-active --quiet nginx 2>/dev/null; then web="nginx"
            elif systemctl is-active --quiet apache2 2>/dev/null; then web="Apache"; fi
            # Mit einem pre_hook (z. B. Webserver kurz anhalten) funktioniert standalone trotzdem
            if [ -n "$web" ] && [ -z "$(rc_get "$name" pre_hook)" ]; then
                fail "$label: Erneuerung im standalone-Modus scheitert, weil Port 80 von $web belegt ist"
                [ "$web" = "nginx" ] && valid_cert_name "$name" && add_fix "Erneuerung auf nginx/webroot umstellen ($name)" "fix_certbot_authenticator $name"
            else
                ok "$label: Erneuerung im standalone-Modus (Port 80 ist frei)"
            fi ;;
        webroot)
            roots="$(rc_webroots "$name")"
            while IFS= read -r root; do
                [ -n "$root" ] && [ ! -d "$root" ] && bad+="${bad:+, }$root"
            done <<< "$roots"
            if [ -z "$roots" ]; then
                fail "$label: In der Erneuerungskonfiguration fehlt das webroot-Verzeichnis – die Erneuerung scheitert"
            elif [ -n "$bad" ]; then
                fail "$label: $( [[ "$bad" == *,* ]] && echo "Die webroot-Verzeichnisse $bad existieren nicht" || echo "Das webroot-Verzeichnis $bad existiert nicht") – die Erneuerung scheitert"
            elif [ -n "${NGINX_DUMP:-}" ] && ! nginx_listens_80; then
                fail "$label: nginx hat keinen Server-Block für Port 80 – die Domain-Prüfung (webroot) kann nicht gelingen"
            else
                ok "$label: Erneuerung per webroot eingerichtet ($(tr '\n' ' ' <<< "$roots" | sed 's/ $//'))"
            fi ;;
        dns-cloudflare)
            root="$(rc_get "$name" dns_cloudflare_credentials)"
            [ -z "$root" ] && root="$LE_DIR/cloudflare.ini"
            if [ ! -f "$root" ]; then
                fail "$label: Die Cloudflare-Zugangsdaten $root fehlen – die Erneuerung per DNS scheitert"
            elif [ "$(stat -c %a "$root" 2>/dev/null)" != "600" ]; then
                warn "$label: $root hat die Rechte $(stat -c %a "$root" 2>/dev/null) statt 600 (Token sollte nur für root lesbar sein: chmod 600 $root)"
            else
                ok "$label: Erneuerung per DNS-Challenge (Cloudflare), Zugangsdaten vorhanden"
            fi ;;
        nginx)
            if ! systemctl is-active --quiet nginx 2>/dev/null; then
                fail "$label: Erneuerung über das nginx-Plugin ist nicht möglich, weil nginx nicht läuft"
            elif ! certbot_is_snap && [ "$(dpkg-query -W -f='${db:Status-Status}' python3-certbot-nginx 2>/dev/null)" != "installed" ]; then
                fail "$label: Das Paket python3-certbot-nginx fehlt – die Erneuerung über das nginx-Plugin scheitert"
            else
                ok "$label: Erneuerung über das nginx-Plugin"
            fi ;;
        apache)
            if ! systemctl is-active --quiet apache2 2>/dev/null; then
                fail "$label: Erneuerung über das Apache-Plugin ist nicht möglich, weil Apache nicht läuft"
            elif ! certbot_is_snap && [ "$(dpkg-query -W -f='${db:Status-Status}' python3-certbot-apache 2>/dev/null)" != "installed" ]; then
                fail "$label: Das Paket python3-certbot-apache fehlt – die Erneuerung über das Apache-Plugin scheitert"
            else
                ok "$label: Erneuerung über das Apache-Plugin"
            fi ;;
        manual)
            if [ -n "$(rc_get "$name" manual_auth_hook)" ]; then ok "$label: Erneuerung über eigenen Hook (manual)"
            else warn "$label: Das Zertifikat wurde im manuellen Modus ausgestellt – certbot kann es nicht selbstständig erneuern"; fi ;;
        "")
            warn "$label: In der Erneuerungskonfiguration ist keine Methode (authenticator) eingetragen" ;;
        *)
            ok "$label: Erneuerung über das Plugin $auth" ;;
    esac
    return 0
}

check_last_renewal() {
    # check_last_renewal <name> <bezeichnung> <zertifikatsdatei> – Ergebnis des letzten certbot-Laufs für dieses Zertifikat
    local line st when kind msg ep mt shown
    line="$(awk -F'\t' -v n="$1" '$1 == "C" && $2 == n { print; exit }' <<< "${LOG_STATUS:-}")"
    [ -n "$line" ] || return 0
    IFS=$'\t' read -r _ _ st when kind msg <<< "$line"
    ep="$(date -d "$when" +%s 2>/dev/null)"
    shown="$(date -d "$when" '+%d.%m.%Y %H:%M' 2>/dev/null)"; [ -z "$shown" ] && shown="$when"
    case "$st" in
        fail)
            # Wurde das Zertifikat nach dem Fehlschlag trotzdem erneuert (z. B. von Hand), ist der Eintrag überholt
            mt="$(stat -L -c %Y "$3" 2>/dev/null)"
            if [ -n "$ep" ] && [[ "$mt" =~ ^[0-9]+$ ]] && [ "$mt" -ge "$ep" ]; then return 0; fi
            [ "$msg" = "-" ] && msg="Ursache siehe $LE_LOG_DIR/letsencrypt.log"
            fail "$2: letzte Erneuerung am $shown fehlgeschlagen – $(cut -c1-110 <<< "$msg")" ;;
        ok)
            case "$kind" in
                due) ok "$2: letzte Erneuerungsprüfung am $shown ohne Fehler (noch nicht fällig)" ;;
                dry) ok "$2: letzter Testlauf (Dry-Run) am $shown erfolgreich" ;;
                *)   ok "$2: zuletzt am $shown erfolgreich erneuert" ;;
            esac ;;
    esac
}

check_certificates() {
    local renew=false files f name wcert wdomain wport whost seen=" " last_run ep age found=false
    load_nginx_dump
    LOG_STATUS="$(certbot_log_status)"
    renewal_timer_active && renew=true

    if [ -n "$PANEL_DOMAIN" ] && [ -d "$PTERO_DIR" ]; then
        f="$(awk -v d="$PANEL_DOMAIN" '$1=="server_name" && index($0, d) {s=1} s && $1=="ssl_certificate" {gsub(";","",$2); print $2; exit}' <<< "${NGINX_DUMP:-}")"
        [ -z "$f" ] && f="$LE_DIR/live/$PANEL_DOMAIN/fullchain.pem"
        check_cert_file "$f" "Panel ($PANEL_DOMAIN)" "$PANEL_DOMAIN"
        name="$(le_name_from_path "$f")"
        if [ -n "$name" ]; then
            seen+="$name "
            check_renewal_conf "$name" "Panel ($PANEL_DOMAIN)" && check_last_renewal "$name" "Panel ($PANEL_DOMAIN)" "$f"
        fi
        systemctl is-active --quiet nginx && check_served_cert "Panel" 443 "$PANEL_DOMAIN" "$f"
    fi

    # Wings: gezielt api.ssl auslesen
    if [ -f "$WINGS_CONFIG" ] && [ "$(yaml_get "$WINGS_CONFIG" api.ssl.enabled)" = "true" ]; then
        wcert="$(yaml_get "$WINGS_CONFIG" api.ssl.cert)"
        wport="$(yaml_get "$WINGS_CONFIG" api.port)"
        whost="$(yaml_get "$WINGS_CONFIG" api.host)"
        wdomain="$(wings_domain)"
        check_cert_file "$wcert" "Wings ($wdomain)" "$wdomain"
        name="$(le_name_from_path "$wcert")"
        if [ -n "$name" ] && [[ "$seen" != *" $name "* ]]; then
            seen+="$name "
            check_renewal_conf "$name" "Wings ($wdomain)" && check_last_renewal "$name" "Wings ($wdomain)" "$wcert"
        fi
        [[ "$whost" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$whost" != "0.0.0.0" ]] || whost="127.0.0.1"
        systemctl is-active --quiet wings && check_served_cert "Wings" "${wport:-8080}" "$wdomain" "$wcert" "$whost"
    fi

    # Weitere Let's-Encrypt-Zertifikate auf dem Server (nur echte Zertifikate, nicht die README im Ordner live)
    for files in "$LE_DIR"/live/*/fullchain.pem; do
        [ -f "$files" ] || continue
        found=true
        f="$(basename "$(dirname "$files")")"
        [[ "$seen" == *" $f "* ]] && continue
        seen+="$f "
        if cert_referenced "$f"; then
            check_cert_file "$files" "Zertifikat $f"
            check_renewal_conf "$f" "Zertifikat $f" && check_last_renewal "$f" "Zertifikat $f" "$files"
        else
            check_cert_file "$files" "Zertifikat $f" "" unused
        fi
    done

    # Automatische Erneuerung: läuft der Timer, und ist certbot tatsächlich in letzter Zeit gelaufen?
    if $found; then
        if $renew; then
            ok "Automatische Zertifikatserneuerung ist aktiv"
            last_run="$(awk -F'\t' '$1 == "R" { print $2; exit }' <<< "${LOG_STATUS:-}")"
            ep="$(date -d "$last_run" +%s 2>/dev/null)"
            if [ -n "$last_run" ] && [[ "$ep" =~ ^[0-9]+$ ]] && [ $(( $(date +%s) - ep )) -gt 259200 ]; then
                age=$(( ($(date +%s) - ep) / 86400 ))
                warn "certbot ist seit $age Tagen nicht gelaufen (letzter Lauf laut Log: $(date -d "$last_run" '+%d.%m.%Y %H:%M')) – der Timer ist aktiv, erneuert aber offenbar nicht (systemctl status certbot.service)"
            fi
        elif renewal_timer_enabled; then
            fail "Die automatische Zertifikatserneuerung (certbot.timer) ist eingerichtet, aber nicht gestartet – Zertifikate laufen nach 90 Tagen ab"
            add_fix "Automatische Zertifikatserneuerung starten" "fix_certbot_timer"
        else
            fail "Keine automatische Zertifikatserneuerung gefunden (certbot.timer) – Zertifikate laufen nach 90 Tagen ab"
            add_fix "Automatische Zertifikatserneuerung starten" "fix_certbot_timer"
        fi
        if { [ -f "$WINGS_CONFIG" ] || [ -d "$PTERO_DIR" ]; } && [ ! -x "$LE_DIR/renewal-hooks/deploy/germandactyl.sh" ]; then
            warn "Nach einer Zertifikatserneuerung werden nginx bzw. Wings nicht automatisch neu geladen"; add_fix "Deploy-Hook für Zertifikatserneuerung anlegen" "fix_deploy_hook"
        elif [ -x "$LE_DIR/renewal-hooks/deploy/germandactyl.sh" ] && ! grep -q 'nginx -t' "$LE_DIR/renewal-hooks/deploy/germandactyl.sh"; then
            warn "Der Deploy-Hook für die Zertifikatserneuerung ist veraltet (nginx wird ohne vorherige Konfigurationsprüfung neu geladen)"; add_fix "Deploy-Hook für Zertifikatserneuerung anlegen" "fix_deploy_hook"
        fi
    fi
}

check_services() {
    local svc php_fpm
    # PHP-Version, die das Panel tatsächlich nutzt (aus der nginx-Konfiguration), sonst die neueste
    php_fpm="$(grep -ohE 'php[0-9]+\.[0-9]+-fpm' /etc/nginx/sites-available/pterodactyl.conf 2>/dev/null | head -n1)"
    [ -z "$php_fpm" ] && php_fpm="$(systemctl list-units --type=service --all 'php*-fpm.service' --no-legend --plain 2>/dev/null | awk '{print $1}' | grep '\.service$' | sed 's/\.service$//' | sort -V | tail -n1)"
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
    else warn "Pterodactyl Panel v$installed installiert, v$latest verfügbar (Verwaltung → Aktualisieren → Panel aktualisieren)"; fi

    php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"
    if [ -z "$php_version" ]; then fail "PHP ist nicht installiert"
    elif gd_version_ge "$php_version" "8.2"; then ok "PHP $php_version"
    else fail "PHP $php_version ist zu alt (benötigt 8.2 oder 8.3) – Verwaltung → Aktualisieren → Panel aktualisieren stellt um"; fi

    if [ "$(panel_env APP_DEBUG)" = "true" ]; then fail "APP_DEBUG=true in der .env – Fehlermeldungen verraten interne Daten"; add_fix "APP_DEBUG auf false setzen" "fix_app_debug"; fi
    [ "$(panel_env APP_ENV)" != "production" ] && warn "APP_ENV ist nicht 'production'"
    if [ "$(stat -c %U "$PTERO_DIR/storage")" = "www-data" ] && [ "$(stat -c %U "$PTERO_DIR/bootstrap/cache")" = "www-data" ]; then
        ok "Verzeichnisrechte des Panels sind korrekt"
    else
        fail "Verzeichnisrechte falsch (chown -R www-data:www-data $PTERO_DIR)"; add_fix "Verzeichnisrechte des Panels korrigieren" "fix_permissions"
    fi
    local perm
    perm="$(stat -c %a "$PTERO_DIR/.env" 2>/dev/null)"
    # Oktal auswerten: Schreibrecht für die Gruppe oder irgendein Recht für andere ist zu viel
    if [ -n "$perm" ] && (( 8#$perm & 8#027 )); then warn ".env ist für andere Benutzer lesbar"; add_fix "Zugriffsrechte der .env einschränken" "fix_permissions"; fi
    cron_has_schedule && ok "Cronjob des Panels ist eingerichtet" \
        || { fail "Cronjob des Panels fehlt – Zeitpläne und Aufräumarbeiten laufen nicht"; add_fix "Cronjob des Panels einrichten" "fix_cron"; }

    if [ -n "$PANEL_DOMAIN" ]; then
        code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${PANEL_DOMAIN}:443:127.0.0.1" "https://${PANEL_DOMAIN}/auth/login")"
        case "$code" in
            200|302) ok "Panel antwortet (https://${PANEL_DOMAIN})" ;;
            502) fail "Panel antwortet mit 502 Bad Gateway – PHP-FPM läuft nicht oder nginx nutzt einen falschen PHP-Socket"; add_fix "PHP-Socket in nginx korrigieren (Ursache für 502)" "fix_php_socket" ;;
            500) fail "Panel antwortet mit 500 – Fehler im Panel (storage/logs prüfen, Hilfe & Analyse → Das Panel ist fehlerhaft)" ;;
            000) fail "Panel ist lokal nicht erreichbar (nginx/SSL prüfen)" ;;
            *) warn "Panel antwortet mit HTTP $code" ;;
        esac
    fi
}

check_wings() {
    [ -x /usr/local/bin/wings ] || return
    local installed latest token port domain code scheme host target
    installed="$(/usr/local/bin/wings version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    latest="$(gd_latest_release pterodactyl/wings)"
    if [ -z "$latest" ]; then warn "Wings v$installed – die neueste Version konnte nicht abgefragt werden"
    elif [ "$installed" = "$latest" ] || gd_version_ge "$installed" "$latest"; then ok "Wings v$installed ist aktuell"
    else warn "Wings v$installed installiert, v$latest verfügbar (Verwaltung → Aktualisieren → Wings aktualisieren)"; fi
    [ -f "$WINGS_CONFIG" ] || { fail "Wings ist nicht konfiguriert ($WINGS_CONFIG fehlt)"; return; }
    token="$(awk '$1=="token:"{print $2; exit}' "$WINGS_CONFIG" | tr -d "'\"")"
    port="$(yaml_get "$WINGS_CONFIG" api.port)"; port="${port:-8080}"
    # Domain wie bei der Zertifikatsprüfung ermitteln (Einstellung, sonst aus dem Zertifikat der config.yml)
    domain="$(wings_domain)"
    # Ohne SSL antwortet die API per http; ist eine bestimmte Adresse eingetragen, lauscht Wings nur dort
    scheme="https"; [ "$(yaml_get "$WINGS_CONFIG" api.ssl.enabled)" = "false" ] && scheme="http"
    host="$(yaml_get "$WINGS_CONFIG" api.host)"
    target="127.0.0.1"
    [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$host" != "0.0.0.0" ]] && target="$host"
    code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${domain}:${port}:${target}" -H "Authorization: Bearer ${token}" "${scheme}://${domain}:${port}/api/system")"
    case "$code" in
        200) ok "Wings-API antwortet (Verbindung zum Panel möglich)" ;;
        401|403) fail "Wings-API lehnt den Token ab – config.yml passt nicht zur Node im Panel" ;;
        000) fail "Wings-API ist nicht erreichbar (Dienst, Port ${port}$( [ "$scheme" = "https" ] && echo ' oder Zertifikat'))" ;;
        *) warn "Wings-API antwortet mit HTTP $code" ;;
    esac
}

check_domain() {
    # check_domain <domain> <bezeichnung> – A-Eintrag (auch Zusatz-IPs), Cloudflare-Proxy und AAAA-Eintrag prüfen
    local domain="$1" label="$2" dns_ips first ip match="" aaaa own6 a6 ok6=false cf=false
    dns_ips="$(gd_resolve_a "$domain")"
    if [ -z "$dns_ips" ]; then
        fail "$label: Die Domain $domain hat keinen A-Eintrag"
    else
        first="$(head -n1 <<< "$dns_ips")"
        for ip in $DNS_SERVER_IP $(gd_local_ips); do
            grep -qxF "$ip" <<< "$dns_ips" && { match="$ip"; break; }
        done
        if [ -n "$match" ]; then ok "$label: Die Domain $domain zeigt auf diesen Server ($match)"
        elif gd_is_cloudflare_ip "$first"; then cf=true; warn "$label: Die Domain $domain läuft über den Cloudflare-Proxy – für Wings und Zertifikate 'DNS only' verwenden"
        else fail "$label: Die Domain $domain zeigt auf $first, dieser Server hat ${DNS_SERVER_IP:-eine andere Adresse}"; fi
    fi
    # Let's Encrypt bevorzugt IPv6: Ein AAAA-Eintrag, der nicht zu diesem Server gehört, lässt die Erneuerung scheitern
    aaaa="$(gd_resolve_aaaa "$domain")"
    if [ -n "$aaaa" ] && ! $cf; then
        own6="$(gd_local_ips6)"
        for a6 in $aaaa; do grep -qixF "$a6" <<< "$own6" && ok6=true; done
        $ok6 || fail "$label ($domain): IPv6-Eintrag (AAAA) zeigt nicht auf diesen Server – Let's Encrypt prüft bevorzugt über IPv6, die Erneuerung scheitert"
    fi
}

check_network() {
    if getent hosts github.com >/dev/null 2>&1; then ok "DNS-Auflösung funktioniert"; else fail "DNS-Auflösung funktioniert nicht (github.com)"; fi
    local wd
    DNS_SERVER_IP="$(gd_public_ip)"
    [ -n "$PANEL_DOMAIN" ] && check_domain "$PANEL_DOMAIN" "Panel"
    if [ -x /usr/local/bin/wings ] && [ -f "$WINGS_CONFIG" ] && [ "$(yaml_get "$WINGS_CONFIG" api.ssl.enabled)" = "true" ]; then
        wd="$(wings_domain)"
        [ "$wd" != "localhost" ] && [ "$wd" != "$PANEL_DOMAIN" ] && check_domain "$wd" "Wings"
    fi
    check_firewall
}

check_firewall() {
    # Ports, die für Wings und die Zertifikatserneuerung offen sein müssen (nur bei aktiver UFW)
    gd_ufw_active || return 0
    ok "Firewall (UFW) ist aktiv"
    local entries=() e port what
    if [ -x /usr/local/bin/wings ] && [ -f "$WINGS_CONFIG" ]; then
        port="$(yaml_get "$WINGS_CONFIG" api.port)"; entries+=("${port:-8080}|Wings-API")
        port="$(yaml_get "$WINGS_CONFIG" system.sftp.bind_port)"; entries+=("${port:-2022}|Wings-SFTP")
    fi
    le_uses_port80 && entries+=("80|Let's Encrypt, Zertifikatserneuerung")
    for e in "${entries[@]}"; do
        port="${e%%|*}"; what="${e#*|}"
        [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || continue
        if ! ufw_port_open "$port" tcp; then
            warn "Die Firewall gibt Port $port/tcp ($what) nicht frei"
            add_fix "Port $port in der Firewall öffnen" "fix_ufw_allow $port"
        fi
    done
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
        warn "Es sind keine automatischen Backups eingerichtet (Backups → Automatische Backups)"
    fi
}

# ---------------------------------------------------------------------------
# Automatische Behebung
# ---------------------------------------------------------------------------
fix_restart() { systemctl restart "$1"; }
fix_permissions() { chown -R www-data:www-data "$PTERO_DIR" && chmod 640 "$PTERO_DIR/.env"; }
fix_app_debug() { sed -i 's/^APP_DEBUG=.*/APP_DEBUG=false/' "$PTERO_DIR/.env" && (cd "$PTERO_DIR" && php artisan config:clear); }
fix_ntp() { timedatectl set-ntp true; }
cron_has_schedule() {
    # Cronjob in root- oder www-data-Crontab, /etc/crontab oder /etc/cron.d (auskommentierte Zeilen zählen nicht)
    { crontab -l 2>/dev/null; crontab -u www-data -l 2>/dev/null; cat /etc/crontab /etc/cron.d/* 2>/dev/null; } \
        | grep -vE '^[[:space:]]*#' | grep -qF "$PTERO_DIR/artisan schedule:run"
}
fix_cron() {
    # Als Benutzer www-data anlegen (gd_panel_cron migriert auch einen alten root-Eintrag)
    cron_has_schedule && return 0
    gd_source_lib panel
    gd_panel_cron
}
fix_deploy_hook() { gd_source_lib security; gd_certbot_hook; }
fix_certbot_timer() {
    command -v certbot >/dev/null 2>&1 || gd_apt_install certbot
    if systemctl cat certbot.timer >/dev/null 2>&1; then systemctl enable --now certbot.timer
    elif systemctl cat snap.certbot.renew.timer >/dev/null 2>&1; then systemctl enable --now snap.certbot.renew.timer
    else systemctl enable --now certbot.timer; fi
}
fix_certbot_renew() { certbot renew --non-interactive; }
fix_ufw_allow() {
    # Nur reine Portnummern zulassen (der Wert landet in einem eval)
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || { echo "Ungültiger Port: $1"; return 1; }
    ufw allow "$1/tcp"
}
fix_certbot_delete() {
    valid_cert_name "$1" || { echo "Ungültiger Zertifikatsname: $1"; return 1; }
    # Sicherheitsnetz: Zertifikate, auf die irgendeine Konfiguration noch verweist (z. B. Apache, Mailserver), bleiben
    if cert_referenced "$1"; then
        echo "Das Zertifikat $1 wird noch in einer Konfiguration unter /etc verwendet und bleibt deshalb erhalten."
        return 1
    fi
    certbot delete --cert-name "$1" --non-interactive
}
fix_certbot_authenticator() {
    # Zertifikat auf das nginx-Plugin umstellen (certbot reconfigure gibt es ab certbot 2.3)
    local ver
    valid_cert_name "$1" || { echo "Ungültiger Zertifikatsname: $1"; return 1; }
    ver="$(certbot --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
    if [ -z "$ver" ] || ! gd_version_ge "$ver" "2.3"; then
        echo "Hinweis: certbot ${ver:-unbekannt} kennt 'certbot reconfigure' noch nicht (ab 2.3). Aktualisiere certbot oder stelle $1 von Hand auf das nginx-Plugin um."
        return 1
    fi
    if ! certbot_is_snap && [ "$(dpkg-query -W -f='${db:Status-Status}' python3-certbot-nginx 2>/dev/null)" != "installed" ]; then
        echo "Hinweis: Das Paket python3-certbot-nginx ist nicht installiert (apt install python3-certbot-nginx), danach erneut beheben."
        return 1
    fi
    certbot reconfigure --cert-name "$1" --nginx --non-interactive
}
fix_php_socket() {
    # Vorhandene PHP-FPM-Version (>= 8.2) verwenden, sonst PHP 8.3 installieren. Danach nginx umstellen.
    local sock ver
    sock="$(ls -1 /run/php/php[0-9]*-fpm.sock 2>/dev/null | sort -V | tail -n1)"
    ver="$(sed -n 's#.*/php\([0-9.]*\)-fpm.sock#\1#p' <<< "$sock")"
    if [ -z "$sock" ] || ! gd_version_ge "$ver" "8.2"; then
        gd_source_lib germandactyl; gd_source_lib security; gd_source_lib panel
        gd_php_migrate || return 1
        sock="/run/php/php${GD_PHP_VERSION}-fpm.sock"
    fi
    systemctl restart "php${ver:-$GD_PHP_VERSION}-fpm" 2>/dev/null
    local f
    # Nur die Konfiguration des Panels anpassen – fremde Seiten nutzen ggf. bewusst eine andere PHP-Version
    for f in /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/snippets/germandactyl-*.conf; do
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
    echo "Analyse vom $(date '+%d.%m.%Y %H:%M') – ${#ERRORS[@]} Fehler, ${#WARNINGS[@]} $([ ${#WARNINGS[@]} -eq 1 ] && echo Warnung || echo Warnungen), ${#OKS[@]} in Ordnung"
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
