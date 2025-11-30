#!/bin/bash

# Zentrale Script-Installation
# Lokale Scripte dienen nur als Offline-Fallback
# Versucht IMMER die neueste Version von GitHub zu laden

# ============================================
# ZENTRALES LOGGING-SYSTEM
# ============================================

# Zentrale Log-Datei
LOG_FILE="${LOG_FILE:-/var/log/pterodactyl-installer.log}"
VERBOSE="${VERBOSE:-false}"

# Log-Datei erstellen falls nicht vorhanden
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/pterodactyl-installer.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

# Basis-Logging-Funktion
_log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local script_name=$(basename "${BASH_SOURCE[2]}" 2>/dev/null || echo "unknown")

    # Format: [TIMESTAMP] [LEVEL] [SCRIPT] Message
    echo "[$timestamp] [$level] [$script_name] $message" >> "$LOG_FILE"

    # Bei VERBOSE: Auch in Console ausgeben
    if [ "$VERBOSE" = "true" ]; then
        case "$level" in
            ERROR)   echo -e "\033[0;31m[$level]\033[0m $message" >&2 ;;
            WARN)    echo -e "\033[0;33m[$level]\033[0m $message" >&2 ;;
            SUCCESS) echo -e "\033[0;32m[$level]\033[0m $message" ;;
            *)       echo "[$level] $message" ;;
        esac
    fi
}

# Öffentliche Logging-Funktionen
log_info() {
    _log "INFO" "$1"
}

log_success() {
    _log "SUCCESS" "$1"
}

log_warn() {
    _log "WARN" "$1"
}

log_error() {
    _log "ERROR" "$1"
}

log_debug() {
    if [ "$VERBOSE" = "true" ]; then
        _log "DEBUG" "$1"
    fi
}

# Befehl mit Logging ausführen
log_command() {
    local cmd="$1"
    log_debug "Executing: $cmd"

    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        log_debug "Command succeeded: $cmd"
        return 0
    else
        local exit_code=$?
        log_error "Command failed (exit $exit_code): $cmd"
        return $exit_code
    fi
}

# ============================================
# ENDE LOGGING-SYSTEM
# ============================================

install_all_scripts() {
    log_info "Starting script installation/update process"

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
                    log_warn "Critical script missing: $critical"
                    break
                fi
            done

            # Wenn alle da sind: Skip (nutze Cache)
            if [ "$all_present" = true ]; then
                log_debug "Using cached scripts (age: ${TIME_DIFF}s < 1800s)"
                return 0
            fi
        else
            log_info "Cache expired (age: ${TIME_DIFF}s >= 1800s), updating scripts"
        fi
    else
        log_info "No cache found, performing initial script installation"
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

    log_info "Using branch: $BRANCH"

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

        log_debug "Downloading $script from GitHub..."

        # Strategie 1: Von GitHub laden (immer versuchen für aktuelle Version)
        if curl -sSL "$REPO_URL/$script" -o "${target}.tmp" 2>/dev/null; then
            # Download erfolgreich
            mv "${target}.tmp" "$target" 2>/dev/null
            chmod +x "$target" 2>/dev/null
            updated=$((updated + 1))
            success=true
            log_success "Downloaded: $script"
        else
            # Strategie 2: Lokale Kopie aus Script-Verzeichnis (falls git clone)
            if [ -f "$SCRIPT_DIR/$script" ]; then
                cp "$SCRIPT_DIR/$script" "$target" 2>/dev/null
                chmod +x "$target" 2>/dev/null
                cached=$((cached + 1))
                success=true
                log_warn "Failed to download $script, using fallback"
            # Strategie 3: Bereits in /opt/pterodactyl vorhanden (Offline-Fallback)
            elif [ -f "$target" ]; then
                # Behalte alte Version als Fallback
                cached=$((cached + 1))
                success=true
                log_warn "Failed to download $script, using fallback"
            else
                # Komplett fehlgeschlagen
                failed=$((failed + 1))
                log_error "Failed to obtain $script - not found locally or on GitHub"
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

    # Statistiken und Zusammenfassung
    log_success "Script installation complete: $updated updated, $cached cached, $failed failed"

    # Debug-Info (nur wenn Fehler aufgetreten)
    if [ $failed -gt 0 ]; then
        echo "Script-Installation: $updated aktualisiert, $cached cached, $failed fehlgeschlagen" >> /opt/pterodactyl/install.log
    fi

    return 0
}

# Hilfsfunktion: Script aufrufen (lokal mit Fallback)
# Verwendung: call_script "backup-verwaltung.sh"
call_script() {
    local script_name="$1"
    shift  # Entferne ersten Parameter, Rest sind Argumente für das Script

    log_info "Calling script: $script_name"

    # Priorität 1: Lokale Kopie in /opt/pterodactyl/
    if [ -f "/opt/pterodactyl/$script_name" ]; then
        log_debug "Script found locally: /opt/pterodactyl/$script_name"
        bash "/opt/pterodactyl/$script_name" "$@"
        return $?
    fi

    # Priorität 2: Im aktuellen Verzeichnis (git clone)
    if [ -f "$(dirname "${BASH_SOURCE[0]}")/$script_name" ]; then
        log_debug "Script found locally: $(dirname "${BASH_SOURCE[0]}")/$script_name"
        bash "$(dirname "${BASH_SOURCE[0]}")/$script_name" "$@"
        return $?
    fi

    # Priorität 3: Von GitHub laden (mit Branch-Erkennung)
    log_warn "Script not found locally, downloading from GitHub"

    BRANCH="${GITHUB_BRANCH:-main}"
    if [ -z "$GITHUB_BRANCH" ] && [ -d "$(dirname "${BASH_SOURCE[0]}")/.git" ]; then
        GIT_BRANCH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ -n "$GIT_BRANCH" ] && [ "$GIT_BRANCH" != "HEAD" ]; then
            BRANCH="$GIT_BRANCH"
        fi
    fi

    REPO_URL="https://raw.githubusercontent.com/pavl21/pterodactyl-gui-installer/${BRANCH}"
    curl -sSfL "$REPO_URL/$script_name" | bash -s -- "$@"
    return $?
}

# Wenn direkt aufgerufen
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    install_all_scripts
fi
