#!/bin/bash
# Pfad: swap-verwaltung.sh
# Swap-Speicher anlegen, ändern oder entfernen (dauerhaft über /etc/fstab).

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
gd_source_lib wings

create_swap() {
    local size ram
    ram="$(LC_ALL=C free -m | awk '/^Mem:/{print $2}')"
    while true; do
        size="$(gd_input "Swap-Speicher erstellen" "Gib die gewünschte Swap-Größe in MB ein.\n\nArbeitsspeicher dieses Servers: ${ram} MB\nEmpfehlung: 2048 MB, bei wenig RAM etwa gleich viel wie der RAM." "2048" 13 70)" || return 0
        [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 256 ] && break
        gd_msg "Ungültige Eingabe" "Bitte gib eine Zahl ab 256 ein." 8 50
    done
    if [ "$(df -Pm / | awk 'NR==2{print $4}')" -le $((size + 1024)) ]; then
        gd_msg "Zu wenig Speicherplatz" "Auf der Festplatte ist nicht genug Platz für ${size} MB Swap frei." 8 70
        return 0
    fi
    clear; echo "Swap-Speicher wird erstellt..."
    if gd_swap_create "$size" >> "$GD_LOG" 2>&1; then
        gd_msg "Swap-Speicher erstellt" "Swap-Speicher mit ${size} MB wurde erstellt und aktiviert. Er bleibt auch nach einem Neustart erhalten." 9 70
    else
        gd_msg "Fehler" "Der Swap-Speicher konnte nicht erstellt werden. Details: $GD_LOG" 9 70
    fi
}

gd_msg "Swap-Verwaltung" "Swap-Speicher wird als Auslagerung genutzt, wenn der Arbeitsspeicher voll ist. Er ist deutlich langsamer als RAM, verhindert aber Abstürze bei kurzen Lastspitzen." 10 70

if [ -e /swapfile ]; then
    current="$(du -m /swapfile | awk '{print $1}')"
    choice=$(whiptail --title "Swap-Speicher vorhanden" --menu "Es existiert bereits Swap-Speicher mit ${current} MB. Was möchtest du tun?" 14 70 3 \
        "1" "Größe ändern" \
        "2" "Swap-Speicher entfernen" \
        "3" "Zurück" 3>&1 1>&2 2>&3) || exit 0
    case "$choice" in
        1) gd_swap_remove >> "$GD_LOG" 2>&1; create_swap ;;
        2) gd_swap_remove >> "$GD_LOG" 2>&1
           gd_msg "Swap-Speicher entfernt" "Der Swap-Speicher wurde deaktiviert und entfernt." 8 60 ;;
    esac
else
    create_swap
fi
