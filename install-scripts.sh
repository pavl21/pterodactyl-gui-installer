#!/bin/bash

# Zentrale Script-Installation
# Wird von allen Hauptscripten aufgerufen um sicherzustellen,
# dass alle Verwaltungs-Scripte verfügbar sind

install_all_scripts() {
    # Prüfen ob bereits installiert (skip wenn weniger als 5 Minuten alt)
    if [ -f "/opt/pterodactyl/.last_install" ]; then
        LAST_INSTALL=$(cat /opt/pterodactyl/.last_install 2>/dev/null || echo 0)
        CURRENT_TIME=$(date +%s)
        TIME_DIFF=$((CURRENT_TIME - LAST_INSTALL))
        
        # Wenn letzter Install weniger als 5 Minuten her, skip
        if [ $TIME_DIFF -lt 300 ]; then
            return 0
        fi
    fi

    # Erstelle Verzeichnis
    mkdir -p /opt/pterodactyl

    # Branch-Erkennung
    # 1. Priorität: Umgebungsvariable GITHUB_BRANCH
    # 2. Priorität: Auto-Detection aus git (falls verfügbar)
    # 3. Fallback: main
    BRANCH="${GITHUB_BRANCH:-main}"

    # Versuche Branch aus git zu erkennen (falls wir in einem git repo sind)
    if [ -z "$GITHUB_BRANCH" ] && [ -d "$(dirname "${BASH_SOURCE[0]}")/.git" ]; then
        GIT_BRANCH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ -n "$GIT_BRANCH" ] && [ "$GIT_BRANCH" != "HEAD" ]; then
            BRANCH="$GIT_BRANCH"
        fi
    fi

    # GitHub Repository Basis-URL mit erkanntem Branch
    REPO_URL="https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/${BRANCH}"

    # Script-Verzeichnis (falls lokal verfügbar)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Liste aller Scripte
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

    for script in "${SCRIPTS[@]}"; do
        # Überspringen wenn bereits vorhanden
        if [ -f "/opt/pterodactyl/$script" ]; then
            continue
        fi

        # Versuche lokale Kopie
        if [ -f "$SCRIPT_DIR/$script" ]; then
            cp "$SCRIPT_DIR/$script" "/opt/pterodactyl/$script" 2>/dev/null
            chmod +x "/opt/pterodactyl/$script" 2>/dev/null
        else
            # Falls lokal nicht vorhanden, von GitHub holen
            curl -sSL "$REPO_URL/$script" -o "/opt/pterodactyl/$script" 2>/dev/null
            chmod +x "/opt/pterodactyl/$script" 2>/dev/null
        fi
    done

    # gds-command als 'gds' verfügbar machen
    if [ -f "/opt/pterodactyl/gds-command.sh" ]; then
        cp "/opt/pterodactyl/gds-command.sh" /usr/local/bin/gds 2>/dev/null
        chmod +x /usr/local/bin/gds 2>/dev/null
    fi

    # Timestamp speichern
    date +%s > /opt/pterodactyl/.last_install

    return 0
}

# Wenn direkt aufgerufen
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    install_all_scripts
fi
