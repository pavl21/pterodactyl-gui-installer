#!/bin/bash
# Pfad: wings-installer.sh
# Wings installieren, verbinden, aktualisieren oder reparieren.
# Liegt das Panel auf demselben Server, wird Wings vollautomatisch eingerichtet.

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
gd_source_lib blueprint
gd_source_lib backup
gd_source_lib autobackup
gd_source_lib uninstall
gd_source_lib manage

# ---------------------------------------------------------------------------
# Wings ist bereits installiert: Status, Neustart, Aktualisierung
# ---------------------------------------------------------------------------
gd_wings_manage() {
    local choice state
    while true; do
        state="$(systemctl is-active wings 2>/dev/null)"
        case "$state" in
            active) state="✔ läuft" ;;
            failed) state="✖ fehlgeschlagen" ;;
            *) state="○ gestoppt ($state)" ;;
        esac
        choice=$(whiptail --title "⇄ Wings-Verwaltung" --menu "Wings ist installiert: v$("$WINGS_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)\nStatus: $state" 17 78 5 \
            "1" "Wings neu starten" \
            "2" "Wings aktualisieren" \
            "3" "Letzte Log-Einträge anzeigen" \
            "4" "Swap-Speicher einrichten" \
            "5" "Zurück" 3>&1 1>&2 2>&3) || return 0
        case "$choice" in
            1)
                clear; echo "Wings wird neu gestartet..."
                if gd_wings_start >> "$GD_LOG" 2>&1; then
                    gd_msg "✔ Wings läuft" "Wings wurde erfolgreich neu gestartet. Die Server sollten in Kürze wieder erreichbar sein." 9 70
                else
                    gd_msg "✖ Wings startet nicht" "Wings konnte nicht gestartet werden. Häufige Ursachen:\n- Port 8080 oder 2022 wird von einem anderen Programm belegt\n- Das SSL-Zertifikat ist abgelaufen oder fehlt\n- /etc/pterodactyl/config.yml fehlt oder ist fehlerhaft\n\nMit 'Letzte Log-Einträge anzeigen' siehst du die genaue Fehlermeldung." 15 78
                fi ;;
            2) gd_wings_update ;;
            3)
                journalctl -u wings -n 40 --no-pager > "$GD_TMP/wings.log" 2>&1
                whiptail --title "Wings-Log (letzte 40 Zeilen)" --scrolltext --textbox "$GD_TMP/wings.log" 25 110 ;;
            4) gd_swap_dialog ;;
            *) return 0 ;;
        esac
    done
}

gd_swap_dialog() {
    local size
    if [ -e /swapfile ]; then
        gd_msg "Swap vorhanden" "Es existiert bereits eine Swap-Datei. Du kannst sie über die SWAP-Verwaltung im Hauptmenü anpassen." 9 70
        return 0
    fi
    gd_yesno "Swap-Speicher" "Möchtest du Swap-Speicher einrichten? Er wird genutzt, wenn der Arbeitsspeicher knapp wird." 9 70 || return 0
    while true; do
        size="$(gd_input "Swap-Speicher erstellen" "Gib die gewünschte Swap-Größe in MB ein (z. B. 2048):" "2048" 10 60)" || return 0
        [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 256 ] && break
        gd_msg "Ungültige Eingabe" "Bitte gib eine Zahl ab 256 ein." 8 50
    done
    if gd_swap_create "$size" >> "$GD_LOG" 2>&1; then
        gd_msg "Swap-Speicher erstellt" "Swap-Speicher mit ${size} MB wurde erstellt, aktiviert und bleibt auch nach einem Neustart erhalten." 9 70
    else
        gd_msg "Fehler" "Der Swap-Speicher konnte nicht erstellt werden. Details: $GD_LOG" 9 70
    fi
}

