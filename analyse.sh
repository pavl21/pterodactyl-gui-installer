#!/bin/bash
# Pfad: analyse.sh
# Allgemeine Analyse des Servers und der Pterodactyl-Installation.

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

ok()   { RESULT+="✔ $1\n"; }
warn() { RESULT+="⚠ $1\n"; }
RESULT=""

SPEEDTEST=false
if whiptail --title "🔍 Analyse" --defaultno --yesno "Die Analyse prüft Speicherplatz, Updates, Dienste, Versionen, Berechtigungen und Zertifikate.\n\nSoll zusätzlich ein Geschwindigkeitstest der Internetverbindung durchgeführt werden? (dauert ca. 30 Sekunden, nutzt speedtest-cli)" 13 74; then
    SPEEDTEST=true
fi

clear
echo "Analyse läuft, bitte warten..."

# Speicherplatz
usage="$(df -P / | awk 'NR==2{print $5}' | tr -d '%')"
free_space="$(df -h / | awk 'NR==2{print $4}')"
if [ "$usage" -lt 80 ]; then ok "Speicherplatz: ${usage} % belegt, ${free_space} frei"; else warn "Speicherplatz: ${usage} % belegt, nur noch ${free_space} frei"; fi

# Arbeitsspeicher
mem_avail="$(free -m | awk '/^Mem:/{print $7}')"
if [ "${mem_avail:-0}" -gt 300 ]; then ok "Arbeitsspeicher: ${mem_avail} MB verfügbar"; else warn "Arbeitsspeicher: nur ${mem_avail} MB verfügbar"; fi

# Updates
apt-get update -qq >> "$GD_LOG" 2>&1
update_count="$(apt list --upgradable 2>/dev/null | grep -vcE '^(Listing|Auflistung)')"
if [ "$update_count" -gt 0 ]; then warn "Offene Updates: $update_count Pakete (apt upgrade)"; else ok "Offene Updates: System ist aktuell"; fi

# DNS
if getent hosts github.com >/dev/null 2>&1; then ok "DNS-Auflösung funktioniert"; else warn "DNS-Auflösung fehlgeschlagen (github.com nicht auflösbar)"; fi

# Dienste
for svc in nginx mariadb redis-server pteroq wings docker; do
    systemctl cat "${svc}.service" >/dev/null 2>&1 || continue
    if systemctl is-active --quiet "$svc"; then ok "Dienst $svc läuft"; else warn "Dienst $svc läuft NICHT (systemctl status $svc)"; fi
done

# nginx-Konfiguration
if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then ok "nginx-Konfiguration ist fehlerfrei"; else warn "nginx-Konfiguration fehlerhaft (nginx -t)"; fi
fi

# PHP
php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"
if [ -n "$php_version" ]; then
    if gd_version_ge "$php_version" "8.2"; then ok "PHP-Version: $php_version"; else warn "PHP-Version: $php_version ist veraltet (benötigt 8.2 oder 8.3) – Panel aktualisieren"; fi
fi

# Panel-Version
if [ -f "$PTERO_DIR/config/app.php" ]; then
    installed="$(grep "'version' =>" "$PTERO_DIR/config/app.php" | cut -d\' -f4)"
    latest="$(gd_latest_release pterodactyl/panel)"
    if [ -n "$latest" ] && [ "$installed" != "$latest" ]; then
        warn "Pterodactyl Panel: v$installed installiert, v$latest verfügbar"
    else
        ok "Pterodactyl Panel: v$installed ist aktuell"
    fi
    if [ "$(stat -c %U "$PTERO_DIR/storage")" = "www-data" ] && [ "$(stat -c %U "$PTERO_DIR/bootstrap/cache")" = "www-data" ]; then
        ok "Verzeichnisrechte des Panels sind korrekt"
    else
        warn "Verzeichnisrechte des Panels sind nicht korrekt (chown -R www-data:www-data $PTERO_DIR)"
    fi
fi

# Wings-Version
if [ -x /usr/local/bin/wings ]; then
    installed="$(/usr/local/bin/wings --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    latest="$(gd_latest_release pterodactyl/wings)"
    if [ -n "$latest" ] && [ "$installed" != "$latest" ]; then
        warn "Wings: v$installed installiert, v$latest verfügbar"
    else
        ok "Wings: v$installed ist aktuell"
    fi
fi

# Zertifikate
if command -v certbot >/dev/null 2>&1; then
    while read -r name days; do
        [ -z "$name" ] && continue
        if [ "$days" -lt 14 ]; then warn "Zertifikat $name: nur noch $days Tage gültig"; else ok "Zertifikat $name: noch $days Tage gültig"; fi
    done <<< "$(certbot certificates 2>/dev/null | awk '/Certificate Name:/{n=$3} /VALID: [0-9]+ day/{match($0,/VALID: [0-9]+/); print n, substr($0,RSTART+7,RLENGTH-7)}')"
    certbot certificates 2>/dev/null | grep -q "INVALID" && warn "Mindestens ein Zertifikat ist abgelaufen oder ungültig"
fi

# Geschwindigkeitstest (optional)
if $SPEEDTEST; then
    command -v speedtest-cli >/dev/null 2>&1 || gd_apt_install speedtest-cli >> "$GD_LOG" 2>&1
    result="$(speedtest-cli --simple 2>/dev/null)"
    if [ -n "$result" ]; then
        ok "Bandbreite: ↓ $(awk '/Download/{print $2, $3}' <<< "$result")  ↑ $(awk '/Upload/{print $2, $3}' <<< "$result")"
    else
        warn "Bandbreitentest fehlgeschlagen (speedtest-cli)"
    fi
fi

whiptail --title "🔍 Ergebnis der Analyse" --scrolltext --msgbox "$RESULT" 24 90
