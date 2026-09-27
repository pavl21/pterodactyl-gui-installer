#!/bin/bash
# Pfad: pelican-installer.sh
# Pelican Panel (Beta) + optional Wings installieren bzw. aktualisieren.

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
gd_source_lib panel
gd_source_lib wings
gd_source_lib pelican
gd_source_lib backup
gd_source_lib autobackup
GD_PHP_VERSION="$PELICAN_PHP"

# ---------------------------------------------------------------------------
# Bereits installiert: Aktualisieren
# ---------------------------------------------------------------------------
pelican_update() {
    gd_yesno "⬆️ Pelican aktualisieren" "Pelican wird auf die neueste Version aktualisiert. Das Panel ist dabei kurz nicht erreichbar.\n\nFortfahren?" 10 70 || return
    gd_gauge_open "⬆️ Pelican wird aktualisiert" "Aktualisierung wird vorbereitet..."
    gd_step 5  "Wartungsmodus wird aktiviert..." bash -c "cd '$PELICAN_DIR' && (php artisan down || true)"
    gd_step 10 "PHP ${PELICAN_PHP} wird sichergestellt..." gd_php_repo
    gd_step 20 "PHP-Pakete werden aktualisiert..." gd_pelican_packages
    gd_step 35 "Neueste Version wird heruntergeladen und Abhängigkeiten installiert..." gd_pelican_download
    gd_step 70 "Datenbank wird aktualisiert..." bash -c "cd '$PELICAN_DIR' && php artisan migrate --seed --force && php artisan optimize:clear && php artisan filament:optimize"
    gd_step 85 "Berechtigungen werden gesetzt..." bash -c "chmod -R 755 '$PELICAN_DIR'/storage/* '$PELICAN_DIR'/bootstrap/cache/ && chown -R www-data:www-data '$PELICAN_DIR'"
    gd_step 90 "Dienste werden neu gestartet..." bash -c "cd '$PELICAN_DIR' && php artisan queue:restart; systemctl restart pelican-queue; php artisan up"
    gd_progress 100 "Fertig."
    gd_gauge_close
    gd_msg "✅ Aktualisierung abgeschlossen" "Pelican wurde aktualisiert." 8 50
}

if [ -d "$PELICAN_DIR" ]; then
    choice=$(whiptail --title "Pelican Verwaltung" --menu "Pelican ist bereits installiert. Was möchtest du tun?" 13 70 3 \
        "1" "Panel aktualisieren" \
        "2" "Wings installieren/verwalten" \
        "3" "Zurück" 3>&1 1>&2 2>&3) || exit 0
    case "$choice" in
        1) pelican_update ;;
        2) gd_run wings-pelican.sh ;;
    esac
    exit 0
fi

# ---------------------------------------------------------------------------
# Neuinstallation
# ---------------------------------------------------------------------------
gd_warn_colors_on
if ! gd_yesno "⚠️ Pelican ist eine Beta-Version" "Pelican ist der Nachfolger von Pterodactyl, befindet sich aber noch in der Beta-Phase. Es kann Fehler enthalten, und Updates können Änderungen erfordern.\n\nPelican bringt die deutsche Sprache bereits mit, GermanDactyl ist dafür nicht nötig. Die Verwaltungsfunktionen dieses Skripts (Backups, Blueprint, phpMyAdmin usw.) sind nur für Pterodactyl vorgesehen.\n\nMöchtest du fortfahren?" 17 76; then
    gd_warn_colors_off
    exit 0
fi
gd_warn_colors_off

GD_DOMAIN="$(gd_ask_domain "🌐 Domain für Pelican" "Gib die Domain (FQDN) ein, unter der Pelican erreichbar sein soll, z. B. panel.deinedomain.de.")" || exit 0
GD_EMAIL="$(gd_ask_email "📧 E-Mail-Adresse" "Gib deine E-Mail-Adresse für das SSL-Zertifikat und dein Administrator-Konto ein. Mit der Eingabe stimmst du den Nutzungsbedingungen von Let's Encrypt zu.")" || exit 0
GD_ADMIN_USER="admin"
GD_ADMIN_PASSWORD="$(gd_gen_password 24)"

