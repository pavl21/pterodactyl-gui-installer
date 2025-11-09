#!/bin/bash

# Lade Whiptail-Farben
source "$(dirname "$0")/whiptail-colors.sh" 2>/dev/null || source /opt/pterodactyl/whiptail-colors.sh 2>/dev/null || true

# GermanDactyl Setup - Management Commands
# Dieser Script bietet einfache Befehle zur Verwaltung des Pterodactyl Panels

PANEL_DIR="/var/www/pterodactyl"
SETUP_URL="https://setup.germandactyl.de/"

# Farben für Output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Prüfen ob Panel installiert ist
check_panel_installed() {
    if [ ! -d "$PANEL_DIR" ]; then
        echo -e "${RED}Fehler: Pterodactyl Panel ist nicht installiert.${NC}"
        echo -e "Installiere es zuerst mit: curl -sSL ${SETUP_URL} | sudo bash"
        exit 1
    fi
}

# Hilfe anzeigen
show_help() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}GermanDactyl Setup - Management Commands${NC}               ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Verfügbare Befehle:${NC}"
    echo ""
    echo -e "  ${GREEN}gds setup${NC}         - Wartungs- und Verwaltungsmenü öffnen"
    echo -e "  ${GREEN}gds maintenance${NC}   - Wartungsmodus aktivieren/deaktivieren"
    echo -e "  ${GREEN}gds backup${NC}        - Backup-Verwaltung öffnen"
    echo -e "  ${GREEN}gds domain${NC}        - Panel-Domain anzeigen"
    echo -e "  ${GREEN}gds cert${NC}          - SSL-Zertifikat-Status anzeigen"
    echo ""
    echo -e "${YELLOW}Zusätzliche Befehle:${NC}"
    echo ""
    echo -e "  ${GREEN}gds update${NC}        - Pterodactyl Panel aktualisieren"
    echo -e "  ${GREEN}gds update-scripts${NC} - Alle Verwaltungs-Scripte aktualisieren"
    echo -e "  ${GREEN}gds cache${NC}         - Cache leeren (config, view, route)"
    echo -e "  ${GREEN}gds restart${NC}       - Alle Pterodactyl-Dienste neu starten"
    echo -e "  ${GREEN}gds status${NC}        - Status aller Pterodactyl-Dienste anzeigen"
    echo -e "  ${GREEN}gds logs${NC}          - Letzte Panel-Logs anzeigen"
    echo -e "  ${GREEN}gds info${NC}          - Panel-Informationen anzeigen"
    echo -e "  ${GREEN}gds user${NC}          - Benutzer erstellen (interaktiv)"
    echo ""
    echo -e "Verwende ${GREEN}gds help${NC} um diese Hilfe anzuzeigen."
    echo ""
}

# Setup/Wartungsmenü öffnen
cmd_setup() {
    echo -e "${BLUE}Öffne Wartungs- und Verwaltungsmenü...${NC}"
    curl -sSL "${SETUP_URL}" | sudo bash -s --
}

# Wartungsmodus
cmd_maintenance() {
    check_panel_installed

    if whiptail --title "Wartungsmodus" --yesno "Möchtest du den Wartungsmodus aktivieren oder deaktivieren?\n\nAktivieren = Ja\nDeaktivieren = Nein" 12 60; then
        # Aktivieren
        cd "$PANEL_DIR" || exit 1
        php artisan down
        if [ $? -eq 0 ]; then
            whiptail_success --title "Erfolgreich" --msgbox "Wartungsmodus wurde aktiviert.\n\nDas Panel ist nun für Besucher nicht erreichbar." 10 60
        else
            whiptail_error --title "Fehler" --msgbox "Fehler beim Aktivieren des Wartungsmodus." 8 60
        fi
    else
        # Deaktivieren
        cd "$PANEL_DIR" || exit 1
        php artisan up
        if [ $? -eq 0 ]; then
            whiptail_success --title "Erfolgreich" --msgbox "Wartungsmodus wurde deaktiviert.\n\nDas Panel ist wieder erreichbar." 10 60
        else
            whiptail_error --title "Fehler" --msgbox "Fehler beim Deaktivieren des Wartungsmodus." 8 60
        fi
    fi
}

