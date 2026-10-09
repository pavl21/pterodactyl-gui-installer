#!/bin/bash
# Pfad: problem-verwaltung.sh
# Problembehandlung für eine bestehende Pterodactyl-Installation.

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
gd_source_lib germandactyl
gd_source_lib security
gd_source_lib panel
gd_source_lib wings
gd_source_lib blueprint

# ---------------------------------------------------------------------------
# Notfall-Administrator anlegen
# ---------------------------------------------------------------------------
create_admin_account() {
    if ! gd_yesno "✱ Ausgesperrt?" "Wenn du das Passwort deines Administrator-Kontos vergessen hast, wird hier ein zusätzlicher, temporärer Administrator angelegt. Damit kannst du dich anmelden, das Passwort deines eigentlichen Kontos ändern und das temporäre Konto anschließend wieder löschen.\n\nMöchtest du fortfahren?" 14 78; then
        return
    fi

    local number username email password output
    number="$(( RANDOM % 9000 + 1000 ))"
    username="admin_${number}"
    email="notfall-${number}@$(gd_conf_get PANEL_DOMAIN | grep . || echo example.com)"
    password="$(gd_gen_password 20)"

    if output="$(gd_artisan_www p:user:make --no-interaction --email="$email" --username="$username" \
        --name-first=Notfall --name-last=Admin --password="$password" --admin=1 2>&1)"; then
        gd_log "Notfall-Administrator $username angelegt."
        while true; do
            gd_msg "★ Temporärer Administrator" "Ein neuer Administrator wurde angelegt:\n\n☺ Benutzername: $username\n✉ E-Mail:       $email\n✱ Passwort:     $password\n\nLösche dieses Konto, sobald du wieder Zugriff auf dein eigentliches Konto hast (Admin → Users)." 16 78
            gd_yesno "Zugangsdaten gespeichert?" "Hast du dir die Zugangsdaten gespeichert? Sie werden danach nicht noch einmal angezeigt." 9 70 && break
        done
    else
        echo "$output" >> "$GD_LOG"
        gd_msg "Fehler" "Der Benutzer konnte nicht angelegt werden.\n\n$(tail -n 5 <<< "$output" | cut -c1-100)" 14 78
    fi
}

# ---------------------------------------------------------------------------
# Panel reparieren = auf die gewünschte Version neu aufspielen
# ---------------------------------------------------------------------------
repair_panel() {
    gd_msg "⚙ Panel reparieren" "Beim Reparieren werden die Dateien des Panels neu heruntergeladen und alle Abhängigkeiten, die Datenbank-Struktur und die Berechtigungen neu eingerichtet. Deine Daten (Benutzer, Server, Einstellungen) bleiben erhalten.\n\nAchtung: Änderungen an Dateien des Panels (Themes, Addons) werden dabei überschrieben." 14 78
    gd_panel_update
}