WITH_WINGS=false
if gd_yesno "🐦 Wings mitinstallieren?" "Soll Wings auf diesem Server gleich mit installiert und automatisch mit Pelican verbunden werden?" 10 70; then
    WITH_WINGS=true
    while true; do
        GD_PORT_RANGE="$(gd_input "🎮 Ports für Gameserver" "Welche Ports sollen für Gameserver freigegeben werden? (z. B. 25565-25600)" "$GD_DEFAULT_PORT_RANGE" 10 70)" || exit 0
        gd_valid_port_range "$GD_PORT_RANGE" && break
        gd_msg "Ungültiger Portbereich" "Bitte gib einen Bereich wie 25565-25600 an." 8 60
    done
fi
gd_security_ask

gd_gauge_open "🚀 Pelican wird installiert" "Installation wird vorbereitet..."
gd_step 2  "Paketquellen werden aktualisiert..." gd_apt update
gd_step 5  "PHP ${PELICAN_PHP}-Paketquelle wird eingerichtet..." gd_php_repo
gd_step 10 "PHP ${PELICAN_PHP}, nginx und Certbot werden installiert..." gd_pelican_packages
gd_step 20 "Composer wird installiert..." gd_composer_install
gd_step 25 "Pelican wird heruntergeladen, Abhängigkeiten werden installiert..." gd_pelican_download
gd_step 40 "Webserver wird für das SSL-Zertifikat vorbereitet..." gd_pelican_nginx "$GD_DOMAIN" http
gd_step 43 "SSL-Zertifikat wird bei Let's Encrypt angefordert..." gd_pelican_certbot "$GD_DOMAIN" "$GD_EMAIL"
gd_step 46 "Webserver wird mit SSL eingerichtet..." gd_pelican_nginx "$GD_DOMAIN" ssl
gd_step 47 "Automatische Zertifikatserneuerung wird eingerichtet..." gd_certbot_hook
gd_step 50 "Pelican wird konfiguriert, Administrator wird angelegt..." gd_pelican_configure "$GD_DOMAIN" "$GD_EMAIL" "$GD_ADMIN_USER" "$GD_ADMIN_PASSWORD"
gd_step 58 "Cronjob und Queue-Dienst werden eingerichtet..." gd_pelican_services
gd_step 62 "Pelican wird auf Erreichbarkeit geprüft..." gd_pelican_healthcheck "$GD_DOMAIN"
if $WITH_WINGS; then
    gd_step 65 "Docker wird installiert..." gd_docker_install
    gd_step 75 "Wings wird heruntergeladen..." gd_pelican_wings_binary
    gd_step 78 "Wings-Dienst wird eingerichtet..." gd_pelican_wings_service
    gd_step 80 "Node wird angelegt und Wings konfiguriert..." gd_pelican_node "$GD_DOMAIN"
    gd_progress 84 "Ports ${GD_PORT_RANGE} werden freigegeben..."
    if gd_pelican_allocations "$GD_PORT_RANGE" >> "$GD_LOG" 2>&1; then
        ALLOC_OK=true
    else
        ALLOC_OK=false
    fi
    gd_step 86 "Wings wird gestartet..." gd_wings_start
fi
gd_security_steps 90 "$WITH_WINGS" "${GD_PORT_RANGE:-}"
gd_progress 100 "Installation abgeschlossen."
gd_gauge_close

gd_conf_set PELICAN_DOMAIN "$GD_DOMAIN"
whiptail --title "🔑 Deine Zugangsdaten" --msgbox "Speichere dir diese Zugangsdaten jetzt ab. Dieses Fenster wird nicht noch einmal angezeigt.\n\nPanel:          https://${GD_DOMAIN}\nBenutzername:   ${GD_ADMIN_USER}\nE-Mail-Adresse: ${GD_EMAIL}\nPasswort:       ${GD_ADMIN_PASSWORD}" 15 78

if $WITH_WINGS; then
    text="Pelican und Wings sind eingerichtet und verbunden. Du kannst direkt deinen ersten Server anlegen."
    [ "${ALLOC_OK:-false}" = "true" ] || text+="\n\nDie Ports konnten nicht automatisch angelegt werden. Füge sie im Panel unter 'Nodes' → deine Node → 'Allocations' hinzu (${GD_PORT_RANGE})."
else
    text="Pelican ist eingerichtet: https://${GD_DOMAIN}\n\nFür Gameserver brauchst du noch Wings. Starte das Skript dazu erneut."
fi
gd_msg "✅ Installation erfolgreich" "$text" 14 78
clear
echo "Pelican: https://${GD_DOMAIN}"
echo "Log:     $GD_LOG"