# ---------------------------------------------------------------------------
# Neuinstallation
# ---------------------------------------------------------------------------
gd_wings_install_local() {
    # Panel liegt auf diesem Server -> alles automatisch
    local domain email
    domain="$(gd_conf_get PANEL_DOMAIN)"
    [ -z "$domain" ] && domain="$(gd_panel_env APP_URL | sed 's#^https\?://##; s#/.*##')"
    email="$(gd_conf_get PANEL_EMAIL)"
    [ -z "$email" ] && email="$(gd_panel_env APP_SERVICE_AUTHOR)"

    GD_WINGS_FQDN="$domain"
    if ! gd_yesno "⇄ Domain für Wings" "Wings nutzt standardmäßig die Domain des Panels:\n\n${domain} (Port 8080)\n\nMöchtest du diese Domain verwenden? Bei 'Nein' kannst du eine eigene Subdomain angeben." 13 74; then
        GD_WINGS_FQDN="$(gd_ask_domain "⇄ Domain für Wings" "Gib die Domain für Wings ein, z. B. node1.deinedomain.de:")" || return 1
    fi
    if ! gd_valid_email "$email"; then
        email="$(gd_ask_email "✉ E-Mail-Adresse" "Gib eine E-Mail-Adresse für das SSL-Zertifikat ein:")" || return 1
    fi
    GD_EMAIL="$email"

    while true; do
        GD_PORT_RANGE="$(gd_input "⚑ Ports für Gameserver" "Welche Ports sollen für Gameserver freigegeben werden?\n\nFormat: Start-Ende, z. B. 25565-25600 (höchstens 1000 Ports, jeweils größer als 1024)." "$GD_DEFAULT_PORT_RANGE" 13 74)" || return 1
        gd_valid_port_range "$GD_PORT_RANGE" && break
        gd_msg "Ungültiger Portbereich" "Bitte gib einen Bereich wie 25565-25600 an." 8 60
    done

    GD_SEC_UFW=false
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        GD_SEC_UFW=true   # Firewall ist bereits aktiv -> Wings-Ports ergänzen
    elif gd_yesno "✚ Firewall" "Soll die Firewall (UFW) aktiviert werden? Dein SSH-Port sowie 80, 443, 8080, 2022 und die Gameserver-Ports werden automatisch freigegeben." 11 74; then
        GD_SEC_UFW=true
    fi

    gd_gauge_open "⇄ Wings wird eingerichtet" "Einrichtung wird vorbereitet..."
    gd_step 2 "Paketquellen werden aktualisiert..." gd_apt update
    gd_wings_local_steps 5 80
    gd_step 88 "Automatische Zertifikatserneuerung wird eingerichtet..." gd_certbot_hook
    if [ "$GD_SEC_UFW" = "true" ]; then
        gd_step 94 "Firewall wird eingerichtet..." gd_firewall_setup true "$GD_PORT_RANGE"
    fi
    gd_progress 100 "Wings ist eingerichtet."
    gd_gauge_close

    gd_msg "✔ Wings ist einsatzbereit" "Wings ist installiert, als Node im Panel eingetragen und verbunden.\n\nDu kannst jetzt direkt im Panel unter 'Admin' → 'Servers' → 'Create New' deinen ersten Gameserver anlegen.\n\nFreigegebene Ports: ${GD_PORT_RANGE}" 14 78
    gd_swap_dialog
}

gd_wings_install_remote() {
    # Panel liegt auf einem anderen Server -> Installation + Verbindung per Token-Befehl aus dem Panel
    GD_WINGS_FQDN="$(gd_ask_domain "⇄ Domain für Wings" "Gib die Domain für diesen Wings-Server ein, z. B. node1.deinedomain.de.\n\nDer DNS-Eintrag muss auf diesen Server zeigen.")" || return 1
    GD_EMAIL="$(gd_ask_email "✉ E-Mail für Let's Encrypt" "Gib eine E-Mail-Adresse für das SSL-Zertifikat ein. Mit der Eingabe stimmst du den Nutzungsbedingungen von Let's Encrypt zu. Das Zertifikat wird automatisch erneuert.")" || return 1

    gd_gauge_open "⇄ Wings wird installiert" "Installation wird vorbereitet..."
    gd_wings_remote_steps 5
    gd_progress 100 "Wings ist installiert."
    gd_gauge_close

    if gd_wings_configure_remote; then
        if gd_yesno "✚ Firewall" "Soll die Firewall (UFW) aktiviert werden? Freigegeben werden dein SSH-Port sowie 8080 und 2022.\n\nDie Ports deiner Gameserver gibst du danach mit 'ufw allow <port>' frei." 12 74; then
            gd_firewall_setup true "" >> "$GD_LOG" 2>&1
        fi
        gd_msg "✔ Wings ist verbunden" "Wings läuft und ist mit deinem Panel verbunden. In der Node-Übersicht sollte nun ein grünes Herz zu sehen sein.\n\nLege im Panel unter der Node im Reiter 'Allocation' noch die Ports für deine Gameserver an." 13 78
        gd_swap_dialog
    fi
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
if [ -x "$WINGS_BIN" ] && [ -f "$WINGS_CONFIG" ]; then
    gd_wings_manage
elif [ -f "$PTERO_DIR/artisan" ]; then
    gd_wings_install_local
else
    gd_wings_install_remote
fi
# Kurzbefehl für die Verwaltung (auch auf reinen Wings-Servern)
[ -f "$WINGS_CONFIG" ] && gd_shortcut_install >> "$GD_LOG" 2>&1
exit 0
