#!/bin/bash

# Zentrale Script-Installation
# Lokale Scripte dienen nur als Offline-Fallback
# Versucht IMMER die neueste Version von GitHub zu laden

install_all_scripts() {
    # Erstelle Verzeichnis
    mkdir -p /opt/pterodactyl

    # Intelligenter Cache: Nicht öfter als alle 30 Minuten von GitHub laden
    # (verhindert zu viele Downloads bei mehreren Script-Aufrufen)
    if [ -f "/opt/pterodactyl/.last_install" ]; then
        LAST_INSTALL=$(cat /opt/pterodactyl/.last_install 2>/dev/null || echo 0)
        CURRENT_TIME=$(date +%s)
        TIME_DIFF=$((CURRENT_TIME - LAST_INSTALL))

        # Wenn letzter Install < 30 Minuten her: Nutze lokale Kopien
        if [ $TIME_DIFF -lt 1800 ]; then
            # Prüfe ob alle kritischen Scripte vorhanden sind
            local all_present=true
            for critical in "whiptail-colors.sh" "gds-command.sh" "installer.sh"; do
                if [ ! -f "/opt/pterodactyl/$critical" ]; then
                    all_present=false
                    break
                fi
            done

            # Wenn alle da sind: Skip (nutze Cache)
            if [ "$all_present" = true ]; then
                return 0
            fi
        fi
    fi

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

    # Zähler für Statistik
    local updated=0
    local cached=0
    local failed=0

    for script in "${SCRIPTS[@]}"; do
        local target="/opt/pterodactyl/$script"
        local success=false

        # Strategie 1: Von GitHub laden (immer versuchen für aktuelle Version)
        if curl -sSL "$REPO_URL/$script" -o "${target}.tmp" 2>/dev/null; then
            # Download erfolgreich
            mv "${target}.tmp" "$target" 2>/dev/null
            chmod +x "$target" 2>/dev/null
            updated=$((updated + 1))
            success=true
        else
            # Strategie 2: Lokale Kopie aus Script-Verzeichnis (falls git clone)
            if [ -f "$SCRIPT_DIR/$script" ]; then
                cp "$SCRIPT_DIR/$script" "$target" 2>/dev/null
                chmod +x "$target" 2>/dev/null
                cached=$((cached + 1))
                success=true
            # Strategie 3: Bereits in /opt/pterodactyl vorhanden (Offline-Fallback)
            elif [ -f "$target" ]; then
                # Behalte alte Version als Fallback
                cached=$((cached + 1))
                success=true
            else
                # Komplett fehlgeschlagen
                failed=$((failed + 1))
            fi
        fi
    done

    # gds-command als 'gds' verfügbar machen
    if [ -f "/opt/pterodactyl/gds-command.sh" ]; then
        cp "/opt/pterodactyl/gds-command.sh" /usr/local/bin/gds 2>/dev/null
        chmod +x /usr/local/bin/gds 2>/dev/null
    fi

    # Timestamp speichern
    date +%s > /opt/pterodactyl/.last_install

    # Debug-Info (nur wenn Fehler aufgetreten)
    if [ $failed -gt 0 ]; then
        echo "Script-Installation: $updated aktualisiert, $cached cached, $failed fehlgeschlagen" >> /opt/pterodactyl/install.log
    fi

    return 0
}

# Wenn direkt aufgerufen
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    install_all_scripts
fi
