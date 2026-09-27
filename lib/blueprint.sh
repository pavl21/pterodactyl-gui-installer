#!/bin/bash
# Pfad: lib/blueprint.sh
# Optionale Einrichtung von Blueprint (https://blueprint.zip), dem Erweiterungs-Framework für Pterodactyl.
# Blueprint ersetzt beim Installieren/Aktualisieren rund 50 Dateien der Oberfläche. Deshalb gilt die Reihenfolge:
# Panel -> Blueprint -> GermanDactyl-Patch -> Oberfläche bauen. Nach jedem Panel-Update wird Blueprint erneut angewendet.

GD_BLUEPRINT_REPO="BlueprintFramework/framework"
GD_BLUEPRINT_LEGACY_TAG="beta-2026-05"   # Letzte Version vor der Umstellung auf Pterodactyl 1.14+
GD_BLUEPRINT_MARKER=".blueprint/extensions/blueprint/private/db/is_installed"

gd_blueprint_installed() {
    [ -f "$PTERO_DIR/$GD_BLUEPRINT_MARKER" ]
}

gd_blueprint_tag_for() {
    # gd_blueprint_tag_for <panelversion> – passende Blueprint-Version (neueste ab Panel 1.14, sonst die letzte für 1.12)
    if gd_version_ge "$1" "1.14.0"; then
        gd_latest_tag "$GD_BLUEPRINT_REPO"
    else
        echo "$GD_BLUEPRINT_LEGACY_TAG"
    fi
}

gd_blueprint_rc() {
    cat > "$PTERO_DIR/.blueprintrc" <<'EOF'
WEBUSER="www-data";
OWNERSHIP="www-data:www-data";
USERSHELL="/bin/bash";
EOF
}

gd_blueprint_apply() {
    # gd_blueprint_apply <tag> – Blueprint (erneut) installieren; ersetzt überschriebene Dateien nach Panel-Updates
    local tag="$1"
    cd "$PTERO_DIR" || return 1
    gd_install_node || return 1
    gd_apt_install zip unzip git curl || return 1
    curl -fL "https://github.com/${GD_BLUEPRINT_REPO}/releases/download/${tag}/release.zip" -o "$GD_TMP/blueprint.zip" || return 1
    unzip -o -q "$GD_TMP/blueprint.zip" -d "$PTERO_DIR" || return 1
    gd_blueprint_rc
    rm -f "$PTERO_DIR/$GD_BLUEPRINT_MARKER"
    chmod +x "$PTERO_DIR/blueprint.sh"
    gd_build_swap_on
    yarn install --network-timeout 600000 || { gd_build_swap_off; return 1; }
    # Einzige Rückfrage von blueprint.sh: Wartungsmodus während der Installation -> ja
    echo y | bash "$PTERO_DIR/blueprint.sh"
    local rc=$?
    gd_build_swap_off
    [ $rc -eq 0 ] || return 1
    gd_conf_set BLUEPRINT_TAG "$tag"
}

gd_blueprint_version() {
    command -v blueprint >/dev/null 2>&1 && blueprint -v 2>/dev/null | tail -n1
}

# ---------------------------------------------------------------------------
# Einbindung in Installation und Aktualisierung
# ---------------------------------------------------------------------------
gd_blueprint_ask() {
    # Setzt GD_BLUEPRINT (true/false)
    GD_BLUEPRINT=false
    local text="Blueprint ist ein Framework, mit dem du Erweiterungen und Themes für Pterodactyl bequem installieren kannst (https://blueprint.zip).\n\nMöchtest du Blueprint gleich mit installieren? (optional)"
    if [ "${GD_APPLY_PATCH:-false}" = "true" ]; then
        text+="\n\nHinweis: Blueprint ersetzt einige Dateien der Oberfläche. Die deutsche Übersetzung wird danach angewendet, einzelne Bereiche können aber englisch bleiben."
    fi
    if gd_yesno "🧩 Blueprint (optional)" "$text" 16 78; then
        GD_BLUEPRINT=true
    fi
    return 0
}

