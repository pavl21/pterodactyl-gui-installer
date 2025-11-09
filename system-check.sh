#!/bin/bash

# System-Voraussetzungs-Prüfung für Pterodactyl Installation
# Prüft OS-Version, Architektur und System-Anforderungen

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funktion für farbigen Output
print_status() {
    local status=$1
    local message=$2

    case $status in
        "ok")
            echo -e "${GREEN}✓${NC} $message"
            ;;
        "warn")
            echo -e "${YELLOW}⚠${NC} $message"
            ;;
        "error")
            echo -e "${RED}✗${NC} $message"
            ;;
        "info")
            echo -e "${BLUE}ℹ${NC} $message"
            ;;
    esac
}

# Header anzeigen
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}  ${GREEN}GermanDactyl Setup - System-Voraussetzungs-Prüfung${NC}     ${BLUE}║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check 1: Root-Rechte
print_status "info" "Prüfe Root-Rechte..."
if [ "$EUID" -ne 0 ]; then
    print_status "error" "Dieses Script muss als Root ausgeführt werden"
    echo ""
    echo "Bitte führe das Script mit 'sudo' aus:"
    echo "  sudo bash $0"
    echo ""
    exit 1
fi
print_status "ok" "Root-Rechte vorhanden"
echo ""

# Check 1.5: APT/DPKG-Locks prüfen
print_status "info" "Prüfe ob Paketmanager verfügbar ist..."

MAX_WAIT=300  # 5 Minuten
WAIT_TIME=0

while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
      fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
      fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do

    if [ $WAIT_TIME -eq 0 ]; then
        echo ""
        print_status "warn" "Paketmanager ist gerade in Benutzung"
        echo ""
        echo -e "${YELLOW}Ein anderer Prozess verwendet aktuell den Paketmanager (apt/dpkg).${NC}"
        echo "Dies kann sein weil:"
        echo "  • Ein automatisches Update läuft"
        echo "  • Eine andere Installation aktiv ist"
        echo "  • Ein Prozess hängt"
        echo ""
        echo "Warte bis der Prozess beendet ist..."
        echo ""
    fi

    sleep 5
    WAIT_TIME=$((WAIT_TIME + 5))

    # Fortschritt anzeigen
    echo -ne "\r⏳ Gewartet: ${WAIT_TIME}s / ${MAX_WAIT}s"

    if [ $WAIT_TIME -ge $MAX_WAIT ]; then
        echo ""
        echo ""
        print_status "error" "Timeout: Paketmanager ist nach ${MAX_WAIT} Sekunden immer noch blockiert"
        echo ""
        echo "Mögliche Lösungen:"
        echo "  1. Warte bis laufende Updates/Installationen beendet sind"
        echo "  2. Starte den Server neu: sudo reboot"
        echo "  3. Erzwinge das Beenden (auf eigene Gefahr):"
        echo "     sudo killall apt apt-get dpkg"
        echo ""
        exit 1
    fi
done

if [ $WAIT_TIME -gt 0 ]; then
    echo ""
    echo ""
fi

print_status "ok" "Paketmanager ist verfügbar"
echo ""

# Check 2: Betriebssystem
print_status "info" "Prüfe Betriebssystem..."

if [ ! -f /etc/os-release ]; then
    print_status "error" "Kann Betriebssystem nicht identifizieren (/etc/os-release fehlt)"
    exit 1
fi

source /etc/os-release

OS_NAME="${NAME}"
OS_VERSION="${VERSION_ID}"
OS_CODENAME="${VERSION_CODENAME}"

echo -e "  ${BLUE}→${NC} Betriebssystem: ${OS_NAME}"
echo -e "  ${BLUE}→${NC} Version: ${OS_VERSION}"
echo -e "  ${BLUE}→${NC} Codename: ${OS_CODENAME}"

