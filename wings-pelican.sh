#!/bin/bash
# Pfad: wings-pelican.sh
# Wings für Pelican installieren. Liegt Pelican auf demselben Server, wird die Node automatisch angelegt,
# sonst wird die im Panel erzeugte Konfiguration abgefragt.

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

if [ -f "$PELICAN_WINGS_CONFIG" ] && [ -x "$PELICAN_WINGS_BIN" ]; then
    if gd_yesno "⇄ Wings ist installiert" "Wings ist bereits eingerichtet (Status: $(systemctl is-active wings)).\n\nSoll Wings auf die neueste Version aktualisiert und neu gestartet werden?" 11 70; then
        gd_gauge_open "↑ Wings wird aktualisiert" "Bitte warten..."
        gd_step 30 "Wings wird heruntergeladen..." gd_pelican_wings_binary
        gd_step 80 "Wings wird neu gestartet..." gd_wings_start
        gd_progress 100 "Fertig."
        gd_gauge_close
    fi
    exit 0
fi

if [ -f "$PELICAN_DIR/artisan" ]; then
    # Pelican liegt auf diesem Server -> automatisch einrichten
    domain="$(gd_conf_get PELICAN_DOMAIN)"
    # Pelican nicht mit diesem Skript eingerichtet: Domain aus der .env übernehmen
    [ -z "$domain" ] && domain="$(grep -E '^APP_URL=' "$PELICAN_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d "\"'" | sed 's#^https\?://##; s#/.*##')"
    if ! gd_valid_domain "$domain"; then
        domain="$(gd_ask_domain "⇄ Domain für Wings" "Unter welcher Domain ist dein Pelican-Panel erreichbar? Wings nutzt sie ebenfalls (Port 8080).")" || exit 0
    fi
    while true; do
        GD_PORT_RANGE="$(gd_input "⚑ Ports für Gameserver" "Welche Ports sollen für Gameserver freigegeben werden? (z. B. 25565-25600)" "$GD_DEFAULT_PORT_RANGE" 10 70)" || exit 0
        gd_valid_port_range "$GD_PORT_RANGE" && break
        gd_msg "Ungültiger Portbereich" "Bitte gib einen Bereich wie 25565-25600 an (größer als 1024, höchstens 1000 Ports)." 9 70
    done
    gd_gauge_open "⇄ Wings wird eingerichtet" "Bitte warten..."
    gd_step 5  "Docker wird installiert..." gd_docker_install
    gd_step 40 "Wings wird heruntergeladen..." gd_pelican_wings_binary
    gd_step 50 "Wings-Dienst wird eingerichtet..." gd_pelican_wings_service
    gd_step 60 "Node wird angelegt und Wings konfiguriert..." gd_pelican_node "$domain"
    gd_progress 75 "Ports werden freigegeben..."
    gd_pelican_allocations "$GD_PORT_RANGE" >> "$GD_LOG" 2>&1 || ALLOC_FAIL=true
    gd_step 82 "Docker-Netzwerk für Gameserver wird vorbereitet..." gd_wings_network_prepare "$PELICAN_WINGS_CONFIG" pelican_nw pelican0
    gd_step 85 "Wings wird gestartet..." gd_wings_start
    gd_progress 90 "Verbindung zwischen Panel und Wings wird geprüft..."
    gd_wings_verify "$domain" "$PELICAN_WINGS_CONFIG" >> "$GD_LOG" 2>&1 || VERIFY_FAIL=true
    if gd_ufw_active; then
        gd_step 95 "Firewall wird angepasst..." gd_firewall_setup true "$GD_PORT_RANGE"
    fi
    gd_progress 100 "Fertig."
    gd_gauge_close
    if [ "${VERIFY_FAIL:-false}" = true ]; then
        gd_msg "⚠ Wings antwortet nicht" "Wings ist installiert, antwortet aber nicht. Prüfe den Dienst mit 'journalctl -u wings -n 50'." 10 74
        exit 1
    fi
    gd_msg "✔ Wings ist einsatzbereit" "Wings ist mit Pelican verbunden.$( [ "${ALLOC_FAIL:-false}" = true ] && echo "\n\nDie Ports konnten nicht automatisch angelegt werden. Füge sie im Panel unter 'Nodes' → 'Allocations' hinzu.")" 11 74
    exit 0
fi

# Pelican liegt auf einem anderen Server -> Konfiguration aus dem Panel einfügen
GD_WINGS_FQDN="$(gd_ask_domain "⇄ Domain für Wings" "Gib die Domain für diesen Wings-Server ein, z. B. node1.deinedomain.de. Der DNS-Eintrag muss auf diesen Server zeigen.")" || exit 0
GD_EMAIL="$(gd_ask_email "✉ E-Mail für Let's Encrypt" "Gib eine E-Mail-Adresse für das SSL-Zertifikat ein. Mit der Eingabe stimmst du den Nutzungsbedingungen von Let's Encrypt zu.")" || exit 0
gd_gauge_open "⇄ Wings wird installiert" "Bitte warten..."
gd_step 5  "Paketquellen werden aktualisiert..." gd_apt_update
gd_step 15 "Docker wird installiert..." gd_docker_install
gd_step 60 "Wings wird heruntergeladen..." gd_pelican_wings_binary
gd_step 75 "Wings-Dienst wird eingerichtet..." gd_pelican_wings_service
gd_step 85 "SSL-Zertifikat für Wings wird angefordert..." gd_wings_certificate "$GD_WINGS_FQDN" "$GD_EMAIL"
gd_step 95 "Automatische Zertifikatserneuerung wird eingerichtet..." gd_certbot_hook
gd_step 97 "Editor wird bereitgestellt..." bash -c "command -v nano >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -q nano"
if gd_ufw_active; then
    gd_step 99 "Firewall wird angepasst..." gd_firewall_setup true ""
fi
gd_progress 100 "Fertig."
gd_gauge_close

gd_msg "Konfiguration einfügen" "Wings ist vorbereitet, jetzt fehlt noch die Konfiguration.\n\n1. Lege im Pelican-Panel unter 'Nodes' eine neue Node an (Domain: ${GD_WINGS_FQDN}, Port 8080, SSL aktiviert).\n2. Öffne danach den Reiter 'Configuration File' und kopiere den Inhalt.\n3. Im nächsten Schritt öffnet sich der Editor nano: Füge den Inhalt ein, speichere mit Strg + O und schließe mit Strg + X." 16 78

while true; do
    nano "$PELICAN_WINGS_CONFIG" < /dev/tty > /dev/tty
    if [ -s "$PELICAN_WINGS_CONFIG" ] && grep -q '^token:' "$PELICAN_WINGS_CONFIG"; then
        chmod 600 "$PELICAN_WINGS_CONFIG"
        gd_wings_network_prepare "$PELICAN_WINGS_CONFIG" pelican_nw pelican0 >> "$GD_LOG" 2>&1
        if gd_wings_start >> "$GD_LOG" 2>&1; then
            gd_msg "✔ Wings läuft" "Wings ist gestartet und sollte im Panel als verbunden angezeigt werden." 9 70
        else
            gd_msg "✖ Wings startet nicht" "Wings konnte nicht gestartet werden. Prüfe die Konfiguration und das SSL-Zertifikat.\n\nFehlermeldungen: journalctl -u wings -n 50" 11 74
        fi
        exit 0
    fi
    gd_msg "Konfiguration fehlt" "Die Datei ist leer oder unvollständig (es fehlt die Zeile 'token:'). Bitte füge die komplette Konfiguration ein." 10 70
done
