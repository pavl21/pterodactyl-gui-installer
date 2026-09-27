#!/bin/bash
# Pfad: theme-verwaltung.sh
# Theme-Verwaltung. Die früher genutzten Farbthemes (Sigma-Production, Stand Pterodactyl 1.10) überschreiben
# den Quellcode der Oberfläche mit einer alten Version und sind mit aktuellen Panels nicht mehr kompatibel.
# Themes werden deshalb über Blueprint (https://blueprint.zip) installiert.

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
gd_source_lib blueprint

while true; do
    choice=$(whiptail --title "🎨 Theme-Verwaltung" --menu "Themes und Erweiterungen werden über Blueprint installiert. Passende Themes findest du unter https://blueprint.zip/browse.\n\nHinweis: Die früheren Farbthemes (DarkNRed usw.) basieren auf Pterodactyl 1.10 und würden aktuelle Panels beschädigen. Sie werden deshalb nicht mehr angeboten." 18 78 3 \
        "1" "🧩 Blueprint öffnen (Themes/Erweiterungen installieren)" \
        "2" "🔧 Original-Oberfläche wiederherstellen (altes Theme entfernen)" \
        "3" "↩️  Zurück" 3>&1 1>&2 2>&3) || exit 0
    case "$choice" in
        1) gd_blueprint_menu ;;
        2)
            gd_msg "🔧 Original-Oberfläche" "Um ein altes Theme vollständig zu entfernen, werden die Dateien des Panels neu aufgespielt (wie beim Aktualisieren). Deine Daten bleiben dabei erhalten, Blueprint und die deutsche Übersetzung werden erneut angewendet." 12 74
            # Danach den Sicherungsordner des alten Theme-Installers entfernen
            gd_panel_update && rm -rf "$PTERO_DIR/backup"
            ;;
        *) exit 0 ;;
    esac
done