# Backup-Verwaltung
cmd_backup() {
    echo -e "${BLUE}Öffne Backup-Verwaltung...${NC}"

    if [ -f "/opt/pterodactyl/backup-verwaltung.sh" ]; then
        bash /opt/pterodactyl/backup-verwaltung.sh
    else
        echo -e "${RED}Backup-Verwaltung Script nicht gefunden.${NC}"
        echo -e "Führe aus: gds update-scripts"
        exit 1
    fi
}

# Domain anzeigen
cmd_domain() {
    check_panel_installed

    # Domain aus .env auslesen
    if [ -f "$PANEL_DIR/.env" ]; then
        APP_URL=$(grep "^APP_URL=" "$PANEL_DIR/.env" | cut -d '=' -f2)

        echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}  ${GREEN}Panel-Domain${NC}                                           ${BLUE}║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${YELLOW}URL:${NC} ${GREEN}${APP_URL}${NC}"
        echo ""

        # Auch aus Nginx Config auslesen zur Bestätigung
        if [ -f "/etc/nginx/sites-available/pterodactyl.conf" ]; then
            NGINX_DOMAIN=$(grep "server_name" /etc/nginx/sites-available/pterodactyl.conf | head -n 1 | awk '{print $2}' | tr -d ';')
            if [ ! -z "$NGINX_DOMAIN" ] && [ "$NGINX_DOMAIN" != "_" ]; then
                echo -e "  ${YELLOW}Nginx:${NC} ${GREEN}${NGINX_DOMAIN}${NC}"
                echo ""
            fi
        fi
    else
        echo -e "${RED}Fehler: .env Datei nicht gefunden.${NC}"
        exit 1
    fi
}

# SSL-Zertifikat-Status
cmd_cert() {
    check_panel_installed

    # Domain aus .env auslesen
    if [ -f "$PANEL_DIR/.env" ]; then
        APP_URL=$(grep "^APP_URL=" "$PANEL_DIR/.env" | cut -d '=' -f2 | sed 's|https://||' | sed 's|http://||')

        echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}  ${GREEN}SSL-Zertifikat Status${NC}                                  ${BLUE}║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        # Prüfen ob Certbot installiert ist
        if ! command -v certbot &> /dev/null; then
            echo -e "${RED}Certbot ist nicht installiert.${NC}"
            exit 1
        fi

        # Zertifikat-Informationen abrufen
        CERT_PATH="/etc/letsencrypt/live/${APP_URL}/fullchain.pem"

        if [ -f "$CERT_PATH" ]; then
            # Ablaufdatum extrahieren
            EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
            EXPIRY_TIMESTAMP=$(date -d "$EXPIRY_DATE" +%s)
            CURRENT_TIMESTAMP=$(date +%s)
            DAYS_LEFT=$(( ($EXPIRY_TIMESTAMP - $CURRENT_TIMESTAMP) / 86400 ))

            echo -e "  ${YELLOW}Domain:${NC} ${GREEN}${APP_URL}${NC}"
            echo -e "  ${YELLOW}Gültig bis:${NC} ${GREEN}${EXPIRY_DATE}${NC}"
            echo -e "  ${YELLOW}Verbleibende Tage:${NC} ${GREEN}${DAYS_LEFT} Tage${NC}"
            echo ""

            if [ $DAYS_LEFT -lt 30 ]; then
                echo -e "  ${RED}Warnung: Zertifikat läuft bald ab!${NC}"
                echo -e "  ${YELLOW}Führe 'certbot renew' aus um es zu erneuern.${NC}"
                echo ""
            else
                echo -e "  ${GREEN}Zertifikat ist gültig.${NC}"
                echo ""
            fi

            # Certbot Zertifikate auflisten
            echo -e "${YELLOW}Alle Certbot-Zertifikate:${NC}"
            certbot certificates 2>/dev/null
        else
            echo -e "${RED}Kein SSL-Zertifikat für ${APP_URL} gefunden.${NC}"
            echo -e "${YELLOW}Installiere ein Zertifikat mit:${NC}"
            echo -e "  certbot --nginx -d ${APP_URL}"
            echo ""
        fi
    else
        echo -e "${RED}Fehler: .env Datei nicht gefunden.${NC}"
        exit 1
    fi
}