# ---------------------------------------------------------------------------
# Webserver-Konfiguration reparieren
# ---------------------------------------------------------------------------
check_nginx_config() {
    local domain email
    domain="$(gd_conf_get PANEL_DOMAIN)"
    domain="$(gd_input "⊘ Panel nicht erreichbar" "Unter welcher Domain soll das Panel erreichbar sein? Gib nur die Domain des Panels ein (nicht die von Wings)." "$domain" 11 70)" || return
    domain="$(tr '[:upper:]' '[:lower:]' <<< "$domain" | tr -d '[:space:]')"
    if ! gd_valid_domain "$domain"; then
        gd_msg "Ungültige Domain" "Die eingegebene Domain ist ungültig. Bitte versuche es erneut." 8 60
        return
    fi
    gd_dns_check_dialog "$domain" || return

    if ! command -v nginx >/dev/null 2>&1; then
        gd_yesno "nginx fehlt" "Der Webserver nginx ist nicht installiert. Soll er installiert werden?" 9 60 || return
        gd_apt_install nginx >> "$GD_LOG" 2>&1
    fi

    # Erst dauerhaft sichern und nachfragen – danach wird die Konfiguration ggf. überschrieben
    local backup=""
    if [ -f /etc/nginx/sites-available/pterodactyl.conf ]; then
        gd_yesno "Konfiguration ersetzen?" "Es existiert bereits eine nginx-Konfiguration für Pterodactyl. Soll sie durch die aktuelle Standardkonfiguration ersetzt werden? (Eine Sicherung wird angelegt.)" 11 70 || return
        backup="/etc/nginx/sites-available/pterodactyl.conf.bak-$(date +%Y%m%d%H%M%S)"
        cp -p /etc/nginx/sites-available/pterodactyl.conf "$backup"
    fi

    if [ ! -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
        gd_yesno "Kein SSL-Zertifikat" "Für $domain wurde kein SSL-Zertifikat gefunden. Soll es jetzt erstellt werden?" 9 70 || return
        email="$(gd_ask_email "✉ E-Mail-Adresse" "Gib eine E-Mail-Adresse für das SSL-Zertifikat ein:" "$(gd_conf_get PANEL_EMAIL)")" || return
        clear; echo "SSL-Zertifikat wird angefordert..."
        if ! { gd_nginx_http_config "$domain" && gd_certbot_issue "$domain" "$email"; } >> "$GD_LOG" 2>&1; then
            # Vorherige Konfiguration zurückspielen, statt das Panel mit der vorläufigen Seite (503) zurückzulassen
            if [ -n "$backup" ]; then
                cp -p "$backup" /etc/nginx/sites-available/pterodactyl.conf
                nginx -t >> "$GD_LOG" 2>&1 && systemctl reload nginx
            fi
            gd_msg "✖ Zertifikat fehlgeschlagen" "Das Zertifikat konnte nicht ausgestellt werden. Häufige Ursachen: DNS zeigt nicht auf diesen Server, Port 80 ist blockiert oder das Limit von Let's Encrypt wurde erreicht.$( [ -n "$backup" ] && echo '\n\nDie vorherige nginx-Konfiguration wurde wiederhergestellt.')\n\nLog: $GD_LOG" 14 78
            return
        fi
        gd_certbot_hook
    fi

    # Alte Direkt-Datei früherer Versionen entfernen (lag ohne Symlink in sites-enabled)
    [ -f /etc/nginx/sites-enabled/pterodactyl.conf ] && [ ! -L /etc/nginx/sites-enabled/pterodactyl.conf ] && rm -f /etc/nginx/sites-enabled/pterodactyl.conf

    if gd_nginx_ssl_config "$domain" >> "$GD_LOG" 2>&1; then
        gd_conf_set PANEL_DOMAIN "$domain"
        if gd_panel_healthcheck "$domain" >> "$GD_LOG" 2>&1; then
            gd_msg "✔ Reparatur erfolgreich" "Das Panel antwortet wieder unter https://$domain.\n\nFalls es im Browser noch nicht geht, leere den Browser-Cache oder teste es in einem privaten Fenster." 11 74
        else
            gd_msg "⚠ Panel antwortet nicht" "Der Webserver ist eingerichtet, aber das Panel antwortet noch nicht korrekt. Versuche als Nächstes 'Das Panel ist fehlerhaft' (Reparatur).\n\nLog: $GD_LOG" 12 74
        fi
    else
        gd_msg "✖ Fehler" "Die nginx-Konfiguration ist fehlerhaft und wurde nicht aktiviert. Details: $GD_LOG" 9 74
    fi
}

# ---------------------------------------------------------------------------
# Menü
# ---------------------------------------------------------------------------
trouble_menu() {
    local choice
    while true; do
        choice=$(whiptail --title "✚ Problembehandlung" --menu "Wobei können wir dir helfen?" 17 70 6 \
            "1" "✱ Ich habe mich ausgesperrt" \
            "2" "⚙ Das Panel ist fehlerhaft (reparieren)" \
            "3" "⊘ Das Panel kann nicht erreicht werden" \
            "4" "✱ SSL-Zertifikate erneuern/prüfen" \
            "5" "✚ Allgemeine Analyse starten" \
            "6" "← Zurück zum Hauptmenü" 3>&1 1>&2 2>&3) || return 0

        case "$choice" in
            1) create_admin_account ;;
            2) repair_panel ;;
            3) check_nginx_config ;;
            4) gd_run certbot-renew-verwaltung.sh ;;
            5) gd_run analyse.sh ;;
            *) return 0 ;;
        esac
    done
}

# Direktaufruf einzelner Aktionen aus dem Hauptmenü (Hilfe & Analyse), sonst das Menü anzeigen
case "${1:-}" in
    admin)  create_admin_account ;;
    repair) repair_panel ;;
    nginx)  check_nginx_config ;;
    *)      trouble_menu ;;
esac
