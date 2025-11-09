#!/bin/bash

# SWAP-Setup für Pterodactyl Installation
# Erstellt automatisch SWAP basierend auf verfügbarem Speicher (2%)

# Farben
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Log-Funktion
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE:-/tmp/pterodactyl_install.log}"
}

# SWAP-Setup
setup_swap() {
    log "Starte SWAP-Setup"

    # Prüfen ob bereits SWAP existiert
    if swapon --show | grep -q '/swapfile'; then
        echo -e "${YELLOW}⚠${NC}  SWAP bereits konfiguriert, überspringe..."
        log "SWAP bereits konfiguriert"
        return 0
    fi

    # Gesamtspeicher ermitteln (in MB)
    if [ -z "$TOTAL_DISK_SPACE" ]; then
        TOTAL_DISK_SPACE=$(df -m / | awk 'NR==2 {print $2}')
    fi

    # 2% vom Gesamtspeicher berechnen
    SWAP_SIZE=$((TOTAL_DISK_SPACE * 2 / 100))

    # Mindestens 512 MB, maximal 4 GB
    if [ $SWAP_SIZE -lt 512 ]; then
        SWAP_SIZE=512
    elif [ $SWAP_SIZE -gt 4096 ]; then
        SWAP_SIZE=4096
    fi

    echo -e "${BLUE}ℹ${NC}  SWAP wird erstellt: ${SWAP_SIZE} MB (2% von ${TOTAL_DISK_SPACE} MB Gesamtspeicher)"
    log "Erstelle ${SWAP_SIZE} MB SWAP"

    # SWAP-Datei erstellen
    dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE status=progress 2>> "${LOG_FILE:-/tmp/pterodactyl_install.log}"
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}⚠${NC}  Konnte SWAP nicht erstellen (nicht kritisch)"
        log "WARNUNG: SWAP-Erstellung fehlgeschlagen"
        return 1
    fi

    # Berechtigungen setzen
    chmod 600 /swapfile

    # SWAP formatieren
    mkswap /swapfile >> "${LOG_FILE:-/tmp/pterodactyl_install.log}" 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}⚠${NC}  Konnte SWAP nicht formatieren"
        log "WARNUNG: SWAP-Formatierung fehlgeschlagen"
        rm -f /swapfile
        return 1
    fi

    # SWAP aktivieren
    swapon /swapfile
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}⚠${NC}  Konnte SWAP nicht aktivieren"
        log "WARNUNG: SWAP-Aktivierung fehlgeschlagen"
        rm -f /swapfile
        return 1
    fi

    # SWAP permanent in /etc/fstab eintragen
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log "SWAP in /etc/fstab eingetragen"
    fi

    # Swappiness optimieren (10 = wenig swappen, nur wenn nötig)
    sysctl vm.swappiness=10 >> "${LOG_FILE:-/tmp/pterodactyl_install.log}" 2>&1
    if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi

    echo -e "${GREEN}✓${NC}  SWAP erfolgreich eingerichtet (${SWAP_SIZE} MB)"
    log "SWAP erfolgreich eingerichtet: ${SWAP_SIZE} MB"

    # SWAP-Status anzeigen
    SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
    echo -e "${BLUE}ℹ${NC}  Gesamt-SWAP: ${SWAP_TOTAL} MB"

    return 0
}

# Wenn direkt aufgerufen, SWAP-Setup ausführen
if [ "${BASH_SOURCE[0]}" -eq "$0" ]; then
    setup_swap
fi