# Panel aktualisieren
cmd_update() {
    check_panel_installed

    echo -e "${YELLOW}Panel-Update wird vorbereitet...${NC}"
    echo ""

    if whiptail --title "Panel aktualisieren" --yesno "Möchtest du das Pterodactyl Panel jetzt aktualisieren?\n\nDies wird:\n- Wartungsmodus aktivieren\n- Neueste Version herunterladen\n- Composer-Abhängigkeiten aktualisieren\n- Datenbank migrieren\n- Cache leeren\n\nFortfahren?" 18 70; then
        cd "$PANEL_DIR" || exit 1

        # Wartungsmodus aktivieren
        php artisan down

        # Panel herunterladen und aktualisieren
        curl -L https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xzv
        chmod -R 755 storage/* bootstrap/cache

        # Composer
        COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

        # Datenbank
        php artisan migrate --seed --force

        # Cache leeren
        php artisan view:clear
        php artisan config:clear
        php artisan cache:clear

        # Berechtigungen
        chown -R www-data:www-data "$PANEL_DIR"

        # Queue Worker neu starten
        systemctl restart pteroq

        # Wartungsmodus deaktivieren
        php artisan up

        echo -e "${GREEN}Panel wurde erfolgreich aktualisiert!${NC}"
    else
        echo -e "${YELLOW}Update abgebrochen.${NC}"
    fi
}

# Verwaltungs-Scripte aktualisieren
cmd_update_scripts() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}Script-Update${NC}                                          ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if ! whiptail --title "Scripte aktualisieren" --yesno "Möchtest du alle Verwaltungs-Scripte von GitHub aktualisieren?\n\nDies lädt die neuesten Versionen aller Scripte herunter:\n• backup-verwaltung.sh\n• database-host-config.sh\n• phpmyadmin-installer.sh\n• wings-installer.sh\n• problem-verwaltung.sh\n• und weitere...\n\nFortfahren?" 20 70; then
        echo -e "${YELLOW}Update abgebrochen.${NC}"
        return 0
    fi

    echo -e "${BLUE}Aktualisiere Scripte...${NC}"
    echo ""

    # GitHub Repository Basis-URL
    REPO_URL="https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/main"

    # Liste aller zu aktualisierenden Scripte
    SCRIPTS=(
        "installer.sh"
        "gds-command.sh"
        "backup-verwaltung.sh"
        "database-host-config.sh"
        "phpmyadmin-installer.sh"
        "wings-installer.sh"
        "problem-verwaltung.sh"
        "custom-ssh-login-config.sh"
        "swap-verwaltung.sh"
        "theme-verwaltung.sh"
        "whiptail-colors.sh"
        "system-check.sh"
        "swap-setup.sh"
        "certbot-renew-verwaltung.sh"
        "pelican-installer.sh"
        "wings-pelican.sh"
        "motd.sh"
        "analyse.sh"
    )

    # Erstelle Verzeichnis falls nicht vorhanden
    mkdir -p /opt/pterodactyl

    # Zähler für erfolgreiche/fehlgeschlagene Updates
    SUCCESS_COUNT=0
    FAIL_COUNT=0

    for script in "${SCRIPTS[@]}"; do
        echo -n "  Aktualisiere $script... "

        # Backup der aktuellen Version (falls vorhanden)
        if [ -f "/opt/pterodactyl/$script" ]; then
            cp "/opt/pterodactyl/$script" "/opt/pterodactyl/${script}.backup" 2>/dev/null
        fi

        # Download der neuen Version
        if curl -sSL "$REPO_URL/$script" -o "/opt/pterodactyl/$script" 2>/dev/null; then
            chmod +x "/opt/pterodactyl/$script"
            echo -e "${GREEN}OK${NC}"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            # Lösche Backup bei Erfolg
            rm -f "/opt/pterodactyl/${script}.backup" 2>/dev/null
        else
            echo -e "${RED}FEHLER${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            # Stelle Backup wieder her bei Fehler
            if [ -f "/opt/pterodactyl/${script}.backup" ]; then
                mv "/opt/pterodactyl/${script}.backup" "/opt/pterodactyl/$script" 2>/dev/null
            fi
        fi
    done

    # gds-command selbst aktualisieren (falls erfolgreich heruntergeladen)
    if [ -f "/opt/pterodactyl/gds-command.sh" ]; then
        echo -n "  Aktualisiere gds-Befehl... "
        if cp "/opt/pterodactyl/gds-command.sh" /usr/local/bin/gds 2>/dev/null; then
            chmod +x /usr/local/bin/gds
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}WARNUNG${NC}"
        fi
    fi

    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}Update abgeschlossen${NC}                                   ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}Erfolgreich:${NC} $SUCCESS_COUNT Script(e)"
    echo -e "  ${RED}Fehlgeschlagen:${NC} $FAIL_COUNT Script(e)"
    echo ""

    if [ $FAIL_COUNT -gt 0 ]; then
        echo -e "${YELLOW}Hinweis: Bei Fehlern wurden die alten Versionen beibehalten.${NC}"
    fi

    echo -e "${BLUE}WICHTIG:${NC} Wenn gds-command.sh aktualisiert wurde, starte das Script neu um die Änderungen zu nutzen."
}

# Cache leeren
cmd_cache() {
    check_panel_installed

    echo -e "${BLUE}Leere Cache...${NC}"
    cd "$PANEL_DIR" || exit 1

    php artisan config:clear
    php artisan cache:clear
    php artisan view:clear
    php artisan route:clear

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Cache erfolgreich geleert!${NC}"
    else
        echo -e "${RED}Fehler beim Leeren des Cache.${NC}"
    fi
}

# Dienste neu starten
cmd_restart() {
    check_panel_installed

    echo -e "${BLUE}Starte Pterodactyl-Dienste neu...${NC}"

    systemctl restart nginx
    systemctl restart redis-server
    systemctl restart pteroq
    systemctl restart "php*-fpm"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Dienste erfolgreich neu gestartet!${NC}"
    else
        echo -e "${RED}Einige Dienste konnten nicht neu gestartet werden.${NC}"
    fi
}

# Status anzeigen
cmd_status() {
    check_panel_installed

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}Pterodactyl Dienste-Status${NC}                             ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_service() {
        if systemctl is-active --quiet "$1"; then
            echo -e "  ${GREEN}●${NC} $1: ${GREEN}aktiv${NC}"
        else
            echo -e "  ${RED}●${NC} $1: ${RED}inaktiv${NC}"
        fi
    }

    check_service "nginx"
    check_service "redis-server"
    check_service "pteroq"
    check_service "mariadb"

    echo ""
}

# Logs anzeigen
cmd_logs() {
    check_panel_installed

    echo -e "${BLUE}Letzte Panel-Logs:${NC}"
    echo ""

    if [ -f "$PANEL_DIR/storage/logs/laravel.log" ]; then
        tail -n 50 "$PANEL_DIR/storage/logs/laravel.log"
    else
        echo -e "${YELLOW}Keine Logs gefunden.${NC}"
    fi
}

# Panel-Informationen
cmd_info() {
    check_panel_installed

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}Pterodactyl Panel Informationen${NC}                        ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    cd "$PANEL_DIR" || exit 1

    # Version
    if [ -f "config/app.php" ]; then
        VERSION=$(grep "'version'" config/app.php | cut -d "'" -f4)
        echo -e "  ${YELLOW}Version:${NC} ${GREEN}${VERSION}${NC}"
    fi

    # PHP Version
    PHP_VERSION=$(php -v | head -n 1 | cut -d ' ' -f2)
    echo -e "  ${YELLOW}PHP Version:${NC} ${GREEN}${PHP_VERSION}${NC}"

    # Domain
    if [ -f ".env" ]; then
        APP_URL=$(grep "^APP_URL=" ".env" | cut -d '=' -f2)
        echo -e "  ${YELLOW}URL:${NC} ${GREEN}${APP_URL}${NC}"
    fi

    # Datenbank
    if [ -f ".env" ]; then
        DB_HOST=$(grep "^DB_HOST=" ".env" | cut -d '=' -f2)
        DB_NAME=$(grep "^DB_DATABASE=" ".env" | cut -d '=' -f2)
        echo -e "  ${YELLOW}Datenbank:${NC} ${GREEN}${DB_NAME}@${DB_HOST}${NC}"
    fi

    echo ""
}

# Benutzer erstellen
cmd_user() {
    check_panel_installed

    echo -e "${BLUE}Neuen Benutzer erstellen${NC}"
    echo ""

    # Interaktive Eingaben mit whiptail
    EMAIL=$(whiptail --title "Benutzer erstellen" --inputbox "E-Mail-Adresse:" 10 60 3>&1 1>&2 2>&3)
    if [ -z "$EMAIL" ]; then
        echo -e "${RED}Abgebrochen.${NC}"
        exit 1
    fi

    USERNAME=$(whiptail --title "Benutzer erstellen" --inputbox "Benutzername:" 10 60 3>&1 1>&2 2>&3)
    if [ -z "$USERNAME" ]; then
        echo -e "${RED}Abgebrochen.${NC}"
        exit 1
    fi

    FIRSTNAME=$(whiptail --title "Benutzer erstellen" --inputbox "Vorname:" 10 60 3>&1 1>&2 2>&3)
    if [ -z "$FIRSTNAME" ]; then
        echo -e "${RED}Abgebrochen.${NC}"
        exit 1
    fi

    LASTNAME=$(whiptail --title "Benutzer erstellen" --inputbox "Nachname:" 10 60 3>&1 1>&2 2>&3)
    if [ -z "$LASTNAME" ]; then
        echo -e "${RED}Abgebrochen.${NC}"
        exit 1
    fi

    PASSWORD=$(whiptail --title "Benutzer erstellen" --passwordbox "Passwort:" 10 60 3>&1 1>&2 2>&3)
    if [ -z "$PASSWORD" ]; then
        echo -e "${RED}Abgebrochen.${NC}"
        exit 1
    fi

    # Admin-Rechte?
    if whiptail --title "Benutzer erstellen" --yesno "Soll der Benutzer Admin-Rechte haben?" 10 60; then
        ADMIN=1
    else
        ADMIN=0
    fi

    cd "$PANEL_DIR" || exit 1

    php artisan p:user:make \
        --email="$EMAIL" \
        --username="$USERNAME" \
        --name-first="$FIRSTNAME" \
        --name-last="$LASTNAME" \
        --password="$PASSWORD" \
        --admin="$ADMIN"

    if [ $? -eq 0 ]; then
        whiptail_success --title "Erfolgreich" --msgbox "Benutzer wurde erfolgreich erstellt!\n\nE-Mail: $EMAIL\nBenutzername: $USERNAME\nAdmin: $([ $ADMIN -eq 1 ] && echo 'Ja' || echo 'Nein')" 12 60
    else
        whiptail_error --title "Fehler" --msgbox "Fehler beim Erstellen des Benutzers." 8 60
    fi
}

# Hauptlogik
case "$1" in
    setup)
        cmd_setup
        ;;
    maintenance)
        cmd_maintenance
        ;;
    backup)
        cmd_backup
        ;;
    domain)
        cmd_domain
        ;;
    cert)
        cmd_cert
        ;;
    update)
        cmd_update
        ;;
    update-scripts)
        cmd_update_scripts
        ;;
    cache)
        cmd_cache
        ;;
    restart)
        cmd_restart
        ;;
    status)
        cmd_status
        ;;
    logs)
        cmd_logs
        ;;
    info)
        cmd_info
        ;;
    user)
        cmd_user
        ;;
    help|--help|-h|"")
        show_help
        ;;
    *)
        echo -e "${RED}Unbekannter Befehl: $1${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac
