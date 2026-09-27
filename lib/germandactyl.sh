#!/bin/bash
# Pfad: lib/germandactyl.sh
# GermanDactyl: Auswahl der Panel-Version passend zu verfügbaren Übersetzungs-Patches
# und eigenständiges Anwenden des Patches (Node.js 22 + yarn, wie vom Panel vorausgesetzt).

GD_PATCH_SERVER="https://patch.germandactyl.de"
GD_PATCH_REPO="pavl21/GermanDactyl"
GD_PATCH_FALLBACK="1.12.2"   # Wird nur genutzt, wenn die Patch-Liste nicht abgerufen werden kann
GD_NODE_MAJOR="22"

gd_patch_exists() {
    # gd_patch_exists <version> -> wahr, wenn es einen GermanDactyl-Patch gibt
    local code
    code="$(curl -s -o /dev/null -L -w '%{http_code}' --max-time 15 "$GD_PATCH_SERVER/$1")"
    [ "$code" = "200" ]
}

gd_patch_latest() {
    # Neueste Version, für die ein Patch existiert (aus dem GermanDactyl-Repository ermittelt)
    local list
    list="$(curl -fsS --max-time 15 "https://api.github.com/repos/$GD_PATCH_REPO/contents/patches" 2>/dev/null \
        | grep -oE '"name": *"v[0-9]+\.[0-9]+\.[0-9]+\.patch"' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1)"
    if [ -n "$list" ]; then
        echo "$list"
    else
        echo "$GD_PATCH_FALLBACK"
    fi
}

gd_choose_panel_version() {
    # Setzt GD_PANEL_VERSION und GD_APPLY_PATCH (true/false) – mit Dialog, falls kein passender Patch existiert.
    local latest patch_version choice
    latest="$(gd_latest_release pterodactyl/panel)"
    if [ -z "$latest" ]; then
        gd_msg "Fehler" "Die aktuelle Pterodactyl-Version konnte nicht ermittelt werden. Prüfe die Internetverbindung (github.com)." 9 70
        return 1
    fi

    if gd_patch_exists "$latest"; then
        GD_PANEL_VERSION="$latest"
        GD_APPLY_PATCH=true
        return 0
    fi

    patch_version="$(gd_patch_latest)"
    choice=$(whiptail --title "🇩🇪 GermanDactyl – Versionsauswahl" --menu "Die neueste Pterodactyl-Version ist v$latest. Für diese Version gibt es noch keine deutsche Übersetzung (GermanDactyl).\n\nDie neueste übersetzte Version ist v$patch_version. Welche Version möchtest du installieren?" 18 78 2 \
        "1" "v$latest – aktuellste Version, Oberfläche auf Englisch" \
        "2" "v$patch_version – ältere Version, Oberfläche auf Deutsch" 3>&1 1>&2 2>&3) || return 1

    if [ "$choice" = "2" ]; then
        GD_PANEL_VERSION="$patch_version"
        GD_APPLY_PATCH=true
    else
        GD_PANEL_VERSION="$latest"
        GD_APPLY_PATCH=false
    fi
    return 0
}

gd_install_node() {
    # Node.js >= 22 sicherstellen (Distro-Paket, falls neu genug, sonst NodeSource-Repository) + yarn
    local current=0
    if command -v node >/dev/null 2>&1; then
        current="$(node -v | sed 's/^v//; s/\..*//')"
    fi
    if [ "$current" -lt "$GD_NODE_MAJOR" ]; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg || return 1
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${GD_NODE_MAJOR}.x nodistro main" \
            > /etc/apt/sources.list.d/nodesource.list
        gd_apt update || return 1
        gd_apt install nodejs || return 1
    fi
    if ! command -v yarn >/dev/null 2>&1; then
        npm install -g yarn || return 1
    fi
    return 0
}