# Nur Debian 12+ unterstützen
if [ "$ID" != "debian" ]; then
    print_status "error" "Nur Debian wird unterstützt"
    echo ""
    echo "Dieses Script unterstützt ausschließlich Debian 12 (Bookworm) und neuer."
    echo "Erkanntes System: ${OS_NAME}"
    echo ""
    exit 1
fi

# Debian Version prüfen
DEBIAN_VERSION=$(echo "$OS_VERSION" | cut -d. -f1)
if [ "$DEBIAN_VERSION" -lt 12 ]; then
    print_status "error" "Debian-Version zu alt"
    echo ""
    echo "Dieses Script benötigt mindestens Debian 12 (Bookworm)."
    echo "Aktuelle Version: Debian ${OS_VERSION}"
    echo ""
    echo "Bitte aktualisiere dein System oder verwende ein neueres Debian."
    exit 1
fi

print_status "ok" "Debian ${OS_VERSION} (${OS_CODENAME}) wird unterstützt"
echo ""

# Check 3: Architektur
print_status "info" "Prüfe System-Architektur..."
ARCH=$(uname -m)
echo -e "  ${BLUE}→${NC} Architektur: ${ARCH}"

if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ]; then
    print_status "warn" "Architektur ${ARCH} wurde nicht ausgiebig getestet"
else
    print_status "ok" "Architektur ${ARCH} wird unterstützt"
fi
echo ""

# Check 4: Verfügbarer RAM
print_status "info" "Prüfe verfügbaren Arbeitsspeicher..."
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
echo -e "  ${BLUE}→${NC} RAM: ${TOTAL_RAM} MB"

RESOURCE_WARNING=0

if [ "$TOTAL_RAM" -lt 1024 ]; then
    print_status "error" "Zu wenig RAM"
    echo ""
    echo "Pterodactyl Panel benötigt mindestens 1 GB RAM."
    echo "Verfügbar: ${TOTAL_RAM} MB"
    echo ""
    exit 1
elif [ "$TOTAL_RAM" -lt 2048 ]; then
    print_status "warn" "RAM knapp bemessen (mindestens 2 GB empfohlen)"
    RESOURCE_WARNING=1
else
    print_status "ok" "Ausreichend RAM verfügbar"
fi
echo ""

# Check 5: Freier Speicherplatz
print_status "info" "Prüfe freien Speicherplatz..."
FREE_SPACE=$(df -m / | awk 'NR==2 {print $4}')
TOTAL_SPACE=$(df -m / | awk 'NR==2 {print $2}')
echo -e "  ${BLUE}→${NC} Frei: ${FREE_SPACE} MB / Gesamt: ${TOTAL_SPACE} MB"

if [ "$FREE_SPACE" -lt 5120 ]; then
    print_status "error" "Zu wenig Speicherplatz"
    echo ""
    echo "Mindestens 5 GB freier Speicher erforderlich."
    echo "Verfügbar: ${FREE_SPACE} MB"
    echo ""
    exit 1
elif [ "$FREE_SPACE" -lt 10240 ]; then
    print_status "warn" "Speicherplatz knapp (mindestens 10 GB empfohlen)"
    RESOURCE_WARNING=1
else
    print_status "ok" "Ausreichend Speicherplatz verfügbar"
fi

# Export für SWAP-Berechnung (2% vom Gesamtspeicher)
export TOTAL_DISK_SPACE="$TOTAL_SPACE"
echo ""

# Check 6: Virtualisierung
print_status "info" "Prüfe Virtualisierung (für Docker/Wings)..."
if [ -f /proc/cpuinfo ]; then
    if grep -q -E 'vmx|svm' /proc/cpuinfo; then
        print_status "ok" "Virtualisierung verfügbar"
    else
        print_status "warn" "Keine Hardware-Virtualisierung erkannt (könnte Docker beeinträchtigen)"
    fi
else
    print_status "warn" "Kann Virtualisierung nicht prüfen"
fi
echo ""

