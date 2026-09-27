#!/bin/bash
# Pfad: certbot-renew-verwaltung.sh
# SSL-Zertifikate prüfen und erneuern. Webserver laufen dabei weiter; nach einer Erneuerung
# werden nginx und Wings über den Deploy-Hook automatisch neu geladen.

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
gd_source_lib security

if ! command -v certbot >/dev/null 2>&1; then
    gd_msg "Certbot fehlt" "Certbot ist auf diesem Server nicht installiert, es gibt also keine Let's-Encrypt-Zertifikate zu erneuern." 9 70
    exit 0
fi

# Deploy-Hook sicherstellen (ältere Installationen hatten keinen)
gd_certbot_hook

gd_msg "🔓 Zertifikate erneuern" "Es werden alle Zertifikate geprüft und erneuert, die in den nächsten 30 Tagen ablaufen. Die Webseiten bleiben dabei erreichbar." 10 70

clear
echo "Zertifikate werden geprüft und bei Bedarf erneuert..."
renew_output="$(certbot renew --non-interactive 2>&1)"
echo "$renew_output" >> "$GD_LOG"

text=""
if grep -q "failed" <<< "$renew_output"; then
    title="⚠️ Probleme bei der Erneuerung"
    text="Mindestens ein Zertifikat konnte nicht erneuert werden:\n\n"
    while IFS= read -r line; do
        domain="$(grep -oE '/etc/letsencrypt/live/[^/]+' <<< "$line" | cut -d/ -f5)"
        [ -z "$domain" ] && continue
        text+="⚠ ${domain}\n"
    done <<< "$(grep -iE 'fail' <<< "$renew_output")"
    if grep -qiE "Could not bind|Address already in use" <<< "$renew_output"; then
        text+="\nUrsache: Port 80 wird blockiert. Ein Zertifikat wurde im 'standalone'-Modus erstellt, während jetzt ein Webserver läuft."
    fi
    if grep -qiE "rateLimited|too many" <<< "$renew_output"; then
        text+="\nUrsache: Das Limit von Let's Encrypt wurde erreicht. Warte einige Stunden und versuche es erneut."
    fi
    if grep -qiE "DNS problem|NXDOMAIN|unauthorized" <<< "$renew_output"; then
        text+="\nUrsache: Die Domain zeigt nicht (mehr) auf diesen Server oder ist über einen Proxy (z. B. Cloudflare) geschaltet."
    fi
    text+="\n\nDas vollständige Protokoll findest du hier: $GD_LOG"
else
    title="✅ Erneuerung abgeschlossen"
    text="Alle Zertifikate wurden geprüft und bei Bedarf erneuert. Es wurden keine Probleme festgestellt.\n\n"
fi

# Übersicht der Restlaufzeiten
overview="$(certbot certificates 2>/dev/null | awk '/Certificate Name:/{n=$3} /Expiry Date:/{sub(/.*\(VALID: /,""); sub(/\)/,""); print "• " n ": noch " $0}' | sed 's/ days/ Tage/')"
[ -n "$overview" ] && text+="\nRestlaufzeiten:\n${overview}"

whiptail --title "$title" --msgbox "$text" 22 84