gd_build_swap_on() {
    # Der Frontend-Build braucht viel Arbeitsspeicher. Bei weniger als 3 GB RAM+Swap
    # wird für die Dauer des Builds eine temporäre Swap-Datei angelegt.
    local total
    total="$(LC_ALL=C free -m | awk '/^Mem:/{m=$2} /^Swap:/{s=$2} END{print m+s}')"
    GD_BUILD_SWAP=""
    if [ "${total:-0}" -lt 3072 ]; then
        GD_BUILD_SWAP="/swapfile-germandactyl-build"
        if fallocate -l 2G "$GD_BUILD_SWAP" 2>/dev/null || dd if=/dev/zero of="$GD_BUILD_SWAP" bs=1M count=2048 status=none; then
            chmod 600 "$GD_BUILD_SWAP"
            mkswap "$GD_BUILD_SWAP" >/dev/null && swapon "$GD_BUILD_SWAP" || { rm -f "$GD_BUILD_SWAP"; GD_BUILD_SWAP=""; }
        else
            GD_BUILD_SWAP=""
        fi
    fi
    return 0
}

gd_build_swap_off() {
    if [ -n "${GD_BUILD_SWAP:-}" ]; then
        swapoff "$GD_BUILD_SWAP" 2>/dev/null
        rm -f "$GD_BUILD_SWAP"
        GD_BUILD_SWAP=""
    fi
    return 0
}

gd_patch_apply() {
    # gd_patch_apply <version> [panel-pfad] – lädt den Patch und wendet ihn an
    local version="$1" dir="${2:-$PTERO_DIR}" rejected
    cd "$dir" || return 1
    curl -fsSL "$GD_PATCH_SERVER/$version" -o "$GD_TMP/germandactyl.patch" || return 1
    git apply --ignore-whitespace --ignore-space-change -C1 --reject "$GD_TMP/germandactyl.patch"
    rejected="$(find . -path ./node_modules -prune -o \( -name '*.rej' -o -name '*.orig' \) -print)"
    if [ -n "$rejected" ]; then
        echo "Folgende Dateien konnten nicht übersetzt werden (Addon/Theme installiert?):"
        sed 's#^\./##; s#\.rej$##; s#\.orig$##' <<< "$rejected" | sort -u
        find . -path ./node_modules -prune -o \( -name '*.rej' -o -name '*.orig' \) -exec rm -f {} +
    fi
    return 0
}

gd_panel_build() {
    # Frontend des Panels neu bauen (nötig, damit die Übersetzung sichtbar wird)
    local dir="${1:-$PTERO_DIR}" rc=0
    cd "$dir" || return 1
    gd_build_swap_on
    yarn install --frozen-lockfile --network-timeout 600000 || yarn install --network-timeout 600000 || rc=1
    [ $rc -eq 0 ] && { yarn run build:production || rc=1; }
    gd_build_swap_off
    [ $rc -eq 0 ] || return 1
    # node_modules wird nur behalten, wenn Blueprint es für Erweiterungen benötigt (spart sonst ~500 MB)
    [ -f "$dir/.blueprint/extensions/blueprint/private/db/is_installed" ] || rm -rf node_modules
    php artisan view:clear
    php artisan optimize:clear
    chown -R www-data:www-data "$dir"
}

gd_germandactyl_steps() {
    # gd_germandactyl_steps <start-prozent> – Patch-Schritte innerhalb eines offenen Fortschrittsbalkens
    local p="${1:-85}"
    gd_step "$p" "GermanDactyl: Node.js ${GD_NODE_MAJOR} und yarn werden vorbereitet..." gd_install_node
    gd_step $((p + 2)) "GermanDactyl: Deutsche Übersetzung (v$GD_PANEL_VERSION) wird angewendet..." gd_patch_apply "$GD_PANEL_VERSION"
    gd_step $((p + 4)) "GermanDactyl: Oberfläche wird neu gebaut, das dauert einige Minuten..." gd_panel_build
    gd_conf_set GD_GERMANDACTYL "$GD_PANEL_VERSION"
}