# Check 7: Systemd
print_status "info" "Prüfe Systemd..."
if command -v systemctl &> /dev/null; then
    print_status "ok" "Systemd verfügbar"
else
    print_status "error" "Systemd nicht gefunden (erforderlich)"
    exit 1
fi
echo ""

# Check 8: Netzwerk
print_status "info" "Prüfe Netzwerkverbindung..."
if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
    print_status "ok" "Netzwerkverbindung verfügbar"
else
    print_status "error" "Keine Netzwerkverbindung"
    echo ""
    echo "Bitte prüfe deine Internetverbindung."
    exit 1
fi
echo ""

# Check 9: DNS
print_status "info" "Prüfe DNS-Auflösung..."
if ping -c 1 -W 2 google.com &> /dev/null; then
    print_status "ok" "DNS funktioniert"
else
    print_status "warn" "DNS-Auflösung könnte Probleme haben"
fi
echo ""

# Check 10: Bereits installierte Webserver/Datenbanken
print_status "info" "Prüfe auf Konflikte mit bereits installierten Diensten..."

CONFLICTS=0

if systemctl is-active --quiet apache2; then
    print_status "warn" "Apache2 läuft bereits (Konflikt mit Nginx möglich)"
    CONFLICTS=1
fi

if systemctl is-active --quiet nginx && [ -d /var/www/pterodactyl ]; then
    print_status "warn" "Pterodactyl scheint bereits installiert zu sein"
    CONFLICTS=1
fi

if [ $CONFLICTS -eq 0 ]; then
    print_status "ok" "Keine Konflikte erkannt"
fi
echo ""

# Zusammenfassung
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}  ${GREEN}Zusammenfassung${NC}                                            ${BLUE}║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ $CONFLICTS -eq 0 ]; then
    print_status "ok" "System erfüllt alle Mindestanforderungen"
else
    print_status "warn" "System erfüllt Mindestanforderungen, aber es wurden Konflikte erkannt"
fi

# Ressourcen-Warnung wenn nötig
if [ $RESOURCE_WARNING -eq 1 ]; then
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║${NC}  ${RED}⚠️  RESSOURCEN-WARNUNG${NC}                                  ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Dein Server hat begrenzte Ressourcen:${NC}"
    echo ""
    if [ "$TOTAL_RAM" -lt 2048 ]; then
        echo -e "  ${RED}•${NC} RAM: ${TOTAL_RAM} MB (empfohlen: mindestens 2048 MB)"
    fi
    if [ "$FREE_SPACE" -lt 10240 ]; then
        echo -e "  ${RED}•${NC} Speicher: ${FREE_SPACE} MB frei (empfohlen: mindestens 10 GB)"
    fi
    echo ""
    echo -e "${YELLOW}Mögliche Konsequenzen:${NC}"
    echo "  • Installation kann länger dauern"
    echo "  • Panel könnte langsam laufen"
    echo "  • Instabilitäten bei hoher Last möglich"
    echo "  • Gameserver könnten Performance-Probleme haben"
    echo ""
    echo -e "${GREEN}Empfehlungen:${NC}"
    echo "  • Upgrade auf einen Server mit mehr RAM"
    echo "  • Mindestens 2 GB RAM und 20 GB Speicher für Produktiv-Betrieb"
    echo ""

    # Export für nachfolgende Scripts
    export RESOURCE_WARNING_SHOWN=1
fi

echo ""
echo -e "${GREEN}Das System ist bereit für die Pterodactyl-Installation!${NC}"
echo ""

# Export Variablen für andere Scripts
export SYSTEM_CHECK_PASSED=1
export DETECTED_OS="debian"
export DETECTED_OS_VERSION="$OS_VERSION"
export DETECTED_OS_CODENAME="$OS_CODENAME"
export TOTAL_RAM_MB="$TOTAL_RAM"
export FREE_SPACE_MB="$FREE_SPACE"