gd_blueprint_install_step() {
    # gd_blueprint_install_step <prozent> – innerhalb eines offenen Fortschrittsbalkens
    local tag
    tag="$(gd_blueprint_tag_for "$GD_PANEL_VERSION")"
    [ -z "$tag" ] && gd_fail "Die Blueprint-Version konnte nicht ermittelt werden."
    gd_step "$1" "Blueprint ${tag} wird installiert (Oberfläche wird gebaut, dauert einige Minuten)..." gd_blueprint_apply "$tag"
}

gd_blueprint_menu() {
    local choice ver files
    while true; do
        if gd_blueprint_installed; then
            ver="$(gd_blueprint_version)"
            choice=$(whiptail --title "🧩 Blueprint" --menu "Blueprint ist installiert (${ver:-unbekannt}).\n\nErweiterungen (.blueprint-Dateien) lädst du zuerst nach $PTERO_DIR hoch und installierst sie dann hier." 18 78 3 \
                "1" "Erweiterung installieren" \
                "2" "Blueprint aktualisieren / erneut anwenden" \
                "3" "Zurück" 3>&1 1>&2 2>&3) || return 0
            case "$choice" in
                1)
                    files="$(cd "$PTERO_DIR" && ls -1 ./*.blueprint 2>/dev/null | sed 's#^\./##; s#\.blueprint$##')"
                    if [ -z "$files" ]; then
                        gd_msg "Keine Erweiterung gefunden" "In $PTERO_DIR liegt keine .blueprint-Datei. Lade die Erweiterung zuerst per SFTP dorthin hoch." 10 70
                        continue
                    fi
                    local items=() f ext
                    for f in $files; do items+=("$f" ""); done
                    ext=$(whiptail --title "Erweiterung installieren" --menu "Welche Erweiterung soll installiert werden?" 18 70 8 "${items[@]}" 3>&1 1>&2 2>&3) || continue
                    clear
                    echo "Erweiterung $ext wird installiert (die Oberfläche wird neu gebaut)..."
                    if (cd "$PTERO_DIR" && blueprint -install "$ext") 2>&1 | tee -a "$GD_LOG"; then
                        gd_msg "✅ Erweiterung installiert" "Die Erweiterung $ext wurde installiert." 8 60
                    else
                        gd_msg "❌ Fehler" "Die Erweiterung konnte nicht installiert werden. Details: $GD_LOG" 9 70
                    fi ;;
                2) gd_blueprint_reapply_dialog ;;
                *) return 0 ;;
            esac
        else
            gd_yesno "🧩 Blueprint installieren" "Blueprint ist ein Framework für Erweiterungen und Themes (https://blueprint.zip).\n\nBlueprint ersetzt einige Dateien der Oberfläche. Eine vorhandene deutsche Übersetzung wird danach erneut angewendet, einzelne Bereiche können aber englisch bleiben.\n\nEmpfehlung: Erstelle vorher ein Backup über die Backup-Verwaltung.\n\nJetzt installieren?" 17 78 || return 0
            gd_blueprint_reapply_dialog
            gd_blueprint_installed || return 0
        fi
    done
}

gd_blueprint_reapply_dialog() {
    # Blueprint installieren/aktualisieren und danach die Übersetzung erneut anwenden
    local panel_version tag gd_version
    panel_version="$(gd_panel_installed_version)"
    tag="$(gd_blueprint_tag_for "$panel_version")"
    gd_version="$(gd_conf_get GD_GERMANDACTYL)"
    gd_gauge_open "🧩 Blueprint" "Blueprint wird vorbereitet..."
    gd_step 10 "Blueprint ${tag} wird installiert (Oberfläche wird gebaut, dauert einige Minuten)..." gd_blueprint_apply "$tag"
    if [ -n "$gd_version" ] && [ "$gd_version" = "$panel_version" ]; then
        GD_PANEL_VERSION="$panel_version"
        gd_germandactyl_steps 60
    fi
    gd_progress 100 "Fertig."
    gd_gauge_close
    gd_msg "✅ Blueprint" "Blueprint ${tag} ist eingerichtet." 8 60
}
